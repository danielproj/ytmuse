import AppKit
import Foundation
import MediaPlayer
import OutputRoutes
import Testing
@testable import Features
@testable import Playback
@testable import SystemIntegration
@testable import AppShell
import TestSupport

/// T23.3 (ARCH03): Play, seek, jumps, speed, like, dislike and save from a media key, an accessory or Control Center obey the same capabilities, the
/// same generation and account fencing, the same advertisement restrictions and the same route gate as the window's own controls. A command the
/// handler would refuse is never switched on, and one that arrives anyway is refused, never silently dropped.
@Suite @MainActor struct RemoteCommandRulesTests {
    private func sample(_ kind: RemoteCommandKind) -> RemoteTransportCommand {
        switch kind {
        case .play: .play
        case .pause: .pause
        case .toggle: .toggle
        case .next: .next
        case .previous: .previous
        case .seek: .seek(30)
        case .skipForward: .skip(30)
        case .skipBackward: .skip(-15)
        case .changeRate: .rate(1.5)
        case .like: .setLike(true)
        case .dislike: .setDislike(true)
        case .save: .setSave(true)
        }
    }
    private func episodeRig() async throws -> (MediaRig, FakeMusicPage) {
        let rig = try await MediaRig.make()
        rig.episodes.episode = RemoteEpisode(videoID: lifecycleVideo, show: "SHOW", back: 15, forward: 30)
        let (_, page) = try await rig.play()
        return (rig, page)
    }
    private func fullLibrary(_ rig: MediaRig) {
        rig.library.states = [.like: .available(FakeRemoteLibrary.control(.like)), .dislike: .available(FakeRemoteLibrary.control(.dislike)), .save: .available(FakeRemoteLibrary.control(.save))]
    }

    // MARK: capabilities and handler agree

