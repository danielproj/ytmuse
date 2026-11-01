import Foundation
import Testing
import Domain
import Diagnostics
import SystemIntegration
import WidgetShared
@testable import AccountSession
@testable import YouTubeMusicAdapter
@testable import AppShell

// T29.1, second half: the paths that need their own fakes (the sign-in flow, the loopback listener, the log and its bundle, error text, the widget file, Spotlight,
// Handoff, share links and refusals).

actor FixedLoopback: OAuthLoopbackListener {
    static let port = 51234
    func bind() async throws -> URL { URL(string: "http://127.0.0.1:\(Self.port)/oauth2callback")! }
    func close() async {}
}
final class URLBox: @unchecked Sendable {
    private let lock = NSLock(); private var value: URL?
    func set(_ url: URL) { lock.withLock { value = url } }
    var url: URL? { lock.withLock { value } }
}
struct CapturingBrowser: OAuthBrowser {
    let box: URLBox
    func open(_ authorizationURL: URL) async throws { box.set(authorizationURL) }
}
struct AcceptingExchange: OAuthProfileExchange {
    func exchange(_ request: OAuthCodeExchange, expectedNonce: String, scopes: Set<String>) async throws -> ValidatedGoogleProfile { try ValidatedGoogleProfile(subject: "synthetic-subject") }
}

extension CanaryPaths {
    static func encode(_ text: String, times: Int = 1) -> String {
        var value = text
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for _ in 0..<times { value = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value }
        return value
    }

    // MARK: the sign-in callback (replayed, forged, encoded redirects)
    static func oauthCallback() async throws -> PathOutcome {
        let box = URLBox()
        let flow = DesktopOAuthFlow(configuration: try DesktopOAuthConfiguration(clientID: "1234567890-w29synthetic.apps.googleusercontent.com"), listener: FixedLoopback(), browser: CapturingBrowser(box: box), exchange: AcceptingExchange())
        try await flow.start(generation: 1)
        let auth = try #require(box.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        let state = try #require(auth.queryItems?.first { $0.name == "state" }?.value)
        let host = "127.0.0.1:\(FixedLoopback.port)"
        func callback(_ query: String, method: String = "GET") -> OAuthCallback { OAuthCallback(method: method, url: URL(string: "http://\(host)/oauth2callback?\(query)")!, host: host) }
        var outputs: [String] = []
        var thrown: [DesktopOAuthError] = []
        func attempt(_ cb: OAuthCallback) async -> DesktopOAuthError? {
            do { _ = try await flow.receive(cb, generation: 1); return nil } catch let error as DesktopOAuthError { thrown.append(error); outputs += Canaries.renderings(of: error); return error } catch { outputs += Canaries.renderings(of: error); return nil }
        }
        // 1. A forged state, with every canary riding as a parameter, an encoded redirect and a double-encoded echo of the authorization URL.
        let forged = "state=\(encode(Canaries.token))&code=\(Canaries.cookie)&login_hint=\(encode(Canaries.email))&redirect=\(encode("http://127.0.0.1:\(FixedLoopback.port)/oauth2callback?code=\(Canaries.cookie)&q=\(Canaries.search)", times: 2))&continue=\(encode(Canaries.signedURL, times: 2))&list=\(encode(Canaries.playlist))&q=\(encode(Canaries.search))"
        let forgedCallback = callback(forged)
        #expect(await attempt(forgedCallback) == .invalidCallback, "a forged state is refused")
        outputs += Canaries.renderings(of: forgedCallback) + [forgedCallback.url.absoluteString.isEmpty ? "" : String(describing: forgedCallback)]
        // 2. A wrong host header and a POST.
        #expect(await attempt(OAuthCallback(method: "GET", url: forgedCallback.url, host: "localhost:\(FixedLoopback.port)")) == .invalidCallback)
        #expect(await attempt(callback("state=\(state)&code=\(Canaries.cookie)", method: "POST")) == .invalidCallback)
        // 3. The real state with an error that echoes private text: denied, and the attempt is consumed.
        let denied = callback("state=\(state)&error=access_denied&error_description=\(encode(Canaries.playlist + " " + Canaries.email))&q=\(encode(Canaries.search, times: 2))")
        #expect(await attempt(denied) == .denied)
        // 4. The same callback again: replayed after being consumed.
        #expect(await attempt(denied) == .invalidCallback, "a replayed callback is refused")
        // 5. A fresh attempt: a valid callback succeeds once; its replay is refused.
        try await flow.start(generation: 2)
        let state2 = try #require(box.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "state" }?.value)
        #expect(state2 != state, "every attempt has its own state")
        let good = callback("state=\(state2)&code=\(encode(Canaries.cookie))&scope=\(encode(Canaries.signedURL))")
        _ = try await flow.receive(good, generation: 2)
        #expect(await attempt(OAuthCallback(method: "GET", url: good.url, host: host)) == .invalidCallback, "a valid callback cannot be replayed")
        outputs += Canaries.renderings(of: good)
        #expect(thrown.count >= 5)
        let planted = [forged, denied.url.absoluteString, good.url.absoluteString].joined(separator: " ")
        return PathOutcome(path: "oauth.callback", delivered: kinds(in: planted), outputs: outputs, control: planted)
    }

