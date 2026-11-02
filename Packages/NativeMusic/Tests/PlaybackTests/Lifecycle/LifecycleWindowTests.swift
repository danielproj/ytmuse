import AppKit
import Domain
import Foundation
import SwiftUI
import Testing
@testable import Playback
@testable import AppShell
import TestSupport

/// T21.1 / T21.2 / T21.3: the window census, the activation policy, the hidden player and the mini-player never being a regular window, and the
/// mini-player's size, pin and focus rules.
@Suite @MainActor struct LifecycleWindowTests {
    /// A registry with a scripted clock: demotions run when the test says so.
    @MainActor private final class Clock { var work: [@MainActor () -> Void] = []; func runAll() { let batch = work; work = []; for item in batch { item() } } }
    private func registry(_ application: FakeApplication, _ clock: Clock) -> ShellWindowRegistry {
        ShellWindowRegistry(application: application, settle: .milliseconds(1), schedule: { _, work in clock.work.append(work) })
    }

    @Test func closingTheLastRegularWindowHidesTheDockAndAnyOpenWindowRestoresIt() {
        let application = FakeApplication(), clock = Clock(), windows = registry(application, clock)
        let main = lifecycleWindow(), second = lifecycleWindow()
        defer { main.close(); second.close() }
        windows.register(main, role: .browser); windows.register(second, role: .browser)
        #expect(windows.regularWindowCount == 2 && application.presence == .regular)
        second.close(); clock.runAll()
        #expect(windows.regularWindowCount == 1 && application.presence == .regular, "closing one of two keeps the Dock icon")
        main.close(); clock.runAll()
        #expect(windows.regularWindowCount == 0 && application.presence == .accessory, "the last regular window closed: audio and the menu bar stay, the Dock icon goes")
        let reopened = lifecycleWindow(); defer { reopened.close() }
        windows.register(reopened, role: .browser)
        #expect(application.presence == .regular, "any window opening again restores the regular policy at once, without waiting")
        #expect(application.changes == [.accessory, .regular])
    }
    @Test func aWindowThatHasNeverBeenOnScreenIsNotTheLastWindowClosed() {
        let application = FakeApplication(), clock = Clock(), windows = registry(application, clock)
        let opening = lifecycleWindow(shown: false); defer { opening.close() }
        windows.register(opening, role: .browser)
        windows.reconcile(); clock.runAll()
        #expect(application.presence == .regular && application.changes.isEmpty && clock.work.isEmpty, "a slow first window never makes the app drop its Dock icon while launching")
        opening.orderFrontRegardless(); windows.reconcile()
        opening.close(); clock.runAll()
        #expect(application.presence == .accessory, "once it has been shown, closing it is the last window closed")
    }
    @Test func aWindowThatReturnsDuringTheSettlingTimeCancelsTheDemotion() {
        let application = FakeApplication(), clock = Clock(), windows = registry(application, clock)
        let main = lifecycleWindow(); defer { main.close() }
        windows.register(main, role: .browser)
        main.orderOut(nil)       // a Space or full-screen transition can read as "not visible" for an instant
        windows.reconcile()
        #expect(!clock.work.isEmpty && application.presence == .regular, "demotion is scheduled, not immediate")
        main.orderFrontRegardless(); windows.reconcile()
        clock.runAll()
        #expect(application.presence == .regular && application.changes.isEmpty, "the transition left no trace in the policy")
    }
    @Test func theHiddenPlayerTheMiniPlayerAndEveryAuxiliaryWindowAreNeverTheLastRegularWindow() {
        let application = FakeApplication(), clock = Clock(), windows = registry(application, clock)
        let hidden = lifecycleWindow(), mini = lifecycleWindow(), popover = lifecycleWindow(), main = lifecycleWindow()
        defer { [hidden, mini, popover, main].forEach { $0.close() } }
        WebKitMusicPage.applyHostWindowRules(hidden)
        windows.register(hidden, role: .auxiliary); windows.register(mini, role: .miniPlayer); windows.register(popover, role: .auxiliary)
        windows.register(main, role: .browser)
        #expect(windows.regularWindowCount == 1, "only the browser window counts")
        main.close(); clock.runAll()
        #expect(application.presence == .accessory, "the hidden player, the mini-player and the popover remain visible and still do not keep the Dock icon")
        #expect(windows.windows(role: .miniPlayer).count == 1 && hidden.isVisible && mini.isVisible)
    }
    @Test func aWindowThatNeverRegistersIsNeverCounted() {
        let application = FakeApplication(), clock = Clock(), windows = registry(application, clock)
        let stranger = lifecycleWindow(); defer { stranger.close() }
        windows.register(lifecycleWindow(shown: false), role: .browser)
        #expect(windows.regularWindowCount == 0 && windows.registeredCount == 1, "unregistered (sheets, panels, alerts, the hidden player) and unshown windows are not regular windows")
    }
    @Test func settingsAndFullScreenNowPlayingKeepTheDockLikeAnyRegularWindow() {
        #expect(ShellWindowRole.allCases.filter(\.keepsDockPresence) == [.browser, .nowPlaying, .settings])
        #expect(!ShellWindowRole.miniPlayer.keepsDockPresence && !ShellWindowRole.auxiliary.keepsDockPresence)
    }
    @Test func aHiddenApplicationKeepsItsPolicyBecauseNoWindowWasClosed() {
        let application = FakeApplication(), clock = Clock(), windows = registry(application, clock)
        let main = lifecycleWindow(); defer { main.close() }
        windows.register(main, role: .browser)
        application.isHidden = true            // Command-H: every window is hidden, none is closed
        main.orderOut(nil); windows.reconcile()
        #expect(clock.work.isEmpty, "no demotion is even scheduled while the application is hidden")
        clock.runAll()
        #expect(application.presence == .regular && application.changes.isEmpty)
        application.isHidden = false          // shown again with its window still ordered out: now it IS the last window gone
        windows.reconcile(); clock.runAll()
        #expect(application.presence == .accessory)
    }
    @Test func reopeningRestoresTheRegularPolicyAndActivatesTheApplication() {
        let application = FakeApplication(), clock = Clock(), windows = registry(application, clock)
        application.presence = .accessory
        windows.restoreRegularPresence()
        #expect(application.presence == .regular && application.activations == 1)
    }

