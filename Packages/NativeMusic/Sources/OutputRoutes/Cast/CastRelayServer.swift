import Domain
import Foundation
import Network
import Synchronization

// W39 (ROUTE07). The listening half of the relay: one TCP listener bound to ONE local address (IPv4, or since TH4 IPv6), each connection answered once and closed.
// Every decision is `CastRelayCore`'s. This file only moves bytes, enforces the connection cap and the read timeout, and refuses to exist where it must
// not: `CastNetworkGate.requireBindable` rejects the wildcard and public addresses always (IPv6: only loopback, unique-local and link-local are private), and any
// non-loopback address unless the real network has been enabled (which never happens in a test process).

public final class CastRelayServer: @unchecked Sendable {
    public let core: CastRelayCore
    public let bindAddress: String
    private let queue = DispatchQueue(label: "local.native-music.cast-relay")
    private var listener: NWListener?
    private var active = 0
    private var stopped = false
    private var lifetimeTimer: DispatchSourceTimer?
    private let connections = Mutex<[ObjectIdentifier: NWConnection]>([:])

    public init(bindAddress: String, receiverAddress: String?, limits: CastRelayLimits = CastRelayLimits(), now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) throws {
        do { try CastNetworkGate.requireBindable(bindAddress) } catch { throw CastRelayError.bindRefused(SafeErrorText.describe(error)) }
        self.bindAddress = bindAddress
        core = CastRelayCore(bound: bindAddress, receiver: receiverAddress, limits: limits, now: now)
    }

    /// Starts listening on a system-chosen port of the bound address and returns it.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: .any)
        parameters.acceptLocalOnly = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let once = Mutex(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: CastRelayError.notStarted) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        // The lifetime is enforced here as well as per request: the socket itself goes away.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let seconds = core.limits.maxLifetime.components.seconds
        timer.schedule(deadline: .now() + .seconds(Int(min(seconds, Int64(Int32.max)))))
        timer.setEventHandler { [weak self] in self?.stop() }
        timer.resume(); lifetimeTimer = timer
        return port
    }
    public var port: UInt16? { listener?.port?.rawValue }

    /// Registers the item and returns the URL the receiver is given: this address, this port, the token path. Nothing else.
    public func url(serving file: URL) throws -> URL {
        guard let port, port != 0 else { throw CastRelayError.notStarted }
        let path = try core.register(file: file)
        guard let url = URL(string: "http://\(CastNetworkGate.urlHost(for: bindAddress)):\(port)\(path)") else { throw CastRelayError.notStarted }
        return url
    }

    public func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            core.revoke()
            lifetimeTimer?.cancel(); lifetimeTimer = nil
            listener?.cancel(); listener = nil
            let open = connections.withLock { let all = Array($0.values); $0.removeAll(); return all }
            for connection in open { connection.cancel() }
        }
    }
    /// Waits until `stop()` has run (for tests that then assert the port is closed).
    public func stopped() async { await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in queue.async { continuation.resume() } } }

    // MARK: Connections

    private func peer(of connection: NWConnection) -> String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        // The zone (the interface a link-local peer arrived on) is not part of who the peer is.
        switch host {
        case .ipv4(let address): return String(address.debugDescription.split(separator: "%").first ?? "")
        case .ipv6(let address): return String(address.debugDescription.split(separator: "%").first ?? "")
        default: return nil
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, active < core.limits.maxConnections, let peer = peer(of: connection), CastNetworkGate.peerAllowed(peer, receiver: core.receiverAddress, boundTo: bindAddress) else { connection.cancel(); return }
        active += 1
        let key = ObjectIdentifier(connection)
        connections.withLock { $0[key] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.queue.async { self?.active -= 1 }; _ = self?.connections.withLock { $0.removeValue(forKey: key) } }
        }
        connection.start(queue: queue)
        let timeout = core.limits.readTimeout.components.seconds
        queue.asyncAfter(deadline: .now() + .seconds(Int(timeout))) { [weak connection] in if connection?.state != .cancelled, connection != nil { self.headTimedOut(connection) } }
        readHead(connection, peer: peer, buffer: Data())
    }
    private var finishedHead = Set<ObjectIdentifier>()
    /// Progress timers after the head (queue-confined): each completed send re-arms; a send that never completes cuts the connection.
    private var idleItems: [ObjectIdentifier: DispatchWorkItem] = [:]
    private func armIdle(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        idleItems[key]?.cancel()
        let item = DispatchWorkItem { [weak connection] in connection?.cancel() }
        idleItems[key] = item
        queue.asyncAfter(deadline: .now() + .seconds(max(1, Int(core.limits.idleTimeout.components.seconds))), execute: item)
    }
    private func disarmIdle(_ connection: NWConnection) { idleItems.removeValue(forKey: ObjectIdentifier(connection))?.cancel() }
    private func headTimedOut(_ connection: NWConnection?) { guard let connection, !finishedHead.contains(ObjectIdentifier(connection)) else { return }; connection.cancel() }

    private func readHead(_ connection: NWConnection, peer: String, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2_048) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                finishedHead.insert(ObjectIdentifier(connection))
                let head = buffer[buffer.startIndex..<end.upperBound]
                respond(connection, to: core.decide(head: Data(head), peer: peer))
            } else if buffer.count > core.limits.maxHeadBytes {
                finishedHead.insert(ObjectIdentifier(connection))
                respond(connection, to: core.decide(head: buffer, peer: peer))
            } else if error != nil || isComplete { connection.cancel() }
            else { readHead(connection, peer: peer, buffer: buffer) }
        }
    }
    private func respond(_ connection: NWConnection, to decision: CastRelayDecision) {
        switch decision {
        case .drop: connection.cancel()
        case .respond(let response):
            armIdle(connection)
            connection.send(content: response.head, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil, let body = response.body else { self?.disarmIdle(connection); connection.cancel(); return }
                self.armIdle(connection)
                self.stream(body, over: connection)
            })
        }
    }
    /// Sends `body.length` bytes of the file from `body.offset` in 128 KiB pieces, one at a time, so a slow receiver never makes the relay buffer a file.
    private func stream(_ body: CastRelayResponse.Body, over connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: body.file) else { connection.cancel(); return }
        do { try handle.seek(toOffset: body.offset) } catch { try? handle.close(); connection.cancel(); return }
        func next(remaining: UInt64) {
            guard remaining > 0 else { try? handle.close(); disarmIdle(connection); connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() }); return }
            let piece = (try? handle.read(upToCount: Int(min(remaining, 131_072)))) ?? Data()
            guard !piece.isEmpty else { try? handle.close(); disarmIdle(connection); connection.cancel(); return }
            armIdle(connection)
            connection.send(content: piece, completion: .contentProcessed { [weak self] error in
                if error != nil { try? handle.close(); self?.disarmIdle(connection); connection.cancel(); return }
                self?.armIdle(connection)
                self?.core.noteServed(UInt64(piece.count))
                next(remaining: remaining - UInt64(piece.count))
            })
        }
        next(remaining: body.length)
    }
}
