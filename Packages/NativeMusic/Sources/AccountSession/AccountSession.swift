import Domain
import Foundation
import Security

public enum LocalSessionState: String, Codable, Sendable { case connected, expired, signedOut, removalPending }
public struct LocalIdentity: Sendable, Identifiable {
    public var id: AccountContext { account.context }
    public var account: Account
    public var state: LocalSessionState
    public init(account: Account, state: LocalSessionState = .connected) { self.account = account; self.state = state }
}
public struct AccountDirectory: Sendable {
    public var identities: [LocalIdentity]
    public var defaultIdentity: AccountContext?
    public init(identities: [LocalIdentity] = [], defaultIdentity: AccountContext? = nil) {
        self.identities = identities; self.defaultIdentity = defaultIdentity
    }
}
public protocol AccountDirectoryStore: Actor {
    func load() async throws -> AccountDirectory
    func save(_ directory: AccountDirectory) async throws
}
/// Participants must reject older generations at every effect boundary. detach must
/// stop/pause, checkpoint the previous owner, cancel work, and clear system ownership.
/// restore must expose only the supplied identity, always paused. removeLocal uses
/// the same authoritative detached barrier as detach, including retries. It must
/// perform idempotent cleanup without allocating a new owner. No remote deletion.
public protocol AccountLifecycleParticipant: Actor {
    nonisolated var participantID: String { get }
    func detach(previous: RequestContext, barrier: RequestContext) async throws
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws
    func removeLocal(_ account: AccountContext, context: RequestContext) async throws
}
public struct AuthenticationChallenge: Sendable, Equatable {
    public let state: String
    public let generation: UInt64
    public let identity: AccountContext?
    /// Adapter reconstructs this from the actual callback state and the initiating
    /// attempt's captured generation/identity, rather than substituting stored state.
    public init(state: String, generation: UInt64, identity: AccountContext?) {
        self.state = state; self.generation = generation; self.identity = identity
    }
}
public struct AccountLifecycleSnapshot: Sendable {
    public let directory: AccountDirectory
    public let context: RequestContext
    public let busy: Bool
    public let reconnectPending: Bool
}

