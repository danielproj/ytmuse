import Foundation
import Testing
@testable import Playback

private final class BundleAnchor {}

/// Runs the real hidden-player WebKit page, scripts, bridge and WebMusicPlayer against the Fixtures/W17 stand-in document in a fresh
/// process (so nothing initialised WebKit before it). No network, no session, no sound; small non-activating panels appear on screen
/// for the length of the run, which is why UI-class runs hold the shared UI lock.
@Suite struct VideoProbeProcessTests {
    @Test func hiddenPlayerVideoLiveAndSurfacesHoldInAColdProcess() async throws {
        let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
        let probe = products.appendingPathComponent("VideoSurfaceProbe")
        try #require(FileManager.default.isExecutableFile(atPath: probe.path), "probe not built at \(probe.path)")
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtures = here.appendingPathComponent("../../../../Fixtures/W17").standardizedFileURL
        let video = try await OwnedTestVideo.url()
        let home = FileManager.default.homeDirectoryForCurrentUser
        defer {
            for folder in ["Library/WebKit/VideoSurfaceProbe", "Library/Caches/VideoSurfaceProbe", "Library/HTTPStorages/VideoSurfaceProbe"] {
                try? FileManager.default.removeItem(at: home.appendingPathComponent(folder))
            }
        }
        let process = Process()
        process.executableURL = probe
        process.arguments = [fixtures.path, video.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(240)
        var collected = Data()
        while process.isRunning && Date() < deadline {
            collected.append(output.fileHandleForReading.availableData)
            try await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        let text = String(decoding: collected, as: UTF8.self)
        print(text)
        #expect(process.terminationReason == .exit, "probe crashed: \(text)")
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text.contains("PASS") && !text.contains("FAIL"), "\(text)")
        #expect(!text.contains("SYNTHETIC-PROBE"), "the probe never prints cookie values")
        // The probe's own checks that must have run (a probe that stops early must not pass).
        // The decoder claims are conditional on frame counting, and the probe must say which branch ran (never an ok where it only skipped).
        if text.contains("SKIP frame positive control") {
            #expect(text.contains("SKIP decoder-stopped check") && !text.contains("ok the video decoder stopped"), "unavailable frame counting must be a SKIP, not an ok")
        } else {
            #expect(text.contains("ok the video decoder stopped") && text.contains("ok with the picture on screen the decoder produces frames"))
        }
        for required in ["fixture: the audio element holds no video track", "Go live returns to the live edge", "the document markup is restored exactly",
                         "an unpublished asset is a restart", "account switch / quit: the surface lets go with the page", "moving the picture did not reload the document",
                         "a seek to 60 s of the window lands at 60 s", "advertising layers are never covered", "while an ad plays and the picture is presented", "the web view never accepts first responder", "a click on the surface reaches nothing", "Go live falls back to the end of the seekable window"] {
            #expect(text.contains("ok " + required), "probe check missing: \(required)")
        }
    }
}
