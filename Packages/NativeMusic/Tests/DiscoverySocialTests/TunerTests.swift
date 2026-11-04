import AccountSession
import Domain
import Features
import Foundation
import Testing

/// T20.2 — The tuner exposes only supplied diversity/discovery controls; radio keeps the service's context.
@Suite @MainActor struct RadioSeedTests {
    private let action = MusicRadioAction(playlistID: "RDAMVMvid00000001", videoID: "vid00000001", params: "wAEB")
    private func song(_ title: String, video: String = "vid00000001", radio: MusicRadioAction?, context: String? = nil, playlist: String? = nil) -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: title, details: ["Artist"], videoID: video, playlistID: playlist, contextPlaylistID: context, radio: radio)
    }
    @Test func onlyAnEntryWhoseOwnMenuOffersARadioIsASeed() {
        let book = RadioSeedBook()
        book.note(items: [
            song("Has radio", radio: action),
            // An RD-prefixed playlist the entry merely plays is not a radio: curated and editorial playlists share the prefix.
            song("Editorial context", video: "vid00000002", radio: nil, context: "RDCLAKeditorialplaylist"),
            MusicCatalogItem(kind: .playlist, title: "Hits", browseID: "VLRDCLAK5uyeditorial", playlistID: "RDCLAK5uyeditorial"),
            MusicCatalogItem(kind: .album, title: "An album", browseID: "MPREb_x", playlistID: "OLAK5uy_album"),
            MusicCatalogItem(kind: .artist, title: "An artist", browseID: "UCartist", radio: MusicRadioAction(playlistID: "RDEMartistradio0001", params: "wAEB")),
            MusicCatalogItem(kind: .category, title: "A mood", browseID: "FEmusic_mood", radio: MusicRadioAction(playlistID: "RDmoodnotaseed00", params: "wAEB")),
            MusicCatalogItem(kind: .song, title: "", videoID: "vid00000004", radio: MusicRadioAction(playlistID: "RDAMVMvid00000004"))])
        #expect(book.seeds.map(\.title) == ["An artist", "Has radio"])
        #expect(book.seeds.first { $0.title == "Has radio" }?.videoID == "vid00000001", "a song's radio starts from the track its action named")
        #expect(book.seeds.first { $0.title == "An artist" }?.videoID == nil)
    }
    @Test func theActionsParametersAreKept() {
        let book = RadioSeedBook()
        book.note(items: [song("Has radio", radio: action)])
        #expect(book.seeds.first?.params == "wAEB")
        let page = MusicBrowsePage(header: MusicPageHeader(title: "Page", actions: MusicPageActions(radio: "RDEMpageradio0001", radioAction: MusicRadioAction(playlistID: "RDEMpageradio0001", params: "wAEB"))), shelves: [])
        book.note(page: page)
        #expect(book.seeds.first { $0.id == "RDEMpageradio0001" }?.params == "wAEB")
    }
    @Test func aPagesOwnRadioActionIsASeedAndAPageWithoutOneIsNot() {
        let book = RadioSeedBook()
        func page(_ title: String, radio: MusicRadioAction?) -> MusicBrowsePage {
            MusicBrowsePage(header: MusicPageHeader(title: title, subtitle: ["Artist"], actions: MusicPageActions(radio: radio?.playlistID, radioAction: radio)), shelves: [])
        }
        book.note(page: page("Radio page", radio: MusicRadioAction(playlistID: "RDEMpageradio0001", params: "wAEB")))
        book.note(page: page("No radio", radio: nil))
        // A page that only has a play-all / shuffle playlist (an RD id) but no radio action is not a seed.
        book.note(page: MusicBrowsePage(header: MusicPageHeader(title: "Shuffle only", actions: MusicPageActions(play: "RDCLAKeditorialplaylist", shuffle: "RDCLAKeditorialplaylist")), shelves: []))
        #expect(book.seeds.map(\.id) == ["RDEMpageradio0001"])
        #expect(book.seeds.first?.kind == .page)
    }
    @Test func seedsAreNewestFirstUniqueAndBounded() {
        let book = RadioSeedBook(limit: 3)
        for index in 1...5 { book.note(items: [song("S\(index)", video: "vid0000000\(index)", radio: MusicRadioAction(playlistID: "RDAMVMvid0000000\(index)", videoID: "vid0000000\(index)", params: "wAEB"))]) }
        #expect(book.seeds.map(\.title) == ["S5", "S4", "S3"])
        book.note(items: [song("S3 again", video: "vid00000003", radio: MusicRadioAction(playlistID: "RDAMVMvid00000003", videoID: "vid00000003", params: "wAEB"))])
        #expect(book.seeds.map(\.title) == ["S3 again", "S5", "S4"])
    }
    @Test func anAccountChangeEmptiesTheBook() {
        let book = RadioSeedBook()
        book.note(items: [song("A", radio: action)])
        book.accountChanged()
        #expect(book.seeds.isEmpty)
    }
}

