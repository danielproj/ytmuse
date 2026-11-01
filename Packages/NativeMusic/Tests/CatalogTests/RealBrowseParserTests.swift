import AccountSession
import Features
import Foundation
import Testing
import YouTubeMusicAdapter

/// T11.1 / T11.3 on the nine REAL anonymous captures (`Fixtures/W11-real`, `real-public-anonymous-capture`). The numbers
/// below were read off the captures themselves; they are not derived from the parser under test.
@Suite struct RealBrowseParserTests {
    @Test func manifestHashesMatchTheBytesOnDisk() throws {
        let manifest = try Data(contentsOf: fixturesRoot().appendingPathComponent("W11-real/manifest.json"))
        let object = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        #expect(object["mode"] as? String == "real-public-anonymous-capture")
        let files = try #require(object["files"] as? [[String: Any]])
        #expect(files.count == 9)
        for file in files {
            let name = try #require(file["path"] as? String)
            let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("W11-real/" + name))
            #expect(data.count == file["bytes"] as? Int, "\(name) size")
            #expect(sha256(data) == file["sha256"] as? String, "\(name) hash")
        }
    }

    /// Every entry renderer in the document is accounted for as classified, skipped, unsupported or duplicate — and the
    /// total equals an independent walk of the raw JSON. A parser that silently dropped one would fail here.
    @Test(arguments: Capture.allCases) func everyRendererIsAccountedFor(capture: Capture) throws {
        let root = try realCapture(capture)
        let page = try MusicBrowseParser.parse(root)
        let accounting = page.accounting
        #expect(accounting.consistent)
        #expect(accounting.items == countEntryRenderers(in: root), "\(capture): items read vs renderers in the document")
        #expect(accounting.items == accounting.classified + accounting.skipped + accounting.unsupported + accounting.duplicates)
        // On these captures nothing is unreadable, unsupported or repeated: every entry became an item.
        #expect(accounting.skipped == 0 && accounting.unsupported == 0 && accounting.duplicates == 0, "\(capture)")
        #expect(page.shelves.reduce(0) { $0 + $1.items.count } == accounting.classified)
        #expect(accounting.sections == accounting.shelves + accounting.headerSections + accounting.furniture + accounting.unsupportedSections)
    }

    @Test func perCaptureCounts() throws {
        let expected: [(Capture, items: Int, shelves: Int, headerSections: Int, furniture: Int, unsupportedSections: Int)] = [
            (.home, 30, 2, 0, 0, 1), (.explore, 87, 4, 0, 0, 0), (.moods, 36, 2, 0, 0, 0), (.newReleases, 50, 3, 0, 0, 0),
            (.charts, 42, 2, 0, 1, 0), (.artist, 75, 8, 1, 0, 0), (.album, 24, 3, 1, 0, 0), (.playlist, 16, 1, 1, 0, 0), (.podcast, 20, 1, 1, 0, 0),
        ]
        for row in expected {
            let a = try realPage(row.0).accounting
            #expect(a.items == row.items && a.shelves == row.shelves && a.headerSections == row.headerSections && a.furniture == row.furniture
                    && a.unsupportedSections == row.unsupportedSections, "\(row.0): \(a)")
        }
        #expect(try realPage(.home).accounting.unsupportedSectionNames == ["musicTastebuilderShelfRenderer"])
    }

    @Test func homeShelvesQuickPicksAndPlayIDs() throws {
        let page = try realPage(.home)
        #expect(page.shelves.map(\.key) == ["list:Quick picks", "carousel:New releases"])
        let picks = page.shelves[0]
        #expect(picks.layout == .list && picks.rowsPerColumn == 4 && picks.items.count == 20)
        #expect(picks.items.allSatisfy { $0.kind == .song && $0.videoID?.count == 11 })
        let first = picks.items[0]
        #expect(first.title == "Thriller" && first.videoID == "Z85lxckrtzg")
        #expect(first.details == ["Michael Jackson", "1.2B plays", "Thriller"])
        #expect(first.links.map(\.browseID) == ["UCoIOOL7QKuBhQHVKL8y7BEQ", "MPREb_dqWTncCjkSp"])
        #expect(CatalogActionPlan.playlist(for: first) == "RDAMVMZ85lxckrtzg")
        #expect(first.thumbnails.count == 2)
        let releases = page.shelves[1]
        #expect(releases.items.count == 10 && releases.items.allSatisfy { $0.kind == .album && $0.browseID?.hasPrefix("MPREb_") == true })
        let single = releases.items[0]
        #expect(single.serviceLabel == "Single" && single.playlistID == "OLAK5uy_mVnsK1j0tmpLEnNrIAe-J0jl0FmU_ML2I")
        #expect(single.links.first?.browseID == "UC5xvi1JLy6hQU11sM71AuuQ")
        #expect(CatalogActionPlan.playlist(for: single) == single.playlistID)
        // Every album's Play target is the playlist its own play button names.
        #expect(releases.items.allSatisfy { $0.playlistID?.hasPrefix("OLAK5uy_") == true })
        #expect(releases.more?.browseID == "FEmusic_new_releases_albums" && releases.more?.params != nil)
        #expect(page.chips.count == 10 && page.chips.allSatisfy { $0.browseID == "FEmusic_home" && $0.params != nil })
        #expect(page.continuation != nil)
    }

    @Test func exploreCategoriesNewReleasesMoodsAndVideos() throws {
        let page = try realPage(.explore)
        #expect(page.shelves.map(\.layout) == [.categories, .carousel, .categories, .carousel])
        #expect(page.shelves.map(\.items.count) == [3, 24, 36, 24])
        let entries = page.shelves[0].items
        #expect(entries.map(\.browseID) == ["FEmusic_new_releases", "FEmusic_charts", "FEmusic_moods_and_genres"])
        #expect(entries[1].browseParams != nil)
        #expect(entries.map(\.title) == ["New releases", "Charts", "Moods & genres"])
        let moods = page.shelves[2].items
        #expect(moods.allSatisfy { $0.kind == .category && $0.browseID == "FEmusic_moods_and_genres_category" && $0.browseParams != nil })
        #expect(moods.first?.title == "Chill")
        let videos = page.shelves[3].items
        #expect(Set(videos.map(\.kind)) == [.video, .episode])
        let episode = try #require(videos.first { $0.kind == .episode })
        #expect(episode.browseID?.hasPrefix("MPED") == true && episode.videoID?.count == 11 && "MPED" + episode.videoID! == episode.browseID)
        #expect(CatalogActionPlan.playlist(for: episode) == nil)
        #expect(page.shelves[3].more?.browseID == "FEmusic_new_releases_videos")
    }

    @Test func moodsNewReleasesAndCharts() throws {
        let moods = try realPage(.moods)
        #expect(moods.heading == "Moods & genres" && moods.shelves.map(\.items.count) == [12, 24])
        #expect(moods.shelves.allSatisfy { $0.layout == .categories })
        let releases = try realPage(.newReleases)
        #expect(releases.heading == "New releases")
        #expect(releases.shelves.map(\.items.count) == [2, 24, 24])
        #expect(releases.shelves[0].items.allSatisfy { $0.kind == .playlist })
        #expect(releases.shelves[0].items.last?.serviceLabel == "Mix")
        let charts = try realPage(.charts)
        #expect(charts.heading == "Charts" && charts.accounting.furniture == 1)
        #expect(charts.shelves.map(\.items.count) == [2, 40])
        let video = charts.shelves[0].items
        #expect(video.allSatisfy { $0.kind == .playlist && $0.serviceLabel == "Chart" && $0.browseID?.hasPrefix("VLPL") == true })
        #expect(CatalogActionPlan.playlist(for: video[0]) == "PL4fGSI1pDJn6t3TXLGiiJdD-sZbrG3tG0")
        let artists = charts.shelves[1].items
        #expect(artists.allSatisfy { $0.kind == .artist && $0.browseID?.hasPrefix("UC") == true })
        #expect(artists.map(\.position) == (1...40).map { String($0) })
        #expect(artists[0].title == "Alka Yagnik" && artists[0].details == ["2.31M subscribers"])
    }

    @Test func artistPageSectionsActionsAndDescription() throws {
        let page = try realPage(.artist)
        let header = try #require(page.header)
        #expect(header.title == "Daft Punk" && header.audienceText == "68.3M monthly audience" && header.thumbnails.count == 3)
        #expect(header.actions.shuffleParams == "wAEB8gECGAE%3D")
        #expect(header.actions.shuffle == "RDAOni3jl65KF37F9JYsJM8DGg" && header.actions.radio == "RDEMni3jl65KF37F9JYsJM8DGg" && header.actions.play == nil)
        #expect(header.actions.offersFollow && !header.actions.offersSave)
        let detail = try #require(ArtistDetail(page: page))
        #expect(detail.topTracks?.items.count == 5 && detail.topTracks?.items.allSatisfy { $0.kind == .song } == true)
        #expect(detail.albums.map(\.items.count) == [10] && detail.singles.map(\.items.count) == [10])
        #expect(detail.albums[0].items.allSatisfy { $0.serviceLabel == nil } && detail.singles[0].items.allSatisfy { $0.serviceLabel != nil })
        #expect(detail.videos.map(\.items.count) == [10, 10])
        #expect(detail.playlists.map(\.items.count) == [10, 10])
        #expect(detail.related.map(\.items.count) == [10] && detail.related[0].items.allSatisfy { $0.kind == .artist })
        #expect(detail.others.isEmpty && detail.offersFollow)
        // Top songs link to their artists and albums.
        let first = try #require(detail.topTracks?.items.first)
        #expect(first.title.hasPrefix("Instant Crush") && first.links.contains { $0.kind == .album && $0.browseID == "MPREb_K8qWMWVqXGi" })
        // The biography keeps its Wikipedia attribution link in the description runs.
        #expect(header.description.contains { $0.url?.host == "en.wikipedia.org" })
        let text = CatalogRichText.make(header.description)
        #expect(text.attribution != nil && text.links.contains { $0.host == "en.wikipedia.org" })
        // The shelf "Show all" lists keep the params needed to open them.
        #expect(page.shelves[0].more?.params == "ggMCCAI%3D")
    }

    @Test func albumPageEditionsCreditsTracks() throws {
        let page = try realPage(.album)
        let header = try #require(page.header)
        #expect(header.title == "Random Access Memories" && header.subtitle == ["Album", "2013"])
        #expect(header.secondSubtitle == ["13 songs", "1 hour, 14 minutes"])
        #expect(header.credits == [MusicLink(kind: .artist, title: "Daft Punk", browseID: "UCRr1xG_2WIDs18a6cIiCxeA")])
        let id = "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c"
        #expect(header.actions.play == id && header.actions.shuffle == id && header.actions.radio == "RDAMPL" + id && header.actions.offersSave)
        // The service's Shuffle is the SAME playlist with its own parameters: the parameters are what make it shuffle.
        #expect(header.actions.shuffleParams == "wAEB8gECKAE%3D" && header.actions.play != nil)
        let detail = try #require(AlbumDetail(page: page))
        #expect(detail.tracks.count == 13 && detail.trackCountText == "13 songs" && detail.durationText == "1 hour, 14 minutes")
        #expect(detail.tracks.map(\.position) == (1...13).map { String($0) })
        #expect(detail.tracks[0].title == "Give Life Back to Music" && detail.tracks[0].durationText == "4:36" && detail.tracks[0].videoID == "IluRBvnYMoY")
        #expect(Set(detail.tracks.compactMap(\.occurrenceID)).count == 13)
        #expect(detail.tracks.allSatisfy { $0.links.first?.browseID == "UCRr1xG_2WIDs18a6cIiCxeA" })
        #expect(detail.editions.map(\.title) == ["Random Access Memories (10th Anniversary Edition)"])
        #expect(detail.editions[0].browseID == "MPREb_eMBjPmWySjR")
        #expect(detail.related.map(\.items.count) == [10])
        #expect(detail.credits.map(\.title) == ["Daft Punk"])
        // The notes keep their licence line whole.
        let text = CatalogRichText.make(header.description)
        #expect(text.attribution != nil)
        #expect(String(text.attribution!.characters).contains("Creative Commons"))
        #expect(text.links.map(\.host) == ["en.wikipedia.org", "creativecommons.org"])
    }

    @Test func playlistPageKeepsTheGreyedTrackAndThePageToken() throws {
        let page = try realPage(.playlist)
        let header = try #require(page.header)
        #expect(header.subtitle == ["Playlist", "2023"] && header.byline == "Pedro Henrique")
        #expect(header.secondSubtitle == ["2.3K views", "16 tracks", "1 hour, 15 minutes"])
        #expect(header.actions.shuffle == header.actions.play && header.actions.shuffleParams == "wAEB8gECKAE%3D")
        #expect(header.actions.play == "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN" && header.actions.radio == "RDAMPLPLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")
        let tracks = try #require(page.shelves.first).items
        #expect(tracks.count == 16 && tracks.allSatisfy { $0.occurrenceID != nil })
        // The row the service greys out is listed as an unavailable song, with no play target — not dropped, not made playable.
        let grey = try #require(tracks.first { $0.availability == .unavailable })
        #expect(grey.title == "Let's Get It Started" && grey.videoID == "9TtSywYIZNg" && grey.kind == .song)
        #expect(tracks.filter { $0.availability == .unavailable }.count == 1)
        let offers = CatalogActionPlan.offers(for: grey, playback: .available)
        #expect(offers.first?.action == .play && offers.first?.unavailable != nil)
        #expect(page.continuation?.hasPrefix("4qmFsgI0") == true && !page.complete)
    }

    @Test func podcastPageEpisodesAndToken() throws {
        let page = try realPage(.podcast)
        let header = try #require(page.header)
        #expect(header.title.hasPrefix("The Music Production Podcast") && header.credits.map(\.title) == ["Sound Stock"] && header.credits[0].kind == .other)
        #expect(header.actions.play == nil && header.actions.shuffle == nil && header.actions.shuffleParams == nil && header.actions.offersSave)
        let shelf = try #require(page.shelves.first)
        #expect(shelf.items.count == 20 && shelf.items.allSatisfy { $0.kind == .episode && $0.videoID?.count == 11 && $0.browseID?.hasPrefix("MPED") == true })
        #expect(shelf.items[0].durationText == "18 min" && shelf.items[0].details == ["17 views", "Sep 24"])
        #expect(shelf.continuation != nil)
        #expect(shelf.items.allSatisfy { CatalogActionPlan.playlist(for: $0) == nil })
        // The show page names no Play of its own; the page model derives the show's playlist from its `MPSPPL…` id.
    }

    @Test func pageParsedTwiceIsIdentical() throws {
        for capture in Capture.allCases { #expect(try realPage(capture) == realPage(capture)) }
    }

    @Test func everyBrowseIDAndTokenIsAcceptedByTheAdapterValidators() throws {
        for capture in Capture.allCases {
            let page = try realPage(capture)
            for item in page.shelves.flatMap(\.items) {
                if let id = item.browseID { #expect(MusicBrowseParser.isBrowseID(id), "\(capture) \(id)") }
                if let params = item.browseParams { #expect(MusicBrowseParser.isParams(params), "\(capture) params") }
            }
            for chip in page.chips { #expect(MusicBrowseParser.isBrowseID(chip.browseID) && (chip.params.map(MusicBrowseParser.isParams) ?? true)) }
            if let token = page.continuation { #expect(MusicBrowseParser.isToken(token)) }
            for shelf in page.shelves { if let token = shelf.continuation { #expect(MusicBrowseParser.isToken(token)) } }
        }
    }
}
