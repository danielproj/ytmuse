import Foundation
import Security
import Synchronization

// W39 (ROUTE07). The decisions of the scoped local relay, with no socket in sight: given the bytes of a request head and who sent it, what is the answer?
// The relay exists only because a Cast receiver fetches its media from a URL and this app's owned and local media is a file on the Mac. Every rule below
// narrows what that URL can be used for. `CastRelayServer` is the thin socket wrapper around this; the abuse tests drive both.
//
//   * ONE item at a time, at a path made of a random per-session token and a random per-item tag. The request path never names a file: the file is
//     fixed on the server side when the item is registered, so there is no traversal to attempt. Anything but the exact path is a uniform 404.
//   * GET only (a Range header is a GET). Every other method is 405. A GET carrying a body is refused.
//   * A bounded lifetime, a request budget and a connection cap. After the lifetime, a revoke or a session end, every request is a 404.
//   * Served only to the receiver's own address (and to loopback when bound to loopback, which is what tests do), and bound to one private LAN address.
//   * Audio files only, from an allowlist of types; the file is pinned by size and modification time, and a changed file is a 404.
//   * No filesystem path, no account, token or cookie appears in any response, and no developer backend is involved.

public struct CastRelayLimits: Sendable, Equatable {
    public var maxLifetime: Duration = .seconds(6 * 3600)
    public var maxRequests = 4_000
    public var maxConnections = 6
    public var maxHeadBytes = 8_192
    public var readTimeout: Duration = .seconds(10)
    /// After the request head: a connection that makes no progress sending (a reader that stopped reading) for this long is cut, so such readers cannot hold the cap.
    public var idleTimeout: Duration = .seconds(15)
    public var maxFileBytes: Int64 = 4 << 30
    public init() {}
}

public enum CastRelayError: Error, Equatable, Sendable {
    case notRegularFile, tooLarge, unsupportedType(String), expired, notStarted, bindRefused(String)
}

public struct CastRelayResponse: Equatable, Sendable {
    public struct Body: Equatable, Sendable { public let file: URL, offset: UInt64, length: UInt64 }
    public let status: Int
    public let headers: [(name: String, value: String)]
    public let body: Body?
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.status == rhs.status && lhs.body == rhs.body && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
    }
    static let reasons = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable", 429: "Too Many Requests", 431: "Request Header Fields Too Large"]
    /// The status line and headers, ready to send.
    public var head: Data {
        var text = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Error")\r\n"
        for header in headers { text += "\(header.name): \(header.value)\r\n" }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }
}

public enum CastRelayDecision: Equatable, Sendable {
    /// Close the connection without a word (a peer that has no business here learns nothing).
    case drop
    case respond(CastRelayResponse)
}

public final class CastRelayCore: @unchecked Sendable {
    public let limits: CastRelayLimits
    /// The path every request must start with: `/c/<token>/`. 128 bits from the system's secure random generator, fresh for each relay.
    public let token: String
    private struct Item { let file: URL; let size: UInt64; let modified: Date; let contentType: String; let tag: String; let fileExtension: String }
    private struct State {
        var item: Item?; var requests = 0; var servedBytes: UInt64 = 0; var revoked = false
    }
    private let state = Mutex(State())
    private let now: @Sendable () -> ContinuousClock.Instant
    private let startedAt: ContinuousClock.Instant
    public let receiverAddress: String?
    private let receiver: String?
    private let bound: String

