import AccountSession
import CryptoKit
import Foundation

/// One song's place in a playlist. The service's `setVideoId` is this place's identity (the same song twice is two occurrences with two
/// ids), so every removal, move and settle works on `setVideoID` and never on the video id.
public struct PlaylistOccurrence: Sendable, Equatable, Hashable, Identifiable {
    public let setVideoID: String
    public let videoID: String
    public let title: String
    public let subtitle: String?
    public let isAvailable: Bool
    /// The page published a remove command for exactly this occurrence. Without one, removal is not offered.
    public let removable: Bool
    public var id: String { setVideoID }
    public init(setVideoID: String, videoID: String, title: String, subtitle: String? = nil, isAvailable: Bool = true, removable: Bool = true) {
        self.setVideoID = setVideoID; self.videoID = videoID; self.title = title; self.subtitle = subtitle; self.isAvailable = isAvailable; self.removable = removable
    }
    /// An occurrence shown optimistically while its add is pending: it has no id the service gave, so it cannot be targeted.
    public var isPlaceholder: Bool { setVideoID.hasPrefix(Self.placeholderPrefix) }
    public static let placeholderPrefix = "pending:"
}

/// Everything read about one playlist at one moment. `occurrences` is the service's order; it is replaced as a whole by a read and
/// changed only by `PlaylistEditSession`.
public struct PlaylistSnapshot: Sendable, Equatable {
    public let playlistID: String
    public var title: String
    public var details: String
    public var privacy: MusicPlaylistPrivacy?
    public var occurrences: [PlaylistOccurrence]
    public var editing: MusicPlaylistEditing?
    public var isSaved: Bool?
    /// Every page was read. A snapshot that is not complete is never the basis of a reorder.
    public var isComplete: Bool
    /// Rows the service listed without an occurrence id: they cannot be targeted, and a reorder is refused while any exist.
    public var unaddressableCount: Int
    /// Songs the page offers that are not in the playlist (the service's own suggestions). Nothing is added from them unasked.
    public var suggestions: [MusicCatalogItem]
    /// The token that reloads the service's suggested songs (the page's section list), never used to read tracks.
    public var suggestionsToken: String?

