import AccountSession
import Foundation
import Testing
import YouTubeMusicAdapter
@testable import Features

/// Real-shape tests: two anonymous public captures (Fixtures/W10-real, labelled real-public-anonymous).
/// In real responses every result row sits in its own item section beside the top card.
@Suite struct RealCaptureParserTests {
    private func parsed(_ name: String) throws -> MusicSearchResponse { try MusicSearchParser.parse(try realCapture(name)) }
    private func kinds(_ response: MusicSearchResponse) -> [MusicSearchKind: Int] {
        Dictionary(response.items.map { ($0.kind, 1) }, uniquingKeysWith: +)
    }
    @Test func theLatinCaptureKeepsEveryRow() throws {
        let response = try parsed("search-latin.json")
        #expect(response.top?.kind == .artist && response.top?.title == "Daft Punk")
        #expect(kinds(response) == [.song: 8, .album: 3, .artist: 3, .playlist: 6, .video: 3, .podcast: 3, .episode: 3])
        #expect(response.unsupportedRows == 3, "three channel profiles are counted, not hidden")
        #expect(response.skippedRows == 0 && !response.complete)
    }
    @Test func theCyrillicCaptureKeepsEveryRow() throws {
        let response = try parsed("search-cyrillic.json")
        #expect(response.top?.kind == .video && response.top?.title.hasPrefix("Женя Трофимов") == true)
        #expect(response.items.count + response.unsupportedRows + response.skippedRows + response.duplicateRows + 1 == 31)
        #expect(response.unsupportedRows == 3 && response.skippedRows == 0)
        #expect(Set(response.items.map(\.kind)) == [.song, .album, .video, .episode, .podcast, .artist, .playlist])
    }
    @Test func everyRowIsAccountedForExactlyOnce() throws {
        for name in ["search-latin.json", "search-cyrillic.json"] {
            let root = try realCapture(name)
            let counted = countRows(in: root)
            let response = try MusicSearchParser.parse(root)
            let classified = (response.top == nil ? 0 : 1) + response.items.count
            #expect(counted.rows + counted.cards == classified + response.skippedRows + response.unsupportedRows + response.duplicateRows,
                    "\(name): rows \(counted.rows) + card \(counted.cards) vs classified \(classified), skipped \(response.skippedRows), unsupported \(response.unsupportedRows), duplicates \(response.duplicateRows)")
        }
    }
    @Test func theInvariantAlsoHoldsForTheSyntheticAndBrokenShapes() throws {
        for name in ["search-all-groups.json", "search-only-profile.json", "search-showing-results-for.json"] {
            let data = try searchFixture(name)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let counted = countRows(in: root)
            let response = try MusicSearchParser.parse(root)
            #expect(counted.rows + counted.cards == (response.top == nil ? 0 : 1) + response.items.count + response.skippedRows + response.unsupportedRows + response.duplicateRows, "\(name)")
        }
    }
    @Test func aCaptureWithoutItsTopCardStillParses() throws {
        for name in ["search-latin.json", "search-cyrillic.json"] {
            var root = try realCapture(name)
            var contents = try #require(root["contents"] as? [String: Any])
            var tabbed = try #require(contents["tabbedSearchResultsRenderer"] as? [String: Any])
            var tabs = try #require(tabbed["tabs"] as? [[String: Any]])
            var tab = try #require(tabs[0]["tabRenderer"] as? [String: Any])
            var content = try #require(tab["content"] as? [String: Any])
            var list = try #require(content["sectionListRenderer"] as? [String: Any])
            let sections = try #require(list["contents"] as? [[String: Any]])
            list["contents"] = sections.filter { $0["musicCardShelfRenderer"] == nil }
            content["sectionListRenderer"] = list; tab["content"] = content; tabs[0]["tabRenderer"] = tab
            tabbed["tabs"] = tabs; contents["tabbedSearchResultsRenderer"] = tabbed; root["contents"] = contents
            let response = try MusicSearchParser.parse(root)
            #expect(response.top == nil && response.items.count >= 20 && response.unsupportedRows == 3, "\(name): \(response.items.count)")
            let counted = countRows(in: root)
            #expect(counted.rows == response.items.count + response.skippedRows + response.unsupportedRows + response.duplicateRows)
        }
    }
    @Test func anUnknownEntryInsideAnItemSectionIsCountedNotIgnored() throws {
        var root = try realCapture("search-latin.json")
        var contents = try #require(root["contents"] as? [String: Any])
        var tabbed = try #require(contents["tabbedSearchResultsRenderer"] as? [String: Any])
        var tabs = try #require(tabbed["tabs"] as? [[String: Any]])
        var tab = try #require(tabs[0]["tabRenderer"] as? [String: Any])
        var content = try #require(tab["content"] as? [String: Any])
        var list = try #require(content["sectionListRenderer"] as? [String: Any])
        var sections = try #require(list["contents"] as? [[String: Any]])
        sections.append(["itemSectionRenderer": ["contents": [["somethingNewRenderer": [:]]]]])
        sections.append(["musicCarouselShelfRenderer": ["contents": []]])
        list["contents"] = sections; content["sectionListRenderer"] = list; tab["content"] = content; tabs[0]["tabRenderer"] = tab
        tabbed["tabs"] = tabs; contents["tabbedSearchResultsRenderer"] = tabbed; root["contents"] = contents
        #expect(try MusicSearchParser.parse(root).skippedRows == 2)
    }
}

