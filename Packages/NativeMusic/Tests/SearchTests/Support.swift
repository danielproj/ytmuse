import AccountSession
import Foundation
import Testing
import YouTubeMusicAdapter
@testable import Features

/// A clock the test advances by hand. `sleep` suspends until `advance` reaches its deadline.
final class VirtualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { .init(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    typealias Duration = Swift.Duration
    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: (deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = [:]
    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { lock.withLock { sleepers.count } }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let ready = lock.withLock { () -> Bool in
                    if deadline <= current { return true }
                    sleepers[id] = (deadline, continuation); return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let waiting = lock.withLock { sleepers.removeValue(forKey: id) }
            waiting?.continuation.resume(throwing: CancellationError())
        }
    }
    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            current = current.advanced(by: duration)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for key in ready.keys { sleepers.removeValue(forKey: key) }
            return ready.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

/// Lets the test hold each remote call open and answer it when it chooses.
actor ScriptedRemote {
    private(set) var queries: [String] = []
    private var pending: [Int: CheckedContinuation<MusicSearchReply, Error>] = [:]
    func call(_ query: String) async throws -> MusicSearchReply {
        let index = queries.count
        queries.append(query)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func answer(_ index: Int, with reply: MusicSearchReply) { pending.removeValue(forKey: index)?.resume(returning: reply) }
    func fail(_ index: Int, with error: any Error) { pending.removeValue(forKey: index)?.resume(throwing: error) }
    var callCount: Int { queries.count }
}

@MainActor final class SpyPerformer: SearchActionPerformer {
    var played: [(playlist: String, title: String)] = []
    var copied: [URL] = []
    var outcome: SearchPlayOutcome = .started
    var gate: CheckedContinuation<Void, Never>?
    var holdPlay = false
    func play(playlistID: String, title: String) async -> SearchPlayOutcome {
        played.append((playlistID, title))
        if holdPlay { await withCheckedContinuation { gate = $0 } }
        return outcome
    }
    func copy(link: URL) { copied.append(link) }
    func release() { gate?.resume(); gate = nil }
}

@MainActor final class FakeLibrary: LocalSearchSource {
    var scopes: Set<SearchPlace> = [.all, .library]
    var titles: [(id: String, title: String)]
    init(_ titles: [(String, String)]) { self.titles = titles.map { (id: $0.0, title: $0.1) } }
    func search(_ query: FoldedQuery, limit: Int) async -> [SearchResult] {
        titles.compactMap { entry in
            guard let quality = query.match(entry.title) else { return nil }
            var badges: Set<SearchBadge> = [.library]
            if quality == .tolerant { badges.insert(.approximate) }
            return SearchResult(kind: .playlist, title: entry.title, subtitle: nil, badges: badges,
                                target: SearchTarget(browseID: "VL" + entry.id, playlistID: entry.id), fromService: false, quality: quality)
        }.sorted(by: SearchRanking.order)
    }
    func vocabulary() async -> [String] { titles.map(\.title) }
}

func searchFixture(_ name: String) throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent("Fixtures/W10/" + name))
}
func parsedFixture(_ name: String) throws -> MusicSearchResponse {
    guard let root = try JSONSerialization.jsonObject(with: try searchFixture(name)) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return try MusicSearchParser.parse(root)
}
func reply(_ response: MusicSearchResponse, generation: UInt64 = 1, mode: MusicSearchReply.Mode = .signedIn) -> MusicSearchReply {
    MusicSearchReply(response: response, mode: mode, accountGeneration: generation)
}
func response(_ items: [MusicSearchItem], top: MusicSearchItem? = nil, suggestion: MusicSearchSuggestion? = nil) -> MusicSearchResponse {
    MusicSearchResponse(top: top, items: items, suggestion: suggestion, skippedRows: 0)
}
func song(_ title: String, _ id: String = "aaaaaaaaaa1", explicit: Bool = false) -> MusicSearchItem {
    MusicSearchItem(kind: .song, title: title, subtitle: "Synthetic Artist", explicit: explicit, videoID: id)
}
/// Gives queued main-actor tasks room to run.
@MainActor func settle(_ rounds: Int = 40) async { for _ in 0..<rounds { await Task.yield() } }

func realCapture(_ name: String) throws -> [String: Any] {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/W10-real/" + name))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicSessionError.unrecognised }
    return object
}
/// Every `musicResponsiveListItemRenderer` in the document plus the top card: the rows the parser must account for.
func countRows(in value: Any) -> (rows: Int, cards: Int) {
    var rows = 0, cards = 0
    func walk(_ node: Any) {
        if let object = node as? [String: Any] {
            if object["musicResponsiveListItemRenderer"] != nil { rows += 1 }
            if object["musicCardShelfRenderer"] != nil { cards += 1 }
            for child in object.values { walk(child) }
        } else if let list = node as? [Any] { for child in list { walk(child) } }
    }
    walk(value)
    return (rows, cards)
}