    public init(playlistID: String, title: String, details: String = "", privacy: MusicPlaylistPrivacy? = nil, occurrences: [PlaylistOccurrence],
                editing: MusicPlaylistEditing? = nil, isSaved: Bool? = nil, isComplete: Bool = true, unaddressableCount: Int = 0, suggestions: [MusicCatalogItem] = []) {
        self.playlistID = playlistID; self.title = title; self.details = details; self.privacy = privacy; self.occurrences = occurrences
        self.editing = editing; self.isSaved = isSaved; self.isComplete = isComplete; self.unaddressableCount = unaddressableCount; self.suggestions = suggestions
    }
    public var role: MusicPlaylistRole { MusicPlaylistRole.of(editing, saved: isSaved) }
    public func occurrence(_ setVideoID: String) -> PlaylistOccurrence? { occurrences.first { $0.setVideoID == setVideoID } }
    public func index(of setVideoID: String) -> Int? { occurrences.firstIndex { $0.setVideoID == setVideoID } }
    public func count(ofVideo videoID: String) -> Int { occurrences.filter { $0.videoID == videoID }.count }
    /// A digest of what an edit depends on (title, description, privacy and the ordered occurrence ids). Two reads with the same
    /// version are the same playlist as far as an edit is concerned.
    public var version: String {
        var text = "\(title)\u{1F}\(details)\u{1F}\(privacy?.rawValue ?? "")"
        for occurrence in occurrences { text += "\u{1E}" + occurrence.setVideoID }
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// A song to add, with the name the confirmation shows.
public struct PlaylistAddition: Sendable, Equatable, Hashable {
    public let videoID: String
    public let title: String
    public init(videoID: String, title: String) { self.videoID = videoID; self.title = title }
}

/// What the person asked for, in terms of occurrences. A move names the occurrence to move and the occurrence it should sit before
/// (nil: the end), never a number, so another change to the playlist in the meantime cannot make it land elsewhere.
public enum PlaylistIntent: Sendable, Equatable {
    case add([PlaylistAddition], MusicPlaylistDuplicateMode)
    case remove([PlaylistOccurrence])
    case move(PlaylistOccurrence, before: PlaylistOccurrence?)
    case rename(String)
    case describe(String)
    case setPrivacy(MusicPlaylistPrivacy)

    /// How many songs the change touches.
    public var affectedCount: Int {
        switch self {
        case .add(let songs, _): songs.count
        case .remove(let songs): songs.count
        case .move, .rename, .describe, .setPrivacy: 1
        }
    }
    /// A change to more than one song needs the confirmation that names the selection.
    public var isBulk: Bool { affectedCount > 1 }
    public var names: [String] {
        switch self {
        case .add(let songs, _): songs.map(\.title)
        case .remove(let songs): songs.map(\.title)
        case .move(let song, _): [song.title]
        case .rename(let title): [title]
        case .describe, .setPrivacy: []
        }
    }
}

/// What the confirmation dialog states: the action, how many songs, and which ones by name. The session accepts a bulk change only
/// with the prompt it would itself have built, so a dialog that names a different selection cannot confirm this one.
public struct PlaylistPrompt: Sendable, Equatable {
    public enum Action: String, Sendable { case add, remove, deletePlaylist, undo, stopContributions, join }
    public let action: Action
    public let playlistTitle: String
    public let count: Int
    public let names: [String]
    /// How many names the dialog lists; the rest are counted ("and 3 more").
    public static let namesShown = 5
    public var shownNames: [String] { Array(names.prefix(Self.namesShown)) }
    public var hiddenCount: Int { max(0, names.count - Self.namesShown) }
    public var isDestructive: Bool { action == .remove || action == .deletePlaylist }
}

public extension PlaylistIntent {
    /// The prompt a bulk change must be confirmed with; nil for a change that needs none.
    func prompt(playlistTitle: String, undo: Bool = false) -> PlaylistPrompt? {
        guard isBulk else { return nil }
        switch self {
        case .add: return PlaylistPrompt(action: undo ? .undo : .add, playlistTitle: playlistTitle, count: affectedCount, names: names)
        case .remove: return PlaylistPrompt(action: undo ? .undo : .remove, playlistTitle: playlistTitle, count: affectedCount, names: names)
        default: return nil
        }
    }
}

public enum PlaylistFailure: Equatable, Sendable {
    case refused, rateLimited, unavailable, offline, needsSignIn, sessionEnded
    /// The service did not offer this person that change on this playlist.
    case notPermitted
    /// A bulk change was submitted without the confirmation that names its selection.
    case needsConfirmation
    /// The playlist was not read completely, so a change that depends on the order cannot be placed.
    case notFullyRead
    /// A check against the service found the change was not applied.
    case notApplied
    /// A check found part of the change applied; only the rest would be sent.
    case partlyApplied
    /// The change could not be sent because the playlist could not be read first (so nothing was sent).
    case couldNotRead
    case invalid
    public var message: String {
        switch self {
        case .refused: String(localized: "YouTube Music didn’t accept this change. Nothing was changed.")
        case .rateLimited: String(localized: "YouTube Music is asking for a pause. Nothing was changed.")
        case .unavailable: String(localized: "YouTube Music couldn’t make this change right now. Nothing was changed.")
        case .offline: String(localized: "You’re offline, so nothing was changed. It isn’t queued.")
        case .needsSignIn: String(localized: "Sign in to YouTube Music to change a playlist.")
        case .sessionEnded: String(localized: "Your session ended, so nothing was changed. Sign in again.")
        case .notPermitted: String(localized: "YouTube Music doesn’t let you change this playlist. Nothing was changed.")
        case .needsConfirmation: String(localized: "This change needs your confirmation first. Nothing was changed.")
        case .notFullyRead: String(localized: "The playlist wasn’t read completely, so it can’t be reordered yet. Refresh and try again.")
        case .notApplied: String(localized: "YouTube Music didn’t apply this change. It was rolled back.")
        case .partlyApplied: String(localized: "Only part of this change was applied. Try Again sends only the rest.")
        case .couldNotRead: String(localized: "The playlist couldn’t be read first, so nothing was sent.")
        case .invalid: String(localized: "This change isn’t valid. Nothing was changed.")
        }
    }
}

public enum PlaylistOperationState: Equatable, Sendable {
    case pending
    /// The service's answer, or a read of the playlist, showed the change is in place.
    case confirmed
    case failed(PlaylistFailure)
    /// The request left and its outcome is unknown: the playlist is read before anything is sent again.
    case needsReconciliation
    /// Part of the change collides with a different change made elsewhere; the person decides each one.
    case conflicted
}

/// One thing the person asked for and what has become of it.
public struct PlaylistOperation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let playlistID: String
    public let intent: PlaylistIntent
    /// The playlist as the person was looking at it when they made the change.
    public let base: PlaylistSnapshot
    public internal(set) var state: PlaylistOperationState
    public internal(set) var attempts: Int
    /// The occurrence ids that existed before the first request of this change left; a settle counts occurrences that are new since then.
    var preIDs: Set<String>
    /// The actions that have been sent (the last request's, or the union over attempts for counting adds).
    var sent: [MusicPlaylistEditAction] = []
    /// A request for this change has left at least once.
    var sentAny = false
    /// What was already true when the change was prepared, in words (a song already there, an occurrence already gone).
    public internal(set) var satisfied: [String] = []
    /// A check could not read the playlist.
    public internal(set) var checkedUnreadable = false
    public internal(set) var isUndo = false
    /// The precondition check found the playlist already different from the version the person was looking at (`baseVersion`), and the
    /// change was reconciled with it rather than applied to a stale view.
    public internal(set) var mergedWithRemoteChanges = false
    public var baseVersion: String { base.version }
    init(id: UUID, playlistID: String, intent: PlaylistIntent, base: PlaylistSnapshot, state: PlaylistOperationState, attempts: Int) {
        self.id = id; self.playlistID = playlistID; self.intent = intent; self.base = base; self.state = state; self.attempts = attempts
        self.preIDs = Set(base.occurrences.map(\.setVideoID))
    }
}

/// A part of a change that collides with a different change made elsewhere. Both views are kept: `mine` is the playlist as the person
/// meant it, `theirs` is the playlist as the service has it. The question is about this one thing only.
public struct PlaylistConflict: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The occurrence was moved elsewhere too, and not to where this change puts it.
        case movedElsewhere(occurrence: PlaylistOccurrence)
        /// The occurrence this change moves is gone.
        case occurrenceRemoved(occurrence: PlaylistOccurrence)
        /// The occurrence now names another song than the one the person saw.
        case occurrenceChanged(occurrence: PlaylistOccurrence)
        case titleChanged(theirs: String)
        case descriptionChanged(theirs: String)
        case privacyChanged(theirs: MusicPlaylistPrivacy?)
    }
    public let id: UUID
    public let operationID: UUID
    public let kind: Kind
    /// The one piece of the change this question is about.
    public let piece: PlaylistIntent
    public let mine: PlaylistSnapshot
    public let theirs: PlaylistSnapshot
    public var summary: String {
        switch kind {
        case .movedElsewhere(let song): String(localized: "“\(song.title)” was also moved somewhere else.")
        case .occurrenceRemoved(let song): String(localized: "“\(song.title)” was removed from the playlist elsewhere.")
        case .occurrenceChanged(let song): String(localized: "“\(song.title)” is no longer the song you were changing.")
        case .titleChanged(let theirs): String(localized: "The title was also changed to “\(theirs)”.")
        case .descriptionChanged: String(localized: "The description was also changed.")
        case .privacyChanged: String(localized: "The visibility was also changed.")
        }
    }
}
public enum PlaylistResolution: Equatable, Sendable { case keepMine, keepTheirs }

