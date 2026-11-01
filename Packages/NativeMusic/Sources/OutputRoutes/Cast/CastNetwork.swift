import CryptoKit
import Foundation
import Network
import Security
import Synchronization

// W39 (ROUTE05). The ONLY file that browses Bonjour or connects to a receiver. Both are refused unless `CastNetworkGate` has been enabled, which no test
// process can do; the composition constructs these two types only in a normal (non-isolated) launch, and browsing starts only when the person opens the
// picker, so the system's Local Network prompt is never raised at launch, in a test or in an isolated run.
//
// TLS note (documented in Docs/Cast.md): a receiver presents a certificate that chains to Google's device authority, not to a system root, so the
// default trust evaluation cannot succeed. The sender therefore does not evaluate the chain. A receiver also REGENERATES its self-signed certificate from time to
// time (CASTV2 device authentication exists to vouch for that), so remembering one across connections would refuse a genuine device after a reboot or rotation and
// break Reconnect. The certificate is pinned for ONE connected session only (`CastCertificatePins`, created fresh for each connection): a different certificate
// presented on that same connection is refused, and a later connection (after a loss, a reboot or a relaunch) is accepted as a new session. The sender does NOT
// perform the CASTV2 device-authentication challenge, so it cannot prove a device is genuine and the pin establishes no identity (`Docs/Cast.md`). What it sends to a
// receiver is a media address on the Mac's own LAN address, with a random token; it sends no account data of any kind.

public final class NWCastDirectory: CastDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var browsing = false
    private var found: [CastDeviceID: (device: CastDevice, endpoint: NWEndpoint)] = [:]
    private var handlers: [UUID: @MainActor () -> Void] = [:]
    public init() {}

    /// Only what browsing currently sees: nothing once browsing has stopped (a receiver is not offered from a stale list). The endpoints of the last results are
    /// kept, so a connection already being made when the picker closes can still finish.
    public func devices() -> [CastDevice] { lock.withLock { browsing ? found.values.map(\.device) : [] } }
    func endpoint(for id: CastDeviceID) -> NWEndpoint? { lock.withLock { found[id]?.endpoint } }

    @MainActor public func observe(_ onChange: @escaping @MainActor () -> Void) -> OutputObservation {
        let key = UUID(); lock.withLock { handlers[key] = onChange }
        return Observation { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: key) } }
    }
    @MainActor public func startBrowsing() {
        guard browser == nil, (try? CastNetworkGate.requireLive()) != nil else { return }
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_googlecast._tcp", domain: "local.")
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        browser.start(queue: .main)
        self.browser = browser
        lock.withLock { browsing = true }
    }
    @MainActor public func stopBrowsing() {
        browser?.cancel(); browser = nil
        lock.withLock { browsing = false }
        notify()
    }
    private func update(_ results: Set<NWBrowser.Result>) {
        var next: [CastDeviceID: (CastDevice, NWEndpoint)] = [:]
        for result in results {
            guard case .bonjour(let record) = result.metadata, let rawID = record["id"], let id = CastDeviceID(rawID) else { continue }
            let name = record["fn"].flatMap { $0.isEmpty ? nil : $0 } ?? "Chromecast"
            next[id] = (CastDevice(id: id, friendlyName: String(name.prefix(80)), model: record["md"], capabilityBits: record["ca"].flatMap { UInt32($0) }), result.endpoint)
        }
        lock.withLock { found = next }
        notify()
    }
    private func notify() {
        let all = lock.withLock { Array(handlers.values) }
        Task { @MainActor in for handler in all { handler() } }
    }
    private final class Observation: OutputObservation {
        private let onCancel: () -> Void
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        @MainActor func cancel() { onCancel() }
    }
}

