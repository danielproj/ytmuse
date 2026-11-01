import AccountSession
import Foundation
import Observation

/// What a collection reads: one of the library tabs, or the service's history. Membership is stored here, apart from the catalog
/// items themselves (LIB03): an entry is a row of this collection that carries an item, not the item.
public struct LibrarySource: Hashable, Sendable {
    public let browseID: String
    public let holds: Set<MusicEntityKind>
    public let title: String
    /// Visible library membership goes stale after 15 minutes, visible history after 5 (SYNC03).
    public let staleAfter: TimeInterval
    /// Every row of a history is kept, in order; a library collection is the same.
    public let kind: MusicLibraryKind?
    public init(kind: MusicLibraryKind) {
        self.kind = kind; browseID = kind.browseID; holds = kind.holds; title = kind.title; staleAfter = 900
    }
    private init(browseID: String, holds: Set<MusicEntityKind>, title: String, staleAfter: TimeInterval) {
        kind = nil; self.browseID = browseID; self.holds = holds; self.title = title; self.staleAfter = staleAfter
    }
    /// One of the Uploads destination's three lists. Songs read the same page as the Library's Uploads collection.
    public static func uploads(_ kind: MusicUploadKind) -> LibrarySource {
        let title: String
        switch kind { case .songs: title = String(localized: "Uploaded songs"); case .albums: title = String(localized: "Uploaded albums"); case .artists: title = String(localized: "Uploaded artists") }
        return LibrarySource(browseID: kind.browseID, holds: kind.holds, title: title, staleAfter: 900)
    }
    public static let history = LibrarySource(browseID: MusicHistory.browseID, holds: [.song, .video, .episode], title: String(localized: "YouTube Music history"), staleAfter: 300)
}

public extension MusicLibraryKind {
    var title: String {
        switch self {
        case .songs: String(localized: "Songs")
        case .likedSongs: String(localized: "Liked Songs")
        case .albums: String(localized: "Albums")
        case .artists: String(localized: "Artists")
        case .following: String(localized: "Following")
        case .playlists: String(localized: "Playlists")
        case .podcasts: String(localized: "Podcasts")
        case .savedEpisodes: String(localized: "Saved Episodes")
        case .uploads: String(localized: "Uploads")
        }
    }
    var symbol: String {
        switch self {
        case .songs: "music.note"
        case .likedSongs: "heart"
        case .albums: "square.stack"
        case .artists: "person.2"
        case .following: "person.crop.circle.badge.checkmark"
        case .playlists: "music.note.list"
        case .podcasts: "mic"
        case .savedEpisodes: "bookmark"
        case .uploads: "arrow.up.circle"
        }
    }
    /// Albums, playlists, artists and shows read well as a grid; tracks and episodes as a list.
    var prefersGrid: Bool { [.albums, .artists, .following, .playlists, .podcasts].contains(self) }
    var emptyTitle: String {
        switch self {
        case .songs: String(localized: "No songs in your library yet")
        case .likedSongs: String(localized: "No liked songs yet")
        case .albums: String(localized: "No saved albums yet")
        case .artists: String(localized: "No artists in your library yet")
        case .following: String(localized: "You aren’t following anyone yet")
        case .playlists: String(localized: "No playlists yet")
        case .podcasts: String(localized: "No saved podcasts yet")
        case .savedEpisodes: String(localized: "No saved episodes yet")
        case .uploads: String(localized: "No uploads yet")
        }
    }
}

/// One row of a collection. `ordinal` is the position in the order the service sent; it never changes when the view is sorted.
public struct LibraryEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let ordinal: Int
    public let item: MusicCatalogItem
    /// The service's heading over this row (a history day), when the page had one.
    public let section: String?
    /// The same item also appears at an earlier ordinal; both rows are kept.
    public let repeats: Bool
    public var artistName: String? { item.links.first { $0.kind == .artist }?.title ?? (item.kind == .artist ? nil : item.details.first) }
}

