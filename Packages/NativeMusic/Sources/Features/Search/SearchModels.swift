import AccountSession
import Domain
import Foundation

/// Where a search looks. `all` asks YouTube Music as well as this Mac; Library
/// is local only (no remote Library adapter exists yet, and the UI says so).
public enum SearchPlace: String, CaseIterable, Sendable, Identifiable {
    case all, library
    public var id: String { rawValue }
    public var title: String {
        switch self { case .all: String(localized: "All"); case .library: String(localized: "Library") }
    }
    public var asksService: Bool { self == .all }
}
/// Result groups in presentation order.
public enum SearchGroup: String, CaseIterable, Sendable, Identifiable {
    case top, songs, albums, artists, playlists, videos, podcasts, episodes
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .top: String(localized: "Top result"); case .songs: String(localized: "Songs"); case .albums: String(localized: "Albums")
        case .artists: String(localized: "Artists"); case .playlists: String(localized: "Playlists"); case .videos: String(localized: "Videos")
        case .podcasts: String(localized: "Podcasts"); case .episodes: String(localized: "Episodes")
        }
    }
    public static func group(for kind: MusicSearchKind) -> SearchGroup {
        switch kind {
        case .song: .songs; case .album: .albums; case .artist: .artists; case .playlist: .playlists
        case .video: .videos; case .podcast: .podcasts; case .episode: .episodes
        }
    }
}
public extension MusicSearchKind {
    var typeName: String {
        switch self {
        case .song: String(localized: "Song"); case .video: String(localized: "Video"); case .album: String(localized: "Album")
        case .artist: String(localized: "Artist"); case .playlist: String(localized: "Playlist"); case .podcast: String(localized: "Podcast")
        case .episode: String(localized: "Episode")
        }
    }
    var symbol: String {
        switch self {
        case .song: "music.note"; case .video: "play.rectangle"; case .album: "square.stack"; case .artist: "person.crop.circle"
        case .playlist: "music.note.list"; case .podcast: "mic"; case .episode: "waveform"
        }
    }
}
/// Badges follow the item through every scope and merge when a local and a service
/// result are the same item.
public enum SearchBadge: String, CaseIterable, Sendable, Comparable {
    case explicit, library, local, recent, service, approximate
    public var title: String {
        switch self {
        case .explicit: String(localized: "Explicit"); case .library: String(localized: "In your library")
        case .local: String(localized: "On this Mac"); case .recent: String(localized: "Recent"); case .service: String(localized: "YouTube Music")
        case .approximate: String(localized: "Approximate match")
        }
    }
    public var symbol: String {
        switch self {
        case .explicit: "e.square"; case .library: "books.vertical"; case .local: "internaldrive"; case .recent: "clock"
        case .service: "play.circle"; case .approximate: "textformat.abc"
        }
    }
    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}
