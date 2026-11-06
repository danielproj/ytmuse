import AppKit
import Domain
import Foundation
import Observation

public struct WebMusicRadioQueueScope: Sendable {
    fileprivate let owner: UUID
    fileprivate let document: UInt64
    fileprivate let load: UInt64
    fileprivate let playlist: String
    fileprivate let video: String
}

/// Elapsed time of the current item, observed apart from `WebMusicPlayer.snapshot`.
/// The hidden page reports its position about four times a second; views that read
/// the coarse snapshot (title, artist, controls, volume) must not be rebuilt by it.
/// Publication is coalesced to the displayed whole second (a seek is a larger jump
/// and still shows at once) and stops while no visible window observes it, so a
/// hidden window costs nothing; the latest value is shown again on becoming visible.
@MainActor @Observable public final class WebMusicTimeline {
    public private(set) var position: Double = 0
    /// W17: seconds behind the live edge, republished once per displayed second like `position`; nil when not live.
    public private(set) var behindLive: Double?
    /// How many times `position` was published (a measurement, not UI state).
    @ObservationIgnored public private(set) var publications = 0
    @ObservationIgnored public private(set) var observing = true
    @ObservationIgnored private var latest: Double = 0
    @ObservationIgnored private var latestBehind: Double?
    public init() {}
    /// The newest reported position whether or not a window is observing (the progress record of an episode reads it every few seconds;
    /// the published `position` stays silent while no window is visible).
    public var latestPosition: Double { latest }
    /// True when the displayed whole second changes, or the position jumps.
    nonisolated static func shouldPublish(from old: Double, to new: Double) -> Bool {
        Int(max(0, old)) != Int(max(0, new)) || abs(new - old) >= 1
    }
    func update(_ value: Double, behindLive behind: Double? = nil) {
        latest = value; latestBehind = behind
        guard observing else { return }
        if behind.map({ Int($0) }) != behindLive.map({ Int($0) }) { behindLive = behind }
        guard Self.shouldPublish(from: position, to: value) else { return }
        position = value; publications += 1
    }
    public func setObserving(_ on: Bool) {
        observing = on
        if on { behindLive = latestBehind }
        if on, latest != position { position = latest; publications += 1 }
    }
}

/// The YouTube Music backend of the app's single playback owner. It drives
/// YouTube Music's own web player, hidden, through fixed commands and publishes
/// only validated, generation-fenced state. Nothing is created or loaded until
/// an explicit `play(playlistID:)`, so launch, sign-in and restore are silent.
@MainActor @Observable public final class WebMusicPlayer: WebMusicPageDelegate {
    /// Everything except the playback position: it changes only when something other than
    /// the clock does, so reading it never subscribes a view to position ticks. `position`
    /// here is always 0; read `timeline` for the clock.
    public private(set) var snapshot = WebMusicSnapshot()
    public let timeline = WebMusicTimeline()
    public private(set) var artwork: Data?
    /// Why the last control was refused (for example, seeking during an ad).
    public private(set) var refusal: WebMusicRefusal?
    /// Rejected bridge messages by category, for diagnostics only (no payloads kept).
    public private(set) var rejected: [WebMusicRejection: Int] = [:]
    /// W17: which native surface shows the video picture (at most one), and what the decoder is doing.
    public private(set) var surfaces = VideoSurfaceOwnership()
    public private(set) var videoActivity = VideoActivity()
    /// Why a Picture in Picture or audio-only request could not be honoured; nil when the last one could.
    public private(set) var videoNotice: String?
    /// Called after every published change (Now Playing follows this).
    @ObservationIgnored public var onChange: (@MainActor (WebMusicSnapshot, Data?) -> Void)?

    @ObservationIgnored var transport = WebMusicTransport()
    @ObservationIgnored var page: (any WebMusicPage)?
    @ObservationIgnored var committedDocument: UInt64 = 0
    @ObservationIgnored private let makePage: @MainActor (any WebMusicPageDelegate) -> any WebMusicPage
    @ObservationIgnored private let cookies: any WebMusicCookieSource
    @ObservationIgnored private let artworkLoader: any WebMusicArtworkLoading
    @ObservationIgnored private let loadTimeout: Duration
    @ObservationIgnored private let rotationDelay: Duration
    @ObservationIgnored private let shuffleAttempts: Int
    @ObservationIgnored private let shuffleInterval: Duration
    @ObservationIgnored private let pictureInPictureTimeout: Duration
    /// P5-1: whether the page is currently allowed to be throttled (nothing is playing).
    @ObservationIgnored private var throttled = false
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var rotation: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// Per-name baseline of the player's own store (value + expiry), so only cookies
    /// that changed in this store are written back — never the whole jar, which could
    /// roll back a newer value the signed coordinator wrote to the record.
    @ObservationIgnored private var cookieBaseline: [String: String] = [:]
    @ObservationIgnored private var pendingRotation: [String: HTTPCookie] = [:]
    /// The user moved the volume slider; a fresh page gets that level once it plays.
    @ObservationIgnored private var userVolume = false
    @ObservationIgnored private var volumePending = false
    /// The ad-time suspension of the load timeout (F1): re-armed once content shows.
    @ObservationIgnored private var timeoutSuspended = false
    @ObservationIgnored private var kickedLoad: UInt64 = 0
    @ObservationIgnored private var playedLoad: UInt64 = 0
    @ObservationIgnored private var routerLoad: UInt64 = 0
    @ObservationIgnored var closed = false
    /// W21: counts every command a person (or a media key) sent. A wake resume is only ever offered to a state no command has touched since.
    @ObservationIgnored public private(set) var commandRevision: UInt64 = 0
    @ObservationIgnored private var currentVideo: String?
    /// W21 (WIN09): the last session a cold launch restored, until Play starts it (nothing loads before an explicit action).
    @ObservationIgnored private var restoredTarget: (playlist: String, title: String?, video: String?, position: Double)?
    @ObservationIgnored private var pendingRestoreSeek: Double?
    /// A representation switch waiting for its load to be confirmed, then settled against the target's length.
    @ObservationIgnored private var pendingSwitch: (load: UInt64, target: String, plan: RepresentationTransition.Plan, from: RepresentationTransition.Current)?
    @ObservationIgnored private var decoderMeter = VideoDecoderMeter()
    @ObservationIgnored private var meterClock = ContinuousClock()
    @ObservationIgnored private var meterOrigin = ContinuousClock.now
    /// The surface that held the picture when Picture in Picture started, so ending it can give the picture back.
    @ObservationIgnored private var pictureInPictureReturn: VideoSurface?
    /// Rework F4: WebKit's presentation-mode change is asynchronous. Until a report says `active`, "not active" reports are the entering
    /// transition, not the system ending Picture in Picture; only active -> not active is an end. A watchdog turns a start that never
    /// reaches `active` into a stated refusal.
    @ObservationIgnored private var pictureInPictureConfirmed = false
    @ObservationIgnored private var pictureInPictureWatch: Task<Void, Never>?
    /// The video whose audio-version switch is waiting for its first picture report (rework F3).
    @ObservationIgnored private var audioVerification: String?
    /// Seconds on the decoder meter's clock; tests replace it.
    @ObservationIgnored var monotonicSeconds: (@MainActor () -> Double)?
    /// The service's play parameters a fresh document cannot carry in its URL; applied through the page's router once the
    /// document commits (a shuffle that silently played in order would be a fake success).
    @ObservationIgnored private var pendingTarget: (playlist: String, video: String?, params: String, load: UInt64)?
    /// PL2: while the user wants music playing, the app holds a user-initiated
    /// activity so App Nap cannot throttle the process that drives the hidden page.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    public var holdsPlaybackActivity: Bool { activity != nil }

