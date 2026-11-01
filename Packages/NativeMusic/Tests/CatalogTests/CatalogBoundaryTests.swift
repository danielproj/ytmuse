import Foundation
import Testing

/// Structural guarantees of the catalog code, checked on the sources themselves.
@Suite struct CatalogBoundaryTests {
    private var sources: URL { fixturesRoot().deletingLastPathComponent().appendingPathComponent("Packages/NativeMusic/Sources") }
    private func files(_ folders: [String]) throws -> [(String, String)] {
        var result: [(String, String)] = []
        for folder in folders {
            let url = sources.appendingPathComponent(folder)
            let enumerator = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
            for case let file as URL in enumerator where file.pathExtension == "swift" { result.append((file.lastPathComponent, try String(contentsOf: file, encoding: .utf8))) }
        }
        return result
    }
    /// `\(…)` with balanced parentheses becomes `%@` (or `%lld` for a count, matched by the caller).
    static func replacingInterpolations(_ text: String) -> String {
        var result = "", depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            if depth == 0, text[index...].hasPrefix("\\(") { depth = 1; result += "%@"; index = text.index(index, offsetBy: 2); continue }
            let character = text[index]
            if depth > 0 { if character == "(" { depth += 1 } else if character == ")" { depth -= 1 } } else { result.append(character) }
            index = text.index(after: index)
        }
        return result
    }
    private let catalogFolders = ["Features/Catalog", "Features/Home", "Features/Explore", "Features/CatalogDetails"]

    @Test func theSweptPopulationIsNotEmpty() throws {
        let names = try files(catalogFolders).map(\.0)
        #expect(names.count >= 8 && names.contains("CatalogRichText.swift") && names.contains("CatalogPageModel.swift") && names.contains("HomeView.swift") && names.contains("ExploreView.swift"))
    }
    @Test func noWebViewNoNetworkNoLoggingInTheCatalogScreens() throws {
        let forbidden = ["WKWebView", "import WebKit", "WebView", "URLSession", "URLRequest", "NSLog(", "os_log", "Logger(", "print(", "dump(", "NSAppleScript", "Process("]
        for (name, text) in try files(catalogFolders) {
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for token in forbidden { #expect(!code.contains(token), "\(name) contains \(token)") }
        }
    }
    @Test func featuresDoNotImportTheAdapterOrPlaybackInternals() throws {
        for (name, text) in try files(catalogFolders) {
            for module in ["import YouTubeMusicAdapter", "import Playback", "import StreamResolver", "import Downloads"] { #expect(!text.contains(module), "\(name) imports \(module)") }
        }
    }
    @Test func theParserNeverLogsOrTouchesTheNetworkAndNamesNoShelfTitle() throws {
        let text = try String(contentsOf: sources.appendingPathComponent("YouTubeMusicAdapter/MusicBrowseParser.swift"), encoding: .utf8)
        for token in ["print(", "NSLog(", "os_log", "Logger(", "URLSession", "Quick picks", "New releases", "Top songs", "Singles"] {
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            #expect(!code.contains(token), "the parser contains \(token)")
        }
    }
    @Test func theDevelopmentCatalogIsDebugOnly() throws {
        let text = try String(contentsOf: sources.appendingPathComponent("AppShell/DevelopmentCatalog.swift"), encoding: .utf8)
        #expect(text.hasPrefix("#if DEBUG") && text.contains("#endif"))
        let composition = try String(contentsOf: sources.appendingPathComponent("AppShell/CatalogComposition.swift"), encoding: .utf8)
        // Every reference to the development catalog sits inside a DEBUG block.
        var depth = 0
        for line in composition.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if DEBUG") { depth += 1 } else if trimmed.hasPrefix("#endif") { depth -= 1 }
            if trimmed.contains("DevelopmentCatalog") && !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") { #expect(depth > 0, "unguarded: \(trimmed)") }
        }
    }
    /// Every error message the catalog can show must exist in the String Catalog (no raw English key left unlocalised).
    @Test func catalogUserStringsAreInTheStringCatalog() throws {
        let data = try Data(contentsOf: fixturesRoot().deletingLastPathComponent().appendingPathComponent("Resources/Localizable.xcstrings"))
        let catalog = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any])
        let pattern = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        var checked = 0
        for (name, text) in try files(catalogFolders) {
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                var key = String(text[range])
                key = Self.replacingInterpolations(key)
                checked += 1
                #expect(catalog[key] != nil || catalog[key.replacingOccurrences(of: "%@", with: "%lld")] != nil, "\(name): missing \(key)")
            }
        }
        #expect(checked >= 30)
    }
}