/// The identifiers a result carries. Nothing here is guessed from a title.
public struct SearchTarget: Sendable, Equatable {
    public var videoID: String?, browseID: String?, playlistID: String?
    public init(videoID: String? = nil, browseID: String? = nil, playlistID: String? = nil) {
        self.videoID = videoID; self.browseID = browseID; self.playlistID = playlistID
    }
}
public enum SearchDetail {
    /// Between the parts of a result's detail line. A catalog entry, so a language can change it.
    public static var separator: String { String(localized: "detailSeparator", defaultValue: " • ", comment: "Separates the parts of a result's detail line, such as artist and duration") }
    public static func join(_ parts: [String]) -> String? { parts.isEmpty ? nil : parts.joined(separator: separator) }
}
public struct SearchResult: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: MusicSearchKind
    public let title: String
    /// The parts of the detail line, in order (artist, album, duration, plays…). Never pre-joined.
    public let details: [String]
    /// The service's own type label for albums ("Album", "Single", "EP"); other kinds use the app's own names.
    public let serviceLabel: String?
    public var badges: Set<SearchBadge>
    public let target: SearchTarget
    public var group: SearchGroup
    public let fromService: Bool
    public let quality: SearchMatchQuality?
    public var subtitle: String? { SearchDetail.join(details) }
    /// Results that have a page of their own: an artist, album, playlist or show by its browse id, a song or video by its id.
    public var opensPage: Bool {
        switch kind {
        case .artist, .album, .playlist, .podcast: target.browseID != nil
        case .song, .video: target.videoID != nil
        case .episode: target.browseID?.hasPrefix("MPED") == true
        }
    }
    public init(kind: MusicSearchKind, title: String, details: [String], serviceLabel: String? = nil, badges: Set<SearchBadge>, target: SearchTarget,
                group: SearchGroup? = nil, fromService: Bool, quality: SearchMatchQuality? = nil) {
        self.kind = kind; self.title = title; self.details = details; self.serviceLabel = serviceLabel; self.badges = badges; self.target = target
        self.group = group ?? SearchGroup.group(for: kind); self.fromService = fromService; self.quality = quality
        id = Self.identity(kind: kind, target: target, title: title)
    }
    public init(kind: MusicSearchKind, title: String, subtitle: String?, badges: Set<SearchBadge>, target: SearchTarget,
                group: SearchGroup? = nil, fromService: Bool, quality: SearchMatchQuality? = nil) {
        self.init(kind: kind, title: title, details: subtitle.map { [$0] } ?? [], badges: badges, target: target, group: group, fromService: fromService, quality: quality)
    }
    /// One item gets one identity whether a library read or the service named it.
    static func identity(kind: MusicSearchKind, target: SearchTarget, title: String) -> String {
        let playlist = target.playlistID ?? target.browseID.map { $0.hasPrefix("VL") ? String($0.dropFirst(2)) : $0 }
        switch kind {
        case .song, .video, .episode: return kind.rawValue + ":" + (target.videoID ?? target.browseID ?? title)
        case .playlist: return kind.rawValue + ":" + (playlist ?? title)
        case .album, .podcast: return kind.rawValue + ":" + (target.browseID ?? target.playlistID ?? title)
        case .artist: return kind.rawValue + ":" + (target.browseID ?? title)
        }
    }
    public init(_ item: MusicSearchItem, top: Bool, approximate: Bool = false) {
        var badges: Set<SearchBadge> = [.service]
        if item.explicit { badges.insert(.explicit) }
        if approximate { badges.insert(.approximate) }
        self.init(kind: item.kind, title: item.title, details: item.details, serviceLabel: item.serviceLabel, badges: badges,
                  target: SearchTarget(videoID: item.videoID, browseID: item.browseID, playlistID: item.playlistID),
                  group: top ? .top : nil, fromService: true)
    }
    /// The same item seen twice: keep the service's description, union the badges.
    func merged(with other: SearchResult) -> SearchResult {
        var copy = fromService ? self : other
        copy.badges = badges.union(other.badges)
        return copy
    }
    /// What the row calls this kind of result: the service's label for an album (so a Single stays a Single).
    public var typeLabel: String { serviceLabel ?? kind.typeName }
}
public struct SearchSection: Identifiable, Sendable, Equatable {
    public let group: SearchGroup
    public let results: [SearchResult]
    public var id: SearchGroup { group }
}

