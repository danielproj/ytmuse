import AccountSession
import Foundation
import Testing
@testable import YouTubeMusicAdapter
@testable import Features

/// W09-F2 rework 2: what a catalog page registers for identity restore, and in which order. The page registers rows from `CatalogRows`, the
/// same function `ShelfView` draws them from, so the row recorded as "first on screen" is the first one the person sees.
@MainActor @Suite struct CatalogRowRegistrationTests {
    private func surface() async -> PodcastsSurface {
        let (playback, _, _, _) = await makeModel()
        return PodcastsSurface(playback: playback, lyrics: LyricsModel(reader: { _ in throw MusicSessionError.policy }), follow: LyricsFollowModel(), ledger: nil,
                               reader: { _ in throw MusicSessionError.policy }, starter: { _ in .started })
    }
    private func shelf(_ key: String, _ layout: MusicShelf.Layout, _ items: [MusicCatalogItem], rows: Int? = nil) -> MusicShelf {
        MusicShelf(key: key, title: nil, layout: layout, items: items, rowsPerColumn: rows)
    }
    private func song(_ n: Int) -> MusicCatalogItem { MusicCatalogItem(kind: .song, title: "Song \(n)", videoID: "vid\(n)", occurrenceID: "o\(n)") }

    @Test func aVerticalListShelfRegistersItsRowsAndCarouselsAndColumnsDoNot() async {
        let list = shelf("list", .list, (1...3).map(song)), carousel = shelf("carousel", .carousel, [song(4)]), columns = shelf("columns", .list, (5...8).map(song), rows: 2)
        let registration = CatalogRows.registration(of: [list, carousel, columns], podcasts: await surface(), pageReadAt: Date())
        #expect(registration.order == ["list", "list|o1", "list|o2", "list|o3", "carousel", "columns"], "a page that registers no rows would restore only to its shelf")
        #expect(registration.parents == ["list|o1": "list", "list|o2": "list", "list|o3": "list"])
    }
    @Test func aShelfWithNothingToShowIsNotRegistered() async {
        let registration = CatalogRows.registration(of: [shelf("empty", .list, [])], podcasts: nil, pageReadAt: Date())
        #expect(registration.order.isEmpty)
    }
    @Test func aShowRegistersItsEpisodesInTheOrderThePersonChoseNotTheServicesOrder() async throws {
        let surface = await surface()
        let episodes = try MusicBrowseParser.parse(try real(.show)).shelves.flatMap(\.items).filter { $0.kind == .episode }
        try #require(episodes.count > 2)
        let show = shelf("episodes", .list, episodes)
        #expect(CatalogRows.drawn(show, podcasts: surface, pageReadAt: Date()) == episodes, "the show's own order by default")
        surface.episodeSort = .titleDescending
        let drawn = CatalogRows.drawn(show, podcasts: surface, pageReadAt: Date())
        #expect(drawn != episodes && Set(drawn.map(\.id)) == Set(episodes.map(\.id)), "a non-default sort reorders the rows")
        let registration = CatalogRows.registration(of: [show], podcasts: surface, pageReadAt: Date())
        #expect(registration.order == ["episodes"] + drawn.map { CatalogRows.rowItem(show, $0) },
                "the restorer is told the rows in the order they are drawn; otherwise the 'first row on screen' is the first in the SERVICE's order, which can be any visible row")
    }
}
