import AccountSession
import Foundation
import Testing
@testable import Features
@testable import YouTubeMusicAdapter

// Rework 1: F2 (the show page's own Play registers the show), F5 (a failed start clears), F6 (the Episodes-for-Later offer rule), the
// context-menu offer, and the parser's place in the removal guard.

@MainActor private final class Performer: SearchActionPerformer {
    var outcome = SearchPlayOutcome.started
    var plays: [(playlist: String, video: String?, params: String?)] = []
    /// Runs while the start is in flight (before it answers).
    var during: (@MainActor () -> Void)?
    func play(playlistID: String, title: String) async -> SearchPlayOutcome { plays.append((playlistID, nil, nil)); during?(); return outcome }
    func play(playlistID: String, title: String, videoID: String?, params: String?) async -> SearchPlayOutcome { plays.append((playlistID, videoID, params)); during?(); return outcome }
    func copy(link: URL) {}
    func copy(text: String) {}
}
private let show = "MPSPPLZr1D7YmlHJw", showList = "PLZr1D7YmlHJw"

@MainActor private func showModel(performer: Performer, registration: PodcastStartRegistration?, scope: Box<String> = Box("a"), page override: MusicBrowsePage? = nil) async throws -> CatalogPageModel {
    let page = try override ?? MusicBrowseParser.parse(try real(.show))
    let model = CatalogPageModel(target: CatalogTarget(browseID: show),
                                 reader: { _ in MusicBrowseReply(value: page, mode: .signedIn, accountGeneration: 1) },
                                 continuer: { _ in throw MusicSessionError.unrecognised }, accountScope: { scope.value }, playback: { .available }, performer: performer)
    model.podcastStart = registration
    await model.load()
    #expect(model.phase == .loaded)
    return model
}
@MainActor private func registration(_ playback: PodcastPlaybackModel) -> PodcastStartRegistration {
    PodcastStartRegistration(began: { show, list in playback.showStarting(show: show, playlistID: list) })
}

