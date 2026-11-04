import AccountSession
import Foundation

/// Reads a Music `browse` response (Home, Explore, charts, moods, new releases, and the album, artist, playlist and
/// podcast-show pages) and its continuations into typed shelves.
///
/// Built on nine real anonymous captures (`Fixtures/W11-real`). Entries are classified from their own typed
/// endpoints (`pageType`, `musicVideoType`), never from a localised shelf title. Everything the parser meets is
/// accounted for in `MusicParseAccounting`: a section is a shelf, a header section, layout furniture or unsupported;
/// an entry is classified, skipped (unreadable), unsupported or a duplicate. Nothing is dropped without a count, and
/// a response that holds sections yet yields no readable content is `.unrecognised`, never an empty page.
///
/// Internal notes (not surfaced anywhere): a pages' primary column carries the header section, and the secondary
/// column of a two-column page carries the track list and the shelves that follow it.
public enum MusicBrowseParser {
    static let idPattern = #"^[A-Za-z0-9_-]{1,128}$"#
    static let videoPattern = #"^[A-Za-z0-9_-]{11}$"#
    static let paramsPattern = #"^[A-Za-z0-9%_=+/.-]{1,1024}$"#
    private static let tokenPattern = #"^[A-Za-z0-9%_=+/.-]{1,4096}$"#

    /// How a page's entries are read. A catalog page lists each thing once (a repeat inside one shelf is a duplicate and is dropped
    /// and counted). A collection page (a library tab or the history) lists what the person has: the same song can be there twice,
    /// so only an entry that names the service's own occurrence id is deduplicated. A collection page also admits the entry kinds
    /// only a library holds (a privately owned track) and counts the control tiles it carries ("New playlist", "Shuffle all") as unsupported.
    public enum Mode: Sendable { case catalog, collection }

    public static func isVideoID(_ value: String) -> Bool { value.range(of: videoPattern, options: .regularExpression) != nil }
    public static func isBrowseID(_ value: String) -> Bool { value.range(of: idPattern, options: .regularExpression) != nil }
    public static func isParams(_ value: String) -> Bool { value.range(of: paramsPattern, options: .regularExpression) != nil }
    public static func isToken(_ value: String) -> Bool { value.range(of: tokenPattern, options: .regularExpression) != nil }

    // MARK: Entry points

    public static func parse(_ root: [String: Any], mode: Mode = .catalog) throws(MusicSessionError) -> MusicBrowsePage {
        guard root["error"] == nil, let lists = sectionLists(root) else { throw .unrecognised }
        var run = Run(mode: mode)
        run.readRootHeader(root["header"] as? [String: Any])
        var chips: [MusicChip] = []
        for list in lists {
            chips += run.readChips(list["header"] as? [String: Any])
            for entry in unwrapped(list["contents"] as? [[String: Any]] ?? [], mode: mode) { run.section(entry) }
        }
        let acc = run.acc
        guard acc.sections > 0 || run.header != nil || run.heading != nil else { throw .unrecognised }
        // Sections existed and nothing readable came of them: a layout change, never "an empty page".
        if acc.sections > 0, acc.shelves == 0, acc.headerSections == 0, acc.furniture == 0, run.header == nil { throw .unrecognised }
        if acc.skipped > 0, acc.classified == 0, run.header == nil { throw .unrecognised }
        guard acc.consistent else { throw .unrecognised }
        if run.header?.description.isEmpty == true, let runs = run.sectionDescription { run.header?.description = runs }
        let continuation = lists.reversed().lazy.compactMap { token(in: $0["continuations"]) }.first
        return MusicBrowsePage(heading: run.heading, header: run.header, chips: chips, shelves: run.shelves, continuation: continuation, accounting: acc)
    }

    /// The answer to a continuation token: more entries for one shelf, or more sections for the page.
    public static func parseContinuation(_ root: [String: Any], mode: Mode = .catalog) throws(MusicSessionError) -> MusicContinuationPage {
        guard root["error"] == nil else { throw .unrecognised }
        var entries: [[String: Any]] = []
        var next: String?
        var recognised = false
        if let contents = root["continuationContents"] as? [String: Any] {
            for (name, value) in contents.sorted(by: { $0.key < $1.key }) {
                guard let container = value as? [String: Any] else { continue }
                recognised = true
                entries += (container["contents"] as? [[String: Any]]) ?? (container["items"] as? [[String: Any]]) ?? []
                next = next ?? token(in: container["continuations"])
                _ = name
            }
        }
        if !recognised, let actions = root["onResponseReceivedActions"] as? [[String: Any]] {
            for action in actions {
                guard let append = action["appendContinuationItemsAction"] as? [String: Any] else { continue }
                recognised = true
                entries += append["continuationItems"] as? [[String: Any]] ?? []
            }
        }
        guard recognised else { throw .unrecognised }
        var run = Run(mode: mode)
        let sectionKeys: Set<String> = ["musicCarouselShelfRenderer", "musicShelfRenderer", "musicPlaylistShelfRenderer", "gridRenderer"]
        entries = unwrapped(entries, mode: mode)
        let sections = entries.filter { $0.keys.contains(where: sectionKeys.contains) }
        var items: [MusicCatalogItem] = []
        if !sections.isEmpty {
            for entry in entries {
                if entry.keys.contains(where: sectionKeys.contains) { run.section(entry) }
                else if let marker = entry["continuationItemRenderer"] as? [String: Any] { run.acc.continuationMarkers += 1; next = next ?? token(in: marker) }
                else { run.acc.sections += 1; run.acc.unsupportedSections += 1; run.acc.unsupportedSectionNames.append(entry.keys.sorted().first ?? "") }
            }
        } else {
            var seen = Set<String>()
            let marker = run.entries(entries, into: &items, seen: &seen)
            next = next ?? marker
        }
        let acc = run.acc
        if acc.skipped > 0, acc.classified == 0, items.isEmpty, run.shelves.isEmpty { throw .unrecognised }
        guard acc.consistent else { throw .unrecognised }
        return MusicContinuationPage(items: items, shelves: run.shelves, continuation: next, accounting: acc)
    }

    // MARK: Layout

