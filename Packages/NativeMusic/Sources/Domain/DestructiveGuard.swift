import Foundation

// W27 rework 1 (real-data safety). The primitives every destructive operation in the app goes through. The rule is enforced at the CALL, not at a declaration:
//
//  * `GuardedFiles` deletes and replaces files, only inside one directory its owner injected, and refuses a real store at the call itself.
//  * `GuardedDefaults` (and `AccountSession.GuardedKeychain`) do the same for preferences and Keychain items.
//  * `ProcessIsolation` says whether this process may touch a real store at all. A test process is always isolated; the app declares its launch decision once.
//  * A source sweep (SettingsGuardTests) forbids the raw APIs (FileManager.removeItem and trashItem, SecItemDelete and SecItemUpdate, UserDefaults.standard / () / (suiteName:),
//    removePersistentDomain / setPersistentDomain, CSSearchableIndex.default()) everywhere in Sources, App and Extensions except inside these wrappers.

public enum GuardRefusal: Error, Equatable, Sendable {
    /// The target is (or lies inside) one of the account holder's real stores while this process is isolated.
    case realRoot(String)
    /// The path is outside the directory this operation was given.
    case outsideRoot
}

public enum ProcessIsolation {
    nonisolated(unsafe) private static var declared = false
    /// The app's launch decision (Debug QA isolation, or Release: never). Called once, before any store opens.
    public static func establish(isolated: Bool) { declared = isolated }
    /// A unit-test process is isolated whatever the app declared: no test can reach a real store.
    public static var runningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }
    public static var isIsolated: Bool { declared || runningUnderTests }
}

/// The account holder's real stores, as paths and names. Computed for comparison only: nothing here opens, reads or writes them.
public struct RealStores: Sendable {
    public let home: URL
    public let applicationSupport: URL
    /// The owned-audio store and its encrypted retained objects.
    public let ownedAudio: URL
    public let groupContainers: URL
    public let keychainSessionNamespace: String
    public let preferencesDomain: String
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, bundleIdentifier: String = "local.native-music.development") {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        let support = self.home.appendingPathComponent("Library/Application Support", isDirectory: true)
        applicationSupport = support.appendingPathComponent("local.native-music.development", isDirectory: true)
        ownedAudio = support.appendingPathComponent("local.native-music.owned-audio", isDirectory: true)
        groupContainers = self.home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        keychainSessionNamespace = Self.sessionKeychainNamespace
        preferencesDomain = bundleIdentifier
    }
    /// The account holder's real stores. INTERNAL to the guard: nothing else names it (`SettingsGuardTests` sweeps for it), so no code can hand it to a wrapper, and the
    /// wrappers' public initializers do not take a `RealStores` or an isolation flag at all. Callers that only COMPARE a path with the real stores use `resolved`.
    static let current = RealStores()
    /// For comparison only (the destructive-action verification): `override` is a test's fake home; nil is the real one. TH2: it hands the real paths to the caller, so
    /// the source sweep (`SettingsGuardTests`) allows its name only in `DestructiveGuard.swift`, the destructive-action verification (`LocalDataRoots.swift`) and the updater's file guard (`UpdateFiles.swift`).
    public static func resolved(_ override: RealStores? = nil) -> RealStores { override ?? current }
    /// The Keychain service namespace of the real session vault, as a name only.
    public static let sessionKeychainNamespace = "local.native-music.development.sessions"

    /// Canonical path: symlinks resolved on the part that exists, `..` removed.
    public static func canonical(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 { tail.insert(existing.lastPathComponent, at: 0); existing = existing.deletingLastPathComponent() }
        var resolved = existing.resolvingSymlinksInPath()
        for part in tail { resolved.appendPathComponent(part) }
        return resolved.standardizedFileURL.path
    }
    public static func contains(_ parent: String, _ child: String) -> Bool { child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/") }
    /// True when `url` is at or inside any real store directory.
    public func containsRealPath(_ url: URL) -> Bool {
        let path = Self.canonical(url)
        return [applicationSupport, ownedAudio, groupContainers].contains { Self.contains(Self.canonical($0), path) }
    }
}

/// File deletion and replacement, confined to one injected directory. The owner of a directory builds one for it; nothing else deletes a file.
public struct GuardedFiles: Sendable {
    public let root: URL
    private let tighten: Bool
    private let real: RealStores
    /// The only public way to build one: the process decides (`ProcessIsolation`), and the real stores are the real ones.
    public init(root: URL) { self.root = root; tighten = false; real = .current }
    /// A test may use a FAKE home (so nothing real is ever named) and may force isolation ON. `isolated` can only TIGHTEN the check: `false` never loosens it, the
    /// process flag still applies. Internal, so only a `@testable` test can reach it.
    init(root: URL, isolated: Bool?, real: RealStores) { self.root = root; tighten = isolated == true; self.real = real }
    private var isolated: Bool { tighten || ProcessIsolation.isIsolated }

