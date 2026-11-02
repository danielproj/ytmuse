import AccountSession
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AppShell
@testable import Features
@testable import Playback

// W18-F1: the speed and jump controls must reach the player bar. The real BrowserShell is hosted (a test process is isolated: no account, no store,
// no network), a fake hidden page plays an episode, and the accessibility tree is read for the controls' identifiers.

private let site = WebMusicFrame(isMainFrame: true, scheme: "https", host: "music.youtube.com", port: 0)
private let episodeID = "AzENYaFVxGg", songID = "khnokW3Mw24"

@MainActor private final class BarPage: WebMusicPage {
    weak var delegate: (any WebMusicPageDelegate)?
    var loads: [URL] = []
    var commands: [WebMusicCommand.Invocation] = []
    var rateReply = WebMusicCommandReply.ok
    init(delegate: any WebMusicPageDelegate) { self.delegate = delegate }
    func install(cookies: [HTTPCookie]) async {}
    func load(_ url: URL) { loads.append(url) }
    func run(_ invocation: WebMusicCommand.Invocation) async -> WebMusicCommandReply { commands.append(invocation); return invocation.body == WebMusicScripts.rate ? rateReply : .ok }
    func setThrottled(_ throttled: Bool) {}
    func teardown() async {}
    func commit() { delegate?.pageCommitted(document: WebMusicNavigation.document(of: loads.last)) }
    func send(_ body: [String: Any]) { delegate?.page(received: body, from: site) }
    var seekValues: [Double] { commands.filter { $0.body == WebMusicScripts.seek }.compactMap { $0.arguments["seconds"] as? Double } }
}
private actor BarCookies: WebMusicCookieSource {
    func playerCookies() async throws -> [HTTPCookie] { [HTTPCookie(properties: [.name: "SAPISID", .value: "SYNTHETIC", .domain: ".youtube.com", .path: "/", .secure: "TRUE"])!] }
    func recordRotation(_ cookies: [HTTPCookie]) async {}
}
private struct BarArt: WebMusicArtworkLoading { func artwork(_ url: URL) async -> Data? { nil } }
private func state(_ video: String, position: Double = 100) -> [String: Any] {
    ["type": "state", "doc": 1, "load": 1, "playing": true, "buffering": false, "position": position, "duration": 1800.0, "videoId": video, "title": "Synthetic",
     "artist": "Synthetic", "artwork": "https://lh3.googleusercontent.com/x", "ad": false]
}
/// The focusable controls SwiftUI placed in the player bar, as AppKit sees them: the hosting view's direct `KeyViewProxy` children (one per control that
/// can take keyboard focus), left to right. (SwiftUI builds its accessibility tree only for an assistive client, so the view hierarchy is the oracle here.)
@MainActor private func barControls(_ host: NSView) -> [CGRect] {
    let height = host.bounds.height
    return host.subviews.filter { String(describing: type(of: $0)).contains("KeyViewProxy") && $0.frame.minY > height - 160 }.map(\.frame).sorted { $0.minX < $1.minX }
}

/// The pop-up menus SwiftUI placed in the player bar band (`SwiftUIPopupButton`, hosted inside AppKit platform views): the speed menu and the skip-length menu.
@MainActor private func barMenus(_ host: NSView) -> [NSPopUpButton] {
    var found: [NSPopUpButton] = []
    func walk(_ view: NSView) {
        for child in view.subviews {
            if let popup = child as? NSPopUpButton, child.convert(child.bounds, to: host).minY > host.bounds.height - 160 { found.append(popup) }
            walk(child)
        }
    }
    walk(host)
    return found.sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
}

