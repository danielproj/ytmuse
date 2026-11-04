import AccountSession
import Domain
import Features
import Foundation
import Testing
import YouTubeMusicAdapter

private let policy = YouTubeMusicListening.policy

/// Drives the recorder with a simulated player: real-shaped readings once a second of clock time.
private struct Player {
    var recorder = ListeningHistoryRecorder(policy: policy)
    var clock = 1_000.0
    var position = 0.0
    var records: [LocalHistoryRecord] = []
    mutating func feed(video: String? = "aaaaaaaaaa1", title: String? = "Song", duration: Double = 200, playing: Bool = true, buffering: Bool = false,
                       ended: Bool = false, content: ListeningObservation.Content = .track, advance: Double = 1, clockStep: Double = 1, position set: Double? = nil) {
        clock += clockStep
        if let set { position = set } else if playing && !buffering && content == .track { position += advance }
        if let record = recorder.observe(ListeningObservation(videoID: video, title: title, artist: "Artist", position: position, duration: duration, playing: playing,
                                                              buffering: buffering, ended: ended, content: content, monotonic: clock, wall: Date(timeIntervalSince1970: 1_700_000_000 + clock))) { records.append(record) }
    }
    var started: Set<String> = []
    /// Listens for `seconds` of clock time. The first reading of a track only sets the baseline, so it is fed before the seconds count.
    mutating func listen(_ seconds: Int, video: String? = "aaaaaaaaaa1", duration: Double = 200) {
        if let video, started.insert(video).inserted { position = 0; feed(video: video, duration: duration, advance: 0) }
        for _ in 0..<seconds { feed(video: video, duration: duration) }
    }
}

