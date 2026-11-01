import Foundation

/// Where a piece of media comes from decides whether keeping a copy is permitted at all. Classification is a pure function of the
/// identifier so every layer (scheduler, UI, tests) agrees without asking a service.
public enum MediaOrigin: String, Codable, Sendable, Equatable {
    /// Plays only through YouTube Music's own web player. The web client offers no downloads and obtaining files would need the
    /// circumvention the playback addendum forbids, so no download route exists (W36 owns any future authorized route).
    case youTubeMusic
    /// Bundled, licensed synthetic test media.
    case owned
    /// A file the account holder chose on this Mac.
    case localFile
    /// A source that publishes an explicit download permission for the item. Nothing in this codebase supplies one today.
    case publisherGrant

    public static let localFilePrefix = "local-file:"
    public static let publisherPrefix = "publisher-grant:"
    /// The bundled licensed synthetic items. Owned status is membership of this list, never a spelling: an 11-character
    /// YouTube video id that happens to begin `owned-` is still YouTube Music (F11). A test pins this list to `OwnedMedia`.
    public static let bundledOwnedIdentifiers: Set<String> = ["owned-a", "owned-b", "owned-video"]

    /// `ownedIdentifiers` lets a composition (or a test) that has its own licensed media name it; the default is the bundled set.
    public static func classify(_ media: ServiceID, ownedIdentifiers: Set<String> = MediaOrigin.bundledOwnedIdentifiers) -> MediaOrigin {
        let raw = media.rawValue
        if raw.hasPrefix(localFilePrefix) { return .localFile }
        if raw.hasPrefix(publisherPrefix) { return .publisherGrant }
        if ownedIdentifiers.contains(raw) { return .owned }
        return .youTubeMusic
    }
}

/// Why a download control is not offered. The UI turns this into words; Domain carries no copy.
public enum DownloadUnavailableReason: String, Sendable, Equatable {
    case youTubeMusicNoMacDownloads
}
public enum DownloadEligibility: Equatable, Sendable {
    case eligible(MediaOrigin)
    case notOffered(DownloadUnavailableReason)
    public static func of(_ media: ServiceID, ownedIdentifiers: Set<String> = MediaOrigin.bundledOwnedIdentifiers) -> DownloadEligibility {
        switch MediaOrigin.classify(media, ownedIdentifiers: ownedIdentifiers) {
        case .youTubeMusic: .notOffered(.youTubeMusicNoMacDownloads)
        case let origin: .eligible(origin)
        }
    }
}

/// OFF06: the nine states a download can show.
public enum DownloadPhase: String, Codable, Sendable, CaseIterable {
    case queued, resolving, downloading, paused, validating, available, renewing, expired, failed
}
/// Why a job is not moving although it wants to. Each cause has a plain recovery.
public enum DownloadPauseCause: String, Codable, Sendable, Equatable {
    case userPaused
    case offline, constrainedNetwork, expensiveNetwork
    case storageBudgetFull, volumeReserve, smartCapReached, diskFull
    case accountUnavailable
}
public enum DownloadFailure: String, Codable, Sendable, Equatable {
    case retriesExhausted, corruptBytes, missingKey, accountRevoked, sourceUnavailable, permissionDenied, storageUnavailable
}
public enum DownloadAction: String, Sendable, Equatable, CaseIterable {
    case play, pause, resume, retry, cancel, remove, renew, downloadAgain, pin, unpin, downloadOnThisNetwork
}

/// OFF06: progress never invents a percentage. `fraction` is nil while the total is unknown.
public struct DownloadProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
    }
    public var fraction: Double? {
        guard let totalBytes else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

public struct DownloadRowModel: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let media: ServiceID
    public let title: String
    public let subtitle: String?
    public let origin: MediaOrigin
    public let phase: DownloadPhase
    public let progress: DownloadProgress
    public let pauseCause: DownloadPauseCause?
    public let failure: DownloadFailure?
    public let pinned: Bool
    public let automatic: Bool
    public let referenceCount: Int
    public let storedBytes: Int64
    public let retryAt: Date?
    public let expiresAt: Date?
    public let actions: [DownloadAction]
    public init(id: UUID, media: ServiceID, title: String, subtitle: String?, origin: MediaOrigin, phase: DownloadPhase, progress: DownloadProgress, pauseCause: DownloadPauseCause?, failure: DownloadFailure?, pinned: Bool, automatic: Bool, referenceCount: Int, storedBytes: Int64, retryAt: Date?, expiresAt: Date?, actions: [DownloadAction]) {
        self.id = id; self.media = media; self.title = title; self.subtitle = subtitle; self.origin = origin; self.phase = phase; self.progress = progress; self.pauseCause = pauseCause; self.failure = failure; self.pinned = pinned; self.automatic = automatic; self.referenceCount = referenceCount; self.storedBytes = storedBytes; self.retryAt = retryAt; self.expiresAt = expiresAt; self.actions = actions
    }
}
public struct DownloadCollectionSummary: Identifiable, Equatable, Sendable {
    public let id: ServiceID
    public let title: String
    public let memberCount: Int
    public let availableCount: Int
    public init(id: ServiceID, title: String, memberCount: Int, availableCount: Int) { self.id = id; self.title = title; self.memberCount = memberCount; self.availableCount = availableCount }
}
/// W27: one account's retained download bytes, as the budget counts them (an unlisted remainder counts as stored and as pinned).
public struct AccountDownloadUsage: Equatable, Sendable {
    public let storedBytes: Int64
    public let pinnedBytes: Int64
    public let automaticBytes: Int64
    public let unlistedBytes: Int64
    public init(storedBytes: Int64 = 0, pinnedBytes: Int64 = 0, automaticBytes: Int64 = 0, unlistedBytes: Int64 = 0) { self.storedBytes = storedBytes; self.pinnedBytes = pinnedBytes; self.automaticBytes = automaticBytes; self.unlistedBytes = unlistedBytes }
}

