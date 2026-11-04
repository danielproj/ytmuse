#if DEBUG
import AccountSession
import Features
import Foundation

/// Debug-only, labelled development data for the isolated UI tests of the Library and History screens, behind the same reader and
/// writer seams the service uses. It exists only when `YTMUSE_UI_DEVELOPMENT_DATA=1`, `YTMUSE_UI_DEVELOPMENT_LIBRARY=1` and QA isolation
/// are all set, the screens label it "Development data · Not YouTube Music", and no Release build contains it. It is not a capture
/// of the service, it performs no network request, and its writer changes nothing anywhere: it only answers like a service would.
enum DevelopmentLibrary {
    static var enabled: Bool { isEnabled(ProcessInfo.processInfo.environment) }
    static func isEnabled(_ environment: [String: String]) -> Bool {
        DevelopmentSearch.isEnabled(environment) && environment["YTMUSE_UI_DEVELOPMENT_LIBRARY"] == "1"
    }
    /// The one account key local development history belongs to.
    static let accountKey = "00000000-0000-4000-8000-000000000012"
    static let songsToken = "devsongs2"
    static let artistA = "UCdevfollowartist0000001", artistB = "UCdevfollowartist0000002"

    private static func song(_ title: String, _ video: String, artist: String = "Development Artist", like: MusicLikeStatus = .indifferent, dislike: Bool = true,
                             saved: MusicItemControls.SongLibrary? = nil, duration: String? = "3:30") -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: title, details: [artist, "Development Album"], videoID: video,
                         links: [MusicLink(kind: .artist, title: artist, browseID: "UCdevelopmentartist00000000"), MusicLink(kind: .album, title: "Development Album", browseID: "MPREbdevelopment1")],
                         durationText: duration, controls: MusicItemControls(like: .init(videoID: video, status: like, dislikeExposed: dislike), songLibrary: saved))
    }
    /// A saved album card that publishes its own save toggle (state and target), as a signed card does; one that published none offers none.
    private static func album(_ title: String, _ id: String, artist: String = "Development Artist") -> MusicCatalogItem {
        MusicCatalogItem(kind: .album, title: title, details: [artist], serviceLabel: "Album", browseID: "MPREb" + id, playlistID: "OLAK5uy" + id,
                         links: [MusicLink(kind: .artist, title: artist, browseID: "UCdevelopmentartist00000000")],
                         controls: MusicItemControls(save: .init(playlistID: "OLAK5uy" + id, isSaved: true)))
    }
    private static func shelf(_ title: String?, _ layout: MusicShelf.Layout, _ items: [MusicCatalogItem], continuation: String? = nil) -> MusicShelf {
        MusicShelf(key: "\(layout.rawValue):\(title ?? "")", title: title, layout: layout, items: items, continuation: continuation)
    }
    private static func page(_ shelves: [MusicShelf]) -> MusicBrowsePage {
        var accounting = MusicParseAccounting()
        accounting.sections = shelves.count; accounting.shelves = shelves.count
        accounting.items = shelves.reduce(0) { $0 + $1.items.count }; accounting.classified = accounting.items
        return MusicBrowsePage(shelves: shelves, accounting: accounting)
    }
    static func pages() -> [String: MusicBrowsePage] {
        var result: [String: MusicBrowsePage] = [:]
        // Songs: the same song twice in a row (both kept), a rating the writer refuses, one it cannot confirm, and a second page.
        let first = [song("Café del Mar", "devsong0001"), song("Café del Mar", "devsong0001"), song("Noche Cálida", "devsong0002"), song("Zeta Song", "devsong0003", artist: "Another Artist")]
        result[MusicLibraryKind.songs.browseID] = page([shelf(nil, .list, first, continuation: songsToken)])
        result[MusicLibraryKind.likedSongs.browseID] = page([shelf(nil, .list, [])])
        result[MusicLibraryKind.albums.browseID] = page([shelf(nil, .grid, [album("Development Album", "development1"), album("Sin Camino", "development2"), album("Zeta Album", "development3", artist: "Another Artist")])])
        result[MusicLibraryKind.following.browseID] = page([shelf(nil, .list, [
            MusicCatalogItem(kind: .artist, title: "Development Artist", details: ["1M subscribers"], browseID: artistA),
            MusicCatalogItem(kind: .artist, title: "Another Artist", details: ["2K subscribers"], browseID: artistB)])])
        result[MusicLibraryKind.podcasts.browseID] = page([shelf(nil, .grid, [MusicCatalogItem(kind: .podcast, title: "Cafe Talk (development)", details: ["Development Host"], browseID: "MPSPPLdevelopmentshow", playlistID: "PLdevelopmentshow")])])
        result[MusicHistory.browseID] = page([
            shelf("Today", .list, [song("Café del Mar", "devsong0001"), song("Café del Mar", "devsong0001")]),
            shelf("Yesterday", .list, [song("Noche Cálida", "devsong0002")])])
        return result
    }
    static func continuation(_ token: String) -> MusicContinuationPage? {
        guard token == songsToken else { return nil }
        let items = [song("Late Song", "devsong0004"), song("Last Song", "devsong0005")]
        var accounting = MusicParseAccounting()
        accounting.items = items.count; accounting.classified = items.count
        return MusicContinuationPage(items: items, shelves: [], continuation: nil, accounting: accounting)
    }
    @Sendable static func reader(_ source: LibrarySource) async throws -> MusicBrowseReply<MusicBrowsePage> {
        // W44-prep: with the synthetic performance flag the songs and playlists collections are the PERF04 stress dataset (the rest is as before).
        if DevelopmentPerformance.enabled, let page = DevelopmentPerformance.libraryPage(for: source.kind) { return MusicBrowseReply(value: page, mode: .signedIn, accountGeneration: 0) }
        // With the development playlists' own flag the Playlists collection lists them (W13); without it everything is as in W12.
        if DevelopmentPlaylists.enabled, source.kind == .playlists { return MusicBrowseReply(value: await DevelopmentPlaylists.shared.libraryPage(), mode: .signedIn, accountGeneration: 0) }
        switch source.kind {
        case .artists?: throw MusicSessionError.network            // offline
        case .playlists?: throw MusicSessionError.unrecognised     // a page this version cannot read
        case .savedEpisodes?: throw MusicSessionError.signedOut    // restricted: the session ended
        default: break
        }
        guard let page = pages()[source.browseID] else { throw MusicSessionError.unrecognised }
        return MusicBrowseReply(value: page, mode: .signedIn, accountGeneration: 0)
    }
    @Sendable static func continuer(_ token: String) async throws -> MusicBrowseReply<MusicContinuationPage> {
        guard let page = (DevelopmentPerformance.enabled ? DevelopmentPerformance.continuation(token) : nil) ?? continuation(token) else { throw MusicSessionError.unrecognised }
        return MusicBrowseReply(value: page, mode: .signedIn, accountGeneration: 0)
    }
    /// Answers like a service: slowly enough for the pending state to be seen, refusing one rating and leaving one unconfirmed.
    @Sendable static func writer(_ request: MusicWriteRequest) async throws -> MusicWriteReply {
        try await Task.sleep(for: .milliseconds(2000))
        let outcome: MusicWriteOutcome
        switch request {
        case .rate(let video, _) where video == "devsong0002": outcome = .rejected(.service)
        case .rate(let video, _) where video == "devsong0003": outcome = .indeterminate(.noAnswer)
        default: outcome = .confirmed
        }
        return MusicWriteReply(outcome: outcome, accountGeneration: 0)
    }
}

/// An in-memory local history for the development screens: two plays, clearable. Never touches a file.
actor DevelopmentLocalHistory: LocalHistoryStoring {
    private var records: [LocalHistoryRecord] = [
        LocalHistoryRecord(videoID: "devsong0001", title: "Café del Mar", artist: "Development Artist", startedAt: Date(timeIntervalSince1970: 1_700_000_000), listenedSeconds: 40),
        LocalHistoryRecord(videoID: "devsong0002", title: "Noche Cálida", artist: "Development Artist", startedAt: Date(timeIntervalSince1970: 1_700_003_600), listenedSeconds: 31),
    ]
    func append(_ record: LocalHistoryRecord, account: String) { records.insert(record, at: 0) }
    func recent(account: String, limit: Int) -> [LocalHistoryRecord] { Array(records.prefix(limit)) }
    func update(_ record: LocalHistoryRecord, account: String) { if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record } }
    func clear(account: String) { records = [] }
}
#endif
