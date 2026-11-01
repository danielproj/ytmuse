import AVFoundation
import Domain
import Features
import Foundation
import Observation
import OutputRoutes
import Playback
import SystemIntegration

// W22. The app side of the output coordinator: the two engine adapters behind the one playback owner (PLAY01), the AirPlay external-playback hookup,
// and the gate the transports use before sound starts. The real CoreAudio directory and AVFoundation applier are named in exactly one place
// (`OutputComposition.swift`); this file takes them as parameters, so a test constructs a controller with scripted fakes only.

/// The hidden YouTube Music player as an output engine. It cannot be pointed at a device: it follows the Mac (`Docs/Routes.md`).
@MainActor final class MusicOutputEngine: OutputEngine {
    private weak var model: PlaybackModel?
    init(model: PlaybackModel) { self.model = model }
    var kind: OutputEngineKind { .youTubeMusic }
    var backend: OutputBackend { .hiddenWebPlayer }
    var isAudibleOrWanted: Bool { model?.music?.isAudibleOrWanted ?? false }
    func pauseForRouteLoss() async -> Bool { await model?.music?.pauseForRouteLoss() ?? true }
    func stopForHandoff() async -> Bool { await model?.music?.stopForHandoff() ?? true }
    func apply(output uid: String?) async -> Bool { uid == nil }
}

/// The native session (owned and local media, AVFoundation) as an output engine.
@MainActor final class LocalOutputEngine: OutputEngine {
    private weak var model: PlaybackModel?
    private weak var controller: OutputController?
    init(model: PlaybackModel, controller: OutputController) { self.model = model; self.controller = controller }
    var kind: OutputEngineKind { .localMedia }
    var backend: OutputBackend { controller?.localBackend ?? .avPlayer }
    /// A session whose last reading says "play" counts as wanted; with no reading yet it is assumed wanted, so a loss errs toward pausing.
    var isAudibleOrWanted: Bool {
        guard let model, model.session != nil else { return false }
        return model.state.map { $0.playback.intent == .play } ?? true
    }
    func pauseForRouteLoss() async -> Bool {
        guard let model, let session = model.session else { return true }
        session.silenceNow()   // this turn: the player is paused before the state machine's own pause is processed
        await session.routeInvalidated(try? RouteID(controller?.coordinator.selection.rawValue ?? OutputRouteID.systemDefault.rawValue))
        await model.refresh()
        return true
    }
    func stopForHandoff() async -> Bool {
        guard let session = model?.session else { return true }
        if await session.isClosed() { return true }
        do { try await session.pause() } catch { return false }
        return true
    }
    func apply(output uid: String?) async -> Bool {
        guard let session = model?.session else { return true }   // applied when a session attaches
        return await session.setOutput(uid: uid)
    }
}

@MainActor @Observable final class OutputController {
    let coordinator: OutputRouteCoordinator
    @ObservationIgnored let applier: any LocalOutputApplying
    @ObservationIgnored weak var model: PlaybackModel?
    /// The `AVPlayer` the system AirPlay picker attaches to (a local `AVPlayer` backend only).
    private(set) var pickerPlayer: AVPlayer?
    private(set) var localBackend: OutputBackend = .avPlayer
    var multipleAirPlayRoutes = false
    /// False in an isolated launch (scripted outputs): the real system AirPlay picker is not created.
    var usesRealSystemPicker = true
    /// Kept alive for the life of the controller; stopped at quit.
    @ObservationIgnored var airPlayDetection: AirPlayRouteDetection?
    #if DEBUG
    /// Isolated launches: the scripted outputs the Debug controls change, and the in-process simulated Cast receiver.
    @ObservationIgnored var scripted: ScriptedOutputDirectory?
    @ObservationIgnored var scriptedCastReceiver: SimulatedCastReceiver?
    #endif
    /// W39: where Cast receivers come from (the real Bonjour browser, or the scripted list of an isolated launch) and how they are connected to. Installed
    /// by the composition; nil when this process offers no Cast.
    @ObservationIgnored var castDirectory: (any CastDirectory)?
    @ObservationIgnored var castFactory: (any CastChannelFactory)?
    private(set) var cast: CastRouteDriver?
    @ObservationIgnored private var castObservation: OutputObservation?
    @ObservationIgnored private var pickerIsOpen = false
    @ObservationIgnored private var castSyncRunning = false
    @ObservationIgnored private var castSyncAgain = false
    @ObservationIgnored private var remoteSession: UUID?
    @ObservationIgnored private var pickerActivity: ContinuousClock.Instant?
    @ObservationIgnored private let clock = ContinuousClock()
    /// A change of external playback this soon after the system picker was used is the person's own choice, not a loss.
    @ObservationIgnored var pickerWindow: Duration = .seconds(5)

