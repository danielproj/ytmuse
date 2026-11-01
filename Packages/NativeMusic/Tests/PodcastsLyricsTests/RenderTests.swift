import AccountSession
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AppShell
@testable import Features
@testable import YouTubeMusicAdapter

/// Headless render checks: each new view is hosted in an off-screen window, laid out and drawn. They show the views build and draw something
/// at real sizes; they are not the native UI run (the console is locked, so that part is pending) and prove nothing about interaction.
@MainActor private func render<V: View>(_ view: V, width: CGFloat = 420, height: CGFloat = 520) async throws -> (window: NSWindow, distinctColors: Int, fitting: CGSize) {
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
    let hosting = NSHostingView(rootView: view)
    window.contentView = hosting; window.ignoresMouseEvents = true; window.alphaValue = 0; window.orderFrontRegardless()
    for _ in 0..<15 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    var colors = Set<UInt32>()
    if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) { for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                colors.insert(UInt32(c.redComponent * 255) << 24 | UInt32(c.greenComponent * 255) << 16 | UInt32(c.blueComponent * 255) << 8 | UInt32(c.alphaComponent * 255))
            }
        } }
    }
    return (window, colors.count, hosting.fittingSize)
}
private let plainDocument = MusicLyricsDocument(body: .plain("First line\nSecond line\n\nFourth line"), sourceFooter: "Source: Musixmatch")
private func timedDocument() -> MusicLyricsDocument {
    MusicLyricsDocument(body: .timed((0..<30).map { MusicTimedLyricLine(text: "Placeholder line \($0)", start: Double($0) * 4, end: nil) }), sourceFooter: "Source: Example")
}
@MainActor private func lyricsModel(_ result: Result<MusicLyricsResult, MusicSessionError>) async -> (LyricsModel, LyricsFollowModel) {
    let model = LyricsModel(reader: { _ in
        switch result { case .success(let value): MusicBrowseReply(value: value, mode: .anonymous, accountGeneration: 1); case .failure(let error): throw error }
    })
    await model.show(videoID: "khnokW3Mw24")
    return (model, LyricsFollowModel(seek: { _ in true }, canSeek: { true }))
}

@MainActor @Suite struct LyricsPanelRenderTests {
    @Test(arguments: [("plain", Result<MusicLyricsResult, MusicSessionError>.success(.lyrics(plainDocument))),
                      ("unavailable", .success(.none(.notOffered))), ("failed", .failure(.network))])
    func eachStateDrawsAtTheSidePanelsWidths(_ name: String, _ result: Result<MusicLyricsResult, MusicSessionError>) async throws {
        let (model, follow) = await lyricsModel(result)
        for width in [300.0, 420.0] {
            let output = try await render(LyricsPanelView(model: model, follow: follow, videoID: "khnokW3Mw24", position: { 0 }), width: width, height: 480)
            defer { output.window.orderOut(nil) }
            #expect(output.distinctColors > 3, Comment(rawValue: "\(name) at \(width) drew nothing"))
        }
    }
    @Test func theTimedPanelDrawsAndStartsOnTheCurrentLine() async throws {
        let (model, follow) = await lyricsModel(.success(.lyrics(timedDocument())))
        let output = try await render(LyricsPanelView(model: model, follow: follow, videoID: "khnokW3Mw24", position: { 61 }), width: 360, height: 400)
        defer { output.window.orderOut(nil) }
        #expect(output.distinctColors > 3)
        #expect(follow.lines.count == 30 && follow.current == 15, "61 s is inside the line that started at 60 s")
        #expect(follow.shown == 15 && follow.mode == .following, "the panel scrolled to it")
    }
    @Test func theIdlePanelSaysNothingIsPlaying() async throws {
        let model = LyricsModel(reader: { _ in throw MusicSessionError.policy })
        let output = try await render(LyricsPanelView(model: model, follow: LyricsFollowModel(), videoID: nil, position: { 0 }), width: 320, height: 300)
        defer { output.window.orderOut(nil) }
        #expect(output.distinctColors > 3 && model.state == .idle)
    }
}

