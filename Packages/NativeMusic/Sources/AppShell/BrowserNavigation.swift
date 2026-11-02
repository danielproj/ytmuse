import Diagnostics
import Foundation
import Observation
import SystemIntegration

public enum BrowserDestination: String, CaseIterable, Codable, Sendable {
    case home, explore, search, library, downloads, history, uploads, podcasts, queue, nowPlaying
    public var title: String {
        switch self { case .home: "Home"; case .explore: "Explore"; case .search: "Search"; case .library: "Library"; case .downloads: "Downloads"; case .history: "History"; case .uploads: "Uploads"; case .podcasts: "Podcasts"; case .queue: "Queue"; case .nowPlaying: "Now Playing" }
    }
    public var symbol: String {
        switch self { case .home: "house"; case .explore: "safari"; case .search: "magnifyingglass"; case .library: "square.stack"; case .downloads: "arrow.down.circle"; case .history: "clock"; case .uploads: "arrow.up.circle"; case .podcasts: "mic"; case .queue: "list.bullet"; case .nowPlaying: "play.circle" }
    }
}
public enum NativeItemKind: String, Codable, Sendable {
    case song, album, artist, playlist, podcast, episode, video, sample, tuner, recap, badge
    /// A catalog page named by a browse id (Charts, New releases, a mood or genre); `NativeItemRoute.params` carries the service's parameters.
    case category
}
public struct NativeItemRoute: Equatable, Codable, Sendable {
    public let kind: NativeItemKind
    public let identifier: String
    /// Opaque service parameters for a category page (moods and genres need them); validated, never interpreted.
    public let params: String?
    public init(kind: NativeItemKind, identifier: String, params: String? = nil) throws {
        guard (1...256).contains(identifier.utf8.count), identifier.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else { throw NavigationFault.invalidItem }
        if let params {
            guard kind == .category || kind == .playlist || kind == .album || kind == .artist, (1...1024).contains(params.utf8.count),
                  params.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || "%_=+/.-".utf8.contains($0) }) else { throw NavigationFault.invalidItem }
        }
        self.kind = kind; self.identifier = identifier; self.params = params
    }
}
public enum NavigationFault: Error { case invalidItem, invalidRestoration }
public struct BrowserEntry: Equatable, Codable, Identifiable, Sendable {
    public var id = UUID()
    public var destination: BrowserDestination
    public var item: NativeItemRoute?
    public var selection: Set<String> = []
    public var scrollOffset: Double = 0
    public var filter = "All"
    public var query = ""
    public var page = 0
    /// W09-F2: what a production page recorded for this visit beyond the fields above (kind, sort, layout, scope, filter). nil: the page has
    /// recorded nothing for this entry yet, so it records what it shows instead of replacing it.
    public var pageValues: [String: String]? = nil
    public init(destination: BrowserDestination, item: NativeItemRoute? = nil) { self.destination = destination; self.item = item }
}
public struct BrowserSession: Equatable, Codable, Sendable {
    public var windowID = UUID()
    public var owner: WindowOwner? = nil
    public var historyEpoch: UInt64? = nil
    public private(set) var entries = [BrowserEntry(destination: .home)]
    public private(set) var index = 0
    public var current: BrowserEntry {
        get { entries[index] }
        set { entries[index] = newValue }
    }
    public func entry(id: UUID) -> BrowserEntry? { entries.first { $0.id == id } }
    /// Changes one entry by identity, whichever entry is current. A page's store is bound to the entry it was made for, so a view that is leaving
    /// can never write into the entry that replaced it.
    public mutating func update(_ id: UUID, _ change: (inout BrowserEntry) -> Void) {
        guard let position = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[position])
    }
    public var canBack: Bool { index > 0 }
    public var canForward: Bool { index + 1 < entries.count }
    public init() {}
    public mutating func open(_ destination: BrowserDestination, item: NativeItemRoute? = nil) {
        guard current.destination != destination || current.item != item else { return }
        entries = Array(entries.prefix(index + 1)); entries.append(BrowserEntry(destination: destination, item: item)); index += 1
        // Browsing history is bounded and cannot retain a whole catalog.
        if entries.count > 100 { entries.removeFirst(); index -= 1 }
    }
    public mutating func back() { if canBack { index -= 1 } }
    public mutating func forward() { if canForward { index += 1 } }
    static func validPageValues(_ values: [String: String]?) -> Bool {
        guard let values else { return true }
        return values.count <= 32 && values.allSatisfy { $0.key.utf8.count <= 64 && $0.value.utf8.count <= 256 }
    }
    public func encoded() throws -> Data { try PropertyListEncoder().encode(self) }
    public static func restore(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw NavigationFault.invalidRestoration }
        let value = try PropertyListDecoder().decode(Self.self, from: data)
        guard (1...100).contains(value.entries.count), value.entries.indices.contains(value.index), Set(value.entries.map(\.id)).count == value.entries.count,
              value.entries.allSatisfy({ (0...624).contains($0.page) && $0.scrollOffset.isFinite && $0.scrollOffset >= 0 && $0.scrollOffset <= 10_000_000 && $0.query.utf8.count <= 4096 && $0.filter.utf8.count <= 128 && $0.selection.count <= 50_000 && $0.selection.allSatisfy { $0.utf8.count <= 256 } && Self.validPageValues($0.pageValues) }) else { throw NavigationFault.invalidRestoration }
        for entry in value.entries { if let item = entry.item { _ = try NativeItemRoute(kind: item.kind, identifier: item.identifier, params: item.params) } }
        return value
    }
}
@MainActor @Observable public final class BrowserNavigation {
    public var session: BrowserSession { didSet { revision &+= 1 } }
    public init(session: BrowserSession = .init()) { self.session = session }
    public private(set) var revision: UInt64 = 0
    public func reset(owner: WindowOwner?) { let id = session.windowID; session = BrowserSession(); session.windowID = id; session.owner = owner }
    public func open(_ destination: BrowserDestination, item: NativeItemRoute? = nil) {
        // PERF05: a navigation interval runs from the request to the new content having been laid out. SwiftUI commits the change at the end of the
        // current run-loop turn, so the interval ends two main-queue turns later (indicative; the label is the fixed destination name, never an item).
        let before = session.current.id
        let signpost = PerformanceSignposts.begin(.navigation, label: destination.rawValue)
        session.open(destination, item: item)
        if session.current.id == before { PerformanceSignposts.end(signpost); return }
        DispatchQueue.main.async { DispatchQueue.main.async { PerformanceSignposts.end(signpost) } }
    }
    public func back() { session.back() }
    public func forward() { session.forward() }
}

/// Window-owned bounded page window. Stable occurrence keys are supplied by the data source.
/// It accepts only a page, never requires retaining all 50,000 catalog items to show 80 rows.
public struct BrowserPageWindow<Element: Identifiable & Sendable>: Sendable where Element.ID: Sendable {
    public private(set) var rows: [Element] = []
    public let limit: Int
    public init(limit: Int = 160) { self.limit = max(1, min(500, limit)) }
    public mutating func replace(_ page: [Element]) { rows = Array(page.prefix(limit)) }
    public mutating func append(_ page: [Element]) { rows = Array((rows + page.prefix(limit)).suffix(limit)) }
}

extension NativeItemRoute {
    /// Only navigation is decoded. No play/mutation/credential parameters execute from a link. The rules are `LinkPolicy`'s (W26): exact hosts,
    /// exact paths, identifiers whose shape matches their kind, no redirect followed and nothing fetched.
    public static func parse(_ url: URL) throws -> NativeItemRoute {
        guard case .success(.item(let item)) = LinkPolicy.parse(url), let kind = NativeItemKind(rawValue: item.kind.rawValue) else { throw NavigationFault.invalidItem }
        return try NativeItemRoute(kind: kind, identifier: item.identifier)
    }
}
