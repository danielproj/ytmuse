import AccountSession
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// The parsers against the four REAL anonymous captures first (`Fixtures/W18-real`). Every renderer is accounted for against an oracle that shares
/// no code with the parser.
@Suite struct RealCaptureManifestTests {
    @Test func theFixtureFilesAreTheCapturesTheManifestHashes() throws {
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixturesRoot().appendingPathComponent("W18-real/manifest.json"))) as? [String: Any])
        #expect(manifest["mode"] as? String == "real-public-anonymous-capture" && manifest["live_eligible"] as? Bool == false)
        let files = try #require(manifest["files"] as? [[String: Any]])
        #expect(files.count == Real.allCases.count)
        for entry in files {
            let path = try #require(entry["path"] as? String)
            let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("W18-real/" + path))
            #expect(sha256(data) == entry["sha256"] as? String && data.count == entry["bytes"] as? Int, Comment(rawValue: path))
        }
    }
    @Test func theShowIsTheSameBytesAsTheW11Capture() throws {
        let w11 = try Data(contentsOf: fixturesRoot().appendingPathComponent("W11-real/browse-podcast.json"))
        #expect(try realData(.show) == w11)
    }
    @Test func theSyntheticFixturesAreLabelledAndHashed() throws {
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixturesRoot().appendingPathComponent("W18/manifest.json"))) as? [String: Any])
        #expect(manifest["mode"] as? String == "synthetic-test-only" && manifest["live_eligible"] as? Bool == false)
        let files = try #require(manifest["files"] as? [String: [String: Any]])
        #expect(files.count >= 15)
        for (name, entry) in files {
            let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("W18/" + name))
            #expect(sha256(data) == entry["sha256"] as? String, Comment(rawValue: name))
        }
    }
}

