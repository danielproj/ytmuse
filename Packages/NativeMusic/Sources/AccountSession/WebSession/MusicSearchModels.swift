import Foundation

/// What a YouTube Music search row is. Classified from the row's own typed endpoints
/// (never from a localised shelf title), so it holds in every interface language.
public enum MusicSearchKind: String, Sendable, Codable, CaseIterable {
    case song, video, album, artist, playlist, podcast, episode
}
/// One parsed `search` row. Only identifiers the row itself carried are present; a
/// missing playable target is a fact the UI reports at the item, not something to guess.
public struct MusicSearchItem: Sendable, Equatable, Identifiable {
    public let kind: MusicSearchKind
    public let title: String
    /// The parts of the detail line as published (artist, album, year, counts, plays), in order and
    /// without the service's type label. Presentation joins them; the parser never glues them together.
    public let details: [String]
    /// The service's own type label for an album row ("Album", "Single", "EP"), in the requested language.
    public let serviceLabel: String?
    public let explicit: Bool
    /// Songs and videos.
    public let videoID: String?
    /// Albums, artists, playlists, podcasts and episodes: the page this row opens.
    public let browseID: String?
    /// The playlist the row's own play button starts (album, playlist, podcast).
    public let playlistID: String?
    public var id: String { kind.rawValue + ":" + (videoID ?? browseID ?? playlistID ?? title) }
    /// The detail parts joined with the plain bullet the service itself uses (not localised; for logs-free comparison).
    public var subtitle: String? { details.isEmpty ? nil : details.joined(separator: " • ") }
    public init(kind: MusicSearchKind, title: String, details: [String], serviceLabel: String? = nil, explicit: Bool = false,
                videoID: String? = nil, browseID: String? = nil, playlistID: String? = nil) {
        self.kind = kind; self.title = title; self.details = details; self.serviceLabel = serviceLabel; self.explicit = explicit
        self.videoID = videoID; self.browseID = browseID; self.playlistID = playlistID
    }
    public init(kind: MusicSearchKind, title: String, subtitle: String?, explicit: Bool = false,
                videoID: String? = nil, browseID: String? = nil, playlistID: String? = nil) {
        self.init(kind: kind, title: title, details: subtitle.map { $0.components(separatedBy: " • ") } ?? [], explicit: explicit,
                  videoID: videoID, browseID: browseID, playlistID: playlistID)
    }
}
/// A spelling the service offered. Never applied by the client on its own.
public struct MusicSearchSuggestion: Sendable, Equatable {
    public let text: String
    /// The service already ran the corrected query ("showing results for"), rather than
    /// only suggesting it ("did you mean").
    public let appliedByService: Bool
    public init(text: String, appliedByService: Bool) { self.text = text; self.appliedByService = appliedByService }
}
public struct MusicSearchResponse: Sendable, Equatable {
    public let top: MusicSearchItem?
    /// Every other recognised row, in service order.
    public let items: [MusicSearchItem]
    public let suggestion: MusicSearchSuggestion?
    /// Rows that looked like results but could not be read. Never silently dropped.
    public let skippedRows: Int
    /// Rows of a kind the app does not present (for example a channel profile). Counted, not hidden.
    public let unsupportedRows: Int
    /// Rows that repeated an item already listed (for example a song in the top card and again below).
    /// Every row read is one of: the top result, a listed item, skipped, unsupported or a duplicate.
    public let duplicateRows: Int
    /// The service said it has nothing for this query (an explicit message, not a missing shelf).
    public let serviceReportedNoResults: Bool
    /// Always false today: no continuation is followed, so this is one page, not the catalog.
    public let complete: Bool
    public init(top: MusicSearchItem?, items: [MusicSearchItem], suggestion: MusicSearchSuggestion?, skippedRows: Int,
                unsupportedRows: Int = 0, duplicateRows: Int = 0, serviceReportedNoResults: Bool = false, complete: Bool = false) {
        self.top = top; self.items = items; self.suggestion = suggestion; self.skippedRows = skippedRows; self.unsupportedRows = unsupportedRows; self.duplicateRows = duplicateRows
        self.serviceReportedNoResults = serviceReportedNoResults; self.complete = complete
    }
}
/// A search answered for one account scope. The scope is read when the request starts
/// and re-checked against the lifecycle before this value is returned.
public struct MusicSearchReply: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable { case signedIn, anonymous }
    public let response: MusicSearchResponse
    public let mode: Mode
    /// The account generation the request belonged to (0 when no account was active).
    public let accountGeneration: UInt64
    /// The active account's session had ended; this answer is the anonymous one.
    public let sessionExpired: Bool
    public init(response: MusicSearchResponse, mode: Mode, accountGeneration: UInt64, sessionExpired: Bool = false) {
        self.response = response; self.mode = mode; self.accountGeneration = accountGeneration; self.sessionExpired = sessionExpired
    }
}
