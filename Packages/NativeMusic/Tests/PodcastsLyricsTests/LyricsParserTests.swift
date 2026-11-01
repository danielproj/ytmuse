import AccountSession
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// T18.3 (parser half): missing and untimed lyrics stay missing and plain; no timing is inferred; "no lyrics" is never read off an unreadable answer.
@Suite struct LyricsParserTests {
    @Test func aSongWhoseNextOffersNoLyricsPageHasNoLyrics() throws {
        for name in ["next-lyrics-tab-unselectable.json", "next-without-lyrics-tab.json"] {
            let next = try MusicLyricsParser.parseWatchNext(try synthetic(name))
            #expect(next.lyricsBrowseID == nil, Comment(rawValue: name))
            #expect(next.tabs.contains { $0.kind == .upNext })
        }
    }
    @Test func aResponseThatIsNotAWatchNextPageIsUnreadableNeverNoLyrics() throws {
        #expect(throws: MusicSessionError.unrecognised) { _ = try MusicLyricsParser.parseWatchNext(try synthetic("next-not-a-queue.json")) }
        #expect(throws: MusicSessionError.unrecognised) { _ = try MusicLyricsParser.parseWatchNext([:]) }
        #expect(throws: MusicSessionError.unrecognised) { _ = try MusicLyricsParser.parseWatchNext(try real(.lyrics)) }
        #expect(throws: MusicSessionError.unrecognised) { _ = try MusicLyricsParser.parseWatchNext(["error": ["code": 400]]) }
    }
    @Test func aMessageOrAnEmptyShelfIsAnEmptyPageAndAnUnknownLayoutIsAnError() throws {
        #expect(try MusicLyricsParser.parseLyrics(try synthetic("lyrics-message.json")) == .none(.emptyPage))
        #expect(try MusicLyricsParser.parseLyrics(try synthetic("lyrics-empty-description.json")) == .none(.emptyPage))
        #expect(throws: MusicSessionError.unrecognised) { _ = try MusicLyricsParser.parseLyrics(try synthetic("lyrics-unreadable.json")) }
        #expect(throws: MusicSessionError.unrecognised) { _ = try MusicLyricsParser.parseLyrics([:]) }
        #expect(throws: MusicSessionError.unrecognised) { _ = try MusicLyricsParser.parseLyrics(["error": ["code": 500], "contents": [:]]) }
    }
    @Test func timedLinesAreReturnedOnlyFromATimedShapeWithTheTimesItPrinted() throws {
        guard case .lyrics(let document) = try MusicLyricsParser.parseLyrics(try synthetic("lyrics-timed.json")), case .timed(let lines) = document.body else { Issue.record("expected timed"); return }
        #expect(document.isTimed && document.sourceFooter == "Source: Example Lyrics Provider")
        #expect(lines.map(\.start) == [1.5, 4.0, 7.25, 9.0] && lines.map(\.text) == ["Placeholder line one", "Placeholder line two", "", "Placeholder line four"])
        #expect(lines.map(\.end) == [4.0, 7.25, 9.0, 12.0])
        guard case .lyrics(let strings) = try MusicLyricsParser.parseLyrics(try synthetic("lyrics-timed-strings.json")), case .timed(let parsed) = strings.body else { Issue.record("expected timed"); return }
        #expect(parsed.map(\.start) == [0, 1.0])
    }
    @Test func timedLyricsThatAreNotWellFormedAreRefusedWholeNeverRepaired() throws {
        for name in ["lyrics-timed-out-of-order.json", "lyrics-timed-no-cue.json", "lyrics-timed-end-before-start.json"] {
            #expect(throws: MusicSessionError.unrecognised, Comment(rawValue: name)) { _ = try MusicLyricsParser.parseLyrics(try synthetic(name)) }
        }
    }
    @Test func whitespaceEdgesRunsAndTheFooterAreKeptExactly() throws {
        guard case .lyrics(let document) = try MusicLyricsParser.parseLyrics(try synthetic("lyrics-verbatim-edges.json")), case .plain(let text) = document.body else { Issue.record("expected plain lyrics"); return }
        #expect(text == "\n\n  Indented first line\n\tTabbed line\n   \nDouble  space and trailing spaces   \n\nSecond run, then\n\n\n")
        #expect(document.sourceFooter == "Source: Placeholder Provider ", "the footer is the runs joined, untouched, trailing space included")
    }
    @Test func theRealPlainPageNeverBecomesTimed() throws {
        guard case .lyrics(let document) = try MusicLyricsParser.parseLyrics(try real(.lyrics)) else { Issue.record("expected lyrics"); return }
        if case .timed = document.body { Issue.record("timing was invented for an untimed page") }
    }
}

