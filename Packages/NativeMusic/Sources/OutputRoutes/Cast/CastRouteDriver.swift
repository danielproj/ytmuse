import Foundation
import Observation

// W39 (ROUTE05, ROUTE07-ROUTE10, DATA03). Joins the app's native playback session to a Cast receiver, inside the W22 route model (no second model).
//
// The native session stays the owner of the queue, the intent and the transport commands (PLAY01). While a receiver renders, the session's engine is a
// SILENT clock: every output stage is muted (`setSilenced`, confirmed before the receiver is asked to play), so nothing it decodes can be heard on the
// Mac and no two players are audible at once (ROUTE08). The receiver is the only thing shown for position, state and capabilities (ROUTE09): readings
// are handed to the coordinator exactly as reported and never advanced with a local timer.
//
// Reconciliation: whichever side changed play/pause last wins. A command this driver sent is "expected"; the receiver's matching report confirms it and
// a contradicting report inside the settle window is a late echo of an earlier command and is ignored. Outside the window the receiver wins (a phone or
// the TV remote paused it), and the local session is told. A report that names an earlier load generation is dropped by the session.

public enum CastNotCastable: Equatable, Sendable {
    case youTubeMusic
    case keptDownload
    case noFile
    case unsupportedType(String)
}
public enum CastLocalSource: Equatable, Sendable {
    /// A file on the Mac, served to the receiver by the scoped relay.
    case file(URL)
    /// A public https address the receiver fetches itself (never a Google or YouTube address; see `CastDirectSourcePolicy`).
    case direct(URL)
    case notCastable(CastNotCastable)
}
/// The item the native session is on, as the driver needs to see it.
public struct CastLocalItem: Equatable, Sendable {
    public let key: String
    public let source: CastLocalSource
    public let title: String
    public let artist: String?
    public let duration: Double?
    public init(key: String, source: CastLocalSource, title: String, artist: String? = nil, duration: Double? = nil) { self.key = key; self.source = source; self.title = title; self.artist = artist; self.duration = duration }
}
public struct CastLocalState: Equatable, Sendable {
    public let item: CastLocalItem?
    /// The session's intent is to play.
    public let playing: Bool
    /// The session's own position. Only used to start a receiver at the right place; never shown while a receiver renders.
    public let position: Double
    public init(item: CastLocalItem?, playing: Bool, position: Double) { self.item = item; self.playing = playing; self.position = position }
}

/// What the driver needs of the native playback session. The app implements it over `PlaybackSession`; tests supply a recorder.
@MainActor public protocol CastLocalTransport: AnyObject {
    func localState() async -> CastLocalState
    /// Mutes (or restores) every output stage of the local engine; true only when it is confirmed.
    func setSilenced(_ on: Bool) async -> Bool
    func pauseLocal() async
    func resumeLocal() async
    func seekLocal(_ seconds: Double) async
}

/// TH4 (rework of M1): what the app's volume slider shows and drives WHILE an owned or local item is cast through the relay. It is the RECEIVER's level, as the
/// receiver reports it, and it is separate from the Mac's own app gain (which is neither read nor changed while casting). nil: not casting such an item, so
/// the slider is the Mac's.
public struct CastVolumeControl: Equatable, Sendable {
    public enum Unavailable: Equatable, Sendable {
        /// The receiver has not yet said what its level or its abilities are: nothing is sent until it has.
        case notReported
        /// The receiver says its volume is fixed (`controlType: "fixed"`).
        case fixed
        /// The receiver's media status says it cannot set the stream volume.
        case unsupported
    }
    public let level: Double
    public let unavailable: Unavailable?
    public var isAdjustable: Bool { unavailable == nil }
    public init(level: Double, unavailable: Unavailable?) { self.level = level; self.unavailable = unavailable }
}

public enum CastNotice: Equatable, Sendable {
    case itemNotCastable(CastNotCastable)
    case receiverCouldNotPlay
    case connectionFailed
    case relayUnavailable
    case networkNotAllowed
}

