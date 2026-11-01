import AppKit
import Domain
import SystemIntegration
import Foundation
import OutputRoutes
import Testing
@testable import Playback
@testable import AppShell

/// W22 rework: Play here gates EVERY audible path, a held prompt does not survive an account barrier, the receiver's position is what is shown, and the
/// wake check uses the same per-engine route as the loss policy.
@Suite @MainActor struct RouteGateTests {
    private func count(_ page: FakeMusicPage, _ body: String) -> Int { page.bodies.filter { $0 == body }.count }
    /// A hidden player playing near the start of its item (so Previous goes to the previous item rather than restarting this one), whose output then leaves.
    private func lostMusic(position: Double = 1) async throws -> (OutputRig, WebMusicPlayer, FakeMusicPage) {
        let rig = try await OutputRig.make()
        let (player, page) = try await rig.play(state: lifecycleState(position: position))
        rig.unplug(); await rig.coordinator.settled()
        return (rig, player, page)
    }
    private func nativeLost() async throws -> (OutputRig, PlaybackSession) {
        let rig = try await OutputRig.make()
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.model.session = session
        rig.unplug(); await rig.coordinator.settled()
        return (rig, session)
    }

    // MARK: finding 2a: Next / Previous on the hidden player
    @Test func nextAndPreviousOnTheHiddenPlayerAreHeldAfterALoss() async throws {
        let (rig, player, page) = try await lostMusic()
        let skips = count(page, WebMusicScripts.skip)
        await player.next()
        #expect(count(page, WebMusicScripts.skip) == skips && !player.snapshot.intent && rig.coordinator.prompt != nil, "the transport's Next asks first and sends nothing")
        rig.coordinator.cancel(try #require(rig.coordinator.prompt?.id))
        await player.previous()
        #expect(count(page, WebMusicScripts.skip) == skips && !player.snapshot.intent && rig.coordinator.prompt != nil, "so does Previous")
    }
    @Test func mediaKeyNextAndPreviousOnTheHiddenPlayerAreHeldAfterALoss() async throws {
        let (rig, player, page) = try await lostMusic()
        let skips = count(page, WebMusicScripts.skip)
        for command in [RemoteTransportCommand.next, .previous] {
            _ = rig.model.remote(command)
            try await Task.sleep(for: .milliseconds(50))
            #expect(count(page, WebMusicScripts.skip) == skips && !player.snapshot.intent && rig.coordinator.prompt != nil, "\(command)")
            rig.coordinator.cancel(try #require(rig.coordinator.prompt?.id))
        }
    }
    @Test func nextRunsAfterPlayHereIsConfirmed() async throws {
        let (rig, player, page) = try await lostMusic()
        let skips = count(page, WebMusicScripts.skip)
        await player.next()
        guard case .playHere(let prompt)? = rig.coordinator.prompt else { Issue.record("expected Play here"); return }
        await rig.coordinator.confirm(prompt.id)
        #expect(count(page, WebMusicScripts.skip) == skips + 1 && player.snapshot.intent)
    }
    @Test func nextWithNoLossStillGoesStraightThrough() async throws {
        let rig = try await OutputRig.make()
        let (player, page) = try await rig.play()
        let skips = count(page, WebMusicScripts.skip)
        await player.next()
        #expect(count(page, WebMusicScripts.skip) == skips + 1 && rig.coordinator.prompt == nil)
    }

    // MARK: finding 2b: new native items
    @Test func aNewNativeItemAfterALossAsksFirstAndStartsNothingUntilConfirmed() async throws {
        let (rig, session) = try await nativeLost()
        let request = rig.model.authority.requestOwnedStart()
        await rig.model.startOwned(request: request)
        #expect(rig.coordinator.prompt != nil && rig.model.error == nil, "held: the owner was not even asked to open a store")
        guard case .playHere(let prompt)? = rig.coordinator.prompt else { Issue.record("expected Play here"); return }
        await rig.coordinator.confirm(prompt.id)
        // The test harness refuses production stores, so the confirmed start fails at the owner: proof that it ran only AFTER the confirmation.
        #expect(rig.model.error != nil)
        await session.close()
    }
    @Test func aNewNativeVideoAfterALossIsHeldToo() async throws {
        let (rig, session) = try await nativeLost()
        await rig.model.startOwnedVideo(request: rig.model.authority.requestOwnedStart())
        #expect(rig.coordinator.prompt != nil && rig.model.error == nil)
        await session.close()
    }

    // MARK: finding 6: the native media-key gate
    @Test func nativeMediaKeyPlayAndToggleAreHeldAfterALoss() async throws {
        let (rig, session) = try await nativeLost()
        #expect(try await session.snapshot().playback.intent == .pause(.routeLoss))
        for command in [RemoteTransportCommand.play, .toggle] {
            #expect(rig.model.remote(command) == .success)
            try await Task.sleep(for: .milliseconds(80))
            #expect(rig.coordinator.prompt != nil, "\(command): Play here is asked")
            #expect(try await session.snapshot().playback.intent == .pause(.routeLoss), "\(command): nothing resumed")
            rig.coordinator.cancel(try #require(rig.coordinator.prompt?.id))
        }
        await session.close()
    }

    // MARK: finding 5: account barrier
    @Test func aHeldPromptDoesNotSurviveAnAccountBarrierAndItsStartPermitIsRejected() async throws {
        let (rig, _, page) = try await lostMusic()
        let pages = rig.base.log.pages.count
        let request = rig.base.authority.requestOwnedStart()
        let outcome = await rig.model.playMusic(playlistID: "PLsyntheticOther", title: "Another", request: request)
        #expect(outcome == .busy && rig.coordinator.prompt != nil)
        let id = try #require(rig.coordinator.prompt?.id)
        // The account switches (the same barrier the lifecycle sends every participant).
        let context = rig.base.context
        try await rig.base.authority.detach(previous: context, barrier: RequestContext(account: nil, accountGeneration: context.accountGeneration + 1, requestGeneration: 0))
        #expect(rig.coordinator.prompt == nil, "the prompt belonged to the earlier account")
        await rig.coordinator.confirm(id)
        #expect(rig.base.log.pages.count == pages && count(page, WebMusicScripts.loadPlaylist) == 0, "a late confirmation starts nothing")
        // And even a start that somehow ran later would carry the OLD permit, which the barrier rejected.
        let late = await rig.model.playMusic(playlistID: "PLsyntheticOther", title: "Another", request: request)
        #expect(late != .started)
    }

    @Test func aHeldStartKeepsTheClicksOwnPermitSoABarrierRejectsItEvenIfThePromptSurvived() async throws {
        let (rig, _, _) = try await lostMusic()
        // Isolate the permit defence: the barrier no longer discards the prompt, so only the permit can stop the held start.
        await rig.base.authority.onBarrier {}
        let pages = rig.base.log.pages.count
        let outcome = await rig.model.playMusic(playlistID: "PLsyntheticOther", title: "Another", request: rig.base.authority.requestOwnedStart())
        #expect(outcome == .busy)
        let id = try #require(rig.coordinator.prompt?.id)
        let context = rig.base.context
        try await rig.base.authority.detach(previous: context, barrier: RequestContext(account: nil, accountGeneration: context.accountGeneration + 1, requestGeneration: 0))
        // The account is back (a later restore), so a start with a FRESH permit would now succeed: only the click's own, rejected permit stops this one.
        try await rig.base.authority.restorePaused(rig.base.identity, context: rig.base.context)
        await rig.coordinator.confirm(id)
        #expect(rig.base.log.pages.count == pages, "the held start used the permit captured at the click, which the barrier rejected")
    }

    // MARK: round 2, R2-1 on the real owner, both directions
    @Test func aNewYouTubeMusicItemAfterANativeLossAsksFirst() async throws {
        let (rig, session) = try await nativeLost()
        let pages = rig.base.log.pages.count
        let outcome = await rig.model.playMusic(playlistID: "PLsyntheticOther", title: "Another", request: rig.base.authority.requestOwnedStart())
        #expect(outcome == .busy && rig.base.log.pages.count == pages && rig.coordinator.prompt != nil, "the speakers would take over: nothing loads until Play here is confirmed")
        await session.close()
    }
    @Test func aNewNativeItemAfterAHiddenPlayerLossAsksFirst() async throws {
        let (rig, _, _) = try await lostMusic()
        await rig.model.startOwned(request: rig.model.authority.requestOwnedStart())
        #expect(rig.coordinator.prompt != nil && rig.model.error == nil, "held: the owner was not asked to open anything")
    }

    // MARK: round 2, R2-3: the native engine is silenced in the announcement's own turn
    @Test func theNativePlayerIsPausedBeforeTheAnnouncementReturns() async throws {
        let rig = try await OutputRig.make()
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.model.session = session
        let player = session.routePickerPlayer
        #expect(player.rate != 0, "precondition: the AVPlayer is playing, so the assertion below is not vacuous")
        rig.unplug()
        // No await since the announcement: the state machine's own pause is one actor hop away, so only `silenceNow()` can have stopped the player.
        #expect(player.rate == 0, "the player was paused inside the announcement's turn")
        await rig.coordinator.settled()
        #expect(try await session.snapshot().playback.intent == .pause(.routeLoss))
        await session.close()
    }

    // MARK: finding 4: the receiver's position is what is shown
    @Test func whileAReceiverPlaysTheTimelineShowsTheReceiversReadingNotTheLocalClock() async throws {
        let rig = try await OutputRig.make()
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.model.session = session
        await rig.model.refresh()
        #expect(rig.model.timeline.receiver == nil && rig.model.timeline.displayedPosition == rig.model.timeline.snapshot?.playback.position, "the Mac renders the sound: the local position")
        await rig.controller.externalPlaybackChanged(true)
        #expect(rig.controller.remoteReading() == .some(nil), "a receiver plays and has reported nothing yet")
        rig.model.timeline.receiver = rig.controller.remoteReading()
        #expect(rig.model.timeline.displayedPosition == nil, "nothing is shown rather than a local guess")
        rig.controller.observeNativePosition(42)
        rig.model.timeline.receiver = rig.controller.remoteReading()
        #expect(rig.model.timeline.displayedPosition == 42, "exactly what the receiver side reported")
        await rig.model.refresh()   // the refresh feeds the receiver reading it reads from the AVPlayer clock, and shows that reading
        #expect(rig.model.timeline.receiver != nil && rig.model.timeline.displayedPosition == rig.controller.coordinator.remotePosition())
        await session.close()
    }
    @Test func theTimelineTextIsADashWhenNoReceiverReadingIsFresh() {
        let model = PlaybackTimelineModel()
        model.receiver = .some(nil)
        #expect(model.displayedPosition == nil)
        model.receiver = .some(12)
        #expect(model.displayedPosition == 12)
    }

    // MARK: finding 1 / W21: one route model for the wake check
    @Test func theWakeComparesTheDeviceAnEngineWasPointedAtNotTheSystemDefault() async throws {
        final class PinnedTransport: PowerTransporting {
            let identity: RouteIdentity
            init(_ identity: RouteIdentity) { self.identity = identity }
            func holdForSleep() async -> Bool { true }
            func holdFacts() async -> (personChanged: Bool, timerExpired: Bool, ownerChanged: Bool) { (false, false, false) }
            func finishWake(resume: Bool) async -> Bool { resume }
            func silenceAfterWake() async {}
            func audibleRoute() -> (identity: RouteIdentity?, pinned: Bool) { (identity, true) }
        }
        struct DeviceRoute: RouteConfirming {
            let dac: RouteIdentity, systemDefault: RouteIdentity
            func identity() -> RouteIdentity? { systemDefault }
            // The system-default comparison NEVER confirms here (the speakers are the default and the DAC is what the engine plays on), so only the
            // device path can resume: if the owner's own `audibleRoute()` were not the one called, the wake would stay paused.
            func wait(for recorded: RouteIdentity?, within timeout: Duration) async -> RouteOutcome { .changed }
            func wait(forDevice recorded: RouteIdentity?, within timeout: Duration) async -> RouteOutcome { recorded == dac ? .same : .absent }
        }
        let dac = RouteIdentity(uid: "SYNTH-USB-DAC", transport: 0x7573_6220), speakers = RouteIdentity(uid: "SYNTH-BUILT-IN", transport: 0x626C_746E)
        let transport = PinnedTransport(dac)
        let power = PowerLifecycleCoordinator(transport: transport, route: DeviceRoute(dac: dac, systemDefault: speakers), display: ShellDisplayState(), silenceCheck: .milliseconds(1))
        await power.handle(.systemWillSleep); await power.handle(.systemDidWake)
        #expect(power.lastDecision == .resume, "the DAC is still the device the engine plays on, though the system default is the speakers: \(String(describing: power.lastDecision))")
        power.stop()
    }
    @Test func theHiddenPlayersWakeRecordIsTheSystemDefaultAndTheLocalEnginesIsItsDevice() async throws {
        let rig = try await OutputRig.make(devices: [routeSpeakers, routeBuds, OutputDevice(uid: "SYNTH-USB-DAC", name: "Synthetic DAC", transportCode: 0x7573_6220)], defaultUID: routeBuds.uid)
        _ = try await rig.play()
        #expect(rig.model.audibleRoute().identity?.uid == routeBuds.uid && !rig.model.audibleRoute().pinned)
        _ = await rig.coordinator.select(.device(uid: "SYNTH-USB-DAC"), engine: .localMedia)
        #expect(rig.model.audibleRoute().identity?.uid == routeBuds.uid, "the hidden player is the subject: its route is the default, whatever the local engine chose")
    }
}
