import Foundation
import Testing

private final class BundleAnchor {}

/// Runs the real WebKit store removal/reconciliation in a separate, fresh
/// process so nothing has initialised WebKit before it (E01 M2 rework, F1).
@Suite struct WebKitStoreProcessTests {
    @Test func realStoreRemovalAndReconciliationSurviveAColdProcess() throws {
        let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
        let probe = products.appendingPathComponent("WebKitStoreProbe")
        try #require(FileManager.default.isExecutableFile(atPath: probe.path), "probe not built at \(probe.path)")
        let ledger = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-webkit-probe-" + UUID().uuidString)
        let home = FileManager.default.homeDirectoryForCurrentUser
        defer {
            try? FileManager.default.removeItem(at: ledger)
            // Only this probe's own WebKit/caches folders, named after the probe executable.
            for folder in ["Library/WebKit/WebKitStoreProbe", "Library/Caches/WebKitStoreProbe", "Library/HTTPStorages/WebKitStoreProbe"] {
                try? FileManager.default.removeItem(at: home.appendingPathComponent(folder))
            }
        }
        let process = Process()
        process.executableURL = probe
        process.arguments = [ledger.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(90)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationReason == .exit, "probe crashed: \(text)")
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text.contains("PASS"), "\(text)")
        #expect(!text.contains("FAIL"), "\(text)")
    }

    /// The hidden YouTube Music player's real WebKit page, cold, in its own process.
    @Test func hiddenPlayerPageSurvivesAColdProcess() throws {
        let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
        let probe = products.appendingPathComponent("WebMusicPlayerProbe")
        try #require(FileManager.default.isExecutableFile(atPath: probe.path), "probe not built at \(probe.path)")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Fixtures/E01-P1").standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        defer {
            for folder in ["Library/WebKit/WebMusicPlayerProbe", "Library/Caches/WebMusicPlayerProbe", "Library/HTTPStorages/WebMusicPlayerProbe"] {
                try? FileManager.default.removeItem(at: home.appendingPathComponent(folder))
            }
        }
        let process = Process()
        process.executableURL = probe
        process.arguments = [fixtures.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(90)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationReason == .exit, "probe crashed: \(text)")
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text.contains("PASS") && !text.contains("FAIL"), "\(text)")
        #expect(!text.contains("SYNTHETIC-PROBE"), "the probe never prints cookie values")
    }

    /// Q1: quit through `requestQuit` (the quit Apple Event and Quit menu path),
    /// called from inside a GCD main-queue block, in a real NSApplication.
    private func runQuitProbe(_ mode: String) throws -> (text: String, seconds: Double, wall: Double, status: Int32, reason: Process.TerminationReason) {
        let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
        let probe = products.appendingPathComponent("QuitProbe")
        try #require(FileManager.default.isExecutableFile(atPath: probe.path), "probe not built at \(probe.path)")
        let process = Process()
        process.executableURL = probe; process.arguments = [mode]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        let start = Date()
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let wall = Date().timeIntervalSince(start)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // TH1: the quit's duration is the probe's own measure from the quit request to termination; the launch is not part of the quit. The 30 s
        // loop above bounds a hang. If the line is missing the quit did not reach
        // termination, and the duration is reported as infinite so every bound below fails.
        var seconds = Double.infinity
        if let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("QUIT-ELAPSED-MS ") }), let ms = Double(line.dropFirst("QUIT-ELAPSED-MS ".count)) { seconds = ms / 1000 }
        print("QUIT-PROBE-TIMING mode=\(mode) quit=\(seconds)s wall=\(wall)s")   // the wall time includes the launch; kept for the record
        return (text, seconds, wall, process.terminationStatus, process.terminationReason)
    }
    @Test func quitRunsTheMainActorShutdownAndExitsPromptly() throws {
        let run = try runQuitProbe("complete")
        #expect(run.reason == .exit && run.status == 0, "\(run.text)")
        #expect(run.text.contains("SHUTDOWN-MAIN-ACTOR") && run.text.contains("SHUTDOWN-DONE"),
                "the MainActor shutdown actually ran (it could not while terminate: sat inside a GCD block): \(run.text)")
        #expect(run.seconds < 1.4, "exited before the 1.5 s deadline, so by the shutdown itself: \(run.seconds)s (wall incl. launch \(run.wall)s)")
    }
    @Test func quitStillRepliesWhenTheShutdownNeverCompletes() throws {
        let run = try runQuitProbe("hang")
        #expect(run.reason == .exit && run.status == 0, "\(run.text)")
        #expect(run.text.contains("SHUTDOWN-STARTED") && !run.text.contains("SHUTDOWN-DONE"), "\(run.text)")
        #expect(run.seconds >= 1.4 && run.seconds < 6, "replied at the deadline: \(run.seconds)s")
        #expect(!run.text.contains("FAIL"), "\(run.text)")
    }
}
