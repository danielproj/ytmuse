import Foundation
import Security
import Testing
import Domain
@testable import AccountSession

private actor GoogleTestDirectory: AccountDirectoryStore {
    var value = AccountDirectory()
    func load() -> AccountDirectory { value }
    func save(_ value: AccountDirectory) { self.value = value }
}
private actor GoogleTestVault: SessionVault {
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) async throws { throw DomainError.unsupported }
    var inserts = 0
    func bind(_ context: RequestContext) {}
    func insert(_ bytes: Data, for account: AccountContext) throws -> CredentialReference { inserts += 1; return try CredentialReference(UUID().uuidString) }
    func read(_ reference: CredentialReference, context: RequestContext) -> Data { Data("synthetic-music-grant".utf8) }
    func delete(_ reference: CredentialReference, for account: AccountContext) {}
    func deleteAll(for account: AccountContext) {}
    func count() -> Int { inserts }
}
private actor GoogleTestStore: GoogleGrantStorage {
    var live: UUID?
    var grant: GoogleGrant?
    var writes = 0
    func begin(_ binding: GoogleGrantBinding) -> UUID { let id = UUID(); live = id; grant = nil; return id }
    func publish(_ grant: GoogleGrant, permit: UUID) throws {
        guard live == permit else { throw DesktopOAuthError.stale }; self.grant = grant; writes += 1
    }
    func read(permit: UUID) throws -> GoogleGrant {
        guard live == permit, let grant else { throw DesktopOAuthError.stale }; return grant
    }
    func clear() { live = nil; grant = nil }
    func hasStoredGrant() -> Bool { grant != nil }
    func removeStoredGrant() -> GoogleGrant? { let old = grant; clear(); return old }
    func discard(permit: UUID) { if live == permit { clear() } }
    func isEmpty() -> Bool { grant == nil && live == nil }
    func count() -> Int { writes }
    func retainedRefresh() -> String? { grant?.refreshToken }
}
private actor GoogleTestBrowser: OAuthBrowser {
    var nonce: String?
    var opened = 0
    let deny: Bool
    init(deny: Bool = false) { self.deny = deny }
    func open(_ url: URL) async throws {
        opened += 1
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ key: String) -> String { query.first { $0.name == key }!.value! }
        nonce = value("nonce")
        var callback = URLComponents(string: value("redirect_uri"))!
        callback.queryItems = [.init(name: "state", value: value("state")), .init(name: deny ? "error" : "code", value: deny ? "access_denied" : "synthetic-code")]
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        _ = try await session.data(from: callback.url!)
    }
    func currentNonce() -> String { nonce! }
    func count() -> Int { opened }
}
private actor GoogleTestTokens: OAuthTokenTransport {
    let keys: SyntheticJWT
    let browser: GoogleTestBrowser
    var holdRefresh = false
    var holdExchange = false
    var exchangeStarted = false
    var refreshStarted = false
    var gate: CheckedContinuation<Void, Never>?
    var denyRefresh = false
    var omitRefreshReplacement = false
    var badSubject = false
    init(keys: SyntheticJWT, browser: GoogleTestBrowser) { self.keys = keys; self.browser = browser }
    func hold() { holdRefresh = true }
    func holdInitial() { holdExchange = true }
    func initialStarted() -> Bool { exchangeStarted }
    func rejectRefresh() { denyRefresh = true }
    func returnWrongSubject() { badSubject = true }
    func omitReplacement() { omitRefreshReplacement = true }
    func started() -> Bool { refreshStarted }
    func release() { gate?.resume(); gate = nil }
    func post(_ request: URLRequest) async throws -> Data {
        if request.url!.path == "/revoke" { throw DesktopOAuthError.temporarilyUnavailable }
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        let refresh = body.contains("grant_type=refresh_token")
        if !refresh {
            exchangeStarted = true
            if holdExchange { await withCheckedContinuation { gate = $0 } }
        }
        if refresh {
            refreshStarted = true
            if holdRefresh { await withCheckedContinuation { gate = $0 } }
            if denyRefresh { throw DesktopOAuthError.revoked }
        }
        let nonce = await browser.currentNonce()
        let token = try keys.token(nonce: nonce, subject: badSubject ? "another-subject" : "synthetic-subject")
        var response: [String: Any] = ["access_token": refresh ? "synthetic-refreshed-access" : "synthetic-access", "token_type": "Bearer", "expires_in": 60,
            "id_token": token, "scope": "openid https://www.googleapis.com/auth/userinfo.profile"]
        if !refresh || !omitRefreshReplacement { response["refresh_token"] = refresh ? "synthetic-refresh-replacement" : "synthetic-refresh" }
        return try JSONSerialization.data(withJSONObject: response)
    }
}
private struct SyntheticMusicBridge: MusicSessionVerifying {
    let account: Account
    let wrongSubject: Bool
    func verify(profile: ValidatedGoogleProfile, challenge: AuthenticationChallenge) throws -> VerifiedMusicSession? {
        try .init(googleSubject: wrongSubject ? "wrong" : profile.subject, account: account, credential: Data("synthetic-music-proof-only".utf8), proofReference: "synthetic-proof", expiresAt: Date().addingTimeInterval(60))
    }
}
private struct GoogleRig {
    let coordinator: GoogleConnectionCoordinator
    let lifecycle: AccountLifecycle
    let storage: GoogleTestStore
    let tokens: GoogleTestTokens
    let browser: GoogleTestBrowser
    let vault: GoogleTestVault
    let clock: TestConnectionClock
    init(deny: Bool = false, bridge: any MusicSessionVerifying = UnverifiedMusicSessionBridge()) async throws {
        let keys = try SyntheticJWT(), browser = GoogleTestBrowser(deny: deny), storage = GoogleTestStore(), vault = GoogleTestVault(), clock = TestConnectionClock()
        let tokens = GoogleTestTokens(keys: keys, browser: browser)
        let verifier = GoogleJWTVerifier(transport: SyntheticGoogleDocuments(jwks: keys.jwks), wallNow: { Date(timeIntervalSince1970: 1_000_010) })
        coordinator = GoogleConnectionCoordinator(configuration: try .init(clientID: "owned-test.apps.googleusercontent.com"), storage: storage, transport: tokens, verifier: verifier,
            browser: browser, makeListener: { NativeOAuthLoopback() }, bridge: bridge, clock: clock)
        lifecycle = try await AccountLifecycle.open(vault: vault, store: GoogleTestDirectory(), participants: [coordinator])
        await coordinator.attach(to: lifecycle)
        self.storage = storage; self.tokens = tokens; self.browser = browser; self.vault = vault; self.clock = clock
    }
    func authorize() async throws { try await coordinator.authenticate(lifecycle.beginAuthentication()) }
}
private func syntheticMusicAccount() throws -> Account {
    let id = UUID(), context = try AccountContext(accountID: id, channelID: ID<ChannelTag>("synthetic-music-channel"), region: "US")
    return try Account(id: id, serviceIdentity: ServiceID("synthetic-music-identity"), context: context, displayName: "Synthetic Music", credential: nil)
}
@Suite struct GoogleCoordinatorTests {
    @Test func realCallbackSignedIdentityAndNoMusicEnrollment() async throws {
        let rig = try await GoogleRig()
        try await rig.authorize()
        #expect(await rig.coordinator.connectionState() == .profileVerified)
        #expect(await rig.lifecycle.snapshot().directory.identities.isEmpty)
        #expect(await rig.vault.count() == 0)
        #expect(await rig.storage.count() == 1)
        #expect(await rig.browser.count() == 1)
        rig.clock.advance(to: 31)
        try await rig.coordinator.refreshGoogleAuthorization()
        #expect(await rig.storage.retainedRefresh() == "synthetic-refresh-replacement")
        #expect(await rig.storage.count() == 2)
        try await rig.coordinator.disconnectGoogleAuthorization()
        #expect(await rig.storage.isEmpty())
        #expect(await rig.coordinator.connectionState() == .disconnected)
    }
    @Test func refreshKeepsExistingRefreshWhenReplacementOmitted() async throws {
        let rig = try await GoogleRig()
        try await rig.authorize(); rig.clock.advance(to: 31)
        await rig.tokens.omitReplacement()
        try await rig.coordinator.refreshGoogleAuthorization()
        #expect(await rig.storage.retainedRefresh() == "synthetic-refresh")
        try await rig.coordinator.disconnectGoogleAuthorization()
    }
    @Test func lateRefreshAfterRemovalCannotRepublish() async throws {
        let rig = try await GoogleRig()
        try await rig.authorize(); rig.clock.advance(to: 31)
        await rig.tokens.hold()
        let pending = Task { try await rig.coordinator.refreshGoogleAuthorization() }
        while !(await rig.tokens.started()) { await Task.yield() }
        try await rig.coordinator.disconnectGoogleAuthorization()
        await rig.tokens.release()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await rig.storage.isEmpty())
        #expect(await rig.storage.count() == 1)
        #expect(await rig.vault.count() == 0)
    }
    @Test func lifecycleSignOutFencesInFlightExchangeAndNewChallenge() async throws {
        let rig = try await GoogleRig(), account = try syntheticMusicAccount()
        let localChallenge = try await rig.lifecycle.beginAuthentication()
        try await rig.lifecycle.completeAuthentication(localChallenge, account: account, secret: Data("synthetic-music".utf8))
        await rig.tokens.holdInitial()
        let challenge = try await rig.lifecycle.beginAuthentication(for: account.context)
        let pending = Task { try await rig.coordinator.authenticate(challenge) }
        while !(await rig.tokens.initialStarted()) { await Task.yield() }
        try await rig.lifecycle.signOut(account.context)
        let replacement = try await rig.lifecycle.beginAuthentication(for: account.context)
        await rig.tokens.release()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await rig.lifecycle.isAuthenticationCurrent(replacement))
        #expect(await rig.storage.isEmpty())
        #expect(await rig.vault.count() == 1)
        #expect(await rig.lifecycle.snapshot().directory.identities.first?.state == .signedOut)
    }
    @Test func explicitTaskCancellationFencesExchange() async throws {
        let rig = try await GoogleRig()
        await rig.tokens.holdInitial()
        let challenge = try await rig.lifecycle.beginAuthentication()
        let pending = Task { try await rig.coordinator.authenticate(challenge) }
        while !(await rig.tokens.initialStarted()) { await Task.yield() }
        pending.cancel()
        await rig.tokens.release()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await rig.storage.isEmpty())
        #expect(await rig.vault.count() == 0)
        #expect(await rig.lifecycle.snapshot().reconnectPending == false)
    }
    @Test func refreshRevocationAndSubjectMismatch() async throws {
        let rig = try await GoogleRig()
        try await rig.authorize(); rig.clock.advance(to: 31)
        await rig.tokens.rejectRefresh()
        await #expect(throws: DesktopOAuthError.revoked) { try await rig.coordinator.refreshGoogleAuthorization() }
        #expect(await rig.storage.isEmpty())
        let other = try await GoogleRig()
        try await other.authorize(); other.clock.advance(to: 31)
        await other.tokens.returnWrongSubject()
        await #expect(throws: (any Error).self) { try await other.coordinator.refreshGoogleAuthorization() }
        #expect(await other.storage.count() == 1)
        try await other.coordinator.disconnectGoogleAuthorization()
    }
    @Test func denialAndStaleChallengeDoNotRetain() async throws {
        let rig = try await GoogleRig(deny: true)
        await #expect(throws: DesktopOAuthError.denied) { try await rig.authorize() }
        #expect(await rig.storage.isEmpty()); #expect(await rig.vault.count() == 0)
        let stale = try await rig.lifecycle.beginAuthentication()
        await rig.lifecycle.cancelAuthentication(stale)
        let newer = try await rig.lifecycle.beginAuthentication()
        await #expect(throws: DesktopOAuthError.stale) { try await rig.coordinator.authenticate(stale) }
        #expect(await rig.lifecycle.isAuthenticationCurrent(newer))
        #expect(await rig.browser.count() == 1)
    }
    @Test func onlyExplicitMusicProofInstallsAndLifecycleSignOutClearsGoogle() async throws {
        let account = try syntheticMusicAccount()
        let rig = try await GoogleRig(bridge: SyntheticMusicBridge(account: account, wrongSubject: false))
        try await rig.authorize()
        #expect(await rig.vault.count() == 1)
        #expect(await rig.lifecycle.snapshot().directory.identities.count == 1)
        try await rig.lifecycle.signOut(account.context)
        #expect(await rig.storage.isEmpty())
        #expect(await rig.coordinator.connectionState() == .disconnected)
        let rejected = try await GoogleRig(bridge: SyntheticMusicBridge(account: account, wrongSubject: true))
        await #expect(throws: DesktopOAuthError.invalidGrant) { try await rejected.authorize() }
        #expect(await rejected.vault.count() == 0)
    }
    @Test func realScopedKeychainPermitFencesLatePublication() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("e01-google-" + UUID().uuidString + ".keychain-db")
        let store = try GoogleKeychainGrantStore(testNamespace: KeychainVault.applicationNamespace + ".test." + UUID().uuidString, isolatedKeychainURL: path)
        do {
        let permit = try await store.begin(.init(generation: 7, target: nil))
        let grant = GoogleGrant(clientID: "synthetic-client", subject: "synthetic-subject", nonce: "synthetic-nonce", accessToken: "synthetic-access", refreshToken: "synthetic-refresh", scopes: ["openid"], expiresIn: 60)
        #expect(try await store.hasStoredGrant() == false)
        try await store.publish(grant, permit: permit)
        #expect(try await store.hasStoredGrant())
        #expect(try await store.read(permit: permit).subject == grant.subject)
        try await store.clear()
        await #expect(throws: DesktopOAuthError.stale) { try await store.publish(grant, permit: permit) }
        await #expect(throws: DesktopOAuthError.stale) { try await store.read(permit: permit) }
        let next = try await store.begin(.init(generation: 8, target: nil))
        await #expect(throws: DesktopOAuthError.stale) { try await store.publish(grant, permit: permit) }
        try await store.publish(grant, permit: next)
        #expect(try await store.removeStoredGrant()?.subject == grant.subject)
        #expect(try await store.hasStoredGrant() == false)
        } catch { try await store.destroyIsolatedTestKeychain(); throw error }
        try await store.destroyIsolatedTestKeychain()
    }
    @Test func developerConfigAndTokenErrorCategories() throws {
        #expect(try DesktopOAuthConfiguration.fromApplicationInfo([:]) == nil)
        #expect(try DesktopOAuthConfiguration.fromApplicationInfo(["YTMuseGoogleDesktopClientID": "$(YTMUSE_GOOGLE_DESKTOP_CLIENT_ID)"]) == nil)
        #expect(throws: DesktopOAuthError.invalidConfiguration) { try DesktopOAuthConfiguration.fromApplicationInfo(["YTMuseGoogleDesktopClientID": "invalid"]) }
        #expect(try DesktopOAuthConfiguration.fromApplicationInfo(["YTMuseGoogleDesktopClientID": "owned-test.apps.googleusercontent.com"])?.scopes == ["openid", "profile"])
        #expect(throws: DesktopOAuthError.revoked) { try DirectOAuthTokenTransport.validateResponse(status: 400, data: Data("{\"error\":\"invalid_grant\"}".utf8)) }
        #expect(DesktopOAuthTokenExchange.expiry(true) == nil)
        #expect(DesktopOAuthTokenExchange.expiry(1.5) == nil)
        #expect(DesktopOAuthTokenExchange.expiry(3600) == 3600)
        #expect(throws: DesktopOAuthError.temporarilyUnavailable) { try DirectOAuthTokenTransport.validateResponse(status: 503, data: Data()) }
    }
}
