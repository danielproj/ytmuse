import Foundation
import Testing
@testable import Playback
@testable import AppShell

// P17-WEB (PLAY17). The hidden player's sleep timer against a fake page and manual clocks: nothing here reaches WebKit, a real page, the Mac's
// audio or the account holder's stores. The class names start with `WebMusic` so the hidden-player suites (T17, T18, T21) pick them up.

@Suite @MainActor struct WebMusicSleepTimerTests {
    private func names(_ page: FakeMusicPage) -> [String] { timerCommandNames(page) }
    private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

    // MARK: Fade steps and timing

    @Test func aLengthTimerFadesOverFiveSecondsInQuarterSecondStepsThenPausesAndPutsTheLevelBack() async throws {
        let (player, page, timing) = try await sleepTimerPlayer()
        #expect(await player.setSleepTimer(.custom(60)) == .set)
        timing.advance(59); await player.sleepTimerTick()
        #expect(names(page).isEmpty && player.sleepTimerState?.fading == false, "nothing is sent before the deadline")
        timing.advance(1); await player.sleepTimerTick()
        #expect(names(page).isEmpty && player.sleepTimerState?.fading == true, "the fade starts at the deadline, at the level the person had")
        for step in 1...19 {
            timing.advance(0.25); await player.sleepTimerTick()
            #expect(fadeFactors(page).count == step && near(fadeFactors(page).last ?? -1, 1 - Double(step) * 0.05), "step \(step)")
            #expect(!names(page).contains("pause"), "step \(step): the page is not paused before the fade has reached silence")
        }
        timing.advance(0.25); await player.sleepTimerTick()
        let sent = names(page)
        #expect(sent.count == 22, "twenty steps, the pause, the level back: \(sent)")
        #expect(Array(sent.suffix(3)) == ["fade(0.00)", "pause", "fade(1.00)"], "silence, then the existing pause, then the level back for the next play: \(sent)")
        #expect(Set(sent.map { $0.hasPrefix("fade") ? "fade" : $0 }) == ["fade", "pause"], "nothing else is sent: no seek, skip, queue change or volume command")
        #expect(!player.snapshot.intent && player.sleepTimerState == nil && player.sleepTimerHasExpired())
    }
    @Test func theTimersOwnTaskRunsTheWholeFadeInVirtualTime() async throws {
        let (player, page, timing) = try await sleepTimerPlayer(timing: ManualSleepTiming(loop: true))
        #expect(await player.setSleepTimer(.custom(30)) == .set)
        await settleTimer { player.sleepTimerState == nil && page.bodies.contains(WebMusicScripts.pause) }
        #expect(player.sleepTimerState == nil)
        let sent = names(page)
        #expect(Array(sent.suffix(3)) == ["fade(0.00)", "pause", "fade(1.00)"] && fadeFactors(page).count == 21, "\(sent)")
        #expect(timing.seconds >= 34.9 && timing.seconds <= 35.3, "30 seconds, then a 5 second fade (\(timing.seconds))")
        #expect(timing.waits.allSatisfy { $0 > 0 && $0 <= 1 }, "the loop never waits more than a second between looks")
    }
    @Test func theFadeIsPacedByTheMonotonicClockSoAWallClockChangeCannotStretchOrSkipIt() async throws {
        let (player, page, timing) = try await sleepTimerPlayer()
        _ = await player.setSleepTimer(.custom(60))
        timing.advance(60); await player.sleepTimerTick()
        timing.jumpWall(3600); await player.sleepTimerTick()       // an hour on the wall, nothing on the monotonic clock
        #expect(fadeFactors(page).isEmpty, "the fade did not jump")
        timing.advance(0.25); await player.sleepTimerTick()
        #expect(near(fadeFactors(page).first ?? -1, 0.95), "and it did not stall: the next step is the next quarter second")
        timing.jumpWall(-3600); timing.advance(0.25); await player.sleepTimerTick()
        #expect(near(fadeFactors(page).last ?? -1, 0.90))
    }
    @Test func presetsAreFiveFifteenThirtyAndSixtyMinutesAndACustomLengthIsAnyLengthUpToADay() async throws {
        let (player, _, timing) = try await sleepTimerPlayer()
        for minutes in [5, 15, 30, 60] {
            #expect(await player.setSleepTimer(.minutes(minutes)) == .set)
            #expect(near(player.sleepTimerState?.remaining(at: timing.wall()) ?? -1, Double(minutes) * 60, 0.01))
        }
        #expect(await player.setSleepTimer(.custom(7 * 60)) == .set && near(player.sleepTimerState?.remaining(at: timing.wall()) ?? -1, 420, 0.01))
        for bad in [0.0, -5, .nan, .infinity, 86_401] {
            #expect(await player.setSleepTimer(.custom(bad)) == .refused(.invalidLength), "\(bad)")
        }
        #expect(player.sleepTimerState?.remaining(at: timing.wall()) != nil, "a refused length leaves the running timer as it was")
    }