/// OFF03: what the storage section shows and what choices exist when pinned media fills the budget.
public struct DownloadStorageSummary: Equatable, Sendable {
    /// Retained bytes across every account on this Mac.
    public let usedBytes: Int64
    public let budgetBytes: Int64
    public let reserveBytes: Int64
    public let volumeAvailableBytes: Int64
    public let pinnedBytes: Int64
    public let automaticBytes: Int64
    public let automaticCapBytes: Int64
    public init(usedBytes: Int64, budgetBytes: Int64, reserveBytes: Int64, volumeAvailableBytes: Int64, pinnedBytes: Int64, automaticBytes: Int64, automaticCapBytes: Int64) {
        self.usedBytes = usedBytes; self.budgetBytes = budgetBytes; self.reserveBytes = reserveBytes; self.volumeAvailableBytes = volumeAvailableBytes; self.pinnedBytes = pinnedBytes; self.automaticBytes = automaticBytes; self.automaticCapBytes = automaticCapBytes
    }
}
public enum DownloadStorageChoice: String, Sendable, Equatable {
    case raiseBudget, removeDownloads, removeAutomaticDownloads, freeDiskSpace
}
public struct DownloadsSnapshot: Equatable, Sendable {
    public let rows: [DownloadRowModel]
    public let collections: [DownloadCollectionSummary]
    public let aggregate: DownloadProgress?
    public let activeCount: Int
    public let waitingCount: Int
    public let storage: DownloadStorageSummary
    public let storageChoices: [DownloadStorageChoice]
    public let smartDownloadsEnabled: Bool
    public let concurrencyLimit: Int
    public let lowPowerMode: Bool
    public let networkConstrained: Bool
    public let networkExpensive: Bool
    public let networkAvailable: Bool
    public let hasAccount: Bool
    /// Whether anything can suggest items for Smart Downloads on this Mac. False when no permitted source supplies suggestions.
    public let smartDownloadsAvailable: Bool
    /// Bytes still on disk that no ledger entry accounts for (a damaged job record was set aside). They count toward the limit.
    public let unlistedBytes: Int64
    public init(rows: [DownloadRowModel], collections: [DownloadCollectionSummary], aggregate: DownloadProgress?, activeCount: Int, waitingCount: Int, storage: DownloadStorageSummary, storageChoices: [DownloadStorageChoice], smartDownloadsEnabled: Bool, concurrencyLimit: Int, lowPowerMode: Bool, networkConstrained: Bool, networkExpensive: Bool, networkAvailable: Bool, hasAccount: Bool, smartDownloadsAvailable: Bool = false, unlistedBytes: Int64 = 0) {
        self.rows = rows; self.collections = collections; self.aggregate = aggregate; self.activeCount = activeCount; self.waitingCount = waitingCount; self.storage = storage; self.storageChoices = storageChoices; self.smartDownloadsEnabled = smartDownloadsEnabled; self.concurrencyLimit = concurrencyLimit; self.lowPowerMode = lowPowerMode; self.networkConstrained = networkConstrained; self.networkExpensive = networkExpensive; self.networkAvailable = networkAvailable; self.hasAccount = hasAccount; self.smartDownloadsAvailable = smartDownloadsAvailable; self.unlistedBytes = unlistedBytes
    }
}
public enum DownloadCommandResult: Equatable, Sendable {
    case done
    case notOffered(DownloadUnavailableReason)
    case refused(DomainError)
}

/// What the Downloads screen drives. The scheduler implements it; Features depends only on this contract.
public protocol DownloadsControlling: Sendable {
    func snapshot() async -> DownloadsSnapshot
    func updates() async -> AsyncStream<DownloadsSnapshot>
    func perform(_ action: DownloadAction, job: UUID) async -> DownloadCommandResult
    func setBudget(bytes: Int64) async -> DownloadCommandResult
    func setSmartDownloads(enabled: Bool) async -> DownloadCommandResult
    func addLocalFile(_ file: URL) async -> DownloadCommandResult
    /// Plays a kept item through the native player from the encrypted store. Refused while nothing can play it.
    func play(job: UUID) async -> DownloadCommandResult
    func removeAutomaticDownloads() async -> DownloadCommandResult
}

/// W27: the download engine's settings and per-account accounting, for Settings and the storage breakdown. A separate seam so the screen's own controller
/// (`DownloadsControlling`) keeps its shape.
public protocol DownloadsSettingsControlling: Sendable {
    func setAutomaticOnExpensive(enabled: Bool) async -> DownloadCommandResult
    func automaticOnExpensiveAllowed() async -> Bool
    func usage(for account: AccountContext) async -> AccountDownloadUsage
    func usageAcrossAccounts() async -> AccountDownloadUsage
    func usageOutside(_ accounts: [AccountContext]) async -> AccountDownloadUsage
    /// Bytes the encrypted object store holds on disk (W14), for the reconciliation with the ledger.
    func objectStoreBytes() async -> Int64
}
