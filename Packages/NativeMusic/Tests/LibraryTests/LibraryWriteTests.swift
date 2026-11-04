import AccountSession
import Features
import Foundation
import Testing
@testable import YouTubeMusicAdapter

private let video = "dQw4w9WgXcQ"
private let channel = "UC_kRDKYrUlrbtrSiyu5Tflg"

// MARK: The wire (real SignedMusicClient over a scripted transport; nothing here reaches a network)

@Suite struct LibraryWriteWireTests {
    private func send(_ request: MusicWriteRequest, body: String, status: Int = 200) async throws -> (MusicWriteOutcome, URLRequest?) {
        let transport = ScriptedSigned(body: Data(body.utf8), status: status)
        let outcome = try await signedClient(transport).write(request, session: try testSession()).value
        return (outcome, await transport.captured().first)
    }
    private func fixture(_ name: String) throws -> String { String(decoding: try w12Data(name), as: UTF8.self) }

    @Test func eachWriteIsOneSignedPostWithTheShapeTheServiceUses() async throws {
        let cases: [(MusicWriteRequest, String, [String: Any])] = [
            (.rate(videoID: video, status: .like), "like/like", ["target": ["videoId": video]]),
            (.rate(videoID: video, status: .dislike), "like/dislike", ["target": ["videoId": video]]),
            (.rate(videoID: video, status: .indifferent), "like/removelike", ["target": ["videoId": video]]),
            (.savePlaylist(playlistID: "OLAK5uy_abc", saved: true), "like/like", ["target": ["playlistId": "OLAK5uy_abc"]]),
            (.savePlaylist(playlistID: "OLAK5uy_abc", saved: false), "like/removelike", ["target": ["playlistId": "OLAK5uy_abc"]]),
            (.songLibrary(feedbackToken: "synthetic-add-token-0001"), "feedback", ["feedbackTokens": ["synthetic-add-token-0001"]]),
            (.follow(channelID: channel, params: "EgIIGxgA", following: true), "subscription/subscribe", ["channelIds": [channel], "params": "EgIIGxgA"]),
            (.follow(channelID: channel, params: "EgIIGxgA", following: false), "subscription/unsubscribe", ["channelIds": [channel]]),
        ]
        for (write, path, expected) in cases {
            let (_, request) = try await send(write, body: try fixture("write-actions.json"))
            let sent = try #require(request)
            #expect(sent.httpMethod == "POST" && sent.url?.absoluteString == "https://music.youtube.com/youtubei/v1/\(path)?prettyPrint=false", Comment(rawValue: "\(write)"))
            #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
            let body = try requestBody(sent)
            for (key, value) in expected { #expect(NSDictionary(dictionary: [key: body[key] as Any]).isEqual(to: [key: value]), Comment(rawValue: "\(write): \(key)")) }
            // Nothing beyond what the endpoint takes is sent (an unsubscribe carries no subscribe parameters).
            #expect(Set(body.keys).subtracting(["context"]) == Set(expected.keys), Comment(rawValue: "\(write): \(Set(body.keys))"))
        }
    }
    @Test func aProviderErrorInsideAnHTTP200IsRefusedNotConfirmed() async throws {
        let rated = try await send(.rate(videoID: video, status: .like), body: try fixture("write-error.json"))
        #expect(rated.0 == .rejected(.service))
        let listed = try await send(.follow(channelID: channel, params: nil, following: true), body: try fixture("write-errors-list.json"))
        #expect(listed.0 == .rejected(.service))
    }
    @Test func successNeedsPositiveEvidenceAnEmptyAnswerIsNotSuccess() async throws {
        let empty = try await send(.rate(videoID: video, status: .like), body: try fixture("write-empty.json"))
        #expect(empty.0 == .indeterminate(.unrecognisedAnswer))
        let ok = try await send(.rate(videoID: video, status: .like), body: try fixture("write-actions.json"))
        #expect(ok.0 == .confirmed)
        let bare = try await send(.savePlaylist(playlistID: "OLAK5uy_abc", saved: true), body: "{}")
        #expect(bare.0 == .indeterminate(.unrecognisedAnswer))
        // An `actions` array with nothing in it is the key present and the evidence absent: not success.
        for request in [MusicWriteRequest.rate(videoID: video, status: .like), .savePlaylist(playlistID: "OLAK5uy_abc", saved: false), .follow(channelID: channel, params: nil, following: true)] {
            let hollow = try await send(request, body: try fixture("write-actions-empty.json"))
            #expect(hollow.0 == .indeterminate(.unrecognisedAnswer), Comment(rawValue: "\(request)"))
        }
    }
    @Test func aFeedbackResponseMustMarkTheTokenProcessed() async throws {
        let token = MusicWriteRequest.songLibrary(feedbackToken: "synthetic-add-token-0001")
        #expect(try await send(token, body: try fixture("write-feedback-processed.json")).0 == .confirmed)
        #expect(try await send(token, body: try fixture("write-feedback-not-processed.json")).0 == .rejected(.service))
        #expect(try await send(token, body: try fixture("write-feedback-missing.json")).0 == .indeterminate(.unrecognisedAnswer))
        #expect(try await send(token, body: try fixture("write-empty.json")).0 == .indeterminate(.unrecognisedAnswer))
    }
    @Test func httpStatusesMapToDefiniteOutcomes() async throws {
        let request = MusicWriteRequest.rate(videoID: video, status: .like)
        #expect(try await send(request, body: "{}", status: 429).0 == .rejected(.rateLimited))
        #expect(try await send(request, body: "{}", status: 503).0 == .rejected(.unavailable))
        await #expect(throws: MusicSessionError.signedOut) { _ = try await send(request, body: "{}", status: 401) }
        await #expect(throws: MusicSessionError.signedOut) { _ = try await send(request, body: "{}", status: 403) }
    }
    @Test func aLoggedOutAnswerIsASignedOutSessionNotAChange() async throws {
        let body = #"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":true}},"actions":[{"x":1}]}"#
        await #expect(throws: MusicSessionError.signedOut) { _ = try await send(.rate(videoID: video, status: .like), body: body) }
    }
    @Test func aLostConnectionAfterTheRequestLeftIsIndeterminateButBeforeItIsAFailure() async throws {
        let transport = ScriptedSigned(failure: URLError(.timedOut))
        let outcome = try await signedClient(transport).write(.rate(videoID: video, status: .like), session: try testSession()).value
        #expect(outcome == .indeterminate(.noAnswer), "the request was handed to the transport: it may have been applied")
        let sent = await transport.captured().count
        #expect(sent == 1)
        // The client version cannot be fetched: nothing was sent, so this is a plain failure and nothing is in doubt.
        let before = SignedMusicClient(transport: ScriptedSigned(), clock: FixedNow()) { throw URLError(.notConnectedToInternet) }
        await #expect(throws: MusicSessionError.network) { _ = try await before.write(.rate(videoID: video, status: .like), session: try testSession()) }
    }
    @Test func anUnreadableAnswerAfterSendingIsIndeterminate() async throws {
        let html = ScriptedSigned(body: Data("<html>".utf8), type: "text/html")
        let outcome = try await signedClient(html).write(.rate(videoID: video, status: .like), session: try testSession()).value
        #expect(outcome == .indeterminate(.unrecognisedAnswer))
    }
    @Test func aMalformedRequestIsRefusedBeforeAnythingIsSent() async throws {
        let transport = ScriptedSigned()
        await #expect(throws: MusicSessionError.policy) { _ = try await signedClient(transport).write(.rate(videoID: "bad", status: .like), session: try testSession()) }
        await #expect(throws: MusicSessionError.policy) { _ = try await signedClient(transport).write(.follow(channelID: "UCshort", params: nil, following: true), session: try testSession()) }
        let sent = await transport.captured().count
        #expect(sent == 0)
    }
    @Test func theAllowlistAdmitsExactlyTheSixLibraryWritePathsAndNothingElse() throws {
        #expect(SignedMusicPolicy.writePaths == ["/youtubei/v1/like/like", "/youtubei/v1/like/dislike", "/youtubei/v1/like/removelike",
                                                 "/youtubei/v1/subscription/subscribe", "/youtubei/v1/subscription/unsubscribe", "/youtubei/v1/feedback"])
        #expect(SignedMusicPolicy.musicPaths.isDisjoint(with: SignedMusicPolicy.writePaths), "reads and writes are separate sets")
        // W13: the three playlist-changing paths are no longer refused outright; they are admitted only through their own set
        // (`playlistWritePaths`, pinned in PlaylistTests), which is disjoint from both the reads and the six library writes above.
        // Everything else destructive stays refused, as do near-misses of the playlist paths.
        for path in ["/youtubei/v1/music/delete_privately_owned_entity", "/youtubei/v1/history/clear", "/youtubei/v1/like/unknown", "/youtubei/v1/playlist/get_add_to_playlist", "/youtubei/v1/browse/edit_playlist/extra",
                     "/youtubei/v1/playlist/remove", "/youtubei/v1/playlist/update"] {
            #expect(!SignedMusicPolicy.musicPaths.contains(path) && !SignedMusicPolicy.writePaths.contains(path) && !SignedMusicPolicy.playlistWritePaths.contains(path), Comment(rawValue: path))
            var request = URLRequest(url: URL(string: "https://music.youtube.com" + path + "?prettyPrint=false")!)
            request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
            for (name, value) in [("Cookie", "SID=x"), ("Authorization", "SAPISIDHASH 1_x"), ("Origin", "https://music.youtube.com"), ("X-Origin", "https://music.youtube.com")] { request.setValue(value, forHTTPHeaderField: name) }
            #expect(throws: MusicSessionError.policy) { try SignedMusicPolicy.validate(request, maximumBytes: 1000) }
        }
        for path in SignedMusicPolicy.playlistWritePaths {
            #expect(!SignedMusicPolicy.musicPaths.contains(path) && !SignedMusicPolicy.writePaths.contains(path), "the playlist paths are a set of their own: \(path)")
        }
        // A listed write path is admitted only as a signed POST with the exact query.
        var good = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/like/like?prettyPrint=false")!)
        good.httpMethod = "POST"; good.httpBody = Data("{}".utf8)
        for (name, value) in [("Cookie", "SID=x"), ("Authorization", "SAPISIDHASH 1_x"), ("Origin", "https://music.youtube.com"), ("X-Origin", "https://music.youtube.com")] { good.setValue(value, forHTTPHeaderField: name) }
        try SignedMusicPolicy.validate(good, maximumBytes: 1000)
        var get = good; get.httpMethod = "GET"
        #expect(throws: MusicSessionError.policy) { try SignedMusicPolicy.validate(get, maximumBytes: 1000) }
        var unsigned = good; unsigned.setValue(nil, forHTTPHeaderField: "Authorization")
        #expect(throws: MusicSessionError.policy) { try SignedMusicPolicy.validate(unsigned, maximumBytes: 1000) }
    }
    @Test func libraryReadsAreSignedAndKeepRepeats() async throws {
        let transport = ScriptedSigned(body: try w12Data("library-songs.json"))
        let page = try await signedClient(transport).library(id: "FEmusic_liked_videos", session: try testSession()).value
        #expect(page.shelves[0].items.count == 7)
        let request = try #require(await transport.captured().first)
        let body = try requestBody(request)
        #expect(body["browseId"] as? String == "FEmusic_liked_videos" && request.value(forHTTPHeaderField: "Cookie")?.isEmpty == false)
        let more = ScriptedSigned(body: try w12Data("library-songs-page2.json"))
        let next = try await signedClient(more).libraryContinuation(token: "LIBSONGS-2", session: try testSession()).value
        #expect(next.items.count == 5 && next.continuation == "LIBSONGS-3")
        let sentBody = try requestBody(try #require(await more.captured().first))
        #expect(sentBody["continuation"] as? String == "LIBSONGS-2" && request.url?.query == "prettyPrint=false")
        await #expect(throws: MusicSessionError.policy) { _ = try await signedClient(transport).library(id: "bad id!", session: try testSession()) }
    }
    @Test func aLoggedOutLibraryAnswerIsASignedOutSessionNeverAnEmptyLibrary() async throws {
        let body = #"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":true}}}"#
        let transport = ScriptedSigned(body: Data(body.utf8))
        await #expect(throws: MusicSessionError.signedOut) { _ = try await signedClient(transport).library(id: "FEmusic_liked_videos", session: try testSession()) }
        await #expect(throws: MusicSessionError.signedOut) { _ = try await signedClient(transport).libraryContinuation(token: "tok", session: try testSession()) }
    }
    @Test func aUnrecognisedLibraryPageThroughTheClientIsUnrecognisedNotEmpty() async throws {
        let transport = ScriptedSigned(body: try w12Data("library-unrecognised.json"))
        await #expect(throws: MusicSessionError.unrecognised) { _ = try await signedClient(transport).library(id: "FEmusic_liked_videos", session: try testSession()) }
    }
}