    // MARK: Advertisements

    @Test func anAdvertisementAtExpiryIsNeverFadedTheTimerOnlyPauses() async throws {
        let (player, page, timing) = try await sleepTimerPlayer(ad: true)
        #expect(player.snapshot.isAd)
        _ = await player.setSleepTimer(.minutes(5))
        timing.advance(300); await player.sleepTimerTick()
        #expect(names(page) == ["pause"], "pause only: no fade step, no level change: \(names(page))")
        #expect(fadeFactors(page).isEmpty && player.sleepTimerState == nil && !player.snapshot.intent)
    }
    @Test func anAdvertisementThatStartsDuringTheFadePutsTheLevelBackAndOnlyPauses() async throws {
        let (player, page, timing) = try await sleepTimerPlayer()
        _ = await player.setSleepTimer(.custom(60))
        timing.advance(60); await player.sleepTimerTick()
        for _ in 0..<3 { timing.advance(0.25); await player.sleepTimerTick() }
        #expect(fadeFactors(page).count == 3 && (fadeFactors(page).last ?? 1) < 1)
        reportPosition(page, 12, ad: true)                       // an ad is stitched in mid-fade
        timing.advance(0.25); await player.sleepTimerTick()
        let sent = names(page)
        #expect(Array(sent.suffix(2)) == ["fade(1.00)", "pause"], "the level is put back before the ad can be heard at a lowered level, then it pauses: \(sent)")
        #expect(fadeFactors(page).dropFirst(3).allSatisfy { $0 == 1 }, "no step below full level was sent after the ad appeared")
        #expect(player.sleepTimerState == nil)
    }
    @Test func anAdvertisementTheNativeSideHasNotSeenYetIsStoppedByThePagesOwnAnswer() async throws {
        let (player, page, timing) = try await sleepTimerPlayer()
        page.intercept = { $0.body == WebMusicScripts.fadeVolume && (($0.arguments["factor"] as? Double) ?? 1) < 1 ? .ad : nil }
        _ = await player.setSleepTimer(.custom(60))
        timing.advance(60); await player.sleepTimerTick()
        timing.advance(0.25); await player.sleepTimerTick()
        #expect(names(page) == ["fade(0.95)", "pause"], "the page said an ad shows: it kept the level, so nothing is restored, and the timer only pauses: \(names(page))")
        #expect(player.sleepTimerState == nil)
    }
    @Test func aPageThatCannotFadeIsPausedWithoutPretendingToFade() async throws {
        for refusal in [WebMusicCommandReply.rejected, .noMedia, .unavailable] {
            let (player, page, timing) = try await sleepTimerPlayer()
            page.intercept = { $0.body == WebMusicScripts.fadeVolume ? refusal : nil }
            _ = await player.setSleepTimer(.custom(60))
            timing.advance(60); await player.sleepTimerTick()
            timing.advance(0.25); await player.sleepTimerTick()
            #expect(names(page) == ["fade(0.95)", "pause"], "\(refusal): \(names(page))")
            #expect(player.sleepTimerState == nil)
        }
    }

    // MARK: Volume restore and who is in charge

