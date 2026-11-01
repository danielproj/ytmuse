import AccountSession
import Foundation
import Observation

public enum CommentsState: Equatable, Sendable {
    case unresolved(String)
    case idle
    case signInRequired
    case loading
    case loaded(CommentsPage)
    case failed(CommentsFailure)
}

/// MEDIA10: comments, ratings, collaboration invitations and moderation, for the account, where the source supplies them.
///
/// Rules this type keeps:
/// - every write is one explicit call for one item (a post, one moderation, one invite request). Nothing loops, polls, retries by itself
///   or queues for later; a request that never left says so and changes nothing;
/// - the person's role decides before anything is sent (`SocialPolicy`); a denied action reaches no transport. Moderation is offered only
///   where the source offered that exact action on that exact comment, and a destructive one needs a confirmation;
/// - the list of comments is only ever what the source returned. A post that the source confirmed is shown by reading again, never by
///   inserting the text locally; one whose outcome is unknown is checked by a read before the person is offered anything else;
/// - ratings and invitations are done by the Library's ledger and the playlist's edit session, which are the only writers; this type adds
///   the role check and the outcome record, and reads their states;
/// - every action leaves one entry in the outbox with its result. Subjects are ids of the service's own items, never addresses.
/// The question a destructive moderation asks, in full: which offer, on which comment (by whom, saying what). Two confirmations are equal only
/// when they name the same thing.
public struct ModerationConfirmation: Equatable, Sendable {
    public let subject: SocialSubject
    public let offer: ModerationOffer
    public let commentID: String
    public let author: String
    public let text: String
}

@MainActor @Observable public final class SocialSurface {
    public let outbox = SocialOutbox()
    public private(set) var comments: [SocialSubject: CommentsState] = [:]
    /// Subjects with a post or moderation in flight (one at a time per subject).
    public private(set) var busy: Set<SocialSubject> = []
    @ObservationIgnored private let transport: any CommentsTransport
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private let ledger: LibraryWriteLedger?
    @ObservationIgnored private var generation: UInt64 = 0
    /// The app's own bound on one comment, not the source's.
    public static let maximumCommentCharacters = 10_000
    /// Requests handed to the transport (a measurement: one explicit action is one request).
    @ObservationIgnored public private(set) var postCount = 0
    @ObservationIgnored public private(set) var moderationCount = 0
    @ObservationIgnored public private(set) var readCount = 0
    public let development: Bool

    public init(transport: any CommentsTransport, ledger: LibraryWriteLedger? = nil, signedIn: @escaping @MainActor () -> SearchPlayback = { .available }, development: Bool = false) {
        self.transport = transport; self.ledger = ledger; self.signedIn = signedIn; self.development = development
    }

    public var isSignedIn: Bool { signedIn() == .available }
    public func songRole() -> SocialRole { isSignedIn ? .member : .signedOut }
    public func playlistRole(_ session: PlaylistEditSession) -> SocialRole { SocialRole.of(session.role, signedIn: isSignedIn) }
    public func state(_ subject: SocialSubject) -> CommentsState {
        if let reason = transport.unresolved { return .unresolved(reason) }
        return comments[subject] ?? (isSignedIn ? .idle : .signInRequired)
    }
    public func page(_ subject: SocialSubject) -> CommentsPage? { if case .loaded(let page)? = comments[subject] { page } else { nil } }

    // MARK: Reading

    public func loadComments(_ subject: SocialSubject) async {
        if transport.unresolved != nil { return }
        if case .loading? = comments[subject] { return }
        guard isSignedIn else { comments[subject] = .signInRequired; return }
        let ticket = generation
        comments[subject] = .loading; readCount += 1
        do {
            let found = try await transport.read(subject)
            guard ticket == generation else { return }
            comments[subject] = .loaded(CommentsPage(comments: Self.unique(found.comments), canPost: found.canPost))
        } catch let failure as CommentsFailure { if ticket == generation { comments[subject] = .failed(failure) } }
        catch { if ticket == generation { comments[subject] = .failed(.unreadable) } }
    }
    static func unique(_ comments: [SocialComment]) -> [SocialComment] {
        var seen = Set<String>()
        return comments.filter { seen.insert($0.id).inserted }
    }

    // MARK: Writing

