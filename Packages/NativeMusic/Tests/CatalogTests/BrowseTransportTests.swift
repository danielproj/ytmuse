import AccountSession
import Domain
import Foundation
import Testing
@testable import YouTubeMusicAdapter

private actor ScriptedSigned: SignedMusicTransport {
    var requests: [URLRequest] = []
    var body: Data
    var status: Int
    var type: String?
    init(_ capture: Capture? = nil, body: Data? = nil, status: Int = 200, type: String? = "application/json; charset=UTF-8") throws {
        self.body = try body ?? capture.map(realData) ?? Data("{}".utf8); self.status = status; self.type = type
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        try SignedMusicPolicy.validate(request, maximumBytes: maximumBytes)
        requests.append(request)
        return .init(status: status, body: body, contentType: type)
    }
    func captured() -> [URLRequest] { requests }
}
private actor ScriptedPublic: PublicHTTPTransport {
    var requests: [URLRequest] = []
    var body: Data
    var status: Int
    init(_ capture: Capture? = nil, body: Data? = nil, status: Int = 200) throws { self.body = try body ?? capture.map(realData) ?? Data("{}".utf8); self.status = status }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse {
        requests.append(request)
        if request.url?.path == "/" { return .init(data: Data(#"{"INNERTUBE_CLIENT_VERSION":"1.20261028.01.00","INNERTUBE_CONTEXT_CLIENT_NAME":"WEB_REMIX"}"#.utf8), status: 200) }
        return .init(data: body, status: status)
    }
    func captured() -> [URLRequest] { requests }
}
private struct Now: WallClock { func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) } }
private func session() throws -> MusicCookieSession {
    func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: ".youtube.com", .path: "/", .expires: Date(timeIntervalSince1970: 1_700_000_000 + 86_400)])!
    }
    return try MusicCookieSession(accountID: UUID(), cookies: [cookie("SAPISID", "SYNTHETIC-SAPISID-VALUE"), cookie("SID", "SYNTHETIC-SID-VALUE")], now: Date(timeIntervalSince1970: 1_700_000_000))
}
private func json(_ request: URLRequest) throws -> [String: Any] {
    guard let data = request.httpBody, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return object
}

@Suite struct SignedBrowseTests {
    private func client(_ transport: ScriptedSigned) -> SignedMusicClient { SignedMusicClient(transport: transport, clock: Now()) { "1.20261028.01.00" } }

