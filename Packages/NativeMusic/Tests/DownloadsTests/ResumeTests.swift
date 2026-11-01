import XCTest
import Foundation
import Synchronization
import Domain
import Downloads
@testable import Downloads

/// T15.1 — crash at each state then resume: one logical job, valid ranges, no mixed variants, no invented percent.
final class ResumeTests: XCTestCase, @unchecked Sendable {
    private let item = owned("song-1")

    /// Counts every persisted state and recorded range of an uninterrupted run, so the crash loop below covers all of them.
    func testCrashAtEveryPersistedStateThenResumeFinishesOneJobWithTheSourceBytes() async throws {
        let data = payload(5 * 1024 + 300)
        var total = 0
        do {
            let env = try Env(); defer { env.cleanup() }
            let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: data))
            let counter = Mutex(0)
            let scheduler = try env.makeScheduler(source: source, sink: MemorySink(), checkpoint: { _ in counter.withLock { $0 += 1 } })
            await scheduler.bind(env.context)
            _ = await scheduler.download(item, title: "One")
            await scheduler.settleBounded()
            total = counter.withLock { $0 }
            let phase = await scheduler.snapshot().rows.first?.phase; XCTAssertEqual(phase, .available)
        }
        XCTAssertGreaterThanOrEqual(total, 10, "resolving, downloading, six ranges, validating and available are all crash points")
        var durablePhases: Set<String> = []
        for crashPoint in 1...total {
            let env = try Env(); defer { env.cleanup() }
            let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: data))
            let sink = MemorySink()
            let seen = Mutex(0)
            let first = try env.makeScheduler(source: source, sink: sink, checkpoint: { _ in
                let n = seen.withLock { $0 += 1; return $0 }
                if n == crashPoint { throw SimulatedCrash() }
            })
            await first.bind(env.context)
            _ = await first.download(item, title: "One")
            await first.settleBounded()
            // The process "dies" here: a brand-new scheduler reads only what reached the disk.
            if let data = try? Data(contentsOf: env.ledgerURL.appendingPathComponent(DownloadLedgerNames.directory(env.account)).appendingPathComponent("ledger.json")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let jobs = object["jobs"] as? [[String: Any]], let phase = jobs.first?["phase"] as? String { durablePhases.insert(phase) }
            let second = try env.makeScheduler(source: source, sink: sink)
            await second.bind(env.context)
            await second.settleBounded()
            let snapshot = await second.snapshot()
            XCTAssertEqual(snapshot.rows.count, 1, "crash point \(crashPoint): one logical job, never a duplicate")
            XCTAssertEqual(snapshot.rows.first?.phase, .available, "crash point \(crashPoint)")
            let stored = await sink.bytes(await source.scripts[item.rawValue]!.variant)
            XCTAssertEqual(stored, data, "crash point \(crashPoint): exactly the source bytes")
            let variants = Set(await source.readLog.map(\.variant)); XCTAssertEqual(variants, ["variant-1"], "no mixed variants")
            XCTAssertTrue(env.stagingFiles().isEmpty, "crash point \(crashPoint): no cleartext partial left behind")
            await second.quit()
        }
        XCTAssertTrue(durablePhases.isSuperset(of: ["resolving", "downloading", "validating", "available"]), "the crashes really left the ledger in each state: \(durablePhases)")
    }

    /// Ranges already recorded are not fetched again after a restart.
    func testResumeContinuesFromRecordedRangesInsteadOfStartingOver() async throws {
        let env = try Env(); defer { env.cleanup() }
        let data = payload(8 * 1024)
        let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: data))
        let sink = MemorySink()
        let first = try env.makeScheduler(source: source, sink: sink)
        await first.bind(env.context)
        await source.holdAfter(reads: 3)
        _ = await first.download(item, title: "One")
        await source.waitUntilBlocked()
        await first.quit()
        let recorded = await first.snapshot().rows.first?.progress.completedBytes
        XCTAssertEqual(recorded, 3 * 1024, "three chunks were durably recorded before the stop")
        await source.release()
        let before = await source.readLog.count
        let second = try env.makeScheduler(source: source, sink: sink)
        await second.bind(env.context); await second.settleBounded()
        let resumedReads = await source.readLog.dropFirst(before)
        XCTAssertEqual(resumedReads.first?.offset, 3 * 1024, "the first read after restart starts at the first missing byte")
        XCTAssertFalse(resumedReads.contains { $0.offset < 3 * 1024 })
        let stored = await sink.bytes("variant-1"); XCTAssertEqual(stored, data)
    }

    /// OFF06: while the total is unknown there is no fraction and no aggregate total; once known the numbers are real.
    func testNoPercentIsInventedWhileTheLengthIsUnknown() async throws {
        let env = try Env(); defer { env.cleanup() }
        let data = payload(4 * 1024 + 17)
        let source = FakeSource(wall: env.wall); await source.setUnknownLength(item, bytes: data)
        let sink = MemorySink()
        let scheduler = try env.makeScheduler(source: source, sink: sink)
        await scheduler.bind(env.context)
        await source.holdAfter(reads: 2)
        _ = await scheduler.download(item, title: "Stream")
        await source.waitUntilBlocked()
        let during = await scheduler.snapshot()
        let row = try XCTUnwrap(during.rows.first)
        XCTAssertNil(row.progress.totalBytes); XCTAssertNil(row.progress.fraction, "no percentage while the size is unknown")
        XCTAssertEqual(row.progress.completedBytes, 2 * 1024)
        XCTAssertNil(during.aggregate?.totalBytes); XCTAssertNil(during.aggregate?.fraction)
        await source.release()
        await scheduler.settleBounded()
        let finalRows = await scheduler.snapshot().rows
        let done = try XCTUnwrap(finalRows.first)
        XCTAssertEqual(done.phase, .available); XCTAssertEqual(done.progress.totalBytes, Int64(data.count)); XCTAssertEqual(done.progress.fraction, 1)
        let stored = await sink.bytes("variant-1"); XCTAssertEqual(stored, data)
    }

    /// OFF07: when the source now describes different bytes, the old partial is discarded and nothing is appended to it.
    func testAChangedVariantRestartsCleanlyAndNeverMixesBytes() async throws {
        let env = try Env(); defer { env.cleanup() }
        let v1 = payload(6 * 1024, seed: 1), v2 = payload(6 * 1024, seed: 2)
        let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: v1, variant: "variant-1", validator: "a"))
        let sink = MemorySink()
        let first = try env.makeScheduler(source: source, sink: sink)
        await first.bind(env.context)
        await source.holdAfter(reads: 2)
        _ = await first.download(item, title: "One")
        await source.waitUntilBlocked()
        await first.quit(); await source.release()
        // The source republishes the item as a different byte sequence (new variant) before the app comes back.
        await source.set(item, .init(bytes: v2, variant: "variant-2", validator: "b"))
        let second = try env.makeScheduler(source: source, sink: sink)
        await second.bind(env.context); await second.settleBounded()
        let stored = await sink.bytes("variant-2"); XCTAssertEqual(stored, v2, "only the new variant's bytes")
        let old = await sink.has("variant-1"); XCTAssertFalse(old)
        let log = await source.readLog.filter { $0.variant == "variant-2" }
        XCTAssertEqual(log.first?.offset, 0, "the new variant is fetched from its start")
    }

    /// A source without ranges cannot resume: a restart begins at byte 0 rather than trusting recorded ranges.
    func testASourceWithoutRangesRestartsFromTheBeginning() async throws {
        let env = try Env(); defer { env.cleanup() }
        let data = payload(5 * 1024)
        let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: data, supportsRanges: false))
        let sink = MemorySink()
        let first = try env.makeScheduler(source: source, sink: sink)
        await first.bind(env.context)
        await source.holdAfter(reads: 2)
        _ = await first.download(item, title: "One")
        await source.waitUntilBlocked(); await first.quit(); await source.release()
        let before = await source.readLog.count
        let second = try env.makeScheduler(source: source, sink: sink)
        await second.bind(env.context); await second.settleBounded()
        let after = await source.readLog.dropFirst(before)
        XCTAssertEqual(after.first?.offset, 0)
        let stored = await sink.bytes("variant-1"); XCTAssertEqual(stored, data)
    }

    /// Reconnect or a repeated request does not spawn a second job (OFF13).
    func testRepeatedRequestsNeverCreateADuplicateJob() async throws {
        let env = try Env(); defer { env.cleanup() }
        let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: payload(2048)))
        let scheduler = try env.makeScheduler(source: source, sink: MemorySink())
        await scheduler.bind(env.context)
        for _ in 0..<4 { _ = await scheduler.download(item, title: "One") }
        await scheduler.settleBounded()
        await scheduler.networkChanged(NetworkPathState(isAvailable: false)); await scheduler.networkChanged(NetworkPathState())
        _ = await scheduler.download(item, title: "One")
        await scheduler.settleBounded()
        let rows = await scheduler.snapshot().rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.phase, .available)
    }

    // MARK: Ledger robustness

    func testADamagedLedgerIsSetAsideAndTheAccountStartsClean() async throws {
        let env = try Env(); defer { env.cleanup() }
        let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: payload(2048)))
        let first = try env.makeScheduler(source: source, sink: MemorySink())
        await first.bind(env.context); _ = await first.download(item, title: "One"); await first.settleBounded(); await first.quit()
        let dir = env.ledgerURL.appendingPathComponent(DownloadLedgerNames.directory(env.account))
        try Data("{ not a ledger".utf8).write(to: dir.appendingPathComponent("ledger.json"))
        let second = try env.makeScheduler(source: source, sink: MemorySink())
        await second.bind(env.context)
        let rows = await second.snapshot().rows
        XCTAssertTrue(rows.isEmpty, "a damaged ledger is not trusted")
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(entries.contains { $0.hasPrefix("ledger.damaged-") }, "it is kept for inspection, not deleted")
    }

    func testALedgerBelongingToAnotherAccountIsNeverAdopted() async throws {
        let env = try Env(); defer { env.cleanup() }
        let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: payload(2048)))
        let first = try env.makeScheduler(source: source, sink: MemorySink())
        await first.bind(env.context); _ = await first.download(item, title: "Mine"); await first.settleBounded(); await first.quit()
        // Copy account A's ledger into account B's directory.
        let a = env.ledgerURL.appendingPathComponent(DownloadLedgerNames.directory(env.account)), b = env.ledgerURL.appendingPathComponent(DownloadLedgerNames.directory(env.otherAccount))
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: a.appendingPathComponent("ledger.json"), to: b.appendingPathComponent("ledger.json"))
        let second = try env.makeScheduler(source: source, sink: MemorySink())
        await second.bind(env.context(for: env.otherAccount))
        let snapshot = await second.snapshot()
        XCTAssertTrue(snapshot.rows.isEmpty, "another account's downloads are never substituted")
        XCTAssertFalse(snapshot.hasAccount, "an unreadable ledger leaves the scheduler unbound rather than guessing")
    }

    func testAnOrphanedStagingFragmentIsRemovedOnLaunch() async throws {
        let env = try Env(); defer { env.cleanup() }
        let source = FakeSource(wall: env.wall); await source.set(item, .init(bytes: payload(2048)))
        let first = try env.makeScheduler(source: source, sink: MemorySink())
        await first.bind(env.context); _ = await first.download(item, title: "One"); await first.settleBounded(); await first.quit()
        let staging = env.ledgerURL.appendingPathComponent(DownloadLedgerNames.directory(env.account)).appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let orphan = staging.appendingPathComponent("orphan.part")
        FileManager.default.createFile(atPath: orphan.path, contents: payload(500), attributes: [.posixPermissions: 0o600])
        let second = try env.makeScheduler(source: source, sink: MemorySink())
        await second.bind(env.context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "a cleartext fragment no job owns is deleted")
    }

    // MARK: Range algebra (property)

    func testRangeSetMatchesABitmapModelForRandomInsertions() throws {
        var rng: UInt64 = 0xC0FFEE
        func next(_ bound: Int) -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int((rng >> 33) % UInt64(bound)) }
        for _ in 0..<400 {
            var set = RangeSet(); var model = [Bool](repeating: false, count: 200)
            for _ in 0..<next(25) + 1 {
                let lower = next(200), length = next(30) + 1, upper = min(199, lower + length - 1)
                set.insert(lower: Int64(lower), upper: Int64(upper))
                for i in lower...upper { model[i] = true }
                XCTAssertEqual(set.coveredBytes, Int64(model.filter { $0 }.count))
                XCTAssertNoThrow(try RangeSet(validating: set.spans), "sorted, disjoint, merged after every insert")
            }
            let missing = set.missing(total: 200)
            var gap = [Bool](repeating: false, count: 200)
            for span in missing { for i in span.lower...span.upper { XCTAssertFalse(gap[Int(i)]); gap[Int(i)] = true } }
            XCTAssertEqual(gap, model.map { !$0 }, "missing() is exactly the complement")
            let prefix = model.firstIndex(of: false) ?? 200
            XCTAssertEqual(set.contiguousPrefix, Int64(prefix))
            let decoded = try JSONDecoder().decode(RangeSet.self, from: JSONEncoder().encode(set)); XCTAssertEqual(decoded, set)
        }
    }
    func testADamagedRangeSetIsRefusedWhenDecoded() {
        for bad in ["[{\"lower\":5,\"upper\":2}]", "[{\"lower\":0,\"upper\":9},{\"lower\":5,\"upper\":20}]", "[{\"lower\":0,\"upper\":9},{\"lower\":10,\"upper\":20}]", "[{\"lower\":10,\"upper\":12},{\"lower\":0,\"upper\":3}]", "[{\"lower\":-1,\"upper\":3}]"] {
            XCTAssertThrowsError(try JSONDecoder().decode(RangeSet.self, from: Data(bad.utf8)), bad)
        }
    }
}
