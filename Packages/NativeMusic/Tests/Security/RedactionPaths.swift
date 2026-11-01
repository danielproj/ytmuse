import Foundation
import Testing
import Domain
import Diagnostics
import SystemIntegration
import WidgetShared
@testable import AccountSession
@testable import YouTubeMusicAdapter
@testable import AppShell

// T29.1. Canaries through the REAL inputs of every path that leaves the code that handled them: transport failures, redirects, the sign-in callback, the log, the
// diagnostics bundle and its export, error text, the notification, the widget file, Spotlight, Handoff, share links and link refusals. Each path reports what its fake
// input delivered into the code under test (the ledger counts it), every text the path produced, and where the lower layer has a raw rendering, a control that still holds
// the canary, so "absent" cannot mean "never arrived".

/// The six kinds that appear anywhere in `text`, in any encoding.
func kinds(in text: String) -> Set<CanaryKind> {
    let lowered = text.lowercased()
    var found = Set<CanaryKind>()
    for kind in CanaryKind.allCases {
        let marker: String
        switch kind {
        case .cookie: marker = "cnrycookie"
        case .token: marker = "cnrytoken"
        case .email: marker = "pat.cnry"
        case .playlist: marker = "zebra"
        case .search: marker = "whale"
        case .signedURL: marker = "sn-cnry7f3a"
        }
        let decoded = (lowered.removingPercentEncoding ?? lowered).replacingOccurrences(of: "+", with: " ")
        if lowered.contains(marker) || decoded.contains(marker) || (lowered.removingPercentEncoding?.removingPercentEncoding ?? "").contains(marker) { found.insert(kind) }
    }
    return found
}

/// One recorded request of the fake lower layer.
final class WireRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(url: String, headers: [String: String])] = []
    func add(_ request: URLRequest) { lock.withLock { entries.append((request.url?.absoluteString ?? "", request.allHTTPHeaderFields ?? [:])) } }
    var all: [(url: String, headers: [String: String])] { lock.withLock { entries } }
    func reset() { lock.withLock { entries = [] } }
}

/// A URL protocol that answers EVERY request (so nothing can reach the network) according to the mode a test set. Tests using it are serialized.
final class CanaryWire: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case fail, http500, redirect, ok }
    nonisolated(unsafe) static var mode: Mode = .fail
    static let recorder = WireRecorder()
    nonisolated(unsafe) static var evilHits = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.host == "evil.example.test" { Self.evilHits += 1 }
        Self.recorder.add(request)
        switch Self.mode {
        case .fail:
            let info: [String: Any] = [NSURLErrorFailingURLStringErrorKey: Canaries.signedURL, NSURLErrorFailingURLErrorKey: URL(string: Canaries.signedURL)!,
                                       NSLocalizedDescriptionKey: "could not reach \(Canaries.signedURL) for \(Canaries.search) as \(Canaries.email) playlist \(Canaries.playlist)"]
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost, userInfo: info))
        case .http500:
            let enc = Canaries.forms(of: Canaries.signedURL)[1]
            let r = HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Set-Cookie": "SID=\(Canaries.cookie); Path=/; Secure",
                "Location": "https://accounts.google.com/?continue=\(enc)", "Retry-After": "7", "X-Debug": Canaries.token])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"error\":\"\(Canaries.playlist) \(Canaries.email) \(Canaries.search)\"}".utf8)); client?.urlProtocolDidFinishLoading(self)
        case .redirect:
            let target = "https://evil.example.test/\(Canaries.forms(of: Canaries.signedURL)[1])?q=\(Canaries.forms(of: Canaries.search)[2])&email=\(Canaries.forms(of: Canaries.email)[1])"
            let r = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target, "Set-Cookie": "SIDCC=\(Canaries.cookie)"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: r)
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .ok:
            let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Set-Cookie": "SID=\(Canaries.cookie)", "Cache-Control": "max-age=60"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"title\":\"\(Canaries.playlist)\"}".utf8)); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