/// What the settled playlist looks like to the outside: which occurrences came and went. A downloads feature observes this; the
/// playlist code decides nothing about retention.
public struct PlaylistMembershipChange: Sendable, Equatable {
    public let playlistID: String
    public let added: [PlaylistOccurrence]
    public let removed: [PlaylistOccurrence]
}

/// The service seam of the editing session. Production implementations read through the signed account; tests use a fake. A read is
/// always safe; `apply` is called only for an explicit action.
public protocol PlaylistServing: Sendable {
    func read(playlistID: String) async throws -> PlaylistSnapshot
    func apply(_ request: MusicPlaylistRequest) async throws -> MusicPlaylistReply
    /// The person's own playlist list (ids and titles), to settle a create or delete whose outcome is unknown.
    func listing() async throws -> [PlaylistListing]
    /// The service's suggested songs for an editable playlist (a read of `PlaylistSnapshot.suggestionsToken`), never members.
    func readSuggestions(token: String) async throws -> [MusicCatalogItem]
}
public extension PlaylistServing {
    func readSuggestions(token: String) async throws -> [MusicCatalogItem] { [] }
}
public struct PlaylistListing: Sendable, Equatable, Hashable {
    public let playlistID: String
    public let title: String
    public init(playlistID: String, title: String) { self.playlistID = playlistID; self.title = title }
}

