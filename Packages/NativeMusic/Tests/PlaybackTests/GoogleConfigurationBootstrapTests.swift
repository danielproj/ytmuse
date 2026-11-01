import Foundation
import Testing
@testable import AppShell
import AccountSession
import Domain

private actor ConfigurationTestVault: SessionVault {
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) async throws { throw DomainError.unsupported }
    func bind(_ context: RequestContext) {}
    func insert(_ bytes: Data, for account: AccountContext) throws -> CredentialReference { throw DomainError.unsupported }
    func read(_ reference: CredentialReference, context: RequestContext) throws -> Data { throw DomainError.unsupported }
    func delete(_ reference: CredentialReference, for account: AccountContext) {}
    func deleteAll(for account: AccountContext) {}
}
private actor ConfigurationTestAuthorization {
    var state: GoogleConnectionState
    var removals = 0
    init(_ state: GoogleConnectionState) { self.state = state }
    func current() -> GoogleConnectionState { state }
    func remove() { removals += 1; state = .disconnected }
    func count() -> Int { removals }
}
@Suite @MainActor struct GoogleConfigurationBootstrapTests {
    @Test func malformedOptionalConfigurationStillOpensLocalAccounts() async throws {
        for raw: Any in ["bad", "$(UNEXPECTED_SETTING)", 123] {
            let setup = try GoogleAuthorizationSetup(info: ["YTMuseGoogleDesktopClientID": raw])
            #expect(setup.invalid && setup.configuration == nil)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("e01-config-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let lifecycle = try await setup.openLocal(directory: directory, vault: ConfigurationTestVault())
            #expect(await lifecycle.snapshot().directory.identities.isEmpty)
            #expect(setup.status(for: .disconnected) == .configurationInvalid)
        }
        let missing = try GoogleAuthorizationSetup(info: [:])
        #expect(!missing.invalid && missing.configuration == nil)
        let unresolved = try GoogleAuthorizationSetup(info: ["YTMuseGoogleDesktopClientID": "$(YTMUSE_GOOGLE_DESKTOP_CLIENT_ID)"])
        #expect(unresolved.invalid && unresolved.configuration == nil)
    }
    @Test func actualSetupAndModelKeepRemovalAvailableWithoutConfiguration() async throws {
        for info: [String: Any] in [[:], ["YTMuseGoogleDesktopClientID": "bad"], ["YTMuseGoogleDesktopClientID": "$(YTMUSE_GOOGLE_DESKTOP_CLIENT_ID)"], ["YTMuseGoogleDesktopClientID": "synthetic-owned.apps.googleusercontent.com"]] {
            let setup = try GoogleAuthorizationSetup(info: info)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("e01-status-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let lifecycle = try await setup.openLocal(directory: directory, vault: ConfigurationTestVault())
            for state in [GoogleConnectionState.storedAuthorization, .cleanupRequired, .disconnected, .profileVerified] {
                let storage = ConfigurationTestAuthorization(state)
                let model = setup.makeModel(lifecycle: lifecycle,
                    authenticate: { _ in Issue.record("Authorization should not be invoked by status mapping") },
                    status: { await storage.current() }, refresh: {}, disconnect: { await storage.remove() })
                await model.refresh()
                #expect(model.canAuthenticate == (setup.configuration != nil))
                #expect(model.canDisconnectAuthorization == (state != .disconnected))
                #expect(model.canRefreshAuthorization == (setup.configuration != nil && state == .profileVerified))
                #expect(!model.authenticationCanConnectMusic && model.identities.isEmpty)
                if state == .cleanupRequired { #expect(model.connectionStatus == state.explanation) }
                if setup.invalid && state == .storedAuthorization {
                    #expect(model.connectionStatus.contains("invalid") && model.connectionStatus.contains("stored locally"))
                }
                if state != .disconnected {
                    await model.disconnectAuthorization()
                    #expect(await storage.count() == 1)
                    #expect(!model.canDisconnectAuthorization && !model.canRefreshAuthorization)
                }
            }
        }
    }
    @Test func genuineLocalStorageErrorsStillThrow() async throws {
        let setup = try GoogleAuthorizationSetup(info: ["YTMuseGoogleDesktopClientID": "bad"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("e01-not-directory-" + UUID().uuidString)
        try Data().write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: (any Error).self) { try await setup.openLocal(directory: file, vault: ConfigurationTestVault()) }
    }
}
