import AccountSession
import Foundation

/// A browse page the catalog screens can open: a browse id and, for moods, genres and "show all" lists, the
/// opaque parameters the service attached to the link.
public struct CatalogTarget: Hashable, Sendable {
    public let browseID: String
    public let params: String?
    public var key: String { browseID + (params.map { "?" + $0 } ?? "") }
    public init(browseID: String, params: String? = nil) { self.browseID = browseID; self.params = params }
    public static let home = CatalogTarget(browseID: "FEmusic_home")
    public static let explore = CatalogTarget(browseID: "FEmusic_explore")
    public static let newReleases = CatalogTarget(browseID: "FEmusic_new_releases")
    public static let charts = CatalogTarget(browseID: "FEmusic_charts")
    public static let moodsAndGenres = CatalogTarget(browseID: "FEmusic_moods_and_genres")

    /// The page an entry opens: the browse id it carried (episodes, songs and videos have no page of their own).
    public init?(item: MusicCatalogItem) {
        switch item.kind {
        case .album, .artist, .playlist, .podcast, .category:
            guard let id = item.browseID else { return nil }
            self.init(browseID: id, params: item.browseParams)
        case .song, .video, .episode: return nil
        }
    }
    /// A navigation route (kind + identifier) to a page. A playlist's route may carry the bare list id or the `VL` browse id.
    public init?(kind: MusicEntityKind, identifier: String) {
        guard identifier.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
        switch kind {
        case .artist, .album, .podcast: self.init(browseID: identifier)
        case .playlist: self.init(browseID: identifier.hasPrefix("VL") ? identifier : "VL" + identifier)
        case .category, .song, .video, .episode: return nil
        }
    }
    /// How long a read stays current before it is labelled stale: the visible, dynamic pages (Home, Explore, charts, new releases,
    /// moods) five minutes; stable catalog metadata (an album, an artist) twenty-four hours; anything else ten minutes.
    public var staleAfter: TimeInterval {
        if browseID.hasPrefix("FEmusic_") { return 300 }
        if browseID.hasPrefix("MPREb_") || browseID.hasPrefix("UC") { return 86_400 }
        return 600
    }
    public init(link: MusicLink) { self.init(browseID: link.browseID, params: link.params) }
}

public enum CatalogFailure: Sendable, Equatable {
    case offline, rateLimited, unavailable, unrecognised, scopeChanged
    init(_ error: any Error) {
        switch error as? MusicSessionError {
        case .network, .timedOut: self = .offline
        case .rateLimited: self = .rateLimited
        case .unrecognised, .oversized: self = .unrecognised
        default: self = .unavailable
        }
    }
    public var message: String {
        switch self {
        case .offline: String(localized: "YouTube Music couldn’t be reached. Check your connection and try again.")
        case .rateLimited: String(localized: "YouTube Music is asking for a pause. Try again in a moment.")
        case .unavailable: String(localized: "YouTube Music couldn’t answer this request. Try again.")
        case .unrecognised: String(localized: "YouTube Music sent a page in a form this version can’t read yet.")
        case .scopeChanged: String(localized: "Your account changed while this loaded. Try again.")
        }
    }
}

// MARK: Capability presentation

public enum CatalogAction: String, Sendable, Hashable, CaseIterable {
    case play, shuffle, radio, copyLink
    public var title: String {
        switch self {
        case .play: String(localized: "Play")
        case .shuffle: String(localized: "Shuffle")
        case .radio: String(localized: "Start Radio")
        case .copyLink: String(localized: "Copy Link")
        }
    }
    public var symbol: String {
        switch self { case .play: "play.fill"; case .shuffle: "shuffle"; case .radio: "dot.radiowaves.left.and.right"; case .copyLink: "link" }
    }
}
public struct CatalogActionOffer: Sendable, Equatable, Identifiable {
    public let action: CatalogAction
    /// Non-nil when the action exists but cannot run now; the reason is shown at the item.
    public let unavailable: String?
    public var id: CatalogAction { action }
    public var isAvailable: Bool { unavailable == nil }
}