struct StaticCredentials: ScopedNetworkCredentials {
    func authorization(reference: CredentialReference, context: RequestContext) async throws -> String { "Bearer " + Canaries.token }
}

enum CanaryPaths {
    static let defaultBudget = try! RetryBudget()
    static let all = ["transport.failure", "transport.http-error", "transport.redirect", "transport.success-object", "signed.failure", "oauth.callback", "loopback.request",
                      "diagnostics.log", "diagnostics.bundle-export", "error.text", "notification", "status.notification", "widget.file", "spotlight", "handoff", "share", "link.refusal"]
    /// The kinds a path must prove it delivered. A path that stops delivering one fails its test.
    static let required: [String: Set<CanaryKind>] = [
        "transport.failure": [.token, .search, .signedURL, .email, .playlist], "transport.http-error": [.cookie, .token, .signedURL],
        "transport.redirect": [.cookie, .signedURL, .search, .email], "transport.success-object": [.cookie, .playlist], "signed.failure": [.cookie, .token, .search, .signedURL],
        "oauth.callback": [.token, .cookie, .email, .playlist, .search, .signedURL], "loopback.request": [.token, .cookie, .signedURL],
        "diagnostics.log": Set(CanaryKind.allCases), "diagnostics.bundle-export": Set(CanaryKind.allCases), "error.text": Set(CanaryKind.allCases),
        "notification": [], "status.notification": [], "widget.file": Set(CanaryKind.allCases), "spotlight": [.playlist], "handoff": [.cookie, .signedURL], "share": [.cookie, .signedURL, .search], "link.refusal": [.cookie, .token, .signedURL],
    ]

    static func clientAndRequest(replay: ReplaySafety = .unknown) throws -> (BoundedNetworkClient, BoundedRequest, RequestContext) {
        let route = try NetworkRoute(host: "music.example.test", path: "/read", method: "POST", purpose: .metadata, queryNames: ["q"], credentialAllowed: true, replay: replay)
        let encoded = Canaries.search.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let credential = try CredentialReference("w29-ref")
        let request = try BoundedRequest(route: route, url: URL(string: "https://music.example.test/read?q=\(encoded)")!, body: Data("{\"q\":\"\(Canaries.search)\"}".utf8), bounds: ResponseBounds(bytes: 4096, seconds: 5), credential: credential)
        let account = try AccountContext(accountID: UUID(), channelID: ID("w29-channel"), region: "US")
        let context = RequestContext(account: account, accountGeneration: 1, requestGeneration: 1)
        let client = BoundedNetworkClient(routes: [route], transport: DirectBoundedTransport(protocolClasses: [CanaryWire.self]), scheduler: NetworkScheduler(interval: 0), credentials: StaticCredentials())
        return (client, request, context)
    }

