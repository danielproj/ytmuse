import Foundation

// W39 (ROUTE05, ROUTE08, ROUTE09, DATA03). One sender session with one receiver: connect, launch the Default Media Receiver, load one item, control it,
// and report ONLY what the receiver says. Position, state and capabilities come from the receiver's MEDIA_STATUS; the session never advances a clock of
// its own. Each LOAD starts a new load generation and retires the previous media session identifier, so a late status of an earlier item is dropped
// (counted in `ignoredStale`) instead of moving the current one.

public enum CastLossCause: Equatable, Sendable {
    /// The connection to the receiver ended, or its heartbeat stopped.
    case connectionLost, heartbeatTimeout
    /// The receiver closed our virtual connection or ended our application.
    case receiverClosed
    /// Another sender loaded other media on the receiver.
    case takenOver
}

/// What the receiver reported about the item loaded by load generation `generation`.
public struct CastMediaReport: Equatable, Sendable {
    public let generation: UInt64
    public let state: CastPlayerState
    public let position: Double?
    public let duration: Double?
    public let capabilities: CastReceiverCapabilities?
    public let observedAt: ContinuousClock.Instant
}

public enum CastSessionEvent: Equatable, Sendable {
    case ready
    case media(CastMediaReport)
    case volume(level: Double?, muted: Bool?)
    /// The loaded item played to its end (the receiver went idle with FINISHED).
    case finished(generation: UInt64)
    case mediaFailed(generation: UInt64)
    case commandRefused(String?)
    case lost(CastLossCause)
}

public struct CastSessionConfiguration: Sendable {
    public var requestTimeout: Duration = .seconds(10)
    public var launchTimeout: Duration = .seconds(15)
    public var heartbeatInterval: Duration = .seconds(5)
    public var heartbeatTimeout: Duration = .seconds(15)
    /// False in tests, which call `heartbeatTick()` themselves.
    public var runsHeartbeat = true
    public init() {}
}

public enum CastShutdown: Sendable, Equatable {
    /// Stop the receiver application and disconnect.
    case stopReceiver
    /// Disconnect and leave the receiver playing (only meaningful when the receiver fetches the media itself).
    case leave
}

@MainActor public final class CastSession {
    public enum Phase: Equatable, Sendable { case idle, connecting, launching, ready, closed }
    public let id = UUID()
    public let device: CastDevice
    public private(set) var phase: Phase = .idle
    /// Messages dropped because they belonged to an earlier load or an unknown media session (diagnostics and tests).
    public private(set) var ignoredStale = 0
    /// The last load generation; the first LOAD is generation 1.
    public private(set) var loadGeneration: UInt64 = 0
    public private(set) var capabilities: CastReceiverCapabilities?
    public var onEvent: (@MainActor (CastSessionEvent) -> Void)?
    /// The Mac's address toward the receiver and the receiver's, as the open connection reported them.
    public var localAddress: String? { channel?.localAddress }
    public var remoteAddress: String? { channel?.remoteAddress }

    private let factory: any CastChannelFactory
    private let configuration: CastSessionConfiguration
    private let now: @MainActor () -> ContinuousClock.Instant
    private var channel: (any CastChannel)?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var transportID: String?
    private var applicationSessionID: String?
    private var mediaSessionID: Int?
    private var retired: Set<Int> = []
    private var expectedContentID: String?
    private var requestCounter = 0
    private var lastReceived: ContinuousClock.Instant
    private var waiters: [UUID: Waiter] = [:]
    /// Set when WE end the session: the receiver's own reply to our STOP (a status without our application) is then not a loss.
    private var shuttingDown = false

    private struct Waiter { let accept: (CastInbound) -> Bool; let continuation: CheckedContinuation<CastInbound, any Error>; var timeout: Task<Void, Never>? }

    public init(device: CastDevice, factory: any CastChannelFactory, configuration: CastSessionConfiguration = CastSessionConfiguration(), now: (@MainActor () -> ContinuousClock.Instant)? = nil) {
        self.device = device; self.factory = factory; self.configuration = configuration
        let clock = now ?? { ContinuousClock.now }
        self.now = clock; lastReceived = clock()
    }

    private func nextRequestID() -> Int { requestCounter += 1; return requestCounter }

    // MARK: Connecting

