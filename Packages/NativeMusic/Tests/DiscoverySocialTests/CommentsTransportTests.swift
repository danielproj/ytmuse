import AccountSession
import Domain
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// MF-C2: the comments READ transport, anonymous and signed, against fake transports that serve the real anonymous captures in
/// `Fixtures/MF-comments` (public data, personal values replaced; see that folder's manifest). Nothing here reaches a network, an account,
/// a store or a signed service: the "signed" client talks to a fake that applies the REAL `SignedMusicPolicy.validate`, so a request the
/// policy would refuse fails the test. Signed comment shapes have not been observed; these tests prove code paths, request counts, bodies,
/// size caps, error mapping and fences, NOT signed runtime behaviour. The coordinator's token and account fences are in `MusicWebSessionTests`.
private enum Wire {
    static let video = "khnokW3Mw24"
    static let firstThread = "UgwyhRsFkVy0erxIjJd4AaABAg"
    static let version = "1.20261028.01.00"
    static let disabled = ["XqZsoesa55w", "WRVsOCh907o", "e_04ZrNroTo"]
    static func data(_ name: String) throws -> Data { try Data(contentsOf: fixturesRoot().appendingPathComponent("MF-comments/" + name)) }
    static func json(_ name: String) throws -> [String: Any] {
        let bytes = try data(name)
        return try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    /// A JSON document padded with trailing whitespace to exactly `count` bytes (still valid JSON).
    static func padded(_ data: Data, to count: Int) -> Data { data + Data(repeating: 0x20, count: count - data.count) }
    static let loggedOut = Data(#"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":true}}}"#.utf8)
    static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    static func clientContext(user: Bool) -> [String: Any] {
        var context: [String: Any] = ["client": ["clientName": "WEB_REMIX", "clientVersion": version, "hl": "en"]]
        if user { context["user"] = ["lockedSafetyMode": false] }
        return context
    }
    /// The whole body, compared as a parsed dictionary: key order is not part of the contract.
    static func sameBody(_ actual: [String: Any], _ expected: [String: Any]) -> Bool { NSDictionary(dictionary: actual).isEqual(to: expected) }
    static var homepage: Data { Data(#"{"INNERTUBE_CLIENT_VERSION":"\#(version)","INNERTUBE_CONTEXT_CLIENT_NAME":"WEB_REMIX"}"#.utf8) }
}
private struct FrozenClock: ConnectionClock {
    func now() -> TimeInterval { 0 }
    func sleep(until: TimeInterval) async throws {}
}
private struct FixedWall: WallClock { func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) } }
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}
private func session() throws -> MusicCookieSession {
    func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: ".youtube.com", .path: "/", .expires: Date(timeIntervalSince1970: 1_700_000_000 + 86_400)])!
    }
    return try MusicCookieSession(accountID: UUID(), cookies: [cookie("SAPISID", "SYNTHETIC-COMMENTS-SAPISID"), cookie("SID", "SYNTHETIC-COMMENTS-SID")],
                                  now: Date(timeIntervalSince1970: 1_700_000_000))
}
private func rotated(_ value: String) -> [MusicSessionCookie] {
    [MusicSessionCookie(name: "__Secure-3PSIDCC", value: value, expires: Date(timeIntervalSince1970: 1_700_003_600))]
}
private func attempt<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

/// What a request body asks for.
private enum Incoming { case video(String), continuation(String), other }
private func incoming(_ request: URLRequest) -> Incoming {
    guard let body = try? Wire.body(request) else { return .other }
    if let token = body["continuation"] as? String { return .continuation(token) }
    if let id = body["videoId"] as? String { return .video(id) }
    return .other
}