public struct CastDriverConfiguration: Sendable {
    public var session = CastSessionConfiguration()
    /// A report that contradicts a command sent less than this long ago is a late echo of an earlier command.
    public var settleWindow: Duration = .seconds(3)
    /// When the next item starts while the receiver is within this long of the end of the previous one, the receiver is let finish it.
    public var switchGrace: Duration = .seconds(4)
    public var shutdownTimeout: Duration = .milliseconds(1_500)
    public init() {}
}

@MainActor @Observable public final class CastRouteDriver {
    public private(set) var notice: CastNotice?
    public private(set) var isLive = false
    /// The route's receiver name while live.
    public private(set) var liveDeviceName: String?
    @ObservationIgnored public private(set) var ignoredStale = 0
    /// Told when a session becomes live or ends, so the app can keep looking for receivers only while it needs to.
    @ObservationIgnored public var onLiveChange: (@MainActor (Bool) -> Void)?
    /// TH4: the slider while an owned or local item is cast (see `CastVolumeControl`); nil otherwise.
    public private(set) var volumeControl: CastVolumeControl?
    /// The newest level the slider asked for, not yet sent (a burst sends the newest). Written synchronously on the main actor by `requestVolume` and read and
    /// cleared synchronously by the send loop, so which level is newest never depends on the order of tasks. (TH5: a generation counter used to be written
    /// beside it and never read; it decided nothing and is gone.)
    @ObservationIgnored private var pendingVolume: Double?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    /// What the person asked for, shown until the receiver next reports its own level with nothing left to send.
    @ObservationIgnored private var requestedLevel: Double?
    private func setLive(_ value: Bool, name: String?) {
        let changed = isLive != value
        isLive = value; liveDeviceName = name
        if !value { pendingVolume = nil; requestedLevel = nil }
        refreshVolumeControl()
        if changed { onLiveChange?(value) }
    }

    @ObservationIgnored private let coordinator: OutputRouteCoordinator
    @ObservationIgnored private let factory: any CastChannelFactory
    @ObservationIgnored private let local: any CastLocalTransport
    @ObservationIgnored private let relayFactory: @MainActor (_ bindAddress: String, _ receiverAddress: String?) throws -> CastRelayServer
    @ObservationIgnored private let quitChoice: any CastQuitChoiceStoring
    @ObservationIgnored private let configuration: CastDriverConfiguration
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant

    private struct Live {
        let session: CastSession
        let remoteID: UUID
        var relay: CastRelayServer?
        var loadedKey: String?
        var lastLocalPlaying: Bool
        var expected: Bool?
        var expectedAt: ContinuousClock.Instant
        var lastPosition: Double?
        var duration: Double?
        var continuation: CastContinuation = .macRelays
        var pendingSwitch: Task<Void, Never>?
        var ending = false
        /// The receiver's own volume reports (RECEIVER_STATUS) and abilities (MEDIA_STATUS `supportedMediaCommands`), as reported.
        var reportedLevel: Double?
        var fixedVolume = false
        var streamVolume: Bool?
    }
    @ObservationIgnored private var live: Live?
    /// Where the receiver last said it was, for the item it was playing, kept across a loss so Reconnect and Play here continue from there.
    @ObservationIgnored private var resumePoint: (key: String, seconds: Double)?

    public init(coordinator: OutputRouteCoordinator, factory: any CastChannelFactory, local: any CastLocalTransport, quitChoice: any CastQuitChoiceStoring = MemoryCastQuitChoice(),
                configuration: CastDriverConfiguration = CastDriverConfiguration(), now: (@MainActor () -> ContinuousClock.Instant)? = nil,
                relayFactory: (@MainActor (String, String?) throws -> CastRelayServer)? = nil) {
        self.coordinator = coordinator; self.factory = factory; self.local = local; self.quitChoice = quitChoice; self.configuration = configuration
        self.now = now ?? { ContinuousClock.now }
        self.relayFactory = relayFactory ?? { try CastRelayServer(bindAddress: $0, receiverAddress: $1) }
        coordinator.castConnect = { [weak self] id, isCurrent in await self?.connect(id, isCurrent: isCurrent) ?? false }
        coordinator.castEnd = { [weak self] in await self?.end() }
    }