    /// Opens the connection, launches the Default Media Receiver and connects to its transport. Throws when any step fails; the session is then closed.
    public func connect() async throws {
        guard phase == .idle else { throw CastError.notConnected }
        phase = .connecting
        do {
            let opened = try await factory.open(device)
            guard phase == .connecting else { opened.close(); throw CastError.closed }
            channel = opened; lastReceived = now()
            reader = Task { @MainActor [weak self] in
                for await event in opened.events {
                    guard let self, self.channel === opened else { return }
                    switch event {
                    case .message(let message): self.receive(message)
                    case .closed: self.lose(.connectionLost)
                    }
                }
                self?.lose(.connectionLost)
            }
            try await send(CastMessages.connect())
            phase = .launching
            let launchID = nextRequestID()
            let reply = try await exchange(CastMessages.launch(requestID: launchID), timeout: configuration.launchTimeout) { [weak self] inbound in
                if case .failure(_, let request, _) = inbound, request == launchID { return true }
                return self?.transportID != nil
            }
            if case .failure(_, _, let reason) = reply { throw CastError.launchFailed(reason) }
            guard let transport = transportID else { throw CastError.launchFailed(nil) }
            try await send(CastMessages.connect(to: transport))
            phase = .ready
            if configuration.runsHeartbeat { startHeartbeat() }
            onEvent?(.ready)
        } catch {
            await abandon()
            throw error is CastError ? error : CastError.closed
        }
    }

    // MARK: Commands (the receiver's next status is the answer; nothing is assumed here)

    /// Loads one item and waits until the receiver has accepted it (its media session exists) or refused it.
    @discardableResult public func load(_ item: CastMessages.Load) async throws -> UInt64 {
        guard phase == .ready, let transport = transportID, let session = applicationSessionID else { throw CastError.notConnected }
        loadGeneration &+= 1; let generation = loadGeneration
        if let old = mediaSessionID { retired.insert(old) }
        mediaSessionID = nil; expectedContentID = item.url
        let id = nextRequestID()
        let reply = try await exchange(CastMessages.load(item, sessionID: session, transportID: transport, requestID: id), timeout: configuration.requestTimeout) { [weak self] inbound in
            if case .failure(_, let request, _) = inbound, request == id { return true }
            guard let self else { return true }
            return self.loadGeneration != generation || self.mediaSessionID != nil
        }
        guard loadGeneration == generation else { throw CastError.superseded }
        if case .failure(let type, _, let reason) = reply { expectedContentID = nil; throw CastError.loadFailed(reason ?? type) }
        return generation
    }
    public func play() async throws { try await command("PLAY") }
    public func pause() async throws { try await command("PAUSE") }
    public func seek(to seconds: Double) async throws {
        guard seconds.isFinite, seconds >= 0 else { throw CastError.commandRefused("position") }
        try await command("SEEK", extra: ["currentTime": seconds])
    }
    /// Ends the loaded media on the receiver. The IDLE status that follows belongs to a retired media session and is ignored.
    public func stopMedia() async throws {
        guard let current = mediaSessionID else { return }
        try await command("STOP"); retired.insert(current); mediaSessionID = nil; expectedContentID = nil
    }
    public func setVolume(level: Double) async throws {
        guard phase == .ready else { throw CastError.notConnected }
        try await send(CastMessages.setVolume(level: level, muted: nil, requestID: nextRequestID()))
    }
    public func setMuted(_ muted: Bool) async throws {
        guard phase == .ready else { throw CastError.notConnected }
        try await send(CastMessages.setVolume(level: nil, muted: muted, requestID: nextRequestID()))
    }
    /// Asks the receiver for its media status; the answer arrives as an ordinary `.media` event.
    public func requestStatus() async throws {
        guard phase == .ready, let transport = transportID else { throw CastError.notConnected }
        try await send(CastMessages.mediaGetStatus(transportID: transport, requestID: nextRequestID()))
    }
    private func command(_ type: String, extra: [String: Any] = [:]) async throws {
        guard phase == .ready, let transport = transportID else { throw CastError.notConnected }
        guard let media = mediaSessionID else { throw CastError.noMedia }
        try await send(CastMessages.mediaCommand(type, mediaSessionID: media, transportID: transport, requestID: nextRequestID(), extra: extra))
    }

    // MARK: Ending

