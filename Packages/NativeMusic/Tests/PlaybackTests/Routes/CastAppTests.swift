import Domain
import Features
import Foundation
import OutputRoutes
import Testing
@testable import Playback
@testable import AppShell

/// T39 at the app level: the native session as the Cast driver's transport (a real `PlaybackSession` over the bundled owned audio, silent clock while a
/// receiver renders), the picker's sentences, lazy discovery, and the full path through the real relay to a simulated receiver. No test here names a real
/// network type; the receiver is `SimulatedCastReceiver` and the directory a recorder.

final class RecordingCastDirectory: CastDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [CastDevice] = []
    private var handlers: [UUID: @MainActor () -> Void] = [:]
    private(set) var startCalls = 0, stopCalls = 0
    func devices() -> [CastDevice] { lock.withLock { list } }
    @MainActor func observe(_ onChange: @escaping @MainActor () -> Void) -> OutputObservation {
        let id = UUID(); lock.withLock { handlers[id] = onChange }
        return Sub { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: id) } }
    }
    @MainActor func startBrowsing() { lock.withLock { startCalls += 1 } }
    @MainActor func stopBrowsing() { lock.withLock { stopCalls += 1 } }
    /// What browsing would find.
    @MainActor func found(_ devices: [CastDevice]) { let all = lock.withLock { list = devices; return Array(handlers.values) }; for handler in all { handler() } }
    private final class Sub: OutputObservation {
        let onCancel: () -> Void
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        @MainActor func cancel() { onCancel() }
    }
}

@MainActor struct CastAppRig {
    let base: LifecycleRig
    let directory: PlaybackScriptedDirectory
    let cast: RecordingCastDirectory
    let receiver: SimulatedCastReceiver
    let controller: OutputController
    var model: PlaybackModel { base.model }
    var coordinator: OutputRouteCoordinator { controller.coordinator }
    static func make(preferred: OutputRouteID? = nil) async throws -> CastAppRig {
        let base = try await LifecycleRig.make()
        let directory = PlaybackScriptedDirectory([routeSpeakers, routeBuds], defaultUID: routeBuds.uid)
        let controller = OutputController(coordinator: OutputRouteCoordinator(directory: directory, store: MemoryPreferredRoute(preferred)), applier: NoOutputApplier())
        let cast = RecordingCastDirectory(), receiver = SimulatedCastReceiver()
        controller.castDirectory = cast; controller.castFactory = receiver
        await controller.bind(to: base.model)
        return CastAppRig(base: base, directory: directory, cast: cast, receiver: receiver, controller: controller)
    }
    /// A native session on the bundled owned audio, playing (at the harness's 0.001 gain).
    func nativePlaying() async throws -> PlaybackSession {
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        model.session = session
        await controller.attach(session)
        return session
    }
}
private let living = CastDevice(id: CastDeviceID("APP-CAST-LIVING")!, friendlyName: "Living Room", capabilityBits: 5)

@Suite(.serialized) @MainActor struct CastAppTests {
    // MARK: Discovery and Local Network permission

    @Test func nothingIsBrowsedAtLaunchOnlyWhenThePickerIsOpened() async throws {
        let rig = try await CastAppRig.make()
        #expect(rig.cast.startCalls == 0 && rig.cast.stopCalls == 0, "binding the controller (launch) never starts browsing, so no Local Network question is raised")
        rig.controller.pickerOpened()
        #expect(rig.cast.startCalls == 1)
        rig.cast.found([living])
        #expect(rig.coordinator.castDevices == [living])
        rig.controller.pickerClosed()
        #expect(rig.cast.stopCalls >= 1)
        rig.cast.found([])
        #expect(rig.coordinator.castDevices.isEmpty, "a receiver that is no longer seen is no longer offered")
    }
    @Test func aRememberedReceiverIsNotLookedForAtLaunchEither() async throws {
        let rig = try await CastAppRig.make(preferred: living.routeID)
        #expect(rig.cast.startCalls == 0 && rig.receiver.openCount == 0 && rig.coordinator.selection.isSystemDefault && rig.coordinator.preferred == living.routeID)
    }

    // MARK: The picker's sentences

