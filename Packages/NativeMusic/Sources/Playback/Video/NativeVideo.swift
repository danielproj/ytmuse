@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Synchronization

/// W17: the native (AVKit) side of video for OWNED and LOCAL media only. YouTube Music video never comes here: it plays in the hidden
/// player (`Docs/Playback-Addendum.md`, "Video surface"). The AVPlayer stays confined to `NativePlayer`; a surface receives this
/// handle to attach its `AVPlayerLayer`, and never creates or drives a player of its own, so there is exactly one decoder and one
/// audio output however many surfaces come and go.
public final class NativeVideoHandle: @unchecked Sendable {
    public let player: AVPlayer
    /// The decoded picture's size in pixels; `.zero` while the item holds no video track.
    public let presentationSize: CGSize
    public let hasVideoTrack: Bool
    /// Whether the item's video tracks are enabled for decoding (false after an audio-only selection).
    public let decoding: Bool
    init(player: AVPlayer, presentationSize: CGSize, hasVideoTrack: Bool, decoding: Bool) {
        self.player = player; self.presentationSize = presentationSize; self.hasVideoTrack = hasVideoTrack; self.decoding = decoding
    }
}

/// Counts the pixel buffers the decoder actually delivers for the current item through an `AVPlayerItemVideoOutput`, polled at 30 Hz
/// on a private queue. This is a measurement, not a display path: the count stops advancing when the video track no longer decodes.
final class NativeVideoProbe: Sendable {
    private let delivered = Mutex(0)
    private let output: AVPlayerItemVideoOutput
    private let timer: DispatchSourceTimer
    private let queue = DispatchQueue(label: "local.native-music.video-probe", qos: .utility)
    init(item: AVPlayerItem) {
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        timer = DispatchSource.makeTimerSource(queue: queue)
        item.add(output)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: time), output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil else { return }
            delivered.withLock { $0 += 1 }
        }
        timer.resume()
    }
    var framesDelivered: Int { delivered.withLock { $0 } }
    func stop(item: AVPlayerItem?) { timer.cancel(); item?.remove(output) }
}
