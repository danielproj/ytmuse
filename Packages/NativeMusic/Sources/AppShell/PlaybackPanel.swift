import SwiftUI
import AppKit
import Synchronization
import Observation
import Domain
import DesignSystem
import Playback
import Queue
import Persistence
import AccountSession
import Downloads
import Features
import SystemIntegration
import Diagnostics

/// Account detach is a barrier even for a pending owned-media initialization.
/// This actor is the single playback owner (PLAY01): at most one of the owned
/// test-audio session or the hidden YouTube Music player exists at a time, and
/// every account barrier tears down whichever one is present.
actor AppPlaybackAuthority: AccountLifecycleParticipant {
    nonisolated let participantID = "single-playback-owner"
    private let directory: URL?
    private let beforeOpen: (@Sendable () async -> Void)?
    private let beforeTeardown: (@Sendable () async -> Void)?
    private let offlineVault: (any ScopedProtectedRecords)?
    private nonisolated let starts = OwnedStartGate()
    // Read-only control tickets share the account barrier, without issuing an owned-start permit.
    private nonisolated let radioControlEpoch = Mutex<UInt64>(0)
    nonisolated func currentRadioControlEpoch() -> UInt64 { radioControlEpoch.withLock { $0 } }
    private nonisolated func invalidateRadioControls() { radioControlEpoch.withLock { $0 &+= 1 } }
    /// W22 (DATA03): told at every account barrier (switch, sign-out, removal, quit) so a held Play here prompt does not outlive the account that raised it.
    /// W23: several parties need the barrier (the output coordinator's held prompts, Now Playing), so handlers add up; each runs at every barrier.
    private nonisolated let barrierHandlers = Mutex<[@Sendable () async -> Void]>([])
    nonisolated func onBarrier(_ handler: @escaping @Sendable () async -> Void) { barrierHandlers.withLock { $0.append(handler) } }
    /// W25 (MAC05, MAC06): what an account barrier IS, captured BEFORE the owner clears its live account. The plain handlers above run after the account is cleared (the
    /// owner clears `musicContext` first), so they cannot tell who is leaving; a listener that must remove the departing account's data needs this event instead.
    struct BarrierEvent: Sendable {
        enum Reason: Sendable { case quit, detach, removal }
        let reason: Reason
        /// The account and session that were live (or, for a removal, that are being removed). Nil when nobody was bound.
        let departing: (account: UUID, generation: UInt64)?
    }
    private nonisolated let eventHandlers = Mutex<[@Sendable (BarrierEvent) async -> Void]>([])
    nonisolated func onBarrierEvent(_ handler: @escaping @Sendable (BarrierEvent) async -> Void) { eventHandlers.withLock { $0.append(handler) } }
    /// Told after an account becomes the live one (sign-in, switch, restore), so a surface that shows nothing without an account can show it.
    private nonisolated let boundHandlers = Mutex<[@Sendable () async -> Void]>([])
    nonisolated func onScopeBound(_ handler: @escaping @Sendable () async -> Void) { boundHandlers.withLock { $0.append(handler) } }
    private func runBarrierHandlers(_ event: BarrierEvent? = nil) async {
        for handler in barrierHandlers.withLock({ $0 }) { await handler() }
        if let event { for handler in eventHandlers.withLock({ $0 }) { await handler(event) } }
    }
    /// Debug QA isolation was requested for this process (always false in Release).
    private let isolationRequested: Bool
    init(directory: URL? = nil, beforeOpen: (@Sendable () async -> Void)? = nil, beforeTeardown: (@Sendable () async -> Void)? = nil, offlineVault: (any ScopedProtectedRecords)? = nil,
         makeMusicPage: (@MainActor (any WebMusicPageDelegate) -> any WebMusicPage)? = nil, isolationRequested: Bool = AppPlaybackAuthority.processIsolationRequested,
         makeSleepTiming: (@MainActor () -> any SleepTimerTiming)? = nil) {
        self.directory = directory; self.beforeOpen = beforeOpen; self.beforeTeardown = beforeTeardown; self.offlineVault = offlineVault
        self.makeMusicPage = makeMusicPage; self.isolationRequested = isolationRequested; self.makeSleepTiming = makeSleepTiming
    }
    /// Test seam: the hidden player's sleep-timer clocks (P17-WEB). Nil uses the real ones.
    private let makeSleepTiming: (@MainActor () -> any SleepTimerTiming)?
    static var processIsolationRequested: Bool {
        #if DEBUG
        IsolatedQAStorage.requested() || runningUnderTestHarness
        #else
        false
        #endif
    }
    #if DEBUG
    /// A unit-test process must never resolve a production default either: an authority
    /// built without its own directory and vault would open the real owned-audio store
    /// and the production login-Keychain item. Under XCTest/Swift Testing the same
    /// refusal as QA isolation applies, so such a test fails loudly instead of reading
    /// (or on a fresh machine creating) the account holder's records.
    static var runningUnderTestHarness: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }
    #endif
    /// Under QA isolation an owned start never resolves a production default (the real
    /// owned-audio directory or the login-Keychain vault); it is refused before any I/O.
    static func refusesProductionDefaults(directory: URL?, hasVault: Bool, isolationRequested: Bool) -> Bool {
        isolationRequested && (directory == nil || !hasVault)
    }
    func retainedStoreID() -> ObjectIdentifier? { retained.map(ObjectIdentifier.init) }
    /// Where an owned start would open its store and protected records (nil = production defaults).
    func ownedStorageBinding() -> (directory: URL?, vault: ObjectIdentifier?) { (directory, offlineVault.map { ObjectIdentifier($0) }) }
    nonisolated func requestOwnedStart() -> OwnedStartRequest { starts.capture() }
    private var revision: UInt64 = 0
    private var retained: EncryptedStore?
    private var session: PlaybackSession?
    private var music: WebMusicPlayer?
    /// The active identity's generation, recorded on restore (always paused).
    private var musicContext: RequestContext?
    private var musicCookies: (@Sendable (RequestContext) -> any WebMusicCookieSource)?
    /// Test seam: the hidden page factory. Nil uses the real WebKit page.
    private let makeMusicPage: (@MainActor (any WebMusicPageDelegate) -> any WebMusicPage)?
    /// Composition supplies how the active account's Keychain session reaches the player.
    func configureMusic(_ cookies: @escaping @Sendable (RequestContext) -> any WebMusicCookieSource) { musicCookies = cookies }
    func musicAvailable() -> Bool { musicContext != nil && musicCookies != nil }
    /// W24: the account and generation the live YouTube Music session is bound to; nil before a restore, after sign-out and while no account is connected.
    func activeScope() -> (account: UUID, generation: UInt64)? {
        guard let context = musicContext, let account = context.account else { return nil }
        return (account.accountID, context.accountGeneration)
    }
    func currentMusic() -> WebMusicPlayer? { music }
    /// The account the hidden player is bound to (nil before a restore and after sign-out), for the account-scoped resume record.
    func activeAccountID() -> UUID? { musicContext?.account?.accountID }
    /// Returns the YouTube Music player for the active account, creating it (but
    /// loading nothing) on an explicit user request. Closes owned test audio first.
    func youtubeMusic(request: OwnedStartRequest) async throws -> WebMusicPlayer {
        guard starts.accepts(request), let context = musicContext, let makeCookies = musicCookies else { throw DomainError.staleContext }
        if let music, await !music.isClosed { return music }
        revision += 1; let ticket = revision
        let oldRetained = retained; retained = nil
        let oldSession = session; session = nil
        if oldSession != nil || oldRetained != nil { await beforeTeardown?() }
        await oldRetained?.bind(RequestContext(account: nil, accountGeneration: ticket, requestGeneration: 0))
        await oldSession?.close(reason: .accountSwitch)
        guard starts.accepts(request), revision == ticket, musicContext == context else { throw DomainError.staleContext }
        let source = makeCookies(context)
        let factory = makeMusicPage, timing = makeSleepTiming
        let player = await MainActor.run {
            let clocks: any SleepTimerTiming = timing?() ?? SystemSleepTimerTiming()
            return if let factory { WebMusicPlayer(cookies: source, sleepTiming: clocks, makePage: factory) } else { WebMusicPlayer(cookies: source, sleepTiming: clocks) }
        }
        // An account barrier may have passed while the player was being built.
        guard starts.accepts(request), musicContext == context, music == nil else { await player.teardown(); throw DomainError.staleContext }
        music = player
        return player
    }
    private func dropMusic() async {
        let old = music; music = nil
        await old?.teardown()
    }
    /// W21: sleep, wake, lock and display sleep are handled by the shell's power lifecycle (`PowerLifecycleCoordinator`), which holds and resumes
    /// both engines through `PlaybackModel`; the owner itself no longer listens.
    /// W39 (ROUTE10): run first on an explicit quit, before the barrier handlers; the output controller stops (or leaves) a Cast receiver here, bounded.
    private var beforeQuit: (@MainActor () async -> Void)?
    func setBeforeQuit(_ work: (@MainActor () async -> Void)?) { beforeQuit = work }
    func quit() async {
        let departing = activeScope()
        starts.invalidate(); invalidateRadioControls(); revision += 1; musicContext = nil
        // ROUTE10: a Cast receiver is stopped (or left) by the remembered Quit plan, bounded, before anything else is torn down.
        await beforeQuit?()
        await runBarrierHandlers(BarrierEvent(reason: .quit, departing: departing))
        await dropMusic()
        let old = session; session = nil
        let oldRetained = retained; retained = nil
        let barrier = RequestContext(account: nil, accountGeneration: revision, requestGeneration: 0)
        if old != nil || oldRetained != nil { await beforeTeardown?() }
        await oldRetained?.bind(barrier)
        await old?.close()
    }

    /// W27: where the owned-audio store lives (its SQLite file and encrypted retained objects). The injected directory, or the production one.
    nonisolated var ownedAudioDirectory: URL {
        directory ?? ((try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)) ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("local.native-music.owned-audio")
    }
    /// The Keychain namespace the owned-audio vault uses: the injected vault's, or the production one.
    nonisolated var ownedKeychainNamespace: String { (offlineVault as? KeychainVault)?.serviceNamespace ?? KeychainVault.applicationNamespace }
    /// W27 (privacy reset): closes the native sessions, removes the owned-audio store's files and its Keychain items. Local only.
    func eraseOwnedAudio() async throws {
        revision += 1; starts.invalidate(); invalidateRadioControls()
        let oldRetained = retained; retained = nil
        let oldSession = session; session = nil
        await oldRetained?.bind(RequestContext(account: nil, accountGeneration: revision, requestGeneration: 0))
        await oldSession?.close(reason: .accountSwitch)
        let directory = ownedAudioDirectory
        try GuardedFiles(root: directory).remove(directory, allowRoot: true)
        let vault: (any SessionVault)? = (offlineVault as? any SessionVault) ?? (try? KeychainVault())
        try await vault?.deleteAll(for: OwnedMedia.account)
    }
    func owned(request: OwnedStartRequest, initialGain: Double = 0.08, maximumStartGain: Float? = nil) async throws -> PlaybackSession {
        if Self.refusesProductionDefaults(directory: directory, hasVault: offlineVault != nil, isolationRequested: isolationRequested) { throw DomainError.forbidden }
        guard starts.accepts(request) else { throw DomainError.staleContext }
        invalidateRadioControls()
        revision += 1; let ticket = revision
        if let beforeOpen { await beforeOpen() }
        guard starts.accepts(request), revision == ticket else { throw DomainError.staleContext }
        await dropMusic()
        let oldRetained = retained; retained = nil
        let oldSession = session; session = nil
        if oldSession != nil || oldRetained != nil { await beforeTeardown?() }
        await oldRetained?.bind(RequestContext(account: nil, accountGeneration: ticket, requestGeneration: 0))
        await oldSession?.close(reason: .accountSwitch)
        let context = RequestContext(account: OwnedMedia.account, accountGeneration: ticket, requestGeneration: 0)
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let store = try SQLiteStore(directory: directory ?? base.appendingPathComponent("local.native-music.owned-audio"), context: context)
        try await store.saveAccount(Account(id: OwnedMedia.account.accountID, serviceIdentity: ServiceID("owned-test-only"), context: OwnedMedia.account, displayName: OwnedMedia.label, credential: nil), context: context)
        let media = OwnedMedia()
        let offline: EncryptedStore?
        let assets: any NativeAssetProvider
        do {
            let vault: any ScopedProtectedRecords
            if let offlineVault { vault = offlineVault } else { vault = try KeychainVault() }
            let candidate = try EncryptedStore(root: (directory ?? base.appendingPathComponent("local.native-music.owned-audio")).appendingPathComponent("retained"), vault: vault)
            offline = candidate; assets = LocalFirstOwnedAssets(store: candidate, fallback: media)
        } catch {
            // This independent bundled-owned license is unrelated to retained/source rights.
            // Only optional store initialization is recoverable here; provider failures propagate.
            offline = nil; assets = media
        }
        await offline?.bind(context)
        let new = try await PlaybackSession.open(context: context, persistence: SQLiteQueuePersistence(store: store), assets: assets, resolver: media, capabilities: media, initialGain: initialGain, maximumStartGain: maximumStartGain)
        guard ticket == revision, starts.accepts(request) else { await offline?.bind(RequestContext(account: nil, accountGeneration: max(ticket, revision), requestGeneration: 0)); await new.close(reason: .accountSwitch); throw DomainError.staleContext }
        retained = offline; session = new; return new
    }
    /// Plays a kept item from the encrypted store through the native session (PLAY01: the same single owner, never alongside the
    /// hidden player). The queue is in memory only; nothing here reaches a service.
    func retained(request: OwnedStartRequest, parts: RetainedPlaybackParts, context: RequestContext, initialGain: Double, maximumStartGain: Float?) async throws -> PlaybackSession {
        guard starts.accepts(request), context.account != nil else { throw DomainError.staleContext }
        invalidateRadioControls()
        revision += 1; let ticket = revision
        await dropMusic()
        let oldRetained = retained; retained = nil
        let oldSession = session; session = nil
        if oldSession != nil || oldRetained != nil { await beforeTeardown?() }
        await oldRetained?.bind(RequestContext(account: nil, accountGeneration: ticket, requestGeneration: 0))
        await oldSession?.close(reason: .accountSwitch)
        guard starts.accepts(request), revision == ticket else { throw DomainError.staleContext }
        let new = try await PlaybackSession.open(context: context, persistence: MemoryQueuePersistence(), assets: parts.assets, resolver: parts.playback, capabilities: parts.playback, initialGain: initialGain, maximumStartGain: maximumStartGain)
        guard ticket == revision, starts.accepts(request) else { await new.close(reason: .accountSwitch); throw DomainError.staleContext }
        session = new; return new
    }
    func detach(previous: RequestContext, barrier: RequestContext) async throws {
        let departing = activeScope() ?? previous.account.map { ($0.accountID, previous.accountGeneration) }
        starts.invalidate(); invalidateRadioControls(); revision += 1; musicContext = nil
        await runBarrierHandlers(BarrierEvent(reason: .detach, departing: departing))
        // Switch, sign-out and removal stop the hidden player and discard its store.
        await dropMusic()
        let old = session; session = nil
        let oldRetained = retained; retained = nil
        let barrier = RequestContext(account: nil, accountGeneration: revision, requestGeneration: 0)
        if old != nil || oldRetained != nil { await beforeTeardown?() }
        await oldRetained?.bind(barrier)
        await old?.close(reason: .accountSwitch)
    }
    /// Records the restored identity only; nothing is created, loaded or played.
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {
        if musicContext != context { invalidateRadioControls() }
        musicContext = identity.state == .connected && context.account == identity.id ? context : nil
        if musicContext != nil { for handler in boundHandlers.withLock({ $0 }) { await handler() } }
    }
    func removeLocal(_ account: AccountContext, context: RequestContext) async throws {
        let live = activeScope()
        await runBarrierHandlers(BarrierEvent(reason: .removal, departing: (account.accountID, live?.account == account.accountID ? live!.generation : context.accountGeneration)))
        if musicContext?.account == account { musicContext = nil; await dropMusic() }
    }
}
actor MemoryQueuePersistence: QueuePersistence {
    private var state: QueueSnapshot?
    func load(context: RequestContext) -> QueueSnapshot? { state }
    func save(_ snapshot: QueueSnapshot, context: RequestContext) { state = snapshot }
}
enum PlaybackUIAction: Equatable, Sendable {
    case transport, previous, next, seek, volume, mute, selectQueue, reorderQueue, shuffle, repeatMode, sleepTimer
    var failure: String {
        switch self {
        case .transport: String(localized: "Playback could not change. Try the transport action again.")
        case .previous: String(localized: "The previous item could not open. Try Previous again.")
        case .next: String(localized: "The next item could not open. Try Next again.")
        case .seek: String(localized: "The playback position could not change. Try seeking again.")
        case .volume: String(localized: "App volume could not change. Try adjusting volume again.")
        case .mute: String(localized: "Mute could not change. Try the mute action again.")
        case .selectQueue: String(localized: "The selected queue item could not open. Try selecting it again.")
        case .reorderQueue: String(localized: "The queue could not be reordered. Check the editable items and try again.")
        case .shuffle: String(localized: "Shuffle could not change. Try the shuffle action again.")
        case .repeatMode: String(localized: "Repeat could not change. Try the repeat action again.")
        case .sleepTimer: String(localized: "The sleep timer could not change. Try setting the timer again.")
        }
    }
}
@MainActor @Observable final class PlaybackModel {
    let authority: AppPlaybackAuthority
    let controlledAudioTest: Bool
    let gainRange: ClosedRange<Double>
    private let initialGain: Double
    var requestedGain: Double
    private var gainRevision: UInt64 = 0
    private var applyingGain: UInt64?
    init(authority: AppPlaybackAuthority = AppPlaybackAuthority(), controlledAudioTest: Bool = ProcessInfo.processInfo.environment["YTMUSE_OWNED_AUDIO_TEST_GAIN"] == "0.001",
         nowPlaying: NowPlayingCenter? = nil) {
        self.authority = authority; self.controlledAudioTest = controlledAudioTest
        initialGain = controlledAudioTest ? 0.001 : 0.08
        requestedGain = initialGain; gainRange = 0...(controlledAudioTest ? 0.001 : 1)
        // W23: a unit-test process never takes the Mac's media keys or Now Playing (it gets a recording stand-in); the app takes the real ones.
        // An isolated UI launch is the same: the recording stand-in, so a test run never holds the account holder's media keys.
        #if DEBUG
        let recorder = Self.recorder(isolatedLaunch: IsolatedQAStorage.requested(), testHarness: AppPlaybackAuthority.runningUnderTestHarness)
        nowPlayingRecorder = recorder
        let system = recorder?.system ?? NowPlayingSystem.live
        #else
        let system = NowPlayingSystem.live
        #endif
        self.nowPlaying = nowPlaying ?? NowPlayingCenter(system: system)
        // Every account barrier (switch, sign-out, removal, quit) lets go of the media keys and clears Now Playing in that same step, before the old
        // item can be read by anything; the old session's own teardown notification would only arrive later, and not at all with no window open.
        authority.onBarrier { [weak self] in await MainActor.run { self?.accountBarrierForNowPlaying() } }
    }
    /// W27: the audio effects (crossfade, equalizer, normalization) the person chose, applied to every NATIVE session as it starts. The hidden YouTube Music
    /// player is never processed. nil: nothing chosen.
    @ObservationIgnored var effectsProvider: (@MainActor () -> AudioEffects?)?
    /// W27: where a fault is recorded for Diagnostics: a category, a component name and a detail (redacted by the log).
    @ObservationIgnored var faultSink: (@MainActor (DiagnosticCategory, String, String) -> Void)?
    /// W27 (DIAG02): where a timing is recorded. A no-op unless the person turned profiling on.
    @ObservationIgnored var profileSink: (@MainActor (ProfileEvent, Double) -> Void)?
    func applyChosenEffects(to player: PlaybackSession) async {
        guard let effects = effectsProvider?(), !effects.bypass else { return }
        do { try await player.configureEffects(effects) } catch { faultSink?(.playbackFailure, "audio", "effects not applied") }
    }
    /// W27 (Restore session, default on): false leaves the last session unrestored at launch.
    @ObservationIgnored var restoreEnabled: @MainActor () -> Bool = { true }
    /// W27 (Replace explicit queue, default Ask): what to do with songs the person queued themselves when a new native context starts. YouTube Music keeps its own queue.
    @ObservationIgnored var replacementPreference: @MainActor () -> ReplacementPreference = { .ask }
    /// A native start that is waiting for the person to say Keep or Replace. The Browser shell shows the question while this is set.
    struct PendingReplacement { let count: Int; let resume: @MainActor (ReplacementPreference) async -> Void }
    private(set) var pendingReplacement: PendingReplacement?
    @ObservationIgnored private var replacementOverride: ReplacementPreference?
    /// The songs the person queued in the open native session (Play next, Add to queue), in order, excluding the one playing.
    func explicitQueuedMedia() async -> [ServiceID] {
        guard let snapshot = try? await session?.snapshot() else { return [] }
        return snapshot.queue.session.entries.filter { !$0.consumed && $0.id != snapshot.queue.session.currentOccurrence && [.user, .playNext, .addToQueue].contains($0.segment) }.map(\.media)
    }
    /// What a native start does about queued songs: nil to go ahead (replacing or nothing queued), the songs to carry for Keep; or waits for the person for Ask.
    private func settleReplacement(retry: @escaping @MainActor (ReplacementPreference) async -> Void) async -> (proceed: Bool, carry: [ServiceID]) {
        let queued = await explicitQueuedMedia()
        guard !queued.isEmpty else { replacementOverride = nil; return (true, []) }
        let choice = replacementOverride ?? replacementPreference(); replacementOverride = nil
        switch choice {
        case .replace: return (true, [])
        case .keep: return (true, queued)
        case .ask: pendingReplacement = PendingReplacement(count: queued.count, resume: retry); return (false, [])
        }
    }
    /// The person's answer. Flips the state synchronously (a confirmation dialog dismisses before any Task its button starts would run), then restarts.
    func resolveReplacement(_ choice: ReplacementPreference) {
        guard let pending = pendingReplacement else { return }
        pendingReplacement = nil; replacementOverride = choice
        Task { await pending.resume(choice) }
    }
    /// Test seam: sets the question as a native start would. TH5: Debug only, like every test hook (it is not in a Release binary).
    #if DEBUG
    func setPendingReplacementForTest(count: Int, resume: @escaping @MainActor (ReplacementPreference) -> Void) { pendingReplacement = PendingReplacement(count: count, resume: { resume($0) }) }
    #endif
    func cancelReplacement() { guard pendingReplacement != nil else { return }; pendingReplacement = nil; replacementOverride = nil }
    @ObservationIgnored private var lastReportedNotice: WebMusicFailure?
    var session: PlaybackSession? {
        didSet {
            guard oldValue !== session else { return }
            oldValue?.setChangeObserver(nil)
            // W23 (R2-1): the session's own events (an item ended, the next one started, a failure) keep Now Playing right with NO window, popover or
            // mini-player open. The UI observer below is for drawing; ownership of the keys does not depend on it.
            session?.setChangeObserver { [weak self] in Task { @MainActor in self?.nativeSessionChanged() } }
        }
    }
    @ObservationIgnored private var nativeSyncRunning = false
    @ObservationIgnored private var nativeSyncAgain = false
    /// Reads the session once per burst of events (coalesced) and publishes it.
    func nativeSessionChanged() {
        guard session != nil, music == nil else { return }
        if nativeSyncRunning { nativeSyncAgain = true; return }
        nativeSyncRunning = true
        Task { [weak self] in
            repeat {
                self?.nativeSyncAgain = false
                await self?.refresh()
            } while self?.nativeSyncAgain == true
            self?.nativeSyncRunning = false
        }
    }
    /// W22: the output coordinator and its engine adapters (nil in a test that does not need them: no route gating then).
    var outputs: OutputController?
    /// W21: what the last system sleep held, until the matching wake settles it (see `PowerTransporting`).
    @ObservationIgnored var sleepHold: PowerSleepHold?
    /// W21: the window-visibility gate treats a hidden display like a hidden window.
    @ObservationIgnored var displayActive = true
    /// W21: persists what a cold launch restores (set by the composition); run before the system sleeps.
    @ObservationIgnored var checkpointForSleep: (@MainActor () async -> Void)?
    /// W21 (WIN09): this Mac's record of the last YouTube Music session, bound once the account directory is known.
    @ObservationIgnored var resumeStore: (any MusicResumeStoring)?
    @ObservationIgnored var resumePolicy = MusicResumePolicy()
    /// W17: the native (AVKit) video surface for owned/local media, and the windows for both kinds of picture.
    let nativeVideo = NativeVideoPresenter()
    @ObservationIgnored let webVideoWindows = WebVideoWindows()
    @ObservationIgnored let nativeVideoWindows = NativeVideoWindows()
    func showVideoWindow() { if let music, music.canShowVideo { webVideoWindows.show(player: music) } }
    func showNativeVideoWindow() { if nativeVideo.hasPicture { nativeVideoWindows.show(model: self) } }
    var state: PlaybackSessionSnapshot? {
        didSet {
            // Told only when the item changes, never on position ticks (the Downloads engine ranks the playing item first).
            let media = state?.queue.current?.media
            guard media != reportedMedia else { return }
            reportedMedia = media; currentItemChanged?(media)
        }
    }
    @ObservationIgnored private var reportedMedia: ServiceID?
    @ObservationIgnored var currentItemChanged: (@MainActor (ServiceID?) -> Void)?
    var error: String?
    var titles: [ServiceID: String] = [:]
    var failedAction: PlaybackUIAction?
    private var retryOperation: (@Sendable (PlaybackSession) async throws -> Void)?
    private var failedSession: PlaybackSession?
    var canRetryAction: Bool { retryOperation != nil && failedSession === session }
    var currentTitle: String {
        if let music, music.snapshot.phase != .idle { return music.snapshot.title ?? music.snapshot.playlistTitle ?? "YouTube Music" }
        return state?.queue.current.map { title(for: $0.media) } ?? String(localized: "Nothing playing")
    }
    func title(for media: ServiceID) -> String {
        if let supplied = titles[media], !supplied.isEmpty { return supplied }
        return String(localized: "Untitled item")
    }
    func retryFailedAction() async {
        guard canRetryAction, let operation = retryOperation, let failedAction else { return }
        await act(action: failedAction, operation)
    }
    var starting = false
    var pending = false
    func startOwned(request: OwnedStartRequest) async {
        // ROUTE09: a new item after a route loss plays on this Mac's current output; the loss already paused what was playing.
        await outputs?.coordinator.acceptCurrentOutput(for: .localMedia)
        let replacement = await settleReplacement(retry: { [weak self] _ in await self?.startOwned(request: request) })
        guard replacement.proceed else { return }
        guard !starting else { return }; error = nil; failedAction = nil; retryOperation = nil; failedSession = nil; starting = true; defer { starting = false }
        let startSignpost = PerformanceSignposts.begin(.firstItemStart, label: "owned")
        defer { PerformanceSignposts.end(startSignpost, failed: error != nil) }
        let carried = sleepTimerToCarry(leavingYouTubeMusic: true)   // P17-WEB: one timer for the session; read before the hidden player is closed
        if let outputs, await outputs.coordinator.beginHandoff(to: .localMedia) == .refused { self.error = String(localized: "The other player could not be stopped. Try Play again."); return }
        do {
            let player = try await authority.owned(request: request, initialGain: initialGain, maximumStartGain: controlledAudioTest ? 0.001 : nil); session = player
            await outputs?.attach(player)
            await applyChosenEffects(to: player)
            titles[OwnedMedia.items[0]] = String(localized: "Owned test tone A")
            titles[OwnedMedia.items[1]] = String(localized: "Owned test tone B")
            await reconcileMusic()
            try await player.startOwnedMedia(OwnedMedia.items)
            if !replacement.carry.isEmpty { try? await player.sendQueue(.add(replacement.carry)) }
            if let carried { try? await player.setTimer(carried) }
            await refresh()
        } catch DomainError.staleContext { error = nil; await refresh() }
        catch { self.error = String(localized: "Owned test audio could not start. Use the test audio button to try again."); await refresh() }
    }
    /// Plays a kept (downloaded) item through the native session, with Now Playing and media keys. False when it could not start.
    func playKept(_ item: PlayableDownload, parts: RetainedPlaybackParts) async -> Bool {
        await outputs?.coordinator.acceptCurrentOutput(for: .localMedia)
        return await playKeptAdmitted(item, parts: parts, request: authority.requestOwnedStart())
    }
    private func playKeptAdmitted(_ item: PlayableDownload, parts: RetainedPlaybackParts, request: OwnedStartRequest) async -> Bool {
        let replacement = await settleReplacement(retry: { [weak self] _ in _ = await self?.playKeptAdmitted(item, parts: parts, request: request) })
        guard replacement.proceed else { return false }
        guard !starting else { return false }; error = nil; failedAction = nil; retryOperation = nil; failedSession = nil; starting = true; defer { starting = false }
        let carried = sleepTimerToCarry(leavingYouTubeMusic: true)
        if let outputs, await outputs.coordinator.beginHandoff(to: .localMedia) == .refused { self.error = String(localized: "The other player could not be stopped. Try Play again."); return false }
        do {
            let player = try await authority.retained(request: request, parts: parts, context: item.context, initialGain: initialGain, maximumStartGain: controlledAudioTest ? 0.001 : nil); session = player
            await outputs?.attach(player)
            await applyChosenEffects(to: player)
            titles[item.media] = item.title
            await reconcileMusic()
            try await player.startOwnedMedia([item.media])
            if !replacement.carry.isEmpty { try? await player.sendQueue(.add(replacement.carry)) }
            if let carried { try? await player.setTimer(carried) }
            await refresh(); return true
        } catch DomainError.staleContext { error = nil; await refresh(); return false }
        catch { self.error = String(localized: "That download could not play. Try Play again, or download it again."); await refresh(); return false }
    }
    /// Debug-only: the owned synthetic video (video-only, silent) through the native AVKit path.
    func startOwnedVideo(request: OwnedStartRequest) async {
        await outputs?.coordinator.acceptCurrentOutput(for: .localMedia)
        guard !starting else { return }; error = nil; failedAction = nil; retryOperation = nil; failedSession = nil; starting = true; defer { starting = false }
        let carried = sleepTimerToCarry(leavingYouTubeMusic: true)
        if let outputs, await outputs.coordinator.beginHandoff(to: .localMedia) == .refused { self.error = String(localized: "The other player could not be stopped. Try Play again."); return }
        do {
            let player = try await authority.owned(request: request, initialGain: initialGain, maximumStartGain: controlledAudioTest ? 0.001 : nil); session = player
            await outputs?.attach(player)
            titles[OwnedMedia.videoItem] = String(localized: "Owned test video")
            await reconcileMusic()
            #if DEBUG
            try await player.startVideoMeasurement()
            #endif
            try await player.startOwnedMedia([OwnedMedia.videoItem])
            if let carried { try? await player.setTimer(carried) }
            await refresh()
        } catch DomainError.staleContext { error = nil; await refresh() }
        catch { self.error = String(localized: "Owned test video could not start. Use the test video button to try again."); await refresh() }
    }
    var timeline = PlaybackTimelineModel()
    private var lastPresentation: PlaybackPresentation?
    private var refreshRevision: UInt64 = 0
    private var observers: Set<UUID> = []
    private var observation: Task<Void, Never>?
    var isObservingUI: Bool { observation != nil }
    var visibleUIObserverCount: Int { observers.count }
    func observe(_ id: UUID, visible: Bool) {
        if visible { observers.insert(id) } else { observers.remove(id) }
        // The YouTube Music clock publishes only while a window is visible.
        music?.timeline.setObserving(!observers.isEmpty)
        if observers.isEmpty { observation?.cancel(); observation = nil }
        else if observation == nil {
            observation = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                }
            }
        }
    }
    func refresh() async {
        refreshRevision += 1; let refreshTicket = refreshRevision
        music?.refreshVideoActivity()
        if let session {
            if await session.isClosed() { self.session = nil; fencedNativeSession = nil; outputs?.sessionEnded(); state = nil; timeline.snapshot = nil; lastPresentation = nil; error = nil; endNativeVideo(); if music == nil { endNowPlaying() } }
            else {
                let revision = gainRevision
                let snapshot = try? await session.snapshot()
                let old = lastPresentation
                let compared = await Task.detached(priority: .utility) {
                    guard let snapshot else { return (nil as PlaybackPresentation?, false) }
                    let next = PlaybackPresentation(snapshot)
                    return (next, next != old)
                }.value
                guard refreshTicket == refreshRevision, self.session === session, !(await session.isClosed()) else { return }
                timeline.snapshot = snapshot
                if let snapshot { outputs?.observeNativePosition(snapshot.playback.position); outputs?.nativeRefreshed() }
                // ROUTE09: while a receiver plays, the position shown is the receiver's own last report (nil: none fresh), never the local clock.
                timeline.receiver = outputs?.remoteReading()
                if let snapshot, timeline.receiver == nil { publishNativeNowPlaying(snapshot) }
                else if let snapshot, let reading = timeline.receiver ?? nil { publishNativeNowPlaying(snapshot, elapsed: reading) }
                nativeVideo.update(await session.videoHandle())
                #if DEBUG
                nativeVideo.updateFrames(await session.videoFramesDelivered())
                #endif
                if compared.1 { state = snapshot; lastPresentation = compared.0 }
                if revision == gainRevision, applyingGain == nil, let snapshot { requestedGain = snapshot.gain }
            }
        }
    }
    /// TH4 (rework of M1): what the volume slider shows and drives. WHILE an owned or local item is cast it is the receiver's own reported level, separate from the
    /// Mac's app gain (`requestedGain`), which is neither read nor changed then: ending the cast leaves the Mac's volume exactly as it was.
    struct VolumeSlider: Equatable {
        var level: Double
        var range: ClosedRange<Double>
        var isReceiver: Bool
        var isEnabled: Bool
        /// Why the slider is disabled, when it is a receiver that cannot take a level.
        var disabledReason: String?
    }
    var volumeSlider: VolumeSlider {
        if let cast = outputs?.castVolume {
            let reason: String? = switch cast.unavailable {
            case nil: nil
            case .notReported?: String(localized: "Waiting for the receiver's volume.")
            case .fixed?: String(localized: "This receiver's volume is fixed.")
            case .unsupported?: String(localized: "This receiver can't change its volume from here.")
            }
            return VolumeSlider(level: cast.level, range: 0...1, isReceiver: true, isEnabled: cast.isAdjustable, disabledReason: reason)
        }
        return VolumeSlider(level: requestedGain, range: gainRange, isReceiver: false, isEnabled: true, disabledReason: nil)
    }
    /// Every surface that moves the volume (bottom player, mini-player, status item, scripting) comes through here for the native session.
    func setSliderVolume(_ value: Double) {
        guard value.isFinite else { return }
        if outputs?.castVolume != nil { outputs?.requestCastVolume(value); return }
        changeGain(min(max(value, gainRange.lowerBound), gainRange.upperBound))
    }
    func changeGain(_ value: Double) {
        requestedGain = value; gainRevision += 1; let ticket = gainRevision; applyingGain = ticket
        Task {
            guard ticket == gainRevision, let session else { return }
            do { try await session.setGain(value) }
            catch { if ticket == gainRevision { self.error = PlaybackUIAction.volume.failure; failedAction = .volume; retryOperation = nil; failedSession = nil } }
            if ticket == gainRevision { applyingGain = nil; await refresh() }
        }
    }
    // MARK: YouTube Music (hidden player behind the same single owner)

    /// The active account's YouTube Music player, once the user has pressed Play.
    var music: WebMusicPlayer?
    /// Receives every published reading of the player (the local listening history follows real progress through this).
    @ObservationIgnored var listening: (@MainActor (WebMusicSnapshot) -> Void)?
    /// Receives every published reading of the player, for the podcast controls (speed for the item that plays, resume, episode progress).
    @ObservationIgnored var episodeObserver: (@MainActor () -> Void)?
    /// W23: the one Now Playing and remote-command owner of the app (MAC01). Windows, the mini-player and the popover all read this model; none builds another.
    @ObservationIgnored let nowPlaying: NowPlayingCenter
    #if DEBUG
    /// Debug only: the recording stand-in an isolated or test process publishes into (nil in a normal launch, which uses the real centres).
    @ObservationIgnored let nowPlayingRecorder: RecordingNowPlayingSystem?
    /// Debug only: what a UI run reads to see that windows, the mini-player and the popover share ONE Now Playing owner and ONE registration.
    /// One recorder for the whole isolated UI process, so a second owner built anywhere in the app (another window's model) is REFUSED and shows in the
    /// census. A unit-test process gets a recorder per model (suites run in parallel there); a normal launch gets none (the real centres).
    @MainActor private static let isolatedLaunchRecorder = NowPlayingSystem.recording()
    static func recorder(isolatedLaunch: Bool, testHarness: Bool) -> RecordingNowPlayingSystem? {
        if testHarness { return NowPlayingSystem.recording() }
        return isolatedLaunch ? isolatedLaunchRecorder : nil
    }
    var nowPlayingCensus: String {
        let center = nowPlaying
        guard let recorder = nowPlayingRecorder else { return "nowPlaying owner=\(center.isActive ? 1 : 0) registrations=\(center.registrationCount)" }
        return "nowPlaying owner=\(center.isActive ? 1 : 0) registrations=\(recorder.commands.registrationCount) attaches=\(recorder.commands.attachCount) refused=\(recorder.commands.refusedOwners) state=\(NowPlayingMapping.stateName(recorder.info.state)) title=\(center.current?.title ?? "-")"
    }
    #endif
    /// The library ledger's like, dislike and save, as the remote layer sees them (the shell fills it in). Nil: no library write path here.
    @ObservationIgnored weak var remoteLibrary: (any RemoteLibraryControlling)?
    /// The podcast controls, as the remote layer sees them (the composition fills it in).
    @ObservationIgnored weak var episodes: (any RemoteEpisodeControlling)?
    /// A native session an account barrier already let go of: it publishes nothing more while it winds down.
    /// Held WEAKLY and compared by identity: an address could be reused by the next session, which must publish. It lets go of the object by itself.
    @ObservationIgnored private weak var fencedNativeSession: PlaybackSession?
    /// How long a finished item with nothing after it keeps the media keys (YouTube moves on to the next item by itself within a moment).
    @ObservationIgnored var endedGrace: Duration = .seconds(10)
    @ObservationIgnored private var endedTask: Task<Void, Never>?
    /// Plays a library playlist through YouTube Music's own player. The permit is
    /// captured at the click, so an account barrier in between rejects it.
    /// Explicit start requests this session has accepted so far (a counter, not a log). A preview compares it to tell a player that moved on because
    /// something asked it to from one that ran on into the next track by itself.
    var playRequestCount = 0
    @discardableResult func playMusic(playlistID: String, title: String, videoID: String? = nil, params: String? = nil, intent: MusicPlaybackIntent = .endpoint, queueCommand: MusicQueueFilterCommand? = nil, request: OwnedStartRequest) async -> SearchPlayOutcome {
        guard queueCommand == nil else { return .failed }
        guard !starting else { return .busy }; starting = true; defer { starting = false }
        let profileStart = DispatchTime.now().uptimeNanoseconds
        let startSignpost = PerformanceSignposts.begin(.firstItemStart, label: "youTubeMusic")
        defer { PerformanceSignposts.end(startSignpost, failed: error != nil) }
        defer { profileSink?(.playbackStart, Double(DispatchTime.now().uptimeNanoseconds - profileStart) / 1_000_000) }
        playRequestCount += 1
        // ROUTE09: a new item after a route loss plays on this Mac's current output; the loss already paused what was playing.
        await outputs?.coordinator.acceptCurrentOutput(for: .youTubeMusic)
        // ROUTE08: the native engine is silenced (and confirmed) before the hidden player starts.
        let carried = sleepTimerToCarry(leavingYouTubeMusic: false)   // P17-WEB: a native timer keeps running on the hidden player
        if let outputs, await outputs.coordinator.beginHandoff(to: .youTubeMusic) == .refused { self.error = String(localized: "The other player could not be stopped. Try Play again."); return .failed }
        do {
            let player = try await authority.youtubeMusic(request: request)
            if music !== player { attach(player) }
            session = nil; state = nil; timeline.snapshot = nil; lastPresentation = nil; endNativeVideo()
            await player.play(playlistID: playlistID, title: title, videoID: videoID, params: params, intent: intent, queueCommand: queueCommand)
            if let carried, !player.isClosed { await player.setSleepTimer(carried) }
            if player.refusal != nil || ((params != nil || queueCommand != nil || intent == .shuffle) && player.snapshot.isFailed) { self.error = String(localized: "YouTube Music could not start. Try Play again."); faultSink?(.playbackFailure, "player", "YouTube Music did not start"); return .failed }
            error = nil
            return .started
        } catch DomainError.staleContext { error = nil; return .stale }
        catch { self.error = String(localized: "YouTube Music could not start. Try Play again."); faultSink?(.playbackFailure, "player", "YouTube Music could not be opened"); return .failed }
    }
    /// A player restored paused from the last session joins the one owner exactly as a started one does (media keys, Now Playing, the bar).
    func attachRestored(_ player: WebMusicPlayer) { if music !== player { attach(player) } }
    private func attach(_ player: WebMusicPlayer) {
        music = player
        player.audibleStartGate = { [weak self] proceed in
            guard let outputs = self?.outputs else { await proceed(); return }
            await outputs.gate(.start, engine: .youTubeMusic, proceed)
        }
        player.timeline.setObserving(!observers.isEmpty)
        player.onChange = { [weak self, weak player] snapshot, artwork in
            guard let self, let player else { return }
            // Teardown by the owner (switch, sign-out, removal, quit, owned mode)
            // arrives here as a final change: no polling is needed.
            if player.isClosed { self.release(player); return }
            self.listening?(snapshot)
            if snapshot.notice != self.lastReportedNotice { self.lastReportedNotice = snapshot.notice; if let notice = snapshot.notice { let fault = FaultClassifier.category(for: notice); self.faultSink?(fault.category, fault.component, fault.detail) } }
            self.noteForResume(snapshot)
            self.episodeObserver?()
            self.publishNowPlaying(snapshot, artwork: artwork)
        }
        // The owner takes the keys only while there is an item (a restored paused item counts); a player created for a Play that has not loaded yet
        // takes them with its first report.
        if player.snapshot.phase != .idle { publishNowPlaying(player.snapshot, artwork: player.artwork) }
    }
    /// Drops a player the authority has torn down (switch, sign-out, removal, quit, owned mode).
    func reconcileMusic() async {
        guard let music else { return }
        let current = await authority.currentMusic()
        if music.isClosed || current !== music { release(music) }
    }
    private func release(_ player: WebMusicPlayer) {
        guard music === player else { return }
        player.onChange = nil; music = nil
        endNowPlaying()
        webVideoWindows.closeAll()
    }
    /// Lets go of the media keys and clears Now Playing: no item, an account barrier, quit, or an item that finished with nothing after it. Another
    /// media application can take the keys from here. Safe to call again.
    func endNowPlaying() {
        endedTask?.cancel(); endedTask = nil
        lastNowPlaying = nil; lastAnnouncedSong = nil
        nowPlaying.relinquish()
    }
    /// An account barrier: whatever was published belongs to the account that is going.
    private func accountBarrierForNowPlaying() {
        if let player = music { release(player) } else { endNowPlaying() }
        if let session { fencedNativeSession = session }
    }
    /// The one owner takes the keys the moment there is an item to act on.
    @discardableResult private func ensureNowPlayingOwner() -> Bool {
        nowPlaying.isActive || nowPlaying.activate { [weak self] command in self?.remote(command) ?? .noActionableItem }
    }
    /// The native session is gone or replaced: no surface keeps its picture.
    private func endNativeVideo() { nativeVideoWindows.closeAll(); nativeVideo.update(nil) }
    @ObservationIgnored private var lastNowPlaying: (item: NowPlayingItem, at: ContinuousClock.Instant)?
    /// W26: told once when a YouTube Music song starts playing (title, artist, advertisement flag). Only the opt-in notification feature listens.
    @ObservationIgnored var songChanged: (@MainActor (String?, String?, Bool) -> Void)?
    @ObservationIgnored private var lastAnnouncedSong: String?
    private func announceSong(_ snapshot: WebMusicSnapshot) {
        guard snapshot.phase == .playing, snapshot.intent, !snapshot.isAd, snapshot.title != nil, let id = snapshot.videoID, id != lastAnnouncedSong else { return }
        lastAnnouncedSong = id
        songChanged?(snapshot.title, snapshot.artist, false)
    }
    /// Now Playing is rewritten only when something a listener sees changes:
    /// metadata, artwork, play state, ad state, route, or a position jump (seek). The
    /// system extrapolates elapsed time from the published rate between updates.
    /// What Now Playing is told about the hidden player's item. The speed is the ELEMENT's (what the page reports it is playing at), so the
    /// system's clock extrapolates at the real rate; it is built here so the speed it carries can be tested. A live stream has no duration to
    /// publish, and an advertisement is published as an advertisement (the mapping drops the song's title, picture and clock).
    static func webNowPlayingItem(_ snapshot: WebMusicSnapshot, artwork: Data?, player: WebMusicPlayer?, route: NowPlayingRoute? = nil) -> NowPlayingItem {
        NowPlayingItem(title: snapshot.title ?? snapshot.playlistTitle ?? "YouTube Music", artist: snapshot.artist,
                       album: nil, artwork: artwork, duration: snapshot.isLive ? 0 : snapshot.duration, elapsed: snapshot.position,
                       playing: snapshot.phase == .playing && snapshot.intent, advertisement: snapshot.isAd, rate: player?.confirmedRate ?? 1,
                       live: snapshot.isLive, route: route, itemID: snapshot.videoID)
    }
    private func publishNowPlaying(_ snapshot: WebMusicSnapshot, artwork: Data?) {
        guard snapshot.phase != .idle else { endNowPlaying(); return }
        // A finished item that already let go of the keys never takes them back (a device change, a late report): only a new item or Play can.
        if snapshot.phase == .ended, !nowPlaying.isActive { return }
        guard ensureNowPlayingOwner() else { return }
        watchForEnd(snapshot)
        let capabilities = remoteCapabilities()
        let item = Self.webNowPlayingItem(snapshot, artwork: artwork, player: music, route: outputs?.nowPlayingRoute(youTubeMusic: true))
        let now = ContinuousClock.now
        if let last = lastNowPlaying, !NowPlayingMapping.needsUpdate(from: last.item, elapsedSince: now - last.at, to: item) {
            // Nothing the listener sees changed, but which commands are on may have (a song's page was read, a podcast started).
            nowPlaying.setCapabilities(capabilities); return
        }
        lastNowPlaying = (item, now)
        nowPlaying.update(item, capabilities: capabilities)
        announceSong(snapshot)
    }
    /// A finished item keeps the keys for a moment, because YouTube moves on to the next one by itself. If nothing follows, the owner lets go.
    private func watchForEnd(_ snapshot: WebMusicSnapshot) {
        guard snapshot.phase == .ended else { endedTask?.cancel(); endedTask = nil; return }
        guard endedTask == nil else { return }
        let finished = snapshot.videoID
        endedTask = Task { [weak self] in
            try? await Task.sleep(for: self?.endedGrace ?? .seconds(10))
            guard !Task.isCancelled, let self, let player = self.music, player.snapshot.phase == .ended, player.snapshot.videoID == finished else { return }
            self.endNowPlaying()
        }
    }
    /// The route changed (an output came or went, a receiver took over): the published item carries it in the same update.
    func routeChangedForNowPlaying() {
        if let player = music, !player.isClosed, player.snapshot.phase != .idle { publishNowPlaying(player.snapshot, artwork: player.artwork) }
        else if music == nil, session != nil, let snapshot = timeline.snapshot {
            // While a receiver plays, its own report is the position (nil outer: not a receiver route; .some(nil): no fresh report, publish nothing).
            if timeline.receiver == nil { publishNativeNowPlaying(snapshot) }
            else if let reading = timeline.receiver ?? nil { publishNativeNowPlaying(snapshot, elapsed: reading) }
        }
    }
    /// The native queue is finished: Now Playing says stopped at once (never "playing" past the end), and the keys are let go after the grace unless the
    /// session starts something again meanwhile.
    private func holdFinishedNative(_ session: PlaybackSession) {
        guard nowPlaying.isActive else { return }
        if var item = lastNowPlaying?.item, item.playing || item.elapsed < item.duration {
            item.playing = false; if item.duration > 0 { item.elapsed = item.duration }
            lastNowPlaying = (item, ContinuousClock.now)
            nowPlaying.update(item, capabilities: remoteCapabilities())
        }
        guard endedTask == nil else { return }
        endedTask = Task { [weak self, weak session] in
            try? await Task.sleep(for: self?.endedGrace ?? .seconds(10))
            guard !Task.isCancelled, let self, let session, self.session === session, self.music == nil else { return }
            let snapshot = self.timeline.snapshot
            guard snapshot?.queue.current == nil || snapshot?.playback.state == .ended else { return }
            self.endNowPlaying()
        }
    }
    /// Now Playing for a native session: title, duration, position and state, rewritten only when something a listener sees changes.
    private func publishNativeNowPlaying(_ snapshot: PlaybackSessionSnapshot, elapsed receiverElapsed: Double? = nil) {
        guard music == nil, let session, session !== fencedNativeSession else { return }
        // A queue that ran out (nothing current, or ended): the same grace as the web player, then the keys are free. It never takes them back.
        if snapshot.queue.current == nil || snapshot.playback.state == .ended { holdFinishedNative(session); return }
        endedTask?.cancel(); endedTask = nil
        guard let current = snapshot.queue.current, snapshot.playback.state != .idle else { return }
        guard ensureNowPlayingOwner() else { return }
        let capabilities = remoteCapabilities()
        let item = NowPlayingItem(title: title(for: current.media), artist: nil, album: nil, artwork: nil, duration: snapshot.media?.duration ?? 0,
                                  elapsed: receiverElapsed ?? snapshot.playback.position, playing: snapshot.playback.state == .playing, advertisement: false,
                                  route: outputs?.nowPlayingRoute(youTubeMusic: false), itemID: current.media.rawValue)
        let now = ContinuousClock.now
        if let last = lastNowPlaying, !NowPlayingMapping.needsUpdate(from: last.item, elapsedSince: now - last.at, to: item) { nowPlaying.setCapabilities(capabilities); return }
        lastNowPlaying = (item, now)
        nowPlaying.update(item, capabilities: capabilities)
    }
    /// Media keys, Control Center and accessories enter here; the same player
    /// methods as the transport bar (ARCH03). Admission is synchronous and decided by the same
    /// `remoteCapabilities()` that switched the system's buttons on: a command that is off is refused, never silently dropped.
    func remote(_ command: RemoteTransportCommand) -> RemoteCommandOutcome {
        let capabilities = remoteCapabilities()
        guard capabilities.hasItem else { return .noActionableItem }
        guard capabilities.enabled.contains(command.kind) else { return .refused }
        if music == nil, let native = session {
            // A native session (kept media): the same session methods as the transport bar.
            switch command {
            case .play: Task { await nativeStart { try? await native.resume(); await self.refresh() } }
            case .pause: Task { try? await native.pause(); await refresh() }
            case .toggle: Task { await nativePlayPause() }
            case .next: Task { try? await native.next(); await refresh() }
            case .previous: Task { try? await native.previous(); await refresh() }
            case .seek(let target): Task { try? await native.seek(target); await refresh() }
            case .skip, .rate, .setLike, .setDislike, .setSave: return .refused
            }
            return .success
        }
        guard let player = music else { return .noActionableItem }
        switch command {
        case .play: Task { await player.resume() }
        case .pause: Task { await player.pause() }
        case .toggle: Task { await player.playPause() }
        case .next: Task { await player.next() }
        case .previous: Task { await player.previous() }
        case .seek(let target): Task { await player.seek(target) }
        case .skip(let seconds):
            guard let episodes else { return .refused }
            Task { _ = await episodes.remoteJump(forward: seconds > 0) }
        case .rate(let rate):
            guard PodcastRate.isValid(rate), let id = player.snapshot.videoID, let episodes, let episode = episodes.remoteEpisode(for: id) else { return .refused }
            Task { _ = await episodes.remoteSetRate(rate, for: episode) }
        case .setLike(let wanted), .setDislike(let wanted), .setSave(let wanted):
            // A physical button is a person's own action. It goes through the library ledger exactly as the mini-player's Like does. The system asks
            // for a STATE: if the ledger is already there, nothing is pressed (a press against a stale button cannot invert it).
            guard let library = remoteLibrary, case .available(let control) = library.remoteLibraryControl(command.kind) else { return .refused }
            if control.isOn == wanted { refreshRemoteCapabilities(); return .success }
            Task { [weak self] in
                await library.remoteLibraryPress(control)
                self?.refreshRemoteCapabilities()
            }
        }
        return .success
    }

    func act(action: PlaybackUIAction = .transport, _ operation: @escaping @Sendable (PlaybackSession) async throws -> Void) async {
        guard let session else { return }
        pending = true; defer { pending = false }
        do { try await operation(session); error = nil; retryOperation = nil; failedSession = nil; failedAction = nil }
        catch {
            guard self.session === session else { return }
            self.error = action.failure; failedAction = action; retryOperation = operation; failedSession = session
        }
        await refresh()
    }
}

