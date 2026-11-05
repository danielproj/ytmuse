import Domain
import Foundation

/// What a catalog entry on a Home, Explore or detail page is. Classified from the entry's own typed
/// endpoints (`pageType`, `musicVideoType`), never from a localised title.
public enum MusicEntityKind: String, Sendable, Codable, CaseIterable {
    case song, video, album, artist, playlist, podcast, episode
    /// A navigation tile that opens another browse page (a mood, a genre, Charts, New releases…).
    case category
}
/// One image the service offered for an entry (the parser keeps every published size, in order).
public struct MusicThumbnail: Sendable, Equatable {
    public let url: URL
    public let width: Int
    public let height: Int
    public init(url: URL, width: Int, height: Int) { self.url = url; self.width = width; self.height = height }
}
/// A run of text inside a detail line that links to another page (an artist, an album).
public struct MusicLink: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable { case artist, album, playlist, podcast, other }
    public let kind: Kind
    public let title: String
    public let browseID: String
    /// Opaque parameters the service attached to the page ("Show all" lists need them).
    public let params: String?
    public init(kind: Kind, title: String, browseID: String, params: String? = nil) { self.kind = kind; self.title = title; self.browseID = browseID; self.params = params }
}
public enum MusicAvailability: String, Sendable, Equatable {
    case available
    /// Nothing was read about this entry (for example a song page restored from history without its details).
    case unknown
    /// The service greys the entry out (not playable for this listener); it is shown, not hidden or invented away.
    case unavailable
}
/// A radio the service itself presents for an entry or a page: the endpoint of its own "Start mix" / radio action (menu item with the `MIX`
/// icon, or the page's `startRadioButton`). Nothing is derived from an id prefix: a curated playlist's play button is not a radio.
public struct MusicRadioAction: Sendable, Equatable, Hashable {
    /// The radio playlist the action names.
    public let playlistID: String
    /// For a song's radio: the track the action starts from.
    public let videoID: String?
    /// The parameters the action's endpoint carried (a radio endpoint in the real captures carries them), sent unchanged.
    public let params: String?
    /// Additional opaque player options carried by a published queue fetch endpoint.
    public let playerParams: String?
    public init(playlistID: String, videoID: String? = nil, params: String? = nil, playerParams: String? = nil) {
        self.playlistID = playlistID; self.videoID = videoID; self.params = params; self.playerParams = playerParams
    }
}
/// One entry of a shelf, grid, track list or navigation tile. Only identifiers the entry itself carried are present.
public struct MusicCatalogItem: Sendable, Equatable, Identifiable {
    public let kind: MusicEntityKind
    public let title: String
    /// The detail line as published, split at the service's bullets, without the type label.
    public let details: [String]
    /// The service's own type label ("Single", "EP", "Album", "Chart"), in the requested language, when it printed one.
    public let serviceLabel: String?
    public let explicit: Bool
    public let availability: MusicAvailability
    /// Songs, videos and episodes.
    public let videoID: String?
    /// The page this entry opens (album, artist, playlist, podcast, category, episode page).
    public let browseID: String?
    /// Opaque parameters the service attached to the page it opens (moods and genres need them).
    public let browseParams: String?
    /// The playlist the entry's own play button starts (album, playlist, podcast, and any song the service seeded with one).
    public let playlistID: String?
    /// For a song or video: the playlist its row sits in, as its own endpoint names it (an album's `OLAK5uy_…`, a playlist, or the
    /// song's own radio). Playing the row from that playlist continues the collection from this track.
    public let contextPlaylistID: String?
    public let thumbnails: [MusicThumbnail]
    /// Artists, albums and similar linked in the detail line.
    public let links: [MusicLink]
    /// Track number or chart rank, as printed.
    public let position: String?
    /// Track length as printed ("4:36"), from the fixed column.
    public let durationText: String?
    /// The service's identity for this occurrence inside a playlist (the same song can appear twice).
    public let occurrenceID: String?
    /// The write controls the entry published for itself (rate, save, follow); nil when it published none.
    public let controls: MusicItemControls?
    /// Private service media has no supported catalog playback or public share target.
    public let isPrivatelyOwned: Bool
    /// The radio the entry's own menu offers ("Start mix"), when it offers exactly one. Nil: the entry published none.
    public let radio: MusicRadioAction?
    /// An episode's progress and menu facts as its row printed them (W18); nil for every other kind and for an episode row that printed none.
    public let episode: MusicEpisodeInfo?
    public var id: String {
        if let occurrenceID { return kind.rawValue + "#" + occurrenceID }
        return kind.rawValue + ":" + (videoID ?? browseID.map { $0 + (browseParams.map { "?" + $0 } ?? "") } ?? playlistID ?? title)
    }
    /// The detail parts joined with the bullet the service itself uses (for comparison only; presentation localises its own separator).
    public var subtitle: String? { details.isEmpty ? nil : details.joined(separator: " • ") }
    public init(kind: MusicEntityKind, title: String, details: [String] = [], serviceLabel: String? = nil, explicit: Bool = false,
                availability: MusicAvailability = .available, videoID: String? = nil, browseID: String? = nil, browseParams: String? = nil,
                playlistID: String? = nil, contextPlaylistID: String? = nil, thumbnails: [MusicThumbnail] = [], links: [MusicLink] = [], position: String? = nil,
                durationText: String? = nil, occurrenceID: String? = nil, controls: MusicItemControls? = nil, isPrivatelyOwned: Bool = false,
                radio: MusicRadioAction? = nil, episode: MusicEpisodeInfo? = nil) {
        self.kind = kind; self.title = title; self.details = details; self.serviceLabel = serviceLabel; self.explicit = explicit
        self.availability = availability; self.videoID = videoID; self.browseID = browseID; self.browseParams = browseParams
        self.playlistID = playlistID; self.contextPlaylistID = contextPlaylistID; self.thumbnails = thumbnails; self.links = links; self.position = position
        self.durationText = durationText; self.occurrenceID = occurrenceID; self.controls = controls; self.isPrivatelyOwned = isPrivatelyOwned
        self.radio = radio; self.episode = episode
    }
}
/// A run of description text, with the service's link when the run carried one. Untrusted: rendering is
/// `CatalogRichText`'s job and it decides which links survive.
public struct MusicTextRun: Sendable, Equatable {
    public let text: String
    public let url: URL?
    public init(text: String, url: URL? = nil) { self.text = text; self.url = url }
}
public struct MusicShelf: Sendable, Equatable, Identifiable {
    public enum Layout: String, Sendable { case carousel, list, grid, categories }
    /// Stable within a page: the service's shelf id, else layout + title + occurrence.
    public let key: String
    public let title: String?
    public let layout: Layout
    public var items: [MusicCatalogItem]
    /// "More" / "Show all": the page that lists the whole shelf.
    public let more: MusicLink?
    /// Opaque token that fetches the next items of this shelf.
    public var continuation: String?
    /// List rows the service stacks into one column of a horizontally scrolling shelf (Quick picks: 4).
    public let rowsPerColumn: Int?
    public var id: String { key }
    public init(key: String, title: String?, layout: Layout, items: [MusicCatalogItem], more: MusicLink? = nil, continuation: String? = nil, rowsPerColumn: Int? = nil) {
        self.key = key; self.title = title; self.layout = layout; self.items = items; self.more = more; self.continuation = continuation; self.rowsPerColumn = rowsPerColumn
    }
}
/// A mood chip on Home (the service's own filter, a browse request with parameters).
public struct MusicChip: Sendable, Equatable, Hashable {
    public let title: String
    public let browseID: String
    public let params: String?
    public let selected: Bool
    public init(title: String, browseID: String, params: String?, selected: Bool) { self.title = title; self.browseID = browseID; self.params = params; self.selected = selected }
}
/// Playlist ids the service itself published for a page's Play / Shuffle / Mix buttons. Nothing is derived.
public struct MusicPageActions: Sendable, Equatable {
    public var play: String?
    public var shuffle: String?
    /// The parameters the service attached to its Shuffle endpoint (the flag that makes the same playlist play shuffled).
    public var shuffleParams: String?
    public var radio: String?
    /// The radio action in full (playlist, track and the endpoint's parameters), when the page published one.
    public var radioAction: MusicRadioAction?
    /// The service offers Save to library / Subscribe on this page. They are controls only when the page also published what they
    /// act on (`controls`) and the person is signed in; otherwise they are reported as a capability.
    public var offersSave = false
    public var offersFollow = false
    /// What the page's own Save and Follow controls act on and their current state, when the page published them.
    public var controls = MusicItemControls()
    public init(play: String? = nil, shuffle: String? = nil, shuffleParams: String? = nil, radio: String? = nil, radioAction: MusicRadioAction? = nil,
                offersSave: Bool = false, offersFollow: Bool = false, controls: MusicItemControls = .init()) {
        self.play = play; self.shuffle = shuffle; self.shuffleParams = shuffleParams; self.radio = radio; self.radioAction = radioAction; self.offersSave = offersSave; self.offersFollow = offersFollow
        self.controls = controls
    }
}
public struct MusicPageHeader: Sendable, Equatable {
    public var title: String
    /// "Album • 2013" split at bullets; the first part is the service's type label when it has no endpoint.
    public var subtitle: [String]
    /// "13 songs • 1 hour, 14 minutes".
    public var secondSubtitle: [String]
    /// The credited artists / owner printed under the title, linked.
    public var credits: [MusicLink]
    /// The owner of a playlist as printed (an unlinked name).
    public var byline: String?
    public var description: [MusicTextRun]
    public var thumbnails: [MusicThumbnail]
    /// "7.2M subscribers" / "24.4M monthly audience", as printed.
    public var audienceText: String?
    public var actions: MusicPageActions
    /// What the page published about changing this playlist (nil: nothing, so nothing is offered).
    public var editing: MusicPlaylistEditing?
    public init(title: String, subtitle: [String] = [], secondSubtitle: [String] = [], credits: [MusicLink] = [], byline: String? = nil, description: [MusicTextRun] = [],
                thumbnails: [MusicThumbnail] = [], audienceText: String? = nil, actions: MusicPageActions = .init(), editing: MusicPlaylistEditing? = nil) {
        self.title = title; self.subtitle = subtitle; self.secondSubtitle = secondSubtitle; self.credits = credits; self.byline = byline; self.description = description
        self.thumbnails = thumbnails; self.audienceText = audienceText; self.actions = actions; self.editing = editing
    }
}
/// Where every renderer the parser met ended up. `sections == shelves + headerSections + furniture + unsupportedSections`
/// and `items == classified + skipped + unsupported + duplicates` always hold; a test fails if either stops holding on a real capture.
public struct MusicParseAccounting: Sendable, Equatable {
    public var sections = 0
    public var shelves = 0
    /// Sections folded into the page header (an album's header section, an artist's description).
    public var headerSections = 0
    /// Layout-only sections (a chart's region picker with no entries).
    public var furniture = 0
    public var unsupportedSections = 0
    public var unsupportedSectionNames: [String] = []
    public var items = 0
    public var classified = 0
    /// Recognisably an entry but unreadable (no title, no usable identifier).
    public var skipped = 0
    /// A kind of entry the app does not present (a channel profile, an unknown page type).
    public var unsupported = 0
    /// An entry repeating one already listed in the same shelf (or an earlier page of it).
    public var duplicates = 0
    /// Pagination markers (`continuationItemRenderer`): not entries.
    public var continuationMarkers = 0
    /// Non-content renderers deliberately ignored (filter menus, headers the page does not use), by renderer name.
    public var ignoredRenderers: [String] = []
    public var consistent: Bool {
        sections == shelves + headerSections + furniture + unsupportedSections && items == classified + skipped + unsupported + duplicates
    }
    public init() {}
    public mutating func add(_ other: MusicParseAccounting) {
        sections += other.sections; shelves += other.shelves; headerSections += other.headerSections; furniture += other.furniture
        unsupportedSections += other.unsupportedSections; unsupportedSectionNames += other.unsupportedSectionNames
        items += other.items; classified += other.classified; skipped += other.skipped; unsupported += other.unsupported
        duplicates += other.duplicates; continuationMarkers += other.continuationMarkers; ignoredRenderers += other.ignoredRenderers
    }
}
public struct MusicBrowsePage: Sendable, Equatable {
    /// The page's own heading from a plain header (Charts, New releases…), when it has one and no richer header.
    public var heading: String?
    public var header: MusicPageHeader?
    public var chips: [MusicChip]
    public var shelves: [MusicShelf]
    /// Fetches the page's next sections (Home loads more shelves as the listener scrolls).
    public var continuation: String?
    /// `true` once no shelf or page continuation is left to follow.
    public var complete: Bool { continuation == nil && shelves.allSatisfy { $0.continuation == nil } }
    public var accounting: MusicParseAccounting
    public init(heading: String? = nil, header: MusicPageHeader? = nil, chips: [MusicChip] = [], shelves: [MusicShelf], continuation: String? = nil,
                accounting: MusicParseAccounting = .init()) {
        self.heading = heading; self.header = header; self.chips = chips; self.shelves = shelves; self.continuation = continuation; self.accounting = accounting
    }
}
/// The answer to a continuation token: more entries for one shelf, or more sections for the page.
public struct MusicContinuationPage: Sendable, Equatable {
    public var items: [MusicCatalogItem]
    public var shelves: [MusicShelf]
    public var continuation: String?
    public var accounting: MusicParseAccounting
    public init(items: [MusicCatalogItem], shelves: [MusicShelf], continuation: String?, accounting: MusicParseAccounting = .init()) {
        self.items = items; self.shelves = shelves; self.continuation = continuation; self.accounting = accounting
    }
}
/// A browse answered for one account scope (same fence as `MusicSearchReply`).
public struct MusicBrowseReply<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value
    public let mode: MusicSearchReply.Mode
    public let accountGeneration: UInt64
    public let sessionExpired: Bool
    public init(value: Value, mode: MusicSearchReply.Mode, accountGeneration: UInt64, sessionExpired: Bool = false) {
        self.value = value; self.mode = mode; self.accountGeneration = accountGeneration; self.sessionExpired = sessionExpired
    }
}
/// What a browse request asks for. Identifiers are validated by the adapter before anything is sent.
public enum MusicBrowseRequest: Sendable, Equatable {
    case page(id: String, params: String?)
    case continuation(String)
}

