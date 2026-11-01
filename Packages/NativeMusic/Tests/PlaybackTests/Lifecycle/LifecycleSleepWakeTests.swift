import AppKit
import Foundation
import Testing
import Domain
@testable import Playback
@testable import AppShell

/// T21.4 on the real hidden-player model with a fake page: what a system sleep holds, and what a wake may and may not resume.
@Suite @MainActor struct LifecycleSleepWakeTests {
    private func playing() async throws -> (WebMusicPlayer, FakeMusicPage, LifecycleRig) {
        let rig = try await LifecycleRig.make()
        let (player, page) = try await rig.play()
        return (player, page, rig)
    }
    private func has(_ page: FakeMusicPage, _ body: String) -> Bool { page.bodies.contains(body) }
    private func count(_ page: FakeMusicPage, _ body: String) -> Int { page.bodies.filter { $0 == body }.count }

    @Test func systemSleepPausesThePageWithoutRecordingAPersonsPause() async throws {
        let (player, page, _) = try await playing()
        let before = player.commandRevision
        let hold = try #require(await player.holdForSystemSleep())
        #expect(count(page, WebMusicScripts.pause) == 1, "the page itself is paused, so it cannot start by itself on wake")
        #expect(!player.snapshot.intent && hold.commandRevision == before && player.commandRevision == before, "a person's command was not recorded")
    }
    @Test func aWakeResumesTheSameItemOnlyWhenNoCommandCameInBetween() async throws {
        let (player, page, _) = try await playing()
        let hold = try #require(await player.holdForSystemSleep())
        let resumed = await player.resumeAfterSystemWake(hold)
        #expect(resumed && count(page, WebMusicScripts.play) == 1 && player.snapshot.intent)
    }
    @Test func aPersonsCommandBetweenSleepAndWakeAlwaysWins() async throws {
        let commands: [(String, (WebMusicPlayer) async -> Void)] = [
            ("pause", { await $0.pause() }), ("resume", { await $0.resume() }), ("play pause", { await $0.playPause() }),
            ("next", { await $0.next() }), ("previous", { await $0.previous() }), ("seek", { await $0.seek(30) }),
        ]
        for (name, command) in commands {
            let (player, page, _) = try await playing()
            let hold = try #require(await player.holdForSystemSleep())
            let plays = count(page, WebMusicScripts.play)
            await command(player)
            let resumed = await player.resumeAfterSystemWake(hold)
            #expect(!resumed, "\(name): a user, route or timer pause stands; so does any other person's command")
            #expect(count(page, WebMusicScripts.play) == plays + (name == "resume" || name == "play pause" ? 1 : 0), "\(name): the wake itself sent no extra play")
        }
    }
    @Test func aClosedPlayerOrADifferentItemIsNeverResumed() async throws {
        let (player, page, _) = try await playing()
        let hold = try #require(await player.holdForSystemSleep())
        page.send(lifecycleState(playing: false, video: lifecycleOtherVideo, title: "Another"))
        #expect(!(await player.resumeAfterSystemWake(hold)), "the page moved to a different item")
        let (second, _, _) = try await playing()
        let secondHold = try #require(await second.holdForSystemSleep())
        await second.teardown()
        #expect(!(await second.resumeAfterSystemWake(secondHold)), "account switch, sign-out or quit closed it")
    }
    @Test func nothingPlayingMeansNothingToHold() async throws {
        let (player, page, _) = try await playing()
        await player.pause()
        let pauses = count(page, WebMusicScripts.pause)
        #expect(await player.holdForSystemSleep() == nil)
        #expect(count(page, WebMusicScripts.pause) == pauses, "a paused player is left alone")
        let rig = try await LifecycleRig.make()
        #expect(await rig.model.holdForSleep() == false, "no player at all")
    }
    @Test func anAdvertisementIsHeldAndResumedLikeAnyPlaybackAndNeverSkipped() async throws {
        let (player, page, _) = try await playing()
        page.send(lifecycleState(position: 0, duration: 15, video: lifecycleAdVideo, ad: true))
        #expect(player.snapshot.isAd)
        let hold = try #require(await player.holdForSystemSleep())
        #expect(await player.resumeAfterSystemWake(hold) && count(page, WebMusicScripts.play) == 1, "the ad resumes where the page left it")
        #expect(!page.bodies.contains(WebMusicScripts.skip) && !page.bodies.contains(WebMusicScripts.seek), "an ad is never skipped, sought or sped up around a sleep")
    }
    @Test func aPageThatPlaysAgainstTheIntentIsPausedAgainAndOnlyThen() async throws {
        let (player, page, _) = try await playing()
        _ = try #require(await player.holdForSystemSleep())
        let pauses = count(page, WebMusicScripts.pause)
        page.send(lifecycleState(playing: false))
        await player.silencePageAgainstIntent()
        #expect(count(page, WebMusicScripts.pause) == pauses, "already paused: nothing to say")
        page.send(lifecycleState(playing: true))   // surprise audio
        await player.silencePageAgainstIntent()
        #expect(count(page, WebMusicScripts.pause) == pauses + 1 && !player.snapshot.intent)
        let (wanted, wantedPage, _) = try await playing()
        await wanted.silencePageAgainstIntent()
        #expect(count(wantedPage, WebMusicScripts.pause) == 0, "playing because a person asked: never silenced")
    }
    @Test func everyPersonCommandCountsAndTheSleepHoldDoesNot() async throws {
        let (player, page, _) = try await playing()
        var revision = player.commandRevision
        for command in [{ await player.pause() }, { await player.resume() }, { await player.seek(20) }, { await player.next() }, { await player.previous() }] as [() async -> Void] {
            await command()
            #expect(player.commandRevision > revision); revision = player.commandRevision
        }
        await player.play(playlistID: "PLsyntheticLife", title: nil); #expect(player.commandRevision > revision)
        _ = page
    }

