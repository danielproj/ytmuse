import AppKit
import Foundation
import SwiftUI
import Testing
import DesignSystem
import Features
@testable import Playback
@testable import AppShell

/// T21.5 (WIN10, MOTION04, PERF06, PERF08): hidden, minimized, occluded and display-off windows stop every decorative piece of work, and the
/// transport, the status item and Now Playing stay responsive.
@Suite @MainActor struct LifecycleOcclusionTests {
    @Test func aWindowShowsSomethingOnlyWhenEveryConditionHoldsAndTheDisplayIsOn() {
        var shown = 0
        for bits in 0..<16 {
            let visible = WindowVisibility.isVisible(onScreen: bits & 1 != 0, miniaturized: bits & 2 != 0, occlusionVisible: bits & 4 != 0, displayActive: bits & 8 != 0)
            let expected = bits & 1 != 0 && bits & 2 == 0 && bits & 4 != 0 && bits & 8 != 0
            #expect(visible == expected, "\(bits)")
            if visible { shown += 1 }
        }
        #expect(shown == 1)
    }
    @Test func aLockedScreenOrASleepingDisplayMakesEveryWindowReadAsHidden() {
        let display = ShellDisplayState()
        func visible() -> Bool { WindowVisibility.isVisible(onScreen: true, miniaturized: false, occlusionVisible: true, displayActive: display.active) }
        #expect(visible())
        display.apply(.screenLocked); #expect(!visible())
        display.apply(.screenUnlocked); #expect(visible())
        display.apply(.displaySlept); #expect(!visible())
        display.apply(.displayWoke); display.apply(.systemWillSleep); #expect(!visible())
        display.apply(.systemDidWake); #expect(visible())
    }
    @Test func everyWindowObserverIncludesTheDisplayStateAndAWindowNotOnScreenReportsHidden() async throws {
        var readings: [Bool] = []
        let observer = WindowVisibility.ObserverView { readings.append($0) }
        let window = lifecycleWindow(shown: false); defer { window.close() }
        window.contentView = observer
        for _ in 0..<20 where readings.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(readings.last == false, "a window that was never ordered on screen reads as hidden")
        let source = try LifecycleSources.source("Sources/AppShell/BottomPlayer.swift")
        #expect(source.contains("ShellDisplayState.didChange") && source.contains("displayActive: ShellDisplayState.shared.active"))
    }
    @Test func theClockTheAnimationsAndTheTintStopWhenNoWindowIsVisibleAndTheTransportKeepsWorking() async throws {
        let rig = try await LifecycleRig.make()
        let (player, page) = try await rig.play(state: lifecycleState(position: 0))
        let window = UUID()
        rig.model.observe(window, visible: true)
        for tick in 1...4 { page.send(lifecycleState(position: Double(tick))) }
        let whileVisible = player.timeline.publications
        #expect(whileVisible >= 4 && player.timeline.observing && rig.model.isObservingUI)
        rig.model.observe(window, visible: false)
        #expect(!player.timeline.observing && !rig.model.isObservingUI, "hidden: the clock and the 250 ms refresh loop are off")
        for tick in 5...40 { page.send(lifecycleState(position: Double(tick))) }
        #expect(player.timeline.publications == whileVisible, "thirty-six position reports while hidden republished the clock no times")
        #expect(player.timeline.latestPosition == 40, "the position is still tracked, so it is right the moment a window shows again")
        // Responsive: the transport, a media key and the status item's play/pause still reach the page, and Now Playing still hears every report.
        var heard = 0
        player.onChange = { _, _ in heard += 1 }
        page.send(lifecycleState(position: 41))
        #expect(heard == 1, "Now Playing keeps full-resolution updates while every window is hidden")
        rig.model.shellTogglePlayPause(); try await Task.sleep(for: .milliseconds(30))
        #expect(page.bodies.contains(WebMusicScripts.pause), "the status item pauses a player nobody can see")
        _ = rig.model.remote(.play); try await Task.sleep(for: .milliseconds(30))
        #expect(page.bodies.contains(WebMusicScripts.play), "a media key plays it")
        rig.model.observe(window, visible: true)
        #expect(player.timeline.position == 41, "the clock catches up the moment a window shows again")
    }
    @Test func everyMotionIsOffWhileHiddenAndNoLoopOrTimerAnimationExistsInTheShell() throws {
        for motion in MusicMotion.allCases {
            #expect(motion.duration(reduceMotion: false, lowPower: false, visible: false) == 0, "\(motion)")
            #expect(motion.animation(reduceMotion: false, lowPower: false, visible: false) == nil, "\(motion)")
            #expect(motion.duration(reduceMotion: true, lowPower: false, visible: true) <= motion.duration(reduceMotion: false, lowPower: false, visible: true), "Reduce Motion never lengthens \(motion)")
        }
        let forbidden = ["repeatForever", "TimelineView(.animation", "TimelineView(.periodic", "Timer.scheduledTimer", "CADisplayLink", "withAnimation(.linear(duration: 1000"]
        var found: [String] = []
        for file in LifecycleSources.swiftFiles(under: LifecycleSources.packageRoot.appendingPathComponent("Sources/AppShell/Lifecycle")) {
            for (line, code) in LifecycleSources.code(file) { for word in forbidden where code.contains(word) { found.append("\(file.lastPathComponent):\(line) \(word)") } }
        }
        #expect(found.isEmpty, "no infinite decorative animation, polling timer or display link in the shell: \(found)")
    }
    @Test func everyShellSurfaceFeedsItsWindowVisibilityToTheOwnersObservation() throws {
        // V02's `PlaybackObservation` (window visibility, with the display gate inside `WindowVisibility`) is what runs the owner's clock and refresh.
        for name in ["StatusItem.swift", "ShellPlayerSurfaces.swift", "MiniPlayer.swift"] {
            let source = try LifecycleSources.source("Sources/AppShell/Lifecycle/" + name)
            #expect(source.contains("WindowVisibility {"), "\(name) feeds window visibility")
        }
        for name in ["StatusItem.swift", "ShellPlayerSurfaces.swift", "MiniPlayer.swift"] {
            let source = try LifecycleSources.source("Sources/AppShell/Lifecycle/" + name)
            #expect(source.contains(".modifier(PlaybackObservation(model: shell.playback))"), "\(name): the clock runs only while this surface shows and is released with it")
        }
        let full = try LifecycleSources.source("Sources/AppShell/Lifecycle/NowPlayingFullScreen.swift")
        #expect(full.contains("ShellExpandedPlayer("), "the full-screen window is V02's expanded player, observed through the shared host")
        let observation = try LifecycleSources.source("Sources/AppShell/BottomPlayer.swift")
        #expect(observation.contains("displayActive: ShellDisplayState.shared.active"), "V02's restyle of the bar kept the display gate")
        let status = try LifecycleSources.source("Sources/AppShell/Lifecycle/StatusItem.swift")
        #expect(status.contains("popover?.contentViewController = nil"), "a closed popover keeps no view, no artwork decode and no observation")
    }
    @Test func hiddenShellSurfacesDecodeNoArtworkAndWindowMotionFollowsReduceMotionAndLowPower() throws {
        for name in ["MiniPlayer.swift", "ShellPlayerSurfaces.swift"] {
            let source = try LifecycleSources.source("Sources/AppShell/Lifecycle/" + name)
            #expect(source.contains("visible: visible") || source.contains("windowVisible: windowVisible"), "\(name): the artwork is told whether its window is shown")
        }
        let expanded = try LifecycleSources.source("Sources/AppShell/ExpandedPlayer.swift")
        #expect(expanded.contains("visible: windowVisible"), "the expanded player's cover is told too")
        let artwork = try LifecycleSources.source("Sources/AppShell/WebMusicQueueViews.swift")
        #expect(artwork.contains("artworkDecode.hold(!visible)"))
        #expect(ShellMotion.animates(reduceMotion: false, lowPower: false))
        #expect(!ShellMotion.animates(reduceMotion: true, lowPower: false) && !ShellMotion.animates(reduceMotion: false, lowPower: true) && !ShellMotion.animates(reduceMotion: true, lowPower: true))
    }
    @Test func aHeldArtworkDriverDecodesNothingUntilItsWindowShowsAgainAndThenDecodesTheNewestDemand() async throws {
        let driver = ArtworkDemandDriver()
        var decoded: [Int] = []
        driver.hold(true)
        driver.apply(1) { decoded.append(1) }
        driver.apply(2) { decoded.append(2) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(decoded.isEmpty, "a hidden window decodes no image, however often the artwork changes")
        driver.resume()                                    // the view being re-attached does not lift the hold
        try await Task.sleep(for: .milliseconds(30))
        #expect(decoded.isEmpty)
        driver.hold(false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(decoded == [2], "shown again: only the newest artwork is decoded")
        driver.hold(true); driver.apply(3) { decoded.append(3) }
        driver.hold(true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(decoded == [2])
    }
    @Test func theStatusItemsTooltipFollowsTheCoarseStateAndNeverThePositionClock() async throws {
        let rig = try await LifecycleRig.make()
        let (_, page) = try await rig.play(state: lifecycleState(position: 0))
        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        withObservationTracking({ _ = rig.model.shellState }, onChange: { counter.fired += 1 })
        for tick in 1...12 { page.send(lifecycleState(position: Double(tick) * 0.25)) }
        #expect(counter.fired == 0, "twelve position reports did not invalidate the shell state")
        page.send(lifecycleState(position: 3, video: lifecycleOtherVideo, title: "Another"))
        #expect(counter.fired == 1, "a new track does")
    }
}
