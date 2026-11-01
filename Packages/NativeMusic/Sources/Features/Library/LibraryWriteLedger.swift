import AccountSession
import Foundation
import Observation

/// What a library change acts on. One key is one thing the person can change (a song's rating, an album's place in the library…).
public enum LibraryWriteKey: Hashable, Sendable {
    case rating(videoID: String)
    case songSaved(videoID: String)
    case playlistSaved(playlistID: String)
    case following(channelID: String)
    /// A podcast episode's place in "Episodes for Later" (W18).
    case episodeLater(videoID: String)
}
/// The value a key is set to.
public enum LibraryWriteValue: Equatable, Sendable {
    case rating(MusicLikeStatus)
    case saved(Bool)
    case following(Bool)
}
public enum LibraryWriteFailure: Equatable, Sendable {
    /// The service answered and refused. Nothing changed.
    case refused
    case rateLimited
    case unavailable
    /// The request never left (no connection). Nothing changed and nothing is queued.
    case offline
    case needsSignIn
    case sessionEnded
    /// This item published no way to make this change.
    case notOffered
    /// A check against the service found the change was not applied.
    case notApplied
    public var message: String {
        switch self {
        case .refused: String(localized: "YouTube Music didn’t accept this change. Nothing was changed.")
        case .rateLimited: String(localized: "YouTube Music is asking for a pause. Nothing was changed.")
        case .unavailable: String(localized: "YouTube Music couldn’t make this change right now. Nothing was changed.")
        case .offline: String(localized: "You’re offline, so nothing was changed. It isn’t queued.")
        case .needsSignIn: String(localized: "Sign in to YouTube Music to change your library.")
        case .sessionEnded: String(localized: "Your session ended, so nothing was changed. Sign in again.")
        case .notOffered: String(localized: "YouTube Music didn’t offer this change for this item.")
        case .notApplied: String(localized: "YouTube Music didn’t apply this change. It was rolled back.")
        }
    }
}
/// SYNC04's four states. `needsReconciliation` means the request left and its outcome is unknown: the service is read before
/// anything is sent again.
public enum LibraryWriteState: Equatable, Sendable {
    case pending
    case confirmed
    case failed(LibraryWriteFailure)
    case needsReconciliation
}
public struct LibraryWrite: Equatable, Sendable, Identifiable {
    public let key: LibraryWriteKey
    /// Kept across retries and checks: one person's action is one operation.
    public let operationID: UUID
    public let desired: LibraryWriteValue
    /// What was shown before the change; shown again if the change fails.
    public let previous: LibraryWriteValue?
    public let request: MusicWriteRequest
    public internal(set) var state: LibraryWriteState
    public internal(set) var attempts: Int
    /// A check was tried and the service could not tell: repeating the change is then allowed, because it sets the same state again
    /// and cannot duplicate anything.
    public internal(set) var checkedUnreadable = false
    public var id: LibraryWriteKey { key }
    /// The value to show: the change while it is pending, confirmed or unconfirmed; the old value once it failed.
    public var displayed: LibraryWriteValue? {
        if case .failed = state { return previous }
        return desired
    }
}
/// One thing the person asked for, ready to send. Built from a control the service published for the entry.
public struct LibraryIntent: Sendable, Equatable {
    public let key: LibraryWriteKey
    public let desired: LibraryWriteValue
    public let previous: LibraryWriteValue?
    public let request: MusicWriteRequest

    public static func rate(_ like: MusicItemControls.Like, to status: MusicLikeStatus) -> LibraryIntent {
        LibraryIntent(key: .rating(videoID: like.videoID), desired: .rating(status), previous: .rating(like.status),
                      request: .rate(videoID: like.videoID, status: status))
    }
    /// Save to or remove from the library. nil when the entry did not publish what this direction needs.
    public static func setSaved(_ save: MusicItemControls.Save, to saved: Bool, was: Bool?) -> LibraryIntent {
        LibraryIntent(key: .playlistSaved(playlistID: save.playlistID), desired: .saved(saved), previous: was.map { .saved($0) },
                      request: .savePlaylist(playlistID: save.playlistID, saved: saved))
    }
    public static func setSongSaved(_ library: MusicItemControls.SongLibrary, videoID: String, to saved: Bool) -> LibraryIntent? {
        guard let token = saved ? library.addToken : library.removeToken else { return nil }
        return LibraryIntent(key: .songSaved(videoID: videoID), desired: .saved(saved), previous: .saved(library.isSaved), request: .songLibrary(feedbackToken: token))
    }
    /// Add one episode to "Episodes for Later" or remove that one episode. The caller offers a direction only when the episode page published it.
    public static func setEpisodeLater(videoID: String, to saved: Bool, was: Bool?) -> LibraryIntent {
        LibraryIntent(key: .episodeLater(videoID: videoID), desired: .saved(saved), previous: was.map { .saved($0) }, request: .episodeLater(videoID: videoID, saved: saved))
    }
    public static func setFollowing(_ follow: MusicItemControls.Follow, to following: Bool, was: Bool?) -> LibraryIntent {
        LibraryIntent(key: .following(channelID: follow.channelID), desired: .following(following), previous: was.map { .following($0) },
                      request: .follow(channelID: follow.channelID, params: follow.params, following: following))
    }
}

