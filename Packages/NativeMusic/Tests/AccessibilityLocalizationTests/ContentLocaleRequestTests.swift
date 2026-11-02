import Testing
import Foundation
import Domain
import AccountSession
@testable import AppShell
@testable import YouTubeMusicAdapter
import TestSupport

// W28 rework 1 (F1): the content language and region chosen in Settings are what the clients put into the request context. Fake transports only: nothing leaves
// the process, and the preferences are a per-test suite with a unique name that is removed afterwards.

private actor Recording: PublicHTTPTransport {
    var bodies: [[String: Any]] = []
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse {
        if request.url!.path == "/" { return .init(data: Data(#"{"INNERTUBE_CLIENT_VERSION":"1.2","clientName":"WEB_REMIX"}"#.utf8), status: 200) }
        if let body = request.httpBody, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { bodies.append(object) }
        return .init(data: Data("{}".utf8), status: 200)   // not a search result: the request is what is under test
    }
    func clients() -> [[String: String]] { bodies.compactMap { ($0["context"] as? [String: Any])?["client"] as? [String: String] } }
}
private actor RecordingSigned: SignedMusicTransport {
    var bodies: [[String: Any]] = []
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        if let body = request.httpBody, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { bodies.append(object) }
        return SignedMusicWireResponse(status: 200, body: Data("{}".utf8), contentType: "application/json; charset=UTF-8")
    }
    func clients() -> [[String: String]] { bodies.compactMap { ($0["context"] as? [String: Any])?["client"] as? [String: String] } }
}

private struct FixedClock: WallClock { func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) } }
private func signedInSession() throws -> MusicCookieSession {
    func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: ".youtube.com", .path: "/", .expires: Date(timeIntervalSince1970: 1_700_000_000 + 86_400)])!
    }
    return try MusicCookieSession(accountID: UUID(), cookies: [cookie("SAPISID", "SYNTHETIC-SAPISID-VALUE"), cookie("SID", "SYNTHETIC-SID-VALUE")], now: Date(timeIntervalSince1970: 1_700_000_000))
}

/// A per-test suite handed to the @Sendable provider (UserDefaults is documented as thread safe).
private struct SendableDefaults: @unchecked Sendable { let value: UserDefaults; init(_ value: UserDefaults) { self.value = value }
  func set(_ v: Any?, forKey k: String) { value.set(v, forKey: k) } }

@Suite struct ContentLocaleRequestTests {
  private func store() -> (SendableDefaults, () -> Void) {
    let defaults = InMemoryDefaults()
    return (SendableDefaults(defaults), {})
  }
  @Test func aChangedSettingChangesTheNextPublicRequest() async throws {
    let (defaults, cleanup) = store(); defer { cleanup() }
    let transport = Recording()
    let client = try PublicMusicClient(transport: transport, locale: { let hint = ContentLocaleSetting.current(systemPreferred: ["en-US"], systemRegion: "US", store: defaults.value); return ContentLocaleHint(hl: hint.hl, gl: hint.gl) })
    _ = try await client.bootstrap()
    _ = try? await client.search("first")
    defaults.set("pt-BR", forKey: LanguageRegionPreferences.contentLanguageKey); defaults.set("CH", forKey: LanguageRegionPreferences.contentRegionKey)
    _ = try? await client.search("second")
    defaults.set("zh-Hans-CN", forKey: LanguageRegionPreferences.contentLanguageKey); defaults.set("system", forKey: LanguageRegionPreferences.contentRegionKey)
    _ = try? await client.search("third")
    let seen = await transport.clients()
    #expect(seen.count == 3, "three searches were captured (\\(seen.count))")
    guard seen.count == 3 else { return }
    #expect(seen[0]["hl"] == "en" && seen[0]["gl"] == "US", "the system choices: \\(seen[0])")
    #expect(seen[1]["hl"] == "pt" && seen[1]["gl"] == "CH", "language without its region, and the chosen region as gl: \\(seen[1])")
    #expect(seen[2]["hl"] == "zh-Hans" && seen[2]["gl"] == "US", "a script is kept, a region of the language is not, system region returns: \\(seen[2])")
  }
  @Test func aChangedSettingChangesTheSignedRequestAndTheInterfaceChoiceDoesNot() async throws {
    let (defaults, cleanup) = store(); defer { cleanup() }
    let transport = RecordingSigned()
    let client = SignedMusicClient(transport: transport, clock: FixedClock(), locale: { let hint = ContentLocaleSetting.current(systemPreferred: ["en"], systemRegion: nil, store: defaults.value); return ContentLocaleHint(hl: hint.hl, gl: hint.gl) }, clientVersion: { "1.2" })
    let session = try signedInSession()
    _ = try? await client.accountMenu(session: session)
    defaults.set("de", forKey: LanguageRegionPreferences.contentLanguageKey); defaults.set("AT", forKey: LanguageRegionPreferences.contentRegionKey)
    _ = try? await client.accountMenu(session: session)
    defaults.set("ja", forKey: LanguageRegionPreferences.interfaceKey)   // the interface language is not a content hint
    _ = try? await client.accountMenu(session: session)
    let seen = await transport.clients()
    #expect(seen.count == 3, "three signed requests were captured (\\(seen.count))")
    guard seen.count == 3 else { return }
    #expect(seen[0]["hl"] == "en" && seen[0]["gl"] == nil)
    #expect(seen[1]["hl"] == "de" && seen[1]["gl"] == "AT", "\\(seen[1])")
    #expect(seen[2] == seen[1], "choosing an interface language changed nothing in the request")
  }
  @Test func malformedStoredValuesNeverDisableTheClientOrReachTheWire() async throws {
    let (defaults, cleanup) = store(); defer { cleanup() }
    defaults.set("not a language", forKey: LanguageRegionPreferences.contentLanguageKey); defaults.set("Switzerland", forKey: LanguageRegionPreferences.contentRegionKey)
    let hint = ContentLocaleSetting.current(systemPreferred: ["de"], systemRegion: nil, store: defaults.value)
    #expect(hint.hl == "en" && hint.gl == nil, "dropped to the defaults: \\(hint)")
    #expect(ContentLocaleHint(hl: "zh-Hans-CN", gl: "cn").hl == "en", "the adapter's own validation also falls back instead of throwing")
    #expect(ContentLocaleHint(hl: "pt", gl: "BR") == ContentLocaleHint(hl: "pt", gl: "BR"))
    #expect(ContentRequestHints(language: "pt-BR", region: "BR").hl == "pt" && ContentRequestHints(language: "zh-Hans-CN", region: nil).hl == "zh-Hans", "hl never carries the region")
  }
}
