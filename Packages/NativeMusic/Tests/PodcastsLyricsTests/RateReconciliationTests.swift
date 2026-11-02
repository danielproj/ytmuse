import AccountSession
import Foundation
import Testing
@testable import AppShell
@testable import Features
@testable import Playback
import MediaPlayer
import SystemIntegration

// Rework 1 (F1): the speed is what the element REPORTS, reconciled on every report; an ad is always 1x. A fake page stands in for the web view
// (no WebKit, no network, no account).

private let site = WebMusicFrame(isMainFrame: true, scheme: "https", host: "music.youtube.com", port: 0)
private let episode = "AzENYaFVxGg", nextEpisode = "XA56BBR2QS0", adCreative = "SYNTHadv001"

@MainActor private final class RatePage: WebMusicPage {
    weak var delegate: (any WebMusicPageDelegate)?
    var loads: [URL] = []
    var commands: [WebMusicCommand.Invocation] = []
    var rateReplies: [WebMusicCommandReply] = []
    var normalReplies: [WebMusicCommandReply] = []
    init(delegate: any WebMusicPageDelegate) { self.delegate = delegate }
    func install(cookies: [HTTPCookie]) async {}
    func load(_ url: URL) { loads.append(url) }
    func run(_ invocation: WebMusicCommand.Invocation) async -> WebMusicCommandReply {
        commands.append(invocation)
        if invocation.body == WebMusicScripts.rate { return rateReplies.isEmpty ? .ok : rateReplies.removeFirst() }
        if invocation.body == WebMusicScripts.normalSpeed { return normalReplies.isEmpty ? .ok : normalReplies.removeFirst() }
        return .ok
    }
    func setThrottled(_ throttled: Bool) {}
    func teardown() async {}
    func commitLast() { delegate?.pageCommitted(document: WebMusicNavigation.document(of: loads.last)) }
    func send(_ body: [String: Any]) { delegate?.page(received: body, from: site) }
    var rateCommands: Int { commands.filter { $0.body == WebMusicScripts.rate }.count }
    var normalSpeedCommands: Int { commands.filter { $0.body == WebMusicScripts.normalSpeed }.count }
}
private actor Cookies: WebMusicCookieSource {
    func playerCookies() async throws -> [HTTPCookie] { [HTTPCookie(properties: [.name: "SAPISID", .value: "SYNTHETIC", .domain: ".youtube.com", .path: "/", .secure: "TRUE"])!] }
    func recordRotation(_ cookies: [HTTPCookie]) async {}
}
private struct NoArt: WebMusicArtworkLoading { func artwork(_ url: URL) async -> Data? { nil } }
private func state(video: String = episode, ad: Bool = false, playing: Bool = true, load: Int = 1) -> [String: Any] {
    ["type": "state", "doc": 1, "load": load, "playing": playing, "buffering": false, "position": 10.0, "duration": 900.0, "videoId": video, "title": "Synthetic",
     "artist": "Synthetic", "artwork": "https://lh3.googleusercontent.com/x", "ad": ad]
}
private func media(video: String = episode, rate: Any? = nil, load: Int = 1) -> [String: Any] {
    var body: [String: Any] = ["type": "media", "doc": 1, "load": load, "videoId": video, "kind": "audio", "width": 0, "height": 0, "frames": 0, "pip": "unsupported", "isolated": false]
    if let rate { body["rate"] = rate }
    return body
}
@MainActor private func started() async throws -> (WebMusicPlayer, RatePage) {
    var created: RatePage?
    let player = WebMusicPlayer(cookies: Cookies(), artwork: NoArt(), loadTimeout: .seconds(60), rotationDelay: .milliseconds(20)) { delegate in
        let page = RatePage(delegate: delegate); created = page; return page
    }
    await player.play(playlistID: "PLsynthetic", title: "Synthetic")
    let page = try #require(created)
    page.commitLast(); page.send(state())
    #expect(player.snapshot.phase == .playing)
    return (player, page)
}