public enum LibraryLayout: String, Sendable, CaseIterable { case list, grid }
/// How the view orders the rows it shows. `service` is the default and the only order the service defines; the others are a
/// view over the same rows and never touch `entries`.
public enum LibrarySort: String, Sendable, CaseIterable, Identifiable {
    case service, titleAscending, titleDescending, artist
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .service: String(localized: "Service order")
        case .titleAscending: String(localized: "Title (A–Z)")
        case .titleDescending: String(localized: "Title (Z–A)")
        case .artist: String(localized: "Artist")
        }
    }
    /// A stable sort: equal keys keep the service's order. Entries with no key for the sort follow the rest, in service order.
    public func apply(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        func compare(_ a: String, _ b: String) -> ComparisonResult { a.localizedStandardCompare(b) }
        switch self {
        case .service: return entries
        case .titleAscending: return entries.stableSorted { compare($0.item.title, $1.item.title) == .orderedAscending }
        case .titleDescending: return entries.stableSorted { compare($0.item.title, $1.item.title) == .orderedDescending }
        case .artist:
            let keyed = entries.filter { $0.artistName != nil }, unkeyed = entries.filter { $0.artistName == nil }
            return keyed.stableSorted { compare($0.artistName ?? "", $1.artistName ?? "") == .orderedAscending } + unkeyed
        }
    }
}
extension Array where Element == LibraryEntry {
    /// Sorting that keeps the service's order among equal keys regardless of the algorithm.
    func stableSorted(by areInIncreasingOrder: (LibraryEntry, LibraryEntry) -> Bool) -> [LibraryEntry] {
        sorted { a, b in
            if areInIncreasingOrder(a, b) { return true }
            if areInIncreasingOrder(b, a) { return false }
            return a.ordinal < b.ordinal
        }
    }
}

public enum LibraryFailure: Sendable, Equatable {
    case needsSignIn, sessionEnded, offline, rateLimited, unavailable, unrecognised, scopeChanged, notAvailableHere
    init(_ error: any Error) {
        switch error as? MusicSessionError {
        case .notSignedIn: self = .needsSignIn
        case .signedOut, .invalidSession: self = .sessionEnded
        case .network, .timedOut: self = .offline
        case .rateLimited: self = .rateLimited
        case .unrecognised, .oversized: self = .unrecognised
        case .policy: self = .notAvailableHere
        default: self = .unavailable
        }
    }
}

/// The distinct states a collection can be in (LIB01). Each reads differently and none stands in for another: an empty library is
/// not a failed read, an offline one is not a restricted one, and a stale one still shows its rows.
public enum LibraryViewState: Sendable, Equatable {
    /// Restricted: the collection needs an account that is not there (or whose session ended); nothing was read.
    case restricted(LibraryFailure)
    case loading
    /// Read completely and there is nothing in it.
    case empty
    /// A read failed and there is nothing to show. `saved` rows exist only when an earlier read succeeded (then `content` is used).
    case offline
    case unrecognised
    case failed(LibraryFailure)
    /// Rows exist but a typed query or the loaded part matches none of them.
    case noMatches
    /// Rows are shown. `stale` marks rows older than the freshness bound; `refreshFailed` marks rows that could not be refreshed.
    case content(stale: Bool, refreshFailed: LibraryFailure?)
}

/// One library or history collection: cached reading, complete incremental paging, search and sort over the loaded rows,
/// multi-selection, and the account-scope fence on every reply.
///
/// Rules this type keeps:
/// - `entries` is the service's order and is only ever appended to (or replaced by a refresh). Search, sort and layout are views;
///   none can change what `entries` holds, and nothing here writes anything to the service;
/// - paging reads every page: it stops only when the service offers no further token, when a token comes back unchanged, or when a
///   page repeats the previous one. A repeated row inside the service's order is kept (a song played twice is two rows). Only a row
///   carrying the service's own occurrence id that is already listed is a true duplicate, and it is counted;
/// - an unrecognised page is `unrecognised`, never an empty library; an entry of a kind this collection doesn't hold is counted
///   (`wrongKind`) and reported, never silently dropped;
/// - a reply for an older request or another account scope cannot replace what is shown.
@MainActor @Observable public final class LibraryCollectionModel {
    public typealias Reader = @Sendable (LibrarySource) async throws -> MusicBrowseReply<MusicBrowsePage>
    public typealias Continuer = @Sendable (String) async throws -> MusicBrowseReply<MusicContinuationPage>

