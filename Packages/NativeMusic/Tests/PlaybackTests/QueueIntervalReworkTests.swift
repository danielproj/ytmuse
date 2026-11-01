@preconcurrency import AVFoundation
import Domain
import Queue
import XCTest
@testable import Playback
private final class OpusFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private struct HeldQueueResolver: PlaybackResolver {
    let base: SequenceAssets
    let gate: CPreparationGate
    func validateEligibility(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<Capability> { await base.validateEligibility(media, context: context) }
    func resolve(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<[MediaVariant]> {
        if media == OwnedMedia.items[1] { await gate.hold() }
        return await base.resolve(media, context: context)
    }
    func refresh(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<MediaVariant> { await base.refresh(variant, context: context) }
    func report(_ event: ServicePlaybackEvent, context: PlaybackContext) async -> PlaybackResult<Void> { await base.report(event, context: context) }
}
final class QueueIntervalReworkTests: XCTestCase, @unchecked Sendable {
    func wave(frames: Int, rate: Double = 48000, level: Float, hz: Double, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("W16-opus01-" + UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for offset in stride(from: 0, to: frames, by: 4096) {
            let count = min(4096, frames - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!; buffer.frameLength = UInt32(count)
            for c in 0..<Int(channels) { for i in 0..<count { buffer.floatChannelData![c][i] = level * Float(sin(Double(offset + i) * 2 * .pi * hz / rate)) } }
            try file.write(from: buffer)
        }
        file.close(); return url
    }

    // R2: a held speculative NEXT-item provider must not hold the CURRENT item's start.
    func testR2HeldNextPreparationDoesNotBlockCurrentStart() async throws {
        for mode in ["provider", "resolver", "normalization"] {
        let a = try wave(frames: 96000, level: 0.2, hz: 317); let b = try wave(frames: 96000, level: 0.15, hz: 701)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let provider = SequenceAssets(files: [a, b], kinds: [.music, .music]); let gate = CPreparationGate()
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: MemoryPersistence(), assets: mode == "resolver" ? provider : HeldSequenceAssets(base: provider, gate: gate), resolver: mode == "resolver" ? HeldQueueResolver(base: provider, gate: gate) : provider, capabilities: provider, automaticTick: false, initialGain: 1, manualDecodedRendering: true, effects: AudioEffects(normalize: mode == "normalization"))
        let done = OpusFlag()
        let starting = Task { try await session.startOwnedMedia(OwnedMedia.items); done.set() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.waiting()), ContinuousClock.now < deadline { await Task.yield() }
        let entered = await gate.waiting(); XCTAssertTrue(entered)
        try await Task.sleep(for: .milliseconds(750))
        let completed = done.get()
        let requested = await session.engine.requestedPlay()
        let state = await session.engine.nativeRate()
        let block = try await session.renderSelected(1024)
        let rms = sqrt((0..<Int(block.frameLength)).map { Double(block.floatChannelData![0][$0]) * Double(block.floatChannelData![0][$0]) }.reduce(0, +) / Double(max(1, Int(block.frameLength))))
        print("W16-OPUS01 R2 next-item provider held 750ms: currentStartReturned=\(completed) currentPlayRequested=\(requested) nativeRate=\(state) currentRenderRMS=\(rms)")
        XCTAssertGreaterThan(rms, 0.05)
        await gate.release(); _ = try? await starting.value
        let after = try await session.renderSelected(1024)
        let afterPeak = (0..<Int(after.frameLength)).map { abs(after.floatChannelData![0][$0]) }.max() ?? 0
        print("W16-OPUS01 R2 after next-item release: currentStartReturned=\(done.get()) renderPeak=\(afterPeak)")
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await session.nextReadyForMeasurement()), ContinuousClock.now < readyDeadline { await Task.yield() }
        let ready = await session.nextReadyForMeasurement(); XCTAssertTrue(ready)
        var rendered = 2048
        while rendered < 96000 {
            let block = try await session.renderSelected(UInt32(min(1024, 96000-rendered)))
            rendered += Int(block.frameLength)
        }
        // Normalization selects the existing limiter with its declared DSP tail.
        for _ in 0..<5 {
            if try await session.snapshot().queue.current?.media == OwnedMedia.items[1] { break }
            _ = try await session.renderSelected(1024)
        }
        let handed = try await session.snapshot().queue.current?.media
        XCTAssertEqual(handed, OwnedMedia.items[1])
        await session.close()
        XCTAssertTrue(completed, "current item start waited on speculative next-item provider")
        XCTAssertTrue(requested, "current item was not playing while next-item preparation was held")
        }
    }

    // R3: a natural-EOF history interval must belong to the item that was listened to.
    func testR3ManualNextDoesNotCarryPreviousListeningStartIntoHistory() async throws {
        let a = try wave(frames: 96000, level: 0.2, hz: 317); let b = try wave(frames: 96000, level: 0.15, hz: 701)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let wall = CExpiryWall(); let origin = wall.now()
        let provider = SequenceAssets(files: [a, b], kinds: [.music, .music], wall: wall)
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: MemoryPersistence(), assets: provider, resolver: provider, capabilities: provider, wall: wall, automaticTick: false, initialGain: 1, manualDecodedRendering: true)
        try await session.startOwnedMedia(OwnedMedia.items)
        _ = try await session.renderSelected(1024)
        wall.advance(100)
        try await session.next()
        let switched = wall.now()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await session.queueSnapshotForMeasurement().current != nil, ContinuousClock.now < deadline {
            _ = try? await session.renderSelected(1024); await Task.yield()
        }
        let final = try await session.queueSnapshotForMeasurement()
        for entry in final.metadata.recent {
            print("W16-OPUS01 R3 history media=\(entry.media) startedOffset=\(entry.started.timeIntervalSince(origin)) endedOffset=\(entry.ended.timeIntervalSince(origin)) manualNextOffset=\(switched.timeIntervalSince(origin))")
        }
        await session.close()
        XCTAssertNil(final.current)
        let second = final.metadata.recent.first { $0.media == OwnedMedia.items[1].rawValue }
        XCTAssertNotNil(second, "item B natural EOF recorded no local history")
        if let second { XCTAssertGreaterThanOrEqual(second.started, switched, "B's history interval starts while A (not B) was playing") }
    }

    func testManualOccurrencesAndPauseIntervals() async throws {
        let a = try wave(frames: 96000, level: 0.2, hz: 317)
        let b = try wave(frames: 96000, level: 0.15, hz: 701)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let wall = CExpiryWall(); let origin = wall.now()
        let provider = SequenceAssets(files: [a,b], kinds: [.music,.music], wall: wall)
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: MemoryPersistence(), assets: provider, resolver: provider, capabilities: provider, wall: wall, automaticTick: false, initialGain: 1, manualDecodedRendering: true)
        try await session.startOwnedMedia([OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0]])
        let initial = try await session.snapshot().queue
        let ids = initial.session.entries.map(\.id)
        wall.advance(10); try await session.next()
        wall.advance(20); try await session.previous(directItem: true)
        wall.advance(30); try await session.select(ids[2])
        wall.advance(40); try await session.pause()
        let paused = try await session.snapshot().queue.metadata.recent
        XCTAssertEqual(paused.map(\.occurrence), [ids[0],ids[1],ids[0],ids[2]])
        XCTAssertEqual(paused.map { $0.started.timeIntervalSince(origin) }, [0,10,30,60])
        XCTAssertEqual(paused.map { $0.ended.timeIntervalSince(origin) }, [10,30,60,100])
        wall.advance(500); try await session.resume()
        wall.advance(5)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var rendered = 0
        while rendered < 96000 {
            let block = try await session.renderSelected(UInt32(min(1024, 96000-rendered)))
            rendered += Int(block.frameLength)
        }
        while try await session.queueSnapshotForMeasurement().current != nil, ContinuousClock.now < deadline { await Task.yield() }
        let final = try await session.queueSnapshotForMeasurement()
        XCTAssertNil(final.current)
        XCTAssertEqual(final.metadata.recent.count, 5)
        XCTAssertEqual(final.metadata.recent.last?.occurrence, ids[2])
        XCTAssertEqual(final.metadata.recent.last?.started.timeIntervalSince(origin), 600)
        XCTAssertEqual(final.metadata.recent.last?.ended.timeIntervalSince(origin), 605)
        await session.close()
    }
}
