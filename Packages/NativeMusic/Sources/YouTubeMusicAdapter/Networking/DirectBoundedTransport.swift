import Foundation
import Domain

final class RejectNetworkRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
private final class NetworkSessionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private let session: URLSession?
    init(_ session: URLSession? = nil) { self.session = session }
    var open: Bool { lock.withLock { !closed } }
    func close() {
        let shouldClose = lock.withLock { if closed { return false }; closed = true; return true }
        if shouldClose { session?.invalidateAndCancel() }
    }
    deinit { close() }
}
/// Standard TLS and system decompression. No shared cookies, credentials, cache, proxy backend or redirects.
public struct DirectBoundedTransport: Sendable {
    public static let shared = DirectBoundedTransport()
    private let lifetime: NetworkSessionLifetime
    /// Call at application shutdown for the shared pool, or at teardown for an explicitly owned transport.
    public func shutdown() { lifetime.close() }
    private let execute: @Sendable (URLRequest, ResponseBounds) async throws -> BoundedResponse
    public init() { self.init(protocolClasses: nil) }
    /// Internal URLProtocol seam retains the production session/delegate/stream collector and deadline.
    init(protocolClasses: [AnyClass]?) {
        let configuration = Self.configuration()
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: RejectNetworkRedirect(), delegateQueue: nil)
        lifetime = NetworkSessionLifetime(session)
        execute = { request, bounds in
            try await withThrowingTaskGroup(of: BoundedResponse.self) { group in
                group.addTask {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw NetworkFault.schema }
                    let body = try await Self.collect(bytes, expected: http.expectedContentLength, limit: bounds.bytes)
                    return BoundedResponse(status: http.statusCode, body: body,
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After"), cacheControl: http.value(forHTTPHeaderField: "Cache-Control"),
                        age: http.value(forHTTPHeaderField: "Age"), expires: Self.expiry(http.value(forHTTPHeaderField: "Expires")), contentType: http.value(forHTTPHeaderField: "Content-Type"))
                }
                group.addTask { try await Task.sleep(for: .seconds(bounds.seconds)); throw NetworkFault.timeout }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw NetworkFault.transport }
                return value
            }
        }
    }
    private static func expiry(_ header: String?) -> Date? {
        guard let header else { return nil }
        guard header.utf8.count <= 128 else { return .distantPast }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header) ?? .distantPast
    }
    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCredentialStorage = nil; c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 120
        return c
    }
    init(execute: @escaping @Sendable (URLRequest, ResponseBounds) async throws -> BoundedResponse) { self.execute = execute; self.lifetime = NetworkSessionLifetime() }
    static func collect<S: AsyncSequence>(_ stream: S, expected: Int64, limit: Int) async throws -> Data where S.Element == UInt8 {
        guard limit > 0, expected <= limit else { throw NetworkFault.oversized }
        try Task.checkCancellation()
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < limit else { throw NetworkFault.oversized }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
    func send(_ request: BoundedRequest, authorization: String?) async throws -> BoundedResponse {
        guard lifetime.open else { throw NetworkFault.cancelled }
        var wire = URLRequest(url: request.url)
        wire.httpMethod = request.route.method; wire.httpBody = request.body
        wire.timeoutInterval = request.bounds.seconds
        wire.httpShouldHandleCookies = false
        wire.setValue("YTMuse-native/1", forHTTPHeaderField: "User-Agent")
        if request.body != nil { wire.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let authorization {
            guard request.route.credentialAllowed, request.credential != nil, authorization.utf8.count <= 16_384,
                  !authorization.contains("\r"), !authorization.contains("\n") else { throw NetworkFault.policy }
            wire.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        do {
            let response = try await execute(wire, request.bounds)
            guard lifetime.open else { throw NetworkFault.cancelled }
            guard response.body.count <= request.bounds.bytes else { throw NetworkFault.oversized }
            if (300...399).contains(response.status) { throw NetworkFault.redirect }
            return response
        } catch { throw Self.sanitize(error) }
    }
    static func sanitizePreservingLimit(_ error: Error) -> Error {
        if let limit = error as? RateLimitBound { return limit }
        return sanitize(error)
    }
    static func sanitize(_ error: Error) -> NetworkFault {
        if let e = error as? NetworkFault { return e }
        if error is CancellationError { return .cancelled }
        if let e = error as? URLError {
            switch e.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            case .cannotFindHost, .dnsLookupFailed: return .dns
            case .notConnectedToInternet, .networkConnectionLost: return .offline
            default: return .transport
            }
        }
        return .transport
    }
}
