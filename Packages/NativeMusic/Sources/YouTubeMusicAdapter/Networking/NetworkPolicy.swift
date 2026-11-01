import Foundation
import Domain

/// Only local categories and correlation IDs may enter diagnostics. Never retain wire errors.
public enum NetworkFault: String, Error, Sendable, Equatable {
    case policy, input, cancelled, stale, timeout, dns, offline, transport, forbidden, authentication
    case rateLimited, server, http, redirect, oversized, contentType, schema, operation, image
}
public enum NetworkPurpose: String, Sendable, Hashable { case metadata, artwork, media }
public enum ReplaySafety: Sendable, Hashable { case knownRead, mutation, unknown }
public struct ResponseBounds: Sendable {
    public let bytes: Int
    public let seconds: TimeInterval
    public let jsonDepth: Int
    public let jsonNodes: Int
    public let imagePixels: Int
    public init(bytes: Int = 4_000_000, seconds: TimeInterval = 30, jsonDepth: Int = 48,
                jsonNodes: Int = 100_000, imagePixels: Int = 16_000_000) throws {
        guard (1...16_000_000).contains(bytes), seconds.isFinite, seconds > 0, seconds <= 120,
              (1...64).contains(jsonDepth), (1...200_000).contains(jsonNodes), (1...40_000_000).contains(imagePixels) else { throw NetworkFault.input }
        self.bytes = bytes; self.seconds = seconds; self.jsonDepth = jsonDepth
        self.jsonNodes = jsonNodes; self.imagePixels = imagePixels
    }
}
/// An exact reviewed route, not a suffix match or permission to probe arbitrary hosts.
/// Composition must supply approved routes; this layer ships no new Music access grant.
public struct NetworkRoute: Hashable, Sendable {
    public let host: String
    public let path: String
    public let method: String
    public let purpose: NetworkPurpose
    public let queryNames: Set<String>
    public let credentialAllowed: Bool
    public let replay: ReplaySafety
    public init(host: String, path: String, method: String, purpose: NetworkPurpose,
                queryNames: Set<String> = [], credentialAllowed: Bool = false, replay: ReplaySafety = .unknown) throws {
        guard host == host.lowercased(), host.contains("."), !host.contains(":"),
              host.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)*$"#, options: .regularExpression) != nil, Self.isPublicName(host),
              path.hasPrefix("/"), !path.contains("%"), !path.contains(".."), !path.contains("?"),
              ["GET", "POST", "PUT", "DELETE"].contains(method),
              queryNames.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw NetworkFault.policy }
        self.host = host; self.path = path; self.method = method; self.purpose = purpose
        self.queryNames = queryNames; self.credentialAllowed = credentialAllowed; self.replay = replay
    }
}
extension NetworkRoute {
    /// W29 (SEC05, T29.2). A route names a public DNS host, never an address and never a name that only resolves on a private network. An allowlist already decides which
    /// routes exist; this keeps a route from ever being BUILT for loopback, a private or link-local address (in any spelling: dotted, short, octal or hex), a
    /// multicast/local name (`.local`, `.localhost`, `.internal`, `.lan`, `.home.arpa`) or a one-label name, so an arbitrary link cannot become a local-network request.
    static func isPublicName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let top = labels.last else { return false }
        // An address in any spelling (dotted, short, octal, hex): the last label is a number, or every label is.
        func numeric(_ label: String) -> Bool { label.allSatisfy(\.isNumber) || (label.hasPrefix("0x") && label.dropFirst(2).allSatisfy(\.isHexDigit)) }
        if numeric(top) || labels.allSatisfy(numeric) { return false }
        let special: Set<String> = ["local", "localhost", "localdomain", "internal", "lan", "home", "intranet", "private", "arpa", "invalid", "onion"]
        return !special.contains(top) && !labels.contains("localhost")
    }
}
public struct BoundedRequest: Sendable {
    public let route: NetworkRoute
    public let url: URL
    public let body: Data?
    public let bounds: ResponseBounds
    public let credential: CredentialReference?
    public init(route: NetworkRoute, url: URL, body: Data? = nil, bounds: ResponseBounds,
                credential: CredentialReference? = nil) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
              c.host == route.host, c.port == nil, c.user == nil, c.password == nil, c.fragment == nil,
              c.percentEncodedPath == route.path, (c.queryItems ?? []).allSatisfy({ route.queryNames.contains($0.name) }),
              (c.queryItems?.count ?? 0) <= 32, url.absoluteString.utf8.count <= 8192,
              (body?.count ?? 0) <= 65_536, credential == nil || route.credentialAllowed else { throw NetworkFault.policy }
        self.route = route; self.url = url; self.body = body; self.bounds = bounds; self.credential = credential
    }
}
public struct BoundedResponse: Sendable {
    public let status: Int
    public let body: Data
    /// Only policy headers; no cookies, locations, server messages or URLs survive transport.
    public let retryAfter: String?
    public let cacheControl: String?
    public let age: String?
    public let expires: Date?
    public let contentType: String?
    public init(status: Int, body: Data, retryAfter: String? = nil, cacheControl: String? = nil,
                age: String? = nil, expires: Date? = nil, contentType: String? = "application/json") {
        self.status = status; self.body = body; self.retryAfter = retryAfter
        self.cacheControl = cacheControl; self.age = age; self.expires = expires; self.contentType = contentType
    }
}
public protocol NetworkTime: Sendable {
    func now() -> TimeInterval
    func wallNow() -> Date
    func sleep(until: TimeInterval) async throws
}
public struct ContinuousNetworkTime: NetworkTime {
    private let origin = ContinuousClock.now
    public init() {}
    public func now() -> TimeInterval { let d = origin.duration(to: .now).components; return Double(d.seconds) + Double(d.attoseconds) / 1e18 }
    public func wallNow() -> Date { Date() }
    public func sleep(until deadline: TimeInterval) async throws { try await Task.sleep(for: .seconds(max(0, deadline - now()))) }
}
public protocol ScopedNetworkCredentials: Sendable {
    /// Resolve only a protected reference for this exact account/channel/generation.
    func authorization(reference: CredentialReference, context: RequestContext) async throws -> String
}
public struct NetworkDiagnostic: Sendable, CustomStringConvertible {
    public let id: UUID
    public let fault: NetworkFault
    public init(id: UUID, fault: NetworkFault) { self.id = id; self.fault = fault }
    public var description: String { "network \(id.uuidString) \(fault.rawValue)" }
}

public struct NetworkIssue: Error, Sendable, Equatable {
    public let fault: NetworkFault
    public let retryAfterSeconds: TimeInterval?
    public init(fault: NetworkFault, retryAfterSeconds: TimeInterval? = nil) { self.fault = fault; self.retryAfterSeconds = retryAfterSeconds }
}
public struct NetworkEnvelope: Sendable {
    public let context: RequestContext
    public let outcome: Result<BoundedResponse, NetworkIssue>
    public init(context: RequestContext, outcome: Result<BoundedResponse, NetworkIssue>) { self.context = context; self.outcome = outcome }
}

// Safe ordinary/debug descriptions keep accidental structured log capture from exposing wire contents. W29 (T29.1): `dump`, `po` and every Mirror-based printer
// read the stored properties, not the description, so each type also hides its children. A request holds the URL (a search term rides in its query), the body and
// the credential reference; a response holds the body and the cookie-adjacent headers.
extension BoundedRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "bounded network request" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
extension BoundedResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "bounded network response" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
extension NetworkEnvelope: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "scoped network outcome" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