public extension PlaylistSnapshot {
    /// The playlist as the person means it once `intent` is applied: what the screen shows while the change is pending. Songs being added
    /// appear as placeholders that cannot be targeted until the service gives them occurrence ids.
    func applying(_ intent: PlaylistIntent, token: String = "0") -> PlaylistSnapshot {
        var result = self
        switch intent {
        case .add(let songs, let mode):
            var present = Set(occurrences.map(\.videoID))
            for (index, song) in songs.enumerated() {
                if mode == .skipExisting, present.contains(song.videoID) { continue }
                present.insert(song.videoID)
                result.occurrences.append(PlaylistOccurrence(setVideoID: PlaylistOccurrence.placeholderPrefix + token + ":" + String(index), videoID: song.videoID,
                                                            title: song.title, removable: false))
            }
        case .remove(let songs):
            let gone = Set(songs.map(\.setVideoID))
            result.occurrences.removeAll { gone.contains($0.setVideoID) }
        case .move(let song, let anchor):
            guard let from = result.index(of: song.setVideoID) else { break }
            let moved = result.occurrences.remove(at: from)
            if let anchor, let to = result.index(of: anchor.setVideoID) { result.occurrences.insert(moved, at: to) } else { result.occurrences.append(moved) }
        case .rename(let title): result.title = title
        case .describe(let text): result.details = text
        case .setPrivacy(let privacy): result.privacy = privacy
        }
        return result
    }
}

public extension PlaylistConflict {
    /// Allowed answers: "keep mine" only exists when there is still something of mine to send.
    var allowsKeepMine: Bool { PlaylistReconciler.forcedAction(for: self) != nil }
    /// Where the colliding thing sits in the person's own version, in words.
    var mineDescription: String { Self.describe(kind, in: mine, mine: true) }
    /// Where it sits in the service's version, in words.
    var theirsDescription: String { Self.describe(kind, in: theirs, mine: false) }

