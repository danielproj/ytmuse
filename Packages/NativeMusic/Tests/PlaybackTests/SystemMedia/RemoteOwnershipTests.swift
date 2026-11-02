import AppKit
import Foundation
import MediaPlayer
import Testing
@testable import Features
@testable import Playback
@testable import SystemIntegration
@testable import AppShell
import TestSupport

/// T23.2 (MAC01, WIN04): however many windows, mini-players and popovers are open there is ONE Now Playing owner and ONE set of remote-command
/// registrations; the owner holds the keys only while an item is active and lets go when it is not, so another media application can take them.
@Suite @MainActor struct RemoteOwnershipTests {
    private func shell(_ rig: MediaRig) -> ShellCoordinator {
        ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(),
                         preferences: InMemoryDefaults(), installsStatusItem: false)
    }

    @Test func nothingIsRegisteredBeforeThereIsAnItem() async throws {
        let rig = try await MediaRig.make()
        #expect(rig.commands.attachCount == 0 && rig.commands.registrationCount == 0 && rig.info.writes.isEmpty && !rig.model.nowPlaying.isActive)
    }
    @Test func severalWindowsAMiniPlayerAndAnotherPlayedItemStillMakeOneRegistration() async throws {
        let rig = try await MediaRig.make()
        let shell = shell(rig)
        let (_, page) = try await rig.play()
        for _ in 0..<3 { rig.model.observe(UUID(), visible: true) }      // three browser windows
        shell.showMiniPlayer()                                            // and the mini-player
        page.send(lifecycleState(position: 20, video: lifecycleOtherVideo, title: "Another Song"))
        page.send(lifecycleState(position: 21, video: lifecycleVideo))
        #expect(rig.commands.attachCount == 1 && rig.commands.refusedOwners == 0, "one registration, never re-made")
        #expect(rig.commands.registrationCount == RemoteCommandKind.allCases.count && rig.commands.owner == ObjectIdentifier(rig.model.nowPlaying))
        shell.stop()
        #expect(rig.commands.registrationCount == 0, "quit lets go")
    }
    @Test func aSecondOwnerOnTheSameSystemIsRefusedAndPublishesNothing() async throws {
        let rig = try await MediaRig.make()
        try await rig.play()
        let writes = rig.info.writes.count
        let intruder = NowPlayingCenter(system: rig.system.system)
        #expect(!intruder.activate { _ in .success } && !intruder.isActive && rig.commands.refusedOwners == 1)
        intruder.update(NowPlayingItem(title: "Intruder", artist: nil, album: nil, artwork: nil, duration: 10, elapsed: 0, playing: true, advertisement: false))
        #expect(rig.info.writes.count == writes && rig.info.info?[MPMediaItemPropertyTitle] as? String == "Synthetic Song", "it published nothing over the owner")
        intruder.relinquish()
        #expect(rig.commands.owner == ObjectIdentifier(rig.model.nowPlaying), "and its relinquish did not take the owner's keys")
    }
    @Test func askingToActivateAgainIsOneRegistrationNotTwo() throws {
        let system = NowPlayingSystem.recording()
        let center = NowPlayingCenter(system: system.system)
        for _ in 0..<5 { #expect(center.activate { _ in .success }) }
        #expect(system.commands.attachCount == 1 && center.registrationCount == RemoteCommandKind.allCases.count)
    }

    // MARK: attaches with an item, detaches without one

    @Test func relinquishingFreesTheKeysForAnotherMediaApplicationAndPlayingAgainTakesThemBack() async throws {
        let rig = try await MediaRig.make()
        try await rig.play()
        rig.model.endNowPlaying()
        #expect(rig.commands.registrationCount == 0 && rig.info.info == nil && rig.info.state == .stopped)
        let other = NowPlayingCenter(system: rig.system.system)      // another media application, on the same keys
        #expect(other.activate { _ in .success }, "free to take them")
        other.relinquish()
        let attached = rig.commands.attachCount
        let page = try #require(rig.log.pages.first)
        page.send(lifecycleState(position: 30))                       // the person plays again
        #expect(rig.commands.attachCount == attached + 1 && rig.model.nowPlaying.isActive && rig.info.info != nil)
    }
    @Test func aFinishedItemWithNothingAfterItLetsGoAfterAGraceAndAnItemThatFollowsKeepsTheKeys() async throws {
        let rig = try await MediaRig.make()
        rig.model.endedGrace = .milliseconds(60)
        let (_, page) = try await rig.play()
        page.send(["type": "ended", "doc": 1, "load": 1, "videoId": lifecycleVideo])
        page.send(lifecycleState(position: 0, video: lifecycleOtherVideo, title: "The Next Song"))      // YouTube moves on by itself
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.model.nowPlaying.isActive && rig.info.info?[MPMediaItemPropertyTitle] as? String == "The Next Song", "the next item kept the keys")
        page.send(["type": "ended", "doc": 1, "load": 1, "videoId": lifecycleOtherVideo])
        await rig.wait { !rig.model.nowPlaying.isActive }
        #expect(!rig.model.nowPlaying.isActive && rig.commands.registrationCount == 0 && rig.info.info == nil, "nothing followed: the keys are free")
    }
    @Test func theAccountBarrierAndQuitBothLetGo() async throws {
        let rig = try await MediaRig.make()
        try await rig.play()
        try await rig.detach()
        await rig.wait { !rig.model.nowPlaying.isActive }
        #expect(rig.commands.registrationCount == 0 && rig.commands.detachCount == 1)
        let again = try await MediaRig.make()
        let shell = shell(again)
        try await again.play()
        shell.stop()
        #expect(again.commands.registrationCount == 0 && again.info.info == nil, "quit releases the keys")
        let quitting = try await MediaRig.make()
        try await quitting.play()
        await quitting.authority.quit()
        await quitting.wait { !quitting.model.nowPlaying.isActive }
        #expect(quitting.commands.registrationCount == 0 && quitting.info.info == nil, "and so does the owner's own quit")
    }
    @Test func aPlayerRestoredPausedOwnsTheKeysBecauseItIsAnItem() async throws {
        let rig = try await MediaRig.make()
        let player = WebMusicPlayerTestingRestore.restored(rig.model)
        #expect(player != nil && rig.model.nowPlaying.isActive && rig.commands.registrationCount == RemoteCommandKind.allCases.count)
        #expect(!rig.commands.enabled.contains(.next) && !rig.commands.enabled.contains(.seek) && rig.commands.enabled.contains(.play), "Play starts it; skipping waits for Play")
    }

    // MARK: structure: one construction site

    @Test func thereIsOneNowPlayingOwnerInTheSourcesAndOneOwnerOfEachSystemCentre() async throws {
        let (owners, remoteCenters, infoCenters, systemInit) = await LifecycleSources.offMain { () -> ([String], [String], [String], [String]) in
            var owners: [String] = [], remote: [String] = [], info: [String] = [], system: [String] = []
            for file in LifecycleSources.swiftFiles(under: LifecycleSources.packageRoot.appendingPathComponent("Sources")) + LifecycleSources.swiftFiles(under: LifecycleSources.repositoryRoot.appendingPathComponent("App/Sources")) {
                for (line, code) in LifecycleSources.code(file) {
                    let place = "\(file.lastPathComponent):\(line)"
                    if code.contains("NowPlayingCenter(") && !code.contains("class NowPlayingCenter") { owners.append(place) }
                    if code.contains("MPRemoteCommandCenter.shared()") { remote.append(file.lastPathComponent) }
                    if code.contains("MPNowPlayingInfoCenter.default()") { info.append(file.lastPathComponent) }
                    if file.path.contains("/AppShell/") && code.contains("NowPlayingSystem.live") { system.append(place) }
                }
            }
            return (owners, remote, info, system)
        }
        #expect(owners.count == 1 && owners.allSatisfy { $0.hasPrefix("PlaybackPanel.swift") }, "the one playback owner builds the one Now Playing owner: \(owners)")
        #expect(Set(remoteCenters) == ["RemoteCommands.swift"] && Set(infoCenters) == ["RemoteCommands.swift"], "only the system layer touches MediaPlayer's centres: \(remoteCenters) \(infoCenters)")
        #expect(!systemInit.isEmpty && systemInit.allSatisfy { $0.hasPrefix("PlaybackPanel.swift") }, "the live system is named at the owner's construction and nowhere else in the app: \(systemInit)")
    }
    @Test func noSurfaceOtherThanTheOwnerPublishesOrRegisters() async throws {
        let offenders = await LifecycleSources.offMain { () -> [String] in
            var bad: [String] = []
            for file in LifecycleSources.swiftFiles(under: LifecycleSources.packageRoot.appendingPathComponent("Sources/AppShell")) where file.lastPathComponent != "PlaybackPanel.swift" && file.lastPathComponent != "RemoteCommandLayer.swift" {
                for (line, code) in LifecycleSources.code(file) where code.contains(".activate {") && code.contains("nowPlaying") || code.contains("nowPlaying.update(") || code.contains("nowPlaying.relinquish(") { bad.append("\(file.lastPathComponent):\(line)") }
            }
            return bad
        }
        #expect(offenders.isEmpty, "windows, the mini-player and the popover read the model; none talks to Now Playing: \(offenders)")
    }
}

/// A restored paused item the way a cold launch makes it (WIN09), without a store: the player is restored and joins the one owner.
@MainActor enum WebMusicPlayerTestingRestore {
    static func restored(_ model: PlaybackModel) -> WebMusicPlayer? {
        let player = WebMusicPlayer(cookies: FakeCookieSource(), makePage: { FakeMusicPage(delegate: $0) })
        guard player.restoreLastSession(playlistID: "PLsyntheticLife", playlistTitle: "Synthetic Mix", videoID: lifecycleVideo, title: "Synthetic Song", artist: "Synthetic Artist", position: 42, duration: 200) else { return nil }
        model.attachRestored(player)
        return player
    }
}
