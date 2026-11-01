#if DEBUG
import AccountSession
import Features
import Foundation

/// Debug-only, labelled development data for the isolated UI tests: a small synthetic catalog behind the same reader
/// seam the service uses. It exists only when `YTMUSE_UI_DEVELOPMENT_DATA=1` is set on an isolated launch (the same gate as
/// `DevelopmentSearch`), the screens label it "Development data · Not YouTube Music", and no Release build contains it.
/// Nothing here is a capture of the service; the real shapes are tested against `Fixtures/W11-real`.
enum DevelopmentCatalog {
    static var enabled: Bool { DevelopmentSearch.enabled }

    static let artistID = "UCdevelopmentartist00000000"
    static let albumID = "MPREbdevelopment1"
    static let playlistID = "VLPLdevelopmentpl1"
    static let podcastID = "MPSPPLdevelopmentshow"
    /// A playlist long enough to need several screens of scrolling inside its one list shelf (W09-F2: Back from the middle of it).
    static let longPlaylistID = "VLPLdevelopmentlong1"
    static let longPlaylistLength = 150
    static let moodParams = "ggMPOg1uX1JOQWZFeDByc2Jm"
    /// The only token the development playlist hands out.
    static let playlistToken = "devplaylisttoken1"
    static let homeRefreshedKey = "home-refreshed"