@Suite struct RealEpisodePageTests {
    @Test func theEpisodePageReadsEveryField() throws {
        let page = try MusicEpisodeParser.parse(try real(.episode))
        #expect(page.videoID == "AzENYaFVxGg")
        #expect(page.title == "Daft\u{00A0}Punk\u{2019}s Sampling-Driven Sound Design on Discovery")
        #expect(page.details == ["5 views", "Sep 23"])
        #expect(page.show == MusicLink(kind: .podcast, title: "The Music Production Podcast: Recording, Mixing, Mastering, Music Producers, Audio Engineering, DAWs, Plugins, Sound Design, and Studio Techniques", browseID: "MPSPPLZr1D7YmlHJw"))
        #expect(page.thumbnails.count == 2 && page.thumbnails.allSatisfy { $0.url.scheme == "https" })
        let text = page.description.map(\.text).joined()
        #expect(text.hasPrefix("In this episode we dissect how Daft") && text.contains("megaphone.fm/adchoices"))
        #expect(page.description.contains { $0.url?.absoluteString == "https://megaphone.fm/adchoices" })
    }
    @Test func progressIsWhatTheServicePrintedAndNeverInferredFromTheLabel() throws {
        let page = try MusicEpisodeParser.parse(try real(.episode))
        // The real anonymous page prints 0 and ALSO a "Played" label: the label is furniture, not a statement.
        #expect(page.info.progressPercent == 0 && page.info.playedLabelPublished)
        #expect(!page.info.servicePlayedToEnd && !page.info.serviceInProgress)
        #expect(page.info.durationText == "14 min 45 sec" && page.info.hasPositionFeedbackToken)
    }
    @Test func theServiceDownloadActionIsRecordedAsAFactAndNothingMore() throws {
        let page = try MusicEpisodeParser.parse(try real(.episode))
        #expect(page.info.publishesServiceDownloadAction, "the real menu carries offlineVideoEndpoint")
    }
    @Test func theEpisodesForLaterToggleOffersOnlyTheDirectionThePagePublished() throws {
        let later = try #require(try MusicEpisodeParser.parse(try real(.episode)).later)
        #expect(later.videoID == "AzENYaFVxGg" && !later.isSaved)
        // Anonymously the add side is a sign-in modal, the remove side is the playlist edit on "SE".
        #expect(!later.addPublished && later.removePublished)
    }
    @Test func everyRendererOfThePageIsAccountedFor() throws {
        let root = try real(.episode)
        let page = try MusicEpisodeParser.parse(root)
        let a = page.accounting
        #expect(a.consistent)
        // Independent oracle: the menu entries, the header buttons and the sections found by walking the raw JSON.
        let menu = count(["menuServiceItemRenderer", "menuNavigationItemRenderer", "menuServiceItemDownloadRenderer", "toggleMenuServiceItemRenderer"], in: root)
        #expect(a.menuItems == menu && a.menuItems == 6, "play next, add to queue, download, save to playlist, go to podcast, share")
        #expect(a.menuIgnored.sorted() == ["modal", "share"], Comment(rawValue: "\(a.menuIgnored)"))
        let buttons = count(["toggleButtonRenderer", "musicPlayButtonRenderer", "menuRenderer"], in: (root["contents"] as! [String: Any])["twoColumnBrowseResultsRenderer"] as Any)
        #expect(a.buttons == 3 && a.buttonsRecognised == 3 && a.buttonsIgnored.isEmpty && buttons >= 3)
        #expect(a.sections == 2 && a.headerSections == 1 && a.descriptionSections == 1 && a.unsupportedSections == 0)
    }
    @Test func aPageWithoutATitleOrAPlayTargetIsUnrecognisedNeverAnEmptyEpisode() throws {
        for name in ["episode-no-title.json", "episode-no-play-target.json"] {
            #expect(throws: MusicSessionError.unrecognised) { _ = try MusicEpisodeParser.parse(try synthetic(name)) }
        }
        #expect(throws: MusicSessionError.unrecognised) { _ = try MusicEpisodeParser.parse([:]) }
        #expect(throws: MusicSessionError.unrecognised) { _ = try MusicEpisodeParser.parse(try real(.lyrics)) }
    }
    @Test func progressOutsideZeroToOneHundredIsUnreadableNotClamped() throws {
        let page = try MusicEpisodeParser.parse(try synthetic("episode-progress-out-of-range.json"))
        #expect(page.info.progressPercent == nil && !page.info.servicePlayedToEnd)
    }
    @Test func aPlayedEpisodeIsOneTheServiceSaysReachedTheEnd() throws {
        let page = try MusicEpisodeParser.parse(try synthetic("episode-played.json"))
        #expect(page.info.servicePlayedToEnd && !page.info.serviceInProgress)
    }
    @Test func aSignedPageSavedAndPartlyPlayed() throws {
        let page = try MusicEpisodeParser.parse(try synthetic("episode-signed-saved-partly-played.json"))
        #expect(page.info.serviceInProgress && page.info.progressPercent == 37.5)
        let later = try #require(page.later)
        #expect(later.isSaved && later.addPublished && later.removePublished)
        let unsaved = try #require(try MusicEpisodeParser.parse(try synthetic("episode-signed-unsaved.json")).later)
        #expect(!unsaved.isSaved && unsaved.addPublished && unsaved.removePublished)
    }
}