    // MARK: Through the one playback owner

    @Test func theOwnerHoldsAndResumesTheHiddenPlayerThroughTheSameFourCalls() async throws {
        let (_, page, rig) = try await playing()
        #expect(await rig.model.holdForSleep())
        #expect(count(page, WebMusicScripts.pause) == 1)
        let facts = await rig.model.holdFacts()
        #expect(!facts.personChanged && !facts.timerExpired && !facts.ownerChanged)
        #expect(await rig.model.finishWake(resume: true) && count(page, WebMusicScripts.play) == 1)
        #expect(rig.model.sleepHold == nil, "settled")
    }
    @Test func theOwnerReportsAPersonsCommandAnAccountBarrierAndTheNoResumeCase() async throws {
        let (_, page, rig) = try await playing()
        _ = await rig.model.holdForSleep()
        _ = rig.model.remote(.pause); try await Task.sleep(for: .milliseconds(30))
        #expect(await rig.model.holdFacts().personChanged, "the media key is a person's command too")
        #expect(await rig.model.finishWake(resume: true) == false)
        let (_, _, second) = try await playing()
        _ = await second.model.holdForSleep()
        try await second.authority.detach(previous: second.context, barrier: RequestContext(account: nil, accountGeneration: 9, requestGeneration: 0))
        #expect(await second.model.holdFacts().ownerChanged, "an account switch or sign-out ended the owner")
        #expect(await second.model.finishWake(resume: true) == false)
        let (_, third, quiet) = try await playing()
        _ = await quiet.model.holdForSleep()
        #expect(await quiet.model.finishWake(resume: false) == false && count(third, WebMusicScripts.play) == 0, "a wake that does not resume sends no play")
        _ = page
    }
    // F9: the audible part first, then the file write.
    @Test func theSessionIsWrittenOnlyAfterThePageHasBeenPaused() async throws {
        let (_, page, rig) = try await playing()
        var pausedWhenWritten: Bool?
        rig.model.checkpointForSleep = { pausedWhenWritten = page.bodies.contains(WebMusicScripts.pause) }
        #expect(await rig.model.holdForSleep())
        #expect(pausedWhenWritten == true, "the checkpoint ran after the pause, not before it")
        let quiet = try await LifecycleRig.make()
        var ran = false
        quiet.model.checkpointForSleep = { ran = true }
        #expect(await quiet.model.holdForSleep() == false && !ran, "nothing playing: nothing held and nothing written")
    }
    @Test func theWholePathWorksThroughTheCoordinatorAndTheRealOwner() async throws {
        let (_, page, rig) = try await playing()
        let power = PowerLifecycleCoordinator(transport: rig.model, route: FixedRoute(result: true), display: ShellDisplayState(), resumePreference: { true }, sleep: { _ in })
        await power.handle(.screenLocked); await power.handle(.displaySlept)
        #expect(count(page, WebMusicScripts.pause) == 0, "audio continues through a lock and display sleep")
        await power.handle(.systemWillSleep)
        #expect(count(page, WebMusicScripts.pause) == 1)
        await power.handle(.systemDidWake)
        #expect(power.lastDecision == .resume && count(page, WebMusicScripts.play) == 1)
    }
    @Test func noPlaybackStartsByItselfAfterAWakeWhenTheRouteIsNotThere() async throws {
        let (_, page, rig) = try await playing()
        let power = PowerLifecycleCoordinator(transport: rig.model, route: FixedRoute(result: false), display: ShellDisplayState(), resumePreference: { true }, sleep: { _ in })
        await power.handle(.systemWillSleep); await power.handle(.systemDidWake)
        #expect(power.lastDecision == .stayPaused(.routeNotConfirmed) && count(page, WebMusicScripts.play) == 0)
    }
}

