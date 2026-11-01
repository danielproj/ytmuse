@preconcurrency import AVFoundation
import XCTest
@testable import Playback
import Domain

final class AudioEffectsTests: XCTestCase {
    // Predeclared PCM float tolerance; no resampling. This is not a codec tolerance.
    let tolerance: Float = 0.000002
    func signal(_ count: Int, frequency: Double = 1000, level: Float = 0.2) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for c in 0..<2 { for i in 0..<count { buffer.floatChannelData![c][i] = level * Float(sin(Double(i) * 2 * .pi * frequency / 48000)) } }
        return buffer
    }
    func rms(_ buffer: AVAudioPCMBuffer, channel: Int = 0) -> Double {
        let samples = (1024..<Int(buffer.frameLength)).map { Double(buffer.floatChannelData![channel][$0]) }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
    }
    func testNativeBypassAndConsecutiveBoundary() throws {
        let a = signal(4096, frequency: 317); let b = signal(4096, frequency: 701)
        let rendered = try NativeDecodedRenderer.render([a,b], effects: AudioEffects())
        var worst: Float = 0
        for c in 0..<2 { for i in 0..<8192 {
            let expected = i < 4096 ? a.floatChannelData![c][i] : b.floatChannelData![c][i - 4096]
            worst = max(worst, abs(rendered.floatChannelData![c][i] - expected))
        } }
        print("W16 PCM contiguous/bypass maximum absolute error=\(worst) frames=8192 tolerance=\(tolerance)")
        XCTAssertLessThanOrEqual(worst, tolerance)
    }
    func testNativeEQNormalizationBalanceClipping() throws {
        let input = signal(48000)
        let base = try NativeDecodedRenderer.render([input], effects: AudioEffects())
        var bands = Array(repeating: Float(0), count: 10); bands[5] = -6
        let eq = try NativeDecodedRenderer.render([input], effects: AudioEffects(bands: bands))
        let db = 20 * log10(rms(eq) / rms(base))
        print("W16 native EQ 1kHz attenuation dB=\(db)")
        XCTAssertEqual(db, -6, accuracy: 0.15)
        let normalized = try NativeDecodedRenderer.render([input], effects: AudioEffects(normalizationDB: 6))
        XCTAssertEqual(20 * log10(rms(normalized) / rms(base)), 6, accuracy: 0.02)
        let right = try NativeDecodedRenderer.render([input], effects: AudioEffects(balance: 1, gain: 0.5))
        XCTAssertEqual(rms(right), 0); XCTAssertEqual(rms(right, channel: 1) / rms(base), 0.5, accuracy: 0.00001)
        let loud = try NativeDecodedRenderer.render([signal(48000, level: 0.9)], effects: AudioEffects(normalizationDB: 24))
        XCTAssertLessThanOrEqual((0..<48000).map { abs(loud.floatChannelData![0][$0]) }.max()!, 1)
    }
    func testPositiveBoostAndStreamingPeakPolicy() throws {
        for (bands, expected) in [([Float](arrayLiteral: 0,0,0,0,0,6,0,0,0,0), 6.0), (Array(repeating: Float(12), count: 10), 18.54624137123685)] {
            let input = signal(96000, level: 0.005)
            let output = try NativeDecodedRenderer.render([input], effects: AudioEffects(bands: bands))
            XCTAssertEqual(20 * log10(rms(output) / rms(input)), expected, accuracy: 0.35)
            let loud = try NativeDecodedRenderer.render([signal(96000, level: 0.9)], effects: AudioEffects(bands: bands))
            let peak = (0..<Int(loud.frameLength)).map { abs(loud.floatChannelData![0][$0]) }.max()!
            XCTAssertLessThanOrEqual(peak, 1.00001); XCTAssertGreaterThan(rms(loud), 0.1)
            print("W16-R1 F1 component expectedBoostDB=\(expected) actualDB=\(20 * log10(rms(output) / rms(input))) loudPeak=\(peak) loudRMS=\(rms(loud))")
        }
    }
    func testAllTenNativeEQBands() throws {
        // Independent octave centers, not read from the implementation's array.
        for (band, hz) in [31.0, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000].enumerated() {
            let input = signal(48000, frequency: hz)
            var settings = Array(repeating: Float(0), count: 10); settings[band] = -6
            let actual = try NativeDecodedRenderer.render([input], effects: AudioEffects(bands: settings))
            let db = 20 * log10(rms(actual) / rms(input))
            print("W16 EQ band \(band) frequency=\(hz) dB=\(db)")
            XCTAssertEqual(db, -6, accuracy: 0.25)
        }
    }
    func testTrimBudgetAndCancellation() throws {
        let request = RequestContext(account: OwnedMedia.account, accountGeneration: 0, requestGeneration: 0)
        let context = PlaybackContext(request: request, generation: 1, occurrenceID: UUID(), route: nil)
        var staging = DecodedPrebuffer(maximumFrames: 4096)
        staging.reset(context: context)
        let input = signal(4200)
        try staging.append(input, delay: 52, padding: 52, context: context)
        XCTAssertEqual(staging.frames, 4096)
        XCTAssertThrowsError(try staging.append(input, delay: 52, padding: 52, context: context))
        let trimmed = try XCTUnwrap(staging.take(context: context).first)
        XCTAssertEqual(trimmed.floatChannelData![0][0], input.floatChannelData![0][52])
        XCTAssertEqual(trimmed.floatChannelData![0][4095], input.floatChannelData![0][4147])
        staging.reset(context: nil)
        XCTAssertThrowsError(try staging.take(context: context))
    }
    func testCrossfadeEnvelopesAndExclusions() throws {
        let a = signal(576000, frequency: 0); let b = signal(576000, frequency: 0)
        for c in 0..<2 { for i in 0..<576000 { a.floatChannelData![c][i] = 0.2; b.floatChannelData![c][i] = 0.6 } }
        let effects = try AudioEffects(crossfade: 12)
        let mix = try NativeDecodedRenderer.renderPair(a, next: b, currentSegment: .music, nextSegment: .music, effects: effects)
        XCTAssertEqual(mix.frameLength, 576000)
        for i in stride(from: 0, to: 576000, by: 997) {
            XCTAssertEqual(mix.floatChannelData![0][i], 0.2 + 0.4 * Float(i) / 575999, accuracy: tolerance)
        }
        for segment in [NativeDecodedRenderer.Segment.advertisement, .spoken] {
            let excluded = try NativeDecodedRenderer.renderPair(a, next: b, currentSegment: segment, nextSegment: .music, effects: effects)
            XCTAssertEqual(excluded.frameLength, 1152000)
            XCTAssertEqual(excluded.floatChannelData![0][575999], 0.2, accuracy: tolerance)
            XCTAssertEqual(excluded.floatChannelData![0][576000], 0.6, accuracy: tolerance)
        }
        let absent = try NativeDecodedRenderer.renderPair(a, next: nil, currentSegment: .music, nextSegment: .unavailable, effects: effects)
        XCTAssertEqual(absent.frameLength, a.frameLength)
        let zero = try NativeDecodedRenderer.renderPair(a, next: b, currentSegment: .music, nextSegment: .music, effects: AudioEffects())
        XCTAssertEqual(zero.frameLength, 1152000)
        print("W16 crossfade measured 576000-frame envelope; ad/spoken/zero 1152000; absent 576000")
    }
    func testPreparedOwnerDecodesAndGatesLiveEffects() async throws {
        let media = OwnedMedia()
        let owner = NativePlayer(assets: media, clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true, maximumStartGain: 0.001)
        let context = PlaybackContext(request: ownedContext(), generation: 1, occurrenceID: UUID(), route: nil)
        let variant = try await media.resolve(OwnedMedia.items[0], context: context).outcome.get()[0]
        _ = try await owner.prepare(variant, context: context).outcome.get()
        let base = try await owner.measurePreparedAudio(effects: AudioEffects(), context: context)
        let referenceFile = try AVAudioFile(forReading: await media.asset(for: variant, context: context))
        let reference = AVAudioPCMBuffer(pcmFormat: referenceFile.processingFormat, frameCapacity: AVAudioFrameCount(referenceFile.length))!
        try referenceFile.read(into: reference)
        XCTAssertEqual(reference.frameLength, base.frameLength)
        var error: Float = 0
        for c in 0..<2 { for i in 0..<Int(base.frameLength) { error = max(error, abs(base.floatChannelData![c][i] - reference.floatChannelData![c][i])) } }
        XCTAssertLessThanOrEqual(error, tolerance)
        print("W16 AVAssetReader vs independent AVAudioFile PCM decode error=\(error)")
        let right = try await owner.measurePreparedAudio(effects: AudioEffects(balance: 1), context: context)
        XCTAssertEqual(base.frameLength, 576000); XCTAssertGreaterThan(rms(base), 0.01)
        XCTAssertEqual(rms(right), 0); XCTAssertEqual(rms(right, channel: 1), rms(base, channel: 1), accuracy: 0.000001)
        let denied = await owner.configureEffects(try AudioEffects(balance: 1), context: context)
        _ = try denied.outcome.get()
        let rate = await owner.nativeRate(); XCTAssertEqual(rate, 0)
        _ = await owner.stop(context: context)
        do { _ = try await owner.measurePreparedAudio(effects: AudioEffects(), context: context); XCTFail("disposed asset accepted") } catch {}
        print("W16 owner prepared-session native decode: 576000 frames; no Play; disposed session rejected")
    }
    func testUnsupportedCrossfadeDoesNotSucceed() throws {
        XCTAssertThrowsError(try AudioEffects(crossfade: 12.001))
        XCTAssertThrowsError(try NativeDecodedRenderer.render([signal(100)], effects: AudioEffects(crossfade: 12)))
    }
}