    @Test func theYouTubeMusicPickerSaysPlainlyThatItCannotBeCastAndListsNoTargets() async throws {
        let rig = try await CastAppRig.make()
        _ = try await rig.base.play()
        rig.cast.found([living]); rig.controller.pickerOpened()
        let value = OutputPickerMapping.content(for: rig.controller)
        #expect(rig.controller.subject == .youTubeMusic)
        #expect(value.castNotes == ["Casting YouTube Music isn't available from this app."])
        #expect(value.rows.allSatisfy { !$0.id.hasPrefix("cast:") }, "no Cast target is listed for a player that cannot use one")
        #expect(value.statement == "YouTube Music plays through this Mac's sound output. Change it in Control Center.")
    }
    @Test func theNativePickerListsReceiversWithWhatTheyCannotDoAndSaysWhatQuitDoes() async throws {
        let rig = try await CastAppRig.make()
        _ = try await rig.nativePlaying()
        rig.controller.pickerOpened()
        var value = OutputPickerMapping.content(for: rig.controller)
        #expect(value.castNotes.contains("Looking for Cast receivers on your network. The first time, macOS asks to allow Local Network access."))
        #expect(value.castNotes.contains("Only owned and local audio can be cast. YouTube Music can't be cast from this app."))
        rig.cast.found([living])
        value = OutputPickerMapping.content(for: rig.controller)
        let row = try #require(value.rows.first { $0.id == living.routeID.rawValue })
        #expect(row.title == "Living Room" && row.detail == "Cast" && row.selectable && row.state == .available)
        #expect(row.volume == "The receiver sets the volume.")
        #expect(row.unsupported.contains("A sleep timer pauses here but can't fade."))
        #expect(!value.castNotes.contains { $0.contains("stops when you quit") }, "not casting yet: no quit statement")
    }
    @Test func whileCastingTheQuitStatementNamesTheRelayAndCannotPromiseContinuation() async throws {
        let rig = try await CastAppRig.make()
        _ = try await rig.nativePlaying()
        rig.cast.found([living])
        #expect(await rig.coordinator.select(living.routeID, engine: .localMedia) == .selected)
        let value = OutputPickerMapping.content(for: rig.controller)
        #expect(value.currentName == "Living Room")
        #expect(value.castNotes.contains("Playback on the receiver stops when you quit, because this Mac is serving the audio."))
        #expect(!value.castNotes.joined().lowercased().contains("keep playing") && !value.castNotes.joined().lowercased().contains("leave"))
        let current = try #require(value.rows.first { $0.state == .current })
        #expect(current.id == living.routeID.rawValue)
        #expect(value.rows.filter { $0.id.hasPrefix("coreaudio:") }.allSatisfy { $0.selectable }, "the Mac's outputs can be chosen to leave the receiver")
        await rig.coordinator.leaveCast()
    }
    @Test func aCastNoticeIsShownWhenAnItemCannotBeCast() async throws {
        let rig = try await CastAppRig.make()
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia([OwnedMedia.videoItem])   // the owned video has no audio file to relay
        rig.model.session = session
        rig.cast.found([living])
        #expect(await rig.coordinator.select(living.routeID, engine: .localMedia) == .failed)
        let value = OutputPickerMapping.content(for: rig.controller)
        #expect(value.castNotes.contains("This item has no audio file that can be cast."))
        #expect(await session.isRemoteRendering() == false, "the failed attempt did not silence the player")
    }

    // MARK: The native session as the transport (real PlaybackSession)

    @Test func theSessionBecomesASilentClockAndTheUsersMuteIsKeptUnderneath() async throws {
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        #expect(await session.nativeMuted() == false)
        #expect(await session.setRemoteRendering(true))
        let silent = await session.nativeMuted(), flagged = await session.isRemoteRendering()
        #expect(silent && flagged)
        try await session.setMuted(false)
        #expect(await session.nativeMuted(), "the person unmuting cannot make a silenced engine audible")
        try await session.setMuted(true)
        #expect(await session.setRemoteRendering(false))
        #expect(await session.nativeMuted(), "the person's own mute survives the route")
        try await session.setMuted(false)
        #expect(await session.nativeMuted() == false)
        try await session.pause()
    }
    @Test func theTransportReadsTheSessionsItemIntentAndPositionAndOnlyBundledAudioIsCastable() async throws {
        let rig = try await CastAppRig.make()
        let session = try await rig.nativePlaying()
        let transport = NativeCastTransport(model: rig.model)
        let state = await transport.localState()
        let item = try #require(state.item)
        guard case .file(let url) = item.source else { Issue.record("not a file: \(item.source)"); return }
        #expect(url.lastPathComponent == "owned-a.wav" && FileManager.default.fileExists(atPath: url.path))
        #expect(item.title == "Owned test tone A" || item.title == "Untitled item" || !item.title.isEmpty)
        #expect(state.playing && item.duration != nil)
        try await session.pause(); await rig.model.refresh()
        #expect(await transport.localState().playing == false)
        await transport.seekLocal(3)
        #expect(abs(await transport.localState().position - 3) < 0.5)
    }
    @Test func aSeekOnTheSessionIsToldToTheObserver() async throws {
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        let seen = TargetBox()
        session.setSeekObserver { seen.append($0) }
        try await session.seek(4)
        #expect(seen.values == [4])
        session.setSeekObserver(nil)
        try await session.seek(5)
        #expect(seen.values == [4])
        try await session.pause()
    }

    // MARK: Through the real session, relay and simulated receiver