    /// `bound` is the address the listener is bound to; `receiver` the only remote address served (nil: nobody, which only a loopback bind can fix).
    public init(bound: String, receiver: String?, limits: CastRelayLimits = CastRelayLimits(), now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.bound = bound; self.receiver = receiver; receiverAddress = receiver; self.limits = limits; self.now = now; startedAt = now()
        token = Self.randomToken(bytes: 16)
    }
    static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "no secure random bytes")
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static let types: [String: String] = ["wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "flac": "audio/flac", "ogg": "audio/ogg", "opus": "audio/ogg"]

    /// Registers the one item the relay serves, replacing any earlier one (whose path then answers 404). Returns the path the receiver is given.
    public func register(file: URL) throws -> String {
        let resolved = file.resolvingSymlinksInPath()
        let ext = resolved.pathExtension.lowercased()
        guard let type = Self.types[ext] else { throw CastRelayError.unsupportedType(ext) }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else { throw CastRelayError.notRegularFile }
        guard Int64(size) <= limits.maxFileBytes else { throw CastRelayError.tooLarge }
        guard !isExpired else { throw CastRelayError.expired }
        let tag = Self.randomToken(bytes: 9)
        state.withLock { $0.item = Item(file: resolved, size: UInt64(size), modified: modified, contentType: type, tag: tag, fileExtension: ext); $0.revoked = false }
        return "/c/\(token)/\(tag).\(ext)"
    }
    /// Ends the relay's usefulness at once: every later request is a 404.
    public func revoke() { state.withLock { $0.item = nil; $0.revoked = true } }
    public var isExpired: Bool { now() - startedAt >= limits.maxLifetime }
    public var requestCount: Int { state.withLock { $0.requests } }
    public var servedBytes: UInt64 { state.withLock { $0.servedBytes } }
    public func noteServed(_ bytes: UInt64) { state.withLock { $0.servedBytes += bytes } }

    private func plain(_ status: Int, extra: [(name: String, value: String)] = []) -> CastRelayDecision {
        .respond(CastRelayResponse(status: status, headers: [("Content-Length", "0"), ("Cache-Control", "no-store")] + extra, body: nil))
    }
    private func notFound() -> CastRelayDecision { plain(404) }

    /// The answer to one request head (everything up to and including the blank line).
    public func decide(head: Data, peer: String) -> CastRelayDecision {
        guard CastNetworkGate.peerAllowed(peer, receiver: receiver, boundTo: bound) else { return .drop }
        guard head.count <= limits.maxHeadBytes else { return plain(431) }
        let over = state.withLock { state -> Bool in state.requests += 1; return state.requests > limits.maxRequests }
        if over { return plain(429) }
        if isExpired { revoke(); return notFound() }
        guard let text = String(data: head, encoding: .utf8), !text.contains("\0"), text.hasSuffix("\r\n\r\n") else { return plain(400) }
        // "\r\n" is ONE Character in Swift, so the terminator is removed as two Characters, not four; a stray CR or LF inside a line is a malformed head.
        var lines = String(text.dropLast(2)).components(separatedBy: "\r\n")
        guard !lines.contains(where: { $0.unicodeScalars.contains { $0 == "\r" || $0 == "\n" } }) else { return plain(400) }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0", lines.count <= 40 else { return plain(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return plain(400) }
            let name = line[..<colon].lowercased()
            guard !name.contains(" ") else { return plain(400) }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Method before path: every method but GET is refused whatever the path, so the answer says nothing about which paths exist.
        guard requestLine[0] == "GET" else { return plain(405, extra: [("Allow", "GET")]) }
        if let length = headers["content-length"], length != "0" { return plain(400) }
        if headers["transfer-encoding"] != nil { return plain(400) }
        guard let item = state.withLock({ $0.revoked ? nil : $0.item }), Self.pathMatches(String(requestLine[1]), token: token, item: (item.tag, item.fileExtension)) else { return notFound() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: item.file.path),
              (attributes[.size] as? NSNumber)?.uint64Value == item.size, (attributes[.modificationDate] as? Date) == item.modified else { return notFound() }
        let base: [(name: String, value: String)] = [("Content-Type", item.contentType), ("Accept-Ranges", "bytes"), ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"),
                                                     ("Access-Control-Allow-Origin", "*"), ("Access-Control-Allow-Headers", "Range"), ("Access-Control-Expose-Headers", "Content-Range, Content-Length, Accept-Ranges")]
        guard let range = headers["range"] else {
            return .respond(CastRelayResponse(status: 200, headers: base + [("Content-Length", String(item.size))], body: .init(file: item.file, offset: 0, length: item.size)))
        }
        guard let span = Self.parseRange(range, size: item.size) else {
            return .respond(CastRelayResponse(status: 416, headers: [("Content-Range", "bytes */\(item.size)"), ("Content-Length", "0"), ("Cache-Control", "no-store")], body: nil))
        }
        return .respond(CastRelayResponse(status: 206, headers: base + [("Content-Range", "bytes \(span.lowerBound)-\(span.upperBound)/\(item.size)"), ("Content-Length", String(span.upperBound - span.lowerBound + 1))],
                                          body: .init(file: item.file, offset: span.lowerBound, length: span.upperBound - span.lowerBound + 1)))
    }

    /// The exact path `/c/<token>/<tag>.<ext>` and nothing else: no query, no fragment, no percent-encoding, no dot segments, no second slash.
    static func pathMatches(_ target: String, token: String, item: (tag: String, ext: String)) -> Bool {
        let expected = "/c/\(token)/\(item.tag).\(item.ext)"
        let a = Array(target.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count { difference |= a[index] ^ b[index] }   // constant time: the token is a secret
        return difference == 0
    }
    /// A single `bytes=a-b`, `bytes=a-` or `bytes=-n` range inside the file, or nil (multi-range, malformed or outside the file: 416).
    static func parseRange(_ value: String, size: UInt64) -> ClosedRange<UInt64>? {
        guard size > 0, value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let spec = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard spec.count == 2, spec[0].count <= 19, spec[1].count <= 19, (spec[0] + spec[1]).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        switch (UInt64(spec[0]), UInt64(spec[1])) {
        case (let first?, let last?): guard first <= last, first < size else { return nil }; return first...min(last, size - 1)
        case (let first?, nil): guard !spec[0].isEmpty, first < size else { return nil }; return first...(size - 1)
        case (nil, let suffix?): guard suffix > 0 else { return nil }; return (size - min(suffix, size))...(size - 1)
        default: return nil
        }
    }
}
