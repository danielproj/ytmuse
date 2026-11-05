import AccountSession
import Foundation
import Observation

/// What the replies of one thread show: what has been read, whether more can be, and a request in flight or failed.
public struct ThreadReplies: Equatable, Sendable {
    public var replies: [SocialComment] = []
    public var next: CommentsToken?
    /// Reply pages read for this thread (bounded by `SocialSurface.maximumReplyPages`).
    public var pages = 0
    public var loading = false
    public var failure: CommentsFailure?
    public init() {}
}
/// The comments of one song as the source returned them, and what is in flight or failed on them. Nothing here is computed or invented: the order,
/// the counts and the sort titles are the source's own.
public struct CommentsList: Equatable, Sendable {
    public var header: CommentsHeader?
    public var threads: [CommentThread]
    public var next: CommentsToken?
    /// Pages read for the CURRENT sort order (the first page counts; bounded by `SocialSurface.maximumCommentPages`).
    public var pages: Int
    public var canPost: Bool
    public var loadingMore = false
    public var moreFailure: CommentsFailure?
    /// A sort switch is in flight: the list below is the old order and nothing more is read from it.
    public var sorting = false
    public var sortFailure: CommentsFailure?
    /// The list's continuations were replaced (the service's own tokens are no longer valid for this list): only Show comments again can go on.
    public var needsReopen = false
    public var replies: [String: ThreadReplies] = [:]
    public var comments: [SocialComment] { threads.map(\.comment) }
    init(first page: CommentsPage) {
        header = page.header; threads = SocialSurface.unique(threads: page.threads); next = page.next; pages = 1; canPost = page.canPost
    }
    /// A comment of this list by id: a top-level comment, an inline reply, or a reply read since.
    public func comment(_ id: String) -> SocialComment? {
        for thread in threads {
            if thread.comment.id == id { return thread.comment }
            if let found = thread.inlineReplies.first(where: { $0.id == id }) { return found }
        }
        for entry in replies.values { if let found = entry.replies.first(where: { $0.id == id }) { return found } }
        return nil
    }
    /// The replies to show under a thread: those the source published inline, then those read since, each once.
    public func shownReplies(of thread: CommentThread) -> [SocialComment] {
        SocialSurface.unique(thread.inlineReplies + (replies[thread.id]?.replies ?? []))
    }
    public var reachedPageBound: Bool { next != nil && pages >= SocialSurface.maximumCommentPages }
    public func reachedReplyBound(_ thread: CommentThread) -> Bool {
        guard let entry = replies[thread.id] else { return false }
        return entry.next != nil && entry.pages >= SocialSurface.maximumReplyPages
    }
}

public enum CommentsState: Equatable, Sendable {
    /// There is no route to read: isolated automation, or a session with no connection.
    case unresolved(String)
    /// Nothing has been asked yet. Comments are read only when the person asks.
    case idle
    case loading
    case loaded(CommentsList)
    /// The song has no comments tab (or this kind of item has no comments route). Never "no comments yet".
    case notOffered
    /// The comments tab printed a message of its own, carried verbatim.
    case serviceMessage(String)
    case failed(CommentsFailure)
}