/// The single table of what can be done with a catalog entry. Play and radio go to the hidden player as playlist ids
/// through the shared performer; nothing is offered that has no real implementation. Following and saving are the library
/// controls (`LibraryControls`), drawn only for a signed-in page that published them; `writeNote` says why otherwise.
public enum CatalogActionPlan {
    /// What the hidden player is asked to start: a playlist, optionally from a given track and/or with the parameters the service
    /// published for it (the shuffle flag).
    public struct PlayTarget: Sendable, Equatable {
        public let playlistID: String
        public let videoID: String?
        public let params: String?
        public init(playlistID: String, videoID: String? = nil, params: String? = nil) { self.playlistID = playlistID; self.videoID = videoID; self.params = params }
    }
    /// A song or video inside a collection plays that collection from this track (the playlist its own row names); a song
    /// the service seeded only with its own radio (`RDAMVM…`) plays that radio. An album, playlist or podcast plays the playlist
    /// its own play button names. Artists, categories and single episodes have no target here.
    public static func target(for item: MusicCatalogItem) -> PlayTarget? {
        switch item.kind {
        case .song, .video:
            // An uploaded track has no radio and no catalog collection; it plays from the Uploads library (a later version).
            guard let video = item.videoID, !item.isUpload else { return nil }
            if let context = item.contextPlaylistID, !context.hasPrefix("RDAMVM") { return PlayTarget(playlistID: context, videoID: video) }
            return PlayTarget(playlistID: "RDAMVM" + video)
        case .album, .playlist, .podcast: return item.playlistID.map { PlayTarget(playlistID: $0) }
        case .artist, .category, .episode: return nil
        }
    }
    public static func playlist(for item: MusicCatalogItem) -> String? { target(for: item)?.playlistID }
    /// Whether the track's Play continues a collection from this track (rather than starting the song's radio).
    public static func continuesCollection(_ item: MusicCatalogItem) -> Bool { target(for: item)?.videoID != nil }
    /// The song's own radio is what Play already starts; for collections the radio is the service's published mix.
    public static func link(for item: MusicCatalogItem) -> URL? {
        func make(_ path: String, _ query: [URLQueryItem] = []) -> URL? {
            var components = URLComponents()
            components.scheme = "https"; components.host = "music.youtube.com"; components.path = path
            if !query.isEmpty { components.queryItems = query }
            return components.url
        }
        switch item.kind {
        case .song, .video, .episode:
            // A private upload has no public link to copy.
            return item.isUpload ? nil : item.videoID.flatMap { make("/watch", [URLQueryItem(name: "v", value: $0)]) }
        case .album, .playlist, .podcast: return item.playlistID.flatMap { make("/playlist", [URLQueryItem(name: "list", value: $0)]) }
            ?? item.browseID.flatMap { make("/browse/" + $0) }
        case .artist: return item.browseID.flatMap { $0.hasPrefix("UC") ? make("/channel/" + $0) : nil }
        case .category: return nil
        }
    }
    /// Whether Play could ever run for this entry (it has a target and is playable for this listener). A Play control is only
    /// drawn when it could: where it never could (an unavailable track, a lone episode, an artist) the reason is text, not a button.
    public static func canEverPlay(_ item: MusicCatalogItem) -> Bool {
        item.availability != .unavailable && item.kind != .episode && playlist(for: item) != nil
    }
    public static func offers(for item: MusicCatalogItem, playback: SearchPlayback) -> [CatalogActionOffer] {
        var offers: [CatalogActionOffer] = []
        switch item.kind {
        case .artist, .category: break
        case .episode:
            // An episode plays from its own row or page (`PodcastsSurface.play`, which restores its speed and place), never from this table; no
            // "can't be played" is offered here, because it can.
            break
        default:
            if item.availability == .unavailable {
                offers.append(.init(action: .play, unavailable: String(localized: "This track isn’t available to you.")))
            } else if playlist(for: item) == nil {
                offers.append(.init(action: .play, unavailable: String(localized: "This item didn’t include anything to play.")))
            } else {
                offers.append(.init(action: .play, unavailable: playbackReason(playback)))
            }
        }
        if link(for: item) != nil { offers.append(.init(action: .copyLink, unavailable: nil)) }
        return offers
    }
    /// Play, Shuffle and Start Radio for a page, each only if the service published its playlist.
    public static func offers(for actions: MusicPageActions, playback: SearchPlayback) -> [CatalogActionOffer] {
        let reason = playbackReason(playback)
        var offers: [CatalogActionOffer] = []
        if actions.play != nil { offers.append(.init(action: .play, unavailable: reason)) }
        if shufflePublished(actions) { offers.append(.init(action: .shuffle, unavailable: reason)) }
        if actions.radio != nil { offers.append(.init(action: .radio, unavailable: reason)) }
        return offers
    }
    /// Shuffle exists only when the service published a Shuffle that differs from Play: its own playlist (an artist's shuffle mix),
    /// or the same playlist with the parameters that make it shuffle. A Shuffle that is just Play's playlist without parameters
    /// would replay in order and call it shuffled, so it is never offered.
    public static func shufflePublished(_ actions: MusicPageActions) -> Bool {
        guard let shuffle = actions.shuffle else { return false }
        return actions.shuffleParams != nil || shuffle != actions.play
    }
    public static func target(for action: CatalogAction, in actions: MusicPageActions) -> PlayTarget? {
        switch action {
        case .play: actions.play.map { PlayTarget(playlistID: $0) }
        case .shuffle: shufflePublished(actions) ? actions.shuffle.map { PlayTarget(playlistID: $0, params: actions.shuffleParams) } : nil
        case .radio: actions.radio.map { PlayTarget(playlistID: $0) }
        case .copyLink: nil
        }
    }
    public static func playlist(for action: CatalogAction, in actions: MusicPageActions) -> String? { target(for: action, in: actions)?.playlistID }
    static func playbackReason(_ playback: SearchPlayback) -> String? {
        switch playback {
        case .available: nil
        case .needsSignIn: String(localized: "Sign in to YouTube Music to play.")
        case .sessionExpired: String(localized: "Your session ended. Sign in again to play.")
        }
    }
    /// Shown once on a page whose service offers Save to library or Follow but where no control could be drawn: before sign-in (the
    /// changes need an account), or when the page did not publish what the change needs. Never a control, never inert.
    public static func writeNote(for actions: MusicPageActions?, signedIn: Bool = false) -> String? {
        guard let actions, actions.offersSave || actions.offersFollow else { return nil }
        if signedIn {
            return String(localized: "This page didn’t include what is needed to follow or save from here.")
        }
        if actions.offersFollow && actions.offersSave { return String(localized: "Following and saving to your library need a signed-in YouTube Music account.") }
        return actions.offersFollow
            ? String(localized: "Following needs a signed-in YouTube Music account.")
            : String(localized: "Saving to your library needs a signed-in YouTube Music account.")
    }
}

