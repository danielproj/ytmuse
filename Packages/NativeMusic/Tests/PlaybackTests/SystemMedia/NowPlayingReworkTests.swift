import AppKit
import Domain
import Foundation
import MediaPlayer
import OutputRoutes
import Synchronization
import Testing
@testable import Features
@testable import Playback
@testable import SystemIntegration
@testable import AppShell
import TestSupport

/// W23 rework 1 (critic W23-opus-01). Each test here fails on the code that was reviewed; `artifacts/harness/nodes/W23/mutation` re-plants the old
/// behaviour to prove it.

/// Findings 1 and 2: the native (owned and kept media) path obeys the same owner rules as the hidden player.
@Suite @MainActor struct NativeNowPlayingReworkTests {
    private func rigWithOneOwnedItem(grace: Duration = .milliseconds(80)) async throws -> (MediaRig, PlaybackSession) {
        let rig = try await MediaRig.make()
        rig.model.endedGrace = grace
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia([OwnedMedia.items[0]])
        rig.model.session = session
        await rig.model.refresh()
        await rig.wait { rig.info.state == .playing }       // `refresh()` is not a synchronisation point: the session's own events drive one too
        return (rig, session)
    }

    @Test func aNativeQueueThatRanOutSaysStoppedAtOnceAndLetsGoAfterTheSameGraceAsTheWebPlayer() async throws {
        let (rig, session) = try await rigWithOneOwnedItem()
        #expect(rig.model.nowPlaying.isActive && rig.info.state == .playing && rig.info.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        let state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .ended))
        await rig.model.refresh()
        let finished = try await session.snapshot()
        #expect(finished.queue.current == nil || finished.playback.state == .ended, "the one item finished: \(finished.playback.state)")
        // The session's own event also drives a refresh now (coalesced with this one), so the stopped state may land a moment after this call returns.
        await rig.wait { rig.info.state != .playing }
        #expect(rig.info.writes.contains { $0.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0 && $0.state != .playing }, "never 'playing at rate 1' past the end")
        await rig.wait { !rig.model.nowPlaying.isActive }
        #expect(!rig.model.nowPlaying.isActive && rig.commands.registrationCount == 0 && rig.info.info == nil, "after the grace the keys are free")
        await rig.model.refresh()
        await rig.model.refresh()
        #expect(!rig.model.nowPlaying.isActive && rig.commands.attachCount == 1, "and the refresh loop does not take them back")
        await session.close()
    }
    @Test func aNativeItemThatStartsAgainWithinTheGraceKeepsTheKeys() async throws {
        // "In time" is true by construction: the grace is far longer than any start of owned audio, the test waits (up to 8 s) until the next item is
        // PUBLISHED and playing, and only then waits out the rest of the grace, measured from the end event.
        let grace = Duration.seconds(3)
        let (rig, session) = try await rigWithOneOwnedItem(grace: grace)
        let state = try await session.snapshot()
        let ended = ContinuousClock.now
        await session.receive(.init(context: state.playback.context, event: .ended))
        await rig.model.refresh()
        try await session.startOwnedMedia([OwnedMedia.items[1]])
        await rig.wait(seconds: 8) { rig.model.nowPlaying.current?.itemID == OwnedMedia.items[1].rawValue && rig.info.state == .playing }
        #expect(ContinuousClock.now - ended < grace, "the next item was published inside the grace (a start slower than that is a different test)")
        let remaining = ended.advanced(by: grace + .milliseconds(400)) - ContinuousClock.now
        if remaining > .zero { try await Task.sleep(for: remaining) }
        let now = try await session.snapshot()
        #expect(rig.model.nowPlaying.isActive && rig.info.info != nil && rig.commands.attachCount == 1, "the next item kept the keys: \(now.playback.state) \(String(describing: now.queue.current?.media))")
        await session.close()
    }

