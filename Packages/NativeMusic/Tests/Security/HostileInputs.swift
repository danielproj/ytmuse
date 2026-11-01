import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Domain
import Playback
import SystemIntegration
@testable import AccountSession
@testable import Artwork
@testable import YouTubeMusicAdapter
@testable import Playback

// T29.2. Hostile inputs against local fixtures and fake transports only. Nothing here opens a socket to a real host or to the local network: every session answers from a
// URL protocol that is the last stop (or is followed by a refuse-everything protocol), and every listener-facing parser is called on bytes.

func isRefusal<T, E: Error>(_ result: Result<T, E>) -> Bool { if case .failure = result { true } else { false } }

// MARK: SSRF-like links (W26 links)

@Suite("T29.2 links that try to reach somewhere else") struct HostileLinkTests {
    static let hostile: [String] = [
        // loopback, private, link-local and metadata addresses, in every spelling an address takes
        "https://127.0.0.1/watch?v=dQw4w9WgXcQ", "https://localhost/watch?v=dQw4w9WgXcQ", "https://[::1]/watch?v=dQw4w9WgXcQ", "https://[::ffff:127.0.0.1]/", "https://2130706433/watch?v=dQw4w9WgXcQ",
        "https://0x7f.0.0.1/watch?v=dQw4w9WgXcQ", "https://0177.0.0.1/watch?v=dQw4w9WgXcQ", "https://127.1/watch?v=dQw4w9WgXcQ", "https://192.168.1.10/", "https://10.0.0.1/",
        "https://172.16.0.1/", "https://169.254.169.254/latest/meta-data/", "https://metadata.google.internal/computeMetadata/v1/", "https://printer.local/", "https://nas.home.arpa/",
        // the allowed name used as bait
        "https://music.youtube.com@127.0.0.1/watch?v=dQw4w9WgXcQ", "https://music.youtube.com:pw@evil.example/watch?v=dQw4w9WgXcQ", "https://music.youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
        "https://evil.example/music.youtube.com/watch?v=dQw4w9WgXcQ", "https://evil.example/?u=https://music.youtube.com/watch?v=dQw4w9WgXcQ", "https://youtube.com@evil.example/",
        "https://www.youtube.com.evil.example/watch?v=dQw4w9WgXcQ", "https://music.youtube.com:8443/watch?v=dQw4w9WgXcQ", "https://music.youtube.com:443/watch?v=dQw4w9WgXcQ",
        "http://music.youtube.com/watch?v=dQw4w9WgXcQ", "https://music.youtube.com./watch?v=dQw4w9WgXcQ", "https://musiс.youtube.com/watch?v=dQw4w9WgXcQ" /* Cyrillic с */,
        "https://xn--music-3ve.youtube.com/watch?v=dQw4w9WgXcQ", "https://music.youtube.com\\@evil.example/watch?v=dQw4w9WgXcQ",
        // other schemes
        "file:///etc/passwd", "ftp://music.youtube.com/", "javascript:alert(1)", "data:text/html;base64,PHNjcmlwdD4=", "ssh://music.youtube.com/", "gopher://127.0.0.1:70/", "ws://music.youtube.com/",
        // redirects and smuggled parameters
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&redirect=https://127.0.0.1/", "https://music.youtube.com/redirect?q=https://127.0.0.1", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&continue=https%3A%2F%2F127.0.0.1",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&url=http://169.254.169.254/", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&v=other", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=LM",
        "https://youtu.be/dQw4w9WgXcQ/../../etc", "https://music.youtube.com/watch?v=dQw4w9WgXcQ%0d%0aHost:%20evil", "https://music.youtube.com/%2e%2e/watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com//watch?v=dQw4w9WgXcQ", "https://music.youtube.com/watch/?v=dQw4w9WgXcQ", "https://music.youtube.com/watch?v=dQw4w9WgXcQ#//127.0.0.1",
        // app scheme
        "ytmuse://play?url=https://evil.example", "ytmuse://song/dQw4w9WgXcQ?action=play", "ytmuse://song/dQw4w9WgXcQ/extra", "ytmuse://127.0.0.1/", "ytmuse://playlist/LM", "ytmuse://settings/reset",
        // hidden characters
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ\u{202E}", "https://music.youtube.com/watch?v=dQw4w9WgXcQ\u{200B}", "https://music.you\u{200B}tube.com/watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ\u{0000}", "  \n\thttps://music.youtube.com/watch?v=dQw4w9WgXcQ\nhttps://127.0.0.1/",
        // size
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=" + String(repeating: "a", count: 3000), "https://music.youtube.com/" + String(repeating: "a", count: 2100),
        "https://music.youtube.com/watch?" + (0..<400).map { "p\($0)=1" }.joined(separator: "&"), "", "   ", "not a link",
    ]
    @Test(arguments: hostile) func isRefused(link: String) {
        let result = LinkPolicy.parse(text: link)
        #expect(isRefusal(result), "accepted: \(link.prefix(120))")
    }
    @Test func theCorpusIsNotVacuousBecauseGoodLinksStillOpen() {
        let good = ["https://music.youtube.com/watch?v=dQw4w9WgXcQ", "https://MUSIC.YOUTUBE.COM/watch?v=dQw4w9WgXcQ", "https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=abcDEF123", "https://youtu.be/dQw4w9WgXcQ",
                    "https://music.youtube.com/playlist?list=PLabcdefghijklmnop", "ytmuse://song/dQw4w9WgXcQ", "ytmuse://library"]
        for link in good { #expect(!isRefusal(LinkPolicy.parse(text: link)), "refused: \(link)") }
        #expect(Self.hostile.count >= 60, "\(Self.hostile.count) hostile links")
    }
    /// A link is a navigation and nothing else: refusing or accepting one never reaches a network API (the sweep also covers `LinkPolicyTests`).
    @Test func theLinkPolicySourceNamesNoNetworkAPI() throws {
        let code = Repo.code(try Repo.text("Packages/NativeMusic/Sources/SystemIntegration/Links.swift"))
        for forbidden in ["URLSession", "URLRequest", "NWConnection", "CFNetwork", "getaddrinfo", "Data(contentsOf", "String(contentsOf", "NSURLConnection", "WKWebView"] { #expect(!code.contains(forbidden), "Links.swift names \(forbidden)") }
        #expect(code.contains("LinkPolicy"))
    }
}

// MARK: routes, requests and policies that must refuse a place they were never given

@Suite("T29.2 routes and policies refuse unknown places") struct HostileRouteTests {
    static let badHosts = ["127.0.0.1", "10.0.0.1", "192.168.0.1", "169.254.169.254", "172.16.5.4", "0x7f.0.0.1", "0177.0.0.1", "1.2.3", "localhost.localdomain", "printer.local", "metadata.google.internal",
                           "app.localhost", "router.lan", "nas.home.arpa", "service.internal", "[::1]", "music.youtube.com:443", "Music.YouTube.com", "music..youtube.com", "-music.youtube.com", "music.youtube.com.", ""]
    @Test(arguments: badHosts) func aRouteToIt_isRefused(host: String) {
        #expect(throws: NetworkFault.policy) { _ = try NetworkRoute(host: host, path: "/read", method: "POST", purpose: .metadata) }
    }
    @Test func aRouteToARealHostStillBuilds() throws {
        for host in ["music.youtube.com", "i.ytimg.com", "music.example.test", "oauth2.googleapis.com", "lh3.googleusercontent.com"] { _ = try NetworkRoute(host: host, path: "/read", method: "GET", purpose: .artwork) }
    }
    @Test func aRequestCannotLeaveItsRoute() throws {
        let route = try NetworkRoute(host: "music.example.test", path: "/read", method: "POST", purpose: .metadata, queryNames: ["q"])
        let bounds = try ResponseBounds()
        let bad = ["http://music.example.test/read", "https://music.example.test:8443/read", "https://user@music.example.test/read", "https://music.example.test/read#frag", "https://other.example.test/read",
                   "https://music.example.test/other", "https://music.example.test/read?other=1", "https://music.example.test/read/../read", "https://music.example.test/read?" + (0..<40).map { "q=\($0)" }.joined(separator: "&"),
                   "https://music.example.test/read?q=" + String(repeating: "a", count: 9000)]
        for text in bad { #expect(throws: NetworkFault.policy, "\(text.prefix(80))") { _ = try BoundedRequest(route: route, url: URL(string: text)!, bounds: bounds) } }
        #expect(throws: NetworkFault.policy, "a body above the cap") { _ = try BoundedRequest(route: route, url: URL(string: "https://music.example.test/read")!, body: Data(count: 70_000), bounds: bounds) }
        #expect(throws: NetworkFault.policy, "a credential on a route that forbids one") { _ = try BoundedRequest(route: route, url: URL(string: "https://music.example.test/read")!, bounds: bounds, credential: try CredentialReference("ref")) }
        _ = try BoundedRequest(route: route, url: URL(string: "https://music.example.test/read?q=ok")!, bounds: bounds)
    }
    @Test func theSignedClientPolicyAcceptsOnlyItsOwnRequests() throws {
        func make(_ url: String, method: String = "POST", cookie: String? = "SAPISID=x", auth: String? = "SAPISIDHASH 1_x", body: Data? = Data("{}".utf8), origin: Bool = true) -> URLRequest {
            var r = URLRequest(url: URL(string: url)!); r.httpMethod = method; r.httpBody = body
            if let cookie { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if let auth { r.setValue(auth, forHTTPHeaderField: "Authorization") }
            if origin { r.setValue(MusicCookieSession.origin, forHTTPHeaderField: "Origin"); r.setValue(MusicCookieSession.origin, forHTTPHeaderField: "X-Origin") }
            return r
        }
        let good = "https://music.youtube.com/youtubei/v1/search?prettyPrint=false"
        try SignedMusicPolicy.validate(make(good), maximumBytes: 4096)
        let bad: [URLRequest] = [
            make("http://music.youtube.com/youtubei/v1/search?prettyPrint=false"), make("https://music.youtube.com:444/youtubei/v1/search?prettyPrint=false"), make("https://127.0.0.1/youtubei/v1/search?prettyPrint=false"),
            make("https://music.youtube.com.evil.example/youtubei/v1/search?prettyPrint=false"), make("https://music.youtube.com/youtubei/v1/search"), make("https://music.youtube.com/youtubei/v1/search?prettyPrint=false&x=1"),
            make("https://music.youtube.com/youtubei/v1/player?prettyPrint=false"), make("https://music.youtube.com/youtubei/v1/browse/../player?prettyPrint=false"), make("https://user@music.youtube.com/youtubei/v1/search?prettyPrint=false"),
            make(good, method: "GET"), make(good, cookie: nil), make(good, auth: "Bearer x"), make(good, body: nil), make(good, origin: false), make(good, cookie: "SID=a\r\nHost: evil"),
            make("https://i.ytimg.com/vi/x/hq.jpg", method: "GET", cookie: "SID=x", auth: nil, body: nil),                  // an image host never gets the session
            make("https://i.ytimg.com/vi/x/hq.jpg", method: "GET", cookie: nil, auth: "SAPISIDHASH 1_x", body: nil),
            make("https://evil.example/a.jpg", method: "GET", cookie: nil, auth: nil, body: nil), make("https://yt3.ggpht.com.evil.example/a.jpg", method: "GET", cookie: nil, auth: nil, body: nil),
        ]
        for request in bad { #expect(throws: MusicSessionError.policy, "\(request.url?.absoluteString.prefix(80) ?? "")") { try SignedMusicPolicy.validate(request, maximumBytes: 4096) } }
        #expect(throws: MusicSessionError.policy, "above the byte cap") { try SignedMusicPolicy.validate(make(good), maximumBytes: 5_000_000) }
        var image = URLRequest(url: URL(string: "https://i.ytimg.com/vi/x/hq.jpg")!); image.httpMethod = "GET"
        try SignedMusicPolicy.validate(image, maximumBytes: 4096)
    }
    @Test func thePublicTransportRefusesBeforeAnythingIsSent() async throws {
        let sent = Counter()
        let transport = DirectPublicTransport(clock: SystemConnectionClock(), execute: { _, _ in sent.bump(); return PublicHTTPResponse(data: Data("{}".utf8), status: 200) })
        func request(_ url: String, method: String = "POST", headers: [String: String] = [:]) -> URLRequest {
            var r = URLRequest(url: URL(string: url)!); r.httpMethod = method; r.httpBody = Data("{}".utf8)
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            return r
        }
        let bad = [request("https://evil.example/youtubei/v1/search?prettyPrint=false"), request("http://music.youtube.com/youtubei/v1/search?prettyPrint=false"), request("https://127.0.0.1/youtubei/v1/search?prettyPrint=false"),
                   request("https://music.youtube.com/youtubei/v1/search?prettyPrint=false", headers: ["Authorization": "Bearer x"]), request("https://music.youtube.com/youtubei/v1/search?prettyPrint=false", headers: ["Cookie": "SID=x"]),
                   request("https://music.youtube.com/youtubei/v1/account/account_menu?prettyPrint=false"), request("https://music.youtube.com/youtubei/v1/search?x=1"), request("https://music.youtube.com:8443/youtubei/v1/search?prettyPrint=false")]
        for r in bad { await #expect(throws: ConnectionError.origin) { _ = try await transport.send(r, maximumBytes: 4096) } }
        #expect(sent.value == 0, "nothing was sent for any of the \(bad.count) hostile requests")
        _ = try await transport.send(request("https://music.youtube.com/youtubei/v1/search?prettyPrint=false"), maximumBytes: 4096)
        #expect(sent.value == 1, "the same transport sends a permitted request (the counter works)")
    }
    @Test func theGoogleDocumentFetcherReadsOnlyTheTwoDocumentsItNames() async {
        let transport = DirectGooglePublicDocuments()
        for url in ["https://evil.example/", "http://accounts.google.com/.well-known/openid-configuration", "https://127.0.0.1/", "https://accounts.google.com/o/oauth2/v2/auth", "https://www.googleapis.com/oauth2/v3/userinfo"] {
            await #expect(throws: DesktopOAuthError.invalidConfiguration, "\(url)") { _ = try await transport.get(URL(string: url)!) }
        }
    }
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

// MARK: bad TLS

/// Fails every request the way the system reports a failed handshake, and counts the attempts.
final class TLSFailureWire: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var code: URLError.Code = .serverCertificateUntrusted
    static let attempts = Counter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.attempts.bump(); client?.urlProtocol(self, didFailWithError: URLError(Self.code)) }
    override func stopLoading() {}
}
final class InstantTime: NetworkTime, @unchecked Sendable {
    private let lock = NSLock(); private var value: Double = 0
    func now() -> TimeInterval { lock.withLock { value } }
    func wallNow() -> Date { Date(timeIntervalSince1970: 0).addingTimeInterval(now()) }
    func sleep(until deadline: TimeInterval) async throws { try Task.checkCancellation(); lock.withLock { value = max(value, deadline) } }
}
@Suite("T29.2 a connection that fails TLS never delivers data", .serialized) struct BadTLSTests {
    static let codes: [URLError.Code] = [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection]
    @Test(arguments: codes) func failsClosedAndStaysWithinTheRetryBudget(code: URLError.Code) async throws {
        TLSFailureWire.code = code
        for replay in [ReplaySafety.knownRead, .mutation] {
            let before = TLSFailureWire.attempts.value
            let route = try NetworkRoute(host: "music.example.test", path: "/read", method: replay == .mutation ? "POST" : "GET", purpose: .metadata, replay: replay)
            let request = try BoundedRequest(route: route, url: URL(string: "https://music.example.test/read")!, bounds: ResponseBounds(bytes: 1024, seconds: 5))
            let client = BoundedNetworkClient(routes: [route], transport: DirectBoundedTransport(protocolClasses: [TLSFailureWire.self]), scheduler: NetworkScheduler(time: InstantTime(), interval: 0), time: InstantTime(), jitter: { 0 })
            let account = try AccountContext(accountID: UUID(), channelID: ID("c"), region: "US")
            let context = RequestContext(account: account, accountGeneration: 1, requestGeneration: 1)
            try await client.bind(context)
            let budget = try RetryBudget(attempts: 3, seconds: 20)
            let envelope = await client.sendEnvelope(request, context: context, budget: budget)
            guard case .failure(let issue) = envelope.outcome else { Issue.record("a failed handshake produced data (\(code))"); continue }
            #expect(issue.fault == .transport)
            let used = TLSFailureWire.attempts.value - before
            #expect(used >= 1 && used <= budget.attempts, "\(replay): \(used) attempts")
            if replay == .mutation { #expect(used == 1, "a mutation is never replayed") }
        }
    }
    /// No code path in the product weakens certificate validation, and no property list asks the system to.
    @Test func noSourceOrPropertyListWeakensTLS() throws {
        let rules = ["didReceive challenge", "URLAuthenticationChallenge", "serverTrust", "SecTrustSetExceptions", "SecTrustEvaluate", "allowsAnyHTTPSCertificate", "NSAllowsArbitraryLoads", "NSAllowsLocalNetworking",
                     "NSExceptionAllowsInsecureHTTPLoads", "NSAppTransportSecurity", "kCFStreamSSLValidatesCertificateChain", "sec_protocol_options_set_verify_block", "sec_protocol_options_set_peer_authentication_required",
                     "URLCredential(trust", "NSURLAuthenticationMethodServerTrust", "tlsMaximumSupportedProtocol", ".TLSv10", ".TLSv11", ".SSLv3", "SSLProtocol.", "tlsMinimumSupportedProtocol ="]
        var scanned = 0
        for base in ["Packages/NativeMusic/Sources", "App/Sources", "Extensions/Sources"] {
            for file in Repo.swiftFiles(under: base) {
                scanned += 1; let code = Repo.code(try String(contentsOf: file, encoding: .utf8))
                for rule in rules {
                    // W39: the Cast channel is the ONE reviewed exception, for the ONE rule. A Cast receiver's certificate chains to Google's device authority, not a system
                    // root, so the system cannot validate it; the channel pins the leaf certificate per device instead (asserted below).
                    if file.lastPathComponent == "CastNetwork.swift", rule == "sec_protocol_options_set_verify_block" { continue }
                    #expect(!code.contains(rule), "\(file.lastPathComponent) names \(rule)")
                }
            }
        }
        for plist in ["App/Info.plist", "Extensions/NativeMusicWidget-Info.plist", "App/NativeMusic.entitlements", "App/NativeMusic-adhoc.entitlements", "Extensions/NativeMusicWidget.entitlements"] {
            let text = try Repo.text(plist); for rule in rules { #expect(!text.contains(rule), "\(plist) names \(rule)") }
        }
        #expect(scanned > 300, "the sweep looked at \(scanned) files")
        // The Cast exception stays exactly that: one file, one call, and the call compares a leaf certificate pinned for ONE connected session (a fresh pin set per
        // connection, never kept across connections, so a genuine receiver that regenerated its certificate can reconnect) instead of accepting everything.
        let cast = Repo.code(try Repo.text("Packages/NativeMusic/Sources/OutputRoutes/Cast/CastNetwork.swift"))
        #expect(cast.components(separatedBy: "sec_protocol_options_set_verify_block").count == 2 && cast.contains("pins.accepts(CastCertificatePins.fingerprint(of:") && !cast.contains("complete(true)"))
        #expect(cast.contains("pins: CastCertificatePins())") && !cast.contains("private let pins"), "the pin set is created per connection and not stored between connections")
        // Planted line: the rule really fires.
        #expect(Repo.code("func urlSession(_ s: URLSession, didReceive challenge: URLAuthenticationChallenge) {}").contains("didReceive challenge"))
    }
    /// The delegate of every session the product builds implements redirect refusal only: it does not implement the authentication-challenge methods.
    @Test func sessionDelegatesDoNotAnswerChallenges() {
        let challenge = NSSelectorFromString("URLSession:didReceiveChallenge:completionHandler:")
        let taskChallenge = NSSelectorFromString("URLSession:task:didReceiveChallenge:completionHandler:")
        for object in [RejectNetworkRedirect(), NoRedirect(), ArtworkRedirectGuard()] as [NSObject] {
            #expect(!object.responds(to: challenge) && !object.responds(to: taskChallenge), "\(type(of: object)) answers authentication challenges")
        }
    }
}

// MARK: bad or replayed sign-in callbacks (forged, replayed, stale, expired, smuggled)

final class StepClock: ConnectionClock, @unchecked Sendable {
    private let lock = NSLock(); private var value: TimeInterval = 1000
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    func sleep(until deadline: TimeInterval) async throws { try await Task.sleep(for: .seconds(3600)) }
}
@Suite("T29.2 sign-in callbacks") struct HostileCallbackTests {
    static let host = "127.0.0.1:\(FixedLoopback.port)"
    func started(clock: StepClock = StepClock(), generation: UInt64 = 1) async throws -> (DesktopOAuthFlow, String) {
        let box = URLBox()
        let flow = DesktopOAuthFlow(configuration: try DesktopOAuthConfiguration(clientID: "1234567890-w29synthetic.apps.googleusercontent.com"), listener: FixedLoopback(), browser: CapturingBrowser(box: box), exchange: AcceptingExchange(), clock: clock)
        try await flow.start(generation: generation)
        let state = try #require(box.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "state" }?.value)
        return (flow, state)
    }
    func callback(_ query: String, method: String = "GET", host: String = host, scheme: String = "http", hostPart: String? = nil, path: String = "/oauth2callback") -> OAuthCallback {
        OAuthCallback(method: method, url: URL(string: "\(scheme)://\(hostPart ?? Self.host)\(path)?\(query)")!, host: host)
    }
    @Test func aForgedStateAndEveryMalformedFormIsRefusedAndTheAttemptSurvives() async throws {
        let (flow, state) = try await started()
        let bad: [OAuthCallback] = [
            callback("code=abc"), callback("state=wrong&code=abc"), callback("state=&code=abc"), callback("state=\(state)x&code=abc"), callback("state=\(state.lowercased() == state ? state.uppercased() : state.lowercased())&code=abc"),
            callback("state=\(state)&state=\(state)&code=abc"), callback("state=wrong&state=\(state)&code=abc"), callback("state=\(state)&code=abc", method: "POST"), callback("state=\(state)&code=abc", method: "get"),
            callback("state=\(state)&code=abc", host: "localhost:\(FixedLoopback.port)"), callback("state=\(state)&code=abc", host: "127.0.0.1:1"), callback("state=\(state)&code=abc", hostPart: "localhost:\(FixedLoopback.port)"),
            callback("state=\(state)&code=abc", scheme: "https"), callback("state=\(state)&code=abc", path: "/other"), callback("state=\(state)&code=abc", path: "/oauth2callback/x"),
            callback("state=\(state)&code=abc#frag"), callback("state=\(state)&code=\(String(repeating: "a", count: 9000))"), callback((0..<9).map { "p\($0)=1" }.joined(separator: "&") + "&state=\(state)"),
            OAuthCallback(method: "GET", url: URL(string: "http://user:pw@\(Self.host)/oauth2callback?state=\(state)&code=abc")!, host: Self.host),
        ]
        for cb in bad { await #expect(throws: DesktopOAuthError.invalidCallback, "\(cb.url.absoluteString.prefix(100))") { _ = try await flow.receive(cb, generation: 1) } }
        // The attempt was not consumed by any of them: the real callback still completes once.
        _ = try await flow.receive(callback("state=\(state)&code=good"), generation: 1)
        await #expect(throws: DesktopOAuthError.invalidCallback, "replay") { _ = try await flow.receive(callback("state=\(state)&code=good"), generation: 1) }
    }
    @Test func aStaleGenerationAndAnExpiredAttemptAreRefusedAndConsumeTheAttempt() async throws {
        let (flow, state) = try await started(generation: 5)
        await #expect(throws: DesktopOAuthError.stale) { _ = try await flow.receive(callback("state=\(state)&code=abc"), generation: 4) }
        await #expect(throws: DesktopOAuthError.invalidCallback, "the stale attempt is gone") { _ = try await flow.receive(callback("state=\(state)&code=abc"), generation: 5) }
        let clock = StepClock()
        let (late, lateState) = try await started(clock: clock)
        clock.advance(181)
        await #expect(throws: DesktopOAuthError.expired) { _ = try await late.receive(callback("state=\(lateState)&code=abc"), generation: 1) }
    }
    @Test func theErrorAnswerIsDeniedAndCannotBeReplayed() async throws {
        let (flow, state) = try await started()
        let denied = callback("state=\(state)&error=access_denied")
        await #expect(throws: DesktopOAuthError.denied) { _ = try await flow.receive(denied, generation: 1) }
        await #expect(throws: DesktopOAuthError.invalidCallback) { _ = try await flow.receive(denied, generation: 1) }
    }
    @Test func aCallbackBeforeAnyStartIsRefused() async throws {
        let flow = DesktopOAuthFlow(configuration: try DesktopOAuthConfiguration(clientID: "1234567890-w29synthetic.apps.googleusercontent.com"), listener: FixedLoopback(), browser: CapturingBrowser(box: URLBox()), exchange: AcceptingExchange())
        await #expect(throws: DesktopOAuthError.invalidCallback) { _ = try await flow.receive(callback("state=x&code=y"), generation: 1) }
    }
    @Test func theListenerParserRefusesSmuggledRequests() {
        let port = UInt16(FixedLoopback.port), h = "127.0.0.1:\(port)", q = "state=abc&code=def"
        let bad = [
            "GET /oauth2callback?\(q) HTTP/1.1\r\nHost: \(h)\r\nHost: \(h)\r\n\r\n", "GET /oauth2callback?\(q) HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n", "GET /oauth2callback?\(q) HTTP/1.1\r\nHost: \(h).evil.example\r\n\r\n",
            "GET /oauth2callback?\(q) HTTP/1.1\r\n\r\n", "GET /oauth2callback?\(q) HTTP/1.1\r\nHost: \(h)\r\nTransfer-Encoding: chunked\r\n\r\n", "GET /oauth2callback?\(q) HTTP/1.1\r\nHost: \(h)\r\nContent-Length: 5\r\n\r\nhello",
            "POST /oauth2callback?\(q) HTTP/1.1\r\nHost: \(h)\r\n\r\n", "GET http://\(h)/oauth2callback?\(q) HTTP/1.1\r\nHost: \(h)\r\n\r\n", "GET //evil.example/oauth2callback?\(q) HTTP/1.1\r\nHost: \(h)\r\n\r\n",
            "GET /oauth2callback/../admin?\(q) HTTP/1.1\r\nHost: \(h)\r\n\r\n", "GET /oauth2callback?\(q)#frag HTTP/1.1\r\nHost: \(h)\r\n\r\n", "GET /oauth2callback?\(q)\\x HTTP/1.1\r\nHost: \(h)\r\n\r\n",
            "GET /oauth2callback?\(q) HTTP/1.0\r\nHost: \(h)\r\n\r\n", "GET /oauth2callback?\(q) HTTP/1.1\r\nHost: \(h)\r\n folded\r\n\r\n", "GET /oauth2callback?\(q) HTTP/1.1\nHost: \(h)\n\n",
            "GET /oauth2callback?\(q)" + String(repeating: "a", count: 17_000) + " HTTP/1.1\r\nHost: \(h)\r\n\r\n", "GET  /oauth2callback?\(q) HTTP/1.1\r\nHost: \(h)\r\n\r\n", "",
        ]
        for text in bad { #expect(throws: DesktopOAuthError.invalidCallback, "\(text.prefix(80).debugDescription)") { _ = try NativeOAuthLoopback.parse(Data(text.utf8), port: port) } }
        #expect(throws: DesktopOAuthError.invalidCallback) { _ = try NativeOAuthLoopback.parse(Data([0xff, 0xfe, 0x00, 0x01]), port: port) }
        #expect((try? NativeOAuthLoopback.parse(Data("GET /oauth2callback?\(q) HTTP/1.1\r\nHost: \(h)\r\n\r\n".utf8), port: port)) != nil, "the well-formed request parses (the corpus is not vacuous)")
        // The page the browser is shown never echoes the request.
        let page = String(decoding: NativeOAuthLoopback.receiptResponse(parsed: true), as: UTF8.self)
        #expect(!page.contains("state") && !page.contains("code=") && page.contains("Content-Security-Policy: default-src 'none'") && page.contains("no-store"))
    }
}