    @Test func cancellingDuringAFadePutsTheLevelBackAndDoesNotPause() async throws {
        let (player, page, timing) = try await sleepTimerPlayer()
        _ = await player.setSleepTimer(.custom(60))
        timing.advance(60); await player.sleepTimerTick()
        timing.advance(1); await player.sleepTimerTick()
        #expect(await player.setSleepTimer(nil) == .cleared)
        #expect(names(page).last == "fade(1.00)" && !names(page).contains("pause") && player.snapshot.intent && player.sleepTimerState == nil)
        #expect(!player.sleepTimerHasExpired(), "a cancelled timer expired nothing")
        let before = names(page).count
        await player.sleepTimerTick()
        #expect(names(page).count == before, "and nothing runs after it")
    }
    @Test func cancellingATimerThatNeverFadedSendsNothing() async throws {
        let (player, page, _) = try await sleepTimerPlayer()
        _ = await player.setSleepTimer(.minutes(5))
        #expect(await player.setSleepTimer(nil) == .cleared && names(page).isEmpty)
    }
    @Test func replacingATimerKeepsExactlyOneAndAFadeInProgressIsRestoredFirst() async throws {
        let (player, page, timing) = try await sleepTimerPlayer()
        _ = await player.setSleepTimer(.custom(60))
        timing.advance(60); await player.sleepTimerTick(); timing.advance(1); await player.sleepTimerTick()
        #expect(await player.setSleepTimer(.minutes(15)) == .set)
        #expect(names(page).last == "fade(1.00)", "the lowered level went back before the new timer started")
        #expect(player.sleepTimerState?.fading == false && near(player.sleepTimerState?.remaining(at: timing.wall()) ?? -1, 900, 0.01))
    }
    @Test func aPersonsCommandDuringTheFadeEndsTheTimerAndPutsTheLevelBack() async throws {
        let commands: [(String, (WebMusicPlayer) async -> Void)] = [
            ("pause", { await $0.pause() }), ("seek", { await $0.seek(30) }), ("next", { await $0.next() }),
            ("play another", { await $0.play(playlistID: "PLsyntheticOther", title: nil) }),
        ]
        for (name, command) in commands {
            let (player, page, timing) = try await sleepTimerPlayer()
            page.intercept = { $0.body == WebMusicScripts.loadPlaylist ? .router : nil }     // the page's own router takes the new playlist: the same document
            _ = await player.setSleepTimer(.custom(60))
            timing.advance(60); await player.sleepTimerTick()
            timing.advance(1); await player.sleepTimerTick()
            await command(player)
            timing.advance(0.25); await player.sleepTimerTick()
            #expect(player.sleepTimerState == nil, "\(name): a person took over, so the timer is over")
            #expect(names(page).last == "fade(1.00)", "\(name): and the level they had is back: \(names(page))")
            #expect(!player.sleepTimerHasExpired(), "\(name): a person's command is not the timer expiring")
        }
    }
    @Test func aNewDocumentDuringTheFadeIsNeverSentTheOldDocumentsRestore() async throws {
        let (player, page, timing) = try await sleepTimerPlayer()
        _ = await player.setSleepTimer(.custom(60))
        timing.advance(60); await player.sleepTimerTick(); timing.advance(1); await player.sleepTimerTick()
        let sent = page.commands.count
        page.delegate?.pageCommitted(document: nil)          // the page replaced its own document
        timing.advance(0.25); await player.sleepTimerTick()
        #expect(page.commands.count == sent && player.sleepTimerState == nil, "a document that was never faded is not touched")
    }
    @Test func aPlayerThatIsNotPlayingWhenTheTimerRunsOutIsLeftAlone() async throws {
        let (player, page, timing) = try await sleepTimerPlayer()
        _ = await player.setSleepTimer(.minutes(5))
        await player.pause()
        reportPosition(page, 11, playing: false)
        timing.advance(300); await player.sleepTimerTick()
        #expect(names(page) == ["pause"], "only the person's own pause: the timer sent nothing (\(names(page)))")
        #expect(player.sleepTimerState == nil)
    }