@Suite @MainActor struct TunerModelTests {
    private let seed = RadioSeed(id: "RDAMVMvid00000001", kind: .song, title: "Seed song", subtitle: "Artist", videoID: "vid00000001", params: "wAEB")
    private func rig(controls: [TunerControl] = [], playback: SearchPlayback = .available, performer: RecordingPerformer = RecordingPerformer(), unresolved: String? = nil) -> (TunerModel, RecordingPerformer) {
        let book = RadioSeedBook()
        book.note(items: [MusicCatalogItem(kind: .song, title: "Seed song", details: ["Artist"], videoID: "vid00000001",
                                           radio: MusicRadioAction(playlistID: "RDAMVMvid00000001", videoID: "vid00000001", params: "wAEB"))])
        Retained.keep(performer)
        let model = TunerModel(seedBook: book, performer: performer, source: FixedControls(controls, unresolved: unresolved), signedIn: { playback })
        return (model, performer)
    }
    private let supplied = [
        TunerControl(id: "variety", title: "Variety", options: [TunerOption(id: "familiar", title: "Familiar", selected: true, params: "famParams"),
                                                                TunerOption(id: "discover", title: "Discover", playlistID: "RDAMVMother0000001", params: "disParams")]),
        TunerControl(id: "mood", title: "Mood", options: [TunerOption(id: "calm", title: "Calm", params: "calmParams")])]

