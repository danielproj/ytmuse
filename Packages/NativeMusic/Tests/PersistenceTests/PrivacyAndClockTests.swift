import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct PersistencePrivacyAndClockTests {
    @Test func secretsAreRejectedReferencesAndPrivatePermissionsSurviveBackup() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context(), store = try SQLiteStore(directory: directory, context: request)
        try await register(store, request)
        let credential = try #require(await store.account(context: request)?.credential)
        #expect(UUID(uuidString: credential.rawValue) != nil)
        let probes = ["Bearer SYNTHETIC_SECRET_CANARY", "Authorization: SYNTHETIC_SECRET_CANARY", "Cookie: SYNTHETIC_SECRET_CANARY", "https://synthetic.invalid/media?signature=SYNTHETIC_SECRET_CANARY", "refresh_token=SYNTHETIC_SECRET_CANARY"]
        for probe in probes {
            await #expect(throws: StorageError.invalidInput) { try await store.saveMedia([media("rejected", title: probe)], context: request) }
            #expect(await store.store(try Preferences(scope: .global, schemaVersion: 1, values: ["unsafe": .text(probe)]), context: request).outcome.failure == .malformedResponse)
            #expect(await store.enqueue(try mutation(request, title: probe), context: request).outcome.failure == .malformedResponse)
        }
        let account = request.account!
        let unsafe = try Account(id: account.accountID, serviceIdentity: ServiceID("service"), context: account, displayName: "Synthetic", credential: CredentialReference("SYNTHETIC_SECRET_CANARY"))
        await #expect(throws: StorageError.invalidInput) { try await store.saveAccount(unsafe, context: request) }
        try await store.saveMedia([media("retained")], context: request)
        let backup = try await store.backup()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent == "library.sqlite-wal" })
        #expect(files.contains { $0.lastPathComponent == "library.sqlite-shm" })
        let dirMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
        for file in files {
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("SYNTHETIC_SECRET_CANARY"))
        }
        let recovery = directory.appendingPathComponent("recovery")
        try SQLiteStore.recover(backup: backup, into: recovery)
        let reopened = try SQLiteStore(directory: recovery, context: request)
        #expect(try await reopened.account(context: request)?.credential == credential)
        #expect(try await reopened.mediaPage(context: request).items.count == 1)
        await reopened.close(); await store.close()
    }
    @Test func preferencesRetainTypesAndScopeAndResetDoesNotClearQueue() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context(), store = try SQLiteStore(directory: directory, context: request)
        try await register(store, request); try await store.saveQueue(oldQueue(request), context: request)
        let windowID = UUID()
        let values: [String: PreferenceValue] = ["bool": .boolean(true), "int": .integer(Int.max), "double": .number(1.25), "text": .text("café")]
        for scope: PreferenceScope in [.global, .account(request.account!), .window(windowID)] {
            _ = try success(await store.store(Preferences(scope: scope, schemaVersion: 3, values: values), context: request))
            let preferences = try success(await store.preferences(scope: scope, context: request))
            #expect(preferences.schemaVersion == 3); #expect(preferences.values == values)
        }
        try await store.clearPreferences(scope: .account(request.account!), context: request)
        #expect(try success(await store.preferences(scope: .account(request.account!), context: request)).values.isEmpty)
        #expect(try success(await store.preferences(scope: .global, context: request)).values == values)
        #expect(try await store.restoredQueue(context: request)?.queue.position == 7)
        await store.close()
    }
    @Test func wallClockJumpsDoNotChangeDurablePositionOrGrantExpiredRights() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try context(), store = try SQLiteStore(directory: directory, context: request)
        try await register(store, request)
        var machine = PlaybackMachine(request: request)
        let occurrence = UUID(); let item = try ServiceID("clock-item")
        machine.select(item, occurrence: occurrence, now: .seconds(1))
        machine.receive(.resolved, context: machine.context, now: .seconds(2))
        machine.receive(.prepared, context: machine.context, now: .seconds(3))
        machine.receive(.started, context: machine.context, now: .seconds(4))
        let anchor = Date(timeIntervalSince1970: 10000)
        let entitlement = try OfflineEntitlement(account: request.account!, media: item, source: "synthetic-grant", rights: [.play], expiresAt: anchor.addingTimeInterval(60), renewAfter: nil, lastValidatedAt: anchor, validation: .available)
        let lease = try EntitlementLease(entitlement: entitlement, validatedAt: anchor, monotonic: .seconds(4))
        #expect(lease.permits(.play, context: request.account!, wall: anchor.addingTimeInterval(10), monotonic: .seconds(14)))
        for wall in [anchor.addingTimeInterval(-3600), anchor.addingTimeInterval(3600), anchor.addingTimeInterval(1)] {
            let position = machine.snapshot.position(at: .seconds(74))
            #expect(position == 70)
            #expect(!lease.permits(.play, context: request.account!, wall: wall, monotonic: .seconds(74)))
            let entry = try QueueEntry(id: occurrence, media: item, segment: .user, originalOrder: 0)
            try await store.saveQueue(QueueSession(account: request.account!, version: 1, entries: [entry], currentOccurrence: occurrence, position: position, shuffleSeed: nil, repeatMode: .off, autoplay: true), context: request)
        }
        await store.close()
        let reopened = try SQLiteStore(directory: directory, context: request)
        let restored = try #require(await reopened.restoredQueue(context: request))
        #expect(restored.queue.position == 70); #expect(restored.intent == .pause(.restored))
        // No persisted lease or monotonic anchor is loaded to authorize playback after reboot.
        #expect(!entitlement.permits(.play, context: request.account!, now: anchor.addingTimeInterval(-1)))
        await reopened.close()
    }
    @Test func metadataFilesAreNotFollowedThroughSymlinks() async throws {
        let directory = try disposable(); defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("sentinel"); try Data("unchanged".utf8).write(to: sentinel)
        let target = directory.appendingPathComponent("library.sqlite")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: sentinel)
        #expect(throws: StorageError.permissions) { _ = try SQLiteStore(directory: directory) }
        #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))
    }
}
