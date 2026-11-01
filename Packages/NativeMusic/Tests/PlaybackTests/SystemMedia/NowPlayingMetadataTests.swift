import AppKit
import Foundation
import MediaPlayer
import OutputRoutes
import Testing
@testable import Features
@testable import Playback
@testable import SystemIntegration
@testable import AppShell

/// T23.1 (MAC01): what the system is shown reflects duration, rate, elapsed position, state and the current route, and an item or account change
/// removes the stale artwork, state and route in the same update. Against a RECORDING Now Playing system: nothing reaches the Mac's media session.
@Suite @MainActor struct NowPlayingMetadataTests {
    private func song(artwork: Data? = nil, album: String? = nil, route: NowPlayingRoute? = nil, id: String = "A", rate: Double = 1) -> NowPlayingItem {
        NowPlayingItem(title: "Synthetic Song \(id)", artist: "Synthetic Artist", album: album, artwork: artwork, duration: 200, elapsed: 10, playing: true, advertisement: false,
                       rate: rate, route: route, itemID: id)
    }
    private func owner() -> (NowPlayingCenter, RecordingNowPlayingSystem) {
        let system = NowPlayingSystem.recording()
        let center = NowPlayingCenter(system: system.system)
        #expect(center.activate { _ in .success })
        return (center, system)
    }