/// All lifecycle writes serialize across suspension. Failed transitions leave a newer
/// detached owner; they never roll authority back to a formerly active generation.
public actor AccountLifecycle: CredentialStore {
    private let vault: any SessionVault
    private let store: any AccountDirectoryStore
    private let participants: [any AccountLifecycleParticipant]
    private var directory: AccountDirectory
    private var owner = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
    private var busy = false
    private var challenge: AuthenticationChallenge?
    /// Whether a Keychain read that fails ONLY because interaction is disallowed may be written to
    /// the roster as `.expired`. A Debug or non-production-signed build cannot tell "the record is
    /// unreadable for good" from "this build's signature is not the one that wrote it": it must
    /// leave the stored state alone, because persisting `.expired` locks the real account out of
    /// the build that can read it (see `KeychainExpiryPolicy`).
    private let persistsPromptExpiry: Bool
    /// Identities shown as expired for this run only; the stored roster is unchanged.
    private var promptExpired: Set<AccountContext> = []
    private let staleLedger: any StaleCredentialLedger
    public init(directory: AccountDirectory, vault: any SessionVault, store: any AccountDirectoryStore,
                participants: [any AccountLifecycleParticipant], persistsPromptExpiry: Bool = true,
                staleLedger: any StaleCredentialLedger = MemoryStaleCredentialLedger()) throws {
        self.persistsPromptExpiry = persistsPromptExpiry; self.staleLedger = staleLedger
        guard Set(directory.identities.map(\.id)).count == directory.identities.count,
              directory.defaultIdentity == nil || directory.identities.contains(where: { $0.id == directory.defaultIdentity }),
              Set(participants.map(\.participantID)).count == participants.count else { throw LifecycleError.invalidDirectory }
        self.directory = directory; self.vault = vault; self.store = store; self.participants = participants
    }
    public static func open(vault: any SessionVault, store: any AccountDirectoryStore,
                            participants: [any AccountLifecycleParticipant], persistsPromptExpiry: Bool = true,
                            staleLedger: any StaleCredentialLedger = MemoryStaleCredentialLedger()) async throws -> AccountLifecycle {
        let lifecycle = try await AccountLifecycle(directory: store.load(), vault: vault, store: store, participants: participants, persistsPromptExpiry: persistsPromptExpiry, staleLedger: staleLedger)
        await lifecycle.settlePendingErasure()
        await lifecycle.settleStaleCredentials(allowingInteraction: false)
        return lifecycle
    }
    /// Deletes records that were left behind with no roster entry pointing at them (see
    /// `StaleCredentialLedger`). At launch it runs with the Keychain UI off, so a record that would need
    /// a prompt stays recorded until the next explicit Sign In Again, which may ask. A reference the
    /// roster points at again is never deleted; an identity that no longer exists had all its records
    /// erased with it.
    public func settleStaleCredentials(allowingInteraction: Bool, account only: AccountContext? = nil) async {
        guard let entries = try? await staleLedger.pending() else { return }
        for entry in entries where only == nil || only?.accountID == entry.account {
            guard let identity = directory.identities.first(where: { $0.account.id == entry.account }) else { try? await staleLedger.remove(reference: entry.reference); continue }
            if identity.account.credential == entry.reference { try? await staleLedger.remove(reference: entry.reference); continue }
            do { try await vault.delete(entry.reference, for: identity.id, allowingInteraction: allowingInteraction) } catch { continue }
            try? await staleLedger.remove(reference: entry.reference)
        }
    }
    private func forgetStaleCredentials(of account: AccountContext) async {
        for entry in (try? await staleLedger.pending()) ?? [] where entry.account == account.accountID { try? await staleLedger.remove(reference: entry.reference) }
    }
    /// QL2: a sign-out interrupted before its records were erased (for example by quitting
    /// while macOS asked about a Keychain item) leaves the identity signed out with its
    /// credential reference still recorded, because the reference is cleared only after the
    /// erase succeeds. Retry it here, at launch, with Keychain UI off; success clears the
    /// reference, and a record that would need a prompt stays recorded for the next explicit
    /// Sign In Again, Sign Out or Remove Local Data.
    public func settlePendingErasure() async {
        for i in directory.identities.indices where directory.identities[i].state == .signedOut && directory.identities[i].account.credential != nil {
            let old = directory.identities[i].account
            do { try await vault.deleteAll(for: old.context, allowingInteraction: false) } catch { continue }
            guard let cleared = try? Account(id: old.id, serviceIdentity: old.serviceIdentity, context: old.context, displayName: old.displayName, credential: nil) else { continue }
            var updated = directory; updated.identities[i].account = cleared
            try? await commit(updated)
        }
    }
    public func snapshot() -> AccountLifecycleSnapshot {
        var shown = directory
        for i in shown.identities.indices where promptExpired.contains(shown.identities[i].id) { shown.identities[i].state = .expired }
        return .init(directory: shown, context: owner, busy: busy, reconnectPending: challenge != nil)
    }
    public func reference(for account: AccountContext, context: RequestContext) -> ServiceResult<CredentialReference?> {
        guard accepts(context), context.account == account else { return .init(context: context, outcome: .failure(.staleContext)) }
        guard let identity = directory.identities.first(where: { $0.id == account }), identity.state == .connected, !promptExpired.contains(account) else {
            return .init(context: context, outcome: .failure(.unauthorized))
        }
        return .init(context: context, outcome: .success(identity.account.credential))
    }
    public func remove(for account: AccountContext, context: RequestContext) async -> ServiceResult<Void> {
        guard accepts(context), context.account == account else { return .init(context: context, outcome: .failure(.staleContext)) }
        do { try await signOut(account); return .init(context: context, outcome: .success(())) }
        catch { return .init(context: context, outcome: .failure(.transientTransport)) }
    }
    public func accepts(_ context: RequestContext) -> Bool {
        !busy && owner.account != nil && context.account == owner.account && context.accountGeneration == owner.accountGeneration
    }
    private func lock() throws { guard !busy else { throw LifecycleError.busy }; busy = true }
    private func next(_ account: AccountContext?) throws -> RequestContext {
        guard owner.accountGeneration < .max else { throw LifecycleError.generationExhausted }
        owner = .init(account: account, accountGeneration: owner.accountGeneration + 1, requestGeneration: 0)
        challenge = nil
        return owner
    }
    private func index(_ account: AccountContext) throws -> Int {
        guard let index = directory.identities.firstIndex(where: { $0.id == account }) else { throw LifecycleError.unknownIdentity }
        return index
    }
    private func commit(_ updated: AccountDirectory) async throws {
        try await store.save(updated); directory = updated
    }
    private func detach() async throws {
        let previous = owner
        let barrier = try next(nil)
        await vault.bind(barrier)
        var failures: [String] = []
        // All hooks run even when an earlier hook fails, so one disk failure cannot
        // prevent cancellation, index redaction, or system-control detachment.
        for participant in participants {
            do { try await participant.detach(previous: previous, barrier: barrier) }
            catch { failures.append(participant.participantID) }
        }
        guard failures.isEmpty else { throw LifecycleError.cleanupFailed(failures) }
    }
    public func switchIdentity(to account: AccountContext) async throws {
        try lock(); defer { busy = false }
        var identity = directory.identities[try index(account)]
        guard identity.state != .signedOut else { throw LifecycleError.signedOut }
        guard identity.state != .removalPending else { throw LifecycleError.removalPending }
        try await detach()
        let target = try next(account)
        do {
            await vault.bind(target)
            // An expired service session may retain local state, but a missing
            // local key must lock it, including after an interrupted sign-out.
            guard let reference = identity.account.credential else { throw LifecycleError.signedOut }
            do { _ = try await vault.read(reference, context: target) }
            catch LifecycleError.keychain(let status) where KeychainInteraction.requiresInteraction(status) {
                // The record exists but macOS would only release it after a Keychain
                // prompt (typically: the app's signature changed since it was written).
                // No prompt is shown; the identity becomes "Session expired — sign in
                // again" with every local file kept, and signing in writes a new record.
                var updated = directory; let i = try index(account)
                updated.identities[i].state = .expired
                if persistsPromptExpiry { try await store.save(updated); directory = updated; promptExpired.remove(account) }
                else { promptExpired.insert(account) }   // this run only: the stored roster keeps its state
                identity = updated.identities[i]
            }
            if identity.state == .connected { promptExpired.remove(account) }
            for participant in participants { try await participant.restorePaused(identity, context: target) }
        } catch {
            // Invalidate every participant that may have partially restored target.
            try await detach()
            if let local = error as? LifecycleError, local == .signedOut || local == .keychain(errSecItemNotFound) {
                var updated = directory; updated.identities[try index(account)].state = .signedOut
                directory = updated; try await store.save(updated)
                throw DomainError.unauthorized
            }
            throw error
        }
    }
    public func rename(_ account: AccountContext, label: String) async throws {
        try lock(); defer { busy = false }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DomainError.invalidInput(.emptyIdentifier) }
        var updated = directory; let i = try index(account); let old = updated.identities[i].account
        updated.identities[i].account = try Account(id: old.id, serviceIdentity: old.serviceIdentity, context: old.context, displayName: label, credential: old.credential)
        try await commit(updated)
    }
    public func setDefault(_ account: AccountContext) async throws {
        try lock(); defer { busy = false }
        let i = try index(account)
        guard directory.identities[i].state != .removalPending else { throw LifecycleError.removalPending }
        var updated = directory; updated.defaultIdentity = account; try await commit(updated)
    }
    public func expire(context: RequestContext) async throws {
        guard accepts(context), let account = context.account else { throw DomainError.staleContext }
        try lock(); defer { busy = false }
        // Keep all durable queue/navigation/outbox data; require an explicit reconnect.
        var updated = directory; updated.identities[try index(account)].state = .expired
        directory = updated
        var failures: [String] = []
        do { try await store.save(updated) } catch { failures.append("directory") }
        do { try await detach() } catch { failures.append("detach") }
        guard failures.isEmpty else { throw LifecycleError.cleanupFailed(failures) }
        let target = try next(account)
        do {
            await vault.bind(target)
            for participant in participants { try await participant.restorePaused(updated.identities[try index(account)], context: target) }
        } catch { try await detach(); throw error }
    }
    /// No implicit browser launch. A single outstanding attempt can be invoked by UI.
    public func beginAuthentication(for account: AccountContext? = nil) throws -> AuthenticationChallenge {
        guard !busy, challenge == nil else { throw LifecycleError.busy }
        if let account {
            let i = try index(account)
            guard directory.identities[i].state != .removalPending else { throw LifecycleError.removalPending }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LifecycleError.invalidCallback }
        let created = AuthenticationChallenge(state: Data(bytes).base64EncodedString(), generation: owner.accountGeneration, identity: account)
        challenge = created; return created
    }
    public func cancelAuthentication() { challenge = nil }
    public func cancelAuthentication(_ expected: AuthenticationChallenge) {
        if challenge == expected { challenge = nil }
    }
    public func isAuthenticationCurrent(_ value: AuthenticationChallenge) -> Bool {
        !busy && challenge == value && owner.accountGeneration == value.generation
    }
    public func isGenerationCurrent(_ generation: UInt64) -> Bool {
        !busy && owner.accountGeneration == generation
    }
    /// Adapter calls only after its verified callback/PKCE/session bridge. Identity is
    /// bound here, with one-use state plus generation; provider secrets have no UI model.
    public func completeAuthentication(_ callback: AuthenticationChallenge, account: Account, secret: Data) async throws {
        guard !busy, challenge == callback, callback.generation == owner.accountGeneration,
              callback.identity == nil || callback.identity == account.context else { throw LifecycleError.invalidCallback }
        challenge = nil
        try lock(); defer { busy = false }
        if let existing = directory.identities.first(where: { $0.id == account.context }) {
            guard existing.state != .removalPending else { throw LifecycleError.removalPending }
            guard existing.account.serviceIdentity == account.serviceIdentity else { throw LifecycleError.invalidCallback }
        }
        if owner.account == account.context { try await detach() }
        let previousDirectory = directory
        let previousReference = directory.identities.first(where: { $0.id == account.context })?.account.credential
        // L1: the NEW record is written first (no Keychain UI) and published, and only then
        // is the old one deleted, so a failed write or commit can never lose a working
        // session. If the old record cannot be deleted (macOS asked and the user refused),
        // the new record and entry are withdrawn and the identity returns to what it was.
        let reference = try await vault.insert(secret, for: account.context)
        let connected = try Account(id: account.id, serviceIdentity: account.serviceIdentity, context: account.context, displayName: account.displayName, credential: reference)
        var updated = directory
        if let i = updated.identities.firstIndex(where: { $0.id == account.context }) {
            // Reconnect preserves the user's local label.
            let old = updated.identities[i].account
            updated.identities[i] = .init(account: try Account(id: connected.id, serviceIdentity: connected.serviceIdentity, context: connected.context, displayName: old.displayName, credential: reference))
        } else { updated.identities.append(.init(account: connected)) }
        if updated.defaultIdentity == nil { updated.defaultIdentity = account.context }
        do { try await commit(updated) }
        catch {
            // The new reference has not been published; remove only that record.
            // Exact-reference cleanup is supplied by SessionVault below.
            try await vault.delete(reference, for: account.context)
            throw error
        }
        promptExpired.remove(account.context)
        guard let previousReference else { return }
        // The old reference is recorded BEFORE macOS may ask, so a quit during the prompt leaves a
        // marker the next launch settles instead of a record nothing points at.
        try? await staleLedger.add(account: account.context.accountID, reference: previousReference)
        do {
            try await vault.delete(previousReference, for: account.context, allowingInteraction: true)
            try? await staleLedger.remove(reference: previousReference)
        } catch {
            var failures = ["previous-credential"]
            do {
                try await commit(previousDirectory)
                // The roster points at the old record again, so it is no longer stale; the new one is.
                try? await staleLedger.remove(reference: previousReference)
                do { try await vault.delete(reference, for: account.context) }
                catch { failures.append("new-credential"); try? await staleLedger.add(account: account.context.accountID, reference: reference) }
            } catch {
                // The roster could not be rolled back, so it (durably and in memory) still points at the NEW
                // record: keep it, a working session. The old record stays in the ledger for deferred deletion.
                failures.append("directory")
            }
            throw LifecycleError.cleanupFailed(failures)
        }
        await settleStaleCredentials(allowingInteraction: true, account: account.context)
    }
    public func signOut(_ account: AccountContext) async throws {
        try lock(); defer { busy = false }
        _ = try index(account)
        var failures: [String] = []
        do { try await detach() } catch { failures.append("detach") }
        promptExpired.remove(account)
        var updated = directory; let i = try index(account); let old = updated.identities[i].account
        // QL2: the identity is signed out at once (nothing can use it), but its credential
        // reference stays recorded until the records are really erased. A quit during the
        // Keychain prompt then leaves a durable "erase pending" marker that launch retries,
        // instead of records no reference points to.
        updated.identities[i].state = .signedOut
        // Fail closed in memory even when storage fails. Always attempt key deletion.
        directory = updated
        do { try await store.save(updated) } catch { failures.append("directory") }
        var erased = false
        do { try await vault.deleteAll(for: account, allowingInteraction: true); erased = true } catch { failures.append("keychain") }
        if erased {
            await forgetStaleCredentials(of: account)
            updated.identities[i].account = try Account(id: old.id, serviceIdentity: old.serviceIdentity, context: old.context, displayName: old.displayName, credential: nil)
            directory = updated
            do { try await store.save(updated) } catch { if !failures.contains("directory") { failures.append("directory") } }
        }
        guard failures.isEmpty else { throw LifecycleError.cleanupFailed(failures) }
    }
    // N2: Keychain UI is off app-wide, but an explicit user action (Sign Out, Remove Local
    // Data, Sign In Again) may need macOS to ask before deleting a record an earlier,
    // differently-signed build wrote. Prompts are allowed for that one deletion call only
    // (`allowingInteraction:`, L2); a refused or failed deletion is never dropped: it
    // surfaces as the existing cleanup-failed state.

    public func remove(_ account: AccountContext) async throws {
        try lock(); defer { busy = false }
        _ = try index(account)
        // Tombstone survives restart and denies reactivation until every hook succeeds.
        var updated = directory; updated.identities[try index(account)].state = .removalPending
        directory = updated
        var failures: [String] = []
        do { try await store.save(updated) } catch { failures.append("directory") }
        do { try await detach() } catch { failures.append("detach") }
        do { try await vault.deleteAll(for: account, allowingInteraction: true); await forgetStaleCredentials(of: account) } catch { failures.append("keychain") }
        // Detachment has already published one authoritative maintenance barrier
        // to the vault and every participant. Reuse it for all cleanup; advancing
        // per hook would leave earlier participants behind the published owner.
        let context = owner
        for participant in participants {
            do { try await participant.removeLocal(account, context: context) }
            catch { failures.append(participant.participantID) }
        }
        await vault.bind(owner)
        if !failures.isEmpty {
            // A successful SQLite cleanup can erase its identity row before a later
            // hook fails. Repersist the public tombstone at the same barrier so the
            // remaining cleanup is still discoverable after reopening the roster.
            do { try await store.save(directory) } catch { failures.append("directory-tombstone") }
            throw LifecycleError.cleanupFailed(failures)
        }
        updated = directory; updated.identities.removeAll { $0.id == account }
        if updated.defaultIdentity == account { updated.defaultIdentity = updated.identities.first(where: { $0.state != .removalPending })?.id }
        try await commit(updated)
    }
}

