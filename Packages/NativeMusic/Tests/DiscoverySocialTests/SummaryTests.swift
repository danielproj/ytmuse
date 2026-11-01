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
        #expect(summary.topArtists == [.init(name: "X", plays: 2), .init(name: "Y", plays: 1)])
        #expect(summary.topTracks == [.init(name: "A", plays: 2), .init(name: "B", plays: 1)])
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
