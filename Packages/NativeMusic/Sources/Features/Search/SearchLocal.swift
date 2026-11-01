import AccountSession
import Foundation

/// A place search looks on this Mac. Sources are asked immediately on every keystroke
/// (no debounce), so they must answer from local data only.
@MainActor public protocol LocalSearchSource: AnyObject {
    /// Which scopes this source answers. `.all` always includes every source's results.
    var scopes: Set<SearchPlace> { get }
    func search(_ query: FoldedQuery, limit: Int) async -> [SearchResult]
    /// Titles whose words a respelling may be drawn from.
    func vocabulary() async -> [String]
}
public extension LocalSearchSource { func vocabulary() async -> [String] { [] } }

/// The signed-in account's library playlists, as the app already reads them (not an
/// offline copy). Matching is local and tolerant; the library may hold only the first
/// page the service returned, which the caller can read from `isComplete`.
@MainActor public final class LibraryPlaylistSearchSource: LocalSearchSource {
    public let scopes: Set<SearchPlace> = [.all, .library]
    private let playlists: @MainActor () -> [MusicLibraryPlaylist]
    public init(playlists: @escaping @MainActor () -> [MusicLibraryPlaylist]) { self.playlists = playlists }
    public func search(_ query: FoldedQuery, limit: Int) async -> [SearchResult] {
        playlists().compactMap { playlist in
            guard let quality = query.match(playlist.title) else { return nil }
            var badges: Set<SearchBadge> = [.library]
            if quality == .tolerant { badges.insert(.approximate) }
            return SearchResult(kind: .playlist, title: playlist.title, subtitle: playlist.countText, badges: badges,
                                target: SearchTarget(browseID: "VL" + playlist.id, playlistID: playlist.id), fromService: false, quality: quality)
        }.sorted(by: SearchRanking.order).prefix(limit).map { $0 }
    }
    public func vocabulary() async -> [String] { playlists().map(\.title) }
}
public enum SearchRanking {
    /// Better match first; ties alphabetical in the person's locale so the order is stable.
    public static func order(_ a: SearchResult, _ b: SearchResult) -> Bool {
        let (qa, qb) = (a.quality?.rawValue ?? 0, b.quality?.rawValue ?? 0)
        if qa != qb { return qa > qb }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}
