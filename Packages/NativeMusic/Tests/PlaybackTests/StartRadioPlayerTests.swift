import Foundation
import Testing
import AccountSession
@testable import Playback
import Features

// Synthetic, sanitized values only: no real session, cookie, page or network. The ids have the shape of a real album track and its published radio.

/// CORE-B rework 1 (F1): a Start Radio from a row is driven through the real `WebMusicPlayer` over a fake page, with the target the production plan produces.
/// The service's radio flag (`wAEB`) must never reach the player as parameters: the player treats any parameters as a shuffle that has to show in the page.
@Suite @MainActor struct StartRadioPlayerTests {
    private static let album = "OLAK5uy_albumList0001"
    private static let video = "radioSeed01"
    private static let radioList = "RDAMVMradioSeed01"
    private static let frame = WebMusicFrame(isMainFrame: true, scheme: "https", host: "music.youtube.com", port: 0)

    private func row() -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: "Track", videoID: Self.video, contextPlaylistID: Self.album,
                         radio: MusicRadioAction(playlistID: Self.radioList, videoID: Self.video, params: "wAEB"))
    }
    private func sample(load: Int, playlist: String, video: String = StartRadioPlayerTests.video, shuffle: Bool? = nil) -> [String: Any] {
        var body: [String: Any] = ["type": "state", "doc": 1, "load": load, "playing": true, "buffering": false, "position": 10.0, "duration": 200.0,
                                   "videoId": video, "title": "Synthetic Song", "artist": "Synthetic Artist", "artwork": "https://lh3.googleusercontent.com/synthetic-art",
                                   "ad": false, "playlistId": playlist]
        if let shuffle { body["shuffle"] = shuffle }
        return body
    }
    private func makePlayer(timeout: Duration = .seconds(60)) -> (WebMusicPlayer, () -> FakeMusicPage?) {
        var created: FakeMusicPage?
        let player = WebMusicPlayer(cookies: FakeCookieSource(), artwork: NoArtwork(), loadTimeout: timeout, rotationDelay: .milliseconds(20),
                                    shuffleAttempts: 5, shuffleInterval: .milliseconds(5)) { delegate in
            let page = FakeMusicPage(delegate: delegate); created = page; return page
        }
        return (player, { created })
    }
    /// What the app's performer does with an offered Start Radio: hands its target to the player.
    private func startRadio(_ player: WebMusicPlayer, _ item: MusicCatalogItem) async throws {
        let target = try #require(CatalogActionPlan.target(for: .radio, on: item), "the row's Start Radio target")
        #expect(target.params == nil, "no parameters reach the player")
        await player.play(playlistID: target.playlistID, title: item.title, videoID: target.videoID, params: target.params)
    }
    private func lastLoad(_ fake: FakeMusicPage) -> Int { fake.commands.last?.arguments["load"] as? Int ?? -1 }

    /// A. Another playlist is playing; the page then reports the radio.
    @Test func startRadioWhileAnotherPlaylistPlaysStartsAndConfirms() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(sample(load: 1, playlist: "PLsynthetic", video: "SYNTHvid001"))
        #expect(player.snapshot.phase == .playing)
        try await startRadio(player, row())
        let command = try #require(fake.commands.last)
        #expect(command.body == WebMusicScripts.loadTarget && command.arguments["playlistId"] as? String == Self.radioList && command.arguments["videoId"] as? String == Self.video)
        #expect((command.arguments["params"] as? String ?? "").isEmpty, "the router is not given the radio flag")
        fake.send(sample(load: lastLoad(fake), playlist: Self.radioList))
        #expect(player.snapshot.phase == .playing && player.snapshot.playlistID == Self.radioList && !player.snapshot.isFailed)
        #expect(fake.tornDown == 0)
    }
    /// B. The page's own shuffle button reports "off" while the radio plays: a radio is not a shuffle, and that is not a failure.
    @Test func startRadioConfirmsWhenThePageReportsShuffleOff() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: "PLsynthetic", title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(sample(load: 1, playlist: "PLsynthetic", video: "SYNTHvid001"))
        try await startRadio(player, row())
        fake.send(sample(load: lastLoad(fake), playlist: Self.radioList, shuffle: false))
        #expect(player.snapshot.phase == .playing && !player.snapshot.isFailed)
        #expect(fake.tornDown == 0)
    }
    /// C. The song's own radio is already playing: Start Radio, once or twice, keeps playing and never drops the page.
    @Test func startRadioOnTheRadioThatIsAlreadyPlayingKeepsPlaying() async throws {
        let (player, page) = makePlayer()
        await player.play(playlistID: Self.radioList, title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(sample(load: 1, playlist: Self.radioList))
        #expect(player.snapshot.phase == .playing)
        for _ in 0..<2 {
            try await startRadio(player, row())
            fake.send(sample(load: lastLoad(fake), playlist: Self.radioList, video: "SYNTHvid002"))
            #expect(player.snapshot.phase == .playing && !player.snapshot.isFailed, "\(player.snapshot.phase)")
        }
        #expect(fake.tornDown == 0, "pressing Start Radio twice does not stop playback")
    }
    /// The reason the flag is never sent: as parameters it is a shuffle, which a radio never confirms. This is the failure the fix avoids.
    @Test func theRadioFlagAsParametersWouldHaveFailedTheStartAndDroppedThePage() async throws {
        let (player, page) = makePlayer(timeout: .milliseconds(300))
        await player.play(playlistID: Self.radioList, title: nil)
        let fake = try #require(page()); fake.commitLast(); fake.send(sample(load: 1, playlist: Self.radioList))
        fake.intercept = { [self] invocation in
            if invocation.body == WebMusicScripts.loadTarget, let load = invocation.arguments["load"] as? Int {
                let reply = sample(load: load, playlist: Self.radioList, video: "SYNTHvid002")
                Task { @MainActor in fake.send(reply) }
            }
            return nil
        }
        await player.play(playlistID: Self.radioList, title: nil, videoID: Self.video, params: "wAEB")
        #expect(player.snapshot.phase == .failed(.shuffleFailed), "\(player.snapshot.phase)")
    }
}