    // MARK: End of track / end of episode

    @Test func endOfItemFadesTheLastFiveSecondsOfThePagesReportedDurationThenPausesAtTheBoundary() async throws {
        let (player, page, timing) = try await sleepTimerPlayer(position: 150, duration: 200)
        #expect(await player.setSleepTimer(.endOfItem) == .set && player.sleepTimerState?.endOfItem == true && player.sleepTimerState?.deadline == nil)
        reportPosition(page, 190)
        timing.advance(1); await player.sleepTimerTick()
        #expect(names(page).isEmpty && player.sleepTimerState?.fading == false, "ten seconds from the end: nothing yet, and the timer does not claim to be fading")
        reportPosition(page, 196)
        await player.sleepTimerTick()
        #expect(near(fadeFactors(page).last ?? -1, (4 - 0.3) / (5 - 0.3)), "four seconds left: inside the five second window, shaped to reach silence at the boundary")
        timing.advance(1); await player.sleepTimerTick()           // no new report: the position is carried forward at the element's speed
        #expect(near(fadeFactors(page).last ?? -1, (3 - 0.3) / (5 - 0.3)))
        timing.advance(2.5); await player.sleepTimerTick()
        #expect(near(fadeFactors(page).last ?? -1, (0.5 - 0.3) / (5 - 0.3)) && !names(page).contains("pause"))
        timing.advance(0.25); await player.sleepTimerTick()
        #expect(Array(names(page).suffix(3)) == ["fade(0.00)", "pause", "fade(1.00)"], "\(names(page))")
        #expect(player.sleepTimerState == nil && player.sleepTimerHasExpired() && !player.snapshot.intent)
        #expect(!names(page).contains("skip") && !names(page).contains("seek"), "the queue was not touched")
    }
    @Test func endOfItemWithNoReportedLengthHasNoBoundaryAndInventsNone() async throws {
        let (player, page, timing) = try await sleepTimerPlayer(position: 0, duration: 0)
        #expect(await player.setSleepTimer(.endOfItem) == .set)
        for position in [10.0, 500, 5000] { reportPosition(page, position, duration: 0); timing.advance(60); await player.sleepTimerTick() }
        #expect(names(page).isEmpty && player.sleepTimerState != nil, "without a duration from the page the timer waits")
    }
    @Test func endOfItemIsRefusedForALiveStreamAndNeedsSomethingLoaded() async throws {
        let (player, page, _) = try await sleepTimerPlayer()
        page.send(systemMediaLiveBody())
        #expect(player.snapshot.isLive)
        #expect(await player.setSleepTimer(.endOfItem) == .refused(.noEnd))
        #expect(await player.setSleepTimer(.minutes(5)) == .set, "a length still works on a live stream")
        let idle = WebMusicPlayer(cookies: FakeCookieSource(), artwork: NoArtwork(), sleepTiming: ManualSleepTiming()) { FakeMusicPage(delegate: $0) }
        let first = await idle.setSleepTimer(.minutes(5)), second = await idle.setSleepTimer(.endOfItem)
        #expect(first == .refused(.nothingPlaying) && second == .refused(.nothingPlaying))
    }
    @Test func thePagesEndedReportPausesAtOnceAndSendsNoFade() async throws {
        let (player, page, _) = try await sleepTimerPlayer(position: 150, duration: 200)
        _ = await player.setSleepTimer(.endOfItem)
        page.send(["type": "ended", "doc": 1, "load": 1, "videoId": lifecycleVideo])
        await settleTimer { player.sleepTimerState == nil }
        #expect(names(page) == ["pause"] && player.sleepTimerHasExpired(), "\(names(page))")
    }
    @Test func seekingBackDuringTheLastSecondsEndsTheFadeButKeepsTheTimerForTheNewEnd() async throws {
        let (player, page, timing) = try await sleepTimerPlayer(position: 150, duration: 200)
        _ = await player.setSleepTimer(.endOfItem)
        reportPosition(page, 197); await player.sleepTimerTick()
        #expect(player.sleepTimerState?.fading == true)
        await player.seek(20)
        reportPosition(page, 20)
        timing.advance(0.25); await player.sleepTimerTick()
        #expect(names(page).last == "fade(1.00)" && player.sleepTimerState?.endOfItem == true && player.sleepTimerState?.fading == false, "\(names(page))")
        #expect(!names(page).contains("pause"))
        reportPosition(page, 197); await player.sleepTimerTick()
        #expect(player.sleepTimerState?.fading == true, "and it fades again when the item really nears its end")
    }
    @Test func aPageThatMovedOnWithoutTheBoundaryBeingCaughtIsPausedQuietly() async throws {
        let (player, page, timing) = try await sleepTimerPlayer(position: 150, duration: 200)
        _ = await player.setSleepTimer(.endOfItem)
        reportPosition(page, 197); await player.sleepTimerTick()
        #expect(player.sleepTimerState?.fading == true)
        reportPosition(page, 0.2, video: lifecycleOtherVideo)      // the next item, started by YouTube before our pause landed
        timing.advance(0.25); await player.sleepTimerTick()
        #expect(Array(names(page).suffix(2)) == ["pause", "fade(1.00)"] && player.sleepTimerState == nil, "\(names(page))")
    }
    @Test func anAdvertisementBeforeTheBoundaryIsWaitedOutNotFadedAndNotCountedAsTheItem() async throws {
        let (player, page, timing) = try await sleepTimerPlayer(position: 150, duration: 200)
        _ = await player.setSleepTimer(.endOfItem)
        reportPosition(page, 0, duration: 15, video: lifecycleAdVideo, ad: true)
        timing.advance(30); await player.sleepTimerTick()
        #expect(names(page).isEmpty && player.sleepTimerState != nil, "an ad's own length is not the item's end")
    }

