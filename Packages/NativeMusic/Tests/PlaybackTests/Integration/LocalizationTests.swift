import Foundation
import Testing
@testable import SystemIntegration
@testable import AppShell

/// Section 13: "All shortcuts appear in native menus, use localized labels". Every string W26 shows or speaks is in the string catalog, and every table
/// entry's menu title is a catalog key.
@Suite struct IntegrationLocalizationTests {
    private func catalog() throws -> Set<String> {
        let data = try Data(contentsOf: IntegrationSources.root.appendingPathComponent("Resources/Localizable.xcstrings"))
        let strings = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any])
        return Set(strings.keys.map { $0.replacingOccurrences(of: "%lld", with: "%@") })
    }
    static let files = ["Packages/NativeMusic/Sources/SystemIntegration/Links.swift", "Packages/NativeMusic/Sources/SystemIntegration/Shortcuts.swift", "Packages/NativeMusic/Sources/SystemIntegration/Scripting.swift",
                        "Packages/NativeMusic/Sources/SystemIntegration/HandoffAndNotifications.swift", "Packages/NativeMusic/Sources/AppShell/Integration/ShellIntegration.swift",
                        "Packages/NativeMusic/Sources/AppShell/Integration/IntegrationSettings.swift", "Packages/NativeMusic/Sources/AppShell/NativeMusicScenes.swift"]
    @Test func everyStringTheNodeShowsIsInTheStringCatalog() throws {
        let known = try catalog()
        let patterns = [#"String\(localized: "((?:[^"\\]|\\.)*)"\)"#, #"(?:Text|Label|Button|Picker|TextField|Section|Toggle|CommandMenu|LocalizedStringKey)\("((?:[^"\\]|\\.)*)""#]
        var checked = 0
        for file in Self.files {
            for line in try IntegrationSources.text(file).components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for pattern in patterns {
                    let regex = try NSRegularExpression(pattern: pattern)
                    for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                        guard let range = Range(match.range(at: 1), in: line) else { continue }
                        // A Debug-only readout line is not catalog text.
                        if line.contains("in-process fake") || line.contains("Apply Next Test Window Size") { continue }
                        let key = String(line[range]).replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "%@", options: .regularExpression).replacingOccurrences(of: "\\\"", with: "\"")
                        checked += 1
                        #expect(known.contains(key), "\(file.split(separator: "/").last ?? ""): missing from the catalog: \(key)")
                    }
                }
            }
        }
        #expect(checked > 40, "the sweep read the strings (\(checked))")
    }
    @Test func everyTableEntryTitleIsACatalogKeyAndNoTwoEntriesShareOne() throws {
        let known = try catalog()
        for entry in ShortcutTable.entries { #expect(known.contains(entry.title), "\(entry.action): \(entry.title)") }
        #expect(Set(ShortcutTable.entries.map(\.title)).count == ShortcutTable.entries.count)
        for action in GlobalShortcutAction.allCases { #expect(known.contains(action.title)) }
    }
}
