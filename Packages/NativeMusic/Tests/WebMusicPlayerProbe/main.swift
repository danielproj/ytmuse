// Test-only helper (never linked into the app). Exercises the real hidden-player
// WebKit page as the FIRST WebKit use in a fresh process (the condition that
// crashed the app at launch in E01 M2). Nothing is loaded: no page, no network.
import AppKit
import Foundation
import Playback

func check(_ condition: Bool, _ label: String) { print((condition ? "ok " : "FAIL ") + label); if !condition { exit(1) } }

@MainActor final class Recorder: WebMusicPageDelegate {
    var changes: [[String]] = []
    var bodies = 0
    func page(received body: Any, from frame: WebMusicFrame) { bodies += 1 }
    func pageCommitted(document: UInt64?) {}
    func pageFailed(_ failure: WebMusicFailure) {}
    func pageCookiesChanged(_ cookies: [HTTPCookie]) { changes.append(cookies.map(\.name).sorted()) }
}
struct ProbeCookies: WebMusicCookieSource {
    func playerCookies() async throws -> [HTTPCookie] { [cookie("SAPISID", "SYNTHETIC-PROBE-SAPISID")] }
    func recordRotation(_ cookies: [HTTPCookie]) async {}
}
struct NoArtwork: WebMusicArtworkLoading { func artwork(_ url: URL) async -> Data? { nil } }
func cookie(_ name: String, _ value: String) -> HTTPCookie {
    HTTPCookie(properties: [.name: name, .value: value, .domain: ".youtube.com", .path: "/", .secure: "TRUE",
                            .expires: Date().addingTimeInterval(3600)])!
}

_ = NSApplication.shared
Task { @MainActor in
    let recorder = Recorder()
    // 1. Cold: the first WebKit use in this process is the player's non-persistent store.
    let page = WebKitMusicPage(delegate: recorder)
    await page.install(cookies: [cookie("SAPISID", "SYNTHETIC-PROBE-SAPISID"), cookie("SID", "SYNTHETIC-PROBE-SID")])
    let facts = await page.diagnostics()
    check(facts != nil, "cold page created and cookies installed without crashing")
    check(facts?.persistent == false, "website data store is non-persistent")
    check(facts?.requiresUserAction == false, "native Play can start media without a web gesture")
    check(facts?.canOpenWindows == false, "page script cannot open windows")
    check(facts?.scripts == 2 && facts?.mainFrameOnlyScripts == 2, "bootstrap and observer are main-frame-only user scripts")
    check(facts?.windowVisible == false, "the hosting window is never shown")
    check(facts?.cookieNames == ["SAPISID", "SID"], "the session cookies are in the player's own store")
    check(facts?.applicationName == WebKitMusicPage.safariApplicationName() && facts?.applicationName?.hasSuffix(" Safari/605.1.15") == true,
          "the player presents Safari's application name (PL1)")
    check(facts?.neverSuspendedWhenInactive == true, "the hidden player is never suspended while not visible (PL2)")
    // 1b. P5-1: the policy written through `webView.configuration.preferences` reaches the live view
    //     (the configuration is a copy, its WKPreferences is shared). Whether WebKit then really throttles a
    //     running page's WebContent process cannot be observed here: only the policy WebKit reports.
    page.setThrottled(true)
    check(await page.diagnostics()?.inactiveSchedulingPolicy == "throttle", "throttling the paused page sticks on the live view (P5-1)")
    check(await page.diagnostics()?.neverSuspendedWhenInactive == false, "a throttled page is not 'never suspended'")
    page.setThrottled(false)
    check(await page.diagnostics()?.inactiveSchedulingPolicy == "none", "lifting it before Play restores 'none'")
    check(await page.diagnostics()?.neverSuspendedWhenInactive == true, "and the page is again never suspended while not visible (PL2)")
    // 2. A cookie change in the store reaches the delegate (rotation observation).
    await page.install(cookies: [cookie("SIDCC", "SYNTHETIC-PROBE-ROTATED")])
    for _ in 0..<60 where !recorder.changes.contains(where: { $0.contains("SIDCC") }) { try? await Task.sleep(for: .milliseconds(50)) }
    check(recorder.changes.contains(where: { $0.contains("SIDCC") }), "cookie store changes are observed")
    // 3. Commands with no document fail closed; teardown releases everything.
    let reply = await page.run(try! WebMusicCommand.pause.invocation())
    check(reply == .unavailable, "a command with no YouTube Music document is unavailable")
    await page.teardown()
    check(await page.diagnostics() == nil, "teardown released the view, window and store")
    await page.teardown()
    check(recorder.bodies == 0, "no bridge message without a document")
    // 4. End to end with fixtures served as simulated responses (no network): the
    //    real player, page scripts, bridge and navigation policy.
    let fixtures = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Fixtures/E01-P1")
    for (name, expectFailure) in [("unsupported-browser.html", WebMusicFailure.unsupportedBrowser), ("music-app-shell.html", nil)] {
        guard let html = try? String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8) else { check(false, "fixture \(name) readable"); return }
        let player = WebMusicPlayer(cookies: ProbeCookies(), artwork: NoArtwork(), loadTimeout: .seconds(30)) { delegate in
            let page = WebKitMusicPage(delegate: delegate); page.simulatedDocument = html; return page
        }
        let start = Date()
        await player.play(playlistID: "PLsyntheticProbe", title: "Probe")
        if let expectFailure {
            while player.snapshot.phase != .failed(expectFailure), Date().timeIntervalSince(start) < 10 { try? await Task.sleep(for: .milliseconds(50)) }
            check(player.snapshot.phase == .failed(expectFailure), "\(name): reported as \(expectFailure), not left to the load timeout")
            check(Date().timeIntervalSince(start) < 5, "\(name): detected within seconds")
            for _ in 0..<40 where player.hasPage { try? await Task.sleep(for: .milliseconds(50)) }
            check(!player.hasPage, "\(name): the page was dropped")
        } else {
            try? await Task.sleep(for: .seconds(3))
            check(!player.snapshot.isFailed && player.snapshot.phase == .loading, "\(name): an app document is not refused")
            check(player.holdsPlaybackActivity, "\(name): App Nap activity held while Play is intended (PL2)")
            await player.teardown()
            check(!player.holdsPlaybackActivity, "activity released at teardown")
        }
    }
    print("PASS")
    exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(60))
print("FAIL timeout")
exit(2)
