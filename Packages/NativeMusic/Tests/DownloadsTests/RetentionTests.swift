import XCTest
import Foundation
import Domain
import Downloads
import AccountSession
import Playback

/// T15.4 — playlist add/remove with two references and a pin updates storage correctly; a removal never deletes
/// another retained reference. Runs on the REAL W14 encrypted store in an isolated test keychain.
final class RetentionTests: XCTestCase, @unchecked Sendable {
    private func rig(_ env: Env, store: (EncryptedStore, KeychainVault, EncryptedStoreSink), names: [String], size: Int = 3 * 1024) async throws -> (DownloadScheduler, FakeSource) {
        let source = FakeSource(wall: env.wall)
        for name in names { await source.set(owned(name), .init(bytes: payload(size, seed: UInt8(name.utf8.first!)), variant: "ret-" + name)) }
        let scheduler = try env.makeScheduler(source: source, sink: store.2)
        await scheduler.bind(env.context)
        return (scheduler, source)
    }
    private func retained(_ store: EncryptedStore, _ name: String, _ env: Env) async -> Int? { try? await store.length(variant: "ret-" + name, context: env.context) }
    private func regularFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    private func objectDirectories(_ env: Env) -> Int {
        let accounts = (try? FileManager.default.contentsOfDirectory(atPath: env.objectsURL.path)) ?? []
        return accounts.reduce(0) { total, name in total + ((try? FileManager.default.contentsOfDirectory(atPath: env.objectsURL.appendingPathComponent(name).path))?.count ?? 0) }
    }

