import Foundation
import Observation

// W22 (ROUTE01-ROUTE04, ROUTE08, ROUTE09, ROUTE11, PLAY17, DATA03). The unified output control: one object that knows the outputs, the person's choice,
// what each engine can do with it, and what happens when a route goes away. It never plays, pauses or routes by itself except through the
// `OutputEngine` seam, and it never touches the system: no default-output change, no volume, no AirPlay or Bluetooth state.

/// What the coordinator needs of an engine. One implementation per engine behind the single playback owner (PLAY01); tests supply fakes.
@MainActor public protocol OutputEngine: AnyObject {
    var kind: OutputEngineKind { get }
    var backend: OutputBackend { get }
    /// Sound is playing or wanted: playing, buffering, preparing toward play, or seeking while play is wanted.
    var isAudibleOrWanted: Bool { get }
    /// Pauses at once, records a route-loss pause (not a person's pause) and returns whether the engine confirmed it.
    func pauseForRouteLoss() async -> Bool
    /// Silences the engine so it cannot make sound until it is started again; true only when that is confirmed.
    func stopForHandoff() async -> Bool
    /// Points the engine at an output device by stable UID (nil: follow the system default). False when it cannot.
    func apply(output uid: String?) async -> Bool
}

public enum SelectionOutcome: Equatable, Sendable {
    case selected
    /// The route is not a live output (a device that is gone is never replaced by a similar one).
    case unavailable
    /// The engine cannot be pointed at a route; the picker states why instead of offering it.
    case unsupported
    case failed
    /// A newer choice or route change overtook this one; its late completion changed nothing.
    case superseded
}
public enum HandoffOutcome: Equatable, Sendable { case ready, refused, superseded }
public enum AudibleGate: Sendable, Equatable { case start, enableTimer }

public struct PlayHerePrompt: Equatable, Sendable {
    public let id: UUID
    /// The engine whose route was lost (the one that asked to start).
    public let engine: OutputEngineKind
    /// Where the sound would come out if confirmed (display name only; nothing keyed on it).
    public let output: String?
    public let reason: RouteLossReason
    public let canReconnect: Bool
}
public struct TimerPrompt: Equatable, Sendable { public let id: UUID }
public enum OutputPrompt: Equatable, Sendable, Identifiable {
    case playHere(PlayHerePrompt), timer(TimerPrompt)
    public var id: UUID { switch self { case .playHere(let prompt): prompt.id; case .timer(let prompt): prompt.id } }
}

@MainActor @Observable public final class OutputRouteCoordinator {
    public enum LaunchNotice: Equatable, Sendable { case preferredUnavailable }

    public private(set) var snapshot = OutputSnapshot.empty
    /// What the person chose this session (the system default until they choose; ROUTE02).
    public private(set) var selection = OutputRouteID.systemDefault
    /// The persisted choice: a stable identifier, never a name.
    public private(set) var preferred: OutputRouteID?
    public private(set) var launchNotice: LaunchNotice?
    /// Route losses, one per ENGINE: each engine is judged against the route it is actually audible on (the hidden player: the system default;
    /// the local engine: its chosen device, else the default).
    public private(set) var losses: [OutputEngineKind: RouteLoss] = [:]
    public private(set) var remote: RemoteSession?
    public private(set) var prompt: OutputPrompt?
    /// Bumped by every selection, handoff, loss and route change; a completion carrying an older value changed nothing.
    public private(set) var generation: UInt64 = 0
    public private(set) var activeEngine: OutputEngineKind?
    /// W39: the Cast receivers seen on the network right now (empty until the person opens the picker and browsing starts).
    public private(set) var castDevices: [CastDevice] = []
    /// The app side of Cast, installed by the composition (nil: this process offers no Cast, as in most tests). `connect` connects, launches, silences the
    /// local engine, loads the current item and calls `castBegan`; it returns whether the route is now live. `isCurrent` turns false if a newer choice overtook it.
    @ObservationIgnored public var castConnect: (@MainActor (CastDeviceID, @MainActor () -> Bool) async -> Bool)?
    /// Ends the live Cast session the way a person chose (the receiver is stopped, the local engine is paused and made audible again).
    @ObservationIgnored public var castEnd: (@MainActor () async -> Void)?
    /// Callbacks and events that were dropped because they belonged to an earlier route, session or generation (diagnostics and tests).
    @ObservationIgnored public private(set) var ignoredStale = 0