    @Test func aSessionAfterAnAccountSwitchPublishesAndTakesTheKeysEvenIfItReusesTheOldOnesAddress() async throws {
        let rig = try await MediaRig.make()
        for round in 0..<6 {
            var session: PlaybackSession? = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
            try await session?.startOwnedMedia(OwnedMedia.items)
            rig.model.session = session
            await rig.model.refresh()
            await rig.wait { rig.model.nowPlaying.isActive && rig.info.info != nil }
            #expect(rig.model.nowPlaying.isActive && rig.info.info != nil, "round \(round): a new session takes the keys")
            try await rig.detach()                                        // the account switch
            await rig.wait { !rig.model.nowPlaying.isActive }
            #expect(!rig.model.nowPlaying.isActive && rig.info.info == nil, "round \(round): and the barrier let go")
            await session?.close()
            rig.model.session = nil
            await rig.model.refresh()
            session = nil                                                // freed: the next allocation may land on the same address
        }
        #expect(rig.commands.attachCount == 6, "every round attached once")
    }
}

/// Finding 3: a finished item must not take the keys back.
@Suite @MainActor struct FinishedItemNowPlayingTests {
    @Test func aDeviceChangeAfterTheGraceDoesNotTakeTheKeysBackForAFinishedSong() async throws {
        let rig = try await MediaRig.make(outputs: true)
        rig.model.endedGrace = .milliseconds(60)
        let (_, page) = try await rig.play()
        page.send(["type": "ended", "doc": 1, "load": 1, "videoId": lifecycleVideo])
        await rig.wait { !rig.model.nowPlaying.isActive }
        #expect(!rig.model.nowPlaying.isActive && rig.commands.attachCount == 1)
        rig.directory?.change([routeSpeakers], defaultUID: routeSpeakers.uid)       // headphones out, an output change
        try await Task.sleep(for: .milliseconds(150))
        rig.model.routeChangedForNowPlaying()
        #expect(!rig.model.nowPlaying.isActive && rig.commands.attachCount == 1 && rig.info.info == nil, "a finished item cannot re-register for another ten seconds")
        page.send(lifecycleState(position: 0, video: lifecycleOtherVideo, title: "A New Song"))
        #expect(rig.model.nowPlaying.isActive && rig.commands.attachCount == 2, "a new item can")
    }
}

/// The remaining review items: the Play-here gate for the media-key Play, the native capability/handler agreement, artwork, the Like state, rewrites,
/// the shared stand-in for the UI run.
@Suite @MainActor struct RemoteReworkTests {
    private func sample(_ kind: RemoteCommandKind) -> RemoteTransportCommand {
        switch kind {
        case .play: .play
        case .pause: .pause
        case .toggle: .toggle
        case .next: .next
        case .previous: .previous
        case .seek: .seek(3)
        case .skipForward: .skip(30)
        case .skipBackward: .skip(-15)
        case .changeRate: .rate(1.5)
        case .like: .setLike(true)
        case .dislike: .setDislike(true)
        case .save: .setSave(true)
        }
    }

    // MARK: after a route loss, a media key plays on this Mac without a prompt

    @Test func aMediaKeyAfterALossPlaysAtOnceOnTheHiddenPlayer() async throws {
        for command in [RemoteTransportCommand.play, .next, .previous] {
            let rig = try await MediaRig.make(outputs: true)
            let (player, page) = try await rig.play(state: lifecycleState(position: 1))
            rig.directory?.change([routeSpeakers], defaultUID: routeSpeakers.uid)
            await rig.controller?.coordinator.settled()
            let before = page.bodies.filter { $0 == WebMusicScripts.play || $0 == WebMusicScripts.skip }.count
            #expect(rig.model.remote(command) == .success, "\(command) is admitted")
            await rig.wait { page.bodies.filter { $0 == WebMusicScripts.play || $0 == WebMusicScripts.skip }.count > before }
            #expect(page.bodies.filter { $0 == WebMusicScripts.play || $0 == WebMusicScripts.skip }.count > before, "\(command): sent to the player")
            #expect(rig.controller?.coordinator.prompt == nil && player.snapshot.intent, "\(command): no prompt")
        }
    }
    @Test func aMediaKeyPlayOnTheNativeSessionAfterALossResumesAtOnce() async throws {
        let rig = try await MediaRig.make(outputs: true)
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.rigSetNative(session)
        await rig.model.refresh()
        await rig.wait { rig.model.nowPlaying.isActive }
        rig.directory?.change([routeSpeakers], defaultUID: routeSpeakers.uid)
        await rig.controller?.coordinator.settled()
        await rig.model.refresh()
        #expect(try await session.snapshot().playback.intent == .pause(.routeLoss), "the loss paused it")
        #expect(rig.model.remote(.play) == .success)
        var intent = try await session.snapshot().playback.intent
        for _ in 0..<60 where intent != .play { try await Task.sleep(for: .milliseconds(50)); intent = try await session.snapshot().playback.intent }
        #expect(intent == .play && rig.controller?.coordinator.prompt == nil, "native Play resumes without a prompt")
        await session.close()
    }

