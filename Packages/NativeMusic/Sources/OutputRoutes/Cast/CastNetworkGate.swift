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

    /// TH4: an IPv6 address, parsed strictly (RFC 4291 text forms: eight groups, one `::`, no embedded IPv4, no brackets, no leading or trailing colon outside `::`).
    /// The relay may serve IPv6 on the same terms as IPv4: loopback (tests), a unique-local address (`fc00::/7`) or a link-local one (`fe80::/10`, which names its
    /// interface as a zone: `fe80::1%en0`). Never the unspecified address, a multicast, a global unicast (public) or an IPv4-mapped address.
    public struct IPv6: Equatable, Sendable {
        public let groups: [UInt16]
        /// The interface name after `%`, for a link-local address.
        public let zone: String?
        public init?(_ text: String) {
            var body = Substring(text)
            var zone: String?
            if let percent = body.firstIndex(of: "%") {
                let name = body[body.index(after: percent)...]
                guard (1...15).contains(name.count), name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }) else { return nil }
                zone = String(name); body = body[..<percent]
            }
            guard body.contains(":"), body.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":") }) else { return nil }
            let halves = body.components(separatedBy: "::")
            guard halves.count <= 2 else { return nil }
            func groups(_ part: String) -> [UInt16]? {
                if part.isEmpty { return [] }
                var result: [UInt16] = []
                for piece in part.split(separator: ":", omittingEmptySubsequences: false) {
                    guard (1...4).contains(piece.count), let value = UInt16(piece, radix: 16) else { return nil }
                    result.append(value)
                }
                return result
            }
            guard let head = groups(halves[0]) else { return nil }
            if halves.count == 1 {
                guard head.count == 8 else { return nil }
                self.groups = head
            } else {
                guard let tail = groups(halves[1]), head.count + tail.count <= 7 else { return nil }
                self.groups = head + [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail
            }
            self.zone = zone
        }
        public var isUnspecified: Bool { groups.allSatisfy { $0 == 0 } }
        public var isLoopback: Bool { groups == [0, 0, 0, 0, 0, 0, 0, 1] }
        public var isLinkLocal: Bool { groups[0] & 0xffc0 == 0xfe80 }
        public var isUniqueLocal: Bool { groups[0] & 0xfe00 == 0xfc00 }
        /// The networks a receiver on a home network is on: unique-local and link-local (never global unicast, which is public).
        public var isPrivateLAN: Bool { isUniqueLocal || isLinkLocal }
        /// The same address regardless of zone: a peer's zone is the interface it arrived on, which is not part of its identity.
        public func sameAddress(as other: IPv6) -> Bool { groups == other.groups }
        /// The form used in a URL host: bracketed, with a zone percent-encoded (`[fe80::1%25en0]`).
        public var urlHost: String {
            "[" + groups.map { String($0, radix: 16) }.joined(separator: ":") + (zone.map { "%25" + $0 } ?? "") + "]"
        }
    }

    /// Whether the relay may listen on `address`: a loopback address always (that is what tests use); otherwise only a private LAN address, never the
    /// wildcard, and only when the real network has been enabled. IPv6 follows the same rules (`IPv6`); a link-local address must name its interface.
    public static func requireBindable(_ address: String) throws {
        if address.contains(":") {
            guard let ip = IPv6(address) else { throw Refusal.notLocalAddress("not an address") }
            if ip.isUnspecified { throw Refusal.wildcardAddress }
            if ip.isLoopback { guard ip.zone == nil else { throw Refusal.notLocalAddress("not an address") }; return }
            guard ip.isPrivateLAN, !ip.isLinkLocal || ip.zone != nil, ip.isLinkLocal || ip.zone == nil else { throw Refusal.notLocalAddress("not a private network address") }
            try requireLive()
            return
        }
        guard let ip = IPv4(address) else { throw address.isEmpty ? Refusal.notIPv4 : Refusal.notLocalAddress("not an address") }
        if ip.isUnspecified { throw Refusal.wildcardAddress }
        if ip.isLoopback { return }
        guard ip.isPrivateLAN else { throw Refusal.notLocalAddress("not a private network address") }
        try requireLive()
    }
    /// Whether a connecting peer may be served: the receiver itself (same family, same address), or (only on a loopback bind) a loopback peer.
    public static func peerAllowed(_ peer: String, receiver: String?, boundTo bind: String) -> Bool {
        if let peerIP = IPv4(peer) {
            if let receiver, let receiverIP = IPv4(receiver), receiverIP == peerIP { return true }
            if let bindIP = IPv4(bind), bindIP.isLoopback, peerIP.isLoopback { return true }
            return false
        }
        guard let peerIP = IPv6(peer) else { return false }
        if let receiver, let receiverIP = IPv6(receiver), receiverIP.sameAddress(as: peerIP) { return true }
        if let bindIP = IPv6(bind), bindIP.isLoopback, peerIP.isLoopback { return true }
        return false
    }
    /// The host part of the URL the receiver is given for a relay bound to `address`.
    public static func urlHost(for address: String) -> String { IPv6(address)?.urlHost ?? address }
}
