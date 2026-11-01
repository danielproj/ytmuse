import AppKit
import Foundation
import Testing
import AccountSession
@testable import Features
@testable import Playback
@testable import AppShell

/// F5 / WIN05: the mini-player's Like. Never during an advertisement, only on an explicit press, only through the social surface and the W12 ledger
/// (`LibraryControlPress`), and a disabled Like says why it is disabled.
@Suite @MainActor struct LifecycleLikeTests {
    private func rig() async throws -> (LifecycleRig, ShellCoordinator, FakeMusicPage) {
        let rig = try await LifecycleRig.make()
        let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(),
                                     preferences: UserDefaults(suiteName: "local.native-music.test-" + UUID().uuidString)!, installsStatusItem: false)
        let (_, page) = try await rig.play()
        return (rig, shell, page)
    }
    private func control() -> LibraryControl {
        let like = MusicItemControls.Like(videoID: lifecycleVideo, status: .indifferent, dislikeExposed: false)
        return LibraryControl(kind: .like, key: .rating(videoID: lifecycleVideo), isOn: false, intent: .rate(like, to: .like), title: "Like", symbol: "heart")
    }
    @Test func aSongWhosePageWasReadOffersLikeAndNothingElseDoes() async throws {
        let (_, shell, _) = try await rig()
        var asked: [String] = []
        shell.likeControlProvider = { id in asked.append(id); return self.control() }
        #expect(shell.likeAvailability().control != nil && asked == [lifecycleVideo])
    }
    @Test func noLikeDuringAnAdvertisementAndTheProviderIsNotEvenAsked() async throws {
        let (_, shell, page) = try await rig()
        var asked = 0
        shell.likeControlProvider = { _ in asked += 1; return self.control() }
        page.send(lifecycleState(position: 0, duration: 15, video: lifecycleAdVideo, ad: true))
        #expect(shell.likeAvailability() == .unavailable(.advertisement) && shell.likeControl() == nil && asked == 0)
        page.send(lifecycleState(position: 1))
        #expect(shell.likeControl() != nil, "the song after the ad can be liked again")
    }
    @Test func eachCauseOfADisabledLikeHasItsOwnReason() async throws {
        let (rig, shell, page) = try await rig()
        shell.likeControlProvider = { _ in nil }
        #expect(shell.likeAvailability() == .unavailable(.pageNotRead))
        page.send(lifecycleState(position: 0, duration: 15, video: lifecycleAdVideo, ad: true))
        #expect(shell.likeAvailability() == .unavailable(.advertisement))
        let idle = try await LifecycleRig.make()
        let quiet = ShellCoordinator(playback: idle.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(),
                                     preferences: UserDefaults(suiteName: "local.native-music.test-" + UUID().uuidString)!, installsStatusItem: false)
        #expect(quiet.likeAvailability() == .unavailable(.nothingPlaying))
        let messages = [ShellCoordinator.LikeUnavailable.nothingPlaying, .advertisement, .ownedMedia, .pageNotRead].map(\.message)
        #expect(Set(messages).count == 4 && messages.allSatisfy { !$0.isEmpty }, "four causes, four different sentences: \(messages)")
        #expect(messages[1].localizedCaseInsensitiveContains("advertisement") && messages[2].localizedCaseInsensitiveContains("your own") && !messages.contains { $0.localizedCaseInsensitiveContains("test") } && messages[3].localizedCaseInsensitiveContains("page"))
        _ = rig
    }
    @Test func ownedMediaHasItsOwnReasonNotTheGenericOne() async throws {
        let rig = try await LifecycleRig.make()
        let session = try await ownedSession()
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.model.session = session
        await rig.model.refresh()
        let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(),
                                     preferences: UserDefaults(suiteName: "local.native-music.test-" + UUID().uuidString)!, installsStatusItem: false)
        shell.likeControlProvider = { _ in self.control() }
        #expect(rig.model.shellState.source == .owned && shell.likeAvailability() == .unavailable(.ownedMedia))
        await session.close()
    }
    @Test func theMiniPlayerGivesTheReasonAsTheHelpAndAsTheAccessibilityHint() throws {
        let source = try LifecycleSources.source("Sources/AppShell/Lifecycle/MiniPlayer.swift")
        #expect(source.contains("shell.likeAvailability()") && source.contains(".accessibilityHint(Text(reason))") && source.contains(".help(Text(control?.title ?? reason))"))
        #expect(!source.contains("open it once and the control appears here"), "no single generic text any more")
    }
    @Test func aPressReachesThePressPathOnlyWhenTheExplicitCallIsMadeNeverOnATrackChange() async throws {
        let (_, shell, page) = try await rig()
        var pressed: [LibraryControl] = []
        shell.likeControlProvider = { _ in self.control() }
        shell.likePress = { pressed.append($0) }
        for index in 0..<4 { page.send(lifecycleState(position: Double(index), video: index % 2 == 0 ? lifecycleOtherVideo : lifecycleVideo, title: "T\(index)")) }
        _ = shell.likeAvailability(); _ = shell.likeControl()
        try await Task.sleep(for: .milliseconds(30))
        #expect(pressed.isEmpty, "reading, rendering and four track changes never press Like")
        let control = try #require(shell.likeControl())
        await shell.pressLike(control)
        #expect(pressed.count == 1 && pressed.first == control)
    }
    @Test func theOnlyPathToTheLibraryIsTheOneLedgerEntryThroughTheSocialSurface() async throws {
        let composition = try LifecycleSources.source("Sources/AppShell/Lifecycle/ShellComposition.swift")
        #expect(composition.contains("LibraryControlPress.press(control, ledger: self.library.ledger, social: self.social)"))
        let library = try LifecycleSources.source("Sources/Features/Library/LibraryView.swift")
        #expect(library.contains("if let social, control.kind == .like || control.kind == .dislike { await social.rate(control) { await ledger.submit(control.intent) } }"), "a like goes through the social surface, which hands it to the ledger")
        let sources = await LifecycleSources.offMain { () -> [String] in
            var bad: [String] = []
            for file in LifecycleSources.swiftFiles(under: LifecycleSources.packageRoot.appendingPathComponent("Sources/AppShell/Lifecycle")) {
                for (line, code) in LifecycleSources.code(file) where code.contains(".submit(") || code.contains(".rate(") || code.contains("ledger.retry(") { bad.append("\(file.lastPathComponent):\(line)") }
            }
            return bad
        }
        #expect(sources.isEmpty, "the shell never talks to the ledger or the social surface itself: \(sources)")
    }
    @Test func skipIsOffDuringAnAdvertisementBecauseEverySurfaceUsesV02sControlsAndTheMenuUsesTheSameRule() async throws {
        let ad = ShellTransportState(source: .youTubeMusic, title: "x", hasItem: true, isPlaying: true, isAd: true, canSkip: false)
        #expect(!ad.skipEnabled && ShellTransportState(hasItem: true, canSkip: true).skipEnabled && !ShellTransportState.idle.skipEnabled)
        // The surfaces compose V02's controls; those disable Previous and Next from the snapshot's `canSkip`, which is false while an ad plays.
        let surfaces = try LifecycleSources.source("Sources/AppShell/Lifecycle/ShellPlayerSurfaces.swift")
        #expect(surfaces.contains("WebMusicControlsView(player: player") && surfaces.contains("OwnedControlsView(model: shell.playback"))
        let v02 = try LifecycleSources.source("Sources/AppShell/MusicTransportBar.swift")
        #expect(v02.contains(".disabled(!state.canSkip).accessibilityIdentifier(\"musicPrevious\")") && v02.contains(".disabled(!state.canSkip).accessibilityIdentifier(\"musicNext\")"))
        var snapshot = WebMusicSnapshot(); snapshot.phase = .playing; snapshot.playlistID = "PLsyntheticLife"; snapshot.isAd = true
        #expect(!snapshot.canSkip && !snapshot.canSeek, "an advertisement: no skip, no Previous, no seek")
        for name in ["StatusItem.swift", "MiniPlayer.swift", "NowPlayingFullScreen.swift", "ShellPlayerSurfaces.swift"] {
            let source = try LifecycleSources.source("Sources/AppShell/Lifecycle/" + name)
            #expect(!source.contains("ShellTransportRow") && !source.contains("ShellArtwork(") && !source.contains("struct AdBadge"), "\(name): no private transport, artwork or Ad pill any more")
        }
    }
}
