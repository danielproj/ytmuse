import AccountSession
import Foundation
import Testing
import YouTubeMusicAdapter

/// The nine real anonymous public captures (`Fixtures/W11-real`, labelled `real-public-anonymous-capture`).
enum Capture: String, CaseIterable {
    case home, explore, moods, charts, artist, album, playlist, podcast
    case newReleases = "new_releases"
    var file: String { "browse-\(rawValue).json" }
}
func fixturesRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("Fixtures")
}
func realData(_ capture: Capture) throws -> Data { try Data(contentsOf: fixturesRoot().appendingPathComponent("W11-real/" + capture.file)) }
func realCapture(_ capture: Capture) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: realData(capture)) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return object
}
func realPage(_ capture: Capture) throws -> MusicBrowsePage { try MusicBrowseParser.parse(try realCapture(capture)) }
func syntheticData(_ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("W11/" + name))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return object
}
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
import CryptoKit
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

import Features
@testable import AccountSession

/// Scripted service for the page-model tests: pages and continuations are answered from closures, each call is counted,
/// and a reply can be held until the test releases it.
actor ServiceScript {
    private(set) var pageCalls: [CatalogTarget] = []
    private(set) var tokenCalls: [String] = []
    var pages: [String: [MusicBrowsePage]] = [:]
    var continuations: [String: MusicContinuationPage] = [:]
    var failures: [String: MusicSessionError] = [:]
    var held: [CheckedContinuation<Void, Never>] = []
    var holdPages = false
    var holdTokens = false
    var mode: MusicSearchReply.Mode = .anonymous
    func setPages(_ target: CatalogTarget, _ list: [MusicBrowsePage]) { pages[target.key] = list }
    func setContinuation(_ token: String, _ page: MusicContinuationPage) { continuations[token] = page }
    func setFailure(_ key: String, _ error: MusicSessionError?) { failures[key] = error }
    func setHold(pages: Bool? = nil, tokens: Bool? = nil) { if let pages { holdPages = pages }; if let tokens { holdTokens = tokens } }
    func setMode(_ value: MusicSearchReply.Mode) { mode = value }
    func release() { let all = held; held = []; for c in all { c.resume() } }
    var heldCount: Int { held.count }
    func page(_ target: CatalogTarget) async throws -> MusicBrowseReply<MusicBrowsePage> {
        pageCalls.append(target)
        if holdPages { await withCheckedContinuation { held.append($0) } }
        if let error = failures[target.key] { throw error }
        guard var list = pages[target.key], !list.isEmpty else { throw MusicSessionError.unrecognised }
        let value = list.count > 1 ? list.removeFirst() : list[0]
        pages[target.key] = list
        return MusicBrowseReply(value: value, mode: mode, accountGeneration: 1)
    }
    func token(_ token: String) async throws -> MusicBrowseReply<MusicContinuationPage> {
        tokenCalls.append(token)
        if holdTokens { await withCheckedContinuation { held.append($0) } }
        if let error = failures[token] { throw error }
        guard let value = continuations[token] else { throw MusicSessionError.unrecognised }
        return MusicBrowseReply(value: value, mode: mode, accountGeneration: 1)
    }
}
@MainActor final class Box<T> { var value: T; init(_ value: T) { self.value = value } }
@MainActor final class StubPerformer: SearchActionPerformer {
    var played: [(String, String)] = []
    /// Every start with the track and parameters it carried (`played` holds the same starts as playlist + title).
    var targets: [(playlist: String, video: String?, params: String?)] = []
    var copied: [URL] = []
    var outcome: SearchPlayOutcome = .started
    func play(playlistID: String, title: String) async -> SearchPlayOutcome { played.append((playlistID, title)); targets.append((playlistID, nil, nil)); return outcome }
    func play(playlistID: String, title: String, videoID: String?, params: String?) async -> SearchPlayOutcome {
        played.append((playlistID, title)); targets.append((playlistID, videoID, params)); return outcome
    }
    func copy(link: URL) { copied.append(link) }
}
@MainActor func makeModel(_ target: CatalogTarget, script: ServiceScript, cache: CatalogCache = CatalogCache(), scope: Box<String> = Box("scope-1"),
                          now: Box<Date> = Box(Date(timeIntervalSince1970: 1_000_000)), performer: StubPerformer? = nil,
                          playback: SearchPlayback = .available, staleAfter: TimeInterval = 600,
                          onItems: @escaping @MainActor ([MusicCatalogItem]) -> Void = { _ in }) -> CatalogPageModel {
    CatalogPageModel(target: target, reader: { try await script.page($0) }, continuer: { try await script.token($0) }, cache: cache,
                     accountScope: { scope.value }, playback: { playback }, performer: performer, now: { now.value }, staleAfter: staleAfter, onItems: onItems)
}
@MainActor func settle(_ rounds: Int = 60) async { for _ in 0..<rounds { await Task.yield() } }
func shelf(_ key: String, _ titles: [String], continuation: String? = nil, kind: MusicEntityKind = .album) -> MusicShelf {
    MusicShelf(key: key, title: key, layout: .carousel, items: titles.map { MusicCatalogItem(kind: kind, title: $0, browseID: "MPREb_" + $0.replacingOccurrences(of: " ", with: "_")) }, continuation: continuation)
}
func pageOf(_ shelves: [MusicShelf], header: MusicPageHeader? = nil, continuation: String? = nil) -> MusicBrowsePage {
    var acc = MusicParseAccounting()
    acc.sections = shelves.count; acc.shelves = shelves.count; acc.items = shelves.reduce(0) { $0 + $1.items.count }; acc.classified = acc.items
    return MusicBrowsePage(header: header, shelves: shelves, continuation: continuation, accounting: acc)
}