    // MARK: native: enabled in the system means performed

    @Test func nativeCommandsOnInTheSystemAreNeverRefusedAndOffOnesAlwaysAre() async throws {
        let rig = try await MediaRig.make()
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.rigSetNative(session)
        await rig.model.refresh()
        await rig.wait { rig.model.nowPlaying.isActive && rig.commands.enabled == rig.model.remoteCapabilities().enabled }
        for seekable in [true, false] {
            if !seekable { rig.model.timeline.snapshot = nil }       // nothing is known about the item's length: no seek
            let capabilities = rig.model.remoteCapabilities()
            #expect(capabilities.enabled.contains(.seek) == (rig.model.timeline.snapshot?.media?.userSeekable == true), "seek is on exactly when the item can be sought (\(seekable))")
            #expect(rig.commands.enabled == capabilities.enabled || !seekable, "the system was told what the owner computed")
            for kind in RemoteCommandKind.allCases {
                let outcome = rig.model.remote(sample(kind))
                if capabilities.enabled.contains(kind) { #expect(outcome != .refused, "native \(kind): on, so never refused") }
                else {
                    #expect(outcome == .refused && !(capabilities.reasons[kind] ?? "").isEmpty, "native \(kind): off, so refused and says why")
                }
            }
        }
        let owned = rig.model.remoteCapabilities()
        #expect(!owned.enabled.contains(.like) && !owned.enabled.contains(.dislike) && !owned.enabled.contains(.save), "owned media has no library path")
        await session.close()
    }

    // MARK: artwork

    @Test func pictureDataThatCannotBeDecodedClearsThePreviousPicture() throws {
        let system = NowPlayingSystem.recording()
        let center = NowPlayingCenter(system: system.system)
        #expect(center.activate { _ in .success })
        func item(_ id: String, art: Data?) -> NowPlayingItem {
            NowPlayingItem(title: id, artist: nil, album: nil, artwork: art, duration: 100, elapsed: 0, playing: true, advertisement: false, itemID: id)
        }
        center.update(item("A", art: systemMediaPNG()))
        #expect(system.info.info?[MPMediaItemPropertyArtwork] != nil)
        center.update(item("B", art: Data([0, 1, 2, 3])))
        #expect(system.info.info?[MPMediaItemPropertyArtwork] == nil && center.artworkObject == nil, "B has no picture of its own, and must not show A's")
    }

    // MARK: Like: a state, not a toggle

    @Test func theSystemsLikeAsksForAStateAndAPressAgainstAStaleButtonCannotInvertIt() async throws {
        #expect(RemoteEventMapping.command(.like, .feedback(negative: false)) == .setLike(true))
        #expect(RemoteEventMapping.command(.like, .feedback(negative: true)) == .setLike(false))
        #expect(RemoteEventMapping.command(.save, .feedback(negative: true)) == .setSave(false) && RemoteEventMapping.command(.dislike, .feedback(negative: false)) == .setDislike(true))
        let rig = try await MediaRig.make()
        try await rig.play()
        rig.library.states = [.like: .available(FakeRemoteLibrary.control(.like, on: true))]
        // The system's button was stale (it showed off) and asks for ON; the ledger is already on: nothing is pressed.
        #expect(rig.model.remote(.setLike(true)) == .success)
        try await Task.sleep(for: .milliseconds(40))
        #expect(rig.library.pressed.isEmpty, "already liked: a like request presses nothing (a toggle would have un-liked it)")
        #expect(rig.model.remote(.setLike(false)) == .success)
        await rig.wait { rig.library.pressed.count == 1 }
        #expect(rig.library.pressed.count == 1, "a request to remove the like presses once")
        rig.library.states = [.like: .available(FakeRemoteLibrary.control(.like, on: false))]
        #expect(rig.model.remote(.setLike(false)) == .success)
        try await Task.sleep(for: .milliseconds(40))
        #expect(rig.library.pressed.count == 1, "already off: nothing pressed")
    }
    @Test func aLikeMadeInAnotherSurfaceUpdatesTheSystemsLikeButton() async throws {
        let rig = try await MediaRig.make()
        let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(),
                                     preferences: InMemoryDefaults(), installsStatusItem: false)
        var liked = false
        shell.libraryControlsProvider = { _ in [FakeRemoteLibrary.control(.like, on: liked)] }
        shell.likePress = { _ in liked = true }
        try await rig.play()
        #expect(!rig.model.nowPlaying.currentCapabilities.active.contains(.like))
        guard case .available(let control) = shell.remoteLibraryControl(.like) else { Issue.record("like is offered"); return }
        await shell.pressLike(control)                                 // the mini-player's own path
        #expect(rig.model.nowPlaying.currentCapabilities.active.contains(.like), "the system's button shows the like the mini-player made")
    }