@Suite @MainActor struct RealCapturePresentationTests {
    private func results(_ name: String) throws -> [SearchResult] {
        let response = try MusicSearchParser.parse(try realCapture(name))
        return ([response.top].compactMap { $0 } + response.items).enumerated().map { SearchResult($1, top: $0 == 0) }
    }
    private func result(_ results: [SearchResult], _ kind: MusicSearchKind, _ title: String) throws -> SearchResult {
        try #require(results.first { $0.kind == kind && $0.title == title })
    }
    @Test func playResolvesTheRightIdForEachKind() throws {
        let all = try results("search-latin.json")
        let song = try result(all, .song, "Aerodynamic")
        #expect(SearchActionPlan.playlist(for: song) == "RDAMVM52fNscjkST4")
        let single = try result(all, .album, "Technologic (Vitalic Remix)")
        #expect(SearchActionPlan.playlist(for: single)?.hasPrefix("OLAK5uy_") == true)
        #expect(SearchActionPlan.playlist(for: single) == "OLAK5uy_nU5NDpR6zWqh54OkycaoD3Bk3Y-HIKqyo")
        let user = try result(all, .playlist, "The Black Eyed Peas/Daft Punk")
        #expect(SearchActionPlan.playlist(for: user) == "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")
        let editorial = try result(all, .playlist, "Presenting Daft Punk")
        #expect(SearchActionPlan.playlist(for: editorial)?.hasPrefix("PL") == true || SearchActionPlan.playlist(for: editorial)?.hasPrefix("RDCLAK") == true)
        let podcast = try result(all, .podcast, "Let's Talk Music Series")
        #expect(SearchActionPlan.playlist(for: podcast)?.hasPrefix("PL") == true)
        let video = try result(all, .video, "Instant Crush (feat. Julian Casablancas)")
        #expect(SearchActionPlan.playlist(for: video)?.hasPrefix("RDAMVM") == true)
        #expect(SearchActionPlan.playlist(for: try #require(all.first { $0.kind == .artist })) == nil)
    }
    @Test func everyPlayableRowYieldsAnIdTheHiddenPlayerAccepts() throws {
        for name in ["search-latin.json", "search-cyrillic.json"] {
            for item in try results(name) where [.song, .video, .album, .playlist, .podcast].contains(item.kind) {
                let id = try #require(SearchActionPlan.playlist(for: item), Comment(rawValue: "\(item.kind) \(item.title)"))
                #expect((2...128).contains(id.utf8.count) && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }, Comment(rawValue: id))
                if item.kind == .album { #expect(id.hasPrefix("OLAK5uy_"), Comment(rawValue: id)) }
            }
        }
    }
    @Test func episodesAreOfferedButReportedNotPlayableYet() throws {
        let all = try results("search-latin.json")
        let episodes = all.filter { $0.kind == .episode }
        #expect(episodes.count == 3)
        for episode in episodes {
            let offers = SearchActionPlan.offers(for: episode, playback: .available)
            #expect(offers.first?.action == .play && offers.first?.unavailable == String(localized: "Single episodes can’t be played from search yet."))
            #expect(SearchActionPlan.playlist(for: episode) == nil)
            #expect(SearchActionPlan.link(for: episode)?.absoluteString.hasPrefix("https://music.youtube.com/watch?v=") == true)
        }
    }
    @Test func detailPartsAreSeparatedNeverRunTogether() throws {
        let latin = try results("search-latin.json")
        let card = try MusicSearchParser.parse(try realCapture("search-latin.json"))
        let instant = try #require(card.items.first { $0.title == "Instant Crush (feat. Julian Casablancas)" && $0.kind == .song })
        #expect(instant.details == ["5:38", "1.2B plays"] && instant.subtitle == "5:38 • 1.2B plays")
        let multi = try result(latin, .song, "AROUND THE GLOBE (RMX)")
        #expect(multi.details == ["Unjaps, 404NR & June Boii", "1.9M plays"], "artists stay one part; the plays are another")
        #expect(multi.subtitle == "Unjaps, 404NR & June Boii • 1.9M plays")
        let everything = latin.flatMap(\.details)
        #expect(everything.allSatisfy { !$0.contains("•") })
        #expect(!everything.contains { $0.range(of: #"\d(?:[KMB]) ?(plays|views)\S"#, options: .regularExpression) != nil })
    }
    @Test func aSingleStaysASingleAndAnEpisodeKeepsItsOwnKind() throws {
        let latin = try results("search-latin.json")
        let single = try result(latin, .album, "Technologic (Vitalic Remix)")
        #expect(single.typeLabel == "Single" && single.group == .albums)
        #expect(single.details == ["Daft Punk", "2005"])
        let song = try result(latin, .song, "Aerodynamic")
        #expect(song.typeLabel == String(localized: "Song"), "other kinds use the app's own localised names")
    }
    @Test func theRealRowsFlowIntoGroupsThroughTheModel() async throws {
        let clock = VirtualClock(), remote = ScriptedRemote()
        let model = SearchModel(remote: { try await remote.call($0) }, clock: clock, playback: { .available })
        model.query = "daft punk"; await settle()
        clock.advance(by: .milliseconds(180)); await settle()
        await remote.answer(0, with: reply(try MusicSearchParser.parse(try realCapture("search-latin.json")))); await settle()
        let counts = Dictionary(uniqueKeysWithValues: model.sections.map { ($0.group, $0.results.count) })
        #expect(counts == [.top: 1, .songs: 8, .albums: 3, .artists: 3, .playlists: 6, .videos: 3, .podcasts: 3, .episodes: 3])
        guard case .loaded(let info) = model.remoteStatus else { Issue.record("expected loaded"); return }
        #expect(info.unsupportedRows == 3 && info.skippedRows == 0)
    }
}
