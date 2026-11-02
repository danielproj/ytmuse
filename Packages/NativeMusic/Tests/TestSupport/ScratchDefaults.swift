import Foundation

// TH3 (operator rule, 2026-11-01): a test never opens a preferences domain by NAME.
//
// `UserDefaults(suiteName: "some-name")` makes cfprefsd write `~/Library/Preferences/some-name.plist`, and cfprefsd rewrites the file after a test has deleted it.
// Tests that did this left 17,833 files there (`ytmuse-settings-test-<UUID>`, `ytmuse-diag-test-<UUID>`, `local.native-music.test-<UUID>`, ...), which the
// operator deleted by hand on 2026-11-01. A suite named by an ABSOLUTE PATH writes only that path, so the two types below are the only ways a test gets a store:
//
//  * `InMemoryDefaults`: every accessor is answered from a dictionary; nothing reaches any file.
//  * `ScratchDefaults`: a real `UserDefaults` over a plist inside a folder this object creates under the temporary directory and removes again (also on
//    deinit). Use it when a test needs the real behaviour (a second instance over the same file, KVO, a persistent domain read back).
//
// `scripts/check-test-preferences.py` (and `TestPreferencesGuardTests`) refuse `UserDefaults(suiteName:)` anywhere in the tests outside this folder.

/// The temporary-folder test for a preferences path. Fail safe: a path that is not lexically AND physically inside this process's temporary folder, or that
/// names anything under a `Library/Preferences` folder, is refused before any store is opened.
public enum ScratchPaths {
    public static func isThrowaway(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("/Library/Preferences") else { return false }
        // TH5 (TH3 critic L4): a `.` or `..` component is refused outright. Resolving such a path lexically and physically can disagree: `<temp>/missing/../link/..`
        // collapses to `<temp>` lexically while the file system walks out through `link`.
        guard !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) else { return false }
        // TH5: the file itself must not be a link (even a dangling one): the folder test below resolves only the folder, and a store opened over a link writes
        // wherever it points.
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil else { return false }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        // The file need not exist yet: resolve its folder, which must.
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
        return folder == temporary || folder.hasPrefix(temporary + "/")
    }
}