    public let source: LibrarySource
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var phase: Phase = .idle
    public private(set) var fetchedAt: Date?
    public private(set) var isRefreshing = false
    public private(set) var refreshFailure: LibraryFailure?
    public private(set) var loadingMore = false
    public private(set) var moreFailure: LibraryFailure?
    /// Why paging stopped before the service stopped offering tokens.
    public private(set) var pagingEnded: CatalogPageModel.PagingEnd?
    public private(set) var accounting = MusicParseAccounting()
    public private(set) var wrongKind = 0
    public private(set) var occurrenceDuplicates = 0
    public private(set) var replayedPages = 0
    public var query = ""
    public var sort: LibrarySort = .service
    public var layout: LibraryLayout
    public var selection: Set<String> = []
    @ObservationIgnored private var tokens: [String] = []
    @ObservationIgnored private var lastPageIDs: [String] = []
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var cache: [String: Cached] = [:]
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let continuer: Continuer
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let maximumEntries: Int
    @ObservationIgnored private let maximumPages: Int
    @ObservationIgnored private let onItems: @MainActor ([MusicCatalogItem]) -> Void

    public enum Phase: Sendable, Equatable { case idle, loading, loaded, failed(LibraryFailure) }
    private struct Cached { let entries: [LibraryEntry]; let tokens: [String]; let fetchedAt: Date; let accounting: MusicParseAccounting; let wrongKind: Int; let lastPage: [String] }

    public init(source: LibrarySource, reader: @escaping Reader, continuer: @escaping Continuer, accountScope: @escaping @MainActor () -> String = { "" },
                now: @escaping @MainActor () -> Date = { Date() }, maximumEntries: Int = 20_000, maximumPages: Int = 400,
                onItems: @escaping @MainActor ([MusicCatalogItem]) -> Void = { _ in }) {
        self.source = source; self.reader = reader; self.continuer = continuer; self.accountScope = accountScope; self.now = now
        self.maximumEntries = maximumEntries; self.maximumPages = maximumPages; self.onItems = onItems
        layout = source.kind?.prefersGrid == true ? .grid : .list
    }

    // MARK: Derived

    public var isComplete: Bool { tokens.isEmpty }
    public var hasMore: Bool { !tokens.isEmpty }
    public var isStale: Bool { fetchedAt.map { now().timeIntervalSince($0) > source.staleAfter } ?? false }
    /// Entries read but not shown as rows: unreadable, a kind the app doesn't present, or a kind this collection doesn't hold.
    public var leftOut: Int { accounting.skipped + accounting.unsupported + wrongKind }
    /// Every parsed item is one of: a row, left out, or a counted duplicate. A test asserts this holds on every fixture.
    public var accountedFor: Bool { entries.count + leftOut + accounting.duplicates + occurrenceDuplicates + replayedItems == accounting.items }
    @ObservationIgnored private var replayedItems = 0
    /// Rows after search, then sort. A view over `entries`; never stored.
    public var visibleEntries: [LibraryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty ? entries : entries.filter { Self.matches($0, trimmed) }
        return sort.apply(filtered)
    }
    public var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Sorting or searching a collection that is still being read covers only what has been read.
    public var coversEverything: Bool { isComplete }
    public var availableSorts: [LibrarySort] {
        LibrarySort.allCases.filter { $0 != .artist || (entries.contains { $0.artistName != nil } && source.kind.map { ![.artists, .following, .playlists, .podcasts].contains($0) } ?? true) }
    }
    public var state: LibraryViewState {
        switch phase {
        case .idle where entries.isEmpty, .loading where entries.isEmpty: return .loading
        case .failed(let failure) where entries.isEmpty:
            switch failure {
            case .needsSignIn, .sessionEnded, .notAvailableHere: return .restricted(failure)
            case .offline: return .offline
            case .unrecognised: return .unrecognised
            default: return .failed(failure)
            }
        default: break
        }
        if entries.isEmpty { return hasMore ? .loading : .empty }
        if searching, visibleEntries.isEmpty { return .noMatches }
        return .content(stale: isStale, refreshFailed: refreshFailure)
    }
    static func matches(_ entry: LibraryEntry, _ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let needles = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let haystack = ([entry.item.title] + entry.item.details).joined(separator: " ")
        return needles.allSatisfy { haystack.range(of: $0, options: options) != nil }
    }

