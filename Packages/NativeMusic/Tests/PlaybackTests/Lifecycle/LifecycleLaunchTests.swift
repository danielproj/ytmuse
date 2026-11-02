import AppKit
import CoreServices
import Foundation
import Testing
@testable import Playback
@testable import AppShell
import TestSupport

/// T21.4 (launch half): a login launch is menu-bar only; a cold launch restores paused; launch at login is off by default and is only ever changed
/// by the Settings toggle, through a protocol, and no test can reach the real login item.
@Suite @MainActor struct LifecycleLaunchTests {
    private func tempStore() -> (UserDefaults, () -> Void) {
        let store = InMemoryDefaults()
        return (store, {})
    }
    @Test func theShellsDefaultsAreTheSpecifiedOnes() {
        let (store, clean) = tempStore(); defer { clean() }
        #expect(ShellPreferences.tooltipEnabled(store) && ShellPreferences.resumeAfterWake(store), "the track tooltip is on and resuming after a wake is the default (WIN01, WIN08)")
        #expect(MiniPlayerPreferences.load(from: store) == MiniPlayerPreferences(pinned: false, expanded: false), "compact and not pinned until the person chooses")
        store.set(false, forKey: ShellPreferenceKey.resumeAfterWake); store.set(false, forKey: ShellPreferenceKey.statusTooltip)
        #expect(!ShellPreferences.tooltipEnabled(store) && !ShellPreferences.resumeAfterWake(store), "and both are the person's to turn off")
    }
    @Test func launchAtLoginIsOffByDefaultAndNothingRegistersUntilTheToggleIsPressed() {
        let service = InMemoryLoginItemService()
        let model = LoginItemModel(service: service)
        #expect(!model.isOn && model.status == .notRegistered && service.registerCount == 0 && service.unregisterCount == 0)
        model.refresh(); model.refresh()
        #expect(service.registerCount == 0, "reading the status is passive")
        model.setEnabled(true)
        #expect(model.isOn && service.registerCount == 1 && model.failure == nil)
        model.setEnabled(false)
        #expect(!model.isOn && service.unregisterCount == 1)
    }
    @Test func aLoginItemThatNeedsApprovalIsShownAsOnAndAFailureIsStatedNotHidden() {
        struct Refusing: LoginItemService {
            var status: LoginItemStatus { .notRegistered }
            func register() throws { throw NSError(domain: "synthetic", code: 1) }
            func unregister() throws {}
            var isInProcessFake: Bool { true }
        }
        let model = LoginItemModel(service: Refusing())
        model.setEnabled(true)
        #expect(!model.isOn && model.failure != nil, "the toggle does not claim success")
        #expect(LoginItemModel(service: InMemoryLoginItemService(status: .requiresApproval)).isOn)
    }
    @Test func aLoginLaunchIsRecognisedFromTheLaunchEventAndNothingElse() {
        #expect(LaunchKind.from(propertyData: AEKeyword(keyAELaunchedAsLogInItem)) == .login)
        #expect(LaunchKind.from(propertyData: nil) == .manual)
        #expect(LaunchKind.from(propertyData: 0x6F6F7070) == .manual)
        #expect(LaunchKind.from(environment: [:]) == nil)
        #expect(LaunchKind.from(environment: ["YTMUSE_SIMULATE_LOGIN_LAUNCH": "1"]) == nil, "the seam needs isolation too: an environment variable alone never changes a real launch")
        #expect(LaunchKind.from(environment: ["YTMUSE_UI_TEST_ISOLATED": "1", "YTMUSE_SIMULATE_LOGIN_LAUNCH": "1"]) == .login)
    }
    @Test func aLoginLaunchSuppressesTheFirstWindowOnceAndAManualLaunchNever() {
        LaunchContext.reset(kind: .login)
        #expect(LaunchContext.kind == .login)
        #expect(LaunchContext.consumeFirstWindowSuppression() && !LaunchContext.consumeFirstWindowSuppression(), "the first window only; every later one is the person's doing")
        LaunchContext.reset(kind: .manual)
        #expect(!LaunchContext.consumeFirstWindowSuppression())
    }
    @Test func aLoginLaunchStartsMenuBarOnlyAndAManualLaunchKeepsTheRegularPolicy() async throws {
        let (store, clean) = tempStore(); defer { clean() }
        let rig = try await LifecycleRig.make()
        for (kind, expected) in [(LaunchKind.login, DockPresence.accessory), (.manual, .regular)] {
            LaunchContext.reset(kind: kind)
            let application = FakeApplication()
            let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: application, preferences: store, installsStatusItem: false)
            shell.start()
            #expect(application.presence == expected, "\(kind)")
            shell.start()
            #expect(shell.started && shell.statusItem == nil, "started once; no real status item was created by the test")
            shell.stop(); #expect(!shell.started)
        }
        LaunchContext.reset(kind: .manual)
        #expect(rig.log.pages.isEmpty, "neither launch created, loaded or played anything")
    }
    @Test func reopeningFromTheStatusItemOrTheDockRestoresThePolicyAndReusesAHiddenWindow() async throws {
        let (store, clean) = tempStore(); defer { clean() }
        let rig = try await LifecycleRig.make()
        let application = FakeApplication(); application.presence = .accessory
        let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: application, preferences: store, installsStatusItem: false)
        var opened = 0
        shell.openMainWindowAction = { opened += 1 }
        shell.showMainWindow()
        #expect(application.presence == .regular && opened == 1 && application.activations == 1, "no window exists: one is opened")
        let hidden = lifecycleWindow(shown: false); defer { hidden.close() }
        hidden.alphaValue = 0
        shell.windows.register(hidden, role: .browser)
        application.presence = .accessory
        shell.showMainWindow()
        #expect(opened == 1 && hidden.alphaValue == 1 && hidden.isVisible && application.presence == .regular, "the window a login launch hid is shown, not duplicated")
        shell.openAnotherWindow()
        #expect(opened == 2, "Command-N opens another")
    }
    @Test func theLoginItemIsOnlyEverReachableThroughTheProtocolAndTheAppTargetsOneFile() async throws {
        let root = LifecycleSources.repositoryRoot
        let references = await LifecycleSources.offMain { LoginItemGuard.references(under: root) }
        #expect(references.contains { $0.hasPrefix(LoginItemGuard.appTargetFile + ":") }, "the app target's one file does name it (so this sweep is not vacuous)")
        let offenders = LoginItemGuard.offenders(references)
        #expect(offenders.isEmpty, "no package target, extension, script or test (this folder included) names the real login item: \(offenders)")
        let swiftPackage = try String(contentsOf: LifecycleSources.packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!swiftPackage.contains("ServiceManagement"))
    }
    /// The guard's own test runs the REAL sweep over a planted tree (a copy of its rule would pass whatever the sweep did).
    // F3 (real-data safety): an isolated launch ALWAYS gets the fake, at run time.
    @Test func everyIsolatedLaunchInputIsIsolatedAndRealStoresNeedAnExplicitOptIn() {
        #expect(LaunchStorageDecision.isIsolated, "this test process is an isolated one (a mutated isIsolated must fail here)")
        #expect(LaunchStorageDecision.isolated(environment: ["YTMUSE_UI_TEST_ISOLATED": "1"], arguments: []))
        #expect(LaunchStorageDecision.isolated(environment: [:], arguments: []), "in Debug a launch that lost its environment is isolated, never real")
        #expect(LaunchStorageDecision.isolated(environment: ["YTMUSE_UI_TEST_ISOLATED": "1", IsolatedQAStorage.realStoresKey: "1"], arguments: [IsolatedQAStorage.realStoresArgument]), "explicit isolation wins over any opt-in")
        #expect(LaunchStorageDecision.isolated(environment: ["YTMUSE_NATIVE_DESIGN_TEST": "1"], arguments: []))
        #expect(!LaunchStorageDecision.isolated(environment: [IsolatedQAStorage.realStoresKey: "1"], arguments: []), "the one way to real stores is the explicit opt-in")
    }
    @Test func anIsolatedLaunchIsGivenTheFakeAndTheSystemItemIsNotEvenBuilt() {
        var built = 0
        let service = LoginItemSelection.choose(system: { built += 1; return InMemoryLoginItemService(status: .enabled) })
        #expect(built == 0 && service.isInProcessFake && service.status == .notRegistered, "the fake (off), and the system closure never ran")
        #expect(LoginItemModel(service: service).usesInProcessFake)
    }
    @Test func theSettingsReadoutNamesTheServiceThatAnswersTheToggle() throws {
        let source = try LifecycleSources.source("Sources/AppShell/Lifecycle/ShellSettings.swift")
        #expect(source.contains("usesInProcessFake ? \"in-process fake\" : \"SYSTEM LOGIN ITEM\"") && source.contains("loginItemService"))
        #expect(InMemoryLoginItemService().isInProcessFake)
    }
    @Test func theGuardCatchesAPlantedReferenceInAnyTestFolderIncludingThisOne() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w21-login-guard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = root.appendingPathComponent("Packages/NativeMusic/Tests/PlaybackTests/Lifecycle")
        let others = root.appendingPathComponent("Tests/NativeMusicUITests")
        try FileManager.default.createDirectory(at: lifecycle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: others, withIntermediateDirectories: true)
        let service = "SMApp" + "Service"
        try ("import Service" + "Management\nfunc leak() { _ = \(service).mainApp.status }\n").write(to: lifecycle.appendingPathComponent("LifecycleSupport.swift"), atomically: true, encoding: .utf8)
        try ("func clean() { let note = \"\(service) is only named in a string\" }\n// \(service) in a comment\n").write(to: lifecycle.appendingPathComponent("Clean.swift"), atomically: true, encoding: .utf8)
        try ("import Service" + "Management\n").write(to: others.appendingPathComponent("UITests.swift"), atomically: true, encoding: .utf8)
        let found = LoginItemGuard.references(under: root)
        #expect(found.contains("Packages/NativeMusic/Tests/PlaybackTests/Lifecycle/LifecycleSupport.swift:1") && found.contains("Packages/NativeMusic/Tests/PlaybackTests/Lifecycle/LifecycleSupport.swift:2"),
                "a reference planted in the Lifecycle test folder is caught: \(found)")
        #expect(found.contains("Tests/NativeMusicUITests/UITests.swift:1"))
        #expect(!found.contains { $0.contains("Clean.swift") }, "a string literal or a comment that merely names it is not a use")
        #expect(LoginItemGuard.offenders(found).count == found.count, "none of these is the app target's file")
        // R2: a real use inside a string interpolation, and a two-space import, are seen; plain text in a string is not.
        try ("func a() { print(\"value: \\(\(service).mainApp.status)\") }\nimport  Service" + "Management\n").write(to: others.appendingPathComponent("Interpolated.swift"), atomically: true, encoding: .utf8)
        let again = LoginItemGuard.references(under: root)
        #expect(again.contains("Tests/NativeMusicUITests/Interpolated.swift:1") && again.contains("Tests/NativeMusicUITests/Interpolated.swift:2"), "\(again)")
        let appCopy = root.appendingPathComponent("App/Sources"); try FileManager.default.createDirectory(at: appCopy, withIntermediateDirectories: true)
        try ("import Service" + "Management\n").write(to: appCopy.appendingPathComponent("NativeMusicApp.swift"), atomically: true, encoding: .utf8)
        #expect(!LoginItemGuard.offenders(LoginItemGuard.references(under: root)).contains { $0.hasPrefix("App/") }, "the app target's one file is the single allowed place")
    }
    @Test func theDefaultProcessWideLoginItemIsTheFakeEverywhereExceptTheAppsComposition() throws {
        for name in ["NativeMusicScenes.swift", "LocalAccountComposition.swift"] {
            let source = try LifecycleSources.source("Sources/AppShell/" + name)
            #expect(source.contains("InMemoryLoginItemService()"), "\(name) defaults to the in-process fake")
        }
    }
}
