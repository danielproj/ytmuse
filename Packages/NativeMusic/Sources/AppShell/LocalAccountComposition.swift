import AppKit
import DesignSystem
import Foundation
import SwiftUI
import Observation
import AccountSession
import Persistence
import Domain
import Features
import Artwork
import Playback
import Diagnostics

/// Local composition. The web Music session coordinator, when supplied, is a
/// lifecycle participant so switch/sign-out/removal fence and clean its state.
public enum LocalAccountComposition {
    /// Establish the app-owned parent before capturing the window store's canonical path.
    /// Shared by normal bootstrap and the explicitly isolated development composition.
    static func windowStore(in directory: URL) async -> WindowRestorationStore {
        await Task.detached {
            // Establish a legitimate missing parent before canonical capture. History is secondary:
            // any filesystem failure is handled by the store's bind/prepare availability boundary.
            // The independent account/database open below still reports its own failures.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return WindowRestorationStore(directory: directory.appendingPathComponent("window-history"))
        }.value
    }

    public static func open(directory: URL, playback: (any AccountLifecycleParticipant)? = nil, artwork: (any AccountLifecycleParticipant)? = nil,
                            windows: (any AccountLifecycleParticipant)? = nil, google: GoogleConnectionCoordinator? = nil,
                            music: MusicSessionCoordinator? = nil, vault suppliedVault: (any SessionVault)? = nil,
                            persistsPromptExpiry: Bool = KeychainExpiryPolicy.currentBuildPersistsPromptExpiry,
                            extra: [any AccountLifecycleParticipant] = []) async throws -> AccountLifecycle {
        try await Task.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let initial = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
            let store = try SQLiteStore(directory: directory.appendingPathComponent("database"), context: initial)
            let roster = SQLiteAccountDirectory(store: store, context: initial)
            let vault: any SessionVault
            if let suppliedVault { vault = suppliedVault } else { vault = try KeychainVault() }
            let storage = SQLiteAccountParticipant(store: store, directory: roster)
            let files = try PrivateAccountFiles(id: "private-files", root: directory.appendingPathComponent("accounts"))
            let work = ScopedAccountWork()
            let presentation: [any AccountLifecycleParticipant] = (windows.map { [$0] } ?? []) + (artwork.map { [$0] } ?? [])
            let services: [any AccountLifecycleParticipant] = (google.map { [$0 as any AccountLifecycleParticipant] } ?? []) + (music.map { [$0 as any AccountLifecycleParticipant] } ?? [])
            let lifecycle = try await AccountLifecycle.open(vault: vault, store: roster, participants: presentation + services + extra + [work, storage, files] + (playback.map { [$0] } ?? []), persistsPromptExpiry: persistsPromptExpiry,
                                                       staleLedger: FileStaleCredentialLedger(url: directory.appendingPathComponent("stale-credentials.json")))
            await google?.attach(to: lifecycle)
            await music?.attach(to: lifecycle)
            return lifecycle
        }.value
    }
}

/// Optional Google configuration cannot prevent the local account store opening.
public struct GoogleAuthorizationSetup: Sendable {
    public let configuration: DesktopOAuthConfiguration?
    public let invalid: Bool
    public init(info: [String: Any]) throws {
        do {
            if let value = info["YTMuseGoogleDesktopClientID"] as? String, value.contains("$(") {
                throw DesktopOAuthError.invalidConfiguration
            }
            configuration = try DesktopOAuthConfiguration.fromApplicationInfo(info); invalid = false
        }
        catch DesktopOAuthError.invalidConfiguration { configuration = nil; invalid = true }
    }
    public func status(for state: GoogleConnectionState) -> GoogleConnectionState {
        guard configuration == nil else { return state }
        if state == .cleanupRequired { return state }
        if [.storedAuthorization, .profileVerified, .musicConnected].contains(state) {
            return invalid ? .configurationInvalidStored : .configurationMissingStored
        }
        return invalid ? .configurationInvalid : .configurationMissing
    }
    @MainActor public func makeModel(lifecycle: AccountLifecycle,
        authenticate: @escaping AccountAuthenticationAction,
        status: @escaping @Sendable () async -> GoogleConnectionState,
        refresh: @escaping @Sendable () async throws -> Void,
        disconnect: @escaping @Sendable () async throws -> Void) -> AccountsModel {
        AccountsModel(lifecycle: lifecycle, authentication: configuration == nil ? nil : authenticate,
            authenticationLabel: "Authorize Google identity", authenticationCanConnectMusic: false,
            connectionStatus: { self.status(for: await status()) },
            refreshAuthorization: configuration == nil ? nil : refresh,
            disconnectAuthorization: disconnect)
    }
    public func openLocal(directory: URL, playback: (any AccountLifecycleParticipant)? = nil, artwork: (any AccountLifecycleParticipant)? = nil,
                          windows: (any AccountLifecycleParticipant)? = nil, google: GoogleConnectionCoordinator? = nil,
                          music: MusicSessionCoordinator? = nil, vault suppliedVault: (any SessionVault)? = nil,
                          persistsPromptExpiry: Bool = KeychainExpiryPolicy.currentBuildPersistsPromptExpiry,
                          extra: [any AccountLifecycleParticipant] = []) async throws -> AccountLifecycle {
        try await LocalAccountComposition.open(directory: directory, playback: playback, artwork: artwork, windows: windows, google: google, music: music, vault: suppliedVault, persistsPromptExpiry: persistsPromptExpiry, extra: extra)
    }
}

