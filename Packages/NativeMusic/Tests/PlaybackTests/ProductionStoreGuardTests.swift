import Testing
import Foundation
import Domain
@testable import AppShell

/// C1 (W09-integration-opus-02, finding C): no test target may reach the production
/// owned-audio store or the production login-Keychain namespace
/// (`local.native-music.development.sessions`). Two layers: a runtime refusal in the owner
/// that fails any test constructing it without its own scratch directory and vault, and a
/// source guard over every test target.
@Suite struct ProductionStoreGuardTests {
    /// Pure rule: a test process counts as isolation, and the refusal decision then rejects every
    /// owner that lacks its own directory or vault. No owner is built or started here, so
    /// this is also the check to run against a mutated refusal.
    @Test func aTestProcessCountsAsIsolationAndTheRuleRefusesProductionDefaults() {
        #expect(AppPlaybackAuthority.processIsolationRequested, "unit tests are treated like QA isolation")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("never-created-" + UUID().uuidString)
        let isolated = AppPlaybackAuthority.processIsolationRequested
        #expect(AppPlaybackAuthority.refusesProductionDefaults(directory: nil, hasVault: false, isolationRequested: isolated))
        #expect(AppPlaybackAuthority.refusesProductionDefaults(directory: scratch, hasVault: false, isolationRequested: isolated))
        #expect(AppPlaybackAuthority.refusesProductionDefaults(directory: nil, hasVault: true, isolationRequested: isolated))
        #expect(!AppPlaybackAuthority.refusesProductionDefaults(directory: scratch, hasVault: true, isolationRequested: isolated))
    }
    /// Behavioural layer. The refusal is the first statement of `owned`, so with the production
    /// defaults it throws before any I/O. The `#require` is fatal on purpose: if the rule above
    /// ever regressed, nothing may run past it, because the starts below would open the real store.
    /// Never run this test against a mutated refusal.
    @Test func anOwnerWithoutItsOwnDirectoryAndVaultIsRefusedBeforeAnyIO() async throws {
        try #require(AppPlaybackAuthority.processIsolationRequested, "unit tests are treated like QA isolation")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("never-created-" + UUID().uuidString)
        for authority in [AppPlaybackAuthority(), AppPlaybackAuthority(directory: scratch)] {
            await #expect(throws: DomainError.forbidden) {
                _ = try await authority.owned(request: authority.requestOwnedStart(), initialGain: 0.001, maximumStartGain: 0.001)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "refused before any I/O")
    }

    /// The guard's own rules, applied to fixture lines, so it cannot be vacuous.
    @Test func theGuardRecognisesAccountCompositionWithoutAnIsolatedVault() {
        func offends(_ code: String) -> Bool { (code.contains(".openLocal(") || code.contains("LocalAccountComposition.open(")) && !code.contains("vault:") }
        #expect(offends("try await setup.openLocal(directory: directory)"))
        #expect(offends("try await LocalAccountComposition.open(directory: directory, playback: nil)"))
        #expect(!offends("try await setup.openLocal(directory: directory, vault: ConfigurationTestVault())"))
    }

    /// The owner rule, shared by the sweep and by its own fixture test. W17 rework (F6): a test never overrides the isolation decision
    /// (`isolationRequested:` defeats "a test process counts as isolation"); hosting a fake hidden player needs no directory only while
    /// isolation is not overridden; every other owner carries both a directory and an `offlineVault`.
    static func ownerOffence(_ code: String) -> String? {
        guard code.contains("AppPlaybackAuthority(") else { return nil }
        if code.contains("isolationRequested:") { return "owner overrides isolationRequested" }
        let usesFakePage = code.contains("makeMusicPage:") && !code.contains("directory")
        if !usesFakePage && !(code.contains("directory") && code.contains("offlineVault")) { return "owner without directory+offlineVault" }
        return nil
    }
    /// Source layer: every `AppPlaybackAuthority(` that can start owned audio carries both a
    /// directory and an `offlineVault`, and nothing constructs the production vault except
    /// the two named no-item uses.
    @Test func noTestTargetConstructsAProductionOwnerOrVault() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "the sweep covers the test targets")
        var offenders: [String] = []
        var sawOwner = 0
        for file in files where file.lastPathComponent != "ProductionStoreGuardTests.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                let place = "\(file.lastPathComponent):\(index + 1)"
                if code.contains("AppPlaybackAuthority(") {
                    sawOwner += 1
                    if let offence = Self.ownerOffence(code) { offenders.append(place + " " + offence) }
                }
                if code.contains("KeychainVault()") || code.range(of: #"KeychainVault\(namespace:\s*(KeychainVault\.applicationNamespace|"local\.native-music\.development\.sessions")"#, options: .regularExpression) != nil {
                    // Constructing the production vault is acceptable only where no item is touched.
                    if file.lastPathComponent != "KeychainNoPromptTests.swift" { offenders.append(place + " production KeychainVault") }
                }
                if code.contains("PlaybackModel()") { offenders.append(place + " default PlaybackModel owner") }
                // Account composition without an isolated vault falls back to the production KeychainVault().
                if (code.contains(".openLocal(") || code.contains("LocalAccountComposition.open(")) && !code.contains("vault:") {
                    offenders.append(place + " account composition without an isolated vault")
                }
                // W25: a test never names the real Spotlight index, WidgetCenter or the real App Group container (the dedicated sweep in WidgetSpotlightGuardTests carries the full rule set and the allowed files).
                for forbidden in ["CSSearchable" + "Index", "Widget" + "Center", "forSecurityApplication" + "GroupIdentifier", "Group " + "Containers"] where code.contains(forbidden) {
                    if !["WidgetSnapshotTests.swift", "WidgetSpotlightGuardTests.swift"].contains(file.lastPathComponent) { offenders.append(place + " names " + forbidden) }
                }
                // A test never names the real-stores opt-in as a literal (it would opt a test process in).
                if code.contains("YTMUSE_USE_REAL_STORES") || code.contains("-YTMuseUseRealStores") {
                    if !["LaunchStorageDecisionTests.swift"].contains(file.lastPathComponent) { offenders.append(place + " real-stores opt-in literal") }
                }
            }
        }
        #expect(sawOwner >= 10, "owner constructions were actually seen (\(sawOwner))")
        #expect(offenders.isEmpty, "\(offenders)")
    }
}

/// The owner rule applied to fixture lines (so the sweep above cannot be vacuous about the override).
@Suite struct ProductionStoreGuardRuleTests {
    @Test func anOverriddenIsolationDecisionIsAlwaysAnOffence() {
        func offends(_ code: String) -> Bool { ProductionStoreGuardTests.ownerOffence(code) != nil }
        #expect(offends("let owner = AppPlaybackAuthority(makeMusicPage: { d in Fake(d) }, isolationRequested: false)"))
        #expect(offends("AppPlaybackAuthority(directory: d, offlineVault: v, isolationRequested: false)"))
        #expect(offends("AppPlaybackAuthority()") && offends("AppPlaybackAuthority(directory: d)"))
        #expect(!offends("AppPlaybackAuthority(makeMusicPage: { d in Fake(d) })"))
        #expect(!offends("AppPlaybackAuthority(directory: d, offlineVault: v, makeMusicPage: { d in Fake(d) })"))
    }
}
