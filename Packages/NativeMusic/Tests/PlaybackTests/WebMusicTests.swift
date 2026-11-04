import Foundation
import Testing
import Domain
import AccountSession
import SystemIntegration
import MediaPlayer
import ImageIO
import CoreGraphics
import JavaScriptCore
import CryptoKit
import Observation
@testable import Playback
@testable import AppShell

// Synthetic, sanitized values only: no real session, cookie, page or network.
private let music = WebMusicFrame(isMainFrame: true, scheme: "https", host: "music.youtube.com", port: 0)
private let syntheticVideo = "SYNTHvid001", otherVideo = "SYNTHvid002", adVideo = "SYNTHadv001"
private func state(doc: Int = 1, load: Int = 1, playing: Bool = true, buffering: Bool = false, position: Double = 10, duration: Double = 200,
                   video: String = syntheticVideo, title: String = "Synthetic Song", artist: String = "Synthetic Artist",
                   artwork: String = "https://lh3.googleusercontent.com/synthetic-art", ad: Bool = false,
                   playlist: String? = nil, signedIn: Bool? = nil, content: String? = nil, shuffle: Bool? = nil) -> [String: Any] {
    var body: [String: Any] = ["type": "state", "doc": doc, "load": load, "playing": playing, "buffering": buffering, "position": position, "duration": duration,
     "videoId": video, "title": title, "artist": artist, "artwork": artwork, "ad": ad]
    if let playlist { body["playlistId"] = playlist }
    if let signedIn { body["signedIn"] = signedIn }
    if let content { body["contentId"] = content }
    if let shuffle { body["shuffle"] = shuffle }
    return body
}

@Suite struct WebMusicBridgeTests {
    @Test func acceptsOnlyTheMusicMainFrameOfTheCurrentDocumentAndLoad() throws {
        let accepted = try WebMusicBridge.validate(state(), frame: music, document: 1, load: 1).get()
        guard case .state(let sample) = accepted.event else { Issue.record("not a state"); return }
        #expect(sample.videoID == syntheticVideo && sample.title == "Synthetic Song" && sample.artworkURL?.host == "lh3.googleusercontent.com")
        let subframe = WebMusicFrame(isMainFrame: false, scheme: "https", host: "music.youtube.com", port: 0)
        #expect(WebMusicBridge.validate(state(), frame: subframe, document: 1, load: 1) == .failure(.subframe))
        for frame in [WebMusicFrame(isMainFrame: true, scheme: "http", host: "music.youtube.com", port: 0),
                      WebMusicFrame(isMainFrame: true, scheme: "https", host: "www.youtube.com", port: 0),
                      WebMusicFrame(isMainFrame: true, scheme: "https", host: "music.youtube.com.example", port: 0),
                      WebMusicFrame(isMainFrame: true, scheme: "https", host: "music.youtube.com", port: 8443)] {
            #expect(WebMusicBridge.validate(state(), frame: frame, document: 1, load: 1) == .failure(.origin))
        }
    }
    @Test func rejectsStaleDocumentsAndLoads() {
        #expect(WebMusicBridge.validate(state(doc: 1), frame: music, document: 2, load: 1) == .failure(.staleDocument))
        #expect(WebMusicBridge.validate(state(doc: -1), frame: music, document: 1, load: 1) == .failure(.malformed))
        #expect(WebMusicBridge.validate(state(doc: 0), frame: music, document: 0, load: 1) == .failure(.staleDocument), "no document committed")
        #expect(WebMusicBridge.validate(state(load: 1), frame: music, document: 1, load: 2) == .failure(.staleLoad))
    }
    @Test func rejectsMalformedAndOversizedPayloads() {
        #expect(WebMusicBridge.validate("state", frame: music, document: 1, load: 1) == .failure(.notDictionary))
        #expect(WebMusicBridge.validate(["type": "eval", "doc": 1, "load": 1], frame: music, document: 1, load: 1) == .failure(.unknownType))
        var extra = state(); extra["cookie"] = "x"
        #expect(WebMusicBridge.validate(extra, frame: music, document: 1, load: 1) == .failure(.malformed), "unknown keys reject")
        var wrongType = state(); wrongType["playing"] = "true"
        #expect(WebMusicBridge.validate(wrongType, frame: music, document: 1, load: 1) == .failure(.malformed))
        var numberAsBool = state(); numberAsBool["playing"] = 1
        #expect(WebMusicBridge.validate(numberAsBool, frame: music, document: 1, load: 1) == .failure(.malformed))
        var boolAsNumber = state(); boolAsNumber["position"] = true
        #expect(WebMusicBridge.validate(boolAsNumber, frame: music, document: 1, load: 1) == .failure(.malformed))
        #expect(WebMusicBridge.validate(state(position: .nan), frame: music, document: 1, load: 1) == .failure(.malformed))
        #expect(WebMusicBridge.validate(state(duration: 1e9), frame: music, document: 1, load: 1) == .failure(.malformed))
        #expect(WebMusicBridge.validate(state(video: "not an id"), frame: music, document: 1, load: 1) == .failure(.malformed))
        #expect(WebMusicBridge.validate(state(title: String(repeating: "a", count: 1537)), frame: music, document: 1, load: 1) == .failure(.malformed),
                "raw text beyond the page script's own bound is malformed")
        var nested = state(); nested["title"] = ["nested": "object"]
        #expect(WebMusicBridge.validate(nested, frame: music, document: 1, load: 1) == .failure(.oversized), "nested values are never part of the schema")
        let huge: [String: Any] = ["type": "state", "doc": 1, "load": 1, "title": String(repeating: "a", count: 500), "artist": String(repeating: "b", count: 500),
                                   "artwork": "https://i.ytimg.com/" + String(repeating: "c", count: 2000), "videoId": syntheticVideo,
                                   "playing": true, "buffering": false, "position": 1, "duration": 2, "ad": false]
        let wide = Dictionary(uniqueKeysWithValues: (0..<20).map { ("k\($0)", "v" as Any) })
        #expect(WebMusicBridge.validate(wide, frame: music, document: 1, load: 1) == .failure(.oversized))
        if case .success = WebMusicBridge.validate(huge, frame: music, document: 1, load: 1) {} else { Issue.record("bounded maximum-size sample should pass") }
        var oversized = huge; oversized["artwork"] = "https://i.ytimg.com/" + String(repeating: "c", count: 5000)
        #expect(WebMusicBridge.validate(oversized, frame: music, document: 1, load: 1) == .failure(.oversized))
    }
    @Test func artworkOutsideYouTubeImageHostsIsDroppedNotTrusted() throws {
        for url in ["https://example.com/a.jpg", "http://i.ytimg.com/a.jpg", "https://user:pw@i.ytimg.com/a.jpg", "javascript:alert(1)", "https://i.ytimg.com.evil.example/a.jpg"] {
            let message = try WebMusicBridge.validate(state(artwork: url), frame: music, document: 1, load: 1).get()
            guard case .state(let sample) = message.event else { Issue.record("not state"); continue }
            #expect(sample.artworkURL == nil, "\(url)")
        }
    }
    @Test func endedAndErrorEventsAreSchemaChecked() throws {
        let ended = try WebMusicBridge.validate(["type": "ended", "doc": 1, "load": 1, "videoId": syntheticVideo], frame: music, document: 1, load: 1).get()
        #expect(ended.event == .ended(videoID: syntheticVideo))
        let error = try WebMusicBridge.validate(["type": "error", "doc": 1, "load": 1, "code": 150], frame: music, document: 1, load: 1).get()
        #expect(error.event == .playerError(code: 150))
        #expect(WebMusicBridge.validate(["type": "error", "doc": 1, "load": 1, "code": "150"], frame: music, document: 1, load: 1) == .failure(.malformed))
        #expect(WebMusicBridge.validate(["type": "error", "doc": 1, "load": 1, "code": 1.5], frame: music, document: 1, load: 1) == .failure(.malformed))
    }
}

@Suite struct WebMusicCommandTests {
    @Test func commandsAreConstantBodiesWithTypedArguments() throws {
        let hostile = "PL');alert(document.cookie)//"
        #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.loadPlaylist(hostile, load: 1).invocation() }
        #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.loadPlaylist("PLsynthetic", load: 0).invocation() }
        let load = try WebMusicCommand.loadPlaylist("PLsynthetic_-1", load: 7).invocation()
        #expect(load.body == WebMusicScripts.loadPlaylist && !load.body.contains("PLsynthetic"))
        #expect(load.arguments["playlistId"] as? String == "PLsynthetic_-1" && load.arguments["load"] as? Int == 7)
        let seek = try WebMusicCommand.seek(42.5).invocation()
        #expect(seek.body == WebMusicScripts.seek && seek.arguments["seconds"] as? Double == 42.5 && !seek.body.contains("42.5"))
        for bad in [Double.nan, .infinity, -1, 90_000] {
            #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.seek(bad).invocation() }
        }
        for bad in [Double.nan, -0.1, 1.1] {
            #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.volume(bad).invocation() }
        }
        #expect(try WebMusicCommand.next.invocation().arguments["forward"] as? Bool == true)
        #expect(try WebMusicCommand.previous.invocation().arguments["forward"] as? Bool == false)
    }
    @Test func seekAndSkipScriptsRefuseDuringAdsAndNothingEverMutesOrSkipsAnAd() {
        for body in [WebMusicScripts.seek, WebMusicScripts.skip] { #expect(body.contains("if (ytmuseAdShowing()) { return \"ad\"; }")) }
        let all = [WebMusicScripts.bootstrap, WebMusicScripts.observer, WebMusicScripts.loadPlaylist, WebMusicScripts.play, WebMusicScripts.pause,
                   WebMusicScripts.seek, WebMusicScripts.skip, WebMusicScripts.volume].joined(separator: "\n")
        for forbidden in ["skipAd", "ytp-ad-skip", "muted = true", ".muted=", "display = \"none\"", "remove()", "evaluateJavaScript", "document.cookie"] {
            #expect(!all.contains(forbidden), "\(forbidden)")
        }
        // W18 narrowed this guard from "never the word playbackRate" to "never SETTING it here": the speed of spoken audio is a feature, set only by
        // the `rate` and `normalSpeed` commands (each refused or restricted around ads, and pinned in the W18 suite), and the periodic report now
        // READS the element's speed so the app can reconcile it. The observer, loader, play, pause, seek, skip and volume scripts never assign it.
        let setsSpeed = try! NSRegularExpression(pattern: #"playbackRate\s*=[^=]|setPlaybackRate|defaultPlaybackRate"#)
        #expect(setsSpeed.firstMatch(in: all, range: NSRange(all.startIndex..., in: all)) == nil, "no script outside rate/normalSpeed sets the speed")
        #expect(WebMusicScripts.observer.contains("video.playbackRate"), "the report reads the element's speed")
        // The two scripts that DO set the speed are held to the same advertising rules (rework 2): they never skip, mute, hide, remove or click anything.
        let speed = [WebMusicScripts.rate, WebMusicScripts.normalSpeed].joined(separator: "\n")
        for forbidden in ["skipAd", "ytp-ad-skip", "muted", "display", "visibility", "remove()", ".click(", "evaluateJavaScript", "document.cookie", "skip-button", "hidden"] {
            #expect(!speed.contains(forbidden), "rate/normalSpeed: \(forbidden)")
        }
        #expect(WebMusicScripts.observer.contains("getPresentingPlayerType(true) === 2"))
        #expect(WebMusicScripts.observer.contains("ad-showing") && WebMusicScripts.observer.contains("ad-interrupting"))
    }
    @Test func navigationIsLimitedToYouTubeMusicAndCarriesNativeGenerations() throws {
        let url = try #require(WebMusicNavigation.playlistURL("PLsynthetic", document: 3, load: 9))
        #expect(url.host == "music.youtube.com" && url.path == "/watch")
        #expect(url.query == "list=PLsynthetic&ytmuse_doc=3&ytmuse_load=9&ytmuse_play=1")
        #expect(WebMusicNavigation.document(of: url) == 3)
        #expect(WebMusicNavigation.playlistURL("bad id", document: 1, load: 1) == nil)
        #expect(WebMusicNavigation.document(of: URL(string: "https://www.youtube.com/watch?ytmuse_doc=3")) == nil)
        #expect(WebMusicNavigation.allowsMainFrame(url))
        for blocked in ["https://accounts.google.com/ServiceLogin", "https://consent.youtube.com/", "https://www.youtube.com/watch?v=x",
                        "http://music.youtube.com/", "https://music.youtube.com:8443/", "file:///etc/hosts"] {
            #expect(!WebMusicNavigation.allowsMainFrame(URL(string: blocked)), "\(blocked)")
        }
        #expect(WebMusicNavigation.allowsSubframe(URL(string: "https://www.google.com/recaptcha")))
        #expect(!WebMusicNavigation.allowsSubframe(URL(string: "javascript:alert(1)")))
        #expect(!WebMusicNavigation.allowsSubframe(URL(string: "itms-apps://example")))
    }
}

@Suite struct WebMusicTransportTests {
    private func message(_ body: [String: Any], doc: UInt64 = 1, load: UInt64 = 1) throws -> WebMusicMessage {
        try WebMusicBridge.validate(body, frame: music, document: doc, load: load).get()
    }
    @Test func loadGenerationFencesOlderLoads() throws {
        var transport = WebMusicTransport()
        #expect(transport.begin(playlistID: "PLsynthetic", title: "Mix") == 1)
        #expect(transport.reserveDocument() == 1)
        let first = transport.apply(try message(state()))
        #expect(first)
        #expect(transport.snapshot.phase == .playing && transport.snapshot.title == "Synthetic Song" && transport.confirmed)
        #expect(transport.begin(playlistID: "PLother", title: "Other") == 2)
        let stale = transport.apply(try message(state(title: "Old track")))
        #expect(!stale, "a sample from load 1 cannot publish into load 2")
        #expect(transport.snapshot.title == nil && transport.snapshot.phase == .loading && !transport.confirmed)
        transport.invalidateDocument()
        let invalidated = transport.apply(try message(state(load: 2), doc: 1, load: 2))
        #expect(!invalidated, "an invalidated document cannot publish")
    }
    @Test func adKeepsTrackMetadataAndContentClockAndRefusesSeekAndSkip() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsynthetic", title: "Mix"); _ = transport.reserveDocument()
        transport.apply(try message(state(position: 42, duration: 200)))
        transport.apply(try message(state(position: 3, duration: 15, video: adVideo, title: "Advertiser", artist: "Brand", artwork: "https://i.ytimg.com/ad", ad: true)))
        let snapshot = transport.snapshot
        #expect(snapshot.isAd && snapshot.phase == .playing)
        #expect(snapshot.title == "Synthetic Song" && snapshot.artist == "Synthetic Artist" && snapshot.videoID == syntheticVideo)
        #expect(snapshot.position == 42 && snapshot.duration == 200, "the content clock is kept during the ad")
        #expect(transport.admitSeek(10) == .failure(.advertisement))
        if case .failure(.advertisement) = transport.admitSkip() {} else { Issue.record("skip admitted during an ad") }
        #expect(!snapshot.canSeek && !snapshot.canSkip)
        transport.apply(try message(state(position: 43, duration: 200)))
        #expect(!transport.snapshot.isAd && transport.admitSeek(500) == .success(200))
    }
    @Test func newTrackNeverInheritsPreviousTrackText() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsynthetic", title: nil); _ = transport.reserveDocument()
        transport.apply(try message(state()))
        var next = state(video: otherVideo); next["title"] = ""; next["artist"] = ""; next["artwork"] = ""
        transport.apply(try message(next))
        #expect(transport.snapshot.videoID == otherVideo && transport.snapshot.title == nil && transport.snapshot.artist == nil && transport.snapshot.artworkURL == nil)
    }
    @Test func endedIsConsumedOncePerOccurrenceAndPlayerErrorsAreNoticesNotFreezes() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsynthetic", title: nil); _ = transport.reserveDocument()
        transport.apply(try message(state()))
        let ended = try message(["type": "ended", "doc": 1, "load": 1, "videoId": syntheticVideo])
        let once = transport.apply(ended)
        #expect(once && transport.snapshot.phase == .ended)
        let twice = transport.apply(ended)
        #expect(!twice, "a duplicate ended report is ignored")
        transport.apply(try message(state(playing: false)))
        #expect(transport.snapshot.phase == .ended, "a paused sample of the ended track stays ended")
        transport.apply(try message(["type": "error", "doc": 1, "load": 1, "code": 150]))
        #expect(transport.snapshot.notice == .notPlayable(code: 150) && !transport.snapshot.isFailed && transport.snapshot.intent,
                "a per-track YouTube error is a notice; the transport keeps tracking the page (F3)")
        let advanced = transport.apply(try message(state(video: otherVideo, title: "Next track")))
        #expect(advanced && transport.snapshot.phase == .playing && transport.snapshot.title == "Next track" && transport.snapshot.notice == nil,
                "when YouTube's queue moves on, the transport follows it")
        transport.fail(.timedOut)
        let late = transport.apply(try message(state()))
        #expect(!late, "a terminal failure does not resurrect from late samples")
    }
    @Test func previousRestartsAfterThreeSeconds() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsynthetic", title: nil); _ = transport.reserveDocument()
        transport.apply(try message(state(position: 2.5)))
        #expect(!transport.previousRestarts)
        transport.apply(try message(state(position: 3.5)))
        #expect(transport.previousRestarts)
    }
}

// MARK: Player with a fake page and fake cookie source

