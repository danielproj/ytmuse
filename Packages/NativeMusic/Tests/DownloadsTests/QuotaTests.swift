import XCTest
import Foundation
import Domain
import Downloads

/// T15.2 — aggregate cross-account quota, the free-space reserve boundary, pinned-full pause and the Smart cap;
/// settings changes never evict pins.
final class QuotaTests: XCTestCase, @unchecked Sendable {
    private let gib = DownloadPolicy.gibibyte

    // MARK: Pure rules

    func testTheReserveIsTheLargerOfFiveGiBAndFivePercentOfTheVolume() {
        XCTAssertEqual(DownloadPolicy.reserve(volumeTotal: 100 * gib), 5 * gib, "5% of 100 GiB is exactly 5 GiB")
        XCTAssertEqual(DownloadPolicy.reserve(volumeTotal: 99 * gib), 5 * gib, "below the crossover the fixed 5 GiB wins")
        XCTAssertEqual(DownloadPolicy.reserve(volumeTotal: 1000 * gib), 50 * gib)
        XCTAssertEqual(DownloadPolicy.reserve(volumeTotal: 2000 * gib + 40), 100 * gib + 2)
        XCTAssertEqual(DownloadPolicy.reserve(volumeTotal: 0), 5 * gib)
    }
    func testAdmissionHonoursTheReserveBoundaryExactlyForSimulatedVolumeSizes() {
        for total in [64 * gib, 100 * gib, 256 * gib, 1000 * gib, 4000 * gib] {
            let reserve = DownloadPolicy.reserve(volumeTotal: total)
            let ledger = DownloadPolicy.Ledger(usedAllAccounts: 0, protectedBytes: 0, automaticBytes: 0)
            let need = gib
            XCTAssertEqual(DownloadPolicy.admission(bytes: need, automatic: false, ledger: ledger, budget: 20 * gib, volumeTotal: total, volumeAvailable: reserve + need), .admit, "exactly at the reserve is allowed (\(total / gib) GiB volume)")
            XCTAssertEqual(DownloadPolicy.admission(bytes: need, automatic: false, ledger: ledger, budget: 20 * gib, volumeTotal: total, volumeAvailable: reserve + need - 1), .volumeReserve, "one byte below it is not")
        }
    }
    func testTheBudgetBoundaryAndTheSmartCap() {
        let budget = 20 * gib
        var ledger = DownloadPolicy.Ledger(usedAllAccounts: budget - gib, protectedBytes: budget - gib, automaticBytes: 0)
        XCTAssertEqual(DownloadPolicy.admission(bytes: gib, automatic: false, ledger: ledger, budget: budget, volumeTotal: 1000 * gib, volumeAvailable: 900 * gib), .admit)
        XCTAssertEqual(DownloadPolicy.admission(bytes: gib + 1, automatic: false, ledger: ledger, budget: budget, volumeTotal: 1000 * gib, volumeAvailable: 900 * gib), .budgetFullOfPinned)
        XCTAssertEqual(DownloadPolicy.automaticCap(budget: budget), 5 * gib, "at most 25% of the configured budget")
        ledger = DownloadPolicy.Ledger(usedAllAccounts: 4 * gib, protectedBytes: 0, automaticBytes: 4 * gib)
        XCTAssertEqual(DownloadPolicy.admission(bytes: gib, automatic: true, ledger: ledger, budget: budget, volumeTotal: 1000 * gib, volumeAvailable: 900 * gib), .admit)
        XCTAssertEqual(DownloadPolicy.admission(bytes: gib + 1, automatic: true, ledger: ledger, budget: budget, volumeTotal: 1000 * gib, volumeAvailable: 900 * gib), .smartCapReached)
        // Manual content may displace automatic content, never the other way round.
        ledger = DownloadPolicy.Ledger(usedAllAccounts: budget, protectedBytes: budget - 4 * gib, automaticBytes: 4 * gib)
        XCTAssertEqual(DownloadPolicy.admission(bytes: 3 * gib, automatic: false, ledger: ledger, budget: budget, volumeTotal: 1000 * gib, volumeAvailable: 900 * gib), .needsEviction(3 * gib))
        XCTAssertEqual(DownloadPolicy.admission(bytes: 5 * gib, automatic: false, ledger: ledger, budget: budget, volumeTotal: 1000 * gib, volumeAvailable: 900 * gib), .budgetFullOfPinned)
        XCTAssertEqual(DownloadPolicy.admission(bytes: gib, automatic: true, ledger: ledger, budget: budget, volumeTotal: 1000 * gib, volumeAvailable: 900 * gib), .budgetFullOfPinned, "automatic content never evicts anything")
        XCTAssertEqual(DownloadPolicy.defaultBudget, 20 * gib)
        XCTAssertEqual(DownloadPolicy.concurrencyLimit(lowPowerMode: false), 2); XCTAssertEqual(DownloadPolicy.concurrencyLimit(lowPowerMode: true), 1)
    }
    func testPropertyAdmissionIsMonotoneInSizeAndNeverAdmitsPastTheBudgetOrTheReserve() {
        var rng: UInt64 = 99
        func next(_ bound: Int64) -> Int64 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int64((rng >> 33) % UInt64(bound)) }
        for _ in 0..<5000 {
            let total = (next(4000) + 32) * gib, budget = (next(100) + 1) * gib
            let used = next(budget / gib * 2 + 1) * gib / 2, automatic = min(used, next(used / gib + 1) * gib)
            let ledger = DownloadPolicy.Ledger(usedAllAccounts: used, protectedBytes: used - automatic, automaticBytes: automatic, inFlightBytes: next(3) * gib)
            let available = next(total / gib + 1) * gib
            var admitted = true
            for need in stride(from: Int64(0), through: 12 * gib, by: Int(gib / 2)) {
                let result = DownloadPolicy.admission(bytes: need, automatic: false, ledger: ledger, budget: budget, volumeTotal: total, volumeAvailable: available)
                if result == .admit {
                    XCTAssertTrue(admitted, "a larger request is never admitted after a smaller one was refused")
                    XCTAssertLessThanOrEqual(ledger.usedAllAccounts + ledger.inFlightBytes + need, budget)
                    XCTAssertGreaterThanOrEqual(available - need, DownloadPolicy.reserve(volumeTotal: total))
                } else if case .needsEviction = result {} else { admitted = false }
            }
        }
    }

    // MARK: Scheduler

    private func make(_ env: Env, sink: MemorySink = MemorySink()) async throws -> (DownloadScheduler, FakeSource, MemorySink) {
        let source = FakeSource(wall: env.wall)
        let scheduler = try env.makeScheduler(source: source, sink: sink)
        await scheduler.bind(env.context)
        return (scheduler, source, sink)
    }

    /// Another account's retained bytes count against the one budget.
    func testTheBudgetSpansAccounts() async throws {
        let env = try Env(); defer { env.cleanup() }
        let sink = MemorySink()
        let other = owned("other"), mine = owned("mine")
        let source = FakeSource(wall: env.wall)
        await source.set(other, .init(bytes: payload(40 * 1024)))
        await source.set(mine, .init(bytes: payload(40 * 1024)))
        let schedulerB = try env.makeScheduler(source: source, sink: sink)
        await schedulerB.bind(env.context(for: env.otherAccount))
        _ = await schedulerB.setBudget(bytes: 64 * 1024)
        _ = await schedulerB.download(other, title: "Other account's song"); await schedulerB.settleBounded()
        let rowsB = await schedulerB.snapshot().rows; XCTAssertEqual(rowsB.first?.phase, .available)
        await schedulerB.quit()
        // Account A has room for its own file alone, but not on top of account B's.
        let schedulerA = try env.makeScheduler(source: source, sink: sink)
        await schedulerA.bind(env.context)
        _ = await schedulerA.download(mine, title: "Mine")
        await schedulerA.settleBounded()
        let rowsA = await schedulerA.snapshot().rows
        let row = try XCTUnwrap(rowsA.first)
        XCTAssertEqual(row.phase, .paused); XCTAssertEqual(row.pauseCause, .storageBudgetFull, "the other account's bytes fill the shared budget")
        let snapshot = await schedulerA.snapshot()
        XCTAssertGreaterThan(snapshot.storage.usedBytes, 40 * 1024, "usage reports every account's retained bytes")
        XCTAssertEqual(snapshot.storage.budgetBytes, 64 * 1024)
        XCTAssertEqual(snapshot.rows.count, 1, "account B's job is not shown or adopted here")
    }

    /// OFF03: pinned media filling the budget pauses NEW downloads, deletes nothing and offers choices.
    func testPinnedMediaFillingTheBudgetPausesNewDownloadsAndDeletesNothing() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, sink) = try await make(env)
        _ = await scheduler.setBudget(bytes: 64 * 1024)
        let pinned = owned("pinned"), extra = owned("extra")
        await source.set(pinned, .init(bytes: payload(40 * 1024, seed: 3), variant: "pinned-v"))
        await source.set(extra, .init(bytes: payload(40 * 1024, seed: 4), variant: "extra-v"))
        _ = await scheduler.download(pinned, title: "Pinned"); await scheduler.settleBounded()
        _ = await scheduler.download(extra, title: "Extra"); await scheduler.settleBounded()
        let snapshot = await scheduler.snapshot()
        let extraRow = try XCTUnwrap(snapshot.rows.first { $0.media == extra })
        XCTAssertEqual(extraRow.phase, .paused); XCTAssertEqual(extraRow.pauseCause, .storageBudgetFull)
        XCTAssertTrue(snapshot.storageChoices.contains(.raiseBudget)); XCTAssertTrue(snapshot.storageChoices.contains(.removeDownloads))
        let kept = await sink.has("pinned-v"); XCTAssertTrue(kept, "pinned content is never deleted to make room")
        let wasPinned = await sink.isPinned("pinned-v"); XCTAssertEqual(wasPinned, true)
        // The person chooses to raise the budget: the paused download resumes by itself.
        _ = await scheduler.setBudget(bytes: 256 * 1024); await scheduler.settleBounded()
        let after = await scheduler.snapshot().rows.first { $0.media == extra }; XCTAssertEqual(after?.phase, .available)
    }

    /// Lowering the budget or switching Smart Downloads off never removes what was kept.
    func testSettingsChangesNeverEvictPinsOrCollectionContent() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, sink) = try await make(env)
        _ = await scheduler.setBudget(bytes: 1 << 20)
        _ = await scheduler.setSmartDownloads(enabled: true)
        let a = owned("a"), b = owned("b"), c = owned("c")
        for (item, seed) in [(a, UInt8(1)), (b, UInt8(2)), (c, UInt8(3))] { await source.set(item, .init(bytes: payload(20 * 1024, seed: seed), variant: "v-" + item.rawValue)) }
        _ = await scheduler.download(a, title: "A")
        _ = await scheduler.setCollection(try ServiceID("owned-list"), title: "List", members: [b], downloading: true)
        _ = await scheduler.download(c, title: "C", request: .automatic)
        await scheduler.settleBounded()
        _ = await scheduler.setBudget(bytes: 4 * 1024)          // far below what is stored
        _ = await scheduler.setSmartDownloads(enabled: false)
        await scheduler.settleBounded()
        for variant in ["v-owned-a", "v-owned-b", "v-owned-c"] {
            let kept = await sink.has(variant); XCTAssertTrue(kept, "\(variant) survives a budget cut and Smart switching off")
        }
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.rows.filter { $0.phase == .available }.count, 3)
        XCTAssertFalse(snapshot.smartDownloadsEnabled)
        // Nothing new starts while over budget.
        let d = owned("d"); await source.set(d, .init(bytes: payload(2048), variant: "v-d"))
        _ = await scheduler.download(d, title: "D"); await scheduler.settleBounded()
        let dRow = await scheduler.snapshot().rows.first { $0.media == d }; XCTAssertEqual(dRow?.pauseCause, .storageBudgetFull)
    }

    /// OFF04: off by default; explicit switch; automatic content capped at 25% of the budget and never displacing other content.
    func testSmartDownloadsAreOffByDefaultAndCappedAtAQuarterOfTheBudget() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, sink) = try await make(env)
        let first = owned("s1"), second = owned("s2")
        await source.set(first, .init(bytes: payload(20 * 1024, seed: 5), variant: "s1-v")); await source.set(second, .init(bytes: payload(20 * 1024, seed: 6), variant: "s2-v"))
        let initial = await scheduler.snapshot(); XCTAssertFalse(initial.smartDownloadsEnabled, "Smart Downloads is off until switched on")
        let refused = await scheduler.download(first, title: "S1", request: .automatic)
        XCTAssertEqual(refused, .refused(.forbidden), "an automatic download needs the explicit switch")
        let none = await scheduler.snapshot().rows; XCTAssertTrue(none.isEmpty)
        _ = await scheduler.setBudget(bytes: 100 * 1024)         // 25% = 25 KiB
        _ = await scheduler.setSmartDownloads(enabled: true)
        let cap = await scheduler.snapshot().storage.automaticCapBytes; XCTAssertEqual(cap, 25 * 1024)
        _ = await scheduler.download(first, title: "S1", request: .automatic); await scheduler.settleBounded()
        _ = await scheduler.download(second, title: "S2", request: .automatic); await scheduler.settleBounded()
        let rows = await scheduler.snapshot().rows
        XCTAssertEqual(rows.first { $0.media == first }?.phase, .available)
        XCTAssertEqual(rows.first { $0.media == second }?.pauseCause, .smartCapReached, "the second would exceed 25% of the budget")
        let kept = await sink.has("s1-v"); XCTAssertTrue(kept)
    }

    /// A manual download may displace automatic content when only that stands in the way, and nothing else.
    func testAManualDownloadEvictsOnlyAutomaticContentToMakeRoom() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, sink) = try await make(env)
        _ = await scheduler.setBudget(bytes: 100 * 1024); _ = await scheduler.setSmartDownloads(enabled: true)      // Smart cap 25 KiB
        let pinned = owned("keep"), smart = owned("smart"), manual = owned("new")
        await source.set(pinned, .init(bytes: payload(30 * 1024, seed: 1), variant: "keep-v")); await source.set(smart, .init(bytes: payload(18 * 1024, seed: 2), variant: "smart-v"))
        await source.set(manual, .init(bytes: payload(40 * 1024, seed: 3), variant: "new-v"))
        _ = await scheduler.download(pinned, title: "Keep"); await scheduler.settleBounded()
        _ = await scheduler.download(smart, title: "Smart", request: .automatic); await scheduler.settleBounded()
        let beforeKeep = await sink.has("keep-v"), beforeSmart = await sink.has("smart-v")
        XCTAssertTrue(beforeKeep && beforeSmart, "precondition: both are stored, so eviction has something to choose between")
        _ = await scheduler.download(manual, title: "New"); await scheduler.settleBounded()
        let keep = await sink.has("keep-v"), gone = await sink.has("smart-v"), added = await sink.has("new-v")
        XCTAssertTrue(keep, "pinned content stays"); XCTAssertFalse(gone, "automatic content made room"); XCTAssertTrue(added)
        let rows = await scheduler.snapshot().rows
        XCTAssertEqual(rows.first { $0.media == manual }?.phase, .available); XCTAssertNil(rows.first { $0.media == smart }, "the evicted automatic item left the list")
        XCTAssertEqual(rows.first { $0.media == pinned }?.phase, .available)
    }
}

/// The real volume measure (read-only): free plus purgeable, never less than the plain free figure, and a sane total.
final class VolumeMeasureTests: XCTestCase {
    func testTheSystemMeasureIsAtLeastThePlainFreeSpaceAndTheTotalIsReal() throws {
        let url = FileManager.default.temporaryDirectory
        let capacity = SystemVolumeCapacity().capacity(at: url)
        let plain = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        XCTAssertGreaterThan(capacity.total, 0)
        XCTAssertGreaterThanOrEqual(capacity.available, Int64(plain))
        XCTAssertLessThanOrEqual(capacity.available, capacity.total)
        XCTAssertEqual(SystemVolumeCapacity().capacity(at: URL(fileURLWithPath: "/nonexistent-w15-path")).available, 0, "an unmeasurable volume counts as having no room")
    }
}