    /// A library tab may wrap its shelf or grid in an `itemSectionRenderer` (both reference clients read that form as well as the
    /// direct one). In a collection reading the wrapper is looked through; what is inside is counted as the sections it holds. A catalog
    /// reading is unchanged. A wrapper holding nothing readable stays an unknown section, so it is still "unrecognised", never empty.
    private static func unwrapped(_ entries: [[String: Any]], mode: Mode) -> [[String: Any]] {
        guard mode == .collection else { return entries }
        return entries.flatMap { entry -> [[String: Any]] in
            guard let wrapper = entry["itemSectionRenderer"] as? [String: Any], let inner = wrapper["contents"] as? [[String: Any]], !inner.isEmpty else { return [entry] }
            return unwrapped(inner, mode: mode)
        }
    }

    /// The primary column's list first, then the secondary column's: a two-column page puts the header section in
    /// the first and the track list in the second.
    private static func sectionLists(_ root: [String: Any]) -> [[String: Any]]? {
        guard let contents = root["contents"] as? [String: Any] else { return nil }
        func list(_ container: [String: Any]?) -> [String: Any]? {
            guard let tabs = container?["tabs"] as? [[String: Any]] else { return nil }
            for tab in tabs {
                let content = (tab["tabRenderer"] as? [String: Any])?["content"] as? [String: Any]
                if let list = content?["sectionListRenderer"] as? [String: Any] { return list }
            }
            return nil
        }
        if let two = contents["twoColumnBrowseResultsRenderer"] as? [String: Any] {
            var lists: [[String: Any]] = []
            if let primary = list(two) { lists.append(primary) }
            if let secondary = (two["secondaryContents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any] { lists.append(secondary) }
            return lists.isEmpty ? nil : lists
        }
        if let single = contents["singleColumnBrowseResultsRenderer"] as? [String: Any], let one = list(single) { return [one] }
        if let direct = contents["sectionListRenderer"] as? [String: Any] { return [direct] }
        return nil
    }

    // MARK: Text, endpoints, images

    static func runs(_ value: Any?) -> [[String: Any]] { ((value as? [String: Any])?["runs"] as? [[String: Any]]) ?? [] }
    static func plain(_ value: Any?, limit: Int = 1024) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        let text = (object["simpleText"] as? String) ?? runs(object).compactMap { $0["text"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.utf8.count > limit ? nil : trimmed
    }
    static func isBullet(_ run: [String: Any]) -> Bool { (run["text"] as? String)?.trimmingCharacters(in: .whitespaces) == "•" }
    static func valid(_ value: String?, _ pattern: String) -> String? {
        guard let value, value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
    }
    private static func token(in value: Any?) -> String? {
        if let list = value as? [[String: Any]] {
            for entry in list {
                if let data = entry["nextContinuationData"] as? [String: Any], let token = valid(data["continuation"] as? String, tokenPattern) { return token }
                if let data = entry["reloadContinuationData"] as? [String: Any], let token = valid(data["continuation"] as? String, tokenPattern) { return token }
            }
            return nil
        }
        if let marker = value as? [String: Any] {
            let command = (marker["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any]
            return valid(command?["token"] as? String, tokenPattern)
        }
        return nil
    }

    struct Endpoint {
        var browseID: String?
        var params: String?
        var pageType: String?
        var videoID: String?
        var playlistID: String?
        var videoType: String?
        var isBrowse = false
        var isWatch = false
    }
    static func endpoint(_ value: Any?) -> Endpoint? {
        guard let object = value as? [String: Any] else { return nil }
        var result = Endpoint()
        if let browse = object["browseEndpoint"] as? [String: Any] {
            result.isBrowse = true
            result.browseID = valid(browse["browseId"] as? String, idPattern)
            result.params = valid(browse["params"] as? String, paramsPattern)
            let supported = browse["browseEndpointContextSupportedConfigs"] as? [String: Any]
            result.pageType = (supported?["browseEndpointContextMusicConfig"] as? [String: Any])?["pageType"] as? String
            return result
        }
        if let watch = (object["watchEndpoint"] ?? object["watchPlaylistEndpoint"]) as? [String: Any] {
            result.isWatch = true
            result.videoID = valid(watch["videoId"] as? String, videoPattern)
            result.playlistID = valid(watch["playlistId"] as? String, idPattern)
            result.params = valid(watch["params"] as? String, paramsPattern)
            let supported = watch["watchEndpointMusicSupportedConfigs"] as? [String: Any]
            result.videoType = (supported?["watchEndpointMusicConfig"] as? [String: Any])?["musicVideoType"] as? String
            return result
        }
        return nil
    }
    static func link(_ run: [String: Any]) -> MusicLink? {
        guard let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.utf8.count <= 512,
              let target = endpoint(run["navigationEndpoint"]), let id = target.browseID else { return nil }
        let kind: MusicLink.Kind
        switch target.pageType {
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST": kind = .artist
        case "MUSIC_PAGE_TYPE_ALBUM": kind = .album
        case "MUSIC_PAGE_TYPE_PLAYLIST": kind = .playlist
        case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE": kind = .podcast
        default: kind = .other
        }
        return MusicLink(kind: kind, title: text, browseID: id, params: target.params)
    }
    /// `https` thumbnails only, scheme-relative URLs upgraded; the host allowlist is the fetch policy's, not the parser's.
    static func thumbnails(_ container: Any?) -> [MusicThumbnail] {
        guard let object = container as? [String: Any] else { return [] }
        let renderer = (object["musicThumbnailRenderer"] ?? object["croppedSquareThumbnailRenderer"]) as? [String: Any]
        let list = ((renderer?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
        var result: [MusicThumbnail] = []
        for entry in list.prefix(8) {
            guard var text = entry["url"] as? String, text.utf8.count <= 2048 else { continue }
            if text.hasPrefix("//") { text = "https:" + text }
            guard let url = URL(string: text), url.scheme == "https", url.host != nil else { continue }
            result.append(MusicThumbnail(url: url, width: entry["width"] as? Int ?? 0, height: entry["height"] as? Int ?? 0))
        }
        return result
    }
    private static func explicit(_ badges: Any?) -> Bool {
        (badges as? [[String: Any]] ?? []).contains {
            (($0["musicInlineBadgeRenderer"] as? [String: Any])?["icon"] as? [String: Any])?["iconType"] as? String == "MUSIC_EXPLICIT_BADGE"
        }
    }
    private static func playEndpoint(_ overlay: Any?) -> Endpoint? {
        let renderer = (overlay as? [String: Any])?["musicItemThumbnailOverlayRenderer"] as? [String: Any]
        let button = (renderer?["content"] as? [String: Any])?["musicPlayButtonRenderer"] as? [String: Any]
        return endpoint(button?["playNavigationEndpoint"])
    }
    /// The parts of a line split at the service's bullets, with the links found in each part.
    static func parts(_ runs: [[String: Any]]) -> [(text: String, links: [MusicLink])] {
        var result: [(String, [MusicLink])] = []
        var text = "", links: [MusicLink] = []
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.utf8.count <= 1024 { result.append((trimmed, links)) }
            text = ""; links = []
        }
        for run in runs {
            if isBullet(run) { flush(); continue }
            text += run["text"] as? String ?? ""
            if let item = link(run) { links.append(item) }
        }
        flush()
        return result
    }

    // MARK: Entries

    private enum Outcome { case item(MusicCatalogItem), unsupported, unreadable }
    private enum Resolved { case kind(MusicEntityKind), unsupported, unreadable }

    private static func resolve(_ nav: Endpoint?, _ play: Endpoint?) -> Resolved {
        let videoType = nav?.videoType ?? play?.videoType
        if videoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" || nav?.pageType == "MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE" { return .kind(.episode) }
        if let page = nav?.pageType {
            switch page {
            case "MUSIC_PAGE_TYPE_ALBUM": return .kind(.album)
            case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST": return .kind(.artist)
            case "MUSIC_PAGE_TYPE_PLAYLIST": return .kind(.playlist)
            case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE": return .kind(.podcast)
            default: return .unsupported
            }
        }
        if let id = nav?.browseID { return id.hasPrefix("FEmusic_") ? .kind(.category) : .unsupported }
        switch videoType {
        case "MUSIC_VIDEO_TYPE_ATV": return .kind(.song)
        case "MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC", "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC": return .kind(.video)
        default: return .unreadable
        }
    }

    private struct Fields {
        var title: String
        var parts: [(text: String, links: [MusicLink])]
        var nav: Endpoint?
        var play: Endpoint?
        var occurrenceVideoID: String?
        var explicit = false
        var availability = MusicAvailability.available
        var thumbnails: [MusicThumbnail] = []
        var position: String?
        var duration: String?
        var occurrence: String?
        var mode = Mode.catalog
        var controls: MusicItemControls?
        var actionTile = false
        var radio: MusicRadioAction?
        var episode: MusicEpisodeInfo?
    }

    private static func make(_ fields: Fields) -> Outcome {
        guard !fields.title.isEmpty, fields.title.utf8.count <= 4096 else { return .unreadable }
        let kind: MusicEntityKind
        // A collection page's control tiles ("New playlist", "Shuffle all") are not members of the collection.
        if fields.mode == .collection, fields.actionTile { return .unsupported }
        var privatelyOwned = false
        if fields.mode == .collection, fields.nav?.videoType == "MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK" || fields.play?.videoType == "MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK",
           fields.nav?.pageType == nil { privatelyOwned = true }
        switch privatelyOwned ? Resolved.kind(.song) : resolve(fields.nav, fields.play) {
        case .kind(let value): kind = value
        case .unsupported: return .unsupported
        case .unreadable:
            // A greyed-out track (not playable for this listener) has no watch endpoint but still names its video:
            // it is listed as an unavailable song, not dropped and not invented into something playable.
            guard fields.availability == .unavailable, fields.occurrenceVideoID != nil else { return .unreadable }
            kind = .song
        }
        var parts = fields.parts
        var label: String?
        // The service's type label leads the line of an album, playlist or podcast card ("Single • Artist").
        if [.album, .playlist, .podcast].contains(kind), parts.count > 1, parts[0].links.isEmpty { label = parts[0].text; parts.removeFirst() }
        let links = parts.flatMap(\.links)
        let details = parts.map(\.text)
        func build(video: String? = nil, browse: String? = nil, params: String? = nil, playlist: String? = nil) -> Outcome {
            .item(MusicCatalogItem(kind: kind, title: fields.title, details: details, serviceLabel: label, explicit: fields.explicit,
                                   availability: fields.availability, videoID: video, browseID: browse, browseParams: params, playlistID: playlist,
                                   contextPlaylistID: (kind == .song || kind == .video) ? fields.nav?.playlistID : nil,
                                   thumbnails: fields.thumbnails, links: links, position: fields.position, durationText: fields.duration,
                                   occurrenceID: fields.occurrence, controls: Self.restricted(fields.controls, to: kind), isPrivatelyOwned: privatelyOwned,
                                   radio: [.song, .video, .album, .artist, .playlist].contains(kind) ? fields.radio : nil,
                                   episode: kind == .episode ? fields.episode : nil))
        }
        switch kind {
        case .song, .video:
            guard let video = fields.nav?.videoID ?? fields.occurrenceVideoID ?? fields.play?.videoID else { return .unreadable }
            return build(video: video)
        case .episode:
            var video = fields.nav?.videoID ?? fields.occurrenceVideoID ?? fields.play?.videoID
            if video == nil, let browse = fields.nav?.browseID, browse.hasPrefix("MPED") { video = valid(String(browse.dropFirst(4)), videoPattern) }
            guard let video else { return .unreadable }
            return build(video: video, browse: fields.nav?.browseID.flatMap { $0.hasPrefix("MPED") ? $0 : nil })
        case .album, .playlist, .podcast, .artist, .category:
            guard let browse = fields.nav?.browseID else { return .unreadable }
            var playlist = fields.play?.playlistID
            if kind == .playlist, playlist == nil, browse.hasPrefix("VL") { playlist = valid(String(browse.dropFirst(2)), idPattern) }
            if kind == .artist || kind == .category { playlist = nil }
            return build(browse: browse, params: fields.nav?.params, playlist: playlist)
        }
    }

    /// A navigation endpoint that is neither a page nor a track: a typed action (create a playlist) or a play-all with no track.
    private static func isActionTile(_ navigation: Any?, nav: Endpoint?) -> Bool {
        if let nav {
            // A watch endpoint with a playlist and no track is a play-all control, not an entry.
            return nav.isWatch && nav.videoID == nil && nav.playlistID != nil
        }
        guard let object = navigation as? [String: Any] else { return false }
        return object.keys.contains { $0.hasSuffix("Endpoint") && $0 != "browseEndpoint" && $0 != "watchEndpoint" && $0 != "watchPlaylistEndpoint" }
    }
    private static func classifyTwoRow(_ renderer: [String: Any], mode: Mode) -> Outcome {
        let titleRuns = runs(renderer["title"])
        let title = titleRuns.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let nav = endpoint(renderer["navigationEndpoint"]) ?? endpoint(titleRuns.first?["navigationEndpoint"])
        var fields = Fields(title: title, parts: parts(runs(renderer["subtitle"])), nav: nav, play: playEndpoint(renderer["thumbnailOverlay"]),
                            explicit: explicit(renderer["subtitleBadges"]), thumbnails: thumbnails(renderer["thumbnailRenderer"]))
        fields.mode = mode
        fields.actionTile = isActionTile(renderer["navigationEndpoint"], nav: nav)
        fields.controls = controls(menu: renderer["menu"], nav: nav)
        fields.radio = radioAction(menu: renderer["menu"])
        return make(fields)
    }

    private static func classifyRow(_ renderer: [String: Any], mode: Mode) -> Outcome {
        let columns = (renderer["flexColumns"] as? [[String: Any]] ?? []).map {
            runs(($0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"])
        }
        guard let first = columns.first else { return .unreadable }
        let title = first.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let nav = endpoint(renderer["navigationEndpoint"]) ?? endpoint(first.first?["navigationEndpoint"])
        let fixed = (renderer["fixedColumns"] as? [[String: Any]])?.first.flatMap {
            plain(($0["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any])?["text"], limit: 64)
        }
        let index = plain(renderer["index"], limit: 16)
            ?? plain(((renderer["customIndexColumn"] as? [String: Any])?["musicCustomIndexColumnRenderer"] as? [String: Any])?["text"], limit: 16)
        let policy = renderer["musicItemRendererDisplayPolicy"] as? String
        let data = renderer["playlistItemData"] as? [String: Any]
        var fields = Fields(title: title, parts: columns.dropFirst().flatMap { parts($0) }, nav: nav, play: playEndpoint(renderer["overlay"]),
                            occurrenceVideoID: valid(data?["videoId"] as? String, videoPattern), explicit: explicit(renderer["badges"]),
                            availability: policy == "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT" ? .unavailable : .available,
                            thumbnails: thumbnails(renderer["thumbnail"]), position: index, duration: fixed,
                            // A suggestion row carries a shared placeholder where a member's occurrence id would be: it is no occurrence.
                            occurrence: valid(data?["playlistSetVideoId"] as? String, idPattern).flatMap { $0 == MusicPlaylistRequest.suggestionPlaceholder ? nil : $0 })
        fields.mode = mode
        // A row with a track of its own is an entry even when its overlay also carries a play-all endpoint.
        fields.actionTile = data?["videoId"] == nil && (isActionTile(renderer["navigationEndpoint"], nav: nav) || (nav == nil && isActionTile(nil, nav: fields.play)))
        fields.controls = controls(menu: renderer["menu"], nav: nav, allowRemoval: true)
        fields.radio = radioAction(menu: renderer["menu"])
        // A removal control belongs to this occurrence only if it names this row's own occurrence and video.
        if var published = fields.controls, let removal = published.playlistRemoval,
           removal.setVideoID != fields.occurrence || removal.videoID != fields.occurrenceVideoID {
            published.playlistRemoval = nil; fields.controls = published.isEmpty ? nil : published
        }
        return make(fields)
    }

    private static func classifyMultiRow(_ renderer: [String: Any], mode: Mode) -> Outcome {
        let titleRuns = runs(renderer["title"])
        let title = titleRuns.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        // The tap target plays the episode; the title's own endpoint opens its page. Either identifies it.
        var nav = endpoint(renderer["onTap"])
        let page = endpoint(titleRuns.first?["navigationEndpoint"])
        if nav?.videoType == nil || nav?.videoID == nil { nav = page ?? nav }
        else if let page, nav != nil { nav?.browseID = page.browseID; nav?.pageType = page.pageType }
        let progress = (renderer["playbackProgress"] as? [String: Any])?["musicPlaybackProgressRenderer"] as? [String: Any]
        let duration = parts(runs(progress?["durationText"])).first?.text
        var fields = Fields(title: title, parts: parts(runs(renderer["subtitle"])), nav: nav, play: nil, thumbnails: thumbnails(renderer["thumbnail"]), duration: duration)
        fields.mode = mode
        fields.controls = controls(menu: renderer["menu"], nav: nav)
        fields.episode = episodeInfo(progress: progress, menu: renderer["menu"], description: renderer["description"])
        return make(fields)
    }

    /// The facts an episode row or page printed about progress and about its own menu. See `MusicEpisodeInfo` for why a "Played" label is not
    /// read as played. A percentage outside 0…100 is unreadable and reported as no progress at all, never clamped.
    static func episodeInfo(progress: [String: Any]?, menu: Any?, description: Any? = nil) -> MusicEpisodeInfo? {
        var percent: Double?
        if let number = progress?["playbackProgressPercentage"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.doubleValue
            if value.isFinite, (0...100).contains(value) { percent = value }
        }
        let duration = progress.flatMap { parts(runs($0["durationText"])).first?.text }
        let token = (progress?["videoPlaybackPositionFeedbackToken"] as? String).map { !$0.isEmpty } ?? false
        let played = !runs(progress?["playedText"]).isEmpty
        var download = false
        func walk(_ node: Any, depth: Int) {
            guard depth < 12 else { return }
            if let object = node as? [String: Any] {
                if object["menuServiceItemDownloadRenderer"] != nil { download = true }
                for value in object.values { walk(value, depth: depth + 1) }
            } else if let list = node as? [Any] { for value in list { walk(value, depth: depth + 1) } }
        }
        if let menu { walk(menu, depth: 0) }
        let summaryText = runs(description).compactMap { $0["text"] as? String }.joined()
        let summary = summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(summaryText.prefix(2_000))
        guard progress != nil || download || summary != nil else { return nil }
        return MusicEpisodeInfo(progressPercent: percent, durationText: duration, hasPositionFeedbackToken: token, playedLabelPublished: played,
                                publishesServiceDownloadAction: download, summary: summary)
    }

    private static func classifyNavigationButton(_ renderer: [String: Any], mode: Mode) -> Outcome {
        let title = plain(renderer["buttonText"]) ?? ""
        let nav = endpoint(renderer["clickCommand"])
        var fields = Fields(title: title, parts: [], nav: nav, play: nil)
        fields.mode = mode
        return make(fields)
    }

    // MARK: Write controls

    /// A control belongs only to the kind of entry it can act on: a rating and a library token to a song or video, a saved playlist to an
    /// album, playlist or show, a follow to an artist. An episode's or a category's toggles are never library controls.
    private static func restricted(_ controls: MusicItemControls?, to kind: MusicEntityKind) -> MusicItemControls? {
        guard var controls else { return nil }
        if kind != .song && kind != .video { controls.like = nil; controls.songLibrary = nil; controls.playlistRemoval = nil }
        if ![.album, .playlist, .podcast].contains(kind) { controls.save = nil }
        if kind != .artist { controls.follow = nil }
        return controls.isEmpty ? nil : controls
    }

    private static let feedbackTokenPattern = #"^[A-Za-z0-9_%=+/.-]{8,4096}$"#
    private static let channelPattern = #"^UC[A-Za-z0-9_-]{22}$"#
    // A library toggle is identified by its icons, the way the web client names them, and never by merely being a toggle that carries
    // a token: a signed episode row also carries "Mark as played" and "Pin to Listen again" toggles of the same shape.
    private static let addIcons: Set<String> = ["LIBRARY_ADD", "BOOKMARK_BORDER"]
    private static let removeIcons: Set<String> = ["LIBRARY_REMOVE", "LIBRARY_SAVED", "BOOKMARK"]
    private static func iconType(_ value: Any?) -> String? { (value as? [String: Any])?["iconType"] as? String }
    /// What a toggle's icons say. Each side's icon names the action its own endpoint performs (an "add" icon's endpoint adds, a
    /// "remove" icon's endpoint removes), whichever side is the default; the side currently displayed (`isToggled`) says whether the
    /// item is already in the library. Anything but one add icon paired with one remove icon is not a library toggle at all.
    private struct LibraryToggle { let isSaved: Bool; let add: Any?; let remove: Any? }
    private static func libraryToggle(_ toggle: [String: Any]) -> LibraryToggle? {
        guard let d = iconType(toggle["defaultIcon"]), let t = iconType(toggle["toggledIcon"]) else { return nil }
        let defaultEndpoint = toggle["defaultServiceEndpoint"], toggledEndpoint = toggle["toggledServiceEndpoint"]
        let displayed: String
        if toggle["isToggled"] as? Bool == true { displayed = t } else { displayed = d }
        if addIcons.contains(d), removeIcons.contains(t) {
            return LibraryToggle(isSaved: removeIcons.contains(displayed), add: defaultEndpoint, remove: toggledEndpoint)
        }
        if removeIcons.contains(d), addIcons.contains(t) {
            return LibraryToggle(isSaved: removeIcons.contains(displayed), add: toggledEndpoint, remove: defaultEndpoint)
        }
        return nil
    }
    private static func likeTarget(_ endpoint: Any?, status: String) -> String? {
        guard let like = (endpoint as? [String: Any])?["likeEndpoint"] as? [String: Any] else { return nil }
        // An endpoint whose own status contradicts the side's icon is not trusted.
        if let own = like["status"] as? String, own != status { return nil }
        return valid((like["target"] as? [String: Any])?["playlistId"] as? String, idPattern)
    }
    private static func feedbackToken(_ endpoint: Any?) -> String? {
        valid(((endpoint as? [String: Any])?["feedbackEndpoint"] as? [String: Any])?["feedbackToken"] as? String, feedbackTokenPattern)
    }
    /// The radio an entry's own menu offers: the menu item the service marks with the `MIX` icon ("Start mix"), whose endpoint is either a
    /// watch endpoint (a song's radio, with the track) or a watch-playlist endpoint (an album's, artist's or playlist's), always with a playlist
    /// and, in the captures, parameters. Exactly one such item, or none: two different ones mean nothing is offered rather than a guess.
    private static func radioAction(menu: Any?) -> MusicRadioAction? {
        guard let renderer = (menu as? [String: Any])?["menuRenderer"] as? [String: Any] else { return nil }
        var found: [MusicRadioAction] = []
        for item in renderer["items"] as? [[String: Any]] ?? [] {
            guard let nav = item["menuNavigationItemRenderer"] as? [String: Any], (nav["icon"] as? [String: Any])?["iconType"] as? String == "MIX",
                  let target = endpoint(nav["navigationEndpoint"]), target.isWatch, let list = target.playlistID else { continue }
            found.append(MusicRadioAction(playlistID: list, videoID: target.videoID, params: target.params))
        }
        return Set(found).count == 1 ? found[0] : nil
    }
    /// The like state, library toggles and (for pages) save targets an entry's `menu` published for itself. Anonymous pages publish a
    /// sign-in prompt where the signed endpoints would be, so they yield no library toggle (they do carry the like button's current
    /// state, which a view draws only for a signed-in account).
    private static func controls(menu: Any?, nav: Endpoint?, allowRemoval: Bool = false) -> MusicItemControls? {
        guard let renderer = (menu as? [String: Any])?["menuRenderer"] as? [String: Any] else { return nil }
        var result = MusicItemControls()
        for button in renderer["topLevelButtons"] as? [[String: Any]] ?? [] {
            guard let like = button["likeButtonRenderer"] as? [String: Any], like["likesAllowed"] as? Bool == true,
                  let video = valid((like["target"] as? [String: Any])?["videoId"] as? String, videoPattern),
                  let status = (like["likeStatus"] as? String).flatMap(MusicLikeStatus.init(rawValue:)) else { continue }
            result.like = .init(videoID: video, status: status, dislikeExposed: like["dislikeNavigationEndpoint"] != nil)
        }
        var libraryToggles = 0
        for item in renderer["items"] as? [[String: Any]] ?? [] {
            if allowRemoval, let removal = playlistRemoval(item["menuServiceItemRenderer"]) { result.playlistRemoval = removal; continue }
            guard let toggle = item["toggleMenuServiceItemRenderer"] as? [String: Any], let library = libraryToggle(toggle) else { continue }
            libraryToggles += 1
            let target = likeTarget(library.add, status: "LIKE") ?? likeTarget(library.remove, status: "INDIFFERENT")
            if let target {
                result.save = .init(playlistID: target, isSaved: library.isSaved)
            } else {
                let add = feedbackToken(library.add), remove = feedbackToken(library.remove)
                if add != nil || remove != nil { result.songLibrary = .init(isSaved: library.isSaved, addToken: add, removeToken: remove) }
            }
        }
        // Two library toggles on one entry cannot both be right: offer neither rather than guess which is the real one.
        if libraryToggles > 1 { result.save = nil; result.songLibrary = nil }
        return result.isEmpty ? nil : result
    }
    /// The per-row remove command of a signed playlist page: `playlistEditEndpoint` with exactly one `ACTION_REMOVE_VIDEO` that names both
    /// the video and its occurrence (`setVideoId`). Anything else (a remove by video id, several actions) is not a removal control.
    private static func playlistRemoval(_ item: Any?) -> MusicPlaylistRowRemoval? {
        guard let renderer = item as? [String: Any],
              let edit = (renderer["serviceEndpoint"] as? [String: Any])?["playlistEditEndpoint"] as? [String: Any],
              let list = valid(edit["playlistId"] as? String, idPattern), MusicPlaylistRequest.isEditablePlaylistID(list),
              let actions = edit["actions"] as? [[String: Any]], actions.count == 1, actions[0]["action"] as? String == "ACTION_REMOVE_VIDEO",
              let video = valid(actions[0]["removedVideoId"] as? String, videoPattern), let occurrence = valid(actions[0]["setVideoId"] as? String, idPattern),
              MusicPlaylistRequest.isOccurrenceID(occurrence) else { return nil }
        return MusicPlaylistRowRemoval(playlistID: list, videoID: video, setVideoID: occurrence)
    }
    /// Reads a signed playlist page's editable header: `musicEditablePlaylistDetailHeaderRenderer` holds the ordinary header and an edit
    /// header (`musicPlaylistEditHeaderRenderer`, with the privacy). A delete command anywhere in the header's menu marks the owner.
    private static func playlistEditing(_ wrapper: [String: Any]) -> MusicPlaylistEditing {
        let edit = (wrapper["editHeader"] as? [String: Any])?["musicPlaylistEditHeaderRenderer"] as? [String: Any]
        let privacy = (edit?["privacy"] as? String).flatMap(MusicPlaylistPrivacy.init(rawValue:))
        let listID = valid(edit?["playlistId"] as? String, idPattern)
        var hasDelete = false
        func walk(_ node: Any, _ depth: Int) {
            guard depth < 24, !hasDelete else { return }
            if let object = node as? [String: Any] {
                if let delete = object["deletePlaylistEndpoint"] as? [String: Any], let target = delete["playlistId"] as? String, listID == nil || target == listID { hasDelete = true; return }
                for child in object.values { walk(child, depth + 1) }
            } else if let list = node as? [Any] { for child in list { walk(child, depth + 1) } }
        }
        walk(wrapper["header"] as Any, 0)
        // The editable header itself is the service's statement that the tracks can be changed; details need the edit header too.
        return MusicPlaylistEditing(canEditTracks: true, canEditDetails: edit != nil, canDelete: hasDelete, privacy: privacy, playlistID: listID)
    }
    /// A page header's Save toggle: the state it shows and, when the service published one, the playlist it acts on. Nil unless it is a
    /// library toggle by its icons.
    private static func saveControl(_ toggle: [String: Any]) -> (playlistID: String?, isSaved: Bool?)? {
        guard let library = libraryToggle(toggle) else { return nil }
        return (likeTarget(library.add, status: "LIKE") ?? likeTarget(library.remove, status: "INDIFFERENT"), library.isSaved)
    }

    // MARK: Run state

    private struct Run {
        var mode = Mode.catalog
        init(mode: Mode = .catalog) { self.mode = mode }
        var acc = MusicParseAccounting()
        var shelves: [MusicShelf] = []
        var header: MusicPageHeader?
        var heading: String?
        var sectionDescription: [MusicTextRun]?
        private var keyCounts: [String: Int] = [:]
        private func plain(_ value: Any?, limit: Int = 1024) -> String? { MusicBrowseParser.plain(value, limit: limit) }
        private func endpoint(_ value: Any?) -> Endpoint? { MusicBrowseParser.endpoint(value) }
        private func runs(_ value: Any?) -> [[String: Any]] { MusicBrowseParser.runs(value) }

        /// Reads entries into `items`, counting each; returns a continuation token carried by a trailing marker.
        mutating func entries(_ entries: [[String: Any]], into items: inout [MusicCatalogItem], seen: inout Set<String>) -> String? {
            var token: String?
            for entry in entries {
                if let marker = entry["continuationItemRenderer"] as? [String: Any] {
                    acc.continuationMarkers += 1; token = token ?? MusicBrowseParser.token(in: marker); continue
                }
                acc.items += 1
                let outcome: Outcome
                if let renderer = entry["musicTwoRowItemRenderer"] as? [String: Any] { outcome = MusicBrowseParser.classifyTwoRow(renderer, mode: mode) }
                else if let renderer = entry["musicResponsiveListItemRenderer"] as? [String: Any] { outcome = MusicBrowseParser.classifyRow(renderer, mode: mode) }
                else if let renderer = entry["musicMultiRowListItemRenderer"] as? [String: Any] { outcome = MusicBrowseParser.classifyMultiRow(renderer, mode: mode) }
                else if let renderer = entry["musicNavigationButtonRenderer"] as? [String: Any] { outcome = MusicBrowseParser.classifyNavigationButton(renderer, mode: mode) }
                else { outcome = .unsupported }
                switch outcome {
                case .item(let item):
                    // A collection keeps repeats (a song played twice is two rows); only the service's own occurrence id identifies a true repeat.
                    if mode == .collection && item.occurrenceID == nil { items.append(item); acc.classified += 1 }
                    else if seen.insert(item.id).inserted { items.append(item); acc.classified += 1 } else { acc.duplicates += 1 }
                case .unsupported: acc.unsupported += 1
                case .unreadable: acc.skipped += 1
                }
            }
            return token
        }

        /// A shelf's identity across refreshes is its layout and title; the service's own shelf id is only the
        /// fallback for an untitled shelf (the ids on Home are generated per response, so they would make every
        /// refresh look like a new page).
        private mutating func key(_ id: String?, layout: MusicShelf.Layout, title: String?) -> String {
            if title?.isEmpty != false, let id, !id.isEmpty { return id }
            let base = layout.rawValue + ":" + (title ?? "")
            keyCounts[base, default: 0] += 1
            return keyCounts[base]! > 1 ? base + "#\(keyCounts[base]!)" : base
        }
        private static func layout(of entries: [[String: Any]], default fallback: MusicShelf.Layout) -> MusicShelf.Layout {
            if entries.contains(where: { $0["musicNavigationButtonRenderer"] != nil }) { return .categories }
            if entries.contains(where: { $0["musicResponsiveListItemRenderer"] != nil || $0["musicMultiRowListItemRenderer"] != nil }) { return .list }
            return fallback
        }

        mutating func section(_ entry: [String: Any]) {
            acc.sections += 1
            if let shelf = entry["musicCarouselShelfRenderer"] as? [String: Any] {
                let header = (shelf["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
                let title = plain(header?["title"])
                let contents = shelf["contents"] as? [[String: Any]] ?? []
                var items: [MusicCatalogItem] = [], seen = Set<String>()
                let marker = entries(contents, into: &items, seen: &seen)
                var more: MusicLink?
                if let target = endpoint((header?["moreContentButton"] as? [String: Any]).flatMap { ($0["buttonRenderer"] as? [String: Any])?["navigationEndpoint"] }
                                         ?? runs(header?["title"]).first?["navigationEndpoint"]), target.isBrowse, let id = target.browseID {
                    more = MusicLink(kind: .other, title: title ?? "", browseID: id, params: target.params)
                }
                let rows = (shelf["numItemsPerColumn"] as? Int) ?? (shelf["numItemsPerColumn"] as? String).flatMap(Int.init)
                let layout = Run.layout(of: contents, default: .carousel)
                shelves.append(MusicShelf(key: key(shelf["shelfId"] as? String, layout: layout, title: title), title: title, layout: layout, items: items, more: more,
                                          continuation: marker ?? MusicBrowseParser.token(in: shelf["continuations"]), rowsPerColumn: layout == .list ? rows : nil))
                acc.shelves += 1
            } else if let shelf = (entry["musicShelfRenderer"] ?? entry["musicPlaylistShelfRenderer"]) as? [String: Any] {
                guard let contents = shelf["contents"] as? [[String: Any]] else {
                    // A chart's region picker: a shelf with sub-headers and no entries at all.
                    acc.furniture += 1
                    return
                }
                let title = plain(shelf["title"])
                var items: [MusicCatalogItem] = [], seen = Set<String>()
                let marker = entries(contents, into: &items, seen: &seen)
                var more: MusicLink?
                if let target = endpoint(shelf["bottomEndpoint"]), target.isBrowse, let id = target.browseID {
                    more = MusicLink(kind: .other, title: plain(shelf["bottomText"]) ?? "", browseID: id, params: target.params)
                }
                let layout = Run.layout(of: contents, default: .list)
                shelves.append(MusicShelf(key: key(shelf["shelfId"] as? String ?? shelf["playlistId"] as? String, layout: layout, title: title), title: title, layout: layout,
                                          items: items, more: more, continuation: marker ?? MusicBrowseParser.token(in: shelf["continuations"])))
                acc.shelves += 1
            } else if let grid = entry["gridRenderer"] as? [String: Any] {
                let title = plain(((grid["header"] as? [String: Any])?["gridHeaderRenderer"] as? [String: Any])?["title"])
                let contents = grid["items"] as? [[String: Any]] ?? []
                var items: [MusicCatalogItem] = [], seen = Set<String>()
                let marker = entries(contents, into: &items, seen: &seen)
                let layout = Run.layout(of: contents, default: .grid)
                shelves.append(MusicShelf(key: key(nil, layout: layout, title: title), title: title, layout: layout == .list ? .grid : layout, items: items,
                                          continuation: marker ?? MusicBrowseParser.token(in: grid["continuations"])))
                acc.shelves += 1
            } else if let shelf = entry["musicDescriptionShelfRenderer"] as? [String: Any] {
                sectionDescription = descriptionRuns(shelf["description"])
                acc.headerSections += 1
            } else if let responsive = entry["musicResponsiveHeaderRenderer"] as? [String: Any] {
                readResponsiveHeader(responsive)
                acc.headerSections += 1
            } else if let editable = entry["musicEditablePlaylistDetailHeaderRenderer"] as? [String: Any] {
                if let inner = (editable["header"] as? [String: Any])?["musicResponsiveHeaderRenderer"] as? [String: Any] {
                    readResponsiveHeader(inner)
                    header?.editing = MusicBrowseParser.playlistEditing(editable)
                    acc.headerSections += 1
                } else {
                    acc.unsupportedSections += 1
                    acc.unsupportedSectionNames.append("musicEditablePlaylistDetailHeaderRenderer")
                }
            } else {
                acc.unsupportedSections += 1
                acc.unsupportedSectionNames.append(entry.keys.sorted().first ?? "")
            }
        }

        mutating func readChips(_ header: [String: Any]?) -> [MusicChip] {
            guard let header else { return [] }
            guard let cloud = header["chipCloudRenderer"] as? [String: Any] else {
                acc.ignoredRenderers.append(header.keys.sorted().first ?? ""); return []
            }
            var chips: [MusicChip] = []
            for entry in cloud["chips"] as? [[String: Any]] ?? [] {
                let chip = entry["chipCloudChipRenderer"] as? [String: Any]
                if let title = plain(chip?["text"], limit: 256), let target = endpoint(chip?["navigationEndpoint"]), target.isBrowse, let id = target.browseID {
                    chips.append(MusicChip(title: title, browseID: id, params: target.params, selected: chip?["isSelected"] as? Bool ?? false))
                } else {
                    // A sort menu (popup) rather than a browse chip: not content.
                    acc.ignoredRenderers.append("chipCloudChipRenderer")
                }
            }
            return chips
        }

        // MARK: Headers

        func descriptionRuns(_ value: Any?) -> [MusicTextRun] {
            var total = 0
            var result: [MusicTextRun] = []
            for run in MusicBrowseParser.runs(value) {
                guard var text = run["text"] as? String else { continue }
                if total + text.count > 20_000 { text = String(text.prefix(max(0, 20_000 - total))) }
                total += text.count
                var url: URL?
                if let target = (run["navigationEndpoint"] as? [String: Any])?["urlEndpoint"] as? [String: Any],
                   let raw = target["url"] as? String, raw.utf8.count <= 2048 { url = URL(string: raw) }
                if !text.isEmpty { result.append(MusicTextRun(text: text, url: url)) }
                if total >= 20_000 { break }
            }
            return result
        }

        mutating func readRootHeader(_ header: [String: Any]?) {
            guard let header else { return }
            if let heading = (header["musicHeaderRenderer"] as? [String: Any]) {
                self.heading = MusicBrowseParser.plain(heading["title"])
            } else if let immersive = header["musicImmersiveHeaderRenderer"] as? [String: Any] {
                readImmersiveHeader(immersive)
            } else {
                acc.ignoredRenderers.append(header.keys.sorted().first ?? "")
            }
        }

        private mutating func readImmersiveHeader(_ renderer: [String: Any]) {
            guard let title = MusicBrowseParser.plain(renderer["title"]) else { return }
            var actions = MusicPageActions()
            func playlist(_ button: Any?) -> (icon: String?, id: String?, params: String?, video: String?) {
                let renderer = (button as? [String: Any])?["buttonRenderer"] as? [String: Any]
                let icon = (renderer?["icon"] as? [String: Any])?["iconType"] as? String
                let target = MusicBrowseParser.endpoint(renderer?["navigationEndpoint"])
                return (icon, target?.playlistID, target?.params, target?.videoID)
            }
            let play = playlist(renderer["playButton"])
            if play.icon == "MUSIC_SHUFFLE" { actions.shuffle = play.id; actions.shuffleParams = play.params } else { actions.play = play.id }
            let radio = playlist(renderer["startRadioButton"])
            actions.radio = radio.id
            actions.radioAction = radio.id.map { MusicRadioAction(playlistID: $0, videoID: radio.video, params: radio.params) }
            let subscription = (renderer["subscriptionButton"] as? [String: Any])?["subscribeButtonRenderer"] as? [String: Any]
            actions.offersFollow = subscription != nil
            if let subscription, let channel = valid(subscription["channelId"] as? String, channelPattern) {
                let subscribe = (subscription["serviceEndpoints"] as? [[String: Any]])?.lazy.compactMap { $0["subscribeEndpoint"] as? [String: Any] }.first
                actions.controls.follow = .init(channelID: channel, isFollowing: subscription["subscribed"] as? Bool, params: valid(subscribe?["params"] as? String, paramsPattern))
            }
            let audience = MusicBrowseParser.plain(renderer["monthlyListenerCount"], limit: 128) ?? MusicBrowseParser.plain(subscription?["longSubscriberCountText"], limit: 128)
            header = MusicPageHeader(title: title, description: descriptionRuns(renderer["description"]),
                                     thumbnails: MusicBrowseParser.thumbnails(renderer["thumbnail"]), audienceText: audience, actions: actions)
        }

        private mutating func readResponsiveHeader(_ renderer: [String: Any]) {
            guard let title = MusicBrowseParser.plain(renderer["title"]) else { return }
            var actions = MusicPageActions()
            for button in renderer["buttons"] as? [[String: Any]] ?? [] {
                if let toggle = button["toggleButtonRenderer"] as? [String: Any] {
                    // Only a library toggle is the page's Save (a description's Show more is a toggle too).
                    if let saved = saveControl(toggle) {
                        actions.offersSave = true
                        actions.controls.save = .init(playlistID: saved.playlistID ?? "", isSaved: saved.isSaved)
                    }
                }
                else if let play = (button["musicPlayButtonRenderer"] as? [String: Any]) {
                    actions.play = MusicBrowseParser.endpoint(play["playNavigationEndpoint"])?.playlistID ?? actions.play
                } else if let plain = button["buttonRenderer"] as? [String: Any] {
                    let icon = (plain["icon"] as? [String: Any])?["iconType"] as? String
                    let target = MusicBrowseParser.endpoint(plain["navigationEndpoint"])
                    let id = target?.playlistID
                    if icon == "MUSIC_SHUFFLE" { actions.shuffle = id ?? actions.shuffle; actions.shuffleParams = target?.params ?? actions.shuffleParams } else if id != nil { actions.play = actions.play ?? id }
                } else if let menu = button["menuRenderer"] as? [String: Any] {
                    for item in menu["items"] as? [[String: Any]] ?? [] {
                        if let toggle = item["toggleMenuServiceItemRenderer"] as? [String: Any] {
                            if let saved = MusicBrowseParser.saveControl(toggle), let list = saved.playlistID { actions.controls.save = .init(playlistID: list, isSaved: saved.isSaved); actions.offersSave = true }
                            continue
                        }
                        guard let nav = item["menuNavigationItemRenderer"] as? [String: Any] else { continue }
                        let icon = (nav["icon"] as? [String: Any])?["iconType"] as? String
                        let target = MusicBrowseParser.endpoint(nav["navigationEndpoint"])
                        let id = target?.playlistID
                        if icon == "MUSIC_SHUFFLE" { actions.shuffle = id ?? actions.shuffle; actions.shuffleParams = target?.params ?? actions.shuffleParams }
                        else if icon == "MIX", let id, target?.isWatch == true {
                            actions.radio = id; actions.radioAction = MusicRadioAction(playlistID: id, videoID: target?.videoID, params: target?.params)
                        }
                    }
                }
            }
            // The page's own Save toggle names no target before sign-in; the playlist its Play button starts is the one it saves.
            if let save = actions.controls.save, save.playlistID.isEmpty {
                actions.controls.save = actions.play.map { .init(playlistID: $0, isSaved: save.isSaved) }
            }
            let subtitle = MusicBrowseParser.parts(MusicBrowseParser.runs(renderer["subtitle"])).map(\.text)
            let second = MusicBrowseParser.parts(MusicBrowseParser.runs(renderer["secondSubtitle"])).map(\.text)
            let credits = MusicBrowseParser.runs(renderer["straplineTextOne"]).compactMap(MusicBrowseParser.link)
            let byline = (((renderer["facepile"] as? [String: Any])?["avatarStackViewModel"] as? [String: Any])?["text"] as? [String: Any])?["content"] as? String
            var runs: [MusicTextRun] = []
            if let shelf = (renderer["description"] as? [String: Any])?["musicDescriptionShelfRenderer"] as? [String: Any] { runs = descriptionRuns(shelf["description"]) }
            header = MusicPageHeader(title: title, subtitle: subtitle, secondSubtitle: second, credits: credits,
                                     byline: byline.flatMap { $0.utf8.count <= 256 ? $0 : nil }, description: runs,
                                     thumbnails: MusicBrowseParser.thumbnails(renderer["thumbnail"]), actions: actions)
        }
    }
}