/// MEDIA10: comments, ratings, collaboration invitations and moderation, for the account, where the source supplies them.
///
/// Rules this type keeps:
/// - comments are READ, signed in or out, and only when the person asks: Show comments, a sort order, More comments, a thread's replies. Each is one
///   explicit call (open at most two requests, the others one), bounded (`maximumCommentPages` per order, `maximumReplyPages` per thread), fenced by
///   the account and by a per-subject counter, and never repeated, prefetched or started by a view appearing. Posting and moderation are refused, in
///   the app's own words and with no transport call, while the transport has no verified write route (`writesUnresolved`);/// - every write is one explicit call for one item (a post, one moderation, one invite request). Nothing loops, polls, retries by itself
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
    /// One counter per subject, advanced by every open and sort switch: an answer for an earlier value belongs to a replaced list and is dropped.
    @ObservationIgnored private var epochs: [SocialSubject: UInt64] = [:]
    /// Subjects with a post or moderation in flight (one at a time per subject).
    public private(set) var busy: Set<SocialSubject> = []
    @ObservationIgnored private let transport: any CommentsTransport
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private let ledger: LibraryWriteLedger?
    @ObservationIgnored private var generation: UInt64 = 0
    /// The app's own bound on one comment, not the source's.
    public static let maximumCommentCharacters = 10_000
    /// The app's own bounds on reading, stated where they are reached: pages of comments per sort order, and pages of replies per thread.
    nonisolated public static let maximumCommentPages = 10
    nonisolated public static let maximumReplyPages = 5
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
    /// Posting and moderation are offered only where the transport has a verified route to write. While this is non-nil nothing is composed and
    /// every post and moderation is refused here, before any transport call.
    public var writesUnresolved: String? { transport.unresolved ?? transport.writesUnresolved }
    public func state(_ subject: SocialSubject) -> CommentsState {
        if let reason = transport.unresolved { return .unresolved(reason) }
        // A playlist has no comments route that was ever observed: it is not offered, and nothing is asked.
        guard subject.kind == .song else { return .notOffered }
        return comments[subject] ?? .idle
    }
    public func list(_ subject: SocialSubject) -> CommentsList? { if case .loaded(let list)? = comments[subject] { list } else { nil } }

    // MARK: Reading
    //
    // Every read is one explicit call from a button: Show comments (the transport's open: at most two requests), a sort option, More comments, and a
    // thread's replies (one request each). Nothing reads when a model or a view is made or appears, and nothing repeats, prefetches or retries by itself.

    /// Show comments, and the explicit Retry or "show again" after a failure. Reading needs no account.
    public func loadComments(_ subject: SocialSubject) async {
        guard subject.kind == .song, transport.unresolved == nil else { return }
        switch comments[subject] {
        case .loading?: return
        case .loaded(let list)? where list.sorting: return
        default: break
        }
        guard SocialPolicy.permission(.readComments, role: songRole()).isAllowed else { comments[subject] = .failed(.needsSignIn); return }
        let ticket = generation
        let epoch = advance(subject)
        comments[subject] = .loading; readCount += 1
        do {
            let opening = try await transport.open(subject)
            guard current(ticket, epoch, subject) else { return }
            switch opening {
            case .page(let page): comments[subject] = .loaded(CommentsList(first: page))
            case .notOffered: comments[subject] = .notOffered
            case .serviceMessage(let message): comments[subject] = .serviceMessage(message)
            }
        } catch {
            guard current(ticket, epoch, subject) else { return }
            comments[subject] = .failed(Self.failure(error))
        }
    }

    /// Switches to one of the sort orders the source printed. One request. Everything read under the old order is dropped when the answer comes.
    public func selectSort(_ option: CommentsSortOption, for subject: SocialSubject) async {
        guard subject.kind == .song, transport.unresolved == nil, case .loaded(var list)? = comments[subject], !list.sorting, !list.needsReopen,
              // Only an option the CURRENT header printed, and not the one already selected.
              let printed = list.header?.sorts.first(where: { $0.token == option.token }), !printed.isSelected else { return }
        let ticket = generation
        // The old order's in-flight more/replies answers are for a list that is about to be replaced.
        let epoch = advance(subject)
        list.sorting = true; list.sortFailure = nil; list.loadingMore = false; list.moreFailure = nil
        list.replies = list.replies.mapValues { var entry = $0; entry.loading = false; return entry }
        comments[subject] = .loaded(list); readCount += 1
        do {
            let page = try await transport.page(printed.token, on: subject)
            guard current(ticket, epoch, subject) else { return }
            // A sort answer carries the new header (the order now selected). Without one it is not an answer this list can use, and the answer
            // already replaced the old order's tokens, so the list can only go on by being shown again.
            guard page.header != nil else {
                update(subject) { $0.sorting = false; $0.sortFailure = .unreadable; $0.needsReopen = true }
                return
            }
            comments[subject] = .loaded(CommentsList(first: page))
        } catch {
            guard current(ticket, epoch, subject) else { return }
            let failure = Self.failure(error)
            update(subject) {
                $0.sorting = false; $0.sortFailure = failure
                // A request that failed leaves the old order's continuations valid; one that found them replaced does not.
                if failure == .outOfDate { $0.needsReopen = true }
            }
        }
    }

    /// The next page of the current order. One request; nothing past `maximumCommentPages` is read.
    public func loadMoreComments(_ subject: SocialSubject) async {
        guard subject.kind == .song, transport.unresolved == nil, case .loaded(let list)? = comments[subject], !list.sorting, !list.needsReopen,
              !list.loadingMore, list.pages < Self.maximumCommentPages, let token = list.next else { return }
        let ticket = generation, epoch = epochs[subject] ?? 0
        update(subject) { $0.loadingMore = true; $0.moreFailure = nil }
        readCount += 1
        do {
            let page = try await transport.page(token, on: subject)
            guard current(ticket, epoch, subject) else { return }
            update(subject) {
                let known = Set($0.threads.map(\.id))
                $0.threads += Self.unique(threads: page.threads).filter { !known.contains($0.id) }
                $0.next = page.next; $0.pages += 1; $0.loadingMore = false
            }
        } catch {
            guard current(ticket, epoch, subject) else { return }
            let failure = Self.failure(error)
            update(subject) { $0.loadingMore = false; $0.moreFailure = failure; if failure == .outOfDate { $0.needsReopen = true } }
        }
    }

    /// The replies of one thread, or their next page. One request; at most `maximumReplyPages` pages per thread.
    public func loadReplies(_ subject: SocialSubject, of threadID: String) async {
        guard subject.kind == .song, transport.unresolved == nil, case .loaded(let list)? = comments[subject], !list.sorting, !list.needsReopen,
              let thread = list.threads.first(where: { $0.id == threadID }) else { return }
        let entry = list.replies[threadID] ?? ThreadReplies()
        guard !entry.loading, entry.pages < Self.maximumReplyPages, let token = entry.pages == 0 ? thread.repliesToken : entry.next else { return }
        let ticket = generation, epoch = epochs[subject] ?? 0
        update(subject) { var changed = $0.replies[threadID] ?? ThreadReplies(); changed.loading = true; changed.failure = nil; $0.replies[threadID] = changed }
        readCount += 1
        do {
            let answer = try await transport.replies(token, of: thread.comment, on: subject)
            guard current(ticket, epoch, subject) else { return }
            // The answer must be for this thread.
            guard answer.parentID == threadID else { throw CommentsFailure.unreadable }
            update(subject) {
                var changed = $0.replies[threadID] ?? ThreadReplies()
                changed.replies = Self.unique(changed.replies + answer.replies); changed.next = answer.next; changed.pages += 1; changed.loading = false
                $0.replies[threadID] = changed
            }
        } catch {
            guard current(ticket, epoch, subject) else { return }
            let failure = Self.failure(error)
            update(subject) {
                var changed = $0.replies[threadID] ?? ThreadReplies(); changed.loading = false; changed.failure = failure
                $0.replies[threadID] = changed
                if failure == .outOfDate { $0.needsReopen = true }
            }
        }
    }

    private func advance(_ subject: SocialSubject) -> UInt64 { let next = (epochs[subject] ?? 0) &+ 1; epochs[subject] = next; return next }
    /// An answer is used only if the account is the one that asked and no open or sort switch has replaced its list since.
    private func current(_ ticket: UInt64, _ epoch: UInt64, _ subject: SocialSubject) -> Bool { ticket == generation && epochs[subject] == epoch }
    private func update(_ subject: SocialSubject, _ change: (inout CommentsList) -> Void) {
        guard case .loaded(var list)? = comments[subject] else { return }
        change(&list); comments[subject] = .loaded(list)
    }
    static func failure(_ error: Error) -> CommentsFailure { (error as? CommentsFailure) ?? .unreadable }
    nonisolated static func unique(_ comments: [SocialComment]) -> [SocialComment] {
        var seen = Set<String>()
        return comments.filter { seen.insert($0.id).inserted }
    }
    nonisolated static func unique(threads: [CommentThread]) -> [CommentThread] {
        var seen = Set<String>()
        return threads.filter { seen.insert($0.id).inserted }
    }

    // MARK: Writing

    /// Posts one comment the person wrote, from a press on Post. Only where the source offered posting on this subject.
    @discardableResult public func post(_ text: String, on subject: SocialSubject) async -> SocialOutboxEntry.Result {
        let label = String(localized: "Comment on \(subject.description)")
        let role = songRole()
        // No verified write route (the app's own state, not the service's answer): refused here, with no transport call, whatever the page says.
        if let reason = writesUnresolved { return refuse(.postComment, label, .sourceUnresolved(reason)) }
        if case .denied(let denial) = SocialPolicy.permission(.postComment, role: role) { return refuse(.postComment, label, .denied(denial)) }
        guard let page = list(subject), page.canPost else {
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
        guard let live = list(subject)?.comment(comment.id), live.moderation.contains(offer) else { return nil }
        return ModerationConfirmation(subject: subject, offer: offer, commentID: live.id, author: live.author, text: live.text)
    }

    /// One moderation the source offered on this comment. A destructive one needs the `confirmation` the question named (compared with what the
    /// page shows now, so an answer to a question about another comment, or about a comment that has changed, is no answer).
    @discardableResult public func moderate(_ offer: ModerationOffer, comment: SocialComment, on subject: SocialSubject, confirmation: ModerationConfirmation? = nil) async -> SocialOutboxEntry.Result {
        let label = String(localized: "\(offer.title): comment by \(comment.author)")
        if let reason = writesUnresolved { return refuse(.moderateComment, label, .sourceUnresolved(reason)) }
        if case .denied(let denial) = SocialPolicy.permission(.moderateComment, role: songRole()) { return refuse(.moderateComment, label, .denied(denial)) }
        // Only an action the source offered on this very comment, as the page now shows it.
        guard let live = list(subject)?.comment(comment.id), live.moderation.contains(offer) else {
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
            case .offline, .needsSignIn, .sessionEnded, .outOfDate, .writesUnavailable: return .failed(failure.message, sent: false)
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
        // The per-subject counters are kept (they only ever grow), so a read from before the change can never match one made after it.
        generation &+= 1; comments = [:]; busy = []; outbox.clear()
    }
}
