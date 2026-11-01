import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct PersistenceIntegrityTests {
    @Test func removalScrubsBackupsAndLeavesOtherIdentity() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = try context(), b = try context(channel: "other-channel", generation: 2)
        let store = try SQLiteStore(directory: directory, context: a)
        try await register(store, a); try await store.saveMedia([media("removed", title: "W03PRIVATECANARYQJZ")], context: a)
        _ = try success(await store.store(Preferences(scope: .account(a.account!), schemaVersion: 1, values: ["private": .text("W03PRIVATECANARYQJZ")]), context: a))
        let operation = try mutation(a); _ = try success(await store.enqueue(operation, context: a))
        await store.bind(b); try await register(store, b); try await store.saveMedia([media("retained")], context: b)
        let reused = try PendingMutation(id: operation.id, account: b.account!, target: operation.target, intent: operation.intent, precondition: operation.precondition, outcome: .pending(operation.id))
        #expect(await store.enqueue(reused, context: b).outcome.failure == .invalidInput(.contextMismatch))
        let backup = try await store.backup()
        let removal = switched(a, generation: 3)
        await store.bind(removal); try await store.removeAccount(context: removal)
        let recovery = directory.appendingPathComponent("recovered-backup"); try SQLiteStore.recover(backup: backup, into: recovery)
        let restored = try SQLiteStore(directory: recovery, context: a)
        #expect(try await restored.account(context: a) == nil)
        #expect(try await restored.search("W03PRIVATECANARYQJZ", context: a).items.isEmpty)
        #expect(try success(await restored.preferences(scope: .account(a.account!), context: a)).values.isEmpty)
        #expect(await restored.status(operation.id, context: a).outcome.failure == .unavailableContent)
        await restored.bind(b); #expect(try await restored.mediaPage(context: b).items.first?.id.rawValue == "retained")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "sqlite" || file.lastPathComponent.hasSuffix("-wal") {
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).lowercased().contains("w03privatecanaryqjz"))
        }
        await restored.close(); await store.close()
    }
    @Test func corruptOriginalAndNewerSchemaNeverWipe() async throws {
        for corrupt in [true, false] {
            let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("library.sqlite")
            if corrupt { try Data("synthetic corrupt database sentinel".utf8).write(to: url) }
            else { let db = try SQLite(url); try db.execute("PRAGMA user_version=999"); try db.execute("CREATE TABLE sentinel(value TEXT)"); try db.execute("INSERT INTO sentinel VALUES('preserved')"); db.close() }
            let bytes = try Data(contentsOf: url)
            #expect(throws: (any Error).self) { _ = try SQLiteStore(directory: directory) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }
    @Test func duplicateOccurrenceFailureRollsBackWholePageAndPlaylistFieldsSurvive() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context(), store = try SQLiteStore(directory: directory, context: request)
        try await register(store, request)
        let id = try ServiceID("collection")
        let playlist = Playlist(metadata: CatalogMetadata(id: id, title: "Unicode café", description: "synthetic", artwork: [try ServiceID("art")], related: [try ServiceID("related")]), owner: try ServiceID("owner"), privacy: .unlisted, permissions: [.playlistMutation: .restricted(.forbidden), .collaboration: .unknown], providerVersion: "opaque", snapshotVersion: .max)
        try await store.savePlaylist(playlist, context: request)
        let restored = try #require(await store.playlist(id, context: request))
        #expect(restored.owner == playlist.owner); #expect(restored.privacy == .unlisted); #expect(restored.permissions == playlist.permissions)
        #expect(restored.snapshotVersion == .max); #expect(restored.providerVersion == "opaque")
        #expect(try await store.collectionMetadata(id, context: request)?.artwork == playlist.metadata.artwork)
        let entry = PlaylistItem(occurrence: .provider(try ServiceID("provider-occurrence")), media: try ServiceID("repeated-media"))
        try await store.storeCollectionPage(id, entries: [entry], startingAt: 0, context: request)
        await #expect(throws: StorageError.sqlite) { try await store.storeCollectionPage(id, entries: [entry, entry], startingAt: 1, replaceAll: true, context: request) }
        let page = try await store.collectionPage(id, context: request)
        #expect(page.items.count == 1); #expect(page.items[0].occurrence == entry.occurrence)
        let queue = try oldQueue(request)
        try await store.saveQueue(queue, continuation: .init(contextID: id, cursor: "continuation"), context: request)
        _ = try success(await store.checkpoint(queue, context: request))
        #expect(try await store.restoredQueue(context: request)?.continuation.cursor == "continuation")
        await store.close()
    }
}