/// The leaf certificate a device presented on ONE connected session: a different certificate on that session is refused. Never kept across connections.
public final class CastCertificatePins: @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [CastDeviceID: String] = [:]
    public init() {}
    public func accepts(_ fingerprint: String, for device: CastDeviceID) -> Bool {
        lock.withLock {
            if let pinned = pins[device] { return pinned == fingerprint }
            pins[device] = fingerprint; return true
        }
    }
    static func fingerprint(of certificate: Data) -> String { SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined() }
}

public struct NWCastChannelFactory: CastChannelFactory {
    private let directory: NWCastDirectory
    public init(directory: NWCastDirectory) { self.directory = directory }
    public func open(_ device: CastDevice) async throws -> any CastChannel {
        do { try CastNetworkGate.requireLive() } catch { throw CastError.networkNotPermitted }
        guard let endpoint = directory.endpoint(for: device.id) else { throw CastError.notConnected }
        // A fresh pin set per connection: it holds for this one session only (see the TLS note above).
        let channel = NWCastChannel(endpoint: endpoint, device: device.id, pins: CastCertificatePins())
        try await channel.start()
        return channel
    }
}

final class NWCastChannel: CastChannel, @unchecked Sendable {
    let events: AsyncStream<CastChannelEvent>
    private let continuation: AsyncStream<CastChannelEvent>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "local.native-music.cast-channel")
    private let addresses = Mutex<(local: String?, remote: String?)>((nil, nil))
    private let decoder = Mutex(CastFrameDecoder())
    private let finished = Mutex(false)

    var localAddress: String? { addresses.withLock { $0.local } }
    var remoteAddress: String? { addresses.withLock { $0.remote } }

    init(endpoint: NWEndpoint, device: CastDeviceID, pins: CastCertificatePins) {
        (events, continuation) = AsyncStream.makeStream(of: CastChannelEvent.self, bufferingPolicy: .unbounded)
        let tls = NWProtocolTLS.Options()
        // The one place certificate validation is not the system's: see the TLS note above. The leaf certificate must match the one this device presented first.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(reference) as? [SecCertificate], let leaf = chain.first else { complete(false); return }
            complete(pins.accepts(CastCertificatePins.fingerprint(of: SecCertificateCopyData(leaf) as Data), for: device))
        }, DispatchQueue(label: "local.native-music.cast-tls"))
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.cellular]
        // The relay is IPv4 only (it binds one private IPv4 address), so the control connection must be too: Network.framework would otherwise race the receiver's
        // addresses and may land on IPv6, leaving a working channel with no way to serve it media.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        // A Bonjour service endpoint has no port; receivers listen on 8009.
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = Mutex(false)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if once.withLock({ let was = $0; $0 = true; return !was }) {
                        self.recordAddresses()
                        self.readLoop()
                        continuation.resume()
                    }
                case .failed, .cancelled:
                    if once.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: CastError.closed) }
                    else { self.finish("connection ended") }
                case .waiting:
                    if once.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: CastError.closed); self.connection.cancel() }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
    private func recordAddresses() {
        func text(_ endpoint: NWEndpoint?) -> String? {
            guard case .hostPort(let host, _)? = endpoint, case .ipv4(let address) = host else { return nil }
            return String(address.debugDescription.split(separator: "%").first ?? "")
        }
        let path = connection.currentPath
        addresses.withLock { $0 = (text(path?.localEndpoint), text(path?.remoteEndpoint)) }
    }
    private func readLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let messages = try decoder.withLock { try $0.append(data) }
                    for message in messages { continuation.yield(.message(message)) }
                } catch { finish("malformed frame"); connection.cancel(); return }
            }
            if error != nil || isComplete { finish("connection ended"); connection.cancel(); return }
            readLoop()
        }
    }
    func send(_ message: CastMessage) async throws {
        let frame = try CastWire.frame(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: CastError.closed) } else { continuation.resume() }
            })
        }
    }
    func close() { finish(nil); connection.cancel() }
    private func finish(_ reason: String?) {
        guard finished.withLock({ let was = $0; $0 = true; return !was }) else { return }
        continuation.yield(.closed(reason)); continuation.finish()
    }
}
