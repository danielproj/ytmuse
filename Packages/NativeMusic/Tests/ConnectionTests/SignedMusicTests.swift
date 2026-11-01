import Foundation
import Testing
import JavaScriptCore
import Domain
@testable import YouTubeMusicAdapter
@testable import AccountSession

/// Synthetic markers only. They must reach the wire headers and nowhere else.
enum WebSessionMarkers {
    static let sapisid = "SYNTHETIC-SAPISID-VALUE"
    static let secure3p = "SYNTHETIC-3PAPISID-VALUE"
    static let sid = "SYNTHETIC-SID-VALUE"
    static let all = [sapisid, secure3p, sid, "SYNTHETIC-HSID-VALUE", "SYNTHETIC-PSIDCC-VALUE"]
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
}
struct FixedWallClock: WallClock {
    let date: Date
    init(_ date: Date = WebSessionMarkers.epoch) { self.date = date }
    func now() -> Date { date }
}
func webCookie(_ name: String, _ value: String, domain: String = ".youtube.com", expires: Date? = WebSessionMarkers.epoch.addingTimeInterval(86_400 * 30)) -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"]
    if let expires { properties[.expires] = expires }
    return HTTPCookie(properties: properties)!
}
func syntheticSession(account: UUID = UUID(), secure3p: Bool = false) throws -> MusicCookieSession {
    var cookies = [webCookie("SAPISID", WebSessionMarkers.sapisid), webCookie("SID", WebSessionMarkers.sid),
                   webCookie("HSID", "SYNTHETIC-HSID-VALUE"), webCookie("__Secure-3PSIDCC", "SYNTHETIC-PSIDCC-VALUE")]
    if secure3p { cookies.append(webCookie("__Secure-3PAPISID", WebSessionMarkers.secure3p)) }
    return try MusicCookieSession(accountID: account, cookies: cookies, now: WebSessionMarkers.epoch)
}
func webSessionFixture(_ name: String) throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent("Fixtures/E01-WebSession/" + name))
}
private actor ScriptedSignedTransport: SignedMusicTransport {
    var responses: [SignedMusicWireResponse]
    var requests: [URLRequest] = []
    init(_ responses: [SignedMusicWireResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        try SignedMusicPolicy.validate(request, maximumBytes: maximumBytes)
        requests.append(request)
        return responses.isEmpty ? .init(status: 500, body: Data(), contentType: nil) : responses.removeFirst()
    }
    func captured() -> [URLRequest] { requests }
}
private func json(_ name: String, status: Int = 200, rotation: [MusicSessionCookie] = []) throws -> SignedMusicWireResponse {
    .init(status: status, body: try webSessionFixture(name), contentType: "application/json; charset=UTF-8", rotation: rotation)
}
private func client(_ transport: ScriptedSignedTransport) -> SignedMusicClient {
    SignedMusicClient(transport: transport, clock: FixedWallClock()) { "1.20261028.01.00" }
}

@Suite struct SignedMusicTests {
    @Test func sapisidHashMatchesIndependentFixedVector() {
        // sha1("1700000000 SYNTHETIC-SAPISID-VALUE https://music.youtube.com"), computed outside Swift.
        let expected = "1700000000_841afddae08881c85b549f95bdbd2c537108ae79"
        #expect(SAPISIDHash.value(timestamp: 1_700_000_000, sapisid: WebSessionMarkers.sapisid) == expected)
        #expect(SAPISIDHash.authorization(timestamp: 1_700_000_000, sapisid: WebSessionMarkers.sapisid) == "SAPISIDHASH " + expected)
        #expect(SAPISIDHash.value(timestamp: 1_700_000_000, sapisid: WebSessionMarkers.sapisid, origin: "https://www.youtube.com") != expected)
    }
    @Test func cookieSelectionKeepsOnlyAllowlistedLiveYouTubeCookies() throws {
        let account = UUID()
        let session = try MusicCookieSession(accountID: account, cookies: [
            webCookie("SAPISID", WebSessionMarkers.sapisid), webCookie("SID", WebSessionMarkers.sid),
            webCookie("SID", "SYNTHETIC-GOOGLE-SID", domain: ".google.com"),
            webCookie("HSID", "SYNTHETIC-SPOOF", domain: ".evilyoutube.com"),
            webCookie("SSID", "SYNTHETIC-SPOOF2", domain: "youtube.com.evil.test"),
            webCookie("YSC", "SYNTHETIC-TRACKING"),
            webCookie("APISID", "SYNTHETIC-EXPIRED", expires: WebSessionMarkers.epoch.addingTimeInterval(-1)),
            webCookie("LOGIN_INFO", "SYNTHETIC;INJECT"),
        ], now: WebSessionMarkers.epoch)
        #expect(Set(session.cookies.map(\.name)) == ["SAPISID", "SID"])
        #expect(session.cookieHeader == "SAPISID=\(WebSessionMarkers.sapisid); SID=\(WebSessionMarkers.sid)")
        #expect(session.sapisid == WebSessionMarkers.sapisid)
        #expect(try syntheticSession(secure3p: true).sapisid == WebSessionMarkers.secure3p)
        #expect(session.isUsable(at: WebSessionMarkers.epoch))
        #expect(!session.isUsable(at: WebSessionMarkers.epoch.addingTimeInterval(86_400 * 31)))
        #expect(throws: MusicSessionError.notSignedIn) {
            try MusicCookieSession(accountID: account, cookies: [webCookie("SID", WebSessionMarkers.sid)], now: WebSessionMarkers.epoch)
        }
        #expect(throws: MusicSessionError.notSignedIn) {
            try MusicCookieSession(accountID: account, cookies: [webCookie("SAPISID", WebSessionMarkers.sapisid, domain: ".google.com"),
                                                                 webCookie("SID", WebSessionMarkers.sid)], now: WebSessionMarkers.epoch)
        }
    }
    @Test func recordIsBoundToItsLocalAccount() throws {
        let first = UUID(), second = UUID()
        let data = try syntheticSession(account: first).encoded()
        #expect(try MusicCookieSession.decode(data, accountID: first).accountID == first)
        #expect(throws: MusicSessionError.invalidSession) { try MusicCookieSession.decode(data, accountID: second) }
        #expect(throws: MusicSessionError.invalidSession) { try MusicCookieSession.decode(Data("{}".utf8), accountID: first) }
    }
    @Test func accountMenuIsSignedLikeTheWebsiteAndParsesIdentity() async throws {
        let transport = ScriptedSignedTransport([try json("account_menu-accepted.json")])
        let session = try syntheticSession()
        let result = try await client(transport).accountMenu(session: session)
        #expect(result.value == MusicAccountIdentity(serviceID: "UCsyntheticChannel000000", displayName: "Synthetic Listener",
            handle: "@synthetic-listener", photoURL: URL(string: "https://yt3.ggpht.com/synthetic-avatar=s176")))
        let request = try #require(await transport.captured().first)
        #expect(request.url?.absoluteString == "https://music.youtube.com/youtubei/v1/account/account_menu?prettyPrint=false")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Cookie") == session.cookieHeader)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "SAPISIDHASH 1700000000_841afddae08881c85b549f95bdbd2c537108ae79")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://music.youtube.com")
        #expect(request.value(forHTTPHeaderField: "X-Origin") == "https://music.youtube.com")
        #expect(request.value(forHTTPHeaderField: "X-Goog-AuthUser") == "0")
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "WEB_REMIX" && client?["clientVersion"] as? String == "1.20261028.01.00")
    }
    @Test func accountMenuFailuresAreNeverAnIdentityOrEmpty() async throws {
        let session = try syntheticSession()
        let cases: [(SignedMusicWireResponse, MusicSessionError)] = [
            // Only explicit signals mean signed out; a missing/unknown header is a schema change.
            (try json("account_menu-missing-header.json"), .unrecognised),
            (try json("account_menu-unknown-header.json"), .unrecognised),
            // Identity must be the menu's single channel ID: two is ambiguous, a handle alone is mutable.
            (try json("account_menu-two-channels.json"), .unrecognised),
            (try json("account_menu-handle-only.json"), .unrecognised),
            (try json("account_menu-signed-out.json"), .signedOut),
            (try json("account_menu-accepted.json", status: 401), .signedOut),
            (try json("account_menu-accepted.json", status: 403), .signedOut),
            (try json("unrecognised-shape.json"), .unrecognised),
            (.init(status: 200, body: try webSessionFixture("unparseable.txt"), contentType: "text/html"), .unrecognised),
            (.init(status: 200, body: try webSessionFixture("unparseable.txt"), contentType: "application/json"), .unrecognised),
            (.init(status: 200, body: Data(count: 1_000_001), contentType: "application/json"), .oversized),
            (try json("account_menu-accepted.json", status: 429), .rateLimited),
            (try json("account_menu-accepted.json", status: 503), .server),
            (try json("account_menu-accepted.json", status: 302), .unrecognised),
        ]
        for (response, expected) in cases {
            let transport = ScriptedSignedTransport([response])
            await #expect(throws: expected) { _ = try await client(transport).accountMenu(session: session) }
        }
    }
    @Test func libraryPlaylistsParseGridAndListAndNeverReadUnknownAsEmpty() async throws {
        let session = try syntheticSession()
        let accepted = try await client(ScriptedSignedTransport([try json("liked_playlists-accepted.json")])).likedPlaylists(session: session).value
        #expect(accepted.playlists == [
            .init(id: "PLsyntheticMorning", title: "Synthetic Morning Mix", countText: "12 songs", itemCount: 12),
            .init(id: "PLsyntheticRoadtrip", title: "Synthetic Roadtrip", countText: "1,204 tracks", itemCount: 1204),
            .init(id: "LM", title: "Liked Music", countText: nil, itemCount: nil),
        ])
        #expect(accepted.complete)
        let empty = try await client(ScriptedSignedTransport([try json("liked_playlists-empty.json")])).likedPlaylists(session: session).value
        #expect(empty.playlists.isEmpty && empty.complete)
        let continued = try await client(ScriptedSignedTransport([try json("liked_playlists-continued.json")])).likedPlaylists(session: session).value
        #expect(continued.playlists.map(\.title) == ["Synthetic List Row"] && continued.playlists.first?.itemCount == 7 && !continued.complete)
        for (response, expected) in [(try json("liked_playlists-signed-out.json"), MusicSessionError.signedOut),
                                     (try json("unrecognised-shape.json"), .unrecognised),
                                     (try json("liked_playlists-accepted.json", status: 403), .signedOut)] {
            await #expect(throws: expected) { _ = try await client(ScriptedSignedTransport([response])).likedPlaylists(session: session) }
        }
        let transport = ScriptedSignedTransport([try json("liked_playlists-accepted.json")])
        _ = try await client(transport).likedPlaylists(session: session)
        let request = try #require(await transport.captured().first)
        #expect(request.url?.path == "/youtubei/v1/browse")
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["browseId"] as? String == "FEmusic_liked_playlists")
    }
    @Test func rotationIsReturnedAndMergedOnlyForAllowlistedNames() async throws {
        let rotated = MusicSessionCookie(name: "__Secure-3PSIDCC", value: "SYNTHETIC-ROTATED-VALUE", expires: WebSessionMarkers.epoch.addingTimeInterval(3600))
        let transport = ScriptedSignedTransport([try json("account_menu-accepted.json", rotation: [rotated])])
        var session = try syntheticSession()
        let result = try await client(transport).accountMenu(session: session)
        #expect(result.rotation == [rotated])
        let changed = session.merge(result.rotation, now: WebSessionMarkers.epoch)
        #expect(changed)
        #expect(session.cookieHeader.contains("__Secure-3PSIDCC=SYNTHETIC-ROTATED-VALUE"))
        #expect(session.rotatedAt == WebSessionMarkers.epoch)
        let repeated = session.merge(result.rotation, now: WebSessionMarkers.epoch)
        let tracking = session.merge([.init(name: "YSC", value: "SYNTHETIC-TRACKING", expires: nil)], now: WebSessionMarkers.epoch)
        #expect(!repeated && !tracking)
        // An expired Set-Cookie deletes; losing SAPISID makes the session unusable.
        let deleted = session.merge([.init(name: "SAPISID", value: "", expires: WebSessionMarkers.epoch.addingTimeInterval(-60))], now: WebSessionMarkers.epoch)
        #expect(deleted)
        #expect(!session.isUsable(at: WebSessionMarkers.epoch))
        let parsed = MusicCookieSession.updates(from: HTTPCookie.cookies(withResponseHeaderFields: [
            "Set-Cookie": "__Secure-3PSIDCC=SYNTHETIC-HEADER-VALUE; Domain=.youtube.com; Path=/; Secure; HttpOnly"],
            for: URL(string: "https://music.youtube.com/youtubei/v1/browse")!))
        #expect(parsed.map(\.name) == ["__Secure-3PSIDCC"])
    }
    @Test func policyRefusesEverythingOutsideTheExactRoutes() async throws {
        let session = try syntheticSession()
        func signed(_ url: String, method: String = "POST", cookie: Bool = true) -> URLRequest {
            var request = URLRequest(url: URL(string: url)!); request.httpMethod = method; request.httpBody = Data("{}".utf8)
            if cookie { request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie") }
            request.setValue("SAPISIDHASH 1_00", forHTTPHeaderField: "Authorization")
            request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("https://music.youtube.com", forHTTPHeaderField: "X-Origin")
            return request
        }
        try SignedMusicPolicy.validate(signed("https://music.youtube.com/youtubei/v1/browse?prettyPrint=false"), maximumBytes: 1000)
        for request in [signed("https://music.youtube.com/youtubei/v1/player?prettyPrint=false"),
                        signed("https://music.youtube.com/youtubei/v1/browse"),
                        signed("https://music.youtube.com/youtubei/v1/browse?prettyPrint=false&key=x"),
                        signed("https://www.youtube.com/youtubei/v1/browse?prettyPrint=false"),
                        signed("http://music.youtube.com/youtubei/v1/browse?prettyPrint=false"),
                        signed("https://music.youtube.com:444/youtubei/v1/browse?prettyPrint=false"),
                        signed("https://music.youtube.com/youtubei/v1/browse?prettyPrint=false", method: "GET"),
                        signed("https://music.youtube.com/youtubei/v1/browse?prettyPrint=false", cookie: false),
                        signed("https://yt3.ggpht.com/synthetic", method: "GET")] {
            #expect(throws: MusicSessionError.policy) { try SignedMusicPolicy.validate(request, maximumBytes: 1000) }
        }
        // Direct transport validates before any I/O: a refused request never reaches the network.
        // (W12: built over a session whose protocol answers locally and counts what reaches it, so no live transport is constructed in a test.)
        let before = LocalOnlyProtocol.reached
        await #expect(throws: MusicSessionError.policy) {
            _ = try await DirectSignedMusicTransport(protocolClasses: [LocalOnlyProtocol.self]).send(signed("https://example.invalid/youtubei/v1/browse?prettyPrint=false"), maximumBytes: 1000)
        }
        #expect(LocalOnlyProtocol.reached == before, "the refused request never reached the session")
        var avatar = URLRequest(url: URL(string: "https://yt3.ggpht.com/synthetic-avatar=s88")!)
        try SignedMusicPolicy.validate(avatar, maximumBytes: 524_288)
        avatar.setValue("SYNTHETIC", forHTTPHeaderField: "Cookie")
        #expect(throws: MusicSessionError.policy) { try SignedMusicPolicy.validate(avatar, maximumBytes: 524_288) }
    }
    @Test func noCookieOrSapisidValueAppearsInAnyDescription() async throws {
        let session = try syntheticSession(secure3p: true)
        var surfaces: [String] = []
        for value: Any in [session, session.cookies, session.cookies[0], Optional.some(session) as Any, ["session": session]] {
            var dumped = ""; dump(value, to: &dumped)
            surfaces += [String(describing: value), String(reflecting: value), dumped]
        }
        for error in [MusicSessionError.notSignedIn, .invalidSession, .signedOut, .unrecognised, .oversized, .network, .rateLimited,
                      .server, .cancelled, .timedOut, .stale, .differentAccount, .duplicateAccount, .policy, .cleanupRequired] {
            surfaces += [String(describing: error), String(reflecting: error), error.localizedDescription]
        }
        for name in ["account_menu-missing-header.json", "unrecognised-shape.json"] {
            do { _ = try await client(ScriptedSignedTransport([try json(name)])).accountMenu(session: session) }
            catch { surfaces += [String(describing: error), String(reflecting: error), error.localizedDescription] }
        }
        #expect(!surfaces.isEmpty)
        for surface in surfaces { for marker in WebSessionMarkers.all { #expect(!surface.contains(marker), "leak in \(surface.prefix(60))") } }
        #expect(Mirror(reflecting: session).children.isEmpty)
        // Codable round-trip is the only path that carries values (into the Keychain record).
        #expect(try MusicCookieSession.decode(session.encoded(), accountID: session.accountID) == session)
    }
    @Test func mainFrameIsLimitedToTheSignInPathAndSubframesToGoogleContent() {
        func url(_ text: String) -> URL? { URL(string: text) }
        for allowed in ["https://accounts.google.com/ServiceLogin", "https://accounts.google.co.uk/x", "https://accounts.google.de/x",
                        "https://accounts.google.com.au/x", "https://accounts.youtube.com/accounts/SetSID", "https://www.youtube.com/signin",
                        "https://music.youtube.com/", "https://consent.youtube.com/m", "https://consent.google.com/m"] {
            #expect(MusicSignInNavigation.allows(url(allowed), mainFrame: true), "\(allowed)")
        }
        for refused in ["https://storage.googleapis.com/bucket/page.html", "https://sites.google.com/view/x", "https://lh3.googleusercontent.com/x",
                        "https://www.gstatic.com/x", "https://support.google.com/accounts", "https://mail.google.com/", "https://www.google.com/",
                        "http://accounts.google.com/", "https://accounts.google.com:8443/", "https://user@accounts.google.com/",
                        "https://accounts.google.com.evil.test/", "https://evilaccounts.google.com/", "https://example.com/", "about:blank",
                        "data:text/html,x", "file:///etc/hosts"] {
            #expect(!MusicSignInNavigation.allows(url(refused), mainFrame: true), "\(refused)")
        }
        #expect(!MusicSignInNavigation.allows(nil, mainFrame: true))
        for allowed in ["https://www.gstatic.com/x.js", "https://apis.google.com/js", "https://lh3.googleusercontent.com/a",
                        "https://play.google.com/log", "https://www.youtube.com/embed", "about:blank", "about:srcdoc"] {
            #expect(MusicSignInNavigation.allows(url(allowed), mainFrame: false), "\(allowed)")
        }
        for refused in ["https://example.com/frame", "http://www.gstatic.com/x", "about:config", "javascript:alert(1)", "data:text/html,x"] {
            #expect(!MusicSignInNavigation.allows(url(refused), mainFrame: false), "\(refused)")
        }
        #expect(MusicSignInNavigation.isMusicDestination(url("https://music.youtube.com/library")))
        #expect(!MusicSignInNavigation.isMusicDestination(url("http://music.youtube.com/")))
    }
    /// Runs the shipped passkey script in JavaScriptCore against a stub window:
    /// it must change nothing off `accounts.google.com` and only remove WebAuthn there.
    @Test func passkeyScriptOnlyActsOnAccountsGoogleCom() throws {
        func run(host: String) throws -> (credential: String, rejected: String, passthrough: String) {
            let context = try #require(JSContext())
            context.evaluateScript("""
            var calls = [];
            function Creds() {}
            Creds.prototype.get = function (o) { calls.push("get"); return "native"; };
            Creds.prototype.create = function (o) { calls.push("create"); return "native"; };
            var window = { location: { hostname: "\(host)" }, PublicKeyCredential: function () {}, navigator: { credentials: new Creds() } };
            function DOMException(m, n) { this.message = m; this.name = n; }
            """)
            context.evaluateScript(MusicSignInNavigation.passkeySuppressionSource)
            let credential = context.evaluateScript("typeof window.PublicKeyCredential")?.toString() ?? ""
            let rejected = context.evaluateScript("var r = window.navigator.credentials.get({ publicKey: {} }); (r && typeof r.then === 'function') ? 'promise' : String(r)")?.toString() ?? ""
            let passthrough = context.evaluateScript("window.navigator.credentials.get({ password: true })")?.toString() ?? ""
            return (credential, rejected, passthrough)
        }
        for host in ["accounts.google.com", "accounts.google.co.uk", "accounts.google.de", "accounts.google.com.au"] {
            let google = try run(host: host)
            #expect(google.credential == "undefined" && google.rejected == "promise" && google.passthrough == "native", "\(host)")
        }
        for host in ["music.youtube.com", "accounts.google.com.evil.test", "www.youtube.com", "evilaccounts.google.com", "accounts.google.evil"] {
            let other = try run(host: host)
            #expect(other.credential == "function" && other.rejected == "native" && other.passthrough == "native", "\(host)")
        }
    }
    @Test func avatarURLAcceptsRealisticGooglePhotoFormsAndUpsizes() throws {
        func pick(_ urls: [(String, Int?)]) -> String? {
            SignedMusicClient.avatarURL(urls.map { url, width in
                var row: [String: Any] = ["url": url]; if let width { row["width"] = width; row["height"] = width }; return row
            })?.absoluteString
        }
        #expect(pick([("https://yt3.ggpht.com/ytc/AIdro_synthetic=s48-c-k-c0x00ffffff-no-rj", 48),
                      ("https://yt3.ggpht.com/ytc/AIdro_synthetic=s88-c-k-c0x00ffffff-no-rj", 88)])
                == "https://yt3.ggpht.com/ytc/AIdro_synthetic=s176-c-k-c0x00ffffff-no-rj")
        // The common yt4 host was refused before (live L5): it must now be accepted.
        #expect(pick([("https://yt4.ggpht.com/synthetic=s88-c-k-c0x00ffffff-no-rj", 88)]) == "https://yt4.ggpht.com/synthetic=s176-c-k-c0x00ffffff-no-rj")
        #expect(pick([("https://lh3.googleusercontent.com/a/ACg8ocSynthetic=s96-c", 96)]) == "https://lh3.googleusercontent.com/a/ACg8ocSynthetic=s176-c")
        #expect(pick([("https://lh5.googleusercontent.com/a-/synthetic=s96", nil)]) == "https://lh5.googleusercontent.com/a-/synthetic=s176")
        #expect(pick([("//yt3.googleusercontent.com/synthetic=s88-c", nil)]) == "https://yt3.googleusercontent.com/synthetic=s176-c")
        // Widths absent: Google lists the largest last.
        #expect(pick([("https://yt3.ggpht.com/small=s32", nil), ("https://yt3.ggpht.com/large=s88", nil)]) == "https://yt3.ggpht.com/large=s176")
        #expect(pick([("https://yt3.ggpht.com/no-size-directive.jpg", 88)]) == "https://yt3.ggpht.com/no-size-directive.jpg")
        for refused in ["http://yt3.ggpht.com/x=s88", "https://yt3.ggpht.com.evil.test/x=s88", "https://example.com/x=s88",
                        "https://yt3.ggpht.com:444/x=s88", "https://lh9.googleusercontent.com/x=s88", "https://storage.googleapis.com/x"] {
            #expect(pick([(refused, 88)]) == nil, "\(refused)")
        }
        #expect(SignedMusicPolicy.isAvatarHost("yt4.ggpht.com") && SignedMusicPolicy.isAvatarHost("lh3.googleusercontent.com"))
        var avatar = URLRequest(url: URL(string: "https://yt4.ggpht.com/synthetic=s176-c")!)
        try SignedMusicPolicy.validate(avatar, maximumBytes: 524_288)
        avatar.url = URL(string: "https://evil.ggpht.com/x")!
        #expect(throws: MusicSessionError.policy) { try SignedMusicPolicy.validate(avatar, maximumBytes: 524_288) }
    }
    @Test func accountMenuAvatarFetchReturnsDecodableImageBytes() async throws {
        // A real 2x2 PNG from ImageIO round-trips through the bounded avatar path.
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR4nGP8z8DAwMDAxMDAwMDAAAANBAEB0wGuQgAAAABJRU5ErkJggg=="))
        let transport = ScriptedSignedTransport([.init(status: 200, body: png, contentType: "image/png")])
        let data = try await client(transport).avatar(URL(string: "https://yt4.ggpht.com/synthetic=s176-c")!)
        #expect(data == png)
        let wrongType = ScriptedSignedTransport([.init(status: 200, body: png, contentType: "text/html")])
        await #expect(throws: MusicSessionError.unrecognised) { _ = try await client(wrongType).avatar(URL(string: "https://yt4.ggpht.com/x=s176")!) }
    }
    /// N4: a second channel ID beyond the old 64-endpoint collection cap is still seen.
    @Test func channelUniquenessIsCheckedAcrossEveryBrowseEndpoint() throws {
        var root = try #require(JSONSerialization.jsonObject(with: try webSessionFixture("account_menu-accepted.json")) as? [String: Any])
        var actions = root["actions"] as! [[String: Any]]
        var open = actions[0]["openPopupAction"] as! [String: Any]
        var popup = open["popup"] as! [String: Any]
        var menu = popup["multiPageMenuRenderer"] as! [String: Any]
        var items: [[String: Any]] = (0..<80).map { ["compactLinkRenderer": ["navigationEndpoint": ["browseEndpoint": ["browseId": "FEsynthetic\($0)"]]]] }
        items.append(["compactLinkRenderer": ["navigationEndpoint": ["browseEndpoint": ["browseId": "UCsyntheticSecondChannel"]]]])
        var sections = menu["sections"] as! [[String: Any]]
        sections.append(["multiPageMenuSectionRenderer": ["items": items]])
        menu["sections"] = sections; popup["multiPageMenuRenderer"] = menu; open["popup"] = popup
        actions[0]["openPopupAction"] = open; root["actions"] = actions
        #expect(throws: MusicSessionError.unrecognised) { try SignedMusicClient.parseAccountMenu(root) }
        // Same menu without the second channel still resolves to the one channel.
        items.removeLast(); sections[sections.count - 1] = ["multiPageMenuSectionRenderer": ["items": items]]
        menu["sections"] = sections; popup["multiPageMenuRenderer"] = menu; open["popup"] = popup
        actions[0]["openPopupAction"] = open; root["actions"] = actions
        #expect(try SignedMusicClient.parseAccountMenu(root).serviceID == "UCsyntheticChannel000000")
    }
}

/// A URL protocol that answers every request itself and counts them: a transport over it cannot reach a network.
final class LocalOnlyProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reached = 0
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.reached += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