@MainActor final class FakeMusicPage: WebMusicPage {
    var installed: [HTTPCookie] = []
    var loads: [URL] = []
    var commands: [WebMusicCommand.Invocation] = []
    var replies: [WebMusicCommandReply] = []
    var tornDown = 0
    var events: [String] = []
    weak var delegate: (any WebMusicPageDelegate)?
    init(delegate: any WebMusicPageDelegate) { self.delegate = delegate }
    func install(cookies: [HTTPCookie]) async { installed += cookies; events.append("install") }
    func load(_ url: URL) { loads.append(url); events.append("load") }
    /// What the page is currently playing. Like the real observer, the next
    /// timeupdate after `loadPlaylist` reports it under the NEW load (F2).
    var nowPlaying: [String: Any]?
    /// Models the real order: the document commits first and YouTube Music's app (and its router) appears LATER. While the router is
    /// absent the target script answers "fallback" (no app yet) exactly as the real one does; `routerAppearsAtAttempt` makes it
    /// appear at the n-th target command.
    static var defaultRouterAvailable = true
    var routerAvailable = FakeMusicPage.defaultRouterAvailable
    var routerAppearsAtAttempt: Int?
    var targetAttempts = 0
    var targetReply: WebMusicCommandReply?
    /// P17-WEB: a test's hook on a command as the page receives it. It may change what the fake page reports, and may answer in the page's place.
    var intercept: ((WebMusicCommand.Invocation) -> WebMusicCommandReply?)?
    var suspendedRadioReply: CheckedContinuation<WebMusicCommandReply, Never>?
    var suspendRadioDispatch = false
    func run(_ invocation: WebMusicCommand.Invocation) async -> WebMusicCommandReply {
        commands.append(invocation); events.append("run")
        if suspendRadioDispatch, invocation.body == WebMusicScripts.updateRadioQueue {
            return await withCheckedContinuation { suspendedRadioReply = $0 }
        }
        if let answer = intercept?(invocation) { return answer }
        if invocation.body == WebMusicScripts.loadTarget || invocation.body == WebMusicScripts.updateRadioQueue {
            targetAttempts += 1
            if let n = routerAppearsAtAttempt, targetAttempts >= n { routerAvailable = true }
            if let targetReply { return targetReply }
            if !routerAvailable { return .fallback }
            return .router
        }
        if invocation.body == WebMusicScripts.loadPlaylist, var sample = nowPlaying, let load = invocation.arguments["load"] as? Int {
            sample["load"] = load
            Task { @MainActor in self.send(sample) }
        }
        return replies.isEmpty ? .ok : replies.removeFirst()
    }
    /// Every inactive-scheduling-policy change the player asked for, in order (true = throttle).
    var throttleLog: [Bool] = []
    func setThrottled(_ throttled: Bool) { throttleLog.append(throttled); events.append(throttled ? "throttle" : "unthrottle") }
    func teardown() async { tornDown += 1; events.append("teardown") }
    var bodies: [String] { commands.map(\.body) }
    /// Commits the last loaded document, as WebKit's didCommit would.
    func commitLast() { delegate?.pageCommitted(document: WebMusicNavigation.document(of: loads.last)) }
    func send(_ body: [String: Any], frame: WebMusicFrame = music) { delegate?.page(received: body, from: frame) }
    var lastDocument: Int { Int(WebMusicNavigation.document(of: loads.last) ?? 0) }
}
actor FakeCookieSource: WebMusicCookieSource {
    var fail = false
    var reads = 0
    var rotations: [[HTTPCookie]] = []
    init(fail: Bool = false) { self.fail = fail }
    func playerCookies() async throws -> [HTTPCookie] {
        reads += 1
        if fail { throw MusicSessionError.keychain }
        return [HTTPCookie(properties: [.name: "SAPISID", .value: "SYNTHETIC-PLAYER-SAPISID", .domain: ".youtube.com", .path: "/", .secure: "TRUE"])!]
    }
    func recordRotation(_ cookies: [HTTPCookie]) async { rotations.append(cookies) }
    func batches() -> [[String]] { rotations.map { $0.map(\.name).sorted() } }
    func rotationCount() -> Int { rotations.count }
    func readCount() -> Int { reads }
}
struct NoArtwork: WebMusicArtworkLoading { func artwork(_ url: URL) async -> Data? { nil } }

@MainActor private func makePlayer(cookies: FakeCookieSource = FakeCookieSource(), timeout: Duration = .seconds(60), shuffleAttempts: Int = 40, router: Bool = true,
                                   routerAppearsAtAttempt: Int? = nil, targetReply: WebMusicCommandReply? = nil) -> (WebMusicPlayer, () -> FakeMusicPage?) {
    var created: FakeMusicPage?
    let player = WebMusicPlayer(cookies: cookies, artwork: NoArtwork(), loadTimeout: timeout, rotationDelay: .milliseconds(20), shuffleAttempts: shuffleAttempts, shuffleInterval: .milliseconds(5)) { delegate in
        let page = FakeMusicPage(delegate: delegate)
        page.routerAvailable = router; page.routerAppearsAtAttempt = routerAppearsAtAttempt; page.targetReply = targetReply
        created = page; return page
    }
    return (player, { created })
}
@MainActor private func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

/// TH1: waits for a condition that is read through an actor, up to 10 s (a bound only a real failure reaches); the caller asserts afterwards.
@MainActor private func settleAsync(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await condition()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

@Suite @MainActor struct WebMusicPlayerTests {
    @Test func nothingIsCreatedOrPlayedUntilAnExplicitPlay() async {
        let cookies = FakeCookieSource()
        let (player, page) = makePlayer(cookies: cookies)
        #expect(page() == nil && !player.hasPage && player.snapshot.phase == .idle)
        await player.resume(); await player.playPause(); await player.seek(5); await player.next()
        #expect(page() == nil, "controls before Play cannot create the page")
        #expect(await cookies.readCount() == 0, "the Keychain session is not read at launch/restore")
    }
    @Test func cookiesAreInstalledBeforeTheFirstLoadAndTheLoadCarriesGenerations() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: "Synthetic Mix")
        let fake = try #require(page())
        #expect(fake.events == ["install", "load"])
        #expect(fake.installed.map(\.name) == ["SAPISID"])
        #expect(fake.loads.last?.query == "list=PLsynthetic&ytmuse_doc=1&ytmuse_load=1&ytmuse_play=1")
        #expect(player.snapshot.phase == .loading && player.snapshot.intent)
        fake.send(state())
        #expect(player.snapshot.phase == .loading, "nothing publishes before the reserved document commits")
        #expect(player.rejected[.staleDocument] == 1)
        fake.commitLast()
        fake.send(state())
        #expect(player.snapshot.phase == .playing && player.snapshot.title == "Synthetic Song")
        fake.send(state(), frame: WebMusicFrame(isMainFrame: false, scheme: "https", host: "music.youtube.com", port: 0))
        #expect(player.rejected[.subframe] == 1)
    }
    @Test func laterPlaylistUsesRouterAndFallsBackToAFullLoadBoundToTheSameLoad() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state())
        fake.replies = [.router]
        await player.play(playlistID: "PLsecond", title: nil)
        #expect(fake.loads.count == 1 && fake.bodies.last == WebMusicScripts.loadPlaylist)
        #expect(fake.commands.last?.arguments["load"] as? Int == 2)
        fake.send(state(load: 1, title: "Stale first playlist"))
        #expect(player.snapshot.title == nil && player.rejected[.staleLoad] == 1)
        fake.send(state(load: 2, title: "Second", playlist: "PLsecond"))
        #expect(player.snapshot.title == "Second")
        fake.replies = [.fallback]
        await player.play(playlistID: "PLthird", title: nil)
        #expect(fake.loads.count == 2 && fake.loads.last?.query == "list=PLthird&ytmuse_doc=2&ytmuse_load=3&ytmuse_play=1")
        fake.send(state(doc: 1, load: 3))
        #expect(player.rejected[.staleDocument] == 1, "the outgoing document is fenced as soon as a new one is reserved")
    }
    @Test func routerTimeoutFallsBackOnceThenFailsVisibly() async throws {
        let (player, page) = makePlayer(timeout: .milliseconds(40))
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state())
        fake.replies = [.router]
        await player.play(playlistID: "PLsecond", title: nil)
        await settle { fake.loads.count == 2 }
        #expect(fake.loads.last?.query == "list=PLsecond&ytmuse_doc=2&ytmuse_load=2&ytmuse_play=1")
        await settle { player.snapshot.phase != .loading }
        #expect(player.snapshot.phase == .failed(.timedOut))
    }
    @Test func seekAndSkipDuringAnAdAreRefusedWithoutReachingThePage() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast()
        fake.send(state(position: 50))
        fake.send(state(position: 2, duration: 15, video: adVideo, title: "Advertiser", ad: true))
        let before = fake.commands.count
        await player.seek(100); #expect(player.refusal == .advertisement)
        await player.next(); await player.previous()
        #expect(fake.commands.count == before, "no seek/next/previous command was sent during the ad")
        #expect(player.snapshot.title == "Synthetic Song" && player.snapshot.isAd)
        await player.pause()
        #expect(fake.bodies.last == WebMusicScripts.pause, "pausing an ad is still allowed")
        fake.send(state(position: 51))
        await player.seek(100)
        #expect(fake.bodies.last == WebMusicScripts.seek && fake.commands.last?.arguments["seconds"] as? Double == 100)
        fake.replies = [.ad]
        await player.seek(120)
        #expect(player.refusal == .advertisement, "the page's own ad check is honoured too")
    }
    @Test func previousRestartsAfterThreeSecondsOtherwiseGoesBack() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast()
        fake.send(state(position: 30))
        await player.previous()
        #expect(fake.bodies.last == WebMusicScripts.seek && fake.commands.last?.arguments["seconds"] as? Double == 0)
        fake.send(state(position: 1))
        await player.previous()
        #expect(fake.bodies.last == WebMusicScripts.skip && fake.commands.last?.arguments["forward"] as? Bool == false)
    }
    @Test func aStartedButPausedPageGetsExactlyOneNativePlay() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast()
        fake.send(state(playing: false)); fake.send(state(playing: false))
        await settle { fake.commands.count == 1 }
        #expect(fake.bodies == [WebMusicScripts.play])
        fake.send(state(playing: true)); fake.send(state(playing: false))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fake.commands.count == 1, "once a load has played, YouTube's own pause is never overridden")
    }
    @Test func cookieRotationWritesBackOnlyTheNamesThatChangedInThePlayerStore() async throws {
        let cookies = FakeCookieSource()
        let (player, page) = makePlayer(cookies: cookies)
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page())
        // TH1: the debounce is a real 20 ms timer followed by a hop to the cookie actor. Under a loaded whole-package run the fixed 60/150 ms waits
        // sometimes ended before that write arrived. Every wait for a write now ends when the write arrives (bounded at 10 s, which only a real
        // failure reaches). The waits for an ABSENCE of a write stay short sleeps: they can only make a failing run look clean, never fail a good one,
        // and each of them is closed by the exact-list assertion that follows a later write (writes are recorded in order).
        let quiet = Duration.milliseconds(120)   // six debounce periods
        player.pageCookiesChanged(fake.installed)
        try await Task.sleep(for: quiet)
        #expect(await cookies.rotationCount() == 0, "the installed set is the baseline")
        // F5: the record may hold a newer SIDCC written by the signed coordinator. The
        // player's store still holds the installed SAPISID; only the names that changed
        // in THIS store (YSC here) may be written back, never the whole jar.
        let tracking = HTTPCookie(properties: [.name: "YSC", .value: "SYNTHETIC-YSC", .domain: ".youtube.com", .path: "/"])!
        player.pageCookiesChanged(fake.installed + [tracking])
        await settleAsync { await cookies.rotationCount() >= 1 }
        try await Task.sleep(for: quiet)
        #expect(await cookies.batches() == [["YSC"]], "unchanged installed cookies are never re-sent")
        let rotated = HTTPCookie(properties: [.name: "SIDCC", .value: "SYNTHETIC-ROTATED", .domain: ".youtube.com", .path: "/"])!
        player.pageCookiesChanged(fake.installed + [tracking, rotated])
        player.pageCookiesChanged(fake.installed + [tracking, rotated])
        await settleAsync { await cookies.rotationCount() >= 2 }
        try await Task.sleep(for: quiet)   // a second, undebounced write would arrive within this window
        #expect(await cookies.batches() == [["YSC"], ["SIDCC"]], "debounced to one write of just the rotated name")
        await player.teardown()
        player.pageCookiesChanged([rotated])
        try await Task.sleep(for: quiet)
        #expect(await cookies.rotationCount() == 2, "no write-back after teardown")
    }
    @Test func unreadableSessionFailsWithoutLoadingAnything() async throws {
        let (player, page) = makePlayer(cookies: FakeCookieSource(fail: true))
        await player.play(playlistID: "PLsynthetic", title: nil)
        #expect(player.snapshot.phase == .failed(.sessionUnavailable))
        await settle { page()?.tornDown == 1 }
        #expect(page()?.loads.isEmpty == true && page()?.tornDown == 1 && !player.hasPage)
    }
    @Test func processLossAndSignInRedirectDropThePageAndNeverAutoReload() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state())
        player.pageFailed(.playerStopped)
        await settle { fake.tornDown == 1 }
        #expect(player.snapshot.phase == .failed(.playerStopped) && fake.loads.count == 1 && !player.hasPage)
        fake.send(state())
        #expect(player.snapshot.phase == .failed(.playerStopped), "the lost document cannot publish")
        await player.resume()
        #expect(player.hasPage && page() !== fake, "only an explicit Play starts a new page")
    }
    @Test func teardownStopsThePageAndFencesEverything() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state())
        await player.teardown()
        #expect(fake.tornDown == 1 && player.isClosed && player.snapshot.phase == .idle && !player.hasPage)
        fake.send(state())
        #expect(player.snapshot.phase == .idle)
        await player.play(playlistID: "PLsynthetic", title: nil)
        #expect(fake.loads.count == 1 && player.snapshot.phase == .idle, "a closed player cannot be restarted")
    }
}

@Suite struct NowPlayingMappingTests {
    @Test func publishesMetadataAndFreezesTheClockDuringAds() {
        var item = NowPlayingItem(title: "Synthetic Song", artist: "Synthetic Artist", album: nil, artwork: nil, duration: 200, elapsed: 42, playing: true, advertisement: false)
        var info = NowPlayingMapping.info(item)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Synthetic Song" && info[MPMediaItemPropertyArtist] as? String == "Synthetic Artist")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 200 && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(NowPlayingMapping.enabled(item).contains("seek"))
        item.advertisement = true
        info = NowPlayingMapping.info(item)
        // W23: the honest Ad state. The system is not shown the song the ad interrupts (its title, artist, picture or clock), and no title is invented.
        #expect(info[MPMediaItemPropertyTitle] as? String == NowPlayingMapping.advertisementTitle && info[MPMediaItemPropertyArtist] == nil)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0 && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil && info[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(!NowPlayingMapping.enabled(item).contains("seek"))
        #expect(NowPlayingMapping.enabled(nil).isEmpty && NowPlayingMapping.state(nil) == .stopped)
        #expect(NowPlayingMapping.status(.refused) == .commandFailed && NowPlayingMapping.status(.noActionableItem) == .noActionableNowPlayingItem)
    }
}

// MARK: Single owner integration (account barriers, permits, remote commands)

private func musicIdentity() throws -> (LocalIdentity, RequestContext) {
    let id = UUID()
    let context = try AccountContext(accountID: id, channelID: ID("UCsyntheticPlayer"), region: "US")
    let account = try Account(id: id, serviceIdentity: ServiceID("UCsyntheticPlayer"), context: context, displayName: "Synthetic Listener", credential: try CredentialReference("synthetic-ref"))
    return (LocalIdentity(account: account, state: .connected), RequestContext(account: context, accountGeneration: 4, requestGeneration: 0))
}
@MainActor final class PageLog { var pages: [FakeMusicPage] = [] }

@Suite @MainActor struct WebMusicAuthorityTests {
    private func authority(_ log: PageLog) -> AppPlaybackAuthority {
        AppPlaybackAuthority(makeMusicPage: { delegate in let page = FakeMusicPage(delegate: delegate); log.pages.append(page); return page })
    }
    @Test func restoreIsSilentAndAccountBarriersTearThePlayerDown() async throws {
        let log = PageLog(), owner = authority(log), cookies = FakeCookieSource()
        await owner.configureMusic { _ in cookies }
        let (identity, context) = try musicIdentity()
        try await owner.restorePaused(identity, context: context)
        let available = await owner.musicAvailable(), existing = await owner.currentMusic(), reads = await cookies.readCount()
        #expect(available && existing == nil, "restore creates nothing")
        #expect(log.pages.isEmpty && reads == 0)
        let model = PlaybackModel(authority: owner)
        await model.playMusic(playlistID: "PLsynthetic", title: "Synthetic Mix", request: owner.requestOwnedStart())
        let page = try #require(log.pages.first)
        #expect(page.loads.count == 1 && model.music != nil)
        try await owner.detach(previous: context, barrier: RequestContext(account: nil, accountGeneration: 5, requestGeneration: 0))
        let stillAvailable = await owner.musicAvailable()
        #expect(page.tornDown == 1 && !stillAvailable)
        #expect(model.music == nil && !model.nowPlaying.isActive,
                "the teardown notification releases the player and Now Playing without any polling (F11)")
    }
    @Test func aPermitCapturedBeforeABarrierCannotStartPlayback() async throws {
        let log = PageLog(), owner = authority(log)
        await owner.configureMusic { _ in FakeCookieSource() }
        let (identity, context) = try musicIdentity()
        try await owner.restorePaused(identity, context: context)
        let early = owner.requestOwnedStart()
        try await owner.detach(previous: context, barrier: RequestContext(account: nil, accountGeneration: 5, requestGeneration: 0))
        try await owner.restorePaused(identity, context: RequestContext(account: context.account, accountGeneration: 6, requestGeneration: 0))
        await #expect(throws: DomainError.staleContext) { try await owner.youtubeMusic(request: early) }
        #expect(log.pages.isEmpty)
        try await owner.removeLocal(identity.id, context: context)
        await #expect(throws: DomainError.staleContext) { try await owner.youtubeMusic(request: owner.requestOwnedStart()) }
    }
    @Test func quitStopsTheHiddenPlayer() async throws {
        let log = PageLog(), owner = authority(log)
        await owner.configureMusic { _ in FakeCookieSource() }
        let (identity, context) = try musicIdentity()
        try await owner.restorePaused(identity, context: context)
        let player = try await owner.youtubeMusic(request: owner.requestOwnedStart())
        await player.play(playlistID: "PLsynthetic", title: nil)
        await owner.quit()
        #expect(log.pages.first?.tornDown == 1 && player.isClosed)
    }
    @Test func remoteCommandsUseTheSamePlayerAndRefuseSeekDuringAds() async throws {
        let log = PageLog(), owner = authority(log)
        await owner.configureMusic { _ in FakeCookieSource() }
        let (identity, context) = try musicIdentity()
        try await owner.restorePaused(identity, context: context)
        let model = PlaybackModel(authority: owner)
        #expect(model.remote(.toggle) == .noActionableItem, "nothing playing: no actionable item")
        await model.playMusic(playlistID: "PLsynthetic", title: "Synthetic Mix", request: owner.requestOwnedStart())
        let page = try #require(log.pages.first); page.commitLast()
        page.send(state(position: 30))
        #expect(model.remote(.seek(60)) == .success)
        await settle { page.bodies.last == WebMusicScripts.seek }
        page.send(state(position: 2, duration: 15, video: adVideo, ad: true))
        #expect(model.remote(.seek(60)) == .refused && model.remote(.next) == .refused && model.remote(.previous) == .refused)
        #expect(model.remote(.pause) == .success)
        await settle { page.bodies.last == WebMusicScripts.pause }
        #expect(page.bodies.last == WebMusicScripts.pause)
        await owner.quit()
    }
}

// MARK: Rework 1 — permanent forms of the critic's probes (F1–F9, F11, F12)

