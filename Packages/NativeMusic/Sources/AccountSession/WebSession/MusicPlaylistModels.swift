import Foundation

/// Who may see a playlist. New playlists are `private` unless the person chooses otherwise.
public enum MusicPlaylistPrivacy: String, Sendable, Equatable, CaseIterable {
    case `private` = "PRIVATE"
    case unlisted = "UNLISTED"
    case `public` = "PUBLIC"
}

/// What the service's own page for a playlist says the signed-in person may do with it. Every field comes from something the page
/// published (an editable header, a delete endpoint); nothing is assumed from ownership, a name or a library list.
public struct MusicPlaylistEditing: Sendable, Equatable {
    /// The page's header is the service's editable one: title, description, privacy and the track list can be changed.
    public var canEditTracks: Bool
    /// The editable header published a title/description/privacy editor.
    public var canEditDetails: Bool
    /// The page published a delete command for this playlist (only its owner is offered one).
    public var canDelete: Bool
    public var privacy: MusicPlaylistPrivacy?
    /// The playlist the editable header says it is for (its edit header's `playlistId`), when it said. A reader that asked for another
    /// playlist does not trust a header that names a different one.
    public var playlistID: String?
    public init(canEditTracks: Bool, canEditDetails: Bool, canDelete: Bool, privacy: MusicPlaylistPrivacy?, playlistID: String? = nil) {
        self.canEditTracks = canEditTracks; self.canEditDetails = canEditDetails; self.canDelete = canDelete; self.privacy = privacy; self.playlistID = playlistID
    }
}

/// How a person relates to one playlist, derived only from `MusicPlaylistEditing` and the page's Save state.
public enum MusicPlaylistRole: String, Sendable, Equatable {
    /// The service offers deletion: the owner.
    case owner
    /// The service offers track editing but not deletion: a collaborator.
    case collaborator
    /// Saved to the library from someone else: no editing offered.
    case saved
    /// Anyone else looking at a public playlist.
    case viewer
    public var canEdit: Bool { self == .owner || self == .collaborator }
    public static func of(_ editing: MusicPlaylistEditing?, saved: Bool?) -> MusicPlaylistRole {
        if let editing, editing.canEditTracks { return editing.canDelete ? .owner : .collaborator }
        return saved == true ? .saved : .viewer
    }
}

/// The per-row remove command a signed playlist page publishes for one occurrence (`ACTION_REMOVE_VIDEO` with that row's `setVideoId`).
/// A row without one cannot be removed: nothing is built from the video id.
public struct MusicPlaylistRowRemoval: Sendable, Equatable {
    public let playlistID: String
    public let videoID: String
    public let setVideoID: String
    public init(playlistID: String, videoID: String, setVideoID: String) { self.playlistID = playlistID; self.videoID = videoID; self.setVideoID = setVideoID }
}

/// Whether adding a song the playlist already holds adds a second occurrence.
///
/// The wire mapping follows the references, not the names: the service checks for a duplicate by default and refuses the whole add when
/// the song is already there; `DEDUPE_OPTION_SKIP` skips *that check* (ytmusicapi `add_playlist_items`: "If True, duplicates will be
/// added", `if duplicates: action["dedupeOption"] = "DEDUPE_OPTION_SKIP"`; Kaset sends no option and relies on the server de-duping).
public enum MusicPlaylistDuplicateMode: String, Sendable, Equatable {
    /// Add it again: the playlist then holds the song twice, each with its own occurrence id. Sent with `DEDUPE_OPTION_SKIP`.
    case keepDuplicates
    /// Leave out any song the playlist already holds: filtered locally, and sent without the option so that a song that appeared in the
    /// meantime is refused by the service instead of duplicated.
    case skipExisting
}

/// One change inside a playlist edit. Removal and moving name the service's per-occurrence `setVideoId`, never the video id, so a song
/// that appears twice is changed where the person meant.
public enum MusicPlaylistEditAction: Sendable, Equatable {
    case add(videoID: String, duplicates: MusicPlaylistDuplicateMode)
    case remove(videoID: String, setVideoID: String)
    /// Moves one occurrence before another occurrence; a nil successor moves it to the end.
    case moveBefore(setVideoID: String, successorSetVideoID: String?)
    case rename(String)
    case describe(String)
    case setPrivacy(MusicPlaylistPrivacy)
    /// Enables collaboration and asks for an invite link (`ACTION_CREATE_COLLABORATION_INVITE_LINK`). Always a request of its own.
    case createInviteLink
    /// Closes the playlist to further contributions (`ACTION_SET_CLOSED_TO_CONTRIBUTIONS`, closed = true). Always a request of its own.
    case closeToContributions
    /// Joins a collaborative playlist with the `jct` value of an invite link (`ACTION_JOIN_COLLABORATION`). Always a request of its own.
    case joinCollaboration(token: String)
    /// Collaboration actions are never combined with anything else.
    var isCollaboration: Bool {
        switch self { case .createInviteLink, .closeToContributions, .joinCollaboration: true; default: false }
    }
}

