@preconcurrency import AVFoundation
import Domain
import Queue
import XCTest
@testable import Playback

private struct AdoptionSaveError: Error {}
actor Flag { private var raised = false; func raise() { raised = true }; var isRaised: Bool { raised } }
private actor AdoptionStore: QueuePersistence {
    var saved: QueueSnapshot?
    var mode = 0
    var attempts = 0
    let gate = CPreparationGate()
    func arm(_ mode: Int) { self.mode = mode }
    func load(context: RequestContext) -> QueueSnapshot? { saved }
    func save(_ value: QueueSnapshot, context: RequestContext) async throws {
        if let saved, saved.metadata.handoff != nil, saved.current?.id != value.current?.id {
            attempts += 1
            let selected = mode; mode = 0
            if selected == 2 { throw AdoptionSaveError() }
            if selected == 1 { await gate.hold() }
        }
        saved = value
    }
}
/// TH3: holds the save that commits the exhaustion (the first save whose queue has no current item) once armed; every other save passes.
private actor ExhaustionHoldStore: QueuePersistence {
    var saved: QueueSnapshot?
    var hold: HeldPoint?
    func arm(_ hold: HeldPoint) { self.hold = hold }
    func load(context: RequestContext) -> QueueSnapshot? { saved }
    func save(_ value: QueueSnapshot, context: RequestContext) async throws {
        if value.current == nil, let hold { self.hold = nil; await hold.hold() }
        saved = value
    }
}
private actor AdoptionReadPermission {
    var error: DomainError?
    func deny(_ error: DomainError) { self.error = error }
    func check() throws { if let error { throw error } }
}
private struct AdoptionAuthorizedAssets: NativeAssetProvider {
    let file: URL
    let permission: AdoptionReadPermission
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { file }
    func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession {
        NativeAssetSession(asset: AVURLAsset(url: file), userSeekable: true, decodedAccess: .authorizedNative, authorizeUserSeek: {}, authorizeDecodedRead: { try await permission.check() })
    }
}
final class QueueAdoptionReworkTests: XCTestCase, @unchecked Sendable {
    func tone(_ hz: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-adoption-\(UUID()).wav")
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
    func matches(_ block: AVAudioPCMBuffer, hz: Double, offset: Int) {
        for i in 0..<Int(block.frameLength) {
            XCTAssertEqual(block.floatChannelData![0][i], 0.2 * Float(sin(Double(offset+i)*2 * .pi*hz/48000)), accuracy: 0.000002, "known source at native offset")
        }
    }
    func scenario(_ action: String, crossfade: Double = 0, fail: Bool = false, pump: Bool = false) async throws {
        let a = try tone(317), b = try tone(701)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let store = AdoptionStore(), wall = CExpiryWall()
        let origin = wall.now()
        let provider = SequenceAssets(files: [a,b], kinds: [.music,.music], wall: wall)
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: store, assets: provider, resolver: provider, capabilities: provider, wall: wall, clock: ManualMonotonic(), automaticTick: false, initialGain: 1, manualDecodedRendering: true, effects: AudioEffects(crossfade: crossfade))
        defer { Task { await store.gate.release(); await session.close() } }
        try await session.startOwnedMedia([OwnedMedia.items[0],OwnedMedia.items[1],OwnedMedia.items[0]])
        try await ready(session)
        let ids = try await session.snapshot().queue.session.entries.map(\.id)
        await store.arm(fail ? 2 : 1)
        let boundary = 48000 - Int(crossfade*48000)
        wall.advance(1)
        let rendering = Task {
            var count = 0
            while count < boundary {
                let block = try await session.renderSelected(UInt32(min(1024,boundary-count)), throughPump: pump)
                count += Int(block.frameLength)
            }
            return count
        }
        if !fail {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(await store.gate.waiting()), ContinuousClock.now < deadline { await Task.yield() }
            let held = await store.gate.waiting(); XCTAssertTrue(held)
            // Read through the same public snapshot while save remains held.
            let stable = try await session.snapshot()
            XCTAssertEqual(stable.queue.current?.id, ids[0]); XCTAssertEqual(stable.playback.context.occurrenceID, ids[0])
        }
        let command = Task { () -> Void in
            switch action {
            case "seek": try await session.seek(0.25)
            case "scrub": await session.coalescedSeek(0.25); try await Task.sleep(for: .milliseconds(180))
            case "pause": try await session.sendQueue(.pause(.user), origin: .mediaKey)
            case "sleep": await session.sleep()
            case "next": try await session.sendQueue(.nextItem, origin: .menu)
            case "previous": try await session.sendQueue(.previousItem, origin: .shortcut)
            case "select": try await session.sendQueue(.select(ids[2]), origin: .appleScript)
            case "remove":
                do { try await session.sendQueue(.remove([ids[1]]), origin: .menu); XCTFail("current B cannot be removed") }
                catch QueueError.immutable {}
            case "quit": await session.close()
            default: break
            }
        }
        if !fail {
            try await Task.sleep(for: .milliseconds(action == "scrub" ? 180 : 40))
            if action == "quit" { let rate = await session.engine.nativeRate(); XCTAssertEqual(rate, 0) }
            await store.gate.release()
        }
        if fail && pump {
            // The production node can already have heard B while A's identity save
            // retries. Advance the disconnected graph during that same retry wait.
            let retryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while await session.handoffRetryCountForMeasurement() == 0, ContinuousClock.now < retryDeadline { await Task.yield() }
            let heard = try await session.renderSelected(1024, throughPump: true)
            matches(heard, hz: 701, offset: 0)
        }
        if action == "quit" { _ = try? await rendering.value }
        else { let count = try await rendering.value; XCTAssertEqual(count, boundary) }
        try await command.value
        if action == "quit" {
            let persisted = await store.saved
            let saved = try XCTUnwrap(persisted)
            XCTAssertEqual(saved.current?.id, ids[1]); XCTAssertEqual(saved.intent,.pause(.quit))
            XCTAssertEqual(saved.metadata.recent.map(\.occurrence), [ids[0]])
            XCTAssertEqual(saved.metadata.recent.first?.started, origin)
            XCTAssertEqual(saved.metadata.recent.first?.ended, origin.addingTimeInterval(1))
            let restored = try QueueMachine(restoring: saved, supportsAutoplay: false)
            XCTAssertEqual(restored.current, ids[1]); XCTAssertEqual(restored.intent,.pause(.restored))
            return
        }
        print("adoption settled action=\(action)")
        var mid = try await session.snapshot()
        XCTAssertEqual(mid.queue.current?.id, mid.playback.context.occurrenceID)
        XCTAssertTrue(mid.failures.isEmpty); XCTAssertTrue((mid.queue.metadata.failures ?? []).isEmpty)
        if action == "pause" { XCTAssertEqual(mid.playback.intent,.pause(.user)); try await session.resume() }
        if action == "sleep" { await session.wake(safeRoute: true, resumeEnabled: true) }
        if action == "scrub" {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while await session.nativeSeekCount() == 0, ContinuousClock.now < deadline { await Task.yield() }
        }
        mid = try await session.snapshot()
        XCTAssertEqual(mid.queue.current?.id, mid.playback.context.occurrenceID)
        let expectedCurrent = action == "previous" ? ids[0] : (["next","select"].contains(action) ? ids[2] : ids[1])
        XCTAssertEqual(mid.queue.current?.id, expectedCurrent)
        if crossfade == 0 {
            let offset = Int((await session.nativePosition()*48000).rounded())
            if fail && pump { XCTAssertEqual(offset,1024,"already-heard B opening must not replay after retry") }
            if ["seek","scrub"].contains(action) { XCTAssertEqual(offset,12000) }
            let block = try await session.renderSelected(1024, throughPump: pump)
            matches(block, hz: expectedCurrent == ids[1] ? 701 : 317, offset: offset)
        }
        if fail {
            let retries = await session.handoffRetryCountForMeasurement(); XCTAssertEqual(retries,1)
            let sourceFailures = await session.unattendedFailureCountForMeasurement(); XCTAssertEqual(sourceFailures,0)
        }
        // Continue each actual occurrence to its own exact end. No extra Resume.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var previous = mid.queue.current?.id
        while let current = try await session.queueSnapshotForMeasurement().current, ContinuousClock.now < deadline {
            let state = try await session.snapshot()
            if state.playback.state != .playing { await Task.yield(); continue }
            if !state.queue.upcoming.isEmpty { try await ready(session) }
            let position = await session.nativePosition()
            let remaining = max(1, Int(((1-position)*48000).rounded()))
            // TH3: between the end of the last occurrence and the queue clearing, the engine has retired its backend and refuses to render. The state read above can
            // be older than that, so the entry says "ended" (nil) instead of throwing; `testTheRenderEntryReadsTheWindowBetweenTheEndAndTheQueueClearingAsAnEnd` holds the window.
            guard let block = try await session.renderSelectedUnlessEnded(UInt32(min(1024,remaining)), throughPump: pump) else { await Task.yield(); continue }
            XCTAssertGreaterThan(block.frameLength,0)
            let after = try await session.snapshot()
            if let next = after.queue.current?.id, next != current.id {
                XCTAssertEqual(after.playback.context.occurrenceID,next)
            }
            if after.queue.current?.id == previous, after.playback.state == .ended { await Task.yield() }
            previous = after.queue.current?.id
            await Task.yield()
        }
        let final = try await session.snapshot()
        XCTAssertNil(final.queue.current)
        XCTAssertTrue(final.failures.isEmpty); XCTAssertTrue((final.queue.metadata.failures ?? []).isEmpty)
        let expected: [UUID] = action == "previous" ? [ids[0],ids[0],ids[1],ids[2]] : (["next","select"].contains(action) ? [ids[0],ids[2]] : [ids[0],ids[1],ids[2]])
        XCTAssertEqual(final.queue.metadata.recent.map(\.occurrence), expected, "action=\(action)")
        XCTAssertEqual(final.queue.metadata.recent.map { $0.started.timeIntervalSince(origin) }, [0] + Array(repeating: 1, count: expected.count-1))
        XCTAssertEqual(final.queue.metadata.recent.map { $0.ended.timeIntervalSince(origin) }, Array(repeating: 1, count: expected.count))
        XCTAssertTrue(final.queue.session.entries.allSatisfy(\.consumed))
        print("queue adoption asserted action=\(action) fade=\(crossfade) pump=\(pump) failedSave=\(fail) records=\(expected.count)")
        await session.close()
    }
    func testPumpAuthorizationFailureRemainsSourceFailure() async throws {
        let file = try tone(317)
        defer { try? FileManager.default.removeItem(at: file) }
        let permission = AdoptionReadPermission()
        let assets = AdoptionAuthorizedAssets(file: file, permission: permission)
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: MemoryPersistence(), assets: assets, resolver: OwnedMedia(), capabilities: OwnedMedia(), automaticTick: false, initialGain: 1, manualDecodedRendering: true)
        try await session.startOwnedMedia([OwnedMedia.items[0]])
        _ = try await session.renderSelected(1024, throughPump: true)
        await permission.deny(.expiredMedia)
        try await session.engine.serviceDecodedForMeasurement()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await session.snapshot().queue.metadata.failures?.isEmpty ?? true, ContinuousClock.now < deadline { await Task.yield() }
        let state = try await session.snapshot()
        XCTAssertEqual(state.playback.error, .expiredMedia)
        XCTAssertEqual(state.queue.metadata.failures?.count, 1)
        XCTAssertEqual(state.queue.metadata.failures?.first?.occurrence, state.queue.current?.id)
        let retries = await session.handoffRetryCountForMeasurement(); XCTAssertEqual(retries,0)
        let rate = await session.engine.nativeRate(); XCTAssertEqual(rate,0)
        await session.close()
    }
    func testClearingTimerPreservesStagedNextWindow() async throws {
        let a = try tone(317), b = try tone(701)
        defer { try? FileManager.default.removeItem(at:a); try? FileManager.default.removeItem(at:b) }
        let provider = SequenceAssets(files:[a,b], kinds:[.music,.music])
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: MemoryPersistence(), assets: provider, resolver: provider, capabilities: provider, clock: ManualMonotonic(), automaticTick:false, initialGain:1, manualDecodedRendering:true)
        try await session.startOwnedMedia([OwnedMedia.items[0],OwnedMedia.items[1],OwnedMedia.items[0]])
        try await ready(session)
        let ids = try await session.snapshot().queue.session.entries.map(\.id)
        var count = 0
        while !(await session.engine.hasStagedHandoffForMeasurement()), count < 40000 {
            count += Int(try await session.renderSelected(1024).frameLength)
        }
        let staged = await session.engine.hasStagedHandoffForMeasurement()
        XCTAssertTrue(staged); XCTAssertLessThan(count,48000)
        try await session.setTimer(nil)
        let retained = await session.engine.hasStagedHandoffForMeasurement(); XCTAssertTrue(retained)
        while count < 144000 {
            let boundary = ((count/48000)+1)*48000
            let block = try await session.renderSelected(UInt32(min(1024,boundary-count)))
            matches(block,hz:count/48000 == 1 ? 701 : 317,offset:count%48000)
            count += Int(block.frameLength)
            if count == 48000 { try await ready(session) }
        }
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while try await session.snapshot().queue.current != nil, ContinuousClock.now < deadline { await Task.yield() }
        let final = try await session.snapshot()
        XCTAssertNil(final.queue.current); XCTAssertTrue(final.failures.isEmpty)
        XCTAssertEqual(final.queue.metadata.recent.map(\.occurrence),ids)
        await session.close()
    }
    /// TH1: the device-free render entry reads the context, then enters the engine. A transition the session itself completes in between (stood in for here by a
    /// deterministic hook that runs `next()` at exactly that point) used to reach the caller as `staleContext`, and failed whole-package runs at random. The entry
    /// now re-reads once the context has really moved on, and renders the new occurrence.
    func testTheRenderEntryRereadsAContextTheSessionMovedPastInsteadOfFailing() async throws {
        let a = try tone(317), b = try tone(701)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let provider = SequenceAssets(files: [a, b], kinds: [.music, .music])
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: MemoryPersistence(), assets: provider, resolver: provider, capabilities: provider, clock: ManualMonotonic(), automaticTick: false, initialGain: 1, manualDecodedRendering: true)
        try await session.startOwnedMedia([OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0]])
        try await ready(session)
        let ids = try await session.snapshot().queue.session.entries.map(\.id)
        let none = await session.renderRereadsForMeasurement(); XCTAssertEqual(none, 0)
        await session.setRenderHookForMeasurement { try? await session.next() }
        let block = try await session.renderSelected(1024)
        XCTAssertEqual(block.frameLength, 1024)
        let rereads = await session.renderRereadsForMeasurement(); XCTAssertEqual(rereads, 1, "the refused context was re-read exactly once")
        let current = try await session.snapshot().queue.current?.id
        XCTAssertEqual(current, ids[1], "the block came from the occurrence the session moved to")
        // The seam is one-shot: an ordinary render afterwards re-reads nothing.
        _ = try await session.renderSelected(1024)
        let after = await session.renderRereadsForMeasurement(); XCTAssertEqual(after, 1)
        await session.close()
    }
    /// TH1 rework 2 (RL6): the player reports `.ended` BEFORE the queue commits the exhaustion (the checkpoint is written first, then `current` is cleared).
    /// The held save keeps that window open; a seek inside it must be refused exactly like a seek past the end: it must not reach the command owner (no
    /// native seek), must not save a checkpoint, and must not change the queue version. Before the fix it did all three.
    func testASeekBetweenTheEndAndTheQueueClearingIsRefusedLikeASeekPastTheEnd() async throws {
        let a = try tone(317)
        defer { try? FileManager.default.removeItem(at: a) }
        let store = HeldQueueStore(), hold = HeldPoint()
        let provider = SequenceAssets(files: [a], kinds: [.music])
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: store, assets: provider, resolver: provider, capabilities: provider, clock: ManualMonotonic(), automaticTick: false, initialGain: 1, manualDecodedRendering: true)
        try await session.startOwnedMedia([OwnedMedia.items[0]])
        var count = 0
        while count < 48000 - 1024 { count += Int(try await session.renderSelected(1024).frameLength) }
        await store.arm(hold)                                         // the first save from here on is the checkpoint the end writes
        while count < 48000 { count += Int(try await session.renderSelected(UInt32(min(1024, 48000 - count))).frameLength) }
        await hold.wait()                                              // the end has been reported; its checkpoint is held, so the queue has not cleared
        let during = try await session.snapshot()
        XCTAssertEqual(during.playback.state, .ended, "the window is open: the player has ended")
        XCTAssertNotNil(during.queue.current, "the window is open: the queue has not cleared its current item")
        let versionBefore = during.queue.session.version, intentBefore = during.queue.intent
        let writesBefore = await store.writes.count, seeksBefore = await session.nativeSeekCount()
        let finished = Flag()
        let seeking = Task { _ = try? await session.seek(0.25); await finished.raise() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await finished.isRaised), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let returned = await finished.isRaised
        let writesDuring = await store.writes.count, seeksDuring = await session.nativeSeekCount()
        let inside = try await session.snapshot()
        await hold.release()                                          // let the end commit, whatever the seek did
        _ = await seeking.value
        XCTAssertTrue(returned, "the seek is refused at once, it does not wait on the held checkpoint")
        XCTAssertEqual(seeksDuring, seeksBefore, "no command reached the owner")
        XCTAssertEqual(writesDuring, writesBefore, "no checkpoint was saved by the seek")
        XCTAssertEqual(inside.queue.session.version, versionBefore, "the queue version did not change")
        XCTAssertEqual(inside.queue.intent, intentBefore)
        XCTAssertEqual(inside.playback.state, .ended)
        let settleBy = ContinuousClock.now.advanced(by: .seconds(5))
        while try await session.snapshot().queue.current != nil, ContinuousClock.now < settleBy { await Task.yield() }
        let final = try await session.snapshot()
        XCTAssertNil(final.queue.current, "the end then commits as before"); XCTAssertEqual(final.playback.state, .ended)
        await session.close()
    }
    /// TH3: the exact window behind the `staleContext` that `testHeldCommitControlsAndContinuation` threw at random under load. After the last occurrence has ended, the
    /// session retires the decoded backend and only then does the queue commit the exhaustion. A loop that decided to render a moment earlier reaches the engine in that
    /// window; the engine refuses (no backend) while the context has not changed and no adoption or control is running. The held save keeps the window open.
    func testTheRenderEntryReadsTheWindowBetweenTheEndAndTheQueueClearingAsAnEnd() async throws {
        let a = try tone(317)
        defer { try? FileManager.default.removeItem(at: a) }
        let store = ExhaustionHoldStore(), hold = HeldPoint()
        let provider = SequenceAssets(files: [a], kinds: [.music])
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: store, assets: provider, resolver: provider, capabilities: provider, clock: ManualMonotonic(), automaticTick: false, initialGain: 1, manualDecodedRendering: true)
        try await session.startOwnedMedia([OwnedMedia.items[0]])
        // Control: while the item plays, the entry renders.
        guard let early = try await session.renderSelectedUnlessEnded(1024) else { return XCTFail("an ordinary render returns its block") }
        XCTAssertEqual(early.frameLength, 1024)
        var count = Int(early.frameLength)
        await store.arm(hold)
        while count < 48000 { count += Int(try await session.renderSelected(UInt32(min(1024, 48000 - count))).frameLength) }
        await hold.wait()
        // The window is really open: ended, the queue has not cleared, and the engine has retired its backend (without these the test would prove nothing).
        var window = try await session.snapshot()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await session.engine.hasDecodedBackendForMeasurement(), ContinuousClock.now < deadline { await Task.yield(); window = try await session.snapshot() }
        let backend = await session.engine.hasDecodedBackendForMeasurement()
        XCTAssertEqual(window.playback.state, .ended, "the window is open: the player has ended")
        XCTAssertNotNil(window.queue.current, "the window is open: the queue has not cleared its current item")
        XCTAssertFalse(backend, "the window is open: the engine has retired its backend")
        // The plain entry refuses, as the loop saw it (a refusal with no adoption, no control and an unchanged context).
        do { _ = try await session.renderSelected(1024); XCTFail("the engine has nothing to render in this window") } catch DomainError.staleContext {}
        // The entry for a loop reads it as the end.
        if let block = try await session.renderSelectedUnlessEnded(1024) { XCTFail("the end renders nothing (got \(block.frameLength) frames)") }
        await hold.release()
        let settleBy = ContinuousClock.now.advanced(by: .seconds(5))
        while try await session.snapshot().queue.current != nil, ContinuousClock.now < settleBy { await Task.yield() }
        let final = try await session.snapshot()
        XCTAssertNil(final.queue.current, "the end then commits as before")
        await session.close()
        // Control: a refusal from a state that is NOT the end still throws (a closed session is paused/stopped, not ended).
        let b = try tone(701)
        defer { try? FileManager.default.removeItem(at: b) }
        let other = SequenceAssets(files: [b], kinds: [.music])
        let second = try await PlaybackSession.open(context: ownedContext(), persistence: MemoryPersistence(), assets: other, resolver: other, capabilities: other, clock: ManualMonotonic(), automaticTick: false, initialGain: 1, manualDecodedRendering: true)
        try await second.startOwnedMedia([OwnedMedia.items[0]])
        _ = try await second.renderSelected(1024)
        await second.close()
        let stateAfterClose = try await second.snapshot().playback.state
        XCTAssertNotEqual(stateAfterClose, .ended, "precondition of the control")
        do { _ = try await second.renderSelectedUnlessEnded(1024); XCTFail("a refusal outside the end must still throw") } catch DomainError.staleContext {}
    }
    /// TH5 (TH3 critic L1): what a control leaves behind when it arrives at the very end of the queue. `insideCheckpoint` holds the end's checkpoint save (the
    /// first save after the end), so the control lands in the window between the player's `.ended` and the queue committing the exhaustion; otherwise the control
    /// arrives after the end has fully committed (a normal end). Both finish the same way: the queue has cleared, nothing is current, and the control's own effect
    /// (paused for a reason) is applied.
    private struct EndOutcome: Equatable, CustomStringConvertible {
        var state: PlaybackState, intent: PlaybackIntent, queueCleared: Bool, recent: Int, failures: [String]
        var description: String { "state=\(state) intent=\(intent) cleared=\(queueCleared) recent=\(recent) failures=\(failures)" }
    }
    private func endOutcome(control: String, insideCheckpoint: Bool, replay: Bool = false) async throws -> (outcome: EndOutcome, windowWasOpen: Bool, framesAfterPlay: Int) {
        let a = try tone(317)
        defer { try? FileManager.default.removeItem(at: a) }
        let store = HeldQueueStore(), hold = HeldPoint()
        let provider = SequenceAssets(files: [a], kinds: [.music])
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: store, assets: provider, resolver: provider, capabilities: provider, clock: ManualMonotonic(), automaticTick: false, initialGain: 1, manualDecodedRendering: true)
        try await session.startOwnedMedia([OwnedMedia.items[0]])
        var count = 0
        while count < 48000 - 1024 { count += Int(try await session.renderSelected(1024).frameLength) }
        if insideCheckpoint { await store.arm(hold) }                 // the first save from here on is the checkpoint the end writes
        while count < 48000 { count += Int(try await session.renderSelected(UInt32(min(1024, 48000 - count))).frameLength) }
        var windowWasOpen = false
        if insideCheckpoint {
            await hold.wait()
            let during = try await session.snapshot()
            windowWasOpen = during.playback.state == .ended && during.queue.current != nil
        } else {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while try await session.snapshot().queue.current != nil, ContinuousClock.now < deadline { await Task.yield() }
        }
        let issued = Task { () -> Void in
            switch control {
            case "pause": try? await session.pause(.user)
            case "playPause": try? await session.playPause()
            case "sleep": await session.sleep()
            case "queuePause": try? await session.sendQueue(.pause(.user))   // the media-key / remote-command route
            default: XCTFail("unknown control \(control)")
            }
        }
        // Whatever the control did while the checkpoint was held, the end then commits.
        try await Task.sleep(for: .milliseconds(200))
        if insideCheckpoint { await hold.release() }
        _ = await issued.value
        let settleBy = ContinuousClock.now.advanced(by: .seconds(5))
        while try await session.snapshot().queue.current != nil, ContinuousClock.now < settleBy { await Task.yield() }
        let final = try await session.snapshot()
        var frames = 0
        if replay {
            // A later Play must not replay the finished item: with nothing current there is nothing to render.
            if control == "sleep" { await session.wake(safeRoute: true, resumeEnabled: true) } else { try? await session.resume() }
            try await Task.sleep(for: .milliseconds(100))
            for _ in 0..<5 {
                guard try await session.snapshot().playback.state == .playing else { break }
                if let block = try? await session.renderSelectedUnlessEnded(1024) { frames += Int(block.frameLength) }
            }
        }
        let outcome = EndOutcome(state: final.playback.state, intent: final.playback.intent, queueCleared: final.queue.current == nil, recent: final.queue.metadata.recent.count, failures: final.failures)
        await session.close()
        return (outcome, windowWasOpen, frames)
    }
    /// TH5 (TH3 critic L1): a pause, play/pause or sleep that arrives inside the end's checkpoint save used to bump the session's sequence and so cancel the
    /// advance that commits the exhaustion: the finished last item stayed current, paused, and the next Play replayed about 19 ms of it. TH1 rework 2 fixed the
    /// same window for seek. Now each leaves exactly the state a normal end followed by the same control leaves.
    func testAPauseOrSleepInsideTheEndsCheckpointBehavesLikeANormalEnd() async throws {
        for control in ["pause", "playPause", "sleep", "queuePause"] {
            let normal = try await endOutcome(control: control, insideCheckpoint: false, replay: true)
            XCTAssertFalse(normal.windowWasOpen, "\(control): the normal end is not inside the window")
            XCTAssertTrue(normal.outcome.queueCleared, "\(control): control run clears the queue")
            let held = try await endOutcome(control: control, insideCheckpoint: true, replay: true)
            XCTAssertTrue(held.windowWasOpen, "\(control): the window was really open when the control arrived (ended, queue not yet cleared)")
            XCTAssertEqual(held.outcome, normal.outcome, "\(control): the same final state as a normal end")
            XCTAssertTrue(held.outcome.queueCleared, "\(control): the finished item is not left current")
            XCTAssertEqual(held.framesAfterPlay, 0, "\(control): a later Play replays nothing of the finished item")
            XCTAssertEqual(normal.framesAfterPlay, 0)
        }
    }
    func testHeldCommitControlsAndContinuation() async throws {
        for action in ["none","seek","scrub","pause","sleep","next","previous","select","remove","quit"] { try await scenario(action) }
    }
    func testHeldCrossfadeSeek() async throws { try await scenario("seek", crossfade: 0.25) }
    func testManualPersistenceFailureControl() async throws { try await scenario("none",fail: true) }
    func testPumpPersistenceFailureRetainsTransition() async throws { try await scenario("none",fail: true,pump: true) }
}