    init(coordinator: OutputRouteCoordinator, applier: any LocalOutputApplying) { self.coordinator = coordinator; self.applier = applier }

    /// Binds the controller to the one playback owner, restores the preferred route and registers both engines. Plays nothing.
    func bind(to model: PlaybackModel) async {
        self.model = model
        model.outputs = self
        model.authority.onBarrier { [weak self] in await MainActor.run { self?.accountBarrier() } }
        await model.authority.setBeforeQuit { [weak self] in await self?.prepareForQuit() }
        observeRouteForNowPlaying()
        coordinator.start()
        await coordinator.register(MusicOutputEngine(model: model))
        await coordinator.register(LocalOutputEngine(model: model, controller: self))
        if let castDirectory, let castFactory {
            let driver = CastRouteDriver(coordinator: coordinator, factory: castFactory, local: NativeCastTransport(model: model), quitChoice: DefaultsCastQuitChoice(AppPreferences.store))
            driver.onLiveChange = { [weak self] _ in self?.updateCastBrowsing() }
            cast = driver
            // Observing a directory starts nothing: browsing (and the system's Local Network question) begins when the picker is opened.
            castObservation = castDirectory.observe { [weak self] in self?.castDevicesChanged() }
        }
    }
    func stop() { coordinator.stop(); airPlayDetection?.stop(); castObservation?.cancel(); castObservation = nil; castDirectory?.stopBrowsing() }

    // MARK: Cast (W39)

    private func castDevicesChanged() { if let castDirectory { coordinator.castDirectoryChanged(castDirectory.devices()) } }
    /// The picker was opened: only now are receivers looked for. Never at launch, in a test or in an isolated run's real network (there is none).
    func pickerOpened() { pickerIsOpen = true; updateCastBrowsing() }
    func pickerClosed() { pickerIsOpen = false; updateCastBrowsing() }
    private func updateCastBrowsing() {
        guard let castDirectory else { return }
        if pickerIsOpen || cast?.isLive == true { castDirectory.startBrowsing() } else { castDirectory.stopBrowsing() }
        castDevicesChanged()
    }
    /// After every session refresh: a live Cast session mirrors the native session's item and play/pause. Coalesced; a no-op when nothing is casting.
    func nativeRefreshed() {
        guard let cast, cast.isLive else { return }
        if castSyncRunning { castSyncAgain = true; return }
        castSyncRunning = true
        Task { @MainActor [weak self] in
            repeat { self?.castSyncAgain = false; await self?.cast?.nativeChanged() } while self?.castSyncAgain == true
            self?.castSyncRunning = false
        }
    }
    /// Quit (ROUTE10, WIN03): the receiver is stopped (or left, where a remembered choice allows it), bounded, before the session closes.
    func prepareForQuit() async { await cast?.prepareForQuit() }

    /// The engine the picker speaks for: the hidden player while it is the owner, otherwise the native one.
    var subject: OutputEngineKind { model?.music.map { !$0.isClosed } == true ? .youTubeMusic : .localMedia }

    /// A new native session: it learns the applier, the chosen device and the external-playback observer.
    func attach(_ session: PlaybackSession) async {
        pickerPlayer = session.routePickerPlayer
        // ROUTE08: a session that starts while a receiver renders is silent from its first instant (before any item is started), so two players are never audible.
        if coordinator.remote?.isCast == true { await session.setRemoteRendering(true) }
        session.setSeekObserver { [weak self] seconds in Task { @MainActor in await self?.cast?.nativeSeek(to: seconds) } }
        await session.configureOutput(applier: applier)
        _ = await session.setOutput(uid: coordinator.selection.deviceUID)
        localBackend = await session.outputBackend()
        await session.observeExternalPlayback { [weak self] active in Task { @MainActor in await self?.externalPlaybackChanged(active) } }
    }
    func sessionEnded() { pickerPlayer = nil; localBackend = .avPlayer }

