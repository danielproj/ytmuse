import AppKit
import Domain
import Foundation
import OutputRoutes
import Testing
@testable import Playback
@testable import AppShell

// W22 on the REAL owners: the hidden player with a fake page, the native session and the playback model, behind a scripted output directory. No test here
// reads or changes a device; `OutputRoutesGuardTests` (RoutesTests) sweeps these sources to keep it that way.

let routeSpeakers = OutputDevice(uid: "SYNTH-BUILT-IN", name: "Synthetic Speakers", transportCode: 0x626C_746E, dataSource: 0x6973_706B, hasDeviceVolume: true)
let routeBuds = OutputDevice(uid: "SYNTH-BT-BUDS", name: "Synthetic Buds", transportCode: 0x626C_7565, hasDeviceVolume: true)
let routeReceiver = OutputDevice(uid: "SYNTH-AIRPLAY", name: "Synthetic Receiver", transportCode: 0x6169_7270)

final class PlaybackScriptedDirectory: OutputDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var current: OutputSnapshot
    private var handlers: [UUID: @MainActor () -> Void] = [:]
    init(_ devices: [OutputDevice], defaultUID: String?) { current = OutputSnapshot(devices: devices, defaultUID: defaultUID) }
    func snapshot() -> OutputSnapshot { lock.withLock { current } }
    @MainActor func observe(_ onChange: @escaping @MainActor () -> Void) -> OutputObservation {
        let id = UUID(); lock.withLock { handlers[id] = onChange }
        return Subscription { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: id) } }
    }
    @MainActor func change(_ devices: [OutputDevice], defaultUID: String?) {
        let list = lock.withLock { current = OutputSnapshot(devices: devices, defaultUID: defaultUID); return Array(handlers.values) }
        for handler in list { handler() }
    }
    private final class Subscription: OutputObservation {
        let onCancel: () -> Void
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        @MainActor func cancel() { onCancel() }
    }
}

/// The one playback owner with a fake hidden page AND the output controller bound to it.
@MainActor struct OutputRig {
    let base: LifecycleRig
    let directory: PlaybackScriptedDirectory
    let controller: OutputController
    var model: PlaybackModel { base.model }
    static func make(devices: [OutputDevice] = [routeSpeakers, routeBuds], defaultUID: String? = routeBuds.uid) async throws -> OutputRig {
        let base = try await LifecycleRig.make()
        let directory = PlaybackScriptedDirectory(devices, defaultUID: defaultUID)
        let controller = OutputController(coordinator: OutputRouteCoordinator(directory: directory, store: MemoryPreferredRoute()), applier: NoOutputApplier())
        await controller.bind(to: base.model)
        return OutputRig(base: base, directory: directory, controller: controller)
    }
    var coordinator: OutputRouteCoordinator { controller.coordinator }
    /// An explicit Play and the page's first reports.
    func play(state: [String: Any] = lifecycleState()) async throws -> (WebMusicPlayer, FakeMusicPage) { try await base.play(state: state) }
    func unplug() { directory.change([routeSpeakers], defaultUID: routeSpeakers.uid) }
    func replug() { directory.change([routeSpeakers, routeBuds], defaultUID: routeBuds.uid) }
}

/// T22.1 on the hidden YouTube Music player: the pause goes to the page through the existing command path, with a route-loss reason.
@Suite @MainActor struct MusicRouteLossTests {
    private func count(_ page: FakeMusicPage, _ body: String) -> Int { page.bodies.filter { $0 == body }.count }