    @Test func theSignedRequestIsTheMusicBrowsePostWithTheIdOnlyInTheBody() async throws {
        let transport = try ScriptedSigned(.home)
        let result = try await client(transport).browse(id: "FEmusic_home", params: "ggM8SgQIBxAD", session: try session())
        #expect(result.value.shelves.count == 2 && result.value.accounting.consistent)
        let request = try #require(await transport.captured().first)
        #expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://music.youtube.com" && request.value(forHTTPHeaderField: "X-Origin") == "https://music.youtube.com")
        let body = try json(request)
        #expect(body["browseId"] as? String == "FEmusic_home" && body["params"] as? String == "ggM8SgQIBxAD")
        let context = try #require((body["context"] as? [String: Any])?["client"] as? [String: Any])
        #expect(context["clientName"] as? String == "WEB_REMIX" && context["clientVersion"] as? String == "1.20261028.01.00")
        #expect(request.url?.query == "prettyPrint=false", "no identifier or token is ever placed in the URL")
    }
    @Test func aContinuationRequestCarriesTheTokenInTheBodyAndParsesTheEnvelope() async throws {
        let body = try Data(contentsOf: fixturesRoot().appendingPathComponent("W11/continuation-playlist-shelf.json"))
        let transport = try ScriptedSigned(body: body)
        let result = try await client(transport).continuation(token: "4qmFsgI0EiRWTFBM%3D", session: try session())
        #expect(result.value.items.count == 5 && result.value.continuation == "SYNTHETICnextShelfToken-2")
        let request = try #require(await transport.captured().first)
        let sent = try json(request)
        #expect(sent["continuation"] as? String == "4qmFsgI0EiRWTFBM%3D" && request.url?.query == "prettyPrint=false")
    }
    @Test(arguments: [Capture.home, .explore, .moods, .newReleases, .charts, .artist, .album, .playlist, .podcast])
    func everyRealCaptureParsesThroughTheSignedPath(capture: Capture) async throws {
        let result = try await client(try ScriptedSigned(capture)).browse(id: "FEmusic_home", params: nil, session: try session())
        #expect(result.value == (try realPage(capture)))
    }
    @Test func failuresMapToTheSessionErrorsTheCoordinatorUnderstands() async throws {
        let signedOut = try Data(contentsOf: fixturesRoot().appendingPathComponent("W10/search-signed-out.json"))
        await #expect(throws: MusicSessionError.signedOut) { try await client(try ScriptedSigned(body: signedOut)).browse(id: "FEmusic_home", params: nil, session: try session()) }
        await #expect(throws: MusicSessionError.unrecognised) { try await client(try ScriptedSigned(body: Data(#"{"contents":{"x":{}}}"#.utf8))).browse(id: "FEmusic_home", params: nil, session: try session()) }
        await #expect(throws: MusicSessionError.signedOut) { try await client(try ScriptedSigned(.home, status: 403)).browse(id: "FEmusic_home", params: nil, session: try session()) }
        await #expect(throws: MusicSessionError.rateLimited) { try await client(try ScriptedSigned(.home, status: 429)).browse(id: "FEmusic_home", params: nil, session: try session()) }
        await #expect(throws: MusicSessionError.server) { try await client(try ScriptedSigned(.home, status: 503)).browse(id: "FEmusic_home", params: nil, session: try session()) }
        await #expect(throws: MusicSessionError.unrecognised) { try await client(try ScriptedSigned(.home, type: "text/html")).browse(id: "FEmusic_home", params: nil, session: try session()) }
    }
    @Test func hostileIdentifiersAndTokensNeverReachTheWire() async throws {
        let transport = try ScriptedSigned(.home)
        let signed = client(transport)
        for id in ["", "a b", "../x", "FEmusic_home\nHost: x", String(repeating: "a", count: 200)] {
            await #expect(throws: MusicSessionError.policy) { try await signed.browse(id: id, params: nil, session: try session()) }
        }
        await #expect(throws: MusicSessionError.policy) { try await signed.browse(id: "FEmusic_home", params: "bad params", session: try session()) }
        await #expect(throws: MusicSessionError.policy) { try await signed.continuation(token: "bad token", session: try session()) }
        #expect(await transport.captured().isEmpty)
    }
    @Test func withoutASessionAndWithoutAnAnonymousClientNothingIsSent() async throws {
        let transport = try ScriptedSigned(.home)
        await #expect(throws: MusicSessionError.policy) { try await client(transport).browse(id: "FEmusic_home", params: nil, session: nil) }
        await #expect(throws: MusicSessionError.policy) { try await client(transport).continuation(token: "tok", session: nil) }
        #expect(await transport.captured().isEmpty)
    }
    @Test func theAllowlistStillRefusesEveryOtherPathAndTheArtworkHostsAreExact() throws {
        #expect(SignedMusicPolicy.musicPaths == ["/youtubei/v1/browse", "/youtubei/v1/account/account_menu", "/youtubei/v1/search", "/youtubei/v1/next"])
        func image(_ text: String) -> URLRequest { var r = URLRequest(url: URL(string: text)!); r.httpMethod = "GET"; return r }
        for good in ["https://yt3.googleusercontent.com/a=w226-h226", "https://lh3.googleusercontent.com/a", "https://i.ytimg.com/vi/x/hq.jpg", "https://yt3.ggpht.com/a"] {
            #expect(throws: Never.self) { try SignedMusicPolicy.validate(image(good), maximumBytes: 524_288) }
        }
        for bad in ["https://evil.example/a.jpg", "https://i.ytimg.com.evil.example/a", "http://i.ytimg.com/a", "https://www.youtube.com/a.jpg", "https://ytimg.com/a"] {
            #expect(throws: MusicSessionError.policy, "\(bad)") { try SignedMusicPolicy.validate(image(bad), maximumBytes: 524_288) }
        }
        var credentialed = image("https://i.ytimg.com/vi/x/hq.jpg"); credentialed.setValue("a=b", forHTTPHeaderField: "Cookie")
        #expect(throws: MusicSessionError.policy) { try SignedMusicPolicy.validate(credentialed, maximumBytes: 524_288) }
    }
    @Test func artworkFetchRequiresAnImageResponseWithinTheCap() async throws {
        let url = URL(string: "https://i.ytimg.com/vi/x/hq.jpg")!
        let image = try ScriptedSigned(body: Data([0xFF, 0xD8, 0xFF]), type: "image/jpeg")
        #expect(try await client(image).artwork(url) == Data([0xFF, 0xD8, 0xFF]))
        await #expect(throws: MusicSessionError.unrecognised) { try await client(try ScriptedSigned(body: Data("<html>".utf8), type: "text/html")).artwork(url) }
        await #expect(throws: MusicSessionError.unrecognised) { try await client(try ScriptedSigned(body: Data(), type: "image/jpeg")).artwork(url) }
        await #expect(throws: MusicSessionError.policy) { try await client(image).artwork(URL(string: "https://evil.example/a.jpg")!) }
    }
}

