import AccountSession
import Domain
import Foundation
import ImageIO
import MachO

/// Wire result after policy checks. Only status, body, MIME type and allowlisted
/// rotated `youtube.com` cookies survive; no other header, URL or server text does.
public struct SignedMusicWireResponse: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String?
    public let rotation: [MusicSessionCookie]
    public init(status: Int, body: Data, contentType: String?, rotation: [MusicSessionCookie] = []) {
        self.status = status; self.body = body; self.contentType = contentType; self.rotation = rotation
    }
}
public protocol SignedMusicTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse
}

/// Exact allowlist for the signed client. Music calls must carry the session;
/// avatar reads must not. Nothing else, no other host, no other query.
public enum SignedMusicPolicy {
    public static let musicPaths: Set<String> = ["/youtubei/v1/browse", "/youtubei/v1/account/account_menu", "/youtubei/v1/search", "/youtubei/v1/next"]
    /// The only requests that change anything: rate, subscribe and library feedback. Each one is sent only for an explicit user action.
    public static let writePaths: Set<String> = ["/youtubei/v1/like/like", "/youtubei/v1/like/dislike", "/youtubei/v1/like/removelike",
                                                 "/youtubei/v1/subscription/subscribe", "/youtubei/v1/subscription/unsubscribe", "/youtubei/v1/feedback"]
    /// The playlist-changing requests: create, edit (add, remove, move, rename, describe, privacy) and delete. Each one is sent only for an
    /// explicit user action by the playlist editing session; nothing else may name these paths.
    public static let playlistWritePaths: Set<String> = ["/youtubei/v1/playlist/create", "/youtubei/v1/browse/edit_playlist", "/youtubei/v1/playlist/delete"]
    /// Account photos are served from numbered YouTube (`yt3`/`yt4`…) and Google
    /// (`lh3`…`lh6`) image hosts. The original fixed set (yt3/lh3 only) refused the
    /// common `yt4.ggpht.com` form, so the avatar silently fell back to the placeholder.
    public static func isAvatarHost(_ host: String) -> Bool {
        host.range(of: #"^(?:yt[0-9]\.(?:ggpht|googleusercontent)\.com|lh[3-6]\.googleusercontent\.com)$"#, options: .regularExpression) != nil
    }
    public static func validate(_ request: URLRequest, maximumBytes: Int) throws(MusicSessionError) {
        guard let url = request.url, url.scheme == "https", url.port == nil, url.user == nil, url.password == nil,
              url.fragment == nil, let host = url.host, request.value(forHTTPHeaderField: "Host") == nil,
              maximumBytes > 0, maximumBytes <= 4_000_000 else { throw .policy }
        let cookie = request.value(forHTTPHeaderField: "Cookie"), authorization = request.value(forHTTPHeaderField: "Authorization")
        if host == "music.youtube.com" {
            guard musicPaths.contains(url.path) || writePaths.contains(url.path) || playlistWritePaths.contains(url.path), url.query == "prettyPrint=false", request.httpMethod == "POST",
                  let body = request.httpBody, body.count <= 65_536,
                  let cookie, !cookie.isEmpty, cookie.utf8.count <= 16_384, !cookie.contains("\r"), !cookie.contains("\n"),
                  let authorization, authorization.hasPrefix("SAPISIDHASH "), authorization.utf8.count <= 256,
                  request.value(forHTTPHeaderField: "Origin") == MusicCookieSession.origin,
                  request.value(forHTTPHeaderField: "X-Origin") == MusicCookieSession.origin else { throw .policy }
        } else {
            guard isAvatarHost(host) || host == "i.ytimg.com", (request.httpMethod ?? "GET") == "GET", request.httpBody == nil,
                  cookie == nil, authorization == nil, maximumBytes <= 524_288 else { throw .policy }
        }
    }
}

/// The existing direct transport configuration: ephemeral, no shared cookie jar,
/// credential store or cache; redirects are refused; bodies stop at the cap.
/// Whether this process is a test process: a test bundle (`….xctest/…`) is among the images loaded into it (`swift test`, an Xcode test
/// host). The application itself is never one, including the application under UI automation, where the test bundle lives in the
/// runner's process.
public enum LiveTransportGuard {
    public static var isTestProcess: Bool {
        (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index) else { return false }
            return String(cString: name).contains(".xctest/")
        }
    }
}

