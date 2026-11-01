// W17 fixture: a SILENT audio-only AAC file (digital zeros, 60 s) standing in for a song version of the synthetic video in the offline
// WebKit probe. Nothing audible, nothing third-party. CC0-1.0. Usage: swift generate-song.swift <output.m4a>
import AVFoundation
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "owned-song-silent.m4a")
try? FileManager.default.removeItem(at: output)
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
do {
    let file = try AVAudioFile(forWriting: output, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000])
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
    buffer.frameLength = 44100   // zero-filled by allocation
    for _ in 0..<60 { try file.write(from: buffer) }
}
print("wrote \(output.path)")
