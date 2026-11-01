import Foundation
import Security
import Testing
import Domain
@testable import AccountSession

/// K1b: no Keychain call may raise UI; a record macOS would only release after a
/// prompt surfaces as "Session expired — sign in again", with local data kept.
private actor PromptingVault: SessionVault {
    var records: [String: Data] = [:]
    var active: RequestContext?
    var promptOnRead = false
    var promptOnDelete = false
    /// Whether the (simulated) user approves macOS's prompt when one may be shown.
    var userApproves = true
    var deletes = 0
    var interactive = false
    /// Interaction state observed at every read and delete.
    var log: [String] = []
    /// Records that exist when prompting is switched on were written by an earlier signature and need
    /// a prompt to delete; a record this build writes afterwards (the new session) deletes without one.
    var legacy: Set<String> = []
    func prompting(read: Bool, delete: Bool) { promptOnRead = read; promptOnDelete = delete; legacy = Set(records.keys) }
    func approve(_ value: Bool) { userApproves = value }
    func setUserInitiatedInteraction(_ allowed: Bool) async { interactive = allowed; log.append(allowed ? "allow" : "restore") }
    func events() -> [String] { log }
    func isInteractive() -> Bool { interactive }
    func bind(_ context: RequestContext) {
        if let active, context.accountGeneration < active.accountGeneration { return }
        active = context
    }
    func insert(_ bytes: Data, for account: AccountContext) throws -> CredentialReference {
        let reference = try CredentialReference(UUID().uuidString); records[reference.rawValue] = bytes; return reference
    }
    func read(_ reference: CredentialReference, context: RequestContext) throws -> Data {
        guard active == context else { throw DomainError.staleContext }
        log.append(interactive ? "read+ui" : "read")
        if promptOnRead { throw LifecycleError.keychain(errSecInteractionNotAllowed) }
        guard let bytes = records[reference.rawValue] else { throw LifecycleError.keychain(errSecItemNotFound) }
        return bytes
    }
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) throws { records[reference.rawValue] = bytes }
    /// A record an earlier signature wrote can be deleted only if macOS may ask and the user approves.
    private func permitDelete(_ reference: String? = nil) throws {
        log.append(interactive ? "delete+ui" : "delete")
        guard promptOnDelete, reference.map(legacy.contains) ?? !legacy.isEmpty else { return }
        guard interactive else { throw LifecycleError.keychain(errSecInteractionNotAllowed) }
        guard userApproves else { throw LifecycleError.keychain(errSecUserCanceled) }
    }
    func delete(_ reference: CredentialReference, for account: AccountContext) throws {
        try permitDelete(reference.rawValue); deletes += 1; records[reference.rawValue] = nil
    }
    func deleteAll(for account: AccountContext) throws { try permitDelete(); records = [:] }
    func count() -> Int { records.count }
}
private actor RestoreLog: AccountLifecycleParticipant {
    nonisolated let participantID = "restore-log"
    var restored: [LocalSessionState] = []
    func detach(previous: RequestContext, barrier: RequestContext) {}
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) { restored.append(identity.state) }
    func removeLocal(_ account: AccountContext, context: RequestContext) {}
    func states() -> [LocalSessionState] { restored }
}

