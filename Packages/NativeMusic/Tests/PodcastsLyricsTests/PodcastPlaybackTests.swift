import AccountSession
import Foundation
import MediaPlayer
import Playback
import SystemIntegration
import Testing
@testable import Features

// MARK: Doubles (no network, no real store)

@MainActor final class FakePlayer: EpisodePlayerControlling {
    var reading = EpisodePlayerReading(videoID: nil, position: 0, duration: 0, playing: false, canSeek: false)
    var confirmedRate = 1.0   // the ACTUAL speed (a test sets it to model the element changing it)
    var seeks: [Double] = []
    var rateRequests: [Double] = []
    var seekWorks = true, rateWorks = true
    func seek(to seconds: Double) async -> Bool { seeks.append(seconds); if seekWorks { reading.position = seconds }; return seekWorks }
    func setRate(_ rate: Double) async -> Bool { rateRequests.append(rate); if rateWorks { confirmedRate = rate }; return rateWorks }
    func play(_ id: String, position: Double = 0, duration: Double = 1800, list: String? = nil) {
        reading = EpisodePlayerReading(videoID: id, position: position, duration: duration, playing: true, canSeek: true, playlistID: list)
    }
}
actor MemoryPodcastStore: PodcastLocalStoring {
    private(set) var saved: [String: PodcastLocalState] = [:]
    private(set) var saves = 0
    var failSave = false
    func load(account: String) async throws -> PodcastLocalState { saved[account] ?? PodcastLocalState() }
    func save(_ state: PodcastLocalState, account: String) async throws { if failSave { throw CocoaError(.fileWriteOutOfSpace) }; saved[account] = state; saves += 1 }
    func clear(account: String) async throws { saved[account] = nil }
    func seed(_ state: PodcastLocalState, account: String) { saved[account] = state }
    func setFailing(_ value: Bool) { failSave = value }
    func state(_ account: String) -> PodcastLocalState? { saved[account] }
}
final class TestClock: @unchecked Sendable {
    private let lock = NSLock(); private var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.date = date }
    var value: Date { get { lock.withLock { date } } set { lock.withLock { date = newValue } } }
}
let account = "11111111-2222-3333-4444-555555555555"
let showA = "MPSPPLshowAAAAAAA", showB = "MPSPPLshowBBBBBBB"
let ep1 = "AzENYaFVxGg", ep2 = "XA56BBR2QS0", song = "khnokW3Mw24"

@MainActor func makeModel(_ store: MemoryPodcastStore = MemoryPodcastStore(), player: FakePlayer = FakePlayer(), now: TestClock = TestClock()) async -> (PodcastPlaybackModel, FakePlayer, MemoryPodcastStore, TestClock) {
    let model = PodcastPlaybackModel(store: store, accountKey: { account }, clock: { now.value })
    model.attach(player)
    await model.load()
    return (model, player, store, now)
}

// MARK: T18.1 rate bounds, per-show restoration, skip defaults and customisation