    @Test func aDisconnectWhilePlayingPausesThePageAsARouteLossAndNotAPersonsPause() async throws {
        let rig = try await OutputRig.make()
        let (player, page) = try await rig.play()
        let revision = player.commandRevision, pauses = count(page, WebMusicScripts.pause)
        rig.unplug()
        await rig.coordinator.settled()
        #expect(count(page, WebMusicScripts.pause) == pauses + 1, "the page itself was told to pause")
        #expect(player.snapshot.pausedByRouteLoss && !player.snapshot.intent, "the reason is recorded: it is not a person's pause")
        #expect(player.commandRevision > revision, "a hold taken earlier can no longer resume over it")
        #expect(rig.coordinator.loss(for: .youTubeMusic)?.engine == .youTubeMusic && rig.coordinator.loss(for: .youTubeMusic)?.wasAudible == true)
    }
    @Test func aDisconnectWhileTheItemIsStillLoadingPausesToo() async throws {
        let rig = try await OutputRig.make()
        _ = await rig.model.playMusic(playlistID: "PLsyntheticLife", title: "Synthetic Mix", request: rig.base.authority.requestOwnedStart())
        let page = try #require(rig.base.log.pages.first)
        page.commitLast()   // the document is there, no state report yet: loading with the intent to play
        let player = try #require(rig.model.music)
        #expect(player.snapshot.phase == .loading && player.snapshot.intent && player.isAudibleOrWanted)
        rig.unplug()
        await rig.coordinator.settled()
        #expect(count(page, WebMusicScripts.pause) == 1 && player.snapshot.pausedByRouteLoss)
    }
    @Test func aPageThatReportsPlayingAfterTheLossIsPausedAgainOnlyAFewTimes() async throws {
        let rig = try await OutputRig.make()
        let (player, page) = try await rig.play()
        rig.unplug(); await rig.coordinator.settled()
        let after = count(page, WebMusicScripts.pause)
        for _ in 0..<8 { page.send(lifecycleState(playing: true)); await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        let extra = count(page, WebMusicScripts.pause) - after
        #expect(extra >= 1 && extra <= 3, "an in-flight 'playing' report is answered with a bounded repeat of the pause (\(extra))")
        #expect(!player.snapshot.intent && count(page, WebMusicScripts.play) == 0, "and nothing ever plays by itself")
    }
    @Test func reconnectingNeverPlaysAndAPersonsPlayIsHeldForConfirmation() async throws {
        let rig = try await OutputRig.make()
        let (player, page) = try await rig.play()
        rig.unplug(); await rig.coordinator.settled()
        rig.replug()
        #expect(rig.coordinator.loss != nil && rig.coordinator.lossCanReconnect(for: .youTubeMusic))
        #expect(count(page, WebMusicScripts.play) == 0, "the output is back and nothing started")
        // A person presses Play (or a media key does): the speakers/other output would take over, so the owner asks first.
        await player.resume()
        #expect(count(page, WebMusicScripts.play) == 0 && rig.coordinator.prompt != nil, "held for confirmation")
        guard case .playHere(let prompt)? = rig.coordinator.prompt else { Issue.record("expected Play here"); return }
        await rig.coordinator.confirm(prompt.id)
        #expect(count(page, WebMusicScripts.play) == 1 && player.snapshot.intent && !player.snapshot.pausedByRouteLoss)
    }
    @Test func aNewItemStartedAfterALossIsHeldForConfirmationToo() async throws {
        let rig = try await OutputRig.make()
        _ = try await rig.play()
        rig.unplug(); await rig.coordinator.settled()
        let pages = rig.base.log.pages.count
        let outcome = await rig.model.playMusic(playlistID: "PLsyntheticOther", title: "Another", request: rig.base.authority.requestOwnedStart())
        #expect(outcome == .busy && rig.base.log.pages.count == pages && rig.coordinator.prompt != nil, "nothing loads or plays until Play here is confirmed")
        guard case .playHere(let prompt)? = rig.coordinator.prompt else { Issue.record("expected Play here"); return }
        await rig.coordinator.confirm(prompt.id)
        #expect(rig.coordinator.loss == nil)
    }
    @Test func aMediaKeyPlayAfterALossIsHeldToo() async throws {
        let rig = try await OutputRig.make()
        _ = try await rig.play()
        rig.unplug(); await rig.coordinator.settled()
        #expect(rig.model.remote(.play) == .success, "admitted: the owner decides asynchronously")
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.coordinator.prompt != nil && !(rig.base.log.pages.first?.bodies.contains(WebMusicScripts.play) ?? true))
    }
    @Test func aSystemWakeCannotResumeOverARouteLossHeldBeforeIt() async throws {
        let rig = try await OutputRig.make()
        let (player, page) = try await rig.play()
        let power = PowerLifecycleCoordinator(transport: rig.model, route: ScriptedRoute(RouteIdentity(uid: routeBuds.uid, transport: routeBuds.transportCode)), display: ShellDisplayState(), silenceCheck: .milliseconds(1))
        await power.handle(.systemWillSleep)
        rig.unplug(); await rig.coordinator.settled()
        await power.handle(.systemDidWake)
        #expect(power.lastDecision == .stayPaused(.routeLost), "\(String(describing: power.lastDecision))")
        #expect(count(page, WebMusicScripts.play) == 0 && !player.snapshot.intent)
        power.stop()
    }
    @Test func theWakeFactsPutARouteLossFirstOfEveryReason() {
        var resumes = 0
        for bits in 0..<128 {
            let facts = WakeFacts(held: bits & 1 != 0, preference: bits & 2 != 0, routeConfirmed: bits & 4 != 0, personChangedPlayback: bits & 8 != 0,
                                  timerExpired: bits & 16 != 0, ownerChanged: bits & 32 != 0, routeLost: bits & 64 != 0)
            let decision = SleepWakePolicy.decide(facts)
            if decision == .resume { resumes += 1; #expect(!facts.routeLost) }
            if facts.held && facts.routeLost { #expect(decision == .stayPaused(.routeLost), "route loss wins over every other reason") }
        }
        #expect(resumes == 1, "still exactly one combination of 128 resumes")
    }
    /// The pause reaches the page INSIDE the system's notification turn: when the announcement returns, the command is already at the page. A pause that
    /// is only enqueued (`Task { }`) fails this: it appears after the next suspension.
    @Test func theRouteLossPauseReachesThePageBeforeTheAnnouncementReturns() async throws {
        let rig = try await OutputRig.make()
        let (player, page) = try await rig.play()
        let before = count(page, WebMusicScripts.pause)
        let clock = ContinuousClock()
        let start = clock.now
        rig.unplug()
        let elapsed = clock.now - start
        // No await has happened since the announcement.
        #expect(count(page, WebMusicScripts.pause) == before + 1, "the pause command was already issued to the page when the announcement returned")
        #expect(!player.snapshot.intent && player.snapshot.pausedByRouteLoss)
        let micros = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
        print("T22 route-loss pause (announcement -> pause command at the page, fake page, synchronous in the announcement's turn): \(Int(micros)) us")
        await rig.coordinator.settled()
        #expect(count(page, WebMusicScripts.pause) == before + 1, "and it was not sent a second time")
    }
}

/// T22.1 on the native engine's state machine: a route loss in any state wins over every later resume event.
@Suite struct NativeRouteLossTests {
    private func machine() -> (PlaybackMachine, RequestContext) {
        let request = ownedContext()
        return (PlaybackMachine(request: request), request)
    }
    private func advance(_ machine: inout PlaybackMachine, to phase: String, now: inout Duration) {
        machine.select(OwnedMedia.items[0], occurrence: UUID(), now: now)
        let context = machine.context
        switch phase {
        case "preparing": _ = machine.receive(.resolved, context: context, now: now)
        case "playing":
            _ = machine.receive(.resolved, context: context, now: now); _ = machine.receive(.prepared, context: context, now: now); _ = machine.receive(.started, context: context, now: now)
        case "seeking":
            _ = machine.receive(.resolved, context: context, now: now); _ = machine.receive(.prepared, context: context, now: now); _ = machine.receive(.started, context: context, now: now)
            _ = try? machine.seek(5, now: now)
        default: break
        }
    }
    @Test(arguments: ["resolving", "preparing", "playing", "seeking"])
    func aRouteLossInAnyStateWinsOverEveryLaterResumeEvent(phase: String) {
        var (machine, _) = machine()
        var now = Duration.seconds(1)
        advance(&machine, to: phase, now: &now)
        let old = machine.context
        let effects = machine.changeRoute(try? RouteID("synthetic-output-loss"), now: now)
        #expect(effects.contains(.stop) && machine.intent == .pause(.routeLoss), "\(phase): paused with a route-loss reason")
        now += .seconds(1)
        // Late events of the route that was lost: every one is dropped (DATA03).
        for event in [PlaybackEvent.prepared, .started, .networkRecovered, .seekCompleted(revision: machine.seekRevision), .resolved, .buffering] {
            #expect(machine.receive(event, context: old, now: now).isEmpty && machine.intent == .pause(.routeLoss), "\(phase): \(event) from the old route is ignored")
        }
        // Events of the new generation cannot play either: the intent is the loss, not Play.
        let current = machine.context
        for event in [PlaybackEvent.prepared, .started, .networkRecovered, .seekCompleted(revision: machine.seekRevision)] {
            let result = machine.receive(event, context: current, now: now)
            #expect(!result.contains(.play) && machine.intent == .pause(.routeLoss) && machine.state != .playing, "\(phase): \(event) cannot start sound")
        }
        #expect(machine.wake(safeRoute: true, resumeEnabled: true).isEmpty, "a wake does not resume a route-loss pause")
    }
    @Test func onlyAPersonsExplicitPlayEndsARouteLossPause() {
        var (machine, _) = machine()
        var now = Duration.seconds(1)
        advance(&machine, to: "playing", now: &now)
        _ = machine.changeRoute(nil, now: now)
        #expect(machine.resume() == [] || machine.resume() == [.play], "resume is the person's call")
        #expect(machine.intent == .play)
    }
}

@Suite @MainActor struct NativeSessionRouteLossTests {
    @Test func theNativeAdapterPausesTheSessionWithARouteLossAndWakeCannotResumeIt() async throws {
        let rig = try await OutputRig.make()
        let wall = ManualWall()
        let session = try await ownedSession(wall: wall, clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.model.session = session
        await rig.model.refresh()
        #expect(try await session.snapshot().playback.intent == .play)
        rig.unplug()
        await rig.coordinator.settled()
        #expect(try await session.snapshot().playback.intent == .pause(.routeLoss))
        #expect(rig.coordinator.loss?.engine == .localMedia)
        #expect(rig.model.routeLossPending())
        #expect(await rig.model.finishWake(resume: false) == false)
        #expect(try await session.snapshot().playback.intent == .pause(.routeLoss), "the loss stands until a person plays")
        await session.close()
    }
}

@Suite @MainActor struct NativePlayHereResumeTests {
    @Test func aPersonsPlayAfterARouteLossAndPlayHereReallyPlaysAgain() async throws {
        let rig = try await OutputRig.make()
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.model.session = session
        rig.unplug(); await rig.coordinator.settled()
        #expect(try await session.snapshot().playback.intent == .pause(.routeLoss))
        await rig.model.nativePlayPause()   // held: Play here is asked first
        #expect(try await session.snapshot().playback.intent == .pause(.routeLoss), "nothing plays before the confirmation")
        guard case .playHere(let prompt)? = rig.coordinator.prompt else { Issue.record("expected Play here"); return }
        await rig.coordinator.confirm(prompt.id)
        var state = try await session.snapshot().playback
        for _ in 0..<100 where state.state != .playing { try await Task.sleep(for: .milliseconds(50)); state = try await session.snapshot().playback }
        #expect(state.intent == .play && state.state == .playing, "intent \(state.intent) state \(state.state)")
        await session.close()
    }
}

/// T22.3 across the two engines: the old engine is silent, and confirmed so, before the new one is started.
@Suite @MainActor struct EngineHandoffTests {
    @Test func startingNativeAudioSilencesAPlayingHiddenPlayerFirst() async throws {
        let rig = try await OutputRig.make()
        let (player, page) = try await rig.play()
        let outcome = await rig.coordinator.beginHandoff(to: .localMedia)
        #expect(outcome == .ready && !player.snapshot.intent)
        #expect(page.bodies.last == WebMusicScripts.pause, "the page was told to pause before the caller may start the other engine")
        #expect(rig.coordinator.activeEngine == .localMedia)
    }
    @Test func startingYouTubeMusicSilencesAPlayingNativeSessionFirst() async throws {
        let rig = try await OutputRig.make()
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.model.session = session
        #expect(try await session.snapshot().playback.intent == .play)
        let outcome = await rig.coordinator.beginHandoff(to: .youTubeMusic)
        #expect(outcome == .ready)
        #expect(try await session.snapshot().playback.intent != .play, "the native engine is paused and confirmed before YouTube Music may start")
        await session.close()
    }
    @Test func aHandoffToTheHiddenPlayerThroughThePlaybackModelStopsTheNativeSessionBeforeThePageLoads() async throws {
        let rig = try await OutputRig.make()
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.model.session = session
        _ = await rig.model.playMusic(playlistID: "PLsyntheticLife", title: "Synthetic Mix", request: rig.base.authority.requestOwnedStart())
        #expect(rig.model.session == nil, "the owner dropped the native session")
        #expect(try await session.snapshot().playback.intent != .play, "and it was silent before the page loaded")
        #expect(rig.base.log.pages.first?.loads.count == 1)
    }
    @Test func theHiddenPlayerIsStoppedWhenItsPageCannotConfirmThePause() async throws {
        let rig = try await OutputRig.make()
        let (player, page) = try await rig.play()
        page.replies = [.unavailable]   // the pause reaches no document
        #expect(await player.stopForHandoff())
        #expect(page.tornDown == 1, "an unconfirmable page is dropped, which certainly silences it")
    }
}
