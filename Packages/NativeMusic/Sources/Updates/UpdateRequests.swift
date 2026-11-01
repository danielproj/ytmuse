import Foundation

/// The network the updater uses, as a protocol: the feed is read into memory (bounded), the asset is written to a file (bounded). A fake serves
/// tests; `URLSessionUpdateNetwork` is the real one.
public protocol UpdateNetwork: Sendable {
    func get(_ request: URLRequest, maxBytes: Int) async throws -> Data
    func download(_ request: URLRequest, to destination: URL, maxBytes: Int) async throws
}

/// The ONLY place an update request is built (T30.3). It is a plain GET of a fixed https URL: no query, no body, no cookies, no credentials, no
/// identifiers. The headers are the three below and nothing else. The user agent is constant: it does not carry the installed version, the system
/// version, a machine or account identifier. The server learns that somebody asked for the file, as any static host does.
public enum UpdateRequests {
    public static let userAgent = "YTMuse-Updater"
    /// The headers this code sets. `Accept-Language` is a constant: left unset, CFNetwork would add the Mac's language list, which is device information. The transport adds only Host, Connection and Cache-Control.
    public static let allowedHeaderNames: Set<String> = ["Accept", "User-Agent", "Accept-Encoding", "Accept-Language"]
    public static func feed(_ url: URL) -> URLRequest { make(url, accept: "application/json") }
    public static func asset(_ url: URL) -> URLRequest { make(url, accept: "application/octet-stream") }
    private static func make(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.httpShouldUsePipelining = false
        request.allowsCellularAccess = true
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }
    /// The feed location from the application's own configuration: https, the pinned repository's GitHub release downloads, no query.
    public static func feedURL(_ text: String, policy: UpdateTrustPolicy) -> URL? {
        let expected = "https://github.com/\(policy.repository)/releases/latest/download/feed.json"
        return text == expected ? URL(string: text) : nil
    }
}

/// The network the app uses for updates (the composition root takes this, so no view-layer file names a URL session).
public enum SystemUpdateNetwork { public static func make() -> any UpdateNetwork { URLSessionUpdateNetwork() } }

/// A session with nothing to leak: ephemeral (no disk cache, no cookie jar, no credential storage), no proxy-auth prompts, redirects only to https on
/// GitHub's release hosts. The bytes are checked by the verifier, so the host allowlist is defence in depth, not the trust anchor.
public final class URLSessionUpdateNetwork: NSObject, UpdateNetwork, URLSessionTaskDelegate, @unchecked Sendable {
    public static func allowedRedirectHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }
    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = [:]
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = URLSessionUpdateNetwork.configuration()) {
        let delegate = RedirectPolicy()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        super.init()
    }
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard request.url?.scheme == "https", URLSessionUpdateNetwork.allowedRedirectHost(request.url?.host) else { completionHandler(nil); return }
            var next = request
            next.httpShouldHandleCookies = false
            completionHandler(next)
        }
    }
    public func get(_ request: URLRequest, maxBytes: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        try Self.check(response, maxBytes: maxBytes)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw UpdateRejection.tooLarge }
        }
        return data
    }
    public func download(_ request: URLRequest, to destination: URL, maxBytes: Int) async throws {
        let (file, response) = try await session.download(for: request)
        defer { UpdateFiles.standard.discardTemporary(file) }
        try Self.check(response, maxBytes: maxBytes)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        guard size <= maxBytes else { throw UpdateRejection.tooLarge }
        try UpdateFiles.standard.placeDownload(file, at: destination)
    }
    private static func check(_ response: URLResponse, maxBytes: Int) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateRejection.transport("status") }
        if http.expectedContentLength > Int64(maxBytes) { throw UpdateRejection.tooLarge }
    }
}
