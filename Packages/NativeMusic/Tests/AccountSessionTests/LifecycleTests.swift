import Testing
import Foundation
import Domain
import AccountSession

actor ParticipantProbe: AccountLifecycleParticipant {
    nonisolated let participantID: String
    var detachFailure = false
    var restoreFailure = false
    var removeFailure = false
    var events: [String] = []
    var active: RequestContext?
    init(_ id: String) { participantID = id }
    func failures(detach: Bool = false, restore: Bool = false, remove: Bool = false) {
        detachFailure = detach; restoreFailure = restore; removeFailure = remove
    }
    func detach(previous: RequestContext, barrier: RequestContext) throws {
        active = barrier; events.append("detach")
        if detachFailure { throw DomainError.offline }
    }
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) throws {
        active = context; events.append("restore-paused")
        if restoreFailure { throw DomainError.offline }
    }
    func removeLocal(_ account: AccountContext, context: RequestContext) throws {
        events.append("remove")
        if removeFailure { throw DomainError.offline }
    }
}

@Suite("T04 lifecycle and callbacks") struct LifecycleTests {
    @Test func unlimitedDirectoryLabelsDefaultsAndChannelIdentity() async throws {
        let vault = try testVault(); let store = MemoryDirectory()
        // A large roster exercises no application account cap without creating keys.
        let accountID = UUID()
        let accounts = try (0..<1025).map { try identity("channel-\($0)", uuid: accountID) }
        let directory = AccountDirectory(identities: accounts.map { LocalIdentity(account: $0, state: .signedOut) })
        let lifecycle = try AccountLifecycle(directory: directory, vault: vault, store: store, participants: [])
        try await lifecycle.rename(accounts[1024].context, label: "Local label")
        try await lifecycle.setDefault(accounts[1024].context)
        let saved = await store.load()
        #expect(saved.identities.count == 1025)
        #expect(saved.identities.last?.account.displayName == "Local label")
        #expect(saved.defaultIdentity == accounts[1024].context)
        await #expect(throws: LifecycleError.signedOut) { try await lifecycle.switchIdentity(to: accounts[0].context) }
        try await vault.destroyIsolatedTestKeychain()
    }
    @Test func oneUseStateGenerationCancellationAndReconnect() async throws {
        let vault = try testVault(); let store = MemoryDirectory(); let account = try identity()
        let lifecycle = try AccountLifecycle(directory: .init(), vault: vault, store: store, participants: [])
        let cancelled = try await lifecycle.beginAuthentication()
        await #expect(throws: LifecycleError.busy) { try await lifecycle.beginAuthentication() }
        await lifecycle.cancelAuthentication()
        await #expect(throws: LifecycleError.invalidCallback) { try await lifecycle.completeAuthentication(cancelled, account: account, secret: Data([1])) }
        let first = try await lifecycle.beginAuthentication()
        let wrongState = AuthenticationChallenge(state: "incorrect", generation: first.generation, identity: first.identity)
        await #expect(throws: LifecycleError.invalidCallback) { try await lifecycle.completeAuthentication(wrongState, account: account, secret: Data([1])) }
        let wrongGeneration = AuthenticationChallenge(state: first.state, generation: first.generation + 1, identity: first.identity)
        await #expect(throws: LifecycleError.invalidCallback) { try await lifecycle.completeAuthentication(wrongGeneration, account: account, secret: Data([1])) }
        try await lifecycle.completeAuthentication(first, account: account, secret: Data([1]))
        await #expect(throws: LifecycleError.invalidCallback) { try await lifecycle.completeAuthentication(first, account: account, secret: Data([1])) }
        try await lifecycle.switchIdentity(to: account.context)
        let before = await lifecycle.snapshot().context
        let obsolete = try await lifecycle.beginAuthentication(for: account.context)
        try await lifecycle.expire(context: before)
        await #expect(throws: LifecycleError.invalidCallback) { try await lifecycle.completeAuthentication(obsolete, account: account, secret: Data([1])) }
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .expired)
        let reconnect = try await lifecycle.beginAuthentication(for: account.context)
        await #expect(throws: LifecycleError.busy) { try await lifecycle.beginAuthentication(for: account.context) }
        try await lifecycle.rename(account.context, label: "Personal local label")
        try await lifecycle.completeAuthentication(reconnect, account: account, secret: Data([2]))
        #expect(await lifecycle.snapshot().directory.identities.first?.account.displayName == "Personal local label")
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .connected)
        try await lifecycle.remove(account.context)
        try await vault.destroyIsolatedTestKeychain()
    }
    @Test func wrongChannelCallbackRefusedWithoutInstallingKey() async throws {
        let vault = try testVault(); let store = MemoryDirectory(); let a = try identity(); let b = try identity("b", uuid: a.id)
        let lifecycle = try AccountLifecycle(directory: .init(identities: [.init(account: a, state: .signedOut)]), vault: vault, store: store, participants: [])
        let challenge = try await lifecycle.beginAuthentication(for: a.context)
        await #expect(throws: LifecycleError.invalidCallback) { try await lifecycle.completeAuthentication(challenge, account: b, secret: Data([3])) }
        #expect(await lifecycle.snapshot().directory.identities.count == 1)
        await lifecycle.cancelAuthentication(); try await vault.destroyIsolatedTestKeychain()
    }
    @Test func partialRestoreDetachesEveryParticipantAndNeverRollsBack() async throws {
        let vault = try testVault(); let store = MemoryDirectory(); let a = try identity(); let b = try identity("b")
        let first = ParticipantProbe("first"); let last = ParticipantProbe("last")
        let lifecycle = try AccountLifecycle(directory: .init(), vault: vault, store: store, participants: [first, last])
        try await connect(lifecycle, a); try await connect(lifecycle, b)
        try await lifecycle.switchIdentity(to: a.context)
        let old = await lifecycle.snapshot().context
        await last.failures(restore: true)
        await #expect(throws: DomainError.offline) { try await lifecycle.switchIdentity(to: b.context) }
        let failed = await lifecycle.snapshot()
        #expect(failed.context.account == nil)
        #expect(failed.context.accountGeneration > old.accountGeneration)
        #expect(await first.active?.account == nil)
        #expect(await last.active?.account == nil)
        #expect(await lifecycle.accepts(old) == false)
        await last.failures()
        try await lifecycle.switchIdentity(to: a.context)
        #expect(await lifecycle.snapshot().context.accountGeneration > failed.context.accountGeneration)
        try await lifecycle.remove(a.context); try await lifecycle.remove(b.context)
        try await vault.destroyIsolatedTestKeychain()
    }
    @Test func removalFailuresRetainTombstoneAndRunAllHooksThenRetry() async throws {
        let vault = try testVault(); let store = MemoryDirectory(); let account = try identity()
        let first = ParticipantProbe("failing-index"); let last = ParticipantProbe("snapshot")
        let lifecycle = try AccountLifecycle(directory: .init(), vault: vault, store: store, participants: [first, last])
        try await connect(lifecycle, account); try await lifecycle.switchIdentity(to: account.context)
        let before = await lifecycle.snapshot().context
        let reference = try #require(await lifecycle.snapshot().directory.identities.first?.account.credential)
        await first.failures(detach: true, remove: true)
        await #expect(throws: LifecycleError.cleanupFailed(["detach", "failing-index"])) { try await lifecycle.remove(account.context) }
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .removalPending)
        #expect(await last.events.contains("remove"))
        #expect(await lifecycle.snapshot().context.account == nil)
        await #expect(throws: LifecycleError.removalPending) { try await lifecycle.switchIdentity(to: account.context) }
        let check = RequestContext(account: account.context, accountGeneration: 9999, requestGeneration: 0)
        await vault.bind(check)
        await #expect(throws: LifecycleError.keychain(-25300)) { try await vault.read(reference, context: check) }
        #expect(await lifecycle.accepts(before) == false)
        await first.failures(); try await lifecycle.remove(account.context)
        #expect(await lifecycle.snapshot().directory.identities.isEmpty)
        try await vault.destroyIsolatedTestKeychain()
    }
    @Test func failedSignOutStorageStillDeletesKeysAndLocksInMemory() async throws {
        let vault = try testVault(); let store = MemoryDirectory(); let account = try identity()
        let lifecycle = try AccountLifecycle(directory: .init(), vault: vault, store: store, participants: [])
        try await connect(lifecycle, account); try await lifecycle.switchIdentity(to: account.context)
        let before = await lifecycle.snapshot().context
        await store.setFailure(true)
        await #expect(throws: LifecycleError.cleanupFailed(["directory"])) { try await lifecycle.signOut(account.context) }
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .signedOut)
        #expect(await lifecycle.accepts(before) == false)
        await #expect(throws: LifecycleError.signedOut) { try await lifecycle.switchIdentity(to: account.context) }
        await store.setFailure(false); try await lifecycle.signOut(account.context)
        try await vault.destroyIsolatedTestKeychain()
    }
}