    // MARK: Loading

    /// The saved copy for this account scope is shown at once (labelled by `fetchedAt`); a stale one is refreshed in the same call.
    public func load() async {
        guard phase == .idle || phase.isFailed else { return }
        let scope = accountScope()
        if let saved = cache[scope] {
            entries = saved.entries; tokens = saved.tokens; fetchedAt = saved.fetchedAt; accounting = saved.accounting; wrongKind = saved.wrongKind; lastPageIDs = saved.lastPage
            phase = .loaded
            if isStale { await refresh() }
            return
        }
        phase = .loading
        await fetch(preserving: false)
    }
    public func refresh() async {
        guard phase != .idle else { return }
        await fetch(preserving: !entries.isEmpty)
    }
    /// The shell calls this when the active account (or whether its session is live) changes: nothing read for the old scope stays.
    public func accountChanged() {
        generation &+= 1
        entries = []; tokens = []; lastPageIDs = []; cache = [:]; selection = []; fetchedAt = nil; accounting = MusicParseAccounting()
        wrongKind = 0; occurrenceDuplicates = 0; replayedPages = 0; replayedItems = 0; pagingEnded = nil; refreshFailure = nil; moreFailure = nil
        loadingMore = false; isRefreshing = false
        phase = .idle
    }

    private func fetch(preserving: Bool, retried: Bool = false) async {
        generation &+= 1
        let ticket = generation, scope = accountScope()
        if preserving { isRefreshing = true } else { phase = .loading }
        defer { if ticket == generation { isRefreshing = false } }
        do {
            let reply = try await reader(source)
            guard ticket == generation, !Task.isCancelled else { return }
            guard accountScope() == scope else {
                if retried { fail(.scopeChanged, preserving: preserving) } else { await fetch(preserving: preserving, retried: true) }
                return
            }
            guard reply.mode == .signedIn else { fail(.needsSignIn, preserving: preserving); return }
            var rows: [LibraryEntry] = [], dropped = 0, wrong = 0, offered: [MusicCatalogItem] = []
            var seenOccurrences = Set<String>(), counts: [String: Int] = [:]
            for shelf in reply.value.shelves {
                for item in shelf.items {
                    guard source.holds.contains(item.kind) else { wrong += 1; continue }
                    if let occurrence = item.occurrenceID, !seenOccurrences.insert(occurrence).inserted { dropped += 1; continue }
                    rows.append(Self.entry(item, ordinal: rows.count, section: shelf.title, counts: &counts)); offered.append(item)
                }
            }
            let page = reply.value
            // A page whose entries were all of another kind or all unreadable is a layout we don't know, not an empty library.
            if rows.isEmpty, page.accounting.items > 0, page.accounting.classified == 0 || wrong == page.accounting.classified { fail(.unrecognised, preserving: preserving); return }
            let time = now()
            entries = rows; selection = selection.filter { id in rows.contains { $0.id == id } }
            tokens = Self.tokens(of: page.shelves.map(\.continuation) + [page.continuation])
            accounting = page.accounting; wrongKind = wrong; occurrenceDuplicates = dropped; replayedPages = 0; replayedItems = 0
            lastPageIDs = rows.map(\.item.id); pagingEnded = nil; moreFailure = nil
            fetchedAt = time; refreshFailure = nil; phase = .loaded
            cache[scope] = Cached(entries: entries, tokens: tokens, fetchedAt: time, accounting: accounting, wrongKind: wrongKind, lastPage: lastPageIDs)
            onItems(offered)
        } catch is CancellationError {
        } catch {
            guard ticket == generation else { return }
            if (error as? MusicSessionError) == .stale || (error as? MusicSessionError) == .cancelled { return }
            fail(LibraryFailure(error), preserving: preserving)
        }
    }
    private func fail(_ failure: LibraryFailure, preserving: Bool) {
        if preserving && !entries.isEmpty { refreshFailure = failure } else { phase = .failed(failure) }
    }
    private static func tokens(of candidates: [String?]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for token in candidates.compactMap({ $0 }) where seen.insert(token).inserted { result.append(token) }
        return result
    }
    /// A row's id is the item's id, with a counter when the same item already appears earlier (both rows are kept).
    private static func entry(_ item: MusicCatalogItem, ordinal: Int, section: String?, counts: inout [String: Int]) -> LibraryEntry {
        let earlier = counts[item.id, default: 0]
        counts[item.id] = earlier + 1
        return LibraryEntry(id: earlier == 0 ? item.id : item.id + "#\(earlier)", ordinal: ordinal, item: item, section: section, repeats: earlier > 0)
    }