@MainActor private struct Rig {
    let accounts: LocalAccountBootstrap
    let player: WebMusicPlayer
    let page: BarPage
    let window: NSWindow
    let host: NSHostingView<AnyView>
}
/// `registered`: the episode the podcast model has registered BEFORE the shell is hosted (nil: none). It may differ from the item that plays.
@MainActor private func rig(playing video: String, isEpisode: Bool, registered: String? = nil, chosenRate: Double? = nil, pageRefusesSpeed: Bool = false) async throws -> Rig {
    let accounts = LocalAccountBootstrap()
    var created: BarPage?
    let player = WebMusicPlayer(cookies: BarCookies(), artwork: BarArt(), loadTimeout: .seconds(60), rotationDelay: .milliseconds(20)) { delegate in
        let page = BarPage(delegate: delegate); created = page; return page
    }
    await player.play(playlistID: "PLsynthetic", title: "Synthetic")
    let page = try #require(created)
    if pageRefusesSpeed { page.rateReply = .rejected }
    page.commit(); page.send(state(video))
    #expect(player.snapshot.phase == .playing && player.snapshot.videoID == video)
    accounts.playback.music = player
    if let chosenRate { await accounts.podcasts.playback.setRate(chosenRate, forShow: "MPSPPLshowAAAAAAA") }
    if let registered = registered ?? (isEpisode ? video : nil) { accounts.podcasts.playback.episodeStarting(videoID: registered, show: "MPSPPLshowAAAAAAA", playlistID: "PLsynthetic") }
    let shell = AnyView(BrowserShell(accounts: accounts))
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1240, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: shell)
    window.contentView = host; window.ignoresMouseEvents = true; window.alphaValue = 0; window.orderFrontRegardless()
    for _ in 0..<25 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
    return Rig(accounts: accounts, player: player, page: page, window: window, host: host)
}

/// What the capsule's ⋯ menu offers for what `rig` hosted: the episode's controls only while the item that plays is the registered episode.
@MainActor private func moreItems(_ rig: Rig) -> [CapsuleMoreItem] {
    let episode = rig.accounts.podcasts.playback.current.map { $0.videoID == rig.player.snapshot.videoID } ?? false
    return WebCapsuleSecondary.moreItems(state: rig.player.snapshot, hasSleepTimer: true, canShowVideo: true, episode: episode)
}

