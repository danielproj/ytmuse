@preconcurrency import AVFoundation
import Domain
import Queue
import XCTest
@testable import Playback

/// N2 (W16-dsp-opus-02): at a zero-overlap boundary the decoded reader switches
/// to the next input and clears its own `upcoming` up to the queued horizon
/// before native adoption, while the owner still references that next item.
/// Every owner path that resets decoded staging must withdraw the planned next
/// before the reset. These cases change a real control inside that window and
/// compare the remaining output against the independently generated sources.
final class StagedResetReworkTests: XCTestCase, @unchecked Sendable {
    func tone(_ hz: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("staged-reset-\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!; buffer.frameLength = 48000
        for c in 0..<2 { for i in 0..<48000 { buffer.floatChannelData![c][i] = 0.2 * Float(sin(Double(i)*2 * .pi*hz/48000)) } }
        try file.write(from: buffer); file.close(); return url
    }
    func ready(_ session: PlaybackSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))   // TH2: a condition-wait failure bound; real audio start-up is slower under load
        while !(await session.nextReadyForMeasurement()), ContinuousClock.now < deadline { await session.tick(); await Task.yield() }
        let yes = await session.nextReadyForMeasurement(); XCTAssertTrue(yes, "next re-planned after reset")
    }

    func scenario(_ action: String) async throws {
        let a = try tone(317), b = try tone(701)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let provider = SequenceAssets(files: [a, b], kinds: [.music, .music])
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: MemoryPersistence(), assets: provider, resolver: provider, capabilities: provider, clock: ManualMonotonic(), automaticTick: false, initialGain: 1, manualDecodedRendering: true)
        try await session.startOwnedMedia([OwnedMedia.items[0], OwnedMedia.items[1]])
        try await ready(session)
        let ids = try await session.snapshot().queue.session.entries.map(\.id)
        var rendered = 0
        while !(await session.engine.hasStagedHandoffForMeasurement()), rendered < 48000 {
            rendered += Int(try await session.renderSelected(1024).frameLength)
        }
        let staged = await session.engine.hasStagedHandoffForMeasurement()
        XCTAssertTrue(staged, "precondition: reader switched to next input before adoption"); XCTAssertLessThan(rendered, 48000)
        // A's logical sample position and the amplitude expected after the action.
        var aPosition = rendered, amplitude: Float = 0.2
        switch action {
        case "gain": try await session.setGain(0.5); amplitude = 0.1
        case "mute":
            try await session.setMuted(true)
            let silent = try await session.renderSelected(512)
            for i in 0..<Int(silent.frameLength) { XCTAssertEqual(silent.floatChannelData![0][i], 0, "muted output") }
            aPosition += Int(silent.frameLength)
            try await session.setMuted(false)
        case "seek": try await session.seek(0.25); aPosition = 12000
        case "timer": try await session.setTimer(.custom(600))
        default: XCTFail("unknown action \(action)")
        }
        let leftover = await session.engine.hasStagedHandoffForMeasurement()
        XCTAssertFalse(leftover, "reset withdrew the staged next together with the owner's reference")
        if action == "timer" {
            // An active timer suspends speculation; the boundary is an ordinary advance.
            await session.tick(); let planned = await session.nextReadyForMeasurement(); XCTAssertFalse(planned)
        } else { try await ready(session) }
        let domain = try await session.snapshot().playback.state
        XCTAssertEqual(domain, .playing, "control reset keeps Domain playing")
        // Remaining A from its exact logical position, then all of B, sample-exact.
        var bPosition = 0
        while bPosition < 48000 {
            let limit = aPosition < 48000 ? min(1024, 48000 - aPosition) : min(1024, 48000 - bPosition)
            let block = try await session.renderSelected(UInt32(limit))
            XCTAssertEqual(Int(block.frameLength), limit)
            for i in 0..<limit {
                let inA = aPosition < 48000
                let hz: Double = inA ? 317 : 701
                let offset: Int = inA ? aPosition + i : bPosition + i
                let phase: Double = Double(offset) * 2 * Double.pi * hz / 48000
                let expected: Float = amplitude * Float(sin(phase))
                XCTAssertEqual(block.floatChannelData![0][i], expected, accuracy: 0.000002, "\(action) \(hz) Hz at \(offset)")
            }
            if aPosition < 48000 { aPosition += limit } else { bPosition += limit }
            if aPosition == 48000, bPosition == 0, action == "timer" {
                // Ordinary (non-handoff) advance: Domain ends A, then starts B.
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))   // TH2: a condition-wait failure bound; real audio start-up is slower under load
                while ContinuousClock.now < deadline {
                    let now = try await session.snapshot()
                    if now.playback.state == .playing, now.queue.current?.id == ids[1] { break }
                    await session.tick(); await Task.yield()
                }
                let advanced = try await session.snapshot()
                XCTAssertEqual(advanced.playback.state, .playing); XCTAssertEqual(advanced.queue.current?.id, ids[1])
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))   // TH2: a condition-wait failure bound; real audio start-up is slower under load
        while try await session.snapshot().queue.current != nil, ContinuousClock.now < deadline { _ = try? await session.renderSelected(1024); await Task.yield() }
        let final = try await session.snapshot()
        XCTAssertNil(final.queue.current); XCTAssertTrue(final.failures.isEmpty)
        XCTAssertNil(final.playback.error)
        XCTAssertEqual(final.queue.metadata.recent.map(\.occurrence), ids, "each occurrence credited exactly once")
        print("staged reset asserted action=\(action) resumeAmplitude=\(amplitude)")
        await session.close()
    }
    func testGainChangeInStagedWindow() async throws { try await scenario("gain") }
    func testMuteToggleInStagedWindow() async throws { try await scenario("mute") }
    func testSeekInStagedWindow() async throws { try await scenario("seek") }
    func testTimerSetInStagedWindow() async throws { try await scenario("timer") }

    /// Wake resumes through Domain -> engine.play without a queue re-resolve. A
    /// sleep within ~1,100 frames after a gapless adoption previously resumed the
    /// paused player node with ~50,000 frames of inserted silence ahead of the
    /// remaining queued B samples while the logical position kept advancing, so
    /// B's tail later played under the next occurrence's identity.
    func wake(afterGaplessAdoptionAt stop: Int) async throws {
        let a = try tone(317), b = try tone(701)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let provider = SequenceAssets(files: [a, b], kinds: [.music, .music])
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: MemoryPersistence(), assets: provider, resolver: provider, capabilities: provider, clock: ManualMonotonic(), automaticTick: false, initialGain: 1, manualDecodedRendering: true)
        try await session.startOwnedMedia([OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0]])
        try await ready(session)
        let ids = try await session.snapshot().queue.session.entries.map(\.id)
        var count = 0
        while count < stop { count += Int(try await session.renderSelected(UInt32(min(1024, stop - count))).frameLength) }
        let adopted = try await session.snapshot()
        XCTAssertEqual(adopted.queue.current?.id, ids[1], "precondition: gapless adoption of B at \(stop)")
        await session.sleep()
        let silent = try await session.renderSelected(1024)
        XCTAssertEqual((0..<Int(silent.frameLength)).map { abs(silent.floatChannelData![0][$0]) }.max() ?? 0, 0, "asleep renders no audio")
        await session.wake(safeRoute: true, resumeEnabled: true)
        let resumed = try await session.snapshot()
        XCTAssertEqual(resumed.playback.state, .playing); XCTAssertEqual(resumed.playback.context.occurrenceID, ids[1])
        try await ready(session)
        // Remaining B from its exact offset, then the head of A#3, sample-exact.
        var offset = stop - 48000, item = 1
        while item == 1 || offset < 4096 {
            let limit = item == 1 ? min(1024, 48000 - offset) : 1024
            let block = try await session.renderSelected(UInt32(limit))
            XCTAssertEqual(Int(block.frameLength), limit)
            let hz: Double = item == 1 ? 701 : 317
            for i in 0..<Int(block.frameLength) {
                let phase: Double = Double(offset + i) * 2 * Double.pi * hz / 48000
                let expected: Float = 0.2 * Float(sin(phase))
                XCTAssertEqual(block.floatChannelData![0][i], expected, accuracy: 0.000002, "wake at \(stop): \(hz) Hz at \(offset + i)")
            }
            offset += Int(block.frameLength)
            if item == 1, offset == 48000 { item = 2; offset = 0 }
        }
        let after = try await session.snapshot()
        XCTAssertEqual(after.queue.current?.id, ids[2]); XCTAssertEqual(after.playback.context.occurrenceID, ids[2])
        // F3 contract: sleep closes B's interval and wake opens a new one, so B#2 has
        // one record per heard span (none before sleep if nothing of B was heard).
        let recent = after.queue.metadata.recent.map(\.occurrence)
        XCTAssertEqual(recent.first, ids[0]); XCTAssertTrue(recent.dropFirst().allSatisfy { $0 == ids[1] })
        XCTAssertEqual(recent.count, stop == 48000 ? 2 : 3, "one interval per heard span at \(stop)")
        XCTAssertTrue(after.failures.isEmpty); XCTAssertNil(after.playback.error)
        print("wake resume asserted stop=\(stop)")
        await session.close()
    }
    func testWakeImmediatelyAfterGaplessAdoption() async throws {
        for stop in [48000, 48128, 49152] { try await wake(afterGaplessAdoptionAt: stop) }
    }
    func testWakeLaterInAdoptedItem() async throws { try await wake(afterGaplessAdoptionAt: 52096) }
}
