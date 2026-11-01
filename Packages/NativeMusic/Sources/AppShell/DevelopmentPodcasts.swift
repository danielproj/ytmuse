#if DEBUG
import AccountSession
import Features
import Foundation

/// Debug-only, labelled development data for the isolated W18 UI test: three episodes of the development show, the page of one of them, and
/// lyrics for three development songs (plain, none, and one that fails once). It exists only when `YTMUSE_UI_DEVELOPMENT_DATA=1` is set on an
/// isolated launch (the same gate as `DevelopmentCatalog`); nothing here is a capture of the service and no Release build contains it. The real
/// shapes are tested against `Fixtures/W18-real`. The placeholder lyrics below are invented text, not any song's lyrics.
enum DevelopmentPodcasts {
    static var enabled: Bool { DevelopmentCatalog.enabled }
    static let unplayed = "devepisode1", partlyPlayed = "devepisode2", played = "devepisode3"
    private static func browse(_ video: String) -> String { "MPED" + video }
    private static let showLink = MusicLink(kind: .podcast, title: "Cafe Talk (development)", browseID: DevelopmentCatalog.podcastID)

    static var episodes: [MusicCatalogItem] {
        [item(unplayed, "Brewing music (development)", ["3 views", "Oct 5"], "18 min", progress: 0),
         item(partlyPlayed, "Grinding beans (development)", ["9 views", "Oct 12"], "50 min", progress: 40),
         item(played, "Cleaning up (development)", ["1 view", "Oct 19"], "5 min", progress: 100)]
    }
    private static func item(_ video: String, _ title: String, _ details: [String], _ length: String, progress: Double) -> MusicCatalogItem {
        MusicCatalogItem(kind: .episode, title: title, details: details, videoID: video, browseID: browse(video), durationText: length,
                         episode: MusicEpisodeInfo(progressPercent: progress, durationText: length, playedLabelPublished: true, publishesServiceDownloadAction: true,
                                                   summary: "Development summary for " + title + "."))
    }

    /// The development episode page: part played by the service, a description with timestamps (chapters), and both Episodes-for-Later directions.
    @Sendable static func episodeReader(_ id: String) async throws -> MusicBrowseReply<MusicEpisodePage> {
        guard id == browse(partlyPlayed) else { throw MusicSessionError.unrecognised }
        var accounting = MusicEpisodeAccounting(); accounting.sections = 2; accounting.headerSections = 1; accounting.descriptionSections = 1
        let notes = "Development show notes.\n\n00:00 Welcome\n05:30 First topic\n20:15 Second topic\n45:00 Wrap up\n"
        let page = MusicEpisodePage(videoID: partlyPlayed, title: "Grinding beans (development)", details: ["9 views", "Oct 12"], show: showLink, thumbnails: [],
                                    description: [MusicTextRun(text: notes)], info: MusicEpisodeInfo(progressPercent: 40, durationText: "50 min", playedLabelPublished: true, publishesServiceDownloadAction: true),
                                    later: MusicEpisodeLater(videoID: partlyPlayed, isSaved: false, addPublished: true, removePublished: true), accounting: accounting)
        return MusicBrowseReply(value: page, mode: .anonymous, accountGeneration: 0)
    }

    static let plainSong = "devsong0001", noLyricsSong = "devsong0002", flakySong = "devsong0003"
    private static let placeholder = "Development line one\nDevelopment line two\n\nDevelopment line four"
    private static let flaky = Flaky()
    private actor Flaky { var failed = false; func shouldFail() -> Bool { defer { failed = true }; return !failed } }
    /// The song the lyrics panel shows when a launch asks for one (a Debug seam: no hidden player runs in an isolated UI launch).
    static var lyricsVideoOverride: String? {
        guard enabled else { return nil }
        return ProcessInfo.processInfo.environment["YTMUSE_UI_DEV_LYRICS_VIDEO"]
    }
    @Sendable static func lyricsReader(_ video: String) async throws -> MusicBrowseReply<MusicLyricsResult> {
        switch video {
        case plainSong: return MusicBrowseReply(value: .lyrics(MusicLyricsDocument(body: .plain(placeholder), sourceFooter: "Source: Development Lyrics")), mode: .anonymous, accountGeneration: 0)
        case noLyricsSong: return MusicBrowseReply(value: .none(.notOffered), mode: .anonymous, accountGeneration: 0)
        case flakySong:
            if await flaky.shouldFail() { throw MusicSessionError.network }
            return MusicBrowseReply(value: .lyrics(MusicLyricsDocument(body: .plain(placeholder), sourceFooter: "Source: Development Lyrics")), mode: .anonymous, accountGeneration: 0)
        default: throw MusicSessionError.unrecognised
        }
    }
}
#endif
