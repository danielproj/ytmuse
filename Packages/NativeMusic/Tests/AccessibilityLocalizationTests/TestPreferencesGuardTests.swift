import Testing
import Foundation

// Operator rule (2026-11-01): a test never writes a persistent preferences domain. The Python guard (scripts/check-test-preferences.py) runs in every
// suite's preamble; this is the same sweep in-process, with a control, so the rule is also a failing test where the code is.

@Suite struct TestPreferencesGuardTests {
  /// Patterns held as data. The file that holds them is excluded from its own sweep.
  static let forbidden: [(String, String)] = [
    (#"UserDefaults\.standard\.(set|removeObject|setValuesForKeys|removePersistentDomain|setPersistentDomain)\("#, "writes the standard (persistent) domain"),
    (#"UserDefaults\.standard\.setValue\("#, "setValue on the standard domain"),
    (#"UserDefaults\(\)\s*\.(set|setValue|removeObject|setPersistentDomain)\("#, "UserDefaults() is the standard domain"),
    (#"UserDefaults\(\s*suiteName:\s*"(swiftpm|xctest|swift-test|com\.apple\.dt)[^"]*"\s*\)\s*!?\??\s*\.(set|setValue|removeObject|setValuesForKeys)\("#, "the test runner's own domain"),
    (#"\.setPersistentDomain\("#, "setPersistentDomain"),
    (#"CFPreferencesSet(AppValue|Value|Multiple)\("#, "CFPreferencesSet*"),
  ]
  static func violations(in text: String) -> [String] {
    let code = Repo.code(text)
    return forbidden.compactMap { pattern, why in code.range(of: pattern, options: .regularExpression) != nil ? why : nil }
  }
  @Test func noTestTargetWritesAPersistentPreferencesDomain() {
    var offenders: [String] = []
    let files = Repo.swiftFiles(under: "Packages/NativeMusic/Tests") + Repo.swiftFiles(under: "Tests")
    #expect(files.count > 50, "the sweep saw the test sources (\(files.count))")
    for (path, text) in files where !path.hasSuffix("TestPreferencesGuardTests.swift") {
      for why in Self.violations(in: text) { offenders.append("\(path): \(why)") }
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
    #expect(Self.violations(in: #"let store = UserDefaults(suiteName: "w-" + UUID().uuidString)!; store.set(1, forKey: "k")"#).isEmpty, "a unique per-test suite is allowed")
    #expect(Self.violations(in: "// UserDefaults.standard.set(1, forKey: \"k\") is what not to do").isEmpty, "comments are not code")
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