/// The two requests behind lyrics, over scripted transports (nothing reaches a network): `next`, then the lyrics page `next` named.
@Suite struct LyricsTransportTests {
    private let video = "khnokW3Mw24"
    @Test func anonymousLyricsAreTwoPostsToNextThenBrowse() async throws {
        let transport = ScriptedPublic(bodies: [try realData(.next), try realData(.lyrics)])
        let client = try PublicMusicClient(transport: transport)
        let result = try await client.lyrics(videoID: video)
        guard case .lyrics(let document) = result else { Issue.record("expected lyrics"); return }
        #expect(document.sourceFooter == "Source: Musixmatch")
        let posts = await transport.captured().filter { $0.httpMethod == "POST" }
        #expect(posts.map { $0.url?.path } == ["/youtubei/v1/next", "/youtubei/v1/browse"])
        let first = try requestBody(posts[0]), second = try requestBody(posts[1])
        #expect(first["videoId"] as? String == video && first["isAudioOnly"] as? Bool == true)
        #expect(second["browseId"] as? String == "MPLYt_K8qWMWVqXGi-5")
        #expect(posts.allSatisfy { $0.url?.query == "prettyPrint=false" && $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil })
    }
    @Test func aSongWithNoLyricsPageStopsAfterNext() async throws {
        let transport = ScriptedPublic(bodies: [try Data(contentsOf: fixturesRoot().appendingPathComponent("W18/next-without-lyrics-tab.json"))])
        let result = try await PublicMusicClient(transport: transport).lyrics(videoID: video)
        #expect(result == .none(.notOffered))
        #expect(await transport.captured().filter { $0.httpMethod == "POST" }.count == 1, "no lyrics browse is asked for")
    }
    @Test func signedLyricsCarryTheSessionOnBothRequests() async throws {
        let transport = ScriptedSigned(bodies: [try realData(.next), try realData(.lyrics)])
        let result = try await signedClient(transport).lyrics(videoID: video, session: try testSession()).value
        guard case .lyrics = result else { Issue.record("expected lyrics"); return }
        let requests = await transport.captured()
        #expect(requests.map { $0.url?.path } == ["/youtubei/v1/next", "/youtubei/v1/browse"])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true && request.value(forHTTPHeaderField: "Cookie")?.isEmpty == false)
        }
    }
    @Test func aSignedAnswerThatSuppliesTimingIsReadAsTimed() async throws {
        let timed = try Data(contentsOf: fixturesRoot().appendingPathComponent("W18/lyrics-timed.json"))
        let transport = ScriptedSigned(bodies: [try realData(.next), timed])
        guard case .lyrics(let document) = try await signedClient(transport).lyrics(videoID: video, session: try testSession()).value else { Issue.record("expected lyrics"); return }
        #expect(document.isTimed)
    }
    @Test func badIdentifiersAreRefusedBeforeAnythingIsSent() async throws {
        let transport = ScriptedSigned(bodies: [])
        await #expect(throws: MusicSessionError.policy) { _ = try await signedClient(transport).lyrics(videoID: "short", session: try testSession()) }
        await #expect(throws: MusicSessionError.policy) { _ = try await signedClient(transport).episode(id: "bad id!", session: try testSession()) }
        #expect(await transport.captured().isEmpty)
        await #expect(throws: ConnectionError.invalidInput) { _ = try await PublicMusicClient(transport: ScriptedPublic(bodies: [])).lyrics(videoID: "x") }
    }
    @Test func anUnreadableNextIsAnErrorNeverNoLyrics() async throws {
        let transport = ScriptedPublic(bodies: [Data(#"{"contents":{"somethingElse":{}}}"#.utf8)])
        await #expect(throws: ConnectionError.shape) { _ = try await PublicMusicClient(transport: transport).lyrics(videoID: video) }
    }
    @Test func nextIsAReadPathAndNotAWritePath() {
        #expect(SignedMusicPolicy.musicPaths.contains("/youtubei/v1/next"))
        #expect(!SignedMusicPolicy.writePaths.contains("/youtubei/v1/next") && !SignedMusicPolicy.playlistWritePaths.contains("/youtubei/v1/next"))
        #expect(SignedMusicPolicy.musicPaths == ["/youtubei/v1/browse", "/youtubei/v1/account/account_menu", "/youtubei/v1/search", "/youtubei/v1/next"])
    }
    @Test func theEpisodePageIsOneBrowseAndAWrongPageIsAnError() async throws {
        let transport = ScriptedPublic(bodies: [try realData(.episode)])
        let page = try await PublicMusicClient(transport: transport).episodePage(id: "MPEDAzENYaFVxGg")
        #expect(page.videoID == "AzENYaFVxGg")
        let posts = await transport.captured().filter { $0.httpMethod == "POST" }
        let body = try requestBody(posts[0])
        #expect(posts.count == 1 && posts[0].url?.path == "/youtubei/v1/browse" && body["browseId"] as? String == "MPEDAzENYaFVxGg")
        await #expect(throws: ConnectionError.shape) { _ = try await PublicMusicClient(transport: ScriptedPublic(bodies: [try realData(.lyrics)])).episodePage(id: "MPEDAzENYaFVxGg") }
    }
}
