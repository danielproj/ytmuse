import Foundation
import JavaScriptCore
import Testing
@testable import Playback

// P17-WEB. The shipped fade script itself, run in JavaScriptCore against a stub page, so the in-page advertising rule is observed and not assumed.

@Suite struct WebMusicSleepTimerScriptTests {
    private final class Page {
        let context: JSContext
        init(volume: Double = 0.8, ad: Bool = false, video: Bool = true, doc: Int = 1) {
            context = JSContext()!
            context.exceptionHandler = { _, error in Issue.record("script error: \(error?.toString() ?? "?")") }
            context.evaluateScript("""
            var window = { __ytmuseState: { doc: \(doc) }, location: { href: "https://music.youtube.com/watch?v=abc" } };
            var adShowing = \(ad);
            var movie = { classList: { contains: function (name) { return adShowing && name === "ad-showing"; } } };
            var video = { volume: \(volume) };
            var document = { getElementById: function (id) { return id === "movie_player" ? movie : null; },
                             querySelector: function (selector) { return selector === "video" && \(video) ? video : null; } };
            function fade(factor) { \(WebMusicScripts.fadeVolume) }
            function personsVolume(level) { \(WebMusicScripts.volume) }
            """)
        }
        func fade(_ factor: Double) -> String { context.objectForKeyedSubscript("fade").call(withArguments: [factor])?.toString() ?? "?" }
        func personsVolume(_ level: Double) -> String { context.objectForKeyedSubscript("personsVolume").call(withArguments: [level])?.toString() ?? "?" }
        var volume: Double { context.evaluateScript("video.volume").toDouble() }
        var remembersALevel: Bool { context.evaluateScript("typeof window.__ytmuseFade !== 'undefined' && window.__ytmuseFade !== null").toBool() }
        func setAd(_ on: Bool) { context.evaluateScript("adShowing = \(on)") }
    }

    @Test func theFadeScalesTheElementsOwnVolumeFromTheLevelItHadAndOneBringsItBack() {
        let page = Page(volume: 0.8)
        #expect(page.fade(0.5) == "ok" && abs(page.volume - 0.4) < 1e-9)
        #expect(page.fade(0.25) == "ok" && abs(page.volume - 0.2) < 1e-9, "the factor applies to the level the fade began at, not to the last step")
        #expect(page.fade(0) == "ok" && page.volume == 0)
        #expect(page.fade(1) == "ok" && abs(page.volume - 0.8) < 1e-9 && !page.remembersALevel, "the person's level is back and nothing is left remembered")
    }
    @Test func anAdvertisementIsNeverFadedAndTheScriptSaysSo() {
        let page = Page(volume: 0.8, ad: true)
        #expect(page.fade(0.5) == "ad" && page.volume == 0.8 && !page.remembersALevel, "refused before anything was lowered")
        #expect(page.fade(0) == "ad" && page.volume == 0.8)
    }
    @Test func anAdvertisementThatAppearsMidFadeGetsTheLevelBackAtTheNextStep() {
        let page = Page(volume: 0.8)
        #expect(page.fade(0.5) == "ok" && abs(page.volume - 0.4) < 1e-9)
        page.setAd(true)
        #expect(page.fade(0.4) == "ad" && abs(page.volume - 0.8) < 1e-9 && !page.remembersALevel, "raised back to what it was, never lowered further")
    }
    @Test func puttingTheLevelBackIsAllowedDuringAnAdvertisementBecauseItOnlyRaisesIt() {
        let page = Page(volume: 0.8)
        _ = page.fade(0.3)
        page.setAd(true)
        #expect(page.fade(1) == "ok" && abs(page.volume - 0.8) < 1e-9)
    }
    @Test func aPersonsOwnVolumeTakesOverFromARunningFade() {
        let page = Page(volume: 0.8)
        _ = page.fade(0.5)
        #expect(page.personsVolume(0.6) == "ok" && abs(page.volume - 0.6) < 1e-9 && !page.remembersALevel)
        #expect(page.fade(0.5) == "ok" && abs(page.volume - 0.3) < 1e-9, "the next step fades from the level the person chose")
    }
    @Test func aReplacedVideoElementStartsFromItsOwnLevel() {
        let page = Page(volume: 0.8)
        _ = page.fade(0.5)
        page.context.evaluateScript("video = { volume: 1 };")
        #expect(page.fade(0.5) == "ok" && abs(page.volume - 0.5) < 1e-9)
        #expect(page.fade(1) == "ok" && abs(page.volume - 1) < 1e-9)
    }
    @Test func noMediaAndNoDocumentAreAnsweredHonestly() {
        #expect(Page(video: false).fade(0.5) == "no-media")
        #expect(Page(doc: -1).fade(0.5) == "unavailable")
    }
    @Test func theCommandCarriesOnlyAFactorBetweenZeroAndOne() throws {
        let command = try WebMusicCommand.fadeVolume(0.25).invocation()
        #expect(command.body == WebMusicScripts.fadeVolume && command.arguments["factor"] as? Double == 0.25 && !command.body.contains("0.25"))
        for bad in [Double.nan, -0.1, 1.1, .infinity] {
            #expect(throws: WebMusicCommandError.invalidArgument) { try WebMusicCommand.fadeVolume(bad).invocation() }
        }
    }
}

