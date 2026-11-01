import AccountSession
import Domain
import Downloads
import Features
import Foundation
import Playback

/// The Downloads engine as the app composes it. The engine needs the app's data directory and Keychain, which exist only
/// once the account store has opened, so this actor exists from launch, answers "no account" until `attach`, and forwards
/// afterwards. It is also the engine's account-lifecycle participant.
/// What a native session needs to play kept items; built from the engine's own store.
struct RetainedPlaybackParts: Sendable {
    let assets: RetainedAssets
    let playback: RetainedPlayback
}
/// Variant → content type, filled as items are resolved (the loader asks for it when a session opens).
final class ContentTypes: @unchecked Sendable {
    private let lock = NSLock(); private var map: [String: String] = [:]
    func set(_ type: String?, for variant: String) { guard let type else { return }; lock.lock(); map[variant] = type; lock.unlock() }
    func value(for variant: String) -> String? { lock.lock(); defer { lock.unlock() }; return map[variant] }
}
actor LateBoundDownloads: DownloadsControlling, DownloadsSettingsControlling, AccountLifecycleParticipant {
    nonisolated let participantID = "downloads-late-bound"
    private var scheduler: DownloadScheduler?
    private var pendingContext: RequestContext?
    private var identityConnected = false
    private var store: EncryptedStore?
    private var player: (@Sendable (PlayableDownload) async -> Bool)?

    /// Opens the encrypted store and ledger under `directory`. Nothing here reads a credential until a download is requested.
    func attach(directory: URL, vault: any ScopedProtectedRecords, volume: any VolumeCapacityProviding = SystemVolumeCapacity()) async throws {
        guard scheduler == nil else { return }
        let root = directory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try EncryptedStore(root: root.appendingPathComponent("retained"), vault: vault)
        // YouTube Music has no source here by design: its items get an explanation, never a queued job.
        let local = LocalFileDownloadSource(issuer: String(localized: "File chosen on this Mac"))
        let scheduler = try DownloadScheduler(ledgerRoot: root.appendingPathComponent("jobs"), sink: EncryptedStoreSink(store: store), sources: [.localFile: local],
                                              network: SystemNetworkPath(), power: SystemPowerState(), volume: volume)
        await scheduler.startObserving()
        self.scheduler = scheduler; self.store = store
        if let player { await scheduler.installPlayHandler(player) }
        if identityConnected, let pendingContext { await scheduler.bind(pendingContext) }
    }
    func quit() async { await scheduler?.quit() }
    /// The composition's way to start native playback of a kept item. Until it is set (and the engine exists) no Play action is offered.
    func setPlayer(_ player: @escaping @Sendable (PlayableDownload) async -> Bool) async { self.player = player; await scheduler?.installPlayHandler(player) }
    /// The pieces a native playback session needs to play kept items from the encrypted store, or nil before the engine exists.
    func playbackParts() -> RetainedPlaybackParts? {
        guard let store, let scheduler else { return nil }
        let types = ContentTypes()
        return RetainedPlaybackParts(assets: RetainedAssets(store: store, contentType: { types.value(for: $0) }), playback: RetainedPlayback { media in
            let kept = await scheduler.playable(media); if let kept { types.set(kept.contentType, for: kept.variant) }; return kept
        })
    }
    func play(job: UUID) async -> DownloadCommandResult { await scheduler?.play(job: job) ?? .refused(.unauthorized) }
    func setCurrentPlayback(_ media: ServiceID?) async { await scheduler?.setCurrentPlayback(media) }

    func snapshot() async -> DownloadsSnapshot { await scheduler?.snapshot() ?? DownloadsSnapshot.unbound }
    func updates() async -> AsyncStream<DownloadsSnapshot> {
        if let scheduler { return await scheduler.updates() }
        return AsyncStream { $0.yield(DownloadsSnapshot.unbound); $0.finish() }
    }
    func perform(_ action: DownloadAction, job: UUID) async -> DownloadCommandResult { await scheduler?.perform(action, job: job) ?? .refused(.unauthorized) }
    func setBudget(bytes: Int64) async -> DownloadCommandResult { await scheduler?.setBudget(bytes: bytes) ?? .refused(.unauthorized) }
    func setSmartDownloads(enabled: Bool) async -> DownloadCommandResult { await scheduler?.setSmartDownloads(enabled: enabled) ?? .refused(.unauthorized) }
    func addLocalFile(_ file: URL) async -> DownloadCommandResult { await scheduler?.addLocalFile(file) ?? .refused(.unauthorized) }
    func removeAutomaticDownloads() async -> DownloadCommandResult { await scheduler?.removeAutomaticDownloads() ?? .refused(.unauthorized) }
    // W27: settings and accounting.
    func setAutomaticOnExpensive(enabled: Bool) async -> DownloadCommandResult { await scheduler?.setAutomaticOnExpensive(enabled: enabled) ?? .refused(.unauthorized) }
    func automaticOnExpensiveAllowed() async -> Bool { await scheduler?.automaticOnExpensiveAllowed ?? false }
    func usage(for account: AccountContext) async -> AccountDownloadUsage { await scheduler?.usage(for: account) ?? AccountDownloadUsage() }
    func usageAcrossAccounts() async -> AccountDownloadUsage { await scheduler?.usageAcrossAccounts() ?? AccountDownloadUsage() }
    func usageOutside(_ accounts: [AccountContext]) async -> AccountDownloadUsage { await scheduler?.usageOutside(accounts) ?? AccountDownloadUsage() }
    func objectStoreBytes() async -> Int64 { await store?.onDiskObjectBytes() ?? 0 }

    func detach(previous: RequestContext, barrier: RequestContext) async throws { pendingContext = nil; identityConnected = false; try await scheduler?.detach(previous: previous, barrier: barrier) }
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {
        pendingContext = context; identityConnected = identity.state == .connected
        try await scheduler?.restorePaused(identity, context: context)
    }
    func removeLocal(_ account: AccountContext, context: RequestContext) async throws {
        if pendingContext?.account == account { pendingContext = nil; identityConnected = false }
        try await scheduler?.removeLocal(account, context: context)
    }
}