    // MARK: rewrites

    @Test func aLiveStreamAndAnAdvertisementAreNotRewrittenForAMovingPosition() async throws {
        let rig = try await MediaRig.make()
        let (_, page) = try await rig.play(state: lifecycleState(position: 100, duration: 0))
        page.send(systemMediaLiveBody())
        var writes = rig.info.writes.count
        for step in 1...12 { page.send(lifecycleState(position: 100 + Double(step) * 10, duration: 0)) }
        #expect(rig.info.writes.count == writes, "a live stream publishes no clock, so a moving position is not a change: \(rig.info.writes.count - writes) rewrites")
        page.send(lifecycleState(position: 1, duration: 15, video: lifecycleAdVideo, ad: true))
        writes = rig.info.writes.count
        for step in 1...12 { page.send(lifecycleState(position: 1 + Double(step) * 5, duration: 90, video: lifecycleAdVideo, ad: true)) }
        #expect(rig.info.writes.count == writes, "nor is an advertisement's: \(rig.info.writes.count - writes) rewrites")
        // A song still follows a real jump.
        let song = try await MediaRig.make()
        let (_, songPage) = try await song.play(state: lifecycleState(position: 10))
        writes = song.info.writes.count
        songPage.send(lifecycleState(position: 150))
        #expect(song.info.writes.count > writes, "a seek in a song is still published")
    }

    // MARK: the Debug census the UI run reads (finding 12)

    @Test func theCensusPrintsAReadableStateNameAndTheItemShownNeverARawNumber() async throws {
        #expect(NowPlayingMapping.stateName(.playing) == "playing" && NowPlayingMapping.stateName(.paused) == "paused" && NowPlayingMapping.stateName(.stopped) == "stopped")
        let rig = try await LifecycleRig.make()               // the default model: its own recording stand-in, which the census reads
        let (_, page) = try await rig.play()
        var census = rig.model.nowPlayingCensus
        #expect(census.contains("owner=1") && census.contains("registrations=12") && census.contains("attaches=1") && census.contains("refused=0"), Comment(rawValue: census))
        #expect(census.contains("state=playing") && census.hasSuffix("title=Synthetic Song"), Comment(rawValue: census))
        page.send(lifecycleState(playing: false, position: 20))
        census = rig.model.nowPlayingCensus
        #expect(census.contains("state=paused") && !census.contains("state=1") && !census.contains("state=2"), Comment(rawValue: census))
        page.send(lifecycleState(position: 21, video: lifecycleOtherVideo, title: "Another Song"))
        #expect(rig.model.nowPlayingCensus.hasSuffix("title=Another Song"), "the census follows the item, whichever it is")
    }

    // MARK: the UI run's stand-in

