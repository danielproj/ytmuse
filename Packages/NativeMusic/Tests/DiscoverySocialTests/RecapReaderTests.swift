import AccountSession
import CryptoKit
import Domain
import Features
import Foundation
import Testing
@testable import YouTubeMusicAdapter
#if DEBUG
@testable import AppShell
#endif

/// MORE-FEATURES RECAP slice. What these tests stand on, and what they do not:
///  * the anonymous files in Fixtures/MF-RECAP are real public responses;
///  * the signed file is a real signed-session response whose every string was replaced by a placeholder before export. A placeholder proves
///    STRUCTURE and that a parser carries a string through verbatim. It is not the service's wording, and says nothing about what the message
///    means (it could be a generic upstream fault);
///  * NO successful Recap payload exists in any fixture, because none has ever been captured. Nothing here tests parsing of one.

private enum RecapFixture {
    static func data(_ name: String) throws -> Data { try Data(contentsOf: fixturesRoot().appendingPathComponent("MF-RECAP/" + name)) }
    static func object(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
    }
    /// The signed capture's response, taken out of the recorder's export envelope (one record).
    static func signedCapture() throws -> [String: Any] {
        let export = try object("signed-known-handler-sanitized-export.json")
        let records = try #require(export["records"] as? [[String: Any]])
        #expect(records.count == 1)
        return try #require((records[0]["response"] as? [String: Any])?["value"] as? [String: Any])
    }
    static func sha256(_ name: String) throws -> String { SHA256.hash(data: try data(name)).map { String(format: "%02x", $0) }.joined() }

    static var messagePath: [Any] { ["contents", "singleColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer", "content", "messageRenderer"] }
    /// A copy of `root` with the value at `path` replaced (nil removes it). Path elements are keys or array indices.
    static func setting(_ root: [String: Any], _ path: [Any], to value: Any?) -> [String: Any] {
        func apply(_ node: Any, _ path: ArraySlice<Any>) -> Any {
            guard let head = path.first else { return node }
            if let key = head as? String, var object = node as? [String: Any] {
                if path.count == 1 { object[key] = value }
                else if let child = object[key] { object[key] = apply(child, path.dropFirst()) }
                return object
            }
            if let index = head as? Int, var list = node as? [Any], list.indices.contains(index) {
                if path.count == 1 { if let value { list[index] = value } else { list.remove(at: index) } }
                else { list[index] = apply(list[index], path.dropFirst()) }
                return list
            }
            return node
        }
        return apply(root, path[...]) as? [String: Any] ?? root
    }
    /// Service-tracking parameter values replaced by key (a missing key is added to the GFEEDBACK service).
    static func tracking(_ root: [String: Any], key: String, value: String?) -> [String: Any] {
        var copy = root
        var context = copy["responseContext"] as? [String: Any] ?? [:]
        var services = context["serviceTrackingParams"] as? [[String: Any]] ?? []
        for index in services.indices where services[index]["service"] as? String == "GFEEDBACK" {
            var params = (services[index]["params"] as? [[String: Any]] ?? []).filter { $0["key"] as? String != key }
            if let value { params.append(["key": key, "value": value]) }
            services[index]["params"] = params
        }
        context["serviceTrackingParams"] = services; copy["responseContext"] = context
        return copy
    }
    static func message(headline: String, runs: [String]? = nil) -> [String: Any] {
        let base = (try? signedCapture()) ?? [:]
        let list = (runs ?? [headline]).map { ["text": $0] as [String: Any] }
        return setting(base, messagePath + ["text"], to: ["runs": list])
    }
}

@Suite struct RecapParserTests {
    // MARK: the evidence itself (positive controls, so the absences below mean something)

