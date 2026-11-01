import Foundation
import Security
import Domain
import Darwin

public enum LifecycleError: Error, Equatable, Sendable {
    case busy, unknownIdentity, signedOut, removalPending, invalidCallback, generationExhausted
    case keychain(OSStatus), cleanupFailed([String]), invalidDirectory
}

/// YTMuse shows no Keychain UI at launch or for background reads/writes.
/// The one exception (N2) is an explicit user action — Sign Out, Remove Local
/// Data, Sign In Again — during which a vault may let macOS ask, so records an
/// earlier, differently-signed build wrote can actually be deleted. `kSecUseAuthenticationUIFail` covers items
/// with access control, but the file-based login keychain's ACL confirmation
/// ("YTMuse wants to use your confidential information…", raised when the
/// app's code signature changed since the item was written) is governed by the
/// legacy per-process user-interaction switch instead. Both are applied, so a
/// read the ACL would prompt for fails with `errSecInteractionNotAllowed`.
public enum KeychainInteraction {
    /// Process-wide and permanent; idempotent. Called by the production vaults.
    public static func disallowUserInteraction() {
        _ = legacySetInteraction(false)
    }
    public static var userInteractionAllowed: Bool {
        var allowed = DarwinBoolean(true)
        return legacyGetInteraction(&allowed) == errSecSuccess ? allowed.boolValue : true
    }
    /// Statuses meaning "readable only after a prompt the app refused to show".
    public static func requiresInteraction(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled
    }
    /// Attributes every vault query (copy, update, delete, add) carries.
    public static var noUI: [String: Any] { [kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail] }
    public static var allowUI: [String: Any] { [kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow] }
    /// Restores the legacy per-process switch (used only inside an explicit user action).
    public static func setUserInteractionAllowed(_ allowed: Bool) { _ = legacySetInteraction(allowed) }
}
@available(macOS, deprecated: 10.10)
private func legacySetInteraction(_ value: Bool) -> OSStatus { SecKeychainSetUserInteractionAllowed(value) }
@available(macOS, deprecated: 10.10)
private func legacyGetInteraction(_ value: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus { SecKeychainGetUserInteractionAllowed(value) }

/// Only random reference UUIDs enter metadata. Secret bytes stay at this boundary.
public protocol SessionVault: Actor {
    func bind(_ context: RequestContext) async
    func insert(_ bytes: Data, for account: AccountContext) async throws -> CredentialReference
    func read(_ reference: CredentialReference, context: RequestContext) async throws -> Data
    func delete(_ reference: CredentialReference, for account: AccountContext) async throws
    func deleteAll(for account: AccountContext) async throws
    /// Rewrites one exact existing record in place (session rotation). Requires the
    /// bound active context; never creates a record or changes its reference.
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) async throws
    /// Entered and left by the lifecycle around an explicit user action only.
    func setUserInitiatedInteraction(_ allowed: Bool) async
    /// L2: the explicit user action's one deletion, with macOS allowed to ask for this call
    /// only. Requirements (not just extension methods) so a vault's own form is dispatched.
    func delete(_ reference: CredentialReference, for account: AccountContext, allowingInteraction: Bool) async throws
    func deleteAll(for account: AccountContext, allowingInteraction: Bool) async throws
}
public extension SessionVault {
    /// Vaults with no interactive mode ignore this.
    func setUserInitiatedInteraction(_ allowed: Bool) async {}
}
public extension SessionVault {
    /// L2: an explicit user action's deletion, with macOS allowed to ask for THIS call only.
    /// The default toggles the vault's interaction mode around the call for vaults without a
    /// per-call form; `KeychainVault` implements it natively with no suspension point inside
    /// the window, so no other vault call can run with prompts allowed.
    func delete(_ reference: CredentialReference, for account: AccountContext, allowingInteraction: Bool) async throws {
        guard allowingInteraction else { try await delete(reference, for: account); return }
        await setUserInitiatedInteraction(true)
        do { try await delete(reference, for: account); await setUserInitiatedInteraction(false) }
        catch { await setUserInitiatedInteraction(false); throw error }
    }
    func deleteAll(for account: AccountContext, allowingInteraction: Bool) async throws {
        guard allowingInteraction else { try await deleteAll(for: account); return }
        await setUserInitiatedInteraction(true)
        do { try await deleteAll(for: account); await setUserInitiatedInteraction(false) }
        catch { await setUserInitiatedInteraction(false); throw error }
    }
}
// No default for `replace`: a vault that lacks it, or declares it with a
// different signature, must fail to compile rather than silently "unsupported".