/// The shared command layer for library changes (like, save, follow). Every surface that shows one of these controls submits
/// through this type, so a change is optimistic in one place, has one operation id, one state and one rollback.
///
/// Rules this type keeps:
/// - a change is sent only from `submit`, `retry` or `check`, which the interface calls for an explicit action on a single item.
///   Nothing here loops over items, runs in the background or replays a stored request;
/// - the value shown changes at once (optimistic) and returns to the old one if the change fails;
/// - success needs the service's positive answer. A provider error inside an HTTP 200 is a failure (`MusicWriteOutcome.rejected`);
///   an answer that is neither is `needsReconciliation`, never success;
/// - when the outcome is unknown, `check` reads the service before anything is sent again (SYNC05). A retry of a change the service
///   refused is a new attempt of the same operation;
/// - nothing is queued while offline: a change that did not leave says so and changes nothing;
/// - state is per account scope; a switch drops it all, and an answer for another scope is discarded.
@MainActor @Observable public final class LibraryWriteLedger {
    public typealias Writer = @Sendable (MusicWriteRequest) async throws -> MusicWriteReply
    /// Reads the service's current value for a key (a page read), or nil when it cannot tell.
    public typealias Reader = @Sendable (LibraryWriteKey) async -> LibraryWriteValue?

    public private(set) var writes: [LibraryWriteKey: LibraryWrite] = [:]
    @ObservationIgnored private let writer: Writer
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private var generation: UInt64 = 0
    /// Requests handed to the writer since this ledger was made (a measurement for tests: one action is one request).
    @ObservationIgnored public private(set) var sentCount = 0

    public init(writer: @escaping Writer, reader: @escaping Reader = { _ in nil }, accountScope: @escaping @MainActor () -> String = { "" },
                signedIn: @escaping @MainActor () -> SearchPlayback = { .available }) {
        self.writer = writer; self.reader = reader; self.accountScope = accountScope; self.signedIn = signedIn
    }

    public func write(_ key: LibraryWriteKey) -> LibraryWrite? { writes[key] }
    public var pendingCount: Int { writes.values.filter { $0.state == .pending }.count }
    public func isBusy(_ key: LibraryWriteKey) -> Bool { writes[key]?.state == .pending }

    // MARK: Display (the optimistic overlay)

    public func rating(_ videoID: String, service: MusicLikeStatus) -> MusicLikeStatus {
        if case .rating(let status)? = writes[.rating(videoID: videoID)]?.displayed { return status }
        return service
    }
    public func isSaved(_ key: LibraryWriteKey, service: Bool) -> Bool {
        if case .saved(let value)? = writes[key]?.displayed { return value }
        return service
    }
    public func isFollowing(_ channelID: String, service: Bool) -> Bool {
        if case .following(let value)? = writes[.following(channelID: channelID)]?.displayed { return value }
        return service
    }

    // MARK: Actions (each is one explicit request for one item)