    @Test func theFixturesAreTheBytesTheManifestNamesAndHaveTheShapeTheParserReads() throws {
        #expect(try RecapFixture.sha256("signed-known-handler-sanitized-export.json") == "c4d678f40273ef31c6a11e7d59c6273211becc77d3320145acd7427f6403c899",
                "the R1 export, byte for byte")
        #expect(try RecapFixture.sha256("anonymous-listening-review-no-contents.json") == "839d4e163b5fd5f14a2263c84eb3a4377b923bf5a08ec842146ecd49992e6b2c")
        let signed = try RecapFixture.signedCapture()
        #expect(MusicRecapParser.serviceParameters(signed, service: "GFEEDBACK")?["browse_id"] == MusicRecapRoute.browseID)
        #expect(MusicRecapParser.serviceParameters(signed, service: "GFEEDBACK")?["logged_in"] == "1")
        let message = try #require(NSDictionary(dictionary: signed).value(forKeyPath: "contents.singleColumnBrowseResultsRenderer.tabs") as? [[String: Any]])
        #expect(message.count == 1)
        let anonymous = try RecapFixture.object("anonymous-listening-review-no-contents.json")
        #expect(anonymous["contents"] == nil, "the real anonymous answer has no contents at all")
        #expect(MusicRecapParser.serviceParameters(anonymous, service: "GFEEDBACK")?["logged_in"] == "0")
        #expect(MusicRecapParser.serviceParameters(anonymous, service: "GFEEDBACK")?["browse_id"] == MusicRecapRoute.browseID)
    }

    // MARK: the signed capture

    @Test func theSignedCaptureIsAServiceMessageAndItsTextIsCarriedVerbatim() throws {
        let signed = try RecapFixture.signedCapture()
        let reading = try MusicRecapParser.parse(signed)
        // The expected text is read from the capture at run time, never typed into the test as the "source wording".
        let runs = try #require(NSDictionary(dictionary: signed).value(forKeyPath: "contents.singleColumnBrowseResultsRenderer.tabs") as? [[String: Any]])
        let tab = try #require(runs[0]["tabRenderer"] as? [String: Any])
        let renderer = try #require(((tab["content"] as? [String: Any])?["messageRenderer"]) as? [String: Any])
        let captured = try #require(((renderer["text"] as? [String: Any])?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined())
        #expect(reading == .serviceMessage(MusicRecapServiceMessage(headline: captured, detail: nil)))
        #expect(captured == "<s:20:t>", "a placeholder: this proves verbatim propagation of a string, not what the service said")
    }
    @Test func secondaryTextIsWithheldAndNoUnverifiedKeyIsInterpreted() throws {
        let real = try RecapFixture.signedCapture()
        let text = try #require(String(data: JSONSerialization.data(withJSONObject: real, options: [.sortedKeys]), encoding: .utf8))
        #expect(text.contains("\"<key:7>\"") && text.contains("\"<key:22>\""), "positive control: the capture really has the two redacted keys and the nested runs")
        guard case .serviceMessage(let captured) = try MusicRecapParser.parse(real) else { Issue.record("expected a service message"); return }
        #expect(captured.detail == nil, "nothing is read from under keys the capture does not name")
        // Spelling those keys the way other clients do must not make the parser read them either: names come from evidence, not from guesses.
        let guessed = text.replacingOccurrences(of: "\"<key:7>\"", with: "\"subtext\"").replacingOccurrences(of: "\"<key:22>\"", with: "\"messageSubtextRenderer\"")
        let renamed = try #require(JSONSerialization.jsonObject(with: Data(guessed.utf8)) as? [String: Any])
        #expect(((renamed["contents"] as? NSDictionary)?.description ?? "").contains("messageSubtextRenderer"), "positive control: the guessed names are present")
        guard case .serviceMessage(let other) = try MusicRecapParser.parse(renamed) else { Issue.record("expected a service message"); return }
        #expect(other == captured && other.detail == nil)
    }
    @Test func aRecognisedButMalformedRunFailsTheWholeMessageInsteadOfYieldingAPartialOne() throws {
        let base = try RecapFixture.signedCapture()
        let path = RecapFixture.messagePath + ["text", "runs"]
        _ = try MusicRecapParser.parse(RecapFixture.setting(base, path, to: [["text": "first"], ["text": "second"]]))   // control: well-formed runs read
        let malformed: [(String, [Any])] = [
            ("a run with no text", [["text": "first"], [String: Any]()]),
            ("a run whose text is a number", [["text": "first"], ["text": 7]]),
            ("a run whose text is null", [["text": "first"], ["text": NSNull()]]),
            ("a run that is not an object", [["text": "first"], "second"]),
            ("only malformed runs next to a readable one", [["bold": true], ["text": "kept?"]]),
        ]
        for (name, runs) in malformed {
            #expect(throws: MusicSessionError.unrecognised, "\(name)") { try MusicRecapParser.parse(RecapFixture.setting(base, path, to: runs)) }
        }
        #expect(throws: MusicSessionError.unrecognised, "runs that are not a list") { try MusicRecapParser.parse(RecapFixture.setting(base, path, to: "text")) }
    }

    // MARK: anonymous captures and controls

    @Test func theRealAnonymousNoContentsAnswerNeedsSignInAndIsNeverAMessageOrAnEmptyRecap() throws {
        let reading = try MusicRecapParser.parse(try RecapFixture.object("anonymous-listening-review-no-contents.json"))
        #expect(reading == .needsSignIn)
        if case .serviceMessage = reading { Issue.record("an anonymous answer is not a service message") }
    }
    @Test func theServicesErrorBodyForAnInventedHandlerIsUnreadable() throws {
        let control = try RecapFixture.object("anonymous-control-invalid-argument.json")
        #expect(control["error"] != nil, "positive control: it is an error body")
        #expect(throws: MusicSessionError.unrecognised) { try MusicRecapParser.parse(control) }
    }

    // MARK: fail loudly

    @Test func anAnswerThatDoesNotProveItIsTheRecapHandlerIsUnreadable() throws {
        let base = try RecapFixture.signedCapture()
        _ = try MusicRecapParser.parse(base)   // the control: the unmodified capture reads
        let other = RecapFixture.tracking(base, key: "browse_id", value: "FEmusic_home")
        let missingID = RecapFixture.tracking(base, key: "browse_id", value: nil)
        let missingContext = base.filter { $0.key != "responseContext" }
        for (name, variant) in [("another handler", other), ("no browse_id", missingID), ("no responseContext", missingContext)] {
            #expect(throws: MusicSessionError.unrecognised, "\(name)") { try MusicRecapParser.parse(variant) }
        }
        // The same key twice with different values cannot be trusted either.
        var twice = base
        var context = try #require(twice["responseContext"] as? [String: Any])
        var services = try #require(context["serviceTrackingParams"] as? [[String: Any]])
        var params = try #require(services[0]["params"] as? [[String: Any]])
        params.append(["key": "browse_id", "value": "FEmusic_home"]); services[0]["params"] = params; context["serviceTrackingParams"] = services; twice["responseContext"] = context
        #expect(throws: MusicSessionError.unrecognised) { try MusicRecapParser.parse(twice) }
    }
    @Test func loggedInMustBeStatedAsZeroOrOne() throws {
        let base = try RecapFixture.signedCapture()
        for value in [nil, "", "2", "true", "yes"] as [String?] {
            #expect(throws: MusicSessionError.unrecognised, "logged_in = \(value ?? "absent")") {
                try MusicRecapParser.parse(RecapFixture.tracking(base, key: "logged_in", value: value))
            }
        }
        #expect(try MusicRecapParser.parse(RecapFixture.tracking(base, key: "logged_in", value: "0")) == .needsSignIn)
    }
    @Test func anythingButTheRecognisedMessageEnvelopeIsUnreadableNeverEmptyOrComputed() throws {
        let base = try RecapFixture.signedCapture()
        _ = try MusicRecapParser.parse(base)   // the control: the unmodified capture reads
        let tabContent: [Any] = ["contents", "singleColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer", "content"]
        let tabs: [Any] = ["contents", "singleColumnBrowseResultsRenderer", "tabs"]
        let secondTab: [String: Any] = ["tabRenderer": ["content": ["messageRenderer": ["text": ["runs": [["text": "x"]]]]]]]
        var twoTabs = base
        if let list = (NSDictionary(dictionary: base).value(forKeyPath: "contents.singleColumnBrowseResultsRenderer.tabs") as? [Any]) {
            twoTabs = RecapFixture.setting(base, tabs, to: list + [secondTab])
        }
        let variants: [(String, [String: Any])] = [
            ("no contents with logged_in 1", base.filter { $0.key != "contents" }),
            ("contents with another container", RecapFixture.setting(base, ["contents", "twoColumnBrowseResultsRenderer"], to: [String: Any]())),
            ("a section list instead of a message", RecapFixture.setting(base, tabContent, to: ["sectionListRenderer": ["contents": [[String: Any]]()]])),
            ("a message and another renderer", RecapFixture.setting(base, tabContent + ["sectionListRenderer"], to: ["contents": [[String: Any]]()])),
            ("a future figures payload", RecapFixture.setting(base, tabContent, to: ["sectionListRenderer": ["contents": [["musicShelfRenderer": ["title": "x"]]]]])),
            ("two tabs", twoTabs),
            ("no tabs", RecapFixture.setting(base, tabs, to: [Any]())),
            ("an empty message", RecapFixture.setting(base, RecapFixture.messagePath + ["text"], to: ["runs": [[String: Any]]()])),
            ("a message with no text", RecapFixture.setting(base, RecapFixture.messagePath + ["text"], to: nil)),
            ("a whitespace-only message", RecapFixture.message(headline: " \n\t ")),
            ("an error beside the contents", base.merging(["error": ["code": 500]]) { $1 }),
        ]
        for (name, variant) in variants {
            #expect(throws: MusicSessionError.unrecognised, "\(name)") { try MusicRecapParser.parse(variant) }
        }
    }

    @Test func simpleTextWasNeverCapturedSoItIsNeverTheMessage() throws {
        let base = try RecapFixture.signedCapture()
        let textPath = RecapFixture.messagePath + ["text"]
        // Control: the captured representation (runs) reads.
        guard case .serviceMessage(let control) = try MusicRecapParser.parse(RecapFixture.setting(base, textPath, to: ["runs": [["text": "from runs"]]])) else { Issue.record("expected a message"); return }
        #expect(control.headline == "from runs")
        let malformedRun: [Any] = [["text": "first"], ["text": 7]]
        let variants: [(String, [String: Any])] = [
            ("simpleText alone", ["simpleText": "x"]),
            ("simpleText beside valid runs", ["simpleText": "x", "runs": [["text": "from runs"]]]),
            ("simpleText beside malformed runs", ["simpleText": "x", "runs": malformedRun]),
            ("an empty simpleText beside valid runs", ["simpleText": "", "runs": [["text": "from runs"]]]),
        ]
        for (name, text) in variants {
            #expect(throws: MusicSessionError.unrecognised, "\(name)") { try MusicRecapParser.parse(RecapFixture.setting(base, textPath, to: text)) }
        }
    }

    // MARK: bounds and verbatim text

    @Test func aMessageTextIsBoundedAndRefusedNeverTruncated() throws {
        let limit = MusicRecapRoute.maximumHeadlineBytes
        let atLimit = String(repeating: "a", count: limit)
        guard case .serviceMessage(let fits) = try MusicRecapParser.parse(RecapFixture.message(headline: atLimit)) else { Issue.record("expected a message"); return }
        #expect(fits.headline == atLimit && fits.headline.utf8.count == limit)
        #expect(throws: MusicSessionError.unrecognised) { try MusicRecapParser.parse(RecapFixture.message(headline: atLimit + "a")) }
        // Bytes, not characters: 500 two-byte characters fit, 501 do not.
        #expect(throws: Never.self) { _ = try MusicRecapParser.parse(RecapFixture.message(headline: String(repeating: "é", count: limit / 2))) }
        #expect(throws: MusicSessionError.unrecognised) { try MusicRecapParser.parse(RecapFixture.message(headline: String(repeating: "é", count: limit / 2 + 1))) }
        let many = (0..<(MusicRecapParser.maximumRuns + 1)).map { _ in "a" }
        #expect(throws: MusicSessionError.unrecognised, "more runs than the bound") { try MusicRecapParser.parse(RecapFixture.message(headline: "", runs: many)) }
        #expect(throws: Never.self) { _ = try MusicRecapParser.parse(RecapFixture.message(headline: "", runs: Array(many.dropLast()))) }
    }
    @Test func textIsPassedThroughExactlyWithoutTrimmingMarkupOrLocalizationInterpretation() throws {
        for text in ["  Leading and trailing  ", "Line one\nLine two\tTabbed", "**bold** _x_ [link](https://example.invalid) %@ %lld \\(x)",
                     "Ünïcödé — 日本語 — العربية — 🎵", "<s:20:t>"] {
            guard case .serviceMessage(let message) = try MusicRecapParser.parse(RecapFixture.message(headline: text)) else { Issue.record("expected a message"); return }
            #expect(message.headline == text)
        }
        guard case .serviceMessage(let joined) = try MusicRecapParser.parse(RecapFixture.message(headline: "", runs: ["One ", "two", " three"])) else { Issue.record("expected a message"); return }
        #expect(joined.headline == "One two three", "runs are joined as printed")
    }
    @Test func controlCharactersOtherThanLineBreaksAndTabsAreRefused() throws {
        for scalar in ["\u{0000}", "\u{0007}", "\u{001B}", "\u{007F}"] {
            #expect(throws: MusicSessionError.unrecognised) { try MusicRecapParser.parse(RecapFixture.message(headline: "a" + scalar + "b")) }
        }
    }

    // MARK: structural guards

    @Test func noProductSourceHardCodesTheRedactedPlaceholdersOrTheMessageWords() throws {
        let root = packageRoot().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            // Code only: the notes in the parser's header legitimately name the placeholders they explain.
            let code = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            #expect(!code.contains("\"<s:") && !code.contains("<key:"), "\(url.lastPathComponent) must not carry capture placeholders")
        }
        #expect(scanned > 100, "the guard looked at the sources (\(scanned))")
    }
}