    @Test func choosingAReceiverSilencesTheSessionAndTheReceiverFetchesTheBundledFile() async throws {
        let rig = try await CastAppRig.make()
        let session = try await rig.nativePlaying()
        rig.cast.found([living])
        let fetched = TargetBox()
        rig.receiver.setOnLoad { url in
            guard let parsed = URL(string: url), let port = parsed.port else { fetched.append(-2); return }
            guard let reply = (try? LoopbackHTTP.get(port: UInt16(port), path: parsed.path)) ?? nil else { fetched.append(-1); return }
            fetched.append(Double(reply.status)); fetched.append(Double(reply.body.count))
        }
        #expect(await rig.coordinator.select(living.routeID, engine: .localMedia) == .selected)
        let mutedWhileCasting = await session.nativeMuted()
        #expect(mutedWhileCasting, "the local engine is silent while the receiver renders")
        let bundled = try #require(OwnedMedia.castableFile(for: OwnedMedia.items[0]))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: bundled.path)[.size] as? NSNumber).doubleValue
        #expect(fetched.values == [200, size], "the receiver got the whole bundled file through the relay")
        #expect(rig.controller.nowPlayingRoute(youTubeMusic: false)?.kind == .cast && rig.controller.nowPlayingRoute(youTubeMusic: false)?.name == "Living Room")
        #expect(rig.coordinator.preferred == living.routeID)
        await rig.coordinator.leaveCast()
        let unmuted = await session.nativeMuted() == false
        #expect(unmuted && !rig.receiver.hasApplication)
        let snapshot = try await session.snapshot()
        #expect(snapshot.playback.intent != .play, "leaving the receiver does not start the Mac's speakers")
    }
    @Test func aLostReceiverPausesTheRealSessionAndOnlyThenMakesItAudibleCapable() async throws {
        let rig = try await CastAppRig.make()
        let session = try await rig.nativePlaying()
        rig.cast.found([living])
        #expect(await rig.coordinator.select(living.routeID, engine: .localMedia) == .selected)
        rig.receiver.dropConnection()
        #expect(await waitUntil { rig.coordinator.loss(for: .localMedia) != nil })
        await rig.coordinator.settled()
        #expect(await waitUntil { !(await session.isRemoteRendering()) })
        let snapshot = try await session.snapshot()
        #expect(snapshot.playback.intent == .pause(.routeLoss), "paused as a route loss: \(snapshot.playback.intent)")
        let value = OutputPickerMapping.content(for: rig.controller)
        #expect(value.loss?.message == "The Cast receiver disconnected, so playback paused." && value.loss?.canReconnect == true)
        // A Play now is held for confirmation, with the Cast wording.
        await rig.model.nativePlayPause()
        let prompt = try #require(OutputPickerMapping.prompt(for: rig.controller))
        #expect(prompt.title == "Play on this Mac?" && prompt.message.hasPrefix("The Cast receiver disconnected, so playback paused."))
        rig.coordinator.cancel(prompt.id)
        #expect(try await session.snapshot().playback.intent != .play)
    }
    @Test func aSessionStartedWhileCastingIsSilentBeforeAnyItemStarts() async throws {
        let rig = try await CastAppRig.make()
        _ = try await rig.nativePlaying()
        rig.cast.found([living])
        #expect(await rig.coordinator.select(living.routeID, engine: .localMedia) == .selected)
        let replacement = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        await rig.controller.attach(replacement)
        let replacementMuted = await replacement.nativeMuted(), replacementFlag = await replacement.isRemoteRendering()
        #expect(replacementMuted && replacementFlag, "silent from attach, before startOwnedMedia")
        await rig.coordinator.leaveCast()
    }
    @Test func quittingStopsTheReceiverBeforeAnythingIsTornDown() async throws {
        let rig = try await CastAppRig.make()
        _ = try await rig.nativePlaying()
        rig.cast.found([living])
        #expect(await rig.coordinator.select(living.routeID, engine: .localMedia) == .selected)
        await rig.base.authority.quit()
        #expect(rig.receiver.receivedTypes().contains("STOP") && !rig.receiver.hasApplication)
        #expect(rig.controller.cast?.isLive == false)
    }
    @Test func anAccountBarrierEndsTheCastSession() async throws {
        let rig = try await CastAppRig.make()
        _ = try await rig.nativePlaying()
        rig.cast.found([living])
        _ = await rig.coordinator.select(living.routeID, engine: .localMedia)
        rig.controller.accountBarrier()
        #expect(await waitUntil { rig.coordinator.remote == nil && !rig.receiver.hasApplication })
    }
}

final class TargetBox: @unchecked Sendable {
    private let lock = NSLock(); private var items: [Double] = []
    func append(_ value: Double) { lock.withLock { items.append(value) } }
    var values: [Double] { lock.withLock { items } }
}