/// PLAY17 / WIN08 on a real native session: a sleep timer that ran out while the Mac slept, and a person's pause, prevent a wake resume.
@Suite @MainActor struct LifecycleNativeSessionSleepTests {
    private func rig(wall: ManualWall) async throws -> (PlaybackModel, PlaybackSession) {
        let session = try await ownedSession(wall: wall, clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        let authority = AppPlaybackAuthority(makeMusicPage: { delegate in FakeMusicPage(delegate: delegate) })
        let model = PlaybackModel(authority: authority)
        model.session = session
        return (model, session)
    }
    @Test func aTimerThatExpiredDuringSleepPreventsTheWakeResume() async throws {
        let wall = ManualWall()
        let (model, session) = try await rig(wall: wall)
        try await session.setTimer(.custom(10))
        #expect(await model.holdForSleep(), "it was playing")
        wall.advance(11)
        #expect(await model.holdFacts().timerExpired)
        let resumed = await model.finishWake(resume: false)
        #expect(!resumed)
        #expect(try await session.snapshot().playback.intent != .play, "the timer's pause stands")
        await session.close()
    }
    @Test func aPlayingSessionResumesOnWakeWhenNothingForbidsIt() async throws {
        let wall = ManualWall()
        let (model, session) = try await rig(wall: wall)
        #expect(await model.holdForSleep())
        #expect(try await session.snapshot().playback.intent == .pause(.sleep))
        #expect(await model.holdFacts() == (personChanged: false, timerExpired: false, ownerChanged: false))
        #expect(await model.finishWake(resume: true))
        #expect(try await session.snapshot().playback.intent == .play)
        await session.close()
    }
    @Test func aPersonsPauseAfterTheSleepHoldWinsOverTheWake() async throws {
        let wall = ManualWall()
        let (model, session) = try await rig(wall: wall)
        #expect(await model.holdForSleep())
        try await session.resume(); try await session.pause(.user)
        let facts = await model.holdFacts()
        #expect(facts.personChanged)
        let resumed = await model.finishWake(resume: false)
        let intent = try await session.snapshot().playback.intent
        #expect(!resumed && intent == .pause(.user))
        await session.close()
    }
    @Test func aPausedNativeSessionIsNotHeldAndNeverResumedByAWake() async throws {
        let wall = ManualWall()
        let (model, session) = try await rig(wall: wall)
        try await session.pause(.user)
        #expect(await model.holdForSleep() == false)
        #expect(!(await model.finishWake(resume: true)), "the person's pause before the sleep stands")
        #expect(try await session.snapshot().playback.intent != .play)
        await session.close()
    }
}