    // MARK: Paging

    /// Reads the next page. A failure keeps the token, so asking again retries the same page.
    public func loadMore() async {
        guard let token = tokens.first, !loadingMore, entries.count < maximumEntries else { return }
        loadingMore = true; moreFailure = nil
        let ticket = generation, scope = accountScope()
        defer { loadingMore = false }
        do {
            let reply = try await continuer(token)
            guard ticket == generation, accountScope() == scope else { return }
            let page = reply.value
            var rows: [LibraryEntry] = [], dropped = 0, wrong = 0, offered: [MusicCatalogItem] = []
            var seen = Set(entries.compactMap(\.item.occurrenceID))
            var counts: [String: Int] = [:]
            for entry in entries { counts[entry.item.id, default: 0] += 1 }
            var ordinal = entries.count
            // Rows continuing a shelf stay under that shelf's heading; a new shelf in the answer brings its own.
            let lastSection = entries.last?.section
            let candidates = page.items.map { ($0, lastSection) } + page.shelves.flatMap { shelf in shelf.items.map { ($0, shelf.title ?? lastSection) } }
            for (item, section) in candidates {
                guard source.holds.contains(item.kind) else { wrong += 1; continue }
                if let occurrence = item.occurrenceID, !seen.insert(occurrence).inserted { dropped += 1; continue }
                rows.append(Self.entry(item, ordinal: ordinal, section: section, counts: &counts)); ordinal += 1; offered.append(item)
            }
            var remaining = Array(tokens.dropFirst())
            let next = Self.tokens(of: [page.continuation] + page.shelves.map(\.continuation))
            // A page that is exactly the previous one again is the service replaying it: nothing is added and paging for it ends.
            let pageIDs = rows.map(\.item.id)
            let replay = !pageIDs.isEmpty && pageIDs == lastPageIDs && dropped == 0
            let progressed = !rows.isEmpty && !replay
            if replay { replayedPages += 1; replayedItems += rows.count; rows = [] }
            else { entries.append(contentsOf: rows); lastPageIDs = pageIDs; onItems(offered) }
            wrongKind += wrong; occurrenceDuplicates += dropped
            accounting.add(page.accounting)
            if next.contains(token) { pagingEnded = .repeatedToken; remaining = [] }
            else if !progressed && !next.isEmpty { pagingEnded = .noNewEntries; remaining = [] }
            else { for token in next where !remaining.contains(token) { remaining.append(token) } }
            tokens = remaining
            cache[scope] = Cached(entries: entries, tokens: tokens, fetchedAt: fetchedAt ?? now(), accounting: accounting, wrongKind: wrongKind, lastPage: lastPageIDs)
        } catch is CancellationError {
        } catch {
            guard ticket == generation, (error as? MusicSessionError) != .stale else { return }
            moreFailure = LibraryFailure(error)
        }
    }
    /// Reads every remaining page (a collection is never assumed to fit in its first response). Stops on a failure, a bound, or
    /// when paging ends; returns whether the collection is now complete.
    @discardableResult public func loadAll() async -> Bool {
        var pages = 0
        while hasMore, moreFailure == nil, pages < maximumPages, entries.count < maximumEntries, !Task.isCancelled {
            let before = (entries.count, tokens)
            await loadMore()
            pages += 1
            if loadingMore { break }
            if before.0 == entries.count && before.1 == tokens { break }
        }
        return isComplete
    }

    // MARK: Selection (a view state: it never changes the collection)

    public func toggle(_ id: String) { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }
    public func selectAllVisible() { selection = Set(visibleEntries.map(\.id)) }
    public func clearSelection() { selection = [] }
    public var selectedEntries: [LibraryEntry] { entries.filter { selection.contains($0.id) } }
}
extension LibraryCollectionModel.Phase { var isFailed: Bool { if case .failed = self { true } else { false } } }