// MARK: the signed client

private actor RecapWire: SignedMusicTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var limits: [Int] = []
    var responses: [SignedMusicWireResponse]
    init(_ responses: [SignedMusicWireResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        try SignedMusicPolicy.validate(request, maximumBytes: maximumBytes)
        requests.append(request); limits.append(maximumBytes)
        return responses.isEmpty ? .init(status: 500, body: Data(), contentType: nil) : responses.removeFirst()
    }
    func captured() -> (requests: [URLRequest], limits: [Int]) { (requests, limits) }
}
private struct RecapNow: WallClock { func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) } }
private func recapSession() throws -> MusicCookieSession {
    func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: ".youtube.com", .path: "/", .expires: Date(timeIntervalSince1970: 1_700_000_000 + 86_400)])!
    }
    return try MusicCookieSession(accountID: UUID(), cookies: [cookie("SAPISID", "SYNTHETIC-SAPISID-VALUE"), cookie("SID", "SYNTHETIC-SID-VALUE")], now: Date(timeIntervalSince1970: 1_700_000_000))
}
private func recapClient(_ transport: RecapWire) -> SignedMusicClient { SignedMusicClient(transport: transport, clock: RecapNow()) { "1.20261028.01.00" } }
private func recapJSON(_ object: [String: Any], status: Int = 200, contentType: String? = "application/json; charset=UTF-8") throws -> SignedMusicWireResponse {
    .init(status: status, body: try JSONSerialization.data(withJSONObject: object), contentType: contentType)
}

