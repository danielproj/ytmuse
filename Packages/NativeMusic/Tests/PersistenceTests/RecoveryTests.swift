import Foundation
import Testing
import Domain
import Darwin
@testable import Persistence

@Suite struct PersistenceRecoveryTests {
    @Test func queueSurvivesKillAtRealBoundaries() async throws {
        let worker = try #require(ProcessInfo.processInfo.environment["PERSISTENCE_CRASH_WORKER"])
        for boundary in ["header", "entry", "beforeCommit", "afterCommit"] {
            let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
            let request = try context()
            let store = try SQLiteStore(directory: directory, context: request)
            try await register(store, request)
            try await store.saveQueue(oldQueue(request), continuation: .init(contextID: ServiceID("old-context"), cursor: "old-cursor"), context: request)
            await store.close()
            let process = Process(); process.executableURL = URL(fileURLWithPath: worker)
            process.arguments = [directory.path, "queue", boundary]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            #expect(process.terminationReason == .uncaughtSignal); #expect(process.terminationStatus == SIGKILL)
            let reopened = try SQLiteStore(directory: directory, context: request)
            let restored = try #require(await reopened.restoredQueue(context: request))
            if boundary == "afterCommit" {
                #expect(restored.queue.version == 2); #expect(restored.queue.entries.count == 40)
                #expect(restored.queue.position == 123); #expect(restored.queue.shuffleSeed == UInt64.max)
                #expect(restored.queue.entries.filter(\.consumed).count == 5)
                #expect(restored.queue.currentOccurrence == restored.queue.entries[5].id)
                #expect(restored.queue.repeatMode == .all); #expect(!restored.queue.autoplay)
                #expect(restored.continuation.cursor == "new-cursor"); #expect(restored.continuation.contextID?.rawValue == "new-context")
            } else {
                #expect(restored.queue.version == 1); #expect(restored.queue.entries.count == 1)
                #expect(restored.queue.position == 7); #expect(restored.queue.shuffleSeed == 42)
                #expect(restored.queue.currentOccurrence == restored.queue.entries[0].id)
                #expect(restored.queue.repeatMode == .one); #expect(restored.queue.autoplay)
                #expect(restored.continuation.cursor == "old-cursor"); #expect(restored.continuation.contextID?.rawValue == "old-context")
            }
            #expect(restored.intent == .pause(.restored))
            await reopened.close()
        }
    }
    @Test func migrationFailureSpaceAndCorruptRecoveryPreserveOriginal() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context()
        let original = try SQLiteStore(directory: directory, context: request, migration: .init(target: 1))
        try await register(original, request); try await original.saveMedia([media("sentinel")], context: request); await original.close()
        let url = directory.appendingPathComponent("library.sqlite")
        let originalBytes = try Data(contentsOf: url)
        #expect(throws: StorageError.insufficientSpace) { _ = try SQLiteStore(directory: directory, migration: .init(availableBytes: 0)) }
        #expect(try Data(contentsOf: url) == originalBytes)
        for index in 0..<5 {
            #expect(throws: StorageError.conflict) {
                _ = try SQLiteStore(directory: directory, migration: .init(afterStatement: { version, statement in if version == 2 && statement == index { throw StorageError.conflict } }))
            }
            let retained = try SQLite(url, readOnly: true); try retained.integrity()
            #expect(try retained.scalar("PRAGMA user_version").int == 1)
            #expect(try retained.scalar("SELECT count(*) FROM entities WHERE id='sentinel'").int == 1)
            retained.close()
        }
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("backup-v1-") && $0.pathExtension == "sqlite" }
        #expect(backups.count == 5)
        let recovery = directory.appendingPathComponent("restored")
        try SQLiteStore.recover(backup: #require(backups.first), into: recovery)
        let reopened = try SQLiteStore(directory: recovery, context: request)
        #expect(try await reopened.search("Synthetic", context: request).items.count == 1)
        await reopened.close()
        let bad = directory.appendingPathComponent("corrupt-backup.sqlite"); try Data("deliberately corrupt".utf8).write(to: bad)
        let bytesBefore = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try SQLiteStore.recover(backup: bad, into: directory.appendingPathComponent("bad-recovery")) }
        #expect(try Data(contentsOf: url) == bytesBefore)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bad-recovery").path))
        let upgraded = try SQLiteStore(directory: directory, context: request)
        #expect(try await upgraded.search("synthetic", context: request).items.count == 1)
        await upgraded.close()
    }
    @Test func killedMigrationRollsBackAndReopens() async throws {
        let worker = try #require(ProcessInfo.processInfo.environment["PERSISTENCE_CRASH_WORKER"])
        for index in [0, 3, 4] {
            let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
            let request = try context()
            let original = try SQLiteStore(directory: directory, context: request, migration: .init(target: 1))
            try await register(original, request); try await original.saveMedia([media("sentinel")], context: request); await original.close()
            let process = Process(); process.executableURL = URL(fileURLWithPath: worker); process.arguments = [directory.path, "migration", String(index)]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == SIGKILL)
            let reopened = try SQLiteStore(directory: directory, context: request)
            #expect(try await reopened.mediaPage(context: request).items.first?.id.rawValue == "sentinel")
            await reopened.close()
        }
    }
}
