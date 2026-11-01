import Foundation
import Testing
import CryptoKit
@testable import YouTubeMusicAdapter
import AccountSession
import StreamResolver

private actor StubTransport: PublicHTTPTransport {
    var response: PublicHTTPResponse
    var requests: [URLRequest] = []
    init(_ response: PublicHTTPResponse) { self.response = response }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse { requests.append(request); return response }
}
private actor Listener: OAuthLoopbackListener {
    let url: URL
    var closed = 0
    init(_ url: String = "http://127.0.0.1:49152/oauth2callback") { self.url = URL(string: url)! }
    func bind() -> URL { url }
    func close() { closed += 1 }
}
private actor Browser: OAuthBrowser {
    var url: URL?
    func open(_ url: URL) { self.url = url }
}
private actor Exchange: OAuthProfileExchange {
    var calls = 0
    func exchange(_ request: OAuthCodeExchange, expectedNonce: String, scopes: Set<String>) throws -> ValidatedGoogleProfile {
        calls += 1
        #expect(request.verifier.count == 43)
        #expect(expectedNonce.count == 43)
        #expect(request.redirect.absoluteString == "http://127.0.0.1:49152/oauth2callback")
        return try .init(subject: "synthetic-unit-subject")
    }
}
private actor CaptureTransport: PublicHTTPTransport {
    let direct = DirectPublicTransport()
    var captures: [Data] = []
    var fixtures: [Data] = []
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse {
        let response = try await direct.send(request, maximumBytes: maximumBytes)
        var receipt: [String: Any] = ["path": request.url!.path, "status": response.status, "bytes": response.data.count,
          "bodySHA256": SHA256.hash(data: response.data).map { String(format: "%02x", $0) }.joined()]
        if request.url!.path == "/" {
            let html = String(decoding: response.data, as: UTF8.self)
            receipt["hasWebRemix"] = html.contains("WEB_REMIX")
            let r = try NSRegularExpression(pattern: #""INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"\\]+)""#)
            if let m = r.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(m.range(at: 1), in: html) { receipt["publicClientVersion"] = String(html[range]) }
        }
        if let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
            receipt["rootKeys"] = root.keys.sorted()
            func sanitizedTree(_ node: Any) -> Any? {
                if let map = node as? [String: Any] {
                    if let r = map["musicResponsiveListItemRenderer"] as? [String: Any] {
                        guard let columns = r["flexColumns"] as? [[String: Any]],
                              let first = columns.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                              let text = first["text"] as? [String: Any], let runs = text["runs"] as? [[String: Any]],
                              let title = runs.first?["text"] as? String,
                              let pid = r["playlistItemData"] as? [String: Any], let id = pid["videoId"] as? String else { return nil }
                        return ["musicResponsiveListItemRenderer": ["flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": title]]]]]], "playlistItemData": ["videoId": id]]]
                    }
                    var result: [String: Any] = [:]
                    for (key, value) in map { if let child = sanitizedTree(value) { result[key] = child } }
                    return result.isEmpty ? nil : result
                } else if let list = node as? [Any] {
                    let result = list.compactMap(sanitizedTree)
                    return result.isEmpty ? nil : result
                }
                return nil
            }
            if request.url!.path.hasSuffix("search") {
                // Preserve original renderer ancestor keys/arrays; prune all values
                // except public video IDs/titles. No tracking or continuation tokens.
                fixtures.append(try JSONSerialization.data(withJSONObject: ["contents": sanitizedTree(root["contents"] ?? [:]) ?? [:]], options: [.sortedKeys, .prettyPrinted]))
            } else if let play = root["playabilityStatus"] as? [String: Any] {
                var fixture: [String: Any] = ["playabilityStatus": ["status": play["status"] ?? "unknown"]]
                if let reason = play["reason"] as? String { receipt["publicDenialReason"] = reason }
                if let details = root["videoDetails"] as? [String: Any] {
                    fixture["videoDetails"] = ["videoId": details["videoId"] ?? "", "title": details["title"] ?? ""]
                }
                fixtures.append(try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .prettyPrinted]))
            }
        }
        captures.append(try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]))
        return response
    }
}
private actor DelayedSearch: PublicHTTPTransport {
    var waiting: CheckedContinuation<PublicHTTPResponse, any Error>?
    let response: PublicHTTPResponse
    init(response: PublicHTTPResponse) { self.response = response }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse {
        if request.url!.path == "/" { return .init(data: Data(#"{"INNERTUBE_CLIENT_VERSION":"1.2","clientName":"WEB_REMIX"}"#.utf8), status: 200) }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func ready() -> Bool { waiting != nil }
    func release() { waiting?.resume(returning: response); waiting = nil }
}
private actor TokenTransport: OAuthTokenTransport {
    var request: URLRequest?
    var data: Data
    init(_ json: String) { data = Data(json.utf8) }
    func post(_ request: URLRequest) -> Data { self.request = request; return data }
}
private actor TokenVerifier: GoogleIDTokenVerifier {
    var calls = 0
    func verify(_ token: String, audience: String, nonce: String) throws -> ValidatedGoogleProfile {
        calls += 1
        guard nonce == "unit-nonce", audience == "unit-only.apps.googleusercontent.com", token == "synthetic.signed.input" else { throw DesktopOAuthError.invalidGrant }
        return try .init(subject: "verified-unit-subject")
    }
}
private actor DelayedExchange: OAuthProfileExchange {
    var waiting: CheckedContinuation<ValidatedGoogleProfile, any Error>?
    func exchange(_ request: OAuthCodeExchange, expectedNonce: String, scopes: Set<String>) async throws -> ValidatedGoogleProfile {
        try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func ready() -> Bool { waiting != nil }
    func release() throws { waiting?.resume(returning: try .init(subject: "unit-stale")); waiting = nil }
}
@Suite struct ConnectionTests {
    @Test func configurationRejectsMissingAndWrongPlatform() throws {
        #expect(throws: ConnectionError.shape) { try PublicMusicConfiguration(homepage: Data("{}".utf8)) }
        #expect(throws: ConnectionError.shape) { try PublicMusicConfiguration(homepage: Data(#"{"INNERTUBE_CLIENT_VERSION":"1.2","clientName":"ANDROID"}"#.utf8)) }
        let config = try PublicMusicConfiguration(homepage: Data(#"{"INNERTUBE_CLIENT_VERSION":"1.2","clientName":"WEB_REMIX"}"#.utf8))
        #expect(config.clientVersion == "1.2")
        let canary = try PublicMusicConfiguration(homepage: Data(#"{"INNERTUBE_CLIENT_VERSION":"1.20261025.12.00-canary_experiment_1.20261020.10.00","clientName":"WEB_REMIX"}"#.utf8))
        #expect(canary.clientVersion.contains("canary_experiment"))
    }
    @Test func errorsNeverBecomeEmptyCatalog() throws {
        for json in [#"{"error":{"code":403}}"#, #"{"contents":{}}"#, #"{}"#, #"{"contents":{"musicResponsiveListItemRenderer":{}}}"#] {
            #expect(throws: (any Error).self) { try PublicMusicClient.parseSearch(.init(data: Data(json.utf8), status: 200)) }
        }
        #expect(throws: ConnectionError.http(403)) { try PublicMusicClient.parseSearch(.init(data: Data(), status: 403)) }
    }
    @Test func parserPositiveControl() throws {
        let data = Data(#"{"contents":{"musicResponsiveListItemRenderer":{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Synthetic parser case"}]}}}],"playlistItemData":{"videoId":"abcdefghijk"}}}}"#.utf8)
        let result = try PublicMusicClient.parseSearch(.init(data: data, status: 200))
        #expect(result.count == 1); #expect(result[0].title == "Synthetic parser case")
    }
    @Test func invalidQueryAndUnbootstrappedFailBeforeNetwork() async throws {
        let transport = StubTransport(.init(data: Data(), status: 200)); let client = try PublicMusicClient(transport: transport)
        await #expect(throws: ConnectionError.invalidInput) { try await client.search(" ") }
        await #expect(throws: ConnectionError.expired) { try await client.search("public") }
        #expect(await transport.requests.isEmpty)
    }
    @Test func originPolicy() async throws {
        let transport = DirectPublicTransport()
        for url in ["http://music.youtube.com/", "https://example.com/", "https://music.youtube.com:8443/"] {
            await #expect(throws: ConnectionError.origin) { try await transport.send(URLRequest(url: URL(string: url)!), maximumBytes: 100) }
        }
    }
    @Test func oauthMissingConfigurationDoesNotOpenBrowser() async throws {
        let b = Browser(); let f = DesktopOAuthFlow(configuration: nil, listener: Listener(), browser: b, exchange: Exchange())
        await #expect(throws: DesktopOAuthError.configurationMissing) { try await f.start(generation: 1) }
        #expect(await b.url == nil)
    }
    @Test func oauthPKCEStateReplayAndGeneration() async throws {
        let b = Browser(); let e = Exchange(); let f = DesktopOAuthFlow(configuration: try .init(clientID: "unit-only.apps.googleusercontent.com"), listener: Listener(), browser: b, exchange: e)
        try await f.start(generation: 7)
        let auth = URLComponents(url: try #require(await b.url), resolvingAgainstBaseURL: false)!
        let params = Dictionary(uniqueKeysWithValues: auth.queryItems!.map { ($0.name, $0.value!) })
        #expect(params["code_challenge_method"] == "S256"); #expect(params["code_challenge"]?.count == 43)
        #expect(params["state"] != params["nonce"])
        func callback(_ state: String, host: String = "127.0.0.1:49152") -> OAuthCallback {
            .init(method: "GET", url: URL(string: "http://127.0.0.1:49152/oauth2callback?state=\(state)&code=synthetic")!, host: host)
        }
        await #expect(throws: DesktopOAuthError.invalidCallback) { try await f.receive(callback("wrong"), generation: 7) }
        await #expect(throws: DesktopOAuthError.invalidCallback) { try await f.receive(callback(params["state"]!, host: "attacker.invalid"), generation: 7) }
        let profile = try await f.receive(callback(params["state"]!), generation: 7)
        #expect(profile.subject == "synthetic-unit-subject"); #expect(await e.calls == 1)
        await #expect(throws: DesktopOAuthError.invalidCallback) { try await f.receive(callback(params["state"]!), generation: 7) }
        try await f.start(generation: 8)
        await #expect(throws: DesktopOAuthError.stale) { try await f.receive(callback("x"), generation: 9) }
    }
    @Test func oauthCancellationExpiryAndOrigin() async throws {
        let clock = TestConnectionClock()
        let b = Browser(); let f = DesktopOAuthFlow(configuration: try .init(clientID: "unit-only.apps.googleusercontent.com"), listener: Listener(), browser: b, exchange: Exchange(), clock: clock)
        try await f.start(generation: 0)
        while clock.waitingCount() == 0 { await Task.yield() }
        clock.advance(to: 181, wake: false)
        let callback = OAuthCallback(method: "POST", url: URL(string: "http://127.0.0.1:49152/oauth2callback")!, host: "127.0.0.1:49152")
        await #expect(throws: DesktopOAuthError.expired) { try await f.receive(callback, generation: 0) }
        try await f.start(generation: 0); await f.cancel()
        await #expect(throws: DesktopOAuthError.invalidCallback) { try await f.receive(callback, generation: 0) }
        let bad = DesktopOAuthFlow(configuration: try .init(clientID: "unit-only.apps.googleusercontent.com"), listener: Listener("http://0.0.0.0:49152/oauth2callback"), browser: b, exchange: Exchange())
        await #expect(throws: DesktopOAuthError.invalidConfiguration) { try await bad.start(generation: 0) }
    }
    @Test func mediaNeverInfersGrantFromURL() throws {
        let o = try MusicPlayerObservation(data: Data(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"formats":[{"url":"https://invalid.example"}]}}"#.utf8))
        #expect(o.boundary == .sourceGrantAndEventsMissing)
        let c = try MusicPlayerObservation(data: Data(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"formats":[{"signatureCipher":"redacted"}]}}"#.utf8))
        #expect(c.boundary == .challengeRequired)
        let d = try MusicPlayerObservation(data: Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED"}}"#.utf8))
        #expect(d.boundary == .serviceDenied)
    }
    @Test func oauthAdverseCallbacksAndDenial() async throws {
        let b = Browser(); let e = Exchange()
        let f = DesktopOAuthFlow(configuration: try .init(clientID: "unit-only.apps.googleusercontent.com"), listener: Listener(), browser: b, exchange: e)
        try await f.start(generation: 1)
        let state = URLComponents(url: try #require(await b.url), resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        for suffix in ["&state=duplicate", "#fragment"] {
            let cb = OAuthCallback(method: "GET", url: URL(string: "http://127.0.0.1:49152/oauth2callback?state=\(state)&code=unit\(suffix)")!, host: "127.0.0.1:49152")
            await #expect(throws: DesktopOAuthError.invalidCallback) { try await f.receive(cb, generation: 1) }
        }
        let denial = OAuthCallback(method: "GET", url: URL(string: "http://127.0.0.1:49152/oauth2callback?state=\(state)&error=access_denied")!, host: "127.0.0.1:49152")
        await #expect(throws: DesktopOAuthError.denied) { try await f.receive(denial, generation: 1) }
        #expect(await e.calls == 0)
        await #expect(throws: DesktopOAuthError.invalidCallback) { try await f.receive(denial, generation: 1) }
    }
    @Test func oauthCancellationDuringExchangeDiscardsProfile() async throws {
        let b = Browser(); let e = DelayedExchange()
        let f = DesktopOAuthFlow(configuration: try .init(clientID: "unit-only.apps.googleusercontent.com"), listener: Listener(), browser: b, exchange: e)
        try await f.start(generation: 1)
        let state = URLComponents(url: try #require(await b.url), resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        let cb = OAuthCallback(method: "GET", url: URL(string: "http://127.0.0.1:49152/oauth2callback?state=\(state)&code=unit")!, host: "127.0.0.1:49152")
        let pending = Task { try await f.receive(cb, generation: 1) }
        while !(await e.ready()) { await Task.yield() }
        await f.cancel(); try await e.release()
        await #expect(throws: DesktopOAuthError.stale) { try await pending.value }
    }
    @Test func capturedRealSuccessAndDenial() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let base = root.appendingPathComponent("artifacts/harness/nodes/E01")
        let search = try Data(contentsOf: base.appendingPathComponent("capture-0.json"))
        let items = try PublicMusicClient.parseSearch(.init(data: search, status: 200))
        #expect(items.count > 0)
        #expect(items.contains { $0.videoID == "q_kw904K2bw" })
        let player = try Data(contentsOf: base.appendingPathComponent("capture-1.json"))
        let detail = try PublicMusicClient.parseDetail(.init(data: player, status: 200), videoID: "q_kw904K2bw", generation: 2)
        #expect(detail.status == "UNPLAYABLE"); #expect(detail.title != nil)
        #expect(try MusicPlayerObservation(data: player).boundary == .serviceDenied)
        #expect(throws: ConnectionError.shape) { try PublicMusicClient.parseDetail(.init(data: player, status: 200), videoID: "abcdefghijk", generation: 2) }
    }
    @Test func delayedSearchRejectsInvalidatedGeneration() async throws {
        let data = Data(#"{"contents":{"musicResponsiveListItemRenderer":{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Synthetic"}]}}}],"playlistItemData":{"videoId":"abcdefghijk"}}}}"#.utf8)
        let transport = DelayedSearch(response: .init(data: data, status: 200))
        let client = try PublicMusicClient(transport: transport); _ = try await client.bootstrap()
        let pending = Task { try await client.search("synthetic") }
        while !(await transport.ready()) { await Task.yield() }
        await client.invalidate(); await transport.release()
        await #expect(throws: ConnectionError.stale) { try await pending.value }
    }
    @Test func tokenExchangeRequiresScopesAndVerifierAndEncodesForms() async throws {
        let transport = TokenTransport(#"{"access_token":"synthetic-access","token_type":"Bearer","expires_in":3600,"scope":"openid https://www.googleapis.com/auth/userinfo.profile","id_token":"synthetic.signed.input"}"#)
        let verifier = TokenVerifier()
        let exchange = DesktopOAuthTokenExchange(transport: transport, verifier: verifier)
        let request = OAuthCodeExchange(clientID: "unit-only.apps.googleusercontent.com", redirect: URL(string: "http://127.0.0.1:49152/oauth2callback")!, code: "synthetic+&=", verifier: "unit-verifier")
        let profile = try await exchange.exchange(request, expectedNonce: "unit-nonce", scopes: ["openid", "profile"])
        #expect(profile.subject == "verified-unit-subject"); #expect(await verifier.calls == 1)
        let body = String(decoding: try #require(await transport.request?.httpBody), as: UTF8.self)
        #expect(body.contains("code=synthetic%2B%26%3D")); #expect(!body.contains("client_secret"))
        await #expect(throws: DesktopOAuthError.invalidGrant) { try await exchange.exchange(request, expectedNonce: "unit-nonce", scopes: ["youtube"]) }
        #expect(await verifier.calls == 1)
        let refresh = try DesktopOAuthTokenExchange.refreshRequest(clientID: "unit", refreshToken: "synthetic+token")
        #expect(refresh.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(try DesktopOAuthTokenExchange.revokeRequest(token: "synthetic").url?.path == "/revoke")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["E01_OBSERVATION_ROOT"] != nil)) func liveAnonymousObservation() async throws {
        guard let path = ProcessInfo.processInfo.environment["E01_OBSERVATION_ROOT"] else { return }
        let transport = CaptureTransport(); let client = try PublicMusicClient(transport: transport)
        var receipt: [String: Any] = ["classification": "anonymous-public; no account/media/ads grant", "observedAt": ISO8601DateFormatter().string(from: Date()), "client": "WEB_REMIX", "configuration": "site-published; not OAuth registration"]
        var stage = "bootstrap"
        do {
            _ = try await client.bootstrap()
            stage = "search"
            let result = try await client.search("Beethoven Symphony 5", limit: 5)
            receipt["search"] = ["query": result.query, "hl": result.hl, "gl": result.gl ?? "server-default", "requestID": result.requestID.uuidString, "ownerGeneration": result.generation, "outcome": "typed Music results", "count": result.items.count, "capped": result.capped, "coverageComplete": result.coverageComplete, "items": result.items.map { ["videoID": $0.videoID, "title": $0.title] }]
            if let item = result.items.first {
                stage = "detail"
                let detail = try await client.detail(videoID: item.videoID)
                receipt["detail"] = ["hl": detail.hl, "gl": detail.gl ?? "server-default", "requestID": detail.requestID.uuidString, "ownerGeneration": detail.generation, "requestedVideoID": detail.requestedVideoID, "status": detail.status, "titleAvailable": detail.title != nil]

            }
        } catch { receipt["failureCategory"] = observationErrorCategory(error); receipt["failureStage"] = stage }
        receipt["requests"] = try await transport.captures.map { try JSONSerialization.jsonObject(with: $0) }
        _ = try await saveObservation(root: URL(fileURLWithPath: path, isDirectory: true), receipt: receipt, projections: transport.fixtures)
        #expect(receipt["failureCategory"] == nil, "Public observation failed; sanitized receipt retained")
    }
}