/// T12.4: what counts as a listen is defined by the adapter's policy; buffering, previews, ads and repeated end reports never make a play.
@Suite struct ListeningHistoryRecorderTests {
    @Test func theAdapterDefinesTheRule() {
        #expect(policy.threshold(duration: 200) == 30 && policy.threshold(duration: 40) == 20 && policy.threshold(duration: 10) == 5)
        #expect(policy.threshold(duration: 0) == nil && policy.threshold(duration: .infinity) == nil && policy.threshold(duration: .nan) == nil)
    }
    @Test func aPlayIsRecordedOnceWhenTheThresholdIsReachedAndNotBefore() {
        var player = Player()
        player.listen(29)
        #expect(player.records.isEmpty)
        player.listen(1)
        #expect(player.records.count == 1)
        player.listen(100)
        #expect(player.records.count == 1, "one occurrence is one play however long it continues")
        let record = player.records[0]
        #expect(record.videoID == "aaaaaaaaaa1" && record.title == "Song" && record.artist == "Artist" && record.listenedSeconds >= 30 && record.sync == .localOnly)
    }
    @Test func timeHeardAfterThePlayCountsIsToppedUpOnTheSameRecord() {
        var player = Player()
        player.listen(30)
        #expect(player.records.count == 1 && player.recorder.takeUpdate() == nil, "the play itself carries the time so far")
        let id = player.records[0].id
        player.listen(59)
        #expect(player.recorder.takeUpdate() == nil, "less than a minute more is not written while it keeps playing")
        player.listen(1)
        let periodic = player.recorder.takeUpdate()
        #expect(periodic?.id == id && periodic?.listenedSeconds ?? 0 >= 89, "at most a minute of heard time goes unsaved")
        #expect(player.recorder.takeUpdate() == nil, "taking an update clears it")
        player.listen(20)
        player.feed(playing: false)
        let paused = player.recorder.takeUpdate()
        #expect(paused?.id == id && paused?.listenedSeconds ?? 0 >= 109, "pausing saves what was heard")
        player.feed(playing: false)
        #expect(player.recorder.takeUpdate() == nil, "nothing new heard, nothing to save")
        #expect(player.records.count == 1, "a top-up is never a second play")
    }
    @Test func replacingOrEndingATrackSavesItsFullTime() {
        var player = Player()
        player.listen(150)
        _ = player.recorder.takeUpdate()
        player.listen(10)
        player.listen(1, video: "bbbbbbbbbb2")
        let switched = player.recorder.takeUpdate()
        #expect(switched?.videoID == "aaaaaaaaaa1" && switched?.id == player.records[0].id && switched?.listenedSeconds ?? 0 >= 159)
        player.listen(40, video: "bbbbbbbbbb2")
        player.feed(video: "bbbbbbbbbb2", ended: true)
        let ended = player.recorder.takeUpdate()
        #expect(ended?.videoID == "bbbbbbbbbb2" && ended?.id == player.records[1].id && ended?.listenedSeconds ?? 0 >= 40)
        player.feed(video: "bbbbbbbbbb2", ended: true)
        #expect(player.recorder.takeUpdate() == nil, "a repeated end report changes nothing")
    }
    @Test func aSkippedTrackNeverProducesAnUpdate() {
        var player = Player()
        player.listen(20)
        player.listen(1, video: "bbbbbbbbbb2")
        #expect(player.records.isEmpty && player.recorder.takeUpdate() == nil)
    }
    @Test func aShortItemNeedsHalfOfIt() {
        var player = Player()
        player.listen(9, duration: 20)
        #expect(player.records.isEmpty)
        player.listen(1, duration: 20)
        #expect(player.records.count == 1)
    }
    @Test func nothingCountsBeforeThePlayerSaysHowLongItIs() {
        var player = Player()
        for _ in 0..<60 { player.feed(duration: 0) }
        #expect(player.records.isEmpty)
    }
    @Test func bufferingAndPausedTimeAreNotListening() {
        var player = Player()
        player.listen(20)
        for _ in 0..<60 { player.feed(playing: false, buffering: true) }
        for _ in 0..<60 { player.feed(playing: false) }
        #expect(player.records.isEmpty)
        player.listen(9)
        #expect(player.records.isEmpty, "28 seconds heard: the first reading after a gap only sets the baseline")
        player.listen(1)
        #expect(player.records.isEmpty, "29 seconds heard")
        player.listen(1)
        #expect(player.records.count == 1)
    }
    @Test func aPlayerThatStillReportsPlayingWhileBufferingIsNotListening() {
        var player = Player()
        player.listen(10)
        // The page's position creeps on (from buffered audio) while it says it is buffering: that is still not listening.
        for _ in 0..<60 { player.feed(playing: true, buffering: true, position: player.position + 1) }
        #expect(player.records.isEmpty)
        player.listen(10)
        #expect(player.records.isEmpty, "10 + 9 seconds heard: the buffering time was not listening")
    }
    @Test func aSeekOrAJumpAddsNothing() {
        var player = Player()
        player.listen(10)
        player.feed(position: 150)           // seek forward 140 s
        #expect(player.records.isEmpty)
        player.listen(19)
        #expect(player.records.isEmpty, "10 + 19 heard; the jump was not heard")
        player.listen(1)
        #expect(player.records.count == 1)
        var scrubber = Player()
        for position in stride(from: 0.0, through: 190.0, by: 20) { scrubber.feed(position: position) }
        #expect(scrubber.records.isEmpty, "scrubbing through a track is not listening to it")
    }
    @Test func aRewindAddsNothing() {
        var player = Player()
        player.listen(25)
        player.feed(position: 5)
        player.listen(4)
        #expect(player.records.isEmpty)
    }
    @Test func advertisementsNeverCountAndDoNotResetTheTrack() {
        var player = Player()
        player.listen(20)
        for _ in 0..<120 { player.feed(video: "adadadadad1", title: "Ad", content: .advertisement) }
        #expect(player.records.isEmpty)
        player.listen(10)
        #expect(player.records.isEmpty, "29 seconds of the track; the ad was not listening")
        player.listen(1)
        #expect(player.records.count == 1 && player.records[0].videoID == "aaaaaaaaaa1")
    }
    @Test func previewsNeverMakeAPlay() {
        var player = Player()
        for _ in 0..<200 { player.feed(content: .preview) }
        #expect(player.records.isEmpty)
    }
    @Test func aRepeatedEndReportNeverMakesAPlay() {
        var player = Player()
        player.listen(5)
        for _ in 0..<20 { player.feed(ended: true) }
        #expect(player.records.isEmpty, "five seconds heard then an end report: not a play")
        var full = Player()
        full.listen(40)
        #expect(full.records.count == 1)
        for _ in 0..<20 { full.feed(ended: true) }
        #expect(full.records.count == 1, "a repeated end does not add a play")
    }
    @Test func skippingToTheEndBeforeTheThresholdIsNotAPlay() {
        var player = Player()
        player.listen(10)
        player.feed(position: 199)
        player.feed(ended: true, position: 200)
        player.feed(ended: true, position: 200)
        #expect(player.records.isEmpty)
    }
    @Test func skippingToAnotherTrackBeforeTheThresholdIsNotAPlayOfEither() {
        var player = Player()
        player.listen(10, video: "aaaaaaaaaa1")
        player.listen(10, video: "bbbbbbbbbb2")
        #expect(player.records.isEmpty)
        player.listen(20, video: "bbbbbbbbbb2")
        #expect(player.records.map(\.videoID) == ["bbbbbbbbbb2"])
    }
    @Test func listeningAgainAfterTheEndIsASecondPlay() {
        var player = Player()
        player.listen(40)
        player.feed(ended: true, position: 200)
        player.feed(position: 0)             // starts over
        player.listen(40)
        #expect(player.records.count == 2)
        #expect(player.records[0].id != player.records[1].id)
    }
    @Test func theClockAndThePositionMustAgree() {
        var frozen = Player()
        for _ in 0..<100 { frozen.feed(advance: 1, clockStep: 0.001) }       // position races ahead of the monotonic clock
        #expect(frozen.records.isEmpty, "position moving faster than time passes is not listening")
        var slow = Player()
        for _ in 0..<200 { slow.feed(advance: 0.2, clockStep: 1) }            // a stalled player drifting
        #expect(slow.records.isEmpty || slow.records[0].listenedSeconds <= 40)
    }
    @Test func aReadingWithoutATrackIdentityIsIgnored() {
        var player = Player()
        for _ in 0..<100 { player.feed(video: nil) }
        #expect(player.records.isEmpty)
    }
}

