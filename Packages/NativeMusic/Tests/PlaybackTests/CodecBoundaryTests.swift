@preconcurrency import AVFoundation
import AudioToolbox
import XCTest

final class CodecBoundaryTests: XCTestCase {
    // Declared before measurements: exact logical frame counts; timestamp error <=1 source frame.
    // Lossy amplitude uses each native decoder's independent output, never zero-error PCM criteria.
    func testNativeEncoderAndPacketMetadataDiscovery() async throws {
        for (name, id, suffix) in [("AAC", kAudioFormatMPEG4AAC, "m4a"), ("Opus", kAudioFormatOpus, "caf")] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("W16-C-" + UUID().uuidString + "." + suffix)
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
                do {
                    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: id, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000], commonFormat: .pcmFormatFloat32, interleaved: false)
                    for chunk in 0..<12 {
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000)!; buffer.frameLength = 4000
                        for c in 0..<2 { for i in 0..<4000 { buffer.floatChannelData![c][i] = Float(sin(Double(chunk * 4000 + i) * 2 * .pi * 317 / 48000)) * 0.2 } }
                        try file.write(from: buffer)
                    }
                    file.close()
                }
                let reference = try AVAudioFile(forReading: url)
                var frames: Int64 = 0
                let chunk = AVAudioPCMBuffer(pcmFormat: reference.processingFormat, frameCapacity: 4096)!
                while reference.framePosition < reference.length { try reference.read(into: chunk, frameCount: AVAudioFrameCount(min(4096, reference.length - reference.framePosition))); if chunk.frameLength == 0 { break }; frames += Int64(chunk.frameLength) }
                let asset = AVURLAsset(url: url); let duration = try await asset.load(.duration)
                let track = try await asset.loadTracks(withMediaType: .audio)[0]
                let reader = try AVAssetReader(asset: asset)
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey:kAudioFormatLinearPCM, AVLinearPCMBitDepthKey:32, AVLinearPCMIsFloatKey:true, AVLinearPCMIsNonInterleaved:false])
                reader.add(out); XCTAssertTrue(reader.startReading())
                var count = 0; var first: Double?
                while let buffer = out.copyNextSampleBuffer() { if first == nil { first = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }; count += CMSampleBufferGetNumSamples(buffer) }
                var audio: AudioFileID?; let opened = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audio)
                var table = AudioFilePacketTableInfo(); var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
                let status = audio.map { AudioFileGetProperty($0,kAudioFilePropertyPacketTableInfo,&size,&table) } ?? opened
                if let audio { AudioFileClose(audio) }
                print("W16-C codec=\(name) AVAudioFile=\(frames) reader=\(count) duration=\(duration.seconds) firstPTS=\(first ?? -999) packetStatus=\(status) valid=\(table.mNumberValidFrames) priming=\(table.mPrimingFrames) remainder=\(table.mRemainderFrames) readerStatus=\(reader.status.rawValue)")
                XCTAssertEqual(frames, 48000); XCTAssertEqual(count, 48000)
            } catch {
                let error = error as NSError
                print("W16-C ATTEMPT codec=\(name) API=AVAudioFile encoder/decoder errorDomain=\(error.domain) code=\(error.code)")
                throw error
            }
        }
    }
}
