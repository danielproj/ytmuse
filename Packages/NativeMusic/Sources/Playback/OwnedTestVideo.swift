#if DEBUG
@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Domain
import Foundation

/// The owned synthetic test video (rework F12): generated from equations at first use, DEBUG builds only, so no video asset ships in Release.
/// 480 x 270 (16:9), 24 fps, 60 s, H.264, VIDEO ONLY (no audio track, so it can never make a sound): a hue-cycling background and a white bar
/// sweeping left to right. No footage, no third-party material; CC0-1.0. Development test media, never YouTube Music or live-service evidence.
/// Written only under the system temporary directory.
enum OwnedTestVideo {
    static let width = 480, height = 270, fps = 24, seconds = 60
    private actor Cache {
        var url: URL?
        func resolve() async throws -> URL {
            if let url, FileManager.default.fileExists(atPath: url.path) { return url }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-owned-test-video-v2", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = directory.appendingPathComponent("owned-video.mp4")
            if FileManager.default.fileExists(atPath: target.path),
               let duration = try? await AVURLAsset(url: target).load(.duration).seconds, abs(duration - Double(OwnedTestVideo.seconds)) < 0.5 {
                url = target; return target
            }
            let staging = directory.appendingPathComponent("staging-" + UUID().uuidString + ".mp4")
            try await OwnedTestVideo.generate(to: staging)
            _ = try? GuardedFiles(root: directory).replace(target, withStaged: staging)
            if !FileManager.default.fileExists(atPath: target.path) { try GuardedFiles(root: directory).move(staging, to: target) }
            url = target; return target
        }
    }
    private static let cache = Cache()
    static func url() async throws -> URL { try await cache.resolve() }

    static func generate(to output: URL) async throws {
        try? GuardedFiles(root: output.deletingLastPathComponent()).remove(output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 120_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel, AVVideoMaxKeyFrameIntervalKey: fps]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? DomainFailure.writer }
        writer.startSession(atSourceTime: .zero)
        let space = CGColorSpaceCreateDeviceRGB()
        for frame in 0..<(fps * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let pixels = buffer else { throw DomainFailure.writer }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                       space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                let t = Double(frame) / Double(fps * seconds)
                context.setFillColor(CGColor(red: 0.2 + 0.5 * abs(sin(t * .pi * 6)), green: 0.3 + 0.4 * abs(sin(t * .pi * 4 + 1)), blue: 0.5 + 0.3 * abs(sin(t * .pi * 2)), alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: Int(t * 6 * Double(width - 24)) % (width - 24), y: height / 3, width: 24, height: height / 3))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? DomainFailure.writer }
    }
    enum DomainFailure: Error { case writer }
}
#endif
