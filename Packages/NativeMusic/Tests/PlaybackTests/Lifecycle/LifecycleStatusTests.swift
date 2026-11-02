import AppKit
import Foundation
import Testing
@testable import Playback
@testable import AppShell
import TestSupport

@MainActor final class RecordingShell: ShellCommanding {
    var transport = ShellTransportState.idle
    private(set) var calls: [String] = []
    func togglePlayPause() { calls.append("toggle") }
    func next() { calls.append("next") }
    func previous() { calls.append("previous") }
    func setVolume(_ level: Double) { calls.append("volume \(level)") }
    func showMainWindow() { calls.append("main") }
    func showMiniPlayer() { calls.append("mini") }
    func showNowPlayingFullScreen() { calls.append("fullscreen") }
    func showQueue() { calls.append("queue") }
    func openSettings() { calls.append("settings") }
    func quit() { calls.append("quit") }
}

/// WIN01 / ARCH03: the status item's context menu and popover are the shared command layer, and an advertisement is never skipped.
@Suite @MainActor struct LifecycleStatusTests {
    private func titles(_ entries: [StatusMenuEntry]) -> [String] { entries.map { if case .item(_, let title, _) = $0 { title } else { "-" } } }
    private func enabled(_ entries: [StatusMenuEntry], _ command: ShellMenuCommand) -> Bool? {
        for case .item(let c, _, let on) in entries where c == command { return on }
        return nil
    }
    @Test func theContextMenuOffersPlayPauseNextPreviousShowMiniPlayerSettingsAndQuit() {
        var state = ShellTransportState(source: .youTubeMusic, title: "Song", artist: "Artist", hasItem: true, isPlaying: true, canSkip: true)
        let entries = StatusMenuModel.entries(for: state)
        #expect(entries.compactMap { if case .item(let c, _, _) = $0 { c } else { nil } } == ShellMenuCommand.allCases, "every command, once, in this order")
        #expect(titles(entries) == ["Pause", "Next", "Previous", "-", "Show YTMuse", "Mini-player", "Settings…", "-", "Quit YTMuse"])
        state.isPlaying = false
        #expect(titles(StatusMenuModel.entries(for: state)).first == "Play")
    }
    @Test func withNothingPlayingTransportIsOffAndTheWindowCommandsAreNot() {
        let entries = StatusMenuModel.entries(for: .idle)
        for command in [ShellMenuCommand.playPause, .next, .previous] { #expect(enabled(entries, command) == false, "\(command)") }
        for command in [ShellMenuCommand.showWindow, .miniPlayer, .settings, .quit] { #expect(enabled(entries, command) == true, "\(command)") }
    }
    @Test func duringAnAdvertisementNextAndPreviousAreOffAndPlayPauseIsNot() {
        let ad = ShellTransportState(source: .youTubeMusic, title: "Hidden by the ad", artist: "x", hasItem: true, isPlaying: true, isAd: true, canSkip: false)
        let entries = StatusMenuModel.entries(for: ad)
        #expect(enabled(entries, .next) == false && enabled(entries, .previous) == false && enabled(entries, .playPause) == true)
        #expect(ad.statusLine == "Ad playing" && ad.tooltip == "Advertisement", "the honest Ad state, and not the song it will be followed by")
    }
    @Test func everyMenuCommandGoesThroughTheSharedCommandLayerAndNowhereElse() {
        let shell = RecordingShell()
        for command in ShellMenuCommand.allCases { StatusMenuModel.perform(command, on: shell) }
        #expect(shell.calls == ["toggle", "next", "previous", "main", "mini", "settings", "quit"])
    }
    @Test func theTooltipNamesTheTrackAndIsEmptyWhenNothingPlays() {
        #expect(ShellTransportState.idle.tooltip == nil)
        #expect(ShellTransportState(title: "Song", artist: "Artist", hasItem: true).tooltip == "Song - Artist")
        #expect(ShellTransportState(title: "Song", artist: nil, hasItem: true).tooltip == "Song")
    }
    @Test func theMenuTheStatusItemBuildsHasTheSameEntriesAndEnabledStateAsTheModel() async throws {
        let rig = try await LifecycleRig.make()
        let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(), preferences: InMemoryDefaults(), installsStatusItem: false)
        let controller = StatusItemController(shell: shell, preferences: shell.preferences)
        let idle = controller.makeMenu()
        #expect(idle.items.filter { !$0.isSeparatorItem }.map(\.title) == titles(StatusMenuModel.entries(for: .idle)).filter { $0 != "-" })
        #expect(idle.items.first?.isEnabled == false && !controller.isInstalled, "nothing was added to the real menu bar")
        _ = try await rig.play()
        let playing = controller.makeMenu()
        #expect(playing.items.first?.title == "Pause" && playing.items.first?.isEnabled == true && playing.items[1].isEnabled)
        rig.log.pages.first?.send(lifecycleState(position: 0, duration: 15, video: lifecycleAdVideo, ad: true))
        let ad = controller.makeMenu()
        #expect(ad.items[1].isEnabled == false && ad.items[2].isEnabled == false && ad.items.first?.isEnabled == true)
    }
    @Test func theShellStateIsTheOwnersAndTheCommandsAreTheMediaKeysCommands() async throws {
        let rig = try await LifecycleRig.make()
        #expect(rig.model.shellState == .idle)
        let (_, page) = try await rig.play()
        let state = rig.model.shellState
        #expect(state.source == .youTubeMusic && state.title == "Synthetic Song" && state.artist == "Synthetic Artist" && state.isPlaying && state.canSkip && !state.isAd)
        rig.model.shellTogglePlayPause(); try await Task.sleep(for: .milliseconds(30))
        #expect(page.bodies.contains(WebMusicScripts.pause) && !rig.model.shellState.isPlaying, "the status item's play/pause is the transport bar's")
        rig.model.shellNext(); try await Task.sleep(for: .milliseconds(30))
        #expect(page.bodies.contains(WebMusicScripts.skip))
        page.send(lifecycleState(position: 0, duration: 15, video: lifecycleAdVideo, ad: true))
        #expect(rig.model.shellState.isAd && !rig.model.shellState.canSkip)
        let skips = page.bodies.filter { $0 == WebMusicScripts.skip }.count
        rig.model.shellNext(); rig.model.shellPrevious(); try await Task.sleep(for: .milliseconds(30))
        #expect(page.bodies.filter { $0 == WebMusicScripts.skip }.count == skips, "no skip reaches the page during an ad")
        rig.model.shellSetVolume(0.4); try await Task.sleep(for: .milliseconds(30))
        #expect(rig.model.shellState.volume == 0.4)
    }
    @Test func theStatusItemIsPermanentAndOnlyEverBuiltFromTheShellCoordinator() async throws {
        let creators = await LifecycleSources.offMain { () -> [String] in
            LifecycleSources.swiftFiles(under: LifecycleSources.packageRoot.appendingPathComponent("Sources"))
                .filter { file in LifecycleSources.code(file).contains { $0.text.contains(".statusItem(withLength") } }.map(\.lastPathComponent)
        }
        #expect(creators == ["StatusItem.swift"], "\(creators)")
        let coordinator = try LifecycleSources.source("Sources/AppShell/Lifecycle/ShellCoordinator.swift")
        #expect(coordinator.contains("controller.install()") && coordinator.contains("statusItem?.remove()"), "installed at launch, removed at quit")
    }
}
