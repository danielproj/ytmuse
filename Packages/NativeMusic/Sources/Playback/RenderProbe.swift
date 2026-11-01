@preconcurrency import AVFoundation
import AudioToolbox
import MediaToolbox
import Synchronization

public struct RenderMeasurement: Sendable {
    public var frames: Int = 0
    public var nonzeroSamples: Int = 0
    public var sumSquares: Double = 0
    public var samples: Int = 0
    public var rms: Double { samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0 }
}
/// Opt-in test instrumentation of this player's decoded audio. No microphone,
/// output-device or other-app capture. Absent from the normal playback path.
final class RenderProbe: Sendable {
    let measurement = Mutex(RenderMeasurement())
    let float32 = Mutex(false)
    func mix(track: AVAssetTrack) throws -> AVAudioMix {
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, client, storage in storage.pointee = client },
            finalize: { tap in Unmanaged<RenderProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let probe = Unmanaged<RenderProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let description = format.pointee
                probe.float32.withLock { $0 = description.mFormatID == kAudioFormatLinearPCM && description.mBitsPerChannel == 32 && description.mFormatFlags & kAudioFormatFlagIsFloat != 0 }
            }, unprepare: nil,
            process: { tap, requested, _, buffers, frames, flags in
                let status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flags, nil, frames)
                guard status == noErr else { frames.pointee = 0; return }
                let probe = Unmanaged<RenderProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard probe.float32.withLock({ $0 }) else { return }
                var count = 0; var nonzero = 0; var squares: Double = 0
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData else { continue }
                    let values = data.assumingMemoryBound(to: Float.self)
                    let size = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    for i in 0..<size { let value = Double(values[i]); squares += value * value; if abs(value) > 0.00001 { nonzero += 1 } }
                    count += size
                }
                probe.measurement.withLock { $0.frames += frames.pointee; $0.samples += count; $0.nonzeroSamples += nonzero; $0.sumSquares += squares }
            })
        var tap: MTAudioProcessingTap?
        let result = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard result == noErr, let tap else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]; return mix
    }
}
