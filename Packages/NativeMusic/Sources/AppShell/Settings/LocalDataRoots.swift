import AccountSession
import Domain
import Foundation
import WidgetShared

// W27 (real-data safety, rework 1). Every destructive action in Settings (the privacy reset, clearing an account's cache, a category's Restore Defaults, removing an
// account) works ONLY on the stores injected into the running session, and the check is made on what the destructive code will actually touch, not on what the
// session declares:
//
//  1. `LocalDataRoots` names the roots a session declares: the application directory (database, accounts, downloads, artwork), the owned-audio store, the Keychain
//     namespaces, the preferences root, the Spotlight index, the App Group snapshot directory. They are values handed in by the composition root.
//  2. `LocalDataTouches` is what the destructive objects ACTUALLY hold: the artwork pipeline's real cache directory, the widget store's real directory, the owned-audio
//     store's real directory, the namespaces of the vaults in use, the domain of the guarded preferences store, whether the index is the system's. They are read from the
//     live objects. `DestructiveActionGuard.verify(roots, touches)` refuses when any of them is outside the declared roots or is a real store while the session is isolated.
//  3. Below that, every destructive call goes through a wrapper that refuses a real store AT THE CALL: `GuardedFiles` (Domain), `GuardedDefaults` (Domain),
//     `GuardedKeychain` (AccountSession), and the system index wrapper in the app target. The raw APIs are forbidden everywhere else by a source sweep.

/// The stores one session reads and writes, as the composition root declares them.
struct LocalDataRoots: Equatable, Sendable {
    enum PreferencesRoot: Equatable, Sendable {
        /// A throwaway plist (QA isolation), named by its path.
        case isolatedPlist(String)
        /// A private in-memory domain (unit tests).
        case memory
        /// The app's own preferences domain (the account holder's real preferences).
        case standardDomain(String)
    }
    enum IndexRoot: Equatable, Sendable { case inMemory, system }
    var applicationDirectory: URL
    /// The owned-audio store (SQLite and encrypted retained objects). In production it is outside the application directory.
    var ownedAudioDirectory: URL
    /// Keychain service-name namespaces of the vaults this session uses (session vault, offline-key vault).
    var keychainNamespaces: [String]
    var preferences: PreferencesRoot
    var groupDirectory: URL?
    var searchIndex: IndexRoot
    /// Whether this session was started isolated. The composition root decides it once (`LaunchStorageDecision`).
    var isolated: Bool
}

/// What the destructive objects actually hold, read from the live objects.
struct LocalDataTouches: Equatable, Sendable {
    var artworkDirectory: URL?
    var widgetDirectory: URL?
    var ownedAudioDirectory: URL?
    var keychainNamespaces: [String]
    var preferences: LocalDataRoots.PreferencesRoot
    var searchIndex: LocalDataRoots.IndexRoot
}

/// The account holder's real stores (comparison only). One definition, shared with every wrapper.
typealias RealRoots = RealStores
extension RealStores {
    var keychainNamespace: String { keychainSessionNamespace }
}

enum DestructiveActionRefusal: Error, Equatable {
    /// The named root is (or lies inside) one of the account holder's real stores while this session is isolated.
    case realRoot(String)
    /// The path is outside the injected application directory.
    case outsideInjectedRoot
    /// A real-root action was requested without the person's confirmation.
    case notConfirmed
    /// What the destructive object holds is not what the session declared.
    case touchesUndeclared(String)
}

/// Created only by the Settings UI when the person presses the confirm button of a destructive action in a session that is not isolated.
struct PersonConfirmation: Sendable {
    fileprivate init() {}
    @MainActor static func fromConfirmationButton() -> PersonConfirmation { PersonConfirmation() }
}

/// Proof that the roots (and, where given, the touches) passed the guard. Only `verify` makes one.
struct VerifiedRoots: Sendable {
    let roots: LocalDataRoots
    fileprivate init(_ roots: LocalDataRoots) { self.roots = roots }
}

enum DestructiveActionGuard {
    static func canonical(_ url: URL) -> String { RealStores.canonical(url) }
    static func contains(_ parent: String, _ child: String) -> Bool { RealStores.contains(parent, child) }
    /// True when `url` is at or inside any real store directory.
    static func isInsideRealRoot(_ url: URL, real: RealRoots = RealStores.resolved()) -> Bool { real.containsRealPath(url) }

    private static func checkIsolatedDirectory(_ url: URL, name: String, real: RealRoots, temp: String) throws {
        if real.containsRealPath(url) { throw DestructiveActionRefusal.realRoot(name) }
        guard contains(temp, canonical(url)) else { throw DestructiveActionRefusal.realRoot(name + " outside the temporary folder") }
    }
    private static func checkIsolatedPreferences(_ root: LocalDataRoots.PreferencesRoot, temp: String) throws {
        switch root {
        case .standardDomain: throw DestructiveActionRefusal.realRoot("preferences domain")
        case .isolatedPlist(let path): guard contains(temp, canonical(URL(fileURLWithPath: path))) else { throw DestructiveActionRefusal.realRoot("preferences file outside the temporary folder") }
        case .memory: break
        }
    }
    private static func checkIsolatedNamespaces(_ namespaces: [String], real: RealRoots) throws {
        for namespace in namespaces where namespace == real.keychainSessionNamespace || !namespace.contains(".test.") { throw DestructiveActionRefusal.realRoot("keychain namespace") }
    }

