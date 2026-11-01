import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct PersistenceStressTests {
    @Test func fiftyThousandIndexedItemsAndDuplicateOccurrencesArePaged() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context(), store = try SQLiteStore(directory: directory, context: request)
        try await register(store, request)
        for start in stride(from: 0, to: 50000, by: 1000) { try await store.saveMedia(StressDataset.items(start..<(start + 1000)), context: request) }
        var seen = Set<String>(), cursor: String? = nil, pages = 0
        repeat {
            let page = try await store.mediaPage(after: cursor, limit: 137, context: request)
            #expect(!page.items.isEmpty && page.items.count <= 137)
            for item in page.items { #expect(seen.insert(item.id.rawValue).inserted) }
            cursor = page.next; pages += 1
        } while cursor != nil
        #expect(seen.count == 50000); #expect(pages == 365)
        // FTS prefix/diacritic normalization, punctuation literalization and bounded results.
        let start = ContinuousClock.now
        let search = try await store.search("SYNTHETIC cafe mél", limit: 23, context: request)
        let elapsed = start.duration(to: .now)
        #expect(search.items.count == 23); #expect(search.next != nil)
        #expect(try await store.search("\" OR *", limit: 20, context: request).items.isEmpty)
        print("T03 synthetic storage: items=50000 pages=365 FTS_results=23 elapsed=\(elapsed); not formal performance acceptance")
        for index in 0..<1000 {
            let id = try ServiceID("collection-\(index)")
            try await store.saveCollection(id, metadata: CatalogMetadata(id: id, title: "Synthetic collection \(index)"), context: request)
        }
        let collection = try ServiceID("collection-0")
        for start in stride(from: 0, to: 10000, by: 1000) {
            let entries = try (start..<(start + 1000)).map { PlaylistItem(occurrence: .synthetic(StressDataset.occurrence($0)), media: try ServiceID("item-000001")) }
            try await store.storeCollectionPage(collection, entries: entries, startingAt: start, context: request)
        }
        var after = -1, occurrenceIDs = Set<OccurrenceIdentity>(), count = 0
        while true {
            let page = try await store.collectionPage(collection, after: after, limit: 173, context: request)
            for entry in page.items { #expect(occurrenceIDs.insert(entry.occurrence).inserted); #expect(entry.media.rawValue == "item-000001") }
            count += page.items.count
            guard let next = page.next else { break }; after = try #require(Int(next))
        }
        #expect(count == 10000); #expect(occurrenceIDs.count == 10000)
        let entries = try (0..<5000).map { try QueueEntry(id: StressDataset.occurrence($0), media: ServiceID("item-000001"), segment: .context, originalOrder: $0, consumed: $0 < 100) }
        let queue = try QueueSession(account: request.account!, version: 1, entries: entries, currentOccurrence: entries[100].id, position: 11, shuffleSeed: StressDataset.seed, repeatMode: .off, autoplay: true)
        try await store.saveQueue(queue, context: request)
        #expect(try await store.queuePage(limit: 100, context: request).count == 100)
        #expect(try await store.restoredQueue(context: request)?.queue.entries.count == 5000)
        await store.close()
    }
    @Test func accountChannelRegionAndGenerationAreIsolated() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = try context(), channel = try context(channel: "second-channel", generation: 2), b = try context(account: "00000000-0000-0000-0000-000000000002", generation: 3), region = try context(region: "GB", generation: 4)
        let store = try SQLiteStore(directory: directory, context: a)
        for (index, request) in [a, channel, b, region].enumerated() {
            await store.bind(request); try await register(store, request)
            try await store.saveMedia([media("shared-id", title: "Scoped title \(index)")], context: request)
            try await store.saveQueue(oldQueue(request), context: request)
            let operation = try mutation(request); _ = try success(await store.enqueue(operation, context: request))
        }
        for (index, original) in [a, channel, b, region].enumerated() {
            let request = switched(original, generation: UInt64(index + 5))
            await store.bind(request)
            #expect(try await store.mediaPage(context: request).items.map(\.title) == ["Scoped title \(index)"])
            #expect(try await store.pendingMutations(context: request).count == 1)
        }
        let currentA = switched(a, generation: 9)
        await store.bind(currentA)
        #expect(await store.queue(context: a).outcome.failure == .staleContext)
        #expect(await store.preferences(scope: .account(b.account!), context: currentA).outcome.failure == .staleContext)
        try await store.removeAccount(context: currentA)
        let currentChannel = switched(channel, generation: 10)
        await store.bind(currentChannel); #expect(try await store.mediaPage(context: currentChannel).items.count == 1)
        let removedA = switched(a, generation: 11)
        await store.bind(removedA); #expect(try await store.search("Scoped", context: removedA).items.isEmpty)
        await store.close()
    }
    @Test func boundsFailBeforeLargeReadsAndIndexesAreUsed() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context(), store = try SQLiteStore(directory: directory, context: request)
        try await register(store, request)
        for limit in [0, -1, 201, Int.max] {
            await #expect(throws: StorageError.invalidInput) { _ = try await store.mediaPage(limit: limit, context: request) }
            await #expect(throws: StorageError.invalidInput) { _ = try await store.search("x", limit: limit, context: request) }
        }
        await store.close()
        let db = try SQLite(directory.appendingPathComponent("library.sqlite"))
        let plans = try db.all("EXPLAIN QUERY PLAN SELECT id FROM entities WHERE scope=? AND id>? ORDER BY id LIMIT 101", [.text("scope"), .text("")])
        #expect(plans.contains { $0[3].string.contains("INDEX") })
        db.close()
    }
}
