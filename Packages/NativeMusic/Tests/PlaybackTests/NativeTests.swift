import Testing
import Foundation
import Domain
import Queue
@testable import Playback

actor MemoryPersistence: QueuePersistence {
    var state: QueueSnapshot?
    func load(context: RequestContext) -> QueueSnapshot? { state }
    func save(_ snapshot: QueueSnapshot, context: RequestContext) { state = snapshot }
}
func ownedContext(_ generation: UInt64 = 1) -> RequestContext { .init(account: OwnedMedia.account, accountGeneration: generation, requestGeneration: 0) }
func ownedSession(wall: any WallClock = SystemWallClock(), clock: any MonotonicClock = SystemMonotonicClock()) async throws -> PlaybackSession {
    let media = OwnedMedia(wall: wall)
    return try await PlaybackSession.open(context: ownedContext(), persistence: MemoryPersistence(), assets: media, resolver: media, capabilities: media, wall: wall, clock: clock, automaticTick: false, initialGain: 0.001, maximumStartGain: 0.001, gapless: false)
}
@Suite(.serialized) struct NativePlaybackTests {
    @Test func T061ActualRenderPauseSeekEndAndGenerationFence() async throws {
        let clock = SystemMonotonicClock(); let media = OwnedMedia()
        let player = NativePlayer(assets: media, clock: clock, observeRendering: true, initialGain: 0.001, maximumStartGain: 0.001)
        let context = PlaybackContext(request: ownedContext(), generation: 1, occurrenceID: UUID(), route: nil)
        let variant = try await media.resolve(OwnedMedia.items[0], context: context).outcome.get()[0]
        _ = try await player.stop(context: context).outcome.get()
        _ = try await player.prepare(variant, context: context).outcome.get()
        _ = try await player.setGain(0.001, context: context).outcome.get()
        let info = try #require(await player.mediaInfo())
        #expect(abs(await player.nativeGain() - 0.001) < 0.00001)
        #expect(abs(info.duration - 12) < 0.001 && info.sampleRate == 48000 && info.bitrate == 1_536_000)
        _ = try await player.play(context: context).outcome.get()
        // TH2: a condition wait, not a fixed 700 ms. Real audio needs a moment to start on a loaded machine; the 30 s only turns "never rendered" into a failure. What is asserted
        // below (frames, non-zero samples, RMS, position past 0.2 s) is exactly what it was.
        let renderDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < renderDeadline {
            if let m = await player.renderMeasurement(), m.frames > 1000, m.nonzeroSamples > 1000, m.rms > 0.01, await player.nativePosition() > 0.2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let first = try #require(await player.renderMeasurement())
        print("T06 native render frames=\(first.frames) nonzero=\(first.nonzeroSamples) rms=\(first.rms)")
        #expect(first.frames > 1000 && first.nonzeroSamples > 1000 && first.rms > 0.01)
        #expect(await player.nativePosition() > 0.2)
        _ = try await player.pause(context: context).outcome.get()
        let paused = await player.nativePosition()
        try await Task.sleep(for: .milliseconds(200))
        #expect(abs(await player.nativePosition() - paused) < 0.04)
        #expect(await player.nativeRate() == 0)
        _ = try await player.seek(to: 5, context: context).outcome.get()
        #expect(abs(await player.nativePosition() - 5) < 0.01)
        _ = try await player.setMuted(true, context: context).outcome.get()
        #expect(await player.nativeMuted())
        _ = try await player.setRate(1.5, context: context).outcome.get()
        // Keep this established quiet hardware check on the primary bypass route.
        // Non-flat selected transport is measured only in device-free manual tests.
        _ = try await player.setBalance(0, context: context).outcome.get()
        _ = try await player.setMuted(false, context: context).outcome.get()
        let stream = await player.observations()
        let ended = Task {
            for await event in stream { if case .ended = event.event { return event.context == context } }
            return false
        }
        _ = try await player.seek(to: 11.6, context: context).outcome.get()
        _ = try await player.play(context: context).outcome.get()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))   // TH2: a failure bound (it was 3 s from the play, which is the start-up plus 0.27 s of audio)
        while await player.nativePosition() < 11.95, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(await ended.value)
        let newer = PlaybackContext(request: ownedContext(2), generation: 1, occurrenceID: nil, route: nil)
        _ = try await player.stop(context: newer).outcome.get()
        if case .failure(.staleContext) = await player.play(context: context).outcome {} else { Issue.record("Stale play accepted") }
        #expect(await player.nativeRate() == 0)
    }
    @Test func T062QueueTransportPausedEndPreviousAndScrubs() async throws {
        let session = try await ownedSession()
        try await session.startOwnedMedia(OwnedMedia.items)
        var state = try await session.snapshot()
        let original = try #require(state.queue.current?.id)
        try await session.seek(4)
        try await session.previous()
        #expect(try await session.snapshot().playback.position < 0.2)
        #expect(try await session.snapshot().queue.current?.id == original)
        try await session.next()
        #expect(try await session.snapshot().queue.current?.media == OwnedMedia.items[1])
        try await session.previous()
        #expect(try await session.snapshot().queue.current?.id == original)
        try await session.next(); try await session.seek(4)
        try await session.previous(directItem: true)
        #expect(try await session.snapshot().queue.current?.id == original)
        try await session.pause()
        state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .ended))
        #expect(try await session.snapshot().queue.current?.id == original)
        try await session.resume()
        state = try await session.snapshot()
        #expect(state.playback.state == .playing && state.queue.intent == .play)
        await session.receive(.init(context: state.playback.context, event: .ended))
        #expect(try await session.snapshot().queue.current?.media == OwnedMedia.items[1])
        // Delayed old end cannot advance twice.
        await session.receive(.init(context: state.playback.context, event: .ended))
        #expect(try await session.snapshot().queue.current?.media == OwnedMedia.items[1])
        let seekCount = await session.nativeSeekCount()
        await session.coalescedSeek(1); await session.coalescedSeek(2); await session.coalescedSeek(3)
        try await Task.sleep(for: .milliseconds(350))
        let scrubbed = try await session.snapshot()
        #expect(scrubbed.playback.position >= 3 && scrubbed.playback.position < 3.5)
        #expect(await session.nativeSeekCount() == seekCount + 1)
        await session.close(reason: .accountSwitch)
        await #expect(throws: DomainError.staleContext) { try await session.resume() }
    }
}