    /// Posts one comment the person wrote, from a press on Post. Only where the source offered posting on this subject.
    @discardableResult public func post(_ text: String, on subject: SocialSubject) async -> SocialOutboxEntry.Result {
        let label = String(localized: "Comment on \(subject.description)")
        let role = songRole()
        if let reason = transport.unresolved { return refuse(.postComment, label, .sourceUnresolved(reason)) }
        if case .denied(let denial) = SocialPolicy.permission(.postComment, role: role) { return refuse(.postComment, label, .denied(denial)) }
        guard let page = page(subject), page.canPost else {
            return refuse(.postComment, label, .denied(.notOffered(String(localized: "YouTube Music didn’t offer commenting here."))))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return refuse(.postComment, label, .denied(.invalid(String(localized: "Write something to post.")))) }
        guard trimmed.count <= Self.maximumCommentCharacters else {
            return refuse(.postComment, label, .denied(.invalid(String(localized: "This comment is longer than this app sends in one post."))))
        }
        guard !busy.contains(subject) else { return refuse(.postComment, label, .denied(.busy)) }
        busy.insert(subject); postCount += 1
        let entry = outbox.open(.postComment, subject: label)
        let ticket = generation
        let result = await send({ try await self.transport.post(trimmed, on: subject) })
        guard ticket == generation else { return result }
        busy.remove(subject); outbox.settle(entry, result)
        // A confirmed post is shown by reading again, not by inserting the text here.
        if result == .confirmed { await loadComments(subject) }
        return result
    }

    /// What the question for a destructive moderation names: this offer, on this comment as the page shows it now. Nil when the source did not
    /// offer it. The dialog holds it while it asks; `moderate` accepts a destructive request only with the very same value.
    public func confirmation(for offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject) -> ModerationConfirmation? {
        guard let live = page(subject)?.comments.first(where: { $0.id == comment.id }), live.moderation.contains(offer) else { return nil }
        return ModerationConfirmation(subject: subject, offer: offer, commentID: live.id, author: live.author, text: live.text)
    }

