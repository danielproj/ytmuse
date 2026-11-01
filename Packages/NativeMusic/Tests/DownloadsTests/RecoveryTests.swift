import XCTest
import Foundation
import Domain
import Downloads
import AccountSession

/// T15.5 — expired URL, full disk, corrupt bytes, missing key, account revoke and the quit checkpoint each have a
/// bounded, correct recovery.
final class RecoveryTests: XCTestCase, @unchecked Sendable {
    private let item = owned("song")

    private func rig(_ env: Env, bytes: Data, sink: MemorySink = MemorySink(), published: String? = nil, served: Data? = nil, configuration: DownloadScheduler.Configuration = .init(chunkBytes: 1024, persistEveryChunks: 1, minimumBudget: 1024)) async throws -> (DownloadScheduler, FakeSource, MemorySink) {
        let source = FakeSource(wall: env.wall)
        await source.set(item, .init(bytes: bytes, publishedSHA256: published, servedBytes: served))
        let scheduler = try env.makeScheduler(source: source, sink: sink, configuration: configuration)
        await scheduler.bind(env.context)
        return (scheduler, source, sink)
    }

    // MARK: Expired URL

    func testAnExpiredAddressIsResolvedAgainAndTheTransferContinuesFromItsRanges() async throws {
        let env = try Env(); defer { env.cleanup() }
        let data = payload(8 * 1024)
        let (scheduler, source, sink) = try await rig(env, bytes: data)
        await source.failRead(number: 4, with: .urlExpired)
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.phase, .available)
        let stored = await sink.bytes("variant-1"); XCTAssertEqual(stored, data)
        let describes = await source.describes; XCTAssertEqual(describes, 2, "one resolve, one re-resolve")
        let offsets = await source.readLog.map(\.offset)
        XCTAssertEqual(offsets, (0..<8).map { Int64($0 * 1024) }, "no range was fetched twice: the transfer continued where it stopped")
    }
    func testASourceThatAlwaysExpiresIsBoundedAndBacksOff() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, _) = try await rig(env, bytes: payload(4096))
        await source.failEveryRead(with: .urlExpired)
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let describes = await source.describes
        XCTAssertLessThanOrEqual(describes, 5, "a bounded number of re-resolves (initial + 3 refreshes + the backoff attempt)")
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.phase, .queued); XCTAssertNotNil(row.retryAt, "then it waits with a backoff instead of spinning")
    }
    func testASourceThatNowDescribesDifferentBytesNeverAppendsToTheOldPartial() async throws {
        let env = try Env(); defer { env.cleanup() }
        let v1 = payload(6 * 1024, seed: 11), v2 = payload(6 * 1024, seed: 12)
        let (scheduler, source, sink) = try await rig(env, bytes: v1)
        await source.holdAfter(reads: 2)
        _ = await scheduler.download(item, title: "Song")
        await source.waitUntilBlocked()
        await source.update(item) { $0.bytes = v2; $0.variant = "variant-2"; $0.validator = "v2" }
        await source.release(); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.phase, .available)
        let stored = await sink.bytes("variant-2"); XCTAssertEqual(stored, v2, "the finished object is the new variant only")
        let old = await sink.has("variant-1"); XCTAssertFalse(old)
    }

    // MARK: Full disk

    func testTheVolumeReserveStopsTheTransferAndFreeingSpaceResumesIt() async throws {
        let env = try Env(); defer { env.cleanup() }
        let gib = DownloadPolicy.gibibyte
        env.volume.set(total: 1000 * gib, available: 50 * gib + 1024)                  // reserve is 50 GiB: only ~1 KiB of headroom
        let (scheduler, _, sink) = try await rig(env, bytes: payload(4096))
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.phase, .paused); XCTAssertEqual(row.pauseCause, .volumeReserve, "never writes into the reserve")
        let snapshot = await scheduler.snapshot()
        XCTAssertTrue(snapshot.storageChoices.contains(.freeDiskSpace))
        let none = await sink.count; XCTAssertEqual(none, 0)
        env.volume.set(available: 400 * gib); await scheduler.volumeSpaceChanged(); await scheduler.settleBounded()
        let done = try await scheduler.onlyRow(); XCTAssertEqual(done.phase, .available)
    }
    func testAnOutOfSpaceErrorFromTheStorePausesWithAResumeAction() async throws {
        let env = try Env(); defer { env.cleanup() }
        let sink = MemorySink(); await sink.setRetainError(OfflineRecovery.storageFull)
        let data = payload(3 * 1024)
        let (scheduler, _, _) = try await rig(env, bytes: data, sink: sink)
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.phase, .paused); XCTAssertEqual(row.pauseCause, .diskFull); XCTAssertTrue(row.actions.contains(.resume))
        XCTAssertEqual(row.progress.completedBytes, 3 * 1024, "the transferred ranges are kept; only validation/import must be repeated")
        await sink.setRetainError(nil)
        _ = await scheduler.perform(.resume, job: row.id); await scheduler.settleBounded()
        let done = try await scheduler.onlyRow(); XCTAssertEqual(done.phase, .available)
        let stored = await sink.bytes("variant-1"); XCTAssertEqual(stored, data)
    }

    // MARK: Corrupt bytes

    func testCorruptBytesRestartOnceThenFailWithDownloadAgainAndKeepNothing() async throws {
        let env = try Env(); defer { env.cleanup() }
        let good = payload(4096, seed: 21)
        var bad = good; bad[100] ^= 0xFF
        let (scheduler, source, sink) = try await rig(env, bytes: good, published: sha(good), served: bad)
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.phase, .failed); XCTAssertEqual(row.failure, .corruptBytes)
        XCTAssertEqual(row.actions, [.downloadAgain, .remove])
        let none = await sink.count; XCTAssertEqual(none, 0, "a copy that failed its digest is never exposed as available")
        XCTAssertTrue(env.stagingFiles().isEmpty, "the corrupt partial is deleted")
        let total = await source.readLog.count; XCTAssertEqual(total, 8, "the corrupt transfer was restarted exactly once (2 × 4 chunks)")
        // The source is fixed; Download Again starts over cleanly and the digest now matches.
        await source.update(item) { $0.servedBytes = nil }
        _ = await scheduler.perform(.downloadAgain, job: row.id); await scheduler.settleBounded()
        let fixed = try await scheduler.onlyRow(); XCTAssertEqual(fixed.phase, .available)
        let stored = await sink.bytes("variant-1"); XCTAssertEqual(stored, good)
    }
    func testAStoredCopyThatNoLongerVerifiesIsReportedNeverHidden() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, _, sink) = try await rig(env, bytes: payload(2048))
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        await sink.setLengthError(OfflineRecovery.redownload)
        await scheduler.auditRetained()
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.phase, .failed); XCTAssertEqual(row.failure, .corruptBytes); XCTAssertTrue(row.actions.contains(.downloadAgain))
    }

    // MARK: Missing key

    func testAMissingKeyIsAnExplicitFailureWithoutARetryLoop() async throws {
        let env = try Env(); defer { env.cleanup() }
        let sink = MemorySink(); await sink.setRetainError(OfflineRecovery.missingKey)
        let (scheduler, source, _) = try await rig(env, bytes: payload(2048), sink: sink)
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.phase, .failed); XCTAssertEqual(row.failure, .missingKey)
        XCTAssertEqual(row.actions, [.downloadAgain, .remove], "a lost key cannot be retried: the item is fetched again under a new key")
        XCTAssertNil(row.retryAt)
        let reads = await source.readLog.count; XCTAssertEqual(reads, 2)
        XCTAssertTrue(env.stagingFiles().isEmpty)
    }
    func testAnAvailableItemWhoseKeyDisappearedIsFlaggedByTheAudit() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, _, sink) = try await rig(env, bytes: payload(2048))
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        await sink.setLengthError(OfflineRecovery.missingKey)
        await scheduler.auditRetained()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.failure, .missingKey)
    }

    // MARK: Account revoke and removal

    func testRevokingTheAccountStopsEverythingRemovesPartialsAndNeverTouchesAnotherAccount() async throws {
        let env = try Env(); defer { env.cleanup() }
        let sink = MemorySink()
        let source = FakeSource(wall: env.wall)
        let other = owned("other"), mine = item
        await source.set(other, .init(bytes: payload(2048, seed: 9), variant: "other-v")); await source.set(mine, .init(bytes: payload(8 * 1024), variant: "mine-v"))
        let theirs = try env.makeScheduler(source: source, sink: sink)
        await theirs.bind(env.context(for: env.otherAccount))
        _ = await theirs.download(other, title: "Theirs"); await theirs.settleBounded(); await theirs.quit()
        let scheduler = try env.makeScheduler(source: source, sink: sink)
        await scheduler.bind(env.context)
        await source.holdAfter(reads: 2)
        _ = await scheduler.download(mine, title: "Mine")
        await source.waitUntilBlocked()
        XCTAssertFalse(env.stagingFiles().isEmpty, "a partial exists before the revoke")
        await scheduler.accountRevoked()
        await source.release()
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.phase, .failed); XCTAssertEqual(row.failure, .accountRevoked); XCTAssertEqual(row.actions, [.remove])
        XCTAssertTrue(env.stagingFiles().isEmpty, "partial cleartext is removed on revoke")
        let active = await scheduler.snapshot().activeCount; XCTAssertEqual(active, 0)
        let kept = await sink.has("other-v"); XCTAssertTrue(kept, "the other account's object is untouched")
        // The other account's ledger is intact and still its own.
        let again = try env.makeScheduler(source: source, sink: sink)
        await again.bind(env.context(for: env.otherAccount))
        let theirRow = try await again.onlyRow(); XCTAssertEqual(theirRow.phase, .available); XCTAssertEqual(theirRow.title, "Theirs")
    }
    func testRemovingTheLocalAccountDeletesItsLedgerAndStagingOnly() async throws {
        let env = try Env(); defer { env.cleanup() }
        let sink = MemorySink()
        let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: payload(8 * 1024)))
        let a = try env.makeScheduler(source: source, sink: sink)
        await a.bind(env.context)
        await source.holdAfter(reads: 2)
        _ = await a.download(item, title: "Song"); await source.waitUntilBlocked()
        try await a.removeLocal(env.account, context: RequestContext(account: nil, accountGeneration: 2, requestGeneration: 0))
        await source.release()
        let directory = env.ledgerURL.appendingPathComponent(DownloadLedgerNames.directory(env.account))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "ledger and any cleartext staging for the removed account are gone")
        let snapshot = await a.snapshot(); XCTAssertTrue(snapshot.rows.isEmpty); XCTAssertFalse(snapshot.hasAccount)
    }
    func testAStaleGenerationCannotRebindAnAccount() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, _, sink) = try await rig(env, bytes: payload(2048))
        await scheduler.bind(env.context(for: env.account, generation: 5))
        await scheduler.bind(env.context(for: env.account, generation: 2))        // an older owner
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let bound = await sink.boundContext; XCTAssertEqual(bound?.accountGeneration, 5, "the newer generation stays authoritative")
    }

    // MARK: Safe quit

    func testQuitCheckpointsInFlightWorkIsBoundedAndLeavesNothingRunning() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, _) = try await rig(env, bytes: payload(8 * 1024), configuration: .init(chunkBytes: 1024, persistEveryChunks: 100, quitTimeout: .milliseconds(200), minimumBudget: 1024))
        await source.holdAfter(reads: 3)
        _ = await scheduler.download(item, title: "Song")
        await source.waitUntilBlocked()
        let started = ContinuousClock.now
        await scheduler.quit()
        XCTAssertLessThan(started.duration(to: .now), .seconds(2), "quit is bounded")
        let quiescent = await scheduler.isQuiescent; XCTAssertTrue(quiescent, "an explicitly quit app keeps no download running")
        await source.release()
        try await Task.sleep(for: .milliseconds(50))
        let reads = await source.readLog.count; XCTAssertEqual(reads, 3, "nothing was fetched after quit")
        // The ledger holds the checkpoint even though ranges were only auto-persisted every 100 chunks.
        await source.holdAfter(reads: 0)
        let next = try env.makeScheduler(source: source, sink: MemorySink())
        await next.bind(env.context)
        await source.waitUntilBlocked()
        let row = try await next.onlyRow()
        XCTAssertEqual(row.progress.completedBytes, 3 * 1024, "the checkpoint recorded the three fetched ranges")
        await source.release(); await next.quit()
    }
    func testQuitIsStillBoundedWhenASourceIgnoresCancellation() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, _) = try await rig(env, bytes: payload(8 * 1024), configuration: .init(chunkBytes: 1024, persistEveryChunks: 1, quitTimeout: .milliseconds(150), minimumBudget: 1024))
        await source.ignoreCancellationWhileHeld(true); await source.holdAfter(reads: 2)
        _ = await scheduler.download(item, title: "Song")
        await source.waitUntilBlocked()
        let started = ContinuousClock.now
        await scheduler.quit()
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        await source.release()
        try await Task.sleep(for: .milliseconds(80))
        // The read that was already in flight may complete on the source's side; the scheduler starts no new read and writes nothing.
        let reads = await source.readLog.count; XCTAssertLessThanOrEqual(reads, 3, "no new read after quit")
        await source.holdAfter(reads: 0)
        let next = try env.makeScheduler(source: source, sink: MemorySink())
        await next.bind(env.context)
        await source.waitUntilBlocked()
        let row = try await next.onlyRow()
        XCTAssertEqual(row.progress.completedBytes, 2 * 1024, "the late return was not recorded: the checkpoint stands")
        await source.release(); await next.quit()
    }
    /// The ranges recorded since the last periodic write exist only in memory; quit's own checkpoint must save them even when
    /// the source ignores cancellation and the transfer had to be halted.
    func testQuitSavesRangesThatWereOnlyInMemoryEvenWhenTheSourceIgnoresCancellation() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, _) = try await rig(env, bytes: payload(8 * 1024), configuration: .init(chunkBytes: 1024, persistEveryChunks: 100, quitTimeout: .milliseconds(100), minimumBudget: 1024))
        await source.ignoreCancellationWhileHeld(true); await source.holdAfter(reads: 3)
        _ = await scheduler.download(item, title: "Song")
        await source.waitUntilBlocked()
        await scheduler.quit()
        await source.release()                     // the halted transfer's late read returns and must write nothing
        await source.holdAfter(reads: 0)           // the next launch is observed while its first read is held
        let next = try env.makeScheduler(source: source, sink: MemorySink())
        await next.bind(env.context)
        await source.waitUntilBlocked()
        let row = try await next.onlyRow()
        XCTAssertEqual(row.progress.completedBytes, 3 * 1024, "the three fetched ranges were saved by the quit checkpoint")
        await source.release(); await next.quit()
    }
    func testWorkInterruptedByQuitResumesOnNextLaunchWithoutAUserAction() async throws {
        let env = try Env(); defer { env.cleanup() }
        let data = payload(6 * 1024)
        let (scheduler, source, sink) = try await rig(env, bytes: data)
        await source.holdAfter(reads: 2)
        _ = await scheduler.download(item, title: "Song"); await source.waitUntilBlocked()
        await scheduler.quit(); await source.release()
        let next = try env.makeScheduler(source: source, sink: sink)
        await next.bind(env.context); await next.settleBounded()
        let row = try await next.onlyRow(); XCTAssertEqual(row.phase, .available)
        let stored = await sink.bytes("variant-1"); XCTAssertEqual(stored, data)
    }

    // MARK: Entitlement and renewal (OFF08)

    func testAGrantNearingItsEndIsRenewedAndAnExpiredOneShowsExpired() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, sink) = try await rig(env, bytes: payload(2048))
        await source.update(item) { $0.permissionLifetime = 3600; $0.renewAfter = 1800 }
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        let firstExpiry = try await scheduler.onlyRow().expiresAt
        env.manual.advance(2000); await scheduler.renewalSweep()
        let renewed = try await scheduler.onlyRow()
        XCTAssertEqual(renewed.phase, .available); XCTAssertGreaterThan(renewed.expiresAt ?? .distantPast, firstExpiry ?? .distantFuture, "renewal extends the stated expiry, no invented lifetime")
        let grant = await sink.grant("variant-1"); XCTAssertEqual(grant?.expires, renewed.expiresAt)
        // The source stops allowing it: after the stated expiry the item reads Expired with explicit actions.
        await source.failRenewal(.permissionDenied)
        env.manual.advance(8000); await scheduler.renewalSweep()
        let expired = try await scheduler.onlyRow()
        XCTAssertEqual(expired.phase, .expired); XCTAssertEqual(expired.actions, [.renew, .downloadAgain, .remove])
        await source.failRenewal(nil)
        _ = await scheduler.perform(.renew, job: expired.id)
        let back = try await scheduler.onlyRow(); XCTAssertEqual(back.phase, .available)
    }
    func testAnUnreachableSourceDoesNotExpireAGrantBeforeItsStatedEnd() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, _) = try await rig(env, bytes: payload(2048))
        await source.update(item) { $0.permissionLifetime = 3600; $0.renewAfter = 600 }
        _ = await scheduler.download(item, title: "Song"); await scheduler.settleBounded()
        await source.failRenewal(.transient(retryAfter: nil)); await source.failDescribe(.transient(retryAfter: nil))
        env.manual.advance(900); await scheduler.renewalSweep()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.phase, .available, "still inside the stated validity, so still usable")
    }
}
