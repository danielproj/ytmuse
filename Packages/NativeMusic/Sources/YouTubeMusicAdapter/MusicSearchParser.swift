import AccountSession
import Foundation

/// Reads a Music `search` response (the unfiltered request) into typed rows.
///
/// Rows are classified from their own typed endpoints, never from shelf titles, because
/// shelf titles are localised. A row's type comes from, in order: the play button's
/// `musicVideoType` (episode), the row's browse `pageType` (album, artist, playlist,
/// podcast), then the play button's `musicVideoType` (song or video). A row that is
/// recognisably a result but cannot be read is counted in `skippedRows`; a kind the app
/// does not present (a profile) is counted in `unsupportedRows`. A document with no
/// recognised container, or rows that all failed, is `.unrecognised`, never an empty list.
///
/// The first run of an unfiltered row's detail line is the service's own type label
/// ("Song", "Album"…) and is removed because the app shows its own localised type name;
/// it is recognised as a label by having no endpoint and being followed by a separator.
public enum MusicSearchParser {
    private static let idPattern = #"^[A-Za-z0-9_-]{1,128}$"#
    private static let videoPattern = #"^[A-Za-z0-9_-]{11}$"#

    public static func parse(_ root: [String: Any]) throws(MusicSessionError) -> MusicSearchResponse {
        guard root["error"] == nil else { throw .unrecognised }
        guard let sections = sectionContents(root) else { throw .unrecognised }
        var top: MusicSearchItem?
        var items: [MusicSearchItem] = []
        var suggestion: MusicSearchSuggestion?
        var skipped = 0, unsupported = 0, duplicates = 0, noResults = false, seen = Set<String>(), recognisedSection = false

        func add(_ outcome: Outcome) {
            switch outcome {
            case .item(let item): if seen.insert(item.id).inserted { items.append(item) } else { duplicates += 1 }
            case .unsupported: unsupported += 1
            case .unreadable: skipped += 1
            }
        }
        /// A list of entries that should be result rows. Pagination markers are not results (the page is one page,
        /// and the response says so through `complete == false`); anything else that is not a row is counted.
        func rows(_ entries: [[String: Any]]) {
            for entry in entries {
                if let renderer = entry["musicResponsiveListItemRenderer"] as? [String: Any] { add(classifyRow(renderer)) }
                else if entry["continuationItemRenderer"] == nil { skipped += 1 }
            }
        }
        for section in sections {
            if let card = section["musicCardShelfRenderer"] as? [String: Any] {
                recognisedSection = true
                switch classifyCard(card) {
                case .item(let item): if top == nil { top = item; seen.insert(item.id) } else { add(.item(item)) }
                case .unsupported: unsupported += 1
                case .unreadable: skipped += 1
                }
                rows(card["contents"] as? [[String: Any]] ?? [])
            } else if let shelf = section["musicShelfRenderer"] as? [String: Any] {
                recognisedSection = true
                rows(shelf["contents"] as? [[String: Any]] ?? [])
            } else if let group = section["itemSectionRenderer"] as? [String: Any] {
                // Real responses wrap each result row in its own item section, beside the messages below.
                recognisedSection = true
                for entry in group["contents"] as? [[String: Any]] ?? [] {
                    if let did = entry["didYouMeanRenderer"] as? [String: Any] {
                        if suggestion == nil, let text = plain(did["correctedQuery"]) { suggestion = MusicSearchSuggestion(text: text, appliedByService: false) }
                    } else if let showing = entry["showingResultsForRenderer"] as? [String: Any] {
                        if let text = plain(showing["correctedQuery"]) { suggestion = MusicSearchSuggestion(text: text, appliedByService: true) }
                    } else if entry["messageRenderer"] != nil { noResults = true }
                    else { rows([entry]) }
                }
            } else {
                // A section kind this parser does not know may hold results: count it rather than ignore it.
                skipped += 1
            }
        }
        guard recognisedSection else { throw .unrecognised }
        // Rows existed and none could be read: a layout change, not "no results".
        if top == nil, items.isEmpty, skipped > 0 { throw .unrecognised }
        if top == nil, items.isEmpty, unsupported == 0, !noResults { throw .unrecognised }
        return MusicSearchResponse(top: top, items: items, suggestion: suggestion, skippedRows: skipped, unsupportedRows: unsupported,
                                   duplicateRows: duplicates, serviceReportedNoResults: noResults && top == nil && items.isEmpty)
    }