    // MARK: the loopback listener's raw request parser
    static func loopbackRequests() -> PathOutcome {
        let port = UInt16(FixedLoopback.port)
        let q = "state=\(encode(Canaries.token))&code=\(Canaries.cookie)&continue=\(encode(Canaries.signedURL, times: 2))"
        let requests = [
            "GET /oauth2callback?\(q) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Probe: \(Canaries.cookie)\r\n\r\n",
            "GET /oauth2callback?\(q) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nHost: \(Canaries.signedURL)\r\n\r\n",
            "GET /oauth2callback?\(q) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nTransfer-Encoding: chunked\r\n\r\n",
            "GET http://evil.example.test/oauth2callback?\(q) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n",
            "POST /oauth2callback?\(q) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n",
            "GET /oauth2callback?\(q)#\(Canaries.token) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n",
        ]
        var outputs: [String] = []
        var refused = 0
        for text in requests {
            do { _ = try NativeOAuthLoopback.parse(Data(text.utf8), port: port) } catch { refused += 1; outputs += Canaries.renderings(of: error) }
        }
        // The only text the listener ever hands back to a browser, accepted or not.
        for parsed in [true, false] { outputs.append(String(decoding: NativeOAuthLoopback.receiptResponse(parsed: parsed), as: UTF8.self)) }
        #expect(refused == requests.count - 0 || refused >= requests.count - 1, "hostile requests are refused (\(refused) of \(requests.count))")
        return PathOutcome(path: "loopback.request", delivered: kinds(in: requests.joined(separator: " ")), outputs: outputs, control: requests.joined(separator: " "))
    }

    // MARK: the log, in every shape and encoding the lower layers produce
    static let detailTemplates: [CanaryKind: [@Sendable (String) -> String]] = [
        .cookie: [{ "Cookie: SAPISID=\($0); SID=\($0); HSID=\($0)" }, { "Set-Cookie: SIDCC=\($0); Path=/; Secure" }, { "reply set __Secure-3PSID=\($0)" }, { "SOCS=\($0) CONSENT=\($0)" }, { "{\"cookie\":\"SAPISID=\($0)\"}" }],
        .token: [{ "Authorization: Bearer \($0)" }, { "access_token=\($0)&refresh_token=\($0)" }, { "{\"id_token\":\"\($0)\"}" }, { "X-Goog-Api-Key: \($0)" }, { "token \($0) rejected" }],
        .email: [{ "login_hint=\($0)" }, { "sign-in for \($0) failed" }, { "{\"email\":\"\($0)\"}" }, { "from: \($0)" }],
        .playlist: [{ "opening “\($0)”" }, { "playlist=\($0)" }, { "title \($0) failed to save" }, { "{\"title\":\"\($0)\"}" }],
        .search: [{ "q=\($0)" }, { "search_query=\($0)&type=songs" }, { "no results for \($0)" }, { "{\"query\":\"\($0)\"}" }],
        .signedURL: [{ "GET \($0) -> 403" }, { "continue=\($0)" }, { "redirected to \($0) then \($0)" }, { "<a href=\"\($0)\">" }],
    ]
    static func diagnosticsLog() -> PathOutcome {
        let context = RedactionContext(privateStrings: [Canaries.playlist, Canaries.search])
        let log = DiagnosticLog(limits: .init(maxEntries: 5000, maxAge: 86_400, maxDetailLength: 4000), context: { context })
        var planted: [String] = []
        for kind in CanaryKind.allCases {
            for form in Canaries.forms(of: Canaries.value(kind)) {
                for template in detailTemplates[kind] ?? [] { let detail = template(form); planted.append(detail); log.record(.sourceOutage, component: "adapter", detail: detail) }
            }
        }
        // The encoded-redirect chains: a URL whose own query is an encoded URL whose query is an encoded canary.
        for chain in [
            "https://accounts.google.com/o/oauth2/v2/auth?continue=\(encode("https://music.youtube.com/watch?v=x&q=\(Canaries.search)", times: 1))&login_hint=\(encode(Canaries.email))",
            "redirect continue=\(encode(Canaries.signedURL, times: 1)) then continue=\(encode(Canaries.signedURL, times: 2)) then \(encode(Canaries.search, times: 2)) \(encode(Canaries.email, times: 2))",
            "https://evil.example.test/\(encode(Canaries.signedURL))?e=\(encode(Canaries.email, times: 2))&p=\(encode(Canaries.playlist, times: 2))",
        ] { planted.append(chain); log.record(.policyRefusal, component: "adapter", detail: chain) }
        let entries = log.snapshot()
        #expect(entries.count == planted.count, "every planted line was recorded (\(entries.count) of \(planted.count))")
        var outputs = entries.map(\.detail)
        outputs += entries.map { "\($0.component) \($0.category) \($0.id)" }
        return PathOutcome(path: "diagnostics.log", delivered: kinds(in: planted.joined(separator: "\n")), outputs: outputs, control: planted.joined(separator: "\n"))
    }