/// One bootstrap is shared by every window. Opening a window cannot construct a
/// second authority or player. Disk work starts once, outside MainActor.
@MainActor @Observable final class LocalAccountBootstrap {
    var model = AccountsModel()
    /// Constructed in `init`: under QA isolation the very first playback owner is the
    /// isolated one, so no window can reach the real owned-audio store or Keychain
    /// while `load()` is still running.
    var playback: PlaybackModel
    /// W22: the output coordinator (real outputs in a normal launch, scripted ones in an isolated launch); see `OutputComposition.swift`.
    var outputs: OutputController?
    var failure = false
    let artworkAuthority = ArtworkUIAuthority()
    var artwork: ArtworkPipeline? { didSet { catalogArtwork.pipeline = artwork } }
    var artworkRequest: ArtworkRequest?
    let windowAuthority = WindowNavigationAuthority()
    var windowStore: WindowRestorationStore?
    #if DEBUG
    var developmentQueue: DevelopmentDesignQueue?
    var nativeDesignTesting: Bool { ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1" }
    /// Debug-only QA namespace for UI automation (see `IsolatedQAStorage`).
    var isolatedQA: Bool { isolatedStorage != nil }
    /// Created synchronously in `init` when isolation is requested.
    @ObservationIgnored let isolatedStorage: IsolatedQAStorage?
    #endif
    private let artworkSource: any ArtworkSource
    /// W21: the shell (status item, mini-player, full-screen Now Playing, window census, power lifecycle). Created once with the one playback owner,
    /// so every window shares it; nothing starts until the application has finished launching.
    @ObservationIgnored let loginItemService: any LoginItemService
    /// W26: what the app target offers for the global hot keys and notifications; an isolated launch never gets them (`IntegrationFacilities.choose`).
    @ObservationIgnored let systemServices: SystemServices
    @ObservationIgnored lazy var shell: ShellCoordinator = ShellCoordinator(playback: playback, loginItem: loginItemService,
        facilities: IntegrationFacilities.choose(isolated: LaunchStorageDecision.isIsolated, hotKeys: systemServices.hotKeys, notifications: systemServices.notifications))
    /// Supplied by the app target (YouTubeMusicAdapter's signed client). When nil,
    /// only the reviewed Google OAuth surface is composed, as before this lane.
    @ObservationIgnored let musicReader: (any MusicSessionReading)?
    @ObservationIgnored private(set) var music: MusicSessionCoordinator?
    /// Catalog artwork (W11): the URLs the service published, loaded through the same bounded pipeline as every other image.
    @ObservationIgnored let catalogArtworkSource: CatalogArtworkSource?
    let catalogArtwork: CatalogArtwork
    /// Created on first use by the first window; shared by all windows.
    @ObservationIgnored lazy var catalog: CatalogHub = makeCatalogHub()
    /// The Library and History screens' state, with the local listening history wired to the playback owner (W12).
    @ObservationIgnored lazy var library: LibrarySurface = { let surface = makeLibrarySurface(); connectListeningHistory(surface); surface.playlists = makePlaylistSurface(); surface.downloads = downloads; return surface }()
    /// The Downloads engine (W15): composed once the account directory is known, forwarding nothing until then.
    @ObservationIgnored let lateDownloads = LateBoundDownloads()
    /// The Downloads screen's state. Debug UI runs with the development-downloads flag get the labelled development controller.
    @ObservationIgnored lazy var downloads: DownloadsModel = {
        #if DEBUG
        if DevelopmentDownloads.enabled { return DownloadsModel(controller: DevelopmentDownloadsController(), development: true) }
        #endif
        return DownloadsModel(controller: lateDownloads)
    }()
    /// Samples, the music tuner, Recap and badges (W20), and comments / moderation / invitations (MEDIA10). Created on first use.
    @ObservationIgnored lazy var conditions = DeviceConditionsMonitor(watching: !Self.automationIsolatedLaunch)
    @ObservationIgnored lazy var previewEngine = SessionPreviewEngine(playback: playback, performer: searchPerformer)
    @ObservationIgnored lazy var discovery: DiscoverySurface = makeDiscoverySurface()
    @ObservationIgnored lazy var social: SocialSurface = makeSocialSurface()
    /// Podcasts and lyrics (W18): episode pages, speed / jump / resume, episode progress, the lyrics panel. Created on first use.
    @ObservationIgnored lazy var podcasts: PodcastsSurface = makePodcastsSurface()
    @ObservationIgnored let podcastStore = LateBoundPodcastStore()
    /// W25: the widget snapshot publisher, its command bridge and the Spotlight controller (nil until `installSystemSurfaces`), and the services they were built on.
    @ObservationIgnored var widgetPublisher: WidgetSnapshotPublisher?
    @ObservationIgnored var widgetBridge: WidgetCommandBridge?
    @ObservationIgnored var spotlight: SpotlightController?
    @ObservationIgnored var resolvedServices: ResolvedSurfaces?
    /// W27: the settings (global / account / window scopes over the app's one preferences store), the local diagnostics (bounded redacted log, opt-in profiler,
    /// support bundle), the destructive-action eraser bound to this session's injected roots, and the download-setting mirror.
    @ObservationIgnored lazy var settings: SettingsStore = makeSettingsStore()
    @ObservationIgnored lazy var downloadMirror = DownloadSettingsMirror(engine: lateDownloads)
    /// The context is read on the main actor wherever the log is written or read from: on another thread it hops there (the log holds no lock while it asks).
    @ObservationIgnored lazy var diagnosticLog = DiagnosticLog(context: { [weak self] in
        if Thread.isMainThread { return MainActor.assumeIsolated { self?.diagnosticsPrivateContext() ?? .empty } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { self?.diagnosticsPrivateContext() ?? .empty } }
    })
    var diagnostics: DiagnosticsCenter?
    var eraser: LocalDataEraser?
    /// Set only for the duration of a Restore Defaults the person pressed in a session that is not isolated.
    @ObservationIgnored var pendingRestoreConfirmation: PersonConfirmation?
    @ObservationIgnored var lastSignInNotice: Date?
    /// The session vault's Keychain namespace as the vault itself reports it (nil before the vault exists).
    @ObservationIgnored var sessionVaultNamespace: String?
    var localRoots: LocalDataRoots?
    @ObservationIgnored var lifecycleHandle: AccountLifecycle?
    @ObservationIgnored var runMarker: RunMarker?
    @ObservationIgnored var profiler: LocalProfiler?
    /// Background beats owned by the composition (cancelled with it).
    @ObservationIgnored var beats: [Task<Void, Never>] = []
    #if DEBUG
    /// The environment this launch was given (Debug only; the development data's flags are read from it).
    @ObservationIgnored let launchEnvironment: [String: String]
    #endif
    /// Debug only: the development data's measurement line for the UI tests. nil in every other run.
    @ObservationIgnored var discoveryReadout: (@MainActor () -> String)?
    /// This Mac's own listening record; bound to its file store once the account directory is known.
    @ObservationIgnored let historyStore = LateBoundHistoryStore()
    /// The upload job list (W19), bound to its per-account file store once the account directory is known.
    @ObservationIgnored let uploadStore = LateBoundUploadStore()
    /// The adapter-defined rule for when listening counts as a play; nil disables the local record.
    @ObservationIgnored let listeningPolicy: ListeningPolicy?
    /// The real Music search through the coordinator (signed for the active account, otherwise anonymous).
    var searchRemote: SearchModel.RemoteSearch? {
        guard let music else { return nil }
        let remote: SearchModel.RemoteSearch = { [weak self] query in
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                let answer = try await music.search(query: query)
                await MainActor.run { self?.profiler?.record(.searchRequest, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
                return answer
            } catch {
                // DIAG02: a category and a fixed phrase, never the error's own text (which can carry a URL or the words searched for).
                await MainActor.run {
                    if let fault = FaultClassifier.category(for: error, component: "search") { self?.diagnosticLog.record(fault.category, component: fault.component, detail: fault.detail) }
                    self?.profiler?.record(.searchRequest, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
                throw error
            }
        }
        return remote
    }
    /// Owned here because a search model holds its performer weakly.
    @ObservationIgnored lazy var searchPerformer: AppSearchPerformer = {
        #if DEBUG
        // Isolated runs never touch the person's clipboard.
        if isolatedQA { return AppSearchPerformer(playback: playback, pasteboard: NSPasteboard(name: NSPasteboard.Name("local.native-music.ui-test-" + UUID().uuidString))) }
        #endif
        return AppSearchPerformer(playback: playback)
    }()
    /// How many bootstraps (each owns one account model, one playback owner and one Now Playing owner) this process has made. One per scene
    /// composition; a window never makes one (W21 guard test).
    nonisolated(unsafe) private(set) static var createdCount = 0
    init(artworkSource: any ArtworkSource = UnconnectedArtworkSource(), musicReader: (any MusicSessionReading)? = nil, listeningPolicy: ListeningPolicy? = nil,
         loginItem: any LoginItemService = InMemoryLoginItemService(), system: SystemServices = .none, environment: [String: String] = ProcessInfo.processInfo.environment) {
        loginItemService = loginItem; systemServices = system
        Self.createdCount += 1
        #if DEBUG
        launchEnvironment = environment
        #endif
        self.listeningPolicy = listeningPolicy
        if let musicReader, artworkSource is UnconnectedArtworkSource {
            let source = CatalogArtworkSource { try await musicReader.artwork($0) }
            self.artworkSource = source; catalogArtworkSource = source
        } else { self.artworkSource = artworkSource; catalogArtworkSource = nil }
        catalogArtwork = CatalogArtwork(pipeline: nil, authority: artworkAuthority, source: catalogArtworkSource)
        self.musicReader = musicReader
        #if DEBUG
        if IsolatedQAStorage.requested(environment) {
            // Never fall back to real storage: a QA instance that cannot isolate stops.
            guard let storage = try? IsolatedQAStorage.createNow() else {
                preconditionFailure("QA isolation was requested but could not be established; refusing to open real storage")
            }
            isolatedStorage = storage
            // The native design mode always uses the controlled 0.001 test gain.
            let controlled = environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1" || environment["YTMUSE_OWNED_AUDIO_TEST_GAIN"] == "0.001"
            // The hidden player's host knob is read from the throwaway preferences too.
            playback = PlaybackModel(authority: AppPlaybackAuthority(directory: storage.root.appendingPathComponent("owned-audio"), offlineVault: storage.ownedVault,
                makeMusicPage: { WebKitMusicPage(delegate: $0, orderHostWindowIn: AppPreferences.store.bool(forKey: WebKitMusicPage.orderedInKey)) }), controlledAudioTest: controlled)
            return
        }
        isolatedStorage = nil
        #endif
        // A normal launch: the hidden player's host knob is read from the app's own preferences store.
        playback = PlaybackModel(authority: AppPlaybackAuthority(makeMusicPage: { WebKitMusicPage(delegate: $0, orderHostWindowIn: AppPreferences.store.bool(forKey: WebKitMusicPage.orderedInKey)) }))
    }
    private var task: Task<Void, Never>?
    private var artworkLifecycle: ArtworkAccountParticipant?
    func retryLocalStorage() async { guard failure else { return }; task = nil; failure = false; await load() }
    /// Quit: the bounded attempt-store drain runs alongside the playback checkpoint,
    /// so it never blocks quit; unconfirmed IDs stay ledgered for next launch.
    private func installShutdown(after: (@Sendable () async -> Void)? = nil) {
        shutdownAfter = after
        PlaybackApplicationDelegate.shutdown = makeShutdownClosure()
    }
    /// What the application delegate runs at quit for this bootstrap: it forwards to THIS instance's `shutdown()` (and only quits the authority if the
    /// bootstrap is already gone). A seam so a test can run exactly the closure the app installs, for one bootstrap, without reaching through the
    /// process-wide static that every other bootstrap in the process shares.
    func makeShutdownClosure() -> @Sendable () async -> Void {
        { [weak self, authority = playback.authority] in
            if let self { await self.shutdown() } else { await authority.quit() }
        }
    }
    @ObservationIgnored var shutdownAfter: (@Sendable () async -> Void)?
    /// This bootstrap's own quit: what the application delegate's static closure runs for the bootstrap that installed it last. A process hosting several
    /// bootstraps at once (the headless render audits do) must shut each down through its own instance: the static closure reaches whichever bootstrap
    /// installed it last, so a test finishing early would otherwise quit another test's player (T52-F1).
    func shutdown() async {
        let music = self.music
        async let drained: Void = { await music?.drainRemovals(within: .seconds(1)) }()
        await playback.saveResumeNow()   // before the owner drops the player: the last session a cold launch restores, paused
        await outputs?.stop()
        await playback.authority.quit()
        await drained
        await lateDownloads.quit()
        runMarker?.endCleanly()   // W27: a quit that got this far is a clean one; a run that never gets here is reported next launch as ending unexpectedly
        await shutdownAfter?()
    }
    func load() async {
        if let task { await task.value; return }
        let launchStart = DispatchTime.now().uptimeNanoseconds
        // The track being played is the first thing the Downloads engine finishes (OFF05).
        playback.currentItemChanged = { [lateDownloads] media in Task { await lateDownloads.setCurrentPlayback(media) } }
        // Play on a kept item starts the native session from the encrypted store (nothing is offered until this is set).
        let keptPlayer = playback
        Task { [lateDownloads] in
            await lateDownloads.setPlayer { item in
                guard let parts = await lateDownloads.playbackParts() else { return false }
                return await keptPlayer.playKept(item, parts: parts)
            }
        }
        let task = Task {
            #if DEBUG
            // Isolation is decided before anything opens: the QA instance never sees
            // the real Application Support data, login Keychain or WebKit stores.
            let isolated = isolatedStorage
            #endif
            installShutdown()
            PlaybackApplicationDelegate.beforeQuit = { [weak self] in self?.model.signIn?.cancel() }
            do {
                #if DEBUG
                if nativeDesignTesting, let isolated {
                    let root = isolated.root
                    let account = try AccountContext(accountID: UUID(), channelID: ID("original-design-test"), region: "US")
                    let context = RequestContext(account: account, accountGeneration: 1, requestGeneration: 1)
                    let pipeline = ArtworkPipeline(source: DevelopmentDesignSource(), diskDirectory: root.appendingPathComponent("artwork"))
                    try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account), generation: 1)
                    artwork = pipeline; artworkAuthority.bind(context)
                    artworkRequest = ArtworkRequest(resource: try ArtworkResource(namespace: "original-development-art", identifier: "resonance", revision: "1"), size: try ArtworkSize(pointsWidth: 1, pointsHeight: 1, scale: 1), policy: .memory(until: .distantFuture), context: context)
                    let windows = await LocalAccountComposition.windowStore(in: root)
                    let historyFault = ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_HISTORY_BROKEN"]
                    if historyFault == "1" {
                        try await Task.detached {
                            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            try Data([1]).write(to: root.appendingPathComponent("window-history"))
                        }.value
                    }
                    if historyFault == "atomic-leftover" {
                        try await Task.detached {
                            let directory = root.appendingPathComponent("window-history")
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            let marker = directory.appendingPathComponent("reset-in-progress.plist"), stage = directory.appendingPathComponent("history-epoch.plist.sb-ee3e07bf-gplhtd")
                            try Data([1]).write(to: marker); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
                            try Data([7]).write(to: stage); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stage.path)
                        }.value
                    }
                    let enabled = try await windows.bind(context)
                    let epoch = await windows.currentEpoch
                    windowStore = windows; windowAuthority.bind(context, historyAvailable: enabled, epoch: epoch)
                    developmentQueue = try await DevelopmentDesignQueue.prepare(context: context)
                    installShutdown { await pipeline.stopPressureMonitoring(); await isolated.destroy(); AppPreferences.removeOwnedIsolatedFile() }
                    return
                }
                #endif
                let appDirectory: URL
                let vault: any SessionVault
                let google: GoogleConnectionCoordinator?
                let setup: GoogleAuthorizationSetup
                #if DEBUG
                if let isolated {
                    // No Google grant store, login Keychain or real web-store ledger.
                    appDirectory = isolated.root; vault = isolated.sessionVault; google = nil
                    setup = try GoogleAuthorizationSetup(info: [:])
                } else {
                    appDirectory = try await Self.productionDirectory()
                    setup = try GoogleAuthorizationSetup(info: Bundle.main.infoDictionary ?? [:])
                    let coordinator = try GoogleConnectionCoordinator(configuration: setup.configuration)
                    await coordinator.inspectStoredAuthorization()
                    google = coordinator; vault = try KeychainVault()
                }
                #else
                appDirectory = try await Self.productionDirectory()
                setup = try GoogleAuthorizationSetup(info: Bundle.main.infoDictionary ?? [:])
                let coordinator = try GoogleConnectionCoordinator(configuration: setup.configuration)
                await coordinator.inspectStoredAuthorization()
                google = coordinator; vault = try KeychainVault()
                #endif
                let pipeline = ArtworkPipeline(source: artworkSource, diskDirectory: appDirectory.appendingPathComponent("artwork"))
                artwork = pipeline
                let windowStore = await LocalAccountComposition.windowStore(in: appDirectory)
                self.windowStore = windowStore
                let windows = WindowAccountParticipant(store: windowStore, presentation: windowAuthority)
                let art = ArtworkAccountParticipant(pipeline: pipeline, presentation: artworkAuthority)
                artworkLifecycle = art
                await art.start()
                #if DEBUG
                installShutdown { await art.stop(); await isolated?.destroy(); if isolated != nil { AppPreferences.removeOwnedIsolatedFile() } }
                #else
                installShutdown { await art.stop() }
                #endif
                #if DEBUG
                // Isolated instances never create or remove a WebKit identified store (those live in the
                // real ~/Library/WebKit container whatever the app directory is).
                let webIsolated = isolated != nil
                #else
                let webIsolated = false
                #endif
                // This Mac's listening record lives beside the other account data and is removed with the account.
                let localHistory = LocalHistoryFileStore(directory: appDirectory.appendingPathComponent("local-history"))
                await historyStore.bind(localHistory)
                let podcastFiles = PodcastLocalFileStore(directory: appDirectory.appendingPathComponent("podcasts"))
                await podcastStore.bind(podcastFiles)
                let uploadJobs = UploadJobFileStore(directory: appDirectory.appendingPathComponent("upload-jobs"))
                await uploadStore.bind(uploadJobs)
                let resumeFiles = MusicResumeFileStore(directory: appDirectory.appendingPathComponent("music-resume"))
                let lateResume = LateBoundMusicResumeStore(); await lateResume.bind(resumeFiles)
                playback.resumeStore = lateResume
                playback.checkpointForSleep = { [weak self] in await self?.playback.saveResumeNow() }
                let signIn = WebMusicSignIn(options: MusicWebSignInOptions(defaults: AppPreferences.store), nonPersistentStores: webIsolated)
                // IDs of in-flight sign-in attempt stores only; no secrets.
                let ledger = FileMusicSignInLedger(url: appDirectory.appendingPathComponent("web-sign-in-attempts.json"))
                let music = musicReader.map { reader -> MusicSessionCoordinator in
                    webIsolated ? MusicSessionCoordinator(vault: vault, reader: reader, stores: IsolatedMusicDataStores(), ledger: ledger, presenter: signIn)
                                : MusicSessionCoordinator(vault: vault, reader: reader, ledger: ledger, presenter: signIn)
                }
                // The retained store needs the protected-record capability of the Keychain vault; without it Downloads stays idle.
                if let protected = vault as? any ScopedProtectedRecords { try? await lateDownloads.attach(directory: appDirectory, vault: protected) }
                sessionVaultNamespace = (vault as? KeychainVault)?.serviceNamespace
                // SEC08: the settings store is a lifecycle participant, so an account's own settings go with it on every removal path.
                let settingsScope = SettingsAccountParticipant { [weak self] in try self?.settings.removeAccount($0) }
                let lifecycle = try await setup.openLocal(directory: appDirectory, playback: playback.authority, artwork: art, windows: windows,
                                                          google: google, music: music, vault: vault, extra: [localHistory, podcastFiles, uploadJobs, resumeFiles, lateDownloads, settingsScope])
                self.music = music
                lifecycleHandle = lifecycle
                configureLocalData(appDirectory: appDirectory, lifecycle: lifecycle)
                if music != nil {
                    // The hidden player reads the active generation's exact Keychain record.
                    await playback.authority.configureMusic { [weak lifecycle] context in
                        KeychainMusicCookieSource(cookies: lifecycle.map { MusicPlayerCookies(vault: vault, lifecycle: $0, context: context) })
                    }
                }
                if let music {
                    model = AccountsModel(lifecycle: lifecycle, music: MusicSessionSurface(signIn: signIn,
                        authenticate: { challenge in try await music.signIn(challenge) },
                        status: { await music.status() }, proof: { await music.proof() }))
                } else if let google {
                    model = setup.makeModel(lifecycle: lifecycle,
                        authenticate: { challenge in try await google.authenticate(challenge) },
                        status: { await google.connectionState() },
                        refresh: { try await google.refreshGoogleAuthorization() },
                        disconnect: { try await google.disconnectGoogleAuthorization() })
                } else {
                    model = AccountsModel(lifecycle: lifecycle)
                }
                await model.refresh()
                // The Library and History state exists from launch, so the local listening record follows playback even before either screen opens.
                _ = library
                spotlight?.start()
                widgetPublisher?.changed()
                let state = await lifecycle.snapshot()
                if let account = state.directory.defaultIdentity,
                   let identity = state.directory.identities.first(where: { $0.id == account }),
                   identity.state == .connected || identity.state == .expired {
                    await model.switchIdentity(account)
                    // WIN09: a manual cold launch shows the last session paused (nothing loads, nothing plays). Settings > Restore session turns it off.
                    await playback.restoreLastSession()
                } else {
                    widgetPublisher?.noteSignedOut()   // nobody to restore: the widget says so instead of "Open YTMuse"
                }
                if let music {
                    // Off the launch path: the window is already up (this runs in its
                    // `.task`). Removal itself initialises WebKit on the main actor first.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        await music.reconcileWebStores()
                    }
                }
            } catch {
                diagnosticLog.record(.storage, component: "launch", detail: "Local storage could not open.")
                await artworkLifecycle?.stop(); artworkLifecycle = nil; artwork = nil; failure = true
            }
        }
        self.task = task; await task.value
        profiler?.record(.launchToAccountReady, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - launchStart) / 1_000_000)
    }
    private static func productionDirectory() async throws -> URL {
        try await Task.detached {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }.value.appendingPathComponent("local.native-music.development")
    }
}
/// Adapts the account's Keychain-backed player cookies to the Playback seam.
struct KeychainMusicCookieSource: WebMusicCookieSource {
    let cookies: MusicPlayerCookies?
    func playerCookies() async throws -> [HTTPCookie] {
        guard let cookies else { throw MusicSessionError.stale }
        return try await cookies.playerCookies()
    }
    /// Stale or failed write-backs are dropped: the record keeps its last good session.
    func recordRotation(_ updates: [HTTPCookie]) async { _ = try? await cookies?.recordRotation(updates) }
}
struct LocalAccountRoot: View {
    @Bindable var accounts: LocalAccountBootstrap
    @State private var panels: AdaptivePanelPresentation<BrowserShell.TrailingPanel>
    @State private var navigation: BrowserNavigation
    private let showsQAReadouts: Bool?
    init(accounts: LocalAccountBootstrap, panels: AdaptivePanelPresentation<BrowserShell.TrailingPanel> = .init(), navigation: BrowserNavigation = .init(), showsQAReadouts: Bool? = nil) {
        self.showsQAReadouts = showsQAReadouts
        self.accounts = accounts; _panels = State(initialValue: panels); _navigation = State(initialValue: navigation)
    }
    var body: some View {
        BrowserShell(accounts: accounts, panels: panels, navigation: navigation, showsQAReadouts: showsQAReadouts)
            .overlay(alignment: .top) {
                if accounts.failure {
                    HStack {
                        Text("Local storage could not open. Existing data was preserved.")
                        Button("Retry local storage") { Task { await accounts.retryLocalStorage() } }.musicButtons()
                    }.padding(MusicSpace.sm).musicSurface().padding(MusicSpace.sm)
                }
            }
    }
}
