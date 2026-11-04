import Foundation

/// The kinds of library collection the app reads (LIB01). Each names the `browse` page that lists it and the kinds of entry that
/// page may hold; an entry of another kind is counted and reported, never silently dropped and never shown as a member.
///
/// Internal notes: these ids come from the web client's own library tabs, not from a capture. Library pages need the signed
/// session, so none of them has an anonymous capture; the parser is exercised on real renderers placed in library containers
/// (`Fixtures/W12`, `synthetic-from-real-renderers`) and every id below is on the end-of-project live check list (`Docs/Library.md`).
public enum MusicLibraryKind: String, Sendable, CaseIterable, Codable, Hashable {
    case songs, likedSongs, albums, artists, following, playlists, podcasts, savedEpisodes

    /// The page that lists this collection.
    public var browseID: String {
        switch self {
        case .songs: "FEmusic_liked_videos"
        case .likedSongs: "VLLM"
        case .albums: "FEmusic_liked_albums"
        case .artists: "FEmusic_library_corpus_track_artists"
        case .following: "FEmusic_library_corpus_artists"
        case .playlists: "FEmusic_liked_playlists"
        case .podcasts: "FEmusic_library_non_music_audio_list"
        case .savedEpisodes: "VLSE"
        }
    }
    /// Entry kinds a collection of this kind may hold.
    public var holds: Set<MusicEntityKind> {
        switch self {
        case .songs, .likedSongs: [.song, .video]
        case .albums: [.album]
        case .artists, .following: [.artist]
        case .playlists: [.playlist]
        case .podcasts: [.podcast]
        case .savedEpisodes: [.episode]
        }
    }
    /// The channel id an artist row names: a `UC…` browse id, or the library's `MPLAUC…` form of it (a followed artist's page).
    public static func channelID(fromBrowseID id: String) -> String? {
        let bare = id.hasPrefix("MPLA") ? String(id.dropFirst(4)) : id
        return bare.range(of: #"^UC[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil ? bare : nil
    }
    /// Every library `browseId` the app relies on, for the end-of-project live check.
    public static var allBrowseIDs: [String] { allCases.map(\.browseID) + [MusicHistory.browseID] }
}

/// The service's own history page (read-only; the app never writes remote history).
public enum MusicHistory {
    public static let browseID = "FEmusic_history"
}

public enum MusicLikeStatus: String, Sendable, Equatable, Codable {
    case like = "LIKE", dislike = "DISLIKE", indifferent = "INDIFFERENT"
}

/// The write controls an entry published for itself. Only what the entry actually carried is present: nothing is offered that was
/// not published. A library toggle is recognised by its icons (see `MusicBrowseParser`), never by merely carrying a token. An
/// anonymous page publishes a sign-in prompt in place of the library endpoints, so it yields no save or follow toggle; its like
/// button does carry the rating's current state, which a view draws only for a signed-in account.
public struct MusicItemControls: Sendable, Equatable {
    public struct Like: Sendable, Equatable {
        public let videoID: String
        public let status: MusicLikeStatus
        /// The service exposes a dislike control for this entry.
        public let dislikeExposed: Bool
        public init(videoID: String, status: MusicLikeStatus, dislikeExposed: Bool) { self.videoID = videoID; self.status = status; self.dislikeExposed = dislikeExposed }
    }
    /// Save to / remove from the library for a song, through feedback tokens the service published (one per direction).
    public struct SongLibrary: Sendable, Equatable {
        public let isSaved: Bool
        public let addToken: String?
        public let removeToken: String?
        public init(isSaved: Bool, addToken: String?, removeToken: String?) { self.isSaved = isSaved; self.addToken = addToken; self.removeToken = removeToken }
    }
    /// Save to / remove from the library for an album, playlist or show, through the playlist id the service published as the target.
    public struct Save: Sendable, Equatable {
        public let playlistID: String
        public let isSaved: Bool?
        public init(playlistID: String, isSaved: Bool?) { self.playlistID = playlistID; self.isSaved = isSaved }
    }
    public struct Follow: Sendable, Equatable {
        public let channelID: String
        public let isFollowing: Bool?
        public let params: String?
        public init(channelID: String, isFollowing: Bool?, params: String?) { self.channelID = channelID; self.isFollowing = isFollowing; self.params = params }
    }
    public var like: Like?
    public var songLibrary: SongLibrary?
    public var save: Save?
    public var follow: Follow?
    /// The remove command a signed playlist page published for this row (an occurrence of a song in a playlist the person may edit).
    public var playlistRemoval: MusicPlaylistRowRemoval?
    public init(like: Like? = nil, songLibrary: SongLibrary? = nil, save: Save? = nil, follow: Follow? = nil, playlistRemoval: MusicPlaylistRowRemoval? = nil) {
        self.like = like; self.songLibrary = songLibrary; self.save = save; self.follow = follow; self.playlistRemoval = playlistRemoval
    }
    public var isEmpty: Bool { like == nil && songLibrary == nil && save == nil && follow == nil && playlistRemoval == nil }
}

/// One write the app can send. Each is a single state-setting request the person asked for; none is ever sent in a batch.
public enum MusicWriteRequest: Sendable, Equatable {
    /// Rate a song or video (like, dislike, or remove the rating).
    case rate(videoID: String, status: MusicLikeStatus)
    /// Save an album, playlist or show to the library (`saved: true`) or remove it.
    case savePlaylist(playlistID: String, saved: Bool)
    /// Save a song to the library, or remove it, with a feedback token the service published for exactly that direction.
    case songLibrary(feedbackToken: String)
    case follow(channelID: String, params: String?, following: Bool)
    /// Add one podcast episode to the person's "Episodes for Later" (`saved: true`) or remove that one episode. Sent as a playlist-edit request
    /// on the service's `SE` list naming only this episode: the service's own remove toggle also clears every watched episode from the list, which
    /// the person did not ask for, so that extra action is never sent.
    case episodeLater(videoID: String, saved: Bool)