@Suite @MainActor struct WebMusicReworkTests {
    // F1: a pre-roll longer than the load timeout neither fails nor reloads the load.
    @Test func prerollAdLongerThanTheTimeoutKeepsTheFirstLoadAlive() async throws {
        let (player, page) = makePlayer(timeout: .milliseconds(40))
        await player.play(playlistID: "PLsynthetic", title: "Mix")
        let fake = try #require(page()); fake.commitLast()
        for _ in 0..<6 {
            fake.send(state(position: 3, duration: 30, video: adVideo, title: "Advertiser", ad: true))
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!player.snapshot.isFailed && player.snapshot.isAd && fake.loads.count == 1, "150 ms of ad against a 40 ms timeout")
        #expect(!fake.bodies.contains(WebMusicScripts.pause) && fake.tornDown == 0, "nothing interferes with the ad")
        fake.send(state(position: 1))
        #expect(player.snapshot.phase == .playing && !player.snapshot.isAd && player.snapshot.title == "Synthetic Song")
        try await Task.sleep(for: .milliseconds(80))
        #expect(!player.snapshot.isFailed, "the confirmed load is no longer timed")
    }
    @Test func prerollAdOnTheRouterPathNeverReloadsThePageMidAd() async throws {
        let (player, page) = makePlayer(timeout: .milliseconds(40))
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state())
        fake.replies = [.router]
        await player.play(playlistID: "PLsecond", title: nil)
        for _ in 0..<6 {
            fake.send(state(load: 2, position: 3, duration: 30, video: adVideo, title: "Advertiser", ad: true))
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(fake.loads.count == 1 && !player.snapshot.isFailed, "no full-load fallback while the ad plays")
        fake.send(state(load: 2, video: otherVideo, title: "Second first track", playlist: "PLsecond"))
        #expect(player.snapshot.title == "Second first track" && player.snapshot.phase == .playing)
    }
    // F2: the outgoing track relabelled under the new load does not confirm it.
    @Test func routerLoadIsNotConfirmedByTheOutgoingTrackAndFallsBack() async throws {
        let (player, page) = makePlayer(timeout: .milliseconds(40))
        await player.play(playlistID: "PLsynthetic", title: "First")
        let fake = try #require(page()); fake.commitLast()
        fake.nowPlaying = state(title: "Outgoing song", playlist: "PLsynthetic")
        fake.send(fake.nowPlaying!)
        fake.replies = [.router]
        await player.play(playlistID: "PLsecond", title: "Second")
        await settle { player.rejected.isEmpty && fake.commands.count == 1 }
        try await Task.sleep(for: .milliseconds(10))
        #expect(player.snapshot.playlistTitle == "Second" && player.snapshot.title == nil && player.snapshot.phase == .loading,
                "the outgoing title never publishes under the new playlist")
        fake.send(state(load: 2, video: otherVideo, title: "Still the old playlist", playlist: "PLsynthetic"))
        #expect(player.snapshot.title == nil, "a different video from the OLD playlist is not evidence either")
        await settle { fake.loads.count == 2 }
        #expect(fake.loads.last?.query == "list=PLsecond&ytmuse_doc=2&ytmuse_load=2&ytmuse_play=1", "the full-load fallback fires")
    }
    @Test func routerLoadConfirmsOnTheRequestedPlaylistEvenWhenItStartsWithTheCurrentSong() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state())
        fake.replies = [.router]
        await player.play(playlistID: "PLsecond", title: nil)
        fake.send(state(load: 2, title: "Same song, new playlist", playlist: "PLsecond"))
        #expect(player.snapshot.title == "Same song, new playlist" && player.snapshot.phase == .playing)
    }
    @Test func withoutAPlaylistIDOnlyADifferentVideoConfirmsARouterLoad() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsynthetic", title: nil); _ = transport.reserveDocument()
        transport.apply(try WebMusicBridge.validate(state(), frame: music, document: 1, load: 1).get())
        _ = transport.begin(playlistID: "PLsecond", title: nil); transport.expectRouter()
        transport.apply(try WebMusicBridge.validate(state(load: 2), frame: music, document: 1, load: 2).get())
        #expect(!transport.confirmed && transport.snapshot.title == nil)
        transport.apply(try WebMusicBridge.validate(state(load: 2, video: otherVideo, title: "New"), frame: music, document: 1, load: 2).get())
        #expect(transport.confirmed && transport.snapshot.title == "New")
    }
    // F3: any terminal failure stops the page, so the transport never shows a failure over audio.
    @Test func terminalFailureDropsThePageSoNothingKeepsPlaying() async throws {
        let (player, page) = makePlayer(timeout: .milliseconds(30))
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast()
        await settle { player.snapshot.isFailed }
        #expect(player.snapshot.phase == .failed(.timedOut))
        await settle { fake.tornDown == 1 }
        #expect(fake.tornDown == 1 && !player.hasPage, "the timed-out page is stopped, not left audible")
        await player.playPause()
        #expect(player.hasPage && page() !== fake, "Play after a failure is an explicit new start")
    }
    @Test func aPerTrackPlayerErrorKeepsTrackingYouTubesQueue() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state())
        fake.send(["type": "error", "doc": 1, "load": 1, "code": 150])
        #expect(player.snapshot.notice == .notPlayable(code: 150) && player.snapshot.intent && player.hasPage)
        fake.send(state(video: otherVideo, title: "YouTube moved on"))
        #expect(player.snapshot.title == "YouTube moved on" && player.snapshot.notice == nil)
        await player.playPause()
        #expect(fake.bodies.last == WebMusicScripts.pause, "the transport button pauses what is playing; it never restarts the playlist")
    }
    // F4: Kaset's ad-pod continuity, natively.
    @Test func adStateHoldsWhileTheAdCreativeIsStillBoundAfterSignalsClear() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsynthetic", title: nil); _ = transport.reserveDocument()
        func send(_ body: [String: Any]) throws { transport.apply(try WebMusicBridge.validate(body, frame: music, document: 1, load: 1).get()) }
        try send(state(position: 40, content: syntheticVideo))
        try send(state(position: 2, duration: 15, video: adVideo, title: "Advertiser", ad: true, content: syntheticVideo))
        try send(state(position: 3, duration: 15, video: adVideo, title: "Advertiser", ad: false, content: syntheticVideo))
        #expect(transport.snapshot.isAd && transport.snapshot.title == "Synthetic Song" && transport.snapshot.videoID == syntheticVideo,
                "between creatives the signal clears but the ad video is still bound")
        #expect(transport.admitSeek(10) == .failure(.advertisement))
        if case .failure(.advertisement) = transport.admitSkip() {} else { Issue.record("skip admitted during the ad gap") }
        let ended = transport.apply(try WebMusicBridge.validate(["type": "ended", "doc": 1, "load": 1, "videoId": adVideo], frame: music, document: 1, load: 1).get())
        #expect(!ended && transport.snapshot.phase != .ended, "an ad creative ending is not a track ending")
        try send(state(position: 41, content: syntheticVideo))
        #expect(!transport.snapshot.isAd && transport.snapshot.position == 41)
    }
    @Test func adContinuityIsInThePageScriptsToo() {
        #expect(WebMusicScripts.observer.contains("awaitingContent") && WebMusicScripts.seek.contains("awaitingContent") && WebMusicScripts.skip.contains("awaitingContent"))
    }
    // F6: a document native code did not reserve stops visibly (kills mutant M3).
    @Test func anUnreservedCommitStopsPlaybackVisibly() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state())
        #expect(player.snapshot.phase == .playing)
        player.pageCommitted(document: nil)
        #expect(player.snapshot.phase == .failed(.pageReplaced))
        await settle { fake.tornDown == 1 }
        #expect(fake.tornDown == 1 && !player.hasPage)
        fake.send(state(position: 99))
        #expect(player.snapshot.phase == .failed(.pageReplaced), "the reloaded document cannot publish")
    }
    @Test func aLateCommitOfAnOlderReservedDocumentIsIgnoredNotFatal() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page())
        fake.replies = [.fallback]
        await player.play(playlistID: "PLsecond", title: nil)
        player.pageCommitted(document: 1)
        fake.send(state(doc: 1, load: 2))
        #expect(player.snapshot.phase == .loading && !player.snapshot.isFailed)
        fake.commitLast(); fake.send(state(doc: 2, load: 2))
        #expect(player.snapshot.phase == .playing)
    }
    @Test func navigationTrackingKeepsTheGenerationAcrossRedirectsOnly() {
        let ours = WebMusicNavigation.playlistURL("PLsynthetic", document: 4, load: 1)
        let redirect = URL(string: "https://music.youtube.com/watch?v=SYNTHvid001&list=PLsynthetic")
        #expect(WebKitMusicPage.track(ours, pending: nil, provisional: false) == 4)
        #expect(WebKitMusicPage.track(redirect, pending: 4, provisional: true) == 4, "a server redirect of our navigation keeps its generation")
        #expect(WebKitMusicPage.track(redirect, pending: nil, provisional: false) == nil, "a page-initiated navigation has none")
        #expect(WebMusicScripts.bootstrap.contains("history.replaceState") && WebMusicScripts.bootstrap.contains("params.delete(\"ytmuse_play\")"),
                "the play intent cannot survive a page reload")
    }
    // F7: long CJK/emoji titles are truncated, not rejected.
    @Test func longCJKTitlesAreTruncatedOnACharacterBoundary() throws {
        let title = String(repeating: "音楽", count: 125) + "🎵"
        let message = try WebMusicBridge.validate(state(title: title), frame: music, document: 1, load: 1).get()
        guard case .state(let sample) = message.event, let shown = sample.title else { Issue.record("rejected"); return }
        #expect(shown.utf8.count <= 512 && shown.hasSuffix("…") && shown.hasPrefix("音楽音楽"))
        #expect(WebMusicBridge.truncated("short", bytes: 512) == "short")
    }
    // F8: the user's volume reaches a fresh page once it plays; untouched volume is never sent.
    @Test func userVolumeIsReappliedToAFreshPage() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let first = try #require(page()); first.commitLast(); first.send(state())
        #expect(!first.bodies.contains(WebMusicScripts.volume), "the app never changes volume by itself")
        await player.setVolume(0.3)
        player.pageFailed(.playerStopped)
        await settle { first.tornDown == 1 }
        await player.resume()
        let second = try #require(page()); #expect(second !== first)
        second.commitLast(); second.send(state(doc: second.lastDocument, load: 2))
        await settle { second.bodies.contains(WebMusicScripts.volume) }
        #expect(second.commands.last(where: { $0.body == WebMusicScripts.volume })?.arguments["level"] as? Double == 0.3)
    }
    // F9: a page that is no longer signed in fails as "sign in again", never plays as a guest.
    @Test func aSignedOutPageAsksToSignInAgain() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast()
        fake.send(state(signedIn: true))
        #expect(player.snapshot.phase == .playing)
        fake.send(state(signedIn: false))
        #expect(player.snapshot.phase == .failed(.signInRequired))
        await settle { fake.tornDown == 1 }
        #expect(fake.tornDown == 1)
        var wrong = state(); wrong["signedIn"] = "no"
        #expect(WebMusicBridge.validate(wrong, frame: music, document: 1, load: 1) == .failure(.malformed))
        #expect(WebMusicScripts.observer.contains("ytcfg.get(\"LOGGED_IN\")"))
    }
    // F11: Now Playing is rewritten only for changes a listener can see.
    @Test func nowPlayingSkipsSamplesTheSystemAlreadyExtrapolates() {
        let base = NowPlayingItem(title: "Song", artist: "Artist", album: nil, artwork: nil, duration: 200, elapsed: 10, playing: true, advertisement: false)
        var next = base; next.elapsed = 10.5
        #expect(!NowPlayingMapping.needsUpdate(from: base, elapsedSince: .milliseconds(500), to: next))
        next.elapsed = 60
        #expect(NowPlayingMapping.needsUpdate(from: base, elapsedSince: .milliseconds(500), to: next), "a seek is published")
        next = base; next.playing = false
        #expect(NowPlayingMapping.needsUpdate(from: base, elapsedSince: .zero, to: next))
        next = base; next.advertisement = true
        #expect(NowPlayingMapping.needsUpdate(from: base, elapsedSince: .zero, to: next))
    }
    // F12: artwork is decoded within bounded dimensions.
    @Test func artworkIsDownsampledAndOversizedHeadersAreRefused() throws {
        func png(_ width: Int, _ height: Int) throws -> Data {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: 0.7, green: 0.1, blue: 0.2, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(context.makeImage())
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil); _ = CGImageDestinationFinalize(destination)
            return data as Data
        }
        let small = try #require(WebMusicArtworkLoader.downsampled(try png(1200, 600)))
        let source = try #require(CGImageSourceCreateWithData(small as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 512 && properties[kCGImagePropertyPixelHeight] as? Int == 256)
        #expect(WebMusicArtworkLoader.downsampled(try png(5000, 8)) == nil, "header dimensions above 4096 are refused before decoding")
        #expect(WebMusicArtworkLoader.downsampled(Data("not an image".utf8)) == nil)
    }

    // N1: an ad flag on the content's own video ID never latches the content as an ad.
    @Test func firstPlayWithAnAdFlagOnTheContentsOwnIDConfirmsWhenContentShows() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsynthetic", title: nil); _ = transport.reserveDocument()
        func send(_ body: [String: Any]) throws { transport.apply(try WebMusicBridge.validate(body, frame: music, document: 1, load: 1).get()) }
        // Server-stitched pre-roll: the ad segment reports the content's own ID.
        try send(state(position: 1, duration: 200, ad: true, content: syntheticVideo))
        #expect(transport.snapshot.isAd && !transport.confirmed)
        try send(state(position: 2, content: syntheticVideo))
        #expect(!transport.snapshot.isAd && transport.confirmed && transport.snapshot.title == "Synthetic Song", "content confirms; no latch")
        #expect(transport.admitSeek(30) == .success(30))
        if case .success = transport.admitSkip() {} else { Issue.record("skip refused on content") }
    }
    @Test func anAdFlagOnTheNextTracksOwnIDDoesNotMakeTheWholeTrackAnAd() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsynthetic", title: nil); _ = transport.reserveDocument()
        func send(_ body: [String: Any]) throws { transport.apply(try WebMusicBridge.validate(body, frame: music, document: 1, load: 1).get()) }
        try send(state(position: 190, content: syntheticVideo))
        // Track B starts; one sample still carries a lingering ad flag on B's own ID.
        try send(state(position: 0, video: otherVideo, title: "Track B", ad: true, content: otherVideo))
        try send(state(position: 1, video: otherVideo, title: "Track B", content: otherVideo))
        #expect(!transport.snapshot.isAd && transport.snapshot.videoID == otherVideo && transport.snapshot.title == "Track B")
        #expect(transport.admitSeek(10) == .success(10))
        let ended = transport.apply(try WebMusicBridge.validate(["type": "ended", "doc": 1, "load": 1, "videoId": otherVideo], frame: music, document: 1, load: 1).get())
        #expect(ended && transport.snapshot.phase == .ended, "B's own end is a track end")
    }
    @Test func controlAnOrdinaryPodStillHoldsUntilContentReturnsThenClears() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsynthetic", title: nil); _ = transport.reserveDocument()
        func send(_ body: [String: Any]) throws { transport.apply(try WebMusicBridge.validate(body, frame: music, document: 1, load: 1).get()) }
        try send(state(position: 20, content: syntheticVideo))
        try send(state(position: 1, duration: 15, video: adVideo, ad: true, content: syntheticVideo))
        try send(state(position: 2, duration: 15, video: "SYNTHadv002", ad: true, content: syntheticVideo))
        try send(state(position: 0, duration: 15, video: "SYNTHadv002", ad: false, content: syntheticVideo))
        #expect(transport.snapshot.isAd, "between creatives the pod still holds")
        try send(state(position: 21, content: syntheticVideo))
        #expect(!transport.snapshot.isAd && transport.snapshot.position == 21)
    }
    @Test func withoutAContentReferenceOnlyThePagesOwnAdDecisionCounts() throws {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: "PLsynthetic", title: nil); _ = transport.reserveDocument()
        func send(_ body: [String: Any]) throws { transport.apply(try WebMusicBridge.validate(body, frame: music, document: 1, load: 1).get()) }
        try send(state(position: 1, video: adVideo, ad: true))
        try send(state(position: 2, video: adVideo, ad: false))
        #expect(!transport.snapshot.isAd, "nothing is recorded natively without the page's content reference")
    }
    @Test func firstPlayThroughAStitchedAdIsSeekableOnceContentShows() async throws {
        let (player, page) = makePlayer(timeout: .milliseconds(40))
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast()
        for _ in 0..<4 { fake.send(state(position: 1, ad: true, content: syntheticVideo)); try await Task.sleep(for: .milliseconds(25)) }
        fake.send(state(position: 5, content: syntheticVideo))
        try await Task.sleep(for: .milliseconds(80))
        #expect(player.snapshot.phase == .playing && !player.snapshot.isAd && player.snapshot.canSeek && !player.snapshot.isFailed)
        await player.seek(50)
        #expect(fake.bodies.last == WebMusicScripts.seek)
    }
    // N3: a cancelled native navigation never lends its generation to the next one.
    @Test func aCancelledNativeNavigationDoesNotLendItsGenerationToAPageNavigation() throws {
        let ours = try #require(WebMusicNavigation.playlistURL("PLsynthetic", document: 7, load: 1))
        let pageInitiated = URL(string: "https://music.youtube.com/")
        var tracker = WebMusicNavigationTracker()
        tracker.policy(ours); tracker.provisionalEnded()
        tracker.policy(pageInitiated)
        #expect(tracker.commit() == nil, "the page-initiated document is unreserved")
        tracker.policy(ours); tracker.policy(URL(string: "https://music.youtube.com/watch?v=SYNTHvid001"))
        #expect(tracker.commit() == 7, "a redirect of our own navigation keeps its generation")
        #expect(tracker == WebMusicNavigationTracker(), "commit resets the tracker")
    }

    // Follow-up 2 (first live Play): PL1/PL2.
    @Test func thePlayerPresentsSafarisApplicationNameDerivedFromTheOS() {
        #expect(WebKitMusicPage.safariApplicationName(osMajor: 27) == "Version/27.0 Safari/605.1.15")
        #expect(WebKitMusicPage.safariApplicationName(osMajor: 28) == "Version/28.0 Safari/605.1.15")
        #expect(WebKitMusicPage.safariApplicationName(osMajor: 14) == "Version/26.0 Safari/605.1.15", "never below the first OS-aligned Safari")
    }
    @Test func anUnsupportedBrowserOrNonAppPageFailsAtOnceAndDropsThePage() async throws {
        #expect(try WebMusicBridge.validate(["type": "page", "doc": 1, "load": 1, "app": false, "unsupported": true], frame: music, document: 1, load: 1).get().event
                == .page(app: false, unsupportedBrowser: true))
        #expect(WebMusicBridge.validate(["type": "page", "doc": 1, "load": 1, "app": "no", "unsupported": true], frame: music, document: 1, load: 1) == .failure(.malformed))
        for (body, expected) in [(["app": false, "unsupported": true], WebMusicFailure.unsupportedBrowser), (["app": false, "unsupported": false], .notMusicApp)] {
            let (player, page) = makePlayer()
            await player.play(playlistID: "PLsynthetic", title: nil)
            let fake = try #require(page()); fake.commitLast()
            fake.send(["type": "page", "doc": 1, "load": 1].merging(body) { $1 })
            #expect(player.snapshot.phase == .failed(expected))
            await settle { fake.tornDown == 1 }
            #expect(fake.tornDown == 1 && !player.hasPage)
        }
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast()
        fake.send(["type": "page", "doc": 1, "load": 1, "app": true, "unsupported": false])
        #expect(player.snapshot.phase == .loading && player.hasPage, "the app page is accepted")
        #expect(WebMusicScripts.observer.contains("ytmusic-app") && WebMusicScripts.observer.contains("not optimi[sz]ed for your browser"))
    }
    @Test func appNapActivityIsHeldOnlyWhilePlayIsIntended() async throws {
        let (player, page) = makePlayer()
        #expect(!player.holdsPlaybackActivity)
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state())
        #expect(player.holdsPlaybackActivity)
        await player.pause()
        #expect(!player.holdsPlaybackActivity, "a paused player lets the app nap")
        await player.resume()
        #expect(player.holdsPlaybackActivity)
        await player.teardown()
        #expect(!player.holdsPlaybackActivity)
    }

    // C1: a cookie snapshot that arrives late is never written back over a newer one.
    @Test func olderCookieSnapshotsAreDroppedAfterANewerOneIsApplied() {
        var sequence = WebMusicSnapshotSequence()
        let first = sequence.begin(), second = sequence.begin(), third = sequence.begin()
        let outOfOrder = sequence.accept(second), older = sequence.accept(first), again = sequence.accept(second)
        let newest = sequence.accept(third), forged = sequence.accept(99)
        #expect(outOfOrder, "replies may arrive out of order")
        #expect(!older, "an older reply after a newer one is dropped")
        #expect(!again, "the same reply twice is dropped")
        #expect(newest)
        #expect(!forged, "a number never issued is refused")
    }
}