public final class ScratchDefaults: @unchecked Sendable {
    public let folder: URL
    /// The suite name: an absolute path to a plist inside `folder`.
    public let path: String
    public let defaults: UserDefaults
    public init(label: String = "defaults") {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-test-defaults-" + UUID().uuidString, isDirectory: true)
        path = folder.appendingPathComponent(label + ".plist").path
        // Stop before anything is created or opened unless the path is a throwaway one.
        precondition(ScratchPaths.isThrowaway(path), "ScratchDefaults refuses a path outside the temporary folder: \(path)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: path)!
    }
    /// A store over a plist the CALLER already keeps in its own scratch folder (a test that crafts the file, or names it for a guard under test). Fail safe: a path
    /// that is not a throwaway one stops the test process before any store is opened.
    public static func open(path: String) -> UserDefaults {
        precondition(ScratchPaths.isThrowaway(path), "ScratchDefaults.open refuses a path outside the temporary folder: \(path)")
        return UserDefaults(suiteName: path)!
    }
    /// A second `UserDefaults` over the same file (a relaunch of the thing under test).
    public func reopen() -> UserDefaults { UserDefaults(suiteName: path)! }
    /// Removes the plist and its folder. Idempotent; also runs when the object goes away.
    public func clean() {
        guard ScratchPaths.isThrowaway(path) else { return }
        defaults.removePersistentDomain(forName: path)
        try? FileManager.default.removeItem(at: folder)
    }
    deinit { clean() }
}

/// Preferences that never reach the disk. Every accessor the shell, the stores and the tests use is answered from a dictionary. The superclass is opened over a
/// throwaway PATH (never a bare name), so an accessor this class forgets to override would write a file in the temporary folder, not a preferences domain.
public final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    public init() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-test-inmemory-" + UUID().uuidString + ".plist").path
        precondition(ScratchPaths.isThrowaway(path), "InMemoryDefaults refuses a path outside the temporary folder")
        super.init(suiteName: path)!
    }
    private func read(_ key: String) -> Any? { lock.withLock { values[key] ?? registered[key] } }
    private func write(_ value: Any?, _ key: String) { lock.withLock { values[key] = value } }
    public override func object(forKey defaultName: String) -> Any? { read(defaultName) }
    public override func value(forKey key: String) -> Any? { read(key) }
    public override func set(_ value: Any?, forKey defaultName: String) { write(value, defaultName) }
    public override func setValue(_ value: Any?, forKey key: String) { write(value, key) }
    public override func set(_ value: Bool, forKey defaultName: String) { write(value, defaultName) }
    public override func set(_ value: Int, forKey defaultName: String) { write(value, defaultName) }
    public override func set(_ value: Float, forKey defaultName: String) { write(value, defaultName) }
    public override func set(_ value: Double, forKey defaultName: String) { write(value, defaultName) }
    public override func set(_ url: URL?, forKey defaultName: String) { write(url?.absoluteString, defaultName) }
    public override func removeObject(forKey defaultName: String) { lock.withLock { _ = values.removeValue(forKey: defaultName) } }
    public override func register(defaults registrationDictionary: [String: Any]) { lock.withLock { registered.merge(registrationDictionary) { _, new in new } } }
    // TH5 (TH3 critic L5): the scalar getters convert the way `UserDefaults` does (a number answers every numeric getter, a numeric string is read as a number, a number
    // answers `string(forKey:)`), not by an exact type cast: `set(2.7, ...)` then `integer(forKey:)` is 2 and not 0. `TestSupportDefaultsTests` compares every getter
    // with a `ScratchDefaults` store over a matrix of stored values.
    public override func bool(forKey defaultName: String) -> Bool {
        switch read(defaultName) {
        case let number as NSNumber: return number.boolValue
        case let text as String: return Self.boolean(of: text)
        default: return false
        }
    }
    public override func integer(forKey defaultName: String) -> Int {
        switch read(defaultName) {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text) ?? 0   // a whole-string integer, as a real store reads it: "3.9", "1e3" and " 12 " are 0
        default: return 0
        }
    }
    public override func float(forKey defaultName: String) -> Float {
        switch read(defaultName) {
        case let number as NSNumber: return number.floatValue
        case let text as String: return (text as NSString).floatValue
        default: return 0
        }
    }
    public override func double(forKey defaultName: String) -> Double {
        switch read(defaultName) {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return (text as NSString).doubleValue
        default: return 0
        }
    }
    public override func string(forKey defaultName: String) -> String? {
        switch read(defaultName) {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }
    /// How a stored string reads as a boolean in a real store: only these words (any case). `TestSupportDefaultsTests` pins this against a real store.
    static func boolean(of text: String) -> Bool { ["yes", "true", "1"].contains(text.lowercased()) }
    public override func data(forKey defaultName: String) -> Data? { read(defaultName) as? Data }
    public override func array(forKey defaultName: String) -> [Any]? { read(defaultName) as? [Any] }
    public override func stringArray(forKey defaultName: String) -> [String]? { read(defaultName) as? [String] }
    public override func dictionary(forKey defaultName: String) -> [String: Any]? { read(defaultName) as? [String: Any] }
    public override func url(forKey defaultName: String) -> URL? { (read(defaultName) as? String).flatMap(URL.init(string:)) }
    public override func dictionaryRepresentation() -> [String: Any] { lock.withLock { registered.merging(values) { _, new in new } } }
    public override func removePersistentDomain(forName domainName: String) { lock.withLock { values.removeAll() } }
    public override func synchronize() -> Bool { true }
    public var isEmpty: Bool { lock.withLock { values.isEmpty } }
}