    // MARK: After the pause

    @Test func aPageThatStartsPlayingAgainByItselfIsPausedAgainAtMostThreeTimes() async throws {
        let (player, page, timing) = try await sleepTimerPlayer()
        _ = await player.setSleepTimer(.minutes(5))
        timing.advance(300); await player.sleepTimerTick(); timing.advance(5); await player.sleepTimerTick()
        let pauses = { page.bodies.filter { $0 == WebMusicScripts.pause }.count }
        let first = pauses()
        for tick in 0..<6 { reportPosition(page, 20 + Double(tick), playing: true); for _ in 0..<5 { await Task.yield() } }
        #expect(pauses() == first + 3, "the page must not resume by itself, and the guard is bounded: \(pauses() - first) more pauses")
    }
    @Test func aPersonsPlayEndsTheTimersHoldAndTheTimersPauseNoLongerStands() async throws {
        let (player, page, timing) = try await sleepTimerPlayer()
        _ = await player.setSleepTimer(.minutes(5))
        timing.advance(300); await player.sleepTimerTick(); timing.advance(5); await player.sleepTimerTick()
        #expect(player.sleepTimerHasExpired())
        await player.resume()
        #expect(!player.sleepTimerHasExpired() && player.snapshot.intent)
        let pauses = page.bodies.filter { $0 == WebMusicScripts.pause }.count
        reportPosition(page, 40, playing: true); for _ in 0..<10 { await Task.yield() }
        #expect(page.bodies.filter { $0 == WebMusicScripts.pause }.count == pauses, "the person asked for this sound")
    }
    @Test func teardownCancelsTheTimerAndSendsTheDroppedPageNothing() async throws {
        let (player, page, timing) = try await sleepTimerPlayer(timing: ManualSleepTiming(loop: true))
        _ = await player.setSleepTimer(.minutes(5))
        await player.teardown()
        let sent = page.commands.count
        timing.advance(1000); await player.sleepTimerTick()
        await settleTimer { false }
        #expect(player.sleepTimerState == nil && page.commands.count == sent && !player.sleepTimerHasExpired())
        #expect(await player.setSleepTimer(.minutes(5)) == .refused(.nothingPlaying), "a closed player takes no timer")
    }
}