// MARK: W09 integration — the shared W09 transport is driven by this one owner

@Suite @MainActor struct W09ConvergedTransportTests {
    /// Owned audio here opens W14's protected records: an isolated keychain file and a temporary directory only.
    private func authority(_ log: PageLog) throws -> AppPlaybackAuthority {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w09-converged-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = try KeychainVault(testNamespace: KeychainVault.applicationNamespace + ".test.w09-converged-" + UUID().uuidString, isolatedKeychainURL: root.appendingPathComponent("isolated.keychain-db"))
        return AppPlaybackAuthority(directory: root, offlineVault: vault,
            makeMusicPage: { delegate in let page = FakeMusicPage(delegate: delegate); log.pages.append(page); return page })
    }
    @Test func sharedTitleFollowsTheHiddenPlayerAndOwnedStartReleasesIt() async throws {
        let log = PageLog(), owner = try authority(log)
        await owner.configureMusic { _ in FakeCookieSource() }
        let (identity, context) = try musicIdentity()
        try await owner.restorePaused(identity, context: context)
        let model = PlaybackModel(authority: owner, controlledAudioTest: true)
        #expect(model.currentTitle == "Nothing playing" && model.music == nil, "nothing is created at restore")
        await model.playMusic(playlistID: "PLsynthetic", title: "Synthetic Mix", request: owner.requestOwnedStart())
        let page = try #require(log.pages.first); page.commitLast()
        page.send(state(position: 30))
        await settle { model.music?.snapshot.title == "Synthetic Song" }
        #expect(model.currentTitle == "Synthetic Song", "Now Playing and the shared bar read the hidden player's item")
        #expect(model.session == nil && model.state == nil && model.timeline.snapshot == nil, "owned presentation is cleared for the web source")
        // Owned test audio replaces the hidden player through the same single owner.
        await model.startOwned(request: owner.requestOwnedStart())
        #expect(page.tornDown == 1 && model.music == nil, "starting owned audio tears the hidden player down and releases it")
        #expect(model.session != nil)
        await owner.quit()
    }
    @Test func aWebStartWithoutARestoredIdentityIsRefusedSilently() async throws {
        let owner = try authority(PageLog())
        let model = PlaybackModel(authority: owner, controlledAudioTest: true)
        // No restored music identity: the owner refuses; a stale context stays silent.
        await model.playMusic(playlistID: "PLsynthetic", title: "Synthetic Mix", request: owner.requestOwnedStart())
        #expect(model.error == nil && model.music == nil)
        await owner.quit()
    }
}

// MARK: W09 integration rework 1 — main's userSeekable guard on the converged owned timeline

@Suite struct W09OwnedTimelineSeekGuardTests {
    private func media(seekable: Bool) -> NativeMediaInfo {
        NativeMediaInfo(userSeekable: seekable, duration: 60, codec: "pcm", sampleRate: 48_000, bitrate: nil, route: "Synthetic route")
    }
    @Test func aRetainedItemThatIsNotUserSeekableOffersNoTimeline() {
        #expect(!PlaybackTimeline.seekEnabled(hasCurrent: true, media: media(seekable: false)), "W14: a non-seekable variant must not offer a slider that then fails")
        #expect(PlaybackTimeline.seekEnabled(hasCurrent: true, media: media(seekable: true)))
        #expect(!PlaybackTimeline.seekEnabled(hasCurrent: false, media: media(seekable: true)))
        #expect(!PlaybackTimeline.seekEnabled(hasCurrent: true, media: nil))
    }
}

// MARK: C1 — the bar's clock is isolated (PERF08/WIN10), the hidden page's power (P1 P5-1/2/3)

@Suite @MainActor struct WebMusicTimelineIsolationTests {
    private func playing() async throws -> (WebMusicPlayer, FakeMusicPage) {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: "Synthetic Mix")
        let fake = try #require(page()); fake.commitLast(); fake.send(state(position: 0))
        return (player, fake)
    }
    /// Whether `action` invalidates an observation of `read`: exactly the condition under which
    /// a SwiftUI body reading the same properties would be re-evaluated. Arming and the
    /// mutation are synchronous, so nothing can be missed between them.
    private final class Flag: @unchecked Sendable { var fired = false }
    private func invalidates(_ read: @escaping @MainActor () -> Void, during action: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking({ MainActor.assumeIsolated { read() } }, onChange: { flag.fired = true })
        action()
        return flag.fired
    }
    @Test func positionTicksInvalidateTheClockOnceASecondAndNeverTheCoarseSnapshot() async throws {
        let (player, fake) = try await playing()
        var coarse = 0, clock = 0
        // Forty position reports a quarter second apart: ten displayed seconds.
        for tick in 1...40 {
            let report = state(position: Double(tick) * 0.25)
            let clockFired = invalidates({ _ = player.timeline.position }, during: {
                if invalidates({ _ = player.snapshot }, during: { fake.send(report) }) { coarse += 1 }
            })
            if clockFired { clock += 1 }
        }
        #expect(coarse == 0, "reading the snapshot is never invalidated by the clock (\(coarse) invalidations)")
        #expect(clock == 10, "the clock republishes once per displayed second, not per report (\(clock))")
        #expect(player.timeline.position == 10)
        // A change that is not the clock does invalidate the coarse snapshot.
        let titled = invalidates({ _ = player.snapshot }, during: { fake.send(state(position: 10.5, video: otherVideo, title: "Another Song")) })
        #expect(titled, "a new track invalidates the coarse snapshot")
    }
    @Test func theWholeBarReadsNoPositionFromTheCoarseSnapshot() async throws {
        let (player, fake) = try await playing()
        fake.send(state(position: 42.5))
        #expect(player.snapshot.position == 0, "the coarse snapshot carries no clock")
        #expect(player.timeline.position == 42.5, "the clock is read from the timeline")
    }
    @Test func nowPlayingStillReceivesEveryPositionReport() async throws {
        let (player, fake) = try await playing()
        var seen: [Double] = []
        player.onChange = { snapshot, _ in seen.append(snapshot.position) }
        for tick in 1...8 { fake.send(state(position: Double(tick) * 0.25)); await Task.yield() }
        // (The artwork fetch also republishes once, so a value may repeat; none may be missing.)
        #expect(Set(seen) == [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2] && seen == seen.sorted() && seen.last == 2, "the Now Playing path keeps full-resolution positions: \(seen)")
    }
    @Test func theClockStopsWhileNoWindowIsVisibleAndCatchesUpWhenShown() async throws {
        let (player, fake) = try await playing()
        player.timeline.setObserving(false)
        var fired = 0
        for tick in 1...20 {
            if invalidates({ _ = player.timeline.position }, during: { fake.send(state(position: Double(tick))) }) { fired += 1 }
        }
        #expect(fired == 0 && player.timeline.position == 0 && player.timeline.publications == 0, "a hidden window publishes nothing (\(fired))")
        let shown = invalidates({ _ = player.timeline.position }, during: { player.timeline.setObserving(true) })
        #expect(shown && player.timeline.position == 20, "shown again, the latest position appears in one publication")
        let again = invalidates({ _ = player.timeline.position }, during: { player.timeline.setObserving(true) })
        #expect(!again, "re-asserting visibility publishes nothing new")
    }
    @Test func coalescingRuleShowsSecondChangesAndJumpsOnly() {
        #expect(!WebMusicTimeline.shouldPublish(from: 3.0, to: 3.75))
        #expect(WebMusicTimeline.shouldPublish(from: 3.75, to: 4.0))
        #expect(WebMusicTimeline.shouldPublish(from: 10.9, to: 9.9), "a seek back to an earlier displayed second shows")
        #expect(WebMusicTimeline.shouldPublish(from: 3.0, to: 4.5))
        #expect(!WebMusicTimeline.shouldPublish(from: 3.9, to: 3.1))
    }
    @Test func theModelLeasesTheClockToWindowVisibility() async throws {
        let log = PageLog()
        let owner = AppPlaybackAuthority(makeMusicPage: { delegate in let page = FakeMusicPage(delegate: delegate); log.pages.append(page); return page })
        await owner.configureMusic { _ in FakeCookieSource() }
        let (identity, context) = try musicIdentity()
        try await owner.restorePaused(identity, context: context)
        let model = PlaybackModel(authority: owner, controlledAudioTest: true)
        let window = UUID()
        model.observe(window, visible: true)
        await model.playMusic(playlistID: "PLsynthetic", title: "Synthetic Mix", request: owner.requestOwnedStart())
        let player = try #require(model.music)
        #expect(player.timeline.observing, "a visible window observes the clock")
        model.observe(window, visible: false)
        #expect(!player.timeline.observing, "a hidden window stops it")
        model.observe(window, visible: true)
        #expect(player.timeline.observing)
        model.observe(window, visible: false)
        await owner.quit()
    }
}

@Suite @MainActor struct WebMusicHiddenPagePowerTests {
    private func started() async throws -> (WebMusicPlayer, FakeMusicPage, () -> FakeMusicPage?) {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: "Synthetic Mix")
        let fake = try #require(page()); fake.commitLast()
        return (player, fake, page)
    }
    @Test func theActivityIsHeldOnlyWhileLoadingBufferingOrPlaying() async throws {
        let (player, fake, _) = try await started()
        #expect(player.snapshot.phase == .loading && player.holdsPlaybackActivity, "loading counts")
        fake.send(state(playing: false, buffering: true))
        #expect(player.snapshot.phase == .buffering && player.holdsPlaybackActivity, "buffering counts")
        fake.send(state())
        #expect(player.snapshot.phase == .playing && player.holdsPlaybackActivity)
        // YouTube pauses itself (a continue-listening prompt): intent is still true, nothing plays.
        fake.send(state(playing: false))
        #expect(player.snapshot.phase == .paused && player.snapshot.intent)
        #expect(!player.holdsPlaybackActivity, "P5-2: a paused page lets the app nap although Play is still intended")
        fake.send(state())
        #expect(player.holdsPlaybackActivity)
        // After the playlist ends.
        fake.send(["type": "ended", "doc": 1, "load": 1, "videoId": syntheticVideo])
        #expect(player.snapshot.phase == .ended && !player.holdsPlaybackActivity, "an ended playlist holds nothing")
        fake.send(state(position: 5, video: otherVideo))
        #expect(player.holdsPlaybackActivity)
        // An advertisement counts as playing.
        fake.send(state(position: 3, duration: 15, video: adVideo, ad: true))
        #expect(player.snapshot.isAd && player.holdsPlaybackActivity)
        await player.teardown()
        #expect(!player.holdsPlaybackActivity)
    }
    @Test func theHiddenPageIsThrottledWhileNothingPlaysAndFreeBeforeAnythingCanPlay() async throws {
        let (player, fake, _) = try await started()
        #expect(fake.throttleLog.isEmpty, "a loading page is never throttled")
        fake.send(state())
        #expect(fake.throttleLog.isEmpty, "a playing page is never throttled")
        fake.send(state(position: 61))
        // The user pauses: the page confirms it paused.
        await player.pause()
        #expect(fake.throttleLog.isEmpty, "the pause command itself is sent to a free page; throttling waits for the page to say it paused")
        fake.send(state(playing: false, position: 61))
        #expect(player.snapshot.phase == .paused && fake.throttleLog == [true], "P5-1: paused → throttled")
        fake.send(state(playing: false, position: 61))
        #expect(fake.throttleLog == [true], "the policy is set on a change, not on every report")
        // Play: the policy is lifted BEFORE the play command reaches the page, and the page keeps its place.
        await player.resume()
        let events = fake.events
        let lift = try #require(events.lastIndex(of: "unthrottle")), play = try #require(events.lastIndex(of: "run"))
        #expect(lift < play && fake.throttleLog == [true, false], "unthrottled first, then play: \(events.suffix(4))")
        #expect(fake.bodies.last == WebMusicScripts.play)
        #expect(fake.tornDown == 0 && player.hasPage && fake.loads.count == 1, "the page, its track and its position are kept (no reload)")
        fake.send(state(position: 61))
        #expect(player.snapshot.phase == .playing && player.timeline.position == 61, "playback continues at the same position")
    }
    @Test func everyCommandThatCouldPlayLiftsThePolicyFirstAndOnlyPauseDoesNot() async throws {
        for (name, command) in [("next", { (p: WebMusicPlayer) in await p.next() }), ("previous", { (p: WebMusicPlayer) in await p.previous() }),
                                ("seek", { (p: WebMusicPlayer) in await p.seek(30) }), ("volume", { (p: WebMusicPlayer) in await p.setVolume(0.5) })] {
            let (player, fake, _) = try await started()
            fake.send(state(playing: false, position: 70))
            #expect(fake.throttleLog == [true], "\(name): throttled while paused")
            await command(player)
            #expect(fake.throttleLog == [true, false], "\(name): lifted before the command")
            let events = fake.events
            #expect(try #require(events.lastIndex(of: "unthrottle")) < (try #require(events.lastIndex(of: "run"))), "\(name): ordering")
            await player.teardown()
        }
        let (player, fake, _) = try await started()
        fake.send(state(playing: false)); await player.pause()
        #expect(fake.throttleLog == [true], "a pause command leaves a throttled page throttled")
        await player.teardown()
    }
    @Test func aPageYouTubePausedByItselfIsThrottledEvenThoughPlayIsStillIntended() async throws {
        let (player, fake, _) = try await started()
        fake.send(state())
        fake.send(state(playing: false))   // continue-listening prompt: intent stays true
        #expect(player.snapshot.intent && fake.throttleLog == [true])
        fake.send(["type": "ended", "doc": 1, "load": 1, "videoId": syntheticVideo])
        #expect(player.snapshot.phase == .ended && fake.throttleLog == [true], "an ended playlist stays throttled")
        fake.send(state(position: 3, duration: 15, video: adVideo, ad: true))
        #expect(player.snapshot.isAd && fake.throttleLog == [true, false], "an advertisement plays: never throttled")
        await player.teardown()
        #expect(!player.holdsPlaybackActivity)
    }
    @Test func anAdvertisementIsNeverThrottledEvenWhilePaused() async throws {
        let (player, fake, _) = try await started()
        fake.send(state()); await player.pause()
        fake.send(state(playing: false, position: 3, duration: 15, video: adVideo, ad: true))
        #expect(player.snapshot.isAd && player.snapshot.phase == .paused && fake.throttleLog.isEmpty, "a paused ad stays on a free page: \(fake.throttleLog)")
        await player.teardown()
    }
    @Test func theThrottleStateStartsFreshOnANewPage() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let first = try #require(page()); first.commitLast(); first.send(state(playing: false))
        #expect(first.throttleLog == [true])
        first.send(["type": "page", "doc": 1, "load": 1, "app": false, "unsupported": false])   // not the app: the page is dropped
        await settle { first.tornDown == 1 }
        await player.play(playlistID: "PLother", title: nil)
        let second = try #require(page()); #expect(second !== first && second.throttleLog.isEmpty, "a fresh page is not throttled")
        second.commitLast(); second.send(state(doc: second.lastDocument, load: 2, playing: false))
        #expect(second.throttleLog == [true], "and is throttled again when it pauses")
        await player.teardown()
    }
}

/// Runs the real observer script in JavaScriptCore against a stub page, so the power and
/// banner rules are exercised on the script that ships, not on a copy of its logic.
@MainActor private final class ObserverHarness {
    let context = JSContext()!
    init(app: Bool, text: String, video: Bool) {
        context.exceptionHandler = { _, exception in Issue.record("script exception: \(exception?.toString() ?? "?")") }
        context.evaluateScript("""
        var __clock = 1000, __posted = [], __intervals = [], __timeouts = [], __listeners = {};
        var __app = \(app), __text = \(JSONLiteral.string(text));
        var __video = \(video) ? { paused: true, ended: false, readyState: 4, currentTime: 10, duration: 200,
          addEventListener: function (name, fn) { (__listeners[name] = __listeners[name] || []).push(fn); } } : null;
        var Date = { now: function () { return __clock; } };
        var setTimeout = function (fn, ms) { __timeouts.push(fn); };
        var setInterval = function (fn, ms) { __intervals.push(fn); };
        var document = {
          querySelector: function (selector) { return selector === "video" ? __video : (selector === "ytmusic-app" && __app ? {} : null); },
          getElementById: function () { return null; }, body: { innerText: __text }, addEventListener: function () {}
        };
        var window = { location: { hostname: "music.youtube.com", href: "https://music.youtube.com/watch?v=SYNTHvid001" },
          __ytmuseState: { doc: 1, load: 1, intent: true, meta: null, observing: false },
          webkit: { messageHandlers: { \(WebMusicBridge.handlerName): { postMessage: function (m) { __posted.push(JSON.stringify(m)); } } } } };
        window.top = window;
        """)
        context.evaluateScript(WebMusicScripts.observer)
    }
    func posts(_ type: String) -> [[String: Any]] {
        let raw = context.evaluateScript("__posted")!.toArray() as? [String] ?? []
        return raw.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }.filter { $0["type"] as? String == type }
    }
    /// One second of wall clock, then every interval callback (the page's own timer).
    func tick(seconds: Int = 1) { context.evaluateScript("__clock += \(seconds * 1000); __intervals.forEach(function (fn) { fn(); });") }
    func runTimeouts() { context.evaluateScript("__timeouts.slice().forEach(function (fn) { fn(); });") }
    func fire(_ event: String) { context.evaluateScript("(__listeners[\"\(event)\"] || []).forEach(function (fn) { fn(); });") }
    func setPosition(_ value: Double) { context.evaluateScript("__video.currentTime = \(value);") }
}
private enum JSONLiteral {
    static func string(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value]); let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }
}

