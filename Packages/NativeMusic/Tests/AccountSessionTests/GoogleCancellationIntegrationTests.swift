// Regression adapted from the independent U1 repro; synthetic localhost only.
import Foundation
import Testing
import Domain
import Features
@testable import AccountSession

private actor FDirectory: AccountDirectoryStore {
    var value = AccountDirectory()
    func load() -> AccountDirectory { value }
    func save(_ value: AccountDirectory) { self.value = value }
}
private actor FVault: SessionVault {
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) async throws { throw DomainError.unsupported }
    var inserts = 0
    func bind(_ context: RequestContext) {}
    func insert(_ bytes: Data, for account: AccountContext) throws -> CredentialReference { inserts += 1; return try CredentialReference(UUID().uuidString) }
    func read(_ reference: CredentialReference, context: RequestContext) -> Data { Data() }
    func delete(_ reference: CredentialReference, for account: AccountContext) {}
    func deleteAll(for account: AccountContext) {}
    func count() -> Int { inserts }
}
private actor FStore: GoogleGrantStorage {
    var live: UUID?; var grant: GoogleGrant?
    func begin(_ binding: GoogleGrantBinding) -> UUID { let id = UUID(); live = id; grant = nil; return id }
    func publish(_ grant: GoogleGrant, permit: UUID) throws { guard live == permit else { throw DesktopOAuthError.stale }; self.grant = grant }
    func read(permit: UUID) throws -> GoogleGrant { guard live == permit, let grant else { throw DesktopOAuthError.stale }; return grant }
    func clear() { live = nil; grant = nil }
    func hasStoredGrant() -> Bool { grant != nil }
    func removeStoredGrant() -> GoogleGrant? { let g = grant; clear(); return g }
    func discard(permit: UUID) { if live == permit { clear() } }
    func stored() -> Bool { grant != nil }
}
private struct FVerifier: GoogleIDTokenVerifier {
    func verify(_ token: String, audience: String, nonce: String) throws -> ValidatedGoogleProfile {
        guard token == "synthetic-id-token" else { throw DesktopOAuthError.invalidGrant }
        return try ValidatedGoogleProfile(subject: "synthetic-subject")
    }
}
/// Synthetic "user completed consent": GETs the loopback callback with the real state.
private actor FBrowser: OAuthBrowser {
    var opened = 0; var deliver = true; var receipts: [String] = []
    func setDeliver(_ v: Bool) { deliver = v }
    func open(_ url: URL) async throws {
        opened += 1
        guard deliver else { return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func v(_ k: String) -> String { q.first { $0.name == k }!.value! }
        var cb = URLComponents(string: v("redirect_uri"))!
        cb.queryItems = [.init(name: "state", value: v("state")), .init(name: "code", value: "synthetic-code")]
        let c = URLSessionConfiguration.ephemeral; c.httpCookieStorage = nil; c.urlCredentialStorage = nil
        let s = URLSession(configuration: c); defer { s.invalidateAndCancel() }
        let (data, _) = try await s.data(from: cb.url!)
        receipts.append(String(decoding: data, as: UTF8.self))
    }
    func count() -> Int { opened }
    func lastReceipt() -> String? { receipts.last }
}
private actor FTokens: OAuthTokenTransport {
    var status = 400
    var body: Data = fjson(["error": "invalid_request", "error_description": "client_secret is missing."])
    var hold = false; var started = false; var gate: CheckedContinuation<Void, Never>?
    func respond(_ s: Int, _ b: Data) { status = s; body = b }
    func setHold(_ v: Bool) { hold = v }
    func isStarted() -> Bool { started }
    func isHeld() -> Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
    func post(_ request: URLRequest) async throws -> Data {
        if request.url!.path == "/revoke" { return Data("{}".utf8) }
        started = true
        if hold { await withCheckedContinuation { gate = $0 } }
        let data = body
        try DirectOAuthTokenTransport.validateResponse(status: status, data: data) // production classification
        return data
    }
}
private final class FClock: ConnectionClock, @unchecked Sendable {
    private let lock = NSLock(); private var t: TimeInterval = 0
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>)] = [:]
    func now() -> TimeInterval { lock.withLock { t } }
    func waiting() -> Int { lock.withLock { sleepers.count } }
    func advance(to v: TimeInterval) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            t = v; let r = sleepers.filter { $0.value.0 <= v }; for k in r.keys { sleepers.removeValue(forKey: k) }; return r.values.map(\.1) }
        for c in ready { c.resume() }
    }
    func sleep(until deadline: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let now = lock.withLock { () -> Bool in if t >= deadline { return true }; sleepers[id] = (deadline, c); return false }
                if now { c.resume() }
            }
        } onCancel: {
            let c = lock.withLock { sleepers.removeValue(forKey: id)?.1 }; c?.resume(throwing: CancellationError())
        }
    }
}
@MainActor private struct FRig {
    let coordinator: GoogleConnectionCoordinator; let lifecycle: AccountLifecycle; let model: AccountsModel
    let store: FStore; let tokens: FTokens; let browser: FBrowser; let vault: FVault; let clock: FClock
    init() async throws {
        let store = FStore(), tokens = FTokens(), browser = FBrowser(), vault = FVault(), clock = FClock()
        let coordinator = GoogleConnectionCoordinator(configuration: try .init(clientID: "owned-test.apps.googleusercontent.com"),
            storage: store, transport: tokens, verifier: FVerifier(), browser: browser, makeListener: { NativeOAuthLoopback() }, clock: clock)
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: FDirectory(), participants: [coordinator])
        await coordinator.attach(to: lifecycle)
        // Same wiring as GoogleAuthorizationSetup.makeModel with a valid configuration.
        model = AccountsModel(lifecycle: lifecycle, authentication: { c in try await coordinator.authenticate(c) },
            authenticationLabel: "Authorize Google identity", authenticationCanConnectMusic: false,
            connectionStatus: { await coordinator.connectionState() },
            refreshAuthorization: { try await coordinator.refreshGoogleAuthorization() },
            disconnectAuthorization: { try await coordinator.disconnectGoogleAuthorization() })
        await model.refresh()
        self.coordinator = coordinator; self.lifecycle = lifecycle; self.store = store; self.tokens = tokens; self.browser = browser; self.vault = vault; self.clock = clock
    }
    func settled() async -> Bool {
        let s = await lifecycle.snapshot()
        return !model.busy && model.pendingMessage == nil && !s.reconnectPending && !s.busy
    }
}
private func fjson(_ v: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: v) }
private let successBody: Data = fjson(["access_token": "synthetic-access", "token_type": "Bearer", "expires_in": 60,
    "id_token": "synthetic-id-token", "refresh_token": "synthetic-refresh", "scope": "openid profile"])