    @ObservationIgnored private let directory: any OutputDirectory
    @ObservationIgnored private let store: any PreferredRouteStoring
    @ObservationIgnored private let clock: ContinuousClock
    @ObservationIgnored private var engines: [OutputEngineKind: any OutputEngine] = [:]
    @ObservationIgnored private var observation: OutputObservation?
    /// What each engine's sound leaves through, as last known.
    @ObservationIgnored private var audible: [OutputEngineKind: RouteIdentity] = [:]
    /// A device an engine's sound moved away from a moment ago (the default changed first); if it then disappears inside the window, that is a loss.
    @ObservationIgnored private var departed: [OutputEngineKind: (identity: RouteIdentity, at: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    /// How long after the default left a device its disappearance still counts as the loss that caused the move (the system announces the default
    /// change and the device's departure as separate notifications, in either order).
    @ObservationIgnored public var departureWindow: Duration = .milliseconds(800)
    @ObservationIgnored private var selectionTicket: UInt64 = 0
    /// The Mac output choice that was in force when a Cast session began; restored when the session ends without the person choosing something else.
    @ObservationIgnored private var selectionBeforeCast = OutputRouteID.systemDefault
    @ObservationIgnored private var handoffTicket: UInt64 = 0
    /// Engines that have made sound on their current route in this session.
    @ObservationIgnored private var soundedOn: Set<OutputEngineKind> = []
    @ObservationIgnored private var acknowledgedTimerSessions: Set<UUID> = []
    @ObservationIgnored private var pending: (id: UUID, generation: UInt64, body: @MainActor () async -> Void)?
    @ObservationIgnored private var lossPauses: [Task<Void, Never>] = []

    public init(directory: any OutputDirectory, store: any PreferredRouteStoring, clock: ContinuousClock = ContinuousClock(), now: (@MainActor () -> ContinuousClock.Instant)? = nil) {
        self.directory = directory; self.store = store; self.clock = clock; self.now = now ?? { ContinuousClock.now }
    }

    // MARK: Lifecycle

    /// Reads the outputs, restores the preferred route if it is still a live output, and starts listening. Nothing plays and nothing is
    /// routed by this call except re-pointing a registered local engine at the preferred device (ROUTE02).
    public func start() {
        snapshot = directory.snapshot()
        preferred = store.load()
        selection = .systemDefault; launchNotice = nil
        if let preferred, !preferred.isSystemDefault, !preferred.isCast {
            if let uid = preferred.deviceUID, snapshot.device(uid: uid) != nil { selection = preferred }
            else { launchNotice = .preferredUnavailable }   // stays on the system output; the missing device is never replaced by a similar one
        }
        // A remembered Cast receiver is never connected to at launch: nothing is browsed or opened until the person opens the picker, and nothing plays
        // there without their choice (ROUTE02). It is only marked as the remembered route when the receiver shows up.
        for kind in [OutputEngineKind.youTubeMusic, .localMedia] { audible[kind] = identity(for: kind) }
        observation?.cancel()
        observation = directory.observe { [weak self] in self?.directoryChanged() }
    }
    public func stop() { observation?.cancel(); observation = nil; for task in lossPauses { task.cancel() }; lossPauses.removeAll() }

    /// Adds an engine. A local engine is pointed at the restored preferred device at once; the hidden player is never pointed anywhere.
    public func register(_ engine: any OutputEngine) async {
        engines[engine.kind] = engine
        guard engine.kind == .localMedia, let uid = selection.deviceUID else { return }
        _ = await engine.apply(output: uid)
    }
    public func unregister(_ kind: OutputEngineKind) { engines[kind] = nil; if activeEngine == kind { activeEngine = nil } }

    // MARK: What the person sees (ROUTE01)

    /// The output ONE engine's sound leaves through now. The hidden player has no choice: it follows the Mac's default output. The local engine plays on
    /// its chosen device while that is live, otherwise on the default. (A remote receiver has no Mac output at all.)
    public func currentOutput(for kind: OutputEngineKind) -> OutputDevice? {
        if kind == .localMedia, backend(for: kind) != .hiddenWebPlayer {
            if remote != nil { return nil }
            if let uid = selection.deviceUID, let device = snapshot.device(uid: uid) { return device }
        }
        return snapshot.defaultDevice
    }
    private func identity(for kind: OutputEngineKind) -> RouteIdentity? { currentOutput(for: kind)?.identity }
    /// Whether the local engine is pointed at its own device rather than following the system default (for the wake check's comparison).
    public func isPinned(_ kind: OutputEngineKind) -> Bool { kind == .localMedia && remote == nil && selection.deviceUID.flatMap { snapshot.device(uid: $0) } != nil }
    /// The route an engine's sound leaves through, for the W21 wake check: one route model for the loss policy and the wake.
    public func audibleRoute(for kind: OutputEngineKind) -> (identity: RouteIdentity?, pinned: Bool) { (identity(for: kind), isPinned(kind)) }
    public func mode(for kind: OutputEngineKind) -> RouteMode {
        if kind == .localMedia, let remote { return remote.isCast ? .castReceiver : .externalPlayback }
        return .systemOutput(currentOutput(for: kind)?.transport ?? .other)
    }
    public func backend(for kind: OutputEngineKind) -> OutputBackend { engines[kind]?.backend ?? (kind == .youTubeMusic ? .hiddenWebPlayer : .avPlayer) }
    public func capabilities(for kind: OutputEngineKind) -> RouteCapabilities { .resolve(engine: kind, backend: backend(for: kind), mode: mode(for: kind)) }
    /// Whether the system AirPlay picker can reach this engine (a local `AVPlayer` only).
    public func offersSystemPicker(for kind: OutputEngineKind) -> Bool { RouteCapabilities.offersSystemPicker(engine: kind, backend: backend(for: kind)) }
    public func loss(for kind: OutputEngineKind) -> RouteLoss? { losses[kind] }
    /// Any engine's loss (the local engine's first), for callers that do not care which engine it was.
    public var loss: RouteLoss? { losses[.localMedia] ?? losses[.youTubeMusic] }
    public func lossCanReconnect(for kind: OutputEngineKind) -> Bool { losses[kind]?.canReconnect(in: snapshot, casts: castDevices) ?? false }

    /// The routes the picker lists: the system output first, then each live output (software loopback devices are left out unless in use). The
    /// current row is the one THIS engine really plays on: the hidden player is always on the system output, whatever the local engine chose.
    public func entries(for kind: OutputEngineKind) -> [OutputRouteEntry] {
        let backend = backend(for: kind)
        let follows = kind == .youTubeMusic || backend == .hiddenWebPlayer
        let chosen: OutputRouteID = follows ? .systemDefault : selection
        let systemTransport = snapshot.defaultDevice?.transport ?? .other
        var result = [OutputRouteEntry(id: .systemDefault, name: snapshot.defaultDevice?.name ?? "", transport: snapshot.defaultDevice?.transport, isCurrent: chosen.isSystemDefault,
                                       connection: snapshot.defaultDevice == nil ? .unavailable : .connected,
                                       capabilities: .resolve(engine: kind, backend: backend, mode: kind == .localMedia && remote != nil ? .externalPlayback : .systemOutput(systemTransport)), isSystemOutput: true)]
        for device in snapshot.devices where ![.virtual, .aggregate].contains(device.transport) || device.uid == chosen.deviceUID || device.uid == snapshot.defaultUID {
            result.append(OutputRouteEntry(id: device.id, name: device.name, transport: device.transport, isCurrent: chosen == device.id, connection: .connected,
                                           capabilities: .resolve(engine: kind, backend: backend, mode: .systemOutput(device.transport)), isSystemOutput: device.uid == snapshot.defaultUID))
        }
        // W39: Cast receivers, by their own identifier. For the hidden YouTube Music player the rows are listed only to state, in their limits, that it cannot be cast.
        let liveCast: CastDeviceID? = { if case .cast(let id)? = remote?.kind { id } else { nil } }()
        for device in castDevices where device.playsAudio {
            let current = !follows && liveCast == device.id
            result.append(OutputRouteEntry(id: device.routeID, name: device.friendlyName, transport: nil, isCurrent: current, connection: .connected,
                                           capabilities: .resolve(engine: kind, backend: backend, mode: .castReceiver), isSystemOutput: false, isPreferred: preferred == device.routeID))
        }
        if let remembered = preferred, remembered.isCast, !castDevices.contains(where: { $0.routeID == remembered }), !follows {
            result.append(OutputRouteEntry(id: remembered, name: "", transport: nil, isCurrent: false, connection: .unavailable,
                                           capabilities: .resolve(engine: kind, backend: backend, mode: .castReceiver), isSystemOutput: false, isPreferred: true))
        }
        return result
    }

    // MARK: Choosing a route (ROUTE02, ROUTE03)

    /// A person's explicit choice. The device must be a live output (matched by UID, never by name); the engine must be one that can be pointed.
    /// A choice supersedes any remembered route and any pending route loss, and is persisted as the preferred route.
    @discardableResult public func select(_ route: OutputRouteID, engine kind: OutputEngineKind) async -> SelectionOutcome {
        // The hidden player follows the Mac; a receiver that is playing is changed in the system picker; an AirPlay receiver is chosen there too.
        if route.isCast, let id = route.castDeviceID { return await selectCast(id, engine: kind) }
        // Leaving a live Cast session by choosing a Mac output: the receiver is stopped and the local engine is paused (never started on the speakers by a
        // route change alone; ROUTE09), then the choice below proceeds as usual.
        if kind == .localMedia, remote?.isCast == true { await leaveCast() }
        guard kind == .localMedia, backend(for: kind) != .hiddenWebPlayer, remote == nil else { return .unsupported }
        if let uid = route.deviceUID {
            guard let device = snapshot.device(uid: uid) else { return .unavailable }
            guard device.transport != .airPlay else { return .unsupported }
        }
        selectionTicket &+= 1; let ticket = selectionTicket
        let applied = await engines[kind]?.apply(output: route.deviceUID) ?? true
        // A later choice or a newer route change overtook this one while the engine was being pointed: its late completion changes nothing.
        guard ticket == selectionTicket else { ignoredStale += 1; return .superseded }
        guard applied else { return .failed }
        generation &+= 1
        selection = route; preferred = route; store.save(route)
        launchNotice = nil; losses[.localMedia] = nil; clearPrompt(); soundedOn.remove(.localMedia)
        audible[.localMedia] = identity(for: .localMedia)
        return .selected
    }

    /// W27 (Output: system default until the person selects another). Forgets the remembered route: the local engine follows the system output again and
    /// nothing is persisted. It selects nothing and moves no sound already playing elsewhere (a receiver or the hidden player is not pointed).
    public func resetToSystemDefault() async {
        selectionTicket &+= 1
        _ = await engines[.localMedia]?.apply(output: nil)
        generation &+= 1
        selection = .systemDefault; preferred = nil; store.save(nil); launchNotice = nil
    }

    // MARK: Cast (W39: ROUTE05, ROUTE08, ROUTE09)

    /// The receivers browsing found. A list that no longer holds the receiver of a live session changes nothing about that session (its own heartbeat decides).
    public func castDirectoryChanged(_ devices: [CastDevice]) { castDevices = devices.sorted { ($0.friendlyName, $0.id.rawValue) < ($1.friendlyName, $1.id.rawValue) } }

    /// A person's choice of a Cast receiver for the local engine. The receiver must have been seen (matched by its identifier, never by name). The route
    /// becomes the session's selection and the remembered preferred route only if the connection succeeds, so a failed attempt leaves everything as it was.
    @discardableResult public func selectCast(_ id: CastDeviceID, engine kind: OutputEngineKind) async -> SelectionOutcome {
        guard kind == .localMedia, backend(for: kind) != .hiddenWebPlayer else { return .unsupported }
        guard castDevices.contains(where: { $0.id == id }) else { return .unavailable }
        guard let castConnect else { return .unsupported }
        if remote?.isCast == true { await leaveCast() }
        selectionTicket &+= 1; let ticket = selectionTicket
        let connected = await castConnect(id) { [weak self] in self?.selectionTicket == ticket }
        guard ticket == selectionTicket else { ignoredStale += 1; return .superseded }
        guard connected else { return .failed }
        let route = OutputRouteID.cast(id: id)
        selection = route; preferred = route; store.save(route)
        launchNotice = nil; losses[.localMedia] = nil; clearPrompt()
        return .selected
    }
    /// Ends the live Cast session by the person's choice. Nothing is a route loss, and nothing starts on the Mac.
    public func leaveCast() async {
        guard remote?.isCast == true else { return }
        selectionTicket &+= 1
        await castEnd?()
        remote = nil; generation &+= 1; soundedOn.remove(.localMedia)
        if selection.isCast { selection = selectionBeforeCast }
        audible[.localMedia] = identity(for: .localMedia)
    }
    /// A Cast session is live: the local engine has been silenced and the receiver renders. Returns the session identifier every later receiver event
    /// must carry, or nil when there is no local engine to hand over.
    @discardableResult public func castBegan(device id: CastDeviceID) -> UUID? {
        guard engines[.localMedia] != nil else { return nil }
        generation &+= 1
        let session = RemoteSession(id: UUID(), generation: generation, kind: .cast(id))
        remote = session; losses[.localMedia] = nil; soundedOn.insert(.localMedia); activeEngine = .localMedia
        if !selection.isCast { selectionBeforeCast = selection }
        selection = .cast(id: id)
        return session.id
    }
    /// A Cast session that began never got to play (its first load failed). Nothing was lost and nothing was chosen: the route goes back as it was.
    public func castAbandoned(session id: UUID) {
        guard remote?.id == id else { ignoredStale += 1; return }
        remote = nil; generation &+= 1; soundedOn.remove(.localMedia)
        if selection.isCast { selection = selectionBeforeCast }
        audible[.localMedia] = identity(for: .localMedia)
    }

    // MARK: Handoff (ROUTE08)

    /// Before engine `kind` starts: every OTHER engine is silenced and must confirm it. Refused when one cannot be confirmed silent, so two
    /// uncontrolled players never coexist. The generation moves first, so a callback from the engine being replaced is recognised as late.
    public func beginHandoff(to kind: OutputEngineKind) async -> HandoffOutcome {
        // W39: a receiver renders the native session's item. If the OTHER engine is about to play, the receiver is stopped first, so the Mac and a receiver are
        // never both audible (a native start keeps the Cast route: the replacement session is silenced on attach and its item is loaded on the receiver).
        if kind != .localMedia, remote?.isCast == true { await leaveCast() }
        generation &+= 1; handoffTicket = generation; let ticket = handoffTicket
        for (other, engine) in engines where other != kind {
            let stopped = await engine.stopForHandoff()
            guard handoffTicket == ticket else { ignoredStale += 1; return .superseded }
            guard stopped else { return .refused }
        }
        activeEngine = kind; soundedOn.insert(kind)
        return .ready
    }

    // MARK: Audible actions (ROUTE09, PLAY17)

    public enum Admission: Equatable, Sendable { case allowed, confirmPlayHere(PlayHerePrompt), acknowledgeTimer(TimerPrompt) }

    /// What must happen before sound may start (or a timer may be enabled) for this engine on its route.
    public func admission(_ gate: AudibleGate, engine kind: OutputEngineKind, timerActive: Bool = false) -> Admission {
        if gate == .start, let loss = losses[kind] {
            return .confirmPlayHere(PlayHerePrompt(id: UUID(), engine: kind, output: snapshot.defaultDevice?.name, reason: loss.reason, canReconnect: loss.canReconnect(in: snapshot, casts: castDevices)))
        }
        let wantsTimerNote = gate == .enableTimer || timerActive
        if wantsTimerNote, capabilities(for: kind).timer == .pauseOnly, !(remote.map { acknowledgedTimerSessions.contains($0.id) } ?? false) {
            return .acknowledgeTimer(TimerPrompt(id: UUID()))
        }
        return .allowed
    }
    /// Runs `body` (the audible action) only when the route allows it; otherwise raises the prompt and holds `body` until it is confirmed.
    /// Returns whether `body` ran.
    @discardableResult public func perform(_ gate: AudibleGate, engine kind: OutputEngineKind, timerActive: Bool = false, _ body: @escaping @MainActor () async -> Void) async -> Bool {
        switch admission(gate, engine: kind, timerActive: timerActive) {
        case .allowed:
            if gate == .start { soundedOn.insert(kind) }
            await body(); return true
        case .confirmPlayHere(let value):
            pending = (value.id, generation, body); prompt = .playHere(value); return false
        case .acknowledgeTimer(let value):
            pending = (value.id, generation, body); prompt = .timer(value); return false
        }
    }
    /// The person confirmed. Play here accepts this Mac's current output for the engine that asked: the loss (and any other engine's loss of the SAME
    /// device) is cleared, the local engine follows the system output again (not persisted: the preferred route stays as it was), and the held action
    /// runs. A prompt that the route outlived (the outputs changed after it was shown) is dropped and must be asked again.
    public func confirm(_ id: UUID) async {
        guard let held = pending, held.id == id, prompt?.id == id else { return }
        guard held.generation == generation else { ignoredStale += 1; clearPrompt(); return }
        switch prompt {
        case .playHere(let value)?:
            clearPrompt()
            selectionTicket &+= 1
            let accepted = losses[value.engine]?.lost
            for (kind, loss) in losses where kind == value.engine || (accepted != nil && loss.lost == accepted) { losses[kind] = nil }
            generation &+= 1; soundedOn.insert(value.engine)
            if value.engine == .localMedia {
                selection = .systemDefault
                _ = await engines[.localMedia]?.apply(output: nil)
            }
            for kind in [OutputEngineKind.youTubeMusic, .localMedia] { audible[kind] = identity(for: kind) }
            await held.body()
        case .timer?:
            clearPrompt()
            if let remote { acknowledgedTimerSessions.insert(remote.id) }
            await held.body()
        case nil: break
        }
    }
    public func cancel(_ id: UUID) { if pending?.id == id { clearPrompt() } }
    private func clearPrompt() { pending = nil; prompt = nil }
    /// An account barrier (switch, sign-out, removal, quit): a held Play here or timer prompt belongs to the account that raised it and must not
    /// survive it (DATA03). Route losses stay: they describe the Mac, not the account.
    public func discardHeld() { clearPrompt() }

    /// "Reconnect": a lost output is a live output again. Re-points the local engine and clears the loss; it does NOT play (ROUTE03).
    @discardableResult public func reconnect() async -> Bool {
        // W39: a lost Cast receiver is reconnected by connecting to it again (it must be seen on the network). It is loaded paused at the last position the
        // receiver reported; reconnecting never plays (ROUTE03).
        if let loss = losses[.localMedia], let id = loss.lostRoute.castDeviceID {
            guard castDevices.contains(where: { $0.id == id }), let castConnect else { return false }
            selectionTicket &+= 1; let ticket = selectionTicket
            let connected = await castConnect(id) { [weak self] in self?.selectionTicket == ticket }
            guard ticket == selectionTicket else { ignoredStale += 1; return false }
            if connected { clearPrompt() }
            return connected
        }
        let reconnectable = losses.filter { $0.value.canReconnect(in: snapshot, casts: castDevices) }
        guard !reconnectable.isEmpty else { return false }
        selectionTicket &+= 1; let ticket = selectionTicket
        var applied = true
        if reconnectable[.localMedia] != nil { applied = await engines[.localMedia]?.apply(output: selection.deviceUID) ?? true }
        guard ticket == selectionTicket, reconnectable.allSatisfy({ losses[$0.key] == $0.value }) else { ignoredStale += 1; return false }
        guard applied else { return false }
        generation &+= 1; for kind in reconnectable.keys { losses[kind] = nil; soundedOn.remove(kind) }
        clearPrompt()
        for kind in [OutputEngineKind.youTubeMusic, .localMedia] { audible[kind] = identity(for: kind) }
        return true
    }

    // MARK: The system's output list (ROUTE03, ROUTE11)

    /// The outputs changed (called in the turn the system announces it). Re-reads the list; the notification itself carries nothing. Each engine is judged
    /// against the route IT is audible on, so a loss of the system default pauses the hidden player and a loss of the local engine's chosen device pauses
    /// only the local engine. When a device is lost that an engine made sound on, every OTHER engine whose route was that same device also holds the loss
    /// (quietly: nothing of it was playing), so no engine can start on the speakers that took over without Play here (ROUTE09).
    public func directoryChanged() {
        let before = audible
        snapshot = directory.snapshot()
        var lostNow: [OutputEngineKind: (reason: RouteLossReason, identity: RouteIdentity)] = [:]
        for kind in [OutputEngineKind.youTubeMusic, .localMedia] where engines[kind] != nil {
            if let previous = before[kind] {
                switch RouteLossPolicy.assess(audible: previous, in: snapshot) {
                case .lost(let reason): lostNow[kind] = (reason, previous); continue
                case .moved(let identity): audible[kind] = identity; generation &+= 1; continue
                case .unchanged: break
                }
            }
            // The device is still live; the route may nevertheless have moved (the system or a person changed the default).
            let current = identity(for: kind)
            if current != before[kind] {
                if let previous = before[kind], OutputTransport(coreAudio: previous.transport).isDetachable { departed[kind] = (previous, now()) }
                audible[kind] = current; generation &+= 1
            }
            // The system may announce the default moving off a device BEFORE announcing the device's departure: a device that vanishes just after the
            // sound left it is the loss that caused the move. This BOUNDS the leak to the gap between the two announcements; it cannot prevent it.
            if let gone = departed[kind] {
                if now() - gone.at > departureWindow { departed[kind] = nil }
                else if snapshot.device(uid: gone.identity.uid) == nil { departed[kind] = nil; lostNow[kind] = (.deviceDisconnected, gone.identity) }
            }
        }
        let significant = lostNow.filter { engines[$0.key]?.isAudibleOrWanted == true || soundedOn.contains($0.key) }
        for (kind, lost) in lostNow {
            let related = significant[kind] != nil || significant.values.contains { $0.identity.uid == lost.identity.uid }
            if related { recordLoss(lost.reason, identity: lost.identity, kind: kind) }
            else { audible[kind] = identity(for: kind); generation &+= 1 }
        }
    }
    /// A loss with no device to compare (a receiver that went away): only for an engine that was sounding or had sounded.
    private func routeLost(_ reason: RouteLossReason, identity lost: RouteIdentity?, kind: OutputEngineKind) {
        guard engines[kind]?.isAudibleOrWanted == true || soundedOn.contains(kind) else { audible[kind] = identity(for: kind); generation &+= 1; return }
        recordLoss(reason, identity: lost, kind: kind)
    }
    private func recordLoss(_ reason: RouteLossReason, identity lost: RouteIdentity?, kind: OutputEngineKind) {
        let engine = engines[kind]
        let sounding = engine?.isAudibleOrWanted == true
        // The record is written before anything awaits, so every resume path that looks sees the loss from this instant.
        losses[kind] = RouteLoss(reason: reason, engine: kind, lost: lost, lostRoute: kind == .localMedia ? selection : .systemDefault, generation: generation, wasAudible: sounding)
        generation &+= 1; clearPrompt(); soundedOn.remove(kind); departed[kind] = nil
        audible[kind] = identity(for: kind)
        // Pause now. `Task.immediate` runs the task's first segment inline in this turn, so the engine's pause is issued (the hidden player's `pause` reaches
        // the page; the local engine's player is paused) before the system's notification handler returns, not one queued job later.
        if sounding, let engine { lossPauses.append(Task.immediate { @MainActor in _ = await engine.pauseForRouteLoss() }) }
    }
    /// Waits for the pauses a loss started. Tests await it; the app never needs to.
    public func settled() async { let tasks = lossPauses; for task in tasks { await task.value }; lossPauses.removeAll() }

    // MARK: Remote sessions (AirPlay external playback; ROUTE08, ROUTE09)

    /// External playback started. Returns the new session's identifier, or nil when the local engine cannot be handed over safely (the decoded
    /// graph is silenced instead, so a receiver and the Mac never play at once).
    @discardableResult public func remoteBegan() async -> UUID? {
        generation &+= 1
        guard let local = engines[.localMedia], local.backend == .avPlayer else {
            if let local = engines[.localMedia] { _ = await local.stopForHandoff() }
            return nil
        }
        let session = RemoteSession(id: UUID(), generation: generation)
        remote = session; losses[.localMedia] = nil; soundedOn.insert(.localMedia); activeEngine = .localMedia
        return session.id
    }
    /// A receiver report. Anything that names another session (or arrives after the session ended) is ignored, so a late event from an earlier
    /// receiver cannot move the current one (DATA03).
    public func remoteEvent(_ event: RemoteEvent, session id: UUID) {
        guard var current = remote, current.id == id else { ignoredStale += 1; return }
        switch event {
        case .position(let seconds, let observedAt):
            guard seconds.isFinite, seconds >= 0 else { ignoredStale += 1; return }
            current.apply(reading: PositionReading(seconds: seconds, observedAt: observedAt)); remote = current
        case .state(let state): current.apply(state: state); remote = current
        case .capabilities(let capabilities): current.apply(capabilities: capabilities); remote = current
        case .volume(let volume): current.apply(volume: volume); remote = current
        case .ended(.chosenByPerson): remote = nil; generation &+= 1; soundedOn.remove(.localMedia); audible[.localMedia] = identity(for: .localMedia)
        case .ended(.receiverLost):
            remote = nil
            routeLost(.receiverDisconnected, identity: nil, kind: .localMedia)
        }
    }
    /// The position to show for the remote session: the receiver's own report, or nil. Never a local timer.
    public func remotePosition() -> Double? { remote?.displayedPosition(now: clock.now) }
}
