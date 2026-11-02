import AppKit
import Foundation
import Testing
import Domain
import AccountSession
import OutputRoutes
import Queue
import SystemIntegration
import WidgetShared
import Updates
@testable import Playback
@testable import Features
@testable import AppShell

/// A scripted download engine behind the same seams the real one answers.
final class SettingsFakeEngine: DownloadsControlling, DownloadsSettingsControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var budget: Int64 = DownloadBudgetChoices.defaultBytes, smart = false, expensive = false
    private(set) var calls: [String] = []
    var current: DownloadsSnapshot {
        lock.withLock { DownloadsSnapshot(rows: [], collections: [], aggregate: nil, activeCount: 0, waitingCount: 0,
            storage: DownloadStorageSummary(usedBytes: 0, budgetBytes: budget, reserveBytes: 0, volumeAvailableBytes: 0, pinnedBytes: 0, automaticBytes: 0, automaticCapBytes: 0),
            storageChoices: [], smartDownloadsEnabled: smart, concurrencyLimit: 2, lowPowerMode: false, networkConstrained: false, networkExpensive: false, networkAvailable: true, hasAccount: true) }
    }
    func snapshot() async -> DownloadsSnapshot { current }
    func updates() async -> AsyncStream<DownloadsSnapshot> { AsyncStream { $0.yield(self.current); $0.finish() } }
    func perform(_ action: DownloadAction, job: UUID) async -> DownloadCommandResult { .done }
    func setBudget(bytes: Int64) async -> DownloadCommandResult { lock.withLock { budget = bytes; calls.append("budget") }; return .done }
    func setSmartDownloads(enabled: Bool) async -> DownloadCommandResult { lock.withLock { smart = enabled; calls.append("smart") }; return .done }
    func addLocalFile(_ file: URL) async -> DownloadCommandResult { .done }
    func play(job: UUID) async -> DownloadCommandResult { .done }
    func removeAutomaticDownloads() async -> DownloadCommandResult { .done }
    func setAutomaticOnExpensive(enabled: Bool) async -> DownloadCommandResult { lock.withLock { expensive = enabled; calls.append("expensive") }; return .done }
    func automaticOnExpensiveAllowed() async -> Bool { lock.withLock { expensive } }
    func usage(for account: AccountContext) async -> AccountDownloadUsage { AccountDownloadUsage() }
    func usageAcrossAccounts() async -> AccountDownloadUsage { AccountDownloadUsage() }
    func usageOutside(_ accounts: [AccountContext]) async -> AccountDownloadUsage { AccountDownloadUsage() }
    func objectStoreBytes() async -> Int64 { 0 }
}

/// The real owners behind one settings store: the shell with its login item, notification model and shortcut service, the mini-player's preferences, the Spotlight
/// opt-ins, a download model over a scripted engine and the output coordinator over a scripted directory. All in memory or in one scratch preferences suite.
@MainActor final class SettingsRig {
    let defaults: UserDefaults
    let guarded: GuardedDefaults
    let suite: String
    let login = InMemoryLoginItemService()
    let shell: ShellCoordinator
    let store: SettingsStore
    let engine = SettingsFakeEngine()
    let downloads: DownloadsModel
    let mirror: DownloadSettingsMirror
    let outputs: OutputController
    let routeStore = MemoryPreferredRoute(OutputRouteID.device(uid: "SCRIPTED-BT-HEADPHONES"))
    let notifications = RecordingNotifications()
    let hotKeys = RecordingHotKeys()
    let box = AccountBox(UUID())
    let scratch: Scratch
    /// W30: the updater behind the two update rows (a signed feed that offers 1.2.0, a fake image and extractor, a playback flag; scratch folders only).
    let updateKit: UpdateKit

    init() throws {
        scratch = try Scratch()
        let (guarded, defaults, suite) = privateDefaults(scratch.url.appendingPathComponent("prefs.plist").path)
        self.guarded = guarded; self.defaults = defaults; self.suite = suite
        let vault = try isolatedVault().0
        let authority = AppPlaybackAuthority(directory: scratch.url.appendingPathComponent("owned"), offlineVault: vault)
        let application = SettingsFakeApplication()
        shell = ShellCoordinator(playback: PlaybackModel(authority: authority), loginItem: login, application: application, preferences: defaults, installsStatusItem: false,
                                 windows: ShellWindowRegistry(application: application, settle: .zero, schedule: { _, work in work() }),
                                 facilities: IntegrationFacilities(hotKeys: hotKeys, notifications: notifications))
        updateKit = try UpdateKit(defaults: defaults, scratch: scratch.url)
        shell.updates = updateKit.controller
        shell.notifications = NotificationSettingsModel(service: notifications, preferences: defaults)
        shell.globalShortcuts = GlobalShortcutService(store: GlobalShortcutStore(defaults: defaults), registrar: hotKeys, perform: { _ in })
        let box = self.box
        store = try SettingsStore(backing: guarded, account: { box.account })
        downloads = DownloadsModel(controller: engine)
        mirror = DownloadSettingsMirror(engine: engine)
        outputs = OutputController(coordinator: OutputRouteCoordinator(directory: ScriptedOutputDirectory(), store: routeStore), applier: NoOutputApplier())
        let outputs = self.outputs
        SettingsOwners.attach(to: store, shell: shell, downloads: downloads, downloadMirror: mirror, outputs: { outputs }, profiler: { nil })
    }
    func cleanup() { try? guarded.removeAll(); scratch.cleanup() }
}

