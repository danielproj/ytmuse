#if DEBUG
import Testing
import Foundation
@testable import AppShell

/// Under QA isolation every preference read/write goes to a throwaway plist in the
/// temporary folder, never the real `local.native-music.development` domain.
@Suite struct AppPreferencesTests {
    private let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
    /// C1 item 11: a Debug launch with no environment at all (for example one whose launch
    /// environment a sandboxed runner dropped) is isolated.
    @Test func anEmptyEnvironmentGetsAThrowawayPlistNotTheStandardDomain() throws {
        let resolved = AppPreferences.resolve(environment: [:])
        let path = try #require(resolved.isolatedPath, "default: isolated")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(resolved.store !== UserDefaults.standard)
    }
    /// Pure decision: resolving never reads or writes the standard domain, it only names it.
    @Test func onlyTheExplicitOptInUsesTheStandardDomain() {
        let resolved = AppPreferences.resolve(environment: [IsolatedQAStorage.realStoresKey: "1"])
        #expect(resolved.store === UserDefaults.standard && resolved.isolatedPath == nil)
    }
    @Test(arguments: [["YTMUSE_UI_TEST_ISOLATED": "1"], ["YTMUSE_NATIVE_DESIGN_TEST": "1"]])
    func isolationUsesAnAppOwnedThrowawayPlist(environment: [String: String]) throws {
        let resolved = AppPreferences.resolve(environment: environment)
        let path = try #require(resolved.isolatedPath)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(resolved.ownedByApp && resolved.store !== UserDefaults.standard)
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == temporary.path)
        #expect(URL(fileURLWithPath: path).lastPathComponent.hasPrefix("ytmuse-ui-test-defaults-"))
        let key = "isolation-probe-" + UUID().uuidString
        resolved.store.set("dark", forKey: key); resolved.store.synchronize()
        #expect(UserDefaults.standard.object(forKey: key) == nil, "an isolated write never reaches the standard domain")
        #expect(UserDefaults(suiteName: "local.native-music.development")?.object(forKey: key) == nil)
        #expect(FileManager.default.fileExists(atPath: path), "the plist lives at the throwaway path")
        // The registration domain is in-memory: the standard domain now "has" the key for reads, and nothing is written to the shared preferences file.
        UserDefaults.standard.register(defaults: [key: "standard"])
        #expect(UserDefaults.standard.string(forKey: key) == "standard", "control: the standard domain answers for the key")
        #expect(resolved.store.string(forKey: key) == "dark", "an isolated read never falls back to the standard domain")
    }
    @Test func aNamedTokenSelectsAStableThrowawayFileInTheAppsTemporaryFolder() throws {
        let token = UUID().uuidString
        let first = AppPreferences.resolve(environment: ["YTMUSE_UI_TEST_ISOLATED": "1", "YTMUSE_UI_TEST_DEFAULTS_ID": token])
        let path = try #require(first.isolatedPath)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(!first.ownedByApp && URL(fileURLWithPath: path).deletingLastPathComponent().path == temporary.path)
        #expect(URL(fileURLWithPath: path).lastPathComponent == "ytmuse-ui-test-defaults-named-" + token + ".plist")
        #expect(AppPreferences.resolve(environment: ["YTMUSE_UI_TEST_ISOLATED": "1", "YTMUSE_UI_TEST_DEFAULTS_ID": token]).isolatedPath == path, "a relaunch with the same token reuses the file")
    }
    @Test(arguments: ["local.native-music.development", "../../Library/Preferences/local.native-music.development",
                      NSHomeDirectory() + "/Library/Preferences/local.native-music.development.plist", "not-a-uuid"])
    func aTokenThatIsNotAUUIDIsRefused(token: String) throws {
        let resolved = AppPreferences.resolve(environment: ["YTMUSE_UI_TEST_ISOLATED": "1", "YTMUSE_UI_TEST_DEFAULTS_ID": token])
        let chosen = try #require(resolved.isolatedPath)
        defer { try? FileManager.default.removeItem(atPath: chosen) }
        #expect(resolved.ownedByApp && resolved.store !== UserDefaults.standard && !chosen.contains("named-"))
        #expect(URL(fileURLWithPath: chosen).deletingLastPathComponent().path == temporary.path)
    }
}
#endif
