import Testing
import Foundation

// Operator rule (2026-11-01): a test never writes a persistent preferences domain. The Python guard (scripts/check-test-preferences.py) runs in every
// suite's preamble; this is the same sweep in-process, with a control, so the rule is also a failing test where the code is.

@Suite struct TestPreferencesGuardTests {
  /// Patterns held as data. The file that holds them is excluded from its own sweep.
  static let forbidden: [(String, String)] = [
    (#"UserDefaults\s*\.\s*standard\s*\.\s*(set|setValue|removeObject|setValuesForKeys|removePersistentDomain|setPersistentDomain)\s*\("#, "writes the standard (persistent) domain"),
    (#"UserDefaults\(\)\s*\.(set|setValue|removeObject|setPersistentDomain)\("#, "UserDefaults() is the standard domain"),
    (#"UserDefaults\(\s*suiteName:\s*"(swiftpm|xctest|swift-test|com\.apple\.dt)[^"]*"\s*\)\s*!?\??\s*\.(set|setValue|removeObject|setValuesForKeys)\("#, "the test runner's own domain"),
    (#"\.setPersistentDomain\("#, "setPersistentDomain"),
    (#"CFPreferencesSet(AppValue|Value|Multiple)\("#, "CFPreferencesSet*"),
    (#"["']/usr/bin/defaults["']"#, "runs the defaults tool"),
    (#"["'](?:[^"'\n]*/)?defaults["']\s*,\s*(?:["']-(?:currentHost|host)["']\s*,\s*(?:["'][^"'\n]*["']\s*,\s*)?)*["'](write|delete|import|rename)["']"#, "defaults write as an argument list"),
    (#"\btypealias\s+\w+\s*=\s*(NS)?UserDefaults\b"#, "a typealias around UserDefaults hides it from these rules"),
  ]
  /// TH5: a name bound to the standard domain (`let d = UserDefaults.standard`, `var d: UserDefaults = .standard`, a parameter defaulting to it, `UserDefaults()`), then written through.
  static let standardAliases = [#"\b(?:let|var)\s+(\w+)\s*(?::[^=\n]+)?=\s*\(?\s*UserDefaults\s*\.\s*standard\b"#, #"\b(?:let|var)\s+(\w+)\s*:\s*UserDefaults\??\s*=\s*\.standard\b"#,
                                #"\b(\w+)\s*:\s*UserDefaults\??\s*=\s*(?:UserDefaults\s*)?\.\s*standard\b"#, #"\b(?:let|var)\s+(\w+)\s*(?::[^=\n]+)?=\s*UserDefaults\s*\(\s*\)"#]
  static func aliasWrites(in code: String) -> [String] {
    var names = Set<String>()
    for pattern in standardAliases {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in expression.matches(in: code, range: NSRange(code.startIndex..., in: code)) where match.numberOfRanges > 1 {
        if let range = Range(match.range(at: 1), in: code) { names.insert(String(code[range])) }
      }
    }
    return names.sorted().filter { code.range(of: #"\b"# + $0 + #"\s*\.\s*(set|setValue|setValuesForKeys|removeObject|removePersistentDomain|setPersistentDomain)\s*\("#, options: .regularExpression) != nil }
  }
  /// TH3: opening a defaults suite makes a preferences domain of its own. A suite NAMED by a bare string writes `~/Library/Preferences/<name>.plist` (17,833 files on
  /// 2026-11-01), so the only file that may open one is TestSupport's (a path inside a scratch folder, or never written).
  static let suiteOpening = #"(UserDefaults\s*\(\s*suiteName\s*:|UserDefaults\s*\.\s*init\s*\(\s*suiteName\s*:|\binit\s*\(\s*suiteName\s*:|\bNSUserDefaults\b|\.removePersistentDomain\()"#
  static let suiteHome = "Packages/NativeMusic/Tests/TestSupport/"
  static func violations(in text: String, path: String = "Packages/NativeMusic/Tests/SomeTests/X.swift") -> [String] {
    let code = Repo.code(text)
    var found = forbidden.compactMap { pattern, why in code.range(of: pattern, options: .regularExpression) != nil ? why : nil }
    found += aliasWrites(in: code).map { "writes the standard domain through the alias `\($0)`" }
    if !path.hasPrefix(suiteHome), code.range(of: suiteOpening, options: .regularExpression) != nil { found.append("opens a defaults suite (or removes a persistent domain) outside TestSupport") }
    return found
  }
  @Test func noTestTargetWritesAPersistentPreferencesDomain() {
    var offenders: [String] = []
    let files = Repo.swiftFiles(under: "Packages/NativeMusic/Tests") + Repo.swiftFiles(under: "Tests")
    #expect(files.count > 50, "the sweep saw the test sources (\(files.count))")
    for (path, text) in files where !path.hasSuffix("TestPreferencesGuardTests.swift") {
      for why in Self.violations(in: text, path: path) { offenders.append("\(path): \(why)") }
    }
    #expect(offenders.isEmpty, "persistent preferences writes in tests: \(offenders)")
  }
  @Test func theSweepCatchesWhatItIsFor() {
    #expect(!Self.violations(in: #"UserDefaults.standard.set(true, forKey: "NSDoubleLocalizedStrings")"#).isEmpty)
    #expect(!Self.violations(in: #"UserDefaults.standard.removeObject(forKey: "k")"#).isEmpty)
    #expect(!Self.violations(in: #"UserDefaults().set(true, forKey: "NSDoubleLocalizedStrings")"#).isEmpty)
    #expect(!Self.violations(in: #"UserDefaults.standard.setValue(true, forKey: "k")"#).isEmpty)
    #expect(!Self.violations(in: #"UserDefaults(suiteName: "swiftpm-testing-helper")!.set(true, forKey: "NSDoubleLocalizedStrings")"#).isEmpty)
    #expect(!Self.violations(in: #"CFPreferencesSetAppValue("k" as CFString, 1 as CFNumber, kCFPreferencesCurrentApplication)"#).isEmpty)
    #expect(Self.violations(in: #"UserDefaults.standard.register(defaults: ["NSDoubleLocalizedStrings": true])"#).isEmpty, "the in-memory form is allowed")
    for text in [#"let store = UserDefaults(suiteName: "w-" + UUID().uuidString)!; store.set(1, forKey: "k")"#, #"let s = try #require(UserDefaults(suiteName: "local.native-music.test-" + id))"#,
                 #"let s = UserDefaults (suiteName: path)"#, #"let s = UserDefaults.init(suiteName: name)"#, #"s.removePersistentDomain(forName: n)"#, #"super.init(suiteName: "x")!"#] {
      #expect(!Self.violations(in: text).isEmpty, "a suite opened by name or path is refused outside TestSupport: \(text)")
      #expect(Self.violations(in: text, path: Self.suiteHome + "ScratchDefaults.swift").isEmpty, "and allowed in TestSupport: \(text)")
    }
    #expect(Self.violations(in: "let store = InMemoryDefaults(); let scratch = ScratchDefaults(); scratch.defaults.set(1, forKey: \"k\")").isEmpty, "the in-memory and scratch stores are the allowed forms")
    #expect(Self.violations(in: "// UserDefaults.standard.set(1, forKey: \"k\") is what not to do").isEmpty, "comments are not code")
    // TH5 (TH3 critic L2): the forms the older rules missed. Each plant is caught; each control is not.
    for text in ["let prefs = UserDefaults.standard\nprefs.set(true, forKey: \"k\")", "var prefs: UserDefaults = .standard\nprefs.removeObject(forKey: \"k\")",
                 "func apply(to defaults: UserDefaults = .standard) { defaults.set(1, forKey: \"k\") }", "let d = UserDefaults()\nd.setValue(1, forKey: \"k\")",
                 "UserDefaults.standard\n    .set(true, forKey: \"k\")", "typealias Prefs = UserDefaults", "typealias Prefs = NSUserDefaults",
                 "process.executableURL = URL(fileURLWithPath: \"/usr/bin/defaults\")", "let args = [\"defaults\", \"-currentHost\", \"write\", \"-g\", \"k\"]"] {
      #expect(!Self.violations(in: text).isEmpty, "a form the older rules missed: \(text)")
    }
    for text in ["let prefs = UserDefaults.standard\nlet v = prefs.string(forKey: \"k\")", "let prefs = UserDefaults.standard\nprefs.register(defaults: [\"k\": 1])",
                 "let prefs = InMemoryDefaults()\nprefs.set(true, forKey: \"k\")", "typealias Handler = (Int) -> Void", "let args = [\"defaults\", \"read\", \"k\"]"] {
      #expect(Self.violations(in: text).isEmpty, "control, not a write: \(text)")
    }
  }
  /// The pseudolanguage switch really is process-local: registering it leaves the persistent domain untouched.
  @Test func registeringADefaultDoesNotReachThePersistentDomain() {
    let key = "w28-probe-" + UUID().uuidString
    UserDefaults.standard.register(defaults: [key: true])
    #expect(UserDefaults.standard.bool(forKey: key), "readable in this process")
    let persistent = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) ?? [:]
    #expect(persistent[key] == nil, "never written to the shared preferences file")
  }
}