// PLAYER-1: the floating capsule keeps its transport row to the glyphs a song needs; an episode's skip buttons, speed menu and skip-length menu moved into
// the ⋯ menu (the old bar grew two controls and two menus). A menu SwiftUI builds on click cannot be read from AppKit, so the choice of what ⋯ offers is a
// pure function (`WebCapsuleSecondary.moreItems`) that the view renders, and these tests state it for the hosted shell's own player and podcast model.
@MainActor @Suite struct PlayerControlsInjectionTests {
    @Test func whileAnEpisodePlaysTheMoreMenuOffersTheEpisodeControlsAndTheBarGrowsNothing() async throws {
        let episode = try await rig(playing: episodeID, isEpisode: true)
        defer { episode.window.orderOut(nil); withExtendedLifetime(episode.accounts) {} }
        let song = try await rig(playing: episodeID, isEpisode: false)       // the same item, NOT registered as an episode
        defer { song.window.orderOut(nil); withExtendedLifetime(song.accounts) {} }
        #expect(barControls(song.host).count >= 4, "the bar itself is hosted and its transport is there: \(barControls(song.host))")
        #expect(barControls(episode.host).count == barControls(song.host).count, "the capsule's row is the same for an episode: \(barControls(episode.host)) | \(barControls(song.host))")
        #expect(moreItems(episode).contains(.episodeControls) && !moreItems(song).contains(.episodeControls))
    }
    @Test func aSongShowsNoneOfThem() async throws {
        let song = try await rig(playing: songID, isEpisode: false)
        defer { song.window.orderOut(nil); withExtendedLifetime(song.accounts) {} }
        let plain = try await rig(playing: episodeID, isEpisode: false)
        defer { plain.window.orderOut(nil); withExtendedLifetime(plain.accounts) {} }
        #expect(barControls(song.host).count == barControls(plain.host).count && barControls(song.host).count >= 4)
        #expect(!moreItems(song).contains(.episodeControls) && !moreItems(plain).contains(.episodeControls))
    }
    /// A: the episode is registered BEFORE the shell is hosted, but the item playing is a song (the player moved on): nothing is offered. (Registering after
    /// hosting would never reach the off-screen host, so the case could not fail.)
    @Test func aRegisteredEpisodeThatIsNotTheItemPlayingOffersNothing() async throws {
        let song = try await rig(playing: songID, isEpisode: false)
        defer { song.window.orderOut(nil); withExtendedLifetime(song.accounts) {} }
        let moved = try await rig(playing: songID, isEpisode: false, registered: episodeID)
        defer { moved.window.orderOut(nil); withExtendedLifetime(moved.accounts) {} }
        #expect(moved.accounts.podcasts.playback.current?.videoID == episodeID && moved.player.snapshot.videoID == songID, "the case is what it says: an episode is registered and a song plays")
        #expect(barControls(moved.host).count == barControls(song.host).count && barControls(song.host).count >= 4)
        #expect(!moreItems(moved).contains(.episodeControls))
    }
    @Test func theMoreMenuListsWhatHasNoSlotOfItsOwn() async throws {
        var live = WebMusicSnapshot(); live.representation = .live
        #expect(WebCapsuleSecondary.moreItems(state: live, hasSleepTimer: true, canShowVideo: false, episode: false) == [.sleepTimer, .goLive])
        #expect(WebCapsuleSecondary.moreItems(state: live, hasSleepTimer: false, canShowVideo: false, episode: true) == [.goLive, .episodeControls])
    }
    /// The speed menu is labelled with the ACTUAL speed (the page refused 1.5×, so the element stays at 1× while 1.5× is the show's choice), and the capsule
    /// hands the menu the player's confirmed rate.
    @Test func theSpeedMenuIsLabelledWithTheActualSpeedNotTheChoice() async throws {
        let episode = try await rig(playing: episodeID, isEpisode: true, chosenRate: 1.5, pageRefusesSpeed: true)
        defer { episode.window.orderOut(nil); withExtendedLifetime(episode.accounts) {} }
        for _ in 0..<10 { episode.host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        #expect(episode.player.confirmedRate == 1 && episode.accounts.podcasts.playback.rate(forShow: "MPSPPLshowAAAAAAA") == 1.5)
        #expect(PodcastRateDisplay(chosen: 1.5, actual: episode.player.confirmedRate).title == "1×", "what is playing, not what was chosen")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let views = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/PlayerCapsuleViews.swift"), encoding: .utf8)
        #expect(views.contains("actual: player.confirmedRate"), "the capsule passes the actual speed to the speed menu")
    }
    @Test func theControlsCallTheSharedModel() async throws {
        let episode = try await rig(playing: episodeID, isEpisode: true)
        defer { episode.window.orderOut(nil); withExtendedLifetime(episode.accounts) {} }
        // The bar's skip buttons act on `accounts.podcasts.playback` (the only model there is): its jump moves the hidden page.
        let model = episode.accounts.podcasts.playback
        #expect(await model.skipForward())
        #expect(episode.page.seekValues.last == 130, "100 s + the default 30 s forward, sent to the page")
        #expect(await model.skipBack())
        #expect(episode.page.seekValues.suffix(2) == [130, 70] || episode.page.seekValues.last != 130, "the second jump is another seek: \(episode.page.seekValues)")
    }
    @Test func theBarAndTheDetailPagesShareTheBootstrapsOneSurfaceAndOneModel() async throws {
        let accounts = LocalAccountBootstrap()
        defer { withExtendedLifetime(accounts) {} }
        #expect(accounts.podcasts === accounts.podcasts && accounts.podcasts.playback === accounts.podcasts.playback)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/BrowserShell.swift"), encoding: .utf8)
        #expect(shell.contains(".environment(\\.podcastsSurface, accounts.podcasts)"), "injected at the root from the bootstrap's own surface")
        #expect(shell.components(separatedBy: "\\.podcastsSurface").count - 1 == 1, "once")
    }
}