@Suite @MainActor struct WebMusicObserverScriptTests {
    private let banner = "Your browser is not optimized for your browser. Try Google Chrome."
    @Test func aPresentAppElementWinsOverAnUnsupportedBanner() {
        let harness = ObserverHarness(app: true, text: banner, video: false)
        harness.runTimeouts()
        let pages = harness.posts("page")
        #expect(pages.count == 1)
        #expect(pages.first?["app"] as? Bool == true && pages.first?["unsupported"] as? Bool == false, "P5-3: the app wins: \(pages)")
    }
    @Test func aDocumentWithoutTheAppAndWithTheBannerIsUnsupported() {
        let harness = ObserverHarness(app: false, text: banner, video: false)
        let pages = harness.posts("page")
        #expect(pages.first?["app"] as? Bool == false && pages.first?["unsupported"] as? Bool == true)
    }
    @Test func aPausedPageStaysSilentAndOnlyChangesAndEventsPost() {
        let harness = ObserverHarness(app: true, text: "", video: true)
        #expect(harness.posts("state").count == 1, "binding the video reports once")
        for _ in 1...10 { harness.tick() }
        #expect(harness.posts("state").count == 1, "P5-1: ten idle seconds of a paused page post nothing: \(harness.posts("state").count)")
        harness.setPosition(11)
        harness.tick()
        #expect(harness.posts("state").count == 2, "a changed position posts")
        harness.tick()
        #expect(harness.posts("state").count == 2, "and an unchanged one does not")
        harness.fire("pause")
        #expect(harness.posts("state").count == 3, "a media event always posts, even when nothing differs")
    }
}

// MARK: C1 — Queue and Now Playing while YouTube Music plays (W09 review finding 6)

@Suite @MainActor struct WebMusicQueueSummaryTests {
    @Test func theQueueSurfaceShowsTheCurrentItemAndOnlyTheUpcomingItemsThePageListed() async throws {
        let (player, page) = makePlayer()
        #expect(!WebMusicQueueSummary.isActive(player), "nothing is shown before Play")
        await player.play(playlistID: "PLsynthetic", title: "Synthetic Mix")
        let fake = try #require(page()); fake.commitLast()
        #expect(WebMusicQueueSummary.isActive(player))
        let loading = WebMusicQueueSummary(player.snapshot)
        #expect(loading.title == "Synthetic Mix" && loading.playlist == "Synthetic Mix" && loading.artist == nil, "before the first sample only the known playlist is named")
        #expect(!loading.isListed && loading.upcoming.isEmpty, "no list before the page lists one")
        fake.send(state())
        let playing = WebMusicQueueSummary(player.snapshot)
        #expect(playing == WebMusicQueueSummary(player.snapshot))
        #expect(playing.title == "Synthetic Song" && playing.artist == "Synthetic Artist" && playing.playlist == "Synthetic Mix" && !playing.isAd)
        #expect(!playing.isListed && playing.upcoming.isEmpty, "a page that reports no queue yields no list: nothing is invented")
        fake.send(queueBody(playing: syntheticVideo, upcoming: [(otherVideo, "Second Song", "Second Artist")]))
        let listed = WebMusicQueueSummary(player.snapshot)
        #expect(listed.isListed && listed.upcoming.map(\.videoID) == [otherVideo] && listed.upcoming.first?.title == "Second Song" && !listed.hasMore)
        fake.send(state(position: 3, duration: 15, video: adVideo, title: "Advertiser", ad: true))
        let advert = WebMusicQueueSummary(player.snapshot)
        #expect(advert.isAd && advert.title == "Synthetic Song", "the ad state is shown, with the content's own text kept")
        #expect(advert.upcoming.map(\.videoID) == [otherVideo], "the list the page gave before the ad stays")
        #expect(WebMusicQueueSummary.managedByYouTubeMusic.contains("YouTube Music manages the upcoming items"))
        #expect(!WebMusicQueueSummary.managedByYouTubeMusic.contains("not listed"), "the text no longer says the items are not listed")
        await player.teardown()
        #expect(!WebMusicQueueSummary.isActive(player), "a closed player is not described")
    }
}

// MARK: W11 rework 1 — the service's own play endpoint (a shuffle's parameters, a track in a collection)

@Suite struct WebMusicTargetCommandTests {
    @Test func theTargetCommandIsAConstantBodyWithTypedArgumentsAndRefusesHostileValues() throws {
        let shuffle = try WebMusicCommand.loadTarget("OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c", videoID: nil, params: "wAEB8gECKAE%3D", load: 4).invocation()
        #expect(shuffle.body == WebMusicScripts.loadTarget)
        #expect(!shuffle.body.contains("OLAK5uy") && !shuffle.body.contains("wAEB8gECKAE"), "values reach the page only as arguments")
        #expect(shuffle.arguments["playlistId"] as? String == "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c")
        #expect(shuffle.arguments["params"] as? String == "wAEB8gECKAE%3D" && shuffle.arguments["videoId"] as? String == "" && shuffle.arguments["load"] as? Int == 4)
        let track = try WebMusicCommand.loadTarget("PLsynthetic", videoID: "IluRBvnYMoY", params: nil, load: 5).invocation()
        #expect(track.arguments["videoId"] as? String == "IluRBvnYMoY" && track.arguments["params"] as? String == "")
        for params in ["bad params", "x');alert(1)//", "", String(repeating: "a", count: 1025)] {
            #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.loadTarget("PLsynthetic", videoID: nil, params: params, load: 1).invocation() }
        }
        #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.loadTarget("PLsynthetic", videoID: "short", params: nil, load: 1).invocation() }
        #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.loadTarget("bad id", videoID: nil, params: nil, load: 1).invocation() }
        #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.loadTarget("PLsynthetic", videoID: nil, params: nil, load: 0).invocation() }
    }
    @Test func theTargetScriptHandsTheRouterTheServicesEndpointAndContainsNothingForbidden() {
        let body = WebMusicScripts.loadTarget
        #expect(body.contains("watchPlaylistEndpoint") && body.contains("watchEndpoint") && body.contains("resolveCommand"))
        for forbidden in ["skipAd", "playbackRate", "muted = true", "evaluateJavaScript", "document.cookie", "eval("] { #expect(!body.contains(forbidden)) }
    }
    @Test func aFreshDocumentUrlStartsAtTheTrackAndStaysYouTubeMusic() throws {
        let url = try #require(WebMusicNavigation.playlistURL("PLsynthetic", videoID: "IluRBvnYMoY", document: 3, load: 9))
        #expect(url.query == "v=IluRBvnYMoY&list=PLsynthetic&ytmuse_doc=3&ytmuse_load=9&ytmuse_play=1" && WebMusicNavigation.allowsMainFrame(url))
        #expect(WebMusicNavigation.playlistURL("PLsynthetic", videoID: "no", document: 3, load: 9) == nil)
        #expect(WebMusicNavigation.playlistURL("PLsynthetic", document: 3, load: 9)?.query == "list=PLsynthetic&ytmuse_doc=3&ytmuse_load=9&ytmuse_play=1")
    }
}

// R2 round-two regression SOURCE: accepted routing and target evidence are
// separate requirements. These cases deliberately keep the outgoing playlist.
@Suite struct WebMusicEndpointEvidenceTests {
    private let playlist = "RDpublished"
    private let oldVideo = "aaaaaaaaaa1"
    private let newVideo = "aaaaaaaaaa2"
    private func send(_ body: [String: Any], to transport: inout WebMusicTransport) throws {
        transport.apply(try WebMusicBridge.validate(body, frame: music, document: transport.document, load: transport.load).get())
    }
    private func playing() throws -> WebMusicTransport {
        var transport = WebMusicTransport()
        _ = transport.begin(playlistID: playlist, title: nil)
        _ = transport.reserveDocument()
        try send(state(video: oldVideo, playlist: playlist, shuffle: false), to: &transport)
        try send(queueBody(playing: oldVideo, upcoming: [("aaaaaaaaaa3", "Old next", "Artist")]), to: &transport)
        #expect(transport.confirmed && transport.snapshot.queue?.upcoming.count == 1)
        return transport
    }
    @Test func fallbackEvidenceIsDiscardedWhenRoutingIsLaterAccepted() throws {
        var transport = try playing()
        let load = transport.begin(playlistID: playlist, title: nil)
        transport.expectEndpoint()
        // Even target/queue evidence tagged with the new load before acceptance
        // must be discarded, rather than latched for a later router reply.
        try send(state(load: 2, video: oldVideo, playlist: playlist, shuffle: false), to: &transport)
        try send(queueBody(playing: oldVideo, upcoming: [(newVideo, "Changed before acceptance", "Artist")], load: 2), to: &transport)
        #expect(!transport.confirmed)
        transport.acceptEndpoint(load: load)
        #expect(!transport.confirmed)
        try send(state(load: 2, video: oldVideo, playlist: playlist, shuffle: false), to: &transport)
        #expect(!transport.confirmed && transport.snapshot.phase == .loading)
    }
    @Test func immediateRouterAcceptanceWithUnchangedOutgoingPlaybackIsUnconfirmed() throws {
        var transport = try playing()
        let load = transport.begin(playlistID: playlist, title: nil)
        transport.expectEndpoint(); transport.acceptEndpoint(load: load)
        try send(queueBody(playing: oldVideo, upcoming: [("aaaaaaaaaa3", "Metadata changed", "Other artist")], load: 2), to: &transport)
        try send(state(load: 2, video: oldVideo, playlist: playlist, shuffle: false), to: &transport)
        #expect(!transport.confirmed && transport.snapshot.phase == .loading)
    }
    @Test func suppliedSeedVideoCannotBeConfirmedByOldVideoEvenWithAChangedQueue() throws {
        var transport = try playing()
        let load = transport.begin(playlistID: playlist, title: nil)
        transport.expectEndpoint(videoID: newVideo); transport.acceptEndpoint(load: load)
        try send(queueBody(playing: oldVideo, upcoming: [(newVideo, "New next", "Artist")], load: 2), to: &transport)
        try send(state(load: 2, video: oldVideo, playlist: playlist, shuffle: false), to: &transport)
        #expect(!transport.confirmed)
        try send(state(load: 2, video: newVideo, playlist: playlist, shuffle: false), to: &transport)
        #expect(transport.confirmed && transport.snapshot.videoID == newVideo && transport.snapshot.shuffle == false)
    }
    @Test func samePlaylistQueueTransitionConfirmsWithShuffleOffInEitherMessageOrder() throws {
        for queueFirst in [false, true] {
            var transport = try playing()
            let load = transport.begin(playlistID: playlist, title: nil)
            transport.expectEndpoint(); transport.acceptEndpoint(load: load)
            let sample = state(load: 2, video: oldVideo, playlist: playlist, shuffle: false)
            let queue = queueBody(playing: oldVideo, upcoming: [(newVideo, "New next", "Artist")], load: 2)
            try send(queueFirst ? queue : sample, to: &transport)
            #expect(!transport.confirmed, "both content and queue evidence are needed")
            try send(queueFirst ? sample : queue, to: &transport)
            #expect(transport.confirmed && transport.snapshot.phase == .playing && transport.snapshot.shuffle == false)
            #expect(transport.snapshot.queue?.upcoming.map(\.videoID) == [newVideo])
        }
    }
    @Test func aClearedQueueCannotProveAChange() throws {
        var transport = try playing()
        let load = transport.begin(playlistID: playlist, title: nil)
        transport.expectEndpoint(); transport.acceptEndpoint(load: load)
        try send(queueBody(playing: nil, load: 2), to: &transport)
        try send(state(load: 2, video: oldVideo, playlist: playlist, shuffle: false), to: &transport)
        #expect(!transport.confirmed)
    }
}

@Suite @MainActor struct WebMusicTargetPlayerTests {
    private let shuffle = "wAEB8gECKAE%3D"
    private func neverInOrder(_ fake: FakeMusicPage) -> Bool {
        fake.loads.allSatisfy { $0.query?.contains("list=") != true && $0.query?.contains("ytmuse_play=1") != true }
    }

    @Test func unchangedEndpointTimesOutAfterFallbackOrImmediateAcceptance() async throws {
        for delayedRouter in [false, true] {
            let (player, page) = makePlayer(timeout: .milliseconds(80))
            await player.play(playlistID: "RDpublished")
            let fake = try #require(page()); fake.commitLast()
            fake.send(state(video: "aaaaaaaaaa1", playlist: "RDpublished", shuffle: false))
            fake.routerAvailable = !delayedRouter
            let play = Task { await player.play(playlistID: "RDpublished", params: "opaqueFilter", intent: .endpoint) }
            await settle { fake.targetAttempts >= 1 }
            fake.send(state(load: 2, video: "aaaaaaaaaa1", playlist: "RDpublished", shuffle: false))
            if delayedRouter {
                #expect(player.snapshot.phase == .loading)
                fake.routerAvailable = true
                await settle { fake.targetAttempts >= 2 }
                // No target report follows the later router acknowledgement.
            }
            await play.value
            #expect(player.snapshot.phase == .failed(.timedOut))
            #expect(fake.loads.count == 1, "no plain playlist fallback")
        }
    }
    @Test func opaqueRadioParametersConfirmWithShuffleOff() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic")
        let fake = try #require(page()); fake.commitLast(); fake.send(state(playlist: "PLsynthetic"))
        let play = Task { await player.play(playlistID: "RDpublished", title: "Radio", params: "opaqueFilter", intent: .endpoint) }
        await settle { fake.targetAttempts >= 1 }
        #expect(fake.commands.last?.arguments["params"] as? String == "opaqueFilter")
        fake.send(state(load: 2, video: "aaaaaaaaaa2", playlist: "RDpublished", shuffle: false))
        await play.value
        #expect(player.snapshot.phase == .playing && player.snapshot.shuffle == false)
        #expect(fake.loads.count == 1)
    }
    @Test func aLiveDocumentGetsTheShuffleEndpointThroughItsRouterAndConfirmsOnlyWhenTheShuffleShowsInThePage() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state(playlist: "PLsynthetic"))
        let play = Task { await player.play(playlistID: "OLAK5uy_album", title: "Album", params: shuffle, intent: .shuffle) }
        await settle { fake.commands.contains { $0.body == WebMusicScripts.loadTarget } }
        let command = try #require(fake.commands.last)
        #expect(command.body == WebMusicScripts.loadTarget && command.arguments["params"] as? String == shuffle && command.arguments["load"] as? Int == 2)
        #expect(fake.loads.count == 1, "the router handled it; no new document")
        // The page plays the album in order (shuffle off): that is not the shuffle, and does not confirm it.
        fake.send(state(load: 2, video: "aaaaaaaaaa1", playlist: "OLAK5uy_album", shuffle: false))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(!player.snapshot.isFailed && player.snapshot.phase == .loading, "playing in order is not a shuffle")
        fake.send(state(load: 2, video: "aaaaaaaaaa2", playlist: "OLAK5uy_album", shuffle: true))
        await play.value
        #expect(player.snapshot.phase == .playing && player.snapshot.playlistID == "OLAK5uy_album")
    }
    @Test func aFreshPageNeverPlaysInOrderAndRoutesTheShuffleOnlyOnceTheRouterExists() async throws {
        let (player, page) = makePlayer(router: false, routerAppearsAtAttempt: 4)
        let play = Task { await player.play(playlistID: "OLAK5uy_album", title: "Album", params: shuffle, intent: .shuffle) }
        await settle { page() != nil && !(page()?.loads.isEmpty ?? true) }
        let fake = try #require(page())
        #expect(fake.loads.count == 1 && neverInOrder(fake), "the first document is neutral: no playlist, no play intent (\(fake.loads))")
        #expect(fake.loads.first?.query == "ytmuse_doc=1&ytmuse_load=1")
        #expect(fake.commands.isEmpty, "nothing is sent before the document has committed")
        fake.commitLast()
        await settle { fake.targetAttempts >= 4 }
        // The router was absent at commit and for three attempts ("fallback"); each was retried, none counted as done.
        #expect(fake.targetAttempts >= 4 && fake.commands.allSatisfy { $0.body == WebMusicScripts.loadTarget })
        #expect(fake.commands.allSatisfy { $0.arguments["params"] as? String == shuffle })
        #expect(player.snapshot.phase == .loading, "nothing counts as started before the page shows the shuffle")
        // A page that starts the playlist by itself, in order, is still not the shuffle.
        fake.send(state(video: "aaaaaaaaaa1", playlist: "OLAK5uy_album", shuffle: false))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(player.snapshot.phase == .loading && !player.snapshot.isFailed)
        fake.send(state(video: "aaaaaaaaaa3", playlist: "OLAK5uy_album", shuffle: true))
        await play.value
        #expect(player.snapshot.phase == .playing && neverInOrder(fake) && fake.loads.count == 1)
    }
    @Test func aPageThatNeverGetsARouterFailsVisiblyAndNothingIsStartedInOrder() async throws {
        let (player, page) = makePlayer(shuffleAttempts: 5, router: false)
        let play = Task { await player.play(playlistID: "OLAK5uy_album", title: "Album", params: shuffle, intent: .shuffle) }
        await settle { page() != nil && !(page()?.loads.isEmpty ?? true) }
        let fake = try #require(page()); fake.commitLast()
        await play.value
        #expect(player.snapshot.phase == .failed(.shuffleFailed), "\(player.snapshot.phase)")
        #expect((1...5).contains(fake.targetAttempts), "retried within the bound (5 tries, the first ones before the document committed) and no more")
        #expect(neverInOrder(fake) && fake.loads.count == 1)
    }
    @Test func onlyTheRoutersOwnAcceptanceCountsAsRouted() async throws {
        for reply in [WebMusicCommandReply.ok, .unavailable, .fallback, .rejected] {
            let (player, page) = makePlayer(shuffleAttempts: 3, targetReply: reply)
            let play = Task { await player.play(playlistID: "OLAK5uy_album", title: nil, params: shuffle, intent: .shuffle) }
            await settle { page() != nil && !(page()?.loads.isEmpty ?? true) }
            page()?.commitLast()
            await play.value
            #expect(player.snapshot.phase == .failed(.shuffleFailed), "\(reply)")
            #expect(page().map(neverInOrder) == true)
        }
    }
    @Test func aRoutedShuffleThatNeverShowsItselfFailsAtTheTimeoutInsteadOfLoadingInOrder() async throws {
        let (player, page) = makePlayer(timeout: .milliseconds(80))
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state(playlist: "PLsynthetic"))
        await player.play(playlistID: "OLAK5uy_album", title: "Album", params: shuffle, intent: .shuffle)
        #expect(player.snapshot.phase == .failed(.shuffleFailed), "the fallback that reloads the playlist is not used for a shuffle")
        #expect(fake.loads.count == 1 && fake.loads.allSatisfy { $0.query?.contains("OLAK5uy_album") != true }, "no full load of the album, with or without the parameters")
    }
    @Test func shufflingThePlaylistThatIsAlreadyPlayingNeedsTheShuffleToShowOn() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "OLAK5uy_album", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state(playlist: "OLAK5uy_album", shuffle: false))
        let play = Task { await player.play(playlistID: "OLAK5uy_album", title: nil, params: shuffle, intent: .shuffle) }
        await settle { fake.targetAttempts >= 1 }
        fake.send(state(load: 2, playlist: "OLAK5uy_album"))          // the old playback, not saying anything about shuffle
        try? await Task.sleep(for: .milliseconds(40))
        #expect(player.snapshot.phase == .loading, "the same playlist playing in order must not confirm its own re-shuffle")
        fake.send(state(load: 2, video: "aaaaaaaaaa4", playlist: "OLAK5uy_album", shuffle: true))
        await play.value
        #expect(player.snapshot.phase == .playing)
    }
    @Test func aPlainPlayNeverSendsTheTargetCommand() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(state())
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!fake.bodies.contains(WebMusicScripts.loadTarget))
    }
    @Test func aTrackInACollectionStartsThePlaylistFromThatTrackOnBothPaths() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "OLAK5uy_album", title: nil, videoID: "IluRBvnYMoY")
        let fake = try #require(page())
        #expect(fake.loads.last?.query == "v=IluRBvnYMoY&list=OLAK5uy_album&ytmuse_doc=1&ytmuse_load=1&ytmuse_play=1")
        fake.commitLast(); fake.send(state())
        fake.replies = [.router]
        await player.play(playlistID: "OLAK5uy_album", title: nil, videoID: "ZbbTmR6Xaag")
        #expect(fake.commands.last?.arguments["videoId"] as? String == "ZbbTmR6Xaag")
    }
    @Test func invalidParametersAreRefusedBeforeAnythingIsCreated() async {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil, params: "bad params")
        #expect(page() == nil && player.refusal == .invalidTarget)
        await player.play(playlistID: "PLsynthetic", title: nil, videoID: "short")
        #expect(page() == nil && player.refusal == .invalidTarget)
    }
}