    private static func place(_ id: String, in snapshot: PlaylistSnapshot) -> String {
        guard let index = snapshot.index(of: id) else { return String(localized: "Not in the playlist") }
        let before = index > 0 ? snapshot.occurrences[index - 1].title : nil
        let after = index + 1 < snapshot.occurrences.count ? snapshot.occurrences[index + 1].title : nil
        switch (before, after) {
        case (let b?, let a?): return String(localized: "Between “\(b)” and “\(a)”")
        case (nil, let a?): return String(localized: "At the start, before “\(a)”")
        case (let b?, nil): return String(localized: "At the end, after “\(b)”")
        case (nil, nil): return String(localized: "The only song")
        }
    }
    private static func describe(_ kind: Kind, in snapshot: PlaylistSnapshot, mine: Bool) -> String {
        switch kind {
        case .movedElsewhere(let song), .occurrenceRemoved(let song), .occurrenceChanged(let song): return place(song.setVideoID, in: snapshot)
        case .titleChanged: return String(localized: "Title: “\(snapshot.title)”")
        case .descriptionChanged: return snapshot.details.isEmpty ? String(localized: "No description") : String(localized: "Description: “\(snapshot.details)”")
        case .privacyChanged:
            let value = snapshot.privacy?.title ?? String(localized: "unknown")
            return String(localized: "Visibility: \(value)")
        }
    }
}
public extension MusicPlaylistPrivacy {
    var title: String {
        switch self {
        case .private: String(localized: "Private")
        case .unlisted: String(localized: "Unlisted")
        case .public: String(localized: "Public")
        }
    }
    var symbol: String {
        switch self { case .private: "lock"; case .unlisted: "link"; case .public: "globe" }
    }
}
public extension MusicPlaylistRole {
    var title: String {
        switch self {
        case .owner: String(localized: "Owner")
        case .collaborator: String(localized: "Collaborator")
        case .saved: String(localized: "Saved")
        case .viewer: String(localized: "Viewer")
        }
    }
}

/// A `PlaylistServing` assembled from three closures, so the application composes the signed account's reads and writes without the
/// editing code knowing where they go.
public struct ClosurePlaylistService: PlaylistServing {
    private let readPlaylist: @Sendable (String) async throws -> PlaylistSnapshot
    private let applyRequest: @Sendable (MusicPlaylistRequest) async throws -> MusicPlaylistReply
    private let list: @Sendable () async throws -> [PlaylistListing]
    private let suggested: @Sendable (String) async throws -> [MusicCatalogItem]
    public init(read: @escaping @Sendable (String) async throws -> PlaylistSnapshot, apply: @escaping @Sendable (MusicPlaylistRequest) async throws -> MusicPlaylistReply,
                listing: @escaping @Sendable () async throws -> [PlaylistListing], suggestions: @escaping @Sendable (String) async throws -> [MusicCatalogItem] = { _ in [] }) {
        readPlaylist = read; applyRequest = apply; list = listing; suggested = suggestions
    }
    public func readSuggestions(token: String) async throws -> [MusicCatalogItem] { try await suggested(token) }
    public func read(playlistID: String) async throws -> PlaylistSnapshot { try await readPlaylist(playlistID) }
    public func apply(_ request: MusicPlaylistRequest) async throws -> MusicPlaylistReply { try await applyRequest(request) }
    public func listing() async throws -> [PlaylistListing] { try await list() }
}

public extension PlaylistIntent {
    /// The change a drag inside the list makes: the row at `source` dropped at SwiftUI's `destination` offset (an index in the list as it
    /// was, to be inserted before). It is a move before the occurrence now at that offset (or to the end), never a position number.
    /// nil when the drop changes nothing.
    static func dragMove(in snapshot: PlaylistSnapshot, from source: Int, to destination: Int) -> PlaylistIntent? {
        let rows = snapshot.occurrences
        guard rows.indices.contains(source), destination >= 0, destination <= rows.count, destination != source, destination != source + 1 else { return nil }
        return .move(rows[source], before: destination < rows.count ? rows[destination] : nil)
    }
}
