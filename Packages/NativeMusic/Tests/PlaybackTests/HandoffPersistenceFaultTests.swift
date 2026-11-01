@preconcurrency import AVFoundation
import Domain
import Queue
import Synchronization
import XCTest
@testable import Playback

private struct DiskFull: Error {}
/// Every durable save of a handoff adoption fails while `failing` is set, like a
/// full disk or a persistent SQLite I/O error; other saves succeed.
private actor FaultyAdoptionStore: QueuePersistence {
    var saved: QueueSnapshot?
    var failing = true
    var adoptionAttempts = 0
    func heal() { failing = false }
    func load(context: RequestContext) -> QueueSnapshot? { saved }
    func save(_ value: QueueSnapshot, context: RequestContext) async throws {
        if let saved, saved.metadata.handoff != nil, saved.current?.id != value.current?.id, value.current != nil {
            adoptionAttempts += 1
            if failing { throw DiskFull() }
        }
        saved = value
    }
}
private final class Elapsed: Sendable {
    let value = Mutex<Duration?>(nil)
}
/// Completion flag for a task whose `value` must never be awaited unbounded: a
/// regression to unbounded retry parks the adoption barrier forever, and awaiting
/// the stuck task would hang the whole run instead of failing the test (O3).
private final class Finished: Sendable {
    let done = Mutex(false)
    func mark() { done.withLock { $0 = true } }
    /// Polls until `mark()` or the limit; false means still pending.
    func wait(_ limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !done.withLock({ $0 }), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return done.withLock { $0 }
    }
}

