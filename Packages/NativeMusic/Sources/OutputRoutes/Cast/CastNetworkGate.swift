import Foundation
import Synchronization

// W39 (real-data and network safety). The one switch between "tests and isolated runs" and "the real network". It starts DENIED. Only the app
// composition of a normal (non-isolated) launch turns it on, and it cannot be turned on inside a test process. Every real network piece (the Bonjour
// browser, the TLS connection to a receiver, the relay's listening socket) asks it first, so a test target that constructs one by mistake gets an error
// instead of a browse, a connection or an open port. `CastNetworkGuardTests` also sweeps every test source for the real types.

public enum CastNetworkGate {
    public enum Refusal: Error, Equatable, Sendable { case notEnabled, testProcess, wildcardAddress, notLocalAddress(String), notIPv4 }

    private static let live = Mutex(false)

    /// A unit-test or UI-test runner process. Swift Testing runs under `swiftpm-testing-helper`, XCTest under `xctest`.
    public static var isTestProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil || environment["XCTestSessionIdentifier"] != nil { return true }
        let name = ProcessInfo.processInfo.processName.lowercased()
        if name.contains("xctest") || name.contains("testing-helper") || name.contains("swiftpm") { return true }
        return Bundle.main.bundlePath.hasSuffix(".xctest") || NSClassFromString("XCTestCase") != nil
    }
    /// Turns the real network on for this process. Refused in a test process.
    public static func enableLive() throws {
        guard !isTestProcess else { throw Refusal.testProcess }
        live.withLock { $0 = true }
    }
    public static func disableLive() { live.withLock { $0 = false } }
    public static var isLive: Bool { live.withLock { $0 } && !isTestProcess }
    /// Required before browsing for receivers or opening a connection to one.
    public static func requireLive() throws {
        guard !isTestProcess else { throw Refusal.testProcess }
        guard live.withLock({ $0 }) else { throw Refusal.notEnabled }
    }

    // MARK: Addresses the relay may bind to

    public struct IPv4: Equatable, Sendable {
        public let octets: [UInt8]
        public init?(_ text: String) {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var values: [UInt8] = []
            for part in parts {
                guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt8(part), String(value) == part else { return nil }
                values.append(value)
            }
            octets = values
        }
        public var isUnspecified: Bool { octets == [0, 0, 0, 0] }
        public var isLoopback: Bool { octets[0] == 127 }
        /// RFC 1918 private ranges and the link-local range: the networks a receiver on a home network is on.
        public var isPrivateLAN: Bool {
            (octets[0] == 10) || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
        }
        public var text: String { octets.map(String.init).joined(separator: ".") }
    }

    /// Whether the relay may listen on `address`: a loopback address always (that is what tests use); otherwise only a private LAN address, never the
    /// wildcard, and only when the real network has been enabled.
    public static func requireBindable(_ address: String) throws {
        guard let ip = IPv4(address) else { throw address.contains(":") || address.isEmpty ? Refusal.notIPv4 : Refusal.notLocalAddress("not an address") }
        if ip.isUnspecified { throw Refusal.wildcardAddress }
        if ip.isLoopback { return }
        guard ip.isPrivateLAN else { throw Refusal.notLocalAddress("not a private network address") }
        try requireLive()
    }
    /// Whether a connecting peer may be served: the receiver itself, or (only on a loopback bind) a loopback peer.
    public static func peerAllowed(_ peer: String, receiver: String?, boundTo bind: String) -> Bool {
        guard let peerIP = IPv4(peer) else { return false }
        if let receiver, let receiverIP = IPv4(receiver), receiverIP == peerIP { return true }
        if let bindIP = IPv4(bind), bindIP.isLoopback, peerIP.isLoopback { return true }
        return false
    }
}