    func testTwoPlaylistsShareOneStoredObjectAndRemovalOnlyDropsTheirOwnReference() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let kit = try env.realStore(); defer { Task { try? await kit.1.destroyIsolatedTestKeychain() } }
        let (scheduler, _) = try await rig(env, store: kit, names: ["x", "y", "z"])
        let p1 = try ServiceID("owned-playlist-1"), p2 = try ServiceID("owned-playlist-2")
        _ = await scheduler.setCollection(p1, title: "One", members: [owned("x"), owned("y")], downloading: true); await scheduler.settleBounded()
        _ = await scheduler.setCollection(p2, title: "Two", members: [owned("y"), owned("z")], downloading: true); await scheduler.settleBounded()
        var rows = await scheduler.snapshot().rows
        XCTAssertEqual(rows.count, 3, "y is one job although two playlists contain it")
        XCTAssertEqual(rows.first { $0.media == owned("y") }?.referenceCount, 2, "one stored object, two references")
        XCTAssertEqual(rows.filter { $0.phase == .available }.count, 3)
        let stored = objectDirectories(env); XCTAssertEqual(stored, 3, "exactly one encrypted object per distinct asset")
        // Playlist one loses y: playlist two still references it, so the object must stay readable.
        _ = await scheduler.reconcileCollection(p1, members: [owned("x")]); await scheduler.settleBounded()
        let yLength = await retained(kit.0, "y", env); XCTAssertEqual(yLength, 3 * 1024, "removal never deletes another retained reference")
        rows = await scheduler.snapshot().rows
        XCTAssertEqual(rows.first { $0.media == owned("y") }?.referenceCount, 1)
        // Playlist two loses y as well: nothing references it any more, so it is deleted from the store.
        _ = await scheduler.reconcileCollection(p2, members: [owned("z")]); await scheduler.settleBounded()
        let gone = await retained(kit.0, "y", env); XCTAssertNil(gone, "the last reference gone, the object is gone")
        let after = await scheduler.snapshot().rows
        XCTAssertNil(after.first { $0.media == owned("y") }); XCTAssertEqual(after.count, 2)
        let remaining = objectDirectories(env); XCTAssertEqual(remaining, 2)
    }

    func testAManualPinSurvivesEveryCollectionChange() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let kit = try env.realStore(); defer { Task { try? await kit.1.destroyIsolatedTestKeychain() } }
        let (scheduler, _) = try await rig(env, store: kit, names: ["x"])
        let list = try ServiceID("owned-playlist-1")
        _ = await scheduler.setCollection(list, title: "One", members: [owned("x")], downloading: true); await scheduler.settleBounded()
        _ = await scheduler.download(owned("x"), title: "x"); await scheduler.settleBounded()       // the person also downloads it by hand
        let pinned = try await scheduler.onlyRow()
        XCTAssertTrue(pinned.pinned); XCTAssertEqual(pinned.referenceCount, 2)
        _ = await scheduler.reconcileCollection(list, members: [])
        let afterRemoval = await retained(kit.0, "x", env); XCTAssertEqual(afterRemoval, 3 * 1024, "the pin keeps it when the playlist drops it")
        _ = await scheduler.setCollection(list, title: "One", members: [], downloading: false)
        let afterOff = await retained(kit.0, "x", env); XCTAssertEqual(afterOff, 3 * 1024, "switching the playlist's download off keeps the pinned item")
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.referenceCount, 1); XCTAssertEqual(row.actions, [.remove])
        // Removing the download by hand finally deletes it.
        _ = await scheduler.perform(.remove, job: row.id)
        let deleted = await retained(kit.0, "x", env); XCTAssertNil(deleted)
        let rows = await scheduler.snapshot().rows; XCTAssertTrue(rows.isEmpty)
    }

    func testPinningAndUnpinningKeepsTheStoreConsistent() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let kit = try env.realStore(); defer { Task { try? await kit.1.destroyIsolatedTestKeychain() } }
        let (scheduler, _) = try await rig(env, store: kit, names: ["x"])
        let list = try ServiceID("owned-playlist-1")
        _ = await scheduler.setCollection(list, title: "One", members: [owned("x")], downloading: true); await scheduler.settleBounded()
        var row = try await scheduler.onlyRow()
        XCTAssertFalse(row.pinned); XCTAssertTrue(row.actions.contains(.pin))
        let pinResult = await scheduler.perform(.pin, job: row.id); XCTAssertEqual(pinResult, .done)
        row = try await scheduler.onlyRow(); XCTAssertTrue(row.pinned); XCTAssertTrue(row.actions.contains(.unpin))
        XCTAssertEqual(row.referenceCount, 2)
        _ = await scheduler.reconcileCollection(list, members: [])
        let kept = await retained(kit.0, "x", env); XCTAssertEqual(kept, 3 * 1024)
        row = try await scheduler.onlyRow(); XCTAssertEqual(row.actions, [.remove], "a pin that is the only reference offers Remove, not Unpin")
        // Pinned only; unpin is refused because it would delete (that is Remove's job and it says so).
        let unpinResult = await scheduler.perform(.unpin, job: row.id); XCTAssertEqual(unpinResult, .refused(.invalidInput(.invalidTransition)))
    }

    func testNewMembersJoinTheQueueAndAHandRemovedMemberStaysOut() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let kit = try env.realStore(); defer { Task { try? await kit.1.destroyIsolatedTestKeychain() } }
        let (scheduler, source) = try await rig(env, store: kit, names: ["x", "y", "z"])
        let list = try ServiceID("owned-playlist-1")
        _ = await scheduler.setCollection(list, title: "One", members: [owned("x")], downloading: true); await scheduler.settleBounded()
        var count = await scheduler.snapshot().rows.count; XCTAssertEqual(count, 1)
        _ = await scheduler.reconcileCollection(list, members: [owned("x"), owned("y"), owned("y"), owned("z")]); await scheduler.settleBounded()
        let rows = await scheduler.snapshot().rows
        XCTAssertEqual(rows.count, 3, "new entries join the queue once, duplicates collapse")
        XCTAssertEqual(rows.filter { $0.phase == .available }.count, 3)
        let reads = await source.readLog.filter { $0.media == "owned-x" }; XCTAssertEqual(reads.count, 3, "x was not fetched again when the playlist changed")
        // The person removes z by hand; the playlist still lists it, but it stays out until it leaves and rejoins.
        let z = try XCTUnwrap(rows.first { $0.media == owned("z") })
        _ = await scheduler.perform(.remove, job: z.id)
        _ = await scheduler.reconcileCollection(list, members: [owned("x"), owned("y"), owned("z")]); await scheduler.settleBounded()
        count = await scheduler.snapshot().rows.count; XCTAssertEqual(count, 2, "a hand-removed song does not come back")
        _ = await scheduler.reconcileCollection(list, members: [owned("x"), owned("y")])
        _ = await scheduler.reconcileCollection(list, members: [owned("x"), owned("y"), owned("z")]); await scheduler.settleBounded()
        count = await scheduler.snapshot().rows.count; XCTAssertEqual(count, 3, "it rejoins after leaving the playlist")
    }

    func testReferencesSurviveARestartAndStillBalance() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let kit = try env.realStore(); defer { Task { try? await kit.1.destroyIsolatedTestKeychain() } }
        let (first, source) = try await rig(env, store: kit, names: ["x"])
        let p1 = try ServiceID("owned-playlist-1"), p2 = try ServiceID("owned-playlist-2")
        _ = await first.setCollection(p1, title: "One", members: [owned("x")], downloading: true)
        _ = await first.setCollection(p2, title: "Two", members: [owned("x")], downloading: true); await first.settleBounded(); await first.quit()
        let second = try env.makeScheduler(source: source, sink: kit.2)
        await second.bind(env.context)
        _ = await second.reconcileCollection(p1, members: [])
        let still = await retained(kit.0, "x", env); XCTAssertEqual(still, 3 * 1024, "the second playlist's reference came back from the ledger")
        _ = await second.reconcileCollection(p2, members: [])
        let gone = await retained(kit.0, "x", env); XCTAssertNil(gone)
    }

    func testDownloadedBytesAreExactlyTheSourceBytesAndLeaveNoCleartext() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let kit = try env.realStore(); defer { Task { try? await kit.1.destroyIsolatedTestKeychain() } }
        let data = payload(200 * 1024 + 11)
        let source = FakeSource(wall: env.wall); await source.set(owned("big"), .init(bytes: data, variant: "ret-big"))
        let scheduler = try env.makeScheduler(source: source, sink: kit.2, configuration: .init(chunkBytes: 32 * 1024, persistEveryChunks: 2, minimumBudget: 1024))
        await scheduler.bind(env.context)
        _ = await scheduler.download(owned("big"), title: "Big"); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.phase, .available)
        let bytes = try await kit.0.read(variant: "ret-big", offset: 0, count: 64 * 1024, context: env.context); XCTAssertEqual(bytes, data.prefix(64 * 1024))
        let tail = try await kit.0.read(variant: "ret-big", offset: 192 * 1024, count: 8 * 1024 + 11, context: env.context); XCTAssertEqual(tail, data.suffix(8 * 1024 + 11))
        XCTAssertTrue(env.stagingFiles().isEmpty, "the cleartext staging copy is gone once the encrypted object exists")
        // Nothing on disk under the object root contains the plaintext.
        let marker = data.subdata(in: 4096..<4160)
        for file in regularFiles(under: env.objectsURL) {
            XCTAssertNil(try Data(contentsOf: file).range(of: marker), "\(file.lastPathComponent) holds no plaintext")
        }
        XCTAssertFalse(regularFiles(under: env.objectsURL).isEmpty)
    }

    /// Owned bundled media: the full path from the real bundled signal to the encrypted store and back.
    func testTheBundledOwnedSignalDownloadsIntoTheEncryptedStoreByItsOwnIdentifier() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let kit = try env.realStore(); defer { Task { try? await kit.1.destroyIsolatedTestKeychain() } }
        let ownedContext = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
        let media = OwnedMedia.items[0]
        let url = try await OwnedMedia().asset(for: MediaVariant(id: media, codec: "PCM", container: "WAVE", bitrate: nil, sampleRate: nil, expiresAt: nil, seekable: true, authorization: ID("owned-bundle-only")),
                                              context: PlaybackContext(request: ownedContext, generation: 1, occurrenceID: nil, route: nil))
        let source = LocalFileDownloadSource(issuer: "Owned synthetic signal license", exactVariant: true) { _ in url }
        let scheduler = try DownloadScheduler(ledgerRoot: env.ledgerURL, sink: kit.2, sources: [.owned: source], wall: SystemWallClock(), volume: env.volume,
                                              configuration: .init(chunkBytes: 64 * 1024, persistEveryChunks: 4, minimumBudget: 1024), wake: WakeRecorder().scheduler)
        await scheduler.bind(ownedContext)
        let result = await scheduler.download(media, title: "Owned signal A"); XCTAssertEqual(result, .done)
        await scheduler.settleBounded()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.phase, .available)
        let original = try Data(contentsOf: url)
        let length = try await kit.0.length(variant: media.rawValue, context: ownedContext); XCTAssertEqual(length, original.count)
        let head = try await kit.0.read(variant: media.rawValue, offset: 0, count: 4096, context: ownedContext); XCTAssertEqual(head, original.prefix(4096))
        let entitlement = try await kit.0.validateEntitlement(media, context: ownedContext).outcome.get()
        XCTAssertTrue(entitlement.rights.isSuperset(of: [.play, .retain]))
        XCTAssertEqual(entitlement.source, "Owned synthetic signal license", "the stored grant is the source's stated permission, not an invented one")
    }

    /// Defence in depth: even a ledger whose pin flag survived without its manual reference never loses the item to a playlist change.
    func testAPinFlagAloneStillProtectsAnItemFromAPlaylistChange() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let kit = try env.realStore(); defer { Task { try? await kit.1.destroyIsolatedTestKeychain() } }
        let (first, source) = try await rig(env, store: kit, names: ["x"])
        let list = try ServiceID("owned-playlist-1")
        _ = await first.setCollection(list, title: "One", members: [owned("x")], downloading: true); await first.settleBounded(); await first.quit()
        // Damage: the ledger says pinned, but the "manual" reference is missing.
        let path = env.ledgerURL.appendingPathComponent(DownloadLedgerNames.directory(env.account)).appendingPathComponent("ledger.json")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]]); jobs[0]["pinned"] = true
        XCTAssertEqual(jobs[0]["references"] as? [String], ["collection:owned-playlist-1"])
        object["jobs"] = jobs; try JSONSerialization.data(withJSONObject: object).write(to: path)
        let second = try env.makeScheduler(source: source, sink: kit.2)
        await second.bind(env.context)
        _ = await second.reconcileCollection(list, members: [])
        let kept = await retained(kit.0, "x", env)
        XCTAssertEqual(kept, 3 * 1024, "the pin flag alone keeps the item")
        let rows = await second.snapshot().rows; XCTAssertEqual(rows.count, 1)
    }
}
