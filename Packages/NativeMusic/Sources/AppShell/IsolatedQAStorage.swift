#if DEBUG
import Domain
import Foundation
import AccountSession

/// Debug-only QA namespace for UI automation. XCUITest launches the same bundle as
/// the account holder's copy, so an automated instance must never open the real
/// Application Support store, the login Keychain or the real sign-in ledger. Every
/// path lives under a fresh temporary root and both vaults are isolated keychain
/// files (`KeychainVault(testNamespace:isolatedKeychainURL:)`), which never search
/// the login Keychain. Absent from Release builds, so no environment can redirect
/// production storage.
struct IsolatedQAStorage: Sendable {
    static let environmentKey = "YTMUSE_UI_TEST_ISOLATED"
    /// Debug builds use isolated scratch storage unless one of these says otherwise. A launch that
    /// loses its environment (for example a sandboxed UI runner that "may drop launch arguments and
    /// environment variables") therefore lands on scratch storage, never on the account holder's data.
    static let realStoresKey = "YTMUSE_USE_REAL_STORES"
    static let realStoresArgument = "-YTMuseUseRealStores"
    enum Storage: Equatable, Sendable { case isolated, real }
    /// THE first decision at launch, before any store opens, as a pure function of the launch inputs.
    /// Explicit isolation (UI automation, design mode) always wins; real stores need an explicit
    /// opt-in (`YTMUSE_USE_REAL_STORES=1`, or the launch argument); anything else is isolated.
    /// Release builds do not contain this type: they always use the real stores.
    static func decide(environment: [String: String], arguments: [String]) -> Storage {
        if environment[environmentKey] == "1" || environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1" { return .isolated }
        let optedIn = environment[realStoresKey] == "1" || arguments.contains(realStoresArgument)
        return optedIn ? .real : .isolated
    }
    /// Decided once per process from the real launch inputs; every consumer reads this value.
    static let launch: Storage = decide(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments)
    /// Whether this process must use isolated scratch storage. The default arguments read the single
    /// launch decision; explicit inputs (tests) are decided on their own.
    static func requested(_ environment: [String: String]? = nil, arguments: [String]? = nil) -> Bool {
        guard environment != nil || arguments != nil else { return launch == .isolated }
        return decide(environment: environment ?? ProcessInfo.processInfo.environment, arguments: arguments ?? CommandLine.arguments) == .isolated
    }
    let root: URL
    let sessionVault: KeychainVault
    let ownedVault: KeychainVault
    /// The Keychain service-name namespaces of the two isolated vaults (test-namespaced; the destructive-action guard checks them).
    let keychainNamespaces: [String]
    static func create() async throws -> IsolatedQAStorage {
        try await Task.detached { try createNow() }.value
    }
    /// Synchronous: the bootstrap decides isolation before any window can act.
    static func createNow() throws -> IsolatedQAStorage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-ui-test-isolated-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let namespace = KeychainVault.applicationNamespace + ".test.ui-isolated-" + UUID().uuidString.lowercased()
        let session = try KeychainVault(testNamespace: namespace, isolatedKeychainURL: root.appendingPathComponent("session.keychain-db"))
        let owned = try KeychainVault(testNamespace: namespace + "-owned", isolatedKeychainURL: root.appendingPathComponent("owned.keychain-db"))
        return IsolatedQAStorage(root: root, sessionVault: session, ownedVault: owned, keychainNamespaces: [namespace, namespace + "-owned"])
    }
    /// Quit-path cleanup. A test runner that kills the process leaves only temporary files.
    func destroy() async {
        try? await sessionVault.destroyIsolatedTestKeychain()
        try? await ownedVault.destroyIsolatedTestKeychain()
        let root = root
        _ = try? await Task.detached { try GuardedFiles(root: root).remove(root, allowRoot: true) }.value
    }
}
#endif