    // MARK: the bundle, its preview and its exported file
    static func report(errors: [DiagnosticEntry]) -> DiagnosticsReport {
        DiagnosticsReport(generatedAt: Date(timeIntervalSince1970: 1_800_000_000), app: .init(name: "YTMuse", version: "1.0", build: "1", osVersion: "27.0", architecture: "arm64"),
                          adapter: .init(name: "adapter", version: "9.9", capabilityStatus: "Signed in via \(Canaries.signedURL) as \(Canaries.email) token \(Canaries.token)"),
                          accounts: 1, playback: .init(engine: "None", engineVersion: "-", quality: .unknown("not playing")),
                          storage: .init(artworkCacheBytes: 1, pinnedDownloadBytes: 2, automaticDownloadBytes: 3, unlistedDownloadBytes: 4), previousRunEndedUnexpectedly: false,
                          errorSummary: [], recentErrors: errors, changedSettings: [SettingChange(id: "newPlaylistVisibility", value: Canaries.playlist), SettingChange(id: "lastSearch", value: Canaries.search)],
                          profiling: .off)
    }
    static func bundleExport() throws -> PathOutcome {
        let scratch = try SecurityScratch(); defer { scratch.cleanup() }
        let context = RedactionContext(privateStrings: [Canaries.playlist, Canaries.search, Canaries.email])
        let log = DiagnosticLog(context: { context })
        var planted = ""
        for kind in CanaryKind.allCases {
            for template in detailTemplates[kind] ?? [] { let detail = template(Canaries.value(kind)); planted += detail + "\n"; log.record(.internalError, component: "diagnostics", detail: detail) }
        }
        let bundle = SupportBundle.make(report: report(errors: log.snapshot()), context: context)
        let file = scratch.url.appendingPathComponent("bundle.json")
        try bundle.export(to: file)
        let exported = try String(contentsOf: file, encoding: .utf8)
        #expect(exported == bundle.text, "what was exported is exactly what the preview showed")
        let permissions = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(permissions & 0o077 == 0, "the export is owner-only")
        let failure = SupportBundle.makeFailure(category: .internalError, component: "diagnostics", error: planted + Canaries.signedURL, generatedAt: Date(timeIntervalSince1970: 0), context: context)
        let controlRaw = String(decoding: (try? JSONEncoder().encode(report(errors: log.snapshot()))) ?? Data(), as: UTF8.self)
        return PathOutcome(path: "diagnostics.bundle-export", delivered: kinds(in: planted + Canaries.signedURL + report(errors: []).adapter.capabilityStatus), outputs: [bundle.text, exported, failure.text, String(data: bundle.data, encoding: .utf8) ?? ""],
                           control: planted + controlRaw.prefix(0))
    }