@MainActor @Suite struct ShowPageStartTests {
    @Test func theShowsOwnPlayAppliesTheShowsSpeedRecordsProgressAndResumes() async throws {
        let store = MemoryPodcastStore()
        var seeded = PodcastLocalState()
        seeded.store(EpisodeProgressRecord(videoID: ep1, position: 300, duration: 1800, updatedAt: Date(timeIntervalSince1970: 1_699_999_000), played: false, showID: show))
        await store.seed(seeded, account: account)
        let (playback, player, _, _) = await makeModel(store)
        await playback.setRate(1.5, forShow: show)
        let performer = Performer()
        let model = try await showModel(performer: performer, registration: registration(playback))
        await model.perform(.play)
        #expect(performer.plays.map(\.playlist) == [showList])
        // The player then reports the show's first episode from that playlist.
        player.reading = EpisodePlayerReading(videoID: ep1, position: 0, duration: 1800, playing: true, canSeek: true, playlistID: showList)
        playback.observe(player.reading); await settle()
        #expect(player.rateRequests == [1.5] && player.confirmedRate == 1.5, "the show's speed, not normal speed")
        #expect(player.seeks == [300], "resumes where this Mac stopped")
        player.reading.position = 60
        playback.observe(player.reading); await settle()
        #expect(playback.localRecord(ep1)?.position == 60 && playback.localRecord(ep1)?.showID == show, "progress is recorded")
    }
    /// A show page that publishes both Play and Shuffle (the real capture publishes Play only; Shuffle is the endpoint shape the Catalog notes describe).
    private func playAndShufflePage() -> MusicBrowsePage {
        let header = MusicPageHeader(title: "Show", actions: MusicPageActions(play: showList, shuffle: showList, shuffleParams: "wAEB8gECKAE%3D"))
        var accounting = MusicParseAccounting(); accounting.sections = 1; accounting.headerSections = 1
        return MusicBrowsePage(header: header, shelves: [], accounting: accounting)
    }
    /// R3-1 / R3-2: the player may report the first episode WHILE the start is still in flight (before `.started` returns, so before the show is
    /// registered) and again after. The episode must be registered from the next reading and get the show's speed, progress and resume. Performed for
    /// BOTH the show's Play and its Shuffle; the Shuffle case proves the shuffle endpoint (its parameters) was actually sent.
    @Test(arguments: [CatalogAction.play, CatalogAction.shuffle])
    func aReadingDuringTheStartIsPickedUpFromTheNextReading(_ action: CatalogAction) async throws {
        let store = MemoryPodcastStore()
        var seeded = PodcastLocalState()
        seeded.store(EpisodeProgressRecord(videoID: ep1, position: 300, duration: 1800, updatedAt: Date(timeIntervalSince1970: 1_699_999_000), played: false, showID: show))
        await store.seed(seeded, account: account)
        let (playback, player, _, _) = await makeModel(store)
        await playback.setRate(1.5, forShow: show)
        let performer = Performer()
        let model = try await showModel(performer: performer, registration: registration(playback), page: playAndShufflePage())
        // The first reading arrives during the start: the show is not registered yet, so it is nothing special.
        performer.during = {
            player.reading = EpisodePlayerReading(videoID: ep1, position: 0, duration: 1800, playing: true, canSeek: true, playlistID: showList)
            playback.observe(player.reading)
        }
        await model.perform(action)
        await settle()
        #expect(playback.current == nil && player.rateRequests.isEmpty && player.seeks.isEmpty, "during the start nothing is registered, and nothing is changed")
        // The next reading of the SAME episode, after the start returned.
        player.reading = EpisodePlayerReading(videoID: ep1, position: 0, duration: 1800, playing: true, canSeek: true, playlistID: showList)
        playback.observe(player.reading); await settle()
        #expect(playback.current?.videoID == ep1 && playback.current?.show == show, "registered from the next reading")
        #expect(player.rateRequests == [1.5] && player.confirmedRate == 1.5, "the show's speed")
        #expect(player.seeks == [300], "resume")
        player.reading.position = 60
        playback.observe(player.reading); await settle()
        #expect(playback.localRecord(ep1)?.position == 60 && playback.localRecord(ep1)?.showID == show, "progress")
        // The action that was performed is the one that was asked for.
        #expect(performer.plays.count == 1 && performer.plays[0].playlist == showList)
        #expect((performer.plays[0].params != nil) == (action == .shuffle), "Shuffle sends the shuffle endpoint's parameters, Play sends none")
    }
    @Test func theShowsShuffleDoesNotRegisterWhenItsActionIsNotOnTheRegisteringList() throws {
        // The registering actions are exactly Play and Shuffle (a source check; the behavioural proof is the Shuffle case above).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = try String(contentsOf: root.appendingPathComponent("Sources/Features/Catalog/CatalogPageModel.swift"), encoding: .utf8)
        #expect(model.contains("registersShow: action == .play || action == .shuffle"))
    }
    @Test(arguments: [SearchPlayOutcome.failed, .stale, .busy])
    func aShowStartThatDidNotHappenRegistersNothing(_ outcome: SearchPlayOutcome) async throws {
        let (playback, player, _, _) = await makeModel()
        await playback.setRate(1.5, forShow: show)
        let performer = Performer(); performer.outcome = outcome
        let model = try await showModel(performer: performer, registration: registration(playback))
        await model.perform(.play)
        player.reading = EpisodePlayerReading(videoID: ep1, position: 30, duration: 900, playing: true, canSeek: true, playlistID: showList)
        playback.observe(player.reading); await settle()
        #expect(playback.current == nil && player.rateRequests.isEmpty && playback.localRecord(ep1) == nil, "nothing is current after a start that did not happen: \(outcome)")
    }
    @Test func aShowStartWhoseAccountChangedDuringItRegistersNothing() async throws {
        let (playback, player, _, _) = await makeModel()
        let scope = Box("a")
        let performer = Performer()
        let model = try await showModel(performer: performer, registration: registration(playback), scope: scope)
        performer.during = { scope.value = "b" }
        await model.perform(.play)
        player.reading = EpisodePlayerReading(videoID: ep1, position: 30, duration: 900, playing: true, canSeek: true, playlistID: showList)
        playback.observe(player.reading); await settle()
        #expect(playback.current == nil && playback.localRecord(ep1) == nil)
    }
    @Test func aBusyShowStartLeavesTheEpisodeThatIsPlayingRegistered() async throws {
        let (playback, player, _, _) = await makeModel()
        await playback.setRate(1.5, forShow: showA)
        playback.episodeStarting(videoID: ep2, show: showA)          // an episode already playing
        player.play(ep2); playback.observe(player.reading); await settle()
        let performer = Performer(); performer.outcome = .busy
        let model = try await showModel(performer: performer, registration: registration(playback))
        await model.perform(.play)
        #expect(playback.current?.videoID == ep2 && playback.current?.show == showA, "the registration of what plays is untouched")
    }
    @Test func theRegistrationHappensAfterTheStartNotBefore() async throws {
        let (playback, _, _, _) = await makeModel()
        let performer = Performer()
        let model = try await showModel(performer: performer, registration: PodcastStartRegistration(began: { show, list in
            #expect(performer.plays.count == 1, "the player was asked first"); playback.showStarting(show: show, playlistID: list)
        }))
        await model.perform(.play)
        #expect(performer.plays.count == 1)
    }
    @Test func aRadioOrAnyOtherPageActionNeverRegistersTheShow() async throws {
        let (playback, player, _, _) = await makeModel()
        let header = MusicPageHeader(title: "Show", actions: MusicPageActions(play: showList, radio: "RDAMPLsynthetic1", radioAction: MusicRadioAction(playlistID: "RDAMPLsynthetic1")))
        var accounting = MusicParseAccounting(); accounting.sections = 1; accounting.headerSections = 1
        let page = MusicBrowsePage(header: header, shelves: [], accounting: accounting)
        let performer = Performer()
        let model = try await showModel(performer: performer, registration: registration(playback), page: page)
        await model.perform(.radio)
        #expect(performer.plays.map(\.playlist) == ["RDAMPLsynthetic1"], "the radio did start")
        player.reading = EpisodePlayerReading(videoID: ep1, position: 30, duration: 900, playing: true, canSeek: true, playlistID: "RDAMPLsynthetic1")
        playback.observe(player.reading); await settle()
        #expect(playback.current == nil && playback.localRecord(ep1) == nil, "a radio's items are not the show's episodes")
        await model.perform(.play)
        player.reading = EpisodePlayerReading(videoID: ep2, position: 30, duration: 900, playing: true, canSeek: true, playlistID: showList)
        playback.observe(player.reading); await settle()
        #expect(playback.current?.videoID == ep2, "Play does")
    }
    @Test func withoutARegistrationAShowStartIsAsBefore() async throws {
        let (playback, player, _, _) = await makeModel()
        let performer = Performer()
        let model = try await showModel(performer: performer, registration: nil)
        await model.perform(.play)
        player.reading = EpisodePlayerReading(videoID: ep1, position: 30, duration: 900, playing: true, canSeek: true, playlistID: showList)
        playback.observe(player.reading); await settle()
        #expect(playback.current == nil && performer.plays.count == 1)
    }
    @Test func onlyAShowPageRegisters() async throws {
        let began = Locked<[String]>([])
        let registration = PodcastStartRegistration(began: { show, _ in began.mutate { $0.append(show) } })
        let page = try MusicBrowseParser.parse(try Data(contentsOf: fixturesRoot().appendingPathComponent("W11-real/browse-album.json")).jsonObjectForTest())
        let performer = Performer()
        let model = CatalogPageModel(target: CatalogTarget(browseID: "MPREb_album"), reader: { _ in MusicBrowseReply(value: page, mode: .signedIn, accountGeneration: 1) },
                                     continuer: { _ in throw MusicSessionError.unrecognised }, playback: { .available }, performer: performer)
        model.podcastStart = registration
        await model.load(); await model.perform(.play)
        #expect(began.value.isEmpty)
    }
}
private extension Data {
    func jsonObjectForTest() throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: self) as? [String: Any] else { throw MusicSessionError.unrecognised }
        return value
    }
}