// MARK: The ledger (optimistic state, rollback, retry, reconciliation)

private actor WriterScript {
    private(set) var requests: [MusicWriteRequest] = []
    var outcomes: [Result<MusicWriteOutcome, MusicSessionError>] = []
    var held: [CheckedContinuation<Void, Never>] = []
    var hold = false
    func push(_ outcome: Result<MusicWriteOutcome, MusicSessionError>...) { outcomes += outcome }
    func setHold(_ value: Bool) { hold = value }
    func release() { let all = held; held = []; for c in all { c.resume() } }
    func write(_ request: MusicWriteRequest) async throws -> MusicWriteReply {
        requests.append(request)
        if hold { await withCheckedContinuation { held.append($0) } }
        let next = outcomes.isEmpty ? .success(.confirmed) : outcomes.removeFirst()
        return MusicWriteReply(outcome: try next.get(), accountGeneration: 1)
    }
}
@MainActor private func ledger(_ script: WriterScript, scope: Box<String> = Box("s1"), state: Box<SearchPlayback> = Box(.available), reader: @escaping LibraryWriteLedger.Reader = { _ in nil }) -> LibraryWriteLedger {
    LibraryWriteLedger(writer: { try await script.write($0) }, reader: reader, accountScope: { scope.value }, signedIn: { state.value })
}
private let like = MusicItemControls.Like(videoID: video, status: .indifferent, dislikeExposed: true)

