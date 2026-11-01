import AccountSession
import Foundation
import Testing
@testable import YouTubeMusicAdapter
@testable import Features

private let episodeBrowse = "MPEDAzENYaFVxGg"

@MainActor @Suite struct EpisodePageModelTests {
    private func make(_ reader: @escaping EpisodePageModel.Reader, scope: Box<String> = Box("a"), id: String = episodeBrowse) -> EpisodePageModel {
        EpisodePageModel(browseID: id, reader: reader, accountScope: { scope.value }, clock: { Date(timeIntervalSince1970: 1_700_000_000) })
    }
    private func reply(_ capture: Real = .episode, mode: MusicSearchReply.Mode = .anonymous) throws -> MusicBrowseReply<MusicEpisodePage> {
        MusicBrowseReply(value: try MusicEpisodeParser_parse(capture), mode: mode, accountGeneration: 1)
    }
    @Test func theRealPageLoadsAndExposesItsChapterlessDescription() async throws {
        let value = try reply()
        let model = make({ _ in value })
        await model.load()
        #expect(model.page?.videoID == "AzENYaFVxGg" && model.readAt == Date(timeIntervalSince1970: 1_700_000_000) && !model.signedIn)
        #expect(model.chapters.isEmpty)
    }
    @Test func chaptersAppearOnlyWhenTheDescriptionPrintsThem() async throws {
        let page = try MusicEpisodeParser_parse(synthetic: "episode-chapters.json")
        let short = make({ _ in MusicBrowseReply(value: page, mode: .anonymous, accountGeneration: 1) })
        await short.load()
        // The fixture's last timestamp (1:02:03) is past the 14 min 45 sec the page prints as its length, so the rule drops the whole list.
        #expect(page.info.durationText == "14 min 45 sec" && short.chapters.isEmpty)
        let long = MusicEpisodePage(videoID: page.videoID, title: page.title, details: page.details, show: page.show, thumbnails: page.thumbnails, description: page.description,
                                    info: MusicEpisodeInfo(progressPercent: 0, durationText: "1 hr 10 min"), later: page.later, accounting: page.accounting)
        let model = make({ _ in MusicBrowseReply(value: long, mode: .anonymous, accountGeneration: 1) })
        await model.load()
        #expect(model.chapters.map(\.start) == [0, 90, 725, 3723])
    }
    @Test func aFailureIsShownAndTryAgainReadsAgain() async throws {
        let calls = Locked(0)
        let value = try reply()
        let model = make({ _ in calls.mutate { $0 += 1 }; if calls.value == 1 { throw MusicSessionError.network }; return value })
        await model.load()
        #expect(model.phase == .failed(.offline))
        await model.load()
        #expect(model.page != nil && calls.value == 2)
        await model.load()
        #expect(calls.value == 2, "a loaded page is not read again by load()")
    }
    @Test func aRefreshThatFailsKeepsThePageOnScreen() async throws {
        let calls = Locked(0)
        let value = try reply()
        let model = make({ _ in calls.mutate { $0 += 1 }; if calls.value == 2 { throw MusicSessionError.network }; return value })
        await model.load(); await model.refresh()
        #expect(model.page != nil, "the older page stays")
    }
    @Test func anotherEpisodesPageIsNeverShownUnderThisOne() async throws {
        let value = try reply()
        let model = make({ _ in value }, id: "MPEDxxxxxxxxxxx")
        await model.load()
        #expect(model.phase == .failed(.unrecognised) && model.page == nil)
        #expect(EpisodePageModel.videoID(ofBrowseID: "MPEDAzENYaFVxGg") == "AzENYaFVxGg" && EpisodePageModel.videoID(ofBrowseID: "MPSPAzENYaFVxGg") == nil && EpisodePageModel.videoID(ofBrowseID: "MPEDshort") == nil)
    }
    @Test func anAnswerReadForAnotherAccountIsDropped() async throws {
        let value = try reply()
        let scope = Box("a")
        let release = Locked(false)
        let model = make({ _ in
            while !release.value { try await Task.sleep(for: .milliseconds(5)) }
            return value
        }, scope: scope)
        let load = Task { await model.load() }
        await settle()
        scope.value = "b"; release.value = true
        await load.value
        #expect(model.page == nil)
        model.accountChanged()
        #expect(model.phase == .idle)
    }
    @Test func aSignedReadIsRecorded() async throws {
        let value = try reply(mode: .signedIn)
        let model = make({ _ in value }); await model.load()
        #expect(model.signedIn)
    }
}