/// The structural guards: the fade can only be a fade of the element's own volume, ahead of an ad check, and the timer can only send a fade or a pause.
@Suite struct WebMusicSleepTimerGuardTests {
    private static var sources: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources") }
    private func source(_ relative: String) throws -> String { try String(contentsOf: Self.sources.appendingPathComponent(relative), encoding: .utf8) }

    @Test func theFadeScriptChecksForAnAdvertisementBeforeItLowersAnything() throws {
        let body = WebMusicScripts.fadeVolume
        let check = try #require(body.range(of: "if (ytmuseAdShowing()) { putBack(); return \"ad\"; }"))
        let lower = try #require(body.range(of: "video.volume = Math.max(0, Math.min(1, fade.base * factor))"))
        #expect(check.lowerBound < lower.lowerBound, "the ad check comes first")
        #expect(body.contains("function ytmuseAdShowing"), "the real ad detection is part of the script")
    }
    @Test func theFadeScriptDoesNothingToAnAdvertisementOrThePlayerBeyondTheElementsVolume() {
        // The shared ad DETECTION text (which says in a comment that it never blocks, skips or mutes) is not the fade's own code.
        let body = WebMusicScripts.fadeVolume.replacingOccurrences(of: WebMusicScripts.adDetection, with: "")
        #expect(body.count > 300)
        for forbidden in ["muted", "display", "visibility", "remove()", ".click(", "skip", "playbackRate", "document.cookie", "evaluateJavaScript", "setVolume", "setPlaybackRate",
                          "localStorage", "currentTime", "pause()", "play()", "nextVideo", "previousVideo", "hidden"] {
            #expect(!body.contains(forbidden), "fadeVolume: \(forbidden)")
        }
    }
    @Test func theTimerSendsOnlyAFadeOrAPauseToThePage() throws {
        let text = try source("Playback/WebMusic/WebMusicSleepTimer.swift")
        #expect(text.count > 5000, "the sweep read the timer's source")
        let regex = try NSRegularExpression(pattern: #"\.(seek|next|previous|play|resume|loadPlaylist|loadTarget|volume|rate|normalSpeed|goLive|presentVideo|pictureInPicture|quality|captions)\("#)
        let hits = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        #expect(hits.isEmpty, "the timer reaches the page through fadeVolume and the existing pause only: \(hits)")
        #expect(text.contains("run(.fadeVolume(") && text.contains("await pause()"))
    }
    @Test func theEndOfItemBoundaryComesFromThePagesOwnDurationNeverFromAConstant() throws {
        let text = try source("Playback/WebMusic/WebMusicSleepTimer.swift")
        #expect(text.contains("guard snap.duration > 0") || text.contains("!snap.isLive, snap.duration > 0"), "no duration, no boundary")
        #expect(text.contains("snap.isAd"), "an advertisement is checked on the native side too")
    }
}