    func pickerInteracted() { pickerActivity = clock.now }
    private func pickerRecently() -> Bool { pickerActivity.map { clock.now - $0 <= pickerWindow } ?? false }

    func externalPlaybackChanged(_ active: Bool) async {
        if active {
            guard remoteSession == nil else { return }
            remoteSession = await coordinator.remoteBegan()
        } else if let id = remoteSession {
            remoteSession = nil
            coordinator.remoteEvent(.ended(pickerRecently() ? .chosenByPerson : .receiverLost), session: id)
        }
    }
    /// Receiver-derived position: while external playback is active AVFoundation drives the player's clock from the receiver, and that reading (with
    /// the instant it was taken) is the only position the remote session shows.
    func observeNativePosition(_ seconds: Double) {
        guard let id = remoteSession else { return }
        coordinator.remoteEvent(.position(seconds, observedAt: clock.now), session: id)
    }

    // MARK: Gate

    /// Runs an audible action only when the route allows it (Play here after a loss; the timer note on a receiver). True when it ran.
    @discardableResult func gate(_ gate: AudibleGate, engine: OutputEngineKind, timerActive: Bool = false, _ body: @escaping @MainActor () async -> Void) async -> Bool {
        await coordinator.perform(gate, engine: engine, timerActive: timerActive, body)
    }
    /// A route loss is held for this engine (its audible route went away and no person has reconnected, played here or chosen another route).
    func lossPending(for kind: OutputEngineKind) -> Bool { coordinator.loss(for: kind) != nil }
    /// What the receiver reports while a remote route plays (nil: not a remote route; `.some(nil)`: no fresh receiver reading).
    func remoteReading() -> Double?? { coordinator.remote == nil ? nil : .some(coordinator.remotePosition()) }
    /// W23: the route Now Playing carries with the item. The hidden player follows the Mac's default output; the native engine is on its device,
    /// or on a receiver while external playback runs (a receiver has no Mac output, so only its kind is known).
    func nowPlayingRoute(youTubeMusic: Bool) -> NowPlayingRoute? {
        if !youTubeMusic, let remote = coordinator.remote {
            if remote.isCast { return NowPlayingRoute(kind: .cast, name: cast?.liveDeviceName) }
            return NowPlayingRoute(kind: .airPlay)
        }
        let kind: OutputEngineKind = youTubeMusic ? .youTubeMusic : .localMedia
        return NowPlayingRoute(kind: .thisMac, name: coordinator.currentOutput(for: kind)?.name)
    }
    /// Republishes Now Playing when the route changes, so the published route is never the previous one.
    private func observeRouteForNowPlaying() {
        withObservationTracking {
            _ = coordinator.generation; _ = coordinator.remote?.state; _ = coordinator.snapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.model?.routeChangedForNowPlaying(); self?.observeRouteForNowPlaying() }
        }
    }
    /// An account barrier: a held Play here or timer prompt does not survive it.
    func accountBarrier() {
        coordinator.discardHeld()
        // A Cast session belongs to the account's session that started it (DATA03): it ends at the barrier, and the receiver is stopped.
        if coordinator.remote?.isCast == true { Task { @MainActor in await coordinator.leaveCast() } }
    }
}

extension PlaybackModel {
    /// The native session plays or resumes: through the output gate, so Play here and the receiver-timer note come first.
    func nativeStart(_ body: @escaping @MainActor () async -> Void) async {
        if let outputs { await outputs.gate(.start, engine: .localMedia, timerActive: state?.timer != nil, body) } else { await body() }
    }
    /// Play/Pause for the native session: only the starting half is gated.
    func nativePlayPause() async {
        if state?.playback.intent == .play { await act { try await $0.playPause() } }
        else { await nativeStart { await self.act { try await $0.playPause() } } }
    }
    /// The sleep timer is being turned on for the native session.
    func nativeEnableTimer(_ body: @escaping @MainActor () async -> Void) async {
        if let outputs { await outputs.gate(.enableTimer, engine: .localMedia, body) } else { await body() }
    }
}