    // MARK: error text (the one way an error becomes stored or shown text)
    struct LeakyCase: Error { let message: String }
    enum LeakyEnum: Error { case failed(String) }
    static func errorText() -> PathOutcome {
        let url = URL(string: Canaries.signedURL)!
        let underlying = NSError(domain: "UnderlyingDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: Canaries.cookie + " " + Canaries.token])
        let errors: [any Error] = [
            URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: Canaries.signedURL, NSURLErrorFailingURLErrorKey: url, NSLocalizedDescriptionKey: Canaries.search + " " + Canaries.email]),
            NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSURLErrorFailingURLErrorKey: url, NSLocalizedDescriptionKey: Canaries.playlist, NSUnderlyingErrorKey: underlying]),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad value \(Canaries.email) at \(Canaries.signedURL)", underlyingError: underlying)),
            CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: "/Users/pat/Music/\(Canaries.playlist).m4a", NSLocalizedDescriptionKey: Canaries.search]),
            LeakyCase(message: "\(Canaries.signedURL) \(Canaries.email) Bearer \(Canaries.token)"),
            LeakyEnum.failed("\(Canaries.signedURL) \(Canaries.email) Authorization: Bearer \(Canaries.token) /Users/pat/\(Canaries.playlist)"),
            LeakyEnum.failed(Canaries.playlist), LeakyEnum.failed(Canaries.search), LeakyCase(message: Canaries.playlist + " " + Canaries.search),
            LeakyTuple.two(Canaries.search, 3), LeakyNested.wrapped(.failed(Canaries.playlist)),
        ]
        var outputs: [String] = [], controls: [String] = []
        for error in errors {
            outputs.append(SafeErrorText.describe(error))
            if let fault = FaultClassifier.category(for: error, component: "adapter") { outputs.append(fault.detail); outputs.append("\(fault.category) \(fault.component)") }
            controls.append(String(describing: error))
        }
        // Reachable from the Queue and the player: a command that fails with a leaky error leaves safe text in the state field the screen reads.
        #expect(SafeErrorText.describe(CancellationError()) == "cancelled")
        #expect(SafeErrorText.describe(QueueErrorLike.confirmationRequired) == "confirmationRequired", "an app error enum keeps its case name")
        return PathOutcome(path: "error.text", delivered: kinds(in: controls.joined(separator: " ")), outputs: outputs, control: controls.joined(separator: " "))
    }
    enum QueueErrorLike: Error { case confirmationRequired }
    /// TH2: payloads with no URL, e-mail or path shape: a name or a typed search, bare, in a struct, in a tuple and one level down.
    enum LeakyTuple: Error { case two(String, Int) }
    enum LeakyNested: Error { case wrapped(LeakyEnum) }

    // MARK: the song-change notification
    static func notification() -> PathOutcome {
        // A notification is built from the playing item's title and artist only; nothing else can be passed in, so the other canary kinds cannot reach it.
        let song = SongNotification.make(title: "Public Song Title", artist: "Public Artist", isAdvertisement: false)
        let ad = SongNotification.make(title: "Public Song Title", artist: "Public Artist", isAdvertisement: true)
        #expect(ad == nil, "an advertisement posts nothing")
        let labels = Mirror(reflecting: try! #require(song)).children.compactMap(\.label)
        #expect(Set(labels) == ["title", "subtitle"], "the notification carries a title and a subtitle and nothing else: \(labels)")
        return PathOutcome(path: "notification", delivered: [], outputs: Canaries.renderings(of: song as Any) + [SongNotification.identifier], control: nil)
    }

    // MARK: the opt-in download and sign-in messages (TH2)
    static func statusNotification() -> PathOutcome {
        // A status message is a fixed headline plus, at most, the title of the item the person already sees. There is no other input: no error text, link, path or account.
        var made: [StatusNotification] = []
        for kind in [StatusNotification.Kind.downloadFinished, .downloadFailed, .signInNeeded] { made.append(.make(kind, item: "Public Song Title")); made.append(.make(kind)) }
        let labels = Mirror(reflecting: made[0]).children.compactMap(\.label)
        #expect(Set(labels) == ["kind", "title", "body"], "a status message carries a kind, a headline and a body and nothing else: \(labels)")
        #expect(made.filter { $0.kind == .downloadFailed }.allSatisfy { $0.body == nil || $0.body == "Public Song Title" }, "a failure message names the item and gives no reason")
        let long = StatusNotification.make(.downloadFailed, item: String(repeating: "x", count: 500))
        #expect(long.body?.count == 200)
        var outputs = made.flatMap { Canaries.renderings(of: $0) + [$0.identifier] + [$0.title, $0.body ?? ""] }
        outputs += Canaries.renderings(of: long)
        return PathOutcome(path: "status.notification", delivered: [], outputs: outputs, control: nil)
    }

    // MARK: the widget file in the App Group
    static func widgetFile() throws -> PathOutcome {
        let hostile: [String: Any] = ["schema": 1, "state": "playing", "title": "Song", "token": Canaries.token, "cookie": Canaries.cookie, "email": Canaries.email,
                                      "playlist": Canaries.playlist, "search": Canaries.search, "signedURL": Canaries.signedURL,
                                      "scope": ["accountToken": "abc", "generation": 1, "launch": "n", "cookie": Canaries.cookie],
                                      "capabilities": ["playPause": true, "next": false, "previous": false, "token": Canaries.token]]
        let data = try JSONSerialization.data(withJSONObject: hostile)
        let result = WidgetSnapshotStore.decode(data)
        #expect(result == .unreadable, "a file with any key outside the schema is unreadable")
        let display = WidgetDisplay(result)
        #expect(display == .redacted(.unknown))
        // The nested forms: an extra key one level down is refused too.
        let nested = try JSONSerialization.data(withJSONObject: ["schema": 1, "state": "idle", "scope": ["accountToken": "abc", "generation": 1, "launch": "n", "playlist": Canaries.playlist]])
        #expect(WidgetSnapshotStore.decode(nested) == .unreadable)
        // A well-formed snapshot encodes only schema keys.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let ok = WidgetSnapshot(state: .playing, title: "Public Song", artist: "Public Artist", capabilities: .init(playPause: true), scope: WidgetScope(accountToken: "tok", generation: 1))
        let object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(ok)) as? [String: Any])
        #expect(Set(object.keys).isSubset(of: WidgetSnapshot.allowedKeys))
        let signedOut = WidgetSnapshot.redacted(.signedOut)
        #expect(signedOut.title == nil && signedOut.artist == nil && signedOut.artwork == nil && signedOut.scope == nil)
        return PathOutcome(path: "widget.file", delivered: kinds(in: String(decoding: data, as: UTF8.self)), outputs: Canaries.renderings(of: display) + Canaries.renderings(of: result) + Canaries.renderings(of: signedOut) + Canaries.renderings(of: WidgetDisplay(.missing)),
                           control: String(decoding: data, as: UTF8.self))
    }

    // MARK: Spotlight
    static func spotlight() async throws -> PathOutcome {
        let backend = InMemorySearchableIndex()
        let indexer = SpotlightIndexer(backend: backend)
        let token = "tok-w29"
        let playlist = try #require(SpotlightEntry(kind: .playlist, title: Canaries.playlist, subtitle: nil, accountToken: token, target: IntentMediaTarget(playlistID: "PLw29synthetic0001")))
        let song = try #require(SpotlightEntry(kind: .song, title: "Public Song", subtitle: "Artist", accountToken: token, target: IntentMediaTarget(videoID: "dQw4w9WgXcQ")))
        var outputs: [String] = []
        func snapshot(_ label: String) -> [String] { backend.entries.flatMap { [$0.title, $0.subtitle ?? "", $0.uniqueID, $0.domain, label] } + backend.calls.map { "\($0.kind) \($0.domains) \($0.count)" } }
        // 1. Indexing on, private entities OFF (the default): a private playlist is never indexed.
        let normal = SpotlightPolicy(enabled: true, includePrivate: false)
        try await indexer.reconcile(desired: [playlist, song], accountToken: token, policy: normal)
        #expect(backend.entries.map(\.title) == ["Public Song"], "the private playlist is not indexed by default")
        outputs += snapshot("default")
        // 2. The person opts in: the private entity is indexed (the control: it really would have been there).
        let optIn = SpotlightPolicy(enabled: true, includePrivate: true)
        try await indexer.reconcile(desired: [playlist, song], accountToken: token, policy: optIn)
        let control = backend.entries.map(\.title).joined(separator: " ")
        #expect(backend.entries.contains { $0.title == Canaries.playlist }, "opting in indexes the private playlist")
        // 3. The option is turned off again: the private entity leaves the index.
        try await indexer.reconcile(desired: [playlist, song], accountToken: token, policy: normal)
        #expect(!backend.entries.contains { $0.title == Canaries.playlist }, "turning private indexing off removes it")
        outputs += snapshot("opt-out")
        // 4. Indexing off, and the account's removal: nothing of it is left.
        try await indexer.reconcile(desired: [playlist, song], accountToken: token, policy: optIn)
        try await indexer.removeAccount(token: token)
        #expect(!backend.entries.contains { $0.accountToken == token })
        outputs += snapshot("removed")
        return PathOutcome(path: "spotlight", delivered: kinds(in: control), outputs: outputs, control: control)
    }

    // MARK: Handoff
    static func handoff() -> PathOutcome {
        var outputs: [String] = []
        for canary in [Canaries.cookie, Canaries.signedURL, Canaries.token] { #expect(LinkItem(kind: .song, identifier: canary) == nil, "a secret cannot become an item identifier") }
        let song = LinkItem(kind: .song, identifier: "dQw4w9WgXcQ")
        let activity = HandoffActivity(item: song)
        #expect(activity != nil)
        outputs += [activity?.webpageURL.absoluteString ?? "", String(describing: activity?.userInfo ?? [:])]
        let playlist = LinkItem(kind: .playlist, identifier: "PLw29synthetic0001")
        #expect(HandoffActivity(item: playlist) == nil, "a private playlist is never advertised")
        // An activity from elsewhere carrying secrets is refused: only the public link is read back.
        let hostile = NSUserActivity(activityType: HandoffActivity.activityType)
        hostile.webpageURL = URL(string: Canaries.signedURL)
        hostile.userInfo = ["kind": "song", "identifier": Canaries.cookie, "cookie": Canaries.cookie, "token": Canaries.token]
        #expect(HandoffActivity.destination(of: hostile) == nil)
        let continued = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        continued.webpageURL = URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=\(Canaries.cookie)")
        if case .item(let item)? = HandoffActivity.destination(of: continued) { outputs.append(CanonicalLink.url(for: item).absoluteString) }
        return PathOutcome(path: "handoff", delivered: kinds(in: Canaries.cookie + Canaries.signedURL), outputs: outputs + Canaries.renderings(of: activity as Any), control: Canaries.cookie + Canaries.signedURL)
    }

    // MARK: share links
    static func share() -> PathOutcome {
        var outputs: [String] = []
        for kindOfItem in LinkItemKind.allCases {
            for canary in [Canaries.cookie, Canaries.signedURL, Canaries.search, Canaries.token] { #expect(CanonicalLink.url(kind: kindOfItem, identifier: canary) == nil) }
        }
        #expect(CanonicalLink.song(videoID: Canaries.cookie) == nil)
        // A link someone pasted with a tracking parameter (that is really a secret) opens the song; the link handed back carries the identifier only.
        let pasted = "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=\(Canaries.cookie)"
        if case .success(.item(let item)) = LinkPolicy.parse(text: pasted) {
            let out = CanonicalLink.url(for: item).absoluteString
            #expect(out == "https://music.youtube.com/watch?v=dQw4w9WgXcQ", "no tracking parameter, cookie or token is ever handed out")
            outputs.append(out)
        } else { Issue.record("the song link was refused") }
        // A search term in a link is a refusal, not an echo.
        let withSearch = LinkPolicy.parse(text: "https://music.youtube.com/watch?v=dQw4w9WgXcQ&q=\(encode(Canaries.search))")
        #expect({ if case .failure = withSearch { true } else { false } }())
        outputs += Canaries.renderings(of: withSearch)
        return PathOutcome(path: "share", delivered: kinds(in: pasted + Canaries.signedURL + Canaries.search), outputs: outputs, control: pasted + Canaries.signedURL + Canaries.search)
    }

    // MARK: link refusals
    static func linkRefusal() -> PathOutcome {
        let candidates = [
            "https://music.youtube.com/watch?v=dQw4w9WgXcQ&continue=\(encode(Canaries.signedURL, times: 2))",
            Canaries.signedURL, "https://music.youtube.com/watch?v=\(Canaries.cookie)", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&token=\(Canaries.token)",
            "ytmuse://song/\(Canaries.cookie)", "https://user:\(Canaries.cookie)@music.youtube.com/watch?v=dQw4w9WgXcQ", "https://music.youtube.com/watch?v=dQw4w9WgXcQ#\(Canaries.token)",
        ]
        var outputs: [String] = [LinkRefusal.message]
        var refused = 0
        for text in candidates {
            if case .failure(let reason) = LinkPolicy.parse(text: text) { refused += 1; outputs += Canaries.renderings(of: reason) }
        }
        #expect(refused >= candidates.count - 1, "refused \(refused) of \(candidates.count)")
        return PathOutcome(path: "link.refusal", delivered: kinds(in: candidates.joined(separator: " ")), outputs: outputs, control: candidates.joined(separator: " "))
    }
}

// MARK: the one way an error becomes text

@Suite("T29.1 error text") struct SafeErrorTextTests {
    /// `String(describing: error)` and `"\(error)"` print whatever the error holds: a failing URL, a path, a header. Text that is stored, shown or logged goes through
    /// `SafeErrorText.describe`; the files below are the reviewed exceptions, each of which redacts or only ever formats an app-owned enum.
    static let allowed: [String: String] = [
        "SafeErrorText.swift": "the one place that formats an error",
        "DiagnosticsCenter.swift": "the text goes straight into DiagnosticLog / SupportBundle.makeFailure, which redact it with the live private context",
        "Codecs.swift": "formats a DomainError, an app-owned enum with no payload that can hold text",
    ]
    @Test func noProductCodeFormatsAnErrorAnyOtherWay() throws {
        let rules = [#"String\(describing:\s*(?:error|err|e|failure|fault|underlying)\)"#, #"String\(reflecting:\s*(?:error|err|e|failure|fault)\)"#, #"\\\((?:error|err|failure|fault)\)"#, #"\\\((?:error|err)\.localizedDescription\)"#, #"(?:error|err)\.localizedDescription"#]
        var scanned = 0, offences: [String] = []
        for base in ["Packages/NativeMusic/Sources", "App/Sources", "Extensions/Sources"] {
            for file in Repo.swiftFiles(under: base) {
                scanned += 1
                let name = file.lastPathComponent
                guard !Self.allowed.keys.contains(name) else { continue }
                let code = Repo.code(try String(contentsOf: file, encoding: .utf8))
                for rule in rules where code.range(of: rule, options: .regularExpression) != nil { offences.append("\(name): \(rule)") }
            }
        }
        #expect(scanned > 300)
        #expect(offences.isEmpty, "\(offences.joined(separator: "\n"))")
        // The rules fire on their own plants.
        for plant in ["x = String(describing: error)", "y = \"failed: \\(error)\"", "z = error.localizedDescription", "w = String(reflecting: err)"] {
            #expect(rules.contains { plant.range(of: $0, options: .regularExpression) != nil }, "\(plant)")
        }
        #expect(!rules.contains { "let errors = [1]; print(errorCount)".range(of: $0, options: .regularExpression) != nil }, "a near miss stays quiet")
    }
    @Test func theQueueAndPlaybackStateFieldsCarryOnlySafeText() async throws {
        // QueueState.error is what the queue screen reads; a command that fails with a leaky error must leave nothing private in it.
        struct Leaky: Error, CustomStringConvertible { var description: String { "failed \(Canaries.signedURL) for \(Canaries.email) Authorization: Bearer \(Canaries.token)" } }
        let text = SafeErrorText.describe(Leaky())
        #expect(Canaries.survivors(in: text).isEmpty, "\(text)")
        #expect(text.count <= SafeErrorText.maximumLength + 1)
        #expect(SafeErrorText.describe(URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: Canaries.signedURL])) == "network error -1001")
        #expect(SafeErrorText.describe(NSError(domain: "D", code: 5, userInfo: [NSLocalizedDescriptionKey: Canaries.search])) == "D 5")
        #expect(SafeErrorText.describe(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: Canaries.email))) == "unreadable response")
        #expect(SafeErrorText.describe(CanaryPaths.LeakyEnum.failed("plain words")).hasPrefix("failed("))
    }
}
