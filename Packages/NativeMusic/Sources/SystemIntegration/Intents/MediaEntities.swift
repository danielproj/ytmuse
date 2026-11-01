import AppIntents
import Foundation

// W24 (MAC03, MAC04, T24.2). The audio-schema entities of this app and their queries.
//
// Each entity is a thin view of an `IntentMedia`: its identifier IS the encoded media (account, generation, kind, target), so there is nothing to
// look up to know what it is and nothing in it that a stale or foreign session could resolve against the current account. The queries read the
// channel's candidates, which come from models and caches the app already holds; they never reach the network.
//
// The SDK's audio domain (`AppSchema.audio`, macOS 27) is adopted for song, album, artist, playlist and algorithmic radio station (a "mix"). The
// required shape of each was read from the SDK's own validator, not from documentation (see Docs/Intents.md).

enum IntentQueries {
    /// Entities for identifiers the system saved earlier. Anything bound to another account or an earlier session is refused with a clear error.
    @MainActor static func entities(for identifiers: [String], kind: IntentMediaKind) async throws -> [IntentMedia] {
        guard let channel = await IntentHub.active.readyChannel() else { throw IntentRefusal.appNotReady }
        let scope = await channel.currentScope()
        var found: [IntentMedia] = []
        for identifier in identifiers {
            if let refusal = IntentResolver.admit(encoded: identifier, current: scope) { throw refusal }
            guard let media = IntentMedia(encoded: identifier) else { throw IntentRefusal.notFound }
            if media.kind == kind { found.append(media) }
        }
        return found
    }
    @MainActor static func matching(_ text: String, kind: IntentMediaKind) async throws -> [IntentMedia] {
        guard let channel = await IntentHub.active.readyChannel() else { throw IntentRefusal.appNotReady }
        guard await channel.currentScope() != nil else { throw IntentRefusal.signedOut }
        switch IntentResolver.resolve(text, among: await channel.candidates(kind: kind, matching: text, limit: 50), kind: kind) {
        case .none: return []
        case .one(let media): return [media]
        case .many(let all): return all   // the system asks the person to choose; nothing here picks for them
        }
    }
    @MainActor static func suggested(kind: IntentMediaKind) async throws -> [IntentMedia] {
        guard let channel = await IntentHub.active.readyChannel() else { return [] }
        guard await channel.currentScope() != nil else { return [] }
        return await channel.candidates(kind: kind, matching: nil, limit: 20)
    }
    static func display(_ media: IntentMedia) -> DisplayRepresentation {
        if let subtitle = media.subtitle, !subtitle.isEmpty { return DisplayRepresentation(title: "\(media.title)", subtitle: "\(subtitle)") }
        return DisplayRepresentation(title: "\(media.title)")
    }
}

// MARK: Song

@AppEntity(schema: .audio.song)
public struct SongEntity: AppEntity {
    public static let defaultQuery = SongQuery()
    public var id: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: artistName.isEmpty ? nil : "\(artistName)") }
    public var title: String
    public var artistName: String
    public var albumTitle: String?
    public var composerName: String?
    public var internationalStandardRecordingCode: String?
    public var artists: [ArtistEntity]
    public var composers: [ArtistEntity]
    public var album: AlbumEntity?
    public init(media: IntentMedia) {
        id = media.encoded; title = media.title; artistName = media.subtitle ?? ""
        albumTitle = nil; composerName = nil; internationalStandardRecordingCode = nil; artists = []; composers = []; album = nil
    }
}
public struct SongQuery: EntityStringQuery {
    public init() {}
    @MainActor public func entities(for identifiers: [String]) async throws -> [SongEntity] { try await IntentQueries.entities(for: identifiers, kind: .song).map(SongEntity.init) }
    @MainActor public func entities(matching string: String) async throws -> [SongEntity] { try await IntentQueries.matching(string, kind: .song).map(SongEntity.init) }
    @MainActor public func suggestedEntities() async throws -> [SongEntity] { try await IntentQueries.suggested(kind: .song).map(SongEntity.init) }
}

// MARK: Album

@AppEntity(schema: .audio.album)
public struct AlbumEntity: AppEntity {
    public static let defaultQuery = AlbumQuery()
    public var id: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: artistName.isEmpty ? nil : "\(artistName)") }
    public var title: String
    public var artistName: String
    public var artists: [ArtistEntity]
    public var universalProductCode: String?
    public init(media: IntentMedia) { id = media.encoded; title = media.title; artistName = media.subtitle ?? ""; artists = []; universalProductCode = nil }
}
public struct AlbumQuery: EntityStringQuery {
    public init() {}
    @MainActor public func entities(for identifiers: [String]) async throws -> [AlbumEntity] { try await IntentQueries.entities(for: identifiers, kind: .album).map(AlbumEntity.init) }
    @MainActor public func entities(matching string: String) async throws -> [AlbumEntity] { try await IntentQueries.matching(string, kind: .album).map(AlbumEntity.init) }
    @MainActor public func suggestedEntities() async throws -> [AlbumEntity] { try await IntentQueries.suggested(kind: .album).map(AlbumEntity.init) }
}

// MARK: Artist

