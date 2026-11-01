import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct PersistenceRecordTests {
    @Test func jobsRangesReferencesHistoryAndArtworkRoundTrip() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context(), store = try SQLiteStore(directory: directory, context: request)
        try await register(store, request)
        let item = try ServiceID("media"), now = Date(timeIntervalSince1970: 100000)
        let job = try DownloadJob(account: request.account!, media: item, variant: ServiceID("variant"), ranges: [ByteRange(lower: 0, upper: 99), ByteRange(lower: 200, upper: 299)], state: .paused, size: 500, retries: 2, references: [ServiceID("playlist-a"), ServiceID("manual-pin")], verification: .unknown)
        try await store.saveDownload(job, context: request)
        let loaded = try #require(await store.download(job.id, context: request))
        #expect(loaded.ranges == job.ranges); #expect(loaded.references == job.references)
        #expect(loaded.size == 500); #expect(loaded.retries == 2); #expect(loaded.state == .paused)
        for status: Bool? in [nil, true, false] {
            let membership = LibraryMembership(account: request.account!, entity: item, serviceStatus: status, sync: .needsReconciliation, sortDate: now, sortKey: "key")
            try await store.saveMembership(membership, context: request)
            let restored = try #require(await store.membership(item, context: request))
            #expect(restored.serviceStatus == status); #expect(restored.sync == .needsReconciliation); #expect(restored.sortDate == now)
        }
        for provenance: HistoryProvenance in [.local, .source] {
            try await store.appendHistory(HistoryEntry(account: request.account!, item: item, startedAt: now, endedAt: now.addingTimeInterval(1), provenance: provenance, sync: provenance == .local ? .localOnly : .confirmed), context: request)
        }
        try await store.clearHistory(provenance: .local, before: now.addingTimeInterval(2), context: request)
        #expect(try await store.recentHistory(provenance: .local, context: request).isEmpty)
        let remote = try await store.recentHistory(provenance: .source, context: request)
        #expect(remote.count == 1); #expect(remote[0].startedAt == now); #expect(remote[0].sync == .confirmed)
        let artwork = try ArtworkCacheEntry(sourceKey: ServiceID("art"), width: 100, height: 100, policy: .until(now), contentHash: "synthetic-hash", bytes: 1000, lastUsedAt: now)
        try await store.saveArtwork(artwork, context: request)
        #expect(try await store.artwork(artwork.sourceKey, width: 100, height: 100, context: request)?.policy == .until(now))
        try await store.saveArtwork(ArtworkCacheEntry(sourceKey: artwork.sourceKey, width: 100, height: 100, policy: .noStore, contentHash: "hash", bytes: 0, lastUsedAt: now), context: request)
        #expect(try await store.artwork(artwork.sourceKey, width: 100, height: 100, context: request) == nil)
        await store.close()
    }
}