/// The service, as the captures show it: a video id answers with its watch-next page; a token answers with the page it was published for;
/// any other token answers with the stale-continuation shell (a 200 watch page, as the service did for a bad token).
private struct Routes: Sendable {
    let watch: [String: Data]
    let byToken: [String: Data]
    let shell: Data
    let entryToken: String, pageToken: String, topSort: String, newestSort: String, repliesToken: String
    let firstPage: MusicCommentsPage
    func answer(_ request: Incoming) -> Data {
        switch request {
        case .video(let id): watch[id] ?? shell
        case .continuation(let token): byToken[token] ?? shell
        case .other: shell
        }
    }
    static func load() throws -> Routes {
        let next = try Wire.json("next-\(Wire.video).json")
        guard case .continuation(let entry) = try MusicCommentsParser.parseEntry(next, videoID: Wire.video) else { throw MusicSessionError.unrecognised }
        let page = try MusicCommentsParser.parsePage(try Wire.json("comments-\(Wire.video).json"), videoID: Wire.video)
        let header = try #require(page.header)
        let top = try #require(header.sortOptions.first { $0.title == "Top" }).token
        let newest = try #require(header.sortOptions.first { $0.title == "Newest" }).token
        let thread = try #require(page.threads.first { $0.comment.id == Wire.firstThread })
        let nextToken = try #require(page.nextToken), repliesToken = try #require(thread.repliesToken)
        var watch = [Wire.video: try Wire.data("next-\(Wire.video).json"), "Qx7Lm2Zk9Vw": try Wire.data("next-Qx7Lm2Zk9Vw.json")]
        for id in Wire.disabled { watch[id] = try Wire.data("next-\(id).json") }
        let first = try Wire.data("comments-\(Wire.video).json")
        let pairs = [(entry, first), (top, first), (newest, try Wire.data("comments-\(Wire.video)-newest.json")),
                     (nextToken, try Wire.data("comments-\(Wire.video)-page2.json")), (repliesToken, try Wire.data("comments-\(Wire.video)-replies.json"))]
        return Routes(watch: watch, byToken: Dictionary(pairs, uniquingKeysWith: { current, _ in current }),
                      shell: try Wire.data("comments-invalid-continuation.json"), entryToken: entry, pageToken: nextToken, topSort: top, newestSort: newest,
                      repliesToken: repliesToken, firstPage: page)
    }
}
/// What a fake returns for one request: the route's answer unless a test overrides it.
private struct Answer: Sendable {
    var status = 200
    var data: Data
    var contentType = "application/json; charset=UTF-8"
    var rotation: [MusicSessionCookie] = []
}
private typealias Override = @Sendable (_ index: Int, _ incoming: Incoming) -> Answer?

private actor PublicWire: PublicHTTPTransport {
    struct Seen { let request: URLRequest; let maximumBytes: Int }
    private(set) var all: [Seen] = []
    private let routes: Routes
    private let override: Override?
    init(_ routes: Routes, override: Override? = nil) { self.routes = routes; self.override = override }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse {
        if request.url?.path == "/" {
            all.append(Seen(request: request, maximumBytes: maximumBytes))
            return .init(data: Wire.homepage, status: 200)
        }
        let index = posts.count
        all.append(Seen(request: request, maximumBytes: maximumBytes))
        let what = incoming(request)
        if let custom = override?(index, what) { return .init(data: custom.data, status: custom.status) }
        return .init(data: routes.answer(what), status: 200)
    }
    /// Comments requests only (not the one version bootstrap GET).
    var posts: [Seen] { all.filter { $0.request.url?.path != "/" } }
}
private actor SignedWire: SignedMusicTransport {
    struct Seen { let request: URLRequest; let maximumBytes: Int }
    private(set) var seen: [Seen] = []
    private let routes: Routes
    private let override: Override?
    init(_ routes: Routes, override: Override? = nil) { self.routes = routes; self.override = override }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        try SignedMusicPolicy.validate(request, maximumBytes: maximumBytes)
        let index = seen.count
        seen.append(Seen(request: request, maximumBytes: maximumBytes))
        let what = incoming(request)
        let answer = override?(index, what) ?? Answer(data: routes.answer(what))
        return .init(status: answer.status, body: answer.data, contentType: answer.contentType, rotation: answer.rotation)
    }
}
private func publicClient(_ wire: PublicWire) throws -> PublicMusicClient { try PublicMusicClient(transport: wire, clock: FrozenClock()) }
private func signedClient(_ wire: SignedWire, anonymous: PublicMusicClient? = nil, versions: Counter = Counter()) -> SignedMusicClient {
    SignedMusicClient(transport: wire, clock: FixedWall(), anonymous: anonymous) { versions.bump(); return Wire.version }
}