// The fixed script itself, run in JavaScriptCore against a stub page, so what the router is handed is observed rather than assumed.
@Suite struct WebMusicTargetScriptTests {
    private func run(playlist: String, video: String, params: String) throws -> (reply: String, command: String?) {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, _ in }
        context.evaluateScript("""
        var captured = null;
        var window = { __ytmuseState: { doc: 1, load: 0, intent: false } };
        var document = { querySelector: function (s) { return s === "ytmusic-app" ? { resolveCommand: function (c) { captured = JSON.stringify(c); } } : null; } };
        function f(playlistId, videoId, params, load) { \(WebMusicScripts.loadTarget) }
        """)
        let reply = context.objectForKeyedSubscript("f").call(withArguments: [playlist, video, params, 3])?.toString() ?? ""
        return (reply, context.objectForKeyedSubscript("captured")?.toString().flatMap { $0 == "null" ? nil : $0 })
    }
    @Test func aShuffleIsAWatchPlaylistEndpointWithTheServicesParameters() throws {
        let result = try run(playlist: "OLAK5uy_album", video: "", params: "wAEB8gECKAE%3D")
        #expect(result.reply == "router")
        let command = try #require(result.command?.data(using: .utf8).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: [String: String]] })
        #expect(command["watchPlaylistEndpoint"] == ["playlistId": "OLAK5uy_album", "params": "wAEB8gECKAE%3D"])
    }
    @Test func aTrackInACollectionIsAWatchEndpointWithTheVideo() throws {
        let command = try #require(try run(playlist: "OLAK5uy_album", video: "IluRBvnYMoY", params: "").command?.data(using: .utf8).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: [String: String]] })
        #expect(command["watchEndpoint"] == ["playlistId": "OLAK5uy_album", "videoId": "IluRBvnYMoY"])
    }
    @Test func withoutARouterTheScriptFallsBackAndSendsNothing() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var window = { __ytmuseState: { doc: 1 } }; var document = { querySelector: function () { return null; } }; function f(playlistId, videoId, params, load) { \(WebMusicScripts.loadTarget) }")
        #expect(context.objectForKeyedSubscript("f").call(withArguments: ["PLx", "", "p", 1])?.toString() == "fallback")
        #expect(context.evaluateScript("window.__ytmuseState.load === undefined && window.__ytmuseState.intent === undefined")?.toBool() == true,
                "fallback never stamps outgoing reports as the new endpoint")
    }
}

// MARK: CORE-A — the page's own queue (read only), and the player bar's shuffle and repeat

/// A well-formed `queue` message: the playing item first (marked), then the upcoming items, as the observer script posts it.
private func queueBody(playing: String?, upcoming: [(String, String, String)] = [], more: Int = 0, doc: Int = 1, load: Int = 1) -> [String: Any] {
    var items: [[String: Any]] = []
    if let playing { items.append(["i": playing, "t": "Playing now", "c": true]) }
    for entry in upcoming { items.append(["i": entry.0, "t": entry.1, "a": entry.2, "u": "https://lh3.googleusercontent.com/\(entry.0)"]) }
    let text = String(decoding: try! JSONSerialization.data(withJSONObject: items), as: UTF8.self)
    return ["type": "queue", "doc": doc, "load": load, "videoId": playing ?? "", "items": text, "more": more]
}
private func queueItemsText(_ items: [[String: Any]]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: items), as: UTF8.self) }

@Suite struct WebMusicQueueBridgeTests {
    private func validate(_ body: [String: Any]) -> Result<WebMusicMessage, WebMusicRejection> { WebMusicBridge.validate(body, frame: music, document: 1, load: 1) }
    private func queue(_ body: [String: Any]) throws -> WebMusicQueue {
        guard case .queue(let queue) = try validate(body).get().event else { throw WebMusicRejection.malformed }
        return queue
    }
    @Test func aQueueMessageCarriesTheUpcomingItemsInThePagesOrder() throws {
        let queue = try queue(queueBody(playing: syntheticVideo, upcoming: [(otherVideo, "Two", "Artist Two"), ("SYNTHvid003", "Three", "Artist Three")], more: 7))
        #expect(queue.videoID == syntheticVideo && queue.upcoming.map(\.videoID) == [otherVideo, "SYNTHvid003"] && queue.more == 7)
        #expect(queue.upcoming.map(\.title) == ["Two", "Three"] && queue.upcoming.map(\.artist) == ["Artist Two", "Artist Three"])
        #expect(queue.upcoming.first?.artworkURL?.host == "lh3.googleusercontent.com")
    }
    @Test func aVideoListedTwiceGetsTwoDistinctRowIdentities() throws {
        let queue = try queue(queueBody(playing: syntheticVideo, upcoming: [(otherVideo, "A", "x"), ("SYNTHvid003", "B", "y"), (otherVideo, "A again", "x")]))
        #expect(queue.upcoming.map(\.id) == ["\(otherVideo)#0", "SYNTHvid003#0", "\(otherVideo)#1"] && Set(queue.upcoming.map(\.id)).count == 3)
    }
    @Test func anEmptyListAndALoneCurrentItemAreBothValidAndMeanDifferentThings() throws {
        let unreadable = try queue(queueBody(playing: nil))
        #expect(unreadable.videoID == nil && unreadable.upcoming.isEmpty, "no video id: the page lists no queue the app can read")
        let last = try queue(queueBody(playing: syntheticVideo))
        #expect(last.videoID == syntheticVideo && last.upcoming.isEmpty, "the playing item alone: nothing follows it")
    }
    @Test func theListMustLeadWithTheMarkedPlayingItemAndMatchTheMessagesVideo() {
        var body = queueBody(playing: syntheticVideo, upcoming: [(otherVideo, "Two", "x")])
        body["videoId"] = otherVideo
        #expect(validate(body) == .failure(.malformed), "the list is not about the video the message names")
        let unmarked = ["type": "queue", "doc": 1, "load": 1, "videoId": syntheticVideo, "more": 0, "items": queueItemsText([["i": syntheticVideo], ["i": otherVideo]])] as [String: Any]
        #expect(validate(unmarked) == .failure(.malformed), "no item is marked as the playing one")
        let twoMarked = ["type": "queue", "doc": 1, "load": 1, "videoId": syntheticVideo, "more": 0, "items": queueItemsText([["i": syntheticVideo, "c": true], ["i": otherVideo, "c": true]])] as [String: Any]
        #expect(validate(twoMarked) == .failure(.malformed))
        let markedLater = ["type": "queue", "doc": 1, "load": 1, "videoId": syntheticVideo, "more": 0, "items": queueItemsText([["i": syntheticVideo], ["i": otherVideo, "c": true]])] as [String: Any]
        #expect(validate(markedLater) == .failure(.malformed))
    }
    @Test func malformedItemsAreRejectedNotRepaired() {
        func body(_ items: Any, videoId: String = syntheticVideo) -> [String: Any] {
            let text = (items as? String) ?? String(decoding: try! JSONSerialization.data(withJSONObject: items), as: UTF8.self)
            return ["type": "queue", "doc": 1, "load": 1, "videoId": videoId, "more": 0, "items": text]
        }
        #expect(validate(body("not json")) == .failure(.malformed))
        #expect(validate(body(["i": syntheticVideo, "c": true] as [String: Any])) == .failure(.malformed), "an object is not a list")
        #expect(validate(body([["i": syntheticVideo, "c": true, "cookie": "x"]])) == .failure(.malformed), "unknown item keys reject")
        #expect(validate(body([["i": "short", "c": true]], videoId: syntheticVideo)) == .failure(.malformed), "an item with a bad video id rejects")
        #expect(validate(body([["i": syntheticVideo, "c": true], ["i": "bad id!"]])) == .failure(.malformed))
        #expect(validate(body([["i": syntheticVideo, "c": 1]])) == .failure(.malformed), "the marker is a boolean")
        #expect(validate(body([["i": syntheticVideo, "c": true, "t": 5]])) == .failure(.malformed), "text is text")
        #expect(validate(body([["i": syntheticVideo, "c": true, "t": ["a"]]])) == .failure(.malformed))
        var wrongItems = body([["i": syntheticVideo, "c": true]]); wrongItems["items"] = 5
        #expect(validate(wrongItems) == .failure(.malformed))
        var wrongMore = body([["i": syntheticVideo, "c": true]]); wrongMore["more"] = -1
        #expect(validate(wrongMore) == .failure(.malformed))
        var unknownKey = body([["i": syntheticVideo, "c": true]]); unknownKey["extra"] = "x"
        #expect(validate(unknownKey) == .failure(.malformed))
    }
    @Test func theListIsBoundedAtThirtyOneItemsAndByBytes() throws {
        func many(_ count: Int) -> [String: Any] {
            var items: [[String: Any]] = [["i": syntheticVideo, "c": true]]
            for n in 1..<count { items.append(["i": String(format: "SYNTH%06d", n)]) }
            return ["type": "queue", "doc": 1, "load": 1, "videoId": syntheticVideo, "more": 0, "items": queueItemsText(items)]
        }
        #expect(try queue(many(31)).upcoming.count == 30)
        #expect(validate(many(32)) == .failure(.malformed), "beyond the window is malformed, not truncated")
        var huge = queueBody(playing: syntheticVideo); huge["items"] = String(repeating: "[", count: 40_001)
        #expect(validate(huge) == .failure(.oversized), "the queue bound is larger than a state's but still a bound")
        var big = queueBody(playing: syntheticVideo); big["items"] = String(repeating: " ", count: 36_001)
        #expect(validate(big) == .failure(.malformed))
        // The larger bound belongs to the queue message alone: a state message of the same size is still oversized.
        var heavy = state(); heavy["title"] = String(repeating: "a", count: 7000)
        #expect(validate(heavy) == .failure(.oversized))
    }
    @Test func titlesAreCleanedAndBoundedAndArtworkIsLimitedToYouTubeImageHosts() throws {
        let long = String(repeating: "x", count: 1400)
        let items: [[String: Any]] = [["i": syntheticVideo, "c": true], ["i": otherVideo, "t": "  Line\u{0}\u{7}One  ", "a": long, "u": "https://example.com/a.jpg"]]
        let queue = try queue(["type": "queue", "doc": 1, "load": 1, "videoId": syntheticVideo, "more": 0, "items": queueItemsText(items)])
        let item = try #require(queue.upcoming.first)
        #expect(item.title == "LineOne" && (item.artist?.utf8.count ?? 0) <= 512 && item.artworkURL == nil, "control characters go, long text is cut, a foreign host is dropped")
    }
    @Test func theStateMessageCarriesShuffleAndRepeatAndRejectsAnythingElse() throws {
        for (raw, mode) in [("off", WebMusicRepeatMode.off), ("all", .all), ("one", .one)] {
            var body = state(shuffle: true); body["repeat"] = raw
            guard case .state(let sample) = try validate(body).get().event else { Issue.record("not state"); return }
            #expect(sample.repeatMode == mode && sample.shuffle == true)
        }
        var bogus = state(); bogus["repeat"] = "NONE"
        #expect(validate(bogus) == .failure(.malformed), "only the three names the observer posts")
        var typed = state(); typed["repeat"] = 1
        #expect(validate(typed) == .failure(.malformed))
        guard case .state(let plain) = try validate(state()).get().event else { return }
        #expect(plain.repeatMode == nil, "a page that does not say leaves it unreported")
        #expect(WebMusicRepeatMode.off.next == .all && WebMusicRepeatMode.all.next == .one && WebMusicRepeatMode.one.next == .off, "the page's own button order")
    }
}

private func refusal(_ result: Result<Void, WebMusicRefusal>) -> WebMusicRefusal? { if case .failure(let reason) = result { reason } else { nil } }

@Suite struct WebMusicQueueTransportTests {
    private func playing(_ transport: inout WebMusicTransport) throws {
        _ = transport.begin(playlistID: "PLsynthetic", title: "Mix"); _ = transport.reserveDocument()
        transport.apply(try WebMusicBridge.validate(state(), frame: music, document: 1, load: 1).get())
    }
    private func apply(_ transport: inout WebMusicTransport, _ body: [String: Any]) throws {
        transport.apply(try WebMusicBridge.validate(body, frame: music, document: 1, load: 1).get())
    }
    @Test func aQueueForThePlayingItemIsShownAndAnotherItemsQueueIsHeldNotShown() throws {
        var transport = WebMusicTransport(); try playing(&transport)
        try apply(&transport, queueBody(playing: otherVideo, upcoming: [("SYNTHvid003", "Three", "x")]))
        #expect(transport.snapshot.queue == nil, "a list about another item is not this item's list")
        try apply(&transport, queueBody(playing: syntheticVideo, upcoming: [(otherVideo, "Two", "x")]))
        #expect(transport.snapshot.queue?.upcoming.map(\.videoID) == [otherVideo])
    }
    @Test func theNextItemDropsTheOldListAndTakesAHeldOneForItself() throws {
        var transport = WebMusicTransport(); try playing(&transport)
        try apply(&transport, queueBody(playing: syntheticVideo, upcoming: [(otherVideo, "Two", "x"), ("SYNTHvid003", "Three", "y")]))
        try apply(&transport, queueBody(playing: otherVideo, upcoming: [("SYNTHvid003", "Three", "y")]))   // arrives before the item shows
        #expect(transport.snapshot.queue?.upcoming.count == 2, "still the old item's list")
        try apply(&transport, state(video: otherVideo, title: "Two"))
        #expect(transport.snapshot.queue?.upcoming.map(\.videoID) == ["SYNTHvid003"], "the held list for the new item replaces the old one")
        try apply(&transport, state(video: "SYNTHvid003", title: "Three"))
        #expect(transport.snapshot.queue == nil, "a new item with no list reported yet shows none")
    }
    @Test func aListWithoutAVideoIdClearsWhatWasShown() throws {
        var transport = WebMusicTransport(); try playing(&transport)
        try apply(&transport, queueBody(playing: syntheticVideo, upcoming: [(otherVideo, "Two", "x")]))
        try apply(&transport, queueBody(playing: nil))
        #expect(transport.snapshot.queue == nil, "the page no longer lists a readable queue")
    }
    @Test func aNewLoadResetsTheList() throws {
        var transport = WebMusicTransport(); try playing(&transport)
        try apply(&transport, queueBody(playing: syntheticVideo, upcoming: [(otherVideo, "Two", "x")]))
        _ = transport.begin(playlistID: "PLother", title: nil)
        #expect(transport.snapshot.queue == nil && transport.snapshot.shuffle == nil && transport.snapshot.repeatMode == nil)
    }
    @Test func shuffleAndRepeatAreOnlyWhatTheLastReportSaid() throws {
        var transport = WebMusicTransport(); try playing(&transport)
        var body = state(shuffle: true); body["repeat"] = "all"
        try apply(&transport, body)
        #expect(transport.snapshot.shuffle == true && transport.snapshot.repeatMode == .all)
        try apply(&transport, state())
        #expect(transport.snapshot.shuffle == nil && transport.snapshot.repeatMode == nil, "a report that does not say clears them: a stale value would be a guess")
    }
    @Test func selectionShuffleAndRepeatAreRefusedDuringAnAdAndForAnItemNotListed() throws {
        var transport = WebMusicTransport(); try playing(&transport)
        try apply(&transport, queueBody(playing: syntheticVideo, upcoming: [(otherVideo, "Two", "x")]))
        if case .success = transport.admitQueueSelection(otherVideo) {} else { Issue.record("a listed item is admitted") }
        #expect(refusal(transport.admitQueueSelection("SYNTHvid009")) == .queueItemGone)
        if case .success = transport.admitQueueSetting() {} else { Issue.record("shuffle and repeat are admitted") }
        try apply(&transport, state(position: 3, duration: 15, video: adVideo, title: "Advertiser", ad: true))
        #expect(refusal(transport.admitQueueSelection(otherVideo)) == .queueAdvertisement)
        #expect(refusal(transport.admitQueueSetting()) == .queueAdvertisement)
        #expect(transport.snapshot.queue?.upcoming.map(\.videoID) == [otherVideo], "the ad leaves the list as it was")
    }
    @Test func nothingIsAdmittedWithoutAPlayingItem() {
        let transport = WebMusicTransport()
        #expect(refusal(transport.admitQueueSelection(otherVideo)) == .nothingLoaded)
        #expect(refusal(transport.admitQueueSetting()) == .nothingLoaded)
    }
}