#if DEBUG
/// Debug-only, labelled development data for the isolated UI run of the Downloads screen. It is a small deterministic state
/// machine behind the same `DownloadsControlling` seam, with no file, store, Keychain or network behind it: the engine's real
/// behaviour is covered by the headless T15 suite. It exists only when `YTMUSE_UI_DEVELOPMENT_DATA=1`,
/// `YTMUSE_UI_DEVELOPMENT_DOWNLOADS=1` and QA isolation are all set, and no Release build contains it.
enum DevelopmentDownloads {
    static func isEnabled(_ environment: [String: String]) -> Bool {
        DevelopmentSearch.isEnabled(environment) && environment["YTMUSE_UI_DEVELOPMENT_DOWNLOADS"] == "1"
    }
    static var enabled: Bool { isEnabled(ProcessInfo.processInfo.environment) }
}
actor DevelopmentDownloadsController: DownloadsControlling {
    private struct Item { var row: DownloadRowModel; var total: Int64? }
    private var items: [Item] = []
    private var budget: Int64 = 20 << 30
    private var smart = false
    private var expensive = true
    private var subscribers: [UUID: AsyncStream<DownloadsSnapshot>.Continuation] = [:]
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    private static func media(_ name: String) -> ServiceID { try! ServiceID("owned-development-" + name) }

    init() {
        func row(_ n: Int, _ title: String, _ phase: DownloadPhase, done: Int64, total: Int64?, cause: DownloadPauseCause? = nil, failure: DownloadFailure? = nil, pinned: Bool = true, stored: Int64 = 0, actions: [DownloadAction]) -> Item {
            Item(row: DownloadRowModel(id: Self.id(n), media: Self.media(title), title: title, subtitle: String(localized: "Development data"), origin: .owned, phase: phase, progress: DownloadProgress(completedBytes: done, totalBytes: total),
                                       pauseCause: cause, failure: failure, pinned: pinned, automatic: false, referenceCount: 1, storedBytes: stored, retryAt: nil, expiresAt: nil, actions: actions), total: total)
        }
        items = [
            row(1, "Kept recording", .available, done: 4 << 20, total: 4 << 20, stored: 4 << 20, actions: [.remove]),
            row(2, "Unknown length stream", .downloading, done: 3 << 20, total: nil, actions: [.pause, .cancel]),
            row(3, "Metered wait", .paused, done: 1 << 20, total: 8 << 20, cause: .expensiveNetwork, actions: [.downloadOnThisNetwork, .cancel]),
            row(4, "Damaged copy", .failed, done: 0, total: 2 << 20, failure: .corruptBytes, actions: [.downloadAgain, .remove]),
            row(5, "Halfway", .downloading, done: 2 << 20, total: 4 << 20, actions: [.pause, .cancel]),
        ]
    }
    private func snapshotNow() -> DownloadsSnapshot {
        let rows = items.map(\.row)
        let active = rows.filter { [.downloading, .queued, .paused].contains($0.phase) }
        let unknown = active.contains { $0.progress.totalBytes == nil }
        let aggregate = active.isEmpty ? nil : DownloadProgress(completedBytes: active.reduce(0) { $0 + $1.progress.completedBytes }, totalBytes: unknown ? nil : active.reduce(0) { $0 + ($1.progress.totalBytes ?? 0) })
        let used = rows.filter { $0.phase == .available }.reduce(0) { $0 + $1.storedBytes }
        return DownloadsSnapshot(rows: rows, collections: [], aggregate: aggregate, activeCount: rows.filter { $0.phase == .downloading }.count, waitingCount: rows.filter { $0.phase == .paused || $0.phase == .queued }.count,
                                 storage: DownloadStorageSummary(usedBytes: used, budgetBytes: budget, reserveBytes: 50 << 30, volumeAvailableBytes: 400 << 30, pinnedBytes: used, automaticBytes: 0, automaticCapBytes: budget / 4),
                                 storageChoices: [], smartDownloadsEnabled: smart, concurrencyLimit: 2, lowPowerMode: false, networkConstrained: false, networkExpensive: expensive, networkAvailable: true, hasAccount: true)
    }
    private func publish() { let value = snapshotNow(); for c in subscribers.values { c.yield(value) } }
    func snapshot() async -> DownloadsSnapshot { snapshotNow() }
    func updates() async -> AsyncStream<DownloadsSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation; continuation.yield(snapshotNow())
            continuation.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        }
    }
    private func drop(_ id: UUID) { subscribers[id] = nil }
    func perform(_ action: DownloadAction, job: UUID) async -> DownloadCommandResult {
        guard let index = items.firstIndex(where: { $0.row.id == job }) else { return .refused(.unavailableContent) }
        var r = items[index].row
        func replace(phase: DownloadPhase, cause: DownloadPauseCause? = nil, actions: [DownloadAction], done: Int64? = nil, stored: Int64? = nil) {
            r = DownloadRowModel(id: r.id, media: r.media, title: r.title, subtitle: r.subtitle, origin: r.origin, phase: phase, progress: DownloadProgress(completedBytes: done ?? r.progress.completedBytes, totalBytes: r.progress.totalBytes), pauseCause: cause,
                                 failure: nil, pinned: r.pinned, automatic: r.automatic, referenceCount: r.referenceCount, storedBytes: stored ?? r.storedBytes, retryAt: nil, expiresAt: nil, actions: actions)
            items[index].row = r
        }
        switch action {
        case .pause: replace(phase: .paused, cause: .userPaused, actions: [.resume, .cancel])
        case .resume: replace(phase: .downloading, actions: [.pause, .cancel])
        case .downloadOnThisNetwork: replace(phase: .downloading, actions: [.pause, .cancel])
        case .downloadAgain: replace(phase: .downloading, actions: [.pause, .cancel], done: 0)
        case .cancel, .remove: items.remove(at: index)
        default: return .refused(.invalidInput(.invalidTransition))
        }
        publish(); return .done
    }
    func setBudget(bytes: Int64) async -> DownloadCommandResult { budget = bytes; publish(); return .done }
    func setSmartDownloads(enabled: Bool) async -> DownloadCommandResult { .refused(.unsupported) }
    func addLocalFile(_ file: URL) async -> DownloadCommandResult { .refused(.unsupported) }
    func play(job: UUID) async -> DownloadCommandResult { .refused(.unsupported) }
    func removeAutomaticDownloads() async -> DownloadCommandResult { .done }
}
#endif
