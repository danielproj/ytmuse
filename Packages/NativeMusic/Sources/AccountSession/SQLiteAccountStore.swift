import Foundation
import Domain
import Persistence

/// The public roster contains profile metadata and random Keychain references only.
/// Each identity has a reserved lifecycle preference beside its normalized profile.
public actor SQLiteAccountDirectory: AccountDirectoryStore {
    private let store: SQLiteStore
    private var context: RequestContext
    public init(store: SQLiteStore, context: RequestContext) { self.store = store; self.context = context }
    public func bind(_ context: RequestContext) {
        guard context.accountGeneration > self.context.accountGeneration else { return }
        self.context = context
    }
    public func load() async throws -> AccountDirectory {
        let records = try await store.localIdentities(context: context)
        let identities = try records.map { record in
            guard let state = LocalSessionState(rawValue: record.state) else { throw LifecycleError.invalidDirectory }
            return LocalIdentity(account: record.account, state: state)
        }
        guard records.filter(\.isDefault).count <= 1 else { throw LifecycleError.invalidDirectory }
        return .init(identities: identities, defaultIdentity: records.first(where: \.isDefault)?.account.context)
    }
    public func save(_ directory: AccountDirectory) async throws {
        try await store.saveLocalIdentities(directory.identities.map {
            StoredLocalIdentity(account: $0.account, state: $0.state.rawValue, isDefault: $0.id == directory.defaultIdentity)
        }, context: context)
    }
}

/// SQLite's own generation barrier gates every private read/write. Queue navigation,
/// outbox and position remain durable on detach/expiry; removal scrubs the partition
/// and versioned backups, FTS, WAL and all cascading account records.
public actor SQLiteAccountParticipant: AccountLifecycleParticipant {
    public nonisolated let participantID = "sqlite"
    private let store: SQLiteStore
    private let directory: SQLiteAccountDirectory
    private var restored: RestoredQueue?
    private var navigation: Preferences?
    public func restoredWorkspace() -> (RestoredQueue?, Preferences?) { (restored, navigation) }
    public init(store: SQLiteStore, directory: SQLiteAccountDirectory) { self.store = store; self.directory = directory }
    public func detach(previous: RequestContext, barrier: RequestContext) async throws {
        restored = nil; navigation = nil
        await store.bind(barrier); await directory.bind(barrier)
    }
    public func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {
        await store.bind(context); await directory.bind(context)
        try await store.saveAccount(identity.account, context: context)
        restored = try await store.restoredQueue(context: context)
        navigation = try await store.preferences(scope: .account(identity.id), context: context).outcome.get()
    }
    public func removeLocal(_ account: AccountContext, context: RequestContext) async throws {
        await store.bind(context); await directory.bind(context)
        try await store.removeDetachedAccount(account, barrier: context)
    }
}
