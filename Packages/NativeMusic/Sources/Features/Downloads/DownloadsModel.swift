import Domain
import Foundation
import Observation

/// The Downloads screen's state. It shows what the download engine reports and sends the person's explicit requests back;
/// it decides nothing about storage, retention or scheduling.
@MainActor @Observable public final class DownloadsModel {
    public enum Filter: String, CaseIterable, Sendable { case all, downloadedOnly }
    public private(set) var snapshot: DownloadsSnapshot
    public var filter: Filter = .all
    public var importing = false
    /// The last request the engine refused or could not finish, in words. Cleared by the next successful request.
    public private(set) var notice: String?
    public let isDevelopment: Bool
    @ObservationIgnored private let controller: any DownloadsControlling
    @ObservationIgnored private var updates: Task<Void, Never>?

    public init(controller: any DownloadsControlling, initial: DownloadsSnapshot = .unbound, development: Bool = false) {
        self.controller = controller; snapshot = initial; isDevelopment = development
    }
    deinit { updates?.cancel() }


    /// Starts following the engine. Safe to call again; the screen calls it when it appears.
    public func start() {
        guard updates == nil else { return }
        updates = Task { [weak self, controller] in
            let stream = await controller.updates()
            for await value in stream { guard !Task.isCancelled else { return }; self?.snapshot = value }
        }
    }
    public func stop() { updates?.cancel(); updates = nil }

    public var visibleRows: [DownloadRowModel] {
        switch filter {
        case .all: snapshot.rows
        case .downloadedOnly: snapshot.rows.filter { $0.phase == .available || $0.phase == .renewing }
        }
    }
    public func perform(_ action: DownloadAction, on row: DownloadRowModel) {
        Task { [weak self, controller] in self?.settle(await controller.perform(action, job: row.id), subject: row.title) }
    }
    public func setBudget(bytes: Int64) { Task { [weak self, controller] in self?.settle(await controller.setBudget(bytes: bytes), subject: nil) } }
    public func setSmartDownloads(_ enabled: Bool) { Task { [weak self, controller] in self?.settle(await controller.setSmartDownloads(enabled: enabled), subject: nil) } }
    public func removeAutomaticDownloads() { Task { [weak self, controller] in self?.settle(await controller.removeAutomaticDownloads(), subject: nil) } }
    public func addFiles(_ urls: [URL]) {
        Task { [weak self, controller] in
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                self?.settle(await controller.addLocalFile(url), subject: url.deletingPathExtension().lastPathComponent)
            }
        }
    }
    public func dismissNotice() { notice = nil }
    private func settle(_ result: DownloadCommandResult, subject: String?) {
        switch result {
        case .done: notice = nil
        case .notOffered: notice = DownloadsText.youTubeMusicExplanation
        case .refused(let error): notice = DownloadsText.refusal(error, subject: subject)
        }
    }
}

public enum DownloadBudgetChoices {
    public static let gibibyte: Int64 = 1 << 30
    public static let defaultBytes = 20 * gibibyte
    public static let choices: [Int64] = [5, 10, 20, 50, 100, 200, 500].map { $0 * gibibyte }
    /// The offered sizes plus the current one, so a budget set elsewhere is never shown as something it is not.
    public static func options(including current: Int64) -> [Int64] { Array(Set(choices + [current])).sorted() }
}

public extension DownloadsSnapshot {
    /// What the screen shows before the engine exists: no account, nothing stored, the default limit.
    static let unbound = DownloadsSnapshot(rows: [], collections: [], aggregate: nil, activeCount: 0, waitingCount: 0,
        storage: DownloadStorageSummary(usedBytes: 0, budgetBytes: DownloadBudgetChoices.defaultBytes, reserveBytes: 0, volumeAvailableBytes: 0, pinnedBytes: 0, automaticBytes: 0, automaticCapBytes: 0),
        storageChoices: [], smartDownloadsEnabled: false, concurrencyLimit: 2, lowPowerMode: false, networkConstrained: false, networkExpensive: false, networkAvailable: true, hasAccount: false)
}