@Suite struct CommentsTransportTests {
    // MARK: Requests, counts and exact bodies

    @Test func anonymousOpenIsTwoRequestsWithTheExactBodiesAndNoCredentials() async throws {
        let routes = try Routes.load()
        let wire = PublicWire(routes)
        let answer = try await publicClient(wire).comments(.open(videoID: Wire.video))
        let posts = await wire.posts
        #expect(posts.count == 2, "open is next{videoId}, then ONE continuation: never a third request")
        #expect(try Wire.sameBody(Wire.body(posts[0].request), ["videoId": Wire.video, "isAudioOnly": true, "context": Wire.clientContext(user: false)]))
        #expect(try Wire.sameBody(Wire.body(posts[1].request), ["continuation": routes.entryToken, "context": Wire.clientContext(user: false)]))
        #expect(posts.map(\.maximumBytes) == [4_000_000, 2_000_000], "the first answer keeps the existing next cap; the comments response is capped at 2,000,000")
        for post in posts {
            #expect(post.request.url?.absoluteString == "https://music.youtube.com/youtubei/v1/next?prettyPrint=false" && post.request.httpMethod == "POST")
            #expect(post.request.value(forHTTPHeaderField: "Cookie") == nil && post.request.value(forHTTPHeaderField: "Authorization") == nil)
        }
        // One bootstrap GET of the home page for the client version, and nothing else: no avatar, no other host or path.
        let all = await wire.all
        #expect(all.count == 3 && all[0].request.url?.absoluteString == "https://music.youtube.com/")
        #expect(all.allSatisfy { $0.request.url?.host == "music.youtube.com" })
        #expect(answer == .opened(entry: .continuation(routes.entryToken), firstPage: routes.firstPage))
        #expect(routes.firstPage.nextToken != nil, "the first page offers a next page, and open still did not follow it")
    }
    @Test func pageSortSwitchAndRepliesAreExactlyOneContinuationRequestEach() async throws {
        let routes = try Routes.load()
        let cases: [(MusicCommentsRequest, String)] = [
            (.page(token: routes.pageToken, videoID: Wire.video), routes.pageToken),
            (.page(token: routes.newestSort, videoID: Wire.video), routes.newestSort),
            (.replies(token: routes.repliesToken, videoID: Wire.video, parentID: Wire.firstThread), routes.repliesToken),
        ]
        for (request, token) in cases {
            let wire = PublicWire(routes)
            let answer = try await publicClient(wire).comments(request)
            let posts = await wire.posts
            #expect(posts.count == 1)
            #expect(try Wire.sameBody(Wire.body(posts[0].request), ["continuation": token, "context": Wire.clientContext(user: false)]), "nothing but the token and the client context")
            #expect(posts[0].maximumBytes == 2_000_000)
            switch (token, answer) {
            case (routes.pageToken, .page(let page)): #expect(page.header == nil && !page.threads.isEmpty)
            case (routes.newestSort, .page(let page)): #expect(page.header?.sortOptions.first { $0.isSelected }?.title == "Newest")
            case (routes.repliesToken, .replies(let replies)): #expect(replies.parentID == Wire.firstThread && replies.replies.count == 10)
            default: Issue.record("wrong answer kind \(answer)")
            }
        }
    }
    @Test func theSignedPathSendsTheSameCountsAndBodiesPlusTheSessionAndRotatesBothAnswers() async throws {
        let routes = try Routes.load()
        let wire = SignedWire(routes, override: { index, what in Answer(data: routes.answer(what), rotation: rotated("ROTATED-\(index)")) })
        let versions = Counter()
        let client = signedClient(wire, versions: versions)
        let signedSession = try session()
        let opened = try await client.comments(.open(videoID: Wire.video), session: signedSession)
        let seen = await wire.seen
        #expect(seen.count == 2 && versions.value == 1)
        #expect(try Wire.sameBody(Wire.body(seen[0].request), ["videoId": Wire.video, "isAudioOnly": true, "context": Wire.clientContext(user: true)]))
        #expect(try Wire.sameBody(Wire.body(seen[1].request), ["continuation": routes.entryToken, "context": Wire.clientContext(user: true)]))
        #expect(seen.map(\.maximumBytes) == [4_000_000, 2_000_000])
        for item in seen {
            #expect(item.request.url?.absoluteString == "https://music.youtube.com/youtubei/v1/next?prettyPrint=false")
            #expect(item.request.value(forHTTPHeaderField: "Cookie") == signedSession.cookieHeader)
            #expect(item.request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        }
        #expect(opened.value == .opened(entry: .continuation(routes.entryToken), firstPage: routes.firstPage))
        #expect(opened.rotation.map(\.value) == ["ROTATED-0", "ROTATED-1"], "both answers' rotated cookies are returned for the coordinator to store")
        let page = try await client.comments(.page(token: routes.pageToken, videoID: Wire.video), session: signedSession)
        let replies = try await client.comments(.replies(token: routes.repliesToken, videoID: Wire.video, parentID: Wire.firstThread), session: signedSession)
        let all = await wire.seen
        #expect(all.count == 4, "page and replies are one request each")
        #expect(try Wire.sameBody(Wire.body(all[2].request), ["continuation": routes.pageToken, "context": Wire.clientContext(user: true)]))
        #expect(try Wire.sameBody(Wire.body(all[3].request), ["continuation": routes.repliesToken, "context": Wire.clientContext(user: true)]))
        guard case .page = page.value, case .replies = replies.value else { Issue.record("wrong answer kinds"); return }
    }
    @Test func theAnonymousPathOfTheSignedClientIsTheSameReadWithNoSession() async throws {
        let routes = try Routes.load()
        let signedWire = SignedWire(routes), publicWire = PublicWire(routes)
        let client = signedClient(signedWire, anonymous: try publicClient(publicWire))
        let result = try await client.comments(.open(videoID: Wire.video), session: nil)
        #expect(result.rotation.isEmpty && result.value == .opened(entry: .continuation(routes.entryToken), firstPage: routes.firstPage))
        #expect(await signedWire.seen.isEmpty, "a nil session never reaches the signed transport")
        let posts = await publicWire.posts
        #expect(posts.count == 2 && posts.allSatisfy { $0.request.value(forHTTPHeaderField: "Cookie") == nil && $0.request.value(forHTTPHeaderField: "Authorization") == nil })
        await #expect(throws: MusicSessionError.policy) { try await signedClient(SignedWire(routes)).comments(.open(videoID: Wire.video), session: nil) }
    }
    @Test func everyCommentsRequestPassesTheRealPublicAllowlistAndNothingMoreIsAllowed() async throws {
        let routes = try Routes.load()
        let sent = Locked<[URLRequest]>([])
        let transport = DirectPublicTransport(clock: FrozenClock(), execute: { request, _ in
            sent.mutate { $0.append(request) }
            if request.url?.path == "/" { return .init(data: Wire.homepage, status: 200) }
            return .init(data: routes.answer(incoming(request)), status: 200)
        })
        let client = try PublicMusicClient(transport: transport, clock: FrozenClock())
        _ = try await client.comments(.open(videoID: Wire.video))
        _ = try await client.comments(.page(token: routes.pageToken, videoID: Wire.video))
        _ = try await client.comments(.replies(token: routes.repliesToken, videoID: Wire.video, parentID: Wire.firstThread))
        #expect(sent.value.count == 5 && Set(sent.value.compactMap { $0.url?.path }) == ["/", "/youtubei/v1/next"])
        // The allowlist is unchanged: a comment write or reply-listing path is refused by the real transport, before anything is sent.
        func post(_ path: String, headers: [String: String] = [:]) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://music.youtube.com\(path)?prettyPrint=false")!)
            request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            return request
        }
        let before = sent.value.count
        for path in ["/youtubei/v1/comment/create_comment", "/youtubei/v1/comment/get_comment_replies", "/youtubei/v1/comment/perform_comment_action",
                     "/youtubei/v1/comment/update_comment", "/youtubei/v1/next/x"] {
            await #expect(throws: ConnectionError.origin, "\(path)") { try await transport.send(post(path), maximumBytes: 2_000_000) }
        }
        await #expect(throws: ConnectionError.origin) { try await transport.send(post("/youtubei/v1/next", headers: ["Cookie": "A=B"]), maximumBytes: 2_000_000) }
        await #expect(throws: ConnectionError.origin) { try await transport.send(post("/youtubei/v1/next", headers: ["Authorization": "SAPISIDHASH x"]), maximumBytes: 2_000_000) }
        await #expect(throws: ConnectionError.origin) { try await transport.send(post("/youtubei/v1/next"), maximumBytes: 4_000_001) }
        #expect(sent.value.count == before)
        _ = try await transport.send(post("/youtubei/v1/next"), maximumBytes: 2_000_000)
    }
    @Test func thePolicySetsAreExactlyWhatTheyWereBeforeComments() {
        #expect(SignedMusicPolicy.musicPaths == ["/youtubei/v1/browse", "/youtubei/v1/account/account_menu", "/youtubei/v1/search", "/youtubei/v1/next"])
        #expect(SignedMusicPolicy.writePaths == ["/youtubei/v1/like/like", "/youtubei/v1/like/dislike", "/youtubei/v1/like/removelike",
                                                 "/youtubei/v1/subscription/subscribe", "/youtubei/v1/subscription/unsubscribe", "/youtubei/v1/feedback"])
        #expect(SignedMusicPolicy.playlistWritePaths == ["/youtubei/v1/playlist/create", "/youtubei/v1/browse/edit_playlist", "/youtubei/v1/playlist/delete"])
        let all = SignedMusicPolicy.musicPaths.union(SignedMusicPolicy.writePaths).union(SignedMusicPolicy.playlistWritePaths)
        #expect(!all.contains { $0.contains("comment") }, "no comment endpoint is allowlisted: C2 reads through next only")
    }

    // MARK: Entry states

    @Test func aTabThatPrintsAMessageIsTheServicesMessageAndOneRequestNeverACommentsPage() async throws {
        let routes = try Routes.load()
        for id in Wire.disabled {
            let wire = PublicWire(routes)
            let answer = try await publicClient(wire).comments(.open(videoID: id))
            #expect(answer == .opened(entry: .serviceMessage("Comments are turned off."), firstPage: nil), "\(id)")
            #expect(await wire.posts.count == 1)
        }
    }
    @Test func noCommentsTabIsNotOfferedNeverNoCommentsAndTheNonsenseControlIsUnreadable() async throws {
        let routes = try Routes.load()
        var next = try Wire.json("next-\(Wire.video).json")
        let tabsPath = ["contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs"]
        var node: Any = next
        for key in tabsPath { node = (node as? [String: Any])?[key] as Any }
        let tabs = try #require(node as? [[String: Any]])
        let kept = tabs.filter { (($0["tabRenderer"] as? [String: Any])?["content"] as? [String: Any])?["sectionListRenderer"] == nil }
        #expect(kept.count == tabs.count - 1, "exactly the comments tab is removed")
        func replace(_ object: inout [String: Any], _ path: ArraySlice<String>, _ value: Any) {
            guard let key = path.first else { return }
            if path.count == 1 { object[key] = value; return }
            var child = object[key] as? [String: Any] ?? [:]
            replace(&child, path.dropFirst(), value); object[key] = child
        }
        replace(&next, tabsPath[...], kept)
        let edited = try JSONSerialization.data(withJSONObject: next)
        let wire = PublicWire(routes, override: { _, _ in Answer(data: edited) })
        #expect(try await publicClient(wire).comments(.open(videoID: Wire.video)) == .opened(entry: .notOffered, firstPage: nil))
        #expect(await wire.posts.count == 1, "no continuation is published, so no second request")
        // The nonsense id echoes itself and says "turned off": the identity rule makes that unreadable, and still one request.
        let nonsense = PublicWire(routes)
        await #expect(throws: MusicSessionError.unrecognised) { try await publicClient(nonsense).comments(.open(videoID: "Qx7Lm2Zk9Vw")) }
        #expect(await nonsense.posts.count == 1)
    }

    // MARK: Validation before anything is sent

    @Test func aBadIdOrTokenSendsNothingOnAnyPath() async throws {
        let routes = try Routes.load()
        let longToken = String(repeating: "A", count: 4_097)
        let bad: [MusicCommentsRequest] = [
            .open(videoID: ""), .open(videoID: "short"), .open(videoID: "twelve_chars"), .open(videoID: "bad id here"), .open(videoID: "../../etc/pw"),
            .page(token: "", videoID: Wire.video), .page(token: "has space", videoID: Wire.video), .page(token: "semi;colon", videoID: Wire.video),
            .page(token: longToken, videoID: Wire.video), .page(token: routes.pageToken, videoID: "nope"),
            .replies(token: routes.repliesToken, videoID: Wire.video, parentID: ""), .replies(token: routes.repliesToken, videoID: Wire.video, parentID: "has.dot"),
            .replies(token: routes.repliesToken, videoID: Wire.video, parentID: String(repeating: "a", count: 129)),
            .replies(token: "", videoID: Wire.video, parentID: Wire.firstThread),
        ]
        let publicWire = PublicWire(routes), signedWire = SignedWire(routes)
        let versions = Counter()
        let publicOnly = try publicClient(publicWire)
        let signed = signedClient(signedWire, anonymous: publicOnly, versions: versions)
        let signedSession = try session()
        for request in bad {
            await #expect(throws: ConnectionError.invalidInput) { try await publicOnly.comments(request) }
            await #expect(throws: MusicSessionError.policy) { try await signed.comments(request, session: nil) }
            await #expect(throws: MusicSessionError.policy) { try await signed.comments(request, session: signedSession) }
            #expect(throws: MusicSessionError.policy) { try request.validate() }
        }
        #expect(await publicWire.all.isEmpty, "not even the version bootstrap is sent")
        #expect(await signedWire.seen.isEmpty && versions.value == 0)
        // Boundaries that are valid: a 4096-character token, a 128-character thread id.
        let edge = String(repeating: "A", count: 4_096)
        try MusicCommentsRequest.page(token: edge, videoID: Wire.video).validate()
        try MusicCommentsRequest.replies(token: edge, videoID: Wire.video, parentID: String(repeating: "a", count: 128)).validate()
    }
    @Test func theRequestValidationAgreesWithTheAdapterParsers() {
        let samples = ["", "a", "abcdefghijk", "abcdefghij", "abcdefghijkl", "a b", "a;b", "a.b", "A-_%=+/.9", String(repeating: "A", count: 4_096), String(repeating: "A", count: 4_097),
                       "ünïcode", "tab\there", "new\nline"]
        for sample in samples {
            let tokenOK = (try? MusicCommentsRequest.page(token: sample, videoID: "abcdefghijk").validate()) != nil
            let videoOK = (try? MusicCommentsRequest.open(videoID: sample).validate()) != nil
            #expect(tokenOK == MusicBrowseParser.isToken(sample), "token \(sample.prefix(12))")
            #expect(videoOK == MusicBrowseParser.isVideoID(sample), "video \(sample.prefix(12))")
        }
    }
    @Test func aWrongVideoOrWrongThreadAnswerIsUnreadableNotAccepted() async throws {
        let routes = try Routes.load()
        // Page 2 prints the video it belongs to; another video's request cannot read it. (The Newest page prints none: the coordinator binds that case.)
        let page2 = PublicWire(routes)
        await #expect(throws: MusicSessionError.unrecognised) { try await publicClient(page2).comments(.page(token: routes.pageToken, videoID: "Qx7Lm2Zk9Vw")) }
        let thread = PublicWire(routes)
        await #expect(throws: MusicSessionError.unrecognised) {
            try await publicClient(thread).comments(.replies(token: routes.repliesToken, videoID: Wire.video, parentID: "UgzOtherThread0000000000"))
        }
        #expect(await page2.posts.count == 1)
        #expect(await thread.posts.count == 1)
    }

    // MARK: Caps, statuses, shells, signed-out

    @Test func theResponseCapIsTwoMillionBytesAndAnOversizedAnswerIsAnErrorNeverATruncatedParse() async throws {
        let routes = try Routes.load()
        let page2 = try Wire.data("comments-\(Wire.video)-page2.json")
        let first = try Wire.data("next-\(Wire.video).json")
        for (size, accepted) in [(2_000_000, true), (2_000_001, false)] {
            let body = Wire.padded(page2, to: size)
            let override: Override = { _, _ in Answer(data: body) }
            let request = MusicCommentsRequest.page(token: routes.pageToken, videoID: Wire.video)
            let direct = await attempt { try await publicClient(PublicWire(routes, override: override)).comments(request) }
            let signed = await attempt { try await signedClient(SignedWire(routes, override: override)).comments(request, session: try session()).value }
            let viaSigned = await attempt { try await signedClient(SignedWire(routes), anonymous: try publicClient(PublicWire(routes, override: override))).comments(request, session: nil).value }
            if accepted {
                #expect((try? direct.get()) != nil && (try? signed.get()) != nil && (try? viaSigned.get()) != nil, "exactly 2,000,000 bytes is accepted")
            } else {
                #expect(throws: ConnectionError.oversized) { try direct.get() }
                #expect(throws: MusicSessionError.oversized) { try signed.get() }
                #expect(throws: MusicSessionError.oversized) { try viaSigned.get() }
            }
        }
        // `open`: the watch-next answer keeps its own 4,000,000 cap, and an oversized first answer ends the read after ONE request.
        let oversizedFirst: Override = { _, what in if case .video = what { return Answer(data: Wire.padded(first, to: 4_000_001)) }; return nil }
        let wire = PublicWire(routes, override: oversizedFirst)
        await #expect(throws: ConnectionError.oversized) { try await publicClient(wire).comments(.open(videoID: Wire.video)) }
        #expect(await wire.posts.count == 1)
        let signedWire = SignedWire(routes, override: oversizedFirst)
        await #expect(throws: MusicSessionError.oversized) { try await signedClient(signedWire).comments(.open(videoID: Wire.video), session: try session()) }
        #expect(await signedWire.seen.count == 1)
        // The second answer of `open` is a comments response and keeps the 2,000,000 cap.
        let oversizedSecond: Override = { _, what in if case .continuation = what { return Answer(data: Wire.padded(page2, to: 2_000_001)) }; return nil }
        let secondWire = PublicWire(routes, override: oversizedSecond)
        await #expect(throws: ConnectionError.oversized) { try await publicClient(secondWire).comments(.open(videoID: Wire.video)) }
        #expect(await secondWire.posts.count == 2)
    }
    @Test func aShellAndHTTP400AreUnrecognisedAnd429IsRateLimitedOnBothPaths() async throws {
        let routes = try Routes.load()
        let shell = try Wire.data("comments-invalid-continuation.json")
        let requests: [MusicCommentsRequest] = [.open(videoID: Wire.video), .page(token: routes.pageToken, videoID: Wire.video),
                                                .replies(token: routes.repliesToken, videoID: Wire.video, parentID: Wire.firstThread)]
        for request in requests {
            // A watch shell where a comments answer belongs (the stale-token shape) is unreadable: it even prints "Comments are turned off.".
            let shellOverride: Override = { _, _ in Answer(data: shell) }
            await #expect(throws: MusicSessionError.unrecognised) {
                try await signedClient(SignedWire(routes), anonymous: try publicClient(PublicWire(routes, override: shellOverride))).comments(request, session: nil)
            }
            await #expect(throws: MusicSessionError.unrecognised) { try await signedClient(SignedWire(routes, override: shellOverride)).comments(request, session: try session()) }
            for (status, expected) in [(400, MusicSessionError.unrecognised), (404, .unrecognised), (429, .rateLimited), (500, .server), (503, .server)] {
                let override: Override = { _, _ in Answer(status: status, data: Data("{}".utf8)) }
                await #expect(throws: expected, "anonymous \(status)") {
                    try await signedClient(SignedWire(routes), anonymous: try publicClient(PublicWire(routes, override: override))).comments(request, session: nil)
                }
                await #expect(throws: expected, "signed \(status)") { try await signedClient(SignedWire(routes, override: override)).comments(request, session: try session()) }
            }
            await #expect(throws: ConnectionError.http(400)) {
                try await publicClient(PublicWire(routes, override: { _, _ in Answer(status: 400, data: Data("{}".utf8)) })).comments(request)
            }
        }
        // A 200 that is not JSON, or JSON of the wrong type, is unreadable too.
        let html: Override = { _, _ in Answer(data: Data("<html></html>".utf8), contentType: "text/html") }
        await #expect(throws: MusicSessionError.unrecognised) { try await signedClient(SignedWire(routes, override: html)).comments(.page(token: routes.pageToken, videoID: Wire.video), session: try session()) }
        let notJSON: Override = { _, _ in Answer(data: Data("[]".utf8)) }
        await #expect(throws: MusicSessionError.unrecognised) { try await signedClient(SignedWire(routes, override: notJSON)).comments(.page(token: routes.pageToken, videoID: Wire.video), session: try session()) }
        // An error only on the SECOND request of `open` is still an error: nothing partial is returned.
        let secondFails: Override = { index, _ in index == 1 ? Answer(status: 400, data: Data("{}".utf8)) : nil }
        await #expect(throws: MusicSessionError.unrecognised) { try await signedClient(SignedWire(routes, override: secondFails)).comments(.open(videoID: Wire.video), session: try session()) }
    }
    @Test func aLoggedOutRootIsSignedOutNeverAParsedPageOnEverySignedRequest() async throws {
        let routes = try Routes.load()
        let all: Override = { _, _ in Answer(data: Wire.loggedOut) }
        let requests: [MusicCommentsRequest] = [.open(videoID: Wire.video), .page(token: routes.pageToken, videoID: Wire.video),
                                                .replies(token: routes.repliesToken, videoID: Wire.video, parentID: Wire.firstThread)]
        for request in requests {
            await #expect(throws: MusicSessionError.signedOut) { try await signedClient(SignedWire(routes, override: all)).comments(request, session: try session()) }
        }
        // `open`: logged out on the SECOND answer only.
        let second: Override = { _, what in if case .continuation = what { return Answer(data: Wire.loggedOut) }; return nil }
        let wire = SignedWire(routes, override: second)
        await #expect(throws: MusicSessionError.signedOut) { try await signedClient(wire).comments(.open(videoID: Wire.video), session: try session()) }
        #expect(await wire.seen.count == 2)
        // The anonymous path has no signed-out state: a loggedOut root there is just an unreadable answer.
        await #expect(throws: MusicSessionError.unrecognised) {
            try await signedClient(SignedWire(routes), anonymous: try publicClient(PublicWire(routes, override: all))).comments(.page(token: routes.pageToken, videoID: Wire.video), session: nil)
        }
        // A signed session that ended without the marker: 401 and 403 are signed out as well.
        for status in [401, 403] {
            let ended: Override = { _, _ in Answer(status: status, data: Data("{}".utf8)) }
            await #expect(throws: MusicSessionError.signedOut) { try await signedClient(SignedWire(routes, override: ended)).comments(.open(videoID: Wire.video), session: try session()) }
        }
    }

    // MARK: Conformers that predate comments

    @Test func aReaderThatDoesNotImplementCommentsThrowsPolicyAndSendsNothing() async throws {
        let reader = MinimalReader()
        await #expect(throws: MusicSessionError.policy) { try await reader.comments(.open(videoID: Wire.video), session: nil) }
        await #expect(throws: MusicSessionError.policy) { try await reader.comments(.page(token: "tok", videoID: Wire.video), session: try session()) }
    }
}
/// Implements only what has no default: every other requirement, comments included, comes from the protocol extension.
private struct MinimalReader: MusicSessionReading {
    func accountMenu(session: MusicCookieSession) async throws -> MusicSignedResult<MusicAccountIdentity> { throw MusicSessionError.policy }
    func likedPlaylists(session: MusicCookieSession) async throws -> MusicSignedResult<MusicLibraryPlaylists> { throw MusicSessionError.policy }
    func avatar(_ url: URL) async throws -> Data { throw MusicSessionError.policy }
}
