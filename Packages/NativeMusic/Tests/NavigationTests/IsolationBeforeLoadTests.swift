#if DEBUG
import Testing
import Foundation
@testable import AppShell

/// Critic W09-integration finding 2: under QA isolation no playback owner bound to the
/// real owned-audio store or login Keychain may exist, even before `load()` completes.
@Suite(.serialized) @MainActor struct IsolationBeforeLoadTests {
    /// Builds an isolated bootstrap and removes its scratch root before returning or
    /// throwing. The earlier `defer { Task { await storage.destroy() } }` returned
    /// before the clean-up ran, so every run (and every failed `#require`) leaked a
    /// `ytmuse-ui-test-isolated-*` folder; awaiting here makes the removal synchronous
    /// with the test.
    private func withIsolatedBootstrap(_ environment: [String: String], _ body: (LocalAccountBootstrap, IsolatedQAStorage) async throws -> Void) async throws {
        let bootstrap = LocalAccountBootstrap(environment: environment)
        let storage = try #require(bootstrap.isolatedStorage, "isolation is decided synchronously in init")
        do { try await body(bootstrap, storage) }
        catch { await storage.destroy(); throw error }
        await storage.destroy()
    }
    @Test func theFirstPlaybackOwnerIsIsolatedBeforeLoad() async throws {
        try await withIsolatedBootstrap(["YTMUSE_UI_TEST_ISOLATED": "1"]) { bootstrap, storage in
        let binding = await bootstrap.playback.authority.ownedStorageBinding()
        // Binding checks only. This test never performs an owned start: starting is covered
        // against explicit scratch bindings elsewhere, and a start here would be the vehicle
        // by which a regression could reach a production store.
        try #require(binding.directory == storage.root.appendingPathComponent("owned-audio"), "never nil, which would mean the real local.native-music.owned-audio")
        try #require(binding.vault == ObjectIdentifier(storage.ownedVault), "never nil, which would mean the production login-Keychain vault")
        #expect(bootstrap.playback.controlledAudioTest == false && bootstrap.playback.gainRange.upperBound == 1)
        }
    }
    @Test func theIsolatedRootIsRemovedWhenTheTestEnds() async throws {
        var removed: URL?
        try await withIsolatedBootstrap(["YTMUSE_UI_TEST_ISOLATED": "1"]) { _, storage in
            removed = storage.root
            #expect(FileManager.default.fileExists(atPath: storage.root.path), "precondition: the root exists while in use")
        }
        let root = try #require(removed)
        #expect(!FileManager.default.fileExists(atPath: root.path), "no ytmuse-ui-test-isolated-* folder is left behind")
    }
    @Test func theIsolatedRootIsRemovedWhenABodyAssertionThrows() async throws {
        struct Boom: Error {}
        var removed: URL?
        await #expect(throws: Boom.self) {
            try await withIsolatedBootstrap(["YTMUSE_UI_TEST_ISOLATED": "1"]) { _, storage in removed = storage.root; throw Boom() }
        }
        let root = try #require(removed)
        #expect(!FileManager.default.fileExists(atPath: root.path), "a failing test leaks nothing either")
    }
    /// The authority's second line of defence, tested as a pure rule (a behavioural test
    /// would itself reach production paths if the rule regressed).
    @Test func underIsolationAnOwnedStartRefusesEveryProductionDefault() {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("never-created")
        #expect(AppPlaybackAuthority.refusesProductionDefaults(directory: nil, hasVault: true, isolationRequested: true))
        #expect(AppPlaybackAuthority.refusesProductionDefaults(directory: scratch, hasVault: false, isolationRequested: true))
        #expect(AppPlaybackAuthority.refusesProductionDefaults(directory: nil, hasVault: false, isolationRequested: true))
        #expect(!AppPlaybackAuthority.refusesProductionDefaults(directory: scratch, hasVault: true, isolationRequested: true))
        #expect(!AppPlaybackAuthority.refusesProductionDefaults(directory: nil, hasVault: false, isolationRequested: false), "production launches keep their defaults")
    }
    @Test func theDesignModeIsIsolatedAndCapsTheTestGain() async throws {
        try await withIsolatedBootstrap(["YTMUSE_NATIVE_DESIGN_TEST": "1"]) { bootstrap, storage in
            #expect(bootstrap.playback.controlledAudioTest && bootstrap.playback.gainRange.upperBound == 0.001)
            #expect(await bootstrap.playback.authority.ownedStorageBinding().directory == storage.root.appendingPathComponent("owned-audio"))
        }
    }
    /// C1 item 11: with NO environment (a dropped launch environment) the Debug bootstrap is still isolated.
    @Test func aLaunchWithNoEnvironmentIsIsolatedByDefault() async throws {
        try await withIsolatedBootstrap([:]) { bootstrap, storage in
            let binding = await bootstrap.playback.authority.ownedStorageBinding()
            try #require(binding.directory == storage.root.appendingPathComponent("owned-audio"), "never nil: that would be the real owned-audio store")
            try #require(binding.vault == ObjectIdentifier(storage.ownedVault), "never nil: that would be the production vault")
        }
    }
}
#endif
