import Foundation

/// Identity taken from `account/account_menu`'s active-account header.
public struct MusicAccountIdentity: Sendable, Equatable {
    /// Stable service identity used for the local account context: the account's
    /// single `UC…` channel ID the account menu publishes (never the mutable handle).
    public let serviceID: String
    public let displayName: String
    public let handle: String?
    public let photoURL: URL?
    public init(serviceID: String, displayName: String, handle: String?, photoURL: URL?) {
        self.serviceID = serviceID; self.displayName = displayName; self.handle = handle; self.photoURL = photoURL
    }
}
public struct MusicLibraryPlaylist: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// The count exactly as the service printed it (for example "12 songs"), if any.
    public let countText: String?
    public let itemCount: Int?
    public init(id: String, title: String, countText: String?, itemCount: Int?) {
        self.id = id; self.title = title; self.countText = countText; self.itemCount = itemCount
    }
}
/// One `browse FEmusic_liked_playlists` page. `complete` is false when the service
/// offered a continuation that this read-only proof does not follow.
public struct MusicLibraryPlaylists: Sendable, Equatable {
    public let playlists: [MusicLibraryPlaylist]
    public let complete: Bool
    public init(playlists: [MusicLibraryPlaylist], complete: Bool) { self.playlists = playlists; self.complete = complete }
}
public struct MusicSignedResult<Value: Sendable>: Sendable {
    public let value: Value
    /// Allowlisted cookies Google rotated on this response (`Set-Cookie`).
    public let rotation: [MusicSessionCookie]
    public init(value: Value, rotation: [MusicSessionCookie]) { self.value = value; self.rotation = rotation }
}
/// Implemented by YouTubeMusicAdapter on the bounded direct transport. Every failure
/// is a `MusicSessionError`; an unparseable response is `.unrecognised`, never empty.
public protocol MusicSessionReading: Sendable {
    /// W27 (DIAG01): the adapter's own version, shown in Diagnostics. A reader that does not know one says so rather than inventing it.
    var adapterVersion: String { get }
    func accountMenu(session: MusicCookieSession) async throws -> MusicSignedResult<MusicAccountIdentity>
    func likedPlaylists(session: MusicCookieSession) async throws -> MusicSignedResult<MusicLibraryPlaylists>
    /// Bounded, credential-free avatar bytes from the exact image hosts the menu uses.
    func avatar(_ url: URL) async throws -> Data
    /// Music `search`: signed with `session`, or the anonymous public request when `session` is nil.
    /// An unreadable response is `.unrecognised`, never an empty result.
    func search(query: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicSearchResponse>
    /// Music `browse` of one page: signed with `session`, or anonymous when nil.
    func browse(id: String, params: String?, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicBrowsePage>
    /// The next entries of a shelf or the next sections of a page.
    func continuation(token: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicContinuationPage>
    /// Bounded, credential-free catalog artwork bytes from the exact image hosts the catalog uses.
    func artwork(_ url: URL) async throws -> Data
    /// One library or history `browse` page. Signed only: a library has no anonymous form. Repeated rows are kept (a song played
    /// twice is two history rows), and an unrecognised page is `.unrecognised`, never an empty library.
    func library(id: String, session: MusicCookieSession) async throws -> MusicSignedResult<MusicBrowsePage>
    func libraryContinuation(token: String, session: MusicCookieSession) async throws -> MusicSignedResult<MusicContinuationPage>
    /// One write the person asked for. Only an explicit user action reaches this.
    func write(_ request: MusicWriteRequest, session: MusicCookieSession) async throws -> MusicSignedResult<MusicWriteOutcome>
    /// One playlist change (create, edit, delete). Only an explicit user action reaches this, through the playlist editing session.
    func editPlaylist(_ request: MusicPlaylistRequest, session: MusicCookieSession) async throws -> MusicSignedResult<MusicPlaylistOutcome>
    /// A podcast episode page (`MPED…`): signed with `session`, or anonymous when nil. An unreadable page is `.unrecognised`.
    func episode(id: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicEpisodePage>
    /// A song's lyrics: its `next` response (where the Lyrics tab is), then the lyrics page it names. Signed when `session` is given, in case a
    /// signed answer supplies timing; anonymous otherwise. "No lyrics" is a result; a response that cannot be read is an error.
    func radioQueue(action: MusicRadioAction, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicRadioQueue>
    func lyrics(videoID: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicLyricsResult>
    /// The rating of one song for the signed-in account (its `next` response's like button). Signed only. `nil` when the service published no
    /// rating in that answer (it sometimes omits it); an unreadable answer is `.unrecognised`, never "not rated".
    func rating(videoID: String, session: MusicCookieSession) async throws -> MusicSignedResult<MusicItemControls.Like?>
    /// One comments read (open, page or replies): signed with `session`, or the anonymous public request when nil. The request is validated before
    /// anything is sent; an unreadable answer is `.unrecognised`, an oversized one `.oversized`, never a partial parse.
    func comments(_ request: MusicCommentsRequest, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicCommentsAnswer>
    /// The account's Recap: one `browse` of the known Recap handler, signed only (it has no anonymous form). It reports the service's answer
    /// for the envelope that has been captured (a message, or the signed-out state); any other answer is `.unrecognised`, never empty.
    func recap(session: MusicCookieSession) async throws -> MusicSignedResult<MusicRecapReading>
}
extension MusicSessionReading {
    public func recap(session: MusicCookieSession) async throws -> MusicSignedResult<MusicRecapReading> { throw MusicSessionError.policy }
    public func radioQueue(action: MusicRadioAction, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicRadioQueue> { throw MusicSessionError.policy }
    /// Readers that predate search do not offer it; the caller reports it as unavailable.
    public func search(query: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicSearchResponse> {
        throw MusicSessionError.policy
    }
    public func browse(id: String, params: String?, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicBrowsePage> {
        throw MusicSessionError.policy
    }
    public func continuation(token: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicContinuationPage> {
        throw MusicSessionError.policy
    }
    public func artwork(_ url: URL) async throws -> Data { throw MusicSessionError.policy }
    public func library(id: String, session: MusicCookieSession) async throws -> MusicSignedResult<MusicBrowsePage> { throw MusicSessionError.policy }
    public func libraryContinuation(token: String, session: MusicCookieSession) async throws -> MusicSignedResult<MusicContinuationPage> { throw MusicSessionError.policy }
    public func write(_ request: MusicWriteRequest, session: MusicCookieSession) async throws -> MusicSignedResult<MusicWriteOutcome> { throw MusicSessionError.policy }
    public func editPlaylist(_ request: MusicPlaylistRequest, session: MusicCookieSession) async throws -> MusicSignedResult<MusicPlaylistOutcome> { throw MusicSessionError.policy }
    public func episode(id: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicEpisodePage> { throw MusicSessionError.policy }
    public func lyrics(videoID: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicLyricsResult> { throw MusicSessionError.policy }
    public func rating(videoID: String, session: MusicCookieSession) async throws -> MusicSignedResult<MusicItemControls.Like?> { throw MusicSessionError.policy }
    /// Readers that predate comments do not offer them.
    public func comments(_ request: MusicCommentsRequest, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicCommentsAnswer> { throw MusicSessionError.policy }
}

public extension MusicSessionReading {
    var adapterVersion: String { "unreported" }
}