@Suite @MainActor struct GoogleCancellationIntegrationTests {
    /// User never returns from the browser: the flow deadline ends the busy state.
    @Test func noCallbackExpiresAtRealDeadline() async throws {
        let rig = try await FRig()
        await rig.browser.setDeliver(false)
        let attempt = Task { await rig.model.authenticate() }
        while true { let opened = await rig.browser.count(); if rig.clock.waiting() > 0 && opened > 0 { break }; await Task.yield() }
        #expect(rig.model.busy && rig.model.pendingMessage != nil)
        rig.clock.advance(to: 179)
        await Task.yield()
        #expect(rig.model.busy && rig.model.message == nil)
        rig.clock.advance(to: 180)
        await attempt.value
        print("F3: message=\(rig.model.message ?? "nil") status=\(rig.model.connectionStatus)")
        #expect(rig.model.message == GoogleAuthorizationFeedback.message(for: .expired))
        #expect(await rig.settled())
        #expect(!(await rig.store.stored()))
        #expect(await rig.vault.count() == 0)
        #expect(rig.model.identities.isEmpty)
        #expect(await rig.coordinator.connectionState() == .disconnected)
    }
    /// Cancel from the welcome surface while waiting for the browser.
    @Test func cancelWhileWaitingReportsCancellation() async throws {
        let rig = try await FRig()
        await rig.browser.setDeliver(false)
        let attempt = Task { await rig.model.authenticate() }
        while true { let opened = await rig.browser.count(); if rig.clock.waiting() > 0 && opened > 0 { break }; await Task.yield() }
        await rig.model.cancelAuthentication()
        await attempt.value
        print("F4: message=\(rig.model.message ?? "nil") status=\(rig.model.connectionStatus)")
        #expect(await rig.settled())
        #expect(rig.model.message == "Authorization cancelled.")
        #expect(rig.model.message != GoogleAuthorizationFeedback.message(for: .expired))
        #expect(rig.clock.now() < 180)
        #expect(rig.model.connectionStatus == GoogleConnectionState.disconnected.explanation)
        #expect(rig.model.canAuthenticate)
        #expect(!(await rig.store.stored()))
        #expect(await rig.vault.count() == 0)
        #expect(rig.model.identities.isEmpty)
    }
    /// Control: Cancel while the token exchange is in flight reports cancellation.
    @Test func cancelDuringExchangeRejectsLateGrant() async throws {
        let rig = try await FRig()
        await rig.tokens.respond(200, successBody); await rig.tokens.setHold(true)
        let attempt = Task { await rig.model.authenticate() }
        while !(await rig.tokens.isHeld()) { await Task.yield() }
        await rig.model.cancelAuthentication()
        await rig.tokens.release()
        await attempt.value
        print("F5: message=\(rig.model.message ?? "nil") status=\(rig.model.connectionStatus)")
        #expect(await rig.settled())
        #expect(rig.model.message == "Authorization cancelled.")
        let stored = await rig.store.stored(), inserts = await rig.vault.count()
        #expect(!stored && inserts == 0)
        #expect(rig.model.identities.isEmpty)
        #expect(await rig.coordinator.connectionState() == .disconnected)
        #expect(rig.model.connectionStatus == GoogleConnectionState.disconnected.explanation)
    }
}