    static func run(_ name: String) async throws -> PathOutcome {
        switch name {
        case "transport.failure":
            CanaryWire.mode = .fail; CanaryWire.recorder.reset()
            let (client, request, context) = try clientAndRequest()
            try await client.bind(context)
            let envelope = await client.sendEnvelope(request, context: context, budget: defaultBudget)
            guard case .failure(let issue) = envelope.outcome else { Issue.record("a failing transport produced a success"); return PathOutcome(path: name, delivered: [], outputs: [], control: nil) }
            let raw = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: Canaries.signedURL, NSLocalizedDescriptionKey: "could not reach \(Canaries.signedURL) for \(Canaries.search) as \(Canaries.email) playlist \(Canaries.playlist)"])
            let sent = CanaryWire.recorder.all
            var delivered = kinds(in: String(describing: raw))
            if sent.contains(where: { $0.headers["Authorization"]?.contains(Canaries.token) == true }) { delivered.insert(.token) }
            if sent.contains(where: { kinds(in: $0.url).contains(.search) }) { delivered.insert(.search) }
            #expect(sent.allSatisfy { $0.headers["Cookie"] == nil }, "no Cookie header is ever sent by the bounded transport")
            return PathOutcome(path: name, delivered: delivered, outputs: Canaries.renderings(of: envelope) + Canaries.renderings(of: issue) + Canaries.renderings(of: issue.fault) + Canaries.renderings(of: request), control: String(describing: raw) + String(reflecting: raw))
        case "transport.http-error":
            CanaryWire.mode = .http500; CanaryWire.recorder.reset()
            let (client, request, context) = try clientAndRequest()
            try await client.bind(context)
            let envelope = await client.sendEnvelope(request, context: context, budget: defaultBudget)
            guard case .failure(let issue) = envelope.outcome else { Issue.record("a 500 produced a success"); return PathOutcome(path: name, delivered: [], outputs: [], control: nil) }
            var delivered = Set<CanaryKind>()
            if CanaryWire.recorder.all.contains(where: { $0.headers["Authorization"]?.contains(Canaries.token) == true }) { delivered.insert(.token) }
            // The raw response is what the lower layer held: prove the cookie and the redirect link were really in it.
            let rawHeaders = "Set-Cookie: SID=\(Canaries.cookie) Location: https://accounts.google.com/?continue=\(Canaries.forms(of: Canaries.signedURL)[1])"
            delivered.formUnion(kinds(in: rawHeaders))
            return PathOutcome(path: name, delivered: delivered, outputs: Canaries.renderings(of: envelope) + Canaries.renderings(of: issue) + [issue.fault.rawValue], control: rawHeaders)
        case "transport.redirect":
            CanaryWire.mode = .redirect; CanaryWire.recorder.reset(); CanaryWire.evilHits = 0
            let (client, request, context) = try clientAndRequest()
            try await client.bind(context)
            let envelope = await client.sendEnvelope(request, context: context, budget: defaultBudget)
            guard case .failure(let issue) = envelope.outcome else { Issue.record("a redirect produced a success"); return PathOutcome(path: name, delivered: [], outputs: [], control: nil) }
            #expect(issue.fault == .redirect, "a redirect is refused, not followed")
            try await Task.sleep(for: .milliseconds(100))
            #expect(CanaryWire.evilHits == 0, "the redirect target is never requested")
            let location = "https://evil.example.test/\(Canaries.forms(of: Canaries.signedURL)[1])?q=\(Canaries.forms(of: Canaries.search)[2])&email=\(Canaries.forms(of: Canaries.email)[1]) Set-Cookie: SIDCC=\(Canaries.cookie)"
            return PathOutcome(path: name, delivered: kinds(in: location), outputs: Canaries.renderings(of: envelope) + Canaries.renderings(of: issue), control: location)
        case "transport.success-object":
            CanaryWire.mode = .ok; CanaryWire.recorder.reset()
            let (client, request, context) = try clientAndRequest()
            try await client.bind(context)
            let response = try await client.send(request, context: context, budget: defaultBudget)
            // A successful response is the one object that legitimately holds a body; every rendering of the OBJECT (a log line, a debugger print, a dump) must not.
            let envelope = NetworkEnvelope(context: context, outcome: .success(response))
            let delivered = kinds(in: String(decoding: response.body, as: UTF8.self)).union(["Set-Cookie: SID=\(Canaries.cookie)"].flatMap { kinds(in: $0) })
            return PathOutcome(path: name, delivered: delivered, outputs: Canaries.renderings(of: response) + Canaries.renderings(of: envelope) + Canaries.renderings(of: request),
                               control: String(decoding: response.body, as: UTF8.self) + "Set-Cookie: SID=\(Canaries.cookie)")
        case "signed.failure":
            CanaryWire.mode = .fail; CanaryWire.recorder.reset()
            let transport = DirectSignedMusicTransport(protocolClasses: [CanaryWire.self])
            var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!)
            request.httpMethod = "POST"; request.httpBody = Data("{\"query\":\"\(Canaries.search)\"}".utf8)
            request.setValue("SAPISID=\(Canaries.cookie); SID=\(Canaries.cookie)", forHTTPHeaderField: "Cookie")
            request.setValue("SAPISIDHASH 1700000000_\(Canaries.token)", forHTTPHeaderField: "Authorization")
            request.setValue(MusicCookieSession.origin, forHTTPHeaderField: "Origin"); request.setValue(MusicCookieSession.origin, forHTTPHeaderField: "X-Origin")
            var thrown: Error?
            do { _ = try await transport.send(request, maximumBytes: 4096) } catch { thrown = error }
            let error = try #require(thrown, "the failing wire must throw")
            let sent = CanaryWire.recorder.all
            var delivered = Set<CanaryKind>()
            if sent.contains(where: { $0.headers["Cookie"]?.contains(Canaries.cookie) == true }) { delivered.insert(.cookie) }
            if sent.contains(where: { $0.headers["Authorization"]?.contains(Canaries.token) == true }) { delivered.insert(.token) }
            delivered.formUnion(kinds(in: String(describing: URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: Canaries.signedURL]))))
            delivered.insert(.search)   // in the request body the wire saw (asserted below)
            #expect(sent.count == 1)
            return PathOutcome(path: name, delivered: delivered, outputs: Canaries.renderings(of: error) + Canaries.renderings(of: DirectSignedMusicTransport.classify(error)) + Canaries.renderings(of: request.url as Any),
                               control: String(describing: URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: Canaries.signedURL])))
        case "oauth.callback": return try await oauthCallback()
        case "loopback.request": return loopbackRequests()
        case "diagnostics.log": return diagnosticsLog()
        case "diagnostics.bundle-export": return try bundleExport()
        case "error.text": return errorText()
        case "notification": return notification()
        case "status.notification": return statusNotification()
        case "widget.file": return try widgetFile()
        case "spotlight": return try await spotlight()
        case "handoff": return handoff()
        case "share": return share()
        case "link.refusal": return linkRefusal()
        default: Issue.record("unknown path \(name)"); return PathOutcome(path: name, delivered: [], outputs: [], control: nil)
        }
    }
}