// MARK: Roles and detail projections

/// What a shelf is, from the kind of entries it holds (never from its localised title).
public enum CatalogShelfRole: String, Sendable, Equatable {
    case tracks, episodes, albums, singles, releases, editions, videos, playlists, artists, podcasts, categories, mixed
}
public enum CatalogShelves {
    public static func role(of shelf: MusicShelf, pageTitle: String? = nil) -> CatalogShelfRole {
        let kinds = Set(shelf.items.map(\.kind))
        guard !kinds.isEmpty else { return .mixed }
        if kinds == [.category] { return .categories }
        if kinds.isSubset(of: [.song, .video]), shelf.layout == .list { return .tracks }
        if kinds == [.episode] { return .episodes }
        if kinds.isSubset(of: [.video, .episode, .song]) { return kinds == [.song] ? .tracks : .videos }
        if kinds == [.playlist] { return .playlists }
        if kinds == [.artist] { return .artists }
        if kinds == [.podcast] { return .podcasts }
        if kinds == [.album] {
            if let pageTitle, !pageTitle.isEmpty {
                let prefix = fold(pageTitle)
                if shelf.items.allSatisfy({ fold($0.title).hasPrefix(prefix) }) { return .editions }
            }
            // The service prints a type label on singles and EPs and none on a plain album (an artist's own shelves); a shelf
            // that mixes labels ("Album", "Single") is a mixed list of releases. Labels are compared, never read.
            let labels = shelf.items.map(\.serviceLabel)
            if labels.allSatisfy({ $0 == nil }) { return .albums }
            return labels.allSatisfy({ $0 != nil }) && Set(labels).count == 1 ? .singles : .releases
        }
        return .mixed
    }
    static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).trimmingCharacters(in: .whitespaces) }
}