/// One radio-queue filter the service attached to a radio's queue ("Popular"): a chip whose endpoint is a watch-playlist endpoint with
/// the radio playlist and the parameters that select the filter. Selecting it is a new queue request with these parameters.
public struct MusicRadioChip: Sendable, Equatable {
    public let title: String
    public let isSelected: Bool
    public let playlistID: String
    public let params: String
    /// Additional published playback semantics. Retained verbatim; the shared playback path cannot apply these yet.
    public let playerParams: String?
    /// The queue section the chip's own command names.
    public let section: MusicQueueUpdateSection
    public init(title: String, isSelected: Bool, playlistID: String, params: String, playerParams: String? = nil, section: MusicQueueUpdateSection = .autoplay) {
        self.title = title; self.isSelected = isSelected; self.playlistID = playlistID; self.params = params; self.playerParams = playerParams; self.section = section
    }
}
/// What a radio's queue (`next`) response says about tuning that radio. Empty `chips` is a real answer only when a queue response was read.
public struct MusicRadioQueue: Sendable, Equatable {
    public let chips: [MusicRadioChip]
    public init(chips: [MusicRadioChip]) { self.chips = chips }
}
/// The queue request a radio is started or filtered with. This is the seam where a radio's tuner settings arrive; nothing in the application
/// uses the reference-only tuner setting below in production. Production queue reads forward only published action values.
public enum MusicRadioQueueRequest: Sendable, Equatable {
    /// Start a radio from its service action. `tunerSetting` is sent as the request's `tunerSettingValue`.
    case start(MusicRadioAction, tunerSetting: String)
    /// Select one of the queue's own filter chips.
    case filter(MusicRadioChip)
    /// The tuner setting a plain radio start is sent with in the reference client (read from its source; not observed live).
    public static let normalTunerSetting = "AUTOMIX_SETTING_NORMAL"
}
