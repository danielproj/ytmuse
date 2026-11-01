import AccountSession
import Domain
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// The real Music `search` request and response shapes — signed and public — against
/// labelled synthetic fixtures (Fixtures/W10: hand-written to the published result shape,
/// not captured from the service).
@Suite struct SearchParserTests {
    private func root(_ name: String) throws -> [String: Any] {
        let data = try searchFixture(name)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    @Test func theFixtureManifestLabelsEverythingSynthetic() throws {
        let manifest = try root("manifest.json")
        #expect(manifest["mode"] as? String == "synthetic-test-only" && manifest["live_eligible"] as? Bool == false)
        let files = try #require(manifest["files"] as? [String])
        #expect(files.count >= 9 && files.allSatisfy { FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/W10/" + $0).path) })
    }
    @Test func theTopCardAndEveryTypedShelfAreParsedFromTheirOwnEndpoints() throws {
        let parsed = try MusicSearchParser.parse(try root("search-all-groups.json"))
        #expect(parsed.top == MusicSearchItem(kind: .song, title: "Café del Mar", subtitle: "Synthetic Artist • 3:45", videoID: "aaaaaaaaaa1"),
                "the service's type label ('Song') is removed from the detail line")
        let kinds = parsed.items.map(\.kind)
        #expect(kinds == [.song, .song, .video, .album, .artist, .playlist, .playlist, .podcast, .episode])
        let titles = parsed.items.map(\.title)
        #expect(titles == ["Café del Mar (Radio Edit)", "Noche Cálida", "Café del Mar (Official Video)", "Synthetic Album", "Synthetic Artist", "Café Mix", "My cafe list", "Cafe Talk", "Brewing music"])
        #expect(parsed.items[1].explicit && !parsed.items[0].explicit)
        #expect(parsed.items[1].subtitle == "Synthetic Artist • Synthetic Album • 4:02")
        #expect(!parsed.complete, "one page, never a claim about the catalog")
    }
    @Test func identifiersComeFromTheRowsEndpointsAndNothingIsInvented() throws {
        let parsed = try MusicSearchParser.parse(try root("search-all-groups.json"))
        let byTitle = Dictionary(uniqueKeysWithValues: parsed.items.map { ($0.title, $0) })
        #expect(byTitle["Synthetic Album"]?.browseID == "MPREb_synthetic01" && byTitle["Synthetic Album"]?.playlistID == "OLAK5uy_syntheticAlbum01")
        #expect(byTitle["Café Mix"]?.browseID == "VLPLsyntheticFeatured01" && byTitle["Café Mix"]?.playlistID == "PLsyntheticFeatured01")
        #expect(byTitle["Cafe Talk"]?.playlistID == "PLsyntheticShow01")
        #expect(byTitle["Synthetic Artist"]?.browseID == "UCaaaaaaaaaaaaaaaaaaaaaa" && byTitle["Synthetic Artist"]?.playlistID == nil && byTitle["Synthetic Artist"]?.subtitle == nil)
        #expect(byTitle["Brewing music"]?.videoID == "cccccccccc1" && byTitle["Brewing music"]?.playlistID == nil, "an episode is not given a made-up playlist")
        #expect(byTitle["Café del Mar (Official Video)"]?.videoID == "bbbbbbbbbb1")
    }
    @Test func rowsThatCannotBeReadOrAreNotShownAreCountedNeverDropped() throws {
        let parsed = try MusicSearchParser.parse(try root("search-all-groups.json"))
        #expect(parsed.skippedRows == 1, "the song whose id is not an 11-character video id")
        #expect(parsed.unsupportedRows == 1, "the channel profile")
        #expect(!parsed.items.contains { $0.title.contains("Broken") || $0.title.contains("Listener") })
    }
    @Test func theTopResultIsNotRepeatedAndDuplicatesAreMerged() throws {
        let parsed = try MusicSearchParser.parse(try root("search-all-groups.json"))
        let ids = ([parsed.top].compactMap { $0 } + parsed.items).map(\.id)
        #expect(Set(ids).count == ids.count)
    }
    @Test func didYouMeanIsASuggestionAndShowingResultsForIsLabelledAsAlreadyApplied() throws {
        #expect(try MusicSearchParser.parse(try root("search-all-groups.json")).suggestion == MusicSearchSuggestion(text: "cafe del mar", appliedByService: false))
        let showing = try MusicSearchParser.parse(try root("search-showing-results-for.json"))
        #expect(showing.suggestion == MusicSearchSuggestion(text: "Synthetic Artist", appliedByService: true) && showing.items.count == 1)
    }
    @Test func anExplicitNoResultsMessageIsNotAnError() throws {
        let parsed = try MusicSearchParser.parse(try root("search-no-results.json"))
        #expect(parsed.serviceReportedNoResults && parsed.top == nil && parsed.items.isEmpty)
    }
    @Test func aPageOfOnlyUnshownKindsIsNotUnrecognised() throws {
        let parsed = try MusicSearchParser.parse(try root("search-only-profile.json"))
        #expect(parsed.items.isEmpty && parsed.unsupportedRows == 1 && !parsed.serviceReportedNoResults)
    }
    @Test func anythingElseIsUnrecognisedNeverAnEmptyList() throws {
        for name in ["search-unrecognised-shape.json", "search-empty-section-list.json", "search-all-rows-broken.json", "search-error.json"] {
            #expect(throws: MusicSessionError.unrecognised, "\(name)") { try MusicSearchParser.parse(try root(name)) }
        }
        #expect(throws: MusicSessionError.unrecognised) { try MusicSearchParser.parse([:]) }
    }
    @Test func aPageWhoseOnlyReadableRowsAreUnshownKindsStillReportsTheUnreadableOne() throws {
        // One unreadable row beside a profile: rows existed and none could be read, so this is a layout
        // change to report, not a confident "nothing here".
        #expect(throws: MusicSessionError.unrecognised) { try MusicSearchParser.parse(try root("search-broken-and-profile.json")) }
    }
    @Test func theTypeComesFromTheEndpointsNotFromLocalisedText() throws {
        var document = try root("search-all-groups.json")
        let text = String(data: try JSONSerialization.data(withJSONObject: document), encoding: .utf8)!
            .replacingOccurrences(of: "\"Song\"", with: "\"Titre\"").replacingOccurrences(of: "\"Album\"", with: "\"Disque\"")
            .replacingOccurrences(of: "\"Songs\"", with: "\"Titres\"")
        let rewritten = try JSONSerialization.jsonObject(with: Data(text.utf8))
        document = try #require(rewritten as? [String: Any])
        let parsed = try MusicSearchParser.parse(document)
        #expect(parsed.items.map(\.kind) == [.song, .song, .video, .album, .artist, .playlist, .playlist, .podcast, .episode])
        #expect(parsed.items[1].subtitle == "Synthetic Artist • Synthetic Album • 4:02", "the first run is dropped as the label whatever its language")
    }
    @Test func theSearchPathIsAllowedAndOtherMusicPathsStayClosed() throws {
        #expect(SignedMusicPolicy.musicPaths == ["/youtubei/v1/browse", "/youtubei/v1/account/account_menu", "/youtubei/v1/search", "/youtubei/v1/next"])
    }
}