    @Test func everyCommandIsOnExactlyWhenItWouldBePerformedAndHasAReasonWhenOff() async throws {
        let states: [(String, (MediaRig, FakeMusicPage) async throws -> Void)] = [
            ("a song", { rig, _ in self.fullLibrary(rig) }),
            ("a song with no library path", { _, _ in }),
            ("an episode", { rig, _ in rig.episodes.episode = RemoteEpisode(videoID: lifecycleVideo, show: "SHOW", back: 15, forward: 30) }),
            ("an advertisement", { rig, page in self.fullLibrary(rig); page.send(lifecycleState(position: 2, duration: 15, video: lifecycleAdVideo, ad: true)) }),
            ("a live stream", { _, page in page.send(lifecycleState(position: 100, duration: 0)); page.send(systemMediaLiveBody()) }),
            ("a song with no queue", { _, page in page.send(lifecycleState(playlist: nil)) }),
        ]
        for (name, arrange) in states {
            let rig = try await MediaRig.make()
            let (_, page) = try await rig.play()
            try await arrange(rig, page)
            rig.model.routeChangedForNowPlaying()     // the owner re-reads its state (a page was read, an episode started) and tells the system
            let capabilities = rig.model.remoteCapabilities()
            #expect(capabilities.hasItem, "\(name)")
            #expect(rig.commands.enabled == capabilities.enabled, "\(name): what the system is told is what the owner computed")
            for kind in RemoteCommandKind.allCases {
                let outcome = rig.model.remote(sample(kind))
                if capabilities.enabled.contains(kind) { #expect(outcome == .success, "\(name): \(kind) is on, so it is performed") }
                else {
                    #expect(outcome == .refused, "\(name): \(kind) is off, so it is refused, not dropped")
                    #expect(!(capabilities.reasons[kind] ?? "").isEmpty, "\(name): \(kind) is off and says why")
                }
            }
        }
    }
    @Test func nothingLoadedMeansNoActionableItemForEveryCommand() async throws {
        let rig = try await MediaRig.make()
        for kind in RemoteCommandKind.allCases { #expect(rig.model.remote(sample(kind)) == .noActionableItem, "\(kind)") }
        #expect(rig.model.remoteCapabilities() == .none)
    }
    @Test func theSystemsButtonsAreSwitchedOffForTheSameCommandsAndNeverDeliverAPressForThem() async throws {
        let rig = try await MediaRig.make()
        let (_, page) = try await rig.play()
        fullLibrary(rig)
        page.send(lifecycleState(position: 2, duration: 15, video: lifecycleAdVideo, ad: true))
        for kind in [RemoteCommandKind.next, .previous, .seek, .skipForward, .skipBackward, .changeRate, .like, .dislike, .save] {
            #expect(rig.commands.press(kind, .position(5)) == nil, "\(kind) is off during an ad: the system has no button to press")
        }
        #expect(rig.commands.press(.pause) == .success)
        // A stray delivery of a disabled command is answered, not run.
        #expect(rig.commands.deliver(.next) == .commandFailed && rig.commands.deliver(.seek, .position(5)) == .commandFailed)
        #expect(!page.bodies.contains(WebMusicScripts.skip) && !page.bodies.contains(WebMusicScripts.seek), "nothing reached the page")
    }

    // MARK: advertisement

    @Test func duringAnAdvertisementOnlyPlayAndPauseAreAnswered() async throws {
        let (rig, page) = try await episodeRig()
        fullLibrary(rig)
        page.send(lifecycleState(position: 2, duration: 15, video: lifecycleAdVideo, ad: true))
        let off: [RemoteCommandKind] = [.next, .previous, .seek, .skipForward, .skipBackward, .changeRate, .like, .dislike, .save]
        for kind in off { #expect(rig.model.remote(sample(kind)) == .refused, "\(kind)") }
        #expect(rig.model.remote(.pause) == .success && rig.model.remote(.play) == .success)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!page.bodies.contains(WebMusicScripts.skip) && !page.bodies.contains(WebMusicScripts.seek) && rig.episodes.jumps.isEmpty && rig.episodes.rates.isEmpty && rig.library.pressed.isEmpty)
    }
    @Test func theLibraryIsNotEvenAskedDuringAnAdvertisement() async throws {
        let rig = try await MediaRig.make()
        let (_, page) = try await rig.play()
        page.send(lifecycleState(position: 2, duration: 15, video: lifecycleAdVideo, ad: true))
        rig.library.states = [.like: .available(FakeRemoteLibrary.control(.like))]
        let asked = rig.library.asked.count
        _ = rig.model.remoteCapabilities(); _ = rig.model.remote(.setLike(true))
        #expect(rig.library.asked.count == asked, "the ad rule is applied before any library lookup")
    }

    // MARK: play, seek, skip, speed

    @Test func playPauseAndSeekRunTheHiddenPlayersOwnCommands() async throws {
        let rig = try await MediaRig.make()
        let (_, page) = try await rig.play()
        #expect(rig.model.remote(.seek(60)) == .success)
        await rig.wait { page.bodies.contains(WebMusicScripts.seek) }
        #expect(page.commands.last { $0.body == WebMusicScripts.seek }?.arguments["seconds"] as? Double == 60)
        #expect(rig.model.remote(.pause) == .success)
        await rig.wait { page.bodies.last == WebMusicScripts.pause }
        #expect(page.bodies.last == WebMusicScripts.pause)
    }
    @Test func aSeekPastTheEndIsClampedByThePlayersOwnAdmissionAsTheSliderIs() async throws {
        let rig = try await MediaRig.make()
        let (_, page) = try await rig.play()
        _ = rig.model.remote(.seek(5000))
        await rig.wait { page.bodies.contains(WebMusicScripts.seek) }
        let target = page.commands.last { $0.body == WebMusicScripts.seek }?.arguments["seconds"] as? Double
        #expect(target.map { $0 <= 200 } == true, "the same admission the window's slider goes through: \(String(describing: target))")
    }
    @Test func episodeJumpsAndSpeedGoThroughThePodcastModelAndOnlyForAnEpisode() async throws {
        let (rig, _) = try await episodeRig()
        let capabilities = rig.model.remoteCapabilities()
        #expect(capabilities.skipBack == 15 && capabilities.skipForward == 30 && capabilities.rates == PodcastRate.steps)
        #expect(capabilities.enabled.isSuperset(of: [.skipBackward, .skipForward, .changeRate]))
        #expect(rig.model.remote(.skip(30)) == .success && rig.model.remote(.skip(-15)) == .success && rig.model.remote(.rate(1.5)) == .success)
        await rig.wait { rig.episodes.jumps.count == 2 && rig.episodes.rates.count == 1 }
        #expect(rig.episodes.jumps == [true, false] && rig.episodes.rates == [1.5])
        #expect(rig.model.remote(.rate(5)) == .refused && rig.model.remote(.rate(.nan)) == .refused, "a speed outside the player's range never reaches it")
        let song = try await MediaRig.make()
        try await song.play()
        #expect(song.model.remote(.skip(30)) == .refused && song.model.remote(.rate(1.5)) == .refused, "a song has no jumps or speed")
        #expect(song.model.remoteReason(.skipForward) == RemoteCommandReason.notEpisode)
    }
    @Test func anEpisodeWhoseShowIsUnknownCannotChangeSpeedAndSaysSo() async throws {
        let rig = try await MediaRig.make()
        rig.episodes.episode = RemoteEpisode(videoID: lifecycleVideo, show: nil, back: 15, forward: 30)
        try await rig.play()
        #expect(!rig.commands.enabled.contains(.changeRate) && rig.model.remoteReason(.changeRate) == RemoteCommandReason.episodeUnknownShow)
    }
    @Test func aLiveStreamWithNoWindowCannotBeSoughtAndSaysWhy() async throws {
        let rig = try await MediaRig.make()
        let (_, page) = try await rig.play(state: lifecycleState(position: 100, duration: 0))
        var body = systemMediaLiveBody(); body["seekEnd"] = 0.2
        page.send(body)
        #expect(!rig.commands.enabled.contains(.seek) && rig.model.remoteReason(.seek) == RemoteCommandReason.liveWindow)
        #expect(rig.model.remote(.seek(10)) == .refused)
    }

    // MARK: like, dislike, save: the ledger, only from a press

    @Test func likeDislikeAndSaveEachPressTheLedgerControlOnceAndOnlyWhenPressed() async throws {
        let rig = try await MediaRig.make()
        try await rig.play()
        fullLibrary(rig)
        _ = rig.model.remoteCapabilities()
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.library.pressed.isEmpty, "reading the capabilities, switching buttons on and four track changes press nothing")
        #expect(rig.model.remote(.setLike(true)) == .success && rig.model.remote(.setDislike(true)) == .success && rig.model.remote(.setSave(true)) == .success)
        await rig.wait { rig.library.pressed.count == 3 }
        #expect(rig.library.pressed.map(\.kind) == [.like, .dislike, .save], "one press per command")
    }
    @Test func aLibraryChangeWithNoWritePathIsOffWithTheLedgersOwnReason() async throws {
        let rig = try await MediaRig.make()
        try await rig.play()
        rig.library.states = [.like: .available(FakeRemoteLibrary.control(.like)), .dislike: .unavailable(RemoteCommandReason.noDislike), .save: .unavailable(RemoteCommandReason.noSave)]
        _ = rig.model.remoteCapabilities()
        #expect(rig.model.remote(.setLike(true)) == .success && rig.model.remote(.setDislike(true)) == .refused && rig.model.remote(.setSave(true)) == .refused)
        #expect(rig.model.remoteReason(.dislike) == RemoteCommandReason.noDislike && rig.model.remoteReason(.save) == RemoteCommandReason.noSave)
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.library.pressed.count == 1)
    }
    @Test func theSystemsLikeButtonShowsOnWhenTheSongIsLiked() async throws {
        let rig = try await MediaRig.make()
        try await rig.play()
        rig.library.states = [.like: .available(FakeRemoteLibrary.control(.like, on: true))]
        let page = try #require(rig.log.pages.first)
        page.send(lifecycleState(position: 11))
        #expect(rig.model.nowPlaying.currentCapabilities.active == [RemoteCommandKind.like])
    }
    @Test func theShellIsTheLedgerSideAndTellsEachCauseApart() async throws {
        let rig = try await MediaRig.make()
        let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(),
                                     preferences: InMemoryDefaults(), installsStatusItem: false)
        #expect(rig.model.remoteLibrary === shell, "the model's library side is the shell, the one that owns the like path")
        guard case .unavailable(let nothing) = shell.remoteLibraryControl(.like) else { Issue.record("nothing playing"); return }
        let (_, page) = try await rig.play()
        guard case .unavailable(let unread) = shell.remoteLibraryControl(.like) else { Issue.record("page not read"); return }
        shell.libraryControlsProvider = { _ in [FakeRemoteLibrary.control(.like)] }
        guard case .available(let like) = shell.remoteLibraryControl(.like), like.kind == .like else { Issue.record("like"); return }
        guard case .unavailable(let noDislike) = shell.remoteLibraryControl(.dislike), case .unavailable(let noSave) = shell.remoteLibraryControl(.save) else { Issue.record("dislike, save"); return }
        page.send(lifecycleState(position: 2, duration: 15, video: lifecycleAdVideo, ad: true))
        guard case .unavailable(let ad) = shell.remoteLibraryControl(.like) else { Issue.record("ad"); return }
        #expect(Set([nothing, unread, noDislike, noSave, ad]).count == 5, "five causes, five sentences")
        var pressed: [LibraryControl] = []
        shell.likePress = { pressed.append($0) }
        await shell.remoteLibraryPress(like)
        #expect(pressed == [like], "the press is the mini-player's own like path, which ends at the W12 ledger")
        let source = try LifecycleSources.source("Sources/AppShell/Lifecycle/ShellComposition.swift")
        #expect(source.contains("LibraryControlPress.press(control, ledger: self.library.ledger, social: self.social)"))
    }