@AppEntity(schema: .audio.artist)
public struct ArtistEntity: AppEntity {
    public static let defaultQuery = ArtistQuery()
    public var id: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    public var name: String
    public init(media: IntentMedia) { id = media.encoded; name = media.title }
}
public struct ArtistQuery: EntityStringQuery {
    public init() {}
    @MainActor public func entities(for identifiers: [String]) async throws -> [ArtistEntity] { try await IntentQueries.entities(for: identifiers, kind: .artist).map(ArtistEntity.init) }
    @MainActor public func entities(matching string: String) async throws -> [ArtistEntity] { try await IntentQueries.matching(string, kind: .artist).map(ArtistEntity.init) }
    @MainActor public func suggestedEntities() async throws -> [ArtistEntity] { try await IntentQueries.suggested(kind: .artist).map(ArtistEntity.init) }
}

// MARK: Playlist

@UnionValue
public enum PlaylistOwner: Sendable {
    case name(String)
}
@AppEntity(schema: .audio.playlist)
public struct PlaylistEntity: AppEntity {
    public static let defaultQuery = PlaylistQuery()
    public var id: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: ownerName.map { "\($0)" }) }
    public var title: String
    public var createdByMe: Bool?
    public var curatedForMe: Bool?
    public var owner: PlaylistOwner?
    private var ownerName: String? { if case .name(let n)? = owner { n } else { nil } }
    public init(media: IntentMedia) {
        id = media.encoded; title = media.title
        // What the library row names as the owner is shown as it was published. Whether the person made it or YouTube Music curated it is not
        // something the row says, so neither flag is claimed.
        createdByMe = nil; curatedForMe = nil; owner = media.subtitle.map { .name($0) }
    }
}
public struct PlaylistQuery: EntityStringQuery {
    public init() {}
    @MainActor public func entities(for identifiers: [String]) async throws -> [PlaylistEntity] { try await IntentQueries.entities(for: identifiers, kind: .playlist).map(PlaylistEntity.init) }
    @MainActor public func entities(matching string: String) async throws -> [PlaylistEntity] { try await IntentQueries.matching(string, kind: .playlist).map(PlaylistEntity.init) }
    @MainActor public func suggestedEntities() async throws -> [PlaylistEntity] { try await IntentQueries.suggested(kind: .playlist).map(PlaylistEntity.init) }
}

// MARK: Mix (an algorithmic radio station the service itself presented as a radio)

@AppEntity(schema: .audio.algorithmicRadioStation)
public struct MixEntity: AppEntity {
    public static let defaultQuery = MixQuery()
    public var id: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { "\($0)" }) }
    public var title: String
    public var curatedForMe: Bool?
    private var subtitle: String?
    public init(media: IntentMedia) { id = media.encoded; title = media.title; curatedForMe = nil; subtitle = media.subtitle }
}
public struct MixQuery: EntityStringQuery {
    public init() {}
    @MainActor public func entities(for identifiers: [String]) async throws -> [MixEntity] { try await IntentQueries.entities(for: identifiers, kind: .mix).map(MixEntity.init) }
    @MainActor public func entities(matching string: String) async throws -> [MixEntity] { try await IntentQueries.matching(string, kind: .mix).map(MixEntity.init) }
    @MainActor public func suggestedEntities() async throws -> [MixEntity] { try await IntentQueries.suggested(kind: .mix).map(MixEntity.init) }
}

// MARK: The schema's own value types

/// What the audio schema's play, save and rate intents accept: any one of the five entity kinds above.
@UnionValue
public enum AudioTarget: Sendable {
    case song(SongEntity)
    case album(AlbumEntity)
    case artist(ArtistEntity)
    case playlist(PlaylistEntity)
    case mix(MixEntity)

    /// The media this value stands for. Nil only for an identifier this layer did not write.
    public var media: IntentMedia? {
        switch self {
        case .song(let e): IntentMedia(encoded: e.id)
        case .album(let e): IntentMedia(encoded: e.id)
        case .artist(let e): IntentMedia(encoded: e.id)
        case .playlist(let e): IntentMedia(encoded: e.id)
        case .mix(let e): IntentMedia(encoded: e.id)
        }
    }
}

@AppEnum(schema: .audio.queueInsertionLocation)
public enum QueueInsertion: String, AppEnum {
    case next, tail
    public static let caseDisplayRepresentations: [QueueInsertion: DisplayRepresentation] = [.next: "Next", .tail: "Last"]
}
@AppEnum(schema: .audio.affinityState)
public enum AffinityChoice: String, AppEnum {
    case like, dislike, unset
    public static let caseDisplayRepresentations: [AffinityChoice: DisplayRepresentation] = [.like: "Like", .dislike: "Dislike", .unset: "Remove rating"]
}
@AppEnum(schema: .audio.playbackAttributes)
public enum PlaybackAttribute: String, AppEnum {
    case shuffle, `repeat`
    public static let caseDisplayRepresentations: [PlaybackAttribute: DisplayRepresentation] = [.shuffle: "Shuffle", .repeat: "Repeat"]
}
/// The schema's optional result of a warm-up. This app has nothing to warm (nothing loads or plays before an explicit play), so no warm-up
/// intent is adopted; the type exists because the play intent's parameter list requires it.
@AppEntity(schema: .audio.warmupAudioQueueResult)
public struct WarmupResult: TransientAppEntity {
    public init() {}
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Prepared queue"
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Prepared queue") }
}