/// What the person can do with a result. Only actions with a real implementation are offered.
public enum SearchAction: String, Sendable, Hashable, CaseIterable {
    case play, copyLink
    public var title: String {
        switch self { case .play: String(localized: "Play"); case .copyLink: String(localized: "Copy Link") }
    }
    public var symbol: String { self == .play ? "play.fill" : "link" }
}
public struct SearchActionOffer: Sendable, Equatable, Identifiable {
    public let action: SearchAction
    /// Non-nil when the action exists but cannot run for this item right now. Shown at the item.
    public let unavailable: String?
    public var id: SearchAction { action }
    public var isAvailable: Bool { unavailable == nil }
}
public enum SearchPlayback: Sendable, Equatable {
    case available, needsSignIn, sessionExpired
}
public enum SearchActionPlan {
    /// A song or video plays as its own radio seed; an album, playlist or podcast plays the
    /// playlist its own play button names. Nothing else has a play target.
    public static func playlist(for result: SearchResult) -> String? {
        switch result.kind {
        case .song, .video: result.target.videoID.map { "RDAMVM" + $0 }
        case .album, .playlist, .podcast: result.target.playlistID
        case .artist, .episode: nil
        }
    }
    public static func link(for result: SearchResult) -> URL? {
        func make(_ path: String, _ query: [URLQueryItem] = []) -> URL? {
            var components = URLComponents()
            components.scheme = "https"; components.host = "music.youtube.com"; components.path = path
            if !query.isEmpty { components.queryItems = query }
            return components.url
        }
        switch result.kind {
        case .song, .video, .episode: return result.target.videoID.flatMap { make("/watch", [URLQueryItem(name: "v", value: $0)]) }
        case .album, .playlist, .podcast: return result.target.playlistID.flatMap { make("/playlist", [URLQueryItem(name: "list", value: $0)]) }
        case .artist: return result.target.browseID.flatMap { $0.hasPrefix("UC") ? make("/channel/" + $0) : nil }
        }
    }
    public static func offers(for result: SearchResult, playback: SearchPlayback) -> [SearchActionOffer] {
        var offers: [SearchActionOffer] = []
        switch result.kind {
        case .artist: break
        case .episode:
            offers.append(.init(action: .play, unavailable: String(localized: "Single episodes can’t be played from search yet.")))
        default:
            if playlist(for: result) == nil {
                offers.append(.init(action: .play, unavailable: String(localized: "This result didn’t include anything to play.")))
            } else {
                switch playback {
                case .available: offers.append(.init(action: .play, unavailable: nil))
                case .needsSignIn: offers.append(.init(action: .play, unavailable: String(localized: "Sign in to YouTube Music to play.")))
                case .sessionExpired: offers.append(.init(action: .play, unavailable: String(localized: "Your session ended. Sign in again to play.")))
                }
            }
        }
        if link(for: result) != nil { offers.append(.init(action: .copyLink, unavailable: nil)) }
        return offers
    }
}
/// `stale`: the account or permit changed before the start. `busy`: another start was already in progress.
public enum SearchPlayOutcome: Sendable, Equatable { case started, stale, busy, failed }
/// Where actions land. The app shell implements this over the one application playback
/// session, so Return, the context menu, the palette and the media keys share a path.
@MainActor public protocol SearchActionPerformer: AnyObject {
    var supportsRadioQueueUpdates: Bool { get }
    func captureRadioQueueScope(playlistID: String) -> UUID?
    func radioQueueScopeIsCurrent(_ scope: UUID) -> Bool
    func applyRadioFilter(_ command: MusicQueueFilterCommand, scope: UUID) async -> SearchPlayOutcome
    func playRadioFilter(_ command: MusicQueueFilterCommand, title: String) async -> SearchPlayOutcome
    func play(playlistID: String, title: String) async -> SearchPlayOutcome
    /// Plays a published endpoint; opaque parameters do not imply Shuffle.
    func play(playlistID: String, title: String, videoID: String?, params: String?) async -> SearchPlayOutcome
    func play(playlistID: String, title: String, videoID: String?, params: String?, intent: MusicPlaybackIntent) async -> SearchPlayOutcome
    func copy(link: URL)
    /// Copies plain text (the links of a selection, one per line).
    func copy(text: String)
}
extension SearchActionPerformer {
    public var supportsRadioQueueUpdates: Bool { false }
    public func captureRadioQueueScope(playlistID: String) -> UUID? { nil }
    public func radioQueueScopeIsCurrent(_ scope: UUID) -> Bool { false }
    public func applyRadioFilter(_ command: MusicQueueFilterCommand, scope: UUID) async -> SearchPlayOutcome { .failed }
    /// Never degrade a queue update to a plain endpoint, including in legacy performers.
    public func playRadioFilter(_ command: MusicQueueFilterCommand, title: String) async -> SearchPlayOutcome { .failed }
    public func play(playlistID: String, title: String, videoID: String?, params: String?, intent: MusicPlaybackIntent) async -> SearchPlayOutcome {
        guard intent == .endpoint else { return .failed }
        return await play(playlistID: playlistID, title: title, videoID: videoID, params: params)
    }
    public func copy(text: String) { if let first = text.split(separator: "\n").first, let url = URL(string: String(first)) { copy(link: url) } }
    /// A performer that cannot carry a track or parameters refuses them rather than quietly playing something else.
    public func play(playlistID: String, title: String, videoID: String?, params: String?) async -> SearchPlayOutcome {
        guard videoID == nil, params == nil else { return .failed }
        return await play(playlistID: playlistID, title: title)
    }
}
public enum SearchItemFeedback: Sendable, Equatable {
    case working
    case failed(String)
    case started
    case copied
}
