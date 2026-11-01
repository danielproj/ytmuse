import AccountSession
import Foundation

/// The page reads a playlist snapshot is built from. Production wires the account coordinator's signed `browse` and `continuation`.
public struct PlaylistPageSource: Sendable {
    public let page: @Sendable (_ browseID: String) async throws -> MusicBrowsePage
    public let continuation: @Sendable (_ token: String) async throws -> MusicContinuationPage
    public init(page: @escaping @Sendable (String) async throws -> MusicBrowsePage, continuation: @escaping @Sendable (String) async throws -> MusicContinuationPage) {
        self.page = page; self.continuation = continuation
    }
}

/// Reads a whole playlist into a `PlaylistSnapshot`.
///
/// - **Tracks come only from the track shelf and its own continuation.** The page's section-list continuation is not "more tracks": on a
///   playlist it reloads the *suggestions* (and related) that follow the track list (ytmusicapi `get_playlist`, 4da34b6), so it is never
///   followed here; it is kept as `suggestionsToken` for `readSuggestions`. A playlist whose shelf names no continuation was read to its
///   end, however long the page's other tokens are.
/// - The occurrence id is the identity: a row the service repeats (a page that overlaps the previous one, or a read that restarted) is
///   kept once, and the same song twice with two ids is kept twice. A suggestion row's placeholder id (`to_be_updated_by_client`) is
///   not an occurrence and never becomes a member.
/// - A continuation the service no longer honours (it answers with something unreadable) restarts the read from the first page, a
///   bounded number of times. If it still cannot be completed, what was read is returned marked incomplete, never as the whole.
/// - A token that repeats, or a page that adds nothing new, ends the walk (a bound against a service that never stops).
/// - A command or header that names another playlist than the one read is not trusted (a row is not removable, the page is not editable).
public enum PlaylistSnapshotReader {
    public static let maximumPages = 200
    public static let maximumRestarts = 2
    public static let maximumOccurrences = 5_000
    public static let maximumSuggestionPages = 3

    public static func read(playlistID: String, source: PlaylistPageSource) async throws -> PlaylistSnapshot {
        var restarts = 0
        while true {
            do { return try await walk(playlistID: playlistID, source: source) }
            catch is ExpiredCursor {
                restarts += 1
                if restarts > maximumRestarts { return try await firstPageOnly(playlistID: playlistID, source: source) }
            }
        }
    }

    /// The service's suggested songs for an editable playlist: a bounded read of the section-list token, kept apart from the members. A
    /// failure to read them is the caller's to show; it never affects the tracks.
    public static func readSuggestions(token: String, source: PlaylistPageSource) async throws -> [MusicCatalogItem] {
        var items: [MusicCatalogItem] = [], seenTokens: Set<String> = [], next: String? = token, pages = 0
        while let current = next, pages < maximumSuggestionPages, seenTokens.insert(current).inserted, items.count < 50 {
            pages += 1
            let more = try await source.continuation(current)
            items += (more.items + more.shelves.flatMap(\.items)).filter { ($0.kind == .song || $0.kind == .video) && $0.videoID != nil }
            next = more.continuation ?? more.shelves.compactMap(\.continuation).first
        }
        var seen = Set<String>()
        return Array(items.filter { seen.insert($0.videoID ?? "").inserted }.prefix(50))
    }

    private struct ExpiredCursor: Error {}