@Suite struct SignedRecapReadTests {
    @Test func oneReadIsOneSignedBrowseOfTheKnownHandlerAndNothingElse() async throws {
        let wire = RecapWire([try recapJSON(try RecapFixture.signedCapture())])
        let result = try await recapClient(wire).recap(session: try recapSession())
        #expect(result.value == .serviceMessage(.init(headline: "<s:20:t>")))
        let (requests, limits) = await wire.captured()
        #expect(requests.count == 1 && limits == [MusicRecapRoute.maximumResponseBytes], "exactly one request, with the Recap byte cap")
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("SAPISID=") == true)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://music.youtube.com" && request.value(forHTTPHeaderField: "X-Origin") == "https://music.youtube.com")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(Set(body.keys) == ["browseId", "context"], "no params, continuation, query or any other field: \(body.keys.sorted())")
        #expect(body["browseId"] as? String == "FEmusic_listening_review" && MusicRecapRoute.browseID == "FEmusic_listening_review")
        let client = try #require((body["context"] as? [String: Any])?["client"] as? [String: Any])
        #expect(client["clientName"] as? String == "WEB_REMIX", "the same client every other signed read uses")
    }
    @Test func theAllowlistsAreUnchangedByRecap() {
        #expect(SignedMusicPolicy.musicPaths == ["/youtubei/v1/browse", "/youtubei/v1/account/account_menu", "/youtubei/v1/search", "/youtubei/v1/next"])
        #expect(SignedMusicPolicy.writePaths == ["/youtubei/v1/like/like", "/youtubei/v1/like/dislike", "/youtubei/v1/like/removelike",
                                                 "/youtubei/v1/subscription/subscribe", "/youtubei/v1/subscription/unsubscribe", "/youtubei/v1/feedback"])
        #expect(SignedMusicPolicy.playlistWritePaths == ["/youtubei/v1/playlist/create", "/youtubei/v1/browse/edit_playlist", "/youtubei/v1/playlist/delete"])
    }
    @Test func aFailureIsOneRequestAndIsNeverRetriedOrReadAsAnEmptyRecap() async throws {
        let cases: [(Int, MusicSessionError)] = [(500, .server), (503, .server), (429, .rateLimited), (401, .signedOut), (403, .signedOut), (404, .unrecognised), (302, .unrecognised)]
        for (status, error) in cases {
            let wire = RecapWire([.init(status: status, body: Data("{}".utf8), contentType: "application/json")])
            await #expect(throws: error, "HTTP \(status)") { try await recapClient(wire).recap(session: try recapSession()) }
            #expect(await wire.captured().requests.count == 1, "HTTP \(status) is not retried")
        }
    }
    @Test func aBodyThatIsNotRecognisedJSONOrIsTooLargeIsUnreadable() async throws {
        let notJSONType = RecapWire([.init(status: 200, body: try JSONSerialization.data(withJSONObject: try RecapFixture.signedCapture()), contentType: "text/html")])
        await #expect(throws: MusicSessionError.unrecognised) { try await recapClient(notJSONType).recap(session: try recapSession()) }
        let malformed = RecapWire([.init(status: 200, body: Data("{\"contents\":".utf8), contentType: "application/json")])
        await #expect(throws: MusicSessionError.unrecognised) { try await recapClient(malformed).recap(session: try recapSession()) }
        let array = RecapWire([.init(status: 200, body: Data("[]".utf8), contentType: "application/json")])
        await #expect(throws: MusicSessionError.unrecognised) { try await recapClient(array).recap(session: try recapSession()) }
        let huge = RecapWire([.init(status: 200, body: Data(count: MusicRecapRoute.maximumResponseBytes + 1), contentType: "application/json")])
        await #expect(throws: MusicSessionError.oversized) { try await recapClient(huge).recap(session: try recapSession()) }
    }
    @Test func anAnswerFromAnotherHandlerOrAFutureShapeIsUnreadableAndAnExplicitSignedOutFlagIsSignedOut() async throws {
        let base = try RecapFixture.signedCapture()
        let other = RecapWire([try recapJSON(RecapFixture.tracking(base, key: "browse_id", value: "FEmusic_home"))])
        await #expect(throws: MusicSessionError.unrecognised) { try await recapClient(other).recap(session: try recapSession()) }
        let future = RecapWire([try recapJSON(RecapFixture.setting(base, ["contents", "singleColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer", "content"],
                                                                      to: ["sectionListRenderer": ["contents": [[String: Any]]()]]))])
        await #expect(throws: MusicSessionError.unrecognised) { try await recapClient(future).recap(session: try recapSession()) }
        let flagged = base.merging(["responseContext": ["mainAppWebResponseContext": ["loggedOut": true]]]) { $1 }
        let signedOut = RecapWire([try recapJSON(flagged)])
        await #expect(throws: MusicSessionError.signedOut) { try await recapClient(signedOut).recap(session: try recapSession()) }
    }
    @Test func aSignedReadAnsweredAsLoggedOutIsASignedOutSessionNotANeedsSignInFallback() async throws {
        let wire = RecapWire([try recapJSON(try RecapFixture.object("anonymous-listening-review-no-contents.json"))])
        await #expect(throws: MusicSessionError.signedOut) { try await recapClient(wire).recap(session: try recapSession()) }
        #expect(await wire.captured().requests.count == 1, "no anonymous or second request follows")
        // The pure parser still reads the same bytes as needs-sign-in (that is how the anonymous capture is tested).
        #expect(try MusicRecapParser.parse(try RecapFixture.object("anonymous-listening-review-no-contents.json")) == .needsSignIn)
    }
    @Test func aReaderThatNeverLearnedRecapRefusesInsteadOfGuessing() async {
        struct Old: MusicSessionReading {
            func accountMenu(session: MusicCookieSession) async throws -> MusicSignedResult<MusicAccountIdentity> { throw MusicSessionError.policy }
            func likedPlaylists(session: MusicCookieSession) async throws -> MusicSignedResult<MusicLibraryPlaylists> { throw MusicSessionError.policy }
            func avatar(_ url: URL) async throws -> Data { throw MusicSessionError.policy }
            func lyrics(videoID: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicLyricsResult> { throw MusicSessionError.policy }
        }
        await #expect(throws: MusicSessionError.policy) { try await Old().recap(session: try recapSession()) }
    }
}