    /// Applies the change on screen at once and sends it. A second change to a key that is still pending is refused.
    public func submit(_ intent: LibraryIntent) async {
        guard writes[intent.key]?.state != .pending else { return }
        switch signedIn() {
        case .needsSignIn: record(intent, failure: .needsSignIn); return
        case .sessionExpired: record(intent, failure: .sessionEnded); return
        case .available: break
        }
        guard intent.request.isWellFormed else { record(intent, failure: .notOffered); return }
        // A new action is a new operation; only `retry` and `check` carry the id of the action they continue.
        writes[intent.key] = LibraryWrite(key: intent.key, operationID: UUID(), desired: intent.desired, previous: intent.previous, request: intent.request,
                                          state: .pending, attempts: 1)
        await send(intent.key)
    }
    /// Sends the same change again after the service refused it (or it never left). After an unknown outcome only once a check has
    /// been tried and could not read the state (SYNC05: the service is read first).
    public func retry(_ key: LibraryWriteKey) async {
        guard var write = writes[key] else { return }
        switch write.state {
        case .failed: break
        case .needsReconciliation where write.checkedUnreadable: break
        default: return
        }
        write.state = .pending; write.attempts += 1; writes[key] = write
        await send(key)
    }
    /// After an unknown outcome: read the service. Equal to the change → confirmed; different → rolled back (retry offered);
    /// unreadable → still unknown.
    public func check(_ key: LibraryWriteKey) async {
        guard let write = writes[key], write.state == .needsReconciliation else { return }
        let ticket = generation, scope = accountScope()
        let observed = await reader(key)
        guard ticket == generation, accountScope() == scope, var current = writes[key], current.state == .needsReconciliation else { return }
        guard let observed else { current.checkedUnreadable = true; writes[key] = current; return }
        current.state = observed == current.desired ? .confirmed : .failed(.notApplied)
        writes[key] = current
    }
    /// Accepts a failure: the old value stays, the message goes.
    public func dismiss(_ key: LibraryWriteKey) {
        guard let state = writes[key]?.state else { return }
        if case .failed = state { writes[key] = nil }
    }
    /// Gives up on a change whose outcome stayed unknown: the old value is shown again and the change is not sent again.
    public func dismissUnconfirmed(_ key: LibraryWriteKey) {
        guard writes[key]?.state == .needsReconciliation else { return }
        writes[key] = nil
    }
    /// A page read showed the service's current value for a key: it replaces any settled change; a pending one is left alone.
    public func observed(_ key: LibraryWriteKey, _ value: LibraryWriteValue) {
        guard let write = writes[key] else { return }
        switch write.state {
        case .pending: return
        case .confirmed: writes[key] = nil
        case .needsReconciliation: var settled = write; settled.state = value == write.desired ? .confirmed : .failed(.notApplied); writes[key] = settled
        case .failed: writes[key] = nil
        }
    }
    public func accountChanged() { generation &+= 1; writes = [:] }

    // MARK: Sending

    private func record(_ intent: LibraryIntent, failure: LibraryWriteFailure) {
        writes[intent.key] = LibraryWrite(key: intent.key, operationID: UUID(), desired: intent.desired, previous: intent.previous, request: intent.request,
                                          state: .failed(failure), attempts: 0)
    }
    private func send(_ key: LibraryWriteKey) async {
        guard let write = writes[key] else { return }
        let ticket = generation, scope = accountScope()
        sentCount += 1
        let state: LibraryWriteState
        do {
            let reply = try await writer(write.request)
            switch reply.outcome {
            case .confirmed: state = .confirmed
            case .rejected(.service): state = .failed(.refused)
            case .rejected(.rateLimited): state = .failed(.rateLimited)
            case .rejected(.unavailable): state = .failed(.unavailable)
            case .indeterminate: state = .needsReconciliation
            }
        } catch let error as MusicSessionError {
            switch error {
            case .stale, .cancelled: return      // the account changed or the action was abandoned; the scope check below drops it
            case .signedOut: state = .failed(.sessionEnded)
            case .notSignedIn: state = .failed(.needsSignIn)
            case .network, .timedOut: state = .failed(.offline)
            case .rateLimited: state = .failed(.rateLimited)
            case .policy: state = .failed(.notOffered)
            default: state = .failed(.unavailable)
            }
        } catch is CancellationError { return } catch { state = .failed(.unavailable) }
        guard ticket == generation, accountScope() == scope, var current = writes[key], current.operationID == write.operationID else { return }
        current.state = state
        writes[key] = current
    }
}

public extension LibraryWriteLedger {
    /// A read showed what the service currently says about an entry: settled changes give way to it.
    func observe(item: MusicCatalogItem) {
        guard let controls = item.controls else { return }
        if let like = controls.like { observed(.rating(videoID: like.videoID), .rating(like.status)) }
        if let song = controls.songLibrary, let video = item.videoID { observed(.songSaved(videoID: video), .saved(song.isSaved)) }
        observe(controls: controls)
    }
    func observe(controls: MusicItemControls) {
        if let save = controls.save, let saved = save.isSaved, !save.playlistID.isEmpty { observed(.playlistSaved(playlistID: save.playlistID), .saved(saved)) }
        if let follow = controls.follow, let following = follow.isFollowing { observed(.following(channelID: follow.channelID), .following(following)) }
    }
}