public actor KeychainVault: ScopedProtectedRecords {
    public static let applicationNamespace = "local.native-music.development.sessions"
    private var metrics: [String: Int] = [:]
    public func protectedMetrics() -> [String: Int] { metrics }
    private let namespace: String
    /// W27: the Keychain service-name namespace of this vault (the destructive-action guard reads it).
    public nonisolated var serviceNamespace: String { namespace }
    private var isClosed = false
    private var testKeychain: SecKeychain?
    private var active: RequestContext?
    private var highWater: UInt64?
    /// True only inside an explicit user-initiated cleanup (see `setUserInitiatedInteraction`).
    private var interactive = false
    private var uiPolicy: CFString { interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail }
    /// Lets macOS ask for the login password during an explicit user action (N2),
    /// then restores the no-prompt default. Production vaults also flip the
    /// process-wide legacy switch; an isolated test keychain never does.
    /// Exactly `async` so this, not the protocol extension's no-op, is the witness
    /// and the overload chosen in async contexts.
    public func setUserInitiatedInteraction(_ allowed: Bool) async {
        interactive = allowed
        if testKeychain == nil { KeychainInteraction.setUserInteractionAllowed(allowed) }
    }
    public func isUserInitiatedInteraction() -> Bool { interactive }
    /// Runs one synchronous body with prompts allowed, then restores. The body contains no
    /// suspension point, so the actor cannot serve another call inside the window (L2).
    private func prompting<T>(_ allow: Bool, _ body: () throws -> T) rethrows -> T {
        guard allow else { return try body() }
        let before = interactive
        interactive = true
        if testKeychain == nil { KeychainInteraction.setUserInteractionAllowed(true) }
        defer { interactive = before; if testKeychain == nil { KeychainInteraction.setUserInteractionAllowed(before) } }
        return try body()
    }
    public func delete(_ reference: CredentialReference, for account: AccountContext, allowingInteraction: Bool) throws {
        try prompting(allowingInteraction) { try delete(reference, for: account) }
    }
    public func deleteAll(for account: AccountContext, allowingInteraction: Bool) throws {
        try prompting(allowingInteraction) { try deleteAll(for: account) }
    }
    /// Test callers must supply a unique app-owned suffix. No broad Keychain queries.
    public init(namespace: String = applicationNamespace) throws {
        guard namespace == Self.applicationNamespace || namespace.hasPrefix(Self.applicationNamespace + ".test.") else {
            throw LifecycleError.invalidDirectory
        }
        self.namespace = namespace
        KeychainInteraction.disallowUserInteraction()
    }
    /// Isolated legacy Keychain for unsigned native test runners. Production uses the standard macOS Keychain. No search ever includes the login Keychain.
    public init(testNamespace: String, isolatedKeychainURL: URL) throws {
        guard testNamespace.hasPrefix(Self.applicationNamespace + ".test."),
              !FileManager.default.fileExists(atPath: isolatedKeychainURL.path) else { throw LifecycleError.invalidDirectory }
        namespace = testNamespace
        var keychain: SecKeychain?
        let password = UUID().uuidString
        let status = password.withCString { pointer in
            SecKeychainCreate(isolatedKeychainURL.path, UInt32(password.utf8.count), pointer, false, nil, &keychain)
        }
        guard status == errSecSuccess, let keychain else { throw LifecycleError.keychain(status) }
        testKeychain = keychain
    }
    public func destroyIsolatedTestKeychain() throws {
        guard let testKeychain else { return }
        let status = SecKeychainDelete(testKeychain)
        guard status == errSecSuccess else { throw LifecycleError.keychain(status) }
        self.testKeychain = nil; isClosed = true; active = nil
    }
    public func bind(_ context: RequestContext) {
        guard !isClosed else { return }
        if let highWater {
            guard context.accountGeneration >= highWater else { return }
            if context.accountGeneration == highWater, context.account != active?.account { return }
        }
        highWater = context.accountGeneration; active = context
    }
    private func service(_ account: AccountContext) -> String {
        // Length framing isolates arbitrary channel identifiers, region and local UUID.
        namespace + ":" + account.accountID.uuidString + ":\(account.channelID.rawValue.utf8.count):" + account.channelID.rawValue + ":" + account.region
    }
    private func query(_ account: AccountContext) -> [String: Any] {
        Self.baseAttributes(service: service(account), testKeychain: testKeychain, interactive: interactive)
    }
    /// The one base every query is built from (tested at the attribute level).
    static func baseAttributes(service: String, testKeychain: SecKeychain?, interactive: Bool = false) -> [String: Any] {
        var attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
        attributes.merge(interactive ? KeychainInteraction.allowUI : KeychainInteraction.noUI) { _, new in new }
        if let testKeychain { attributes[kSecMatchSearchList as String] = [testKeychain] }
        else { attributes[kSecUseDataProtectionKeychain as String] = false }
        return attributes
    }
    /// The session-record read used at launch (switch/restore) and for every signed read.
    static func readAttributes(service: String, reference: CredentialReference, testKeychain: SecKeychain?) -> [String: Any] {
        var attributes = baseAttributes(service: service, testKeychain: testKeychain)
        attributes[kSecAttrAccount as String] = reference.rawValue
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        return attributes
    }
    public func insert(_ bytes: Data, for account: AccountContext) throws -> CredentialReference {
        guard !isClosed, !bytes.isEmpty else { throw DomainError.unauthorized }
        let reference = try CredentialReference(UUID().uuidString)
        var attributes = query(account)
        attributes[kSecAttrAccount as String] = reference.rawValue
        if let testKeychain {
            attributes.removeValue(forKey: kSecMatchSearchList as String)
            attributes[kSecUseKeychain as String] = testKeychain
        }
        attributes[kSecValueData as String] = bytes
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw LifecycleError.keychain(status) }
        if let current=try epoch(account) {
            let q=try protectedQuery(authorizationEpochName,account);let value=Data(current.uuidString.utf8)
            let update=GuardedKeychain.update(q as CFDictionary,[kSecValueData as String:value] as CFDictionary)
            let granted=update==errSecItemNotFound ? protectedAdd(value,query:q) : update
            if granted != errSecSuccess {
                var cleanup=query(account);cleanup[kSecAttrAccount as String]=reference.rawValue
                let removed=GuardedKeychain.delete(cleanup as CFDictionary)
                guard removed==errSecSuccess || removed==errSecItemNotFound else{throw LifecycleError.cleanupFailed(["unpublished-credential"])}
                throw LifecycleError.keychain(granted)
            }
        }
        return reference
    }
    public func read(_ reference: CredentialReference, context: RequestContext) throws -> Data {
        guard let active, active.account == context.account, active.accountGeneration == context.accountGeneration,
              let account = context.account else { throw DomainError.staleContext }
        guard !isClosed, UUID(uuidString: reference.rawValue) != nil else { throw DomainError.unauthorized }
        let attributes = Self.readAttributes(service: service(account), reference: reference, testKeychain: testKeychain)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let bytes = result as? Data else { throw LifecycleError.keychain(status) }
        return bytes
    }
    /// Exactly `async throws` so this, not the protocol default, is the witness.
    public func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) async throws {
        guard let active, active.account == context.account, active.accountGeneration == context.accountGeneration,
              let account = context.account else { throw DomainError.staleContext }
        guard !isClosed, !bytes.isEmpty, UUID(uuidString: reference.rawValue) != nil else { throw DomainError.unauthorized }
        var attributes = query(account)
        attributes[kSecAttrAccount as String] = reference.rawValue
        // Same convention as read: a rotation write never raises a Keychain prompt.
        attributes[kSecUseAuthenticationUI as String] = uiPolicy
        let status = GuardedKeychain.update(attributes as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        guard status == errSecSuccess else { throw LifecycleError.keychain(status) }
    }
    public func delete(_ reference: CredentialReference, for account: AccountContext) throws {
        guard !isClosed, UUID(uuidString: reference.rawValue) != nil else { throw DomainError.unauthorized }
        var attributes = query(account); attributes[kSecAttrAccount as String] = reference.rawValue
        let status = GuardedKeychain.delete(attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LifecycleError.keychain(status) }
    }
    private struct ProtectedOwner: Codable {
        let pid: Int32; let token: UUID
        var incarnation: String? = nil
    }
    private let protectedLockName = "protected.lock.v2"
    private let accountEpochName = "account.erasure-epoch.v3"
    private let authorizationEpochName = "account.authorization.v3"
    public nonisolated static func processIncarnation(_ pid: Int32) -> String? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        var size=0
        guard sysctlbyname("kern.bootsessionuuid",nil,&size,nil,0)==0,size>0 else{return nil}
        var boot=[CChar](repeating:0,count:size)
        guard sysctlbyname("kern.bootsessionuuid",&boot,&size,nil,0)==0 else{return nil}
        return String(cString:boot)+":\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }
    private func epoch(_ account: AccountContext) throws -> UUID? {
        guard let bytes=try protectedRead(protectedQuery(accountEpochName,account)) else{return nil}
        guard let id=UUID(uuidString:String(decoding:bytes,as:UTF8.self)) else{throw DomainError.unauthorized}
        return id
    }
    private func requireCurrentEpoch(_ lease: ProtectedRecordLease) throws {
        guard try epoch(lease.account)==lease.epoch else{throw DomainError.staleContext}
    }
    private func recordQuery(_ name:String,_ lease:ProtectedRecordLease)throws->[String:Any]{
        var q=try protectedQuery(name,lease.account)
        if let epoch=lease.epoch{q[kSecAttrComment as String]=epoch.uuidString}
        return q
    }
    private func eraseRecords(_ account: AccountContext, credentialsOnly: Bool) throws {
        var q=query(account);q[kSecReturnAttributes as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitAll
        q[kSecUseAuthenticationUI as String]=uiPolicy
        var result:CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound{return}
        guard status==errSecSuccess else{throw LifecycleError.keychain(status)}
        let rows=(result as? [[String:Any]]) ?? (result as? [String:Any]).map{[$0]} ?? []
        for row in rows {
            guard let name=row[kSecAttrAccount as String] as? String else{throw DomainError.unauthorized}
            if credentialsOnly && UUID(uuidString:name)==nil{continue}
            if name=="protected.record.v2:"+protectedLockName || name=="protected.record.v2:"+accountEpochName{continue}
            var exact=query(account);exact[kSecAttrAccount as String]=name
            let removed=GuardedKeychain.delete(exact as CFDictionary)
            guard removed==errSecSuccess || removed==errSecItemNotFound else{throw LifecycleError.keychain(removed)}
        }
    }
    private func fenceErasure(_ account:AccountContext)throws{
        let q=try protectedQuery(accountEpochName,account)
        let value=Data(UUID().uuidString.utf8)
        let update=GuardedKeychain.update(q as CFDictionary,[kSecValueData as String:value] as CFDictionary)
        let status=update==errSecItemNotFound ? protectedAdd(value,query:q) : update
        guard status==errSecSuccess else{throw LifecycleError.keychain(status)}
    }
    private func protectedQuery(_ name: String, _ account: AccountContext) throws -> [String: Any] {
        guard !isClosed, !name.isEmpty, name.utf8.count <= 128,
              name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }) else { throw DomainError.forbidden }
        var q = query(account)
        // UUID session references cannot address these records or their key material.
        q[kSecAttrAccount as String] = "protected.record.v2:" + name
        return q
    }
    private func protectedRead(_ q: [String: Any]) throws -> Data? {
        var q = q
        q[kSecUseAuthenticationUI as String] = uiPolicy
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        metrics["copyCalls", default: 0] += 1
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw LifecycleError.keychain(status) }
        return bytes
    }
    private func protectedAdd(_ bytes: Data, query q: [String: Any], generic: Data? = nil) -> OSStatus {
        var q = q
        if let testKeychain {
            q.removeValue(forKey: kSecMatchSearchList as String); q[kSecUseKeychain as String] = testKeychain
        }
        q[kSecValueData as String] = bytes
        if let generic { q[kSecAttrGeneric as String] = generic }
        return SecItemAdd(q as CFDictionary, nil)
    }
    private func claimProtectedLease(_ account: AccountContext) throws -> ProtectedRecordLease? {
        let q = try protectedQuery(protectedLockName, account)
        guard let identity=Self.processIncarnation(getpid()) else{throw DomainError.unauthorized}
        let owner = ProtectedOwner(pid: getpid(), token: UUID(), incarnation: identity)
        let bytes = try JSONEncoder().encode(owner)
        func add() -> OSStatus { metrics["leaseAddCalls",default:0] += 1; return protectedAdd(bytes, query: q, generic: Data(owner.token.uuidString.utf8)) }
        var status = add()
        if status == errSecDuplicateItem {
            // A live (including reused PID) owner is never displaced. A crashed owner's
            // exact token is conditionally deleted; a concurrent replacement cannot be erased.
            if let data = try protectedRead(q), let old = try? JSONDecoder().decode(ProtectedOwner.self, from: data),
               (old.incarnation != nil && Self.processIncarnation(old.pid).map{$0 != old.incarnation!} == true || kill(old.pid,0) == -1 && errno == ESRCH) {
                var stale = q; stale[kSecAttrGeneric as String] = Data(old.token.uuidString.utf8)
                let removed = GuardedKeychain.delete(stale as CFDictionary)
                guard removed == errSecSuccess || removed == errSecItemNotFound else { throw LifecycleError.keychain(removed) }
                status = add()
            }
        }
        if status == errSecDuplicateItem { return nil }
        guard status == errSecSuccess else { throw LifecycleError.keychain(status) }
        return ProtectedRecordLease(account: account, token: owner.token, epoch: try epoch(account))
    }
    private func checkProtectedContext(_ context: RequestContext) throws -> AccountContext {
        guard !isClosed, let account = context.account, active?.account == account,
              active?.accountGeneration == context.accountGeneration else { throw DomainError.staleContext }
        return account
    }
    public func acquireProtectedLease(context: RequestContext) throws -> ProtectedRecordLease? {
        metrics["leaseAttempts", default: 0] += 1
        let account=try checkProtectedContext(context)
        if let current=try epoch(account) {
            let authorized=try protectedRead(protectedQuery(authorizationEpochName,account))
            guard authorized==Data(current.uuidString.utf8) else{throw DomainError.unauthorized}
        }
        return try claimProtectedLease(account)
    }
    public func releaseProtectedLease(_ lease: ProtectedRecordLease) throws {
        metrics["leaseReleases", default: 0] += 1
        // Cleanup is allowed after detach; the exact unguessable token confers no read/write rights.
        var q = try protectedQuery(protectedLockName, lease.account)
        q[kSecAttrGeneric as String] = Data(lease.token.uuidString.utf8)
        metrics["leaseDeleteCalls",default:0] += 1
        let status = GuardedKeychain.delete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LifecycleError.keychain(status) }
    }
    private func requireProtectedLease(_ lease: ProtectedRecordLease, _ context: RequestContext) throws {
        guard try checkProtectedContext(context) == lease.account,
              let data = try protectedRead(protectedQuery(protectedLockName, lease.account)),
              try JSONDecoder().decode(ProtectedOwner.self, from: data).token == lease.token else { throw DomainError.staleContext }
        try requireCurrentEpoch(lease)
    }
    public func protectedRecordStamp(_ name: String, lease: ProtectedRecordLease, context: RequestContext) async throws -> ProtectedRecordStamp? {
        try requireProtectedLease(lease, context)
        guard name != protectedLockName, name != accountEpochName, name != authorizationEpochName else { throw DomainError.forbidden }
        var q = try recordQuery(name,lease)
        q[kSecUseAuthenticationUI as String] = uiPolicy
        q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        metrics["copyCalls", default: 0] += 1; metrics["stampReads", default: 0] += 1
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = result as? [String: Any] else { throw LifecycleError.keychain(status) }
        return ProtectedRecordStamp(version: attributes[kSecAttrGeneric as String] as? Data)
    }
    public func protectedRecord(_ name: String, lease: ProtectedRecordLease, context: RequestContext) throws -> Data? {
        try requireProtectedLease(lease, context)
        guard name != protectedLockName, name != accountEpochName, name != authorizationEpochName else { throw DomainError.forbidden }
        metrics[name == "offline.master.v2" ? "masterRetrievals" : "recordReads", default: 0] += 1
        let value=try protectedRead(recordQuery(name,lease));try requireCurrentEpoch(lease);return value
    }
    public func replaceProtectedRecord(_ name: String, value: Data?, lease: ProtectedRecordLease, context: RequestContext) throws {
        try requireProtectedLease(lease, context)
        guard name != protectedLockName, name != accountEpochName, name != authorizationEpochName, value.map({ $0.count <= 1_048_576 }) ?? true else { throw DomainError.forbidden }
        let q = try recordQuery(name,lease)
        metrics["recordWrites", default: 0] += 1
        let status: OSStatus
        if let value {
            let version = Data(UUID().uuidString.utf8)
            let update = GuardedKeychain.update(q as CFDictionary, [kSecValueData as String: value, kSecAttrGeneric as String: version] as CFDictionary)
            if update == errSecItemNotFound {
                var unscoped=try protectedQuery(name,lease.account)
                unscoped[kSecUseAuthenticationUI as String]=uiPolicy
                unscoped[kSecReturnAttributes as String]=true
                var found:CFTypeRef?
                let lookup=SecItemCopyMatching(unscoped as CFDictionary,&found)
                if lookup==errSecSuccess,let attrs=found as? [String:Any],attrs[kSecAttrComment as String] as? String != lease.epoch?.uuidString {
                    let exact=try protectedQuery(name,lease.account)
                    let removed=GuardedKeychain.delete(exact as CFDictionary)
                    guard removed==errSecSuccess || removed==errSecItemNotFound else{throw LifecycleError.keychain(removed)}
                    try requireCurrentEpoch(lease)
                } else if lookup != errSecSuccess && lookup != errSecItemNotFound { throw LifecycleError.keychain(lookup) }
                status=protectedAdd(value,query:q,generic:version)
            } else { status=update }
        } else { status = GuardedKeychain.delete(q as CFDictionary) }
        guard status == errSecSuccess || (value == nil && status == errSecItemNotFound) else { throw LifecycleError.keychain(status) }
        try requireCurrentEpoch(lease)
    }
    /// Reopens only an explicitly named, existing isolated test Keychain. Does not unlock or change ACLs.
    public init(testNamespace: String, reopeningIsolatedKeychainURL: URL) throws {
        guard testNamespace.hasPrefix(Self.applicationNamespace + ".test.") else { throw LifecycleError.invalidDirectory }
        namespace = testNamespace
        var value: SecKeychain?
        let status = SecKeychainOpen(reopeningIsolatedKeychainURL.path, &value)
        guard status == errSecSuccess, let value else { throw LifecycleError.keychain(status) }
        testKeychain = value
    }
    /// How long an erase waits for a lease holder that predates its barrier.
    public static let eraseLeaseWait: Duration = .seconds(2)
    public func eraseProtectedAccount(_ account: AccountContext, barrier: RequestContext, cleanup: @Sendable () throws -> Void) async throws {
        guard !isClosed, barrier.account == nil, let active,
              active.accountGeneration == barrier.accountGeneration,
              active.account == nil || active.account == account else { throw DomainError.staleContext }
        self.active = barrier; highWater = barrier.accountGeneration
        // The barrier above already stops new readers and publishers, so a holder still
        // present began before it (an in-flight read or publication) and lets go within
        // milliseconds. A single claim turned that overlap into `busy`, which is how the
        // retained-restart test failed under load (the claim in `invalidate`, after every
        // earlier step had succeeded). Wait for the holder like `EncryptedStore.withObject`
        // does, bounded; a lease that is genuinely stuck still reports `busy`.
        var claimed = try claimProtectedLease(account)
        let deadline = ContinuousClock.now.advanced(by: Self.eraseLeaseWait)
        while claimed == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            claimed = try claimProtectedLease(account)
        }
        guard !isClosed else { throw DomainError.staleContext }   // the wait suspended: the vault may have closed meanwhile
        guard let lease = claimed else { throw LifecycleError.busy }
        do {
            // Files are removed while the account gate still exists. New publishers
            // cannot recreate them between key deletion and old cleanup completion.
            try cleanup()
            try eraseRecords(account,credentialsOnly:false)
            try releaseProtectedLease(lease)
        } catch { let original=error; try releaseProtectedLease(lease); throw original }
    }
    /// Deletes session and future download keys in this exact identity namespace only.
    public func deleteAll(for account: AccountContext) throws {
        guard !isClosed else { throw DomainError.unauthorized }
        // W04 credentials are erased regardless of offline lease admission. Even
        // if fencing/private cleanup fails, an error never leaves session UUIDs readable.
        var failure: Error?
        do{try eraseRecords(account,credentialsOnly:true)}catch{failure=error}
        do{try fenceErasure(account)}catch{if failure==nil{failure=error}}
        if let failure{throw failure}
        // A genuine active writer retains exclusivity but its old epoch is invalid.
        // Private cleanup is retryable and cannot hold credential erasure hostage.
        guard let lease=try claimProtectedLease(account) else{return}
        do{try eraseRecords(account,credentialsOnly:false);try releaseProtectedLease(lease)}
        catch{let original=error;try releaseProtectedLease(lease);throw original}
    }
}