@MainActor func eventually(_ timeout: Double = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}

/// The same wait with an async condition, on the monotonic clock (a wall-clock jump neither cuts it short nor stretches it).
@MainActor func eventuallyAsync(_ timeout: Double = 8, _ condition: @MainActor () async -> Bool) async -> Bool {
    let end = ContinuousClock.now.advanced(by: .seconds(timeout))
    while ContinuousClock.now < end { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return await condition()
}

actor RecordingResumeStore: MusicResumeStoring {
    private(set) var loads = 0
    func save(_ record: MusicResumeRecord, account: String) {}
    func load(account: String) -> MusicResumeRecord? { loads += 1; return nil }
    func clear(account: String) {}
}

/// The app's OWN wiring, composed: a `LocalAccountBootstrap` over this process's isolated storage, loaded, with one account signed in and active. The effect checks of the
/// settings the app consumes through its composition read the composed objects, so removing the wiring from the app fails them (review finding 4).
@MainActor final class ComposedRig {
    let bootstrap: LocalAccountBootstrap
    let account: Account
    private init(bootstrap: LocalAccountBootstrap, account: Account) { self.bootstrap = bootstrap; self.account = account }
    /// `quietAudio` makes the composed playback model start owned audio at the controlled gain (0.001), the way the UI tests do; the test proves it before any start.
    static func make(quietAudio: Bool = false) async throws -> ComposedRig {
        if quietAudio { setenv("YTMUSE_OWNED_AUDIO_TEST_GAIN", "0.001", 1) }
        let bootstrap = LocalAccountBootstrap(loginItem: InMemoryLoginItemService())
        if quietAudio { unsetenv("YTMUSE_OWNED_AUDIO_TEST_GAIN") }
        bootstrap.installSystemSurfaces(hub: IntentHub(), receiver: WidgetCommandReceiver())
        await bootstrap.load()
        // The isolated session's preferences file is shared by every composed test in this process: start each from the defaults, as a fresh launch would.
        try await bootstrap.settings.resetAll(); bootstrap.settings.refreshAfterErase()
        let lifecycle = try #require(bootstrap.lifecycleHandle)
        let account = try syntheticAccount("UCwiring00001", name: "Wiring Listener")
        let challenge = try await lifecycle.beginAuthentication()
        try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("synthetic-disposable-session".utf8))
        await bootstrap.model.refresh()
        await bootstrap.model.switchIdentity(account.context)
        return ComposedRig(bootstrap: bootstrap, account: account)
    }
    func finish() async { await bootstrap.shutdown() }
    var settings: SettingsStore { bootstrap.settings }
    /// A silent native session: decoded rendering into a buffer, no audio output.
    func manualSession() async throws -> PlaybackSession {
        let media = OwnedMedia()
        let context = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
        return try await PlaybackSession.open(context: context, persistence: MemoryQueuePersistence(), assets: media, resolver: media, capabilities: media, automaticTick: false,
                                              initialGain: 0.001, initiallyMuted: false, maximumStartGain: 0.001, manualDecodedRendering: true)
    }
}

