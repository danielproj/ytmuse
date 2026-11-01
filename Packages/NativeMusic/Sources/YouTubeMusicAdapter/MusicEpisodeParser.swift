import AccountSession
import Foundation

/// Reads a podcast episode page (`browse MPED…`) into a typed page.
///
/// Built on the real anonymous capture in `Fixtures/W18-real`. Everything the parser meets is accounted for in `MusicEpisodeAccounting`: a
/// section is the header, the description or unsupported; a header button and a menu item is recognised or ignored BY NAME. A page without
/// a header and a play target is `.unrecognised`, never an empty episode.
///
/// Internal notes (not surfaced anywhere): the header (title, byline, progress, buttons) is the first column's only section; the description is
/// the secondary column's `musicDescriptionShelfRenderer`. The "Download" menu item is parsed only to be counted and to record that the service
/// publishes its own offline action; it never becomes a control. The remove side of the Episodes-for-Later toggle that the service publishes also
/// carries `ACTION_REMOVE_WATCHED_VIDEOS` (clears every watched episode from the list); the write this app sends names the one episode only.
public enum MusicEpisodeParser {
    static let laterPlaylistID = "SE"

    public static func parse(_ root: [String: Any]) throws(MusicSessionError) -> MusicEpisodePage {
        guard root["error"] == nil, let contents = root["contents"] as? [String: Any],
              let two = contents["twoColumnBrowseResultsRenderer"] as? [String: Any] else { throw .unrecognised }
        var accounting = MusicEpisodeAccounting()
        var header: [String: Any]?
        var description: [MusicTextRun] = []
        func countSection(_ entry: [String: Any], primary: Bool) {
            accounting.sections += 1
            if primary, header == nil, let renderer = entry["musicResponsiveHeaderRenderer"] as? [String: Any] {
                header = renderer; accounting.headerSections += 1
            } else if !primary, let shelf = entry["musicDescriptionShelfRenderer"] as? [String: Any] {
                description += descriptionRuns(shelf["description"]); accounting.descriptionSections += 1
            } else { accounting.unsupportedSections += 1 }
        }
        for tab in two["tabs"] as? [[String: Any]] ?? [] {
            let list = ((tab["tabRenderer"] as? [String: Any])?["content"] as? [String: Any])?["sectionListRenderer"] as? [String: Any]
            for entry in list?["contents"] as? [[String: Any]] ?? [] { countSection(entry, primary: true) }
        }
        let secondary = (two["secondaryContents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any]
        for entry in secondary?["contents"] as? [[String: Any]] ?? [] { countSection(entry, primary: false) }
        guard let header, let title = MusicBrowseParser.plain(header["title"]) else { throw .unrecognised }

        var videoID: String?
        var show: MusicLink?
        var downloadPublished = false
        var toggleSides: [[String: Any]] = []
        for button in header["buttons"] as? [[String: Any]] ?? [] {
            accounting.buttons += 1
            if let toggle = button["toggleButtonRenderer"] as? [String: Any] {
                toggleSides.append(toggle); accounting.buttonsRecognised += 1
            } else if let play = button["musicPlayButtonRenderer"] as? [String: Any] {
                let target = MusicBrowseParser.endpoint(play["playNavigationEndpoint"])
                if target?.videoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" { videoID = target?.videoID }
                accounting.buttonsRecognised += 1
            } else if let menu = button["menuRenderer"] as? [String: Any] {
                accounting.buttonsRecognised += 1
                for item in menu["items"] as? [[String: Any]] ?? [] {
                    accounting.menuItems += 1
                    if let service = item["menuServiceItemRenderer"] as? [String: Any] {
                        let queue = (service["serviceEndpoint"] as? [String: Any])?["queueAddEndpoint"] as? [String: Any]
                        if queue != nil { accounting.menuRecognised += 1 } else { accounting.menuIgnored.append("menuServiceItemRenderer") }
                    } else if item["menuServiceItemDownloadRenderer"] != nil {
                        downloadPublished = true; accounting.menuRecognised += 1
                    } else if let navigation = item["menuNavigationItemRenderer"] as? [String: Any] {
                        let target = MusicBrowseParser.endpoint(navigation["navigationEndpoint"])
                        if target?.pageType == "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE", let id = target?.browseID {
                            let name = MusicBrowseParser.plain(navigation["text"]) ?? id
                            show = show ?? MusicLink(kind: .podcast, title: name, browseID: id)
                            accounting.menuRecognised += 1
                        } else {
                            let nav = navigation["navigationEndpoint"] as? [String: Any] ?? [:]
                            accounting.menuIgnored.append(nav["shareEntityEndpoint"] != nil ? "share" : nav["modalEndpoint"] != nil ? "modal" : "menuNavigationItemRenderer")
                        }
                    } else if item["toggleMenuServiceItemRenderer"] != nil {
                        accounting.menuIgnored.append("toggleMenuServiceItemRenderer")
                    } else { accounting.menuIgnored.append(item.keys.sorted().first ?? "unknown") }
                }
            } else { accounting.buttonsIgnored.append(button.keys.sorted().first ?? "unknown") }
        }
        guard let videoID else { throw .unrecognised }
        // The strapline names the show with its own link; it wins over the menu's "Go to podcast".
        if let link = MusicBrowseParser.runs(header["straplineTextOne"]).compactMap(MusicBrowseParser.link).first(where: { $0.kind == .podcast }) { show = link }
        guard accounting.consistent else { throw .unrecognised }

        let progress = (header["progress"] as? [String: Any])?["musicPlaybackProgressRenderer"] as? [String: Any]
        var info = MusicBrowseParser.episodeInfo(progress: progress, menu: nil) ?? MusicEpisodeInfo()
        if downloadPublished {
            info = MusicEpisodeInfo(progressPercent: info.progressPercent, durationText: info.durationText, hasPositionFeedbackToken: info.hasPositionFeedbackToken,
                                    playedLabelPublished: info.playedLabelPublished, publishesServiceDownloadAction: true, summary: info.summary)
        }
        let later = toggleSides.lazy.compactMap { laterControl($0, videoID: videoID) }.first
        return MusicEpisodePage(videoID: videoID, title: title, details: MusicBrowseParser.parts(MusicBrowseParser.runs(header["subtitle"])).map(\.text),
                                show: show, thumbnails: MusicBrowseParser.thumbnails(header["thumbnail"]), description: description, info: info,
                                later: later, accounting: accounting)
    }

    private enum Side { case add, remove, other }
    private static func side(_ endpoint: Any?, videoID: String) -> Side {
        guard let edit = (endpoint as? [String: Any])?["playlistEditEndpoint"] as? [String: Any], edit["playlistId"] as? String == laterPlaylistID else { return .other }
        let actions = edit["actions"] as? [[String: Any]] ?? []
        if actions.contains(where: { $0["action"] as? String == "ACTION_ADD_VIDEO" && $0["addedVideoId"] as? String == videoID }) { return .add }
        if actions.contains(where: { $0["action"] as? String == "ACTION_REMOVE_VIDEO_BY_VIDEO_ID" && $0["removedVideoId"] as? String == videoID }) { return .remove }
        return .other
    }
    /// The Episodes-for-Later toggle: a toggle with a `playlistEditEndpoint` on the `SE` playlist for THIS episode on either side. Any other toggle is not it.
    private static func laterControl(_ toggle: [String: Any], videoID: String) -> MusicEpisodeLater? {
        let normal = side(toggle["defaultServiceEndpoint"], videoID: videoID), toggled = side(toggle["toggledServiceEndpoint"], videoID: videoID)
        guard normal != .other || toggled != .other else { return nil }
        let isToggled = toggle["isToggled"] as? Bool ?? false
        let displayed = isToggled ? toggled : normal
        let saved: Bool
        switch displayed {
        case .remove: saved = true
        case .add: saved = false
        case .other: saved = isToggled
        }
        return MusicEpisodeLater(videoID: videoID, isSaved: saved, addPublished: normal == .add || toggled == .add, removePublished: normal == .remove || toggled == .remove)
    }
    private static func descriptionRuns(_ value: Any?) -> [MusicTextRun] {
        var total = 0
        var result: [MusicTextRun] = []
        for run in MusicBrowseParser.runs(value) {
            guard var text = run["text"] as? String else { continue }
            if total + text.count > 20_000 { text = String(text.prefix(max(0, 20_000 - total))) }
            total += text.count
            var url: URL?
            if let target = (run["navigationEndpoint"] as? [String: Any])?["urlEndpoint"] as? [String: Any], let raw = target["url"] as? String, raw.utf8.count <= 2048 { url = URL(string: raw) }
            if !text.isEmpty { result.append(MusicTextRun(text: text, url: url)) }
            if total >= 20_000 { break }
        }
        return result
    }
}