@Suite struct RealShowPageTests {
    @Test func everyEpisodeRowIsAnEpisodeWithItsPageAndNoRowIsLost() throws {
        let root = try real(.show)
        let page = try MusicBrowseParser.parse(root)
        let rows = count(["musicMultiRowListItemRenderer"], in: root)
        #expect(rows == 20 && page.accounting.items == rows && page.accounting.consistent)
        let episodes = page.shelves.flatMap(\.items).filter { $0.kind == .episode }
        #expect(episodes.count + page.accounting.duplicates + page.accounting.skipped + page.accounting.unsupported == rows)
        #expect(episodes.allSatisfy { $0.videoID?.count == 11 && $0.browseID?.hasPrefix("MPED") == true && $0.opensPageForTest })
    }
    @Test func everyRealRowPrintsAPlayedLabelAndNoRowIsPlayed() throws {
        let episodes = try MusicBrowseParser.parse(try real(.show)).shelves.flatMap(\.items).filter { $0.kind == .episode }
        #expect(!episodes.isEmpty)
        for item in episodes {
            let info = try #require(item.episode)
            #expect(info.playedLabelPublished && info.progressPercent == 0 && !info.servicePlayedToEnd && !info.serviceInProgress, Comment(rawValue: item.title))
            #expect(info.publishesServiceDownloadAction && info.hasPositionFeedbackToken && info.durationText != nil && info.summary != nil)
        }
    }
    @Test func progressVariantsReadAsPublishedAndAMalformedValueIsNotProgress() throws {
        let episodes = try MusicBrowseParser.parse(try synthetic("show-progress.json")).shelves.flatMap(\.items).filter { $0.kind == .episode }
        let info = episodes.prefix(4).map { $0.episode }
        #expect(info[0]?.servicePlayedToEnd == true)
        #expect(info[1]?.progressPercent == 37.5 && info[1]?.serviceInProgress == true)
        #expect(info[2]?.progressPercent == nil, "150 is out of range")
        #expect(info[3]?.progressPercent == nil, "a boolean is not a number")
    }
    @Test func nonEpisodeRowsCarryNoEpisodeInfo() throws {
        let page = try MusicBrowseParser.parse(try Data(contentsOf: fixturesRoot().appendingPathComponent("W11-real/browse-album.json")).jsonObject())
        #expect(page.shelves.flatMap(\.items).allSatisfy { $0.episode == nil })
    }
}
private extension Data {
    func jsonObject() throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: self) as? [String: Any] else { throw MusicSessionError.unrecognised }
        return value
    }
}
private extension MusicCatalogItem {
    /// An episode row the service named opens its page (the rule `Features` applies, restated here against the item).
    var opensPageForTest: Bool { browseID?.hasPrefix("MPED") == true }
}

@Suite struct RealLyricsTests {
    @Test func theLyricsPageIsPlainTextWithItsSourceFooterAndNoTiming() throws {
        let result = try MusicLyricsParser.parseLyrics(try real(.lyrics))
        guard case .lyrics(let document) = result, case .plain(let text) = document.body else { Issue.record("expected plain lyrics"); return }
        #expect(!document.isTimed && document.sourceFooter == "Source: Musixmatch")
        #expect(text.hasPrefix("I didn\u{2019}t want".replacingOccurrences(of: "\u{2019}", with: "'")) && text.hasSuffix("'Cause I know it unlocks like a door"))
        #expect(text.contains("\n\n") && !text.hasSuffix("\n"))
    }
    @Test func theTextIsByteForByteWhatTheSourceSent() throws {
        // Independent extraction straight from the raw JSON, then compared with what the parser returned.
        let root = try real(.lyrics)
        let sections = ((root["contents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]]
        let shelf = try #require(sections?.first?["musicDescriptionShelfRenderer"] as? [String: Any])
        let raw = ((shelf["description"] as? [String: Any])?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        guard case .lyrics(let document) = try MusicLyricsParser.parseLyrics(root), case .plain(let text) = document.body else { Issue.record("expected plain lyrics"); return }
        let expected = try #require(raw)
        #expect(text == expected && text.utf8.elementsEqual(expected.utf8))
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == expected.split(separator: "\n", omittingEmptySubsequences: false).count)
    }
    @Test func theNextResponseNamesTheLyricsPageAndEveryTabIsAccountedFor() throws {
        let root = try real(.next)
        let next = try MusicLyricsParser.parseWatchNext(root)
        #expect(next.lyricsBrowseID == "MPLYt_K8qWMWVqXGi-5")
        #expect(next.tabs.map(\.kind) == [.upNext, .lyrics, .other, .related])
        let rawTabs = count(["tabRenderer"], in: root)
        #expect(next.tabs.count == rawTabs && rawTabs == 4)
        #expect(next.tabs.first(where: { $0.kind == .related })?.browseID == "MPTRt_K8qWMWVqXGi-5")
    }
}