/// An artist page: top tracks, albums, singles, videos, playlists and related artists, in the service's order.
public struct ArtistDetail: Sendable, Equatable {
    public let header: MusicPageHeader
    public let topTracks: MusicShelf?
    public let albums: [MusicShelf]
    public let singles: [MusicShelf]
    public let videos: [MusicShelf]
    public let playlists: [MusicShelf]
    public let related: [MusicShelf]
    public let others: [MusicShelf]
    /// The service offers Follow on this page (a control only for a signed-in page that published what it acts on).
    public var offersFollow: Bool { header.actions.offersFollow }
    public init?(page: MusicBrowsePage) {
        guard let header = page.header else { return nil }
        self.header = header
        var tracks: MusicShelf?
        var albums: [MusicShelf] = [], singles: [MusicShelf] = [], videos: [MusicShelf] = [], playlists: [MusicShelf] = [], related: [MusicShelf] = [], others: [MusicShelf] = []
        for shelf in page.shelves {
            switch CatalogShelves.role(of: shelf) {
            case .tracks: if tracks == nil { tracks = shelf } else { others.append(shelf) }
            case .albums: albums.append(shelf)
            case .singles: singles.append(shelf)
            case .releases: albums.append(shelf)
            case .videos: videos.append(shelf)
            case .playlists: playlists.append(shelf)
            case .artists: related.append(shelf)
            default: others.append(shelf)
            }
        }
        topTracks = tracks; self.albums = albums; self.singles = singles; self.videos = videos; self.playlists = playlists; self.related = related; self.others = others
    }
}
/// An album page: its tracks, credited artists, other editions and the rest of the page.
public struct AlbumDetail: Sendable, Equatable {
    public let header: MusicPageHeader
    public let tracks: [MusicCatalogItem]
    public let editions: [MusicCatalogItem]
    /// The artists the album is credited to, linked. Writer and performer credits aren't part of this response.
    public var credits: [MusicLink] { header.credits }
    public let related: [MusicShelf]
    public var trackCountText: String? { header.secondSubtitle.first }
    public var durationText: String? { header.secondSubtitle.dropFirst().first }
    public init?(page: MusicBrowsePage) {
        guard let header = page.header else { return nil }
        self.header = header
        var tracks: [MusicCatalogItem] = [], editions: [MusicCatalogItem] = [], related: [MusicShelf] = []
        for shelf in page.shelves {
            switch CatalogShelves.role(of: shelf, pageTitle: header.title) {
            case .tracks where tracks.isEmpty: tracks = shelf.items
            case .editions where editions.isEmpty: editions = shelf.items
            default: related.append(shelf)
            }
        }
        self.tracks = tracks; self.editions = editions; self.related = related
    }
}
public enum SongQuality: Sendable, Equatable {
    /// YouTube Music's own player chooses the audio quality; this version neither measures nor selects it.
    case chosenByService
}
/// A song or video detail built from the entry the person opened (no request: the entry already carries its credits).
public struct SongDetail: Sendable, Equatable {
    public let item: MusicCatalogItem
    public var artists: [MusicLink] { item.links.filter { $0.kind == .artist } }
    public var album: MusicLink? { item.links.first { $0.kind == .album } }
    public var isAvailable: Bool { item.availability == .available }
    /// Nothing was read about this song (a page restored from history): availability is neither claimed nor denied.
    public var availabilityKnown: Bool { item.availability != .unknown }
    public let quality = SongQuality.chosenByService
    public init?(item: MusicCatalogItem) {
        guard item.kind == .song || item.kind == .video else { return nil }
        self.item = item
    }
    public func offers(playback: SearchPlayback) -> [CatalogActionOffer] { CatalogActionPlan.offers(for: item, playback: playback) }
}

// MARK: Refresh merge

/// Refresh keeps what is on screen where it is. Shelves the listener already has keep their order, and entries inside
/// them keep theirs; anything new is appended after what was visible, and a shelf the service no longer sends is
/// dropped unless it is the one the listener is looking at. This is the whole rule that stops a refresh from
/// reshuffling the page under the pointer.
public enum CatalogMerge {
    public static func refreshed(current: [MusicShelf], fresh: [MusicShelf], anchor: String?, extended: Set<String> = []) -> [MusicShelf] {
        var freshByKey: [String: MusicShelf] = [:]
        for shelf in fresh where freshByKey[shelf.key] == nil { freshByKey[shelf.key] = shelf }
        var result: [MusicShelf] = []
        var placed = Set<String>()
        for old in current {
            if let new = freshByKey[old.key] {
                result.append(merged(old, new, keepTail: extended.contains(old.key)))
            } else if old.key == anchor {
                result.append(old)
            } else { continue }
            placed.insert(old.key)
        }
        for new in fresh where placed.insert(new.key).inserted { result.append(new) }
        return result
    }
    static func merged(_ old: MusicShelf, _ new: MusicShelf, keepTail: Bool) -> MusicShelf {
        var newByID: [String: MusicCatalogItem] = [:]
        for item in new.items where newByID[item.id] == nil { newByID[item.id] = item }
        var kept: [MusicCatalogItem] = [], tail: [MusicCatalogItem] = []
        var keptIDs = Set<String>()
        for item in old.items {
            if let updated = newByID[item.id] { if keptIDs.insert(item.id).inserted { kept.append(updated) } }
            else if keepTail { tail.append(item) }
        }
        let added = new.items.filter { keptIDs.insert($0.id).inserted }
        var shelf = old
        shelf.items = kept + added + tail
        shelf.continuation = keepTail ? old.continuation : new.continuation
        return shelf
    }
    /// Appends the next entries of a shelf, dropping any the shelf already lists (a boundary entry is often repeated).
    public static func appended(_ items: [MusicCatalogItem], to shelf: MusicShelf) -> (shelf: MusicShelf, duplicates: Int) {
        var known = Set(shelf.items.map(\.id)), duplicates = 0
        var result = shelf
        for item in items { if known.insert(item.id).inserted { result.items.append(item) } else { duplicates += 1 } }
        return (result, duplicates)
    }
}