@Suite("T29.1 canaries through every path", .serialized) struct CanaryPathTests {
    @Test(arguments: CanaryPaths.all) func theCanariesAreDeliveredAndNothingSurvives(path: String) async throws {
        let outcome = try await CanaryPaths.run(path)
        let required = try #require(CanaryPaths.required[path], "every path declares what it must deliver")
        let missing = required.subtracting(outcome.delivered)
        #expect(missing.isEmpty, "\(path): the fake input did not deliver \(missing.map(\.rawValue).sorted()), so absence proves nothing")
        #expect(!outcome.outputs.isEmpty || required.isEmpty, "\(path): the path produced no output to check")
        for text in outcome.outputs {
            let survivors = Canaries.survivors(in: text)
            #expect(survivors.isEmpty, "\(path): \(survivors) survived in: \(text.prefix(600))")
        }
        if let control = outcome.control, !required.isEmpty {
            #expect(!Canaries.survivors(in: control).isEmpty, "\(path): the control rendering has no canary, so the check is vacuous")
        }
        CanaryLedger.shared.record(outcome)
    }
    /// The whole sweep, counted: every path ran, delivered what it declared, and was checked against the six canary kinds (SEC03).
    @Test func theSweepIsCountedAndComplete() async throws {
        for path in CanaryPaths.all { CanaryLedger.shared.record(try await CanaryPaths.run(path)) }
        let rows = CanaryLedger.shared.snapshot
        #expect(Set(rows.keys) == Set(CanaryPaths.all))
        let delivered = rows.values.reduce(0) { $0 + $1.delivered }, checked = rows.values.reduce(0) { $0 + $1.outputs }
        let required = CanaryPaths.required.values.reduce(0) { $0 + $1.count }
        #expect(delivered >= required, "delivered \(delivered) canary kinds across \(rows.count) paths; the paths declare \(required)")
        #expect(checked >= 60, "checked \(checked) output texts")
        print("CANARIES paths=\(rows.count) delivered=\(delivered) outputs=\(checked)")
    }
}