    /// Ends the session. `.stopReceiver` stops the receiver application first; both disconnect. Never throws: a connection that is already gone is closed.
    public func shutdown(_ mode: CastShutdown) async {
        guard phase != .closed else { return }
        shuttingDown = true
        if phase == .ready, let channel {
            if mode == .stopReceiver, let session = applicationSessionID { try? await channel.send(CastMessages.stopApplication(sessionID: session, requestID: nextRequestID())) }
            if let transport = transportID { try? await channel.send(CastMessages.close(to: transport)) }
            try? await channel.send(CastMessages.close())
        }
        await abandon()
    }
    private func abandon() async {
        phase = .closed
        heartbeat?.cancel(); heartbeat = nil; reader?.cancel(); reader = nil
        let held = channel; channel = nil; held?.close()
        for key in Array(waiters.keys) { resolve(key, with: .failure(CastError.closed)) }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        let interval = configuration.heartbeatInterval
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.heartbeatTick()
            }
        }
    }
    /// One heartbeat step: the connection is lost if the receiver has said nothing for `heartbeatTimeout`; otherwise a PING goes out. The real loop
    /// calls this every `heartbeatInterval`; tests call it with a controlled clock.
    public func heartbeatTick() async {
        guard phase == .ready || phase == .launching else { return }
        if now() - lastReceived > configuration.heartbeatTimeout { lose(.heartbeatTimeout); return }
        try? await channel?.send(CastMessages.ping())
    }

    // MARK: Receiving

    private func send(_ message: CastMessage) async throws {
        guard let channel else { throw CastError.closed }
        do { try await channel.send(message) } catch { throw CastError.closed }
    }
    private func exchange(_ message: CastMessage, timeout: Duration, accept: @escaping (CastInbound) -> Bool) async throws -> CastInbound {
        let key = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CastInbound, any Error>) in
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.resolve(key, with: .failure(CastError.timedOut))
            }
            waiters[key] = Waiter(accept: accept, continuation: continuation, timeout: timer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.send(message) } catch { self.resolve(key, with: .failure(error)) }
            }
        }
    }
    private func resolve(_ key: UUID, with result: Result<CastInbound, any Error>) {
        guard let waiter = waiters.removeValue(forKey: key) else { return }
        waiter.timeout?.cancel()
        waiter.continuation.resume(with: result)
    }

    /// Handles one message from the receiver. `internal` so tests deliver scripted (and late) messages in an exact order.
    func receive(_ message: CastMessage) {
        guard phase != .closed, !shuttingDown else { return }
        lastReceived = now()
        guard let inbound = CastMessages.parse(message) else { return }
        switch inbound {
        case .ping: Task { @MainActor [weak self] in try? await self?.channel?.send(CastMessages.pong()) }
        case .pong, .other: break
        case .close:
            // Only the receiver ending OUR virtual connection (to the platform receiver or to our application) is a loss.
            if phase == .ready || phase == .launching { lose(.receiverClosed) }
        case .receiverStatus(_, let status): applyReceiverStatus(status)
        case .mediaStatus(_, let entries): applyMediaStatus(entries)
        case .failure(let type, _, let reason):
            if phase == .ready, !waiters.values.contains(where: { $0.accept(inbound) }) { onEvent?(.commandRefused(reason ?? type)) }
        }
        for (key, waiter) in waiters where waiter.accept(inbound) { resolve(key, with: .success(inbound)) }
    }

    private func applyReceiverStatus(_ status: CastReceiverStatus) {
        if phase == .launching {
            if let app = status.applications.first(where: { $0.appID == CastIdentity.defaultMediaReceiverAppID }), app.namespaces.isEmpty || app.namespaces.contains(CastNamespace.media) {
                transportID = app.transportID; applicationSessionID = app.sessionID
            }
            return
        }
        guard phase == .ready else { return }
        if let volume = status.volume { onEvent?(.volume(level: volume.level, muted: volume.muted)) }
        // Our application is gone from the receiver (another sender launched something else, or the device ended it).
        if let session = applicationSessionID, !status.applications.contains(where: { $0.sessionID == session }) { lose(.receiverClosed) }
    }

    private func applyMediaStatus(_ entries: [CastMediaStatus]) {
        guard phase == .ready else { return }
        for entry in entries {
            if retired.contains(entry.mediaSessionID) { ignoredStale += 1; continue }
            if let active = mediaSessionID {
                guard entry.mediaSessionID == active else {
                    // An identifier we have never seen, carrying media we did not load: another sender took the receiver over.
                    if let content = entry.contentID, content != expectedContentID { lose(.takenOver); return }
                    ignoredStale += 1; continue
                }
            } else {
                // Loading: only the media we asked for may establish the session identifier.
                guard let expected = expectedContentID, entry.contentID == expected else { ignoredStale += 1; continue }
                mediaSessionID = entry.mediaSessionID
            }
            if let bits = entry.capabilities { capabilities = bits }
            if entry.state == .idle, let reason = entry.idleReason {
                switch reason {
                case .finished: onEvent?(.finished(generation: loadGeneration)); mediaSessionID = nil; retired.insert(entry.mediaSessionID); expectedContentID = nil
                case .error: onEvent?(.mediaFailed(generation: loadGeneration)); mediaSessionID = nil; retired.insert(entry.mediaSessionID); expectedContentID = nil
                case .cancelled, .interrupted: lose(.takenOver); return
                }
                continue
            }
            onEvent?(.media(CastMediaReport(generation: loadGeneration, state: entry.state, position: entry.currentTime, duration: entry.duration,
                                            capabilities: capabilities, observedAt: now())))
        }
    }

    private func lose(_ cause: CastLossCause) {
        guard phase != .closed else { return }
        let wasReady = phase == .ready
        phase = .closed
        heartbeat?.cancel(); heartbeat = nil; reader?.cancel(); reader = nil
        let held = channel; channel = nil; held?.close()
        for key in Array(waiters.keys) { resolve(key, with: .failure(CastError.closed)) }
        // A connection that fails before it is ready is reported by `connect()` throwing, not as a loss of a route that never existed.
        if wasReady { onEvent?(.lost(cause)) }
    }
}