/// A request that changes a playlist. Each one is sent only for an explicit action by the person.
public enum MusicPlaylistRequest: Sendable, Equatable {
    case create(title: String, description: String?, privacy: MusicPlaylistPrivacy, videoIDs: [String])
    case edit(playlistID: String, actions: [MusicPlaylistEditAction])
    case delete(playlistID: String)

    public static let maximumActions = 50
    public static let maximumTitleLength = 150
    public static let maximumDescriptionLength = 5000

    /// A playlist the person can edit has a `PL…` id. Albums (`OLAK5uy…`), generated mixes, Liked Music (`LM`), Watch Later (`WL`) and
    /// saved episodes (`SE`) are never edit targets here, whatever else the page says.
    public static func isEditablePlaylistID(_ id: String) -> Bool { id.range(of: #"^PL[A-Za-z0-9_-]{8,126}$"#, options: .regularExpression) != nil }
    /// The playlist id the service's `browse` page prefix (`VL…`) names, as the id edits use.
    public static func playlistID(fromBrowseID id: String) -> String { id.hasPrefix("VL") ? String(id.dropFirst(2)) : id }
    public static func isVideoID(_ id: String) -> Bool { id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil }
    /// The placeholder the service puts in a suggestion row where a member's occurrence id would be: never an occurrence.
    public static let suggestionPlaceholder = "to_be_updated_by_client"
    public static func isOccurrenceID(_ id: String) -> Bool { id != suggestionPlaceholder && id.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil }
    public static func isJoinToken(_ token: String) -> Bool { token.range(of: #"^[A-Za-z0-9_-]{8,128}$"#, options: .regularExpression) != nil }
    static func isTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximumTitleLength && !trimmed.contains("<") && !trimmed.contains(">")
            && !trimmed.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
    static func isDescription(_ text: String) -> Bool {
        text.count <= maximumDescriptionLength && !text.contains("<") && !text.contains(">")
    }

    /// Valid only if every identifier has the shape the service uses and the sizes are within what it accepts. Checked before anything is sent.
    public var isWellFormed: Bool {
        switch self {
        case .create(let title, let description, _, let videos):
            return Self.isTitle(title) && (description.map(Self.isDescription) ?? true) && videos.count <= Self.maximumActions && videos.allSatisfy(Self.isVideoID)
        case .delete(let id): return Self.isEditablePlaylistID(id)
        case .edit(let id, let actions):
            guard Self.isEditablePlaylistID(id), !actions.isEmpty, actions.count <= Self.maximumActions else { return false }
            if actions.contains(where: \.isCollaboration), actions.count != 1 { return false }
            return actions.allSatisfy { action in
                switch action {
                case .add(let video, _): return Self.isVideoID(video)
                case .remove(let video, let set): return Self.isVideoID(video) && Self.isOccurrenceID(set)
                case .moveBefore(let set, let successor): return Self.isOccurrenceID(set) && (successor.map(Self.isOccurrenceID) ?? true) && set != successor
                case .rename(let title): return Self.isTitle(title)
                case .describe(let text): return Self.isDescription(text)
                case .setPrivacy, .createInviteLink, .closeToContributions: return true
                case .joinCollaboration(let token): return Self.isJoinToken(token)
                }
            }
        }
    }
}

/// One occurrence the service reported adding.
public struct MusicPlaylistAddedOccurrence: Sendable, Equatable {
    public let videoID: String
    public let setVideoID: String
    public init(videoID: String, setVideoID: String) { self.videoID = videoID; self.setVideoID = setVideoID }
}

/// What a playlist request came to. Success needs the service's own positive statement (`STATUS_SUCCEEDED`, or a created playlist id).
public struct MusicPlaylistOutcome: Sendable, Equatable {
    public let outcome: MusicWriteOutcome
    /// The id the service gave a created playlist.
    public let createdPlaylistID: String?
    /// The occurrence ids the service reported for songs it added (it may report none; the playlist is then read back).
    public let added: [MusicPlaylistAddedOccurrence]
    /// The invite link the service returned for an invite request (`collaborationInviteLink`), as text; validated before it is shown.
    public let inviteLink: String?
    public init(outcome: MusicWriteOutcome, createdPlaylistID: String? = nil, added: [MusicPlaylistAddedOccurrence] = [], inviteLink: String? = nil) {
        self.outcome = outcome; self.createdPlaylistID = createdPlaylistID; self.added = added; self.inviteLink = inviteLink
    }
}
/// A playlist request answered for one account scope (the same fence as every other signed answer).
public struct MusicPlaylistReply: Sendable, Equatable {
    public let result: MusicPlaylistOutcome
    public let accountGeneration: UInt64
    public init(result: MusicPlaylistOutcome, accountGeneration: UInt64) { self.result = result; self.accountGeneration = accountGeneration }
}
