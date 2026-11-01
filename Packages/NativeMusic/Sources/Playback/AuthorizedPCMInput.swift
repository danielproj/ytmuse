@preconcurrency import AVFoundation
import Domain

/// One bounded native decoder. AVAssetReader applies native container edit/packet
/// trimming; this layer does not subtract encoder priming a second time.
final class AuthorizedPCMInput {
    let session: NativeAssetSession
    let track: AVAssetTrack
    let sampleRate: Double
    let duration: Double
    let totalFrames: Int64
    let startFrame: Int64
    var cursor: Int64
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: CMSampleBuffer?
    private var offset = 0
    let format: AVAudioFormat
    init(session: NativeAssetSession, track: AVAssetTrack, sampleRate: Double, duration: Double, start: Double) throws {
        guard duration.isFinite, duration > 0, duration * sampleRate < Double(Int64.max) else { throw DomainError.unsupported }
        self.session = session; self.track = track; self.sampleRate = sampleRate; self.duration = duration
        totalFrames = Int64((duration * sampleRate).rounded()); startFrame = Int64((start * sampleRate).rounded()); cursor = startFrame
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let pair = try IncrementalDecodedPlayer.makeReader(session: session, track: track, start: start)
        reader = pair.0; output = pair.1
    }
    var retainedFrames: Int { pending.map(CMSampleBufferGetNumSamples) ?? 0 }
    func close() { pending = nil; reader.cancelReading() }
    deinit { close() }
    func readExact(_ count: Int) throws -> AVAudioPCMBuffer? {
        guard cursor < totalFrames else { return nil }
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!
        result.frameLength = UInt32(count)
        var filled = 0
        while filled < count {
            guard let part = try read(count - filled) else { throw DomainError.malformedResponse }
            for channel in 0..<2 { result.floatChannelData![channel].advanced(by: filled).update(from: part.floatChannelData![channel], count: Int(part.frameLength)) }
            filled += Int(part.frameLength)
        }
        return result
    }
    func read(_ maximum: Int) throws -> AVAudioPCMBuffer? {
        if let failure = session.failure { throw failure }
        guard !session.isClosed else { throw DomainError.staleContext }
        if cursor >= totalFrames { return nil }
        if pending == nil { pending = output.copyNextSampleBuffer(); offset = 0 }
        guard let pending else {
            guard reader.status == .completed else { throw session.failure ?? DomainError.transientTransport }
            // Truncation is never silently repaired with zero samples.
            guard abs(cursor - totalFrames) <= 1 else { throw DomainError.malformedResponse }
            return nil
        }
        let frames = CMSampleBufferGetNumSamples(pending)
        guard frames > 0, frames <= 16384,
              let description = CMSampleBufferGetFormatDescription(pending),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mSampleRate == sampleRate, asbd.pointee.mChannelsPerFrame == 2,
              asbd.pointee.mBitsPerChannel == 32, let data = CMSampleBufferGetDataBuffer(pending) else { throw DomainError.unsupported }
        let count = min(maximum, frames - offset, Int(totalFrames - cursor))
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!; result.frameLength = UInt32(count)
        var values = Array(repeating: Float(0), count: count * 2)
        let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: offset * 8, dataLength: $0.count, destination: $0.baseAddress!) }
        guard status == noErr else { throw DomainError.unsupported }
        for c in 0..<2 { for i in 0..<count { let v = values[i * 2 + c]; guard v.isFinite else { throw DomainError.malformedResponse }; result.floatChannelData![c][i] = v } }
        offset += count; cursor += Int64(count)
        if offset == frames { self.pending = nil }
        return result
    }
}

struct NativeUpcoming {
    let id: UUID
    let context: PlaybackContext
    let variant: MediaVariant
    let session: NativeAssetSession
    let track: AVAssetTrack
    let duration: Double
    let sampleRate: Double
    let normalization: Float
    let overlap: Double
}
