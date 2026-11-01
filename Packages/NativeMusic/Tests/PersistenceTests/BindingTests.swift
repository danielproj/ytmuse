import Foundation
import Testing
import Domain
@testable import Persistence

@Suite("W03-R1 storage binding order") struct PersistenceBindingTests {
    @Test func olderBindingCannotReinstatePriorAccount() async throws {
        let directory = try disposable()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try context(generation: 1)
        let current = try context(account: "00000000-0000-0000-0000-000000000002", generation: 2)
        let store = try SQLiteStore(directory: directory, context: old)
        try await register(store, old)
        try await store.saveMedia([media("old", title: "Prior account")], context: old)
        await store.bind(current)
        try await register(store, current)
        try await store.saveMedia([media("current", title: "Current account")], context: current)
        #expect(await store.queue(context: old).outcome.failure == .staleContext)
        // A delayed binding from older work cannot rewind the active account owner.
        await store.bind(old)
        #expect(await store.queue(context: old).outcome.failure == .staleContext)
        do {
            let page = try await store.mediaPage(context: current)
            #expect(page.items.map(\.title) == ["Current account"])
        } catch {
            Issue.record("New active account was rejected after an older bind: \(error)")
        }
        await store.close()
    }

    @Test func sameGenerationCannotChangeAccountChannelRegionOrSignOut() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try context(generation: 7)
        let store = try SQLiteStore(directory: directory, context: owner)
        try await register(store, owner)
        try await store.saveMedia([media("owned")], context: owner)
        let conflicts = [
            try context(account: "00000000-0000-0000-0000-000000000002", generation: 7),
            try context(channel: "different-channel", generation: 7),
            try context(region: "GB", generation: 7),
            RequestContext(account: nil, accountGeneration: 7, requestGeneration: 1)
        ]
        for conflict in conflicts {
            await store.bind(conflict)
            #expect(await store.queue(context: conflict).outcome.failure == .staleContext)
            #expect(try await store.mediaPage(context: owner).items.map(\.id.rawValue) == ["owned"])
        }
        // Per-feature query generations do not own the account lifecycle, in either order.
        for query in [UInt64.max, 2, 0, 1] {
            let request = switched(owner, generation: 7, query: query)
            await store.bind(request)
            #expect(try await store.mediaPage(context: request).items.count == 1)
            #expect(try await store.mediaPage(context: owner).items.count == 1)
        }
        await store.close()
    }

    @Test func newerSwitchBackIsAllowedButDelayedAndDuplicateBindsCannotRewind() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = try context(generation: 1)
        let b = try context(account: "00000000-0000-0000-0000-000000000002", generation: 2)
        let store = try SQLiteStore(directory: directory, context: a)
        try await register(store, a); try await store.saveMedia([media("account-a")], context: a)
        await store.bind(b); try await register(store, b); try await store.saveMedia([media("account-b")], context: b)
        let currentA = switched(a, generation: 3, query: 10)
        await store.bind(currentA)
        for delayed in [a, b, b, switched(b, generation: 3)] {
            await store.bind(delayed)
            #expect(await store.queue(context: delayed).outcome.failure == .staleContext)
            #expect(try await store.mediaPage(context: currentA).items.map(\.id.rawValue) == ["account-a"])
        }
        await store.bind(currentA); await store.bind(currentA)
        #expect(try await store.mediaPage(context: switched(currentA, generation: 3, query: 0)).items.count == 1)
        await store.close()
    }

    @Test func removalRetainsGenerationFloorAndCloseCannotBeRebound() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = try context(generation: 5)
        let store = try SQLiteStore(directory: directory, context: a)
        try await register(store, a)
        try await store.removeAccount(context: a)
        for delayed in [switched(a, generation: 4), a, switched(a, generation: 5, query: .max), try context(channel: "other", generation: 5)] {
            await store.bind(delayed)
            #expect(await store.queue(context: delayed).outcome.failure == .staleContext)
            #expect(await store.preferences(scope: .global, context: delayed).outcome.failure == .staleContext)
            await #expect(throws: DomainError.staleContext) { try await register(store, delayed) }
        }
        let newer = switched(a, generation: 6)
        await store.bind(newer); try await register(store, newer)
        #expect(try await store.account(context: newer)?.context == newer.account)
        await store.close()
        let afterClose = switched(a, generation: 7)
        await store.bind(afterClose)
        #expect(await store.queue(context: afterClose).outcome.failure == .staleContext)
        #expect(await store.preferences(scope: .global, context: afterClose).outcome.failure == .staleContext)
    }

    @Test func signOutRejectsDelayedIdentityAndAllowsNewerSignIn() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = try context(generation: 1), store = try SQLiteStore(directory: directory, context: a)
        try await register(store, a); try await store.saveMedia([media("preserved")], context: a)
        let signedOut = RequestContext(account: nil, accountGeneration: 2, requestGeneration: 1)
        await store.bind(signedOut)
        for delayed in [a, switched(a, generation: 2)] {
            await store.bind(delayed)
            #expect(await store.queue(context: delayed).outcome.failure == .staleContext)
            #expect(await store.preferences(scope: .global, context: signedOut).outcome.failure == nil)
            #expect(await store.queue(context: signedOut).outcome.failure == .unauthorized)
        }
        await store.bind(signedOut) // Duplicate sign-out does not change authority.
        let signedIn = switched(a, generation: 3)
        await store.bind(signedIn)
        #expect(try await store.mediaPage(context: signedIn).items.map(\.id.rawValue) == ["preserved"])
        await store.bind(signedOut)
        #expect(try await store.mediaPage(context: signedIn).items.count == 1)
        await store.close()
    }

    @Test func freshStoreBootstrapsAtZeroAndExhaustedGenerationFailsClosed() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = try context(generation: 0), store = try SQLiteStore(directory: directory)
        #expect(await store.queue(context: a).outcome.failure == .staleContext)
        await store.bind(a); try await register(store, a)
        #expect(try await store.account(context: a) != nil)
        let last = switched(a, generation: .max)
        await store.bind(last)
        #expect(try await store.account(context: last) != nil)
        try await store.removeAccount(context: last)
        for delayed in [last, a] {
            await store.bind(delayed)
            #expect(await store.queue(context: delayed).outcome.failure == .staleContext)
        }
        await store.close()
        // A new process/store gets a new session-owner lifetime, not a persisted clock.
        let reopened = try SQLiteStore(directory: directory, context: a)
        try await register(reopened, a)
        #expect(try await reopened.account(context: a) != nil)
        await reopened.close()
    }
}