@Suite @MainActor struct WebMusicQueuePlayerTests {
    private func started(shuffle: Bool? = false, mode: String? = "off") async throws -> (WebMusicPlayer, FakeMusicPage) {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: "Synthetic Mix")
        let fake = try #require(page()); fake.commitLast()
        var body = state(shuffle: shuffle)
        if let mode { body["repeat"] = mode }
        fake.send(body)
        fake.send(queueBody(playing: syntheticVideo, upcoming: [(otherVideo, "Two", "x"), ("SYNTHvid003", "Three", "y")]))
        return (player, fake)
    }
    private func commands(_ fake: FakeMusicPage, _ body: String) -> [WebMusicCommand.Invocation] { fake.commands.filter { $0.body == body } }
    @Test func playingAListedItemHandsThePageOnlyItsVideoIdAndTheOutputGateComesFirst() async throws {
        let (player, fake) = try await started()
        var gated = false
        player.audibleStartGate = { proceed in gated = true; await proceed() }
        await player.playQueueItem(otherVideo)
        let sent = commands(fake, WebMusicScripts.playQueueItem)
        #expect(gated && sent.count == 1 && sent.first?.arguments["videoId"] as? String == otherVideo && player.refusal == nil)
        #expect(player.snapshot.intent, "selecting an item is a request to play")
        await player.teardown()
    }
    @Test func anItemTheFakePageDoesNotListIsRefusedWithoutReachingThePage() async throws {
        let (player, fake) = try await started()
        await player.playQueueItem("SYNTHvid009")
        #expect(commands(fake, WebMusicScripts.playQueueItem).isEmpty && player.refusal == .queueItemGone)
        await player.teardown()
    }
    @Test func selectionShuffleAndRepeatNeverReachThePageDuringAnAd() async throws {
        let (player, fake) = try await started()
        fake.send(state(position: 3, duration: 15, video: adVideo, title: "Advertiser", ad: true))
        await player.playQueueItem(otherVideo)
        #expect(player.refusal == .queueAdvertisement)
        await player.setShuffle(true)
        #expect(player.refusal == .queueAdvertisement)
        await player.setRepeat(.all)
        #expect(player.refusal == .queueAdvertisement)
        #expect([WebMusicScripts.playQueueItem, WebMusicScripts.setShuffle, WebMusicScripts.setRepeat].allSatisfy { commands(fake, $0).isEmpty }, "no command was sent")
        await player.teardown()
    }
    @Test func aPageAnswerBecomesAStatedReasonAndNothingIsShownAsDone() async throws {
        let (player, fake) = try await started()
        fake.replies = [.ad]
        await player.playQueueItem(otherVideo)
        #expect(player.refusal == .queueAdvertisement, "the page's own ad check also refuses")
        fake.replies = [.rejected]
        await player.playQueueItem(otherVideo)
        #expect(player.refusal == .queueItemGone)
        fake.replies = [.rejected]
        await player.setShuffle(true)
        #expect(player.refusal == .pageDidNotTake)
        fake.replies = [.unsupported]
        await player.setRepeat(.one)
        #expect(player.refusal == .pageDidNotTake)
        fake.replies = [.ok]
        await player.setRepeat(.one)
        #expect(player.refusal == nil)
        await player.teardown()
    }
    @Test func shuffleAndRepeatStateChangeOnlyWhenThePageReportsIt() async throws {
        let (player, fake) = try await started()
        #expect(player.snapshot.shuffle == false && player.snapshot.repeatMode == .off)
        await player.setShuffle(true)
        await player.setRepeat(.all)
        let shuffle = try #require(commands(fake, WebMusicScripts.setShuffle).first), repeating = try #require(commands(fake, WebMusicScripts.setRepeat).first)
        #expect(shuffle.arguments["on"] as? Bool == true && repeating.arguments["mode"] as? String == "all")
        #expect(player.snapshot.shuffle == false && player.snapshot.repeatMode == .off, "an acknowledged command is not the page's state: nothing changes until it reports")
        var report = state(shuffle: true); report["repeat"] = "all"
        fake.send(report)
        #expect(player.snapshot.shuffle == true && player.snapshot.repeatMode == .all)
        await player.teardown()
    }
    @Test func nothingIsSentBeforeAnythingPlays() async {
        let (player, page) = makePlayer()
        await player.setShuffle(true); await player.setRepeat(.all); await player.playQueueItem(otherVideo)
        #expect(page() == nil, "the controls cannot create the page")
    }
    @Test func theCommandsCarryOnlyValidatedArguments() throws {
        let item = try WebMusicCommand.playQueueItem(otherVideo).invocation()
        #expect(item.body == WebMusicScripts.playQueueItem && !item.body.contains(otherVideo) && item.arguments["videoId"] as? String == otherVideo)
        for bad in ["short", "x');alert(1)//", "", "SYNTHvid00 "] { #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.playQueueItem(bad).invocation() } }
        #expect(try WebMusicCommand.shuffle(false).invocation().arguments["on"] as? Bool == false)
        #expect(try WebMusicCommand.repeatMode(.one).invocation().arguments["mode"] as? String == "one")
    }
}

/// The shipped observer and command scripts, run in JavaScriptCore against a stub page whose queue items carry the SERVICE'S OWN renderer shape: the
/// real anonymous public `next` response in `Fixtures/W18-real/next-song.json` (hash-checked against its manifest), plus synthetic items cloned from it.
@MainActor private final class QueuePageHarness {
    let context = JSContext()!
    private final class IssueBox: @unchecked Sendable { var items: [String] = [] }
    private let box = IssueBox()
    var issues: [String] { box.items }
    /// `nodes` are the `ytmusic-player-queue-item` `.data` values; `shuffle`/`repeatMode` are the player bar's state (nil = the page shows none).
    init(nodes: [[String: Any]], playing: String, ad: Bool = false, shuffle: String? = "false", repeatMode: String? = "NONE", clicksWork: Bool = true, markSelectedAttribute: Int? = nil) {
        let box = box
        context.exceptionHandler = { _, exception in box.items.append(exception?.toString() ?? "?") }
        let data = try! JSONSerialization.data(withJSONObject: nodes)
        context.evaluateScript("""
        var __nodes = \(String(decoding: data, as: UTF8.self)).map(function (d, i) {
          return { data: d, hasAttribute: function (name) { return name === "selected" && \(markSelectedAttribute.map { "i === \($0)" } ?? "false"); } };
        });
        var __playing = \(JSONLiteral.string(playing)), __ad = \(ad), __clicks = [], __posted = [], __intervals = [], __listeners = {}, __clock = 1000;
        var __shuffle = \(shuffle.map(JSONLiteral.string) ?? "null"), __repeat = \(repeatMode.map(JSONLiteral.string) ?? "null"), __works = \(clicksWork);
        var __routed = null, __router = true;
        var Date = { now: function () { return __clock; } };
        var setTimeout = function (fn) { Promise.resolve().then(fn); };
        var setInterval = function (fn) { __intervals.push(fn); };
        var __shuffleButton = { click: function () { __clicks.push("shuffle"); if (__works && __shuffle !== null) { __shuffle = __shuffle === "true" ? "false" : "true"; } },
          getAttribute: function (name) { return name === "aria-pressed" ? __shuffle : null; } };
        var __repeatButton = { click: function () { __clicks.push("repeat"); if (__works && __repeat !== null) { __repeat = __repeat === "NONE" ? "ALL" : (__repeat === "ALL" ? "ONE" : "NONE"); } } };
        var __bar = { getAttribute: function (name) { return name === "repeat-mode_" ? __repeat : null; } };
        var __api = { getVideoData: function () { return { video_id: __playing }; } };
        var __video = { paused: false, ended: false, readyState: 4, currentTime: 10, duration: 200, addEventListener: function () {} };
        var __app = { resolveCommand: function (command) { if (!__router) { throw new Error("no"); } __routed = command; } };
        var __movie = { classList: { contains: function (name) { return __ad && name === "ad-showing"; } } };
        var document = {
          querySelector: function (selector) {
            switch (selector) {
            case "video": return __video;
            case "ytmusic-player": return { playerApi: __api };
            case "ytmusic-app": return __app;
            case "ytmusic-player-bar .shuffle": return __shuffle === null ? null : __shuffleButton;
            case "ytmusic-player-bar .repeat": return __repeat === null ? null : __repeatButton;
            case "ytmusic-player-bar": return __bar;
            default: return null; }
          },
          querySelectorAll: function (selector) {
            return selector.split(",").some(function (part) { return part.trim() === "ytmusic-player-queue-item"; }) ? __nodes : [];
          },
          getElementById: function (id) { return id === "movie_player" ? __movie : null; }, body: { innerText: "" }, addEventListener: function () {}
        };
        var window = { location: { hostname: "music.youtube.com", href: "https://music.youtube.com/watch?v=" + __playing },
          __ytmuseState: { doc: 1, load: 1, intent: false, meta: null, observing: false },
          webkit: { messageHandlers: { \(WebMusicBridge.handlerName): { postMessage: function (m) { __posted.push(JSON.stringify(m)); } } } } };
        window.top = window;
        """)
    }
    func installObserver() { context.evaluateScript(WebMusicScripts.observer) }
    func tick() { context.evaluateScript("__clock += 1000; __intervals.forEach(function (fn) { fn(); });") }
    func posts(_ type: String) -> [[String: Any]] {
        let raw = context.evaluateScript("__posted")!.toArray() as? [String] ?? []
        return raw.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }.filter { $0["type"] as? String == type }
    }
    /// The newest queue post, through the real bridge.
    func lastQueue() -> Result<WebMusicMessage, WebMusicRejection>? {
        posts("queue").last.map { WebMusicBridge.validate($0, frame: music, document: 1, load: 1) }
    }
    /// Runs a command body as the page would: an async function over typed arguments; the promise is settled before this returns.
    func run(_ body: String, _ arguments: [String: Any]) -> String {
        let names = arguments.keys.sorted()
        let literals = names.map { name -> String in
            if let flag = arguments[name] as? Bool { return flag ? "true" : "false" }
            if let number = arguments[name] as? Int { return String(number) }
            return JSONLiteral.string(arguments[name] as? String ?? "")
        }
        context.evaluateScript("var __result = 'pending'; (async function (\(names.joined(separator: ", "))) { \(body) })(\(literals.joined(separator: ", "))).then(function (v) { __result = v; });")
        return context.evaluateScript("__result")?.toString() ?? "?"
    }
    var clicks: [String] { (context.evaluateScript("__clicks")?.toArray() as? [String]) ?? [] }
    var routed: [String: Any]? { context.evaluateScript("__routed")?.toDictionary() as? [String: Any] }
    func set(_ script: String) { context.evaluateScript(script) }
}

private enum RealQueue {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// The two `playlistPanelVideoRenderer`s of the real `next` capture, as the page's queue items hold them (`{ playlistPanelVideoRenderer: … }`).
    static func items() throws -> [[String: Any]] {
        let file = root.appendingPathComponent("Fixtures/W18-real/next-song.json")
        let data = try Data(contentsOf: file)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Fixtures/W18-real/manifest.json"))) as? [String: Any])
        let entries = try #require(manifest["files"] as? [[String: Any]])
        let expected = try #require(entries.first { $0["path"] as? String == "next-song.json" }?["sha256"] as? String)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected, "the fixture is the byte-for-byte capture")
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let panel = try #require(((((((json["contents"] as? [String: Any])?["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any])?["tabbedRenderer"] as? [String: Any])?["watchNextTabbedResultsRenderer"] as? [String: Any])?["tabs"] as? [[String: Any]])?.first?["tabRenderer"] as? [String: Any])?["content"] as? [String: Any])
        let queue = try #require(((panel["musicQueueRenderer"] as? [String: Any])?["content"] as? [String: Any])?["playlistPanelRenderer"] as? [String: Any])
        return try #require(queue["contents"] as? [[String: Any]])
    }
    /// A synthetic item in the real renderer's shape: the capture's first renderer with another video, title and artist.
    static func clone(_ real: [String: Any], id: String, title: String, selected: Bool = false) throws -> [String: Any] {
        var renderer = try #require(real["playlistPanelVideoRenderer"] as? [String: Any])
        renderer["videoId"] = id
        renderer["title"] = ["runs": [["text": title]]]
        renderer["selected"] = selected
        var endpoint = try #require(renderer["navigationEndpoint"] as? [String: Any])
        var watch = try #require(endpoint["watchEndpoint"] as? [String: Any]); watch["videoId"] = id; endpoint["watchEndpoint"] = watch
        renderer["navigationEndpoint"] = endpoint
        return ["playlistPanelVideoRenderer": renderer]
    }
}

@Suite @MainActor struct WebMusicQueueObserverScriptTests {
    private func page(extra: Int = 3, playing: String = "khnokW3Mw24", ad: Bool = false) throws -> QueuePageHarness {
        let real = try RealQueue.items()
        var nodes = real
        for n in 0..<extra { nodes.append(try RealQueue.clone(real[0], id: String(format: "SYNTHq%05d", n), title: "Synthetic Track \(n)")) }
        let harness = QueuePageHarness(nodes: nodes, playing: playing, ad: ad)
        harness.installObserver()
        return harness
    }
    @Test func theRealCapturesRendererIsReadIntoTheItemsTheBridgeAccepts() throws {
        let real = try RealQueue.items()
        #expect(real.count == 2 && real[0]["playlistPanelVideoRenderer"] != nil && real[1]["automixPreviewVideoRenderer"] != nil,
                "the capture lists the playing song and the page's automix preview, which is not a queue item")
        let harness = try page(extra: 3)
        let message = try #require(harness.lastQueue(), "a queue was posted: \(harness.issues)")
        guard case .queue(let queue) = try message.get().event else { Issue.record("not a queue"); return }
        #expect(queue.videoID == "khnokW3Mw24" && queue.upcoming.count == 3 && queue.more == 0, "the automix preview is skipped, not listed and not an error")
        #expect(queue.upcoming.map(\.title) == ["Synthetic Track 0", "Synthetic Track 1", "Synthetic Track 2"])
        let first = try #require(queue.upcoming.first)
        #expect(first.artist == "Daft Punk & Julian Casablancas" && first.artworkURL?.host?.hasSuffix("googleusercontent.com") == true, "artist and artwork come from the renderer: \(first)")
        #expect(harness.issues.isEmpty)
    }
    @Test func theArtistIsTheBylineUpToItsFirstBulletAndArtworkIsAMidSizeThumbnail() throws {
        let harness = try page(extra: 0)
        let queue = try #require(harness.posts("queue").last)
        let items = try #require((try? JSONSerialization.jsonObject(with: Data((queue["items"] as? String ?? "").utf8))) as? [[String: Any]])
        let playing = try #require(items.first)
        #expect(playing["c"] as? Bool == true)
        #expect(playing["a"] as? String == "Daft Punk & Julian Casablancas", "the byline's artists, up to its first bullet")
        let url = try #require(playing["u"] as? String)
        #expect(url.contains("w120-h120"), "the first thumbnail at least 100 px wide is the one used")
    }
    @Test func aQueueThatStillMarksAnotherItemSelectedIsNotAttributedToTheNewOne() throws {
        // The page moved on to SYNTHq00001 but its DOM still marks the old item selected: the old marker names another video, so only the video match counts.
        let real = try RealQueue.items()
        let nodes = [real[0], try RealQueue.clone(real[0], id: "SYNTHq00000", title: "A"), try RealQueue.clone(real[0], id: "SYNTHq00001", title: "B")]
        let harness = QueuePageHarness(nodes: nodes, playing: "SYNTHq00001"); harness.installObserver()
        guard case .queue(let queue)? = try harness.lastQueue()?.get().event else { Issue.record("no queue"); return }
        #expect(queue.videoID == "SYNTHq00001" && queue.upcoming.isEmpty, "B is the only entry with that video, and nothing follows it")
    }
    @Test func aVideoListedTwiceWithNoMarkerClaimsNothingAfterIt() throws {
        let real = try RealQueue.items()
        let nodes = [try RealQueue.clone(real[0], id: "SYNTHq00000", title: "A"), try RealQueue.clone(real[0], id: "SYNTHq00001", title: "B"), try RealQueue.clone(real[0], id: "SYNTHq00000", title: "A again")]
        let harness = QueuePageHarness(nodes: nodes, playing: "SYNTHq00000"); harness.installObserver()
        #expect(harness.posts("queue").isEmpty, "ambiguous and never listed before: nothing is posted")
        let marked = QueuePageHarness(nodes: nodes, playing: "SYNTHq00000", markSelectedAttribute: 2); marked.installObserver()
        guard case .queue(let queue)? = try marked.lastQueue()?.get().event else { Issue.record("no queue"); return }
        #expect(queue.upcoming.isEmpty, "the page's own selected attribute says it is the last one")
    }
    @Test func anUnknownPageShapeProducesNoListAndNoError() throws {
        let harness = QueuePageHarness(nodes: [["somethingElse": ["videoId": "SYNTHq00000"]], ["playlistPanelVideoRenderer": ["videoId": 5]], [:]], playing: "SYNTHq00000")
        harness.installObserver(); harness.tick(); harness.tick()
        #expect(harness.posts("queue").isEmpty && harness.issues.isEmpty, "hidden, with no crash: \(harness.issues)")
        #expect(!harness.posts("state").isEmpty, "the rest of the observer still works")
    }
    @Test func aListThatBecomesUnreadableIsClearedOnce() throws {
        let harness = try page(extra: 1)
        #expect(harness.posts("queue").count == 1)
        harness.set("__nodes = [];")
        harness.tick()
        let clearing = try #require(harness.posts("queue").last)
        #expect(harness.posts("queue").count == 2 && clearing["videoId"] as? String == "", "an empty videoId says the queue is unreadable")
        harness.tick(); harness.tick()
        #expect(harness.posts("queue").count == 2, "the clearing is posted once")
    }
    @Test func theQueueIsPostedOnceAndAgainOnlyWhenItChanges() throws {
        let harness = try page(extra: 2)
        for _ in 0..<5 { harness.tick() }
        #expect(harness.posts("queue").count == 1, "an unchanged queue posts nothing more")
        harness.set("__nodes.shift();")   // the playing item leaves the list
        harness.set("__playing = __nodes[0].data.playlistPanelVideoRenderer.videoId; window.location.href = 'https://music.youtube.com/watch?v=' + __playing; __nodes[0].data.playlistPanelVideoRenderer.selected = true;")
        harness.tick()
        #expect(harness.posts("queue").count == 2)
    }
    @Test func nothingIsPostedWhileAnAdvertisementPlays() throws {
        let harness = try page(extra: 2)
        let before = harness.posts("queue").count
        harness.set("__ad = true; __nodes.pop();")
        harness.tick(); harness.tick()
        #expect(harness.posts("queue").count == before, "the list stays what it was before the ad")
        harness.set("__ad = false;")
        harness.tick()
        #expect(harness.posts("queue").count == before + 1, "and is read again when the ad is over")
    }
    @Test func aLongQueueIsCutToThirtyUpcomingItemsAndSaysHowManyMore() throws {
        let real = try RealQueue.items()
        var nodes = [try RealQueue.clone(real[0], id: "SYNTHq00000", title: "Now", selected: true)]
        for n in 1...100 { nodes.append(try RealQueue.clone(real[0], id: String(format: "SYNTHq%05d", n), title: "T\(n)")) }
        let harness = QueuePageHarness(nodes: nodes, playing: "SYNTHq00000"); harness.installObserver()
        guard case .queue(let queue)? = try harness.lastQueue()?.get().event else { Issue.record("no queue \(harness.issues)"); return }
        #expect(queue.upcoming.count == 30 && queue.more == 70 && queue.upcoming.first?.title == "T1" && queue.upcoming.last?.title == "T30")
    }
    @Test func shuffleAndRepeatAreReadFromThePlayerBarAndOmittedWhenItSaysNothing() throws {
        let real = try RealQueue.items()
        let known = QueuePageHarness(nodes: real, playing: "khnokW3Mw24", shuffle: "true", repeatMode: "ALL"); known.installObserver()
        let first = try #require(known.posts("state").last)
        #expect(first["shuffle"] as? Bool == true && first["repeat"] as? String == "all")
        for (raw, name) in [("NONE", "off"), ("ONE", "one")] {
            let harness = QueuePageHarness(nodes: real, playing: "khnokW3Mw24", repeatMode: raw); harness.installObserver()
            #expect(harness.posts("state").last?["repeat"] as? String == name)
        }
        let silent = QueuePageHarness(nodes: real, playing: "khnokW3Mw24", shuffle: nil, repeatMode: nil); silent.installObserver()
        let message = try #require(silent.posts("state").last)
        #expect(message["shuffle"] == nil && message["repeat"] == nil, "no guess when the page shows nothing")
        let odd = QueuePageHarness(nodes: real, playing: "khnokW3Mw24", repeatMode: "SOMETHING"); odd.installObserver()
        #expect(odd.posts("state").last?["repeat"] == nil, "an unknown mode is not reported")
    }
}