    // MARK: route loss (W22) and fencing

    @Test func aMediaKeyPlayAfterARouteLossPlaysOnThisMacWithoutAsking() async throws {
        let rig = try await MediaRig.make(outputs: true)
        let (player, page) = try await rig.play()
        rig.directory?.change([routeSpeakers], defaultUID: routeSpeakers.uid)
        await rig.controller?.coordinator.settled()
        let plays = page.bodies.filter { $0 == WebMusicScripts.play }.count
        #expect(!player.snapshot.intent, "the loss paused it")
        #expect(rig.model.remote(.toggle) == .success)
        await rig.wait { page.bodies.filter { $0 == WebMusicScripts.play }.count > plays }
        #expect(page.bodies.filter { $0 == WebMusicScripts.play }.count == plays + 1 && rig.controller?.coordinator.prompt == nil)
    }
    @Test func aCommandAdmittedUnderOneOwnershipNeverReachesTheNextOne() throws {
        let system = NowPlayingSystem.recording()
        let center = NowPlayingCenter(system: system.system)
        var delivered: [RemoteTransportCommand] = []
        center.activate { delivered.append($0); return .success }
        let stamp = center.ownershipGeneration
        center.deliverAdmitted(.pause, generation: stamp)
        #expect(delivered == [.pause])
        center.relinquish()                                  // the account went away
        center.activate { delivered.append($0); return .success }     // and the next account's item took the keys
        center.deliverAdmitted(.pause, generation: stamp)
        #expect(delivered == [.pause], "a late delivery from the previous ownership is dropped")
        center.deliverAdmitted(.pause, generation: center.ownershipGeneration)
        #expect(delivered == [.pause, .pause])
    }
    @Test func aCommandAfterTheAccountBarrierFindsNothingToAct() async throws {
        let rig = try await MediaRig.make()
        try await rig.play()
        fullLibrary(rig)
        try await rig.detach()
        await rig.wait { !rig.model.nowPlaying.isActive }
        for kind in RemoteCommandKind.allCases { #expect(rig.model.remote(sample(kind)) == .noActionableItem, "\(kind)") }
        #expect(rig.library.pressed.isEmpty && rig.commands.deliver(.play) == nil)
    }

    // MARK: the system's events

    @Test func systemEventsBecomeCommandsOnlyWhenTheirArgumentIsSane() {
        #expect(RemoteEventMapping.command(.seek, .position(30)) == .seek(30))
        #expect(RemoteEventMapping.command(.seek, .position(-1)) == nil && RemoteEventMapping.command(.seek, .position(.nan)) == nil && RemoteEventMapping.command(.seek, .none) == nil)
        #expect(RemoteEventMapping.command(.skipForward, .interval(30)) == .skip(30) && RemoteEventMapping.command(.skipBackward, .interval(15)) == .skip(-15))
        #expect(RemoteEventMapping.command(.skipForward, .interval(0)) == nil && RemoteEventMapping.command(.skipBackward, .interval(.infinity)) == nil)
        #expect(RemoteEventMapping.command(.changeRate, .rate(1.5)) == .rate(1.5) && RemoteEventMapping.command(.changeRate, .rate(0)) == nil)
        for kind in [RemoteCommandKind.play, .pause, .toggle, .next, .previous, .like, .dislike, .save] { #expect(RemoteEventMapping.command(kind, .none)?.kind == kind) }
        let mapped = RemoteCommandKind.allCases.compactMap { RemoteEventMapping.command($0, .position(1))?.kind }
        #expect(mapped.contains(.seek))
    }
    @Test func theTransportBarAndTheKeysShareOneEntry() throws {
        let transport = try LifecycleSources.source("Sources/AppShell/Lifecycle/ShellTransport.swift")
        #expect(transport.contains("func shellTogglePlayPause() { _ = remote(.toggle) }") && transport.contains("func shellNext() { _ = remote(.next) }"))
        let panel = try LifecycleSources.source("Sources/AppShell/PlaybackPanel.swift")
        #expect(panel.contains("let capabilities = remoteCapabilities()") && panel.contains("guard capabilities.enabled.contains(command.kind) else { return .refused }"))
        #expect(panel.contains("nowPlaying.update(item, capabilities: capabilities)"), "the buttons the system shows come from the same function the handler asks")
    }
}
