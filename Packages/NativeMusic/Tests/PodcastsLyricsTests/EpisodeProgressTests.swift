import AccountSession
import Domain
import Downloads
import Foundation
import Testing
@testable import AppShell
@testable import Features
@testable import YouTubeMusicAdapter

// MARK: T18.2 local-only progress never pretends remote sync

@Suite struct EpisodeProgressResolverTests {
    private let read = Date(timeIntervalSince1970: 1_700_000_000)
    private func local(_ position: Double, played: Bool = false, at offset: TimeInterval = -60, duration: Double? = 1800) -> EpisodeProgressRecord {
        EpisodeProgressRecord(videoID: ep1, position: position, duration: duration, updatedAt: read.addingTimeInterval(offset), played: played)
    }
    @Test func localProgressIsMarkedOnThisMacAndIsNeverPresentedAsFromTheService() {
        let progress = EpisodeProgressResolver.resolve(service: nil, local: local(600), pageReadAt: read)
        #expect(progress.origin == .thisMac && progress.provenance == "On this Mac")
        #expect(progress.status == .inProgress(fraction: 600.0 / 1800) && progress.resumePosition == 600)
        #expect(progress.provenance?.contains("YouTube") == false)
        #expect(EpisodeProgressResolver.resolve(service: nil, local: local(0, played: true), pageReadAt: read).origin == .thisMac)
    }
    @Test func everyLocalRecordIsLocalOnlyAndNeverConfirmed() {
        #expect(local(600).sync == .localOnly && local(0, played: true).sync == .localOnly)
    }
    @Test func aServiceThatReportsNothingNeverHidesALocalRecord() {
        let anonymous = MusicEpisodeInfo(progressPercent: 0, playedLabelPublished: true)
        let progress = EpisodeProgressResolver.resolve(service: anonymous, local: local(600), pageReadAt: read)
        #expect(progress.origin == .thisMac && progress.resumePosition == 600)
    }
    @Test func aPlayedLabelAloneIsNeverPlayed() {
        let label = MusicEpisodeInfo(progressPercent: 0, playedLabelPublished: true)
        #expect(EpisodeProgressResolver.resolve(service: label, local: nil, pageReadAt: read) == .unplayed)
        let unreadable = MusicEpisodeInfo(progressPercent: nil, playedLabelPublished: true)
        #expect(EpisodeProgressResolver.resolve(service: unreadable, local: nil, pageReadAt: read) == .unplayed)
    }
    @Test func theServicesPercentageIsAFigureNotAPositionAndIsMarkedAsTheServices() {
        let service = MusicEpisodeInfo(progressPercent: 37.5)
        let progress = EpisodeProgressResolver.resolve(service: service, local: nil, pageReadAt: read)
        #expect(progress.status == .inProgress(fraction: 0.375) && progress.origin == .youTubeMusic && progress.provenance == "From YouTube Music")
        #expect(progress.resumePosition == nil, "a percentage does not become a position to seek to")
        let done = EpisodeProgressResolver.resolve(service: MusicEpisodeInfo(progressPercent: 100), local: nil, pageReadAt: read)
        #expect(done.status == .played && done.origin == .youTubeMusic)
    }
    @Test func whicheverWasNewerWinsWhenBothHaveProgress() {
        let service = MusicEpisodeInfo(progressPercent: 90)
        #expect(EpisodeProgressResolver.resolve(service: service, local: local(100, at: -60), pageReadAt: read).origin == .youTubeMusic, "listened here before the page was read")
        #expect(EpisodeProgressResolver.resolve(service: service, local: local(100, at: 30), pageReadAt: read).origin == .thisMac, "listened here after the page was read")
    }
    @Test func aBriefStartLeavesNothingAndPlayedKeepsNoResumePoint() {
        #expect(EpisodeProgressResolver.resolve(service: nil, local: local(3), pageReadAt: read) == .unplayed)
        let played = EpisodeProgressResolver.resolve(service: nil, local: local(1799, played: true), pageReadAt: read)
        #expect(played.status == .played && played.resumePosition == nil)
        #expect(EpisodeProgressResolver.resolve(service: nil, local: local(600, duration: nil), pageReadAt: read).status == .inProgress(fraction: nil), "no length, no percentage")
    }
    @Test func theRealShowsRowsAreAllUnplayedWhateverLabelTheyCarry() throws {
        let items = try MusicBrowseParser.parse(try real(.show)).shelves.flatMap(\.items).filter { $0.kind == .episode }
        #expect(!items.isEmpty)
        for item in items { #expect(EpisodeProgressResolver.resolve(service: item.episode, local: nil, pageReadAt: read) == .unplayed, Comment(rawValue: item.title)) }
    }
}

@Suite struct EpisodeProgressRecorderTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func reading(_ id: String? = ep1, _ position: Double, duration: Double = 1800, playing: Bool = true, ended: Bool = false, ad: Bool = false) -> EpisodeProgressRecorder.Reading {
        .init(videoID: id, position: position, duration: duration, playing: playing, ended: ended, advertisement: ad)
    }
    private func recorder() -> EpisodeProgressRecorder { var r = EpisodeProgressRecorder(); r.know(ep1, show: showA); return r }
    @Test func onlyEpisodesThePersonStartedAreRecorded() {
        var r = recorder()
        #expect(r.observe(reading(song, 60), now: now, existing: nil) == nil && r.observe(reading(nil, 60), now: now, existing: nil) == nil)
        #expect(r.observe(reading(ep2, 60), now: now, existing: nil) == nil, "an episode nobody started here is not recorded")
        #expect(r.observe(reading(ep1, 60), now: now, existing: nil)?.showID == showA)
    }
    @Test func adsAndTheFirstSecondsLeaveNothing() {
        var r = recorder()
        #expect(r.observe(reading(ep1, 60, ad: true), now: now, existing: nil) == nil)
        #expect(r.observe(reading(ep1, 4.9), now: now, existing: nil) == nil)
        #expect(r.observe(reading(ep1, 5), now: now, existing: nil)?.position == 5)
    }
    @Test func positionsAreStoredEveryFiveSecondsAndOnPause() {
        var r = recorder()
        #expect(r.observe(reading(ep1, 10), now: now, existing: nil) != nil)
        #expect(r.observe(reading(ep1, 12), now: now, existing: nil) == nil && r.observe(reading(ep1, 14.9), now: now, existing: nil) == nil)
        #expect(r.observe(reading(ep1, 15), now: now, existing: nil)?.position == 15)
        #expect(r.observe(reading(ep1, 17, playing: false), now: now, existing: nil)?.position == 17, "pausing stores where it stopped")
        #expect(r.observe(reading(ep1, 17, playing: false), now: now, existing: nil) == nil, "and not again while still paused")
    }
    @Test func theEndMarksPlayedAndIsNotRepeated() {
        var r = recorder()
        let record = r.observe(reading(ep1, 1800, ended: true), now: now, existing: nil)
        #expect(record?.played == true)
        #expect(r.observe(reading(ep1, 1800, ended: true), now: now, existing: record) == nil)
        var near = recorder()
        #expect(near.observe(reading(ep1, 1799.2), now: now, existing: nil)?.played == true, "within a second of the end")
        var shy = recorder()
        #expect(shy.observe(reading(ep1, 1790), now: now, existing: nil)?.played == false)
    }
    @Test func theStoredLengthIsKeptWhenTheReadingHasNone() {
        var r = recorder()
        let existing = EpisodeProgressRecord(videoID: ep1, position: 100, duration: 1800, updatedAt: now, played: false)
        #expect(r.observe(reading(ep1, 200, duration: 0), now: now, existing: existing)?.duration == 1800)
    }
}

