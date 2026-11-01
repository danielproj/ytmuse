import Foundation
import MediaPlayer
import Testing
@testable import Playback
@testable import AppShell

/// T23 (MAC01, PLAY17). The expiry of the hidden player's sleep timer reaches Now Playing from the player's own events, with no window, popover or
/// mini-player open (the W23 R3-1 rule), against the RECORDING stand-in for the Mac's Now Playing centre: nothing here holds the account holder's media keys.
@Suite @MainActor struct NowPlayingSleepTimerTests {
    private func started(_ timing: ManualSleepTiming) async throws -> (MediaRig, WebMusicPlayer, FakeMusicPage) {
        let rig = try await MediaRig.make(timing: timing)
        let (player, page) = try await rig.play()
        await rig.wait { rig.info.state == .playing }
        #expect(!rig.model.isObservingUI && rig.model.visibleUIObserverCount == 0 && rig.info.state == .playing, "no window observes the owner")
        return (rig, player, page)
    }
    private func rate(_ rig: MediaRig) -> Double? { rig.info.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double }

    @Test func theTimersPauseIsPublishedPausedWithNoWindowAndTheFadeBeforeItIsNotAPause() async throws {
        let timing = ManualSleepTiming()
        let (rig, player, page) = try await started(timing)
        _ = await player.setSleepTimer(.minutes(5))
        timing.advance(300); await player.sleepTimerTick()
        timing.advance(2.5); await player.sleepTimerTick()
        #expect(player.sleepTimerState?.fading == true && rig.info.state == .playing && rate(rig) == 1, "while it fades the sound is still playing: Now Playing says so")
        timing.advance(2.5); await player.sleepTimerTick()
        await rig.wait { rig.info.state == .paused }                 // and NO refresh call from here: the player's own change reaches the owner
        #expect(rig.info.state == .paused && rate(rig) == 0, "Now Playing says paused, not 'playing at rate 1'")
        #expect(page.bodies.last == WebMusicScripts.fadeVolume, "the pause was followed by putting the level back")
        #expect(rig.commands.registrationCount >= 1, "the owner still holds the item: a pause is not a stop")
    }
    @Test func endOfItemAtTheBoundaryIsPublishedPausedWithNoWindow() async throws {
        let timing = ManualSleepTiming()
        let (rig, player, page) = try await started(timing)
        _ = await player.setSleepTimer(.endOfItem)
        page.send(["type": "ended", "doc": 1, "load": 1, "videoId": lifecycleVideo])
        await rig.wait { player.sleepTimerState == nil }
        await rig.wait { rig.info.state != .playing }
        #expect(rig.info.state != .playing && rate(rig) == 0)
        #expect(player.sleepTimerHasExpired())
    }
    @Test func aTimerCancelledByAnAccountSwitchLeavesNothingPublishedByIt() async throws {
        let timing = ManualSleepTiming()
        let (rig, player, page) = try await started(timing)
        _ = await player.setSleepTimer(.minutes(5))
        try await rig.detach()
        let writes = rig.info.writes.count
        timing.advance(1000); await player.sleepTimerTick()
        #expect(rig.info.writes.count == writes, "the old account's timer publishes nothing")
        _ = page
    }
}
