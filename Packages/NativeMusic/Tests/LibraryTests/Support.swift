import AccountSession
import CryptoKit
import Domain
import Features
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// W12 fixtures: library and history pages built from rows of the real anonymous captures (`synthetic-from-real-renderers`).
func fixturesRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("Fixtures")
}
func w12Data(_ name: String) throws -> Data { try Data(contentsOf: fixturesRoot().appendingPathComponent("W12/" + name)) }
func w12(_ name: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: try w12Data(name)) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return object
}
func realCapture(_ name: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: fixturesRoot().appendingPathComponent("W11-real/browse-\(name).json"))) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return object
}
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func libraryPage(_ name: String) throws -> MusicBrowsePage { try MusicBrowseParser.parse(try w12(name), mode: .collection) }
func libraryContinuation(_ name: String) throws -> MusicContinuationPage { try MusicBrowseParser.parseContinuation(try w12(name), mode: .collection) }

/// Counts the entry renderers anywhere in a document: an oracle independent of the parser.
func countEntryRenderers(in value: Any) -> Int {
    let names: Set<String> = ["musicTwoRowItemRenderer", "musicResponsiveListItemRenderer", "musicMultiRowListItemRenderer", "musicNavigationButtonRenderer"]
    var count = 0
    func walk(_ node: Any) {
        if let object = node as? [String: Any] {
            for (key, child) in object { if names.contains(key) { count += 1 }; walk(child) }
        } else if let list = node as? [Any] { for child in list { walk(child) } }
    }
    walk(value)
    return count
}

/// A scripted signed service: nothing here reaches a network. It records every request it is given (after the real policy check).
actor ScriptedSigned: SignedMusicTransport {
    private(set) var requests: [URLRequest] = []
    var body: Data
    var status: Int
    var type: String?
    var failure: (any Error)?
    init(body: Data = Data("{}".utf8), status: Int = 200, type: String? = "application/json; charset=UTF-8", failure: (any Error)? = nil) {
        self.body = body; self.status = status; self.type = type; self.failure = failure
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> SignedMusicWireResponse {
        try SignedMusicPolicy.validate(request, maximumBytes: maximumBytes)
        requests.append(request)
        if let failure { throw failure }
        return .init(status: status, body: body, contentType: type)
    }
    func captured() -> [URLRequest] { requests }
    func set(body: Data) { self.body = body }
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
