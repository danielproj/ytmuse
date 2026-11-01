import Foundation
import Testing

private final class BundleAnchor {}

/// What the SHIPPED WebKit exposes to a page for choosing an audio output or an AirPlay target, measured in a fresh process (`OutputCapabilityProbe`).
/// `Docs/Routes.md` rests on these facts: the hidden YouTube Music player follows the Mac's output because no public per-element choice is usable.
/// If a WebKit update changes one of them, this fails so the decision is made again instead of the new capability silently going unused.
@Suite struct WebKitCapabilityProbeTests {
    static func facts() throws -> (text: String, facts: [String: String]) {
        let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
        let probe = products.appendingPathComponent("OutputCapabilityProbe")
        try #require(FileManager.default.isExecutableFile(atPath: probe.path), "probe not built at \(probe.path)")
        let home = FileManager.default.homeDirectoryForCurrentUser
        defer { for folder in ["Library/WebKit/OutputCapabilityProbe", "Library/Caches/OutputCapabilityProbe", "Library/HTTPStorages/OutputCapabilityProbe"] { try? FileManager.default.removeItem(at: home.appendingPathComponent(folder)) } }
        let process = Process()
        process.executableURL = probe
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(text)")
        #expect(text.contains("PASS") && !text.contains("FAIL"), "\(text)")
        var facts: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("fact ") {
            let pair = line.dropFirst(5).split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { facts[pair[0]] = pair[1] }
        }
        return (text, facts)
    }

    @Test func aPageCannotLearnAnyAudioOutputWithoutCapturePermissionSoPerElementRoutingHasNoUsableIdentifier() throws {
        let (text, facts) = try Self.facts()
        #expect(facts["isSecureContext"] == "true", "\(text)")
        // The API surface exists in this WebKit ...
        #expect(facts["setSinkId"] == "function" && facts["sinkIdProperty"] == "true" && facts["enumerateDevices"] == "function")
        // ... but without capture permission (which this app never grants a page) it lists no output to name, and offers no way to ask for one.
        #expect(facts["enumerateAudioOutputs"] == "0" && facts["enumerateOutputsWithId"] == "0" && facts["enumerateOutputsWithLabel"] == "0", "\(text)")
        #expect(facts["selectAudioOutput"] == "undefined", "no permission-free output chooser")
        #expect(facts["setSinkIdDefault"] == "resolved" && facts["setSinkIdUnknown"] == "NotFoundError", "only the default is accepted; an identifier we cannot obtain is refused")
        #expect(facts["audioContextSetSinkId"] == "undefined")
    }
    @Test func theAirPlayTargetPickerIsAPageApiNeedingAUserGestureInAPageNobodySees() throws {
        let (text, facts) = try Self.facts()
        // The page-side pickers exist, but they are invoked by page script from a user gesture inside the page. The hidden page is never shown and the app
        // never synthesises input into it, so there is no supported way to open one; the app disables WebKit's AirPlay for the page (see the guard).
        #expect(facts["showPlaybackTargetPicker"] == "function" && facts["remotePlayback"] == "function", "\(text)")
        #expect(facts["defaultAllowsAirPlayForMediaPlayback"] == "true", "WebKit's own default is on; the player turns it off explicitly")
    }
}