/// References of credential records that no roster entry points at but that still exist (REWORK 1,
/// item 7): the old record whose prompted deletion was refused while the roster could not be rolled
/// back, or interrupted by a quit during the prompt. References only, never secrets. Retried at launch
/// with the Keychain UI off, and again at the next explicit Sign In Again.
public protocol StaleCredentialLedger: Sendable {
    func add(account: UUID, reference: CredentialReference) async throws
    func remove(reference: CredentialReference) async throws
    func pending() async throws -> [(account: UUID, reference: CredentialReference)]
}
public actor MemoryStaleCredentialLedger: StaleCredentialLedger {
    private var entries: [(account: UUID, reference: CredentialReference)] = []
    public init() {}
    public func add(account: UUID, reference: CredentialReference) { if !entries.contains(where: { $0.reference == reference }) { entries.append((account, reference)) } }
    public func remove(reference: CredentialReference) { entries.removeAll { $0.reference == reference } }
    public func pending() -> [(account: UUID, reference: CredentialReference)] { entries }
}
/// Owner-only (0600 file in a 0700 directory) JSON array of `{account, reference}` UUID strings.
public actor FileStaleCredentialLedger: StaleCredentialLedger {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func add(account: UUID, reference: CredentialReference) throws {
        var all = try read()
        if !all.contains(where: { $0.reference == reference }) { all.append((account, reference)) }
        try write(all)
    }
    public func remove(reference: CredentialReference) throws { try write(read().filter { $0.reference != reference }) }
    public func pending() throws -> [(account: UUID, reference: CredentialReference)] { try read() }
    private func read() throws -> [(account: UUID, reference: CredentialReference)] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LifecycleError.invalidDirectory }
        let data = try Data(contentsOf: url)
        guard data.count <= 65_536, let rows = try JSONSerialization.jsonObject(with: data) as? [[String: String]] else { throw LifecycleError.invalidDirectory }
        return rows.compactMap { row in
            guard let account = row["account"].flatMap(UUID.init(uuidString:)), let raw = row["reference"], UUID(uuidString: raw) != nil,
                  let reference = try? CredentialReference(raw) else { return nil }
            return (account, reference)
        }
    }
    private func write(_ rows: [(account: UUID, reference: CredentialReference)]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: rows.map { ["account": $0.account.uuidString, "reference": $0.reference.rawValue] })
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