@MainActor @Suite struct EpisodeScreenRenderTests {
    private func surface(page: MusicEpisodePage?) async -> PodcastsSurface {
        let (playback, _, _, _) = await makeModel()
        return PodcastsSurface(playback: playback, lyrics: LyricsModel(reader: { _ in throw MusicSessionError.policy }), follow: LyricsFollowModel(), ledger: nil,
                               reader: { _ in
                                   guard let page else { throw MusicSessionError.network }
                                   return MusicBrowseReply(value: page, mode: .anonymous, accountGeneration: 1)
                               }, starter: { _ in .started })
    }
    @Test func theRealEpisodePageDrawsWithItsActionsAndTheDownloadExplanation() async throws {
        let page = try MusicEpisodeParser_parse(.episode)
        let surface = await surface(page: page)
        let model = surface.page(forBrowseID: "MPEDAzENYaFVxGg")
        await model.load()
        let output = try await render(EpisodeDetailView(model: model, surface: surface, navigator: CatalogNavigator()), width: 760, height: 640)
        defer { output.window.orderOut(nil) }
        #expect(output.distinctColors > 5 && model.page != nil)
        // This page published the show; Play starts from the show's playlist and is therefore available.
        #expect(EpisodePlayTargets.request(videoID: page.videoID, title: page.title, showBrowseID: page.show?.browseID) != nil)
    }
    @Test func aFailedPageDrawsTheFailureNotAnEmptyEpisode() async throws {
        let surface = await surface(page: nil)
        let model = surface.page(forBrowseID: "MPEDAzENYaFVxGg")
        await model.load()
        let output = try await render(EpisodeDetailView(model: model, surface: surface, navigator: CatalogNavigator()), width: 600, height: 400)
        defer { output.window.orderOut(nil) }
        #expect(output.distinctColors > 3)
        if case .failed(let failure) = model.phase { #expect(failure == .offline) } else { Issue.record("expected a failed phase") }
    }
    @Test func theTransportControlsDrawWithTheChosenLengths() async throws {
        let (playback, _, _, _) = await makeModel()
        #expect(playback.setSkip(back: 10, forward: 45))
        let output = try await render(PodcastTransportControls(playback: playback, rate: 1.5), width: 360, height: 60)
        defer { output.window.orderOut(nil) }
        #expect(output.distinctColors > 2)
    }
    @Test func theRowExtrasDrawForTheRealRowsAndAreInertWithoutASurface() async throws {
        let item = try #require(try MusicBrowseParser.parse(try real(.show)).shelves.flatMap(\.items).first { $0.kind == .episode })
        let surface = await surface(page: nil)
        let with = try await render(EpisodeRowExtras(item: item, show: "MPSPPLZr1D7YmlHJw", showPlaylist: nil, readAt: Date()).environment(\.podcastsSurface, surface), width: 600, height: 80)
        defer { with.window.orderOut(nil) }
        let without = try await render(EpisodeRowExtras(item: item, show: "MPSPPLZr1D7YmlHJw", showPlaylist: nil, readAt: Date()), width: 600, height: 80)
        defer { without.window.orderOut(nil) }
        #expect(with.distinctColors >= without.distinctColors && with.distinctColors > 1)
    }
}

@MainActor @Suite struct PodcastsCompositionTests {
    @Test func theBootstrapOffersOneSurfaceWiredToTheOnePlaybackOwner() {
        let accounts = LocalAccountBootstrap()
        #expect(accounts.podcasts === accounts.podcasts, "created once, shared by every window")
        #expect(accounts.playback.episodeObserver != nil, "the player's readings reach the podcast controls")
        #expect(accounts.podcasts.ledger === accounts.library.ledger, "Episodes for Later goes through the Library's ledger")
    }
    @Test func theEpisodePlayerAdapterReportsNothingWhenThereIsNoPlayer() {
        // The bootstrap's own owner (a test process is isolated: it has no production store and no hidden player until Play is pressed).
        let accounts = LocalAccountBootstrap()
        let adapter = WebMusicEpisodePlayer(playback: accounts.playback)
        defer { withExtendedLifetime(accounts) {} }
        #expect(adapter.reading.videoID == nil && !adapter.reading.canSeek && adapter.confirmedRate == 1)
    }
    @Test func theEpisodePlayerAdapterRefusesWithoutAPlayer() async {
        let accounts = LocalAccountBootstrap()
        let adapter = WebMusicEpisodePlayer(playback: accounts.playback)
        defer { withExtendedLifetime(accounts) {} }
        let moved = await adapter.seek(to: 10), changed = await adapter.setRate(1.5)
        #expect(!moved && !changed)
    }
}
