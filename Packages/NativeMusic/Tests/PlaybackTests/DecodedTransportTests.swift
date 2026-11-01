@preconcurrency import AVFoundation
import XCTest
import Domain
@testable import Playback

private struct PCMProvider: NativeAssetProvider {
    let url: URL
    let seekable: Bool
    let access: NativeAssetSession.DecodedAccess
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { url }
    func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession {
        NativeAssetSession(asset: AVURLAsset(url: url), userSeekable: seekable, decodedAccess: access,
                           authorizeUserSeek: { if !seekable { throw DomainError.forbidden } })
    }
}
private func equal<T: Equatable>(_ value: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(value, expected, file: file, line: line) }
private func near(_ value: Double, _ expected: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(value, expected, accuracy: accuracy, file: file, line: line) }
private func fails(_ result: Result<Void, DomainError>, file: StaticString = #filePath, line: UInt = #line) { if case .success = result { XCTFail("expected failure", file: file, line: line) } }
private actor PermissionGate {
    var arrived = false
    var continuation: CheckedContinuation<Void, Never>?
    func hold() async { arrived = true; await withCheckedContinuation { continuation = $0 } }
    func entered() -> Bool { arrived }
    func release() { continuation?.resume(); continuation = nil }
}
private struct HeldSeekProvider: NativeAssetProvider {
    let url: URL; let gate: PermissionGate
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { url }
    func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession {
        NativeAssetSession(asset: AVURLAsset(url: url), userSeekable: true, decodedAccess: .localPCM, authorizeUserSeek: { await gate.hold() })
    }
}
private actor CDecodeAuthorizationGate {
    var first=true;var entered=false;var continuation:CheckedContinuation<Void,Never>?
    func authorize() async {guard first else{return};first=false;entered=true;await withCheckedContinuation{continuation=$0}}
    func waiting()->Bool{entered}
    func release(){continuation?.resume();continuation=nil}
}
private struct HeldDecodeProvider: NativeAssetProvider {
    let url:URL;let gate:CDecodeAuthorizationGate
    func asset(for variant:MediaVariant,context:PlaybackContext) async throws ->URL{url}
    func assetSession(for variant:MediaVariant,context:PlaybackContext) async throws ->NativeAssetSession{
        NativeAssetSession(asset:AVURLAsset(url:url),userSeekable:true,decodedAccess:.localPCM,authorizeUserSeek:{},authorizeDecodedRead:{await gate.authorize()})
    }
}
final class DecodedTransportTests: XCTestCase, @unchecked Sendable {
    let sampleRate = 48000.0
    func fixture(seconds: Double, level: Float, hz: Double = 1000) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("W16-B-" + UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var cursor = 0; let total = Int(seconds * sampleRate)
        while cursor < total {
            let count = min(4096, total - cursor)
            let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!; chunk.frameLength = UInt32(count)
            for c in 0..<2 { for i in 0..<count { chunk.floatChannelData![c][i] = level * Float(sin(Double(cursor + i) * 2 * .pi * hz / sampleRate)) } }
            try file.write(from: chunk); cursor += count
        }
        return url
    }
    func owner(_ url: URL, seekable: Bool = true, access: NativeAssetSession.DecodedAccess = .localPCM) async throws -> (NativePlayer, PlaybackContext) {
        let owner = NativePlayer(assets: PCMProvider(url: url, seekable: seekable, access: access), clock: SystemMonotonicClock(), initialGain: 1, manualDecodedRendering: true)
        let ctx = PlaybackContext(request: ownedContext(), generation: 1, occurrenceID: UUID(), route: nil)
        let variant = try await OwnedMedia().resolve(OwnedMedia.items[0], context: ctx).outcome.get()[0]
        _ = try await owner.prepare(variant, context: ctx).outcome.get()
        return (owner, ctx)
    }
    func testLongIncrementalTransportBoundaryPauseSeekStopAndBypass() async throws {
        let url = try fixture(seconds: 17, level: 0.2, hz: 317); defer { try? FileManager.default.removeItem(at: url) }
        let (owner, ctx) = try await owner(url)
        equal(await owner.selectedBackend(), .avPlayer)
        _ = try await owner.configureEffects(AudioEffects(gain: 0.5), context: ctx).outcome.get()
        equal(await owner.selectedBackend(), .decodedNative)
        let available = await owner.dspCapabilities(context: ctx)
        equal(available.effects, .supported)
        XCTAssertTrue(available.gapless); XCTAssertTrue(available.crossfade)
        _ = try await owner.play(context: ctx).outcome.get()
        var cursor = 0; var worst: Float = 0
        while cursor < 816000 {
            let samples = try await owner.renderSelected(1024, context: ctx)
            XCTAssertGreaterThan(samples.frameLength, 0)
            for i in 0..<Int(samples.frameLength) {
                let expected = 0.1 * Float(sin(Double(cursor + i) * 2 * .pi * 317 / sampleRate))
                worst = max(worst, abs(samples.floatChannelData![0][i] - expected))
            }
            cursor += Int(samples.frameLength)
        }
        XCTAssertEqual(cursor, 816000); XCTAssertLessThanOrEqual(worst, 0.000002)
        near(await owner.nativePosition(), 17, accuracy: 1.0 / sampleRate)
        let resources = await owner.decodedResourceState()
        XCTAssertLessThanOrEqual(resources.peakFrames, 49152)
        print("W16-B long frames=\(cursor) worst=\(worst) peakRetained=\(resources.peakFrames) payloadCeiling=\(resources.ceilingBytes)")
        _ = try await owner.seek(to: 2, context: ctx).outcome.get()
        _ = try await owner.play(context: ctx).outcome.get()
        _ = try await owner.pause(context: ctx).outcome.get()
        let paused = await owner.nativePosition()
        let silent = try await owner.renderSelected(512, context: ctx)
        XCTAssertEqual(silent.floatChannelData![0][0], 0)
        equal(await owner.nativePosition(), paused)
        _ = try await owner.play(context: ctx).outcome.get()
        let resumed = try await owner.renderSelected(1024, context: ctx)
        XCTAssertEqual(resumed.floatChannelData![0][100], 0.1 * Float(sin(Double(96000 + 100) * 2 * .pi * 317 / sampleRate)), accuracy: 0.000002)
        _ = try await owner.configureEffects(AudioEffects(), context: ctx).outcome.get()
        equal(await owner.selectedBackend(), .avPlayer)
        equal(await owner.nativeRate(), 0) // manual mode never starts hardware AVPlayer
        _ = await owner.stop(context: ctx)
        do { _ = try await owner.renderSelected(1024, context: ctx); XCTFail("stopped render") } catch {}
        let stale = PlaybackContext(request: ownedContext(0), generation: 1, occurrenceID: UUID(), route: nil)
        fails(await owner.configureEffects(try AudioEffects(balance: 1), context: stale).outcome)
    }
    func renderRMS(_ owner: NativePlayer, _ ctx: PlaybackContext, frames: Int) async throws -> (Double, Float) {
        _ = try await owner.play(context: ctx).outcome.get()
        var sum = 0.0; var count = 0; var peak: Float = 0
        while count < frames {
            let buffer = try await owner.renderSelected(UInt32(min(1024, frames - count)), context: ctx)
            guard buffer.frameLength > 0 else { break }
            for i in 0..<Int(buffer.frameLength) {
                let v = buffer.floatChannelData![0][i]; peak = max(peak, abs(v)); sum += Double(v) * Double(v)
            }
            count += Int(buffer.frameLength)
        }
        XCTAssertEqual(count, frames)
        return (sqrt(sum / Double(max(1, count))), peak)
    }
    func testAutomaticNormalizationAndNativeEQClippingBalanceGain() async throws {
        var measured: [Double] = []
        for level: Float in [0.02, 0.6] {
            let url = try fixture(seconds: 2, level: level); defer { try? FileManager.default.removeItem(at: url) }
            let (owner, ctx) = try await owner(url)
            _ = try await owner.configureEffects(AudioEffects(normalize: true), context: ctx).outcome.get()
            let (rms, peak) = try await renderRMS(owner, ctx, frames: 96000)
            measured.append(rms); XCTAssertLessThanOrEqual(peak, 1.00001)
            XCTAssertEqual(20 * log10(rms), -18, accuracy: 0.3)
            _ = await owner.stop(context: ctx)
        }
        XCTAssertEqual(measured[0], measured[1], accuracy: 0.002)
        let url = try fixture(seconds: 2, level: 0.8); defer { try? FileManager.default.removeItem(at: url) }
        let (owner, ctx) = try await owner(url)
        var bands = Array(repeating: Float(0), count: 10); bands[5] = -6
        _ = try await owner.configureEffects(AudioEffects(bands: bands), context: ctx).outcome.get()
        let (eq, _) = try await renderRMS(owner, ctx, frames: 96000)
        XCTAssertEqual(20 * log10(eq / (0.8 / sqrt(2))), -6, accuracy: 0.15)
        _ = try await owner.setBalance(1, context: ctx).outcome.get()
        _ = try await owner.seek(to: 0, context: ctx).outcome.get()
        _ = try await owner.play(context: ctx).outcome.get()
        let right = try await owner.renderSelected(1024, context: ctx)
        XCTAssertLessThan((0..<Int(right.frameLength)).map { abs(right.floatChannelData![0][$0]) }.max()!, 0.0001)
        _ = try await owner.setMuted(true, context: ctx).outcome.get()
        let mute = try await owner.renderSelected(1024, context: ctx)
        XCTAssertLessThan((0..<Int(mute.frameLength)).map { abs(mute.floatChannelData![1][$0]) }.max()!, 0.0001)
        _ = try await owner.setMuted(false, context: ctx).outcome.get()
        _ = try await owner.configureEffects(AudioEffects(normalizationDB: 24), context: ctx).outcome.get()
        _ = try await owner.seek(to: 0, context: ctx).outcome.get()
        let (_, peak) = try await renderRMS(owner, ctx, frames: 96000)
        XCTAssertLessThanOrEqual(peak, 1.00001)
        print("W16-B normalized RMS=\(measured) native EQ RMS=\(eq) peak=\(peak)")
        _ = await owner.stop(context: ctx)
    }
    func testAppGainRateAndSingleCompletion() async throws {
        let url = try fixture(seconds: 2, level: 0.2, hz: 400); defer { try? FileManager.default.removeItem(at: url) }
        let (player, ctx) = try await owner(url)
        _ = try await player.configureEffects(AudioEffects(gain: 0.5), context: ctx).outcome.get()
        _ = try await player.setGain(0.5, context: ctx).outcome.get()
        let (rms, _) = try await renderRMS(player, ctx, frames: 24000)
        XCTAssertEqual(rms, 0.2 / sqrt(2) * 0.25, accuracy: 0.00001)
        let priorEvents = await player.observations()
        _ = try await player.pause(context: ctx).outcome.get()
        var captured: ScopedEngineEvent?
        for await event in priorEvents { if event.renderGeneration != nil { captured = event; break } }
        _ = try await player.seek(to: 0, context: ctx).outcome.get()
        equal(await player.validatesObservation(try XCTUnwrap(captured)), false)
        _ = try await player.setRate(2, context: ctx).outcome.get()
        let events = await player.observations()
        let completion = Task { () -> Int in
            var ends = 0
            for await event in events {
                if case .ended = event.event { ends += 1 }
                if case .position = event.event, ends > 0 { return ends }
            }
            return ends
        }
        _ = try await player.play(context: ctx).outcome.get()
        equal(await player.nativeRate(), 2)
        var count = 0; var crossings = 0; var previous: Float = 0
        // Bounded render calls, no hardware or wall-clock advancement required.
        for _ in 0..<120 {
            let block = try await player.renderSelected(1024, context: ctx)
            for i in 0..<Int(block.frameLength) {
                let value = block.floatChannelData![0][i]
                if count > 8192, previous < 0, value >= 0 { crossings += 1 }
                previous = value; count += 1
            }
            if await player.nativeRate() == 0 { break }
        }
        let hz = Double(crossings) / (Double(count - 8192) / 48000)
        XCTAssertEqual(hz, 400, accuracy: 4) // source pitch preserved at 2x
        near(await player.nativePosition(), 2, accuracy: 1.0 / 48000)
        _ = try await player.renderSelected(1024, context: ctx)
        _ = try await player.pause(context: ctx).outcome.get()
        let ends = await completion.value; XCTAssertEqual(ends, 1)
        print("W16-B selected app gain RMS=\(rms); 2x output frames=\(count) pitch=\(hz) completions=\(ends)")
        _ = await player.stop(context: ctx)
    }
    func testEffectsReplacementReportsBufferingThenStarted() async throws {
        let url = try fixture(seconds: 2, level: 0.2); defer { try? FileManager.default.removeItem(at: url) }
        let (player, ctx) = try await owner(url)
        _ = try await player.configureEffects(AudioEffects(gain: 0.5), context: ctx).outcome.get()
        _ = try await player.play(context: ctx).outcome.get()
        _ = try await player.renderSelected(1024, context: ctx)
        let position = await player.nativePosition()
        _ = try await player.configureEffects(AudioEffects(normalize: true), context: ctx).outcome.get()
        let events = await player.observations()
        var sawBuffering = false; var sawStart = false
        for await event in events {
            guard await player.validatesObservation(event) else { continue }
            if case .buffering = event.event { sawBuffering = true }
            if case .started = event.event, sawBuffering { sawStart = true; break }
        }
        XCTAssertTrue(sawBuffering); XCTAssertTrue(sawStart)
        near(await player.nativePosition(), position, accuracy: 1.0 / 48000)
        _ = await player.stop(context: ctx)
    }
    func testAllTenSelectedNativeTransportBands() async throws {
        for (band,hz) in [31.0,62,125,250,500,1000,2000,4000,8000,16000].enumerated() {
            let url=try fixture(seconds:2,level:0.2,hz:hz);defer{try? FileManager.default.removeItem(at:url)}
            let (player,ctx)=try await owner(url)
            var bands=Array(repeating:Float(0),count:10);bands[band] = -6
            _ = try await player.configureEffects(AudioEffects(bands:bands),context:ctx).outcome.get()
            let (rms,_)=try await renderRMS(player,ctx,frames:96000)
            let db=20*log10(rms/(0.2/sqrt(2)))
            XCTAssertEqual(db,-6,accuracy:0.25)
            print("W16-C production EQ band=\(band) frequency=\(hz) measuredDB=\(db)")
            _ = await player.stop(context:ctx)
        }
    }
    func testPauseCancelsPlayHeldDuringSelectedBackendPreparation() async throws {
        let url=try fixture(seconds:2,level:0.2);defer{try? FileManager.default.removeItem(at:url)}
        let gate=CDecodeAuthorizationGate()
        let player=NativePlayer(assets:HeldDecodeProvider(url:url,gate:gate),clock:SystemMonotonicClock(),initialGain:1,manualDecodedRendering:true)
        let ctx=PlaybackContext(request:ownedContext(),generation:1,occurrenceID:UUID(),route:nil)
        let variant=try await OwnedMedia().resolve(OwnedMedia.items[0],context:ctx).outcome.get()[0]
        _ = try await player.prepare(variant,context:ctx).outcome.get()
        let configuring=Task{await player.configureEffects(try AudioEffects(balance:1),context:ctx)}
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while !(await gate.waiting()),ContinuousClock.now<deadline{await Task.yield()}
        let playing=Task{await player.play(context:ctx)}
        while !(await player.requestedPlay()),ContinuousClock.now<deadline{await Task.yield()}
        equal(await player.requestedPlay(),true)
        _ = try await player.pause(context:ctx).outcome.get()
        await gate.release();_ = try await configuring.value.outcome.get()
        fails(await playing.value.outcome)
        equal(await player.nativeRate(),0)
        let output=try await player.renderSelected(1024,context:ctx);XCTAssertEqual(output.floatChannelData![1][100],0)
        _ = await player.stop(context:ctx)
        print("W16-C held selected-backend Play reservation cancelled by later Pause; no primary fallback/late native start")
    }
    func testHeldSeekStopFencesPermissionAndScheduledBuffers() async throws {
        let url = try fixture(seconds: 3, level: 0.1); defer { try? FileManager.default.removeItem(at: url) }
        let gate = PermissionGate()
        let player = NativePlayer(assets: HeldSeekProvider(url: url, gate: gate), clock: SystemMonotonicClock(), initialGain: 1, manualDecodedRendering: true)
        let ctx = PlaybackContext(request: ownedContext(), generation: 1, occurrenceID: UUID(), route: nil)
        let variant = try await OwnedMedia().resolve(OwnedMedia.items[0], context: ctx).outcome.get()[0]
        _ = try await player.prepare(variant, context: ctx).outcome.get()
        _ = try await player.configureEffects(AudioEffects(gain: 0.5), context: ctx).outcome.get()
        _ = try await player.play(context: ctx).outcome.get()
        _ = try await player.renderSelected(1024, context: ctx)
        let seek = Task { await player.seek(to: 1, context: ctx) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.entered()), ContinuousClock.now < deadline { await Task.yield() }
        equal(await gate.entered(), true)
        let newer = PlaybackContext(request: ownedContext(2), generation: 1, occurrenceID: nil, route: nil)
        _ = try await player.stop(context: newer).outcome.get()
        await gate.release()
        fails(await seek.value.outcome)
        let resource = await player.decodedResourceState(); XCTAssertEqual(resource.retainedFrames, 0)
        equal(await player.nativeRate(), 0)
        equal(await player.selectedBackend(), .avPlayer)
        fails(await player.play(context: ctx).outcome)
        print("W16-B held user-seek completion rejected after account/operation replacement; retained=0")
    }
    func testPlayOnlyAndUnsupportedAdmissionAndReplacement() async throws {
        let url = try fixture(seconds: 1, level: 0.1); defer { try? FileManager.default.removeItem(at: url) }
        let (owner, ctx) = try await owner(url, seekable: false)
        _ = try await owner.configureEffects(try AudioEffects(balance: 1), context: ctx).outcome.get()
        fails(await owner.seek(to: 0.5, context: ctx).outcome)
        let newer = PlaybackContext(request: ownedContext(2), generation: 2, occurrenceID: UUID(), route: nil)
        _ = try await owner.stop(context: newer).outcome.get()
        fails(await owner.play(context: ctx).outcome)
        let (unsupported, uctx) = try await self.owner(url, access: .unavailable)
        fails(await unsupported.configureEffects(try AudioEffects(balance: 1), context: uctx).outcome)
        equal(await unsupported.selectedBackend(), .avPlayer)
        let unavailable = await unsupported.dspCapabilities(context: uctx)
        equal(unavailable.effects, .temporarilyUnavailable(.unsupported))
        XCTAssertFalse(unavailable.gapless); XCTAssertFalse(unavailable.crossfade)
        _ = await unsupported.stop(context: uctx)
    }
}
