import XCTest
import Foundation
import Synchronization
import Domain
import Downloads

/// T15.3 — measured network path and Low Power Mode change scheduling, a manual override is explicit, and current
/// playback wins.
final class SchedulingTests: XCTestCase, @unchecked Sendable {
    private func setup(_ env: Env, network: FakeNetwork = FakeNetwork(), power: FakePower = FakePower(), items: [String] = ["a", "b", "c"], size: Int = 8 * 1024) async throws -> (DownloadScheduler, FakeSource, MemorySink) {
        let source = FakeSource(wall: env.wall); let sink = MemorySink()
        for name in items { await source.set(owned(name), .init(bytes: payload(size, seed: UInt8(name.utf8.first!)), variant: "v-" + name)) }
        let scheduler = try env.makeScheduler(source: source, sink: sink, network: network, power: power)
        await scheduler.bind(env.context)
        return (scheduler, source, sink)
    }

    // MARK: Network (OFF05)

    func testAnExpensiveOrConstrainedPathHoldsAutomaticDownloadsAndAskBeforeManualOnes() async throws {
        for (label, state, cause) in [("expensive", NetworkPathState(isExpensive: true), DownloadPauseCause.expensiveNetwork), ("constrained", NetworkPathState(isConstrained: true), .constrainedNetwork)] {
            let env = try Env(); defer { env.cleanup() }
            let network = FakeNetwork(); network.state.withLock { $0 = state }
            let (scheduler, _, sink) = try await setup(env, network: network)
            _ = await scheduler.setBudget(bytes: 1 << 20); _ = await scheduler.setSmartDownloads(enabled: true)
            _ = await scheduler.download(owned("a"), title: "Auto", request: .automatic)
            _ = await scheduler.download(owned("b"), title: "Manual")
            await scheduler.settleBounded()
            let rows = await scheduler.snapshot().rows
            let auto = try XCTUnwrap(rows.first { $0.media == owned("a") }), manual = try XCTUnwrap(rows.first { $0.media == owned("b") })
            XCTAssertEqual(auto.pauseCause, cause, label); XCTAssertEqual(manual.pauseCause, cause, "\(label): manual downloads wait for an explicit say-so too")
            XCTAssertFalse(auto.actions.contains(.downloadOnThisNetwork), "an automatic download can never be overridden")
            XCTAssertTrue(manual.actions.contains(.downloadOnThisNetwork), "a manual one can")
            let none = await sink.count; XCTAssertEqual(none, 0, "nothing was fetched on the metered path")
            // The override is an explicit act on that one download.
            let result = await scheduler.perform(.downloadOnThisNetwork, job: manual.id); XCTAssertEqual(result, .done)
            await scheduler.settleBounded()
            let after = await scheduler.snapshot().rows
            XCTAssertEqual(after.first { $0.media == owned("b") }?.phase, .available, "\(label): the overridden download ran")
            XCTAssertEqual(after.first { $0.media == owned("a") }?.pauseCause, cause, "\(label): the automatic one is still held")
            // The path becoming unmetered releases the held automatic download.
            await scheduler.networkChanged(NetworkPathState()); await scheduler.settleBounded()
            let free = await scheduler.snapshot().rows.first { $0.media == owned("a") }; XCTAssertEqual(free?.phase, .available)
        }
    }
    /// W27 (Automatic downloads on expensive networks, default off): the setting lets an AUTOMATIC download use an expensive path, never a constrained one (Low Data Mode),
    /// and it survives a relaunch through the ledger's settings.
    func testAnAutomaticDownloadRunsOnAnExpensivePathOnlyWhenAllowedAndNeverOnAConstrainedOne() async throws {
        let env = try Env(); defer { env.cleanup() }
        let network = FakeNetwork(); network.state.withLock { $0 = NetworkPathState(isExpensive: true) }
        let (scheduler, _, sink) = try await setup(env, network: network)
        _ = await scheduler.setBudget(bytes: 1 << 20); _ = await scheduler.setSmartDownloads(enabled: true)
        let defaultAllowed = await scheduler.automaticOnExpensiveAllowed
        XCTAssertFalse(defaultAllowed, "off by default")
        _ = await scheduler.download(owned("a"), title: "Auto", request: .automatic)
        await scheduler.settleBounded()
        let held = await scheduler.snapshot().rows.first { $0.media == owned("a") }
        XCTAssertEqual(held?.pauseCause, .expensiveNetwork, "held while the setting is off")
        let none = await sink.count; XCTAssertEqual(none, 0)
        let allowed = await scheduler.setAutomaticOnExpensive(enabled: true); XCTAssertEqual(allowed, .done)
        await scheduler.settleBounded()
        let ran = await scheduler.snapshot().rows.first { $0.media == owned("a") }
        XCTAssertEqual(ran?.phase, .available, "allowed: the automatic download ran on the expensive path")
        // Low Data Mode (constrained) still blocks it.
        await scheduler.networkChanged(NetworkPathState(isConstrained: true, isExpensive: true))
        _ = await scheduler.download(owned("b"), title: "Auto 2", request: .automatic)
        await scheduler.settleBounded()
        let constrained = await scheduler.snapshot().rows.first { $0.media == owned("b") }
        XCTAssertEqual(constrained?.pauseCause, .constrainedNetwork, "a constrained path always blocks automatic downloads")
        // The choice is in the ledger's settings: a new scheduler over the same folder reads it.
        let reopened = try env.makeScheduler(source: FakeSource(wall: env.wall), sink: MemorySink())
        let persisted = await reopened.automaticOnExpensiveAllowed
        XCTAssertTrue(persisted)
        _ = await reopened.setAutomaticOnExpensive(enabled: false)
        let cleared = await reopened.automaticOnExpensiveAllowed; XCTAssertFalse(cleared)
    }
    func testGoingOfflinePausesEverythingAndComingBackResumesWithoutDuplicates() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, _) = try await setup(env, items: ["a"], size: 10 * 1024)
        await source.holdAfter(reads: 2)
        _ = await scheduler.download(owned("a"), title: "A")
        await source.waitUntilBlocked()
        await scheduler.networkChanged(NetworkPathState(isAvailable: false))
        await scheduler.settleBounded()
        let paused = try await scheduler.onlyRow()
        XCTAssertEqual(paused.pauseCause, .offline); XCTAssertEqual(paused.progress.completedBytes, 2 * 1024, "progress so far is kept")
        await source.release()
        await scheduler.networkChanged(NetworkPathState()); await scheduler.settleBounded()
        let rows = await scheduler.snapshot().rows
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.phase, .available)
        let log = await source.readLog; XCTAssertEqual(log.first(where: { $0.offset == 2 * 1024 })?.offset, 2 * 1024)
        XCTAssertEqual(log.filter { $0.offset == 0 }.count, 1, "the first chunk was fetched once")
    }
    func testARunningDownloadStopsWhenThePathBecomesExpensiveUnlessOverridden() async throws {
        let env = try Env(); defer { env.cleanup() }
        let network = FakeNetwork()
        let (scheduler, source, _) = try await setup(env, network: network, items: ["a"], size: 10 * 1024)
        await source.holdAfter(reads: 2)
        _ = await scheduler.download(owned("a"), title: "A")
        await source.waitUntilBlocked()
        await scheduler.networkChanged(NetworkPathState(isExpensive: true))
        await scheduler.settleBounded()
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.pauseCause, .expensiveNetwork)
        await source.release()
        _ = await scheduler.perform(.downloadOnThisNetwork, job: row.id); await scheduler.settleBounded()
        let done = await scheduler.snapshot().rows.first; XCTAssertEqual(done?.phase, .available)
    }

    // MARK: Low Power Mode

    func testConcurrencyIsTwoAndOneInLowPowerMode() async throws {
        let env = try Env(); defer { env.cleanup() }
        let power = FakePower()
        let (scheduler, source, _) = try await setup(env, power: power, size: 12 * 1024)
        await source.holdAfter(reads: 0)
        for name in ["a", "b", "c"] { _ = await scheduler.download(owned(name), title: name) }
        await source.waitUntilBlocked()
        _ = await scheduler.waitFor("two running") { $0.activeCount == 2 }
        var snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.activeCount, 2, "default concurrency is two"); XCTAssertEqual(snapshot.concurrencyLimit, 2)
        await scheduler.powerChanged(lowPower: true)
        _ = await scheduler.waitFor("one running") { $0.activeCount <= 1 }
        snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.concurrencyLimit, 1); XCTAssertTrue(snapshot.lowPowerMode)
        XCTAssertLessThanOrEqual(snapshot.activeCount, 1, "Low Power Mode sheds the second download")
        await source.release()
        await scheduler.settleBounded(); await scheduler.settleBounded()
        let finished = await scheduler.snapshot().rows
        XCTAssertEqual(finished.filter { $0.phase == .available }.count, 3, "everything still completes, one at a time")
    }
    func testNeverMoreThanTheLimitRunsAtOnceAndNothingStartsTwice() async throws {
        let env = try Env(); defer { env.cleanup() }
        let power = FakePower(); power.low.withLock { $0 = true }
        let (scheduler, source, _) = try await setup(env, power: power, items: ["a", "b", "c", "d"], size: 6 * 1024)
        await source.holdAfter(reads: 0)
        for name in ["a", "b", "c", "d"] { _ = await scheduler.download(owned(name), title: name) }
        await source.waitUntilBlocked()
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.activeCount, 1, "one download in Low Power Mode"); XCTAssertEqual(snapshot.waitingCount, 3)
        await source.release(); await scheduler.settleBounded()
        let rows = await scheduler.snapshot().rows; XCTAssertEqual(rows.count, 4); XCTAssertTrue(rows.allSatisfy { $0.phase == .available })
        let reads = await source.readLog
        for name in ["a", "b", "c", "d"] { XCTAssertEqual(reads.filter { $0.media == "owned-" + name }.count, 6, "each item's chunks fetched exactly once") }
    }

    // MARK: Priority

    func testTheNewestExplicitDownloadStartsFirst() async throws {
        let env = try Env(); defer { env.cleanup() }
        let power = FakePower(); power.low.withLock { $0 = true }     // one slot makes the order observable
        let (scheduler, source, _) = try await setup(env, power: power, items: ["a", "b", "c"], size: 2048)
        let network = FakeNetwork(); _ = network
        await scheduler.networkChanged(NetworkPathState(isAvailable: false))       // queue everything first
        for name in ["a", "b", "c"] { _ = await scheduler.download(owned(name), title: name) }
        await scheduler.networkChanged(NetworkPathState()); await scheduler.settleBounded()
        let order = await source.readLog.map(\.media).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(order, ["owned-c", "owned-b", "owned-a"], "the most recently requested download goes first")
    }
    func testCurrentPlaybackPreemptsAndWins() async throws {
        let env = try Env(); defer { env.cleanup() }
        let power = FakePower(); power.low.withLock { $0 = true }
        let (scheduler, source, _) = try await setup(env, power: power, items: ["a", "b"], size: 8 * 1024)
        await source.holdAfter(reads: 2)
        _ = await scheduler.download(owned("a"), title: "A")
        await source.waitUntilBlocked()
        _ = await scheduler.download(owned("b"), title: "B")
        let queued = await scheduler.snapshot().rows.first { $0.media == owned("b") }; XCTAssertEqual(queued?.phase, .queued)
        await scheduler.setCurrentPlayback(owned("b"))
        await source.release()
        await scheduler.settleBounded()
        _ = await scheduler.waitFor("both finish") { $0.rows.allSatisfy { $0.phase == .available } }
        let both = await scheduler.snapshot().rows; XCTAssertTrue(both.allSatisfy { $0.phase == .available }, "the preempted download resumed and finished")
        // Deterministic order from the source's own log: A's first two chunks, then ALL of B (it took the only slot), then A's rest.
        let sequence = await source.readLog.map(\.media).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(sequence, ["owned-a", "owned-b", "owned-a"], "the track being played took the only slot from the older download")
        let reads = await source.readLog.filter { $0.media == "owned-a" }
        XCTAssertEqual(reads.map(\.offset), (0..<8).map { Int64($0 * 1024) }, "no byte of the preempted download was fetched twice")
    }

    // MARK: Retries (OFF13)

    func testBackoffIsExponentialJitteredCappedAndBounded() {
        let policy = RetryPolicy(base: 2, factor: 2, cap: 300, maxAttempts: 6)
        for attempt in 1...12 {
            let raw = min(300, 2 * pow(2, Double(attempt - 1)))
            let low = policy.delay(attempt: attempt, unit: 0), high = policy.delay(attempt: attempt, unit: 1)
            XCTAssertEqual(low, raw / 2, accuracy: 1e-9); XCTAssertEqual(high, raw, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(policy.delay(attempt: attempt, unit: 0.37), 300)
        }
        XCTAssertFalse(policy.exhausted(attempt: 6)); XCTAssertTrue(policy.exhausted(attempt: 7))
    }
    func testTransientFailuresBackOffThenGiveUpWithAnExplicitFailureThatRetryRevives() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, sink) = try await setup(env, items: ["a"], size: 2048)
        await source.failEveryRead(with: .transient(retryAfter: nil))
        _ = await scheduler.download(owned("a"), title: "A")
        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            await scheduler.settleBounded()
            let row = await scheduler.snapshot().rows.first
            if row?.phase == .failed { break }
            let due = try XCTUnwrap(row?.retryAt, "a failed attempt is scheduled, not retried immediately")
            delays.append(due.timeIntervalSince(env.wall.now()))
            env.manual.advance(due.timeIntervalSince(env.wall.now()) + 0.001)
            await scheduler.wakeFired()
        }
        await scheduler.settleBounded()
        let failed = try await scheduler.onlyRow()
        XCTAssertEqual(failed.phase, .failed); XCTAssertNotNil(failed.failure); XCTAssertEqual(failed.failure, .retriesExhausted)
        XCTAssertEqual(delays.count, 6, "six bounded retries")
        for (index, delay) in delays.enumerated() { XCTAssertEqual(delay, min(300, 2 * pow(2, Double(index))) * 0.75, accuracy: 0.01, "exponential with the injected jitter (unit 0.5)") }
        XCTAssertTrue(failed.actions.contains(.retry))
        // After the source recovers, an explicit Retry succeeds with a fresh budget of attempts.
        await source.clearFailures()
        let retried = await scheduler.perform(.retry, job: failed.id); XCTAssertEqual(retried, .done)
        await scheduler.settleBounded()
        let revived = try await scheduler.onlyRow(); XCTAssertEqual(revived.phase, .available)
        let stored = await sink.count; XCTAssertEqual(stored, 1)
    }
    func testAServerRetryAfterLongerThanTheBackoffIsHonoured() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, source, _) = try await setup(env, items: ["a"], size: 2048)
        await source.failRead(number: 1, with: .transient(retryAfter: 120))
        _ = await scheduler.download(owned("a"), title: "A"); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow()
        XCTAssertGreaterThanOrEqual(row.retryAt?.timeIntervalSince(env.wall.now()) ?? 0, 120)
        env.manual.advance(121); await scheduler.wakeFired(); await scheduler.settleBounded()
        let done = await scheduler.snapshot().rows.first; XCTAssertEqual(done?.phase, .available)
    }
}