    // MARK: Connecting (ROUTE05, ROUTE08)

    /// Connects, launches the Default Media Receiver, silences the local engine (confirmed) and loads the current item. False leaves everything as it was.
    func connect(_ id: CastDeviceID, isCurrent: @MainActor () -> Bool) async -> Bool {
        let local = self.local
        guard let device = coordinator.castDevices.first(where: { $0.id == id }) else { return false }
        notice = nil
        if live != nil { await end() }
        let reconnecting = coordinator.loss(for: .localMedia)?.lostRoute.castDeviceID == id
        let session = CastSession(device: device, factory: factory, configuration: configuration.session, now: now)
        do { try await session.connect() }
        catch {
            notice = (error as? CastError) == .networkNotPermitted ? .networkNotAllowed : .connectionFailed
            return false
        }
        guard isCurrent() else { await session.shutdown(.stopReceiver); return false }
        let state = await local.localState()
        if let item = state.item, case .notCastable(let reason) = item.source {
            notice = .itemNotCastable(reason)
            await session.shutdown(.stopReceiver); return false
        }
        // ROUTE08: the local engine is silenced and confirmed before the receiver is asked to play anything.
        // If silence cannot be confirmed the receiver is never asked to play, and whatever the attempt changed on the local engine is put back.
        guard await local.setSilenced(true) else { _ = await local.setSilenced(false); notice = .connectionFailed; await session.shutdown(.stopReceiver); return false }
        guard isCurrent(), let remoteID = coordinator.castBegan(device: id) else { _ = await local.setSilenced(false); await session.shutdown(.stopReceiver); return false }
        let sessionID = session.id
        session.onEvent = { [weak self] event in self?.handle(event, from: sessionID) }
        live = Live(session: session, remoteID: remoteID, lastLocalPlaying: state.playing, expectedAt: now())
        setLive(true, name: device.friendlyName)
        try? await session.requestReceiverStatus()   // the receiver's own level, so the slider can start where the speaker is
        coordinator.remoteEvent(.state(.connecting), session: remoteID)
        guard let item = state.item else { return true }   // nothing is queued yet: the first item is loaded when playback starts
        let start = reconnecting && resumePoint?.key == item.key ? (resumePoint?.seconds ?? state.position) : state.position
        // A reconnect never starts playback (ROUTE03); a route chosen while playing continues, with the receiver rendering.
        let result = await load(item, startAt: start, autoplay: reconnecting ? false : state.playing)
        guard result == .loaded, isCurrent() else { await abandonFailedConnect(); return false }
        // Reconnecting never plays: if the session still says "play" (the loss pause had not landed), it is paused to agree with the receiver, which was loaded paused.
        if reconnecting, state.playing { live?.lastLocalPlaying = false; await local.pauseLocal() }
        return true
    }
    private func abandonFailedConnect() async {
        guard let current = live else { return }
        live = nil; setLive(false, name: nil)
        await teardown(current, mode: .stopReceiver)
        _ = await local.setSilenced(false)
        coordinator.castAbandoned(session: current.remoteID)
    }

