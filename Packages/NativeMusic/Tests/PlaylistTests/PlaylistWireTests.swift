import AccountSession
import Foundation
import Testing
@testable import YouTubeMusicAdapter

private let list = "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"
private let video = "dQw4w9WgXcQ"

/// The playlist requests as bytes: a real SignedMusicClient over a scripted transport; nothing here reaches a network.
@Suite struct PlaylistWireTests {
    private func send(_ request: MusicPlaylistRequest, body: String, status: Int = 200) async throws -> (MusicPlaylistOutcome, URLRequest?) {
        let transport = ScriptedSigned(body: Data(body.utf8), status: status)
        let outcome = try await signedClient(transport).editPlaylist(request, session: try testSession()).value
        return (outcome, await transport.captured().first)
    }
    private func fixture(_ name: String) throws -> String { String(decoding: try w13Data(name), as: UTF8.self) }
    private func actions(_ request: URLRequest) throws -> [[String: Any]] { try #require(try requestBody(request)["actions"] as? [[String: Any]]) }

    // MARK: Comparison with Kaset's working requests (Sources/Kaset/Services/API/YTMusicClient.swift @ 4c59ff2)
    // create:  POST playlist/create        {title, privacyStatus, [description], [videoIds]}
    // add:     POST browse/edit_playlist   {playlistId, actions:[{action:ACTION_ADD_VIDEO, addedVideoId}]}
    // remove:  POST browse/edit_playlist   {playlistId, actions:[{action:ACTION_REMOVE_VIDEO, removedVideoId, setVideoId}]}
    // delete:  POST playlist/delete        {playlistId}
    // Kaset has no move, rename or privacy edit; those follow the web client's action names (ytmusicapi convention) and are on the live list.

    @Test func createIsPrivateByDefaultAndMatchesKasetsBody() async throws {
        let (outcome, sent) = try await send(.create(title: "Road trip", description: nil, privacy: PlaylistCreatorDefaults.privacy, videoIDs: []), body: try fixture("create-ok.json"))
        let request = try #require(sent)
        #expect(request.url?.absoluteString == "https://music.youtube.com/youtubei/v1/playlist/create?prettyPrint=false")
        let body = try requestBody(request)
        #expect(body["title"] as? String == "Road trip" && body["privacyStatus"] as? String == "PRIVATE")
        #expect(Set(body.keys) == ["title", "privacyStatus", "context"], "no description and no videoIds when none were given: \(Set(body.keys))")
        #expect(outcome.outcome == .confirmed && outcome.createdPlaylistID == "PLsyntheticCreated0000000000000000001")
    }
    @Test func createCarriesDescriptionAndSeedSongsWhenGiven() async throws {
        let (_, sent) = try await send(.create(title: "T", description: "About", privacy: .unlisted, videoIDs: [video]), body: try fixture("create-ok.json"))
        let body = try requestBody(try #require(sent))
        #expect(body["description"] as? String == "About" && body["videoIds"] as? [String] == [video] && body["privacyStatus"] as? String == "UNLISTED")
        // A blank description is not sent at all.
        let (_, blank) = try await send(.create(title: "T", description: "  \n", privacy: .private, videoIDs: []), body: try fixture("create-ok.json"))
        #expect(try requestBody(try #require(blank))["description"] == nil)
    }
    @Test func eachEditActionHasTheWebClientsShape() async throws {
        let cases: [(MusicPlaylistEditAction, [String: String])] = [
            // The references define the option by what it does to the service's own duplicate check: ytmusicapi `add_playlist_items`
            // (4da34b6, lines 444-464: `if duplicates: action["dedupeOption"] = "DEDUPE_OPTION_SKIP"`; without it "an error will be
            // returned if there are duplicates") and Kaset `addSongToPlaylist` (`:1617`, sends none, "the server de-dupes").
            // So Keep duplicates sends SKIP (the check is skipped), and Skip existing sends nothing (the check stays on).
            (.add(videoID: video, duplicates: .keepDuplicates), ["action": "ACTION_ADD_VIDEO", "addedVideoId": video, "dedupeOption": "DEDUPE_OPTION_SKIP"]),
            (.add(videoID: video, duplicates: .skipExisting), ["action": "ACTION_ADD_VIDEO", "addedVideoId": video]),
            (.remove(videoID: video, setVideoID: "56B44F6D10557CC6"), ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": video, "setVideoId": "56B44F6D10557CC6"]),
            (.moveBefore(setVideoID: "AAAA1111", successorSetVideoID: "BBBB2222"), ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": "AAAA1111", "movedSetVideoIdSuccessor": "BBBB2222"]),
            (.moveBefore(setVideoID: "AAAA1111", successorSetVideoID: nil), ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": "AAAA1111"]),
            (.rename("New name"), ["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": "New name"]),
            (.describe("About it"), ["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": "About it"]),
            (.setPrivacy(.unlisted), ["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": "UNLISTED"]),
            (.describe(""), ["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": ""]),    // clearing: unverified live (ytmusicapi sends only non-empty)
            (.createInviteLink, ["action": "ACTION_CREATE_COLLABORATION_INVITE_LINK"]),
            (.joinCollaboration(token: "kM9wXdRj2p8v_qL3sHBkTz"), ["action": "ACTION_JOIN_COLLABORATION", "joinCollaborationToken": "kM9wXdRj2p8v_qL3sHBkTz"]),
        ]
        for (action, expected) in cases {
            let (_, sent) = try await send(.edit(playlistID: list, actions: [action]), body: try fixture("edit-succeeded.json"))
            let request = try #require(sent)
            #expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://music.youtube.com/youtubei/v1/browse/edit_playlist?prettyPrint=false")
            let body = try requestBody(request)
            #expect(body["playlistId"] as? String == list && Set(body.keys) == ["playlistId", "actions", "context"], Comment(rawValue: "\(Set(body.keys))"))
            let sentAction = try #require(try actions(request).first as? [String: String])
            #expect(sentAction == expected, Comment(rawValue: "\(action): \(sentAction)"))
        }
        // Closing to contributions carries a boolean, not a string.
        let (_, closing) = try await send(.edit(playlistID: list, actions: [.closeToContributions]), body: try fixture("edit-succeeded.json"))
        let closingRequest = try #require(closing)
        let closed = try #require(try actions(closingRequest).first)
        #expect(closed["action"] as? String == "ACTION_SET_CLOSED_TO_CONTRIBUTIONS")
        #expect(closed["closedToContributions"] as? Bool == true)
    }
    @Test func collaborationRequestsAreAlwaysAloneAndNeedAValidToken() {
        func ok(_ actions: [MusicPlaylistEditAction]) -> Bool { MusicPlaylistRequest.edit(playlistID: list, actions: actions).isWellFormed }
        #expect(ok([.createInviteLink]) && ok([.closeToContributions]) && ok([.joinCollaboration(token: "kM9wXdRj2p8v_qL3sHBkTz")]))
        #expect(!ok([.createInviteLink, .rename("x")]), "never combined with another change")
        #expect(!ok([.rename("x"), .closeToContributions]))
        for token in ["", "short", "has space in it 1234", "https://x.example/?a=b", String(repeating: "a", count: 200)] {
            #expect(!ok([.joinCollaboration(token: token)]), Comment(rawValue: token))
        }
    }
    @Test func theInviteLinkAnswerIsParsedAndOnlyAValidOneIsKept() async throws {
        let id = list
        let ok = try await send(.edit(playlistID: id, actions: [.createInviteLink]), body: try fixture("edit-invite-link.json")).0
        #expect(ok.outcome == .confirmed)
        let link = try #require(ok.inviteLink)
        #expect(link.contains("jct=kM9wXdRj2p8v_qL3sHBkTz"))
        let foreign = try await send(.edit(playlistID: id, actions: [.createInviteLink]), body: try fixture("edit-invite-link-foreign.json")).0
        #expect(foreign.outcome == .confirmed, "the request succeeded; what it printed is judged separately")
        // (PlaylistSharing keeps only a link on a YouTube host that names this playlist; see PlaylistSessionTests.)
        let bare = try await send(.edit(playlistID: id, actions: [.createInviteLink]), body: try fixture("edit-succeeded-no-results.json")).0
        #expect(bare.outcome == .confirmed && bare.inviteLink == nil)
    }
    @Test func theRealSignedAddShapeAgreesWithOurs() throws {
        // The only real SIGNED capture available (Kaset's, W12-kaset-real) carries ACTION_ADD_VIDEO with these keys; ours is a subset of them.
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("W12-kaset-real/artist_lofi_girl_episodes_more.json"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"action\" : \"ACTION_ADD_VIDEO\"") || text.contains("\"action\":\"ACTION_ADD_VIDEO\""))
        #expect(text.contains("addedVideoId"))
        let skipping = SignedMusicClient.wire(.add(videoID: video, duplicates: .skipExisting))
        #expect(Set(skipping.keys) == ["action", "addedVideoId"], "the check stays on: only keys the real capture also carries")
        let keeping = SignedMusicClient.wire(.add(videoID: video, duplicates: .keepDuplicates))
        #expect(Set(keeping.keys) == ["action", "addedVideoId", "dedupeOption"])
        #expect(keeping["dedupeOption"] as? String == "DEDUPE_OPTION_SKIP", "the option that lets a duplicate in (the real capture sends CHECK, which asks first)")
    }
    @Test func removeAndMoveNameTheOccurrenceNotJustTheVideo() async throws {
        let (_, sent) = try await send(.edit(playlistID: list, actions: [.remove(videoID: video, setVideoID: "OCC1"), .moveBefore(setVideoID: "OCC2", successorSetVideoID: "OCC3")]), body: try fixture("edit-succeeded.json"))
        let sentActions = try actions(try #require(sent))
        #expect(sentActions[0]["setVideoId"] as? String == "OCC1" && sentActions[1]["setVideoId"] as? String == "OCC2")
    }
    @Test func deleteMatchesKasetsBody() async throws {
        let (outcome, sent) = try await send(.delete(playlistID: list), body: try fixture("delete-ok.json"))
        let request = try #require(sent)
        #expect(request.url?.absoluteString == "https://music.youtube.com/youtubei/v1/playlist/delete?prettyPrint=false")
        #expect(Set(try requestBody(request).keys) == ["playlistId", "context"] && outcome.outcome == .confirmed)
    }

    // MARK: Answers

    @Test func anEditNeedsTheServicesOwnSuccessStatus() async throws {
        let ok = try await send(.edit(playlistID: list, actions: [.add(videoID: video, duplicates: .keepDuplicates)]), body: try fixture("edit-succeeded.json")).0
        #expect(ok.outcome == .confirmed && ok.added == [.init(videoID: video, setVideoID: "ADDED00000000001")])
        let flat = try await send(.edit(playlistID: list, actions: [.add(videoID: video, duplicates: .keepDuplicates)]), body: try fixture("edit-succeeded-flat.json")).0
        #expect(flat.added == ok.added)
        let none = try await send(.edit(playlistID: list, actions: [.rename("x")]), body: try fixture("edit-succeeded-no-results.json")).0
        #expect(none.outcome == .confirmed && none.added.isEmpty)
        #expect(try await send(.edit(playlistID: list, actions: [.rename("x")]), body: try fixture("edit-failed.json")).0.outcome == .rejected(.service))
        #expect(try await send(.edit(playlistID: list, actions: [.rename("x")]), body: try fixture("edit-error.json")).0.outcome == .rejected(.service))
        // A bare 200 is not success.
        #expect(try await send(.edit(playlistID: list, actions: [.rename("x")]), body: try fixture("edit-no-status.json")).0.outcome == .indeterminate(.unrecognisedAnswer))
    }
    @Test func aCreateNeedsAUserPlaylistIdBackAndADeleteNeedsAStatus() async throws {
        #expect(try await send(.create(title: "T", description: nil, privacy: .private, videoIDs: []), body: try fixture("create-missing-id.json")).0.outcome == .indeterminate(.unrecognisedAnswer))
        // An id that is not a user playlist's (an album id) is not "the created playlist".
        let wrong = try await send(.create(title: "T", description: nil, privacy: .private, videoIDs: []), body: try fixture("create-wrong-kind-id.json")).0
        #expect(wrong.outcome == .indeterminate(.unrecognisedAnswer) && wrong.createdPlaylistID == nil)
        #expect(try await send(.delete(playlistID: list), body: try fixture("delete-bare.json")).0.outcome == .indeterminate(.unrecognisedAnswer))
    }
    @Test func httpStatusesAndLostConnectionsMapToDefiniteOrUnknownOutcomes() async throws {
        let request = MusicPlaylistRequest.edit(playlistID: list, actions: [.rename("x")])
        #expect(try await send(request, body: "{}", status: 429).0.outcome == .rejected(.rateLimited))
        #expect(try await send(request, body: "{}", status: 503).0.outcome == .rejected(.unavailable))
        await #expect(throws: MusicSessionError.signedOut) { _ = try await send(request, body: "{}", status: 401) }
        let lost = ScriptedSigned(failure: URLError(.timedOut))
        let afterSend = try await signedClient(lost).editPlaylist(request, session: try testSession()).value
        #expect(afterSend.outcome == .indeterminate(.noAnswer), "the request left: it may have been applied")
        let loggedOut = #"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":true}},"status":"STATUS_SUCCEEDED"}"#
        await #expect(throws: MusicSessionError.signedOut) { _ = try await send(request, body: loggedOut) }
    }

    @Test func aFailureBeforeAnythingLeftIsAFailureNotAnUnknownOutcome() async throws {
        // The client version cannot be read, so no request is built or sent: the person is told nothing was changed.
        let transport = ScriptedSigned(body: try w13Data("edit-succeeded.json"))
        let client = SignedMusicClient(transport: transport, clock: FixedNow()) { throw URLError(.notConnectedToInternet) }
        await #expect(throws: MusicSessionError.self) { _ = try await client.editPlaylist(.edit(playlistID: list, actions: [.rename("x")]), session: try testSession()) }
        #expect(await transport.captured().isEmpty)
    }

    // MARK: Policy: what may be sent at all

    @Test func onlyEditablePlaylistIdsAreEverSent() async throws {
        for id in ["LM", "WL", "SE", "OLAK5uy_abcdefghijklmnop", "RDCLAK5uy_abcdefghij", "VL" + list, "", "PL", "PL../../x", "PLabc def00000"] {
            let transport = ScriptedSigned(body: try w13Data("edit-succeeded.json"))
            await #expect(throws: MusicSessionError.policy, Comment(rawValue: id)) { _ = try await signedClient(transport).editPlaylist(.edit(playlistID: id, actions: [.rename("x")]), session: try testSession()) }
            await #expect(throws: MusicSessionError.policy, Comment(rawValue: id)) { _ = try await signedClient(transport).editPlaylist(.delete(playlistID: id), session: try testSession()) }
            #expect(await transport.captured().isEmpty, "nothing left for \(id)")
        }
    }
    @Test func malformedActionsAreRefusedBeforeAnythingIsSent() async throws {
        let bad: [MusicPlaylistRequest] = [
            .edit(playlistID: list, actions: []),
            .edit(playlistID: list, actions: [.add(videoID: "short", duplicates: .keepDuplicates)]),
            .edit(playlistID: list, actions: [.remove(videoID: video, setVideoID: "")]),
            .edit(playlistID: list, actions: [.remove(videoID: video, setVideoID: "has space")]),
            .edit(playlistID: list, actions: [.moveBefore(setVideoID: "A", successorSetVideoID: "A")]),
            .edit(playlistID: list, actions: [.rename("")]),
            .edit(playlistID: list, actions: [.rename("<script>")]),
            .edit(playlistID: list, actions: [.rename(String(repeating: "x", count: 151))]),
            .edit(playlistID: list, actions: Array(repeating: .add(videoID: video, duplicates: .keepDuplicates), count: 51)),
            .create(title: "  ", description: nil, privacy: .private, videoIDs: []),
            .create(title: "T", description: nil, privacy: .private, videoIDs: ["nope"]),
        ]
        for request in bad {
            let transport = ScriptedSigned(body: try w13Data("edit-succeeded.json"))
            await #expect(throws: MusicSessionError.policy, Comment(rawValue: "\(request)")) { _ = try await signedClient(transport).editPlaylist(request, session: try testSession()) }
            #expect(await transport.captured().isEmpty)
        }
    }
    @Test func theThreePlaylistPathsAreAllowlistedAndNothingElseWasAdded() {
        #expect(SignedMusicPolicy.playlistWritePaths == ["/youtubei/v1/playlist/create", "/youtubei/v1/browse/edit_playlist", "/youtubei/v1/playlist/delete"])
        // The six library write paths are unchanged; W19 added exactly one (the confirmed upload removal, pinned in LibraryTests and UploadsTests).
        #expect(SignedMusicPolicy.writePaths.count == 7 && SignedMusicPolicy.writePaths.contains("/youtubei/v1/music/delete_privately_owned_entity"), "the six library write paths plus the one upload removal")
        #expect(SignedMusicPolicy.playlistWritePaths.isDisjoint(with: SignedMusicPolicy.writePaths))
    }

    // MARK: The carried safety fix: a test-made transport can never reach the network

    @Test func aTestMadeTransportRefusesWhatItsProtocolsDoNotAnswer() async throws {
        // TH2: counted per path. The process-wide total moved whenever another test (they run in parallel, and this suite's next test refuses a request too) refused one in between.
        let path = "/youtubei/v1/browse/edit_playlist"
        let before = RefuseEverythingURLProtocol.refusedCount(forPath: path)
        let transport = DirectSignedMusicTransport(protocolClasses: [])
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/browse/edit_playlist?prettyPrint=false")!)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        for (name, value) in [("Cookie", "SAPISID=x"), ("Authorization", "SAPISIDHASH 1_abc"), ("Origin", "https://music.youtube.com"), ("X-Origin", "https://music.youtube.com")] { request.setValue(value, forHTTPHeaderField: name) }
        await #expect(throws: MusicSessionError.network) { _ = try await transport.send(request, maximumBytes: 1000) }
        #expect(RefuseEverythingURLProtocol.refusedCount(forPath: path) == before + 1, "the refusing protocol answered, not the network")
    }
    @Test func theRefusingProtocolIsAlwaysLastAndAGivenProtocolStillWins() async throws {
        final class Answer: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { request.url?.path.hasSuffix("/browse") == true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let transport = DirectSignedMusicTransport(protocolClasses: [Answer.self])
        func make(_ path: String) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/\(path)?prettyPrint=false")!)
            request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
            for (name, value) in [("Cookie", "SAPISID=x"), ("Authorization", "SAPISIDHASH 1_abc"), ("Origin", "https://music.youtube.com"), ("X-Origin", "https://music.youtube.com")] { request.setValue(value, forHTTPHeaderField: name) }
            return request
        }
        let answered = try await transport.send(make("browse"), maximumBytes: 1000)
        #expect(answered.status == 200)
        let before = RefuseEverythingURLProtocol.refusedCount(forPath: "/youtubei/v1/search")
        await #expect(throws: MusicSessionError.network) { _ = try await transport.send(make("search"), maximumBytes: 1000) }
        #expect(RefuseEverythingURLProtocol.refusedCount(forPath: "/youtubei/v1/search") == before + 1)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/YouTubeMusicAdapter/SignedMusic.swift"), encoding: .utf8)
        #expect(source.contains("protocolClasses + [RefuseEverythingURLProtocol.self]"), "appended after the given classes, never before")
    }
}

/// The form's default and the request's default are the same value.
enum PlaylistCreatorDefaults { static let privacy = MusicPlaylistPrivacy.private }