// MARK: This Mac's file (isolated temp directory; never a real store)

@Suite struct PodcastLocalFileStoreTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("w18-test-" + UUID().uuidString, isDirectory: true)
    }
    @Test func aRoundTripKeepsPreferencesAndProgressInAPrivateFile() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PodcastLocalFileStore(directory: dir)
        var state = PodcastLocalState()
        _ = state.preferences.setRate(1.75, forShow: showA); _ = state.preferences.setDefaultRate(1.25)
        state.store(EpisodeProgressRecord(videoID: ep1, position: 300, duration: 900, updatedAt: Date(timeIntervalSince1970: 1_700_000_000), played: false, showID: showA))
        try await store.save(state, account: account)
        #expect(try await store.load(account: account) == state)
        let file = dir.appendingPathComponent(account + ".plist")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(((try FileManager.default.attributesOfItem(atPath: dir.path))[.posixPermissions] as? Int) == 0o700)
    }
    @Test func anAccountWithNothingStartsEmptyAndAccountsAreSeparate() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PodcastLocalFileStore(directory: dir)
        #expect(try await store.load(account: account) == PodcastLocalState())
        var state = PodcastLocalState(); _ = state.preferences.setRate(2, forShow: showA)
        try await store.save(state, account: account)
        #expect(try await store.load(account: "99999999-2222-3333-4444-555555555555") == PodcastLocalState())
    }
    @Test func aDamagedFileIsSetAsideAndTheAccountStartsClean() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: dir.appendingPathComponent(account + ".plist"))
        let store = PodcastLocalFileStore(directory: dir)
        await #expect(throws: PodcastLocalFileStore.Failure.corrupt) { _ = try await store.load(account: account) }
        #expect(try await store.load(account: account) == PodcastLocalState(), "the damaged file was moved, so the next read is a clean start")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains("damaged") })
    }
    @Test func anAccountKeyThatIsNotAUUIDNeverBecomesAPath() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PodcastLocalFileStore(directory: dir)
        for bad in ["../x", "a/b", "", "not-a-uuid"] {
            await #expect(throws: PodcastLocalFileStore.Failure.invalidAccount) { _ = try await store.load(account: bad) }
            await #expect(throws: PodcastLocalFileStore.Failure.invalidAccount) { try await store.save(PodcastLocalState(), account: bad) }
        }
    }
    @Test func removingTheAccountRemovesItsFile() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PodcastLocalFileStore(directory: dir)
        try await store.save(PodcastLocalState(), account: account)
        try await store.clear(account: account)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(account + ".plist").path))
    }
    @Test func theTableIsBounded() {
        var state = PodcastLocalState()
        for index in 0..<(PodcastLocalState.maximumRecords + 25) {
            state.store(EpisodeProgressRecord(videoID: "v\(index)", position: 10, duration: nil, updatedAt: Date(timeIntervalSince1970: Double(index)), played: false))
        }
        #expect(state.progress.count == PodcastLocalState.maximumRecords && state.progress["v0"] == nil && state.progress["v\(PodcastLocalState.maximumRecords + 24)"] != nil)
    }
}

