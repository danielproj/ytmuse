import Testing
import Foundation
import Domain
import AccountSession

@Suite("T04 owned native Keychain") struct KeychainTests {
    @Test func exactIdentityReferenceIsolationAndDeletion() async throws {
        let vault = try testVault(); let a = try identity(); let b = try identity("other", uuid: a.id)
        defer { Task { try? await vault.destroyIsolatedTestKeychain() } }
        let ref = try await vault.insert(Data([1, 7, 9]), for: a.context)
        let other = try await vault.insert(Data([2, 8]), for: b.context)
        let ac = RequestContext(account: a.context, accountGeneration: 1, requestGeneration: 2)
        let bc = RequestContext(account: b.context, accountGeneration: 2, requestGeneration: 0)
        await vault.bind(ac)
        #expect(try await vault.read(ref, context: ac) == Data([1, 7, 9]))
        await vault.bind(bc); await vault.bind(ac)
        await #expect(throws: DomainError.staleContext) { try await vault.read(ref, context: ac) }
        await #expect(throws: LifecycleError.keychain(-25300)) { try await vault.read(ref, context: bc) }
        #expect(try await vault.read(other, context: bc) == Data([2, 8]))
        try await vault.deleteAll(for: a.context)
        #expect(try await vault.read(other, context: bc) == Data([2, 8]))
        let back = RequestContext(account: a.context, accountGeneration: 3, requestGeneration: 0)
        await vault.bind(back)
        await #expect(throws: LifecycleError.keychain(-25300)) { try await vault.read(ref, context: back) }
        try await vault.deleteAll(for: a.context); try await vault.deleteAll(for: b.context)
        try await vault.destroyIsolatedTestKeychain()
    }
    /// E01 M2 rework: rotation write-back rewrites only the exact existing record,
    /// only for the bound active generation, and never creates or crosses accounts.
    @Test func replaceRewritesOnlyTheExactRecordForTheBoundGeneration() async throws {
        let vault = try testVault(); let a = try identity(); let b = try identity("other")
        let ref = try await vault.insert(Data([1, 2, 3]), for: a.context)
        let otherRef = try await vault.insert(Data([9, 9]), for: b.context)
        let ac = RequestContext(account: a.context, accountGeneration: 1, requestGeneration: 0)
        await vault.bind(ac)
        try await vault.replace(ref, with: Data([4, 5, 6]), context: ac)
        #expect(try await vault.read(ref, context: ac) == Data([4, 5, 6]))
        // The production path calls through the existential; the concrete method must be its witness.
        let erased: any SessionVault = vault
        try await erased.replace(ref, with: Data([4, 5, 6]), context: ac)
        // Missing record: an error, and nothing is created under that reference.
        let missing = try CredentialReference(UUID().uuidString)
        await #expect(throws: LifecycleError.keychain(errSecItemNotFound)) { try await vault.replace(missing, with: Data([7]), context: ac) }
        await #expect(throws: LifecycleError.keychain(errSecItemNotFound)) { try await vault.read(missing, context: ac) }
        // Another account's reference cannot be addressed from this account's context.
        await #expect(throws: LifecycleError.keychain(errSecItemNotFound)) { try await vault.replace(otherRef, with: Data([7]), context: ac) }
        await #expect(throws: DomainError.unauthorized) { try await vault.replace(ref, with: Data(), context: ac) }
        // Stale generation: a newer owner is bound; the old context can no longer write.
        let newer = RequestContext(account: a.context, accountGeneration: 2, requestGeneration: 0)
        await vault.bind(newer)
        await #expect(throws: DomainError.staleContext) { try await vault.replace(ref, with: Data([8]), context: ac) }
        let bc = RequestContext(account: b.context, accountGeneration: 3, requestGeneration: 0)
        await #expect(throws: DomainError.staleContext) { try await vault.replace(otherRef, with: Data([8]), context: bc) }
        #expect(try await vault.read(ref, context: newer) == Data([4, 5, 6]))
        await vault.bind(bc)
        #expect(try await vault.read(otherRef, context: bc) == Data([9, 9]))
        try await vault.deleteAll(for: a.context); try await vault.deleteAll(for: b.context)
        try await vault.destroyIsolatedTestKeychain()
    }
    @Test func rejectsUnownedNamespaces() throws {
        #expect(throws: LifecycleError.invalidDirectory) { try KeychainVault(namespace: "unrelated") }
    }
}