@MainActor @Suite struct EpisodeStartFailureTests {
    @Test(arguments: [SearchPlayOutcome.failed, .stale, .busy])
    func anEpisodeStartThatDidNotHappenLeavesNothingCurrentAndNothingToResume(_ outcome: SearchPlayOutcome) async throws {
        let store = MemoryPodcastStore()
        var seeded = PodcastLocalState()
        seeded.store(EpisodeProgressRecord(videoID: ep1, position: 300, duration: 1800, updatedAt: .distantPast, played: false, showID: showA))
        await store.seed(seeded, account: account)
        let (playback, player, _, _) = await makeModel(store)
        let surface = PodcastsSurface(playback: playback, lyrics: LyricsModel(reader: { _ in throw MusicSessionError.policy }), follow: LyricsFollowModel(), ledger: nil,
                                      reader: { _ in throw MusicSessionError.policy }, starter: { _ in outcome })
        await surface.play(try #require(EpisodePlayTargets.request(videoID: ep1, title: "T", showBrowseID: showA)))
        #expect(playback.current == nil, "\(outcome)")
        // Something else is playing the same id later (not started by this press): no resume, no record, no speed.
        player.play(ep1, position: 0)
        playback.observe(player.reading); await settle()
        #expect(player.seeks.isEmpty && playback.localRecord(ep1)?.position == 300 && player.rateRequests.isEmpty)
    }
    @Test func aStartThatDidNotHappenLeavesTheEpisodeThatIsPlayingRegistered() async throws {
        let (playback, _, _, _) = await makeModel()
        playback.episodeStarting(videoID: ep2, show: showA)
        for outcome in [SearchPlayOutcome.failed, .stale, .busy] {
            let surface = PodcastsSurface(playback: playback, lyrics: LyricsModel(reader: { _ in throw MusicSessionError.policy }), follow: LyricsFollowModel(), ledger: nil,
                                          reader: { _ in throw MusicSessionError.policy }, starter: { _ in outcome })
            await surface.play(try #require(EpisodePlayTargets.request(videoID: ep1, title: "T", showBrowseID: showB)))
            #expect(playback.current?.videoID == ep2 && playback.current?.show == showA, "\(outcome)")
        }
    }
    @Test func theEpisodeIsRegisteredAfterTheStartNotBefore() async throws {
        let (playback, _, _, _) = await makeModel()
        let seen = Locked<[Bool]>([])
        let surface = PodcastsSurface(playback: playback, lyrics: LyricsModel(reader: { _ in throw MusicSessionError.policy }), follow: LyricsFollowModel(), ledger: nil,
                                      reader: { _ in throw MusicSessionError.policy }, starter: { _ in seen.mutate { $0.append(playback.current == nil) }; return .started })
        await surface.play(try #require(EpisodePlayTargets.request(videoID: ep1, title: "T", showBrowseID: showA)))
        #expect(seen.value == [true] && playback.current?.videoID == ep1)
    }
    @Test func aSuccessfulStartStaysCurrent() async throws {
        let (playback, _, _, _) = await makeModel()
        let surface = PodcastsSurface(playback: playback, lyrics: LyricsModel(reader: { _ in throw MusicSessionError.policy }), follow: LyricsFollowModel(), ledger: nil,
                                      reader: { _ in throw MusicSessionError.policy }, starter: { _ in .started })
        await surface.play(try #require(EpisodePlayTargets.request(videoID: ep1, title: "T", showBrowseID: showA)))
        #expect(playback.current?.videoID == ep1)
    }
}

@Suite struct EpisodeLaterOfferTests {
    private func later(saved: Bool, add: Bool, remove: Bool) -> MusicEpisodeLater { MusicEpisodeLater(videoID: ep1, isSaved: saved, addPublished: add, removePublished: remove) }
    @Test func onlyThePublishedDirectionIsOfferedAndNeverBoth() {
        // saved shown: Remove if published, else nothing; not saved: Save if published, else nothing.
        #expect(later(saved: true, add: true, remove: true).offeredChange(shownSaved: true) == false)
        #expect(later(saved: true, add: true, remove: false).offeredChange(shownSaved: true) == nil, "an add side does not make a Remove")
        #expect(later(saved: false, add: true, remove: true).offeredChange(shownSaved: false) == true)
        #expect(later(saved: false, add: false, remove: true).offeredChange(shownSaved: false) == nil, "a remove side does not make a Save")
        #expect(later(saved: false, add: false, remove: false).offeredChange(shownSaved: false) == nil && later(saved: true, add: false, remove: false).offeredChange(shownSaved: true) == nil)
    }
    @Test func theRealAnonymousCaptureOffersNothingUntilTheAddSideIsPublished() throws {
        let page = try MusicEpisodeParser_parse(.episode)
        let later = try #require(page.later)
        #expect(later.offeredChange(shownSaved: false) == nil, "anonymous: the add side is a sign-in modal")
    }
    @Test func theSignedFixturesOfferTheDirectionTheyPublish() throws {
        let unsaved = try #require(try MusicEpisodeParser_parse(synthetic: "episode-signed-unsaved.json").later)
        #expect(unsaved.offeredChange(shownSaved: unsaved.isSaved) == true)
        let saved = try #require(try MusicEpisodeParser_parse(synthetic: "episode-signed-saved-partly-played.json").later)
        #expect(saved.offeredChange(shownSaved: saved.isSaved) == false)
        // An optimistic overlay flips the shown state; the offer follows the SHOWN state and the page's publication.
        #expect(unsaved.offeredChange(shownSaved: true) == false && saved.offeredChange(shownSaved: false) == true)
    }
    @Test func theViewUsesTheGate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Features/Library/LibraryView.swift"), encoding: .utf8)
        #expect(view.contains("later.offeredChange(shownSaved: saved)") && !view.contains("later.removePublished") && !view.contains("later.addPublished"))
    }
}

@Suite struct CatalogEpisodeOfferTests {
    @Test func aCatalogEpisodeRowNoLongerSaysItCannotBePlayed() {
        let item = MusicCatalogItem(kind: .episode, title: "E", videoID: ep1, browseID: "MPED" + ep1)
        let offers = CatalogActionPlan.offers(for: item, playback: .available)
        #expect(!offers.contains { $0.action == .play }, "Play is the podcast surface's, not this table's")
        #expect(offers.allSatisfy { $0.unavailable == nil }, "nothing it lists claims that playing is impossible")
    }
}
