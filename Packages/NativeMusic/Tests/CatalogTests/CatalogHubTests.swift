import AccountSession
import Artwork
import Features
import Foundation
import Testing
@testable import AppShell

/// The app side: routes, model reuse, search opening, the development gate.
@MainActor @Suite struct CatalogHubTests {
    private func hub(scope: Box<String> = Box("s"), development: Bool = false) -> CatalogHub {
        let script = ServiceScript()
        return CatalogHub(artwork: CatalogArtwork(pipeline: nil, authority: ArtworkUIAuthority(), source: nil), development: development,
                          reader: { try await script.page($0) }, continuer: { try await script.token($0) }, scope: { scope.value }, playback: { .available }, performer: nil)
    }
    private func entry(_ destination: BrowserDestination, _ item: NativeItemRoute? = nil) -> BrowserEntry { BrowserEntry(destination: destination, item: item) }

    @Test func homeAndExploreHaveModelsAndOtherDestinationsDoNot() {
        let hub = hub()
        let home = entry(.home), explore = entry(.explore)
        #expect(hub.model(for: home)?.target == .home && hub.model(for: explore)?.target == .explore)
        for other in [BrowserDestination.library, .downloads, .history, .uploads, .podcasts, .queue, .nowPlaying, .search] { #expect(hub.model(for: entry(other)) == nil, "\(other)") }
    }
    @Test func theSameEntryKeepsItsModelSoBackReturnsToTheSamePageAndAnchor() {
        let hub = hub()
        let home = entry(.home)
        let first = hub.model(for: home)
        first?.anchor = "carousel:New releases"
        #expect(hub.model(for: home) === first && hub.model(for: home)?.anchor == "carousel:New releases")
        #expect(hub.model(for: entry(.home)) !== first, "another navigation entry is another page")
    }
    @Test func modelsAreBounded() {
        let hub = hub()
        let entries = (0..<40).map { _ in entry(.home) }
        let models = entries.compactMap { hub.model(for: $0) }
        #expect(models.count == 40)
        #expect(hub.model(for: entries[0]) !== models[0], "the oldest page's model was released (its data is in the cache)")
        #expect(hub.model(for: entries[39]) === models[39])
    }
    @Test func routesMapToTargetsAndDevelopmentRoutesAreNotTheCatalogs() throws {
        let hub = hub()
        let artist = try NativeItemRoute(kind: .artist, identifier: "UCRr1xG_2WIDs18a6cIiCxeA")
        let playlist = try NativeItemRoute(kind: .playlist, identifier: "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")
        let category = try NativeItemRoute(kind: .category, identifier: "FEmusic_moods_and_genres_category", params: "ggMPOg1uX1JOQWZFeDByc2Jm")
        #expect(hub.target(for: artist)?.browseID == "UCRr1xG_2WIDs18a6cIiCxeA")
        #expect(hub.target(for: playlist)?.browseID == "VLPLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")
        #expect(hub.target(for: category) == CatalogTarget(browseID: "FEmusic_moods_and_genres_category", params: "ggMPOg1uX1JOQWZFeDByc2Jm"))
        for route in [artist, playlist, category] { #expect(hub.handles(route)) }
        let development = try NativeItemRoute(kind: .album, identifier: "development-3")
        #expect(!hub.handles(development) && hub.model(for: entry(.library, development)) == nil)
        for kind in [NativeItemKind.sample, .tuner, .recap, .badge, .episode] { #expect(!hub.handles(try NativeItemRoute(kind: kind, identifier: "x1"))) }
    }
    @Test func entriesLinksAndSearchResultsBecomeRoutes() throws {
        let hub = hub()
        let page = try realPage(.artist)
        let song = page.shelves[0].items[0]
        let songRoute = try #require(hub.route(for: song))
        #expect(songRoute.kind == .song && songRoute.identifier == song.videoID && hub.song(song.videoID!) == song)
        #expect(hub.route(for: page.shelves[1].items[0])?.kind == .album)
        #expect(hub.route(for: page.shelves[5].items[0])?.kind == .playlist)
        #expect(hub.route(for: page.shelves[7].items[0])?.kind == .artist)
        let mood = try realPage(.explore).shelves[2].items[0]
        let moodRoute = try #require(hub.route(for: mood))
        #expect(moodRoute.kind == .category && moodRoute.params == mood.browseParams)
        let episode = try #require(try realPage(.podcast).shelves[0].items.first)
        // W18: an episode the service named a page for (`MPED…`) opens that page; one it named none for still has no route.
        #expect(hub.route(for: episode)?.kind == .episode && hub.route(for: episode)?.identifier == episode.browseID)
        let unnamed = MusicCatalogItem(kind: .episode, title: "No page", videoID: "AzENYaFVxGg")
        #expect(hub.route(for: unnamed) == nil)
        #expect(hub.route(for: MusicLink(kind: .artist, title: "x", browseID: "UCRr1xG_2WIDs18a6cIiCxeA"))?.kind == .artist)
        let more = try #require(hub.route(for: MusicLink(kind: .other, title: "x", browseID: "MPADUCRr1xG_2WIDs18a6cIiCxeA", params: "ggMIegYIAhoCAQI%3D")))
        #expect(more.kind == .category && more.params == "ggMIegYIAhoCAQI%3D")
        // Search results.
        let target = SearchTarget(videoID: nil, browseID: "UCRr1xG_2WIDs18a6cIiCxeA", playlistID: nil)
        let result = SearchResult(kind: .artist, title: "Daft Punk", details: [], badges: [.service], target: target, fromService: true)
        #expect(hub.route(for: result)?.kind == .artist)
        let songResult = SearchResult(kind: .song, title: "Song", details: ["A", "B"], badges: [.service, .explicit], target: SearchTarget(videoID: "aaaaaaaaaa1", browseID: nil, playlistID: nil), fromService: true)
        #expect(hub.route(for: songResult)?.identifier == "aaaaaaaaaa1" && hub.song("aaaaaaaaaa1")?.explicit == true)
        let episodeResult = SearchResult(kind: .episode, title: "E", details: [], badges: [.service], target: SearchTarget(videoID: "aaaaaaaaaa2", browseID: nil, playlistID: nil), fromService: true)
        #expect(hub.route(for: episodeResult) == nil)
    }
    @Test func routeParamsAreValidatedAndSurviveRestoration() throws {
        #expect(throws: (any Error).self) { try NativeItemRoute(kind: .category, identifier: "FEmusic_x", params: "bad params") }
        #expect(throws: (any Error).self) { try NativeItemRoute(kind: .song, identifier: "aaaaaaaaaa1", params: "ggMP") }
        #expect(throws: (any Error).self) { try NativeItemRoute(kind: .category, identifier: "FEmusic_x", params: String(repeating: "a", count: 1025)) }
        var session = BrowserSession()
        session.open(.home, item: try NativeItemRoute(kind: .category, identifier: "FEmusic_moods_and_genres_category", params: "ggMPOg1uX1JOQWZFeDByc2Jm"))
        let restored = try BrowserSession.restore(try session.encoded())
        #expect(restored.current.item?.params == "ggMPOg1uX1JOQWZFeDByc2Jm" && restored.current.item?.kind == .category)
        // A stored session from before parameters existed still restores.
        let old = try JSONSerialization.data(withJSONObject: ["kind": "album", "identifier": "MPREb_x"])
        #expect(try JSONDecoder().decode(NativeItemRoute.self, from: old).params == nil)
    }
    @Test func accountChangeReasksOpenPagesAndClearsTheCache() async throws {
        let scope = Box("s1")
        let script = ServiceScript()
        await script.setPages(.home, [try realPage(.home)])
        let hub = CatalogHub(artwork: CatalogArtwork(pipeline: nil, authority: ArtworkUIAuthority(), source: nil), development: false,
                             reader: { try await script.page($0) }, continuer: { try await script.token($0) }, scope: { scope.value }, playback: { .available }, performer: nil)
        let model = try #require(hub.model(for: entry(.home)))
        await model.load()
        scope.value = "s2"
        hub.accountChanged(); await settle(200)
        let calls = await script.pageCalls.count
        #expect(calls == 2 && model.phase == .loaded)
    }
    @Test func theDevelopmentCatalogNeedsTheFlagAndStoreIsolation() {
        #if DEBUG
        // Since C1, a Debug launch is store-isolated unless it opts in to the real stores (C1's LaunchStorageDecisionTests pin that,
        // and tests never name the opt-in), so the catalog needs only the flag; without the flag it is never offered.
        #expect(DevelopmentSearch.isEnabled(["YTMUSE_UI_DEVELOPMENT_DATA": "1"]) == true)
        #expect(DevelopmentSearch.isEnabled([:]) == false && DevelopmentSearch.isEnabled(["YTMUSE_UI_TEST_ISOLATED": "1"]) == false, "isolation alone is not the flag")
        #endif
    }
}