    @Test func anIsolatedLaunchSharesOneRecorderSoASecondOwnerShowsAndATestProcessKeepsItsOwn() async throws {
        let first = try #require(PlaybackModel.recorder(isolatedLaunch: true, testHarness: false))
        let second = try #require(PlaybackModel.recorder(isolatedLaunch: true, testHarness: false))
        #expect(first === second, "every model in the isolated app process writes to the one stand-in")
        #expect(PlaybackModel.recorder(isolatedLaunch: false, testHarness: false) == nil, "a normal launch uses the real centres")
        let a = try #require(PlaybackModel.recorder(isolatedLaunch: true, testHarness: true)), b = try #require(PlaybackModel.recorder(isolatedLaunch: true, testHarness: true))
        #expect(a !== b && a !== first, "a unit-test process gets one per model, so parallel suites cannot collide")
        // And on a shared stand-in a second model's owner is refused, which the census would show as refused=1.
        let shared = NowPlayingSystem.recording()
        let owner = NowPlayingCenter(system: shared.system), intruder = NowPlayingCenter(system: shared.system)
        #expect(owner.activate { _ in .success } && !intruder.activate { _ in .success } && shared.commands.refusedOwners == 1)
    }
}

extension MediaRig {
    /// A native session joined to the model the way the playback owner does it.
    func rigSetNative(_ session: PlaybackSession) { model.session = session }
}

/// R2-1: the native session keeps Now Playing right on its OWN events, with no window, popover or mini-player open (a normal mode since W21). The session
/// is started the way the app does it (set on the model, one refresh), nothing observes, and the test makes NO further refresh call.
@Suite @MainActor struct NativeNoWindowNowPlayingTests {
    private func startedWithNoWindow(_ items: [ServiceID], grace: Duration = .milliseconds(120)) async throws -> (MediaRig, PlaybackSession) {
        let rig = try await MediaRig.make()
        rig.model.endedGrace = grace
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(items)
        rig.model.session = session
        await rig.model.refresh()                                   // the one refresh the app's own start makes
        await rig.wait { rig.info.state == .playing }               // it is not a synchronisation point: the session's own start events drive one too
        #expect(!rig.model.isObservingUI, "no window is watching")
        return (rig, session)
    }

