@preconcurrency import AVFoundation
import AudioToolbox
import Domain
import Foundation

/// Validated processing request. Volume is independent of system volume.
public struct AudioEffects: Sendable, Equatable {
    public let bands: [Float]
    public let normalize: Bool
    public let normalizationDB: Float?
    public let balance: Float
    public let gain: Float
    public let crossfade: Double
    public init(bands: [Float] = Array(repeating: 0, count: 10), normalizationDB: Float? = nil, normalize: Bool = false,
                balance: Float = 0, gain: Float = 1, crossfade: Double = 0) throws {
        guard bands.count == 10, bands.allSatisfy({ $0.isFinite && (-12...12).contains($0) }),
              normalizationDB.map({ $0.isFinite && (-24...24).contains($0) }) ?? true,
              balance.isFinite, (-1...1).contains(balance), gain.isFinite, (0...1).contains(gain),
              crossfade.isFinite, (0...12).contains(crossfade) else { throw DomainError.invalidInput(.invalidRange) }
        self.normalize = normalize; self.bands = bands; self.normalizationDB = normalizationDB; self.balance = balance
        self.gain = gain; self.crossfade = crossfade
    }
    public var bypass: Bool { bands.allSatisfy { $0 == 0 } && normalizationDB == nil && !normalize && balance == 0 && gain == 1 && crossfade == 0 }
}

/// Off-render-thread bounded PCM staging. Trims are decoded frame counts supplied by
/// the decoder, never guessed from a file extension. Scope includes account/item/route.
public struct DecodedPrebuffer {
    public let maximumFrames: Int
    public private(set) var context: PlaybackContext?
    public private(set) var frames = 0
    private var chunks: [AVAudioPCMBuffer] = []
    public init(maximumFrames: Int = 48_000 * 12) { precondition((1...576000).contains(maximumFrames)); self.maximumFrames = maximumFrames }
    public mutating func reset(context: PlaybackContext?) { chunks.removeAll(); frames = 0; self.context = context }
    public mutating func append(_ input: AVAudioPCMBuffer, delay: Int, padding: Int, context: PlaybackContext) throws {
        guard self.context == context else { throw DomainError.staleContext }
        let length = Int(input.frameLength)
        guard delay >= 0, padding >= 0, delay <= length, padding <= length - delay else { throw DomainError.invalidInput(.invalidRange) }
        let count = length - delay - padding
        guard count > 0, count <= maximumFrames - frames,
              input.format.channelCount == 2, !input.format.isInterleaved, let source = input.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: AVAudioFrameCount(count)),
              let target = copy.floatChannelData else { throw DomainError.invalidInput(.invalidRange) }
        copy.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 { target[channel].update(from: source[channel].advanced(by: delay), count: count) }
        chunks.append(copy); frames += count
    }
    public mutating func take(context: PlaybackContext) throws -> [AVAudioPCMBuffer] {
        guard self.context == context else { throw DomainError.staleContext }
        defer { chunks.removeAll(); frames = 0 }
        return chunks
    }
}

