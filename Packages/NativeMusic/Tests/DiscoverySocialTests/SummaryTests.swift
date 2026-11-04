import Features
import Foundation
import Testing

/// T20.3 — Recap and badges render supplied data without manufactured statistics; a missing payload is distinct from unsupported account evidence.
struct ScriptedSummary: AccountSummarySource {
    var unresolvedReason: String?
    var recapAnswer: Result<SummaryAnswer<RecapPayload>, SamplesFailure> = .success(.noPayload)
    var badgesAnswer: Result<SummaryAnswer<BadgePayload>, SamplesFailure> = .success(.noPayload)
    var unresolved: String? { unresolvedReason }
    func recap() async throws -> SummaryAnswer<RecapPayload> { try recapAnswer.get() }
    func badges() async throws -> SummaryAnswer<BadgePayload> { try badgesAnswer.get() }
}

@Suite @MainActor struct AccountSummaryModelTests {
    private let payload = RecapPayload(title: "Your year", period: "As printed by the source", entries: [
        SummaryEntry(id: "1", title: "Minutes", value: "1,204 minutes", caption: "As printed"),
        SummaryEntry(id: "2", title: "Top artist", value: "An Artist")])
    @Test func aSourceWithNoRouteIsUnresolvedAndNeverRead() async {
        let model = AccountSummaryModel(source: ScriptedSummary(unresolvedReason: "No route."))
        await model.loadRecap(); await model.loadBadges()
        #expect(model.recap == .unresolved("No route.") && model.badges == .unresolved("No route."))
        #expect(model.readCount == 0)
    }
    @Test func theApplicationsOwnSourceSaysItCannotReadThisAndMakesNothingUp() async {
        let model = AccountSummaryModel(source: UnresolvedSummarySource())
        guard case .unresolved(let reason) = model.recap else { Issue.record("expected unresolved"); return }
        #expect(reason.contains("nothing is shown and nothing is made up"))
        await model.loadRecap()
        guard case .unresolved = model.recap else { Issue.record("a load must not turn unresolved into anything else"); return }
    }
    @Test func aSuppliedPayloadIsShownVerbatimInTheSourcesOrder() async {
        let model = AccountSummaryModel(source: ScriptedSummary(recapAnswer: .success(.payload(payload))))
        await model.loadRecap()
        guard case .loaded(let shown) = model.recap else { Issue.record("expected loaded"); return }
        #expect(shown == payload)
        #expect(shown.entries.map(\.value) == ["1,204 minutes", "An Artist"], "figures are the source's own text, never parsed or recomputed")
        #expect(shown.entries.count == payload.entries.count, "no entry is added")
    }
    @Test func aMissingPayloadAndAnUnsupportedAccountAreDifferentStates() async {
        let missing = AccountSummaryModel(source: ScriptedSummary(recapAnswer: .success(.noPayload)))
        await missing.loadRecap()
        let unsupported = AccountSummaryModel(source: ScriptedSummary(recapAnswer: .success(.accountUnsupported("Not offered for this account."))))
        await unsupported.loadRecap()
        #expect(missing.recap == .payloadMissing)
        #expect(unsupported.recap == .accountUnsupported("Not offered for this account."))
        #expect(missing.recap != unsupported.recap)
        let unresolved = AccountSummaryModel(source: ScriptedSummary(unresolvedReason: "No route."))
        #expect(unresolved.recap != missing.recap && unresolved.recap != unsupported.recap)
    }
    @Test func aPayloadWithNoEntriesIsAMissingPayloadNotAnEmptyRecap() async {
        let model = AccountSummaryModel(source: ScriptedSummary(recapAnswer: .success(.payload(RecapPayload(title: "Empty", entries: []))),
                                                                badgesAnswer: .success(.payload(BadgePayload(badges: [])))))
        await model.loadRecap(); await model.loadBadges()
        #expect(model.recap == .payloadMissing && model.badges == .payloadMissing)
    }
    @Test func badgesAreShownAsSuppliedAndNeverInvented() async {
        let badges = BadgePayload(badges: [BadgeEntry(id: "b1", title: "First badge", detail: "Source words", earned: "Source date")])
        let model = AccountSummaryModel(source: ScriptedSummary(badgesAnswer: .success(.payload(badges))))
        await model.loadBadges()
        #expect(model.badges == .loaded(badges))
        #expect(model.recap == .idle, "loading badges does not touch Recap")
    }
    @Test func signedOutAndEndedSessionsAreNotReadAndAreTheirOwnStates() async {
        let source = ScriptedSummary(recapAnswer: .success(.payload(payload)))
        let out = AccountSummaryModel(source: source, signedIn: { .needsSignIn })
        await out.loadRecap()
        let ended = AccountSummaryModel(source: source, signedIn: { .sessionExpired })
        await ended.loadRecap()
        #expect(out.recap == .signInRequired && ended.recap == .sessionEnded)
        #expect(out.readCount == 0 && ended.readCount == 0)
    }
    @Test func aReadFailureIsAFailureNotAMissingPayload() async {
        let model = AccountSummaryModel(source: ScriptedSummary(recapAnswer: .failure(.offline)))
        await model.loadRecap()
        #expect(model.recap == .failed(.offline) && model.recap != .payloadMissing)
    }
    @Test func anAccountChangeClearsTheSummariesAndTheLocalRecord() async {
        let model = AccountSummaryModel(source: ScriptedSummary(recapAnswer: .success(.payload(payload))), localRecords: { [LocalHistoryRecord(videoID: "v", title: "T", artist: "A", startedAt: Date(), listenedSeconds: 60)] })
        await model.loadRecap(); await model.refreshLocal()
        #expect(model.local != nil)
        model.accountChanged()
        #expect(model.recap == .idle && model.badges == .idle && model.local == nil)
    }
}

