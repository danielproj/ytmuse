import AppKit
import Foundation
import SystemIntegration
import Testing
import WidgetShared
@testable import AppShell

// W25 test support. Nothing here names the real App Group container, WidgetCenter, an installed widget or the system's Spotlight index: the store is over a
// temporary directory of the test's own, the reloader records, the index is in memory. `WidgetSpotlightGuardTests` sweeps every test file to keep it so.

enum Scratch {
    /// A fresh directory under the temporary folder, named by this call's own id. The test removes exactly this one.
    static func make() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w25-test-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    static func bytes(in directory: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let base = directory.resolvingSymlinksInPath().path + "/"
        guard let walker = FileManager.default.enumerator(at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey]) else { return found }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            found[url.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "")] = try? Data(contentsOf: url)
        }
        return found
    }
}

enum WidgetFixtures {
    static let when = Date(timeIntervalSince1970: 1_800_000_000)
    static let account = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let scope = WidgetScope(account: account, generation: 5)
    static let allButtons = WidgetCapabilities(playPause: true, next: true, previous: true)
    static func playing(_ title: String = "Synthetic Song", artist: String? = "Synthetic Artist", scope: WidgetScope = scope, caps: WidgetCapabilities = allButtons) -> WidgetSnapshot {
        WidgetSnapshot(state: .playing, title: title, artist: artist, capabilities: caps, scope: scope, serial: 1, writtenAt: when)
    }
    /// A real, tiny PNG so the thumbnailer has an image to decode.
    static func picture(edge: Int = 400) -> Data {
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in NSColor.systemPurple.setFill(); rect.fill(); return true }
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }
    static func nowPlaying(_ title: String = "Synthetic Song", artist: String? = "Synthetic Artist", playing: Bool = true, ad: Bool = false, artwork: Data? = nil, id: String = "A") -> NowPlayingItem {
        NowPlayingItem(title: title, artist: artist, album: nil, artwork: artwork, duration: 200, elapsed: 10, playing: playing, advertisement: ad, itemID: id)
    }
}

/// The repository root, found from this file, for source sweeps.
enum WidgetSources {
    nonisolated static var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/test.sh").path) { url.deleteLastPathComponent() }
        return url
    }
    nonisolated static func files(under path: String, extensions: Set<String> = ["swift"]) -> [URL] {
        let base = root.appendingPathComponent(path)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension) && !$0.path.contains("/.build/") }
    }
    nonisolated static func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    /// Source without line comments (a rule about code must not fire on prose).
    nonisolated static func code(_ text: String) -> String { text.components(separatedBy: "\n").map { $0.components(separatedBy: "//").first ?? $0 }.joined(separator: "\n") }
}