    private enum LoadResult { case loaded, failed, superseded }
    /// Loads `item` on the receiver at `startAt`. The relay is created on the first item that needs it, bound to the Mac's address toward the receiver.
    /// The key is recorded before anything awaits, so a second notification for the same item cannot start a second load.
    private func load(_ item: CastLocalItem, startAt: Double, autoplay: Bool) async -> LoadResult {
        guard live != nil, let sessionID = live?.session.id else { return .failed }
        live?.loadedKey = item.key; live?.lastLocalPlaying = autoplay; live?.expected = autoplay; live?.expectedAt = now()
        let url: URL, contentType: String, continuation: CastContinuation
        switch item.source {
        case .notCastable(let reason): notice = .itemNotCastable(reason); return .failed
        case .direct(let address):
            do { try CastDirectSourcePolicy.validate(address) } catch { notice = .itemNotCastable(.noFile); return .failed }
            url = address; contentType = "audio/mpeg"; continuation = .receiverIndependent
        case .file(let file):
            do {
                if live?.relay == nil {
                    guard let bind = live?.session.localAddress else { throw CastError.relayUnavailable("no local address") }
                    let relay = try relayFactory(bind, live?.session.remoteAddress)
                    _ = try await relay.start()
                    guard live?.session.id == sessionID else { relay.stop(); return .superseded }
                    live?.relay = relay
                }
                guard let relay = live?.relay else { throw CastError.relayUnavailable("no relay") }
                url = try relay.url(serving: file)
                contentType = CastRelayCore.types[file.pathExtension.lowercased()] ?? "audio/mpeg"
                continuation = .macRelays
            } catch {
                if case CastRelayError.bindRefused = error { notice = .networkNotAllowed } else { notice = .relayUnavailable }
                live?.loadedKey = nil; refreshVolumeControl()
                return .failed
            }
        }
        live?.continuation = continuation; refreshVolumeControl()
        guard let session = live?.session, session.id == sessionID else { return .superseded }
        do {
            _ = try await session.load(CastMessages.Load(url: url.absoluteString, contentType: contentType, title: item.title, artist: item.artist,
                                                                      duration: item.duration, startAt: startAt, autoplay: autoplay))
            guard live?.session.id == sessionID else { return .superseded }
            return .loaded
        } catch CastError.superseded {
            return .superseded
        } catch {
            guard live?.session.id == sessionID else { return .superseded }
            live?.loadedKey = nil; refreshVolumeControl()
            notice = .receiverCouldNotPlay
            return .failed
        }
    }

    // MARK: The native session changed (called after every session refresh; cheap and idempotent)

    public func nativeChanged() async {
        let local = self.local
        guard var current = live, !current.ending else { return }
        let state = await local.localState()
        guard live?.session.id == current.session.id else { return }
        guard state.item?.key == current.loadedKey else { await itemChanged(state); return }
        if state.playing != current.lastLocalPlaying {
            current.lastLocalPlaying = state.playing; current.expected = state.playing; current.expectedAt = now()
            live = current
            do { if state.playing { try await current.session.play() } else { try await current.session.pause() } } catch { }
        }
    }
    // MARK: Volume: the slider drives the receiver's own level (TH4)

    /// Recomputes what the slider shows. Called wherever its inputs change: going live or ending, an item loaded or dropped, a receiver report.
    private func refreshVolumeControl() {
        var value: CastVolumeControl?
        if let current = live, !current.ending, current.loadedKey != nil, current.continuation == .macRelays {
            let shown = requestedLevel ?? current.reportedLevel
            let why: CastVolumeControl.Unavailable? = current.fixedVolume ? .fixed : current.streamVolume == false ? .unsupported : (shown == nil || current.streamVolume == nil) ? .notReported : nil
            value = CastVolumeControl(level: shown ?? 0, unavailable: why)
        }
        if volumeControl != value { volumeControl = value }
    }
    /// The slider moved while an owned or local item is cast through the relay. Nothing is sent unless the receiver has reported its level, is not fixed and can
    /// set the stream volume (`volumeControl.isAdjustable`); a non-finite level is ignored; the level is clamped to 0...1; the newest level wins (it is handed
    /// over here, synchronously, so task order cannot decide). The Mac's own volume is never read or changed. Connecting sets nothing.
    public func requestVolume(_ level: Double) {
        guard level.isFinite, let control = volumeControl, control.isAdjustable else { return }
        let clamped = min(1, max(0, level))
        pendingVolume = clamped; requestedLevel = clamped
        refreshVolumeControl()
        if volumeTask == nil { volumeTask = Task { @MainActor [weak self] in await self?.sendPendingVolume() } }
    }
    private func sendPendingVolume() async {
        while let next = pendingVolume {
            pendingVolume = nil
            guard let session = live?.session, live?.ending == false else { break }
            try? await session.setVolume(level: next)
        }
        volumeTask = nil
    }
    /// Waits until every level handed to `requestVolume` has been sent (for tests).
    public func volumeSettled() async { await volumeTask?.value }
    /// A person's seek (or the item restarting): the receiver is sought to the same place. Positions shown still come from the receiver's next report.
    public func nativeSeek(to seconds: Double) async {
        guard let current = live, !current.ending, current.loadedKey != nil else { return }
        try? await current.session.seek(to: seconds)
    }