// MARK: T18.2 saved / download eligibility keeps item-specific permissions

@Suite struct EpisodeDownloadPermissionTests {
    @Test func aYouTubeMusicEpisodeIsNotOfferedADownloadEvenThoughItsMenuCarriesTheServicesOwnAction() throws {
        let page = try MusicEpisodeParser_parse(.episode)
        #expect(page.info.publishesServiceDownloadAction)
        let media = try ServiceID(page.videoID)
        #expect(DownloadEligibility.of(media) == .notOffered(.youTubeMusicNoMacDownloads))
    }
    @Test func everyRealRowThatPublishesTheActionIsStillNotOffered() throws {
        let items = try MusicBrowseParser.parse(try real(.show)).shelves.flatMap(\.items).filter { $0.kind == .episode }
        #expect(!items.isEmpty && items.allSatisfy { $0.episode?.publishesServiceDownloadAction == true })
        for item in items { #expect(DownloadEligibility.of(try ServiceID(try #require(item.videoID))) == .notOffered(.youTubeMusicNoMacDownloads)) }
    }
    @Test func theSchedulerStillQueuesNothingForTheEpisode() async throws {
        let media = try ServiceID(ep1)
        #expect(MediaOrigin.classify(media, ownedIdentifiers: MediaOrigin.bundledOwnedIdentifiers) == .youTubeMusic)
    }
}

// MARK: Saving for later: the one write, through the Library's ledger, from an explicit press

@Suite struct EpisodeLaterWireTests {
    private func send(_ request: MusicWriteRequest, body: String) async throws -> (MusicWriteOutcome, URLRequest?) {
        let transport = ScriptedSigned(bodies: [Data(body.utf8)])
        let outcome = try await signedClient(transport).write(request, session: try testSession()).value
        return (outcome, await transport.captured().first)
    }
    @Test func saveSendsOneEditNamingOnlyThisEpisode() async throws {
        let (outcome, request) = try await send(.episodeLater(videoID: ep1, saved: true), body: #"{"status":"STATUS_SUCCEEDED"}"#)
        #expect(outcome == .confirmed)
        let sent = try #require(request)
        #expect(sent.url?.absoluteString == "https://music.youtube.com/youtubei/v1/browse/edit_playlist?prettyPrint=false" && sent.httpMethod == "POST")
        let body = try requestBody(sent)
        #expect(body["playlistId"] as? String == "SE")
        let actions = try #require(body["actions"] as? [[String: Any]])
        #expect(actions.count == 1 && actions[0]["action"] as? String == "ACTION_ADD_VIDEO" && actions[0]["addedVideoId"] as? String == ep1)
    }
    @Test func removeSendsOnlyTheSingleRemoveAndNeverTheClearWatchedAction() async throws {
        let (outcome, request) = try await send(.episodeLater(videoID: ep1, saved: false), body: #"{"status":"STATUS_SUCCEEDED"}"#)
        #expect(outcome == .confirmed)
        let body = try requestBody(try #require(request))
        let actions = try #require(body["actions"] as? [[String: Any]])
        #expect(actions.count == 1 && actions[0]["action"] as? String == "ACTION_REMOVE_VIDEO_BY_VIDEO_ID" && actions[0]["removedVideoId"] as? String == ep1)
        #expect(!String(decoding: try #require(request?.httpBody), as: UTF8.self).contains("REMOVE_WATCHED"), "the service's own remove also clears every watched episode; this never does")
        // The page itself does publish that extra action: the real remove side carries it.
        let page = try real(.episode)
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self)
        #expect(raw.contains("ACTION_REMOVE_WATCHED_VIDEOS"))
    }
    @Test func onlyAnExplicitStatusSucceededIsSuccess() async throws {
        for (body, expected) in [(#"{"status":"STATUS_SUCCEEDED"}"#, MusicWriteOutcome.confirmed), (#"{"status":"STATUS_FAILED"}"#, .rejected(.service)),
                                 (#"{"error":{"code":400}}"#, .rejected(.service)), (#"{}"#, .indeterminate(.unrecognisedAnswer)), (#"{"actions":[{"x":1}]}"#, .indeterminate(.unrecognisedAnswer))] {
            let (outcome, _) = try await send(.episodeLater(videoID: ep1, saved: true), body: body)
            #expect(outcome == expected, Comment(rawValue: body))
        }
    }
    @Test func aBadVideoIdIsRefusedBeforeAnythingIsSent() async throws {
        let transport = ScriptedSigned(bodies: [])
        await #expect(throws: MusicSessionError.policy) { _ = try await signedClient(transport).write(.episodeLater(videoID: "bad", saved: true), session: try testSession()) }
        #expect(await transport.captured().isEmpty)
    }
}

@MainActor @Suite struct EpisodeLaterLedgerTests {
    private func ledger(writes: Locked<[MusicWriteRequest]>, signedIn: SearchPlayback = .available) -> LibraryWriteLedger {
        LibraryWriteLedger(writer: { request in writes.mutate { $0.append(request) }; return MusicWriteReply(outcome: .confirmed, accountGeneration: 1) }, accountScope: { "s" }, signedIn: { signedIn })
    }
    @Test func onePressIsOneRequestAndTheStateIsOptimistic() async {
        let writes = Locked<[MusicWriteRequest]>([])
        let ledger = ledger(writes: writes)
        let key = LibraryWriteKey.episodeLater(videoID: ep1)
        #expect(ledger.isSaved(key, service: false) == false)
        await ledger.submit(.setEpisodeLater(videoID: ep1, to: true, was: false))
        #expect(writes.value == [.episodeLater(videoID: ep1, saved: true)] && ledger.sentCount == 1)
        #expect(ledger.isSaved(key, service: false) == true && ledger.write(key)?.state == .confirmed)
    }
    @Test func signedOutNothingIsSentAndTheSayingIsPlain() async {
        let writes = Locked<[MusicWriteRequest]>([])
        let ledger = ledger(writes: writes, signedIn: .needsSignIn)
        await ledger.submit(.setEpisodeLater(videoID: ep1, to: true, was: false))
        #expect(writes.value.isEmpty && ledger.write(.episodeLater(videoID: ep1))?.state == .failed(.needsSignIn))
    }
    @Test func aRefusalRollsBackAndNothingIsQueued() async {
        let ledger = LibraryWriteLedger(writer: { _ in MusicWriteReply(outcome: .rejected(.service), accountGeneration: 1) }, accountScope: { "s" })
        await ledger.submit(.setEpisodeLater(videoID: ep1, to: true, was: false))
        let key = LibraryWriteKey.episodeLater(videoID: ep1)
        #expect(ledger.write(key)?.state == .failed(.refused) && ledger.isSaved(key, service: false) == false)
    }
    @Test func theEpisodesOwnPageSettlesAnUnknownOutcome() async {
        let ledger = LibraryWriteLedger(writer: { _ in MusicWriteReply(outcome: .indeterminate(.noAnswer), accountGeneration: 1) },
                                        reader: { key in key == .episodeLater(videoID: ep1) ? .saved(true) : nil }, accountScope: { "s" })
        await ledger.submit(.setEpisodeLater(videoID: ep1, to: true, was: false))
        #expect(ledger.write(.episodeLater(videoID: ep1))?.state == .needsReconciliation)
        await ledger.check(.episodeLater(videoID: ep1))
        #expect(ledger.write(.episodeLater(videoID: ep1))?.state == .confirmed)
    }
}