@Suite @MainActor struct LocalListeningSummaryTests {
    private func record(_ title: String, _ artist: String?, seconds: Double = 100, at: TimeInterval = 0) -> LocalHistoryRecord {
        LocalHistoryRecord(videoID: "v" + title, title: title, artist: artist, startedAt: Date(timeIntervalSince1970: at), listenedSeconds: seconds)
    }
    @Test func itCountsOnlyWhatThisMacRecorded() {
        let summary = LocalListeningSummary.make(from: [record("A", "X", seconds: 30, at: 10), record("B", "X", seconds: 70, at: 5), record("A", "Y", seconds: 0, at: 20)])
        #expect(summary.plays == 3 && summary.listenedSeconds == 100)
        #expect(summary.since == Date(timeIntervalSince1970: 5))
        #expect(summary.topArtists.map(\.name) == ["X", "Y"] && summary.topArtists.map(\.plays) == [2, 1])
        #expect(summary.topTracks.map(\.name) == ["A", "B"] && summary.topTracks.map(\.plays) == [2, 1])
        #expect(summary.topTracks[0].seconds == 30 && summary.topArtists[0].seconds == 100)
        #expect(summary.songs == 2 && summary.artists == 2)
    }
    @Test func songsAreTheSameSongByVideoNotByTitle() {
        let summary = LocalListeningSummary.make(from: [
            LocalHistoryRecord(videoID: "one", title: "Intro", artist: "First", startedAt: .init(timeIntervalSince1970: 3), listenedSeconds: 60),
            LocalHistoryRecord(videoID: "two", title: "Intro", artist: "Second", startedAt: .init(timeIntervalSince1970: 2), listenedSeconds: 60),
            LocalHistoryRecord(videoID: "two", title: "Intro", artist: "Second", startedAt: .init(timeIntervalSince1970: 1), listenedSeconds: 60),
        ])
        #expect(summary.topTracks.map(\.id) == ["two", "one"], "two songs called Intro stay two songs")
        #expect(summary.topTracks.map(\.detail) == ["Second", "First"], "each shows its own artist")
        #expect(summary.songs == 2)
    }
    @Test func equalPlaysRankTheLongerListenFirst() {
        let summary = LocalListeningSummary.make(from: [record("A", "X", seconds: 40), record("B", "Y", seconds: 200)])
        #expect(summary.topTracks.map(\.name) == ["B", "A"] && summary.topArtists.map(\.name) == ["Y", "X"])
    }
    @Test func theLastDaysEndTodayAndKeepEmptyDays() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13 UTC
        let today = calendar.startOfDay(for: now)
        let records = [record("A", "X", seconds: 120, at: now.timeIntervalSince1970 - 60), record("B", "X", seconds: 30, at: now.timeIntervalSince1970 - 120),
                       record("C", "X", seconds: 90, at: today.timeIntervalSince1970 - 3_600), record("D", "X", seconds: 50, at: today.timeIntervalSince1970 - 30 * 86_400)]
        let summary = LocalListeningSummary.make(from: records, days: 14, now: now, calendar: calendar)
        #expect(summary.recentDays.count == 14 && summary.recentDays.last?.start == today)
        #expect(summary.recentDays.last?.plays == 2 && summary.recentDays.last?.seconds == 150)
        #expect(summary.recentDays[12].plays == 1 && summary.recentDays[12].seconds == 90)
        #expect(summary.recentDays.dropLast(2).allSatisfy { $0.plays == 0 }, "a play older than the window is in the totals, not in a day")
        #expect(summary.plays == 4 && summary.listenedSeconds == 290)
    }
    @Test func itIsNeverOfficial() {
        #expect(LocalListeningSummary.make(from: [record("A", "X")]).isOfficial == false)
        #expect(LocalListeningSummary.make(from: []).isOfficial == false)
    }
    @Test func tiesKeepTheOrderTheyFirstAppearedAndTheListIsBounded() {
        let records = (1...9).map { record("T\($0)", "Artist\($0)") }
        let summary = LocalListeningSummary.make(from: records, top: 5)
        #expect(summary.topTracks.map(\.name) == ["T1", "T2", "T3", "T4", "T5"])
        #expect(summary.topArtists.count == 5)
    }
    @Test func noArtistNamesAreNeverInventedAndNegativeDurationsAreNotCounted() {
        let summary = LocalListeningSummary.make(from: [record("A", nil, seconds: -50), record("B", "", seconds: 10)])
        #expect(summary.topArtists.isEmpty)
        #expect(summary.listenedSeconds == 10)
    }
    @Test func theLocalRecordLivesBesideTheOfficialStatesNeverInsideThem() async {
        let records = [record("A", "X")]
        let model = AccountSummaryModel(source: ScriptedSummary(unresolvedReason: "No route."), localRecords: { records })
        await model.loadRecap(); await model.refreshLocal()
        #expect(model.local?.plays == 1)
        #expect(model.recap == .unresolved("No route."), "a local count never fills in for a missing Recap")
        #expect(model.badges == .unresolved("No route."))
    }
    @Test func withNothingRecordedThereIsNoSummaryRatherThanZeroes() async {
        let model = AccountSummaryModel(source: ScriptedSummary(), localRecords: { [] })
        await model.refreshLocal()
        #expect(model.local == nil)
    }
}