@MainActor @Suite struct PodcastsSurfaceTests {
    private func surface(starter: @escaping PodcastsSurface.Starter = { _ in .started }, store: MemoryPodcastStore = MemoryPodcastStore()) async -> (PodcastsSurface, FakePlayer) {
        let (playback, player, _, _) = await makeModel(store)
        let lyrics = LyricsModel(reader: { _ in throw MusicSessionError.policy })
        let follow = LyricsFollowModel()
        let surface = PodcastsSurface(playback: playback, lyrics: lyrics, follow: follow, ledger: nil, reader: { _ in throw MusicSessionError.policy }, starter: starter)
        return (surface, player)
    }
    @Test func playRegistersTheEpisodeBeforeTheHiddenPlayerIsAskedAndAsksOnce() async throws {
        let asked = Locked<[EpisodePlayRequest]>([])
        let (surface, _) = await surface(starter: { request in asked.mutate { $0.append(request) }; return .started })
        let request = try #require(EpisodePlayTargets.request(videoID: ep1, title: "T", showBrowseID: showA))
        await surface.play(request)
        #expect(asked.value == [request] && surface.playback.current?.videoID == ep1 && surface.playback.current?.show == showA)
        #expect(request.playlistID == "PLshowAAAAAAA", "the show's playlist is its page id without the prefix")
    }
    @Test func aFailedStartIsReportedAtTheEpisodeNotInvented() async throws {
        let (surface, _) = await surface(starter: { _ in .failed })
        await surface.play(try #require(EpisodePlayTargets.request(videoID: ep1, title: "T", showBrowseID: showA)))
        #expect(surface.feedbackText(for: ep1) != nil)
        let (stale, _) = await self.surface(starter: { _ in .stale })
        await stale.play(try #require(EpisodePlayTargets.request(videoID: ep1, title: "T", showBrowseID: showA)))
        #expect(stale.feedbackText(for: ep1)?.contains("account") == true)
    }
    @Test func playNeedsAShowToStartFromAndSaysNothingElse() {
        #expect(EpisodePlayTargets.request(videoID: ep1, title: "T", showBrowseID: nil) == nil)
        #expect(EpisodePlayTargets.request(videoID: ep1, title: "T", showBrowseID: "UCnotashow") == nil)
        #expect(EpisodePlayTargets.request(videoID: "short", title: "T", showBrowseID: showA) == nil)
        #expect(EpisodePlayTargets.request(videoID: nil, title: "T", showBrowseID: showA) == nil)
        #expect(EpisodePlayTargets.request(videoID: ep1, title: "T", showBrowseID: nil, publishedShowPlaylist: "PLpublished1")?.playlistID == "PLpublished1", "a playlist the show page itself published wins")
        #expect(EpisodePlayTargets.playlistID(forShow: "MPSPPLZr1D7YmlHJw") == "PLZr1D7YmlHJw" && EpisodePlayTargets.playlistID(forShow: "MPSP") == nil)
    }
    @Test func rowsCarryTheirResolvedProgressInTheChosenOrder() async throws {
        let (surface, _) = await surface()
        let items = try MusicBrowseParser.parse(try real(.show)).shelves.flatMap(\.items).filter { $0.kind == .episode }
        surface.playback.mark(items[1].videoID!, played: true, duration: 900, show: showA)
        surface.episodeSort = .unplayedFirst
        let rows = surface.rows(for: items, pageReadAt: Date())
        #expect(rows.count == items.count && rows.last?.item.videoID == items[1].videoID && rows.last?.progress.isPlayed == true)
        #expect(rows.last?.progress.provenance == "On this Mac")
        surface.episodeSort = .serviceOrder
        #expect(surface.rows(for: items, pageReadAt: Date()).map(\.item) == items)
    }
    @Test func theSurfaceKeepsAFewPagesAndAnAccountChangeClearsThem() async {
        let (surface, _) = await surface()
        let first = surface.page(forBrowseID: episodeBrowse)
        #expect(first === surface.page(forBrowseID: episodeBrowse))
        for index in 0..<20 { _ = surface.page(forBrowseID: "MPED" + String(format: "%011d", index)) }
        #expect(first !== surface.page(forBrowseID: episodeBrowse), "the oldest pages are let go")
        surface.accountChanged()
        #expect(surface.page(forBrowseID: episodeBrowse).phase == .idle)
    }
}