/// Native, device-independent renderer used to qualify decoded routes. Does not open
/// a hardware output. No custom audio callback: scheduling and allocation happen here,
/// AVAudioEngine owns its render callback. Production AVPlayer remains primary.
public enum NativeDecodedRenderer {
    public static let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public enum Segment { case music, spoken, advertisement, unavailable }
    /// Equal-gain linear overlap preserves coherent signal peaks. Eligibility is
    /// mandatory at this seam; caller must also retain provider authorization.
    public static func renderPair(_ current: AVAudioPCMBuffer, next: AVAudioPCMBuffer?,
                                  currentSegment: Segment, nextSegment: Segment,
                                  effects: AudioEffects) throws -> AVAudioPCMBuffer {
        let plain = try AudioEffects(bands: effects.bands, normalizationDB: effects.normalizationDB,
                                     balance: effects.balance, gain: effects.gain)
        guard let next, nextSegment != .unavailable else { return try render([current], effects: plain) }
        guard current.format == next.format else { throw DomainError.unsupported }
        guard effects.crossfade > 0, currentSegment == .music, nextSegment == .music else {
            return try render([current, next], effects: plain)
        }
        let overlap = min(Int(effects.crossfade * current.format.sampleRate), Int(current.frameLength), Int(next.frameLength))
        let length = Int(current.frameLength) + Int(next.frameLength) - overlap
        guard length <= 48_000 * 24, current.format.channelCount == 2, !current.format.isInterleaved,
              let a = current.floatChannelData, let b = next.floatChannelData,
              let mix = AVAudioPCMBuffer(pcmFormat: current.format, frameCapacity: AVAudioFrameCount(length)),
              let out = mix.floatChannelData else { throw DomainError.invalidInput(.invalidRange) }
        mix.frameLength = AVAudioFrameCount(length)
        let start = Int(current.frameLength) - overlap
        for c in 0..<2 {
            for i in 0..<length {
                if i < start { out[c][i] = a[c][i] }
                else if i < Int(current.frameLength) {
                    let t = overlap > 1 ? Float(i - start) / Float(overlap - 1) : 1
                    out[c][i] = a[c][i] * (1 - t) + b[c][i - start] * t
                } else { out[c][i] = b[c][i - start] }
            }
        }
        return try render([mix], effects: plain)
    }