/// Structural comparison deliberately excludes queue checkpoint versions and position ticks.
/// Large collection projection/diff runs on a utility executor before MainActor installation.
private struct PlaybackPresentation: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let id: UUID; let media: String; let segment: QueueSegment; let consumed: Bool; let immutable: Bool
    }
    let rows: [Row]
    let context: PlaybackContext
    let key: String
    init(_ value: PlaybackSessionSnapshot) {
        rows = value.queue.session.entries.map { Row(id: $0.id, media: $0.media.rawValue, segment: $0.segment, consumed: $0.consumed, immutable: value.queue.metadata.immutable.contains($0.id)) }
        context = value.playback.context
        key = "\(value.playback.state)|\(value.playback.intent)|\(value.gain)|\(value.muted)|\(value.appliedGain)|\(value.nativeStartGain ?? -1)|\(value.failures)|\(Int(value.timer?.remaining ?? -1))|\(value.timer?.endOfItem ?? false)|\(value.timer?.fading ?? false)|\(value.media?.duration ?? -1)|\(value.media?.codec ?? "")|\(value.media?.bitrate ?? -1)|\(value.media?.sampleRate ?? -1)|\(value.media?.route ?? "")|\(value.queue.session.shuffleSeed ?? 0)|\(value.queue.session.repeatMode)|\(value.queue.session.autoplay)"
    }
}
