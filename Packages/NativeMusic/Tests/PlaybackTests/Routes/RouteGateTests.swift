import AppKit
import Domain
import SystemIntegration
import Foundation
import OutputRoutes
import Testing
@testable import Playback
@testable import AppShell

/// W22 rework: after a loss EVERY audible path (a person's Play, Next, Previous, a media key, a new item) plays on this Mac's current output without a
/// prompt, the receiver's position is what is shown, and the wake check uses the same per-engine route as the loss policy.
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
    @Test func nextAndPreviousOnTheHiddenPlayerRunAtOnceAfterALoss() async throws {
        let (rig, player, page) = try await lostMusic()
        let skips = count(page, WebMusicScripts.skip)
        await player.next()
        #expect(count(page, WebMusicScripts.skip) == skips + 1 && player.snapshot.intent && rig.coordinator.prompt == nil && rig.coordinator.loss == nil, "Next plays here")
        await player.previous()
        #expect(count(page, WebMusicScripts.skip) == skips + 2 && rig.coordinator.prompt == nil, "so does Previous")
    }
    @Test func mediaKeyNextOnTheHiddenPlayerRunsAtOnceAfterALoss() async throws {
        let (rig, player, page) = try await lostMusic()
        let skips = count(page, WebMusicScripts.skip)
        _ = rig.model.remote(.next)
        try await Task.sleep(for: .milliseconds(50))
        #expect(count(page, WebMusicScripts.skip) == skips + 1 && player.snapshot.intent && rig.coordinator.prompt == nil)
    }
    @Test func nextWithNoLossStillGoesStraightThrough() async throws {
        let rig = try await OutputRig.make()
        let (player, page) = try await rig.play()
        let skips = count(page, WebMusicScripts.skip)
        await player.next()
        #expect(count(page, WebMusicScripts.skip) == skips + 1 && rig.coordinator.prompt == nil)
    }

    // MARK: finding 2b: new native items
    @Test func aNewNativeItemAfterALossStartsWithoutAsking() async throws {
        let (rig, session) = try await nativeLost()
        await rig.model.startOwned(request: rig.model.authority.requestOwnedStart())
        // The test harness refuses production stores, so the start fails at the owner: proof that it ran with no prompt in between.
        #expect(rig.coordinator.prompt == nil && rig.coordinator.loss(for: .localMedia) == nil && rig.model.error != nil)
        await session.close()
    }

    // MARK: finding 6: the native media-key gate
    @Test func nativeMediaKeyPlayResumesAtOnceAfterALoss() async throws {
        let (rig, session) = try await nativeLost()
        #expect(try await session.snapshot().playback.intent == .pause(.routeLoss))
        #expect(rig.model.remote(.play) == .success)
        var intent = try await session.snapshot().playback.intent
        for _ in 0..<40 where intent != .play { try await Task.sleep(for: .milliseconds(50)); intent = try await session.snapshot().playback.intent }
        #expect(intent == .play && rig.coordinator.prompt == nil && rig.coordinator.loss(for: .localMedia) == nil)
        await session.close()
    }

    @Test func aRadioQueueControlNeverCreatesAnOutputHeldStart() async throws {
        let (rig, _, page) = try await lostMusic()
        let command = try #require(MusicQueueFilterCommand(playlistID: "RDATmZvkhnokW3Mw24", params: "opaque%3D", playerParams: "0gcJCW0At9Zurpe2"))
        let starts = rig.model.playRequestCount, before = page.commands.count
        // The former start entry point fails closed, before output gating or ownership changes.
        let result = await rig.model.playMusic(playlistID: command.playlistID, title: "Workout", queueCommand: command, request: rig.base.authority.requestOwnedStart())
        #expect(result == .failed && rig.model.playRequestCount == starts)
        #expect(page.commands.count == before && rig.coordinator.prompt == nil)
    }

    // MARK: round 2, R2-1 on the real owner, both directions
    @Test func aNewYouTubeMusicItemAfterANativeLossStartsWithoutAsking() async throws {
        let (rig, session) = try await nativeLost()
        let pages = rig.base.log.pages.count
        let outcome = await rig.model.playMusic(playlistID: "PLsyntheticOther", title: "Another", request: rig.base.authority.requestOwnedStart())
        #expect(outcome == .started && rig.base.log.pages.count > pages && rig.coordinator.prompt == nil)
        await session.close()
    }
    @Test func aNewNativeItemAfterAHiddenPlayerLossStartsWithoutAsking() async throws {
        let (rig, _, _) = try await lostMusic()
        await rig.model.startOwned(request: rig.model.authority.requestOwnedStart())
        #expect(rig.coordinator.prompt == nil && rig.coordinator.losses.isEmpty, "the Play accepted this Mac's output for the lost device")
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