@Suite(.serialized) struct KeychainNoPromptTests {
    @Test func everyVaultQueryRefusesAuthenticationUIAndUsesTheFileKeychainExplicitly() throws {
        let base = KeychainVault.baseAttributes(service: "local.native-music.development.sessions:synthetic", testKeychain: nil)
        #expect(base[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
        #expect(base[kSecUseDataProtectionKeychain as String] as? Bool == false && base[kSecAttrSynchronizable as String] as? Bool == false)
        let read = KeychainVault.readAttributes(service: "local.native-music.development.sessions:synthetic",
                                                reference: try CredentialReference(UUID().uuidString), testKeychain: nil)
        #expect(read[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String, "the launch restore read")
        #expect(read[kSecReturnData as String] as? Bool == true && read[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(KeychainInteraction.noUI[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
    }
    @Test func constructingTheProductionVaultDisablesLegacyKeychainUIForTheProcess() throws {
        // Constructing touches no item; it only switches off the file keychain's ACL prompt.
        _ = try KeychainVault()
        #expect(!KeychainInteraction.userInteractionAllowed)
        #expect(KeychainInteraction.requiresInteraction(errSecInteractionNotAllowed) && KeychainInteraction.requiresInteraction(errSecAuthFailed))
        #expect(!KeychainInteraction.requiresInteraction(errSecItemNotFound), "a missing record still means signed out, not expired")
    }
    @Test func aRecordThatWouldNeedAPromptAtLaunchBecomesSignInAgainWithDataKept() async throws {
        let vault = PromptingVault(), log = RestoreLog()
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: MemoryDirectory(), participants: [log])
        let account = try identity("prompt-channel")
        try await connect(lifecycle, account)
        await vault.prompting(read: true, delete: false)
        try await lifecycle.switchIdentity(to: account.context)
        let snapshot = await lifecycle.snapshot()
        #expect(snapshot.context.account == account.context, "the identity is still restored (paused) as the active owner")
        #expect(snapshot.directory.identities.first?.state == .expired, "shown as Session expired — sign in again")
        #expect(await log.states() == [.expired], "participants see the expired identity, so no player is offered")
        #expect(await vault.count() == 1, "nothing is deleted")
    }
    @Test func aMissingRecordStillSignsOut() async throws {
        let vault = PromptingVault()
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: MemoryDirectory(), participants: [])
        let account = try identity("missing-channel")
        try await connect(lifecycle, account)
        try await vault.deleteAll(for: account.context)
        await #expect(throws: DomainError.unauthorized) { try await lifecycle.switchIdentity(to: account.context) }
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .signedOut)
    }
    // N2: explicit user actions may let macOS ask; a refusal is surfaced, never dropped.
    private func expiredAfterSignatureChange() async throws -> (AccountLifecycle, PromptingVault, Account) {
        let vault = PromptingVault()
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: MemoryDirectory(), participants: [])
        let account = try identity("older-signature")
        try await connect(lifecycle, account)
        await vault.prompting(read: true, delete: true)
        try await lifecycle.switchIdentity(to: account.context)
        await vault.prompting(read: false, delete: true)
        return (lifecycle, vault, account)
    }
    @Test func launchReadsNeverRunWithInteractionAllowed() async throws {
        let (_, vault, _) = try await expiredAfterSignatureChange()
        #expect(await vault.events() == ["read"], "the launch restore read ran with Keychain UI off")
        #expect(await !vault.isInteractive())
    }
    @Test func signInAgainWritesTheNewRecordThenDeletesTheOldOneWithMacOSAllowedToAsk() async throws {
        let (lifecycle, vault, account) = try await expiredAfterSignatureChange()
        let challenge = try await lifecycle.beginAuthentication(for: account.context)
        try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("synthetic-new-session".utf8))
        #expect(await vault.count() == 1, "the old record is gone: no orphaned session record")
        #expect(Array(await vault.events().suffix(3)) == ["allow", "delete+ui", "restore"])
        #expect(await !vault.isInteractive())
        try await lifecycle.switchIdentity(to: account.context)
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .connected)
    }
    @Test func aRefusedSignInAgainRollsBackToTheOldRecordAndCanBeRetried() async throws {
        let (lifecycle, vault, account) = try await expiredAfterSignatureChange()
        await vault.approve(false)
        let challenge = try await lifecycle.beginAuthentication(for: account.context)
        await #expect(throws: LifecycleError.cleanupFailed(["previous-credential"])) {
            try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("synthetic-new-session".utf8))
        }
        #expect(await vault.count() == 1, "the new record was withdrawn: none beside the undeletable old one")
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .expired, "still Sign In Again")
        #expect(await !vault.isInteractive(), "interaction restored after a failure too")
        await vault.approve(true)
        let retry = try await lifecycle.beginAuthentication(for: account.context)
        try await lifecycle.completeAuthentication(retry, account: account, secret: Data("synthetic-new-session".utf8))
        #expect(await vault.count() == 1)
    }
    @Test func aRefusedSignOutDeletionSurfacesCleanupAndRemoveRetriesIt() async throws {
        let (lifecycle, vault, account) = try await expiredAfterSignatureChange()
        await vault.approve(false)
        await #expect(throws: LifecycleError.cleanupFailed(["keychain"])) { try await lifecycle.signOut(account.context) }
        #expect(await vault.count() == 1, "the failure is reported, not dropped")
        #expect(await !vault.isInteractive())
        await vault.approve(true)
        try await lifecycle.remove(account.context)
        let remaining = await lifecycle.snapshot().directory.identities
        #expect(await vault.count() == 0 && remaining.isEmpty)
        #expect(await vault.events().filter { $0.hasPrefix("delete") }.allSatisfy { $0 == "delete+ui" }, "every user-initiated deletion may prompt")
    }
    @Test func aRefusedRemovalStaysPendingUntilRetried() async throws {
        let (lifecycle, vault, account) = try await expiredAfterSignatureChange()
        await vault.approve(false)
        await #expect(throws: LifecycleError.self) { try await lifecycle.remove(account.context) }
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .removalPending)
        await vault.approve(true)
        try await lifecycle.remove(account.context)
        #expect(await vault.count() == 0)
    }
    @Test func interactionIsToggledOnlyAtTheAttributeAndProcessLevelsAskedFor() async throws {
        let base = KeychainVault.baseAttributes(service: "local.native-music.development.sessions:synthetic", testKeychain: nil, interactive: true)
        #expect(base[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIAllow as String)
        let quiet = KeychainVault.baseAttributes(service: "local.native-music.development.sessions:synthetic", testKeychain: nil)
        #expect(quiet[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
        let production = try KeychainVault()
        await production.setUserInitiatedInteraction(true)
        let on = await production.isUserInitiatedInteraction()
        #expect(KeychainInteraction.userInteractionAllowed && on)
        await production.setUserInitiatedInteraction(false)
        let off = await production.isUserInitiatedInteraction()
        #expect(!KeychainInteraction.userInteractionAllowed && !off, "restored")
        let isolated = try testVault()
        await isolated.setUserInitiatedInteraction(true)
        #expect(!KeychainInteraction.userInteractionAllowed, "an isolated test keychain never flips the process switch")
        await isolated.setUserInitiatedInteraction(false)
        try await isolated.destroyIsolatedTestKeychain()
    }
}
