import XCTest
import Foundation
import Domain
import Queue
import Features
import AccountSession
@testable import Downloads
@testable import Playback

actor MemoryAccountDirectory: AccountDirectoryStore {
    var value = AccountDirectory()
    func load() -> AccountDirectory { value }
    func save(_ directory: AccountDirectory) { value = directory }
}

/// W15 rework 1 (critic review at 4afa885f): progress ranges never outlive their bytes, sign-out removes cleartext partials through
/// the real lifecycle, the Smart cap holds under concurrent starts, slots are not leaked, and renewal/ledger/eligibility details.
final class ReworkTests: XCTestCase, @unchecked Sendable {
    private let item = owned("song")
    private func rig(_ env: Env, bytes: Data, sink: MemorySink = MemorySink(), configuration: DownloadScheduler.Configuration = .init(chunkBytes: 1024, persistEveryChunks: 1, minimumBudget: 1024)) async throws -> (DownloadScheduler, FakeSource, MemorySink) {
        let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: bytes))
        let scheduler = try env.makeScheduler(source: source, sink: sink, configuration: configuration)
        await scheduler.bind(env.context)
        return (scheduler, source, sink)
    }

    // MARK: F1 — ranges never outlive their bytes

    /// Critic probe P1: a recoverable "source unavailable" mid-transfer, then Try Again.
    func testTryAgainAfterSourceUnavailableStoresTheRealBytesNotAZeroFilledPrefix() async throws {
        let env = try Env(); defer { env.cleanup() }
        let data = payload(8 * 1024, seed: 31)
        let (scheduler, source, sink) = try await rig(env, bytes: data)
        await source.failRead(number: 5, with: .unavailable)
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let failed = try await scheduler.onlyRow()
        XCTAssertEqual(failed.phase, .failed); XCTAssertEqual(failed.failure, .sourceUnavailable)
        XCTAssertEqual(failed.progress.completedBytes, 0, "the deleted staging bytes take their ranges with them")
        XCTAssertTrue(env.stagingFiles().isEmpty)
        _ = await scheduler.perform(.retry, job: failed.id); await scheduler.settleBounded()
        let done = try await scheduler.onlyRow(); XCTAssertEqual(done.phase, .available)
        let stored = await sink.bytes("variant-1"); XCTAssertEqual(stored, data, "every byte, from byte 0")
        let offsets = await source.readLog.map(\.offset)
        XCTAssertEqual(Array(offsets.suffix(8)), (0..<8).map { Int64($0 * 1024) }, "the retry fetched the whole file again")
    }
    /// Critic probe P1b: the same, across a relaunch before Try Again.
    func testTheSameAcrossARelaunch() async throws {
        let env = try Env(); defer { env.cleanup() }
        let data = payload(8 * 1024, seed: 32)
        let (first, source, sink) = try await rig(env, bytes: data)
        await source.failRead(number: 5, with: .unavailable)
        _ = await first.download(item, title: "Song"); await first.settleBounded(); await first.quit()
        let second = try env.makeScheduler(source: source, sink: sink)
        await second.bind(env.context)
        let row = try await second.onlyRow()
        XCTAssertEqual(row.phase, .failed); XCTAssertEqual(row.progress.completedBytes, 0, "the failed job carries no ranges across the relaunch")
        _ = await second.perform(.retry, job: row.id); await second.settleBounded()
        let stored = await sink.bytes("variant-1"); XCTAssertEqual(stored, data)
    }
    /// Critic probe P1c: the REAL local-file source; the picked file is moved away and back mid-transfer (same inode, size, mtime).
    func testARealPickedFileMovedAwayAndBackMidTransferIsKeptWholeNotWithAHole() async throws {
        let env = try Env(); defer { env.cleanup() }
        let data = payload(6 * 1024, seed: 33)
        let url = env.root.appendingPathComponent("pick.wav"); try data.write(to: url)
        let away = env.root.appendingPathComponent("pick-away.wav")
        let sink = MemorySink()
        let gate = GatedLocalSource(real: LocalFileDownloadSource(issuer: "File chosen on this Mac", wall: env.wall))
        let scheduler = try DownloadScheduler(ledgerRoot: env.ledgerURL, sink: sink, sources: [.localFile: gate], wall: env.wall, volume: env.volume,
                                              configuration: .init(chunkBytes: 1024, persistEveryChunks: 1, minimumBudget: 1024), wake: WakeRecorder().scheduler)
        await scheduler.bind(env.context)
        let id = try ServiceID(MediaOrigin.localFilePrefix + UUID().uuidString)
        await gate.hold(after: 3)
        _ = await scheduler.download(id, title: "Pick", location: url.path)
        await gate.waitUntilBlocked()
        try FileManager.default.moveItem(at: url, to: away)       // the volume "drops"
        await gate.release(); await scheduler.settleBounded()
        let failed = try await scheduler.onlyRow(); XCTAssertEqual(failed.phase, .failed)
        try FileManager.default.moveItem(at: away, to: url)       // and comes back, same inode / size / mtime
        _ = await scheduler.perform(.retry, job: failed.id); await scheduler.settleBounded()
        let done = try await scheduler.onlyRow(); XCTAssertEqual(done.phase, .available)
        let variant = await scheduler.variantForTesting(id)
        let stored = await sink.bytes(try XCTUnwrap(variant)); XCTAssertEqual(stored, data, "no zero-filled start")
        XCTAssertEqual(try Data(contentsOf: url), data, "the source file itself is untouched")
    }
    /// A staging file that was replaced (same name, different file) holds none of the recorded ranges.
    func testAReplacedStagingFileLosesItsRangesAtRelaunch() async throws {
        let env = try Env(); defer { env.cleanup() }
        let data = payload(8 * 1024, seed: 34)
        let (first, source, sink) = try await rig(env, bytes: data)
        await source.holdAfter(reads: 3)
        _ = await first.download(item, title: "Song"); await source.waitUntilBlocked(); await first.quit(); await source.release()
        let staging = env.ledgerURL.appendingPathComponent(DownloadLedgerNames.directory(env.account)).appendingPathComponent("staging")
        let part = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: staging.path).first)
        try FileManager.default.removeItem(at: staging.appendingPathComponent(part))
        FileManager.default.createFile(atPath: staging.appendingPathComponent(part).path, contents: Data(count: 3 * 1024), attributes: [.posixPermissions: 0o600])   // zeros, right size, new file
        let second = try env.makeScheduler(source: source, sink: sink)
        await second.bind(env.context); await second.settleBounded()
        let stored = await sink.bytes("variant-1"); XCTAssertEqual(stored, data, "the zero-filled replacement was not trusted")
    }
    /// The same file swap while the app keeps running (pause, replace, resume): no relaunch to catch it, so the open must.
    func testAStagingFileReplacedWhilePausedLosesItsRangesWithoutARelaunch() async throws {
        let env = try Env(); defer { env.cleanup() }
        let data = payload(8 * 1024, seed: 39)
        let (scheduler, source, sink) = try await rig(env, bytes: data)
        await source.holdAfter(reads: 3)
        _ = await scheduler.download(item, title: "Song"); await source.waitUntilBlocked()
        let row = try await scheduler.onlyRow()
        _ = await scheduler.perform(.pause, job: row.id); await source.release()
        let staging = env.ledgerURL.appendingPathComponent(DownloadLedgerNames.directory(env.account)).appendingPathComponent("staging")
        let part = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: staging.path).first)
        try FileManager.default.removeItem(at: staging.appendingPathComponent(part))
        FileManager.default.createFile(atPath: staging.appendingPathComponent(part).path, contents: Data(count: 3 * 1024), attributes: [.posixPermissions: 0o600])
        _ = await scheduler.perform(.resume, job: row.id); await scheduler.settleBounded()
        let stored = await sink.bytes("variant-1"); XCTAssertEqual(stored, data, "the replacement file's zeros were not trusted")
    }
    /// A finished copy is checked against what the source really holds; complete-looking ranges over a hole are corrupt.
    func testACompleteLookingCopyThatDiffersFromTheSourceIsRejected() async throws {
        let env = try Env(); defer { env.cleanup() }
        let good = payload(4096, seed: 35); var hole = good; for i in 0..<1024 { hole[i] = 0 }
        let source = FakeSource(wall: env.wall)
        await source.set(item, .init(bytes: good, servedBytes: hole, digestFromSource: true))
        let sink = MemorySink()
        let scheduler = try env.makeScheduler(source: source, sink: sink)
        await scheduler.bind(env.context)
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.phase, .failed); XCTAssertEqual(row.failure, .corruptBytes)
        let none = await sink.count; XCTAssertEqual(none, 0, "nothing was exposed as Downloaded")
    }
    /// The object the store holds must be what was staged and checked.
    func testAStoreThatReturnsADifferentHashFromWhatWasStagedIsCorrupt() async throws {
        let env = try Env(); defer { env.cleanup() }
        let sink = HashLyingSink()
        let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: payload(2048, seed: 36)))
        let scheduler = try env.makeScheduler(source: source, sink: sink)
        await scheduler.bind(env.context)
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.phase, .failed); XCTAssertEqual(row.failure, .corruptBytes)
    }

    // MARK: F2 — sign-out through the real lifecycle

    func testSigningOutThroughTheRealLifecycleRemovesCleartextPartialsAndAKeylessCopyIsNeverDownloaded() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let kit = try env.realStore(); defer { Task { try? await kit.vault.destroyIsolatedTestKeychain() } }
        let data = payload(6 * 1024, seed: 37)
        let source = FakeSource(wall: env.wall)
        let kept = owned("kept"), partial = owned("partial")
        await source.set(kept, .init(bytes: payload(3 * 1024, seed: 38), variant: "kept-v")); await source.set(partial, .init(bytes: data, variant: "partial-v"))
        let scheduler = try env.makeScheduler(source: source, sink: kit.sink)
        let directory = MemoryAccountDirectory()
        let lifecycle = try await AccountLifecycle.open(vault: kit.vault, store: directory, participants: [scheduler])
        let account = try Account(id: env.account.accountID, serviceIdentity: ServiceID("w15-test"), context: env.account, displayName: "W15", credential: nil)
        let challenge = try await lifecycle.beginAuthentication()
        do { try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("synthetic-disposable-session".utf8)) } catch { XCTFail("completeAuthentication threw \(error)"); throw error }
        try await lifecycle.switchIdentity(to: env.account)
        let bound = await scheduler.snapshot().hasAccount; XCTAssertTrue(bound, "the lifecycle bound the engine")
        _ = await scheduler.download(kept, title: "Kept"); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.phase, .available)
        await source.holdAfter(reads: 4)
        _ = await scheduler.download(partial, title: "Partial"); await source.waitUntilBlocked()
        XCTAssertFalse(env.stagingFiles().isEmpty, "a cleartext partial exists before sign-out")
        try await lifecycle.signOut(env.account)
        await source.release()
        XCTAssertTrue(env.stagingFiles().isEmpty, "sign-out removed the cleartext partial")
        let after = await scheduler.snapshot(); XCTAssertFalse(after.hasAccount, "nothing of the signed-out account is shown")
        // A relaunch: a fresh engine on the same data, the account's keys erased by sign-out. The kept copy must not read Downloaded.
        let store2 = try EncryptedStore(root: env.objectsURL, vault: kit.vault)
        let relaunched = try env.makeScheduler(source: source, sink: EncryptedStoreSink(store: store2))
        await relaunched.bind(env.context)
        let rows = await relaunched.snapshot().rows
        XCTAssertFalse(rows.contains { $0.phase == .available }, "a copy whose key is gone is never shown as Downloaded: \(rows.map { ($0.title, $0.phase) })")
        let keptRow = try XCTUnwrap(rows.first { $0.title == "Kept" }, "the copy is still listed, but not as Downloaded")
        XCTAssertEqual(keptRow.phase, .failed); XCTAssertTrue([.missingKey, .corruptBytes].contains(keptRow.failure), "\(String(describing: keptRow.failure))")
        XCTAssertTrue(keptRow.actions.contains(.downloadAgain) && !keptRow.actions.contains(.play))
        await relaunched.quit()
    }
    /// The same expectation for a sign-out seen only at the next launch (identity restored as signed out).
    func testARestoredSignedOutIdentityPurgesItsLedgerAndStaging() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (first, source, sink) = try await rig(env, bytes: payload(8 * 1024))
        await source.holdAfter(reads: 3)
        _ = await first.download(item, title: "Song"); await source.waitUntilBlocked(); await first.quit(); await source.release()
        XCTAssertFalse(env.stagingFiles().isEmpty, "a quit keeps its partial to resume")
        let second = try env.makeScheduler(source: source, sink: sink)
        let account = try Account(id: env.account.accountID, serviceIdentity: ServiceID("w15-test"), context: env.account, displayName: "W15", credential: nil)
        try await second.restorePaused(LocalIdentity(account: account, state: .signedOut), context: env.context)
        XCTAssertTrue(env.stagingFiles().isEmpty)
        await second.bind(env.context)
        let row = try await second.onlyRow(); XCTAssertEqual(row.phase, .failed); XCTAssertEqual(row.failure, .accountRevoked); XCTAssertEqual(row.progress.completedBytes, 0)
    }
    func testAnAccountSwitchDiscardsTheLeavingAccountsPartialsButAQuitKeepsThem() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, _) = try await rig(env, bytes: payload(8 * 1024))
        await source.holdAfter(reads: 3)
        _ = await scheduler.download(item, title: "Song"); await source.waitUntilBlocked()
        try await scheduler.detach(previous: env.context, barrier: RequestContext(account: nil, accountGeneration: 2, requestGeneration: 0))
        await source.release()
        XCTAssertTrue(env.stagingFiles().isEmpty)
        await scheduler.bind(env.context(for: env.account, generation: 3))
        await source.holdAfter(reads: 0); await source.waitUntilBlocked()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.progress.completedBytes, 0, "starts again from the first byte when the account returns")
        await source.release(); await scheduler.quit()
    }

    // MARK: F3 — the Smart cap under concurrent starts

    /// Critic probe P2b.
    func testTheSmartCapHoldsWhenAutomaticDownloadsStartTogether() async throws {
        let env = try Env(); defer { env.cleanup() }
        let source = FakeSource(wall: env.wall); let sink = MemorySink()
        let names = ["a", "b", "c"]
        for n in names { await source.set(owned(n), .init(bytes: payload(1024, seed: UInt8(n.utf8.first!)), variant: "auto-" + n)) }
        let scheduler = try env.makeScheduler(source: source, sink: sink)
        await scheduler.bind(env.context)
        _ = await scheduler.setBudget(bytes: 48_000); _ = await scheduler.setSmartDownloads(enabled: true)
        for n in names { _ = await scheduler.download(owned(n), title: n, request: .automatic) }
        await scheduler.settleBounded()
        let snapshot = await scheduler.snapshot()
        let stored = snapshot.rows.filter { $0.phase == .available }.reduce(0) { $0 + $1.storedBytes }
        XCTAssertLessThanOrEqual(stored, snapshot.storage.automaticCapBytes, "stored \(stored) B against a cap of \(snapshot.storage.automaticCapBytes) B")
        XCTAssertEqual(snapshot.rows.filter { $0.phase == .available }.count, 2)
        XCTAssertEqual(snapshot.rows.filter { $0.pauseCause == .smartCapReached }.count, 1)
    }
    func testPropertyTheSmartCapHoldsForRandomBudgetsSizesAndConcurrency() async throws {
        var rng: UInt64 = 0xFACADE
        func next(_ n: Int) -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int((rng >> 33) % UInt64(n)) }
        var sawPause = 0
        for round in 0..<25 {
            let env = try Env(); defer { env.cleanup() }
            let source = FakeSource(wall: env.wall); let sink = MemorySink()
            let count = 3 + next(5)
            for i in 0..<count { await source.set(owned("p\(i)"), .init(bytes: payload(512 + next(3000), seed: UInt8(i + 1)), variant: "p\(i)-v")) }
            let scheduler = try env.makeScheduler(source: source, sink: sink)
            await scheduler.bind(env.context)
            _ = await scheduler.setBudget(bytes: Int64(30_000 + next(60_000))); _ = await scheduler.setSmartDownloads(enabled: true)
            for i in 0..<count { _ = await scheduler.download(owned("p\(i)"), title: "p\(i)", request: .automatic) }
            await scheduler.settleBounded()
            let snapshot = await scheduler.snapshot()
            let stored = snapshot.rows.filter { $0.phase == .available }.reduce(0) { $0 + $1.storedBytes }
            XCTAssertLessThanOrEqual(stored, snapshot.storage.automaticCapBytes, "round \(round)")
            XCTAssertLessThanOrEqual(snapshot.storage.usedBytes, snapshot.storage.budgetBytes, "round \(round)")
            sawPause += snapshot.rows.filter { $0.pauseCause == .smartCapReached }.count
        }
        XCTAssertGreaterThan(sawPause, 0, "the property actually reached the cap")
    }

    // MARK: F5 / F6 — slots

    func testTwoCollectionMembersAndTwoAutomaticDownloadsRunAlongsideEachOther() async throws {
        for mode in ["collection", "automatic"] {
            let env = try Env(); defer { env.cleanup() }
            let source = FakeSource(wall: env.wall)
            for n in ["a", "b", "c"] { await source.set(owned(n), .init(bytes: payload(4 * 1024), variant: "v-" + n)) }
            let scheduler = try env.makeScheduler(source: source, sink: MemorySink())
            await scheduler.bind(env.context)
            await source.holdAfter(reads: 0)
            if mode == "collection" { _ = await scheduler.setCollection(try ServiceID("owned-list"), title: "L", members: [owned("a"), owned("b"), owned("c")], downloading: true) }
            else { _ = await scheduler.setBudget(bytes: 1 << 20); _ = await scheduler.setSmartDownloads(enabled: true); for n in ["a", "b", "c"] { _ = await scheduler.download(owned(n), title: n, request: .automatic) } }
            _ = await scheduler.waitFor("two running") { $0.rows.filter { $0.phase == .downloading }.count == 2 }
            let snapshot = await scheduler.snapshot()
            XCTAssertEqual(snapshot.rows.filter { $0.phase == .downloading }.count, 2, "\(mode): the second job runs alongside the first (concurrency 2)")
            XCTAssertEqual(snapshot.rows.filter { $0.phase == .queued }.count, 1)
            await source.release(); await scheduler.settleBounded()
        }
    }
    /// Mutation MC: only the item being played may take a slot from a running download.
    func testANewerManualDownloadNeverPreemptsRunningOnes() async throws {
        let env = try Env(); defer { env.cleanup() }
        let source = FakeSource(wall: env.wall)
        for n in ["a", "b", "c"] { await source.set(owned(n), .init(bytes: payload(4 * 1024), variant: "v-" + n)) }
        let scheduler = try env.makeScheduler(source: source, sink: MemorySink())
        await scheduler.bind(env.context)
        await source.holdAfter(reads: 0)
        _ = await scheduler.download(owned("a"), title: "a"); _ = await scheduler.download(owned("b"), title: "b")
        _ = await scheduler.waitFor("two running") { $0.rows.filter { $0.phase == .downloading }.count == 2 }
        _ = await scheduler.download(owned("c"), title: "c")        // newer, so ranked higher than both
        try await Task.sleep(for: .milliseconds(100))
        let rows = await scheduler.snapshot().rows
        XCTAssertEqual(rows.first { $0.media == owned("a") }?.phase, .downloading); XCTAssertEqual(rows.first { $0.media == owned("b") }?.phase, .downloading)
        XCTAssertEqual(rows.first { $0.media == owned("c") }?.phase, .queued, "it waits its turn")
        await source.release(); await scheduler.settleBounded()
        let done = await scheduler.snapshot().rows; XCTAssertTrue(done.allSatisfy { $0.phase == .available })
    }

    // MARK: F7 — renewal extends only the same bytes, for every origin

    func testRenewalNeverExtendsAGrantOnAChangedVariantForAnyOrigin() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, sink) = try await rig(env, bytes: payload(2048))
        await source.update(item) { $0.permissionLifetime = 3600; $0.renewAfter = 600 }
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let before = await sink.grant("variant-1")
        await source.update(item) { $0.variant = "variant-2"; $0.validator = "v2" }       // the source now describes different bytes
        env.manual.advance(900); await scheduler.renewalSweep()
        let after = await sink.grant("variant-1")
        XCTAssertEqual(after?.expires, before?.expires, "the old object's grant was not extended on behalf of different bytes")
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.phase, .expired, "a source that now describes other bytes does not renew this copy: it reads Expired, with its grant left as it was")
    }

    // MARK: F9 — a damaged ledger keeps its retained bytes in the budget

    func testADamagedLedgerLeavesItsRetainedBytesCountingTowardTheLimit() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (first, source, sink) = try await rig(env, bytes: payload(40 * 1024))
        _ = await first.setBudget(bytes: 64 * 1024)
        _ = await first.download(item, title: "Song"); await first.settleBounded()
        let used = await first.snapshot().storage.usedBytes; XCTAssertGreaterThan(used, 40 * 1024)
        await first.quit()
        try Data("{ not a ledger".utf8).write(to: env.ledgerURL.appendingPathComponent(DownloadLedgerNames.directory(env.account)).appendingPathComponent("ledger.json"))
        let second = try env.makeScheduler(source: source, sink: sink)
        await second.bind(env.context)
        let snapshot = await second.snapshot()
        XCTAssertTrue(snapshot.rows.isEmpty)
        XCTAssertEqual(snapshot.unlistedBytes, used, "the unlisted copy still counts"); XCTAssertEqual(snapshot.storage.usedBytes, used)
        let other = owned("other"); await source.set(other, .init(bytes: payload(40 * 1024, seed: 9), variant: "other-v"))
        _ = await second.setBudget(bytes: 64 * 1024); _ = await second.download(other, title: "Other"); await second.settleBounded()
        let blocked = try await second.onlyRow(); XCTAssertEqual(blocked.pauseCause, .storageBudgetFull, "the budget cannot be exceeded by forgetting what is on disk")
        await second.quit()
        let third = try env.makeScheduler(source: source, sink: sink)           // and it survives another launch
        await third.bind(env.context)
        let again = await third.snapshot(); XCTAssertEqual(again.unlistedBytes, used)
    }

    // MARK: F4 / F10 / F11 — honest controls, the note, eligibility by kind

    func testSmartDownloadsIsNotAWorkingSwitchWhenNothingCanSuggest() async throws {
        let env = try Env(); defer { env.cleanup() }
        let scheduler = try DownloadScheduler(ledgerRoot: env.ledgerURL, sink: MemorySink(), sources: [:], wall: env.wall, volume: env.volume, wake: WakeRecorder().scheduler)
        await scheduler.bind(env.context)
        let snapshot = await scheduler.snapshot()
        XCTAssertFalse(snapshot.smartDownloadsAvailable)
        let refused = await scheduler.setSmartDownloads(enabled: true); XCTAssertEqual(refused, .refused(.unsupported), "it cannot be switched on")
        let after = await scheduler.snapshot(); XCTAssertFalse(after.smartDownloadsEnabled)
        let off = await scheduler.setSmartDownloads(enabled: false); XCTAssertEqual(off, .done)
    }
    func testNoSurfaceOffersASmartSwitchOrPromisesWhatCannotRun() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let view = try String(contentsOf: sources.appendingPathComponent("Features/Downloads/DownloadsView.swift"), encoding: .utf8)
        let text = try String(contentsOf: sources.appendingPathComponent("Features/Downloads/DownloadsText.swift"), encoding: .utf8)
        let toggle = try XCTUnwrap(view.range(of: "Toggle(isOn: Binding(get: { model.snapshot.smartDownloadsEnabled }"))
        XCTAssertTrue(view[..<toggle.lowerBound].contains("if model.snapshot.smartDownloadsAvailable {"), "the Smart switch exists only where suggestions exist")
        for forbidden in ["offline listening", "your own recordings"] { XCTAssertFalse((view + text).localizedCaseInsensitiveContains(forbidden), forbidden) }
    }
    func testTheCapabilityNoteIsWordsWithNoControlAndAppearsOnSongAndCollectionPages() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Features")
        let note = try String(contentsOf: sources.appendingPathComponent("Downloads/DownloadCapabilityNote.swift"), encoding: .utf8)
        XCTAssertFalse(note.contains("Button") || note.contains("Toggle") || note.contains("onTapGesture"), "words only")
        XCTAssertTrue(note.contains("DownloadEligibility.of(media)") && note.contains("youTubeMusicExplanation"))
        let detail = try String(contentsOf: sources.appendingPathComponent("CatalogDetails/CatalogDetailViews.swift"), encoding: .utf8)
        XCTAssertEqual(detail.components(separatedBy: "DownloadCapabilityNote(media:").count - 1, 2, "collection header and song page")
        for id in ["dQw4w9WgXcQ", "MPREb_abcdef", "VLPLxyz"] { XCTAssertEqual(DownloadEligibility.of(youtube(id)), .notOffered(.youTubeMusicNoMacDownloads), "the note shows for \(id)") }
        XCTAssertEqual(DownloadsText.youTubeMusicExplanation, "YouTube Music doesn’t offer downloads on Mac.")
    }
    func testEligibilityComesFromTheItemNotAFreeFormPrefix() {
        // A YouTube video id may begin "owned-": it is still YouTube Music.
        XCTAssertEqual(MediaOrigin.classify(youtube("owned-12345")), .youTubeMusic)
        XCTAssertEqual(DownloadEligibility.of(youtube("owned-abcdef")), .notOffered(.youTubeMusicNoMacDownloads))
        // Owned status is exactly the bundled identifiers, pinned to the media the app really ships.
        XCTAssertEqual(MediaOrigin.bundledOwnedIdentifiers, Set(OwnedMedia.items.map(\.rawValue) + [OwnedMedia.videoItem.rawValue]))
        for id in OwnedMedia.items { XCTAssertEqual(MediaOrigin.classify(id), .owned) }
    }
}

/// A store that stages and verifies but returns a hash that is not the staged content's.
actor HashLyingSink: RetentionSink {
    func retain(file: URL, variant: String, grant: RetentionGrant, reference: String, context: RequestContext) async throws {}
    func addReference(variant: String, reference: String, context: RequestContext) async throws {}
    func removeReference(variant: String, reference: String, context: RequestContext) async throws {}
    func setPinned(variant: String, pinned: Bool, context: RequestContext) async throws {}
    func retainedLength(variant: String, context: RequestContext) async throws -> Int { 2048 }
    func verify(variant: String, context: RequestContext) async throws -> String? { String(repeating: "0", count: 64) }
    func updateGrant(variant: String, grant: RetentionGrant, context: RequestContext) async throws {}
    func delete(variant: String, context: RequestContext) async throws {}
    func bind(_ context: RequestContext) async {}
}