    // P17-WEB: the sleep timer's state (logic in WebMusicSleepTimer.swift).
    /// What the timer is doing, for every surface; nil without one. Changes only when it is set, starts to fade or ends.
    public internal(set) var sleepTimerState: WebSleepTimerState?
    @ObservationIgnored var sleepTiming: any SleepTimerTiming
    @ObservationIgnored var sleepPlan: WebSleepPlan?
    @ObservationIgnored var sleepTask: Task<Void, Never>?
    @ObservationIgnored var sleepTokens: UInt64 = 0
    @ObservationIgnored var sleepTicking = false
    @ObservationIgnored var sleepRecheck = false
    /// `commandRevision` right after the timer paused the page: while no command has come since, the timer's pause stands (no wake resume, no restart by the page).
    @ObservationIgnored var sleepExpiredRevision: UInt64?
    @ObservationIgnored var sleepRepauses = 0
    @ObservationIgnored var sleepReport: (position: Double, at: Double, videoID: String?)?
    /// The page, unless the player is closed.
    var livePage: (any WebMusicPage)? { closed ? nil : page }
    /// The document the page's commands currently reach (0 when none has committed).
    var committedDocumentForSleep: UInt64 { committedDocument == transport.document ? committedDocument : 0 }

    public init(cookies: any WebMusicCookieSource, artwork: any WebMusicArtworkLoading = WebMusicArtworkLoader(),
                loadTimeout: Duration = .seconds(15), rotationDelay: Duration = .seconds(2), shuffleAttempts: Int = 40, shuffleInterval: Duration = .milliseconds(250), pictureInPictureTimeout: Duration = .seconds(4),
                sleepTiming: any SleepTimerTiming = SystemSleepTimerTiming(),
                makePage: @escaping @MainActor (any WebMusicPageDelegate) -> any WebMusicPage = { WebKitMusicPage(delegate: $0) }) {
        self.cookies = cookies; artworkLoader = artwork; self.loadTimeout = loadTimeout; self.rotationDelay = rotationDelay; self.shuffleAttempts = max(1, shuffleAttempts); self.shuffleInterval = shuffleInterval; self.pictureInPictureTimeout = pictureInPictureTimeout; self.sleepTiming = sleepTiming; self.makePage = makePage
    }
    @ObservationIgnored private let radioOwner = UUID()
    /// The clock a radio queue update's deadline is read from: the continuous clock in the app. A test supplies one that stands still until it lets
    /// the deadline pass, so whether an update was confirmed in time never depends on how busy the machine running the test is.
    @ObservationIgnored var radioQueueClock: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    @ObservationIgnored private(set) var updatingRadioQueue = false
    /// True while an update the page accepted waits for the page's queue to show its change (the last phase before success or the deadline).
    @ObservationIgnored private(set) var radioQueueAwaitingChange = false
    /// One uncancellable page invocation at most, including one whose native deadline expired.
    @ObservationIgnored private var radioDispatch: UUID?
    @MainActor private final class RadioDispatchResult {
        var active = true
        var reply: WebMusicCommandReply?
        var acceptedRevision: UInt64 = 0
    }
    public func captureRadioQueueScope(playlistID: String) -> WebMusicRadioQueueScope? {
        guard !closed, page != nil, committedDocument != 0, committedDocument == transport.document,
              transport.confirmed, snapshot.playlistID == playlistID, snapshot.canControlQueue,
              let video = snapshot.videoID else { return nil }
        return .init(owner: radioOwner, document: committedDocument, load: transport.load, playlist: playlistID, video: video)
    }
    public func radioQueueScopeIsCurrent(_ scope: WebMusicRadioQueueScope) -> Bool {
        !closed && page != nil && scope.owner == radioOwner && scope.document == committedDocument
            && committedDocument == transport.document && scope.load == transport.load && transport.confirmed
            && snapshot.playlistID == scope.playlist && snapshot.videoID == scope.video && !snapshot.isFailed
            && snapshot.queue?.videoID == scope.video
    }
    /// Updates only the published autoplay section of an existing queue. Acceptance is not confirmation.
    /// Nothing here changes ownership, creates a page, resets the transport or changes pause intent.
    public func applyRadioFilter(_ command: MusicQueueFilterCommand, scope: WebMusicRadioQueueScope,
                                 admitted: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        guard !updatingRadioQueue, radioDispatch == nil, admitted(), radioQueueScopeIsCurrent(scope), let page else { return false }
        switch transport.admitQueueSetting() {
        case .failure(let reason): refusal = reason; return false
        case .success: break
        }
        guard let before = snapshot.queue,
              let invocation = try? WebMusicCommand.updateRadioQueue(command, document: scope.document, load: scope.load,
                  videoID: scope.video, currentPlaylistID: scope.playlist).invocation() else { return false }
        let deadline = radioQueueClock().advanced(by: loadTimeout)
        let result = RadioDispatchResult(), dispatch = UUID()
        updatingRadioQueue = true; radioDispatch = dispatch
        defer {
            result.active = false
            updatingRadioQueue = false; radioQueueAwaitingChange = false
            // Restore the normal paused/ad scheduling policy even if WebKit never resumes.
            updateThrottle(transport.snapshot)
        }
        // An unstructured invocation is intentional: a task group would join a suspended WebKit
        // continuation on timeout. Keep its slot until it really returns; repeated presses cannot
        // accumulate dispatches. Late completion may only release that slot, never certify success.
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.radioDispatch == dispatch { self.radioDispatch = nil } }
            guard result.active, self.radioQueueClock() < deadline, !Task.isCancelled,
                  admitted(), self.radioQueueScopeIsCurrent(scope) else { return }
            if case .failure = self.transport.admitQueueSetting() { result.reply = .unavailable; return }
            self.setThrottle(false)
            let reply = await page.run(invocation)
            guard result.active, self.radioQueueClock() < deadline,
                  admitted(), self.radioQueueScopeIsCurrent(scope) else { return }
            result.acceptedRevision = self.transport.queueRevision
            result.reply = reply
        }
        while result.reply == nil, radioQueueClock() < deadline, !Task.isCancelled {
            guard admitted(), radioQueueScopeIsCurrent(scope) else { return false }
            if case .failure(let reason) = transport.admitQueueSetting() { refusal = reason; return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard admitted(), radioQueueScopeIsCurrent(scope) else { return false }
        guard !Task.isCancelled, radioQueueClock() < deadline else { refusal = .pageDidNotTake; return false }
        guard let reply = result.reply else { refusal = .pageDidNotTake; return false }
        guard reply == .router else { refusal = Self.refusal(for: reply); return false }
        // Discard pre-acceptance evidence, using only the revision of the applicable snapshot.
        let accepted = result.acceptedRevision
        radioQueueAwaitingChange = true
        while radioQueueClock() < deadline, !Task.isCancelled {
            guard admitted(), radioQueueScopeIsCurrent(scope) else { return false }
            if case .failure(let reason) = transport.admitQueueSetting() { refusal = reason; return false }
            if transport.queueRevision > accepted, let after = snapshot.queue,
               before.upcoming.map(\.videoID) != after.upcoming.map(\.videoID) {
                refusal = nil; return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        refusal = .pageDidNotTake
        return false
    }
    public var isClosed: Bool { closed }
    public var hasPage: Bool { page != nil }

    // MARK: Commands (the only path from native controls into the page)

    /// Plays a whole library playlist through YouTube Music's own queue.
    public func play(playlistID: String, title: String? = nil, videoID: String? = nil, params: String? = nil, intent: MusicPlaybackIntent = .endpoint, queueCommand: MusicQueueFilterCommand? = nil) async {
        guard !closed, WebMusicIdentifier.isPlaylistID(playlistID),
              videoID.map({ WebMusicIdentifier.isVideoID($0) }) ?? true,
              params.map(WebMusicIdentifier.isEndpointParams) ?? true else { refusal = .invalidTarget; return }
        guard queueCommand == nil else { refusal = .invalidTarget; return }
        commandRevision &+= 1
        restoredTarget = nil
        refusal = nil
        // Parameterized endpoints always use the router, with no plain playlist fallback.
        if params != nil || intent == .shuffle { await playEndpoint(playlistID, title: title, videoID: videoID, params: params, intent: intent); return }
        let load = transport.begin(playlistID: playlistID, title: title)
        kickedLoad = 0; artwork = nil; publish()
        currentVideo = videoID
        if let page, committedDocument != 0, committedDocument == transport.document {
            routerLoad = load; transport.expectRouter()
            let command: WebMusicCommand = (videoID == nil && params == nil) ? .loadPlaylist(playlistID, load: load) : .loadTarget(playlistID, videoID: videoID, params: params, load: load)
            let reply = await run(command, on: page)
            guard load == transport.load else { return }
            if reply != .router { fullLoad(playlistID, load: load) }
        } else {
            let fresh = page == nil
            let target = page ?? makePage(self)
            page = target
            if fresh {
                let session: [HTTPCookie]
                do { session = try await cookies.playerCookies() } catch {
                    guard load == transport.load else { return }
                    fail(.sessionUnavailable); return
                }
                guard load == transport.load, page === target else { return }
                await target.install(cookies: session)
                cookieBaseline = Self.baseline(session); volumePending = userVolume
                guard load == transport.load, page === target else { return }
            }
            fullLoad(playlistID, load: load)
        }
        armTimeout(load)
    }
    /// Routes the exact published endpoint after a neutral document is ready, with bounded retries and no plain-load fallback.
    /// Endpoint intent requires accepted routing and an observable target/queue transition; Shuffle retains strict shuffle evidence.
    /// Filter selection confirmation comes separately from the queue's fresh chip selection flags.
    private func playEndpoint(_ playlistID: String, title: String?, videoID: String?, params: String?, intent: MusicPlaybackIntent) async {
        let load = transport.begin(playlistID: playlistID, title: title)
        kickedLoad = 0; artwork = nil; publish()
        currentVideo = videoID
        let live = page != nil && committedDocument != 0 && committedDocument == transport.document
        if !live {
            let fresh = page == nil
            let target = page ?? makePage(self)
            page = target
            if fresh {
                let session: [HTTPCookie]
                do { session = try await cookies.playerCookies() } catch {
                    guard load == transport.load else { return }
                    fail(.sessionUnavailable); return
                }
                guard load == transport.load, page === target else { return }
                await target.install(cookies: session)
                cookieBaseline = Self.baseline(session); volumePending = userVolume
                guard load == transport.load, page === target else { return }
            }
            guard let url = WebMusicNavigation.hostURL(document: transport.reserveDocument(), load: load) else { fail(intent == .shuffle ? .shuffleFailed : .loadFailed); return }
            committedDocument = 0
            target.load(url)
        }
        if intent == .shuffle { transport.expectShuffle() } else { transport.expectEndpoint(videoID: videoID) }
        var routed = false
        for _ in 0..<shuffleAttempts {
            guard load == transport.load, !closed, !transport.snapshot.isFailed else { return }
            if let page, committedDocument != 0, committedDocument == transport.document {
                let command: WebMusicCommand = .loadTarget(playlistID, videoID: videoID, params: params, load: load)
                let reply = await run(command, on: page)
                guard load == transport.load else { return }
                // Only the router's own acceptance counts. "fallback" (no app yet) and "unavailable" (no state yet) are not done.
                if reply == .router { transport.acceptEndpoint(load: load); routed = true; break }
            }
            try? await Task.sleep(for: shuffleInterval)
        }
        guard load == transport.load, !closed, !transport.snapshot.isFailed else { return }
        guard routed else { fail(intent == .shuffle ? .shuffleFailed : .loadFailed); return }
        armTimeout(load)
        while load == transport.load, !transport.confirmed, !transport.snapshot.isFailed, !closed { try? await Task.sleep(for: .milliseconds(20)) }
    }
    public func playPause() async {
        if snapshot.intent { await pause() } else { await resume() }
    }
    public func pause() async {
        guard let page, !closed else { return }
        commandRevision &+= 1
        transport.setIntent(false); publish()
        _ = await run(.pause, on: page)
    }
    /// W22 (ROUTE09): set by the playback owner. Consulted before an explicit Play makes sound, so Play here (after a route loss) and the receiver-timer note
    /// come first. Nil (a test, or no output coordinator) means Play goes straight through.
    @ObservationIgnored public var audibleStartGate: (@MainActor (_ proceed: @escaping @MainActor () async -> Void) async -> Void)?
    public func resume() async {
        if let gate = audibleStartGate { await gate { [weak self] in await self?.resumeAfterAdmission() }; return }
        await resumeAfterAdmission()
    }
    /// Play, after the route has admitted it.
    public func resumeAfterAdmission() async {
        guard !closed else { return }
        // A restored item has no page yet: Play loads its playlist and item, then moves to where it was.
        if let target = restoredTarget, page == nil, transport.load == 0 {
            await play(playlistID: target.playlist, title: target.title, videoID: target.video)
            if target.position > 1 { pendingRestoreSeek = target.position }
            return
        }
        if case .failed = snapshot.phase, let id = snapshot.playlistID { await play(playlistID: id, title: snapshot.playlistTitle); return }
        guard let page, transport.load > 0 else { return }
        commandRevision &+= 1
        transport.setIntent(true); transport.setRouteLossPause(false); refusal = nil; publish()
        _ = await run(.play, on: page)
    }
    public func seek(_ target: Double) async {
        guard let page else { return }
        commandRevision &+= 1
        switch transport.admitSeek(target) {
        case .failure(let reason): refusal = reason
        case .success(let position):
            refusal = nil
            if await run(.seek(position), on: page) == .ad { refusal = .advertisement }
        }
    }
    public func next() async { await skip(forward: true) }
    /// PLAY11: restarts after three seconds, otherwise YouTube's previous item.
    public func previous() async {
        if transport.previousRestarts, case .success = transport.admitSkip() { await seek(0); return }
        await skip(forward: false)
    }
    /// Next and Previous start sound too (YouTube plays the next item), so they ask the output gate exactly as Play does (W22, ROUTE09).
    private func skip(forward: Bool) async {
        if let gate = audibleStartGate { await gate { [weak self] in await self?.skipAfterAdmission(forward: forward) }; return }
        await skipAfterAdmission(forward: forward)
    }
    private func skipAfterAdmission(forward: Bool) async {
        guard let page else { return }
        commandRevision &+= 1
        switch transport.admitSkip() {
        case .failure(let reason): refusal = reason
        case .success:
            refusal = nil; transport.setIntent(true); publish()
            if await run(forward ? .next : .previous, on: page) == .ad { refusal = .advertisement }
        }
    }
    /// CORE-A: plays an item from the page's own queue (one the page lists after the playing item). It starts sound like Next does, so it asks the
    /// output gate the same way. Refused during an ad. The result is what the page does next: the new item reports itself like any other.
    public func playQueueItem(_ videoID: String) async {
        if let gate = audibleStartGate { await gate { [weak self] in await self?.playQueueItemAfterAdmission(videoID) }; return }
        await playQueueItemAfterAdmission(videoID)
    }
    private func playQueueItemAfterAdmission(_ videoID: String) async {
        guard let page, !closed else { return }
        commandRevision &+= 1
        switch transport.admitQueueSelection(videoID) {
        case .failure(let reason): refusal = reason
        case .success:
            refusal = nil; transport.setIntent(true); publish()
            refusal = Self.refusal(for: await run(.playQueueItem(videoID), on: page), itemCommand: true)
        }
    }
    /// CORE-A: asks the page's player bar to turn shuffle on or off. The state shown afterwards is whatever the page then reports, never this request.
    public func setShuffle(_ on: Bool) async {
        guard let page, !closed else { return }
        commandRevision &+= 1
        switch transport.admitQueueSetting() {
        case .failure(let reason): refusal = reason
        case .success: refusal = nil; refusal = Self.refusal(for: await run(.shuffle(on), on: page))
        }
    }
    /// CORE-A: asks the page's player bar for a repeat mode (its own button is stepped until the page shows it).
    public func setRepeat(_ mode: WebMusicRepeatMode) async {
        guard let page, !closed else { return }
        commandRevision &+= 1
        switch transport.admitQueueSetting() {
        case .failure(let reason): refusal = reason
        case .success: refusal = nil; refusal = Self.refusal(for: await run(.repeatMode(mode), on: page))
        }
    }
    /// What the page's answer to a queue, shuffle or repeat request means for the person: nothing when it took, a stated reason otherwise.
    static func refusal(for reply: WebMusicCommandReply, itemCommand: Bool = false) -> WebMusicRefusal? {
        switch reply {
        case .ok: nil
        case .ad: .queueAdvertisement
        case .rejected: itemCommand ? .queueItemGone : .pageDidNotTake
        default: .pageDidNotTake
        }
    }
    /// The speed the page's `<video>` is ACTUALLY playing at: what its periodic report says (and a speed command's read-back), 1 until the page
    /// has said for this item. It is reconciled on every report, so a new item, a full load or an ad that changed the element's speed shows here.
    /// Position and duration are always in media seconds, whatever the speed.
    public var confirmedRate: Double { transport.snapshot.elementRate ?? 1 }
    /// W18: asks the page for a listening speed. True only when the page's own `<video>` reports the speed back; an ad, a missing element or a
    /// page that ignored the request leaves `confirmedRate` as it was.
    @discardableResult public func setRate(_ rate: Double) async -> Bool {
        guard rate.isFinite, (0.5...3).contains(rate), let page, !closed, !snapshot.isAd else { return false }
        let reply = await run(.rate(rate), on: page)
        if reply == .ok { transport.noteElementRate(rate); publish(); return true }
        return false
    }
    /// An advertisement is always 1x. If the element reports another speed while one shows (the episode's speed carried into the ad), it is
    /// returned to normal speed; the app never changes an ad's speed in any other way. A page that does not take it is asked ONCE per ad: the
    /// refusal is remembered until the ad ends, and the element's real speed stays shown.
    private func restoreAdSpeed() {
        if !transport.snapshot.isAd { adSpeedRefused = false; return }
        guard let page, !closed, let rate = transport.snapshot.elementRate, abs(rate - 1) > 0.001, !adSpeedRestoring, !adSpeedRefused else { return }
        adSpeedRestoring = true
        Task {
            let reply = await self.run(.normalSpeed, on: page)
            if reply == .ok { self.transport.noteElementRate(1); self.publish() } else { self.adSpeedRefused = true }
            self.adSpeedRestoring = false
        }
    }
    private var adSpeedRestoring = false
    private var adSpeedRefused = false
    public func setVolume(_ level: Double) async {
        guard level.isFinite, (0...1).contains(level) else { return }
        transport.setVolume(level); userVolume = true; publish()
        if let page { _ = await run(.volume(level), on: page) }
    }
    /// Shows the last session paused, with nothing loaded: only on a player that has never been asked to play. Returns whether it was restored.
    @discardableResult public func restoreLastSession(playlistID: String, playlistTitle: String?, videoID: String?, title: String?, artist: String?, position: Double, duration: Double) -> Bool {
        guard !closed, page == nil, WebMusicIdentifier.isPlaylistID(playlistID), videoID.map({ WebMusicIdentifier.isVideoID($0) }) ?? true,
              position.isFinite, position >= 0, duration.isFinite, duration >= 0 else { return false }
        guard transport.restore(playlistID: playlistID, playlistTitle: playlistTitle, title: title, artist: artist, position: position, duration: duration) else { return false }
        restoredTarget = (playlistID, playlistTitle ?? title, videoID, position)
        currentVideo = videoID
        publish()
        timeline.update(position)
        return true
    }
    /// The position the restored item will resume at (nil once it has been started or when nothing was restored).
    public var restoredPosition: Double? { restoredTarget?.position }

    // MARK: System sleep and wake (W21, WIN07/WIN08)

    /// What the app knew when the Mac went to sleep: that this player was making sound because a person asked for it, and which of their
    /// commands it had seen by then. Nothing else resumes playback after a wake.
    public struct SystemSleepHold: Sendable, Equatable {
        public let commandRevision: UInt64
        public let videoID: String?
    }
    /// The Mac is about to sleep. Audio that a person wanted is paused in the page (so the page cannot start itself on wake: no surprise audio)
    /// without recording a person's pause, and the hold says it was wanted. Nil when nothing was playing or loading, or the player is closed.
    /// An advertisement counts as playing; it is paused like any other playback and resumes from where the page left it (never skipped).
    public func holdForSystemSleep() async -> SystemSleepHold? {
        guard !closed, let page, snapshot.intent, !snapshot.isFailed,
              [WebMusicPhase.loading, .buffering, .playing].contains(snapshot.phase) || snapshot.isAd else { return nil }
        let hold = SystemSleepHold(commandRevision: commandRevision, videoID: snapshot.videoID)
        transport.setIntent(false); publish()
        _ = await run(.pause, on: page)
        return hold
    }
    /// The Mac woke and the app decided to resume: only when no command arrived since the hold, the same player and item are still here, and
    /// nothing closed it. Returns whether play was sent.
    @discardableResult public func resumeAfterSystemWake(_ hold: SystemSleepHold) async -> Bool {
        guard !closed, let page, commandRevision == hold.commandRevision, !snapshot.pausedByRouteLoss, !sleepTimerHasExpired(), transport.load > 0, snapshot.videoID == hold.videoID, !snapshot.isFailed else { return false }
        transport.setIntent(true); refusal = nil; publish()
        _ = await run(.play, on: page)
        return true
    }
    /// After a wake that did not resume: if the page is making sound anyway, it is paused again. A pause only; the person's intent is untouched.
    public func silencePageAgainstIntent() async {
        guard !closed, let page, !snapshot.intent, [WebMusicPhase.loading, .buffering, .playing].contains(snapshot.phase) else { return }
        _ = await run(.pause, on: page)
    }

    // MARK: Output route (W22, ROUTE03, ROUTE08)

    /// Sound is playing, or a person wants it and the page is loading or buffering toward it. A page that plays against its intent counts as sound.
    public var isAudibleOrWanted: Bool {
        guard !closed, page != nil, !snapshot.isFailed else { return false }
        return snapshot.phase == .playing || (snapshot.intent && [WebMusicPhase.loading, .buffering].contains(snapshot.phase))
    }
    @ObservationIgnored private var routeLossRepauses = 0
    /// The output the page was playing through went away (headphones unplugged, a device or receiver disconnected). The pause reaches the page through
    /// the same command path as a person's pause, and records a ROUTE-LOSS reason: it is not a person's
    /// pause, no later wake or reconnect resumes it, and only a person's explicit Play does (after Play here is confirmed when speakers would take over).
    /// The command revision moves, so a sleep hold taken earlier cannot resume over it.
    @discardableResult public func pauseForRouteLoss() async -> Bool {
        guard !closed, let page else { return false }
        commandRevision &+= 1; routeLossRepauses = 0
        transport.setIntent(false); transport.setRouteLossPause(true); publish()
        return await run(.pause, on: page) != .unavailable
    }
    /// The other engine is about to play: this one must make no sound until it is started again. A page that cannot confirm the pause (no committed
    /// document) is dropped instead, which certainly silences it. True when silence is established.
    public func stopForHandoff() async -> Bool {
        guard !closed, let page else { return true }
        commandRevision &+= 1
        transport.setIntent(false); publish()
        if await run(.pause, on: page) == .unavailable { await dropPage() }
        return true
    }
    /// A page that reports playing after a route-loss pause (the report was in flight, or YouTube restarted itself) is paused again, a bounded number of times.
    private func repauseAfterRouteLossIfNeeded() {
        guard snapshot.pausedByRouteLoss, snapshot.phase == .playing, routeLossRepauses < 3, let page, !closed else { return }
        routeLossRepauses += 1
        Task { _ = await self.run(.pause, on: page) }
    }

    /// Account switch, sign-out, removal or quit: stop media and discard the store.
    public func teardown() async {
        closed = true
        cancelSleepTimerForTeardown()
        transport.reset(); committedDocument = 0
        surfaces.releaseAll(); pictureInPictureReturn = nil; pendingSwitch = nil; decoderMeter.reset(); videoActivity = VideoActivity()
        pictureInPictureWatch?.cancel(); pictureInPictureConfirmed = false; audioVerification = nil
        timeout?.cancel(); rotation?.cancel(); artworkTask?.cancel(); pendingRotation = [:]
        artwork = nil; refusal = nil; publish()
        await dropPage()
    }
    /// Every terminal failure stops audio: the page is dropped (its teardown pauses
    /// media), so the transport never shows a failure while the hidden page plays.
    private func fail(_ failure: WebMusicFailure) {
        transport.fail(failure); transport.invalidateDocument()
        surfaces.releaseAll(); pictureInPictureReturn = nil; pendingSwitch = nil
        timeout?.cancel(); timeoutSuspended = false
        publish()
        Task { await self.dropPage() }
    }

    func run(_ command: WebMusicCommand, on page: any WebMusicPage) async -> WebMusicCommandReply {
        guard let invocation = try? command.invocation() else { return .unavailable }
        // Nothing but a pause may reach a page that is still throttled.
        if command != .pause { setThrottle(false) }
        return await page.run(invocation)
    }
    private func fullLoad(_ playlistID: String, load: UInt64) {
        guard let page, let url = WebMusicNavigation.playlistURL(playlistID, videoID: currentVideo, document: transport.reserveDocument(), load: load) else { return }
        committedDocument = 0
        page.load(url)
    }
    private func armTimeout(_ load: UInt64) {
        timeout?.cancel(); timeoutSuspended = false
        timeout = Task { [weak self, loadTimeout] in
            try? await Task.sleep(for: loadTimeout)
            guard !Task.isCancelled else { return }
            self?.loadTimedOut(load)
        }
    }
    private func loadTimedOut(_ load: UInt64) {
        guard load == transport.load, !transport.confirmed, !closed else { return }
        // Never reload or fail a load while an ad plays (pre-roll pods run 15–30 s+).
        if snapshot.isAd { timeoutSuspended = true; return }
        // A shuffle that was routed but never showed itself playing is a failure, not a reason to load the playlist in order.
        if transport.requiresShuffle { fail(.shuffleFailed); return }
        if transport.requiresEndpoint { fail(.timedOut); return }
        if routerLoad == load, let id = snapshot.playlistID {
            // The in-page router did not start this load: one full-load fallback,
            // bound to the same load generation.
            routerLoad = 0; fullLoad(id, load: load); armTimeout(load); return
        }
        fail(.timedOut)
    }
    private func dropPage() async {
        // The picture returns to the hidden host (a native surface never outlives the page it showed).
        page?.attachVideo(to: nil)
        let old = page; page = nil; throttled = false; committedDocument = 0; cookieBaseline = [:]; pendingRotation = [:]; rotation?.cancel()
        await old?.teardown()
    }


    // MARK: W17 video, live and representation switching

    /// What the decoder is doing, read from the frame counter the page reports. Not part of `snapshot`: frames advance continuously.
    public struct VideoActivity: Sendable, Equatable {
        public var pictureSize: CGSize?
        public var frames = 0
        public var advances = 0
        public var decoding = false
    }
    /// Whether this player is the one that may take the picture right now: something with a picture is loaded and playing or paused.
    public var canShowVideo: Bool { !closed && page != nil && snapshot.hasPicture && !snapshot.isFailed }

    private func meterSeconds() -> Double {
        if let monotonicSeconds { return monotonicSeconds() }
        let now = ContinuousClock.now
        return Double((now - meterOrigin).components.seconds) + Double((now - meterOrigin).components.attoseconds) / 1e18
    }
    private func noteMedia(_ sample: WebMusicMediaSample) {
        let seconds = meterSeconds()
        decoderMeter.record(frames: sample.decodedFrames, at: seconds)
        let next = VideoActivity(pictureSize: transport.snapshot.pictureSize, frames: decoderMeter.frames, advances: decoderMeter.advances,
                                 decoding: decoderMeter.isDecoding(at: seconds) && sample.decodedFrames > 0)
        if next != videoActivity { videoActivity = next }
        // Picture in Picture (rework F4): "active" confirms it; only active -> not active is the system ending it (its own return/close
        // button). A "not active" report while WebKit is still entering the mode is ignored.
        if surfaces.holder == .pictureInPicture {
            if sample.pictureInPicture == .active { pictureInPictureConfirmed = true; pictureInPictureWatch?.cancel() }
            else if pictureInPictureConfirmed { endPictureInPictureFromSystem() }
        }
        // Rework F3: an audio-version switch says "the decoder stopped" only when the song reports no picture; a song that still carries a
        // picture is reported as such (the decoder may not have stopped, and this could not be verified).
        if let id = audioVerification, sample.videoID == id || sample.videoID == nil, transport.confirmed {
            audioVerification = nil
            if sample.pictureWidth > 0 || sample.pictureHeight > 0 {
                videoNotice = String(localized: "YouTube's audio version still carries a picture, so the video decoder may not have stopped. This could not be stopped or verified here.")
            }
        }
    }
    private func endPictureInPictureFromSystem() {
        pictureInPictureConfirmed = false; pictureInPictureWatch?.cancel()
        surfaces.release(.pictureInPicture)
        if let back = pictureInPictureReturn { surfaces.request(back) } else { Task { await self.endPresentation() } }
        pictureInPictureReturn = nil
    }
    /// Re-reads the decoder against the clock: a decoder that stopped reports no more frames, so staleness is what shows it.
    public func refreshVideoActivity() {
        let decoding = decoderMeter.isDecoding(at: meterSeconds())
        if decoding != videoActivity.decoding { videoActivity.decoding = decoding }
    }

    /// Shows the picture on a native surface. The SAME web view (and so the same media) moves into `host`; nothing is loaded, paused or
    /// restarted. Whichever surface held the picture lets go in the same step, so two surfaces never show it and nothing plays twice.
    @discardableResult public func presentVideo(on surface: VideoSurface, host: NSView?) async -> VideoSurfaceOwnership.Change? {
        guard !closed, let page else { return nil }
        videoNotice = nil
        switch surface {
        case .pictureInPicture:
            guard snapshot.hasPicture else { videoNotice = String(localized: "There is no picture to show."); return nil }
            guard snapshot.pictureInPicture == .available else {
                videoNotice = String(localized: "Picture in Picture is not available for this video: WebKit reports that it does not support it here.")
                return nil
            }
            let previous = surfaces.holder
            guard await run(.pictureInPicture(true), on: page) == .ok else {
                videoNotice = String(localized: "WebKit did not start Picture in Picture for this video.")
                return nil
            }
            pictureInPictureReturn = previous
            pictureInPictureConfirmed = snapshot.pictureInPicture == .active
            pictureInPictureWatch?.cancel()
            if !pictureInPictureConfirmed {
                pictureInPictureWatch = Task { [weak self, timeout = pictureInPictureTimeout] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, let self, !self.closed, self.surfaces.holder == .pictureInPicture, !self.pictureInPictureConfirmed else { return }
                    if let page = self.page { _ = await self.run(.pictureInPicture(false), on: page) }
                    self.endPictureInPictureFromSystem()
                    self.videoNotice = String(localized: "WebKit did not enter Picture in Picture for this video.")
                }
            }
            return surfaces.request(.pictureInPicture)
        case .inline, .window, .fullScreen:
            guard let host else { return nil }
            if surfaces.holder == .pictureInPicture { _ = await run(.pictureInPicture(false), on: page); pictureInPictureReturn = nil }
            guard !closed, self.page === page else { return nil }
            page.attachVideo(to: host)
            _ = await run(.presentVideo(true), on: page)
            return surfaces.request(surface)
        }
    }
    /// A surface closes. Only the holder's release changes anything; the media keeps playing or stays paused exactly as it was.
    public func releaseVideo(_ surface: VideoSurface) async {
        guard surfaces.release(surface) else { return }
        if surface == .pictureInPicture { pictureInPictureWatch?.cancel(); pictureInPictureConfirmed = false }
        if surface == .pictureInPicture, let page, !closed { _ = await run(.pictureInPicture(false), on: page); pictureInPictureReturn = nil }
        guard surfaces.holder == nil else { return }
        await endPresentation()
    }
    private func endPresentation() async {
        guard let page, !closed else { return }
        _ = await run(.presentVideo(false), on: page)
        page.attachVideo(to: nil)
    }
    /// The page player's own quality level (one it offered) and captions. Refused honestly when the page does not take them.
    public func setQuality(_ level: String) async {
        guard let page, !closed, snapshot.qualities.contains(level) else { videoNotice = String(localized: "That quality is not one this video offers."); return }
        videoNotice = nil
        if await run(.quality(level), on: page) != .ok { videoNotice = String(localized: "YouTube Music did not change the quality.") }
    }
    public func setCaptions(_ on: Bool) async {
        guard let page, !closed, snapshot.captions != .unavailable else { videoNotice = String(localized: "This video has no captions to show."); return }
        videoNotice = nil
        if await run(.captions(on), on: page) != .ok { videoNotice = String(localized: "YouTube Music did not change the captions.") }
    }
    /// Rework F2: what the web view answers to input (real AppKit). Nil without a page or for a fake page.
    public func inputFacts() -> WebMusicInputFacts? { page?.inputFacts() }
    /// A one-off decoder and geometry read of the page's `<video>`.
    public func measureVideo() async -> WebMusicVideoMeasurement? { await page?.measureVideo() }

    /// Go live: the player's jump to the live edge of the window it reported.
    public func goLive() async {
        guard let page, !closed else { return }
        switch transport.admitGoLive() {
        case .failure(let reason): refusal = reason
        case .success:
            refusal = nil; transport.setIntent(true); publish()
            switch await run(.goLive, on: page) {
            case .ok: break
            case .ad: refusal = .advertisement
            default: refusal = .liveNotSeekable
            }
        }
    }

    /// Switches the presentation of what is playing. The target is started through the service's own endpoint (the playlist already
    /// playing, the target's video id). The position is carried over only when the service published the pair, and only if the two
    /// lengths then agree (MEDIA02); otherwise it starts from the beginning and `snapshot.restart` says why.
    @discardableResult public func switchRepresentation(to target: RepresentationTransition.Target) async -> RepresentationTransition.Plan {
        guard !closed, page != nil else { return .refused(.nothingPlaying) }
        let current = transport.current()
        let plan = RepresentationTransition.plan(current: current, target: target, catalog: transport.catalog)
        switch plan {
        case .refused(let reason):
            if reason == .advertisement { refusal = .advertisement }
            return plan
        case .keep: return plan
        case .continued, .restart:
            guard let from = current, WebMusicIdentifier.isVideoID(target.asset.assetID) else { return .refused(.nothingPlaying) }
            // The video surface follows the target: a song has no picture, so it is let go before the switch (never covered).
            if target.representation == .audio { await releaseAllSurfaces() }
            let playlist = snapshot.playlistID ?? "RDAMVM" + target.asset.assetID
            pendingSwitch = (transport.load + 1, target.asset.assetID, plan, from)
            audioVerification = target.representation == .audio ? target.asset.assetID : nil
            await play(playlistID: playlist, title: snapshot.playlistTitle, videoID: target.asset.assetID)
            return plan
        }
    }
    /// Audio only: the song version, asked of the service. Nothing covers a decoding video. When the service published no audio version
    /// the video keeps playing and `videoNotice` says so.
    @discardableResult public func selectAudioOnly() async -> Result<RepresentationTransition.Plan, RepresentationTransition.AudioOnlyUnavailable> {
        videoNotice = nil
        // The reason is the snapshot's own (rework F9): a page that has not said song or video is not "nothing playing".
        if let reason = snapshot.audioOnlyUnavailable { videoNotice = reason.message; return .failure(reason) }
        switch RepresentationTransition.audioOnlyTarget(for: transport.current(), catalog: transport.catalog) {
        case .failure(let reason):
            videoNotice = reason.message
            return .failure(reason)
        case .success(let target):
            return .success(await switchRepresentation(to: target))
        }
    }
    /// The video version of what is playing, when the service published one.
    @discardableResult public func selectVideo() async -> RepresentationTransition.Plan? {
        guard let other = snapshot.counterpartVideoID, snapshot.counterpartRepresentation == .video else {
            videoNotice = String(localized: "YouTube Music has published no video version of this song.")
            return nil
        }
        videoNotice = nil
        return await switchRepresentation(to: .init(asset: .youTubeMusic(other), representation: .video))
    }
    private func releaseAllSurfaces() async {
        for surface in VideoSurface.allCases { await releaseVideo(surface) }
    }
    private func settlePendingSwitch() {
        guard let pending = pendingSwitch else { return }
        guard pending.load == transport.load else { pendingSwitch = nil; return }
        guard transport.confirmed, transport.snapshot.videoID == pending.target else { return }
        // A carried position is judged against the target's length, so it waits until the page has reported one; a restart decided up
        // front needs nothing more than the confirmed load.
        if case .continued = pending.plan, transport.snapshot.duration <= 0 { return }
        pendingSwitch = nil
        let settled = RepresentationTransition.settle(pending.plan, current: pending.from, targetDuration: transport.snapshot.duration > 0 ? transport.snapshot.duration : nil)
        switch settled {
        case .continued(let position):
            transport.setRestart(nil)
            if let page { Task { _ = await self.run(.seek(position), on: page) } }
        case .restart(let reason):
            transport.setRestart(reason); publish()
        case .keep, .refused: break
        }
    }

    // MARK: WebMusicPageDelegate

    public func page(received body: Any, from frame: WebMusicFrame) {
        switch WebMusicBridge.validate(body, frame: frame, document: committedDocument == transport.document ? transport.document : 0, load: transport.load) {
        case .failure(let rejection): rejected[rejection, default: 0] += 1
        case .success(let message):
            let wasConfirmed = transport.confirmed, wasFailed = transport.snapshot.isFailed
            guard transport.apply(message) else { return }
            if transport.snapshot.isFailed, !wasFailed, case .failed(let failure) = transport.snapshot.phase { fail(failure); return }
            publish()
            repauseAfterRouteLossIfNeeded()
            if sleepPlan != nil {
                noteSleepReport()
                if case .ended = message.event { sleepTimerNeedsLookNow() }
                else if transport.snapshot.isAd, sleepPlan?.fade != nil { sleepTimerNeedsLookNow() }
            }
            repauseAfterSleepTimerIfNeeded()
            if case .media(let sample) = message.event { noteMedia(sample) }
            restoreAdSpeed()
            settlePendingSwitch()
            if transport.confirmed, !wasConfirmed { timeout?.cancel(); timeoutSuspended = false }
            if transport.snapshot.isAd, !transport.confirmed {
                // An ad for this load is running: suspend the load timeout (F1).
                timeout?.cancel(); timeoutSuspended = true
            } else if timeoutSuspended, !transport.confirmed, !transport.snapshot.isAd {
                armTimeout(transport.load)
            }
            if transport.confirmed, volumePending, let page {
                volumePending = false
                let level = snapshot.volume
                Task { _ = await self.run(.volume(level), on: page) }
            }
            if snapshot.phase == .playing { playedLoad = transport.load }
            if let target = pendingRestoreSeek, transport.confirmed, snapshot.phase == .playing, snapshot.canSeek {
                pendingRestoreSeek = nil
                Task { await self.seek(target) }
            }
            // YouTube may not start a fresh watch page by itself: at most one native
            // Play per load, and only before that load has ever played (so a later
            // pause or prompt from YouTube is never overridden).
            if transport.confirmed, playedLoad != transport.load, kickedLoad != transport.load, snapshot.intent, snapshot.phase == .paused, let page {
                kickedLoad = transport.load
                Task { _ = await self.run(.play, on: page) }
            }
        }
    }
    public func pageCommitted(document: UInt64?) {
        guard let document else {
            // A document native code did not reserve (a page reload or self-navigation):
            // it cannot report and has no play intent, so stop visibly.
            committedDocument = 0
            if page != nil, !closed, transport.load > 0, !transport.snapshot.isFailed { fail(.pageReplaced) }
            return
        }
        // An older reserved document committing late is simply not trusted.
        committedDocument = document == transport.document ? document : 0
    }
    public func pageFailed(_ failure: WebMusicFailure) {
        guard !closed else { return }
        fail(failure)
    }
    public func pageCookiesChanged(_ cookies: [HTTPCookie]) {
        guard !closed, page != nil else { return }
        let changed = cookies.filter { cookieBaseline[$0.name] != Self.fingerprint($0) }
        guard !changed.isEmpty else { return }
        for cookie in changed { pendingRotation[cookie.name] = cookie; cookieBaseline[cookie.name] = Self.fingerprint(cookie) }
        rotation?.cancel()
        rotation = Task { [weak self, rotationDelay, source = self.cookies] in
            try? await Task.sleep(for: rotationDelay)
            guard !Task.isCancelled, let self, !self.closed else { return }
            let batch = Array(self.pendingRotation.values); self.pendingRotation = [:]
            guard !batch.isEmpty else { return }
            await source.recordRotation(batch)
        }
    }
    static func fingerprint(_ cookie: HTTPCookie) -> String {
        "\(cookie.value)\u{0}\(cookie.expiresDate?.timeIntervalSince1970 ?? 0)"
    }
    static func baseline(_ cookies: [HTTPCookie]) -> [String: String] {
        Dictionary(cookies.map { ($0.name, fingerprint($0)) }, uniquingKeysWith: { _, last in last })
    }

    private func publish() {
        let full = transport.snapshot
        let previousArtwork = snapshot.artworkURL
        var coarse = full; coarse.position = 0
        // The position is zeroed above so a clock tick leaves `coarse` equal to what is shown;
        // writing only on a difference states that rule and does not depend on Observation
        // skipping equal writes of an Equatable value.
        if coarse != snapshot { snapshot = coarse }
        timeline.update(full.position, behindLive: transport.behindLive)
        // P5-2: the App Nap activity is held only while the page is loading, buffering
        // or playing (an ad counts as playing), never while it merely sits paused/ended.
        let active = [WebMusicPhase.loading, .buffering, .playing].contains(full.phase) || full.isAd
        let wantsActivity = !closed && full.intent && !full.isFailed && active
        if wantsActivity, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Playing YouTube Music")
        } else if !wantsActivity, let current = activity {
            ProcessInfo.processInfo.endActivity(current); activity = nil
        }
        updateThrottle(full)
        if full.artworkURL != previousArtwork { fetchArtwork(full.artworkURL) }
        onChange?(full, artwork)
    }
    /// P5-1: while the page is paused or ended (and plays no ad) it may be throttled, even when YouTube
    /// paused it by itself and the intent is still to play; any phase that plays or is about to play, and
    /// every command that could make it play, turns the policy back to `.none` first.
    private func updateThrottle(_ full: WebMusicSnapshot) {
        setThrottle(!closed && !full.isAd && !full.isFailed && (full.phase == .paused || full.phase == .ended))
    }
    private func setThrottle(_ on: Bool) {
        guard on != throttled else { return }
        throttled = on
        page?.setThrottled(on)
    }
    private func fetchArtwork(_ url: URL?) {
        artworkTask?.cancel(); artwork = nil
        guard let url else { return }
        artworkTask = Task { [weak self, loader = artworkLoader] in
            let data = await loader.artwork(url)
            guard !Task.isCancelled, let self, self.snapshot.artworkURL == url else { return }
            self.artwork = data
            self.onChange?(self.transport.snapshot, data)
        }
    }
}
