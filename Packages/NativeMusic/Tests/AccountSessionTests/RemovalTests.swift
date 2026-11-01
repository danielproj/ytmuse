import Testing
import Foundation
import Domain
import AccountSession
@testable import Persistence

@Suite("T04 durable roster and registered SQLite cleanup") struct RemovalTests {
    @Test func normalizedRosterHasNoAggregateAccountCapAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-music-T04-roster-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
        let store = try SQLiteStore(directory: root, context: context)
        let directory = SQLiteAccountDirectory(store: store, context: context)
        let uuid = UUID()
        let accounts = try (0..<1025).map { try identity("durable-channel-\($0)", uuid: uuid) }
        let records = AccountDirectory(identities: accounts.map { LocalIdentity(account: $0, state: .signedOut) }, defaultIdentity: accounts.last?.context)
        try await directory.save(records)
        await store.close()
        let reopened = try SQLiteStore(directory: root, context: context)
        let loaded = try await SQLiteAccountDirectory(store: reopened, context: context).load()
        #expect(Set(loaded.identities.map(\.id)) == Set(accounts.map(\.context)))
        #expect(loaded.defaultIdentity == accounts.last?.context)
        #expect(loaded.identities.allSatisfy { $0.state == .signedOut })
        await reopened.close()
    }
    @Test func coordinatorRemovalScrubsRegisteredTablesBackupAndCredentialReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-music-T04-remove-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
        let store = try SQLiteStore(directory: root, context: context), vault = try testVault()
        let directory = SQLiteAccountDirectory(store: store, context: context)
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: directory, participants: [SQLiteAccountParticipant(store: store, directory: directory)])
        let a = try identity(); let b = try identity("kept")
        try await connect(lifecycle, a); try await connect(lifecycle, b)
        try await lifecycle.switchIdentity(to: a.context)
        let request = await lifecycle.snapshot().context
        let reference = try #require(try await lifecycle.reference(for: a.context, context: request).outcome.get())
        try await store.seedEveryPrivateTable(request)
        let before = try await store.privateTableCounts(a.context)
        #expect(before.count == 13); #expect(before.values.allSatisfy { $0 > 0 })
        let backup = try await store.backup()
        try await lifecycle.remove(a.context)
        #expect(try await store.privateTableCounts(a.context).values.allSatisfy { $0 == 0 })
        let restored = root.appendingPathComponent("restored")
        try SQLiteStore.recover(backup: backup, into: restored)
        let recovered = try SQLiteStore(directory: restored, context: context)
        #expect(try await recovered.privateTableCounts(a.context).values.allSatisfy { $0 == 0 })
        let roster = try await SQLiteAccountDirectory(store: recovered, context: context).load()
        #expect(roster.identities.map(\.id) == [b.context])
        await recovered.close()
        // Secure-delete/checkpoint and backup VACUUM remove deleted reference bytes.
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.pathExtension == "sqlite" || file.lastPathComponent.hasSuffix("-wal") {
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(reference.rawValue))
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("W04PRIVATECANARY"))
        }
        try await lifecycle.switchIdentity(to: b.context)
        #expect(await lifecycle.snapshot().context.account == b.context)
        try await lifecycle.remove(b.context)
        await store.close(); try await vault.destroyIsolatedTestKeychain()
    }
}
extension SQLiteStore {
    func seedEveryPrivateTable(_ context: RequestContext) throws {
        let account = context.account!, item = try ServiceID("private-media")
        try saveMedia([MediaItem(id: item, kind: .song, title: "W04PRIVATECANARY", artists: [], duration: 5, artwork: [], explicit: false, availability: .available)], context: context)
        let collection = try ServiceID("collection")
        try savePlaylist(Playlist(metadata: .init(id: collection, title: "W04PRIVATECANARY"), owner: ServiceID("synthetic-owner"), privacy: .private, permissions: [:], providerVersion: nil, snapshotVersion: 1), context: context)
        try storeCollectionPage(collection, entries: [.init(occurrence: .synthetic(UUID()), media: item)], startingAt: 0, context: context)
        let entry = try QueueEntry(id: UUID(), media: item, segment: .user, originalOrder: 0)
        try saveQueue(QueueSession(account: account, version: 1, entries: [entry], currentOccurrence: entry.id, position: 1, shuffleSeed: nil, repeatMode: .off, autoplay: false), context: context)
        _ = try store(Preferences(scope: .account(account), schemaVersion: 1, values: ["navigation": .text("W04PRIVATECANARY")]), context: context).outcome.get()
        let id = UUID()
        _ = try enqueue(PendingMutation(id: id, account: account, target: collection, intent: .library(.save(true)), precondition: .init(providerVersion: nil, snapshotVersion: 1), outcome: .pending(id)), context: context).outcome.get()
        try saveMembership(.init(account: account, entity: item, serviceStatus: true, sync: .localOnly, sortDate: nil, sortKey: "private"), context: context)
        try appendHistory(.init(account: account, item: item, startedAt: Date(timeIntervalSince1970: 10), endedAt: nil, provenance: .local, sync: .localOnly), context: context)
        try saveDownload(DownloadJob(account: account, media: item, variant: ServiceID("variant"), ranges: [ByteRange(lower: 0, upper: 10)], state: .paused, size: 11, retries: 0, references: [collection], verification: .unknown), context: context)
        try saveArtwork(.init(sourceKey: ServiceID("art"), width: 32, height: 32, policy: .revalidate, contentHash: "hash", bytes: 2, lastUsedAt: Date()), context: context)
    }
    func privateTableCounts(_ account: AccountContext) throws -> [String: Int64] {
        let key = Self.key(account)
        let tables = ["identities", "entities", "collections", "collection_entries", "queues", "queue_entries", "outbox", "memberships", "history", "downloads", "download_ranges", "download_refs", "artwork"]
        var counts: [String: Int64] = [:]
        for table in tables { counts[table] = try db.scalar("SELECT count(*) FROM \(table) WHERE scope=?", [.text(key)]).int }
        #expect(try db.scalar("SELECT count(*) FROM preferences WHERE scope=?", [.text("account:" + key)]).int == (counts["identities"] == 0 ? 0 : 1))
        return counts
    }
}
