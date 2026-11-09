import AccountSession
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// The playing song's rating, read from the player overlay of its `next` answer. Every case starts from a REAL anonymous capture
/// (`MF-comments`, `R1-real`, `R2-real`, `W18-real`); the shapes no capture shows (a signed LIKE or DISLIKE, likes switched off, a button for
/// another song) are those captures with one value changed. No signed answer has been captured: that the signed overlay carries the
/// account's state in the same place is on the live check list (Docs/Library.md).
@Suite struct WatchRatingParserTests {
    private func capture(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent(path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    /// The capture with its overlay's like button edited by `change`.
    private func edited(_ path: String, _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var root = try capture(path)
        var overlays = try #require(root["playerOverlays"] as? [String: Any])
        var overlay = try #require(overlays["playerOverlayRenderer"] as? [String: Any])
        var actions = try #require(overlay["actions"] as? [[String: Any]])
        var like = try #require(actions[0]["likeButtonRenderer"] as? [String: Any])
        change(&like)
        actions[0]["likeButtonRenderer"] = like
        overlay["actions"] = actions; overlays["playerOverlayRenderer"] = overlay; root["playerOverlays"] = overlays
        return root
    }

    static let withButton: [(String, String)] = [
        ("W18-real/next-song.json", "khnokW3Mw24"), ("R1-real/next-radio.json", "Rgrt_8mXrK8"), ("R2-real/next-radio-artist.json", "Zgbfx0KLwUk"),
        ("MF-comments/next-khnokW3Mw24-de.json", "khnokW3Mw24"), ("MF-comments/next-e_04ZrNroTo.json", "e_04ZrNroTo"),
        ("MF-comments/next-WRVsOCh907o.json", "WRVsOCh907o"), ("MF-comments/next-XqZsoesa55w.json", "XqZsoesa55w"),
    ]
    @Test(arguments: WatchRatingParserTests.withButton) func everyRealCaptureWithAnOverlayButtonYieldsItsSongsRating(_ entry: (String, String)) throws {
        let like = try #require(try MusicWatchRatingParser.parse(try capture(entry.0), videoID: entry.1))
        #expect(like == .init(videoID: entry.1, status: .indifferent, dislikeExposed: true))
    }
    @Test func anOverlayWithoutALikeButtonIsNoRatingNotNotLiked() throws {
        // The same song captured twice: the English answer's overlay carries no actions, the German one carries the button.
        #expect(try MusicWatchRatingParser.parse(try capture("MF-comments/next-khnokW3Mw24.json"), videoID: "khnokW3Mw24") == nil)
        #expect(try MusicWatchRatingParser.parse(try capture("MF-comments/next-khnokW3Mw24-de.json"), videoID: "khnokW3Mw24") != nil)
    }
    @Test func noOverlayAtAllIsNoRating() throws {
        #expect(try MusicWatchRatingParser.parse(try capture("MF-comments/next-Qx7Lm2Zk9Vw.json"), videoID: "Qx7Lm2Zk9Vw") == nil)
    }
    @Test func theStateTheButtonCarriesIsTheRating() throws {
        for status in [MusicLikeStatus.like, .dislike, .indifferent] {
            let root = try edited("R2-real/next-radio-artist.json") { $0["likeStatus"] = status.rawValue }
            #expect(try MusicWatchRatingParser.parse(root, videoID: "Zgbfx0KLwUk")?.status == status)
        }
        let noDislike = try edited("R2-real/next-radio-artist.json") { $0["dislikeNavigationEndpoint"] = nil }
        #expect(try MusicWatchRatingParser.parse(noDislike, videoID: "Zgbfx0KLwUk")?.dislikeExposed == false)
    }
    @Test func likesSwitchedOffOffersNoRating() throws {
        let off = try edited("R2-real/next-radio-artist.json") { $0["likesAllowed"] = false }
        #expect(try MusicWatchRatingParser.parse(off, videoID: "Zgbfx0KLwUk") == nil)
    }
    @Test func aRatingIsNeverMovedFromOneSongToAnother() throws {
        // The answer is about another song than the one asked for.
        #expect(throws: MusicSessionError.unrecognised) { try MusicWatchRatingParser.parse(try capture("R2-real/next-radio-artist.json"), videoID: "khnokW3Mw24") }
        // The button names another song than the answer.
        let other = try edited("R2-real/next-radio-artist.json") { $0["target"] = ["videoId": "khnokW3Mw24"] }
        #expect(throws: MusicSessionError.unrecognised) { try MusicWatchRatingParser.parse(other, videoID: "Zgbfx0KLwUk") }
    }
    @Test func anUnreadableButtonOrAnswerIsAnErrorNeverARating() throws {
        let unknown = try edited("R2-real/next-radio-artist.json") { $0["likeStatus"] = "LOVE" }
        #expect(throws: MusicSessionError.unrecognised) { try MusicWatchRatingParser.parse(unknown, videoID: "Zgbfx0KLwUk") }
        var twice = try capture("R2-real/next-radio-artist.json")
        var overlays = try #require(twice["playerOverlays"] as? [String: Any]), overlay = try #require(overlays["playerOverlayRenderer"] as? [String: Any])
        let actions = try #require(overlay["actions"] as? [[String: Any]])
        overlay["actions"] = actions + actions; overlays["playerOverlayRenderer"] = overlay; twice["playerOverlays"] = overlays
        #expect(throws: MusicSessionError.unrecognised) { try MusicWatchRatingParser.parse(twice, videoID: "Zgbfx0KLwUk") }
        var failed = try capture("R2-real/next-radio-artist.json"); failed["error"] = ["code": 400]
        #expect(throws: MusicSessionError.unrecognised) { try MusicWatchRatingParser.parse(failed, videoID: "Zgbfx0KLwUk") }
        // A browse page is not a watch answer, even though it carries like buttons in its rows.
        #expect(throws: MusicSessionError.unrecognised) { try MusicWatchRatingParser.parse(try capture("W11-real/browse-album.json"), videoID: "Zgbfx0KLwUk") }
    }
}