/// Answers every request it is asked about with a refusal, so a session built for a test can never reach the network.
final class RefuseEverythingURLProtocol: URLProtocol {
    private static let counter = NSLock()
    nonisolated(unsafe) private static var refusals = 0
    nonisolated(unsafe) private static var refusalsByPath: [String: Int] = [:]
    /// How many requests this protocol has refused (a measurement for tests).
    static var refusedCount: Int { counter.withLock { refusals } }
    /// TH2: refusals of requests for one URL path. The total above is process-wide, so a test that read it before and after was wrong whenever another test refused a request in
    /// between (tests run in parallel); a test that owns a path counts that path's refusals only.
    static func refusedCount(forPath path: String) -> Int { counter.withLock { refusalsByPath[path, default: 0] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.counter.withLock { Self.refusals += 1; Self.refusalsByPath[path, default: 0] += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

public struct DirectSignedMusicTransport: SignedMusicTransport {
    private let session: URLSession
    /// The live transport. It cannot be made in a test process: construction stops the process there, so no test, by any spelling
    /// (including a defaulted `SignedMusicClient` argument), can reach the service with the account's session. Tests use
    /// `init(protocolClasses:)` or a scripted `SignedMusicTransport`.
    public init() {
        precondition(!LiveTransportGuard.isTestProcess, "The live signed transport must never be constructed in a test process")
        session = URLSession(configuration: DirectBoundedTransport.configuration(), delegate: RejectNetworkRedirect(), delegateQueue: nil)
    }
    /// The same constructor as a throwing call, so the refusal can be tested without ending the test process.
    public static func live() throws(MusicSessionError) -> DirectSignedMusicTransport {
        guard !LiveTransportGuard.isTestProcess else { throw .policy }
        return DirectSignedMusicTransport()
    }
    /// Test seam: the same policy and body handling over an ephemeral session that only the given URL protocols can answer. It takes
    /// protocol classes, never a session, so no network session can be injected through it.
    init(protocolClasses: [AnyClass]) {
        let configuration = URLSessionConfiguration.ephemeral
        // A refuse-everything protocol always comes last: a request the given classes do not answer is refused here and can never be
        // handed to the system's network stack, whatever a test passes in.
        configuration.protocolClasses = protocolClasses + [RefuseEverythingURLProtocol.self]
        session = URLSession(configuration: configuration, delegate: RejectNetworkRedirect(), delegateQueue: nil)
    }
    public func shutdown() { session.invalidateAndCancel() }
    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        try SignedMusicPolicy.validate(request, maximumBytes: maximumBytes)
        var wire = request
        wire.httpShouldHandleCookies = false; wire.timeoutInterval = 20
        do {
            let (bytes, response) = try await session.bytes(for: wire)
            guard let http = response as? HTTPURLResponse, let url = wire.url else { throw MusicSessionError.unrecognised }
            let body = try await DirectBoundedTransport.collect(bytes, expected: http.expectedContentLength, limit: maximumBytes)
            var rotation: [MusicSessionCookie] = []
            if url.host == "music.youtube.com", let fields = http.allHeaderFields as? [String: String] {
                rotation = MusicCookieSession.updates(from: HTTPCookie.cookies(withResponseHeaderFields: fields, for: url))
            }
            return .init(status: http.statusCode, body: body, contentType: http.value(forHTTPHeaderField: "Content-Type"), rotation: rotation)
        } catch let error as MusicSessionError { throw error }
        catch { throw Self.classify(error) }
    }
    static func classify(_ error: any Error) -> MusicSessionError {
        if error is CancellationError { return .cancelled }
        if let fault = error as? NetworkFault { return fault == .oversized ? .oversized : fault == .cancelled ? .cancelled : .network }
        if let error = error as? URLError { return error.code == .cancelled ? .cancelled : error.code == .timedOut ? .timedOut : .network }
        return .network
    }
}

/// SAPISIDHASH-signed `music.youtube.com/youtubei/v1` reads with the `WEB_REMIX`
/// context from the public bootstrap. Read-only: account menu and library playlists.
public actor SignedMusicClient: MusicSessionReading {
    public nonisolated var adapterVersion: String { YouTubeMusicAdapterInfo.version }
    private let transport: any SignedMusicTransport
    private let clientVersion: @Sendable () async throws -> String
    private let clock: any WallClock
    private let hl: String
    private let locale: ContentLocaleProvider?
    /// The anonymous public client that answers a search when no session is supplied.
    private let anonymous: PublicMusicClient?
    private var cachedVersion: (value: String, until: Date)?
    public init(transport: any SignedMusicTransport = DirectSignedMusicTransport(), clock: any WallClock = SystemWallClock(),
                hl: String = "en", locale: ContentLocaleProvider? = nil, anonymous: PublicMusicClient? = nil, clientVersion: @escaping @Sendable () async throws -> String) {
        self.transport = transport; self.clock = clock; self.hl = hl; self.locale = locale; self.anonymous = anonymous; self.clientVersion = clientVersion
    }
    /// Uses the existing public `music.youtube.com` bootstrap for `INNERTUBE_CLIENT_VERSION`.
    public init(publicClient: PublicMusicClient, transport: any SignedMusicTransport = DirectSignedMusicTransport(), clock: any WallClock = SystemWallClock(), locale: ContentLocaleProvider? = nil) {
        self.init(transport: transport, clock: clock, locale: locale, anonymous: publicClient) { try await publicClient.bootstrap().clientVersion }
    }
    static func classifyConnection(_ error: ConnectionError) -> MusicSessionError {
        switch error {
        case .shape, .service, .expired: .unrecognised
        case .oversized: .oversized
        case .stale: .stale
        case .http(429): .rateLimited
        case .http(let status) where (500...599).contains(status): .server
        case .http(401), .http(403): .signedOut
        case .invalidInput, .origin: .policy
        case .http: .unrecognised
        }
    }
    static let userAgent = "Mozilla/5.0 (Macintosh; Mac OS X 27_0_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.1 Safari/605.1.15 YTMuse/0.1"

    public func accountMenu(session: MusicCookieSession) async throws -> MusicSignedResult<MusicAccountIdentity> {
        let (root, rotation) = try await post("account/account_menu", body: [:], session: session, limit: 1_000_000)
        return .init(value: try Self.parseAccountMenu(root), rotation: rotation)
    }
    public func likedPlaylists(session: MusicCookieSession) async throws -> MusicSignedResult<MusicLibraryPlaylists> {
        let (root, rotation) = try await post("browse", body: ["browseId": "FEmusic_liked_playlists"], session: session, limit: 4_000_000)
        return .init(value: try Self.parseLibraryPlaylists(root), rotation: rotation)
    }
    /// `search` with the account's session, or the anonymous public request when `session` is nil.
    /// The query travels only in the request body; it is never logged or placed in a URL.
    public func search(query: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicSearchResponse> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, query.utf8.count <= 512 else { throw MusicSessionError.policy }
        guard let session else {
            guard let anonymous else { throw MusicSessionError.policy }
            do { return .init(value: try await anonymous.searchResponse(query), rotation: []) }
            catch let error as MusicSessionError { throw error }
            catch let error as ConnectionError { throw Self.classifyConnection(error) }
            catch { throw DirectSignedMusicTransport.classify(error) }
        }
        let (root, rotation) = try await post("search", body: ["query": query], session: session, limit: 2_000_000)
        if Self.loggedOut(root) { throw MusicSessionError.signedOut }
        return .init(value: try MusicSearchParser.parse(root), rotation: rotation)
    }
    /// `browse` of one page with the account's session, or the anonymous public request when `session` is nil.
    public func browse(id: String, params: String?, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicBrowsePage> {
        guard MusicBrowseParser.isBrowseID(id), params.map(MusicBrowseParser.isParams) ?? true else { throw MusicSessionError.policy }
        guard let session else {
            guard let anonymous else { throw MusicSessionError.policy }
            do { return .init(value: try await anonymous.browsePage(id: id, params: params), rotation: []) }
            catch let error as MusicSessionError { throw error }
            catch let error as ConnectionError { throw Self.classifyConnection(error) }
            catch { throw DirectSignedMusicTransport.classify(error) }
        }
        var body = ["browseId": id]
        if let params { body["params"] = params }
        let (root, rotation) = try await post("browse", body: body, session: session, limit: 4_000_000)
        if Self.loggedOut(root) { throw MusicSessionError.signedOut }
        return .init(value: try MusicBrowseParser.parse(root), rotation: rotation)
    }
    /// A podcast episode page with the account's session, or the anonymous public request when `session` is nil.
    public func episode(id: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicEpisodePage> {
        guard MusicBrowseParser.isBrowseID(id) else { throw MusicSessionError.policy }
        guard let session else {
            guard let anonymous else { throw MusicSessionError.policy }
            do { return .init(value: try await anonymous.episodePage(id: id), rotation: []) }
            catch let error as MusicSessionError { throw error }
            catch let error as ConnectionError { throw Self.classifyConnection(error) }
            catch { throw DirectSignedMusicTransport.classify(error) }
        }
        let (root, rotation) = try await post("browse", body: ["browseId": id], session: session, limit: 4_000_000)
        if Self.loggedOut(root) { throw MusicSessionError.signedOut }
        return .init(value: try MusicEpisodeParser.parse(root), rotation: rotation)
    }
    /// Lyrics: `next` for the song, then the lyrics page it names. Signed requests carry the account's session in case the answer supplies timing.
    public func radioQueue(action: MusicRadioAction, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicRadioQueue> {
        let body = try MusicRadioQueueParser.queueBody(action)
        guard let session else {
            guard let anonymous else { throw MusicSessionError.policy }
            do { return .init(value: try await anonymous.radioQueue(action: action), rotation: []) }
            catch let error as MusicSessionError { throw error }
            catch let error as ConnectionError { throw Self.classifyConnection(error) }
            catch { throw DirectSignedMusicTransport.classify(error) }
        }
        let (root, rotation) = try await post("next", body: body, session: session, limit: 4_000_000)
        if Self.loggedOut(root) { throw MusicSessionError.signedOut }
        return .init(value: try MusicRadioQueueParser.parse(root), rotation: rotation)
    }
    public func lyrics(videoID: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicLyricsResult> {
        guard MusicBrowseParser.isVideoID(videoID) else { throw MusicSessionError.policy }
        guard let session else {
            guard let anonymous else { throw MusicSessionError.policy }
            do { return .init(value: try await anonymous.lyrics(videoID: videoID), rotation: []) }
            catch let error as MusicSessionError { throw error }
            catch let error as ConnectionError { throw Self.classifyConnection(error) }
            catch { throw DirectSignedMusicTransport.classify(error) }
        }
        let (nextRoot, firstRotation) = try await post("next", body: ["videoId": videoID, "isAudioOnly": true], session: session, limit: 4_000_000)
        if Self.loggedOut(nextRoot) { throw MusicSessionError.signedOut }
        let tabs = try MusicLyricsParser.parseWatchNext(nextRoot)
        guard let browseID = tabs.lyricsBrowseID else { return .init(value: .none(.notOffered), rotation: firstRotation) }
        guard MusicBrowseParser.isBrowseID(browseID) else { throw MusicSessionError.unrecognised }
        let (root, secondRotation) = try await post("browse", body: ["browseId": browseID], session: session, limit: 4_000_000)
        if Self.loggedOut(root) { throw MusicSessionError.signedOut }
        return .init(value: try MusicLyricsParser.parseLyrics(root), rotation: firstRotation + secondRotation)
    }
    public func continuation(token: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicContinuationPage> {
        guard MusicBrowseParser.isToken(token) else { throw MusicSessionError.policy }
        guard let session else {
            guard let anonymous else { throw MusicSessionError.policy }
            do { return .init(value: try await anonymous.browseContinuation(token: token), rotation: []) }
            catch let error as MusicSessionError { throw error }
            catch let error as ConnectionError { throw Self.classifyConnection(error) }
            catch { throw DirectSignedMusicTransport.classify(error) }
        }
        let (root, rotation) = try await post("browse", body: ["continuation": token], session: session, limit: 4_000_000)
        if Self.loggedOut(root) { throw MusicSessionError.signedOut }
        return .init(value: try MusicBrowseParser.parseContinuation(root), rotation: rotation)
    }
    /// A library or history page: signed only, repeated rows kept (`MusicBrowseParser.Mode.collection`).
    public func library(id: String, session: MusicCookieSession) async throws -> MusicSignedResult<MusicBrowsePage> {
        guard MusicBrowseParser.isBrowseID(id) else { throw MusicSessionError.policy }
        let (root, rotation) = try await post("browse", body: ["browseId": id], session: session, limit: 4_000_000)
        if Self.loggedOut(root) { throw MusicSessionError.signedOut }
        return .init(value: try MusicBrowseParser.parse(root, mode: .collection), rotation: rotation)
    }
    public func libraryContinuation(token: String, session: MusicCookieSession) async throws -> MusicSignedResult<MusicContinuationPage> {
        guard MusicBrowseParser.isToken(token) else { throw MusicSessionError.policy }
        let (root, rotation) = try await post("browse", body: ["continuation": token], session: session, limit: 4_000_000)
        if Self.loggedOut(root) { throw MusicSessionError.signedOut }
        return .init(value: try MusicBrowseParser.parseContinuation(root, mode: .collection), rotation: rotation)
    }

    /// Sends one write. Success needs positive evidence in the answer (`classify`): an HTTP 200 on its own is never success.
    /// A failure before anything was sent throws; once the request has left, a lost connection or an unreadable answer is
    /// `indeterminate`, because the service may have applied the change (SYNC05: read the state before trying again).
    public func write(_ request: MusicWriteRequest, session: MusicCookieSession) async throws -> MusicSignedResult<MusicWriteOutcome> {
        guard request.isWellFormed else { throw MusicSessionError.policy }
        let (endpoint, body) = Self.wire(request)
        let sent = Submission()
        do {
            let (root, rotation) = try await post(endpoint, body: body, session: session, limit: 1_000_000, onSubmit: { sent.mark() })
            if Self.loggedOut(root) { throw MusicSessionError.signedOut }
            return .init(value: Self.classify(request, root), rotation: rotation)
        } catch {
            // Whatever the transport threw is classified first; a raw connection error is never allowed to escape unclassified.
            let mapped = (error as? MusicSessionError) ?? DirectSignedMusicTransport.classify(error)
            switch mapped {
            case .signedOut, .policy, .stale, .notSignedIn, .invalidSession: throw mapped
            case .rateLimited: return .init(value: .rejected(.rateLimited), rotation: [])
            case .server: return .init(value: .rejected(.unavailable), rotation: [])
            case .cancelled, .network, .timedOut, .oversized, .unrecognised:
                if sent.value { return .init(value: .indeterminate(mapped == .unrecognised || mapped == .oversized ? .unrecognisedAnswer : .noAnswer), rotation: []) }
                throw mapped == .cancelled && !(error is MusicSessionError) ? error : mapped
            default: throw mapped
            }
        }
    }
    private final class Submission: @unchecked Sendable {
        private let lock = NSLock(); private var flag = false
        func mark() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }
    /// The endpoint and body for a write: the same request shapes the service's own pages publish.
    static func wire(_ request: MusicWriteRequest) -> (endpoint: String, body: [String: Any]) {
        switch request {
        case .rate(let video, let status):
            let path = status == .like ? "like/like" : status == .dislike ? "like/dislike" : "like/removelike"
            return (path, ["target": ["videoId": video]])
        case .savePlaylist(let list, let saved):
            return (saved ? "like/like" : "like/removelike", ["target": ["playlistId": list]])
        case .songLibrary(let token):
            return ("feedback", ["feedbackTokens": [token]])
        case .episodeLater(let video, let saved):
            let action: [String: Any] = saved ? ["action": "ACTION_ADD_VIDEO", "addedVideoId": video]
                                              : ["action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID", "removedVideoId": video]
            return ("browse/edit_playlist", ["playlistId": MusicEpisodeParser.laterPlaylistID, "actions": [action]])
        case .follow(let channel, let params, let following):
            var body: [String: Any] = ["channelIds": [channel]]
            if following, let params { body["params"] = params }
            return (following ? "subscription/subscribe" : "subscription/unsubscribe", body)
        }
    }
    /// Reads the answer to a write. `error` (or `errors`) means refused; a feedback response must mark every token processed;
    /// a rate/subscribe answer needs the actions the service attaches to a change it made. Anything else is not evidence.
    static func classify(_ request: MusicWriteRequest, _ root: [String: Any]) -> MusicWriteOutcome {
        if root["error"] != nil { return .rejected(.service) }
        if let errors = root["errors"] as? [Any], !errors.isEmpty { return .rejected(.service) }
        if case .episodeLater = request {
            switch root["status"] as? String {
            case "STATUS_SUCCEEDED": return .confirmed
            case nil: return .indeterminate(.unrecognisedAnswer)
            default: return .rejected(.service)
            }
        }
        if case .songLibrary = request {
            guard let responses = root["feedbackResponses"] as? [[String: Any]], !responses.isEmpty else { return .indeterminate(.unrecognisedAnswer) }
            let flags = responses.map { $0["isProcessed"] as? Bool }
            if flags.contains(false) { return .rejected(.service) }
            return flags.allSatisfy { $0 == true } ? .confirmed : .indeterminate(.unrecognisedAnswer)
        }
        if let actions = root["actions"] as? [Any], !actions.isEmpty { return .confirmed }
        return .indeterminate(.unrecognisedAnswer)
    }

    /// Catalog artwork: credential-free bytes from the exact image hosts the catalog uses, bounded, `image/*` only.
    public func artwork(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        try SignedMusicPolicy.validate(request, maximumBytes: 524_288)
        let response = try await transport.send(request, maximumBytes: 524_288)
        guard response.status == 200, response.contentType?.lowercased().hasPrefix("image/") == true, !response.body.isEmpty else { throw MusicSessionError.unrecognised }
        return response.body
    }
    public func avatar(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        try SignedMusicPolicy.validate(request, maximumBytes: 524_288)
        let response = try await transport.send(request, maximumBytes: 524_288)
        guard response.status == 200, response.contentType?.lowercased().hasPrefix("image/") == true,
              let source = CGImageSourceCreateWithData(response.body as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...1024).contains(width), (1...1024).contains(height) else { throw MusicSessionError.unrecognised }
        return response.body
    }

    private func version() async throws -> String {
        if let cachedVersion, clock.now() < cachedVersion.until { return cachedVersion.value }
        do {
            let value = try await clientVersion()
            guard value.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else { throw MusicSessionError.unrecognised }
            cachedVersion = (value, clock.now().addingTimeInterval(1800)); return value
        } catch let error as MusicSessionError { throw error }
        catch is CancellationError { throw MusicSessionError.cancelled }
        catch ConnectionError.shape { throw MusicSessionError.unrecognised }
        catch { throw MusicSessionError.network }
    }
    func post(_ endpoint: String, body: [String: Any], session: MusicCookieSession, limit: Int, onSubmit: (@Sendable () -> Void)? = nil) async throws -> ([String: Any], [MusicSessionCookie]) {
        guard let sapisid = session.sapisid, session.isUsable(at: clock.now()) else { throw MusicSessionError.signedOut }
        let version = try await version()
        var payload: [String: Any] = body
        let hint = locale?() ?? ContentLocaleHint(hl: hl, gl: nil)
        var client: [String: String] = ["clientName": "WEB_REMIX", "clientVersion": version, "hl": hint.hl]
        if let gl = hint.gl { client["gl"] = gl }
        payload["context"] = ["client": client, "user": ["lockedSafetyMode": false]]
        var request = URLRequest(url: URL(string: MusicCookieSession.origin + "/youtubei/v1/" + endpoint + "?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let timestamp = Int(clock.now().timeIntervalSince1970)
        for (name, value) in [("Content-Type", "application/json"), ("User-Agent", Self.userAgent),
                              ("Cookie", session.cookieHeader),
                              ("Authorization", SAPISIDHash.authorization(timestamp: timestamp, sapisid: sapisid)),
                              ("Origin", MusicCookieSession.origin), ("X-Origin", MusicCookieSession.origin),
                              ("Referer", MusicCookieSession.origin + "/"), ("X-Goog-AuthUser", "0")] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        try SignedMusicPolicy.validate(request, maximumBytes: limit)
        onSubmit?()
        let response = try await transport.send(request, maximumBytes: limit)
        try Task.checkCancellation()
        guard response.body.count <= limit else { throw MusicSessionError.oversized }
        switch response.status {
        case 200: break
        case 401, 403: throw MusicSessionError.signedOut
        case 429: throw MusicSessionError.rateLimited
        case 500...599: throw MusicSessionError.server
        default: throw MusicSessionError.unrecognised
        }
        let mime = response.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard mime == "application/json" else { throw MusicSessionError.unrecognised }
        return (try Self.json(response.body), response.rotation)
    }

    /// Bounded nesting/node scan before Foundation builds an object graph.
    static func json(_ data: Data) throws(MusicSessionError) -> [String: Any] {
        var depth = 0, nodes = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else {
                if byte == 34 { quoted = true; nodes += 1 }
                if byte == 123 || byte == 91 { depth += 1; nodes += 1 }
                if byte == 125 || byte == 93 { depth -= 1 }
                if byte == 44 || byte == 58 { nodes += 1 }
                guard depth >= 0, depth <= 64, nodes <= 400_000 else { throw .unrecognised }
            }
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw .unrecognised }
        return root
    }
    static func loggedOut(_ root: [String: Any]) -> Bool {
        ((root["responseContext"] as? [String: Any])?["mainAppWebResponseContext"] as? [String: Any])?["loggedOut"] as? Bool == true
    }
    static func text(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let simple = object["simpleText"] as? String { return simple }
        guard let runs = object["runs"] as? [[String: Any]] else { return nil }
        let joined = runs.compactMap { $0["text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }
    static func dictionaries(named key: String, in value: Any, depth: Int = 0, into found: inout [[String: Any]]) {
        guard depth < 40, found.count < 64 else { return }
        if let object = value as? [String: Any] {
            if let match = object[key] as? [String: Any] { found.append(match) }
            for (name, child) in object where name != key { dictionaries(named: key, in: child, depth: depth + 1, into: &found) }
        } else if let list = value as? [Any] {
            for child in list { dictionaries(named: key, in: child, depth: depth + 1, into: &found) }
        }
    }
    static func contains(key: String, in value: Any, depth: Int = 0) -> Bool {
        guard depth < 40 else { return false }
        if let object = value as? [String: Any] {
            return object[key] != nil || object.values.contains { contains(key: key, in: $0, depth: depth + 1) }
        }
        if let list = value as? [Any] { return list.contains { contains(key: key, in: $0, depth: depth + 1) } }
        return false
    }

    /// `actions[].openPopupAction.popup.multiPageMenuRenderer.header.activeAccountHeaderRenderer`.
    /// Only explicit signals mean signed out (`loggedOut`, or 401/403 upstream). A
    /// menu whose header is missing or unknown is unrecognised: a schema change must
    /// never expire a signed-in identity. The stable identity is the menu's single
    /// distinct `UC…` channel ID; none or several is unrecognised. A handle is
    /// mutable and is display-only.
    public static func parseAccountMenu(_ root: [String: Any]) throws(MusicSessionError) -> MusicAccountIdentity {
        if loggedOut(root) { throw .signedOut }
        let menus = (root["actions"] as? [[String: Any]] ?? []).compactMap {
            (($0["openPopupAction"] as? [String: Any])?["popup"] as? [String: Any])?["multiPageMenuRenderer"] as? [String: Any]
        }
        guard let menu = menus.first else { throw .unrecognised }
        guard let header = (menu["header"] as? [String: Any])?["activeAccountHeaderRenderer"] as? [String: Any] else { throw .unrecognised }
        guard let name = text(header["accountName"])?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.utf8.count <= 256 else { throw .unrecognised }
        var handle = text(header["channelHandle"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = handle, !(value.hasPrefix("@") && value.utf8.count <= 128 && value.utf8.count > 1) { handle = nil }
        let thumbnails = ((header["accountPhoto"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
        let photo = avatarURL(thumbnails)
        guard let browseIDs = browseIDs(in: menu) else { throw .unrecognised }
        let channels = Set(browseIDs.filter { $0.range(of: #"^UC[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil })
        guard channels.count == 1, let serviceID = channels.first else { throw .unrecognised }
        return MusicAccountIdentity(serviceID: serviceID, displayName: name, handle: handle, photoURL: photo)
    }

    /// Largest published thumbnail (or the last, which Google lists largest-last when
    /// widths are absent), scheme-relative URLs made HTTPS, allowed hosts only, and
    /// Google's size directive (`=s88-c-…`, `=s96-c`) raised to 176 px for a crisp
    /// 60 pt avatar on Retina. Unknown forms keep their own URL unchanged.
    public static func avatarURL(_ thumbnails: [[String: Any]]) -> URL? {
        let widths = thumbnails.map { $0["width"] as? Int ?? 0 }
        let chosen = widths.allSatisfy({ $0 == 0 }) ? thumbnails.last : thumbnails.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
        guard var text = chosen?["url"] as? String, text.utf8.count <= 2048 else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        text = text.replacingOccurrences(of: #"=s[0-9]{1,4}(?=-|$)"#, with: "=s176", options: .regularExpression)
        guard var components = URLComponents(string: text), components.scheme == "https", components.port == nil,
              components.user == nil, components.password == nil, let host = components.host?.lowercased(),
              SignedMusicPolicy.isAvatarHost(host) else { return nil }
        components.fragment = nil
        return components.url
    }
    /// Every `browseId` under a `browseEndpoint`, with no match cap. The walk is
    /// bounded by depth and node count; hitting a bound returns nil (unrecognised)
    /// so a truncated set can never pass the single-channel rule.
    static func browseIDs(in value: Any) -> [String]? {
        var found: [String] = [], visited = 0, truncated = false
        func walk(_ value: Any, _ depth: Int) {
            guard !truncated else { return }
            visited += 1
            guard depth < 48, visited <= 200_000 else { truncated = true; return }
            if let object = value as? [String: Any] {
                if let endpoint = object["browseEndpoint"] as? [String: Any], let id = endpoint["browseId"] as? String { found.append(id) }
                for child in object.values { walk(child, depth + 1) }
            } else if let list = value as? [Any] {
                for child in list { walk(child, depth + 1) }
            }
        }
        walk(value, 0)
        return truncated ? nil : found
    }
    /// Grid (`musicTwoRowItemRenderer`) or list (`musicResponsiveListItemRenderer`)
    /// library layouts. No recognised container means unrecognised, never empty.
    public static func parseLibraryPlaylists(_ root: [String: Any]) throws(MusicSessionError) -> MusicLibraryPlaylists {
        if loggedOut(root) { throw .signedOut }
        guard let contents = root["contents"] as? [String: Any] else { throw .unrecognised }
        var grids: [[String: Any]] = [], shelves: [[String: Any]] = []
        dictionaries(named: "gridRenderer", in: contents, into: &grids)
        dictionaries(named: "musicShelfRenderer", in: contents, into: &shelves)
        let items = grids.compactMap { $0["items"] as? [[String: Any]] }.flatMap { $0 }
            + shelves.compactMap { $0["contents"] as? [[String: Any]] }.flatMap { $0 }
        guard !grids.isEmpty || !shelves.isEmpty else { throw .unrecognised }
        var playlists: [MusicLibraryPlaylist] = [], seen = Set<String>(), recognised = 0
        for item in items {
            let row: (title: String?, subtitle: String?, endpoint: [String: Any]?)
            if let card = item["musicTwoRowItemRenderer"] as? [String: Any] {
                row = (text(card["title"]), text(card["subtitle"]),
                       (card["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])
            } else if let line = item["musicResponsiveListItemRenderer"] as? [String: Any] {
                let columns = (line["flexColumns"] as? [[String: Any]] ?? []).map {
                    text(($0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"])
                }
                row = (columns.first ?? nil, columns.dropFirst().compactMap { $0 }.joined(separator: " • "),
                       (line["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])
            } else if item["continuationItemRenderer"] != nil { continue }
            else { continue }
            recognised += 1
            guard let browseID = row.endpoint?["browseId"] as? String, browseID.hasPrefix("VL"), browseID.count > 2, browseID.utf8.count <= 128,
                  let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.utf8.count <= 512 else { continue }
            let id = String(browseID.dropFirst(2))
            guard seen.insert(id).inserted, playlists.count < 500 else { continue }
            let count = countText(row.subtitle)
            playlists.append(.init(id: id, title: title, countText: count?.text, itemCount: count?.value))
        }
        guard items.isEmpty || recognised > 0 else { throw .unrecognised }
        let continued = contains(key: "continuations", in: contents) || contains(key: "continuationItemRenderer", in: contents)
        return MusicLibraryPlaylists(playlists: playlists, complete: !continued && playlists.count < 500)
    }
    static func countText(_ subtitle: String?) -> (text: String, value: Int?)? {
        guard let subtitle, let regex = try? NSRegularExpression(pattern: #"([0-9][0-9,.   ]*)\s*(songs?|tracks?|episodes?|videos?)\b"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: subtitle, range: NSRange(subtitle.startIndex..., in: subtitle)),
              let whole = Range(match.range, in: subtitle), let number = Range(match.range(at: 1), in: subtitle) else { return nil }
        let digits = subtitle[number].filter(\.isNumber)
        return (String(subtitle[whole]).trimmingCharacters(in: .whitespaces), digits.count <= 9 ? Int(digits) : nil)
    }
}