// MARK: the summary model

/// A source that records every read, and can hold reads open so a test can change the account while one is in flight.
private actor RecapScript: AccountSummarySource {
    nonisolated var unresolved: String? { nil }
    nonisolated var badgesUnresolved: String? { "No badges route." }
    private(set) var reads = 0
    private var pending: [CheckedContinuation<SummaryAnswer<RecapPayload>, any Error>] = []
    private var immediate: [Result<SummaryAnswer<RecapPayload>, any Error>] = []
    private let hold: Bool
    init(hold: Bool = false, answers: [Result<SummaryAnswer<RecapPayload>, any Error>] = []) { self.hold = hold; immediate = answers }
    func recap() async throws -> SummaryAnswer<RecapPayload> {
        reads += 1
        if hold { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return try (immediate.isEmpty ? .success(.noPayload) : immediate.removeFirst()).get()
    }
    func badges() async throws -> SummaryAnswer<BadgePayload> { throw SamplesFailure.unreadable }
    func waitingCount() -> Int { pending.count }
    func resolve(_ index: Int, _ result: Result<SummaryAnswer<RecapPayload>, any Error>) { pending[index].resume(with: result) }
}

@Suite @MainActor struct RecapSummaryModelTests {
    private let message = SummaryServiceMessage(headline: "Service words one", detail: "Service words two")

    @Test func aServiceMessageIsItsOwnStateAndNeverMissingPayloadOrUnsupportedAccount() async {
        let script = RecapScript(answers: [.success(.serviceMessage(message))])
        let model = AccountSummaryModel(source: script)
        await model.loadRecap()
        #expect(model.recap == .serviceMessage(message))
        #expect(model.recap != .payloadMissing && model.recap != .accountUnsupported("Service words one"))
        if case .loaded = model.recap { Issue.record("a message is not a Recap") }
        let missing = AccountSummaryModel(source: RecapScript(answers: [.success(.noPayload)]))
        await missing.loadRecap()
        #expect(missing.recap == .payloadMissing && missing.recap != model.recap, "the two answers stay different facts")
    }
    @Test func aSignedOutModelSendsNothingAndAsksForSignIn() async {
        let script = RecapScript()
        let model = AccountSummaryModel(source: script, signedIn: { .needsSignIn })
        await model.loadRecap()
        #expect(model.recap == .signInRequired && model.readCount == 0)
        #expect(await script.reads == 0, "signed out: the source is never asked")
        let ended = AccountSummaryModel(source: script, signedIn: { .sessionExpired })
        await ended.loadRecap()
        #expect(ended.recap == .sessionEnded)
        #expect(await script.reads == 0)
    }
    @Test func buildingTheModelOrTheSurfaceReadsNothing() async {
        let script = RecapScript()
        let model = AccountSummaryModel(source: script)
        #expect(model.recap == .idle && model.readCount == 0)
        #expect(model.badges == .unresolved("No badges route."), "per-kind: Recap has a route, badges say why not")
        #expect(await script.reads == 0, "no startup account request")
    }
    @Test func eachExplicitLoadOrRetryIsExactlyOneRead() async {
        let script = RecapScript(answers: [.success(.serviceMessage(message)), .success(.serviceMessage(message)), .failure(SamplesFailure.offline)])
        let model = AccountSummaryModel(source: script)
        await model.loadRecap()
        #expect(await script.reads == 1 && model.readCount == 1, "the first open reads once and then stops")
        await model.loadRecap()   // Retry
        #expect(await script.reads == 2 && model.readCount == 2)
        await model.loadRecap()
        #expect(await script.reads == 3 && model.recap == .failed(.offline), "a failure is shown, not retried on its own")
        #expect(await script.reads == 3)
    }
    @Test func badgesStayUnresolvedAndNeverReadWhenRecapHasARoute() async {
        let script = RecapScript(answers: [.success(.serviceMessage(message))])
        let model = AccountSummaryModel(source: script)
        await model.loadBadges()
        #expect(model.badges == .unresolved("No badges route.") && model.readCount == 0)
        await model.loadRecap()
        #expect(model.badges == .unresolved("No badges route."), "reading Recap does not touch badges")
    }
    @Test func theLocalSummaryStaysSeparateAndNeverFillsAMessage() async {
        let records = [LocalHistoryRecord(videoID: "v", title: "T", artist: "A", startedAt: Date(), listenedSeconds: 60)]
        let model = AccountSummaryModel(source: RecapScript(answers: [.success(.serviceMessage(message))]), localRecords: { records })
        await model.loadRecap()
        #expect(model.local == nil, "reading Recap does not compute a local summary")
        await model.refreshLocal()
        #expect(model.recap == .serviceMessage(message), "and a local summary does not replace the message")
        #expect(model.local?.plays == 1 && model.local?.isOfficial == false)
    }
    @Test func anAccountChangeDropsAnAnswerInFlightAndALaterReadIsNotOverwrittenByTheOldCallback() async {
        let script = RecapScript(hold: true)
        let model = AccountSummaryModel(source: script)
        let first = Task { await model.loadRecap() }
        while await script.waitingCount() < 1 { await Task.yield() }
        #expect(model.recap == .loading)
        let before = model.epoch
        model.accountChanged()
        #expect(model.recap == .idle && model.epoch == before &+ 1, "the screen is told to start over")
        let second = Task { await model.loadRecap() }
        while await script.waitingCount() < 2 { await Task.yield() }
        let newer = SummaryServiceMessage(headline: "New account answer")
        await script.resolve(1, .success(.serviceMessage(newer)))
        await second.value
        #expect(model.recap == .serviceMessage(newer))
        await script.resolve(0, .success(.serviceMessage(SummaryServiceMessage(headline: "Old account answer"))))
        await first.value
        #expect(model.recap == .serviceMessage(newer), "the old account's answer arrived late and was ignored")
        // An old failure is ignored the same way.
        let third = Task { await model.loadRecap() }
        while await script.waitingCount() < 3 { await Task.yield() }
        model.accountChanged()
        await script.resolve(2, .failure(SamplesFailure.offline))
        await third.value
        #expect(model.recap == .idle)
    }

    // MARK: the composed source (Debug builds expose the internal composition)
    #if DEBUG
    @Test func theComposedSourceCarriesAMessageAsAMessageAndAMissingSessionAsSignIn() async throws {
        let source = SignedRecapSummarySource { .serviceMessage(MusicRecapServiceMessage(headline: "H", detail: "D")) }
        #expect(try await source.recap() == .serviceMessage(SummaryServiceMessage(headline: "H", detail: "D")))
        #expect(try await SignedRecapSummarySource { .needsSignIn }.recap() == .signInRequired)
        #expect(source.unresolved == nil && source.recapUnresolved == nil && source.badgesUnresolved?.contains("nothing is made up") == true)
    }
    @Test func theComposedSourceMapsEveryFailureToItsOwnStateNeverToAnEmptyRecap() async {
        func answer(_ error: MusicSessionError) async -> String {
            do { return "answer:\(try await SignedRecapSummarySource { throw error }.recap())" }
            catch let failure as SamplesFailure { return "failure:\(failure)" }
            catch { return "other:\(error)" }
        }
        #expect(await answer(.notSignedIn) == "answer:signInRequired")
        #expect(await answer(.signedOut) == "answer:sessionEnded")
        #expect(await answer(.network) == "failure:offline")
        #expect(await answer(.timedOut) == "failure:offline")
        #expect(await answer(.rateLimited) == "failure:rateLimited")
        for error in [MusicSessionError.unrecognised, .oversized, .server, .policy, .stale, .keychain, .cancelled] {
            #expect(await answer(error) == "failure:unreadable", "\(error)")
        }
    }
    @Test func aLoggedOutAnswerToTheSignedReadReachesTheScreenAsAnEndedSession() async throws {
        let wire = RecapWire([try recapJSON(try RecapFixture.object("anonymous-listening-review-no-contents.json"))])
        let client = recapClient(wire)
        let session = try recapSession()
        // adapter (MusicSessionError.signedOut, which the coordinator turns into an expired identity) -> feature source -> screen state
        let source = SignedRecapSummarySource { try await client.recap(session: session).value }
        let model = AccountSummaryModel(source: source)
        await model.loadRecap()
        #expect(model.recap == .sessionEnded, "not a message, not nothing-to-show, not a computed summary")
        #expect(await wire.captured().requests.count == 1)
    }
    @Test func aSignedOutShellNeverReachesTheReaderAndOneExplicitReadIsOneReaderCall() async {
        let calls = LockedCounter()
        let source = SignedRecapSummarySource { calls.bump(); return .serviceMessage(MusicRecapServiceMessage(headline: "H")) }
        let signedOut = AccountSummaryModel(source: source, signedIn: { .needsSignIn })
        await signedOut.loadRecap()
        #expect(signedOut.recap == .signInRequired && calls.value == 0)
        let model = AccountSummaryModel(source: source)
        #expect(calls.value == 0, "composing the source reads nothing")
        await model.loadRecap()
        #expect(calls.value == 1 && model.recap == .serviceMessage(SummaryServiceMessage(headline: "H")))
        await model.loadBadges()
        #expect(calls.value == 1 && model.badges == .unresolved(UnresolvedSummarySource().unresolved ?? ""), "badges neither read nor resolved")
    }
    @Test func isolatedAutomationComposesTheUnresolvedSourceAndANormalLaunchComposesTheReader() async {
        let calls = LockedCounter()
        let isolated = LocalAccountBootstrap.summarySource(isolated: true) { calls.bump(); return .needsSignIn }
        #expect(isolated.recapUnresolved != nil && isolated.badgesUnresolved != nil)
        let isolatedModel = AccountSummaryModel(source: isolated)
        await isolatedModel.loadRecap()
        guard case .unresolved = isolatedModel.recap else { Issue.record("isolated automation must stay unresolved"); return }
        #expect(calls.value == 0, "isolated automation never reaches the reader")
        let normal = LocalAccountBootstrap.summarySource(isolated: false) { calls.bump(); return .needsSignIn }
        #expect(normal.recapUnresolved == nil && normal.badgesUnresolved != nil)
        let model = AccountSummaryModel(source: normal)
        await model.loadRecap()
        #expect(calls.value == 1 && model.recap == .signInRequired)
    }
    #endif
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite struct RecapScreenSourceTests {
    /// The service's words are shown as text, not as a localization key or markup. A sweep of the view source (not a rendering).
    @Test func theMessageIsShownVerbatimWithARetry() throws {
        let text = try String(contentsOf: packageRoot().appendingPathComponent("Sources/Features/DiscoveryExtras/DiscoveryViews.swift"), encoding: .utf8)
        #expect(text.contains("Text(verbatim: message.headline)") && text.contains("Text(verbatim: detail)"))
        #expect(text.contains("case .serviceMessage(let message):"), "the summary view has its own branch for it")
        #expect(text.contains("Button(\"Retry\", action: retry)"))
        #expect(!text.contains("Text(message.headline)") && !text.contains("LocalizedStringKey(message.headline)"))
        // The Recap screen reads on open and when the account changes, and nowhere else by itself.
        #expect(text.contains(".task(id: model.epoch) { await model.loadRecap() }"))
        #expect(text.components(separatedBy: "loadRecap()").count - 1 == 2, "open and Retry, nothing more")
    }
}