    @Test func startingARadioSendsExactlyTheServicesPlaylistTrackAndParameters() async {
        let (tuner, performer) = rig()
        let seed = try! #require(tuner.seeds.first)
        await tuner.start(seed)
        #expect(performer.plays == [.init(playlistID: "RDAMVMvid00000001", title: "Seed song", videoID: "vid00000001", params: "wAEB")], "the endpoint's own parameters go with the request")
        #expect(tuner.context?.seed == seed && tuner.context?.playlistID == "RDAMVMvid00000001")
        #expect(tuner.startCount == 1)
    }
    @Test func aSeedTheBookDoesNotHoldIsNotStarted() async {
        let (tuner, performer) = rig()
        await tuner.start(RadioSeed(id: "RDmadeupseed00000", kind: .song, title: "Made up"))
        #expect(performer.plays.isEmpty && tuner.context == nil)
    }
    @Test func nothingIsStartedWithoutASessionAndEachCaseSaysWhy() async {
        let (out, p1) = rig(playback: .needsSignIn)
        await out.start(out.seeds[0])
        #expect(out.failure == .needsSignIn && p1.plays.isEmpty)
        let (ended, p2) = rig(playback: .sessionExpired)
        await ended.start(ended.seeds[0])
        #expect(ended.failure == .sessionEnded && p2.plays.isEmpty)
        #expect(TunerFailure.needsSignIn.message != TunerFailure.sessionEnded.message)
    }
    @Test func aQueueThatWasReadAndCarriedNoControlsSaysSoAndIsNotUnresolved() async {
        let (tuner, _) = rig(controls: [])
        #expect(tuner.capability == .noRadio)
        await tuner.start(tuner.seeds[0])
        #expect(tuner.controls.isEmpty)
        #expect(tuner.capability == .noControlsSupplied)
    }
    @Test func aSourceThatCannotReadTheQueueIsUnresolvedNeverAbsent() async {
        let (tuner, _) = rig(controls: [], unresolved: "Cannot read the queue.")
        await tuner.start(tuner.seeds[0])
        #expect(tuner.controls.isEmpty)
        #expect(tuner.capability == .unresolved("Cannot read the queue."))
        #expect(tuner.capability != .noControlsSupplied, "an unread queue is not a queue with no controls")
    }
    @Test func theApplicationsOwnSourceIsUnresolvedAndDoesNotBlameTheService() async {
        let own = UnresolvedRadioControlsSource()
        let reason = try! #require(own.unresolved)
        #expect(reason.contains("doesn’t read a radio’s queue") && !reason.contains("YouTube Music didn’t supply"))
        let book = RadioSeedBook()
        book.note(items: [MusicCatalogItem(kind: .song, title: "S", videoID: "vid00000001", radio: MusicRadioAction(playlistID: "RDAMVMvid00000001", videoID: "vid00000001", params: "wAEB"))])
        let performer = RecordingPerformer(); Retained.keep(performer)
        let tuner = TunerModel(seedBook: book, performer: performer)
        await tuner.start(tuner.seeds[0])
        guard case .unresolved = tuner.capability else { Issue.record("the default tuner must report unresolved, not \(tuner.capability)"); return }
    }
    @Test func aQueueReadByTheSeamBecomesTheServicesFilterChipsExactly() async {
        let chips = [MusicRadioChip(title: "Popular", isSelected: true, playlistID: "RDAMVMvid00000001", params: "popularParams"),
                     MusicRadioChip(title: "Deep cuts", isSelected: false, playlistID: "RDAMVMvid00000001", params: "deepParams")]
        let source = QueueRadioControlsSource(reader: { _ in MusicRadioQueue(chips: chips) })
        let book = RadioSeedBook()
        book.note(items: [MusicCatalogItem(kind: .song, title: "Seed song", videoID: "vid00000001", radio: MusicRadioAction(playlistID: "RDAMVMvid00000001", videoID: "vid00000001", params: "wAEB"))])
        let performer = RecordingPerformer(); Retained.keep(performer)
        let tuner = TunerModel(seedBook: book, performer: performer, source: source)
        await tuner.start(tuner.seeds[0])
        #expect(tuner.capability == .controlsSupplied(1))
        let control = try! #require(tuner.controls.first)
        #expect(control.options.map(\.title) == ["Popular", "Deep cuts"] && control.options.map(\.selected) == [true, false])
        await tuner.choose(option: "RDAMVMvid00000001|deepParams", in: "queue-filter", suppliedBy: tuner.controlsIdentity)
        #expect(performer.plays.count == 1 && tuner.failure == .unsupportedFilter, "legacy performers cannot silently degrade canonical queue updates")
        #expect(tuner.context?.seed.id == "RDAMVMvid00000001")
    }
    @Test func publishedPlayerParamsAreKeptAndUnsupportedChoicesNeverStartPlayback() async {
        let book = RadioSeedBook()
        book.note(items: [MusicCatalogItem(kind: .song, title: seed.title, videoID: seed.videoID,
            radio: MusicRadioAction(playlistID: seed.id, videoID: seed.videoID, params: seed.params))])
        let performer = RecordingPerformer()
        let source = QueueRadioControlsSource { _ in MusicRadioQueue(chips: [
            MusicRadioChip(title: "Workout", isSelected: false, playlistID: "RDpublished", params: "p", playerParams: "extra")]) }
        let model = TunerModel(seedBook: book, performer: performer, source: source)
        await model.start(book.seeds[0])
        #expect(model.controls.first?.options.first?.playerParams == "extra")
        await model.choose(option: "RDpublished|p", in: "queue-filter", suppliedBy: model.controlsIdentity)
        #expect(model.failure == .unsupportedFilter && performer.plays.count == 1)
        let command = try! #require(MusicQueueFilterCommand(playlistID: "RDpublished", params: "p", playerParams: "extra"))
        #expect(await performer.playRadioFilter(command, title: "Workout") == .failed)
        #expect(performer.captureRadioQueueScope(playlistID: command.playlistID) == nil)
        #expect(!performer.radioQueueScopeIsCurrent(UUID()))
        #expect(await performer.applyRadioFilter(command, scope: UUID()) == .failed)
        #expect(performer.plays.count == 1, "default implementation never drops extra fields or queue semantics")
    }
    @Test func unreadableQueueThrowsWhileAReadEmptyQueueIsAnAnswer() async throws {
        let none = QueueRadioControlsSource(reader: { _ in throw MusicSessionError.unrecognised })
        let empty = QueueRadioControlsSource(reader: { _ in MusicRadioQueue(chips: []) })
        let context = RadioContext(seed: seed, playlistID: seed.id, params: seed.params, choices: [:])
        await #expect(throws: MusicSessionError.unrecognised) { try await none.controls(for: context) }
        #expect(try await empty.controls(for: context).isEmpty)
    }
    @Test func retryReadsFiltersWithoutRestartingAndAccountChangeFencesLateAnswers() async {
        let book = RadioSeedBook()
        book.note(items: [MusicCatalogItem(kind: .song, title: seed.title, videoID: seed.videoID,
            radio: MusicRadioAction(playlistID: seed.id, videoID: seed.videoID, params: seed.params))])
        let performer = RecordingPerformer()
        let source = HeldRadioControls()
        let model = TunerModel(seedBook: book, performer: performer, source: source)
        let start = Task { await model.start(book.seeds[0]) }
        while !(await source.holding) { await Task.yield() }
        #expect(model.capability == .loadingControls && model.context != nil)
        await source.fail(); await start.value
        #expect(model.capability == .controlsFailed && model.failure == nil)
        #expect(performer.plays.count == 1)
        let retry = Task { await model.retryControls() }
        while !(await source.holding) { await Task.yield() }
        await source.finish(); await retry.value
        #expect(model.capability == .noControlsSupplied && performer.plays.count == 1)
        let stale = Task { await model.retryControls() }
        while !(await source.holding) { await Task.yield() }
        model.accountChanged()
        await source.finish(); await stale.value
        #expect(model.context == nil && model.controls.isEmpty && !model.busy)
    }
    @Test func suppliedControlsAreExposedExactlyAsSuppliedNothingAddedOrRenamed() async {
        let (tuner, _) = rig(controls: supplied)
        await tuner.start(tuner.seeds[0])
        #expect(tuner.controls == supplied)
        #expect(tuner.capability == .controlsSupplied(2))
        #expect(tuner.controls.flatMap(\.options).map(\.title) == ["Familiar", "Discover", "Calm"])
    }
    @Test func choosingAnOptionRestartsTheSameSeedWithWhatThatOptionPublished() async {
        let (tuner, performer) = rig(controls: supplied)
        await tuner.start(tuner.seeds[0])
        await tuner.choose(option: "discover", in: "variety", suppliedBy: tuner.controlsIdentity)
        #expect(performer.plays.count == 2)
        #expect(performer.plays[1] == .init(playlistID: "RDAMVMother0000001", title: "Seed song", videoID: nil, params: "disParams"))
        #expect(tuner.context?.seed == seed, "the seed is kept")
        #expect(tuner.context?.choices == ["variety": "discover"])
        #expect(tuner.controls.first { $0.id == "variety" }?.selectedOption?.id == "familiar")
        #expect(tuner.selectionUnconfirmed)
        await tuner.retryControls()
        #expect(tuner.selectionUnconfirmed && tuner.controls == supplied)
        #expect(tuner.controls.first { $0.id == "mood" } == supplied[1], "the other control is untouched")
    }
    @Test func anOptionWithNoPlaylistKeepsTheRadiosPlaylistAndAddsItsParameters() async {
        let (tuner, performer) = rig(controls: supplied)
        await tuner.start(tuner.seeds[0])
        await tuner.choose(option: "calm", in: "mood", suppliedBy: tuner.controlsIdentity)
        #expect(performer.plays[1].playlistID == "RDAMVMvid00000001" && performer.plays[1].params == "calmParams")
    }
    @Test func twoChoicesAreKeptTogetherAndTheSeedSurvivesBoth() async {
        let (tuner, performer) = rig(controls: supplied)
        await tuner.start(tuner.seeds[0])
        await tuner.choose(option: "discover", in: "variety", suppliedBy: tuner.controlsIdentity)
        await tuner.choose(option: "calm", in: "mood", suppliedBy: tuner.controlsIdentity)
        #expect(tuner.context?.choices == ["variety": "discover", "mood": "calm"])
        #expect(tuner.context?.seed == seed)
        let plays = performer.plays
        #expect(plays.count == 3 && plays[2].playlistID == "RDAMVMother0000001" && plays[2].params == "calmParams", "the second choice keeps the playlist the first one chose")
    }
    @Test func aControlOrOptionNobodySuppliedIsRefusedAndSendsNothing() async {
        let (tuner, performer) = rig(controls: supplied)
        await tuner.start(tuner.seeds[0])
        await tuner.choose(option: "extreme", in: "variety", suppliedBy: tuner.controlsIdentity)
        #expect(tuner.failure == .controlNotSupplied)
        await tuner.choose(option: "familiar", in: "novelty", suppliedBy: tuner.controlsIdentity)
        #expect(tuner.failure == .controlNotSupplied)
        #expect(performer.plays.count == 1)
        let (bare, p) = rig(controls: [])
        await bare.choose(option: "familiar", in: "variety", suppliedBy: bare.controlsIdentity)
        #expect(p.plays.isEmpty && bare.context == nil)
    }
    @Test func aRefusedRestartKeepsTheRadioThatWasPlaying() async {
        let (tuner, performer) = rig(controls: supplied)
        await tuner.start(tuner.seeds[0])
        let before = tuner.context
        performer.outcome = .failed
        await tuner.choose(option: "discover", in: "variety", suppliedBy: tuner.controlsIdentity)
        #expect(tuner.failure == .notStarted)
        #expect(tuner.context == before, "what was playing is unchanged")
        #expect(tuner.controls.first { $0.id == "variety" }?.selectedOption?.id == "familiar")
    }
    @Test func aRefusedFirstStartLeavesNoRadio() async {
        let performer = RecordingPerformer(); performer.outcome = .failed
        let (tuner, _) = rig(performer: performer)
        await tuner.start(tuner.seeds[0])
        #expect(tuner.context == nil && tuner.failure == .notStarted)
    }
    @Test func aStaleStartIsReportedAsAnEndedSession() async {
        let performer = RecordingPerformer(); performer.outcome = .stale
        let (tuner, _) = rig(performer: performer)
        await tuner.start(tuner.seeds[0])
        #expect(tuner.failure == .sessionEnded)
    }
    @Test func anAccountChangeDropsTheRadioItsControlsAndTheSeeds() async {
        let (tuner, _) = rig(controls: supplied)
        await tuner.start(tuner.seeds[0])
        tuner.accountChanged()
        #expect(tuner.context == nil && tuner.controls.isEmpty && tuner.seeds.isEmpty && tuner.failure == nil)
        #expect(tuner.capability == .noRadio)
    }
    @Test func serviceConfirmationSurvivesMetadataRetry() async {
        let confirmed = [TunerControl(id: "variety", title: "Variety", options: [
            TunerOption(id: "discover", title: "Discover", selected: true, params: "disParams")])]
        let (tuner, performer) = rig(controls: confirmed)
        await tuner.start(tuner.seeds[0])
        #expect(performer.plays[0].videoID == seed.videoID)
        await tuner.choose(option: "discover", in: "variety", suppliedBy: tuner.controlsIdentity)
        #expect(tuner.controls == confirmed && !tuner.selectionUnconfirmed)
        await tuner.retryControls()
        #expect(tuner.controls == confirmed && !tuner.selectionUnconfirmed)
        #expect(performer.plays.count == 2)
    }
    @Test func theApplicationsOwnControlsSourceSuppliesNone() async throws {
        let (tuner, _) = rig()
        let context = RadioContext(seed: seed, playlistID: seed.id, params: nil, choices: [:])
        #expect(try await UnresolvedRadioControlsSource().controls(for: context).isEmpty)
        _ = tuner
    }
}
struct FixedControls: RadioControlsSource {
    let controls: [TunerControl]
    let unresolved: String?
    init(_ controls: [TunerControl], unresolved: String? = nil) { self.controls = controls; self.unresolved = unresolved }
    func controls(for context: RadioContext) async -> [TunerControl] { controls }
}

private actor HeldRadioControls: RadioControlsSource {
    nonisolated var unresolved: String? { nil }
    private var waiter: CheckedContinuation<[TunerControl], any Error>?
    var holding: Bool { waiter != nil }
    func controls(for context: RadioContext) async throws -> [TunerControl] {
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func fail() { waiter?.resume(throwing: MusicSessionError.network); waiter = nil }
    func finish() { waiter?.resume(returning: []); waiter = nil }
}