private actor ScriptedSigned: SignedMusicTransport {
    var requests: [URLRequest] = []
    var next: SignedMusicWireResponse
    init(_ fixture: String, status: Int = 200) throws { next = .init(status: status, body: try searchFixture(fixture), contentType: "application/json; charset=UTF-8") }
    func set(_ response: SignedMusicWireResponse) { next = response }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        try SignedMusicPolicy.validate(request, maximumBytes: maximumBytes)
        requests.append(request)
        return next
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

@Suite struct SignedSearchTests {
    private func client(_ transport: ScriptedSigned) -> SignedMusicClient { SignedMusicClient(transport: transport, clock: Now()) { "1.20261028.01.00" } }
    @Test func theSignedRequestIsTheMusicSearchPostWithTheQueryOnlyInTheBody() async throws {
        let transport = try ScriptedSigned("search-all-groups.json")
        let result = try await client(transport).search(query: "café ☕ 東京", session: try session())
        #expect(result.value.top?.title == "Café del Mar")
        let request = try #require(await transport.captured().first)
        #expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("SAPISID=") == true)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://music.youtube.com" && request.value(forHTTPHeaderField: "X-Origin") == "https://music.youtube.com")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["query"] as? String == "café ☕ 東京")
        let client = try #require((body["context"] as? [String: Any])?["client"] as? [String: Any])
        #expect(client["clientName"] as? String == "WEB_REMIX" && client["clientVersion"] as? String == "1.20261028.01.00")
        #expect(request.url?.query == "prettyPrint=false", "the query is never placed in the URL")
    }
    @Test func aSignedOutAnswerIsSignedOutAndAnUnreadableOneIsUnrecognised() async throws {
        let signedOut = try ScriptedSigned("search-signed-out.json")
        await #expect(throws: MusicSessionError.signedOut) { try await client(signedOut).search(query: "q", session: try session()) }
        let unknown = try ScriptedSigned("search-unrecognised-shape.json")
        await #expect(throws: MusicSessionError.unrecognised) { try await client(unknown).search(query: "q", session: try session()) }
        let denied = try ScriptedSigned("search-all-groups.json", status: 403)
        await #expect(throws: MusicSessionError.signedOut) { try await client(denied).search(query: "q", session: try session()) }
        let limited = try ScriptedSigned("search-all-groups.json", status: 429)
        await #expect(throws: MusicSessionError.rateLimited) { try await client(limited).search(query: "q", session: try session()) }
    }
    @Test func emptyAndOverlongQueriesNeverReachTheWire() async throws {
        let transport = try ScriptedSigned("search-all-groups.json")
        let signed = client(transport)
        await #expect(throws: MusicSessionError.policy) { try await signed.search(query: "   ", session: try session()) }
        await #expect(throws: MusicSessionError.policy) { try await signed.search(query: String(repeating: "a", count: 513), session: try session()) }
        #expect(await transport.captured().isEmpty)
    }
    @Test func withoutASessionAndWithoutAnAnonymousClientNothingIsSent() async throws {
        let transport = try ScriptedSigned("search-all-groups.json")
        await #expect(throws: MusicSessionError.policy) { try await client(transport).search(query: "q", session: nil) }
        #expect(await transport.captured().isEmpty)
    }
}

private actor ScriptedPublic: PublicHTTPTransport {
    var requests: [URLRequest] = []
    var searchBody: Data
    var gate: CheckedContinuation<Void, Never>?
    var holdNext = false
    init(_ fixture: String) throws { searchBody = try searchFixture(fixture) }
    func hold() { holdNext = true }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse {
        requests.append(request)
        if request.url?.path == "/" { return .init(data: Data(#"{"INNERTUBE_CLIENT_VERSION":"1.20261028.01.00","INNERTUBE_CONTEXT_CLIENT_NAME":"WEB_REMIX"}"#.utf8), status: 200) }
        if holdNext { holdNext = false; await withCheckedContinuation { gate = $0 } }
        return .init(data: searchBody, status: 200)
    }
    func captured() -> [URLRequest] { requests }
}

@Suite struct PublicSearchTests {
    @Test func theAnonymousRequestCarriesNoCredentialAndBootstrapsOnDemand() async throws {
        let transport = try ScriptedPublic("search-all-groups.json")
        let client = try PublicMusicClient(transport: transport)
        let parsed = try await client.searchResponse("café")
        #expect(parsed.top?.title == "Café del Mar")
        let requests = await transport.captured()
        #expect(requests.map { $0.url?.path ?? "" } == ["/", "/youtubei/v1/search"], "the client version is fetched once, first")
        let search = try #require(requests.last)
        #expect(search.value(forHTTPHeaderField: "Authorization") == nil && search.value(forHTTPHeaderField: "Cookie") == nil)
        let bodyData = try #require(search.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["query"] as? String == "café")
        _ = try await client.searchResponse("again")
        #expect(await transport.captured().count == 3, "the second search reuses the bootstrap")
    }
    @Test func aNewerSearchOrAnInvalidationMakesTheOlderReplyStale() async throws {
        let transport = try ScriptedPublic("search-all-groups.json")
        let client = try PublicMusicClient(transport: transport)
        _ = try await client.bootstrap()
        await transport.hold()
        let older = Task { try await client.searchResponse("older") }
        while !(await transport.waiting()) { await Task.yield() }
        _ = try await client.searchResponse("newer")
        await transport.release()
        await #expect(throws: ConnectionError.stale) { try await older.value }
        await transport.hold()
        let invalidated = Task { try await client.searchResponse("invalidated") }
        while !(await transport.waiting()) { await Task.yield() }
        await client.invalidate(); await transport.release()
        await #expect(throws: ConnectionError.stale) { try await invalidated.value }
    }
    @Test func theSignedClientDelegatesAnAnonymousSearchToThePublicClient() async throws {
        let transport = try ScriptedPublic("search-all-groups.json")
        let publicClient = try PublicMusicClient(transport: transport)
        let signed = SignedMusicClient(publicClient: publicClient, transport: try ScriptedSigned("search-all-groups.json"), clock: Now())
        let result = try await signed.search(query: "café", session: nil)
        #expect(result.value.items.count == 9 && result.rotation.isEmpty)
        #expect(await transport.captured().last?.value(forHTTPHeaderField: "Authorization") == nil)
    }
    @Test func publicFailuresMapToTheSessionErrorsTheCoordinatorUnderstands() async throws {
        let unreadable = try ScriptedPublic("search-unrecognised-shape.json")
        let signed = SignedMusicClient(publicClient: try PublicMusicClient(transport: unreadable), transport: try ScriptedSigned("search-all-groups.json"), clock: Now())
        await #expect(throws: MusicSessionError.unrecognised) { try await signed.search(query: "q", session: nil) }
        #expect(throws: ConnectionError.http(500)) { try PublicMusicClient.parseSearchResponse(.init(data: Data(), status: 500)) }
        #expect(SignedMusicClient.classifyConnection(.http(429)) == .rateLimited && SignedMusicClient.classifyConnection(.http(503)) == .server)
        #expect(SignedMusicClient.classifyConnection(.shape) == .unrecognised && SignedMusicClient.classifyConnection(.stale) == .stale)
    }
    @Test func theNarrowLegacyParserIsUnchanged() throws {
        let data = Data(#"{"contents":{"musicResponsiveListItemRenderer":{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Synthetic parser case"}]}}}],"playlistItemData":{"videoId":"abcdefghijk"}}}}"#.utf8)
        #expect(try PublicMusicClient.parseSearch(.init(data: data, status: 200)).count == 1)
    }
}
