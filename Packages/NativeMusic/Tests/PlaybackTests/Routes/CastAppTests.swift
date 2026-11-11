import Domain
import Features
import Foundation
import OutputRoutes
import Testing
@testable import Playback
@testable import AppShell
@testable import SystemIntegration
import TestSupport

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
    static func make(preferred: OutputRouteID? = nil, receiverOptions: SimulatedCastReceiver.Options? = nil, receiverLevel: Double? = nil) async throws -> CastAppRig {
        let base = try await LifecycleRig.make()
        let directory = PlaybackScriptedDirectory([routeSpeakers, routeBuds], defaultUID: routeBuds.uid)
        let controller = OutputController(coordinator: OutputRouteCoordinator(directory: directory, store: MemoryPreferredRoute(preferred)), applier: NoOutputApplier())
        let cast = RecordingCastDirectory(), receiver = SimulatedCastReceiver(options: receiverOptions ?? SimulatedCastReceiver.Options())
        if let receiverLevel { receiver.setLevel(receiverLevel) }
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

    @Test func youTubeMusicHasNoPickerSoNoCastTargetIsOfferedForIt() async throws {
        let rig = try await CastAppRig.make()
        _ = try await rig.base.play()
        rig.cast.found([living])
        #expect(rig.controller.subject == .youTubeMusic)
        #expect(!rig.controller.offersPicker, "the hidden player cannot be cast, and has no output button to offer a receiver from")
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
        #expect(row.volume == "While you cast, the volume slider sets the receiver's volume. The Mac's volume stays as it was.")
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
        // A Play now plays on this Mac without a prompt.
        await rig.model.nativePlayPause()
        #expect(OutputPickerMapping.prompt(for: rig.controller) == nil && rig.coordinator.loss(for: .localMedia) == nil)
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
    @Test func whileCastingTheSliderIsTheReceiversLevelAndTheMacsVolumeIsLeftAlone() async throws {
        let rig = try await CastAppRig.make(receiverLevel: 0.4)
        _ = try await rig.nativePlaying()
        rig.model.changeGain(0.0008)   // a distinctive Mac volume (the harness's range is 0...0.001)
        await rig.model.refresh()
        let macGain = rig.model.requestedGain
        #expect(macGain == 0.0008 && rig.model.volumeSlider == PlaybackModel.VolumeSlider(level: macGain, range: rig.model.gainRange, isReceiver: false, isEnabled: true, disabledReason: nil))
        rig.cast.found([living])
        #expect(await rig.coordinator.select(living.routeID, engine: .localMedia) == .selected)
        #expect(await waitUntil { rig.model.volumeSlider.isReceiver && rig.model.volumeSlider.isEnabled })
        #expect(rig.model.volumeSlider.level == 0.4 && rig.model.volumeSlider.range == 0...1, "the slider shows the receiver's level, not the Mac's \(macGain)")
        #expect(rig.model.shellState.volume == 0.4 && rig.model.shellState.volumeEnabled, "the mini-player and status item show the same")
        rig.model.setSliderVolume(0.45)   // every surface (bottom player, mini-player, status item, scripting) comes through here
        await rig.controller.cast?.volumeSettled()
        #expect(await waitUntil { abs(rig.receiver.volume - 0.45) < 1e-9 }, "a small move: about the receiver's level, never the Mac's or full: \(rig.receiver.volume)")
        #expect(rig.model.requestedGain == macGain, "the Mac's saved volume is not touched while casting")
        let snapshotGain = try await rig.model.session?.snapshot().gain
        #expect(snapshotGain == macGain, "nor is the session's gain")
        await rig.coordinator.leaveCast()
        #expect(!rig.model.volumeSlider.isReceiver && rig.model.volumeSlider.level == macGain && rig.model.requestedGain == macGain, "casting ended: the Mac's volume is exactly what it was")
        let after = try await rig.model.session?.snapshot().gain
        #expect(after == macGain, "the next local playback does not start quiet or loud")
        let sent = rig.receiver.receivedTypes().filter { $0 == "SET_VOLUME" }.count
        rig.model.setSliderVolume(0.0003)
        #expect(rig.model.requestedGain == 0.0003 && rig.receiver.receivedTypes().filter { $0 == "SET_VOLUME" }.count == sent, "the slider is the Mac's again")
    }
    @Test func aFixedVolumeReceiverDisablesTheSliderWithAReasonAndIsSentNothing() async throws {
        var options = SimulatedCastReceiver.Options(); options.volumeControlType = "fixed"
        let rig = try await CastAppRig.make(receiverOptions: options, receiverLevel: 0.5)
        _ = try await rig.nativePlaying()
        rig.cast.found([living])
        #expect(await rig.coordinator.select(living.routeID, engine: .localMedia) == .selected)
        #expect(await waitUntil { rig.model.volumeSlider.isReceiver && rig.model.volumeSlider.disabledReason == "This receiver's volume is fixed." })
        await rig.model.refresh()
        #expect(!rig.model.volumeSlider.isEnabled && !rig.model.shellState.volumeEnabled && rig.model.shellState.volumeHelp == "This receiver's volume is fixed.")
        rig.model.setSliderVolume(0.9)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.receiver.receivedTypes().filter { $0 == "SET_VOLUME" }.isEmpty && rig.receiver.volume == 0.5)
        await rig.coordinator.leaveCast()
    }
    /// TH5 (TH4 critic L-c): a script's `set volume` while the receiver cannot take a level is refused with the sentence the slider shows (localized in en, ru, de,
    /// es and fr), not answered with success while nothing is sent. The control: an adjustable receiver is sent the level and the script is told nothing is wrong.
    @Test func aScriptedVolumeChangeIsRefusedWhenTheCastReceiverCannotTakeALevelAndSucceedsWhenItCan() async throws {
        func shell(_ rig: CastAppRig) -> ShellCoordinator {
            ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(), preferences: InMemoryDefaults(), installsStatusItem: false)
        }
        var fixed = SimulatedCastReceiver.Options(); fixed.volumeControlType = "fixed"
        var unsupported = SimulatedCastReceiver.Options(); unsupported.supportedMediaCommands = 15 & ~4
        var silent = SimulatedCastReceiver.Options(); silent.reportsVolumeLevel = false
        let cases: [(String, SimulatedCastReceiver.Options, String)] = [
            ("fixed", fixed, "This receiver's volume is fixed."),
            ("unsupported", unsupported, "This receiver can't change its volume from here."),
            ("no level reported", silent, "Waiting for the receiver's volume."),
        ]
        for (name, options, sentence) in cases {
            let rig = try await CastAppRig.make(receiverOptions: options, receiverLevel: 0.5)
            _ = try await rig.nativePlaying()
            rig.cast.found([living])
            #expect(await rig.coordinator.select(living.routeID, engine: .localMedia) == .selected, "\(name)")
            #expect(await waitUntil { rig.model.volumeSlider.isReceiver && rig.model.volumeSlider.disabledReason == sentence }, "\(name): the slider says why")
            await rig.model.refresh()
            let scripting = shell(rig)
            let refusal = scripting.setVolume(percent: 80)
            #expect(refusal == .notAllowedNow(sentence), "\(name): refused with the slider's sentence, not nil (success): \(String(describing: refusal))")
            #expect(refusal?.message == sentence && refusal?.code == ScriptRefusal.notAllowedNow("").code, "\(name)")
            try await Task.sleep(for: .milliseconds(100))
            #expect(rig.receiver.receivedTypes().filter { $0 == "SET_VOLUME" }.isEmpty && rig.receiver.volume == 0.5, "\(name): nothing was sent")
            await rig.coordinator.leaveCast()
        }
        // Control: a receiver that can take a level.
        let rig = try await CastAppRig.make(receiverLevel: 0.4)
        _ = try await rig.nativePlaying()
        rig.cast.found([living])
        #expect(await rig.coordinator.select(living.routeID, engine: .localMedia) == .selected)
        #expect(await waitUntil { rig.model.volumeSlider.isReceiver && rig.model.volumeSlider.isEnabled })
        await rig.model.refresh()
        let scripting = shell(rig)
        #expect(scripting.setVolume(percent: 45) == nil, "an adjustable receiver is not refused")
        await rig.controller.cast?.volumeSettled()
        #expect(await waitUntil { abs(rig.receiver.volume - 0.45) < 1e-9 }, "and is sent the level: \(rig.receiver.volume)")
        await rig.coordinator.leaveCast()
    }
    /// TH5: the sentences a refusal can carry exist in all five launch languages (the catalog is the source for the window's slider too).
    @Test func theReceiverVolumeSentencesAreTranslatedInEnRuDeEsAndFr() throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localizable.xcstrings"))) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: [String: Any]])
        for key in ["This receiver's volume is fixed.", "This receiver can't change its volume from here.", "Waiting for the receiver's volume."] {
            let localizations = try #require(strings[key]?["localizations"] as? [String: [String: Any]], "\(key) is in the catalog")
            for language in ["en", "ru", "de", "es", "fr"] {
                let unit = localizations[language]?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String
                #expect(value?.isEmpty == false, "\(key) has a \(language) translation")
                if language != "en" { #expect(value != key, "\(key) \(language) is translated, not copied") }
            }
        }
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
