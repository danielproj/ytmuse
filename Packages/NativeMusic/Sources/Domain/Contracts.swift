import Foundation

public enum CatalogEntity: Sendable { case media(MediaItem), album(Album), artist(Artist), podcast(Podcast), playlist(Playlist) }
public struct CatalogSection: Sendable {
    public let id: ServiceID; public let title: String; public let items: Page<CatalogEntity>
    public init(id: ServiceID, title: String, items: Page<CatalogEntity>) { self.id = id; self.title = title; self.items = items }
}
public enum SearchScope: String, Sendable { case all, songs, albums, artists, playlists, videos, podcasts, episodes, library, uploads }
public struct SearchQuery: Sendable {
    public let text: String; public let scope: SearchScope
    public init(text: String, scope: SearchScope = .all) { self.text = text; self.scope = scope }
}
public struct TunerRequest: Sendable {
    public let seeds: [ServiceID]; public let diversity: String?; public let discovery: String?
    public init(seeds: [ServiceID], diversity: String? = nil, discovery: String? = nil) { self.seeds = seeds; self.diversity = diversity; self.discovery = discovery }
}
/// URL is a canonical public navigation URL; authenticated media URLs never cross this boundary.
public protocol MusicCatalog: Sendable {
    func home(cursor: PageCursor?, context: RequestContext) async -> ServiceResult<Page<CatalogSection>>
    func search(_ query: SearchQuery, cursor: PageCursor?, context: RequestContext) async -> ServiceResult<Page<CatalogEntity>>
    func suggestions(_ query: SearchQuery, context: RequestContext) async -> ServiceResult<[String]>
    func details(_ id: ServiceID, context: RequestContext) async -> ServiceResult<CatalogEntity>
    func library(scope: SearchScope, cursor: PageCursor?, context: RequestContext) async -> ServiceResult<Page<CatalogEntity>>
    func radio(_ request: TunerRequest, cursor: PageCursor?, context: RequestContext) async -> ServiceResult<Page<MediaItem>>
    func canonicalLink(_ id: ServiceID, context: RequestContext) async -> ServiceResult<URL>
}
public protocol AccountService: Actor, CapabilityProvider {
    func identities(context: RequestContext) async -> ServiceResult<[Account]>
    func authenticate(context: RequestContext) async -> ServiceResult<Account>
    func refresh(context: RequestContext) async -> ServiceResult<Account>
    func switchIdentity(to account: AccountContext, context: RequestContext) async -> ServiceResult<Account>
    func revoke(context: RequestContext) async -> ServiceResult<Void>
    func removeLocalIdentity(_ account: AccountContext, context: RequestContext) async -> ServiceResult<Void>
}
public enum LibraryAction: Sendable { case save(Bool), like(Bool), dislike(Bool), follow(Bool), pauseHistory(Bool), clearHistory }
public protocol LibraryService: Sendable {
    func apply(_ action: LibraryAction, target: ServiceID, operationID: UUID, context: RequestContext) async -> ServiceResult<LibraryMembership>
    func reconcile(_ mutation: PendingMutation, context: RequestContext) async -> ServiceResult<SyncState>
}
public enum PlaylistAction: Sendable {
    case create(title: String, privacy: PlaylistPrivacy)
    case edit(title: String?, description: String?, privacy: PlaylistPrivacy?)
    case delete
    case add([ServiceID])
    case remove([OccurrenceIdentity])
    case move(occurrences: [OccurrenceIdentity], before: OccurrenceIdentity?)
    case join(invitation: ServiceID)
    case leave
    case invite(role: String)
}
public protocol PlaylistService: Sendable {
    func items(_ playlist: ServiceID, cursor: PageCursor?, context: RequestContext) async -> ServiceResult<Page<PlaylistItem>>
    func apply(_ action: PlaylistAction, target: ServiceID, operationID: UUID, precondition: MutationPrecondition, context: RequestContext) async -> ServiceResult<Playlist>
    func suggestions(_ playlist: ServiceID, cursor: PageCursor?, context: RequestContext) async -> ServiceResult<Page<MediaItem>>
}
public enum ServicePlaybackEvent: Sendable { case started, paused(position: Double), progressed(position: Double), ended, adImpression(ServiceID), adCompleted(ServiceID) }
public protocol PlaybackResolver: Sendable {
    func resolve(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<[MediaVariant]>
    func validateEligibility(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<Capability>
    func refresh(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<MediaVariant>
    func report(_ event: ServicePlaybackEvent, context: PlaybackContext) async -> PlaybackResult<Void>
}
public enum EngineEvent: Sendable { case prepared, started, paused, position(Double), buffering, ended, failed(DomainError), entitlementRevoked }
public struct ScopedEngineEvent: Sendable {
    public let context: PlaybackContext; public let event: EngineEvent
    /// Capture using the shared injected monotonic clock before asynchronous delivery.
    /// Nil is reserved for immediate observations at the receiving boundary.
    public let observedAt: Duration?
    /// Optional native render generation fences already-queued observations on seek/backend disposal.
    public let renderGeneration: UUID?
    public init(context: PlaybackContext, event: EngineEvent, observedAt: Duration? = nil, renderGeneration: UUID? = nil) {
        self.context = context; self.event = event; self.observedAt = observedAt; self.renderGeneration = renderGeneration
    }
}
/// Engines serialize transport application and reject obsolete contexts before touching hardware.
/// Apply transport before suspending for acknowledgements. Stamp queued observations with
/// the injected monotonic clock at capture, rather than at later delivery.
public protocol PlaybackEngine: Actor {
    func validatesObservation(_ event: ScopedEngineEvent) async -> Bool
    func prepare(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<Void>
    func play(context: PlaybackContext) async -> PlaybackResult<Void>
    func pause(context: PlaybackContext) async -> PlaybackResult<Void>
    func validateSeek(context: PlaybackContext) async -> PlaybackResult<Void>
    func seek(to seconds: Double, context: PlaybackContext) async -> PlaybackResult<Void>
    func stop(context: PlaybackContext) async -> PlaybackResult<Void>
    func setGain(_ gain: Double, context: PlaybackContext) async -> PlaybackResult<Void>
    func setRate(_ rate: Double, context: PlaybackContext) async -> PlaybackResult<Void>
    func scheduleNext(_ variant: MediaVariant?, context: PlaybackContext) async -> PlaybackResult<Void>
    func events(context: PlaybackContext) async -> PlaybackResult<AsyncStream<ScopedEngineEvent>>
}
public extension PlaybackEngine {
    /// Engines with dynamic source rights override this; engine.seek remains the final fence.
    func validateSeek(context: PlaybackContext) async -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
}
public struct LocalAsset: Sendable {
    public let reference: ServiceID; public let entitlement: OfflineEntitlement; public let verification: Verification
    public init(reference: ServiceID, entitlement: OfflineEntitlement, verification: Verification) { self.reference = reference; self.entitlement = entitlement; self.verification = verification }
}
public protocol OfflineMediaStore: Actor {
    func resolve(_ media: ServiceID, context: RequestContext) async -> ServiceResult<LocalAsset>
    func verify(_ media: ServiceID, context: RequestContext) async -> ServiceResult<Verification>
    func validateEntitlement(_ media: ServiceID, context: RequestContext) async -> ServiceResult<OfflineEntitlement>
    func pin(_ media: ServiceID, reference: ServiceID, context: RequestContext) async -> ServiceResult<DownloadJob>
    func unpin(_ media: ServiceID, reference: ServiceID, context: RequestContext) async -> ServiceResult<Void>
    func delete(_ media: ServiceID, context: RequestContext) async -> ServiceResult<Void>
}
public struct OutputRoute: Sendable {
    public let id: RouteID; public let name: String; public let capabilities: [Feature: CapabilityState]
    public init(id: RouteID, name: String, capabilities: [Feature: CapabilityState]) { self.id = id; self.name = name; self.capabilities = capabilities }
}
public enum RemoteTransport: Sendable { case play, pause, seek(Double), stop, gain(Double) }
public struct RouteSession: Sendable {
    public let id: UUID; public let route: OutputRoute; public let position: Double?; public let state: PlaybackState
    public init(id: UUID, route: OutputRoute, position: Double?, state: PlaybackState) throws(DomainError) {
        guard position.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw .invalidInput(.negativeValue) }
        self.id = id; self.route = route; self.position = position; self.state = state
    }
}
public protocol RouteProvider: Sendable {
    func discover(context: RequestContext) async -> ServiceResult<[OutputRoute]>
    func connect(_ route: RouteID, context: PlaybackContext) async -> PlaybackResult<RouteSession>
    func disconnect(context: PlaybackContext) async -> PlaybackResult<Void>
    func capabilities(_ route: RouteID, context: RequestContext) async -> ServiceResult<OutputRoute>
    func transport(_ command: RemoteTransport, context: PlaybackContext) async -> PlaybackResult<RouteSession>
    func session(context: PlaybackContext) async -> PlaybackResult<RouteSession>
}
public struct LyricLine: Sendable {
    public let text: String; public let startsAt: Double?
    public init(text: String, startsAt: Double?) throws(DomainError) {
        guard startsAt.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw .invalidInput(.negativeValue) }; self.text = text; self.startsAt = startsAt
    }
}
public struct Lyrics: Sendable {
    public let lines: [LyricLine]; public let attribution: String?; public let availability: Availability
    public init(lines: [LyricLine], attribution: String?, availability: Availability) { self.lines = lines; self.attribution = attribution; self.availability = availability }
}
public protocol LyricsProvider: Sendable { func lyrics(_ media: ServiceID, context: RequestContext) async -> ServiceResult<Lyrics> }
public enum RemoteMutation: Sendable {
    case library(LibraryAction)
    case playlist(PlaylistAction)
    public var requiredFeature: Feature {
        switch self { case .library(.clearHistory), .library(.pauseHistory): .historyMutation
        case .library: .libraryMutation
        case .playlist(.join), .playlist(.leave), .playlist(.invite): .collaboration
        case .playlist: .playlistMutation }
    }
}
public protocol MutationOutbox: Actor {
    func enqueue(_ mutation: PendingMutation, context: RequestContext) async -> ServiceResult<PendingMutation>
    /// Atomically claims the first dispatch and increments attempts. Existing attempts fail with reconciliationRequired.
    func beginAttempt(_ id: UUID, context: RequestContext) async -> ServiceResult<PendingMutation>
    func reconcile(_ id: UUID, context: RequestContext) async -> ServiceResult<PendingMutation>
    func commit(_ id: UUID, context: RequestContext) async -> ServiceResult<PendingMutation>
    func fail(_ id: UUID, error: DomainError, ambiguous: Bool, context: RequestContext) async -> ServiceResult<PendingMutation>
    func cancel(_ id: UUID, context: RequestContext) async -> ServiceResult<Void>
    func status(_ id: UUID, context: RequestContext) async -> ServiceResult<PendingMutation>
}
// Infrastructure injection: adapters own wire formats and ephemeral credential material.
public struct TransportRequest: Sendable {
    public enum Method: Sendable { case get, post, put, delete }
    public let url: URL; public let method: Method; public let body: Data?
    public init(url: URL, method: Method, body: Data? = nil) { self.url = url; self.method = method; self.body = body }
}
public struct TransportResponse: Sendable {
    public let status: Int; public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}
public protocol NetworkTransport: Sendable { func send(_ request: TransportRequest, context: RequestContext) async -> ServiceResult<TransportResponse> }
public protocol CredentialStore: Actor {
    func reference(for account: AccountContext, context: RequestContext) async -> ServiceResult<CredentialReference?>
    func remove(for account: AccountContext, context: RequestContext) async -> ServiceResult<Void>
}
public protocol PersistenceStore: Actor {
    func queue(context: RequestContext) async -> ServiceResult<QueueSession?>
    func checkpoint(_ queue: QueueSession, context: RequestContext) async -> ServiceResult<Void>
    func preferences(scope: PreferenceScope, context: RequestContext) async -> ServiceResult<Preferences>
    func store(_ preferences: Preferences, context: RequestContext) async -> ServiceResult<Void>
}
public struct InfrastructureDependencies: Sendable {
    public let wallClock: any WallClock; public let monotonicClock: any MonotonicClock
    public let transport: any NetworkTransport; public let credentials: any CredentialStore; public let persistence: any PersistenceStore
    public let engine: any PlaybackEngine; public let capabilities: any CapabilityProvider
    public init(wallClock: any WallClock, monotonicClock: any MonotonicClock, transport: any NetworkTransport, credentials: any CredentialStore, persistence: any PersistenceStore, engine: any PlaybackEngine, capabilities: any CapabilityProvider) {
        self.wallClock = wallClock; self.monotonicClock = monotonicClock; self.transport = transport; self.credentials = credentials; self.persistence = persistence; self.engine = engine; self.capabilities = capabilities
    }
}

public protocol DownloadCoordinator: Actor {
    func schedule(_ media: ServiceID, context: RequestContext) async -> ServiceResult<DownloadJob>
    func pause(_ job: UUID, context: RequestContext) async -> ServiceResult<DownloadJob>
    func resume(_ job: UUID, context: RequestContext) async -> ServiceResult<DownloadJob>
    func cancel(_ job: UUID, context: RequestContext) async -> ServiceResult<Void>
}
/// The composition root supplies implementations; Domain never creates a live or fixture adapter.
public struct MusicServices: Sendable {
    public let catalog: any MusicCatalog; public let accounts: any AccountService
    public let library: any LibraryService; public let playlists: any PlaylistService
    public let resolver: any PlaybackResolver; public let offline: any OfflineMediaStore
    public let routes: any RouteProvider; public let lyrics: any LyricsProvider; public let outbox: any MutationOutbox
    public init(catalog: any MusicCatalog, accounts: any AccountService, library: any LibraryService, playlists: any PlaylistService, resolver: any PlaybackResolver, offline: any OfflineMediaStore, routes: any RouteProvider, lyrics: any LyricsProvider, outbox: any MutationOutbox) {
        self.catalog = catalog; self.accounts = accounts; self.library = library; self.playlists = playlists; self.resolver = resolver; self.offline = offline; self.routes = routes; self.lyrics = lyrics; self.outbox = outbox
    }
}

public extension PlaybackEngine {
    func validatesObservation(_ event: ScopedEngineEvent) async -> Bool { true }
}