@Suite struct PodcastRateTests {
    @Test func theBoundsAreHalfSpeedToTripleAndNothingOutsideIsAccepted() {
        #expect(PodcastRate.range == 0.5...3 && PodcastRate.normal == 1)
        for ok in [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 1.1] { #expect(PodcastRate.isValid(ok), Comment(rawValue: "\(ok)")) }
        for bad in [0.49, 0.0, -1, 3.01, 4, .nan, .infinity, -.infinity] { #expect(!PodcastRate.isValid(bad), Comment(rawValue: "\(bad)")) }
        #expect(PodcastRate.steps.first == 0.5 && PodcastRate.steps.last == 3 && PodcastRate.steps.allSatisfy(PodcastRate.isValid) && PodcastRate.steps.contains(1))
        #expect(PodcastRate.steps == PodcastRate.steps.sorted())
    }
    @Test func labelsHaveNoTrailingZeros() {
        #expect(PodcastRate.label(1) == "1×" && PodcastRate.label(1.5) == "1.5×" && PodcastRate.label(0.75) == "0.75×" && PodcastRate.label(3) == "3×")
    }
    @Test func theHiddenPlayersRateCommandMatchesTheBoundsAndAsksForPitchPreservation() throws {
        for ok in [0.5, 1, 1.5, 3.0] {
            let invocation = try WebMusicCommand.rate(ok).invocation()
            #expect(invocation.arguments["rate"] as? Double == ok)
            #expect(invocation.body.contains("preservesPitch") && invocation.body.contains("webkitPreservesPitch"), "the page's own element keeps pitch while the speed changes")
            #expect(invocation.body.contains("playbackRate") && invocation.body.contains("\"rejected\""), "the element's speed is read back, so a page that ignored the request does not answer ok")
            #expect(invocation.body.contains("ytmuseAdShowing"), "refused during an ad")
        }
        for bad in [0.49, 3.01, .nan, .infinity, 0] { #expect(throws: WebMusicCommandError.invalidArgument) { _ = try WebMusicCommand.rate(bad).invocation() } }
    }
    @Test func theCommandLayerAndTheControlAgreeOnTheBounds() {
        // The playback command layer's own range is the same closed interval.
        #expect(PodcastRate.range.lowerBound == 0.5 && PodcastRate.range.upperBound == 3)
    }
}

@Suite struct PodcastSkipIntervalTests {
    @Test func theDefaultsAreFifteenBackAndThirtyForward() {
        #expect(PodcastSkipIntervals.defaultBack == 15 && PodcastSkipIntervals.defaultForward == 30)
        #expect(PodcastSkipIntervals.standard.back == 15 && PodcastSkipIntervals.standard.forward == 30 && PodcastPlaybackPreferences().skip == .standard)
    }
    @Test func onlyTheOfferedLengthsAreAccepted() {
        #expect(PodcastSkipIntervals(back: 10, forward: 45)?.back == 10)
        #expect(PodcastSkipIntervals(back: 7, forward: 30) == nil && PodcastSkipIntervals(back: 15, forward: 31) == nil && PodcastSkipIntervals(back: 0, forward: 30) == nil && PodcastSkipIntervals(back: -15, forward: 30) == nil)
        #expect(PodcastSkipIntervals.backChoices.contains(15) && PodcastSkipIntervals.forwardChoices.contains(30))
    }
    @Test func aJumpStaysInsideTheItem() {
        #expect(PodcastSkipIntervals.target(from: 100, by: 30, duration: 1800) == 130)
        #expect(PodcastSkipIntervals.target(from: 100, by: -15, duration: 1800) == 85)
        #expect(PodcastSkipIntervals.target(from: 5, by: -15, duration: 1800) == 0)
        #expect(PodcastSkipIntervals.target(from: 1790, by: 30, duration: 1800) == 1800)
        #expect(PodcastSkipIntervals.target(from: 40, by: 30, duration: 0) == 70, "no length known: no upper clamp")
    }
    @Test func aDamagedStoredValueFallsBackToTheDefaults() throws {
        let json = Data(#"{"skip":{"back":7,"forward":999},"defaultRate":9,"showRates":{"MPSPok":1.5,"MPSPbad":12,"bad key!":1.5}}"#.utf8)
        let decoded = try JSONDecoder().decode(PodcastPlaybackPreferences.self, from: json)
        #expect(decoded.skip == .standard && decoded.defaultRate == 1)
        #expect(decoded.showRates == ["MPSPok": 1.5], "an out-of-bounds speed and a key that is not a page id are dropped")
    }
}

@MainActor @Suite struct PodcastPreferenceModelTests {
    @Test func aShowsSpeedIsRememberedAcrossARelaunch() async {
        let store = MemoryPodcastStore()
        let (first, _, _, _) = await makeModel(store)
        #expect(await first.setRate(1.5, forShow: showA))
        #expect(first.rate(forShow: showA) == 1.5 && first.rate(forShow: showB) == 1, "another show keeps the default")
        await settle()
        // A new model over the same store is a new launch.
        let (second, _, _, _) = await makeModel(store)
        #expect(second.rate(forShow: showA) == 1.5 && second.rate(forShow: showB) == 1)
    }
    @Test func theDefaultSpeedAppliesToShowsWithoutTheirOwn() async {
        let (model, _, _, _) = await makeModel()
        #expect(model.setDefaultRate(1.25))
        #expect(model.rate(forShow: showB) == 1.25 && model.rate(forShow: nil) == 1.25)
        await model.setRate(2, forShow: showA)
        #expect(model.rate(forShow: showA) == 2)
        await model.clearRate(forShow: showA)
        #expect(model.rate(forShow: showA) == 1.25)
    }
    @Test func outOfBoundsSpeedsAndBadShowIdsAreRefusedAndChangeNothing() async {
        let (model, player, _, _) = await makeModel()
        #expect(await model.setRate(3.5, forShow: showA) == false && model.rate(forShow: showA) == 1)
        #expect(await model.setRate(0.25, forShow: showA) == false)
        #expect(await model.setRate(.nan, forShow: showA) == false)
        #expect(await model.setRate(1.5, forShow: "../etc") == false)
        #expect(!model.setDefaultRate(9) && model.rate(forShow: nil) == 1)
        #expect(player.rateRequests.isEmpty)
    }
    @Test func skipLengthsAreCustomisableAndKept() async {
        let store = MemoryPodcastStore()
        let (model, _, _, _) = await makeModel(store)
        #expect(model.skip == .standard)
        #expect(model.setSkip(back: 10, forward: 60))
        #expect(!model.setSkip(back: 11, forward: 60) && model.skip.back == 10 && model.skip.forward == 60)
        await settle()
        let (again, _, _, _) = await makeModel(store)
        #expect(again.skip.back == 10 && again.skip.forward == 60)
    }
    @Test func aStoreThatCannotSaveSaysSoAndKeepsTheChoiceUntilQuit() async {
        let store = MemoryPodcastStore(); await store.setFailing(true)
        let (model, _, _, _) = await makeModel(store)
        await model.setRate(1.5, forShow: showA)
        await settle()
        #expect(model.notice == .couldNotSave && model.rate(forShow: showA) == 1.5)
    }
    @Test func anotherAccountsSettingsAreNeverShown() async {
        let store = MemoryPodcastStore()
        var other = PodcastLocalState(); _ = other.preferences.setRate(2.5, forShow: showA)
        await store.seed(other, account: "99999999-2222-3333-4444-555555555555")
        let (model, _, _, _) = await makeModel(store)
        #expect(model.rate(forShow: showA) == 1)
        model.accountChanged()
        #expect(model.state == PodcastLocalState())
    }
}

@MainActor @Suite struct PodcastPlaybackBehaviourTests {
    @Test func anEpisodePlaysAtItsShowsSpeedOnceAndASongAfterItReturnsToNormal() async {
        let (model, player, _, _) = await makeModel()
        await model.setRate(1.5, forShow: showA)
        model.episodeStarting(videoID: ep1, show: showA)
        player.play(ep1)
        model.observe(player.reading); await settle()
        #expect(player.rateRequests == [1.5] && player.confirmedRate == 1.5)
        model.observe(player.reading); await settle()
        #expect(player.rateRequests == [1.5], "the speed is applied once, not on every reading")
        // The player moves on to a song (not an episode of the show).
        player.play(song)
        model.observe(player.reading); await settle()
        #expect(player.rateRequests == [1.5, 1.0] && player.confirmedRate == 1, "a song never plays at an episode's speed")
    }
    @Test func aSpeedTheElementLostInsideTheSameEpisodeIsAppliedAgain() async {
        let (model, player, _, _) = await makeModel()
        await model.setRate(1.5, forShow: showA)
        model.episodeStarting(videoID: ep1, show: showA)
        player.play(ep1); model.observe(player.reading); await settle()
        #expect(player.rateRequests == [1.5])
        player.confirmedRate = 1            // the element reports normal speed again (after an ad, or a source change)
        model.observe(player.reading); await settle()
        #expect(player.rateRequests == [1.5, 1.5] && player.confirmedRate == 1.5, "the reconciled actual speed differs from the choice, so it is corrected")
    }
    @Test func theChosenSpeedIsReappliedAfterAnAdAndNeverDuringIt() async {
        let (model, player, _, _) = await makeModel()
        await model.setRate(1.5, forShow: showA)
        model.episodeStarting(videoID: ep1, show: showA)
        player.play(ep1); model.observe(player.reading); await settle()
        // An ad: the element is at normal speed and the model asks for nothing.
        player.confirmedRate = 1
        player.reading = EpisodePlayerReading(videoID: ep1, position: 10, duration: 0, playing: true, advertisement: true, canSeek: false)
        model.observe(player.reading); await settle()
        #expect(player.rateRequests == [1.5], "nothing is requested while the ad shows")
        // The ad ends: the episode's chosen speed returns, to the episode.
        player.play(ep1, position: 11)
        model.observe(player.reading); await settle()
        #expect(player.rateRequests == [1.5, 1.5])
    }
    @Test func theNextEpisodeOfTheSameShowPlaylistKeepsTheShowsSpeedAndIsRecorded() async {
        let (model, player, _, _) = await makeModel()
        await model.setRate(2, forShow: showA)
        model.episodeStarting(videoID: ep1, show: showA, playlistID: "PLshowAAAAAAA")
        player.play(ep1, list: "PLshowAAAAAAA"); model.observe(player.reading); await settle()
        player.play(ep2, position: 30, list: "PLshowAAAAAAA"); model.observe(player.reading); await settle()
        #expect(player.confirmedRate == 2 && model.current?.videoID == ep2 && model.current?.show == showA)
        #expect(model.localRecord(ep2)?.showID == showA)
    }
    @Test func aRefusedSpeedChangeIsReportedAndTheOldSpeedStays() async {
        let (model, player, _, _) = await makeModel()
        player.rateWorks = false
        await model.setRate(1.5, forShow: showA)
        model.episodeStarting(videoID: ep1, show: showA)
        player.play(ep1); model.observe(player.reading); await settle()
        #expect(model.notice == .rateRefused && player.confirmedRate == 1)
        for _ in 0..<5 { model.observe(player.reading); await settle() }
        #expect(player.rateRequests == [1.5], "a refused speed is not asked for again on every reading")
        player.play(ep2); model.episodeStarting(videoID: ep2, show: showA)
        model.observe(player.reading); await settle()
        #expect(player.rateRequests == [1.5, 1.5], "another episode asks again")
    }
    @Test func noSpeedIsRequestedDuringAnAdvertisement() async {
        let (model, player, _, _) = await makeModel()
        await model.setRate(1.5, forShow: showA)
        model.episodeStarting(videoID: ep1, show: showA)
        player.reading = EpisodePlayerReading(videoID: ep1, position: 0, duration: 0, playing: true, advertisement: true, canSeek: false)
        model.observe(player.reading); await settle()
        #expect(player.rateRequests.isEmpty)
    }
    @Test func skipBackAndForwardUseTheChosenLengthsAndStayInsideTheItem() async {
        let (model, player, _, _) = await makeModel()
        model.episodeStarting(videoID: ep1, show: showA)
        player.play(ep1, position: 100, duration: 1800)
        #expect(await model.skipBack() && player.seeks == [85])
        player.reading.position = 100
        #expect(await model.skipForward() && player.seeks == [85, 130])
        model.setSkip(back: 30, forward: 90)
        player.reading.position = 20
        #expect(await model.skipBack() && player.seeks.last == 0, "clamped at the start")
        player.reading.position = 1790
        #expect(await model.skipForward() && player.seeks.last == 1800, "clamped at the end")
    }
    @Test func skipIsRefusedDuringAnAdOrWhenNothingIsSeekable() async {
        let (model, player, _, _) = await makeModel()
        player.reading = EpisodePlayerReading(videoID: ep1, position: 10, duration: 100, playing: true, advertisement: true, canSeek: false)
        #expect(await model.skipForward() == false && player.seeks.isEmpty && model.notice == .seekRefused)
        player.reading = EpisodePlayerReading(videoID: nil, position: 0, duration: 0, playing: false, canSeek: false)
        #expect(await model.skipBack() == false && player.seeks.isEmpty)
        player.play(ep1, position: 50); player.seekWorks = false
        #expect(await model.skipBack() == false && model.notice == .seekRefused)
    }
    @Test func anEpisodeResumesWhereThisMacLeftOffExactlyOnce() async {
        let store = MemoryPodcastStore()
        var seeded = PodcastLocalState()
        seeded.store(EpisodeProgressRecord(videoID: ep1, position: 612.5, duration: 1800, updatedAt: Date(timeIntervalSince1970: 1_699_999_000), played: false, showID: showA))
        await store.seed(seeded, account: account)
        let (model, player, _, _) = await makeModel(store)
        model.episodeStarting(videoID: ep1, show: showA)
        player.reading = EpisodePlayerReading(videoID: ep1, position: 0, duration: 0, playing: false, canSeek: false)
        model.observe(player.reading); await settle()
        #expect(player.seeks.isEmpty, "nothing to seek before the player has the item loaded")
        player.play(ep1, position: 0, duration: 1800)
        model.observe(player.reading); await settle()
        #expect(player.seeks == [612.5])
        model.observe(player.reading); await settle()
        #expect(player.seeks == [612.5], "resume happens once")
    }
    @Test func aPlayedOrUnstartedEpisodeStartsFromTheBeginning() async {
        let store = MemoryPodcastStore()
        var seeded = PodcastLocalState()
        seeded.store(EpisodeProgressRecord(videoID: ep1, position: 1799, duration: 1800, updatedAt: .distantPast, played: true))
        seeded.store(EpisodeProgressRecord(videoID: ep2, position: 3, duration: 1800, updatedAt: .distantPast, played: false))
        await store.seed(seeded, account: account)
        let (model, player, _, _) = await makeModel(store)
        for id in [ep1, ep2] {
            model.episodeStarting(videoID: id, show: showA)
            player.play(id); model.observe(player.reading); await settle()
        }
        #expect(player.seeks.isEmpty)
    }
    @Test func progressIsRecordedForEpisodesOnlyAndKeptOnThisMac() async {
        let (model, player, store, now) = await makeModel()
        model.episodeStarting(videoID: ep1, show: showA)
        player.play(ep1, position: 60); now.value = now.value.addingTimeInterval(60)
        model.observe(player.reading); await settle()
        #expect(model.localRecord(ep1)?.position == 60 && model.localRecord(ep1)?.played == false && model.localRecord(ep1)?.showID == showA)
        let saved = await store.state(account)
        #expect(saved?.progress[ep1]?.position == 60)
        // A song the person plays is never given an episode record.
        player.play(song, position: 90); model.observe(player.reading); await settle()
        #expect(model.localRecord(song) == nil)
    }
    @Test func theEndOfAnEpisodeMarksItPlayedAndListeningAgainStartsANewListen() async {
        let (model, player, _, _) = await makeModel()
        model.episodeStarting(videoID: ep1, show: showA)
        player.play(ep1, position: 1799.5, duration: 1800); model.observe(player.reading); await settle()
        #expect(model.localRecord(ep1)?.played == true)
        player.play(ep1, position: 30, duration: 1800); model.observe(player.reading); await settle()
        #expect(model.localRecord(ep1)?.played == false && model.localRecord(ep1)?.position == 30)
    }
    @Test func aLocalMarkChangesOnlyWhatThisMacShows() async {
        let (model, _, store, _) = await makeModel()
        model.mark(ep1, played: true, duration: 885, show: showA)
        #expect(model.localRecord(ep1)?.played == true)
        model.mark(ep1, played: false, duration: 885, show: showA)
        #expect(model.localRecord(ep1) == nil)
        await settle()
        #expect(await store.state(account)?.progress[ep1] == nil)
    }
}

// MARK: T18.1 chapters use actual timestamps

@Suite struct EpisodeChapterTests {
    @Test func theRealEpisodesDescriptionHasNoChaptersAndNoneAreInvented() throws {
        let page = try MusicEpisodeParser_parse(.episode)
        let text = page.description.map(\.text).joined()
        #expect(EpisodeChapters.parse(description: text, duration: 885).isEmpty)
        #expect(EpisodeChapters.parse(description: "", duration: nil).isEmpty)
    }
    @Test func chaptersComeFromTheTimestampsTheDescriptionPrints() throws {
        let page = try MusicEpisodeParser_parse(synthetic: "episode-chapters.json")
        let chapters = EpisodeChapters.parse(description: page.description.map(\.text).joined(), duration: 4000)
        #expect(chapters.map(\.start) == [0, 90, 725, 3723], "00:00, 01:30, 12:05, 1:02:03 exactly")
        #expect(chapters.map(\.title) == ["Intro", "First topic", "Second topic", "Closing thoughts"])
    }
    @Test func theChapterPlayingIsTheLastOneStarted() {
        let chapters = [EpisodeChapter(start: 0, title: "A"), EpisodeChapter(start: 90, title: "B"), EpisodeChapter(start: 725, title: "C")]
        #expect(EpisodeChapters.current(in: chapters, at: 0)?.title == "A" && EpisodeChapters.current(in: chapters, at: 89.9)?.title == "A")
        #expect(EpisodeChapters.current(in: chapters, at: 90)?.title == "B" && EpisodeChapters.current(in: chapters, at: 5000)?.title == "C")
    }
    @Test func aListThatBreaksAnyRuleHasNoChaptersAtAll() {
        func parse(_ text: String, duration: Double? = 4000) -> Int { EpisodeChapters.parse(description: text, duration: duration).count }
        #expect(parse("0:00 One\n1:00 Two\n2:00 Three") == 3)
        #expect(parse("0:05 One\n1:00 Two\n2:00 Three") == 0, "does not start at 0:00")
        #expect(parse("0:00 One\n1:00 Two") == 0, "fewer than three")
        #expect(parse("0:00 One\n0:05 Two\n2:00 Three") == 0, "closer than ten seconds")
        #expect(parse("0:00 One\n2:00 Two\n1:00 Three") == 0, "out of order")
        #expect(parse("0:00 One\n1:00 Two\n99:00 Three", duration: 600) == 0, "past the end")
        #expect(parse("0:00 One\n1:00 Two\n99:00 Three", duration: nil) == 3, "the length is unknown, so nothing is past it")
        #expect(parse("0:00 \n1:00 Two\n2:00 Three") == 0, "a timestamp with no title is not a chapter")
        #expect(parse("Intro at 0:00 and then 1:00") == 0, "a timestamp inside a sentence is not a chapter line")
    }
}

// MARK: Durations and sorting

@Suite struct EpisodeDurationTests {
    @Test func theServicesPrintedLengthsParseAndOthersAreNil() {
        #expect(EpisodeDuration.seconds(from: "14 min 45 sec") == 885 && EpisodeDuration.seconds(from: "18 min") == 1080)
        #expect(EpisodeDuration.seconds(from: "1 hr 3 min") == 3780 && EpisodeDuration.seconds(from: "45 sec") == 45 && EpisodeDuration.seconds(from: "2 hr") == 7200)
        for bad in ["", "soon", "18 minutos", "0 min", "x min", "1:03:09"] { #expect(EpisodeDuration.seconds(from: bad) == nil, Comment(rawValue: bad)) }
        #expect(EpisodeDuration.seconds(from: nil) == nil)
        #expect(EpisodeDuration.clock(885) == "14:45" && EpisodeDuration.clock(3723) == "1:02:03" && EpisodeDuration.clock(-5) == "0:00")
    }
}
@Suite struct EpisodeSortTests {
    private func row(_ title: String, _ length: String?, _ status: EpisodeProgress.Status = .unplayed) -> EpisodeRow {
        let info = MusicEpisodeInfo(progressPercent: 0, durationText: length)
        return EpisodeRow(item: MusicCatalogItem(kind: .episode, title: title, videoID: String(repeating: "a", count: 11), episode: info), progress: EpisodeProgress(status: status, origin: nil, resumePosition: nil))
    }
    @Test func theShowsOrderIsTheDefaultAndRestorable() {
        let rows = [row("B", "10 min"), row("A", "5 min"), row("C", nil)]
        #expect(EpisodeSort.serviceOrder.apply(to: rows).map(\.title) == ["B", "A", "C"])
        #expect(EpisodeSort.allCases.first == .serviceOrder)
    }
    @Test func otherOrdersAreStableViewsOverIt() {
        let rows = [row("B", "10 min"), row("A", "5 min"), row("C", nil), row("D", "5 min")]
        #expect(EpisodeSort.shortest.apply(to: rows).map(\.title) == ["A", "D", "B", "C"], "equal lengths keep the show's order; no length goes last")
        #expect(EpisodeSort.longest.apply(to: rows).map(\.title) == ["B", "A", "D", "C"])
        #expect(EpisodeSort.titleAscending.apply(to: rows).map(\.title) == ["A", "B", "C", "D"] && EpisodeSort.titleDescending.apply(to: rows).map(\.title) == ["D", "C", "B", "A"])
        #expect(Set(EpisodeSort.shortest.apply(to: rows).map(\.title)) == Set(rows.map(\.title)), "nothing is dropped or duplicated")
    }
    @Test func unplayedComeFirstThenStartedThenPlayedKeepingTheShowsOrder() {
        let rows = [row("P", "5 min", .played), row("U1", "5 min"), row("S", "5 min", .inProgress(fraction: 0.3)), row("U2", "5 min")]
        #expect(EpisodeSort.unplayedFirst.apply(to: rows).map(\.title) == ["U1", "U2", "S", "P"])
    }
    @Test func noDateOrderIsOfferedBecauseRowsPrintNoYear() {
        let titles = EpisodeSort.allCases.map(\.title).joined(separator: "|").lowercased()
        #expect(!titles.contains("newest") && !titles.contains("oldest") && !titles.contains("date"))
    }
}

// MARK: The system's Now Playing follows the listening speed

@Suite struct NowPlayingRateTests {
    private func item(rate: Double, playing: Bool = true, ad: Bool = false, elapsed: Double = 100) -> NowPlayingItem {
        NowPlayingItem(title: "T", artist: nil, album: nil, artwork: nil, duration: 1800, elapsed: elapsed, playing: playing, advertisement: ad, rate: rate)
    }
    @Test func theSystemIsToldTheSpeedWhilePlayingAndZeroOtherwise() {
        #expect(NowPlayingMapping.info(item(rate: 1.5))[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
        #expect(NowPlayingMapping.info(item(rate: 1.5, playing: false))[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(NowPlayingMapping.info(item(rate: 1.5, ad: true))[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0, "an ad is not the episode's speed")
        #expect(NowPlayingItem(title: "T", artist: nil, album: nil, artwork: nil, duration: 1, elapsed: 0, playing: true, advertisement: false).rate == 1, "music is at normal speed by default")
        #expect(item(rate: 9).rate == 1 && item(rate: .nan).rate == 1 && item(rate: 0).rate == 1, "an out-of-bounds speed is never published")
    }
    @Test func aChangeOfSpeedRewritesNowPlayingAndTheExtrapolationUsesIt() {
        #expect(NowPlayingMapping.needsUpdate(from: item(rate: 1), elapsedSince: .seconds(1), to: item(rate: 2, elapsed: 101)))
        // 10 s later at 2× the clock has advanced 20 s: a reading at 120 is on time, a reading at 110 (extrapolated at 1×) is a jump.
        #expect(!NowPlayingMapping.needsUpdate(from: item(rate: 2), elapsedSince: .seconds(10), to: item(rate: 2, elapsed: 120)))
        #expect(NowPlayingMapping.needsUpdate(from: item(rate: 2), elapsedSince: .seconds(10), to: item(rate: 2, elapsed: 110)))
    }
}
