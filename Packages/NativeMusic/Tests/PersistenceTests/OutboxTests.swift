import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct PersistenceOutboxTests {
    @Test func claimIsAtomicAcrossConnectionsAndRestart() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context(), operation = try mutation(request)
        let first = try SQLiteStore(directory: directory, context: request); try await register(first, request)
        let second = try SQLiteStore(directory: directory, context: request)
        _ = try success(await first.enqueue(operation, context: request))
        let wins = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for i in 0..<40 {
                let store = i % 2 == 0 ? first : second
                group.addTask { if case .success = await store.beginAttempt(operation.id, context: request).outcome { return true }; return false }
            }
            var wins = 0; for await won in group { if won { wins += 1 } }; return wins
        }
        #expect(wins == 1)
        let pending = try success(await second.status(operation.id, context: request))
        #expect(pending.attempts == 1); #expect(pending.outcome == .needsReconciliation)
        await first.close(); await second.close()
        let restarted = try SQLiteStore(directory: directory, context: request)
        #expect(await restarted.beginAttempt(operation.id, context: request).outcome.failure == .reconciliationRequired)
        let same = try success(await restarted.enqueue(operation, context: request)); #expect(same.attempts == 1)
        let changed = try mutation(request, id: operation.id, title: "different-payload")
        #expect(await restarted.enqueue(changed, context: request).outcome.failure == .invalidInput(.contextMismatch))
        _ = try success(await restarted.fail(operation.id, error: .transientTransport, ambiguous: true, context: request))
        #expect(await restarted.beginAttempt(operation.id, context: request).outcome.failure == .reconciliationRequired)
        _ = try success(await restarted.reconcile(operation.id, context: request))
        _ = try success(await restarted.commit(operation.id, context: request))
        #expect(await restarted.beginAttempt(operation.id, context: request).outcome.failure == .reconciliationRequired)
        #expect(try success(await restarted.status(operation.id, context: request)).outcome == .confirmed)
        await restarted.close()
    }
    @Test func cancelledAndFailedOperationsCannotDispatchAgain() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context(), store = try SQLiteStore(directory: directory, context: request)
        try await register(store, request)
        let cancelled = try mutation(request)
        _ = try success(await store.enqueue(cancelled, context: request))
        _ = try success(await store.cancel(cancelled.id, context: request))
        _ = try success(await store.enqueue(cancelled, context: request))
        #expect(await store.beginAttempt(cancelled.id, context: request).outcome.failure == .reconciliationRequired)
        let failed = try mutation(request)
        _ = try success(await store.enqueue(failed, context: request)); _ = try success(await store.beginAttempt(failed.id, context: request))
        _ = try success(await store.fail(failed.id, error: .forbidden, ambiguous: false, context: request))
        #expect(try success(await store.status(failed.id, context: request)).outcome == .failed(.forbidden))
        #expect(await store.beginAttempt(failed.id, context: request).outcome.failure == .reconciliationRequired)
        await store.close()
    }
    @Test func everyIntentRoundTripsAndPreservesPreconditions() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context(), store = try SQLiteStore(directory: directory, context: request)
        try await register(store, request)
        let occurrence = OccurrenceIdentity.synthetic(UUID()), provider = OccurrenceIdentity.provider(try ServiceID("provider-occurrence"))
        let actions: [RemoteMutation] = [.library(.save(true)), .library(.like(false)), .library(.dislike(true)), .library(.follow(true)), .library(.pauseHistory(true)), .library(.clearHistory), .playlist(.create(title: "title", privacy: .private)), .playlist(.edit(title: "renamed", description: "text", privacy: .unlisted)), .playlist(.delete), .playlist(.add([try ServiceID("a"), try ServiceID("a")])), .playlist(.remove([occurrence, provider])), .playlist(.move(occurrences: [provider, occurrence], before: occurrence)), .playlist(.join(invitation: try ServiceID("invitation"))), .playlist(.leave), .playlist(.invite(role: "editor"))]
        for action in actions {
            let id = UUID()
            let operation = try PendingMutation(id: id, account: request.account!, target: ServiceID("target"), intent: action, precondition: .init(providerVersion: "opaque-version", snapshotVersion: .max), outcome: .pending(id))
            let stored = try success(await store.enqueue(operation, context: request))
            #expect(try encode(IntentRecord(action)) == encode(IntentRecord(stored.intent)))
            #expect(stored.precondition == operation.precondition)
        }
        await store.close()
    }
}
extension Result where Failure == DomainError {
    var failure: DomainError? { if case .failure(let error) = self { error } else { nil } }
}
