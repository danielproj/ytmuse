import Foundation
import Testing

/// TH3 (W39 critic R2-L2): the engine's test doubles (`stickDecodedMixerForTesting`, `stuckMixerVolumeForTesting`) live in production source under `#if DEBUG`. A Release
/// binary must not carry a way to make the engine's mixer refuse silence, or any other hook a test installs. Every identifier that ends in `ForTesting` in the product
/// (package sources, the app, the extensions) must therefore be declared and used only inside a `#if DEBUG` region. The scanner is proved on planted text first, and the
/// sweep asserts that it found the known hooks (a sweep that sees none passes nothing).
///
/// TH5 (TH3 critic L3): the identifier forms are `…ForTesting`, `…ForTests`, `…ForTest` and `testing…` (e.g. `testingHook`), plus any `public` or `open` `…ForMeasurement`
/// member. The product has no hook of the `ForTests`, `ForTest` or `testing…` forms today; the sweep refuses one the day it appears.
/// WHY the internal `…ForMeasurement` members (a dozen, such as `hasDecodedBackendForMeasurement`) are not required to be inside `#if DEBUG`: they are `internal`, so
/// the only way to reach them is `@testable import`, which a Release build does not allow (the module is built without testability), and a test target is never part of
/// the app. They are dead code in Release, not an entry point. A `public` or `open` one WOULD be reachable from the app or an extension, so that form is swept like the others.
@Suite struct DebugHookSweepTests {
    /// The identifier forms that name a test hook, and the public measurement members. Held as data so the planted tests below use the very same expressions.
    static let hookIdentifier = #"\b\w*[Ff]or(Testing|Tests?)\b|\btesting[A-Z_]\w*\b"#
    static let publicMeasurement = #"\b(public|open)\b[^\n{=]*\b\w+ForMeasurement\b"#
    /// Line numbers (1-based) of every `…ForTesting` identifier that is NOT inside a `#if DEBUG` region. A region ends at its `#endif`; an `#else` / `#elseif`
    /// branch of a `#if DEBUG` is not Debug; `#if !DEBUG` is not Debug; a nested `#if` of another condition keeps its enclosing Debug region.
    static func unguarded(in text: String) -> (hooks: [Int], unguarded: [Int]) {
        var stack: [Bool] = []   // true while the innermost branch of that #if is a Debug-only branch
        var hooks: [Int] = [], bad: [Int] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.replacingOccurrences(of: #"(?<!:)//.*$"#, with: "", options: .regularExpression)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                let condition = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                stack.append(condition == "DEBUG" || condition.hasPrefix("DEBUG ") && !condition.contains("||"))
            } else if trimmed.hasPrefix("#elseif") || trimmed.hasPrefix("#else") { if !stack.isEmpty { stack[stack.count - 1] = false } }
            else if trimmed.hasPrefix("#endif") { if !stack.isEmpty { stack.removeLast() } }
            else if line.range(of: Self.hookIdentifier, options: .regularExpression) != nil || line.range(of: Self.publicMeasurement, options: .regularExpression) != nil {
                hooks.append(index + 1)
                if !stack.contains(true) { bad.append(index + 1) }
            }
        }
        return (hooks, bad)
    }

    @Test func theScannerKnowsWhatDebugOnlyMeans() {
        func bad(_ text: String) -> [Int] { Self.unguarded(in: text).unguarded }
        #expect(bad("func stickForTesting() {}") == [1], "a bare hook is unguarded")
        #expect(bad("#if DEBUG\nfunc stickForTesting() {}\n#endif") == [], "inside #if DEBUG")
        #expect(bad("#if DEBUG\nfunc a() {}\n#endif\nfunc stickForTesting() {}") == [4], "after the #endif")
        #expect(bad("#if DEBUG\nfunc a() {}\n#else\nfunc stickForTesting() {}\n#endif") == [4], "the #else branch of #if DEBUG ships in Release")
        #expect(bad("#if !DEBUG\nfunc stickForTesting() {}\n#endif") == [2], "#if !DEBUG is Release")
        #expect(bad("#if DEBUG || RELEASE_TOOLS\nfunc stickForTesting() {}\n#endif") == [2], "an or-condition is not Debug-only")
        #expect(bad("#if DEBUG\n#if os(macOS)\nfunc stickForTesting() {}\n#endif\nvar stuckForTesting: Int?\n#endif") == [], "a nested #if keeps the Debug region around it")
        #expect(bad("#if os(macOS)\nfunc stickForTesting() {}\n#endif") == [2], "another condition is not Debug")
        #expect(bad("// stickForTesting is only mentioned in a comment\nlet x = 1 // and here: stuckForTesting") == [], "comments are not code")
        #expect(bad("#if DEBUG\nfunc ok() {}\n#endif\n#if DEBUG\nlet y = stuckForTesting\n#endif") == [], "two separate Debug regions")
        // TH5: the other forms, each planted outside #if DEBUG (caught) and inside it (control).
        for planted in ["public func probeForTests() {}", "public func probeForTest() {}", "public var testingHook: Int?", "func testing_stick() {}", "public func tickForMeasurement() {}",
                        "open func settleForMeasurement() async {}", "public private(set) var framesForMeasurement = 0"] {
            #expect(bad(planted) == [1], "outside #if DEBUG: \(planted)")
            #expect(bad("#if DEBUG\n\(planted)\n#endif") == [], "control, inside #if DEBUG: \(planted)")
        }
        // Controls: an internal measurement member is not an entry point (see the note above), and ordinary words that merely contain `test` are not hooks.
        #expect(bad("func hasDecodedBackendForMeasurement() -> Bool { false }") == [], "internal: reachable only through @testable import")
        #expect(bad("let contest = 1\nfunc attestation() {}\nvar latestTime = 0\nfunc fortestingly() {}") == [], "names that only contain `test` are not hooks")
    }

    @Test func everyTestHookInTheProductIsDebugOnly() throws {
        let files = ["Packages/NativeMusic/Sources", "App/Sources", "Extensions"].flatMap(SettingsSources.swiftFiles(under:))
        #expect(files.count > 100, "the sweep looked at the product (\(files.count) files)")
        var seen = Set<String>(), offenders: [String] = []
        for file in files {
            let result = Self.unguarded(in: try String(contentsOf: file, encoding: .utf8))
            if !result.hooks.isEmpty { seen.insert(file.lastPathComponent) }
            for line in result.unguarded { offenders.append("\(file.lastPathComponent):\(line)") }
        }
        // Not vacuous: the engine's two doubles and the scheduler's variant read are known hooks, so the sweep must have found them.
        #expect(seen.isSuperset(of: ["NativePlayer.swift", "IncrementalDecodedPlayer.swift", "DownloadScheduler.swift"]), "hooks found in \(seen.sorted())")
        #expect(offenders.isEmpty, "test hooks outside #if DEBUG (they would ship in Release): \(offenders)")
    }
}