    @Test func aPlayingSongPublishesTitleArtistLengthPositionRateAndStateTogether() async throws {
        let rig = try await MediaRig.make()
        try await rig.play(state: lifecycleState(position: 42, duration: 200))
        let info = try #require(rig.info.info)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Synthetic Song" && info[MPMediaItemPropertyArtist] as? String == "Synthetic Artist")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 200 && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1 && info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.audio.rawValue)
        #expect(rig.info.state == .playing)
    }
    @Test func pausingPublishesRateZeroAtThePausedPositionNotAnExtrapolatedOne() async throws {
        let rig = try await MediaRig.make()
        let (_, page) = try await rig.play(state: lifecycleState(position: 42))
        page.send(lifecycleState(playing: false, position: 57))
        let info = try #require(rig.info.info)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0 && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 57 && rig.info.state == .paused)
        page.send(lifecycleState(playing: true, position: 57.4))
        #expect(rig.info.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1 && rig.info.state == .playing, "playing again re-anchors at the position")
    }
    @Test func theAnchorIsTheUpdateItselfAndTheSystemsClockStaysRightAtTheListeningSpeed() throws {
        let (center, system) = owner()
        center.update(song(rate: 1.5))
        let info = try #require(system.info.info)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 10 && info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
        let first = song(rate: 1.5)
        var onTime = first; onTime.elapsed = 25      // ten seconds at 1.5x: exactly where the system's clock already is
        var drifted = first; drifted.elapsed = 20    // a jump back that the system's extrapolation cannot know
        #expect(!NowPlayingMapping.needsUpdate(from: first, elapsedSince: .seconds(10), to: onTime))
        #expect(NowPlayingMapping.needsUpdate(from: first, elapsedSince: .seconds(10), to: drifted))
        var paused = first; paused.playing = false
        #expect(NowPlayingMapping.needsUpdate(from: first, elapsedSince: .seconds(1), to: paused), "a change of state is published at once")
    }
    @Test func theElapsedTimeNeverExceedsTheLengthAndABufferingItemHasNoRate() throws {
        var item = song(); item.elapsed = 500
        #expect(NowPlayingMapping.info(item)[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 200)
        item.elapsed = -3
        #expect(NowPlayingMapping.info(item)[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 0)
        item.playing = false
        #expect(NowPlayingMapping.info(item)[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    }
    @Test func albumAndArtworkArePublishedWhenKnownAndDroppedWithTheItem() throws {
        let (center, system) = owner()
        center.update(song(artwork: systemMediaPNG(), album: "Synthetic Album"))
        let withArt = try #require(system.info.info)
        #expect(withArt[MPMediaItemPropertyAlbumTitle] as? String == "Synthetic Album" && withArt[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
        center.update(song(id: "B"))
        let next = try #require(system.info.info)
        #expect(next[MPMediaItemPropertyArtwork] == nil && next[MPMediaItemPropertyAlbumTitle] == nil && center.artworkObject == nil, "no stale picture from the previous item")
    }
    @Test func anItemChangeReplacesTitleArtworkRouteAndStateInOneUpdate() throws {
        let (center, system) = owner()
        center.update(song(artwork: systemMediaPNG(), album: "Old Album", route: NowPlayingRoute(kind: .airPlay, name: "Kitchen"), id: "A", rate: 1.5))
        let writes = system.info.writes.count
        var next = song(id: "B"); next.playing = false; next.route = NowPlayingRoute(kind: .thisMac, name: "Synthetic Speakers")
        center.update(next)
        #expect(system.info.writes.count == writes + 1, "one update, not a clear and a set")
        let info = try #require(system.info.info)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Synthetic Song B" && info[MPMediaItemPropertyArtwork] == nil && info[MPMediaItemPropertyAlbumTitle] == nil)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0 && system.info.state == .paused)
        #expect(center.current?.route == NowPlayingRoute(kind: .thisMac, name: "Synthetic Speakers") && center.current?.itemID == "B")
        #expect(NowPlayingMapping.needsUpdate(from: song(route: NowPlayingRoute(kind: .airPlay)), elapsedSince: .zero, to: song(route: NowPlayingRoute(kind: .thisMac))), "a route change alone is published")
    }
    @Test func aLiveStreamHasNoDurationAndNoElapsedTime() async throws {
        let rig = try await MediaRig.make()
        let (_, page) = try await rig.play(state: lifecycleState(position: 100, duration: 0))
        page.send(systemMediaLiveBody())
        let info = try #require(rig.info.info)
        #expect(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil, "no fake duration, no fake clock")
        #expect(rig.model.nowPlaying.current?.duration == 0 && rig.model.nowPlaying.current?.live == true)
    }
    @Test func anAdvertisementIsPublishedAsAnAdvertisementWithNothingOfTheSongAndNoSeek() async throws {
        let rig = try await MediaRig.make()
        let (_, page) = try await rig.play(state: lifecycleState(position: 42))
        page.send(lifecycleState(position: 3, duration: 15, video: lifecycleAdVideo, title: "Some Advertiser", artist: "Ad Artist", ad: true))
        let info = try #require(rig.info.info)
        #expect(info[MPMediaItemPropertyTitle] as? String == NowPlayingMapping.advertisementTitle, "the honest Ad state, not the ad's own text")
        #expect(info[MPMediaItemPropertyArtist] == nil && info[MPMediaItemPropertyAlbumTitle] == nil && info[MPMediaItemPropertyArtwork] == nil)
        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil)
        #expect(rig.info.state == .playing, "the ad is playing; the buttons say so")
        #expect(!rig.commands.enabled.contains(.seek) && !rig.commands.enabled.contains(.next) && !rig.commands.enabled.contains(.previous) && rig.commands.enabled.contains(.pause))
        page.send(lifecycleState(position: 1, video: lifecycleVideo))
        #expect(rig.info.info?[MPMediaItemPropertyTitle] as? String == "Synthetic Song" && rig.commands.enabled.contains(.seek), "the song is back after the ad, with its controls")
    }
    @Test func anAdvertisementDropsThePictureEvenWhenTheItemStillCarriesOne() throws {
        let (center, system) = owner()
        var ad = song(artwork: systemMediaPNG(), album: "Synthetic Album"); ad.advertisement = true
        center.update(ad)
        let info = try #require(system.info.info)
        #expect(info[MPMediaItemPropertyArtwork] == nil && center.artworkObject == nil && info[MPMediaItemPropertyAlbumTitle] == nil, "the interrupted song's picture is not the ad's")
    }
    @Test func theElementsListeningSpeedIsWhatTheSystemsClockRunsAt() async throws {
        let rig = try await MediaRig.make()
        let (player, _) = try await rig.play()
        let item = PlaybackModel.webNowPlayingItem(player.snapshot, artwork: nil, player: player)
        #expect(item.rate == 1 && NowPlayingMapping.info(item)[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        var fast = item; fast.rate = 2
        #expect(NowPlayingMapping.info(fast)[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 2)
        #expect(NowPlayingMapping.needsUpdate(from: item, elapsedSince: .seconds(1), to: fast), "a speed change is re-anchored at once")
    }

    // MARK: account change