    private static func song(_ title: String, _ video: String, artist: String = "Development Artist", position: String? = nil, duration: String? = nil,
                             explicit: Bool = false, unavailable: Bool = false, occurrence: String? = nil, context: String? = nil) -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: title, details: [artist, "Development Album"], explicit: explicit, availability: unavailable ? .unavailable : .available,
                         videoID: video, contextPlaylistID: context, links: [MusicLink(kind: .artist, title: artist, browseID: artistID), MusicLink(kind: .album, title: "Development Album", browseID: albumID)],
                         position: position, durationText: duration, occurrenceID: occurrence)
    }
    private static let album = MusicCatalogItem(kind: .album, title: "Development Album", details: ["Development Artist"], serviceLabel: "Album", browseID: albumID,
                                                playlistID: "OLAK5uydevelopment1", links: [MusicLink(kind: .artist, title: "Development Artist", browseID: artistID)])
    private static let single = MusicCatalogItem(kind: .album, title: "Sin Camino", details: ["2021"], serviceLabel: "Single", browseID: "MPREbdevelopment2", playlistID: "OLAK5uydevelopment2")
    private static let artist = MusicCatalogItem(kind: .artist, title: "Development Artist", details: ["1M monthly audience"], browseID: artistID)
    private static let playlist = MusicCatalogItem(kind: .playlist, title: "Café Collection (development)", details: ["Development"], serviceLabel: "Playlist", browseID: playlistID, playlistID: "PLdevelopmentpl1")
    private static let longPlaylist = MusicCatalogItem(kind: .playlist, title: "Long Playlist (development)", details: ["Development"], serviceLabel: "Playlist", browseID: longPlaylistID, playlistID: "PLdevelopmentlong1")
    private static let show = MusicCatalogItem(kind: .podcast, title: "Cafe Talk (development)", details: ["Development Host"], serviceLabel: "Podcast", browseID: podcastID, playlistID: "PLdevelopmentshow")
    private static let mood = MusicCatalogItem(kind: .category, title: "Chill", browseID: "FEmusic_moods_and_genres_category", browseParams: moodParams)

    private static func shelf(_ title: String, _ layout: MusicShelf.Layout, _ items: [MusicCatalogItem], more: MusicLink? = nil, continuation: String? = nil, rows: Int? = nil) -> MusicShelf {
        MusicShelf(key: "\(layout.rawValue):\(title)", title: title, layout: layout, items: items, more: more, continuation: continuation, rowsPerColumn: rows)
    }
    private static func page(heading: String? = nil, header: MusicPageHeader? = nil, chips: [MusicChip] = [], shelves: [MusicShelf], continuation: String? = nil) -> MusicBrowsePage {
        var accounting = MusicParseAccounting()
        accounting.sections = shelves.count; accounting.shelves = shelves.count
        accounting.items = shelves.reduce(0) { $0 + $1.items.count }; accounting.classified = accounting.items
        return MusicBrowsePage(heading: heading, header: header, chips: chips, shelves: shelves, continuation: continuation, accounting: accounting)
    }
    private static func link(_ host: String, _ path: String, scheme: String = "https") -> URL? {
        var components = URLComponents(); components.scheme = scheme; components.host = host; components.path = path
        return components.url
    }
    /// A biography that exercises the rich-text rules: literal markup, an executable link target, and a licence line.
    private static let description: [MusicTextRun] = [
        MusicTextRun(text: "A development biography with <b>markup</b> and a <script>alert(1)</script> tag that stay literal text. "),
        MusicTextRun(text: "A link that must not run", url: URL(string: "javascript:alert(1)")),
        MusicTextRun(text: ". " + String(repeating: "More development words to make this description long enough to be bounded. ", count: 12) + "\n\nFrom Wikipedia ("),
        MusicTextRun(text: "en.wikipedia.org/wiki/Development", url: link("en.wikipedia.org", "/wiki/Development")),
        MusicTextRun(text: ") under Creative Commons Attribution CC-BY-SA 3.0 ("),
        MusicTextRun(text: "creativecommons.org/licenses/...", url: link("creativecommons.org", "/licenses/by-sa/3.0/legalcode", scheme: "http")),
        MusicTextRun(text: ")"),
    ]

    static func pages() -> [String: MusicBrowsePage] {
        let tracks = [song("Café del Mar", "devsong0001", position: "1", duration: "3:45", occurrence: "o1", context: "OLAK5uydevelopment1"),
                      song("Noche Cálida", "devsong0002", position: "2", duration: "4:02", explicit: true, occurrence: "o2", context: "OLAK5uydevelopment1"),
                      song("Sin Permiso", "devsong0003", position: "3", duration: "2:58", unavailable: true, occurrence: "o3", context: "OLAK5uydevelopment1")]
        var result: [String: MusicBrowsePage] = [:]
        let quickPicks = shelf("Quick picks", .list, [song("Café del Mar", "devsong0001"), song("Noche Cálida", "devsong0002", explicit: true)], rows: 2)
        let releases = shelf("New releases", .carousel, [album, single], more: MusicLink(kind: .other, title: "New releases", browseID: "FEmusic_new_releases_albums"))
        let featured = shelf("Featured playlists", .carousel, [playlist, show])
        let daily = shelf("Daily mixes", .carousel, [MusicCatalogItem(kind: .playlist, title: "Daily mix 1 (development)", details: ["Development"], serviceLabel: "Mix", browseID: "VLPLdevelopmentmix1", playlistID: "PLdevelopmentmix1")])
        let chips = [MusicChip(title: "Relax", browseID: "FEmusic_home", params: "devchip1", selected: false)]
        // The first read of Home. A refresh gets `homeRefreshed`: a different arrangement, so a test can tell whether what the listener
        // is looking at stayed where it was (a shelf above is dropped, a new one arrives, entries inside a shelf change).
        result[CatalogTarget.home.key] = page(chips: chips, shelves: [quickPicks, releases, featured, daily])
        let newReleases2 = shelf("New releases", .carousel, [single, MusicCatalogItem(kind: .album, title: "Fresh Album (development)", details: ["Development Artist"], serviceLabel: "Album", browseID: "MPREbdevelopment9", playlistID: "OLAK5uydevelopment9")],
                                 more: MusicLink(kind: .other, title: "New releases", browseID: "FEmusic_new_releases_albums"))
        result[homeRefreshedKey] = page(chips: chips, shelves: [shelf("Fresh arrivals", .carousel, [album]), newReleases2, featured, daily])
        result[CatalogTarget.explore.key] = page(shelves: [
            shelf("", .categories, [MusicCatalogItem(kind: .category, title: "New releases", browseID: "FEmusic_new_releases"),
                                    MusicCatalogItem(kind: .category, title: "Charts", browseID: "FEmusic_charts"),
                                    MusicCatalogItem(kind: .category, title: "Moods & genres", browseID: "FEmusic_moods_and_genres")]),
            shelf("New albums & singles", .carousel, [album, single]),
            shelf("Top artists", .list, [artist]),
            shelf("Long playlist", .carousel, [longPlaylist])])
        result[CatalogTarget.newReleases.key] = page(heading: "New releases", shelves: [shelf("Albums & singles", .carousel, [album, single])])
        result[CatalogTarget.charts.key] = page(heading: "Charts", shelves: [shelf("Top artists", .list, [MusicCatalogItem(kind: .artist, title: "Development Artist", details: ["1M subscribers"], browseID: artistID, position: "1")])])
        result[CatalogTarget.moodsAndGenres.key] = page(heading: "Moods & genres", shelves: [shelf("Moods & moments", .categories, [mood])])
        result[CatalogTarget(browseID: "FEmusic_moods_and_genres_category", params: moodParams).key] = page(heading: "Chill", shelves: [shelf("Chill playlists", .carousel, [playlist])])
        result[CatalogTarget(browseID: artistID).key] = page(
            header: MusicPageHeader(title: "Development Artist", description: description, audienceText: "1M monthly audience",
                                    actions: MusicPageActions(shuffle: "RDAOdevelopmentshuffle", shuffleParams: "wAEB8gECGAE%3D", radio: "RDEMdevelopmentradio", offersFollow: true)),
            shelves: [shelf("Top songs", .list, tracks.map { song($0.title, $0.videoID!) }), shelf("Albums", .carousel, [album]), shelf("Singles & EPs", .carousel, [single]),
                      shelf("Fans might also like", .carousel, [artist])])
        result[CatalogTarget(browseID: albumID).key] = page(
            header: MusicPageHeader(title: "Development Album", subtitle: ["Album", "2019"], secondSubtitle: ["3 songs", "11 minutes"],
                                    credits: [MusicLink(kind: .artist, title: "Development Artist", browseID: artistID)], description: description,
                                    actions: MusicPageActions(play: "OLAK5uydevelopment1", shuffle: "OLAK5uydevelopment1", shuffleParams: "wAEB8gECKAE%3D", radio: "RDAMPLOLAK5uydevelopment1", offersSave: true)),
            shelves: [MusicShelf(key: "list:", title: nil, layout: .list, items: tracks),
                      shelf("Other versions", .carousel, [MusicCatalogItem(kind: .album, title: "Development Album (Deluxe)", details: ["Development Artist"], serviceLabel: "Album",
                                                                              browseID: "MPREbdevelopment3", playlistID: "OLAK5uydevelopment3")])])
        let playlistTracks = (1...4).map { song("List song \($0)", "devlist000\($0)", artist: "Development Artist", occurrence: "p\($0)") }
        result[CatalogTarget(browseID: playlistID).key] = page(
            header: MusicPageHeader(title: "Café Collection (development)", subtitle: ["Playlist", "2024"], secondSubtitle: ["8 tracks"], byline: "Development Curator",
                                    actions: MusicPageActions(play: "PLdevelopmentpl1", shuffle: "PLdevelopmentpl1", shuffleParams: "wAEB8gECKAE%3D", radio: "RDAMPLPLdevelopmentpl1", offersSave: true)),
            shelves: [MusicShelf(key: "PLdevelopmentpl1", title: nil, layout: .list, items: playlistTracks)], continuation: playlistToken)
        let longTracks = (1...longPlaylistLength).map { n in
            song("Long song \(String(format: "%03d", n))", "devlong" + String(format: "%03d", n), artist: "Development Artist", occurrence: "l" + String(format: "%03d", n))
        }
        result[CatalogTarget(browseID: longPlaylistID).key] = page(
            header: MusicPageHeader(title: "Long Playlist (development)", subtitle: ["Playlist", "2024"], secondSubtitle: ["\(longPlaylistLength) tracks"], byline: "Development Curator"),
            shelves: [MusicShelf(key: "PLdevelopmentlong1", title: nil, layout: .list, items: longTracks)])
        result[CatalogTarget(browseID: podcastID).key] = page(
            header: MusicPageHeader(title: "Cafe Talk (development)", credits: [MusicLink(kind: .other, title: "Development Host", browseID: "UCdevelopmenthost0000000")],
                                    description: [MusicTextRun(text: "A development show about coffee.")], actions: MusicPageActions(offersSave: true)),
            shelves: [MusicShelf(key: "list:", title: nil, layout: .list, items: DevelopmentPodcasts.episodes)])
        return result
    }
    /// The one continuation the development playlist hands out: one repeated boundary track and two new ones.
    static func continuation(_ token: String) -> MusicContinuationPage? {
        guard token == playlistToken else { return nil }
        let items = [song("List song 4", "devlist0004", occurrence: "p4"), song("List song 5", "devlist0005", occurrence: "p5"), song("List song 6", "devlist0006", occurrence: "p6")]
        var accounting = MusicParseAccounting()
        accounting.items = 3; accounting.classified = 3
        return MusicContinuationPage(items: items, shelves: [], continuation: nil, accounting: accounting)
    }

    /// Home is read at launch (and again when the account scope settles, within a second or two). Reads at least five seconds after
    /// the first are a later refresh and get the different arrangement, so a UI test can tell whether what the listener is looking at
    /// stayed where it was.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Double?
        func isLaterRefresh() -> Bool {
            lock.withLock {
                let now = ProcessInfo.processInfo.systemUptime
                guard let first else { first = now; return false }
                return now - first >= 5
            }
        }
    }
    private static let reads = Reads()
    @Sendable static func reader(_ target: CatalogTarget) async throws -> MusicBrowseReply<MusicBrowsePage> {
        // The development playlists (W13) answer for their own pages when their own flag is set; every other page is as before.
        if DevelopmentPlaylists.enabled, target.browseID.hasPrefix("VLPLdev"), let page = await DevelopmentPlaylists.shared.page(for: target.browseID) {
            return MusicBrowseReply(value: page, mode: .signedIn, accountGeneration: 0)
        }
        let all = pages()
        let key = (target == .home && reads.isLaterRefresh()) ? homeRefreshedKey : target.key
        guard let page = all[key] else { throw MusicSessionError.unrecognised }
        return MusicBrowseReply(value: page, mode: .anonymous, accountGeneration: 0)
    }
    @Sendable static func continuer(_ token: String) async throws -> MusicBrowseReply<MusicContinuationPage> {
        guard let page = continuation(token) else { throw MusicSessionError.unrecognised }
        return MusicBrowseReply(value: page, mode: .anonymous, accountGeneration: 0)
    }
}
#endif