@MainActor @Suite struct LibraryWriteLedgerTests {
    @Test func theChangeShowsAtOnceAndIsConfirmedOnlyByTheServicesAnswer() async throws {
        let script = WriterScript()
        await script.setHold(true)
        let ledger = ledger(script)
        let task = Task { await ledger.submit(.rate(like, to: .like)) }
        await settle()
        #expect(ledger.rating(video, service: .indifferent) == .like, "optimistic: shown before any answer")
        #expect(ledger.write(.rating(videoID: video))?.state == .pending && ledger.isBusy(.rating(videoID: video)))
        await script.release(); await task.value
        #expect(ledger.write(.rating(videoID: video))?.state == .confirmed && ledger.rating(video, service: .indifferent) == .like)
    }
    @Test func aRefusalRollsBackAndOffersARetryWithTheSameOperation() async throws {
        let script = WriterScript()
        await script.push(.success(.rejected(.service)), .success(.confirmed))
        let ledger = ledger(script)
        await ledger.submit(.rate(like, to: .like))
        let failed = try #require(ledger.write(.rating(videoID: video)))
        #expect(failed.state == .failed(.refused) && ledger.rating(video, service: .indifferent) == .indifferent, "rolled back to what was shown")
        await ledger.retry(.rating(videoID: video))
        let retried = try #require(ledger.write(.rating(videoID: video)))
        #expect(retried.state == .confirmed && retried.operationID == failed.operationID && retried.attempts == 2)
        #expect(await script.requests.count == 2)
    }
    @Test func aProviderErrorInAnHTTP200StaysFailedEndToEnd() async throws {
        // The real client reading a 200 whose body is an error object, behind the real ledger.
        let transport = ScriptedSigned(body: try w12Data("write-error.json"))
        let client = signedClient(transport)
        let session = try testSession()
        let ledger = LibraryWriteLedger(writer: { MusicWriteReply(outcome: try await client.write($0, session: session).value, accountGeneration: 1) }, accountScope: { "s" })
        await ledger.submit(.rate(like, to: .like))
        #expect(ledger.write(.rating(videoID: video))?.state == .failed(.refused))
        #expect(ledger.rating(video, service: .indifferent) == .indifferent)
    }
    @Test func anAnswerThatIsNeitherSuccessNorFailureIsNeverShownAsSuccess() async throws {
        let transport = ScriptedSigned(body: try w12Data("write-empty.json"))
        let client = signedClient(transport)
        let session = try testSession()
        let ledger = LibraryWriteLedger(writer: { MusicWriteReply(outcome: try await client.write($0, session: session).value, accountGeneration: 1) }, accountScope: { "s" })
        await ledger.submit(.rate(like, to: .like))
        #expect(ledger.write(.rating(videoID: video))?.state == .needsReconciliation)
    }
    @Test func eachDefiniteFailureRollsBackWithItsOwnReason() async throws {
        let cases: [(Result<MusicWriteOutcome, MusicSessionError>, LibraryWriteFailure)] = [
            (.success(.rejected(.rateLimited)), .rateLimited), (.success(.rejected(.unavailable)), .unavailable), (.failure(.network), .offline),
            (.failure(.timedOut), .offline), (.failure(.signedOut), .sessionEnded), (.failure(.notSignedIn), .needsSignIn), (.failure(.policy), .notOffered), (.failure(.server), .unavailable)]
        for (outcome, expected) in cases {
            let script = WriterScript()
            await script.push(outcome)
            let ledger = ledger(script)
            await ledger.submit(.setFollowing(.init(channelID: channel, isFollowing: false, params: nil), to: true, was: false))
            #expect(ledger.write(.following(channelID: channel))?.state == .failed(expected), "\(outcome)")
            #expect(!ledger.isFollowing(channel, service: false), "rolled back")
            #expect(!expected.message.isEmpty)
        }
    }
    @Test func nothingIsSentWhenSignedOutOrSessionEndedOrNotWellFormed() async throws {
        let script = WriterScript()
        let state = Box(SearchPlayback.needsSignIn)
        let ledger = ledger(script, state: state)
        await ledger.submit(.rate(like, to: .like))
        #expect(ledger.write(.rating(videoID: video))?.state == .failed(.needsSignIn))
        state.value = .sessionExpired
        ledger.dismiss(.rating(videoID: video))
        await ledger.submit(.rate(like, to: .like))
        #expect(ledger.write(.rating(videoID: video))?.state == .failed(.sessionEnded))
        state.value = .available
        ledger.dismiss(.rating(videoID: video))
        await ledger.submit(.rate(.init(videoID: "bad", status: .indifferent, dislikeExposed: false), to: .like))
        #expect(ledger.write(.rating(videoID: "bad"))?.state == .failed(.notOffered))
        let sent = await script.requests.count
        #expect(sent == 0 && ledger.sentCount == 0)
    }
    @Test func oneActionIsOneRequestAndASecondOnTheSameItemWhilePendingIsRefused() async throws {
        let script = WriterScript()
        await script.setHold(true)
        let ledger = ledger(script)
        let first = Task { await ledger.submit(.rate(like, to: .like)) }
        await settle()
        // Run as a task so a ledger that did send the second request could not hang this test on the held reply.
        let second = Task { await ledger.submit(.rate(like, to: .dislike)) }
        await settle()
        let during = await script.requests
        #expect(during == [.rate(videoID: video, status: .like)], "the second change was not sent")
        await script.release(); await first.value; await second.value
        await script.release()
        #expect(ledger.sentCount == 1)
    }
    @Test func theLedgerNeverBatchesDifferentItemsAreSeparateActions() async throws {
        let script = WriterScript()
        let ledger = ledger(script)
        await ledger.submit(.rate(like, to: .like))
        let sent = await script.requests
        #expect(sent.count == 1 && ledger.pendingCount == 0, "a change to one item sends one request; nothing else is touched")
    }
    @Test func anUnknownOutcomeIsCheckedBeforeAnythingIsSentAgain() async throws {
        let script = WriterScript()
        await script.push(.success(.indeterminate(.noAnswer)))
        let read = Box<LibraryWriteValue?>(nil)
        let ledger = ledger(script, reader: { _ in await MainActor.run { read.value } })
        let key = LibraryWriteKey.rating(videoID: video)
        await ledger.submit(.rate(like, to: .like))
        #expect(ledger.write(key)?.state == .needsReconciliation && ledger.rating(video, service: .indifferent) == .like, "shown as the person asked, unconfirmed")
        await ledger.retry(key)
        let blind = await script.requests.count
        #expect(blind == 1, "no blind replay of a change whose outcome is unknown")
        await ledger.check(key)
        #expect(ledger.write(key)?.checkedUnreadable == true)
        await ledger.retry(key)
        let retried = await script.requests.count
        #expect(retried == 2, "once the check could not tell, repeating the same state-setting change is allowed")
    }
    @Test func aCheckThatFindsTheChangeConfirmsItAndOneThatDoesNotRollsItBack() async throws {
        for (found, expected) in [(LibraryWriteValue.rating(.like), LibraryWriteState.confirmed), (.rating(.indifferent), .failed(.notApplied))] {
            let script = WriterScript()
            await script.push(.success(.indeterminate(.unrecognisedAnswer)))
            let ledger = ledger(script, reader: { _ in found })
            let key = LibraryWriteKey.rating(videoID: video)
            await ledger.submit(.rate(like, to: .like))
            await ledger.check(key)
            #expect(ledger.write(key)?.state == expected)
            if expected != .confirmed { #expect(ledger.rating(video, service: .indifferent) == .indifferent) }
        }
    }
    @Test func aLaterReadReplacesASettledChange() async throws {
        let script = WriterScript()
        let ledger = ledger(script)
        await ledger.submit(.rate(like, to: .like))
        #expect(ledger.rating(video, service: .indifferent) == .like)
        ledger.observed(.rating(videoID: video), .rating(.indifferent))
        #expect(ledger.write(.rating(videoID: video)) == nil && ledger.rating(video, service: .indifferent) == .indifferent)
    }
    @Test func aPendingChangeIsNotReplacedByAReadThatPredatesIt() async throws {
        let script = WriterScript()
        await script.setHold(true)
        let ledger = ledger(script)
        let task = Task { await ledger.submit(.rate(like, to: .like)) }
        await settle()
        ledger.observed(.rating(videoID: video), .rating(.indifferent))
        #expect(ledger.write(.rating(videoID: video))?.state == .pending)
        await script.release(); await task.value
    }
    @Test func anAccountSwitchDropsEveryChangeAndAnAnswerForTheOldScopeIsDiscarded() async throws {
        let script = WriterScript()
        await script.setHold(true)
        let scope = Box("s1")
        let ledger = ledger(script, scope: scope)
        let task = Task { await ledger.submit(.rate(like, to: .like)) }
        await settle()
        scope.value = "s2"
        ledger.accountChanged()
        #expect(ledger.writes.isEmpty)
        await script.release(); await task.value
        #expect(ledger.writes.isEmpty, "the late answer for the old account created nothing")
    }
    @Test func eachNewActionIsANewOperationWhileARetryKeepsItsOwn() async throws {
        let script = WriterScript()
        await script.push(.success(.confirmed), .success(.confirmed), .success(.rejected(.service)), .success(.confirmed))
        let ledger = ledger(script)
        let key = LibraryWriteKey.rating(videoID: video)
        await ledger.submit(.rate(like, to: .like))
        let first = try #require(ledger.write(key)).operationID
        await ledger.submit(.rate(.init(videoID: video, status: .like, dislikeExposed: true), to: .indifferent))
        let second = try #require(ledger.write(key))
        #expect(second.operationID != first && second.attempts == 1, "a new action after a settled one is a new operation")
        await ledger.submit(.rate(like, to: .like))   // refused by the script
        let third = try #require(ledger.write(key))
        #expect(third.state == .failed(.refused) && third.operationID != second.operationID)
        await ledger.retry(key)
        let retried = try #require(ledger.write(key))
        #expect(retried.operationID == third.operationID && retried.attempts == 2, "a retry continues the same operation")
    }
    @Test func dismissingAFailureKeepsTheOldValue() async throws {
        let script = WriterScript()
        await script.push(.success(.rejected(.service)))
        let ledger = ledger(script)
        await ledger.submit(.rate(like, to: .like))
        ledger.dismiss(.rating(videoID: video))
        #expect(ledger.writes.isEmpty && ledger.rating(video, service: .indifferent) == .indifferent)
        await ledger.submit(.rate(like, to: .like)); ledger.dismiss(.rating(videoID: video))
    }
    @Test func saveAndFollowIntentsCarryTheirOwnKeysAndDirection() async throws {
        let save = MusicItemControls.Save(playlistID: "OLAK5uy_abc", isSaved: true)
        let remove = LibraryIntent.setSaved(save, to: false, was: true)
        #expect(remove.request == .savePlaylist(playlistID: "OLAK5uy_abc", saved: false) && remove.key == .playlistSaved(playlistID: "OLAK5uy_abc") && remove.previous == .saved(true))
        let song = MusicItemControls.SongLibrary(isSaved: false, addToken: "synthetic-add-token-0001", removeToken: nil)
        #expect(LibraryIntent.setSongSaved(song, videoID: video, to: true)?.request == .songLibrary(feedbackToken: "synthetic-add-token-0001"))
        #expect(LibraryIntent.setSongSaved(song, videoID: video, to: false) == nil, "no remove token was published: the change isn't offered")
    }
}

// MARK: Which controls an entry offers

@MainActor @Suite struct LibraryControlsTests {
    private func ledger() -> LibraryWriteLedger { LibraryWriteLedger(writer: { _ in throw MusicSessionError.policy }) }
    @Test func onlyWhatTheEntryPublishedIsOffered() throws {
        let bare = MusicCatalogItem(kind: .song, title: "S", videoID: video)
        #expect(LibraryControls.make(item: bare, source: LibrarySource(kind: .songs), ledger: ledger()).isEmpty)
        let rated = MusicCatalogItem(kind: .song, title: "S", videoID: video, controls: .init(like: .init(videoID: video, status: .indifferent, dislikeExposed: false)))
        let kinds = LibraryControls.make(item: rated, source: nil, ledger: ledger()).map(\.kind)
        #expect(kinds == [.like], "no dislike unless the service exposes it")
        let both = MusicCatalogItem(kind: .song, title: "S", videoID: video, controls: .init(like: .init(videoID: video, status: .like, dislikeExposed: true)))
        let controls = LibraryControls.make(item: both, source: nil, ledger: ledger())
        #expect(controls.map(\.kind) == [.like, .dislike] && controls[0].isOn && controls[0].title == String(localized: "Remove Like"))
    }
    @Test func aSongOffersSaveOnlyWithTheTokenForThatDirection() throws {
        let unsaved = MusicCatalogItem(kind: .song, title: "S", videoID: video, controls: .init(songLibrary: .init(isSaved: false, addToken: "synthetic-add-token-0001", removeToken: nil)))
        #expect(LibraryControls.make(item: unsaved, source: nil, ledger: ledger()).map(\.kind) == [.save])
        let noToken = MusicCatalogItem(kind: .song, title: "S", videoID: video, controls: .init(songLibrary: .init(isSaved: false, addToken: nil, removeToken: "synthetic-remove-token-1")))
        #expect(LibraryControls.make(item: noToken, source: nil, ledger: ledger()).isEmpty)
    }
    /// The critic's probe D: the person's own playlist and Liked Music are listed in Playlists, and the web client offers no "remove from
    /// library" for them. Nothing is invented from membership: a save control exists only where the entry published a toggle.
    @Test func noLibraryActionIsInventedFromMembership() throws {
        for (title, list) in [("My own playlist", "PLprobeOwnedPlaylist0001"), ("Liked Music", "LM"), ("Episodes for Later", "SE")] {
            let item = MusicCatalogItem(kind: .playlist, title: title, browseID: "VL" + list, playlistID: list)
            let controls = LibraryControls.make(item: item, source: LibrarySource(kind: .playlists), ledger: ledger())
            #expect(controls.isEmpty, Comment(rawValue: "\(title): offered \(controls.map { "\($0.title) -> \($0.intent.request)" })"))
        }
        let album = MusicCatalogItem(kind: .album, title: "A", browseID: "MPREb_x", playlistID: "OLAK5uy_abc")
        #expect(LibraryControls.make(item: album, source: LibrarySource(kind: .albums), ledger: ledger()).isEmpty, "an album card that published no toggle offers none")
        let show = MusicCatalogItem(kind: .podcast, title: "S", browseID: "MPSPPLx", playlistID: "PLshow")
        #expect(LibraryControls.make(item: show, source: LibrarySource(kind: .podcasts), ledger: ledger()).isEmpty)
        let liked = MusicCatalogItem(kind: .song, title: "S", videoID: video)
        #expect(LibraryControls.make(item: liked, source: LibrarySource(kind: .likedSongs), ledger: ledger()).isEmpty, "a row with no like button gets no like button")
    }
    @Test func aSaveToggleTheEntryPublishedIsOffered() throws {
        let published = MusicCatalogItem(kind: .album, title: "A", browseID: "MPREb_x", playlistID: "OLAK5uy_abc", controls: .init(save: .init(playlistID: "OLAK5uy_abc", isSaved: true)))
        let controls = LibraryControls.make(item: published, source: LibrarySource(kind: .albums), ledger: ledger())
        #expect(controls.count == 1 && controls[0].isOn && controls[0].intent.request == .savePlaylist(playlistID: "OLAK5uy_abc", saved: false))
    }
    @Test func followingOffersUnfollowFromTheChannelTheRowNames() throws {
        let artist = MusicCatalogItem(kind: .artist, title: "Ar", browseID: channel)
        let follow = LibraryControls.make(item: artist, source: LibrarySource(kind: .following), ledger: ledger())
        #expect(follow.count == 1 && follow[0].isOn && follow[0].intent.request == .follow(channelID: channel, params: nil, following: false))
        // The library's own form of the same artist id.
        let library = MusicCatalogItem(kind: .artist, title: "Ar", browseID: "MPLA" + channel)
        let viaLibraryID = LibraryControls.make(item: library, source: LibrarySource(kind: .following), ledger: ledger())
        #expect(viaLibraryID.first?.intent.request == .follow(channelID: channel, params: nil, following: false))
        #expect(MusicLibraryKind.channelID(fromBrowseID: "MPLA" + channel) == channel && MusicLibraryKind.channelID(fromBrowseID: channel) == channel)
        #expect(MusicLibraryKind.channelID(fromBrowseID: "MPLAx") == nil && MusicLibraryKind.channelID(fromBrowseID: "VLLM") == nil)
        #expect(LibraryControls.make(item: artist, source: LibrarySource(kind: .artists), ledger: ledger()).isEmpty, "an artist among a library's artists isn't thereby followed")
    }
    @Test func anOptimisticRemovalShowsAsRemovedUntilItFails() async throws {
        let script = WriterScript()
        await script.setHold(true)
        let ledger = LibraryWriteLedger(writer: { try await script.write($0) }, accountScope: { "s" })
        let album = MusicCatalogItem(kind: .album, title: "A", browseID: "MPREb_x", playlistID: "OLAK5uy_abc", controls: .init(save: .init(playlistID: "OLAK5uy_abc", isSaved: true)))
        let source = LibrarySource(kind: .albums)
        let control = try #require(LibraryControls.make(item: album, source: source, ledger: ledger).first)
        let task = Task { await ledger.submit(control.intent) }
        await settle()
        #expect(LibraryControls.make(item: album, source: source, ledger: ledger).first?.isOn == false)
        await script.push(.success(.rejected(.service)))
        await script.release(); await task.value
        #expect(LibraryControls.make(item: album, source: source, ledger: ledger).first?.isOn == true, "rolled back to saved")
    }
    @Test func pageHeadersOfferSaveAndFollowFromWhatTheyPublished() throws {
        let album = try MusicBrowseParser.parse(try realCapture("album"))
        let save = LibraryControls.make(page: album.header!.actions, ledger: ledger())
        #expect(save.map(\.kind) == [.save] && !save[0].isOn)
        let artist = try MusicBrowseParser.parse(try realCapture("artist"))
        let follow = LibraryControls.make(page: artist.header!.actions, ledger: ledger())
        #expect(follow.map(\.kind) == [.follow] && follow[0].intent.request == .follow(channelID: "UC_kRDKYrUlrbtrSiyu5Tflg", params: "EgIIGxgA", following: true))
        #expect(LibraryControls.make(page: MusicPageActions(offersSave: true), ledger: ledger()).isEmpty)
    }
}
