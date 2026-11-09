import Domain
import Foundation

public enum MusicSessionStatus: Sendable, Equatable {
    case signedOut, signingIn, verifying, signedIn(String), expired
    public var explanation: String {
        switch self {
        case .signedOut: "Not signed in. You sign in on Google’s own page; YTMuse never sees your password."
        case .signingIn: "Waiting for Google sign-in…"
        case .verifying: "Verifying your YouTube Music account…"
        case .signedIn(let name): "Signed in to YouTube Music as \(name). Press Play on a library playlist to listen."
        case .expired: "Session expired — sign in again. Your local data is kept."
        }
    }
}
public struct MusicAccountProof: Sendable, Equatable {
    public let identity: MusicAccountIdentity
    public let library: MusicLibraryPlaylists
    /// Bounded avatar bytes, if the menu published an allowed photo URL.
    public let avatar: Data?
}
public enum MusicProofState: Sendable, Equatable {
    case none, signedIn(MusicAccountProof), expired, unrecognised, failed(MusicSessionError)
}

/// Owns the web sign-in Music session for the local lifecycle. Registered as a
/// participant so switching, sign-out and removal fence every in-flight read.
/// Each sign-in attempt uses a fresh, transient WebKit store that is removed when
/// the attempt ends (success or not); the account's exact Keychain record is the
/// only durable copy of the session. Sign-out and removal touch no WebKit state.
public actor MusicSessionCoordinator: AccountLifecycleParticipant {
    public nonisolated let participantID = "music-web-session"
    private let vault: any SessionVault
    private let reader: any MusicSessionReading
    private let stores: any MusicWebsiteDataStores
    private let ledger: any MusicSignInLedger
    private var attempt: UUID?
    /// Background removals that keep retrying after the sheet has closed.
    private var removals: [UUID: Task<Void, Never>] = [:]
    /// Bounded backoff (~90 s in total) for removing an attempt store whose web
    /// content process is still releasing it. Unconfirmed IDs stay in the ledger.
    private let removalDelays: [Duration]
    private let pause: @Sendable (Duration) async -> Void
    private let presenter: (any MusicWebSignInPresenting)?
    private let clock: any WallClock
    private let region: String
    private weak var lifecycle: AccountLifecycle?
    private var epoch = UUID()
    private var signing: MusicSessionStatus?
    private var proofTask: (context: RequestContext, task: Task<MusicProofState, Never>)?
    /// Comments (C2): every continuation, sort and replies token the service issued, with where it was issued. See `comments(_:)`.
    private var issuedComments: [String: IssuedCommentsToken] = [:]
    private var issuedCommentsOrder: [String] = []
    /// The live comment list of each video (a monotonically increasing id; a new `open` or sort switch starts a new one).
    private var commentLists: [String: UInt64] = [:]
    /// Per video, the last list whose answer was accepted AND whose tokens were registered. A failed newer request falls back to this, never to a list still in flight.
    private var settledCommentLists: [String: UInt64] = [:]
    private var commentListOrder: [String] = []
    private var lastCommentList: UInt64 = 0
    static let maxIssuedCommentTokens = 2_048
    static let maxCommentVideos = 64
    public init(vault: any SessionVault, reader: any MusicSessionReading, stores: any MusicWebsiteDataStores = WebKitMusicDataStores(),
                ledger: any MusicSignInLedger, presenter: (any MusicWebSignInPresenting)?, clock: any WallClock = SystemWallClock(), region: String? = nil,
                removalDelays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30), .seconds(30)],
                pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.vault = vault; self.reader = reader; self.stores = stores; self.ledger = ledger; self.presenter = presenter; self.clock = clock
        self.removalDelays = removalDelays; self.pause = pause
        let candidate = region ?? Locale.current.region?.identifier ?? ""
        // Region is a local hint for the account context only; "ZZ" is CLDR's unknown region.
        self.region = candidate.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil ? candidate : "ZZ"
    }
    public func attach(to lifecycle: AccountLifecycle) { self.lifecycle = lifecycle }

    public func status() async -> MusicSessionStatus {
        if let signing { return signing }
        guard let snapshot = await lifecycle?.snapshot(), let active = snapshot.context.account,
              let identity = snapshot.directory.identities.first(where: { $0.id == active }) else { return .signedOut }
        switch identity.state {
        case .connected: return .signedIn(identity.account.displayName)
        case .expired: return .expired
        case .signedOut, .removalPending: return .signedOut
        }
    }

    /// Startup ownership: removes attempt stores left by an interrupted run (crash,
    /// quit mid-sign-in, unconfirmed removal). Only ledger IDs are touched, never
    /// an enumeration. Composition calls this after the first window is up.
    public func reconcileWebStores() async {
        guard let pending = try? await ledger.pending() else { return }
        for identifier in pending where identifier != attempt { scheduleRemoval(identifier) }
        await settleRemovals()
    }
    /// Ends an attempt's store: wipe its data now, then remove the directory in
    /// the background with bounded backoff that continues after the sheet has
    /// closed. The ledger entry is cleared only once removal is confirmed.
    private func endAttempt(_ identifier: UUID) async {
        _ = await stores.wipe(identifier)
        scheduleRemoval(identifier)
    }
    private func scheduleRemoval(_ identifier: UUID) {
        guard removals[identifier] == nil else { return }
        removals[identifier] = Task { [stores, ledger, removalDelays, pause] in
            if await stores.remove(identifier) { try? await ledger.remove(identifier) }
            else {
                for delay in removalDelays {
                    await pause(delay)
                    if Task.isCancelled { break }
                    if await stores.remove(identifier) { try? await ledger.remove(identifier); break }
                }
            }
            await self.removalFinished(identifier)
        }
    }
    private func removalFinished(_ identifier: UUID) { removals[identifier] = nil }
    /// Waits for every scheduled removal to confirm or exhaust its backoff.
    func settleRemovals() async {
        while let next = removals.values.first { await next.value }
    }
    /// App termination: one immediate removal attempt per ledgered store, bounded
    /// by `limit` so quit is never blocked. Anything unconfirmed stays ledgered
    /// and is removed at the next launch's reconciliation.
    public func drainRemovals(within limit: Duration) async {
        for task in removals.values { task.cancel() }
        guard let pending = try? await ledger.pending() else { return }
        let ids = pending.filter { $0 != attempt }
        guard !ids.isEmpty else { return }
        let work = Task { [stores, ledger] in
            for identifier in ids where !Task.isCancelled {
                if await stores.remove(identifier) { try? await ledger.remove(identifier) }
            }
        }
        // Return at whichever comes first, even if a removal never returns.
        let gate = FirstResume()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Task { await work.value; gate.fire(done) }
            Task { [pause] in await pause(limit); work.cancel(); gate.fire(done) }
        }
    }

    /// Runs Google's sign-in in a fresh attempt store, verifies the Music identity,
    /// then installs the account through the lifecycle with the Keychain record as
    /// its only credential. The attempt store is removed on every outcome.
    public func signIn(_ challenge: AuthenticationChallenge) async throws {
        guard let lifecycle, let presenter else { throw MusicSessionError.policy }
        guard signing == nil, attempt == nil else { throw LifecycleError.busy }
        guard await lifecycle.isAuthenticationCurrent(challenge) else { throw MusicSessionError.stale }
        let accountID = challenge.identity?.accountID ?? UUID()
        let store = UUID()
        // Protected from reconciliation before the first suspension (N1), and
        // recorded before WebKit can create anything on disk for this identifier.
        attempt = store
        // N2: earlier attempts whose removal was never confirmed are retried now.
        for earlier in (try? await ledger.pending()) ?? [] where earlier != store { scheduleRemoval(earlier) }
        do { try await ledger.add(store) } catch { attempt = nil; throw MusicSessionError.cleanupRequired }
        signing = .signingIn
        defer { signing = nil }
        do {
            var session = try await presenter.begin(store: store, account: accountID, now: { [clock] in clock.now() })
            // The presenter wiped the store and released the web view; nothing needs
            // the web store after this point.
            attempt = nil; await endAttempt(store)
            signing = .verifying
            await presenter.verifying()
            guard await lifecycle.isAuthenticationCurrent(challenge) else { throw MusicSessionError.stale }
            let menu = try await reader.accountMenu(session: session)
            session.merge(menu.rotation, now: clock.now())
            guard session.isUsable(at: clock.now()) else { throw MusicSessionError.signedOut }
            let identity = menu.value
            let snapshot = await lifecycle.snapshot()
            let context: AccountContext
            if let target = challenge.identity {
                guard target.channelID.rawValue == identity.serviceID else { throw MusicSessionError.differentAccount }
                context = target
            } else {
                guard !snapshot.directory.identities.contains(where: { $0.account.serviceIdentity.rawValue == identity.serviceID }) else {
                    throw MusicSessionError.duplicateAccount
                }
                context = try AccountContext(accountID: accountID, channelID: ID(identity.serviceID), region: region)
            }
            let account = try Account(id: context.accountID, serviceIdentity: ServiceID(identity.serviceID), context: context,
                                      displayName: identity.displayName, credential: nil)
            guard await lifecycle.isAuthenticationCurrent(challenge) else { throw MusicSessionError.stale }
            try await lifecycle.completeAuthentication(challenge, account: account, secret: session.encoded())
            // Handover: the newly installed/reconnected identity becomes the active
            // owner, restored paused at a newer generation; older work is fenced.
            try await lifecycle.switchIdentity(to: context)
            await presenter.finish(nil)
        } catch {
            if attempt == store { attempt = nil; await endAttempt(store) }
            await presenter.finish(Self.failure(error))
            if error is CancellationError || error as? MusicSessionError == .cancelled { throw CancellationError() }
            throw error
        }
    }
    static func failure(_ error: any Error) -> MusicSignInFailure? {
        if error is CancellationError { return nil }
        switch error as? MusicSessionError {
        case .cancelled, .stale: return nil
        case .network: return .network
        case .timedOut: return .timedOut
        case .signedOut, .notSignedIn: return .signedOut
        case .unrecognised, .oversized: return .unrecognised
        case .differentAccount: return .differentAccount
        case .keychain: return .generic
        case .duplicateAccount: return .duplicateAccount
        case .rateLimited: return .rateLimited
        case .server: return .server
        default: return .generic
        }
    }

    /// Read-only visible proof for the active identity: account menu then one
    /// `FEmusic_liked_playlists` page. Concurrent callers share one in-flight read.
    public func proof() async -> MusicProofState {
        guard let lifecycle else { return .none }
        let snapshot = await lifecycle.snapshot()
        guard !snapshot.busy, let account = snapshot.context.account,
              let identity = snapshot.directory.identities.first(where: { $0.id == account }) else { return .none }
        if identity.state == .expired { return .expired }
        guard identity.state == .connected else { return .none }
        let context = snapshot.context
        if let proofTask, proofTask.context == context { return await proofTask.task.value }
        let task = Task { await self.readProof(context) }
        proofTask = (context, task)
        let value = await task.value
        if proofTask?.context == context { proofTask = nil }
        return value
    }
    private func readProof(_ context: RequestContext) async -> MusicProofState {
        do {
            let identity = try await signed(context) { try await $0.accountMenu(session: $1) }
            let library = try await signed(context) { try await $0.likedPlaylists(session: $1) }
            var avatar: Data?
            if let url = identity.photoURL { avatar = try? await reader.avatar(url) }
            try await fence(context)
            return .signedIn(.init(identity: identity, library: library, avatar: avatar))
        } catch let error as MusicSessionError {
            switch error {
            case .signedOut, .notSignedIn:
                // Never an empty library: the service ended the session. Local data is kept.
                guard (try? await fence(context)) != nil else { return .none }
                try? await lifecycle?.expire(context: context)
                return .expired
            case .unrecognised, .oversized: return .unrecognised
            case .stale, .cancelled: return .none
            default: return .failed(error)
            }
        } catch { return .none }
    }
    /// One Music `search` for the active account scope: signed when a connected account is
    /// active, otherwise the anonymous public request. The scope is captured first and the
    /// answer is dropped (`stale`) if the account changed while it was in flight, so a
    /// reply can never be shown under a different account. A service-ended session expires
    /// the identity (like the library read) and the anonymous answer is returned, flagged.
    public func search(query: String) async throws -> MusicSearchReply {
        let reply = try await scoped(signed: { try await $0.search(query: query, session: $1) }, anonymous: { try await $0.search(query: query, session: nil).value })
        return MusicSearchReply(response: reply.value, mode: reply.mode, accountGeneration: reply.accountGeneration, sessionExpired: reply.sessionExpired)
    }
    /// One Music `browse` page (Home is personalised when signed in) under the same account-scope rules as `search`.
    public func browse(id: String, params: String? = nil) async throws -> MusicBrowseReply<MusicBrowsePage> {
        try await scoped(signed: { try await $0.browse(id: id, params: params, session: $1) }, anonymous: { try await $0.browse(id: id, params: params, session: nil).value })
    }
    /// The next entries of a shelf or the next sections of a page, under the same account-scope rules.
    public func continuation(token: String) async throws -> MusicBrowseReply<MusicContinuationPage> {
        try await scoped(signed: { try await $0.continuation(token: token, session: $1) }, anonymous: { try await $0.continuation(token: token, session: nil).value })
    }
    /// A podcast episode page under the same account-scope rules as `browse`.
    public func episode(id: String) async throws -> MusicBrowseReply<MusicEpisodePage> {
        try await scoped(signed: { try await $0.episode(id: id, session: $1) }, anonymous: { try await $0.episode(id: id, session: nil).value })
    }
    /// A song's lyrics under the same account-scope rules: signed when a connected account is active (a signed answer may carry timing),
    /// anonymous otherwise. An answer for another scope is dropped (`stale`).
    /// Explicit tuner metadata read under the same credential rotation and account fences as browse.
    public func radioQueue(action: MusicRadioAction) async throws -> MusicBrowseReply<MusicRadioQueue> {
        try await scoped(signed: { try await $0.radioQueue(action: action, session: $1) }, anonymous: { try await $0.radioQueue(action: action, session: nil).value })
    }
    public func lyrics(videoID: String) async throws -> MusicBrowseReply<MusicLyricsResult> {
        try await scoped(signed: { try await $0.lyrics(videoID: videoID, session: $1) }, anonymous: { try await $0.lyrics(videoID: videoID, session: nil).value })
    }
    /// One comments read (open, page or replies) under the same account-scope rules as `lyrics`, and with every token bound to where it came from.
    ///
    /// The service's continuation tokens are opaque and the Newest response carries no video id, so a syntactically valid token proves nothing
    /// about which song, thread, list or account it belongs to. The coordinator therefore remembers each token it handed out (`open`'s pages, a
    /// page's next token, a sort option, a thread's replies token) with the video, the kind, the signed/anonymous mode, the account and its
    /// generation, and the id of the comment list it belongs to. A page or replies request is refused BEFORE anything is sent when its token:
    /// was never issued here, or belongs to another account or generation or the other mode, or (page and replies tokens) to a list that has since been replaced
    /// (`stale`); or names another video, is used as the wrong kind, or names another thread (`policy`). A new `open` or a sort switch starts a
    /// new list, so an answer still in flight for the replaced list is dropped (`stale`) and its tokens are never registered. A token issued to
    /// a signed session is never sent anonymously after that session ends, nor the other way round. A failed `open` or sort switch that nobody
    /// replaced restores the last SETTLED list (the last whose answer was accepted), never an older request still in flight. The registry is bounded (`maxIssuedCommentTokens`, `maxCommentVideos`).
    public func comments(_ request: MusicCommentsRequest) async throws -> MusicBrowseReply<MusicCommentsAnswer> {
        try request.validate()
        let video = request.videoID
        let tokenMode: MusicSearchReply.Mode?
        switch request {
        case .open: tokenMode = nil
        case .page(let token, _), .replies(let token, _, _): tokenMode = issuedComments[token]?.scope.mode
        }
        var admission: CommentsAdmission?
        let reply: MusicBrowseReply<MusicCommentsAnswer>
        do {
            reply = try await scoped(signed: { reader, session in
                guard tokenMode != .anonymous else { throw MusicSessionError.stale }
                return try await reader.comments(request, session: session)
            }, anonymous: { reader in
                // The signed session that issued this token has ended: the token is not transferable to an anonymous request.
                guard tokenMode != .signedIn else { throw MusicSessionError.signedOut }
                return try await reader.comments(request, session: nil).value
            }, admit: { context, mode in
                admission = try self.admitComments(request, context: context, mode: mode)
            })
            guard let lifecycle else { throw MusicSessionError.stale }
            let now = await lifecycle.snapshot().context
            // Checked and registered with no suspension in between: nothing can start a newer list inside this window.
            guard let admitted = admission, now.accountGeneration == reply.accountGeneration, commentLists[video] == admitted.list else { throw MusicSessionError.stale }
            registerCommentTokens(reply.value, video: video, list: admitted.list,
                                  scope: CommentsScope(account: now.account, generation: reply.accountGeneration, mode: reply.mode))
        } catch {
            if let admission, admission.began, commentLists[video] == admission.list { restoreCommentList(video, to: admission.previous) }
            throw error
        }
        return reply
    }
    private struct CommentsScope: Equatable { let account: AccountContext?; let generation: UInt64; let mode: MusicSearchReply.Mode }
    private enum CommentsTokenKind: Equatable { case sort, more, replies(parent: String) }
    private struct IssuedCommentsToken { let videoID: String; let kind: CommentsTokenKind; let scope: CommentsScope; let list: UInt64 }
    private struct CommentsAdmission { let list: UInt64; let began: Bool; let previous: UInt64? }

    /// Everything knowable locally, synchronously against the snapshot the request will run under. Throws before any transport.
    private func admitComments(_ request: MusicCommentsRequest, context: RequestContext, mode: MusicSearchReply.Mode) throws -> CommentsAdmission {
        let scope = CommentsScope(account: context.account, generation: context.accountGeneration, mode: mode)
        let video = request.videoID
        switch request {
        case .open:
            return beginCommentList(video)
        case .page(let token, _):
            let issued = try issuedComment(token, video: video, scope: scope)
            switch issued.kind {
            // A sort switch replaces the list, so it is allowed from any list of this video and scope (the latest request wins; an older one
            // still in flight is dropped when it returns). Every other token must belong to the list that is current now.
            case .sort: return beginCommentList(video)
            case .more:
                guard commentLists[video] == issued.list else { throw MusicSessionError.stale }
                return CommentsAdmission(list: issued.list, began: false, previous: nil)
            case .replies: throw MusicSessionError.policy
            }
        case .replies(let token, _, let parentID):
            let issued = try issuedComment(token, video: video, scope: scope)
            guard issued.kind == .replies(parent: parentID) else { throw MusicSessionError.policy }
            guard commentLists[video] == issued.list else { throw MusicSessionError.stale }
            return CommentsAdmission(list: issued.list, began: false, previous: nil)
        }
    }
    /// The token must have been issued here, for this video, under this account scope and mode.
    private func issuedComment(_ token: String, video: String, scope: CommentsScope) throws -> IssuedCommentsToken {
        guard let issued = issuedComments[token] else { throw MusicSessionError.stale }
        guard issued.videoID == video else { throw MusicSessionError.policy }
        guard issued.scope == scope else { throw MusicSessionError.stale }
        return issued
    }
    private func beginCommentList(_ video: String) -> CommentsAdmission {
        lastCommentList += 1
        // The fallback is the last settled list, not whatever request happens to be current: that one may itself still be in flight.
        let previous = settledCommentLists[video]
        // The most recently used video goes last, so a reopened one is never the first to be evicted.
        commentListOrder.removeAll { $0 == video }
        commentListOrder.append(video)
        commentLists[video] = lastCommentList
        while commentListOrder.count > Self.maxCommentVideos {
            let evicted = commentListOrder.removeFirst()
            commentLists.removeValue(forKey: evicted)
            settledCommentLists.removeValue(forKey: evicted)
            dropIssuedComments { $0.videoID == evicted }
        }
        return CommentsAdmission(list: lastCommentList, began: true, previous: previous)
    }
    private func restoreCommentList(_ video: String, to previous: UInt64?) {
        if let previous { commentLists[video] = previous }
        else { commentLists.removeValue(forKey: video); settledCommentLists.removeValue(forKey: video); commentListOrder.removeAll { $0 == video } }
    }
    private func dropIssuedComments(where drop: (IssuedCommentsToken) -> Bool) {
        issuedCommentsOrder.removeAll { key in
            guard let issued = issuedComments[key], drop(issued) else { return false }
            issuedComments.removeValue(forKey: key); return true
        }
    }
    private func registerCommentTokens(_ answer: MusicCommentsAnswer, video: String, list: UInt64, scope: CommentsScope) {
        // Tokens of a replaced list are dead: they would be refused anyway; dropping them keeps the registry small.
        dropIssuedComments { $0.videoID == video && $0.list != list }
        settledCommentLists[video] = list
        func put(_ token: String, _ kind: CommentsTokenKind) {
            if issuedComments.updateValue(IssuedCommentsToken(videoID: video, kind: kind, scope: scope, list: list), forKey: token) != nil {
                issuedCommentsOrder.removeAll { $0 == token }
            }
            issuedCommentsOrder.append(token)
        }
        func put(_ page: MusicCommentsPage) {
            for option in page.header?.sortOptions ?? [] { put(option.token, .sort) }
            if let next = page.nextToken { put(next, .more) }
            for thread in page.threads { if let token = thread.repliesToken { put(token, .replies(parent: thread.comment.id)) } }
        }
        switch answer {
        case .opened(_, let page): if let page { put(page) }
        case .page(let page): put(page)
        case .replies(let replies): if let next = replies.nextToken { put(next, .replies(parent: replies.parentID)) }
        }
        while issuedCommentsOrder.count > Self.maxIssuedCommentTokens { issuedComments.removeValue(forKey: issuedCommentsOrder.removeFirst()) }
    }
    /// One library or history page for the active account. Signed only: with no connected account the answer is `.notSignedIn`
    /// (never an anonymous page that could be mistaken for an empty library). Same account-scope fence as every other read.
    public func library(id: String) async throws -> MusicBrowseReply<MusicBrowsePage> {
        try await scopedSigned { try await $0.library(id: id, session: $1) }
    }
    /// The account's Recap, read once for the active account. Signed only: with no connected account the answer is `.notSignedIn` and nothing is
    /// sent. Held to the account scope it started in like every signed read (`stale` when the account changed meanwhile).
    public func recap() async throws -> MusicBrowseReply<MusicRecapReading> {
        try await scopedSigned { try await $0.recap(session: $1) }
    }
    public func libraryContinuation(token: String) async throws -> MusicBrowseReply<MusicContinuationPage> {
        try await scopedSigned { try await $0.libraryContinuation(token: token, session: $1) }
    }
    /// One write, only ever called from an explicit user action. The reply is held to the account scope the request started in: an
    /// answer for another scope is dropped (`stale`). A service-ended session expires the identity, like every signed read.
    public func write(_ request: MusicWriteRequest) async throws -> MusicWriteReply {
        // A change the service already answered is never reported as "not made" because the rotated cookies could not be saved after it.
        let reply = try await scopedSigned(keepingAnswerOnRotationFault: true) { try await $0.write(request, session: $1) }
        return MusicWriteReply(outcome: reply.value, accountGeneration: reply.accountGeneration)
    }
    /// One playlist change, only ever called from the playlist editing session for an explicit user action. Held to the account scope it
    /// started in, like `write`; an answer the service gave is kept even when saving the rotated cookies then fails.
    public func editPlaylist(_ request: MusicPlaylistRequest) async throws -> MusicPlaylistReply {
        let reply = try await scopedSigned(keepingAnswerOnRotationFault: true) { try await $0.editPlaylist(request, session: $1) }
        return MusicPlaylistReply(result: reply.value, accountGeneration: reply.accountGeneration)
    }
    private func scopedSigned<Value: Sendable & Equatable>(keepingAnswerOnRotationFault: Bool = false,
        _ operation: @Sendable (any MusicSessionReading, MusicCookieSession) async throws -> MusicSignedResult<Value>) async throws -> MusicBrowseReply<Value> {
        guard let lifecycle else { throw MusicSessionError.stale }
        let snapshot = await lifecycle.snapshot()
        let context = snapshot.context
        guard let account = context.account, let identity = snapshot.directory.identities.first(where: { $0.id == account }) else { throw MusicSessionError.notSignedIn }
        guard identity.state == .connected else { throw identity.state == .expired ? MusicSessionError.signedOut : MusicSessionError.notSignedIn }
        do {
            let value = try await signed(context, keepingAnswerOnRotationFault: keepingAnswerOnRotationFault, operation)
            try await fence(context)
            return MusicBrowseReply(value: value, mode: .signedIn, accountGeneration: context.accountGeneration)
        } catch MusicSessionError.signedOut {
            guard (try? await fence(context)) != nil else { throw MusicSessionError.stale }
            try? await lifecycle.expire(context: context)
            throw MusicSessionError.signedOut
        }
    }
    /// Signed when a connected account is active, otherwise anonymous. The scope is captured first and the answer
    /// is dropped (`stale`) if the account changed while it was in flight, so a reply can never be shown under a
    /// different account. A service-ended session expires the identity and the anonymous answer is returned, flagged.
    /// `admit` (comments only) runs right after the snapshot is read, synchronously and before any transport, with the very context and mode the
    /// request will run under; a throw there sends nothing.
    private func scoped<Value: Sendable & Equatable>(
        signed operation: @Sendable (any MusicSessionReading, MusicCookieSession) async throws -> MusicSignedResult<Value>,
        anonymous: @Sendable (any MusicSessionReading) async throws -> Value,
        admit: (RequestContext, MusicSearchReply.Mode) throws -> Void = { _, _ in }) async throws -> MusicBrowseReply<Value> {
        guard let lifecycle else { throw MusicSessionError.stale }
        let snapshot = await lifecycle.snapshot()
        let context = snapshot.context
        let generation = context.accountGeneration
        let identity = context.account.flatMap { account in snapshot.directory.identities.first(where: { $0.id == account }) }
        try admit(context, identity?.state == .connected ? .signedIn : .anonymous)
        if let identity, identity.state == .connected {
            do {
                let value = try await signed(context, operation)
                try await fence(context)
                return MusicBrowseReply(value: value, mode: .signedIn, accountGeneration: generation)
            } catch MusicSessionError.signedOut {
                guard (try? await fence(context)) != nil else { throw MusicSessionError.stale }
                try? await lifecycle.expire(context: context)
                // Expiry is itself a lifecycle transition: the anonymous answer belongs to the scope after it.
                let after = await lifecycle.snapshot().context
                let value = try await anonymous(reader)
                try await sameScope(after)
                return MusicBrowseReply(value: value, mode: .anonymous, accountGeneration: after.accountGeneration, sessionExpired: true)
            }
        }
        let value = try await anonymous(reader)
        try await sameScope(context)
        return MusicBrowseReply(value: value, mode: .anonymous, accountGeneration: generation, sessionExpired: identity?.state == .expired)
    }
    /// An anonymous answer has no account owner to fence, so it is held to the same
    /// account scope (and generation) the request started in.
    private func sameScope(_ context: RequestContext) async throws {
        try Task.checkCancellation()
        guard let lifecycle else { throw MusicSessionError.stale }
        let now = await lifecycle.snapshot().context
        guard now.account == context.account, now.accountGeneration == context.accountGeneration else { throw MusicSessionError.stale }
    }
    private func fence(_ context: RequestContext) async throws {
        try Task.checkCancellation()
        guard let lifecycle, await lifecycle.accepts(context) else { throw MusicSessionError.stale }
    }
    /// Reads the exact record for this generation, signs one request, and writes
    /// Google's cookie rotation back only if the same owner is still current.
    private func signed<Value: Sendable>(_ context: RequestContext, keepingAnswerOnRotationFault: Bool = false,
        _ operation: @Sendable (any MusicSessionReading, MusicCookieSession) async throws -> MusicSignedResult<Value>) async throws -> Value {
        let operationEpoch = epoch
        guard let lifecycle, let account = context.account else { throw MusicSessionError.stale }
        try await fence(context)
        guard case .success(let stored) = await lifecycle.reference(for: account, context: context).outcome,
              let reference = stored else { throw MusicSessionError.signedOut }
        let bytes: Data
        do { bytes = try await vault.read(reference, context: context) }
        // A local Keychain fault (locked, ACL after rebuild, unreadable record) is
        // not a service expiry and must never rewrite lifecycle state.
        catch { throw (error as? DomainError) == .staleContext ? MusicSessionError.stale : MusicSessionError.keychain }
        let session: MusicCookieSession
        do { session = try MusicCookieSession.decode(bytes, accountID: account.accountID) } catch { throw MusicSessionError.keychain }
        var current = session
        guard current.isUsable(at: clock.now()) else { throw MusicSessionError.signedOut }
        let result = try await operation(reader, current)
        guard operationEpoch == epoch else { throw MusicSessionError.stale }
        try await fence(context)
        if current.merge(result.rotation, now: clock.now()) {
            do { try await vault.replace(reference, with: current.encoded(), context: context) }
            catch {
                // The next signed request re-reads the stored record and Google rotates again; the answer in hand is kept.
                if keepingAnswerOnRotationFault, (error as? DomainError) != .staleContext { return result.value }
                throw (error as? DomainError) == .staleContext ? MusicSessionError.stale : MusicSessionError.keychain
            }
        }
        return result.value
    }

    public func detach(previous: RequestContext, barrier: RequestContext) async throws {
        epoch = UUID()
        proofTask?.task.cancel(); proofTask = nil
    }
    public func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {}
    /// The session lives only in the Keychain record, which the lifecycle's own
    /// `deleteAll` removes; no web store outlives its sign-in attempt.
    public func removeLocal(_ account: AccountContext, context: RequestContext) async throws {}
}

/// Resumes a continuation exactly once, from whichever racer arrives first.
private final class FirstResume: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire(_ continuation: CheckedContinuation<Void, Never>) {
        let first = lock.withLock { () -> Bool in if fired { return false }; fired = true; return true }
        if first { continuation.resume() }
    }
}