    // Unity small-signal gain. Native limiting catches transient overshoot after
    // the bounded input-peak/cascade-response preamp below protects sustained input.
    static func makeLimiter() -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    }
    static func needsLimiter(_ effects: AudioEffects, normalizationGain: Float = 1) -> Bool {
        effects.normalize || effects.bands.contains { $0 > 0 } || normalizationGain > 1 || (effects.normalizationDB ?? 0) > 0
    }

    /// Maximum magnitude of the actual octave-peaking cascade, not the sum of
    /// requested dB values. Evaluated on control changes, never by a render callback.
    static func peakResponse(_ effects: AudioEffects, sampleRate: Double) -> Float {
        guard effects.bands.contains(where: { $0 > 0 }) else { return 1 }
        let coefficients = zip(frequencies, effects.bands).filter { $0.1 != 0 }.map { hz, gain -> [Double] in
            let w = 2 * Double.pi * Double(hz) / sampleRate, a = pow(10, Double(gain) / 40)
            let alpha = sin(w) * sinh(log(2) / 2 * w / sin(w))
            return [1 + alpha * a, -2 * cos(w), 1 - alpha * a, 1 + alpha / a, -2 * cos(w), 1 - alpha / a]
        }
        let probes = (0...2048).map { 10 * pow((sampleRate / 2 - 1) / 10, Double($0) / 2048) } + frequencies.map(Double.init)
        var maximum = 1.0
        for hz in probes {
            let w = 2 * Double.pi * hz / sampleRate
            var magnitude = 1.0
            for c in coefficients {
                let numerator = pow(c[0] + c[1] * cos(w) + c[2] * cos(2 * w), 2) + pow(c[1] * sin(w) + c[2] * sin(2 * w), 2)
                let denominator = pow(c[3] + c[4] * cos(w) + c[5] * cos(2 * w), 2) + pow(c[4] * sin(w) + c[5] * sin(2 * w), 2)
                magnitude *= sqrt(numerator / denominator)
            }
            maximum = max(maximum, magnitude)
        }
        return Float(maximum)
    }
    /// Feed-forward input-peak protection, at most 4096 frames per window. No
    /// output render/track scan. Low-level requested boosts retain unity preamp;
    /// sustained loud input is reduced toward -2.5dBFS predicted output peak.
    /// Frequency response predicts sinusoids, not arbitrary transient bounds, so
    /// the native limiter remains after EQ for transient overshoot protection.
    static func compensatePeaks(_ buffer: AVAudioPCMBuffer, response: Float) {
        for start in stride(from: 0, to: Int(buffer.frameLength), by: 4096) {
            let end = min(start + 4096, Int(buffer.frameLength))
            var peak: Float = 0
            for c in 0..<2 { for i in start..<end { peak = max(peak, abs(buffer.floatChannelData![c][i])) } }
            let predicted = peak * response
            if predicted > 0.75 {
                let scale: Float = 0.75 / predicted
                for c in 0..<2 { for i in start..<end { buffer.floatChannelData![c][i] *= scale } }
            }
        }
    }

    public static func render(_ buffers: [AVAudioPCMBuffer], effects: AudioEffects) throws -> AVAudioPCMBuffer {
        guard effects.crossfade == 0 else { throw DomainError.unsupported }
        guard let first = buffers.first, first.format.channelCount == 2, first.format.sampleRate == 48000, !first.format.isInterleaved,
              buffers.allSatisfy({ $0.format == first.format && $0.floatChannelData != nil }) else { throw DomainError.unsupported }
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0, total <= 48_000 * 24,
              let output = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(total)) else { throw DomainError.invalidInput(.invalidRange) }
        let engine = AVAudioEngine(); let player = AVAudioPlayerNode(); let eq = AVAudioUnitEQ(numberOfBands: 10)
        let limiter = makeLimiter(); limiter.bypass = !needsLimiter(effects)
        engine.attach(player); engine.attach(eq); engine.attach(limiter)
        for (index, band) in eq.bands.enumerated() {
            band.filterType = .parametric; band.frequency = frequencies[index]; band.bandwidth = 1
            band.gain = effects.bands[index]; band.bypass = effects.bands[index] == 0
        }
        eq.bypass = effects.bands.allSatisfy { $0 == 0 }
        engine.connect(player, to: eq, format: first.format)
        engine.connect(eq, to: limiter, format: first.format)
        engine.connect(limiter, to: engine.mainMixerNode, format: first.format)
        try engine.enableManualRenderingMode(.offline, format: first.format, maximumFrameCount: 1024)
        defer { player.stop(); engine.stop(); engine.disableManualRenderingMode() }
        // Explicit contiguous sample timestamps, independent of completion callbacks.
        let response = peakResponse(effects, sampleRate: first.format.sampleRate)
        var cursor: AVAudioFramePosition = 0
        for buffer in buffers {
            let staged = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: buffer.frameLength)!
            staged.frameLength = buffer.frameLength
            let scale = effects.gain * pow(Float(10), (effects.normalizationDB ?? 0) / 20)
            for channel in 0..<2 {
                let balance: Float = channel == 0 ? min(1, 1 - effects.balance) : min(1, 1 + effects.balance)
                for frame in 0..<Int(buffer.frameLength) { staged.floatChannelData![channel][frame] = buffer.floatChannelData![channel][frame] * scale * balance }
            }
            if needsLimiter(effects) { compensatePeaks(staged, response: response) }
            player.scheduleBuffer(staged, at: AVAudioTime(sampleTime: cursor, atRate: first.format.sampleRate))
            cursor += AVAudioFramePosition(buffer.frameLength)
        }
        try engine.start(); player.play()
        let block = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: 1024)!
        var written = 0; var stalls = 0
        while written < total {
            let status = try engine.renderOffline(AVAudioFrameCount(min(1024, total - written)), to: block)
            guard status == .success else {
                stalls += 1; if stalls > 8 { throw DomainError.transientTransport }; continue
            }
            guard block.frameLength > 0 else { throw DomainError.transientTransport }
            for channel in 0..<2 {
                output.floatChannelData![channel].advanced(by: written).update(from: block.floatChannelData![channel], count: Int(block.frameLength))
            }
            written += Int(block.frameLength)
        }
        output.frameLength = AVAudioFrameCount(total)
        return output
    }
}