// MARK: History model, local store and the separation from the service's history

private actor MemoryHistory: LocalHistoryStoring {
    private(set) var byAccount: [String: [LocalHistoryRecord]] = [:]
    var failAppend = false
    var failRead = false
    func set(failAppend value: Bool) { failAppend = value }
    func set(failRead value: Bool) { failRead = value }
    func append(_ record: LocalHistoryRecord, account: String) async throws {
        if failAppend { throw CocoaError(.fileWriteUnknown) }
        byAccount[account, default: []].insert(record, at: 0)
    }
    func recent(account: String, limit: Int) async throws -> [LocalHistoryRecord] {
        if failRead { throw CocoaError(.fileReadUnknown) }
        return Array((byAccount[account] ?? []).prefix(limit))
    }
    func update(_ record: LocalHistoryRecord, account: String) async throws {
        if failAppend { throw CocoaError(.fileWriteUnknown) }
        if let index = byAccount[account]?.firstIndex(where: { $0.id == record.id }) { byAccount[account]?[index] = record }
    }
    func clear(account: String) async throws { byAccount[account] = [] }
}
private let accountA = "11111111-1111-4111-8111-111111111111"
@MainActor private func historyModel(store: (any LocalHistoryStoring)?, account: Box<String?> = Box(accountA), script: LibraryScript = LibraryScript(),
                                     policy: ListeningPolicy? = YouTubeMusicListening.policy) -> (HistoryModel, LibraryScript) {
    let remote = makeCollection(.history, script: script)
    return (HistoryModel(remote: remote, store: store, policy: policy, accountKey: { account.value }), script)
}
@MainActor private func play(_ model: HistoryModel, seconds: Int, video: String = "aaaaaaaaaa1", from clock: inout Double) {
    var position = 0.0
    for _ in 0..<seconds {
        clock += 1; position += 1
        model.observe(ListeningObservation(videoID: video, title: "Song", artist: "Artist", position: position, duration: 200, playing: true, monotonic: clock, wall: Date(timeIntervalSince1970: 1_700_000_000 + clock)))
    }
}

