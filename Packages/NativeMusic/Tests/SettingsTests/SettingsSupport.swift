import AppKit
import Foundation
import Testing
import Domain
import AccountSession
@testable import Features
@testable import AppShell
import TestSupport

// W27 test support. Everything here is synthetic and lives in memory or in a fresh temporary folder created by the test that needs it. No test in this target
// names a real path, a real Keychain namespace, the standard preferences domain, the real Spotlight index or an App Group.

/// The repository root, from this file's own location.
enum SettingsSources {
    static var packageRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static var repositoryRoot: URL { packageRoot.deletingLastPathComponent().deletingLastPathComponent() }
    static func swiftFiles(under relative: String) -> [URL] {
        let root = relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : repositoryRoot.appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            if [".build", ".git", ".swiftpm", "DerivedData"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if url.pathExtension == "swift" { found.append(url) }
        }
        return found
    }
    static func text(_ relative: String) throws -> String { try String(contentsOf: repositoryRoot.appendingPathComponent(relative), encoding: .utf8) }
}

/// A fresh scratch folder for one test, removed by `cleanup()`.
struct Scratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-settings-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

@MainActor func memoryStore(account: UUID? = nil) throws -> (SettingsStore, MemorySettingsBacking, AccountBox) {
    let backing = MemorySettingsBacking(); let box = AccountBox(account)
    return (try SettingsStore(backing: backing, account: { box.account }), backing, box)
}
@MainActor final class AccountBox { var account: UUID?; init(_ account: UUID?) { self.account = account } }

/// A scripted application for the window census.
@MainActor final class SettingsFakeApplication: ApplicationActivating {
    var presence: DockPresence = .regular
    var isHidden = false
    func setPresence(_ presence: DockPresence) { self.presence = presence }
    func activate() {}
}

func syntheticAccount(_ channel: String = "UCsynthetic0001", uuid: UUID = UUID(), name: String = "Synthetic Listener") throws -> Account {
    let context = try AccountContext(accountID: uuid, channelID: ID<ChannelTag>(channel), region: "US")
    return try Account(id: uuid, serviceIdentity: ServiceID("synthetic-service"), context: context, displayName: name, credential: nil)
}
func isolatedVault() throws -> (KeychainVault, URL, String) {
    let namespace = KeychainVault.applicationNamespace + ".test." + UUID().uuidString
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-settings-keychain-" + UUID().uuidString + ".keychain-db")
    return (try KeychainVault(testNamespace: namespace, isolatedKeychainURL: url), url, namespace)
}

/// A guarded defaults store over a private suite named by an absolute path in a scratch folder (never the standard domain, never a name in the runner's shared
/// domain space). TH2: whether a store is real is derived from that domain, so a test that wants a throwaway store must name a file inside the temporary folder.
func privateDefaults(_ path: String) -> (GuardedDefaults, UserDefaults, String) {
    let store = ScratchDefaults.open(path: path)
    return (GuardedDefaults(store: store, domain: path), store, path)
}

/// Every suite that composes the app (`LocalAccountBootstrap`) shares ONE isolated preferences file for the process, so they run one after another.
@Suite(.serialized) enum ComposedBootstrapSuites {}
