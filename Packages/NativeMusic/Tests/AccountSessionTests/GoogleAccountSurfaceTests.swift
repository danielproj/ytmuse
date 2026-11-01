import Foundation
import Testing
import Domain
import Features
import AccountSession

private actor GoogleSurfaceState {
    var state: GoogleConnectionState = .profileVerified
    var refreshes = 0
    func current() -> GoogleConnectionState { state }
    func refresh() { refreshes += 1 }
    func disconnect() { state = .disconnected }
    func count() -> Int { refreshes }
}
@Suite @MainActor struct GoogleAccountSurfaceTests {
    @Test func configuredGoogleActionDoesNotCreateMusicIdentity() async throws {
        let vault = try testVault()
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: MemoryDirectory(), participants: [])
        let status = GoogleSurfaceState()
        let model = AccountsModel(lifecycle: lifecycle,
            authentication: { challenge in await lifecycle.cancelAuthentication(challenge) },
            authenticationLabel: "Authorize Google identity", authenticationCanConnectMusic: false,
            connectionStatus: { await status.current() }, refreshAuthorization: { await status.refresh() },
            disconnectAuthorization: { await status.disconnect() })
        await model.authenticate()
        #expect(model.canAuthenticate)
        #expect(model.authenticationCanConnectMusic == false)
        #expect(model.identities.isEmpty)
        #expect(model.connectionStatus == GoogleConnectionState.profileVerified.explanation)
        #expect(model.canDisconnectAuthorization && model.canRefreshAuthorization)
        #expect(await lifecycle.snapshot().reconnectPending == false)
        await model.refreshAuthorization()
        #expect(await status.count() == 1)
        await model.disconnectAuthorization()
        #expect(!model.canDisconnectAuthorization && !model.canRefreshAuthorization)
        try await vault.destroyIsolatedTestKeychain()
    }
    @Test func absentConfigurationHasNoAuthorizationAction() async {
        let model = AccountsModel(connectionStatus: { .configurationMissing })
        await model.refresh()
        #expect(!model.canAuthenticate)
        #expect(!model.canDisconnectAuthorization)
        #expect(model.connectionStatus == GoogleConnectionState.configurationMissing.explanation)
    }
}

private actor FeedbackAttempt {
    var calls = 0
    var waiting: CheckedContinuation<Void, Never>?
    func run() async throws {
        calls += 1
        if calls == 1 { throw DesktopOAuthError.missingClientSecret }
        await withCheckedContinuation { waiting = $0 }
    }
    func ready() -> Bool { waiting != nil }
    func finish() { waiting?.resume(); waiting = nil }
}
extension GoogleAccountSurfaceTests {
    @Test func sharedFeedbackShowsFailureClearsOnRetryAndCompletes() async throws {
        let vault = try testVault()
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: MemoryDirectory(), participants: [])
        let attempt = FeedbackAttempt()
        let model = AccountsModel(lifecycle: lifecycle, authentication: { challenge in
            try await attempt.run(); await lifecycle.cancelAuthentication(challenge)
        })
        await model.authenticate()
        #expect(model.message == GoogleAuthorizationFeedback.message(for: .missingClientSecret))
        #expect(model.message?.contains("paused") == false)
        let retry = Task { await model.authenticate() }
        while !(await attempt.ready()) { await Task.yield() }
        #expect(model.busy && model.message == nil && model.pendingMessage != nil)
        await attempt.finish(); await retry.value
        #expect(!model.busy && model.pendingMessage == nil && model.message == nil)
        #expect(model.identities.isEmpty)
        try await vault.destroyIsolatedTestKeychain()
    }
    @Test func cancellationFeedbackIsSharedAndSafe() async throws {
        let vault = try testVault()
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: MemoryDirectory(), participants: [])
        let model = AccountsModel(lifecycle: lifecycle, authentication: { _ in throw CancellationError() })
        await model.authenticate()
        #expect(model.message == "Authorization cancelled.")
        #expect(!model.busy && model.pendingMessage == nil)
        try await vault.destroyIsolatedTestKeychain()
    }
}
