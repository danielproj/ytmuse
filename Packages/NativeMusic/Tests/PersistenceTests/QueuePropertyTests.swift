import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct PersistenceQueuePropertyTests {
    @Test(arguments: [UInt64(1), 7, 42, 271828, 314159, UInt64.max])
    func duplicateShuffleSnapshotsRoundTripAndRollback(seed: UInt64) async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context()
        let store = try SQLiteStore(directory: directory, context: request); try await register(store, request)
        var generator = seed
        for version in 1...8 {
            var order = Array(0..<128)
            for i in stride(from: 127, through: 1, by: -1) {
                generator = generator &* 6364136223846793005 &+ 1442695040888963407
                order.swapAt(i, Int(generator % UInt64(i + 1)))
            }
            let entries = try order.map { index in
                try QueueEntry(id: StressDataset.occurrence(index), media: ServiceID("duplicate-\(index % 3)"), segment: index % 2 == 0 ? .context : .user, originalOrder: index, consumed: index < version)
            }
            let queue = try QueueSession(account: request.account!, version: UInt64(version), entries: entries, currentOccurrence: entries[version].id, position: Double(version) * 1.25, shuffleSeed: seed, repeatMode: .all, autoplay: false)
            try await store.saveQueue(queue, context: request)
            let restored = try #require(await store.restoredQueue(context: request)?.queue)
            #expect(restored.entries.map(\.id) == entries.map(\.id))
            #expect(restored.entries.map(\.media) == entries.map(\.media))
            #expect(restored.entries.map(\.originalOrder) == entries.map(\.originalOrder))
            #expect(restored.entries.map(\.segment) == entries.map(\.segment))
            #expect(restored.entries.map(\.consumed) == entries.map(\.consumed))
            #expect(restored.currentOccurrence == queue.currentOccurrence)
            #expect(restored.position == queue.position); #expect(restored.shuffleSeed == seed)
            let replacement = try oldQueue(request)
            // Use the current version so this exercises the write transaction, not stale-version rejection.
            let rejected = try QueueSession(account: request.account!, version: UInt64(version), entries: replacement.entries, currentOccurrence: replacement.currentOccurrence, position: 999, shuffleSeed: 0, repeatMode: .off, autoplay: true)
            await #expect(throws: StorageError.conflict) {
                try await store.writeQueue(rejected, continuation: .init(contextID: nil, cursor: nil), context: request, boundary: { point in if point == "entry" { throw StorageError.conflict } })
            }
            #expect(try await store.restoredQueue(context: request)?.queue.entries.map(\.id) == entries.map(\.id))
            #expect(try await store.restoredQueue(context: request)?.queue.position == queue.position)
        }
        await store.close()
    }
}