@MainActor @Suite struct HistoryModelTests {
    @Test func realProgressBecomesALocalOnlyPlayThatIsListedWithItsProvenance() async throws {
        let store = MemoryHistory()
        let (model, _) = historyModel(store: store)
        var clock = 0.0
        play(model, seconds: 45, from: &clock)
        await settle()
        #expect(model.local.count == 1 && model.local[0].sync == .localOnly && model.local[0].title == "Song")
        let saved = await store.byAccount[accountA]
        #expect(saved?.count == 1, "kept under the active account only")
    }
    @Test func clearingThisMacNeverTouchesTheServiceOrItsHistory() async throws {
        let store = MemoryHistory()
        let script = LibraryScript()
        await script.setPage(LibrarySource.history.browseID, try libraryPage("history.json"))
        let (model, _) = historyModel(store: store, script: script)
        await model.remote.load()
        var clock = 0.0
        play(model, seconds: 45, from: &clock)
        await settle()
        let readsBefore = await script.pageCalls.count
        let remoteBefore = model.remote.entries
        await model.clearLocal()
        #expect(model.local.isEmpty && model.localCleared)
        let readsAfter = await script.pageCalls.count
        #expect(readsAfter == readsBefore && model.remote.entries == remoteBefore, "clearing this Mac's record read, wrote and changed nothing at the service")
        #expect(model.controls.clear.reason.contains("can’t be cleared") && model.controls.pause.reason.contains("can’t be paused"))
    }
    @Test func theServicesHistoryControlsAreUnavailableWithAnHonestReasonNotALocalImitation() {
        let controls = RemoteHistoryControls.current
        for control in [controls.pause, controls.clear] {
            #expect(control.reason.localizedCaseInsensitiveContains("service gives it no request"))
            #expect(!control.reason.localizedCaseInsensitiveContains("this mac"), "never mixes in the local record")
        }
    }
    @Test func localAndRemoteAreSeparateCollectionsWithDifferentProvenance() async throws {
        let script = LibraryScript()
        await script.setPage(LibrarySource.history.browseID, try libraryPage("history.json"))
        let (model, _) = historyModel(store: MemoryHistory(), script: script)
        await model.remote.load(); await model.loadLocal()
        #expect(model.remote.entries.count == 5 && model.local.isEmpty)
        var clock = 0.0
        play(model, seconds: 45, from: &clock); await settle()
        #expect(model.remote.entries.count == 5, "a local play is not added to the service's history")
        #expect(model.local.count == 1)
    }
    @Test func theStoredPlayCarriesTheWholeTimeHeardNotOnlyTheThreshold() async throws {
        let store = MemoryHistory()
        let (model, _) = historyModel(store: store)
        var clock = 0.0
        play(model, seconds: 150, from: &clock)
        model.observe(ListeningObservation(videoID: "aaaaaaaaaa1", title: "Song", artist: "Artist", position: 150, duration: 200, playing: false, monotonic: clock + 1))
        await settle(400)
        let saved = await store.byAccount[accountA] ?? []
        #expect(saved.count == 1 && saved[0].listenedSeconds >= 149, "a 150-second listen is not saved as the 30 seconds that made it a play")
        #expect(model.local.first?.listenedSeconds == saved.first?.listenedSeconds)
        let all = await model.allLocalRecords()
        #expect(all == saved)
    }
    @Test func aRecordingFailureIsReportedNotHidden() async throws {
        let store = MemoryHistory()
        await store.set(failAppend: true)
        let (model, _) = historyModel(store: store)
        var clock = 0.0
        play(model, seconds: 45, from: &clock); await settle()
        #expect(model.localFailure && model.local.isEmpty)
        await store.set(failAppend: false); await store.set(failRead: true)
        await model.loadLocal()
        #expect(model.localFailure)
    }
    @Test func aPlayWithNoActiveAccountIsNotRecordedAnywhere() async throws {
        let store = MemoryHistory()
        let account = Box<String?>(nil)
        let (model, _) = historyModel(store: store, account: account)
        var clock = 0.0
        play(model, seconds: 45, from: &clock); await settle()
        let saved = await store.byAccount
        #expect(saved.isEmpty && model.droppedWithoutAccount == 1)
    }
    @Test func thereIsNoLocalHistoryWithoutAnAdapterRuleOrAStore() async throws {
        let (noPolicy, _) = historyModel(store: MemoryHistory(), policy: nil)
        var clock = 0.0
        play(noPolicy, seconds: 100, from: &clock); await settle()
        #expect(noPolicy.local.isEmpty && !noPolicy.hasLocalStore)
        let (noStore, _) = historyModel(store: nil)
        #expect(!noStore.hasLocalStore)
    }
    @Test func anAccountSwitchStartsAFreshRecorderAndShowsNoOtherAccountsPlays() async throws {
        let store = MemoryHistory()
        let account = Box<String?>(accountA)
        let (model, _) = historyModel(store: store, account: account)
        var clock = 0.0
        play(model, seconds: 20, from: &clock)       // 20 s heard for account A, not yet a play
        account.value = "22222222-2222-4222-8222-222222222222"
        model.accountChanged()
        play(model, seconds: 15, from: &clock); await settle()
        #expect(model.local.isEmpty, "20 s + 15 s across two accounts is not a play for either")
        play(model, seconds: 30, from: &clock); await settle()
        #expect(model.local.count == 1)
        let a = await store.byAccount[accountA]
        #expect(a == nil || a?.isEmpty == true)
    }
    @Test func sectionsKeepTheServicesHeadingsAndOrder() throws {
        let entries = (try libraryPage("history.json")).shelves.flatMap { shelf in shelf.items.map { (shelf.title, $0) } }
        #expect(entries.map(\.0) == ["Today", "Today", "Today", "Yesterday", "Yesterday"])
    }
}