@MainActor @Suite struct RateReconciliationTests {
    @Test func theSpeedIsOneUntilThePageSaysOtherwiseAndACommandReadBackIsRecorded() async throws {
        let (player, page) = try await started()
        #expect(player.confirmedRate == 1)
        #expect(await player.setRate(1.5) && player.confirmedRate == 1.5 && page.rateCommands == 1)
    }
    @Test func theElementsOwnReportWinsOverTheLastConfirmation() async throws {
        let (player, page) = try await started()
        _ = await player.setRate(1.5)
        // The element reports 1x (a new item reset it): the app shows and uses the ACTUAL speed.
        page.send(media(rate: 1.0))
        #expect(player.confirmedRate == 1)
        page.send(media(rate: 2.0))
        #expect(player.confirmedRate == 2, "and a speed set by something else is shown as it is")
    }
    @Test func aNewItemInThePageForgetsTheOldItemsSpeedUntilTheElementReportsAgain() async throws {
        let (player, page) = try await started()
        _ = await player.setRate(1.5)
        page.send(state(video: nextEpisode))
        #expect(player.confirmedRate == 1, "unknown for the new item is treated as normal speed, so the app asks again")
        page.send(media(video: nextEpisode, rate: 1.5))
        #expect(player.confirmedRate == 1.5)
    }
    @Test func aNewLoadStartsAtNormalSpeed() async throws {
        let (player, _) = try await started()
        _ = await player.setRate(2)
        await player.play(playlistID: "PLsecond", title: nil)
        #expect(player.confirmedRate == 1)
    }
    @Test func teardownForgetsTheSpeed() async throws {
        let (player, _) = try await started()
        _ = await player.setRate(2)
        await player.teardown()
        #expect(player.confirmedRate == 1)
    }
    @Test func aSpeedIsNeverRequestedDuringAnAdvertisement() async throws {
        let (player, page) = try await started()
        page.send(state(video: adCreative, ad: true))
        #expect(player.snapshot.isAd)
        #expect(await player.setRate(1.5) == false && page.rateCommands == 0, "the player layer refuses before any script is run")
    }
    @Test func anAdThatPlaysAtAnotherSpeedIsReturnedToNormalOnce() async throws {
        let (player, page) = try await started()
        _ = await player.setRate(1.5)
        page.send(state(video: adCreative, ad: true))
        page.send(media(video: adCreative, rate: 1.5))
        for _ in 0..<100 where page.normalSpeedCommands == 0 { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<20 { await Task.yield() }
        #expect(page.normalSpeedCommands == 1)
        #expect(player.confirmedRate == 1, "the ad's speed is seen to be normal again")
        #expect(page.rateCommands == 1, "the only speed command was the episode's own, before the ad")
    }
    @Test func anAdAlreadyAtNormalSpeedAndAnEpisodeAtItsSpeedAreLeftAlone() async throws {
        let (player, page) = try await started()
        page.send(state(video: adCreative, ad: true))
        page.send(media(video: adCreative, rate: 1.0))
        for _ in 0..<20 { await Task.yield() }
        #expect(page.normalSpeedCommands == 0)
        // Back to the episode at 1.5x: nothing forces it to normal.
        page.send(state())
        page.send(media(rate: 1.5))
        for _ in 0..<20 { await Task.yield() }
        #expect(page.normalSpeedCommands == 0 && player.confirmedRate == 1.5)
    }
    @Test func aPageThatDoesNotReturnTheAdToNormalIsShownAsItIs() async throws {
        let (player, page) = try await started()
        page.normalReplies = [.rejected]
        page.send(state(video: adCreative, ad: true))
        page.send(media(video: adCreative, rate: 1.5))
        for _ in 0..<100 where page.normalSpeedCommands == 0 { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<20 { await Task.yield() }
        #expect(player.confirmedRate == 1.5, "honest: the element's speed is not claimed to be normal")
    }
    @Test func theReportCarriesAFiniteSpeedOrNothing() throws {
        func parse(_ rate: Any?) -> Result<WebMusicMessage, WebMusicRejection> { WebMusicBridge.validate(media(rate: rate), frame: site, document: 1, load: 1) }
        guard case .success(let ok) = parse(1.25), case .media(let sample) = ok.event else { Issue.record("expected a media sample"); return }
        #expect(sample.rate == 1.25)
        if case .success(let absent) = parse(nil), case .media(let none) = absent.event { #expect(none.rate == nil) } else { Issue.record("absent rate must be fine") }
        for bad: Any in [0, -1, 17, Double.nan, true, "1.5"] { #expect(parse(bad) == .failure(.malformed), Comment(rawValue: "\(bad)")) }
    }
    @Test func theCommandsAndTheReportAreRestrictedToReadingOrRestoringNormal() throws {
        #expect(WebMusicScripts.observer.contains("video.playbackRate") && !WebMusicScripts.observer.contains("playbackRate ="))
        #expect(WebMusicScripts.observer.contains("\"ratechange\""), "a speed change is reported when it happens")
        _ = try WebMusicCommand.normalSpeed.invocation()
    }
    /// Every place `normalSpeed` writes a speed, found by pattern over the whole script: each must be exactly 1 (a regex over all matches, not `contains`).
    @Test func normalSpeedOnlyEverSetsOnePointZero() throws {
        let body = WebMusicScripts.normalSpeed
        let assignments = try NSRegularExpression(pattern: #"playbackRate\s*=(?!=)\s*([^;}\n]+)"#).matches(in: body, range: NSRange(body.startIndex..., in: body))
        let calls = try NSRegularExpression(pattern: #"setPlaybackRate\(([^)]*)\)"#).matches(in: body, range: NSRange(body.startIndex..., in: body))
        #expect(assignments.count >= 1 && calls.count >= 1, "the sweep found the writes it is meant to check")
        for match in assignments + calls {
            let value = String(body[Range(match.range(at: 1), in: body)!]).trimmingCharacters(in: .whitespaces)
            #expect(value == "1", "normalSpeed writes \(value)")
        }
        // The same sweep over the episode command: it writes only the requested `rate`.
        let rateBody = WebMusicScripts.rate
        let writes = try NSRegularExpression(pattern: #"(?:playbackRate\s*=(?!=)\s*|setPlaybackRate\()([^;}\n)]+)"#).matches(in: rateBody, range: NSRange(rateBody.startIndex..., in: rateBody))
        #expect(writes.count >= 2)
        for match in writes { #expect(String(rateBody[Range(match.range(at: 1), in: rateBody)!]).trimmingCharacters(in: .whitespaces) == "rate") }
    }
    /// N1/N2/N3: the speed scripts never speed an ad up, mute it, hide it or press its skip control.
    @Test func theSpeedScriptsNeverMuteHideSkipOrClick() {
        for (name, body) in [("rate", WebMusicScripts.rate), ("normalSpeed", WebMusicScripts.normalSpeed)] {
            for forbidden in ["muted", ".mute(", "volume", "display", "visibility", "remove()", ".click(", "skip", "dispatchEvent", "currentTime", "pause("] {
                #expect(!body.contains(forbidden), "\(name) contains \(forbidden)")
            }
        }
    }
    /// R2-1: a restore that lands after the ad ended does nothing, because the page re-checks before it writes.
    @Test func normalSpeedRechecksInsideThePageThatAnAdIsShowing() {
        let body = WebMusicScripts.normalSpeed
        let check = body.range(of: "if (!ytmuseAdShowing()) { return \"not-ad\"; }")
        let write = body.range(of: "playbackRate = 1")
        #expect(check != nil && write != nil && check!.lowerBound < write!.lowerBound, "the ad check comes before any write")
        #expect(body.contains(WebMusicScripts.adDetection), "and it is the same detection `rate`, `seek` and `skip` use")
        #expect(WebMusicScripts.rate.contains("if (ytmuseAdShowing()) { return \"ad\"; }"))
    }
    @Test func aRestoreThatLandsAfterTheAdEndedDoesNothingAndIsNotRetriedAsARefusal() async throws {
        let (player, page) = try await started()
        _ = await player.setRate(1.5)
        page.normalReplies = [.unavailable]           // the page answers "not-ad": the ad had ended
        page.send(state(video: adCreative, ad: true))
        page.send(media(video: adCreative, rate: 1.5))
        for _ in 0..<100 where page.normalSpeedCommands == 0 { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<20 { await Task.yield() }
        #expect(page.normalSpeedCommands == 1 && player.confirmedRate == 1.5, "nothing was claimed to be normal")
    }
    /// R2-6: a refusal is remembered for the ad; the next report sends nothing; a later ad is asked again.
    @Test func aRefusedAdRestoreIsAskedOncePerAd() async throws {
        let (player, page) = try await started()
        page.normalReplies = [.rejected, .rejected]
        page.send(state(video: adCreative, ad: true))
        for rate in [1.5, 1.75, 1.5, 1.25] {
            page.send(media(video: adCreative, rate: rate))
            for _ in 0..<30 { await Task.yield() }
        }
        #expect(page.normalSpeedCommands == 1, "four reports during one ad, one request")
        #expect(player.confirmedRate == 1.25, "the element's speed is shown as it is")
        // The ad ends and a second one starts: it is asked again.
        page.send(state())
        for _ in 0..<10 { await Task.yield() }
        page.send(state(video: adCreative, ad: true))
        page.send(media(video: adCreative, rate: 1.5))
        for _ in 0..<50 where page.normalSpeedCommands < 2 { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<20 { await Task.yield() }
        #expect(page.normalSpeedCommands == 2)
    }

    /// R2-3 (N8): Now Playing is told the element's speed — not 1 and not the chosen speed.
    @Test func nowPlayingGetsTheSpeedTheElementReports() async throws {
        let (player, page) = try await started()
        _ = await player.setRate(1.5)
        #expect(PlaybackModel.webNowPlayingItem(player.snapshot, artwork: nil, player: player).rate == 1.5)
        page.send(media(rate: 2.0))
        #expect(PlaybackModel.webNowPlayingItem(player.snapshot, artwork: nil, player: player).rate == 2.0, "the element's own speed, not the last choice")
        page.send(media(rate: 1.0))
        let item = PlaybackModel.webNowPlayingItem(player.snapshot, artwork: nil, player: player)
        #expect(item.rate == 1.0 && item.playing && NowPlayingMapping.info(item)[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
        page.send(media(rate: 1.5))
        #expect(NowPlayingMapping.info(PlaybackModel.webNowPlayingItem(player.snapshot, artwork: nil, player: player))[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
        #expect(PlaybackModel.webNowPlayingItem(player.snapshot, artwork: nil, player: nil).rate == 1, "no player: normal speed")
    }
    @Test func theCallSitesUseTheActualSpeed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/PlaybackPanel.swift"), encoding: .utf8)
        #expect(panel.contains("Self.webNowPlayingItem(snapshot, artwork: artwork, player: music, route:") && panel.contains("rate: player?.confirmedRate ?? 1"))
        // PLAYER-1: the speed menu lives in the capsule's (and the expanded player's) ⋯ menu, built in PlayerCapsuleViews.
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/PlayerCapsuleViews.swift"), encoding: .utf8)
        #expect(bar.contains("actual: player.confirmedRate"), "the transport is given the player's actual speed")
        let views = try String(contentsOf: root.appendingPathComponent("Sources/Features/Podcasts/PodcastViews.swift"), encoding: .utf8)
        #expect(views.contains("Text(display.title)") && views.contains("accessibilityValue(Text(display.accessibilityValue))") && views.contains("display.differenceHelp"))
    }
}

@Suite struct PodcastRateDisplayTests {
    @Test func theLabelIsTheActualSpeedAndTheHelpNamesBothWhenTheyDiffer() {
        let same = PodcastRateDisplay(chosen: 1.5, actual: 1.5)
        #expect(same.title == "1.5×" && same.accessibilityValue == "1.5×" && same.differenceHelp == nil)
        let differs = PodcastRateDisplay(chosen: 1.5, actual: 1)
        #expect(differs.title == "1×" && differs.accessibilityValue == "1×", "shows what is playing, not what was chosen")
        #expect(differs.differenceHelp?.contains("1×") == true && differs.differenceHelp?.contains("1.5×") == true)
        #expect(PodcastRateDisplay(chosen: 1.5, actual: 2).title == "2×")
    }
    @Test func withoutAnActualSpeedTheChoiceIsShown() {
        let unknown = PodcastRateDisplay(chosen: 1.25, actual: nil)
        #expect(unknown.title == "1.25×" && unknown.differenceHelp == nil)
    }
}