    private static func walk(playlistID: String, source: PlaylistPageSource) async throws -> PlaylistSnapshot {
        let page = try await source.page("VL" + playlistID)
        var snapshot = base(playlistID: playlistID, page: page)
        var seen = Set(snapshot.occurrences.map(\.setVideoID))
        var tokens = Set<String>()
        var next = playlistShelf(page, playlistID: playlistID)?.continuation
        var pages = 1, stopped = false
        while let token = next {
            guard tokens.insert(token).inserted, pages < maximumPages, snapshot.occurrences.count < maximumOccurrences else { stopped = true; break }
            pages += 1
            let more: MusicContinuationPage
            do { more = try await source.continuation(token) }
            catch MusicSessionError.unrecognised { throw ExpiredCursor() }
            var fresh = 0
            for item in more.items + more.shelves.flatMap(\.items) {
                guard let occurrence = occurrence(from: item, playlistID: playlistID, editable: snapshot.editing?.canEditTracks == true) else {
                    if isMemberRowWithoutAnId(item) { snapshot.unaddressableCount += 1 }
                    continue
                }
                if seen.insert(occurrence.setVideoID).inserted { snapshot.occurrences.append(occurrence); fresh += 1 }
            }
            next = more.continuation ?? more.shelves.compactMap(\.continuation).first
            if fresh == 0, next != nil, more.items.isEmpty, more.shelves.isEmpty { stopped = true; break }
        }
        snapshot.isComplete = !stopped
        return snapshot
    }
    /// After the restarts are used up: the first page alone, honestly incomplete.
    private static func firstPageOnly(playlistID: String, source: PlaylistPageSource) async throws -> PlaylistSnapshot {
        var snapshot = base(playlistID: playlistID, page: try await source.page("VL" + playlistID))
        snapshot.isComplete = false
        return snapshot
    }

    /// The playlist's own shelf: the first shelf holding any occurrence-bearing row, else the shelf the page keys by this playlist's id
    /// (an empty playlist's). Any other shelf is the service's suggestions or related items, never members.
    private static func playlistShelf(_ page: MusicBrowsePage, playlistID: String) -> MusicShelf? {
        page.shelves.first { shelf in shelf.items.contains { $0.occurrenceID.map(MusicPlaylistRequest.isOccurrenceID) == true } }
            ?? page.shelves.first { $0.key.contains(playlistID) }
    }
    /// A song row of the playlist's own shelf that carries no usable occurrence id (a suggestion row's placeholder is not one).
    private static func isMemberRowWithoutAnId(_ item: MusicCatalogItem) -> Bool { item.kind == .song || item.kind == .video }
    private static func occurrence(from item: MusicCatalogItem, playlistID: String, editable: Bool) -> PlaylistOccurrence? {
        guard item.kind == .song || item.kind == .video, let set = item.occurrenceID, MusicPlaylistRequest.isOccurrenceID(set), let video = item.videoID else { return nil }
        let removal = item.controls?.playlistRemoval
        let removable = editable && removal?.setVideoID == set && removal?.videoID == video && removal?.playlistID == playlistID
        return PlaylistOccurrence(setVideoID: set, videoID: video, title: item.title, subtitle: item.details.isEmpty ? nil : item.details.joined(separator: " • "),
                                  isAvailable: item.availability != .unavailable, removable: removable)
    }
    private static func base(playlistID: String, page: MusicBrowsePage) -> PlaylistSnapshot {
        let header = page.header
        // An editable header that names another playlist is not this playlist's.
        var editing = header?.editing
        if let named = editing?.playlistID, named != playlistID { editing = nil }
        var snapshot = PlaylistSnapshot(playlistID: playlistID, title: header?.title ?? page.heading ?? "", details: (header?.description ?? []).map(\.text).joined(),
                                        privacy: editing?.privacy, occurrences: [], editing: editing, isSaved: header?.actions.controls.save?.isSaved)
        let shelf = playlistShelf(page, playlistID: playlistID)
        var seen = Set<String>()
        for item in shelf?.items ?? [] {
            guard let occurrence = occurrence(from: item, playlistID: playlistID, editable: editing?.canEditTracks == true) else {
                if isMemberRowWithoutAnId(item) { snapshot.unaddressableCount += 1 }
                continue
            }
            if seen.insert(occurrence.setVideoID).inserted { snapshot.occurrences.append(occurrence) }
        }
        let others = page.shelves.filter { $0.key != shelf?.key }
        snapshot.suggestions = Array(others.flatMap(\.items).filter { ($0.kind == .song || $0.kind == .video) && $0.videoID != nil }.prefix(20))
        // The section list's own token reloads the suggestions, and only an editable playlist has any to read.
        snapshot.suggestionsToken = editing?.canEditTracks == true ? page.continuation : nil
        snapshot.isComplete = shelf?.continuation == nil
        return snapshot
    }
}
