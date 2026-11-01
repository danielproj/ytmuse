import Foundation
import Testing
@testable import Playback
@testable import AppShell

// P17-WEB test support. Synthetic values only: a fake hidden page, manual clocks, no real session, cookie, page or network.

/// Manual clocks for the hidden player's sleep timer. The wall clock decides the deadline, the monotonic clock paces the fade; `jumpWall` moves only
/// the wall (a clock change, or time asleep), `advance` moves both. With `loop: false` the test drives the evaluation itself with `sleepTimerTick()`;
/// with `loop: true` the timer's own task runs in VIRTUAL time: every wait moves both clocks by the wait and yields, so a 5-second fade takes no real time.
@MainActor final class ManualSleepTiming: SleepTimerTiming {
    private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var seconds = 0.0
    private(set) var waits: [Double] = []
    let runsLoop: Bool
    init(loop: Bool = false) { runsLoop = loop }
    func wall() -> Date { now }
    func monotonic() -> Double { seconds }
    func wait(_ interval: Double) async { waits.append(interval); advance(interval); await Task.yield() }
    func advance(_ interval: Double) { now = now.addingTimeInterval(interval); seconds += interval }
    func jumpWall(_ interval: Double) { now = now.addingTimeInterval(interval) }
}

/// The factors a page was asked to fade to, in order (a factor of 1 is "put the level back").
@MainActor func fadeFactors(_ page: FakeMusicPage) -> [Double] {
    page.commands.filter { $0.body == WebMusicScripts.fadeVolume }.compactMap { $0.arguments["factor"] as? Double }
}
/// The bodies of the commands the timer sent, named, so a sequence reads at a glance.
@MainActor func timerCommandNames(_ page: FakeMusicPage) -> [String] {
    page.commands.map { command -> String in
        switch command.body {
        case WebMusicScripts.fadeVolume: "fade(\(String(format: "%.2f", command.arguments["factor"] as? Double ?? -1)))"
        case WebMusicScripts.pause: "pause"
        case WebMusicScripts.play: "play"
        case WebMusicScripts.seek: "seek"
        case WebMusicScripts.skip: "skip"
        case WebMusicScripts.volume: "volume"
        case WebMusicScripts.loadPlaylist: "loadPlaylist"
        case WebMusicScripts.loadTarget: "loadTarget"
        default: "other"
        }
    }
}

/// A player on a fake page, playing an item of `duration` seconds at `position`, with manual sleep-timer clocks.
@MainActor func sleepTimerPlayer(timing: ManualSleepTiming = ManualSleepTiming(), position: Double = 10, duration: Double = 200,
                                 ad: Bool = false) async throws -> (WebMusicPlayer, FakeMusicPage, ManualSleepTiming) {
    var created: FakeMusicPage?
    let player = WebMusicPlayer(cookies: FakeCookieSource(), artwork: NoArtwork(), loadTimeout: .seconds(60), rotationDelay: .milliseconds(20), sleepTiming: timing) { delegate in
        let page = FakeMusicPage(delegate: delegate); created = page; return page
    }
    await player.play(playlistID: "PLsyntheticSleep", title: "Synthetic Mix")
    let page = try #require(created)
    page.commitLast()
    page.send(lifecycleState(position: position, duration: duration, ad: ad, playlist: "PLsyntheticSleep"))
    #expect(player.snapshot.phase == .playing)
    return (player, page, timing)
}
/// One position report of the playing item, as the page sends them a few times a second.
@MainActor func reportPosition(_ page: FakeMusicPage, _ position: Double, duration: Double = 200, video: String = lifecycleVideo, playing: Bool = true, ad: Bool = false) {
    page.send(lifecycleState(playing: playing, position: position, duration: duration, video: video, ad: ad, playlist: "PLsyntheticSleep"))
}
/// Lets the timer's own task run (virtual time) until `condition` holds.
@MainActor func settleTimer(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<2000 where !condition() { await Task.yield() }
}