    /// The verdict in words, for the Debug readout: "accepted" or "refused: <why>".
    static func verdict(_ roots: LocalDataRoots, touches: LocalDataTouches? = nil, real: RealRoots = RealStores.resolved()) -> String {
        do { _ = try verify(roots, touches: touches, confirmation: nil, real: real); return "accepted" }
        catch DestructiveActionRefusal.notConfirmed { return "needs the person's confirmation (not isolated)" }
        catch { return "refused: \(SafeErrorText.describe(error))" }
    }

    /// Verifies the declared roots and, when given, what the destructive objects actually hold. Isolated sessions may hold nothing but temporary, test-namespaced,
    /// in-memory or throwaway stores. A session that is not isolated acts only with the person's confirmation.
    @discardableResult
    static func verify(_ roots: LocalDataRoots, touches: LocalDataTouches? = nil, confirmation: PersonConfirmation?, real: RealRoots = RealStores.resolved(),
                       temporary: URL = FileManager.default.temporaryDirectory, processIsolated: Bool = ProcessIsolation.isIsolated) throws -> VerifiedRoots {
        // The PROCESS decides, not only the session's own flag: a test process is isolated whatever the roots claim, so a mis-declared session cannot open a real store.
        if roots.isolated || processIsolated {
            let temp = canonical(temporary)
            try checkIsolatedDirectory(roots.applicationDirectory, name: "application directory", real: real, temp: temp)
            try checkIsolatedDirectory(roots.ownedAudioDirectory, name: "owned-audio directory", real: real, temp: temp)
            try checkIsolatedNamespaces(roots.keychainNamespaces, real: real)
            try checkIsolatedPreferences(roots.preferences, temp: temp)
            if let group = roots.groupDirectory {
                if WidgetSnapshotStore.refusesRealContainer(group) { throw DestructiveActionRefusal.realRoot("App Group directory") }
                try checkIsolatedDirectory(group, name: "App Group directory", real: real, temp: temp)
            }
            if roots.searchIndex == .system { throw DestructiveActionRefusal.realRoot("Spotlight index") }
            if let touches {
                // What the objects hold must be what was declared (inside the declared directories) and must itself be isolated.
                let app = canonical(roots.applicationDirectory)
                if let dir = touches.artworkDirectory { try checkIsolatedDirectory(dir, name: "artwork cache directory", real: real, temp: temp); guard contains(app, canonical(dir)) else { throw DestructiveActionRefusal.touchesUndeclared("artwork cache") } }
                if let dir = touches.widgetDirectory { try checkIsolatedDirectory(dir, name: "widget snapshot directory", real: real, temp: temp); guard let declared = roots.groupDirectory, canonical(declared) == canonical(dir) else { throw DestructiveActionRefusal.touchesUndeclared("widget snapshot directory") } }
                if let dir = touches.ownedAudioDirectory { try checkIsolatedDirectory(dir, name: "owned-audio directory", real: real, temp: temp); guard canonical(roots.ownedAudioDirectory) == canonical(dir) else { throw DestructiveActionRefusal.touchesUndeclared("owned-audio directory") } }
                try checkIsolatedNamespaces(touches.keychainNamespaces, real: real)
                guard Set(touches.keychainNamespaces).isSubset(of: Set(roots.keychainNamespaces)) else { throw DestructiveActionRefusal.touchesUndeclared("keychain namespace") }
                try checkIsolatedPreferences(touches.preferences, temp: temp)
                guard touches.preferences == roots.preferences else { throw DestructiveActionRefusal.touchesUndeclared("preferences root") }
                if touches.searchIndex == .system { throw DestructiveActionRefusal.realRoot("Spotlight index") }
            }
            return VerifiedRoots(roots)
        }
        // Not isolated: this is the person's own app. Only an explicit confirmation lets a destructive action run.
        guard confirmation != nil else { throw DestructiveActionRefusal.notConfirmed }
        return VerifiedRoots(roots)
    }
}

/// How the eraser deletes files.
protocol ErasureFileSystem: Sendable {
    func remove(_ url: URL) throws
    func exists(_ url: URL) -> Bool
}
/// The eraser's file system: `GuardedFiles` confined to one injected directory.
struct GuardedFileSystem: ErasureFileSystem {
    let root: URL
    /// The process decides whether this is an isolated one (`ProcessIsolation`); nothing here can loosen that.
    private var files: GuardedFiles { GuardedFiles(root: root) }
    func remove(_ url: URL) throws {
        do { try files.remove(url) }
        catch GuardRefusal.outsideRoot { throw DestructiveActionRefusal.outsideInjectedRoot }
        catch GuardRefusal.realRoot(let what) { throw DestructiveActionRefusal.realRoot(what) }
    }
    func exists(_ url: URL) -> Bool { files.exists(url) }
}
