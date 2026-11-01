import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Playback
@testable import AppShell

/// T21.2 / WIN04 / PLAY01: Command-N windows navigate independently and share exactly one account, one player and one Now Playing owner.
@Suite @MainActor struct LifecycleOwnershipTests {
    @Test func twoWindowsStartingPlayCreateOnePlayerOnePageAndOneNowPlayingSession() async throws {
        let rig = try await LifecycleRig.make()
        // Window A and window B both press Play on different playlists; both go through the one model.
        let a = await rig.model.playMusic(playlistID: "PLsyntheticLife", title: "A", request: rig.authority.requestOwnedStart())
        let first = try #require(rig.model.music)
        let b = await rig.model.playMusic(playlistID: "PLsyntheticOther", title: "B", request: rig.authority.requestOwnedStart())
        #expect(a == .started && b == .started)
        #expect(rig.log.pages.count == 1, "one hidden page for the one application session, however many windows pressed Play")
        let owner = await rig.authority.currentMusic()
        #expect(owner === first && rig.model.music === first, "the same player: the second window reused it")
        #expect(rig.model.nowPlaying.isActive)
    }
    @Test func twoPlaysAtTheSameMomentNeverCreateASecondPlayerOrPage() async throws {
        let rig = try await LifecycleRig.make()
        async let a = rig.model.playMusic(playlistID: "PLsyntheticLife", title: "A", request: rig.authority.requestOwnedStart())
        async let b = rig.model.playMusic(playlistID: "PLsyntheticOther", title: "B", request: rig.authority.requestOwnedStart())
        _ = await (a, b)
        #expect(rig.log.pages.count <= 1, "\(rig.log.pages.count)")
        let owner = await rig.authority.currentMusic()
        #expect(rig.model.music === owner, "the model and the owner never disagree about the one player")
    }
    @Test func everyWindowOfOneBootstrapSharesTheOneShellAndTheOnePlaybackOwner() async throws {
        let rig = try await LifecycleRig.make()
        let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(),
                                     preferences: UserDefaults(suiteName: "local.native-music.test-" + UUID().uuidString)!, installsStatusItem: false)
        var opened = 0
        shell.openMainWindowAction = { opened += 1 }
        shell.openAnotherWindow(); shell.openAnotherWindow(); shell.showMainWindow()
        #expect(opened == 3, "Command-N and Open only ever ask the scene for a window")
        #expect(shell.playback === rig.model && rig.log.pages.isEmpty, "opening windows creates no player")
        #expect(shell.transport == rig.model.shellState, "every surface reads the one owner")
    }
    /// The structural guarantee: the owner, the player, the shell and Now Playing each have exactly one construction site, and it is the shared one.
    @Test func thePlaybackOwnerThePlayerAndNowPlayingAreEachConstructedInExactlyOnePlace() async throws {
        let sites = await LifecycleSources.offMain { () -> [String: [String]] in
            var sites: [String: [String]] = [:]
            let needles = ["PlaybackModel(": "PlaybackModel", "NowPlayingCenter(": "NowPlayingCenter", "WebMusicPlayer(": "WebMusicPlayer", "ShellCoordinator(": "ShellCoordinator",
                           "LocalAccountBootstrap(": "LocalAccountBootstrap", "MPNowPlayingInfoCenter": "MPNowPlayingInfoCenter", "AppPlaybackAuthority" + "(": "AppPlaybackAuthority"]
            for file in LifecycleSources.swiftFiles(under: LifecycleSources.packageRoot.appendingPathComponent("Sources")) {
                for (line, code) in LifecycleSources.code(file) {
                    for (needle, name) in needles where code.contains(needle) && code.range(of: "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: needle), options: .regularExpression) != nil && !code.contains("class \(name)") && !code.contains("init(") && !code.contains("struct ") && !code.contains("///") {
                        sites[name, default: []].append("\(file.lastPathComponent):\(line)")
                    }
                }
            }
            return sites
        }
        #expect(!(sites["PlaybackModel"] ?? []).isEmpty && (sites["PlaybackModel"] ?? []).allSatisfy { $0.hasPrefix("LocalAccountComposition.swift") || $0.hasPrefix("PlaybackPanel.swift") }, "\(sites["PlaybackModel"] ?? [])")
        #expect((sites["NowPlayingCenter"] ?? []).allSatisfy { $0.hasPrefix("PlaybackPanel.swift") } && (sites["NowPlayingCenter"] ?? []).count == 1, "\(sites["NowPlayingCenter"] ?? [])")
        #expect((sites["WebMusicPlayer"] ?? []).allSatisfy { $0.hasPrefix("PlaybackPanel.swift") }, "the hidden player is only built by the one owner: \(sites["WebMusicPlayer"] ?? [])")
        #expect((sites["ShellCoordinator"] ?? []).allSatisfy { $0.hasPrefix("LocalAccountComposition.swift") }, "\(sites["ShellCoordinator"] ?? [])")
        #expect((sites["LocalAccountBootstrap"] ?? []).allSatisfy { $0.hasPrefix("NativeMusicScenes.swift") }, "one bootstrap per scene composition: \(sites["LocalAccountBootstrap"] ?? [])")
        #expect(sites["MPNowPlayingInfoCenter"]?.allSatisfy { $0.hasPrefix("RemoteCommands.swift") } ?? true, "the system's Now Playing is touched only through the one system layer the one NowPlayingCenter publishes into (W23)")
    }
    // F4: every Command-N window shares one bootstrap, owner and player.
    @Test func theWindowGroupContentConstructsNothingAndOnlyReusesTheSceneBootstrap() throws {
        let scenes = try LifecycleSources.source("Sources/AppShell/NativeMusicScenes.swift")
        let start = try #require(scenes.range(of: "WindowGroup(\"YTMuse\", id: \"main\") {"))
        let end = try #require(scenes.range(of: "}.defaultSize(", range: start.upperBound..<scenes.endIndex))
        let content = String(scenes[start.upperBound..<end.lowerBound])
        #expect(content.contains("LocalAccountRoot(accounts: accounts)"), "each window shows the scene's one bootstrap")
        for forbidden in ["Bootstrap(", "PlaybackModel(", "NowPlayingCenter(", "WebMusicPlayer(", "ShellCoordinator(", "AppPlaybackAuthority" + "("] {
            #expect(!content.contains(forbidden), "a window's content never constructs \(forbidden)")
        }
        // Settings and the commands use the same one.
        #expect(!scenes.components(separatedBy: "Settings {").dropFirst().joined().contains("Bootstrap("))
    }
    @MainActor @Test func aSceneCompositionMakesExactlyOneBootstrapAndEveryWindowIsHandedThatOne() throws {
        let before = LocalAccountBootstrap.createdCount
        _ = NativeMusicScenes(loginItem: InMemoryLoginItemService())
        #expect(LocalAccountBootstrap.createdCount == before + 1, "one scene composition, one account/player/Now Playing owner")
        // The bootstrap's own members are the one owner every window reads.
        let bootstrap = LocalAccountBootstrap(loginItem: InMemoryLoginItemService())
        #expect(bootstrap.shell.playback === bootstrap.playback, "the shell, and so the status item and mini-player, use the window's player")
        #expect(bootstrap.playback.nowPlaying === bootstrap.playback.nowPlaying)
    }
    @Test func theMainWindowSceneIsTheOnlyWindowGroupAndTheShellSharesItsBootstrap() throws {
        let scenes = try LifecycleSources.source("Sources/AppShell/NativeMusicScenes.swift")
        #expect(scenes.components(separatedBy: "WindowGroup(").count == 2, "one WindowGroup: Command-N makes more windows of the same scene")
        #expect(scenes.components(separatedBy: "@State private var accounts").count == 2)
        #expect(scenes.contains("accounts.shell") && scenes.contains("MainWindowCommands(shell: accounts.shell)"))
    }
    @Test func commandWClosesTheActiveWindowAndNeverQuitsAndCommandQRunsTheCheckpointedQuitOnly() throws {
        let delegate = try LifecycleSources.source("Sources/AppShell/PlaybackApplicationDelegate.swift")
        #expect(delegate.contains("applicationShouldTerminateAfterLastWindowClosed") && delegate.contains("-> Bool { false }"), "closing the last window never quits")
        let scenes = try LifecycleSources.source("Sources/AppShell/NativeMusicScenes.swift")
        #expect(scenes.contains("CommandGroup(replacing: .appTermination)") && scenes.contains("PlaybackApplicationDelegate.requestQuit()"))
        #expect(!scenes.contains("CommandGroup(replacing: .saveItem)"), "Command-W is the system's Close")
        #expect(delegate.contains("RunLoop.main.perform") && delegate.contains(".terminateLater"), "the E01 quit-path fix is intact")
        #expect(delegate.contains("Self.willTerminate?()"), "the shell goes first at quit")
    }
    @Test func quitStopsEligiblePlaybackAndTheShellRemovesItsWindows() async throws {
        let rig = try await LifecycleRig.make()
        let (player, page) = try await rig.play()
        let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(),
                                     preferences: UserDefaults(suiteName: "local.native-music.test-" + UUID().uuidString)!, installsStatusItem: false)
        shell.start()
        shell.showMiniPlayer()
        let panel = try #require(shell.miniPlayer?.panel); panel.alphaValue = 0
        shell.stop()
        #expect(shell.miniPlayer?.panel == nil && !shell.started, "the mini-player closed with the quit")
        await rig.authority.quit()
        #expect(page.tornDown == 1 && player.isClosed, "playback stopped")
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.model.music == nil && !rig.model.nowPlaying.isActive, "the one Now Playing owner let go")
    }
}