    private enum Outcome { case item(MusicSearchItem), unsupported, unreadable }

    private static func sectionContents(_ root: [String: Any]) -> [[String: Any]]? {
        guard let contents = root["contents"] as? [String: Any] else { return nil }
        if let list = (contents["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] { return list }
        guard let tabs = (contents["tabbedSearchResultsRenderer"] as? [String: Any])?["tabs"] as? [[String: Any]] else { return nil }
        for tab in tabs {
            let content = (tab["tabRenderer"] as? [String: Any])?["content"] as? [String: Any]
            if let list = (content?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] { return list }
        }
        return nil
    }

    private static func runs(_ value: Any?) -> [[String: Any]] {
        ((value as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
    }
    private static func plain(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        let text = (object["simpleText"] as? String) ?? runs(object).compactMap { $0["text"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.utf8.count > 512 ? nil : trimmed
    }
    private static func column(_ renderer: [String: Any], _ index: Int) -> [[String: Any]] {
        let columns = renderer["flexColumns"] as? [[String: Any]] ?? []
        guard columns.indices.contains(index) else { return [] }
        return runs((columns[index]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"])
    }
    private static func valid(_ value: String?, _ pattern: String) -> String? {
        guard let value, value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
    }
    private static func explicit(_ badges: Any?) -> Bool {
        (badges as? [[String: Any]] ?? []).contains {
            (($0["musicInlineBadgeRenderer"] as? [String: Any])?["icon"] as? [String: Any])?["iconType"] as? String == "MUSIC_EXPLICIT_BADGE"
        }
    }
    private static func videoType(_ endpoint: [String: Any]?) -> String? {
        let watch = endpoint?["watchEndpoint"] as? [String: Any]
        let supported = watch?["watchEndpointMusicSupportedConfigs"] as? [String: Any]
        return (supported?["watchEndpointMusicConfig"] as? [String: Any])?["musicVideoType"] as? String
    }
    private static func pageType(_ browse: [String: Any]?) -> String? {
        let supported = browse?["browseEndpointContextSupportedConfigs"] as? [String: Any]
        return (supported?["browseEndpointContextMusicConfig"] as? [String: Any])?["pageType"] as? String
    }

    private static func classifyRow(_ renderer: [String: Any]) -> Outcome {
        let titleRuns = column(renderer, 0)
        let title = titleRuns.compactMap { $0["text"] as? String }.joined()
        let count = (renderer["flexColumns"] as? [[String: Any]])?.count ?? 0
        let columns = (1..<max(1, count)).map { column(renderer, $0) }
        let play = ((((renderer["overlay"] as? [String: Any])?["musicItemThumbnailOverlayRenderer"] as? [String: Any])?["content"] as? [String: Any])?["musicPlayButtonRenderer"] as? [String: Any])?["playNavigationEndpoint"] as? [String: Any]
        let videoID = (renderer["playlistItemData"] as? [String: Any])?["videoId"] as? String
        return classify(title: title, columns: columns, endpoint: renderer["navigationEndpoint"] as? [String: Any],
                        play: play, playlistItemVideoID: videoID, badges: renderer["badges"])
    }
    private static func classifyCard(_ card: [String: Any]) -> Outcome {
        let titleRuns = runs(card["title"])
        let title = titleRuns.compactMap { $0["text"] as? String }.joined()
        let play = ((((card["thumbnailOverlay"] as? [String: Any])?["musicItemThumbnailOverlayRenderer"] as? [String: Any])?["content"] as? [String: Any])?["musicPlayButtonRenderer"] as? [String: Any])?["playNavigationEndpoint"] as? [String: Any]
        return classify(title: title, columns: [runs(card["subtitle"])], endpoint: titleRuns.first?["navigationEndpoint"] as? [String: Any],
                        play: play, playlistItemVideoID: nil, badges: card["subtitleBadges"] ?? card["badges"])
    }
    private static func isBullet(_ run: [String: Any]) -> Bool { (run["text"] as? String)?.trimmingCharacters(in: .whitespaces) == "•" }
    /// Splits the detail columns into the service's type label and the separate parts of the line. The label is
    /// the first run of the first column when it has no endpoint and is followed by a bullet (or stands alone);
    /// bullets separate parts, so "5:38" and "1.2B plays" never run together.
    private static func details(_ columns: [[[String: Any]]]) -> (label: String?, parts: [String]) {
        var columns = columns.filter { !$0.isEmpty }
        var label: String?
        if var first = columns.first, let head = first.first, head["navigationEndpoint"] == nil, first.count == 1 || isBullet(first[1]) {
            label = (head["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            first.removeFirst()
            if let separator = first.first, isBullet(separator) { first.removeFirst() }
            columns[0] = first
        }
        var parts: [String] = []
        for column in columns {
            var current = ""
            func flush() {
                let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
                current = ""
            }
            for run in column { if isBullet(run) { flush() } else { current += run["text"] as? String ?? "" } }
            flush()
        }
        return (label?.isEmpty == true ? nil : label, parts)
    }

    private static func classify(title rawTitle: String, columns: [[[String: Any]]], endpoint: [String: Any]?, play: [String: Any]?,
                                 playlistItemVideoID: String?, badges: Any?) -> Outcome {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 4096 else { return .unreadable }
        let browse = endpoint?["browseEndpoint"] as? [String: Any]
        let browseID = valid(browse?["browseId"] as? String, idPattern)
        let page = pageType(browse)
        let type = videoType(play) ?? videoType(endpoint)
        let watch = (play?["watchEndpoint"] as? [String: Any]) ?? (endpoint?["watchEndpoint"] as? [String: Any])
        let videoID = valid(playlistItemVideoID ?? watch?["videoId"] as? String, videoPattern)
        var playlistID = valid(((play?["watchPlaylistEndpoint"] as? [String: Any]) ?? (endpoint?["watchPlaylistEndpoint"] as? [String: Any]))?["playlistId"] as? String, idPattern)

        let kind: MusicSearchKind
        if type == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" { kind = .episode }
        else {
            switch page {
            case "MUSIC_PAGE_TYPE_ALBUM": kind = .album
            case "MUSIC_PAGE_TYPE_ARTIST": kind = .artist
            case "MUSIC_PAGE_TYPE_PLAYLIST": kind = .playlist
            case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE": kind = .podcast
            case "MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE": kind = .episode
            case "MUSIC_PAGE_TYPE_USER_CHANNEL": return .unsupported
            case nil:
                switch type {
                case "MUSIC_VIDEO_TYPE_ATV": kind = .song
                case "MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC", "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC": kind = .video
                default: return .unreadable
                }
            default: return .unsupported
            }
        }
        if kind == .playlist, playlistID == nil, let browseID, browseID.hasPrefix("VL") { playlistID = valid(String(browseID.dropFirst(2)), idPattern) }
        if kind == .album || kind == .podcast, playlistID == nil { playlistID = valid(watch?["playlistId"] as? String, idPattern) }

        let (typeLabel, parts) = details(columns)
        let detail = parts.contains(where: { $0.utf8.count > 1024 }) ? [] : parts
        let serviceLabel = kind == .album ? typeLabel : nil

        switch kind {
        case .song, .video, .episode:
            guard videoID != nil else { return .unreadable }
            return .item(MusicSearchItem(kind: kind, title: title, details: detail, explicit: explicit(badges), videoID: videoID, browseID: browseID, playlistID: nil))
        case .album, .artist, .playlist, .podcast:
            guard browseID != nil || playlistID != nil else { return .unreadable }
            return .item(MusicSearchItem(kind: kind, title: title, details: detail, serviceLabel: serviceLabel, explicit: explicit(badges), videoID: nil, browseID: browseID, playlistID: kind == .artist ? nil : playlistID))
        }
    }
}