    /// One moderation the source offered on this comment. A destructive one needs the `confirmation` the question named (compared with what the
    /// page shows now, so an answer to a question about another comment, or about a comment that has changed, is no answer).
    @discardableResult public func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject, confirmation: ModerationConfirmation? = nil) async -> SocialOutboxEntry.Result {
        let label = String(localized: "\(offer.title): comment by \(comment.author)")
        if let reason = transport.unresolved { return refuse(.moderateComment, label, .sourceUnresolved(reason)) }
        if case .denied(let denial) = SocialPolicy.permission(.moderateComment, role: songRole()) { return refuse(.moderateComment, label, .denied(denial)) }
        // Only an action the source offered on this very comment, as the page now shows it.
        guard let live = page(subject)?.comments.first(where: { $0.id == comment.id }), live.moderation.contains(offer) else {
            return refuse(.moderateComment, label, .denied(.notAllowedOnThisComment))
        }
        if offer.destructive, confirmation == nil || confirmation != self.confirmation(for: offer, comment: live, on: subject) { return refuse(.moderateComment, label, .denied(.needsConfirmation)) }
        guard !busy.contains(subject) else { return refuse(.moderateComment, label, .denied(.busy)) }
        busy.insert(subject); moderationCount += 1
        let entry = outbox.open(.moderateComment, subject: label)
        let ticket = generation
        let result = await send({ try await self.transport.moderate(offer, comment: live, on: subject) })
        guard ticket == generation else { return result }
        busy.remove(subject); outbox.settle(entry, result)
        if result == .confirmed { await loadComments(subject) }
        return result
    }

    private func send(_ operation: @escaping () async throws -> SocialWriteAnswer) async -> SocialOutboxEntry.Result {
        do {
            switch try await operation() {
            case .confirmed: return .confirmed
            case .rejected(let words): return .failed(words ?? String(localized: "YouTube Music didn’t accept this. Nothing was changed."), sent: true)
            case .indeterminate: return .unconfirmed
            }
        } catch let failure as CommentsFailure {
            switch failure {
            // The request never left.
            case .offline, .needsSignIn, .sessionEnded: return .failed(failure.message, sent: false)
            // The service answered and said wait: it left, and nothing was changed.
            case .rateLimited: return .failed(failure.message, sent: true)
            // The request left and its answer could not be read. Whether it was applied is not known: it is read back before anything is sent again.
            case .unreadable: return .unconfirmed
            }
        } catch {
            // An error nobody classified, after the request may have left: not known to be unsent, so it is not reported as unsent.
            return .unconfirmed
        }
    }
    private func refuse(_ action: SocialActionKind, _ subject: String, _ result: SocialOutboxEntry.Result) -> SocialOutboxEntry.Result {
        outbox.open(action, subject: subject, result: result)
        return result
    }

    // MARK: Invitations (through the playlist's edit session, the only writer)

    /// Asks for a collaboration invite link. Only the owner; one request; the result is the session's own.
    @discardableResult public func createInvite(for session: PlaylistEditSession, title: String) async -> SocialOutboxEntry.Result {
        let label = String(localized: "Invite link for the playlist “\(title)”")
        if case .denied(let denial) = SocialPolicy.permission(.createInvite, role: playlistRole(session)) { return refuse(.createInvite, label, .denied(denial)) }
        let entry = outbox.open(.createInvite, subject: label)
        let before = session.sentCount
        await session.createInviteLink()
        let result = Self.result(of: session.collaboration, sentBefore: before, sentNow: session.sentCount, link: true)
        outbox.settle(entry, result)
        return result
    }
    /// Closes the playlist to further contributions, after the confirmation that names it.
    @discardableResult public func stopContributions(for session: PlaylistEditSession, title: String, confirmation: PlaylistPrompt?) async -> SocialOutboxEntry.Result {
        let label = String(localized: "Stop contributions to the playlist “\(title)”")
        if case .denied(let denial) = SocialPolicy.permission(.stopContributions, role: playlistRole(session)) { return refuse(.stopContributions, label, .denied(denial)) }
        guard confirmation != nil, confirmation == session.stopContributionsPrompt else { return refuse(.stopContributions, label, .denied(.needsConfirmation)) }
        let entry = outbox.open(.stopContributions, subject: label)
        let before = session.sentCount
        await session.stopContributions(confirmation: confirmation)
        let result = Self.result(of: session.collaboration, sentBefore: before, sentNow: session.sentCount, link: false)
        outbox.settle(entry, result)
        return result
    }
    static func result(of collaboration: PlaylistCollaboration, sentBefore: Int, sentNow: Int, link: Bool) -> SocialOutboxEntry.Result {
        switch collaboration {
        case .invite(let url): return url == nil ? .failed(String(localized: "YouTube Music turned collaboration on but returned no usable invite link."), sent: true) : .confirmed
        case .closed: return .confirmed
        case .unconfirmed: return .unconfirmed
        case .pending: return .unconfirmed
        case .idle: return .failed(String(localized: "Nothing was sent."), sent: false)
        case .failed(let failure): return .failed(failure.message, sent: sentNow > sentBefore)
        }
    }

    // MARK: Ratings (the Library's ledger is the writer)

    /// A like or dislike the person pressed: the role is checked first (signed out is denied and `change` is never run), then `change` — the button's own
    /// call into the Library's ledger, the only writer, and the only place a change is submitted — makes the change, and the outbox records what became of it.
    @discardableResult public func rate(_ control: LibraryControl, change: @escaping @MainActor () async -> Void) async -> SocialOutboxEntry.Result {
        let label = String(localized: "Rating: \(control.title)")
        if case .denied(let denial) = SocialPolicy.permission(.rate, role: songRole()) { return refuse(.rate, label, .denied(denial)) }
        guard let ledger, case .rating(let video) = control.key else { return refuse(.rate, label, .denied(.notOffered(LibraryWriteFailure.notOffered.message))) }
        if ledger.isBusy(control.key) { return refuse(.rate, label, .denied(.busy)) }
        let entry = outbox.open(.rate, subject: label)
        await change()
        let result = ratingResult(videoID: video) ?? .failed(String(localized: "Nothing was sent."), sent: false)
        outbox.settle(entry, result)
        return result
    }
    /// What the ledger holds for a song's rating, as the outcome of the person's last rating action; nil when there is none.
    public func ratingResult(videoID: String) -> SocialOutboxEntry.Result? {
        guard let write = ledger?.write(.rating(videoID: videoID)) else { return nil }
        switch write.state {
        case .pending: return .pending
        case .confirmed: return .confirmed
        case .needsReconciliation: return .unconfirmed
        case .failed(let failure):
            if failure == .needsSignIn { return .denied(.needsSignIn) }
            return .failed(failure.message, sent: write.attempts > 0)
        }
    }

    public func accountChanged() {
        generation &+= 1; comments = [:]; busy = []; outbox.clear()
    }
}
