import Foundation
import Testing
import Domain
@testable import Playback
@testable import AppShell

/// T21 (PLAY17) on the real playback owner with a fake hidden page: the YouTube Music sleep timer through account switch, quit, the system sleep and
/// the wake, and the one timer of the application session across the two engines.
@Suite @MainActor struct LifecycleWebSleepTimerTests {
    private func playing(_ timing: ManualSleepTiming = ManualSleepTiming()) async throws -> (WebMusicPlayer, FakeMusicPage, LifecycleRig, ManualSleepTiming) {
        let rig = try await LifecycleRig.make(timing: timing)
        let (player, page) = try await rig.play()
        return (player, page, rig, timing)
    }
    private func count(_ page: FakeMusicPage, _ body: String) -> Int { page.bodies.filter { $0 == body }.count }

    // MARK: Cancelled by an account switch and by quit

    @Test func anAccountSwitchCancelsTheTimerAndNothingRunsAfterIt() async throws {
        let (player, page, rig, timing) = try await playing()
        _ = await player.setSleepTimer(.minutes(5))
        try await rig.detach()
        #expect(player.isClosed && player.sleepTimerState == nil && rig.model.sleepTimerDisplay == nil)
        let sent = page.commands.count
        timing.advance(400); await player.sleepTimerTick()
        #expect(page.commands.count == sent && !player.sleepTimerHasExpired(), "a timer that belonged to the old account fires nothing for the new one")
    }
    @Test func quitCancelsTheTimerEvenInTheMiddleOfAFade() async throws {
        let (player, page, rig, timing) = try await playing()
        _ = await player.setSleepTimer(.custom(60))
        timing.advance(60); await player.sleepTimerTick(); timing.advance(1); await player.sleepTimerTick()
        #expect(player.sleepTimerState?.fading == true)
        await rig.authority.quit()
        #expect(player.isClosed && player.sleepTimerState == nil)
        let sent = page.commands.count
        timing.advance(10); await player.sleepTimerTick()
        #expect(page.commands.count == sent, "the fade does not continue on a page that is being dropped")
    }
    @Test func signingOutOrRemovingTheAccountEndsTheTimerThroughTheSameBarrier() async throws {
        let (player, _, rig, _) = try await playing()
        _ = await player.setSleepTimer(.endOfItem)
        await rig.authority.quit()
        #expect(player.sleepTimerState == nil && rig.model.music == nil, "the owner let go of the player and its timer")
        #expect(rig.model.sleepTimerDisplay == nil)
    }

    // MARK: Expiry during sleep