    /// The entry itself, not what a final symlink points at: its parent folder is resolved, its own name is kept (removing a link removes the link).
    private static func entry(_ url: URL) -> String {
        let parent = RealStores.canonical(url.deletingLastPathComponent())
        return parent.hasSuffix("/") ? parent + url.lastPathComponent : parent + "/" + url.lastPathComponent
    }
    private func check(_ url: URL, allowRoot: Bool) throws {
        let target = Self.entry(url), parent = RealStores.canonical(root), rootEntry = Self.entry(root)
        let isRoot = target == parent || target == rootEntry
        guard RealStores.contains(parent, target) || isRoot, allowRoot || !isRoot else { throw GuardRefusal.outsideRoot }
        if isolated, real.containsRealPath(url.deletingLastPathComponent()) || real.containsRealPath(URL(fileURLWithPath: target)) { throw GuardRefusal.realRoot("path") }
    }
    /// Removes a file or folder inside the root. A missing target is not an error. `allowRoot` lets an owner remove its own directory.
    public func remove(_ url: URL, allowRoot: Bool = false) throws {
        try check(url, allowRoot: allowRoot)
        guard FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return }
        try FileManager.default.removeItem(at: url)
    }
    /// Atomically replaces `target` with the staged file, both inside the root.
    @discardableResult
    public func replace(_ target: URL, withStaged staging: URL) throws -> URL? {
        try check(target, allowRoot: false); try check(staging, allowRoot: false)
        return try FileManager.default.replaceItemAt(target, withItemAt: staging)
    }
    /// Moves a file or folder inside the root to another place inside the root (both ends checked; never replaces an existing item).
    public func move(_ source: URL, to destination: URL) throws {
        try check(source, allowRoot: false); try check(destination, allowRoot: false)
        try FileManager.default.moveItem(at: source, to: destination)
    }
    /// Copies inside the root (both ends checked).
    public func copy(_ source: URL, to destination: URL) throws {
        try check(source, allowRoot: false); try check(destination, allowRoot: false)
        try FileManager.default.copyItem(at: source, to: destination)
    }
    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// Preferences writes and removals, bound to ONE session store. A store that is the account holder's real preferences domain refuses every write and removal while
/// the process is isolated, at the call.
public final class GuardedDefaults: @unchecked Sendable {
    /// For reads and for owners that were handed this store; destructive operations go through this class.
    public let store: UserDefaults
    public let domain: String
    /// TH2: derived from the session's own domain, never supplied. A domain is a throwaway only when it is an absolute path inside the temporary folder (the app's isolated
    /// plist, or a test's scratch file); every other name, the product's bundle identifier included, is the account holder's real domain.
    public let isRealDomain: Bool
    public init(store: UserDefaults, domain: String) { self.store = store; self.domain = domain; isRealDomain = !Self.isThrowaway(domain) }
    static func isThrowaway(_ domain: String, temporary: URL = FileManager.default.temporaryDirectory) -> Bool {
        guard domain.hasPrefix("/"), !domain.contains("\0") else { return false }
        let url = URL(fileURLWithPath: domain)
        // TH2 rework: the file usually does not exist yet, and `canonical` removes `..` lexically BEFORE it resolves a symlink, so `<temp>/<link>/../x.plist` looked like
        // `<temp>/x.plist` while the kernel writes `<link target>/../x.plist`. So: no `.` or `..` component at all, and the decision is made on the real path of the PARENT folder
        // plus the file's own name, as `GuardedFiles.entry` does.
        let parts = url.pathComponents
        guard !parts.contains("."), !parts.contains(".."), let name = parts.last, name != "/" else { return false }
        let target = RealStores.canonical(url.deletingLastPathComponent()) + "/" + name, temp = RealStores.canonical(temporary)
        return RealStores.contains(temp, target) && target != temp
    }
    private func check() throws { if isRealDomain, ProcessIsolation.isIsolated { throw GuardRefusal.realRoot("preferences domain") } }
    public func value(forKey key: String) -> Any? { store.object(forKey: key) }
    public func set(_ value: Any?, forKey key: String) throws { try check(); if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) } }
    public func remove(_ key: String) throws { try check(); store.removeObject(forKey: key) }
    public func keys(withPrefix prefix: String) -> [String] { store.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) } }
    /// Empties this session's domain.
    public func removeAll() throws { try check(); store.removePersistentDomain(forName: domain) }
}