/// T27.2. For every setting, observe its real downstream effect or its genuine restriction. `effectChecks` has one entry per registry id; a setting added without an
/// effect check fails `everySettingHasAnEffectCheck`. The settings the app consumes through its COMPOSITION are checked on the composed objects (`WiringTests`).
@Suite @MainActor struct SettingsEffectTests {
    typealias Check = @MainActor (SettingsRig) async throws -> Void
    static let effectChecks: [String: Check] = [
        "appearance": { rig in
            #expect(Appearance(storedValue: rig.store.text("appearance")).colorScheme == nil, "system follows the Mac")
            try await rig.store.set("appearance", .text("dark"))
            #expect(Appearance(storedValue: rig.defaults.string(forKey: "appearance")).colorScheme == .dark, "the window's own preferred scheme reads the same key")
        },
        "artworkAccent": { _ in /* observed on the composed bootstrap: WiringTests.artworkAccent... */ #expect(SettingsRegistry.definition("artworkAccent")?.isStored == true) },
        "motion": { _ in
            #expect(ShellMotion.animates(reduceMotion: false, lowPower: false))
            #expect(!ShellMotion.animates(reduceMotion: true, lowPower: false) && !ShellMotion.animates(reduceMotion: false, lowPower: true), "follows system accessibility and power state")
        },
        "launchAtLogin": { rig in
            #expect(!rig.shell.loginItem.isOn && rig.login.registerCount == 0, "nothing registers until the toggle")
            try await rig.store.set("launchAtLogin", .bool(true))
            #expect(rig.shell.loginItem.isOn && rig.login.registerCount == 1 && rig.store.bool("launchAtLogin"))
            _ = try await rig.store.reset(.general)
            #expect(!rig.shell.loginItem.isOn && rig.login.unregisterCount == 1, "restore defaults unregisters it")
        },
        "backgroundControl": { _ in try await Self.closingTheLastWindowKeepsTheStatusItemAndHidesTheDock() },
        "dockIcon": { _ in try await Self.closingTheLastWindowKeepsTheStatusItemAndHidesTheDock() },
        "restoreSession": { rig in
            // The gate itself (the app's wiring of it is WiringTests.restoreSession...).
            let store = RecordingResumeStore()
            let account = try syntheticAccount()
            let identity = LocalIdentity(account: account, state: .connected)
            rig.shell.playback.resumeStore = store
            rig.shell.playback.restoreEnabled = { [weak rig] in rig?.store.bool("restoreSession") ?? true }
            try await rig.shell.playback.authority.restorePaused(identity, context: RequestContext(account: account.context, accountGeneration: 4, requestGeneration: 0))
            await rig.shell.playback.restoreLastSession()
            #expect(await store.loads == 1, "on by default: the last session is looked up")
            try await rig.store.set("restoreSession", .bool(false))
            await rig.shell.playback.restoreLastSession()
            #expect(await store.loads == 1, "off: the record is not even read")
        },
        "miniPlayerOnTop": { rig in
            #expect(!rig.store.bool("miniPlayerOnTop"))
            try await rig.store.set("miniPlayerOnTop", .bool(true))
            #expect(MiniPlayerPreferences.load(from: rig.defaults).pinned && rig.store.bool("miniPlayerOnTop"), "the mini-player's own pinned preference")
            let panel = MiniPlayerPanel(contentRect: NSRect(x: -3000, y: -3000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
            MiniPlayerController.configure(panel, preferences: MiniPlayerPreferences.load(from: rig.defaults))
            #expect(panel.level == .floating && panel.isFloatingPanel, "pinned floats above other windows")
            _ = try await rig.store.reset(.general)
            #expect(!MiniPlayerPreferences.load(from: rig.defaults).pinned)
        },
        "headphoneDisconnect": { _ in
            let headphones = OutputDevice(uid: "BT", name: "Headphones", transportCode: 0x626C_7565, hasDeviceVolume: true)
            let speakers = OutputDevice(uid: "SPK", name: "Speakers", transportCode: 0x626C_746E, hasDeviceVolume: true)
            let identity = headphones.identity
            #expect(RouteLossPolicy.assess(audible: identity, in: OutputSnapshot(devices: [speakers], defaultUID: "SPK")) == .lost(.deviceDisconnected), "a gone route is a LOSS, which pauses")
            #expect(RouteLossPolicy.assess(audible: identity, in: OutputSnapshot(devices: [speakers, headphones], defaultUID: "BT")) == .unchanged, "reconnecting is not a resume: no assessment ever asks for one")
        },
        "audioQuality": { _ in Self.mustBeUnavailable("audioQuality", plannedIn: "W34") },
        "crossfade": { rig in
            #expect(ChosenAudioEffects.make(from: rig.store)?.bypass == true, "defaults leave the audio untouched")
            try await rig.store.set("crossfade", .double(5))
            #expect(ChosenAudioEffects.make(from: rig.store)?.crossfade == 5)
            _ = try await rig.store.reset(.playback)
            #expect(ChosenAudioEffects.make(from: rig.store)?.crossfade == 0)
        },
        "equalizer": { rig in
            try await rig.store.set("equalizer", .text("bass"))
            #expect(ChosenAudioEffects.make(from: rig.store)?.bands == EqualizerPreset.bass.bands && EqualizerPreset.bass.bands != EqualizerPreset.flat.bands)
            for preset in EqualizerPreset.allCases { #expect((try? AudioEffects(bands: preset.bands)) != nil, "\(preset) is a valid ten-band request") }
        },
        "normalization": { rig in
            try await rig.store.set("normalization", .bool(true))
            #expect(ChosenAudioEffects.make(from: rig.store)?.normalize == true)
        },
        "autoplayRadio": { _ in
            // C5: the row is read-only because YouTube Music's player owns what plays next, not because a feature is planned.
            let definition = SettingsRegistry.definition("autoplayRadio")
            #expect(definition?.availability.isControllable == false && definition?.availability.note?.contains("YouTube Music") == true)
        },
        "replaceExplicitQueue": { rig in
            #expect(ReplacementPreference(rawValue: rig.store.text("replaceExplicitQueue")) == .ask, "Ask by default")
            try await rig.store.set("replaceExplicitQueue", .text("keep"))
            #expect(ReplacementPreference(rawValue: rig.store.text("replaceExplicitQueue")) == .keep)
        },
        "outputRoute": { rig in
            #expect(rig.routeStore.load() != nil)
            _ = try await rig.store.reset(.playback)
            #expect(rig.routeStore.load() != nil, "Restore Defaults on Playback leaves the remembered output alone")
            try await rig.store.restoreOne("outputRoute")
            #expect(rig.routeStore.load() == nil && rig.outputs.coordinator.preferred == nil, "forgetting it is its own action: the system default again")
            #expect(rig.store.text("outputRoute") == "systemDefault")
        },
        "songVideo": { _ in
            let policy = SettingsRegistry.definition("songVideo")
            #expect(policy?.storage == .policy && policy?.defaultValue == .text("audioWhenPermitted"))
        },
        "newPlaylistVisibility": { _ in /* observed on the composed bootstrap: WiringTests */ #expect(SettingsRegistry.definition("newPlaylistVisibility")?.scope == .account) },
        "downloadStorage": { rig in
            #expect(rig.store.double("downloadStorage") == 20 && rig.downloads.snapshot.storage.budgetBytes == 20 << 30)
            try await rig.store.set("downloadStorage", .double(50))
            #expect(await eventually { rig.engine.current.storage.budgetBytes == 50 << 30 }, "the engine's budget changed")
        },
        "smartDownloads": { rig in
            try await rig.store.set("smartDownloads", .bool(true))
            #expect(await eventually { rig.engine.current.smartDownloadsEnabled }, "the engine's own switch (eligibility stays the engine's)")
        },
        "automaticOnExpensive": { rig in
            #expect(!rig.mirror.automaticOnExpensive)
            try await rig.store.set("automaticOnExpensive", .bool(true))
            #expect(await rig.engine.automaticOnExpensiveAllowed() && rig.store.bool("automaticOnExpensive"))
            _ = try await rig.store.reset(.downloads)
            #expect(await eventually { !rig.engine.current.smartDownloadsEnabled && rig.engine.current.storage.budgetBytes == 20 << 30 })
            #expect(await !rig.engine.automaticOnExpensiveAllowed())
        },
        "trackChangeNotifications": { rig in
            #expect(rig.notifications.requestCount == 0 && !rig.store.bool("trackChangeNotifications"), "nothing asks for permission until the toggle")
            try await rig.store.set("trackChangeNotifications", .bool(true))
            #expect(rig.notifications.requestCount == 1 && rig.store.bool("trackChangeNotifications"))
            _ = try await rig.store.reset(.integration)
            #expect(!rig.store.bool("trackChangeNotifications"))
        },
        "downloadErrorNotifications": { rig in
            let finished = StatusNotification.make(.downloadFinished, item: "Kept Tone")
            await rig.shell.notifications?.statusEvent(finished)
            #expect(rig.notifications.postedStatus.isEmpty && rig.notifications.requestCount == 0, "off by default: nothing posted, nothing asked")
            try await rig.store.set("downloadErrorNotifications", .bool(true))
            #expect(rig.notifications.requestCount == 1 && rig.store.bool("downloadErrorNotifications"), "turning it on is what asks")
            await rig.shell.notifications?.statusEvent(finished)
            await rig.shell.notifications?.statusEvent(.make(.downloadFailed, item: "Kept Tone"))
            #expect(rig.notifications.postedStatus.map(\.kind) == [.downloadFinished, .downloadFailed])
            #expect(rig.notifications.posted.isEmpty, "song notifications are a separate opt-in")
            _ = try await rig.store.reset(.integration)
            await rig.shell.notifications?.statusEvent(finished)
            #expect(rig.notifications.postedStatus.count == 2 && !rig.store.bool("downloadErrorNotifications"), "restoring defaults turns it off")
        },
        "spotlightIndexing": { rig in
            #expect(!rig.shell.spotlightSettings.enabled)
            try await rig.store.set("spotlightIndexing", .bool(true))
            #expect(rig.shell.spotlightSettings.enabled)
            _ = try await rig.store.reset(.integration)
            #expect(!rig.shell.spotlightSettings.enabled && !rig.shell.spotlightSettings.includePrivate)
        },
        "spotlightPrivate": { rig in
            try await rig.store.set("spotlightPrivate", .bool(true))
            #expect(rig.shell.spotlightSettings.includePrivate)
            _ = try await rig.store.reset(.integration)
            #expect(!rig.shell.spotlightSettings.includePrivate)
        },
        "globalShortcuts": { rig in
            let service = try #require(rig.shell.globalShortcuts)
            #expect(service.assigned.isEmpty && rig.hotKeys.registerCalls == 0, "unassigned: nothing is registered")
            #expect(service.assign(KeyChord("j", [.control, .option, .command]), to: .playPause) == nil)
            #expect(rig.store.text("globalShortcuts") == "assigned" && !rig.hotKeys.registrations.isEmpty)
            _ = try await rig.store.reset(.integration)
            #expect(service.assigned.isEmpty && rig.hotKeys.registrations.isEmpty && rig.store.text("globalShortcuts") == "unassigned", "restore defaults clears and unregisters them")
        },
        "analytics": { _ in
            let manifest = try SettingsSources.text("Packages/NativeMusic/Package.swift")
            #expect(!manifest.lowercased().contains("analytics") && !manifest.lowercased().contains("telemetry") && !manifest.lowercased().contains("crashlytics") && !manifest.lowercased().contains("sentry"))
            #expect(SettingsRegistry.definition("analytics")?.defaultValue == .text("off"))
        },
        "updateChecking": { rig in
            // The row is the opt-in: nothing is requested until the person chooses, then at most one check a day; "only when I choose" and Restore Defaults stop it again.
            let updates = rig.shell.updates!, net = rig.updateKit.network
            #expect(rig.store.text("updateChecking") == "askOnce" && updates.shouldAskOnce)
            await updates.checkIfDue()
            #expect(net.feedRequests == 0, "ask once: no request on its own initiative")
            try await rig.store.set("updateChecking", .text("daily"))
            #expect(updates.state.mode == .daily && !updates.shouldAskOnce && rig.store.text("updateChecking") == "daily")
            await updates.checkIfDue()
            #expect(net.feedRequests == 1, "opted in: the daily check is real")
            await updates.checkIfDue()
            #expect(net.feedRequests == 1, "and runs at most once a day")
            try await rig.store.set("updateChecking", .text("manualOnly"))
            await updates.checkIfDue()
            #expect(net.feedRequests == 1 && rig.store.text("updateChecking") == "manualOnly", "declined: no automatic request")
            try await rig.store.set("updateChecking", .text("daily"))
            _ = try await rig.store.reset(.updates)
            #expect(updates.state.mode == .undecided && rig.store.text("updateChecking") == "askOnce" && updates.shouldAskOnce, "Restore Defaults asks again, and checks nothing")
            await updates.checkIfDue()
            #expect(net.feedRequests == 1)
        },
        "automaticInstallation": { rig in
            // "Automatic installation": an update is downloaded and verified only when idle and never swapped in without the explicit restart.
            let updates = rig.shell.updates!, kit = rig.updateKit
            #expect(!rig.store.bool("automaticInstallation"))
            await updates.checkNow()
            #expect(updates.status == .offered("1.2.0") && kit.network.assetRequests == 0, "off: an update is found, nothing is downloaded")
            try await rig.store.set("automaticInstallation", .bool(true))
            kit.playback.playing = true
            await updates.checkNow()
            #expect(updates.status == .offered("1.2.0") && kit.network.assetRequests == 0, "on, but while playing: nothing is downloaded")
            kit.playback.playing = false
            await updates.checkNow()
            #expect(updates.status == .ready("1.2.0") && kit.network.assetRequests == 1, "on and idle: downloaded and verified")
            #expect(kit.installedVersion == "1.0.0" && kit.relauncher.relaunched.isEmpty, "never installed by itself")
            updates.restartToInstall(confirmation: nil)
            #expect(updates.installFailure == "restartNotRequested" && kit.installedVersion == "1.0.0", "an explicit restart is required")
            kit.playback.playing = true
            updates.restartToInstall(confirmation: .fromPersonAction())
            #expect(updates.installFailure == "playbackActive" && kit.installedVersion == "1.0.0" && kit.relauncher.relaunched.isEmpty, "and never while playing")
            _ = try await rig.store.reset(.updates)
            #expect(!updates.state.automaticInstallation && !rig.store.bool("automaticInstallation"), "Restore Defaults turns it off")
        },
        "resumeAfterWake": { rig in
            #expect(ShellPreferences.resumeAfterWake(rig.defaults))
            try await rig.store.set("resumeAfterWake", .bool(false))
            #expect(!ShellPreferences.resumeAfterWake(rig.defaults))
        },
        "statusTooltip": { rig in
            try await rig.store.set("statusTooltip", .bool(false))
            #expect(!ShellPreferences.tooltipEnabled(rig.defaults))
        },
        "profiling": { rig in
            #expect(!rig.store.bool("profiling"))
            #expect(rig.store.hasOwner("diagnostics"))
        },
    ]

    static func mustBeUnavailable(_ id: String, plannedIn: String) {
        let definition = SettingsRegistry.definition(id)
        #expect(definition?.availability.isControllable == false && definition?.availability.note?.contains(plannedIn) == true, "\(id) says it is planned in \(plannedIn), not that it is impossible")
    }
    @MainActor static func closingTheLastWindowKeepsTheStatusItemAndHidesTheDock() async throws {
        let app = SettingsFakeApplication()
        let registry = ShellWindowRegistry(application: app, settle: .zero, schedule: { _, work in work() })
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.orderFrontRegardless()
        registry.register(window, role: .browser)
        #expect(registry.regularWindowCount == 1 && app.presence == .regular, "visible with a regular window")
        window.close()
        #expect(await eventually { app.presence == .accessory }, "hidden when only the menu bar remains; the app and its playback keep running (closing a window quits nothing)")
        #expect(ShellWindowRole.miniPlayer.keepsDockPresence == false && ShellWindowRole.browser.keepsDockPresence)
    }

    /// W30: a build without an update feed (every source build): the same writes change nothing and nothing is ever requested, and the rows are honest about it.
    @Test func withoutAFeedTheUpdateRowsWriteNothingAndNothingIsRequested() async throws {
        let rig = try SettingsRig(); defer { rig.cleanup() }
        let kit = try UpdateKit(defaults: rig.defaults, scratch: rig.scratch.url.appendingPathComponent("nofeed"), configured: false)
        rig.shell.updates = kit.controller
        try await rig.store.set("updateChecking", .text("daily")); try await rig.store.set("automaticInstallation", .bool(true))
        await kit.controller.checkIfDue(); await kit.controller.checkNow()
        #expect(!kit.controller.isAvailable && kit.controller.state.mode == .undecided && !kit.controller.state.automaticInstallation && kit.network.feedRequests == 0)
        for id in ["updateChecking", "automaticInstallation"] { #expect(SettingsRegistry.definition(id)?.availability.note?.contains("source build has none") == true, "the row says a source build checks nothing") }
    }

    @Test func everySettingHasAnEffectCheck() {
        #expect(Set(Self.effectChecks.keys) == Set(SettingsRegistry.definitions.map(\.id)), "a setting without an effect check, or a check for a setting that is gone")
    }
    @Test func everySettingShowsItsDownstreamEffectOrItsGenuineRestriction() async throws {
        for definition in SettingsRegistry.definitions {
            let rig = try SettingsRig(); defer { rig.cleanup() }
            let check = try #require(Self.effectChecks[definition.id], "\(definition.id)")
            try await check(rig)
        }
    }
}

extension ComposedBootstrapSuites {
/// Review finding 4: the effect of a setting the app consumes through its composition is observed on the COMPOSED app, so removing the wiring fails a test.
@Suite @MainActor struct WiringTests {
    @Test func artworkAccentTheShellAsksTheSettingAndNothingElse() async throws {
        let rig = try await ComposedRig.make(); defer { Task { await rig.finish() } }
        #expect(rig.bootstrap.playerAccent(web: "web", artwork: "art", usesWebPlayer: true) == "web", "on by default")
        try await rig.settings.set("artworkAccent", .bool(false))
        #expect(rig.bootstrap.playerAccent(web: "web", artwork: "art", usesWebPlayer: true) == nil, "off removes the tint")
        // And the shell uses exactly that function.
        let shell = try SettingsSources.text("Packages/NativeMusic/Sources/AppShell/BrowserShell.swift")
        #expect(shell.contains("accounts.playerAccent(web: webAccent, artwork: artworkLight"), "BrowserShell asks the composed setting")
    }
    @Test func newPlaylistVisibilityTheComposedCreatorStartsAtTheAccountsChoice() async throws {
        let rig = try await ComposedRig.make(); defer { Task { await rig.finish() } }
        let surface = rig.bootstrap.makePlaylistSurface()
        #expect(surface.creator.startingVisibility() == .private, "private by default")
        try await rig.settings.set("newPlaylistVisibility", .text("unlisted"))
        #expect(surface.creator.startingVisibility() == .unlisted, "the composed creator follows this account's stored choice")
        try await rig.settings.set("newPlaylistVisibility", .text("public"))
        #expect(surface.creator.startingVisibility() == .public)
    }
    @Test func restoreSessionTheComposedPlaybackGateFollowsTheSetting() async throws {
        let rig = try await ComposedRig.make(); defer { Task { await rig.finish() } }
        #expect(rig.bootstrap.playback.restoreEnabled(), "on by default")
        try await rig.settings.set("restoreSession", .bool(false))
        #expect(!rig.bootstrap.playback.restoreEnabled())
    }
    @Test func crossfadeEqualizerNormalizationTheComposedProviderFeedsNativeSessions() async throws {
        let rig = try await ComposedRig.make(); defer { Task { await rig.finish() } }
        let session = try await rig.manualSession(); defer { Task { await session.close(reason: .accountSwitch) } }
        let opened = await session.currentEffects()
        try await session.startOwnedMedia(OwnedMedia.items)
        let started = await session.currentEffects()
        let stored = rig.settings.double("crossfade")
        await rig.bootstrap.playback.applyChosenEffects(to: session)
        let before = await session.currentEffects()
        #expect(before.crossfade == 0 && !before.normalize, "defaults leave a native session without crossfade or normalization (opened \(opened.crossfade), started \(started.crossfade), stored \(stored), after \(before.crossfade))")
        try await rig.settings.set("crossfade", .double(4)); try await rig.settings.set("equalizer", .text("vocal")); try await rig.settings.set("normalization", .bool(true))
        await rig.bootstrap.playback.applyChosenEffects(to: session)
        let effects = await session.currentEffects()
        #expect(effects.crossfade == 4 && effects.bands == EqualizerPreset.vocal.bands && effects.normalize, "the native session now carries the chosen effects")
        let panel = try SettingsSources.text("Packages/NativeMusic/Sources/AppShell/PlaybackPanel.swift")
        #expect(panel.components(separatedBy: "await applyChosenEffects(to: player)").count - 1 == 2, "both native starts apply them; the hidden player is never processed")
    }
    @Test func replaceExplicitQueueNativeStartsHonourTheComposedPreference() async throws {
        let rig = try await ComposedRig.make(); defer { Task { await rig.finish() } }
        #expect(rig.bootstrap.playback.replacementPreference() == .ask)
        try await rig.settings.set("replaceExplicitQueue", .text("keep"))
        #expect(rig.bootstrap.playback.replacementPreference() == .keep)
        // The session honours each choice when a new context starts with songs the person queued.
        for choice in [ReplacementPreference.replace, .keep, .ask] {
            let session = try await rig.manualSession(); defer { Task { await session.close(reason: .accountSwitch) } }
            try await session.startOwnedMedia([OwnedMedia.items[0]])
            try await session.sendQueue(.playNext([OwnedMedia.items[1]]))
            func queued() async throws -> Int {
                let snapshot = try await session.snapshot().queue.session
                return snapshot.entries.filter { !$0.consumed && $0.id != snapshot.currentOccurrence && [.playNext, .addToQueue, .user].contains($0.segment) }.count
            }
            #expect(try await queued() == 1)
            switch choice {
            case .replace: try await session.startOwnedMedia([OwnedMedia.items[0]], replacement: .replace); #expect(try await queued() == 0, "replace drops the queued song")
            case .keep: try await session.startOwnedMedia([OwnedMedia.items[0]], replacement: .keep); #expect(try await queued() == 1, "keep carries it over")
            case .ask:
                await #expect(throws: QueueError.confirmationRequired) { try await session.startOwnedMedia([OwnedMedia.items[0]], replacement: .ask) }
                #expect(try await queued() == 1, "ask changes nothing until the person decides")
            }
        }
        let panel = try SettingsSources.text("Packages/NativeMusic/Sources/AppShell/PlaybackPanel.swift")
        #expect(panel.components(separatedBy: "await settleReplacement(retry:").count - 1 == 2, "both native starts settle the question first")
    }
    /// R2-3. The Ask and Keep paths the way the app takes them: the preference comes from the stored setting through the composition, a second native start finds the songs
    /// the person queued, asks, and the answer (the dialog's `resolveReplacement`) restarts the start with the songs carried (Keep) or dropped (Replace). No test-only setter.
    @Test func askThenKeepCarriesTheQueuedSongsAndReplaceDropsThemThroughThePlaybackModelsOwnStart() async throws {
        let rig = try await ComposedRig.make(quietAudio: true); defer { Task { await rig.finish() } }
        let playback = rig.bootstrap.playback
        try #require(playback.controlledAudioTest, "fail safe: owned audio only ever starts at the controlled gain in a test")
        #expect(playback.replacementPreference() == .ask)
        await playback.startOwned(request: playback.authority.requestOwnedStart())
        let first = try #require(playback.session, "the first native start opened a session")
        try await first.sendQueue(.playNext([OwnedMedia.items[1]]))
        let queuedBefore = await playback.explicitQueuedMedia()
        try #require(queuedBefore == [OwnedMedia.items[1]], "the person has one queued song")
        // A new native context starts: with Ask the model asks first and changes nothing.
        await playback.startOwned(request: playback.authority.requestOwnedStart())
        #expect(playback.pendingReplacement?.count == 1, "Ask: the question is shown")
        let queuedWhileAsking = await playback.explicitQueuedMedia()
        #expect(playback.session === first && queuedWhileAsking == queuedBefore, "and nothing changed while it is open")
        // Keep: the answer restarts the start and the queued song is still queued.
        playback.resolveReplacement(.keep)
        #expect(playback.pendingReplacement == nil)
        #expect(await eventuallyAsync { playback.session !== first }, "the start ran after the answer")
        #expect(await eventuallyAsync { await playback.explicitQueuedMedia() == queuedBefore }, "Keep: the songs the person queued are carried into the new context")
        // Replace: ask again, answer Replace, and the queued song is gone.
        await playback.startOwned(request: playback.authority.requestOwnedStart())
        #expect(playback.pendingReplacement?.count == 1)
        let second = playback.session
        playback.resolveReplacement(.replace)
        #expect(await eventuallyAsync { playback.session !== second }, "the start ran after the answer")
        #expect(await eventuallyAsync { await playback.explicitQueuedMedia().isEmpty }, "Replace: the queued songs were dropped")
        // With the preference stored as Keep the app does not ask at all.
        try await rig.settings.set("replaceExplicitQueue", .text("keep"))
        try await playback.session?.sendQueue(.playNext([OwnedMedia.items[1]]))
        await playback.startOwned(request: playback.authority.requestOwnedStart())
        #expect(playback.pendingReplacement == nil, "Keep stored: no question")
        #expect(await eventuallyAsync { await playback.explicitQueuedMedia() == [OwnedMedia.items[1]] })
    }
    @Test func askShowsTheQuestionAndTheAnswerResumesTheStartOnce() async throws {
        let rig = try await ComposedRig.make(); defer { Task { await rig.finish() } }
        let playback = rig.bootstrap.playback
        var resumed: [ReplacementPreference] = []
        playback.setPendingReplacementForTest(count: 2) { resumed.append($0) }
        #expect(playback.pendingReplacement?.count == 2)
        playback.resolveReplacement(.keep)
        #expect(playback.pendingReplacement == nil, "the state flips synchronously, before any Task the dialog button starts")
        playback.cancelReplacement()   // the dialog dismissing itself after the button must not undo the answer
        #expect(await eventually { resumed == [.keep] })
    }
}
}

/// W27 (Download/error notifications): what the detector announces.
@Suite struct DownloadEventDetectorTests {
    func row(_ id: UUID, _ phase: DownloadPhase, title: String = "Kept Tone") -> DownloadRowModel {
        DownloadRowModel(id: id, media: try! ServiceID("local-file:1"), title: title, subtitle: nil, origin: .localFile, phase: phase, progress: DownloadProgress(completedBytes: 0, totalBytes: nil), pauseCause: nil,
                         failure: phase == .failed ? .corruptBytes : nil, pinned: true, automatic: false, referenceCount: 1, storedBytes: 0, retryAt: nil, expiresAt: nil, actions: [])
    }
    @Test func theFirstSnapshotOnlySeedsAndFinishedAndFailedAreAnnouncedOnce() {
        var detector = DownloadEventDetector()
        let a = UUID(), b = UUID()
        #expect(detector.ingest([row(a, .available), row(b, .failed)]).isEmpty, "what was already done or failed is not news")
        #expect(detector.ingest([row(a, .available), row(b, .failed)]).isEmpty)
        let c = UUID()
        #expect(detector.ingest([row(a, .available), row(b, .failed), row(c, .downloading)]).isEmpty)
        #expect(detector.ingest([row(c, .available)]).map(\.kind) == [.downloadFinished])
        #expect(detector.ingest([row(c, .available)]).isEmpty, "announced once")
        let d = UUID()
        _ = detector.ingest([row(d, .downloading)])
        let failed = detector.ingest([row(d, .failed)])
        #expect(failed.map(\.kind) == [.downloadFailed] && failed.first?.body == "Kept Tone")
    }
    @Test func theMessagesCarryOnlyAFixedHeadlineAndTheTitle() {
        let leaky = StatusNotification.make(.downloadFinished, item: String(repeating: "x", count: 500))
        #expect(leaky.body?.count == 200 && leaky.title == "Download finished")
        #expect(StatusNotification.make(.signInNeeded).body?.contains("http") == false)
    }
}
