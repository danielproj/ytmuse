import AccountSession
import Domain
import Foundation
import Observation

/// What the app can do about YouTube Music's own history controls. There is no request this app can send to pause or clear
/// YouTube Music's history, so each is unavailable and says why. Clearing this Mac's local record is a different thing and is
/// never offered as a stand-in (LIB05, SYNC07).
public struct RemoteHistoryControls: Sendable, Equatable {
    public struct Unavailable: Sendable, Equatable { public let title: String; public let reason: String }
    public let pause: Unavailable
    public let clear: Unavailable
    public static let current = RemoteHistoryControls(
        pause: .init(title: String(localized: "Pause history"),
                     reason: String(localized: "YouTube Music’s own history can’t be paused from this app: the service gives it no request to do that. Use your Google Account’s activity controls.")),
        clear: .init(title: String(localized: "Clear history"),
                     reason: String(localized: "YouTube Music’s own history can’t be cleared from this app: the service gives it no request to do that. Use your Google Account’s activity controls.")))
}

/// History, two kinds kept apart:
/// - **YouTube Music history** (`remote`): read from the service's history page. YouTube's own player records it when the hidden
///   player plays; this app never writes, edits or imitates it;
/// - **On this Mac** (`local`): the app's own record of what it actually played, `Local only`. Clearing it clears this record and
///   nothing else, and says so.
@MainActor @Observable public final class HistoryModel {
    public let remote: LibraryCollectionModel
    public private(set) var local: [LocalHistoryRecord] = []
    public private(set) var localLoaded = false
    /// This Mac's record could not be read or written (it is reported, not hidden).
    public private(set) var localFailure = false
    public private(set) var localCleared = false
    public let controls = RemoteHistoryControls.current
    /// Plays that finished while no account was active are not recorded; the count is a measurement.
    @ObservationIgnored public private(set) var droppedWithoutAccount = 0
    @ObservationIgnored private var recorder: ListeningHistoryRecorder?
    @ObservationIgnored private let store: (any LocalHistoryStoring)?
    @ObservationIgnored private let accountKey: @MainActor () -> String?
    @ObservationIgnored private let limit: Int
    /// Writes run one after another, so a play's top-up can never land before the play itself.
    @ObservationIgnored private var writes: Task<Void, Never>?

    public init(remote: LibraryCollectionModel, store: (any LocalHistoryStoring)?, policy: ListeningPolicy?, accountKey: @escaping @MainActor () -> String?, limit: Int = 500) {
        self.remote = remote; self.store = store; recorder = policy.map { ListeningHistoryRecorder(policy: $0) }; self.accountKey = accountKey; self.limit = limit
    }

    /// Local history exists only with a store and an adapter-defined listening policy.
    public var hasLocalStore: Bool { store != nil && recorder != nil }

    /// One reading of real playback progress. Records at most one local play per listened occurrence, and tops up that play's heard time as
    /// listening goes on.
    public func observe(_ reading: ListeningObservation) {
        let record = recorder?.observe(reading)
        let update = recorder?.takeUpdate()
        guard record != nil || update != nil else { return }
        guard let account = accountKey(), let store else { if record != nil { droppedWithoutAccount += 1 }; return }
        if let update { write(account: account) { try await store.update(update, account: account) } }
        if let record { write(account: account) { try await store.append(record, account: account) } }
    }
    private func write(account: String, _ operation: @escaping @Sendable () async throws -> Void) {
        let previous = writes
        writes = Task { [weak self] in
            await previous?.value
            do { try await operation() } catch { self?.localFailure = true; return }
            await self?.reloadLocal(account: account)
        }
    }
    /// Everything this Mac keeps for the account (the store's own bound, not the screen's `limit`), for totals that must not stop at a page.
    public func allLocalRecords() async -> [LocalHistoryRecord] {
        guard let account = accountKey(), let store else { return [] }
        await writes?.value
        return (try? await store.recent(account: account, limit: .max)) ?? local
    }
    public func loadLocal() async {
        guard let account = accountKey() else { local = []; localLoaded = true; return }
        await reloadLocal(account: account)
    }
    private func reloadLocal(account: String) async {
        guard let store else { local = []; localLoaded = true; return }
        do {
            let records = try await store.recent(account: account, limit: limit)
            guard accountKey() == account else { return }
            local = records; localLoaded = true; localFailure = false
            if !records.isEmpty { localCleared = false }
        } catch { localFailure = true; localLoaded = true }
    }
    /// Clears this Mac's record. Never touches the service and never reads as having cleared its history.
    public func clearLocal() async {
        guard let account = accountKey(), let store else { return }
        do { try await store.clear(account: account); guard accountKey() == account else { return }; local = []; localCleared = true; localFailure = false }
        catch { localFailure = true }
    }
    public func accountChanged() {
        local = []; localLoaded = false; localCleared = false; localFailure = false
        recorder = recorder.map { ListeningHistoryRecorder(policy: $0.policy) }
        remote.accountChanged()
    }
}
