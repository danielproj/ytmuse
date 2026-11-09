// Test-only helper (never linked into the app). W17: the REAL hidden-player WebKit page, scripts, bridge and WebMusicPlayer against a
// synthetic stand-in document (Fixtures/W17) that carries a playing <video> of the repository's owned synthetic media. No network, no
// session, no sound (the media are muted; the video file has no audio track and the song file is digital silence).
// Arguments: <Fixtures/W17> <owned-video.mp4>
import AppKit
import Foundation
import Playback

func check(_ condition: Bool, _ label: String) { print((condition ? "ok " : "FAIL ") + label); if !condition { print("FAIL"); exit(1) } }
func note(_ text: String) { print("   " + text) }

struct ProbeCookies: WebMusicCookieSource {
    func playerCookies() async throws -> [HTTPCookie] { [HTTPCookie(properties: [.name: "SAPISID", .value: "SYNTHETIC-PROBE-SAPISID", .domain: ".youtube.com", .path: "/", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)])!] }
    func recordRotation(_ cookies: [HTTPCookie]) async {}
}
struct NoArtwork: WebMusicArtworkLoading { func artwork(_ url: URL) async -> Data? { nil } }

@MainActor func waitFor(_ label: String, seconds: Double = 12, _ condition: @MainActor () -> Bool) async -> Bool {
    let start = Date()
    while !condition(), Date().timeIntervalSince(start) < seconds { try? await Task.sleep(for: .milliseconds(40)) }
    let ok = condition()
    if !ok { print("   timed out waiting for: \(label)") }
    return ok
}

