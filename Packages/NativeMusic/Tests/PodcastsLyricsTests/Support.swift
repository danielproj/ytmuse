import AccountSession
import CryptoKit
import Domain
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// W18 fixtures: the four REAL anonymous captures in `Fixtures/W18-real` (`real-public-anonymous-capture`), and the hand-written edge cases in
/// `Fixtures/W18` (`synthetic-test-only`, assembled by `Fixtures/W18/generate.py` from the real renderers).
func fixturesRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("Fixtures")
}
enum Real: String, CaseIterable {
    case next = "next-song.json", lyrics = "browse-lyrics.json", episode = "browse-episode.json", show = "browse-podcast.json"
}
func realData(_ capture: Real) throws -> Data { try Data(contentsOf: fixturesRoot().appendingPathComponent("W18-real/" + capture.rawValue)) }
func real(_ capture: Real) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: try realData(capture)) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return object
}
func synthetic(_ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("W18/" + name))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return object
}
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Counts every dictionary key equal to one of `names` anywhere in a document: an oracle that shares no code with the parsers.
func count(_ names: Set<String>, in value: Any) -> Int {
    var total = 0
    func walk(_ node: Any) {
        if let object = node as? [String: Any] { for (key, child) in object { if names.contains(key) { total += 1 }; walk(child) } }
        else if let list = node as? [Any] { for child in list { walk(child) } }
    }
    walk(value)
    return total
}

actor ScriptedSigned: SignedMusicTransport {
    private(set) var requests: [URLRequest] = []
    var bodies: [Data]
    var status: Int
    init(bodies: [Data], status: Int = 200) { self.bodies = bodies; self.status = status }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        try SignedMusicPolicy.validate(request, maximumBytes: maximumBytes)
        requests.append(request)
        let body = bodies.count > 1 ? bodies.removeFirst() : (bodies.first ?? Data("{}".utf8))
        return .init(status: status, body: body, contentType: "application/json; charset=UTF-8")
    }
    func captured() -> [URLRequest] { requests }
}
actor ScriptedPublic: PublicHTTPTransport {
    private(set) var requests: [URLRequest] = []
    var bodies: [Data]
    init(bodies: [Data]) { self.bodies = bodies }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> PublicHTTPResponse {
        requests.append(request)
        if request.url?.path == "/" { return .init(data: Data(#"{"INNERTUBE_CLIENT_VERSION":"1.20261028.01.00","INNERTUBE_CONTEXT_CLIENT_NAME":"WEB_REMIX"}"#.utf8), status: 200) }
        let body = bodies.count > 1 ? bodies.removeFirst() : (bodies.first ?? Data("{}".utf8))
        return .init(data: body, status: 200)
    }
    func captured() -> [URLRequest] { requests }
}
struct FixedNow: WallClock { func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) } }
func testSession() throws -> MusicCookieSession {
    func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: ".youtube.com", .path: "/", .expires: Date(timeIntervalSince1970: 1_700_000_000 + 86_400)])!
    }
    return try MusicCookieSession(accountID: UUID(), cookies: [cookie("SAPISID", "SYNTHETIC-SAPISID-VALUE"), cookie("SID", "SYNTHETIC-SID-VALUE")], now: Date(timeIntervalSince1970: 1_700_000_000))
}
func signedClient(_ transport: ScriptedSigned) -> SignedMusicClient { SignedMusicClient(transport: transport, clock: FixedNow()) { "1.20261028.01.00" } }
func requestBody(_ request: URLRequest) throws -> [String: Any] {
    guard let data = request.httpBody, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return object
}
@MainActor func settle(_ rounds: Int = 80) async { for _ in 0..<rounds { await Task.yield() } }
@MainActor final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

func MusicEpisodeParser_parse(_ capture: Real) throws -> MusicEpisodePage { try MusicEpisodeParser.parse(try real(capture)) }
func MusicEpisodeParser_parse(synthetic name: String) throws -> MusicEpisodePage { try MusicEpisodeParser.parse(try synthetic(name)) }
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: T
    init(_ value: T) { stored = value }
    var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}