    @Test func aTimerThatRanOutWhileTheMacSleptKeepsTheWakeFromResuming() async throws {
        let (player, page, rig, timing) = try await playing()
        _ = await player.setSleepTimer(.custom(600))
        #expect(await rig.model.holdForSleep(), "it was playing: the page is paused for the sleep")
        timing.advance(700)                                       // the Mac slept past the deadline
        let facts = await rig.model.holdFacts()
        #expect(facts.timerExpired && !facts.personChanged && !facts.ownerChanged, "the deadline counts time asleep")
        #expect(await rig.model.finishWake(resume: true) == false, "even a wake that would resume does not, because the timer ran out")
        #expect(count(page, WebMusicScripts.play) == 0)
    }
    @Test func theTimersOwnLoopFindingItFirstAfterTheWakeChangesNothing() async throws {
        let (player, page, rig, timing) = try await playing()
        _ = await player.setSleepTimer(.custom(600))
        #expect(await rig.model.holdForSleep())
        let pauses = count(page, WebMusicScripts.pause)
        timing.advance(700); await player.sleepTimerTick()        // the loop looks before the wake handler does
        #expect(player.sleepTimerState == nil && count(page, WebMusicScripts.pause) == pauses && !page.bodies.contains(WebMusicScripts.fadeVolume), "no fade on a page that is already paused")
        let facts = await rig.model.holdFacts()
        #expect(facts.timerExpired, "the expiry is remembered after the timer has gone")
        #expect(await rig.model.finishWake(resume: true) == false && count(page, WebMusicScripts.play) == 0)
        await player.resume()
        #expect(!player.sleepTimerHasExpired(), "a person's Play ends the timer's hold")
    }
    @Test func aTimerThatDidNotRunOutDoesNotStopTheWakeFromResuming() async throws {
        let (player, page, rig, timing) = try await playing()
        _ = await player.setSleepTimer(.custom(600))
        #expect(await rig.model.holdForSleep())
        timing.advance(60)
        #expect(await rig.model.holdFacts().timerExpired == false)
        #expect(await rig.model.finishWake(resume: true) && count(page, WebMusicScripts.play) == 1, "ten minutes were set and one passed: the wake resumes")
        #expect(player.sleepTimerState != nil, "and the timer is still counting")
    }
    @Test func theWholeWakePathStaysPausedWhenTheTimerRanOut() async throws {
        let (player, page, rig, timing) = try await playing()
        let power = PowerLifecycleCoordinator(transport: rig.model, route: FixedRoute(result: true), display: ShellDisplayState(), resumePreference: { true }, sleep: { _ in })
        _ = await player.setSleepTimer(.custom(600))
        await power.handle(.systemWillSleep)
        timing.advance(1000)
        await power.handle(.systemDidWake)
        #expect(power.lastDecision == .stayPaused(.timerExpired) && count(page, WebMusicScripts.play) == 0)
    }
    @Test func theWakeGuardOnThePlayerHoldsEvenIfTheCallerForgotToAsk() async throws {
        let (player, page, _, timing) = try await playing()
        _ = await player.setSleepTimer(.custom(600))
        let hold = try #require(await player.holdForSystemSleep())
        timing.advance(700)
        #expect(await player.resumeAfterSystemWake(hold) == false && count(page, WebMusicScripts.play) == 0)
    }
    @Test func aTimerThatPausedThePlayerBeforeTheMacSleptStillStandsAfterTheWake() async throws {
        let (player, page, rig, timing) = try await playing()
        _ = await player.setSleepTimer(.minutes(5))
        timing.advance(300); await player.sleepTimerTick(); timing.advance(5); await player.sleepTimerTick()
        #expect(!player.snapshot.intent)
        #expect(await rig.model.holdForSleep() == false, "nothing was playing: nothing to hold or resume")
        #expect(await rig.model.finishWake(resume: true) == false && count(page, WebMusicScripts.play) == 0)
    }

    // MARK: One timer across the two engines

    @Test func theTimerToCarryIsWhatIsLeftOfARunningOneOrEndOfItemAndNeverAFadingOne() async throws {
        let (player, _, rig, timing) = try await playing()
        #expect(rig.model.sleepTimerToCarry(leavingYouTubeMusic: true) == nil, "no timer, nothing to carry")
        _ = await player.setSleepTimer(.minutes(10))
        timing.advance(240)
        #expect(rig.model.sleepTimerToCarry(leavingYouTubeMusic: true) == .custom(360))
        _ = await player.setSleepTimer(.endOfItem)
        #expect(rig.model.sleepTimerToCarry(leavingYouTubeMusic: true) == .endOfItem)
        _ = await player.setSleepTimer(.custom(60))
        timing.advance(60); await player.sleepTimerTick()
        #expect(rig.model.sleepTimerToCarry(leavingYouTubeMusic: true) == nil, "a fade already under way is ending, not moving")
        #expect(rig.model.sleepTimerToCarry(leavingYouTubeMusic: false) == nil, "and the native side has none")
    }
    @Test func aNativeTimerKeepsRunningOnTheHiddenPlayerWhenYouTubeMusicStarts() async throws {
        let timing = ManualSleepTiming()
        let rig = try await MediaRig.make(timing: timing)
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.model.session = session
        await rig.model.refresh()
        try await session.setTimer(.minutes(15))
        await rig.model.refresh()
        await rig.wait { rig.model.sleepTimerDisplay != nil }
        #expect(rig.model.sleepTimerDisplay != nil)
        _ = await rig.model.playMusic(playlistID: "PLsyntheticLife", title: "Synthetic Mix", request: rig.authority.requestOwnedStart())
        let page = try #require(rig.log.pages.first)
        page.commitLast(); page.send(lifecycleState())
        let player = try #require(rig.model.music)
        let remaining = try #require(player.sleepTimerState?.remaining(at: timing.wall()))
        #expect(remaining > 800 && remaining <= 900, "the minutes that were left, not a new fifteen (\(remaining))")
        #expect(rig.model.sleepTimerDisplay?.deadline != nil)
        await session.close()
    }
}
