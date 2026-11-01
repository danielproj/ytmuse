import Foundation
import Testing
@testable import YouTubeMusicAdapter
@testable import AccountSession

final class TestConnectionClock: ConnectionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>)] = [:]
    let autoAdvance: Bool
    init(autoAdvance: Bool = false) { self.autoAdvance = autoAdvance }
    func now() -> TimeInterval { lock.withLock { time } }
    func waitingCount() -> Int { lock.withLock { sleepers.count } }
    func advance(to value: TimeInterval, wake: Bool = true) {
        let ready = lock.withLock {
            precondition(value >= time); time = value
            let ready = wake ? sleepers.filter { $0.value.0 <= time } : [:]
            for key in ready.keys { sleepers.removeValue(forKey: key) }
            return ready.values.map(\.1)
        }
        for continuation in ready { continuation.resume() }
    }
    func sleep(until deadline: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                if autoAdvance { time = max(time, deadline) }
                if time >= deadline { lock.unlock(); continuation.resume(); return }
                sleepers[id] = (deadline, continuation); lock.unlock()
            }
        } onCancel: {
            let pending = self.lock.withLock { self.sleepers.removeValue(forKey: id)?.1 }
            pending?.resume(throwing: CancellationError())
        }
    }
}
private actor GatedBind: OAuthLoopbackListener {
    var gate: CheckedContinuation<Void, Never>?
    var isOpen = false
    var closeCount = 0
    func bind() async -> URL {
        await withCheckedContinuation { gate = $0 }
        isOpen = true
        return URL(string: "http://127.0.0.1:49152/oauth2callback")!
    }
    func ready() -> Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
    func close() { isOpen = false; closeCount += 1 }
}
private actor ImmediateListener: OAuthLoopbackListener {
    var isOpen = false
    var closes = 0
    func bind() -> URL { isOpen = true; return URL(string: "http://127.0.0.1:49152/oauth2callback")! }
    func close() { isOpen = false; closes += 1 }
}
private actor ProbeBrowser: OAuthBrowser {
    var urls: [URL] = []
    func open(_ url: URL) { urls.append(url) }
}
private actor ProbeExchange: OAuthProfileExchange {
    func exchange(_ request: OAuthCodeExchange, expectedNonce: String, scopes: Set<String>) throws -> ValidatedGoogleProfile { try .init(subject: "synthetic") }
}
private func row(_ id: String) -> [String: Any] {
    ["musicResponsiveListItemRenderer": ["flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": id]]]]]], "playlistItemData": ["videoId": id]]]
}
private func rows(_ ids: [String]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["contents": ["items": ids.map(row)]])
}
private actor OperationTransport: PublicHTTPTransport {
    var waiting: [String: CheckedContinuation<PublicHTTPResponse, any Error>] = [:]
    var requests: [URLRequest] = []
    var delaySearch = false
    func delaySearches() { delaySearch = true }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse {
        requests.append(request)
        if request.url!.path == "/" { return .init(data: Data(#"{"INNERTUBE_CLIENT_VERSION":"1.2","clientName":"WEB_REMIX"}"#.utf8), status: 200) }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        if let id = body["videoId"] as? String { return try await withCheckedThrowingContinuation { waiting[id] = $0 } }
        if delaySearch, body["query"] as? String == "older" { return try await withCheckedThrowingContinuation { waiting["older"] = $0 } }
        return .init(data: try rows(["abcdefghijk"]), status: 200)
    }
    func ready(_ key: String) -> Bool { waiting[key] != nil }
    func release(_ key: String) throws {
        let data = key == "older" ? try rows(["abcdefghijk"]) : Data("{\"playabilityStatus\":{\"status\":\"UNPLAYABLE\"},\"videoDetails\":{\"videoId\":\"\(key)\",\"title\":\"Synthetic\"}}".utf8)
        waiting.removeValue(forKey: key)?.resume(returning: .init(data: data, status: 200))
    }
}
@Suite struct ConnectionReworkTests {
    @Test func cancelledBindMustCloseAfterLateCompletionAndBlockReplacement() async throws {
        let listener = GatedBind(); let browser = ProbeBrowser()
        let flow = DesktopOAuthFlow(configuration: try .init(clientID: "unit-only.apps.googleusercontent.com"), listener: listener, browser: browser, exchange: ProbeExchange())
        let start = Task { try await flow.start(generation: 1) }
        while !(await listener.ready()) { await Task.yield() }
        await flow.cancel()
        await #expect(throws: DesktopOAuthError.busy) { try await flow.start(generation: 2) }
        await listener.release()
        await #expect(throws: DesktopOAuthError.stale) { try await start.value }
        #expect(await listener.isOpen == false)
        #expect(await listener.closeCount == 2)
        #expect(await browser.urls.isEmpty)
    }
    @Test func unansweredAttemptAutomaticallyExpiresAndCanRestart() async throws {
        let clock = TestConnectionClock(); let listener = ImmediateListener(); let browser = ProbeBrowser()
        let flow = DesktopOAuthFlow(configuration: try .init(clientID: "unit-only.apps.googleusercontent.com"), listener: listener, browser: browser, exchange: ProbeExchange(), clock: clock)
        try await flow.start(generation: 1)
        #expect(await listener.isOpen)
        clock.advance(to: 181)
        for _ in 0..<10000 { if !(await listener.isOpen) { break }; await Task.yield() }
        #expect(await listener.isOpen == false)
        try await flow.start(generation: 2)
        #expect(await browser.urls.count == 2)
        await flow.cancel()
    }
    @Test func configTTLUsesOnlyInjectedMonotonicTime() async throws {
        let clock = TestConnectionClock(); let transport = OperationTransport()
        let client = try PublicMusicClient(transport: transport, clock: clock)
        _ = try await client.bootstrap()
        clock.advance(to: 1799); _ = try await client.search("still valid")
        clock.advance(to: 1800)
        await #expect(throws: ConnectionError.expired) { try await client.search("expired") }
    }
    @Test func searchAndDetailHaveIndependentTokensAndBoundContext() async throws {
        let transport = OperationTransport()
        let client = try PublicMusicClient(transport: transport, hl: "de", gl: "DE")
        _ = try await client.bootstrap()
        let detail = Task { try await client.detail(videoID: "abcdefghijk") }
        while !(await transport.ready("abcdefghijk")) { await Task.yield() }
        let result = try await client.search("Größe")
        #expect(result.query == "Größe"); #expect(result.hl == "de"); #expect(result.gl == "DE")
        try await transport.release("abcdefghijk")
        let value = try await detail.value
        #expect(value.hl == "de"); #expect(value.gl == "DE"); #expect(value.requestID != result.requestID)
        #expect(value.generation == result.generation)
        let requests = await transport.requests
        for request in requests.dropFirst() {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let context = body["context"] as! [String: Any]; let config = context["client"] as! [String: String]
            #expect(config["hl"] == "de"); #expect(config["gl"] == "DE")
        }
    }
    @Test func newerSearchSupersedesOlderButOwnerInvalidationRejectsDetail() async throws {
        let transport = OperationTransport(); await transport.delaySearches()
        let client = try PublicMusicClient(transport: transport); _ = try await client.bootstrap()
        let old = Task { try await client.search("older") }
        while !(await transport.ready("older")) { await Task.yield() }
        _ = try await client.search("newer"); try await transport.release("older")
        await #expect(throws: ConnectionError.stale) { try await old.value }
        let detail = Task { try await client.detail(videoID: "abcdefghijk") }
        while !(await transport.ready("abcdefghijk")) { await Task.yield() }
        await client.invalidate(); try await transport.release("abcdefghijk")
        await #expect(throws: ConnectionError.stale) { try await detail.value }
    }
    @Test func arraysPreserveRankAndSiblingRendererObjectsFailClosed() throws {
        let ids = ["abcdefghijk", "bcdefghijkl", "cdefghijklm"]
        #expect(try PublicMusicClient.parseSearch(.init(data: rows(ids), status: 200)).map(\.videoID) == ids)
        let ambiguous = try JSONSerialization.data(withJSONObject: ["contents": ["one": row(ids[0]), "two": row(ids[1])]])
        #expect(throws: ConnectionError.shape) { try PublicMusicClient.parseSearch(.init(data: ambiguous, status: 200)) }
    }
    @Test func documentedIdentityAliasesOnly() {
        #expect(GoogleIdentityScopes.normalized(["openid", "https://www.googleapis.com/auth/userinfo.profile", "https://www.googleapis.com/auth/userinfo.email"]) == ["openid", "profile", "email"])
        #expect(GoogleIdentityScopes.normalized(["https://www.googleapis.com/auth/youtube"]) != ["https://www.googleapis.com/auth/youtube.readonly"])
        #expect(GoogleIdentityScopes.normalized(["https://evil.example/userinfo.profile"]) != ["profile"])
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func value() -> Int { lock.withLock { count } }
}
private struct CountedBytes: AsyncSequence, Sendable {
    typealias Element = UInt8
    let count: Int
    let counter: ReadCounter
    struct AsyncIterator: AsyncIteratorProtocol {
        var remaining: Int
        let counter: ReadCounter
        mutating func next() async throws -> UInt8? {
            guard remaining > 0 else { return nil }
            remaining -= 1; counter.increment(); return 7
        }
    }
    func makeAsyncIterator() -> AsyncIterator { .init(remaining: count, counter: counter) }
}
private actor IOProbe {
    var times: [TimeInterval] = []
    func receive(at time: TimeInterval) -> PublicHTTPResponse { times.append(time); return .init(data: Data([1]), status: 200) }
}
@Suite struct ConnectionTransportTests {
    @Test func allowlistRejectsEveryUnapprovedInputBeforeIO() async throws {
        let clock = TestConnectionClock(autoAdvance: true); let io = IOProbe()
        let transport = DirectPublicTransport(clock: clock) { _, _ in await io.receive(at: clock.now()) }
        var invalid: [(URLRequest, Int)] = []
        for url in ["http://music.youtube.com/", "https://example.com/", "https://music.youtube.com:443/", "https://music.youtube.com/?x=1", "https://music.youtube.com/#f", "https://a:b@music.youtube.com/", "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false", "https://music.youtube.com/youtubei/v1/search?prettyPrint=true", "https://music.youtube.com/youtubei/v1/search?prettyPrint=false&extra=1"] {
            invalid.append((URLRequest(url: URL(string: url)!), 10))
        }
        for method in ["POST", "PUT", "HEAD", "DELETE"] {
            var request = URLRequest(url: URL(string: "https://music.youtube.com/")!); request.httpMethod = method
            invalid.append((request, 10))
        }
        var search = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!); search.httpMethod = "GET"
        invalid.append((search, 10)); search.httpMethod = "POST"
        for (header, value) in [("authorization", "Bearer unit-only"), ("cookie", "synthetic=1"), ("Host", "other.example")] {
            var request = search; request.setValue(value, forHTTPHeaderField: header); invalid.append((request, 10))
        }
        for limit in [-1, 0, 4_000_001] { invalid.append((search, limit)) }
        var huge = search; huge.httpBody = Data(repeating: 1, count: 32_769); invalid.append((huge, 10))
        for (request, limit) in invalid {
            await #expect(throws: ConnectionError.origin) { try await transport.send(request, maximumBytes: limit) }
        }
        #expect(await io.times.isEmpty)
        // Positive controls prove the I/O seam is reached for all three allowed forms.
        for path in ["/", "/youtubei/v1/search?prettyPrint=false", "/youtubei/v1/player?prettyPrint=false"] {
            var request = URLRequest(url: URL(string: "https://music.youtube.com\(path)")!)
            if path != "/" { request.httpMethod = "POST" }
            _ = try await transport.send(request, maximumBytes: 10)
        }
        #expect(await io.times.count == 3)
    }
    @Test func streamingCapStopsReadsAndHonorsAdvertisedSize() async throws {
        let counter = ReadCounter()
        await #expect(throws: ConnectionError.oversized) {
            try await DirectPublicTransport.collect(CountedBytes(count: 100, counter: counter), expectedLength: -1, limit: 3)
        }
        #expect(counter.value() == 4) // Detect overflow on the next byte, never consume the rest.
        let advertised = ReadCounter()
        await #expect(throws: ConnectionError.oversized) {
            try await DirectPublicTransport.collect(CountedBytes(count: 100, counter: advertised), expectedLength: 100, limit: 3)
        }
        #expect(advertised.value() == 0)
        let exact = try await DirectPublicTransport.collect(CountedBytes(count: 3, counter: ReadCounter()), expectedLength: -1, limit: 3)
        #expect(exact == Data([7, 7, 7]))
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await DirectPublicTransport.collect(CountedBytes(count: 100, counter: ReadCounter()), expectedLength: -1, limit: 3)
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
    @Test func actualRedirectDelegateDeniesRedirectAndPacerReservesOneSecond() async throws {
        let session = URLSession(configuration: .ephemeral)
        let request = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.com/"])!
        let redirect = await NoRedirect().urlSession(session, task: session.dataTask(with: request), willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://example.com/")!))
        #expect(redirect == nil)
        session.invalidateAndCancel()
        let clock = TestConnectionClock(autoAdvance: true); let io = IOProbe()
        let transport = DirectPublicTransport(clock: clock) { _, _ in await io.receive(at: clock.now()) }
        for _ in 0..<3 { _ = try await transport.send(request, maximumBytes: 10) }
        #expect(await io.times == [0, 1, 2])
    }
}

@Suite struct ConnectionObservationTests {
    @Test func categoriesDistinguishNetworkTimeoutCancelAndShape() {
        #expect(observationErrorCategory(URLError(.cannotConnectToHost)) == "network")
        #expect(observationErrorCategory(URLError(.timedOut)) == "timeout")
        #expect(observationErrorCategory(URLError(.cancelled)) == "cancelled")
        #expect(observationErrorCategory(CancellationError()) == "cancelled")
        #expect(observationErrorCategory(ConnectionError.shape) == "shape")
        #expect(observationErrorCategory(NSError(domain: NSCocoaErrorDomain, code: 3840)) == "shape")
        #expect(observationErrorCategory(ConnectionError.http(503)) == "http")
        #expect(observationErrorCategory(NSError(domain: "synthetic-unexpected", code: 1)) == "unexpected")
    }
    @Test func observationWritesAreSeparateAndProjectionHashesMatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pinned = root.appendingPathComponent("capture-0.json")
        try Data("pinned".utf8).write(to: pinned)
        let projection = Data("{\"contents\":{}}".utf8)
        let first = try saveObservation(root: root, receipt: ["failureCategory": "shape"], projections: [projection])
        let firstReceipt = try Data(contentsOf: first.appendingPathComponent("receipt.json"))
        let second = try saveObservation(root: root, receipt: ["failureCategory": "timeout"], projections: [])
        #expect(first != second)
        #expect(try Data(contentsOf: first.appendingPathComponent("receipt.json")) == firstReceipt)
        #expect(try Data(contentsOf: pinned) == Data("pinned".utf8))
        let decoded = try JSONSerialization.jsonObject(with: firstReceipt) as! [String: Any]
        let projections = decoded["projections"] as! [[String: Any]]
        #expect(projections[0]["sha256"] as? String == sha256(projection))
        #expect(projections[0]["bytes"] as? Int == projection.count)
        #expect(throws: (any Error).self) { try Data("overwrite".utf8).write(to: first.appendingPathComponent("receipt.json"), options: [.withoutOverwriting]) }
    }
}

private struct ScopeGrantTransport: OAuthTokenTransport {
    let granted: String
    func post(_ request: URLRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["access_token": "synthetic", "token_type": "Bearer", "expires_in": 3600, "scope": granted, "id_token": "synthetic.signed"])
    }
}
private actor RequiredVerifier: GoogleIDTokenVerifier {
    var calls = 0
    func verify(_ token: String, audience: String, nonce: String) throws -> ValidatedGoogleProfile {
        calls += 1
        guard nonce == "expected-nonce", audience == "unit-only.apps.googleusercontent.com", token == "synthetic.signed" else { throw DesktopOAuthError.invalidGrant }
        return try .init(subject: "synthetic-verified")
    }
}
private actor DeadlineExchange: OAuthProfileExchange {
    var waiting: CheckedContinuation<ValidatedGoogleProfile, any Error>?
    func ready() -> Bool { waiting != nil }
    func exchange(_ request: OAuthCodeExchange, expectedNonce: String, scopes: Set<String>) async throws -> ValidatedGoogleProfile {
        try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func release() throws { waiting?.resume(returning: try .init(subject: "synthetic")); waiting = nil }
}
@Suite struct ConnectionScopeDeadlineTests {
    @Test func URLFormGrantStillRequiresOpenIDReadonlyNonceAndVerification() async throws {
        let readonly = "https://www.googleapis.com/auth/youtube.readonly"
        let urlProfile = "https://www.googleapis.com/auth/userinfo.profile"
        let required: Set<String> = ["openid", "profile", readonly]
        let config = try DesktopOAuthConfiguration(clientID: "unit-only.apps.googleusercontent.com", scopes: ["openid", urlProfile, readonly])
        #expect(config.scopes.contains(urlProfile))
        let request = OAuthCodeExchange(clientID: config.clientID, redirect: URL(string: "http://127.0.0.1:49152/oauth2callback")!, code: "synthetic", verifier: "synthetic")
        let verifier = RequiredVerifier()
        for grant in ["openid \(urlProfile)", "\(urlProfile) \(readonly)", "openid \(urlProfile) https://www.googleapis.com/auth/youtube", "openid https://evil.example/userinfo.profile \(readonly)"] {
            let exchange = DesktopOAuthTokenExchange(transport: ScopeGrantTransport(granted: grant), verifier: verifier)
            await #expect(throws: DesktopOAuthError.invalidGrant) { try await exchange.exchange(request, expectedNonce: "expected-nonce", scopes: required) }
        }
        #expect(await verifier.calls == 0)
        let exchange = DesktopOAuthTokenExchange(transport: ScopeGrantTransport(granted: "openid \(urlProfile) \(readonly)"), verifier: verifier)
        let profile = try await exchange.exchange(request, expectedNonce: "expected-nonce", scopes: required)
        #expect(profile.subject == "synthetic-verified"); #expect(await verifier.calls == 1)
        await #expect(throws: DesktopOAuthError.invalidGrant) { try await exchange.exchange(request, expectedNonce: "wrong-nonce", scopes: required) }
        #expect(await verifier.calls == 2)
    }
    @Test func exchangeCompletionUsesTheSameMonotonicDeadline() async throws {
        let clock = TestConnectionClock(); let listener = ImmediateListener(); let browser = ProbeBrowser(); let exchange = DeadlineExchange()
        let flow = DesktopOAuthFlow(configuration: try .init(clientID: "unit-only.apps.googleusercontent.com"), listener: listener, browser: browser, exchange: exchange, clock: clock)
        try await flow.start(generation: 1)
        let auth = try #require(await browser.urls.first)
        let state = URLComponents(url: auth, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        let callback = OAuthCallback(method: "GET", url: URL(string: "http://127.0.0.1:49152/oauth2callback?state=\(state)&code=synthetic")!, host: "127.0.0.1:49152")
        let result = Task { try await flow.receive(callback, generation: 1) }
        while !(await exchange.ready()) { await Task.yield() }
        while clock.waitingCount() == 0 { await Task.yield() }
        clock.advance(to: 181, wake: false); try await exchange.release()
        await #expect(throws: DesktopOAuthError.expired) { try await result.value }
        try await flow.start(generation: 2); await flow.cancel()
    }
}

@Suite struct ConnectionPacingCancellationTests {
    @Test func cancelledPacedRequestDoesNotReachIO() async throws {
        let clock = TestConnectionClock(); let io = IOProbe()
        let transport = DirectPublicTransport(clock: clock) { _, _ in await io.receive(at: clock.now()) }
        let request = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        _ = try await transport.send(request, maximumBytes: 10)
        let pending = Task { try await transport.send(request, maximumBytes: 10) }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await io.times == [0])
    }
}