/// R1 (W16-union-opus-01): a persistent adoption-save fault must not retry forever
/// behind the adoption barrier. Retries are bounded; the handoff is then abandoned
/// with the queue's durable state (A) authoritative and the fault reported.
final class HandoffPersistenceFaultTests: XCTestCase, @unchecked Sendable {
    func tone(_ hz: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-fault-\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!; buffer.frameLength = 48000
        for c in 0..<2 { for i in 0..<48000 { buffer.floatChannelData![c][i] = 0.2 * Float(sin(Double(i)*2 * .pi*hz/48000)) } }
        try file.write(from: buffer); file.close(); return url
    }
    func ready(_ session: PlaybackSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await session.nextReadyForMeasurement()), ContinuousClock.now < deadline { await session.tick(); await Task.yield() }
        let yes = await session.nextReadyForMeasurement(); XCTAssertTrue(yes)
    }
    func peak(_ block: AVAudioPCMBuffer) -> Float { (0..<Int(block.frameLength)).map { abs(block.floatChannelData![0][$0]) }.max() ?? 0 }

    /// A is rendered to its end so the queued handoff commits (and its save fails).
    /// The render and every control run in tasks that are only ever awaited with a
    /// deadline: a regression to unbounded retry then FAILS here rather than hanging.
    fileprivate func renderToTheBoundary(_ session: PlaybackSession, pump: Bool) -> (Task<Int, Never>, Finished) {
        let done = Finished()
        let task = Task { () -> Int in
            defer { done.mark() }
            var count = 0
            while count < 48000 {
                do { count += Int(try await session.renderSelected(UInt32(min(1024, 48000 - count)), throughPump: pump).frameLength) }
                catch { break }   // the abandoned handoff supersedes the in-flight render
            }
            return count
        }
        return (task, done)
    }
    fileprivate func fixture(_ body: (PlaybackSession, FaultyAdoptionStore, [UUID], CExpiryWall) async throws -> Void) async throws {
        let a = try tone(317), b = try tone(701)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let store = FaultyAdoptionStore(), wall = CExpiryWall()
        let provider = SequenceAssets(files: [a, b], kinds: [.music, .music], wall: wall)
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: store, assets: provider, resolver: provider, capabilities: provider, wall: wall, clock: ManualMonotonic(), automaticTick: false, initialGain: 1, manualDecodedRendering: true)
        try await session.startOwnedMedia([OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0]])
        try await ready(session)
        let ids = try await session.snapshot().queue.session.entries.map(\.id)
        try await body(session, store, ids, wall)
    }
    /// O1/O2 (W16-union-opus-02): with NO competing control, the abandonment itself must
    /// withdraw the staged B, leave Domain paused (not failed), and commit the queue's
    /// pause, so the durable queue no longer reads `intent=play` plus a stale handoff.
    func noControlFault(pump: Bool) async throws {
        try await fixture { session, store, ids, wall in
            wall.advance(1)
            let (rendering, done) = renderToTheBoundary(session, pump: pump)
            let finished = await done.wait(.seconds(4))
            XCTAssertTrue(finished, "abandonment must release the render within a bound, not hang (pump=\(pump))")
            guard finished else { return }   // leave the stuck session; never await it
            _ = await rendering.value
            let attempts = await store.adoptionAttempts
            XCTAssertEqual(attempts, 1 + PlaybackSession.handoffRetryLimit)
            let abandoned = await session.handoffPersistenceFailureCountForMeasurement(); XCTAssertEqual(abandoned, 1)
            // O2: the withdrawal itself, which only a control-free run can see.
            let staged = await session.engine.hasStagedHandoffForMeasurement(); XCTAssertFalse(staged, "staged B withdrawn")
            let state = try await session.snapshot()
            XCTAssertEqual(state.playback.intent, .pause(.user))
            XCTAssertNotEqual(state.playback.state, .failed, "a superseded handoff is not a source failure")
            XCTAssertNil(state.playback.error)
            XCTAssertTrue((state.queue.metadata.failures ?? []).isEmpty)
            let sourceFailures = await session.unattendedFailureCountForMeasurement(); XCTAssertEqual(sourceFailures, 0)
            // O1: the live and the durable queue both carry the pause at A's end.
            XCTAssertEqual(state.queue.current?.id, ids[0])
            XCTAssertEqual(state.queue.intent, .pause(.user), "queue pause committed after the barrier")
            XCTAssertNil(state.queue.metadata.handoff, "stale handoff cleared")
            XCTAssertGreaterThan(state.queue.session.position, 0.9, "position at the end of A, not the last periodic checkpoint")
            let saved = await store.saved
            XCTAssertEqual(saved?.current?.id, ids[0])
            XCTAssertEqual(saved?.intent, .pause(.user), "durable intent")
            XCTAssertNil(saved?.metadata.handoff, "durable handoff cleared")
            XCTAssertGreaterThan(saved?.session.position ?? 0, 0.9, "durable position")
            XCTAssertFalse(state.queue.metadata.recent.contains { $0.occurrence == ids[1] }, "B is not credited")
            // A plain Play once storage recovers does not credit A again.
            await store.heal()
            let creditedBefore = state.queue.metadata.recent.filter { $0.occurrence == ids[0] }.count
            try await session.resume()
            let after = try await session.snapshot()
            XCTAssertEqual(after.queue.metadata.recent.filter { $0.occurrence == ids[0] }.count, creditedBefore, "Play after recovery credits A no further")
            XCTAssertEqual(after.queue.session.entries.map(\.id), ids)
            await session.close()
        }
    }
    func testAbandonedHandoffWithoutControlsPausesTheQueueManual() async throws { try await noControlFault(pump: false) }
    func testAbandonedHandoffWithoutControlsPausesTheQueueThroughPump() async throws { try await noControlFault(pump: true) }

    func persistentFault(pump: Bool) async throws {
        try await fixture { session, store, ids, wall in
        wall.advance(1)
        let boundary = ContinuousClock.now
        let (rendering, renderDone) = renderToTheBoundary(session, pump: pump)
        // Controls issued while the save keeps failing must complete promptly.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await store.adoptionAttempts == 0, ContinuousClock.now < deadline { await Task.yield() }
        let attempted = await store.adoptionAttempts; XCTAssertGreaterThan(attempted, 0, "precondition: the adoption save was attempted")
        var controls: [(String, Task<Void, Error>, Elapsed)] = []
        for name in ["setGain", "seek", "pause"] {
            let elapsed = Elapsed(); let start = ContinuousClock.now
            let task = Task {
                defer { elapsed.value.withLock { $0 = start.duration(to: .now) } }
                switch name {
                case "setGain": try await session.setGain(0.5)
                case "seek": try await session.seek(0.1)
                default: try await session.pause()
                }
            }
            controls.append((name, task, elapsed))
        }
        let settle = ContinuousClock.now.advanced(by: .seconds(2))
        while controls.contains(where: { $0.2.value.withLock { $0 } == nil }), ContinuousClock.now < settle { try await Task.sleep(for: .milliseconds(5)) }
        for (name, task, elapsed) in controls {
            let took = elapsed.value.withLock { $0 }
            XCTAssertNotNil(took, "\(name) still pending 2 s into a persistent save fault")
            if let took { XCTAssertLessThan(took, .seconds(1), "\(name) responsive") }
            if took != nil { _ = try? await task.value }
        }
        // Never await a stuck task: unbounded retry would hang here instead of failing (O3).
        let renderFinished = await renderDone.wait(.seconds(4))
        XCTAssertTrue(renderFinished, "the render is released within a bound (pump=\(pump))")
        guard renderFinished, controls.allSatisfy({ $0.2.value.withLock { $0 } != nil }) else { return }
        _ = await rendering.value
        XCTAssertLessThan(boundary.duration(to: .now), .seconds(3))
        // Bounded: one attempt plus the retry limit, then a deterministic fallback.
        let attempts = await store.adoptionAttempts
        XCTAssertEqual(attempts, 1 + PlaybackSession.handoffRetryLimit)
        let abandoned = await session.handoffPersistenceFailureCountForMeasurement(); XCTAssertEqual(abandoned, 1)
        let state = try await session.snapshot()
        XCTAssertTrue(state.failures.contains { $0.contains("could not save the handoff") }, "fault surfaced: \(state.failures)")
        XCTAssertEqual(state.queue.current?.id, ids[0]); XCTAssertEqual(state.playback.context.occurrenceID, ids[0], "queue and Domain agree on A")
        XCTAssertEqual(state.playback.intent, .pause(.user))
        XCTAssertFalse(state.queue.metadata.recent.contains { $0.occurrence == ids[1] }, "B is not credited")
        XCTAssertTrue((state.queue.metadata.failures ?? []).isEmpty, "not a source failure")
        let sourceFailures = await session.unattendedFailureCountForMeasurement(); XCTAssertEqual(sourceFailures, 0)
        let staged = await session.engine.hasStagedHandoffForMeasurement(); XCTAssertFalse(staged)
        let rate = await session.engine.nativeRate(); XCTAssertEqual(rate, 0)
        let gain = await session.configuredGain(); XCTAssertEqual(gain, 0.5, accuracy: 0.000001)
        if let quiet = try? await session.renderSelected(1024) { XCTAssertEqual(peak(quiet), 0, "no B output after abandonment") }
        // Once storage recovers, ordinary selection commits B; resume plays it from its start.
        await store.heal()
        try await session.next(); try await session.resume()
        let healed = try await session.snapshot()
        XCTAssertEqual(healed.queue.current?.id, ids[1]); XCTAssertEqual(healed.playback.context.occurrenceID, ids[1])
        try await session.setGain(1)
        let block = try await session.renderSelected(1024)
        for i in 0..<Int(block.frameLength) {
            XCTAssertEqual(block.floatChannelData![0][i], 0.2 * Float(sin(Double(i) * 2 * .pi * 701 / 48000)), accuracy: 0.000002, "B from its start")
        }
        print("handoff persistent fault asserted pump=\(pump) attempts=\(attempts) controls=\(controls.map { "\($0.0)=\($0.2.value.withLock { $0 }.map { "\($0)" } ?? "pending")" })")
        await session.close()
        }
    }
    func testPersistentAdoptionSaveFaultManual() async throws { try await persistentFault(pump: false) }
    func testPersistentAdoptionSaveFaultThroughPump() async throws { try await persistentFault(pump: true) }
}