    // MARK: The hidden player's window

    @Test func theHiddenPlayersHostWindowIsOutOfTheWindowsMenuCyclingAndMissionControl() {
        let window = lifecycleWindow(shown: false)
        WebKitMusicPage.applyHostWindowRules(window)
        #expect(window.isExcludedFromWindowsMenu && window.ignoresMouseEvents)
        #expect(window.collectionBehavior.contains(.ignoresCycle) && window.collectionBehavior.contains(.transient) && window.collectionBehavior.contains(.stationary))
        #expect(!window.collectionBehavior.contains(.managed) && !window.collectionBehavior.contains(.participatesInCycle))
        let source = (try? LifecycleSources.source("Sources/Playback/WebMusic/WebMusicPage.swift")) ?? ""
        #expect(source.contains("Self.applyHostWindowRules(window)"), "the real host window takes the same rules")
    }

    // MARK: The mini-player (T21.3)

    @Test func theMiniPlayerIsAboutThreeSixtyBySixtyCompactAndLargerWhenExpanded() {
        #expect(MiniPlayerPreferences().defaultSize == CGSize(width: 360, height: 160))
        var expanded = MiniPlayerPreferences(); expanded.expanded = true
        #expect(expanded.defaultSize.width == 360 && expanded.defaultSize.height > 400)
        #expect(MiniPlayerPreferences().minimumSize.width <= 360 && MiniPlayerPreferences().minimumSize.height <= 160, "the default fits above the minimum: it is resizable")
    }
    @Test func theMiniPlayerPanelIsNonActivatingNeverMainAndOutOfTheDocumentLists() throws {
        var shownWindow: NSWindow?
        let controller = MiniPlayerController(preferences: InMemoryDefaults()) { _ in AnyView(Color.clear) }
        controller.onVisibilityChange = { window in if let window { window.alphaValue = 0; shownWindow = window } }
        controller.show(); defer { controller.close() }
        let panel = try #require(controller.panel)
        #expect(panel === shownWindow)
        #expect(panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.resizable) && panel.styleMask.contains(.titled))
        #expect(!panel.canBecomeMain && panel.becomesKeyOnlyIfNeeded && !panel.hidesOnDeactivate && panel.isExcludedFromWindowsMenu)
        #expect(panel.collectionBehavior.contains(.ignoresCycle) && !panel.collectionBehavior.contains(.canJoinAllSpaces), "not pinned: on its own Space like a window")
        #expect(panel.contentRect(forFrameRect: panel.frame).size.width.rounded() == 360 && panel.contentRect(forFrameRect: panel.frame).size.height.rounded() == 160)
        #expect(!panel.isKeyWindow, "showing the mini-player never makes it key")
    }
    /// TH2 (W28): showing, moving and closing the mini-player in a test process must not write `NSWindow Frame YTMuseMiniPlayer` into the runner's shared defaults domain.
    @Test func anIsolatedProcessNeverAutosavesTheMiniPlayersFrame() throws {
        // First, and with #require: if the source no longer puts the isolation check before the autosave name, stop BEFORE a window is shown. A broken guard must not be able to
        // write the frame into the runner's shared defaults domain from the test that checks it (Harness-Brief: tests of safety guards fail safe).
        let code = LifecycleSources.code(LifecycleSources.packageRoot.appendingPathComponent("Sources/AppShell/Lifecycle/MiniPlayer.swift")).map(\.text).joined(separator: "\n")
        let save = try #require(code.range(of: "setFrameAutosaveName(\"YTMuseMiniPlayer\")"))
        let guardAt = try #require(code.range(of: "if ProcessIsolation.isIsolated {"))
        try #require(guardAt.lowerBound < save.lowerBound, "the isolation check comes before the autosave name")
        // And the autosave is not INSIDE the isolated branch: nothing between the check and its `else` may name the frame (critic L1).
        let elseAt = try #require(code.range(of: "} else {", range: guardAt.upperBound..<code.endIndex))
        try #require(!code[guardAt.upperBound..<elseAt.lowerBound].contains("FrameAutosaveName") && !code[guardAt.upperBound..<elseAt.lowerBound].contains("setFrameUsingName"), "the isolated branch only centres the panel")
        try #require(ProcessIsolation.isIsolated, "a test process is isolated: otherwise this test must not run the show path")
        let key = "NSWindow Frame YTMuseMiniPlayer"
        let before = UserDefaults.standard.object(forKey: key) as? String   // a READ of the runner's domain, to compare
        let controller = MiniPlayerController(preferences: InMemoryDefaults()) { _ in AnyView(Color.clear) }
        controller.onVisibilityChange = { $0?.alphaValue = 0 }
        controller.show()
        let panel = try #require(controller.panel)
        #expect(panel.frameAutosaveName.isEmpty, "no autosave name is adopted in an isolated process: \(panel.frameAutosaveName)")
        var moved = panel.frame; moved.origin.x += 37; moved.origin.y += 11
        panel.setFrame(moved, display: false)
        controller.close()
        #expect(UserDefaults.standard.object(forKey: key) as? String == before, "the shared domain's frame entry is exactly what it was")
    }
    @Test func pinningFloatsAboveAndIsRememberedAndExpandingChangesTheSizeNotTheOrigin() throws {
        let store = InMemoryDefaults()
        let controller = MiniPlayerController(preferences: store) { _ in AnyView(Color.clear) }
        controller.onVisibilityChange = { $0?.alphaValue = 0 }
        controller.show(); defer { controller.close() }
        let panel = try #require(controller.panel)
        controller.setPinned(true)
        #expect(panel.level == .floating && panel.isFloatingPanel && panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(MiniPlayerPreferences.load(from: store).pinned, "the pin is remembered")
        controller.setPinned(false)
        #expect(panel.level == .normal && !panel.isFloatingPanel)
        let top = panel.frame.maxY, left = panel.frame.minX
        controller.setExpanded(true)
        #expect(panel.frame.height > 400 && abs(panel.frame.maxY - top) < 1 && abs(panel.frame.minX - left) < 1, "the top-left corner stays put")
        #expect(MiniPlayerPreferences.load(from: store).expanded)
        controller.setExpanded(false)
        #expect(panel.contentRect(forFrameRect: panel.frame).size.height.rounded() == 160)
    }
    @Test func aMetadataChangeNeverTakesFocusOrMakesTheMiniPlayerKey() async throws {
        let rig = try await LifecycleRig.make()
        let (_, page) = try await rig.play()
        let controller = MiniPlayerController(preferences: InMemoryDefaults()) { _ in AnyView(Color.clear) }
        controller.onVisibilityChange = { $0?.alphaValue = 0 }
        controller.show(); defer { controller.close() }
        let panel = try #require(controller.panel)
        let main = lifecycleWindow(); defer { main.close() }
        main.makeKeyAndOrderFront(nil)
        let keyBefore = NSApp.keyWindow
        for index in 0..<5 { page.send(lifecycleState(position: Double(index), video: index % 2 == 0 ? lifecycleOtherVideo : lifecycleVideo, title: "Track \(index)", artist: "Artist \(index)")) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!panel.isKeyWindow && !panel.isMainWindow, "five track changes: the mini-player never became key or main")
        #expect(NSApp.keyWindow === keyBefore, "and focus did not move")
        // Structural: nothing in the shell's sources asks for key status.
        for name in ["MiniPlayer.swift", "ShellCoordinator.swift", "StatusItem.swift"] {
            let code = LifecycleSources.code(LifecycleSources.packageRoot.appendingPathComponent("Sources/AppShell/Lifecycle/" + name)).map(\.text).joined(separator: "\n")
            #expect(!code.contains("makeKey(") && (name == "ShellCoordinator.swift" || !code.contains("makeKeyAndOrderFront(nil)")), Comment(rawValue: name))
        }
        let mini = LifecycleSources.code(LifecycleSources.packageRoot.appendingPathComponent("Sources/AppShell/Lifecycle/MiniPlayer.swift")).map(\.text).joined(separator: "\n")
        #expect(mini.contains("orderFrontRegardless()") && !mini.contains("makeKey"))
    }
}
