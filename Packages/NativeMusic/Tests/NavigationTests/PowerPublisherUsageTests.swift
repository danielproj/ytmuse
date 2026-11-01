import Testing
import Foundation

/// P1 follow-up 3 (NP1): Low Power Mode notifications may arrive on any thread, and
/// view handlers write state, so W09's shell and artwork views must subscribe through
/// DesignSystem's main-queue `MusicGlassPower.changes`, never the raw notification.
@Suite struct PowerPublisherUsageTests {
    @Test func onlyDesignSystemSubscribesToTheRawPowerNotification() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "the scan must actually see the package sources")
        let raw = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("publisher(for: .NSProcessInfoPowerStateDidChange)") }
        #expect(raw.map(\.lastPathComponent) == ["DesignSystem.swift"])
        for name in ["BrowserShell.swift", "NativeArtworkView.swift"] {
            let file = try #require(files.first { $0.lastPathComponent == name })
            #expect(try String(contentsOf: file, encoding: .utf8).contains(".onReceive(MusicGlassPower.changes)"))
        }
    }
}