    private func itemChanged(_ state: CastLocalState) async {
        guard var current = live else { return }
        guard let item = state.item else {
            // The queue ran out. A receiver within a few seconds of the end of the last item is let finish it (the silent local clock is slightly ahead);
            // anything else is stopped so nothing keeps playing for an empty queue.
            current.loadedKey = nil; live = current; refreshVolumeControl()
            if let position = current.lastPosition, let duration = current.duration, duration - position <= Double(configuration.switchGrace.components.seconds) { return }
            try? await current.session.stopMedia(); return
        }
        if case .notCastable(let reason) = item.source {
            // The queue moved to something that cannot be cast: the route ends honestly (local paused, audible again only by a Play), not silently.
            notice = .itemNotCastable(reason)
            await coordinator.leaveCast(); return
        }
        current.pendingSwitch?.cancel()
        if let position = current.lastPosition, let duration = current.duration, duration - position <= Double(configuration.switchGrace.components.seconds), current.loadedKey != nil {
            // The silent local clock reached the end first; the receiver is let finish the previous item, then the next one is loaded.
            let wait = max(0.5, duration - position + 2)
            current.loadedKey = nil   // the previous item is over as far as the queue is concerned
            let sessionID = current.session.id
            current.pendingSwitch = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, self?.live?.session.id == sessionID else { return }
                await self?.loadCurrentAfterSwitch()
            }
            live = current; refreshVolumeControl()
            return
        }
        live = current
        if await load(item, startAt: state.position, autoplay: state.playing) == .failed { await coordinator.leaveCast() }
    }
    private func loadCurrentAfterSwitch() async {
        let local = self.local
        guard live != nil else { return }
        live?.pendingSwitch = nil
        let state = await local.localState()
        guard let item = state.item else { return }
        if case .notCastable(let reason) = item.source { notice = .itemNotCastable(reason); await coordinator.leaveCast(); return }
        guard live?.loadedKey != item.key else { return }
        if await load(item, startAt: state.position, autoplay: state.playing) == .failed { await coordinator.leaveCast() }
    }

    // MARK: What the receiver says (ROUTE09, DATA03)

    private func handle(_ event: CastSessionEvent, from sessionID: UUID) {
        guard let current = live, current.session.id == sessionID else { ignoredStale += 1; return }
        switch event {
        case .ready: break
        case .media(let report):
            guard report.generation == current.session.loadGeneration else { ignoredStale += 1; return }
            if let position = report.position { live?.lastPosition = position; coordinator.remoteEvent(.position(position, observedAt: report.observedAt), session: current.remoteID) }
            if let duration = report.duration { live?.duration = duration }
            if let capabilities = report.capabilities { coordinator.remoteEvent(.capabilities(capabilities), session: current.remoteID); live?.streamVolume = capabilities.canSetStreamVolume; refreshVolumeControl() }
            coordinator.remoteEvent(.state(Self.remoteState(report.state)), session: current.remoteID)
            Task { @MainActor [weak self] in await self?.reconcile(report, session: sessionID) }
        case .volume(let level, let muted, let fixed):
            coordinator.remoteEvent(.volume(ReceiverVolume(level: level, muted: muted, fixed: fixed)), session: current.remoteID)
            if let level, level.isFinite { live?.reportedLevel = min(1, max(0, level)) }
            live?.fixedVolume = fixed
            if pendingVolume == nil, volumeTask == nil { requestedLevel = nil }   // nothing left to send: the receiver's word is what is shown
            refreshVolumeControl()
        case .finished(let generation):
            guard generation == current.session.loadGeneration else { ignoredStale += 1; return }
            if current.pendingSwitch != nil {
                current.pendingSwitch?.cancel(); live?.pendingSwitch = nil
                Task { @MainActor [weak self] in await self?.loadCurrentAfterSwitch() }
            }
        case .mediaFailed(let generation):
            guard generation == current.session.loadGeneration else { ignoredStale += 1; return }
            notice = .receiverCouldNotPlay
            Task { @MainActor [weak self] in await self?.coordinator.leaveCast() }
        case .commandRefused: break
        case .lost:
            Task { @MainActor [weak self] in await self?.receiverLost(session: sessionID) }
        }
    }
    static func remoteState(_ state: CastPlayerState) -> RemoteState {
        switch state { case .playing: .playing; case .paused: .paused; case .buffering, .loading: .connecting; case .idle: .stopped }
    }
    private func reconcile(_ report: CastMediaReport, session sessionID: UUID) async {
        let local = self.local
        guard var current = live, current.session.id == sessionID, report.generation == current.session.loadGeneration else { return }
        let receiverPlaying = report.state == .playing || report.state == .buffering || report.state == .loading
        if let expected = current.expected {
            if expected == receiverPlaying { current.expected = nil; live = current; return }                       // confirmed
            if now() - current.expectedAt < configuration.settleWindow { return }                                      // a late echo of an earlier command
            current.expected = nil; live = current
        }
        guard report.state != .idle else { return }
        let state = await local.localState()
        guard live?.session.id == sessionID, state.playing != receiverPlaying else { return }
        // The receiver changed it (another app, a remote): the local session follows. Its engine is silent, so this is never audible on the Mac.
        live?.lastLocalPlaying = receiverPlaying
        if receiverPlaying { await local.resumeLocal() } else { await local.pauseLocal() }
    }

    // MARK: Loss (ROUTE03, ROUTE09)

    private func receiverLost(session sessionID: UUID) async {
        guard let current = live, current.session.id == sessionID, !current.ending else { return }
        live = nil; setLive(false, name: nil)
        current.pendingSwitch?.cancel()
        // The coordinator records the loss and pauses the local engine in this turn; the engine is made audible again only after that pause has settled,
        // and it stays paused: a Play now needs the person's confirmation (Play here).
        if let key = current.loadedKey, let seconds = current.lastPosition { resumePoint = (key, seconds) }
        coordinator.remoteEvent(.ended(.receiverLost), session: current.remoteID)
        await coordinator.settled()
        // Play here continues from where the receiver was, not from where the silent local clock happens to be.
        if let seconds = current.lastPosition { await local.seekLocal(seconds) }
        _ = await local.setSilenced(false)
        await teardown(current, mode: .stopReceiver)
    }

    // MARK: Ending by choice, and Quit (ROUTE08, ROUTE10, WIN03)

    /// The person left the Cast route. The receiver is stopped; the local session is put at the receiver's last reading, paused, and made audible again
    /// (so a later Play is an ordinary Play on the Mac's output). Nothing starts on the Mac by this alone.
    func end() async {
        guard var current = live else { return }
        current.ending = true; current.pendingSwitch?.cancel(); live = nil; setLive(false, name: nil)
        let position = coordinator.remotePosition() ?? current.lastPosition
        await local.pauseLocal()
        if let position { await local.seekLocal(position) }
        _ = await local.setSilenced(false)
        await teardown(current, mode: .stopReceiver)
    }

    /// What Quit does now. `.ask` is never produced while only relayed media can be cast.
    public var quitPlan: CastQuitPlan {
        guard let current = live else { return .notCasting }
        return CastQuitPolicy.plan(isCasting: true, continuation: current.continuation, remembered: quitChoice.load())
    }
    public func rememberQuitChoice(_ choice: CastQuitChoice?) { quitChoice.save(choice) }

    /// Carries out the Quit plan with a bound, so a receiver that does not answer cannot hold the application open.
    public func prepareForQuit() async {
        guard let current = live else { return }
        let plan = quitPlan
        live = nil; setLive(false, name: nil)
        current.pendingSwitch?.cancel()
        let mode: CastShutdown = plan == .leave ? .leave : .stopReceiver
        let timeout = configuration.shutdownTimeout
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            Task { @MainActor in
                await self.teardown(current, mode: mode)
                if !resumed { resumed = true; continuation.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !resumed { resumed = true; continuation.resume() }
            }
        }
    }

    private func teardown(_ current: Live, mode: CastShutdown) async {
        await current.session.shutdown(mode)
        current.relay?.stop()
    }
}
