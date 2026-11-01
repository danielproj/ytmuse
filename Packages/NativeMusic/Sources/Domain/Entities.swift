import Foundation

public struct Account: Sendable {
    public let id: UUID
    public let serviceIdentity: ServiceID
    public let context: AccountContext
    public let displayName: String
    public let credential: CredentialReference?
    public init(id: UUID, serviceIdentity: ServiceID, context: AccountContext, displayName: String, credential: CredentialReference?) throws(DomainError) {
        guard id == context.accountID else { throw .invalidInput(.contextMismatch) }
        self.id = id; self.serviceIdentity = serviceIdentity; self.context = context; self.displayName = displayName; self.credential = credential
    }
}
public enum MediaKind: String, Sendable { case song, video, episode, live, sample }
public enum Availability: Equatable, Sendable { case available, unknown, unavailable(DomainError) }
public struct MediaItem: Sendable {
    public let id: ServiceID
    public let kind: MediaKind
    public let title: String
    public let artists: [ServiceID]
    public let duration: Double?
    public let artwork: [ServiceID]
    public let explicit: Bool?
    public let availability: Availability
    public init(id: ServiceID, kind: MediaKind, title: String, artists: [ServiceID], duration: Double?, artwork: [ServiceID], explicit: Bool?, availability: Availability) throws(DomainError) {
        guard duration.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw .invalidInput(.negativeValue) }
        self.id = id; self.kind = kind; self.title = title; self.artists = artists; self.duration = duration; self.artwork = artwork; self.explicit = explicit; self.availability = availability
    }
}
public struct CatalogMetadata: Sendable {
    public let id: ServiceID
    public let title: String
    public let description: String?
    public let artwork: [ServiceID]
    public let related: [ServiceID]
    public let page: PageCursor?
    public init(id: ServiceID, title: String, description: String? = nil, artwork: [ServiceID] = [], related: [ServiceID] = [], page: PageCursor? = nil) {
        self.id = id; self.title = title; self.description = description; self.artwork = artwork; self.related = related; self.page = page
    }
}
public struct Album: Sendable { public let metadata: CatalogMetadata; public let tracks: Page<MediaItem>; public init(metadata: CatalogMetadata, tracks: Page<MediaItem>) { self.metadata = metadata; self.tracks = tracks } }
public struct Artist: Sendable { public let metadata: CatalogMetadata; public let releases: Page<CatalogMetadata>; public init(metadata: CatalogMetadata, releases: Page<CatalogMetadata>) { self.metadata = metadata; self.releases = releases } }
public struct Podcast: Sendable { public let metadata: CatalogMetadata; public let episodes: Page<MediaItem>; public init(metadata: CatalogMetadata, episodes: Page<MediaItem>) { self.metadata = metadata; self.episodes = episodes } }
public enum PlaylistPrivacy: String, Sendable { case `private`, unlisted, `public` }
public struct Playlist: Sendable {
    public let metadata: CatalogMetadata
    public let owner: ServiceID
    public let privacy: PlaylistPrivacy
    public let permissions: [Feature: CapabilityState]
    public let providerVersion: String?
    public let snapshotVersion: UInt64
    public init(metadata: CatalogMetadata, owner: ServiceID, privacy: PlaylistPrivacy = .private, permissions: [Feature: CapabilityState], providerVersion: String?, snapshotVersion: UInt64) {
        self.metadata = metadata; self.owner = owner; self.privacy = privacy; self.permissions = permissions; self.providerVersion = providerVersion; self.snapshotVersion = snapshotVersion
    }
}
public enum OccurrenceIdentity: Hashable, Sendable { case provider(ServiceID), synthetic(UUID) }
public struct PlaylistItem: Sendable {
    public let occurrence: OccurrenceIdentity
    public let media: ServiceID
    public init(occurrence: OccurrenceIdentity, media: ServiceID) { self.occurrence = occurrence; self.media = media }
}
public enum QueueSegment: String, Sendable { case user, playNext, addToQueue, context, recommendation, history, advertisement }
public struct QueueEntry: Sendable {
    public let id: UUID
    public let media: ServiceID
    public let segment: QueueSegment
    public let originalOrder: Int
    public let consumed: Bool
    public init(id: UUID = UUID(), media: ServiceID, segment: QueueSegment, originalOrder: Int, consumed: Bool = false) throws(DomainError) {
        guard originalOrder >= 0 else { throw .invalidInput(.negativeValue) }
        self.id = id; self.media = media; self.segment = segment; self.originalOrder = originalOrder; self.consumed = consumed
    }
}
public enum RepeatMode: String, Sendable { case off, one, all }
public struct QueueSession: Sendable {
    public let account: AccountContext
    public let version: UInt64
    public let entries: [QueueEntry]
    public let currentOccurrence: UUID?
    public let position: Double
    public let shuffleSeed: UInt64?
    public let repeatMode: RepeatMode
    public let autoplay: Bool
    public init(account: AccountContext, version: UInt64, entries: [QueueEntry], currentOccurrence: UUID?, position: Double, shuffleSeed: UInt64?, repeatMode: RepeatMode, autoplay: Bool) throws(DomainError) {
        guard Set(entries.map(\.id)).count == entries.count else { throw .invalidInput(.duplicateOccurrence) }
        guard currentOccurrence.map({ id in entries.contains { $0.id == id } }) ?? true else { throw .invalidInput(.missingCurrentOccurrence) }
        guard position.isFinite, position >= 0 else { throw .invalidInput(.negativeValue) }
        self.account = account; self.version = version; self.entries = entries; self.currentOccurrence = currentOccurrence; self.position = position; self.shuffleSeed = shuffleSeed; self.repeatMode = repeatMode; self.autoplay = autoplay
    }
}
public struct MediaVariant: Sendable {
    public let id: ServiceID
    public let codec: String
    public let container: String
    public let bitrate: Int?
    public let sampleRate: Int?
    public let expiresAt: Date?
    public let seekable: Bool
    public let authorization: AuthorizationReference
    public init(id: ServiceID, codec: String, container: String, bitrate: Int?, sampleRate: Int?, expiresAt: Date?, seekable: Bool, authorization: AuthorizationReference) throws(DomainError) {
        guard bitrate.map({ $0 > 0 }) ?? true, sampleRate.map({ $0 > 0 }) ?? true else { throw .invalidInput(.negativeValue) }
        self.id = id; self.codec = codec; self.container = container; self.bitrate = bitrate; self.sampleRate = sampleRate; self.expiresAt = expiresAt; self.seekable = seekable; self.authorization = authorization
    }
}
public struct ByteRange: Equatable, Sendable {
    public let lower: Int64; public let upper: Int64
    public init(lower: Int64, upper: Int64) throws(DomainError) {
        guard lower >= 0, upper >= lower else { throw .invalidInput(.invalidRange) }; self.lower = lower; self.upper = upper
    }
}
public enum Verification: Equatable, Sendable { case unknown, verified(hash: String, at: Date), failed(DomainError) }
public enum DownloadState: Equatable, Sendable { case queued, running, paused, completed, failed(DomainError), cancelled }
public struct DownloadJob: Sendable {
    public let id: UUID; public let account: AccountContext; public let media: ServiceID; public let variant: ServiceID
    public let ranges: [ByteRange]; public let state: DownloadState; public let size: Int64?; public let retries: Int
    public let references: Set<ServiceID>; public let verification: Verification
    public init(id: UUID = UUID(), account: AccountContext, media: ServiceID, variant: ServiceID, ranges: [ByteRange], state: DownloadState, size: Int64?, retries: Int, references: Set<ServiceID>, verification: Verification) throws(DomainError) {
        guard retries >= 0, size.map({ $0 >= 0 }) ?? true else { throw .invalidInput(.negativeValue) }
        let sorted = ranges.sorted { $0.lower < $1.lower }
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.upper < $1.lower }), ranges.allSatisfy({ range in size.map { range.upper < $0 } ?? true }) else { throw .invalidInput(.invalidRange) }
        if state == .completed { guard case .verified = verification else { throw .invalidInput(.invalidTransition) } }
        self.id = id; self.account = account; self.media = media; self.variant = variant; self.ranges = ranges; self.state = state; self.size = size; self.retries = retries; self.references = references; self.verification = verification
    }
}
public enum OfflineRight: String, Hashable, Sendable { case play, seek, retain }
public struct OfflineEntitlement: Sendable {
    public let account: AccountContext; public let media: ServiceID; public let source: String
    public let rights: Set<OfflineRight>; public let expiresAt: Date; public let renewAfter: Date?; public let lastValidatedAt: Date; public let validation: Availability
    public init(account: AccountContext, media: ServiceID, source: String, rights: Set<OfflineRight>, expiresAt: Date, renewAfter: Date?, lastValidatedAt: Date, validation: Availability) throws(DomainError) {
        guard !source.isEmpty, renewAfter.map({ $0 <= expiresAt }) ?? true else { throw .invalidInput(.invalidRange) }
        self.account = account; self.media = media; self.source = source; self.rights = rights; self.expiresAt = expiresAt; self.renewAfter = renewAfter; self.lastValidatedAt = lastValidatedAt; self.validation = validation
    }
    public func permits(_ right: OfflineRight, context: AccountContext, now: Date) -> Bool {
        account == context && validation == .available && now >= lastValidatedAt && now < expiresAt && rights.contains(right)
    }
}
public enum SyncState: Equatable, Sendable { case localOnly, pending(UUID), confirmed, failed(DomainError), needsReconciliation }
public struct LibraryMembership: Sendable {
    public let account: AccountContext; public let entity: ServiceID; public let serviceStatus: Bool?; public let sync: SyncState; public let sortDate: Date?; public let sortKey: String
    public init(account: AccountContext, entity: ServiceID, serviceStatus: Bool?, sync: SyncState, sortDate: Date?, sortKey: String) { self.account = account; self.entity = entity; self.serviceStatus = serviceStatus; self.sync = sync; self.sortDate = sortDate; self.sortKey = sortKey }
}
public enum HistoryProvenance: String, Sendable { case source, local }
public struct HistoryEntry: Sendable {
    public let id: UUID; public let account: AccountContext; public let item: ServiceID; public let startedAt: Date; public let endedAt: Date?; public let provenance: HistoryProvenance; public let sync: SyncState
    public init(id: UUID = UUID(), account: AccountContext, item: ServiceID, startedAt: Date, endedAt: Date?, provenance: HistoryProvenance, sync: SyncState) throws(DomainError) {
        guard endedAt.map({ $0 >= startedAt }) ?? true else { throw .invalidInput(.invalidRange) }
        self.id = id; self.account = account; self.item = item; self.startedAt = startedAt; self.endedAt = endedAt; self.provenance = provenance; self.sync = sync
    }
}
public struct MutationPrecondition: Equatable, Sendable {
    public let providerVersion: String?; public let snapshotVersion: UInt64
    public init(providerVersion: String?, snapshotVersion: UInt64) { self.providerVersion = providerVersion; self.snapshotVersion = snapshotVersion }
}
public struct PendingMutation: Sendable {
    public let id: UUID; public let account: AccountContext; public let target: ServiceID; public let intent: RemoteMutation; public let precondition: MutationPrecondition; public let attempts: Int; public let outcome: SyncState
    public init(id: UUID = UUID(), account: AccountContext, target: ServiceID, intent: RemoteMutation, precondition: MutationPrecondition, attempts: Int = 0, outcome: SyncState) throws(DomainError) {
        guard attempts >= 0 else { throw .invalidInput(.negativeValue) }
        if case .pending(let operation) = outcome, operation != id { throw .invalidInput(.contextMismatch) }
        self.id = id; self.account = account; self.target = target; self.intent = intent; self.precondition = precondition; self.attempts = attempts; self.outcome = outcome
    }
}
public enum CachePolicy: Equatable, Sendable { case noStore, until(Date), revalidate }
public struct ArtworkCacheEntry: Sendable {
    public let sourceKey: ServiceID; public let width: Int; public let height: Int; public let policy: CachePolicy; public let contentHash: String; public let bytes: Int64; public let lastUsedAt: Date
    public init(sourceKey: ServiceID, width: Int, height: Int, policy: CachePolicy, contentHash: String, bytes: Int64, lastUsedAt: Date) throws(DomainError) {
        guard width > 0, height > 0, bytes >= 0, !contentHash.isEmpty else { throw .invalidInput(.negativeValue) }
        self.sourceKey = sourceKey; self.width = width; self.height = height; self.policy = policy; self.contentHash = contentHash; self.bytes = bytes; self.lastUsedAt = lastUsedAt
    }
}
public enum PreferenceScope: Hashable, Sendable { case global, account(AccountContext), window(UUID) }
public enum PreferenceValue: Equatable, Sendable { case boolean(Bool), integer(Int), number(Double), text(String) }
public struct Preferences: Sendable {
    public let scope: PreferenceScope; public let schemaVersion: Int; public let values: [String: PreferenceValue]
    public init(scope: PreferenceScope, schemaVersion: Int, values: [String: PreferenceValue]) throws(DomainError) {
        guard schemaVersion > 0 else { throw .invalidInput(.negativeValue) }
        guard values.values.allSatisfy({ if case .number(let number) = $0 { return number.isFinite }; return true }) else { throw .invalidInput(.invalidRange) }
        self.scope = scope; self.schemaVersion = schemaVersion; self.values = values
    }
}

/// A validated process-local lease binds server expiry to elapsed monotonic time.
/// Recreated only after entitlement validation; never persisted across boots.
public struct EntitlementLease: Sendable {
    private let entitlement: OfflineEntitlement
    private let wallAnchor: Date
    private let monotonicAnchor: Duration
    public init(entitlement: OfflineEntitlement, validatedAt: Date, monotonic: Duration) throws(DomainError) {
        guard entitlement.validation == .available, validatedAt >= entitlement.lastValidatedAt, validatedAt < entitlement.expiresAt else { throw .expiredMedia }
        self.entitlement = entitlement; wallAnchor = validatedAt; monotonicAnchor = monotonic
    }
    public func permits(_ right: OfflineRight, context: AccountContext, wall: Date, monotonic: Duration) -> Bool {
        guard monotonic >= monotonicAnchor, wall >= wallAnchor else { return false }
        let elapsed = (monotonic - monotonicAnchor).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return seconds < entitlement.expiresAt.timeIntervalSince(wallAnchor) && entitlement.permits(right, context: context, now: wall)
    }
}