    @Test func aSingleItemThatEndsIsPublishedStoppedAndTheKeysAreReleasedWithNoWindow() async throws {
        let (rig, session) = try await startedWithNoWindow([OwnedMedia.items[0]])
        #expect(rig.info.state == .playing && rig.model.nowPlaying.isActive)
        let state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .ended))      // and no refresh from here on
        await rig.wait { !rig.model.nowPlaying.isActive }
        #expect(!rig.model.nowPlaying.isActive && rig.commands.registrationCount == 0 && rig.info.info == nil, "the keys were released by the model on its own")
        let stopped = rig.info.writes.contains { $0.info != nil && $0.state != .playing && $0.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0 }
        #expect(stopped, "and Now Playing said stopped (rate 0) before it let go, never 'playing at rate 1'")
        await session.close()
    }
    @Test func aQueueThatAdvancesPublishesTheSecondItemWithNoWindow() async throws {
        let (rig, session) = try await startedWithNoWindow(OwnedMedia.items)
        #expect(rig.model.nowPlaying.current?.itemID == OwnedMedia.items[0].rawValue)
        let state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .ended))
        await rig.wait(seconds: 5) { rig.model.nowPlaying.current?.itemID == OwnedMedia.items[1].rawValue && rig.info.state == .playing }
        #expect(rig.model.nowPlaying.current?.itemID == OwnedMedia.items[1].rawValue, "the second item is what Now Playing shows, not the first")
        #expect(rig.model.nowPlaying.isActive && rig.info.state == .playing, "and it plays: both are waited for, they are separate publications")
        await session.close()
    }
    // MARK: R3-1: every state change the SESSION makes itself reaches Now Playing, with no window open

    private func startedWithClocks(_ items: [ServiceID] = OwnedMedia.items) async throws -> (MediaRig, PlaybackSession, ManualWall, ManualMonotonic) {
        let rig = try await MediaRig.make()
        let wall = ManualWall(), clock = ManualMonotonic()
        let session = try await ownedSession(wall: wall, clock: clock)
        try await session.startOwnedMedia(items)
        rig.model.session = session
        await rig.model.refresh()
        await rig.wait { rig.info.state == .playing }
        #expect(!rig.model.isObservingUI && rig.info.state == .playing)
        return (rig, session, wall, clock)
    }

    @Test func aSleepTimerThatRunsOutIsPublishedPausedWithNoWindow() async throws {
        let (rig, session, wall, clock) = try await startedWithClocks()
        try await session.setTimer(.minutes(1))
        wall.advance(120); await session.tick()                       // the deadline passed: the fade starts
        clock.advance(to: .seconds(6)); await session.tick()          // the fade ended: the session pauses itself
        #expect(try await session.snapshot().playback.intent != .play, "the session paused itself")
        await rig.wait { rig.info.state == .paused }                  // and NO refresh call from here
        #expect(rig.info.state == .paused && rig.info.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0, "Now Playing says paused, not 'playing at rate 1'")
        await session.close()
    }
    @Test func aPauseMadeOnTheSessionItselfIsPublishedWithNoWindow() async throws {
        let (rig, session, _, _) = try await startedWithClocks()
        try await session.pause()
        await rig.wait { rig.info.state == .paused }
        #expect(rig.info.state == .paused && rig.info.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        try await session.resume()
        await rig.wait { rig.info.state == .playing }
        #expect(rig.info.state == .playing, "and so is the resume")
        await session.close()
    }
    @Test func anEngineEventThatMovesTheStateAloneIsPublishedWithNoWindow() async throws {
        let (rig, session, _, _) = try await startedWithClocks()
        let state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .buffering))      // no operation runs: only the event reaches the session
        await rig.wait { rig.info.state != .playing }
        #expect(rig.info.state != .playing && rig.info.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0, "buffering is not playing at rate 1")
        await session.receive(.init(context: state.playback.context, event: .started))
        await rig.wait { rig.info.state == .playing }
        #expect(rig.info.state == .playing, "and playing again once the engine says so")
        await session.close()
    }
    @Test func theEndOfItemTimerThatPausesTheSessionIsPublishedWithNoWindow() async throws {
        let (rig, session, _, _) = try await startedWithClocks()
        try await session.setTimer(.endOfItem)
        let state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .ended))      // the item ends: the timer pauses instead of advancing
        await rig.wait { rig.info.state == .paused }
        #expect(rig.info.state == .paused, "the timer's own pause reached Now Playing")
        await session.close()
    }
    @Test func aRouteInvalidationASleepAndAWakeAreEachPublishedWithNoWindow() async throws {
        let (rig, session, _, _) = try await startedWithClocks()
        await session.routeInvalidated(try? RouteID("SYNTH-OUT"))
        await rig.wait { rig.info.state == .paused }
        #expect(rig.info.state == .paused, "a route invalidation paused the session")
        try await session.resume()
        await rig.wait { rig.info.state == .playing }
        await session.sleep()
        await rig.wait { rig.info.state == .paused }
        #expect(rig.info.state == .paused, "the system sleep paused it")
        await session.wake(safeRoute: true, resumeEnabled: true)
        await rig.wait { rig.info.state == .playing }
        #expect(rig.info.state == .playing, "and a wake that resumes it is published too")
        await session.close()
    }
    @Test func aSessionThatTicksWithNothingToDoTellsTheOwnerNothingAndOneThatPausesItselfDoes() async throws {
        let wall = ManualWall(), clock = ManualMonotonic()
        let session = try await ownedSession(wall: wall, clock: clock)
        try await session.startOwnedMedia(OwnedMedia.items)
        try await Task.sleep(for: .milliseconds(150))                  // the start's own events settle
        let calls = Mutex(0)
        session.setChangeObserver { calls.withLock { $0 += 1 } }
        for _ in 0..<20 { await session.tick() }                       // the one-second tick of a playing item with no timer
        #expect(calls.withLock { $0 } == 0, "a tick that changes nothing is not a notification")
        try await session.setTimer(.minutes(1))
        calls.withLock { $0 = 0 }
        wall.advance(120); await session.tick(); clock.advance(to: .seconds(6)); await session.tick()
        #expect(calls.withLock { $0 } >= 1, "the tick that paused the session told its owner")
        await session.close()
    }
    @Test func replacingTheSessionStopsListeningToTheOldOne() async throws {
        let (rig, old) = try await startedWithNoWindow([OwnedMedia.items[0]])
        rig.model.session = nil
        let state = try await old.snapshot()
        let writes = rig.info.writes.count
        await old.receive(.init(context: state.playback.context, event: .ended))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.info.writes.count == writes, "a session the owner let go of cannot publish")
        await old.close()
    }
}