    /// A request is valid only if every identifier has the shape the service uses. Checked before anything is sent.
    public var isWellFormed: Bool {
        func id(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
        switch self {
        case .rate(let video, _): return id(video, #"^[A-Za-z0-9_-]{11}$"#)
        case .savePlaylist(let list, _): return id(list, #"^[A-Za-z0-9_-]{2,128}$"#)
        case .songLibrary(let token): return id(token, #"^[A-Za-z0-9_%=+/.-]{8,4096}$"#)
        case .episodeLater(let video, _): return id(video, #"^[A-Za-z0-9_-]{11}$"#)
        case .follow(let channel, let params, _):
            return id(channel, #"^UC[A-Za-z0-9_-]{22}$"#) && (params.map { id($0, #"^[A-Za-z0-9%_=+/.-]{1,1024}$"#) } ?? true)
        }
    }
}
public enum MusicWriteRejection: Sendable, Equatable {
    /// The service answered and said no (an error object, or a response marking the change as not processed). Nothing changed.
    case service
    case rateLimited
    case unavailable
}
public enum MusicWriteDoubt: Sendable, Equatable {
    /// The request left, but the connection ended or timed out before an answer: the change may or may not have happened.
    case noAnswer
    /// The service answered with something this version cannot read as either success or failure.
    case unrecognisedAnswer
}
/// What a write came to. Success needs positive evidence in the response; an HTTP 200 alone is never success (SYNC04).
public enum MusicWriteOutcome: Sendable, Equatable {
    case confirmed
    case rejected(MusicWriteRejection)
    case indeterminate(MusicWriteDoubt)
}
/// A write answered for one account scope (the same fence as every other signed answer).
public struct MusicWriteReply: Sendable, Equatable {
    public let outcome: MusicWriteOutcome
    public let accountGeneration: UInt64
    public init(outcome: MusicWriteOutcome, accountGeneration: UInt64) { self.outcome = outcome; self.accountGeneration = accountGeneration }
}