nonisolated(unsafe) var panels: [NSPanel] = []
NSApplication.shared.setActivationPolicy(.accessory)
Task { @MainActor in
    let arguments = CommandLine.arguments
    guard arguments.count > 2, let template = try? String(contentsOf: URL(fileURLWithPath: arguments[1]).appendingPathComponent("music-video-shell.html"), encoding: .utf8),
          let video = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])),
          let song = try? Data(contentsOf: URL(fileURLWithPath: arguments[1]).appendingPathComponent("owned-song-silent.m4a")) else { check(false, "fixtures readable"); return }
    let html = template.replacingOccurrences(of: "{{VIDEO}}", with: video.base64EncodedString()).replacingOccurrences(of: "{{SONG}}", with: song.base64EncodedString())
    @MainActor func makePlayer() -> WebMusicPlayer {
        WebMusicPlayer(cookies: ProbeCookies(), artwork: NoArtwork(), loadTimeout: .seconds(30)) { delegate in
            let page = WebKitMusicPage(delegate: delegate); page.simulatedDocument = html; return page
        }
    }
    /// A small non-activating panel in a screen corner: WebKit counts a video frame only once it is presented, so the decoder
    /// measurements need a surface that is actually on screen. It never takes focus and shows only the synthetic picture.
    @MainActor func host(_ width: Double, _ height: Double, x: Double = 0) -> (NSWindow, NSView) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = NSPanel(contentRect: NSRect(x: screen.maxX - width - 24 - x, y: screen.minY + 24, width: width, height: height), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.becomesKeyOnlyIfNeeded = true; panel.hidesOnDeactivate = false
        let view = VideoPictureView(frame: NSRect(x: 0, y: 0, width: width, height: height)); panel.contentView = view
        panel.orderFrontRegardless(); panels.append(panel)
        return (panel, view)
    }

    // ---------------------------------------------------------------- 1. a music video: representation, picture, decoder, counterpart
    let player = makePlayer()
    await player.play(playlistID: "PLsyntheticVideo", title: "Probe")
    check(await waitFor("playing") { player.snapshot.phase == .playing }, "the synthetic music video plays in the real hidden page")
    check(await waitFor("representation") { player.snapshot.representation == .video }, "the page reports the item as a VIDEO (musicVideoType)")
    check(await waitFor("picture") { player.snapshot.pictureSize == CGSize(width: 480, height: 270) }, "the picture is 480 x 270 (the video track's size)")
    // Hidden (no surface shows it) WebKit presents no frames: the counter is 0 although the media plays. That is the measurement's limit.
    try? await Task.sleep(for: .milliseconds(1200))
    note("hidden: frames counted = \(player.videoActivity.frames) while the media plays (WebKit counts presented frames only)")
    check(await waitFor("counterpart") { player.snapshot.counterpartVideoID == "sOnGVersi01" }, "the service-published counterpart (the song version) is read from the queue item that matches this video")
    check(player.snapshot.counterpartRepresentation == .audio, "and it is the audio version")
    check(player.snapshot.counterpartVideoID != "sUnrelated1", "an unrelated look-alike queue item is never taken as the counterpart")
    note("picture in picture reported by WebKit: \(player.snapshot.pictureInPicture.rawValue)")
    let baseline = await player.measureVideo()
    check(baseline?.present == true && baseline?.presenting == false && baseline?.hidden == 0 && baseline?.styleInstalled == false, "before any surface the page is untouched")

    // ---------------------------------------------------------------- 2. one owner across surfaces; no reload; exact restore
    let (inlineWindow, inline) = host(320, 180), (playerWindow, playerHost) = host(640, 360, x: 360)
    _ = inlineWindow; _ = playerWindow
    let first = await player.presentVideo(on: .inline, host: inline)
    check(first == .attached(.inline), "the inline preview takes the picture")
    let inlineFacts = await player.measureVideo()
    check(inlineFacts?.presenting == true && inlineFacts?.styleInstalled == true && (inlineFacts?.hidden ?? 0) > 0, "the page chrome is hidden for the picture")
    check(inlineFacts?.fit == "contain", "the picture is scaled to fit with its aspect ratio preserved (object-fit: contain)")
    let inlineLayout = WebKitMusicPage.layoutSize(for: CGSize(width: 320, height: 180))   // zoomed out: the page is never laid out narrower than its compact-player breakpoint
    check(inlineFacts?.rect.count == 4 && abs(inlineFacts!.rect[2] - inlineLayout.width) < 1.5 && abs(inlineFacts!.rect[3] - inlineLayout.height) < 1.5, "the video element fills the 320 x 180 preview, nothing else of the page")
    check((inlineFacts?.adOverlayCount ?? 0) >= 1 && inlineFacts?.adOverlaysOnTop == true, "advertising layers are never covered: a hit test at the centre of every ad layer lands on that layer (F1)")
    // F2: the presented page is not interactive. Real AppKit: the host answers no hit test, the web view takes no first responder and offers no menu.
    let centre = NSPoint(x: inline.bounds.midX, y: inline.bounds.midY)
    check(inline.hitTest(centre) == nil, "a click on the surface reaches nothing (the surface answers no hit test)")
    let input = player.inputFacts()
    check(input != nil && input?.acceptsFirstResponder == false && input?.hitTestReturnsView == false && input?.becameFirstResponder == false && input?.hasContextMenu == false,
          "the web view never accepts first responder, is not hit, and has no context menu (F2)")
    check(inline.subviews.count == 1, "the web view itself is on the preview")
    let origin = inlineFacts?.origin
    check(player.snapshot.phase == .playing, "playing while presented")
    // WebKit counts a video frame only when it is PRESENTED, and presents only while the document is visible. A process started from a
    // shell may have windows the window server reports as occluded (document.visibilityState == "hidden"): then no frame is ever counted
    // and the frame positive control cannot run. That is reported, never silently passed; the structural signals (below) and the
    // native AVKit decoder test (NativeVideoTests) still apply.
    try? await Task.sleep(for: .milliseconds(1500))
    let presented = await player.measureVideo()
    let frameCounting = presented?.visibility == "visible"
    if frameCounting {
        check(await waitFor("decoder advancing") { player.videoActivity.decoding && player.videoActivity.frames >= 8 }, "with the picture on screen the decoder produces frames (getVideoPlaybackQuality)")
        note("frames=\(player.videoActivity.frames) advances=\(player.videoActivity.advances)")
    } else {
        print("SKIP frame positive control: the page's visibilityState is \"\(presented?.visibility ?? "?")\" in this session, so WebKit presents (and counts) no frames; live/visible check required")
    }

    let moved = await player.presentVideo(on: .window, host: playerHost)
    check(moved == .moved(from: .inline, to: .window), "the player window takes the picture from the preview in one step")
    check(inline.subviews.isEmpty && playerHost.subviews.count == 1, "exactly one surface holds the web view")
    let windowFacts = await player.measureVideo()
    check(windowFacts?.origin == origin, "moving the picture did not reload the document")
    let windowLayout = WebKitMusicPage.layoutSize(for: CGSize(width: 640, height: 360))
    check(windowFacts?.rect.count == 4 && abs(windowFacts!.rect[2] - windowLayout.width) < 1.5 && abs(windowFacts!.rect[3] - windowLayout.height) < 1.5, "the picture follows the new surface's size")
    check(player.snapshot.phase == .playing, "still playing after the move")
    let beforeFrames = player.videoActivity.frames, beforeTime = windowFacts?.time ?? 0
    try? await Task.sleep(for: .milliseconds(900))
    let afterMove = await player.measureVideo()
    check((afterMove?.time ?? 0) != beforeTime && afterMove?.paused == false, "the media kept playing through the move (same element, \(String(format: "%.1f", beforeTime)) s -> \(String(format: "%.1f", afterMove?.time ?? 0)) s)")
    if frameCounting { check(player.videoActivity.frames > beforeFrames + 4, "the same decoder keeps producing frames after the move") }
    let full = await player.presentVideo(on: .fullScreen, host: playerHost)
    check(full == .moved(from: .window, to: .fullScreen) && player.surfaces.activeSurfaces == 1, "full screen takes it from the window; one holder")
    await player.releaseVideo(.window)
    check(player.surfaces.holder == .fullScreen, "the window letting go of a picture it does not hold changes nothing")
    await player.releaseVideo(.fullScreen)
    check(player.surfaces.holder == nil && playerHost.subviews.isEmpty, "the last surface lets go: the web view is back in the hidden host")
    let restored = await player.measureVideo()
    check(restored?.presenting == false && restored?.hidden == 0 && restored?.styleInstalled == false, "the page presentation is switched off")
    check(restored?.digest == baseline?.digest, "the document markup is restored exactly")
    check(restored?.origin == origin && player.snapshot.phase == .playing, "never reloaded, still playing")

    // Picture in Picture only where WebKit says the element supports it, and an honest reason otherwise.
    let pip = await player.presentVideo(on: .pictureInPicture, host: nil)
    if player.snapshot.pictureInPicture == .available { note("WebKit reports Picture in Picture available; start result: \(String(describing: pip))"); await player.releaseVideo(.pictureInPicture) }
    else { check(pip == nil && (player.videoNotice ?? "").contains("not available"), "Picture in Picture is refused with a reason where WebKit does not support it") }

    // ---------------------------------------------------------------- 3. audio only = the song version; the decoder STOPS; position carried only for the published pair
    _ = await player.presentVideo(on: .window, host: playerHost)
    try? await Task.sleep(for: .milliseconds(1500))
    let carried = player.timeline.position
    let selection = await player.selectAudioOnly()
    guard case .success(.continued(let at)) = selection else { check(false, "audio-only is a continued switch for the published pair, got \(selection)"); return }
    check(at > 0.5, "the position to carry is the playing position (\(at))")
    check(await waitFor("song playing") { player.snapshot.videoID == "sOnGVersi01" && player.snapshot.representation == .audio && player.snapshot.phase == .playing }, "the service's audio version (the song) is playing")
    check(player.snapshot.pictureSize == nil && !player.snapshot.hasPicture, "the song holds no picture")
    check(player.surfaces.holder == nil && playerHost.subviews.isEmpty, "the video surface was let go before the switch, not covered")
    // Rework F3: "the decoder stopped" is claimed only where frames can be counted AND were seen advancing earlier. Where the document is hidden
    // the counter is 0 for the whole run, so a "not decoding" reading would be trivially true: report a SKIP, never an ok.
    if frameCounting {
        check(await waitFor("decoder stopped", seconds: 8) { !player.videoActivity.decoding }, "the video decoder stopped (frames that advanced before no longer advance)")
    } else {
        print("SKIP decoder-stopped check: the page's frame counter is unavailable in this session (document hidden), so it cannot show a stop; live/visible check required")
    }
    let songFacts = await player.measureVideo()
    check(songFacts?.present == true && songFacts?.pictureWidth == 0 && songFacts?.pictureHeight == 0, "fixture: the audio element holds no video track (0 x 0), a property of the fixture and not of YouTube's audio version")
    check(player.videoNotice == nil, "an audio version without a picture raises no notice")
    note("decoder after audio-only: decoding=\(player.videoActivity.decoding) frames=\(player.videoActivity.frames)\(frameCounting ? "" : " (frame counting unavailable in this session)")")
    check(await waitFor("carried position", seconds: 8) { player.timeline.position >= at - 0.6 && player.timeline.position < at + 6 }, "the position continued (carried \(String(format: "%.1f", at)) s, now \(String(format: "%.1f", player.timeline.position)) s)")
    check(player.snapshot.restart == nil, "no restart is reported for the published pair")
    _ = carried

    // Same title, no published relation: restart, never a silent mapping.
    let unrelated = await player.switchRepresentation(to: .init(asset: .youTubeMusic("sUnrelated1"), representation: .video))
    check(unrelated == .restart(.noPublishedCounterpart), "an unpublished asset is a restart, not a position-carrying switch")
    check(await waitFor("unrelated playing") { player.snapshot.videoID == "sUnrelated1" && player.snapshot.phase == .playing }, "the unrelated asset plays")
    check(await waitFor("restart reported") { player.snapshot.restart == .noPublishedCounterpart }, "the restart and its reason are reported")
    check(player.timeline.position < 3.5, "it started from the beginning (\(String(format: "%.1f", player.timeline.position)) s)")

    // ---------------------------------------------------------------- 4. teardown with a surface attached
    _ = await player.presentVideo(on: .window, host: playerHost)
    check(playerHost.subviews.count == 1, "a surface holds the page")
    await player.teardown()
    check(player.surfaces.holder == nil && playerHost.subviews.isEmpty && !player.hasPage, "account switch / quit: the surface lets go with the page, nothing keeps playing")

    // ---------------------------------------------------------------- 4b. an advertisement is shown, never covered
    let adPlayer = makePlayer()
    await adPlayer.play(playlistID: "PLsyntheticAd", title: "Ad probe")
    check(await waitFor("ad showing") { adPlayer.snapshot.isAd }, "the page's ad state is reported")
    check(await waitFor("ad picture") { adPlayer.snapshot.hasPicture }, "the ad's picture is available to be shown before the load is confirmed")
    let (adWindow, adHost) = host(480, 270, x: 720); _ = adWindow
    _ = await adPlayer.presentVideo(on: .window, host: adHost)
    let adFacts = await adPlayer.measureVideo()
    check(adFacts?.presenting == true && (adFacts?.adOverlayCount ?? 0) >= 1 && adFacts?.adOverlaysOnTop == true, "while an ad plays and the picture is presented, the ad layers are on top by hit test")
    await adPlayer.seek(30)
    check(adPlayer.refusal == .advertisement, "seeking during an ad is refused")
    await adPlayer.teardown()

    // ---------------------------------------------------------------- 5. live: window, clamp, Go live
    let live = makePlayer()
    await live.play(playlistID: "PLsyntheticLive", title: "Live probe")
    check(await waitFor("live playing") { live.snapshot.phase == .playing && live.snapshot.representation == .live }, "a live stream is reported as live")
    check(await waitFor("window") { live.snapshot.liveRewindable }, "the page's seekable window is rewindable")
    check(live.snapshot.isLive && live.snapshot.duration == 0, "no fixed duration for a live stream")
    check(await waitFor("at live edge") { live.snapshot.atLiveEdge }, "playback starts at the live edge")
    await live.seek(10_000)
    check(await waitFor("clamped to the edge") { live.snapshot.atLiveEdge && live.timeline.position >= 118 && live.timeline.position < 140 }, "a seek past the live edge is clamped to the live edge (\(String(format: "%.0f", live.timeline.position)) s)")
    await live.seek(60)
    check(await waitFor("seeked into the window") { live.timeline.position > 57 && live.timeline.position < 66 && !live.snapshot.atLiveEdge }, "a seek to 60 s of the window lands at 60 s of the window (the window's start is added back; \(String(format: "%.0f", live.timeline.position)) s)")
    await live.seek(10)
    check(await waitFor("rewound") { live.timeline.position < 30 && !live.snapshot.atLiveEdge }, "a seek into the window moves there and leaves the live edge (\(String(format: "%.0f", live.timeline.position)) s)")
    check(live.snapshot.canGoLive, "Go live is offered when behind the edge")
    check(await waitFor("behind live") { (live.timeline.behindLive ?? 0) > 80 }, "the distance behind live is published (\(String(format: "%.0f", live.timeline.behindLive ?? 0)) s)")
    await live.seek(-50)
    check(await waitFor("clamped to the start") { live.timeline.position < 6 }, "a seek before the window is clamped to its oldest point")
    await live.goLive()
    check(await waitFor("live again") { live.snapshot.atLiveEdge }, "Go live returns to the live edge")
    check(!live.snapshot.canGoLive, "and Go live is no longer offered")
    check(live.snapshot.phase == .playing, "still playing")
    await live.teardown()
    // The same live stream where the player offers no jump of its own: Go live uses the end of the seekable window.
    let bare = makePlayer()
    await bare.play(playlistID: "PLsyntheticLiveNoHead", title: "Live probe")
    check(await waitFor("bare live playing") { bare.snapshot.phase == .playing && bare.snapshot.isLive && bare.snapshot.liveRewindable }, "a live stream without seekToLiveHead plays")
    await bare.seek(20)
    check(await waitFor("bare rewound") { bare.timeline.position < 40 && !bare.snapshot.atLiveEdge && bare.snapshot.canGoLive }, "it can be rewound")
    await bare.goLive()
    check(await waitFor("bare live again") { bare.snapshot.atLiveEdge }, "Go live falls back to the end of the seekable window")
    await bare.teardown()
    for panel in panels { panel.close() }
    print("PASS")
    exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(240))
print("FAIL timeout")
exit(2)