@Suite @MainActor struct WebMusicQueueCommandScriptTests {
    private func page(ad: Bool = false, shuffle: String? = "false", repeatMode: String? = "NONE", clicksWork: Bool = true, extra: Int = 3) throws -> QueuePageHarness {
        let real = try RealQueue.items()
        var nodes = real
        for n in 0..<extra { nodes.append(try RealQueue.clone(real[0], id: String(format: "SYNTHq%05d", n), title: "Synthetic Track \(n)")) }
        return QueuePageHarness(nodes: nodes, playing: "khnokW3Mw24", ad: ad, shuffle: shuffle, repeatMode: repeatMode, clicksWork: clicksWork)
    }
    @Test func playingAQueueItemHandsTheRouterThePagesOwnEndpointForThatItem() throws {
        let harness = try page()
        #expect(harness.run(WebMusicScripts.playQueueItem, ["videoId": "SYNTHq00001"]) == "ok")
        let routed = try #require(harness.routed)
        let watch = try #require(routed["watchEndpoint"] as? [String: Any])
        #expect(watch["videoId"] as? String == "SYNTHq00001", "the item's own published endpoint, not one built here")
        #expect(harness.context.evaluateScript("window.__ytmuseState.intent").toBool(), "the page is allowed to start it")
        #expect(harness.issues.isEmpty)
    }
    @Test func anAdvertisementRefusesSelectionBeforeAnythingIsRouted() throws {
        let harness = try page(ad: true)
        #expect(harness.run(WebMusicScripts.playQueueItem, ["videoId": "SYNTHq00001"]) == "ad" && harness.routed == nil)
        #expect(!harness.context.evaluateScript("window.__ytmuseState.intent").toBool(), "and no intent to play was recorded")
    }
    @Test func onlyAnItemAfterThePlayingOneCanBeChosen() throws {
        let harness = try page()
        #expect(harness.run(WebMusicScripts.playQueueItem, ["videoId": "khnokW3Mw24"]) == "rejected", "the playing item itself is not 'next'")
        #expect(harness.run(WebMusicScripts.playQueueItem, ["videoId": "SYNTHzzzzzz"]) == "rejected", "an item the page does not list")
        #expect(harness.routed == nil)
        harness.set("__playing = 'SYNTHq00001'; window.location.href = 'x';")
        #expect(harness.run(WebMusicScripts.playQueueItem, ["videoId": "SYNTHq00000"]) == "rejected", "an earlier item is not offered")
    }
    @Test func aPageWithoutARouterOrEndpointDoesNothing() throws {
        let harness = try page()
        harness.set("__app.resolveCommand = undefined;")
        #expect(harness.run(WebMusicScripts.playQueueItem, ["videoId": "SYNTHq00001"]) == "unsupported")
        harness.set("__app.resolveCommand = function () { throw new Error('x'); };")
        #expect(harness.run(WebMusicScripts.playQueueItem, ["videoId": "SYNTHq00001"]) == "rejected")
        #expect(!harness.context.evaluateScript("window.__ytmuseState.intent").toBool(), "a failed request leaves the play intent as it was")
        let noEndpoint = QueuePageHarness(nodes: [["playlistPanelVideoRenderer": ["videoId": "khnokW3Mw24", "selected": true]], ["playlistPanelVideoRenderer": ["videoId": "SYNTHq00001"]]], playing: "khnokW3Mw24")
        #expect(noEndpoint.run(WebMusicScripts.playQueueItem, ["videoId": "SYNTHq00001"]) == "rejected", "an item that publishes no watch endpoint is not played")
    }
    @Test func shuffleClicksOnlyWhenTheStateDiffersAndAnswersOkOnlyWhenThePageShowsIt() throws {
        let harness = try page()
        #expect(harness.run(WebMusicScripts.setShuffle, ["on": true]) == "ok" && harness.clicks == ["shuffle"])
        #expect(harness.run(WebMusicScripts.setShuffle, ["on": true]) == "ok" && harness.clicks == ["shuffle"], "already on: no second click")
        #expect(harness.run(WebMusicScripts.setShuffle, ["on": false]) == "ok" && harness.clicks == ["shuffle", "shuffle"])
        let stuck = try page(clicksWork: false)
        #expect(stuck.run(WebMusicScripts.setShuffle, ["on": true]) == "rejected" && stuck.clicks == ["shuffle"], "a click the page ignored is not reported as done")
    }
    @Test func shuffleAndRepeatNeverClickAControlWhoseStateTheyCannotRead() throws {
        let blind = try page(shuffle: nil, repeatMode: nil)
        #expect(blind.run(WebMusicScripts.setShuffle, ["on": true]) == "unsupported" && blind.run(WebMusicScripts.setRepeat, ["mode": "all"]) == "unsupported" && blind.clicks.isEmpty)
        let unreadable = try page(shuffle: "mixed", repeatMode: "WEIRD")
        #expect(unreadable.run(WebMusicScripts.setShuffle, ["on": true]) == "unsupported" && unreadable.run(WebMusicScripts.setRepeat, ["mode": "all"]) == "unsupported" && unreadable.clicks.isEmpty)
    }
    @Test func repeatStepsThePagesOwnButtonUntilThePageShowsTheRequestedMode() throws {
        let harness = try page()
        #expect(harness.run(WebMusicScripts.setRepeat, ["mode": "one"]) == "ok" && harness.clicks == ["repeat", "repeat"], "off -> all -> one")
        #expect(harness.run(WebMusicScripts.setRepeat, ["mode": "one"]) == "ok" && harness.clicks.count == 2, "already there: no click")
        #expect(harness.run(WebMusicScripts.setRepeat, ["mode": "all"]) == "ok" && harness.clicks.count == 4, "one -> off -> all")
        let stuck = try page(clicksWork: false)
        #expect(stuck.run(WebMusicScripts.setRepeat, ["mode": "all"]) == "rejected" && stuck.clicks == ["repeat"], "it gives up after a click that changed nothing")
    }
    @Test func anAdvertisementRefusesShuffleAndRepeatWithoutAClick() throws {
        let harness = try page(ad: true)
        #expect(harness.run(WebMusicScripts.setShuffle, ["on": true]) == "ad" && harness.run(WebMusicScripts.setRepeat, ["mode": "all"]) == "ad" && harness.clicks.isEmpty)
    }
    @Test func theNewScriptsAreHeldToTheAdvertisingRulesAndTouchNothingElse() {
        for body in [WebMusicScripts.playQueueItem, WebMusicScripts.setShuffle, WebMusicScripts.setRepeat] {
            #expect(body.contains("if (ytmuseAdShowing()) { return \"ad\"; }"))
            for forbidden in ["skipAd", "ytp-ad-skip", "muted", "display", "visibility", "remove()", "evaluateJavaScript", "document.cookie", "skip-button", "playbackRate", "volume", "eval(", "fetch(", "XMLHttpRequest"] {
                #expect(!body.contains(forbidden), "\(forbidden)")
            }
        }
        #expect(!WebMusicScripts.playQueueItem.contains(".click(") && WebMusicScripts.setShuffle.contains("ytmusic-player-bar .shuffle") && WebMusicScripts.setRepeat.contains("ytmusic-player-bar .repeat"))
        #expect(!WebMusicScripts.queueDetection.contains(".click(") && !WebMusicScripts.queueDetection.contains("resolveCommand"), "the reader of the queue acts on nothing")
        // Arguments only: the typed values never appear in the constant bodies.
        #expect((try? WebMusicCommand.playQueueItem("SYNTHvid001").invocation())?.body.contains("SYNTHvid001") == false)
    }
}

@Suite @MainActor struct RadioQueueCommandScriptTests {
    @Test func boundedArgumentsAndCanonicalOperationReachResolveCommandExactly() throws {
        for extra in [nil, "0gcJCW0At9Zurpe2"] as [String?] {
            let command = try #require(MusicQueueFilterCommand(playlistID: "RDATmZvkhnokW3Mw24", params: "opaque%3D", playerParams: extra))
            let invocation = try WebMusicCommand.updateRadioQueue(command, document: 1, load: 1, videoID: "khnokW3Mw24", currentPlaylistID: "RDoriginal").invocation()
            let harness = QueuePageHarness(nodes: try RealQueue.items(), playing: "khnokW3Mw24")
            harness.set("__api.getPlaylistId = function() { return 'RDoriginal'; };")
            let before = harness.context.evaluateScript("JSON.stringify(window.__ytmuseState)")?.toString()
            #expect(harness.run(invocation.body, invocation.arguments) == "router")
            let actual = try #require(harness.routed)
            var endpoint = ["playlistId": command.playlistID, "params": command.params]
            if let extra { endpoint["playerParams"] = extra }
            let expected: [String: Any] = ["queueUpdateCommand": ["queueUpdateSection": "QUEUE_UPDATE_SECTION_AUTOPLAY",
                "fetchContentsCommand": ["watchEndpoint": endpoint], "dedupeAgainstLocalQueue": true,
                "syncMode": "QUEUE_UPDATE_SYNC_MODE_DEDUPE_AGAINST_LOCAL"]]
            #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
            #expect(harness.context.evaluateScript("JSON.stringify(window.__ytmuseState)")?.toString() == before)
            #expect(harness.issues.isEmpty)
        }
    }
    @Test func liveAdAndStaleDocumentLoadOrContentRefuseWithoutMutation() throws {
        let command = try #require(MusicQueueFilterCommand(playlistID: "RDpublished", params: "p"))
        let call = try WebMusicCommand.updateRadioQueue(command, document: 1, load: 1, videoID: "khnokW3Mw24", currentPlaylistID: "RDoriginal").invocation()
        for replacement in ["__ad = true;", "window.__ytmuseState.doc = 2;", "window.__ytmuseState.load = 2;", "__playing = 'aaaaaaaaaa2';", "__api.getPlaylistId = function() { return 'PLother'; };"] {
            let harness = QueuePageHarness(nodes: try RealQueue.items(), playing: "khnokW3Mw24")
            harness.set("__api.getPlaylistId = function() { return 'RDoriginal'; };")
            harness.set(replacement)
            let before = harness.context.evaluateScript("JSON.stringify(window.__ytmuseState)")?.toString()
            #expect(["ad", "rejected"].contains(harness.run(call.body, call.arguments)))
            #expect(harness.routed == nil)
            #expect(harness.context.evaluateScript("JSON.stringify(window.__ytmuseState)")?.toString() == before)
        }
    }
    @Test func malformedAndOversizedFieldsAreRefused() throws {
        for bad in ["", "bad params", "p\n", "p\r\n", "é", "p<script>", String(repeating: "p", count: 1025)] {
            #expect(MusicQueueFilterCommand(playlistID: "RDvalid", params: bad) == nil)
            #expect(MusicQueueFilterCommand(playlistID: "RDvalid", params: "p", playerParams: bad) == nil)
        }
        #expect(MusicQueueFilterCommand(playlistID: String(repeating: "p", count: 129), params: "p") == nil)
        let command = try #require(MusicQueueFilterCommand(playlistID: "RDvalid", params: String(repeating: "p", count: 1024)))
        for load: UInt64 in [0, 9_007_199_254_740_992] {
            #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.updateRadioQueue(command, document: 1, load: load, videoID: "khnokW3Mw24", currentPlaylistID: "RDoriginal").invocation() }
        }
    }
}
@Suite @MainActor struct RadioQueuePlayerTests {
    private func ready() async throws -> (WebMusicPlayer, FakeMusicPage, WebMusicRadioQueueScope) {
        let (player, page) = makePlayer(timeout: .milliseconds(80))
        await player.play(playlistID: "RDoriginal")
        let fake = try #require(page()); fake.commitLast()
        let paused = state(playing: false, video: "aaaaaaaaaa1", playlist: "RDoriginal", shuffle: false)
        fake.send(paused)
        await player.pause()
        fake.send(queueBody(playing: "aaaaaaaaaa1", upcoming: [("bbbbbbbbbb1", "Before", "")]))
        return (player, fake, try #require(player.captureRadioQueueScope(playlistID: "RDoriginal")))
    }
    @Test func pausedAutoplayUpdatePreservesCurrentTargetDocumentLoadIntentAndArtwork() async throws {
        let (player, fake, scope) = try await ready()
        let before = player.snapshot, art = player.artwork, loads = fake.loads.count
        let command = try #require(MusicQueueFilterCommand(playlistID: "RDdifferentFetch", params: "p", playerParams: "0gcJCW0At9Zurpe2"))
        let task = Task { await player.applyRadioFilter(command, scope: scope) }
        await settle { fake.targetAttempts >= 1 }
        await Task.yield(); await Task.yield()
        fake.send(queueBody(playing: "aaaaaaaaaa1", upcoming: [("cccccccccc1", "After", "")]))
        #expect(await task.value)
        #expect(player.snapshot.playlistID == before.playlistID && player.snapshot.videoID == before.videoID)
        #expect(player.snapshot.phase == before.phase && player.snapshot.intent == false && player.artwork == art)
        #expect(player.transport.load == 1 && player.committedDocument == 1 && fake.loads.count == loads)
        #expect(fake.commands.last?.arguments["playerParams"] as? String == command.playerParams)
    }
    @Test func unconfirmedControlAndBothNativeAndPageAdRefusalKeepHealthyPlayback() async throws {
        for mode in ["unchanged", "native-ad", "page-ad", "stale-admission", "pre-acceptance", "stale-after-dispatch"] {
            let (player, fake, scope) = try await ready()
            let command = try #require(MusicQueueFilterCommand(playlistID: "RDfetch", params: "p"))
            if mode == "native-ad" {
                var ad = state(video: "aaaaaaaaaa1", playlist: "RDoriginal"); ad["ad"] = true
                fake.send(ad)
            }
            if mode == "page-ad" { fake.targetReply = .ad }
            var applicable = mode != "stale-admission"
            if mode == "pre-acceptance" || mode == "stale-after-dispatch" {
                fake.intercept = { invocation in
                    guard invocation.body == WebMusicScripts.updateRadioQueue else { return nil }
                    if mode == "pre-acceptance" {
                        fake.send(queueBody(playing: "aaaaaaaaaa1", upcoming: [("cccccccccc1", "Too early", "")]))
                    } else { applicable = false }
                    return .router
                }
            }
            let count = fake.commands.count
            let result = await player.applyRadioFilter(command, scope: scope, admitted: { applicable })
            #expect(!result && !player.snapshot.isFailed && player.transport.load == 1 && fake.loads.count == 1)
            if mode == "native-ad" || mode == "stale-admission" { #expect(fake.commands.count == count) }
        }
    }
    @Test func unrelatedPostAcceptanceReportCannotCertifyAnEarlierApplicableQueue() async throws {
        for laterApplicable in [false, true] {
            let (player, fake, scope) = try await ready()
            let command = try #require(MusicQueueFilterCommand(playlistID: "RDfetch", params: "p"))
            fake.intercept = { invocation in
                guard invocation.body == WebMusicScripts.updateRadioQueue else { return nil }
                fake.send(queueBody(playing: "aaaaaaaaaa1", upcoming: [("cccccccccc1", "Before acceptance", "")]))
                return .router
            }
            let task = Task { await player.applyRadioFilter(command, scope: scope) }
            await settle { fake.targetAttempts > 0 || fake.commands.contains { $0.body == WebMusicScripts.updateRadioQueue } }
            // Let the resolver return; Q1 is already the snapshot's baseline revision.
            for _ in 0..<10 { await Task.yield() }
            let acceptedRevision = player.transport.queueRevision
            fake.send(queueBody(playing: "zzzzzzzzzz1", upcoming: [("dddddddddd1", "Other content", "")]))
            #expect(player.transport.queueRevision == acceptedRevision)
            #expect(player.snapshot.queue?.videoID == "aaaaaaaaaa1")
            if laterApplicable {
                fake.send(queueBody(playing: "aaaaaaaaaa1", upcoming: [("eeeeeeeeee1", "After acceptance", "")]))
                #expect(player.transport.queueRevision > acceptedRevision)
            }
            #expect(await task.value == laterApplicable)
            #expect(!player.snapshot.isFailed && player.snapshot.phase == .paused && !player.snapshot.intent)
        }
    }
    @Test func suspendedDispatchTimesOutReleasesBusyAndFencesLateCompletion() async throws {
        let (player, fake, scope) = try await ready()
        let command = try #require(MusicQueueFilterCommand(playlistID: "RDfetch", params: "p"))
        fake.suspendRadioDispatch = true
        let task = Task { await player.applyRadioFilter(command, scope: scope) }
        await settle { fake.suspendedRadioReply != nil }
        #expect(player.updatingRadioQueue)
        // A continuation ignores cancellation. The outer operation must return without joining it.
        #expect(await task.value == false)
        #expect(!player.updatingRadioQueue && !player.snapshot.isFailed && player.snapshot.phase == .paused)
        #expect(fake.throttleLog.last == true && fake.tornDown == 0 && fake.loads.count == 1)
        let count = fake.commands.count
        for _ in 0..<3 { #expect(await player.applyRadioFilter(command, scope: scope) == false) }
        #expect(fake.commands.count == count, "one outstanding invocation remains bounded after timeout")
        let before = player.snapshot, refusal = player.refusal
        fake.suspendedRadioReply?.resume(returning: .router); fake.suspendedRadioReply = nil
        for _ in 0..<10 { await Task.yield() }
        #expect(player.snapshot == before && player.refusal == refusal && !player.updatingRadioQueue)
        // A fresh control works once the old invocation actually finishes.
        fake.suspendRadioDispatch = false
        let fresh = Task { await player.applyRadioFilter(command, scope: scope) }
        await settle { fake.commands.count > count }
        for _ in 0..<10 { await Task.yield() }
        fake.send(queueBody(playing: "aaaaaaaaaa1", upcoming: [("eeeeeeeeee1", "Fresh", "")]))
        #expect(await fresh.value)
    }
    @Test func playlistDocumentAndClosedPlayerReplacementInvalidateOldScope() async throws {
        for replacement in ["playlist", "document", "closed"] {
            let (player, fake, scope) = try await ready()
            if replacement == "playlist" { await player.play(playlistID: "PLreplacement") }
            if replacement == "document" { player.transport.invalidateDocument() }
            if replacement == "closed" { await player.teardown() }
            let count = fake.commands.count
            let command = try #require(MusicQueueFilterCommand(playlistID: "RDfetch", params: "p"))
            #expect(!player.radioQueueScopeIsCurrent(scope))
            #expect(await player.applyRadioFilter(command, scope: scope) == false)
            #expect(fake.commands.count == count)
        }
    }
    @Test func legacyStartArgumentCannotStartOrCreateAnything() async throws {
        let (player, page) = makePlayer()
        let command = try #require(MusicQueueFilterCommand(playlistID: "RDpublished", params: "p"))
        await player.play(playlistID: command.playlistID, queueCommand: command)
        #expect(page() == nil && player.refusal == .invalidTarget)
    }
}