    @Test func anAccountSwitchClearsNowPlayingAndLetsGoOfTheKeysWithNoWindowOpen() async throws {
        let rig = try await MediaRig.make()
        try await rig.play()
        #expect(rig.info.info != nil && rig.commands.registrationCount == RemoteCommandKind.allCases.count && !rig.model.isObservingUI, "no window is watching")
        try await rig.detach()
        await rig.wait { rig.info.info == nil }
        #expect(rig.info.info == nil && rig.info.state == .stopped && rig.model.nowPlaying.current == nil)
        #expect(rig.commands.registrationCount == 0 && rig.commands.owner == nil && !rig.model.nowPlaying.isActive, "the previous account's item is not visible and the keys are free")
    }
    @Test func signOutAndRemovalClearItToo() async throws {
        let rig = try await MediaRig.make()
        try await rig.play()
        try await rig.authority.removeLocal(rig.identity.id, context: rig.context)
        await rig.wait { rig.info.info == nil }
        #expect(rig.info.info == nil && rig.commands.registrationCount == 0)
    }
    @Test func aNativeSessionIsClearedByTheBarrierAndDoesNotComeBackWhileItWindsDown() async throws {
        let rig = try await MediaRig.make()
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.model.session = session
        await rig.model.refresh()
        await rig.wait { rig.model.nowPlaying.current?.itemID == OwnedMedia.items[0].rawValue }      // `refresh()` is not a synchronisation point: the session's own events drive one too
        #expect(rig.model.nowPlaying.isActive && rig.info.info != nil && rig.model.nowPlaying.current?.itemID == OwnedMedia.items[0].rawValue)
        try await rig.detach()
        await rig.wait { rig.info.info == nil }
        #expect(rig.info.info == nil && rig.commands.registrationCount == 0)
        await rig.model.refresh()     // the old session is still set and not yet closed here: it must publish nothing more
        try await Task.sleep(for: .milliseconds(100))      // absence cannot be waited for: give any (wrong) publication time to land
        #expect(rig.info.info == nil && !rig.model.nowPlaying.isActive, "a fenced session cannot take the keys back")
        await session.close()
    }

    // MARK: route (W22)

    @Test func theRoutePublishedIsTheOneTheItemIsAudibleOnAndChangesInTheSameUpdate() async throws {
        let rig = try await MediaRig.make(outputs: true)
        try await rig.play()
        #expect(rig.model.nowPlaying.current?.route == NowPlayingRoute(kind: .thisMac, name: routeBuds.name))
        let writes = rig.info.writes.count
        rig.directory?.change([routeSpeakers], defaultUID: routeSpeakers.uid)
        await rig.wait { rig.model.nowPlaying.current?.route?.name == routeSpeakers.name }
        #expect(rig.model.nowPlaying.current?.route == NowPlayingRoute(kind: .thisMac, name: routeSpeakers.name))
        #expect(rig.info.writes.count > writes, "the route change was published, not left for the next position tick")
    }
    @Test func aLostRouteIsAPauseTheSystemIsToldAbout() async throws {
        let rig = try await MediaRig.make(outputs: true)
        try await rig.play()
        rig.directory?.change([routeSpeakers], defaultUID: routeSpeakers.uid)
        await rig.controller?.coordinator.settled()
        await rig.wait { rig.info.state == .paused }
        #expect(rig.info.state == .paused && rig.info.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0, "a lost route pauses; the clock stops")
    }
    @Test func whileAReceiverPlaysTheElapsedTimeIsTheReceiversReadingAndTheRouteIsAirPlay() async throws {
        let rig = try await MediaRig.make(outputs: true)
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.model.session = session
        await rig.model.refresh()
        await rig.wait { rig.model.nowPlaying.current?.route?.kind == .thisMac }
        #expect(rig.model.nowPlaying.current?.route?.kind == .thisMac)
        await rig.controller?.externalPlaybackChanged(true)
        await rig.model.refresh()
        await rig.wait { rig.model.nowPlaying.current?.route == NowPlayingRoute(kind: .airPlay) }
        let reading = try #require(rig.controller?.coordinator.remotePosition())
        await rig.wait { rig.info.info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == reading }
        #expect(rig.model.nowPlaying.current?.route == NowPlayingRoute(kind: .airPlay), "a receiver renders the sound")
        #expect(rig.info.info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == reading, "exactly what the receiver side reported")
        await session.close()
    }
}
