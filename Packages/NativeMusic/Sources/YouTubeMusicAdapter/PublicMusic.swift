import Foundation
import AccountSession

public enum ConnectionError: Error, Equatable { case invalidInput, origin, oversized, http(Int), service, shape, stale, expired }
public struct PublicHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public init(data: Data, status: Int) { self.data = data; self.status = status }
}
public protocol PublicHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse
}
final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
/// Cookies, credentials and disk caches are disabled. Bodies stop at the byte limit.
public actor DirectPublicTransport: PublicHTTPTransport {
    private var next: TimeInterval = 0
    private let clock: any ConnectionClock
    private let execute: @Sendable (URLRequest, Int) async throws -> PublicHTTPResponse
    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCredentialStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 30
        let session = URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
        clock = SystemConnectionClock()
        execute = { request, limit in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ConnectionError.shape }
            let data = try await Self.collect(bytes, expectedLength: http.expectedContentLength, limit: limit)
            return .init(data: data, status: http.statusCode)
        }
    }
    /// Internal seam replaces only I/O/clock. The same public allowlist and pacing
    /// run before it. Production has no constructor accepting arbitrary sessions.
    init(clock: any ConnectionClock, execute: @escaping @Sendable (URLRequest, Int) async throws -> PublicHTTPResponse) {
        self.clock = clock; self.execute = execute
    }
    static func collect<S: AsyncSequence>(_ bytes: S, expectedLength: Int64, limit: Int) async throws -> Data where S.Element == UInt8 {
        guard limit > 0, expectedLength <= limit else { throw ConnectionError.oversized }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw ConnectionError.oversized }
            data.append(byte)
        }
        return data
    }
    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse {
        guard let url = request.url, url.scheme == "https", url.host == "music.youtube.com", url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              (url.path == "/" && (request.httpMethod ?? "GET") == "GET" && url.query == nil) ||
                (["/youtubei/v1/search", "/youtubei/v1/player", "/youtubei/v1/browse", "/youtubei/v1/next"].contains(url.path) && request.httpMethod == "POST" && url.query == "prettyPrint=false"),
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil, request.value(forHTTPHeaderField: "Host") == nil,
              (request.httpBody?.count ?? 0) <= 32_768, maximumBytes > 0, maximumBytes <= 4_000_000 else { throw ConnectionError.origin }
        let reserved = max(next, clock.now()); next = reserved + 1
        try await clock.sleep(until: reserved)
        try Task.checkCancellation()
        return try await execute(request, maximumBytes)
    }
}
public struct PublicMusicConfiguration: Sendable {
    public let clientVersion: String
    public let validUntil: TimeInterval
    public init(homepage: Data, clock: any ConnectionClock = SystemConnectionClock()) throws {
        guard homepage.count <= 4_000_000, let text = String(data: homepage, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #""INNERTUBE_CLIENT_VERSION"\s*:\s*"([A-Za-z0-9._-]{1,128})""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { throw ConnectionError.shape }
        clientVersion = String(text[range]); validUntil = clock.now() + 1800
        // Only the site's actual web Music identity is selected. No fallback platforms.
        guard clientVersion.utf8.count <= 128, text.contains("WEB_REMIX") else { throw ConnectionError.shape }
    }
}
public struct PublicMusicItem: Sendable, Equatable, Codable {
    public let videoID: String
    public let title: String
}
public struct PublicSearchReceipt: Sendable {
    public let requestID: UUID
    public let generation: UInt64
    public let query: String
    public let hl: String
    public let gl: String?
    public let items: [PublicMusicItem]
    public let capped: Bool
    /// This narrow parser has no pagination API; it does not claim catalog completeness.
    public let coverageComplete: Bool
}
public struct PublicMusicDetail: Sendable, Equatable {
    public let requestID: UUID
    public let hl: String
    public let gl: String?
    public let requestedVideoID: String
    public let title: String?
    public let status: String
    public let generation: UInt64
}
/// W28 (L10N03): the language and region hints a request carries, asked for on EVERY request so a changed setting applies to the next one. A malformed hint is
/// replaced by the default (`en`, no region) instead of disabling the client. The region is a hint for what is suggested; it never decides availability.
public struct ContentLocaleHint: Sendable, Equatable {
    public let hl: String
    public let gl: String?
    public static let `default` = ContentLocaleHint(hl: "en", gl: nil)
    public init(hl: String, gl: String?) {
        let goodLanguage = hl.range(of: #"^[a-z]{2,3}(?:-[A-Za-z]{4})?$"#, options: .regularExpression) != nil
        let goodRegion = gl.map { $0.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil } ?? true
        self.hl = goodLanguage ? hl : "en"; self.gl = goodRegion ? gl : nil
    }
}
public typealias ContentLocaleProvider = @Sendable () -> ContentLocaleHint
public actor PublicMusicClient {
    private let transport: any PublicHTTPTransport
    private var generation: UInt64 = 0
    private var searchToken: UUID?
    private var detailTokens: [String: UUID] = [:]
    private let clock: any ConnectionClock
    private let fixedHint: ContentLocaleHint
    private let provider: ContentLocaleProvider?
    private var hint: ContentLocaleHint { provider?() ?? fixedHint }
    private var hl: String { hint.hl }
    private var gl: String? { hint.gl }
    private var config: PublicMusicConfiguration?
    public init(transport: any PublicHTTPTransport = DirectPublicTransport(), clock: any ConnectionClock = SystemConnectionClock(), hl: String = "en", gl: String? = nil, locale: ContentLocaleProvider? = nil) throws {
        guard hl.range(of: #"^[a-z]{2,3}(?:-[A-Za-z]{2,4})?$"#, options: .regularExpression) != nil,
              gl == nil || gl!.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil else { throw ConnectionError.invalidInput }
        self.transport = transport; self.clock = clock; self.fixedHint = ContentLocaleHint(hl: hl, gl: gl); self.provider = locale
    }
    private func clientContext(_ config: PublicMusicConfiguration) -> [String: String] {
        var value = ["clientName": "WEB_REMIX", "clientVersion": config.clientVersion, "hl": hl]
        if let gl { value["gl"] = gl }; return value
    }
    public func invalidate() { generation &+= 1; config = nil; searchToken = nil; detailTokens = [:] }
    public func bootstrap() async throws -> PublicMusicConfiguration {
        let captured = generation
        var request = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        request.setValue("Mozilla/5.0 (Macintosh; Mac OS X 27_0_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.1 Safari/605.1.15 YTMuse/0.1", forHTTPHeaderField: "User-Agent")
        let response = try await transport.send(request, maximumBytes: 4_000_000)
        try Task.checkCancellation()
        guard captured == generation else { throw ConnectionError.stale }
        guard response.status == 200 else { throw ConnectionError.http(response.status) }
        let value = try PublicMusicConfiguration(homepage: response.data, clock: clock); config = value; return value
    }
    public func search(_ query: String, limit: Int = 10) async throws -> PublicSearchReceipt {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 512,
              (1...25).contains(limit) else { throw ConnectionError.invalidInput }
        guard let config, clock.now() < config.validUntil else { throw ConnectionError.expired }
        let captured = generation; let requestID = UUID(); searchToken = requestID
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Mac OS X 27_0_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.1 Safari/605.1.15 YTMuse/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context": ["client": clientContext(config)], "query": query])
        let response = try await transport.send(request, maximumBytes: 2_000_000)
        try Task.checkCancellation()
        guard captured == generation else { throw ConnectionError.stale }
        guard searchToken == requestID else { throw ConnectionError.stale }
        let items = try Self.parseSearch(response)
        return .init(requestID: requestID, generation: captured, query: query, hl: hl, gl: gl, items: Array(items.prefix(limit)), capped: items.count > limit, coverageComplete: false)
    }
    /// Anonymous `search`, parsed into typed rows. Bootstraps the client version when needed.
    /// A reply is accepted only if neither `invalidate()` nor a newer search happened meanwhile.
    public func searchResponse(_ query: String) async throws -> MusicSearchResponse {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 512 else { throw ConnectionError.invalidInput }
        if config.map({ clock.now() >= $0.validUntil }) ?? true { _ = try await bootstrap() }
        guard let config, clock.now() < config.validUntil else { throw ConnectionError.expired }
        let captured = generation; let requestID = UUID(); searchToken = requestID
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Mac OS X 27_0_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.1 Safari/605.1.15 YTMuse/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context": ["client": clientContext(config)], "query": query])
        let response = try await transport.send(request, maximumBytes: 2_000_000)
        try Task.checkCancellation()
        guard captured == generation, searchToken == requestID else { throw ConnectionError.stale }
        return try Self.parseSearchResponse(response)
    }
    /// Anonymous `browse` of one page (Home, Explore, charts, moods, an album, artist, playlist or podcast show), parsed
    /// into typed shelves. Identifiers travel only in the POST body; nothing is placed in the URL or logged.
    public func browsePage(id: String, params: String? = nil) async throws -> MusicBrowsePage {
        guard MusicBrowseParser.isBrowseID(id), params.map(MusicBrowseParser.isParams) ?? true else { throw ConnectionError.invalidInput }
        var body: [String: Any] = ["browseId": id]
        if let params { body["params"] = params }
        return try Self.parseBrowse(try await browsePost(body))
    }
    /// Anonymous continuation of a shelf or page (lazy pagination).
    public func browseContinuation(token: String) async throws -> MusicContinuationPage {
        guard MusicBrowseParser.isToken(token) else { throw ConnectionError.invalidInput }
        return try Self.parseBrowseContinuation(try await browsePost(["continuation": token]))
    }
    /// Anonymous `browse` of a podcast episode page (`MPED…`).
    public func episodePage(id: String) async throws -> MusicEpisodePage {
        guard MusicBrowseParser.isBrowseID(id) else { throw ConnectionError.invalidInput }
        let response = try await browsePost(["browseId": id])
        guard response.status == 200 else { throw ConnectionError.http(response.status) }
        guard response.data.count <= 4_000_000 else { throw ConnectionError.oversized }
        do { return try MusicEpisodeParser.parse(try SignedMusicClient.json(response.data)) } catch { throw ConnectionError.shape }
    }
    /// Anonymous lyrics: the song's `next` (where the Lyrics tab is), then the lyrics page it names. A song whose `next` offers no lyrics page
    /// is `.none(.notOffered)`; a response that cannot be read is an error, never "no lyrics".
    public func lyrics(videoID: String) async throws -> MusicLyricsResult {
        guard MusicBrowseParser.isVideoID(videoID) else { throw ConnectionError.invalidInput }
        let next = try await browsePost(["videoId": videoID, "isAudioOnly": true], path: "next")
        guard next.status == 200 else { throw ConnectionError.http(next.status) }
        guard next.data.count <= 4_000_000 else { throw ConnectionError.oversized }
        let tabs: MusicWatchNext
        do { tabs = try MusicLyricsParser.parseWatchNext(try SignedMusicClient.json(next.data)) } catch { throw ConnectionError.shape }
        guard let browseID = tabs.lyricsBrowseID else { return .none(.notOffered) }
        guard MusicBrowseParser.isBrowseID(browseID) else { throw ConnectionError.shape }
        let page = try await browsePost(["browseId": browseID])
        guard page.status == 200 else { throw ConnectionError.http(page.status) }
        guard page.data.count <= 4_000_000 else { throw ConnectionError.oversized }
        do { return try MusicLyricsParser.parseLyrics(try SignedMusicClient.json(page.data)) } catch { throw ConnectionError.shape }
    }
    /// A bounded anonymous radio queue read; never asks for media or starts playback.
    public func radioQueue(action: MusicRadioAction) async throws -> MusicRadioQueue {
        let body = try MusicRadioQueueParser.queueBody(action)
        let response = try await browsePost(body, path: "next")
        guard response.status == 200 else { throw ConnectionError.http(response.status) }
        guard response.data.count <= 4_000_000 else { throw ConnectionError.oversized }
        return try MusicRadioQueueParser.parse(try SignedMusicClient.json(response.data))
    }
    private func browsePost(_ fields: [String: Any], path: String = "browse") async throws -> PublicHTTPResponse {
        if config.map({ clock.now() >= $0.validUntil }) ?? true { _ = try await bootstrap() }
        guard let config, clock.now() < config.validUntil else { throw ConnectionError.expired }
        let captured = generation
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/\(path)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Mac OS X 27_0_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.1 Safari/605.1.15 YTMuse/0.1", forHTTPHeaderField: "User-Agent")
        var body = fields
        body["context"] = ["client": clientContext(config)]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try await transport.send(request, maximumBytes: 4_000_000)
        try Task.checkCancellation()
        guard captured == generation else { throw ConnectionError.stale }
        return response
    }
    public static func parseBrowse(_ response: PublicHTTPResponse) throws -> MusicBrowsePage {
        guard response.status == 200 else { throw ConnectionError.http(response.status) }
        guard response.data.count <= 4_000_000 else { throw ConnectionError.oversized }
        do { return try MusicBrowseParser.parse(try SignedMusicClient.json(response.data)) }
        catch { throw ConnectionError.shape }
    }
    public static func parseBrowseContinuation(_ response: PublicHTTPResponse) throws -> MusicContinuationPage {
        guard response.status == 200 else { throw ConnectionError.http(response.status) }
        guard response.data.count <= 4_000_000 else { throw ConnectionError.oversized }
        do { return try MusicBrowseParser.parseContinuation(try SignedMusicClient.json(response.data)) }
        catch { throw ConnectionError.shape }
    }
    public static func parseSearchResponse(_ response: PublicHTTPResponse) throws -> MusicSearchResponse {
        guard response.status == 200 else { throw ConnectionError.http(response.status) }
        guard response.data.count <= 2_000_000 else { throw ConnectionError.oversized }
        do { return try MusicSearchParser.parse(try SignedMusicClient.json(response.data)) }
        catch { throw ConnectionError.shape }
    }
    /// Observes the same WEB_REMIX player metadata boundary; never extracts media.
    public func detail(videoID: String) async throws -> PublicMusicDetail {
        guard videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { throw ConnectionError.invalidInput }
        guard let config, clock.now() < config.validUntil else { throw ConnectionError.expired }
        let captured = generation; let requestID = UUID(); detailTokens[videoID] = requestID
        defer { if detailTokens[videoID] == requestID { detailTokens.removeValue(forKey: videoID) } }
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Mac OS X 27_0_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.1 Safari/605.1.15 YTMuse/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context": ["client": clientContext(config)], "videoId": videoID])
        let response = try await transport.send(request, maximumBytes: 2_000_000)
        try Task.checkCancellation()
        guard captured == generation, detailTokens[videoID] == requestID else { throw ConnectionError.stale }
        return try Self.parseDetail(response, videoID: videoID, generation: captured, requestID: requestID, hl: hl, gl: gl)
    }
    public static func parseDetail(_ response: PublicHTTPResponse, videoID: String, generation: UInt64, requestID: UUID = UUID(), hl: String = "en", gl: String? = nil) throws -> PublicMusicDetail {
        guard response.status == 200 else { throw ConnectionError.http(response.status) }
        guard response.data.count <= 2_000_000, let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw ConnectionError.shape }
        guard root["error"] == nil else { throw ConnectionError.service }
        guard let play = root["playabilityStatus"] as? [String: Any], let status = play["status"] as? String,
              ["OK", "LOGIN_REQUIRED", "UNPLAYABLE", "ERROR", "CONTENT_CHECK_REQUIRED", "AGE_CHECK_REQUIRED", "LIVE_STREAM_OFFLINE"].contains(status) else { throw ConnectionError.shape }
        let details = root["videoDetails"] as? [String: Any]
        if let details { guard details["videoId"] as? String == videoID else { throw ConnectionError.shape } }
        let title = details?["title"] as? String
        guard title == nil || (!title!.isEmpty && title!.utf8.count <= 4096), status != "OK" || title != nil else { throw ConnectionError.shape }
        return .init(requestID: requestID, hl: hl, gl: gl, requestedVideoID: videoID, title: title, status: status, generation: generation)
    }
    public static func parseSearch(_ response: PublicHTTPResponse) throws -> [PublicMusicItem] {
        guard response.status == 200 else { throw ConnectionError.http(response.status) }
        guard response.data.count <= 2_000_000, let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw ConnectionError.shape }
        guard root["error"] == nil else { throw ConnectionError.service }
        guard root["contents"] != nil else { throw ConnectionError.shape }
        var items: [PublicMusicItem] = []
        func walk(_ node: Any, depth: Int) throws -> [PublicMusicItem] {
            var local: [PublicMusicItem] = []
            guard depth < 80 else { throw ConnectionError.shape }
            if let map = node as? [String: Any] {
                if let renderer = map["musicResponsiveListItemRenderer"] as? [String: Any] {
                    guard let columns = renderer["flexColumns"] as? [[String: Any]],
                          let first = columns.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                          let text = first["text"] as? [String: Any], let runs = text["runs"] as? [[String: Any]],
                          let title = runs.first?["text"] as? String, !title.isEmpty, title.utf8.count <= 4096 else { throw ConnectionError.shape }
                    let playlist = renderer["playlistItemData"] as? [String: Any]
                    let nav = renderer["navigationEndpoint"] as? [String: Any]
                    let watch = nav?["watchEndpoint"] as? [String: Any]
                    if let id = (playlist?["videoId"] ?? watch?["videoId"]) as? String {
                        guard id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { throw ConnectionError.shape }
                        local.append(.init(videoID: id, title: title))
                    }
                }
                let branches = try map.filter { $0.key != "musicResponsiveListItemRenderer" }.values.map { try walk($0, depth: depth + 1) }.filter { !$0.isEmpty }
                guard branches.count + (local.isEmpty ? 0 : 1) <= 1 else { throw ConnectionError.shape }
                if let branch = branches.first { local = branch }
            } else if let list = node as? [Any] {
                for value in list { local += try walk(value, depth: depth + 1) }
            }
            return local
        }
        items = try walk(root["contents"]!, depth: 0)
        // Unknown/empty shapes must never read as a confident empty catalog.
        guard !items.isEmpty else { throw ConnectionError.shape }
        return items
    }
}
