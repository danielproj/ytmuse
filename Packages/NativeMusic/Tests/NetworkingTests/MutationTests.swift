import Foundation
import Domain
import Persistence
import Testing
@testable import YouTubeMusicAdapter

@Suite struct MutationTests {
    struct Envelope: Decodable, Sendable { let success: Bool }
    @Test func durableAmbiguityRejectionAndReconciliationNeverReplay() async throws {
        // Worktree-local scratch, never the OS shared temp directory.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build/w07/mutation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = owner(account: try identity()), store = try SQLiteStore(directory: directory, context: context)
        let account = context.account!
        try await store.saveAccount(Account(id: account.accountID, serviceIdentity: ServiceID("synthetic-service"), context: account, displayName: "Synthetic", credential: nil), context: context)
        let executor = DurableMutationExecutor(outbox: store), probe = Probe()
        for mode in ["rejected", "ambiguous", "confirmed"] {
            let id = UUID()
            let mutation = try PendingMutation(id: id, account: account, target: ServiceID("synthetic-target"), intent: .playlist(.add([ServiceID("duplicate"), ServiceID("duplicate")])), precondition: .init(providerVersion: "synthetic-v1", snapshotVersion: 1), outcome: .pending(id))
            _ = try await store.enqueue(mutation, context: context).outcome.get()
            let result = await executor.execute(id: id, context: context) { claimed in
                #expect(claimed.attempts == 1 && claimed.precondition == mutation.precondition)
                #expect(try await store.status(id, context: context).outcome.get().outcome == .needsReconciliation)
                await probe.record()
                if mode == "ambiguous" { throw URLError(.timedOut) }
                let response = BoundedResponse(status: 200, body: Data((mode == "confirmed" ? #"{"success":true}"# : #"{"success":false}"#).utf8))
                let decoded = try await NetworkDecoder().json(Envelope.self, response: response, bounds: ResponseBounds())
                return decoded.success ? .confirmed : .rejected
            }
            let state = try result.outcome.get()
            if mode == "confirmed" { #expect(state.outcome == .confirmed) }
            if mode == "rejected" { #expect(state.outcome == .failed(.malformedResponse)) }
            if mode == "ambiguous" {
                #expect(state.outcome == .needsReconciliation)
                let blocked = await executor.execute(id: id, context: context) { _ in await probe.record(); return .confirmed }
                #expect(throws: DomainError.reconciliationRequired) { try blocked.outcome.get() }
                let reconciled = await executor.reconcile(id: id, context: context) { _ in .confirmed }
                #expect(try reconciled.outcome.get().outcome == .confirmed)
            }
            let duplicate = await executor.execute(id: id, context: context) { _ in await probe.record(); return .confirmed }
            #expect(throws: DomainError.reconciliationRequired) { try duplicate.outcome.get() }
        }
        #expect(await probe.calls == 3)
        await store.close()
        let reopened = try SQLiteStore(directory: directory, context: context)
        #expect(try await reopened.pendingMutations(context: context).count == 1) // only explicitly rejected operation
        await reopened.close()
    }
}
