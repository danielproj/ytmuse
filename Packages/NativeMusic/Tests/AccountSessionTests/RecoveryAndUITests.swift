import Testing
import Foundation
import Domain
import AccountSession
import Features

@Suite("T04 failure recovery and native UI state") struct RecoveryAndUITests {
    @Test func missingKeyOffersReconnectAndExpiryStorageFailureDetaches() async throws {
        let vault = try testVault(); let store = MemoryDirectory(); let account = try identity()
        let lifecycle = try AccountLifecycle(directory: .init(), vault: vault, store: store, participants: [])
        try await connect(lifecycle, account)
        try await vault.deleteAll(for: account.context)
        await #expect(throws: DomainError.unauthorized) { try await lifecycle.switchIdentity(to: account.context) }
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .signedOut)
        #expect(await lifecycle.snapshot().context.account == nil)
        await #expect(throws: LifecycleError.signedOut) { try await lifecycle.switchIdentity(to: account.context) }
        let reconnect = try await lifecycle.beginAuthentication(for: account.context)
        try await lifecycle.completeAuthentication(reconnect, account: account, secret: Data([8]))
        try await lifecycle.switchIdentity(to: account.context)
        let previous = await lifecycle.snapshot().context
        await store.setFailure(true)
        await #expect(throws: LifecycleError.cleanupFailed(["directory"])) { try await lifecycle.expire(context: previous) }
        #expect(await lifecycle.snapshot().context.account == nil)
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .expired)
        #expect(await lifecycle.reference(for: account.context, context: previous).outcome.isFailure)
        await store.setFailure(false); try await lifecycle.remove(account.context)
        try await vault.destroyIsolatedTestKeychain()
    }
    @Test @MainActor func providerRestrictionsCancelAttemptAndRemainAccurateInNativeState() async throws {
        let vault = try testVault(); let store = MemoryDirectory()
        let lifecycle = try AccountLifecycle(directory: .init(), vault: vault, store: store, participants: [])
        let restricted = AccountsModel(lifecycle: lifecycle, authentication: { _ in throw DomainError.regionRestricted })
        await restricted.authenticate()
        #expect(restricted.message == "This action is unavailable in this identity’s region.")
        #expect(await lifecycle.snapshot().reconnectPending == false)
        let forbidden = AccountsModel(lifecycle: lifecycle, authentication: { _ in throw DomainError.forbidden })
        await forbidden.authenticate()
        #expect(forbidden.message == "This identity does not have permission for that action.")
        #expect(forbidden.identities.isEmpty)
        #expect(await lifecycle.snapshot().reconnectPending == false)
        try await vault.destroyIsolatedTestKeychain()
    }
}
private extension Result {
    var isFailure: Bool { if case .failure = self { true } else { false } }
}
