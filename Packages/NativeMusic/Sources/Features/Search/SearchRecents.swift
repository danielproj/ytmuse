import AccountSession
import Foundation
import Observation

/// An item the person played or copied from search, kept so an empty search can offer it again.
public struct RecentSearchItem: Codable, Sendable, Equatable, Identifiable {
    public let kind: MusicSearchKind
    public let title: String
    public let details: [String]
    public let serviceLabel: String?
    public let videoID: String?, browseID: String?, playlistID: String?
    public var id: String { result.id }
    public init(_ result: SearchResult) {
        kind = result.kind
        title = String(result.title.prefix(512)); details = result.details.map { String($0.prefix(256)) }.prefix(6).map { $0 }
        serviceLabel = result.serviceLabel
        videoID = result.target.videoID; browseID = result.target.browseID; playlistID = result.target.playlistID
    }
    /// Shown as a result the person already chose once; it carries no service badge because nothing was asked.
    public var result: SearchResult {
        SearchResult(kind: kind, title: title, details: details, serviceLabel: serviceLabel, badges: [.recent],
                     target: SearchTarget(videoID: videoID, browseID: browseID, playlistID: playlistID), fromService: false)
    }
}

/// Recent queries and recent items, per account scope, on this Mac only.
///
/// Privacy (SEC03): these are the person's private search strings. They are stored only in the app's
/// preferences store, are never written to a log, a diagnostic or an error message, are recorded only when
/// the person submits a search or acts on a result (never per keystroke), are bounded, can be cleared at any
/// time, and are erased with the account (`prune`).
@MainActor @Observable public final class SearchRecents {
    public private(set) var queries: [String] = []
    public private(set) var items: [RecentSearchItem] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let scope: @MainActor () -> String
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private var loadedScope: String?
    nonisolated static let prefix = "search.recents.v1."
    private struct Stored: Codable, Sendable { var queries: [String]; var items: [RecentSearchItem] }

    public init(defaults: UserDefaults, scope: @escaping @MainActor () -> String, limit: Int = 10) {
        self.defaults = defaults; self.scope = scope; self.limit = max(1, min(50, limit))
        reload()
    }
    public var isEmpty: Bool { queries.isEmpty && items.isEmpty }
    /// Re-reads the bucket for the current account scope (call when the active account changes).
    public func reload() {
        let key = scope(); loadedScope = key
        if let data = defaults.data(forKey: Self.prefix + key), let stored = try? PropertyListDecoder().decode(Stored.self, from: data) {
            queries = Array(stored.queries.prefix(limit)); items = Array(stored.items.prefix(limit))
        } else { queries = []; items = [] }
    }
    private func save() {
        guard let key = loadedScope else { return }
        if queries.isEmpty && items.isEmpty { defaults.removeObject(forKey: Self.prefix + key); return }
        if let data = try? PropertyListEncoder().encode(Stored(queries: queries, items: items)) { defaults.set(data, forKey: Self.prefix + key) }
    }
    public func record(query text: String) {
        if loadedScope != scope() { reload() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { return }
        let folded = SearchText.fold(trimmed)
        queries.removeAll { SearchText.fold($0) == folded }
        queries.insert(trimmed, at: 0); queries = Array(queries.prefix(limit)); save()
    }
    public func record(item result: SearchResult) {
        if loadedScope != scope() { reload() }
        let item = RecentSearchItem(result)
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0); items = Array(items.prefix(limit)); save()
    }
    public func clearQueries() { queries = []; save() }
    public func clearItems() { items = []; save() }
    public func clearAll() { queries = []; items = []; save() }
    public func remove(query text: String) { queries.removeAll { $0 == text }; save() }
    /// W27: every search term recorded for any account (the strings a diagnostic export must never carry).
    nonisolated public static func recordedTerms(defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(prefix) }.flatMap { entry -> [String] in
            guard let data = entry.value as? Data, let stored = try? PropertyListDecoder().decode(Stored.self, from: data) else { return [] }
            return stored.queries
        }
    }
    /// Erases the buckets of every account that no longer exists. `keeping` holds the scope keys still in use.
    public static func prune(defaults: UserDefaults, keeping: Set<String>) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) && !keeping.contains(String(key.dropFirst(prefix.count))) {
            defaults.removeObject(forKey: key)
        }
    }
}