@Suite struct PublicBrowseTests {
    @Test func theAnonymousRequestCarriesNoCredentialAndBootstrapsOnDemand() async throws {
        let transport = try ScriptedPublic(.explore)
        let client = try PublicMusicClient(transport: transport)
        let page = try await client.browsePage(id: "FEmusic_explore")
        #expect(page == (try realPage(.explore)))
        let requests = await transport.captured()
        #expect(requests.map { $0.url?.path ?? "" } == ["/", "/youtubei/v1/browse"])
        let browse = try #require(requests.last)
        #expect(browse.value(forHTTPHeaderField: "Authorization") == nil && browse.value(forHTTPHeaderField: "Cookie") == nil && browse.httpMethod == "POST")
        let sent = try json(browse)
        #expect(browse.url?.query == "prettyPrint=false" && sent["browseId"] as? String == "FEmusic_explore")
    }
    @Test func aContinuationIsAnAnonymousPostWithTheTokenInTheBody() async throws {
        let transport = try ScriptedPublic(body: try Data(contentsOf: fixturesRoot().appendingPathComponent("W11/continuation-section-list.json")))
        let page = try await PublicMusicClient(transport: transport).browseContinuation(token: "tok%3D")
        #expect(page.shelves.count == 1 && page.continuation == "SYNTHETICpageToken-3")
        let sent = try json(try #require(await transport.captured().last))
        #expect(sent["continuation"] as? String == "tok%3D")
    }
    @Test func theSignedClientDelegatesAnAnonymousBrowseToThePublicClient() async throws {
        let transport = try ScriptedPublic(.moods)
        let signed = SignedMusicClient(publicClient: try PublicMusicClient(transport: transport), transport: try ScriptedSigned(.home), clock: Now())
        let result = try await signed.browse(id: "FEmusic_moods_and_genres", params: nil, session: nil)
        #expect(result.value.heading == "Moods & genres" && result.rotation.isEmpty)
        #expect(await transport.captured().last?.value(forHTTPHeaderField: "Authorization") == nil)
        let continued = try await SignedMusicClient(publicClient: try PublicMusicClient(transport: try ScriptedPublic(body: try Data(contentsOf: fixturesRoot().appendingPathComponent("W11/continuation-end.json")))),
                                                    transport: try ScriptedSigned(.home), clock: Now()).continuation(token: "tok", session: nil)
        #expect(continued.value.continuation == nil)
    }
    @Test func publicFailuresMapToTheSessionErrorsTheCoordinatorUnderstands() async throws {
        func signed(_ transport: ScriptedPublic) throws -> SignedMusicClient { SignedMusicClient(publicClient: try PublicMusicClient(transport: transport), transport: try ScriptedSigned(.home), clock: Now()) }
        await #expect(throws: MusicSessionError.unrecognised) { try await signed(try ScriptedPublic(body: Data(#"{"contents":{"x":{}}}"#.utf8))).browse(id: "FEmusic_home", params: nil, session: nil) }
        await #expect(throws: MusicSessionError.rateLimited) { try await signed(try ScriptedPublic(.home, status: 429)).browse(id: "FEmusic_home", params: nil, session: nil) }
        await #expect(throws: MusicSessionError.server) { try await signed(try ScriptedPublic(.home, status: 500)).browse(id: "FEmusic_home", params: nil, session: nil) }
    }
    @Test func hostileInputIsRefusedBeforeAnythingIsSent() async throws {
        let transport = try ScriptedPublic(.home)
        let client = try PublicMusicClient(transport: transport)
        await #expect(throws: ConnectionError.invalidInput) { try await client.browsePage(id: "bad id") }
        await #expect(throws: ConnectionError.invalidInput) { try await client.browsePage(id: "FEmusic_home", params: "bad params") }
        await #expect(throws: ConnectionError.invalidInput) { try await client.browseContinuation(token: "bad token") }
        #expect(await transport.captured().isEmpty)
    }
    @Test func thePublicTransportAllowsBrowseAndStillRefusesOtherPaths() async throws {
        let transport = DirectPublicTransport(clock: FrozenClock(), execute: { _, _ in .init(data: Data("{}".utf8), status: 200) })
        func post(_ path: String) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://music.youtube.com\(path)?prettyPrint=false")!)
            request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); return request
        }
        _ = try await transport.send(post("/youtubei/v1/browse"), maximumBytes: 4_000_000)
        // W18 added `next` (the song's lyrics tab) as the fourth read path; it is allowed, and these stay refused.
        _ = try await transport.send(post("/youtubei/v1/next"), maximumBytes: 4_000_000)
        for path in ["/youtubei/v1/next/x", "/youtubei/v1/music/get_queue", "/youtubei/v1/account/account_menu", "/youtubei/v1/browse/x"] {
            await #expect(throws: ConnectionError.origin, "\(path)") { try await transport.send(post(path), maximumBytes: 4_000_000) }
        }
    }
}
private struct FrozenClock: ConnectionClock {
    func now() -> TimeInterval { 0 }
    func sleep(until: TimeInterval) async throws {}
}
