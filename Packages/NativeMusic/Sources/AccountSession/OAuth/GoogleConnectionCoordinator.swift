import Foundation
import Domain

public enum GoogleConnectionState: Sendable, Equatable {
    case configurationInvalidStored, configurationMissingStored, configurationInvalid, configurationMissing, storedAuthorization, disconnected, authorizing, profileVerified, musicConnected, cleanupRequired
    public var explanation: String {
        switch self {
        case .configurationInvalidStored: "Google authorization is disabled because this build’s client configuration is invalid. A Google authorization is stored locally and can be disconnected. Music access is not verified."
        case .configurationMissingStored: "Google authorization awaits this app’s Desktop registration. A Google authorization is stored locally and can be disconnected. Music access is not verified."
        case .configurationInvalid: "Google authorization is disabled because this build’s client configuration is invalid. Local accounts remain available."
        case .configurationMissing: "Google sign-in awaits this app’s Desktop registration. No Music account connected."
        case .storedAuthorization: "A Google authorization is stored locally. Reauthorize for this app session, or disconnect it. Music access is not verified."
        case .disconnected: "Google sign-in is available. Music session access has not been verified."
        case .authorizing: "Waiting for Google authorization…"
        case .profileVerified: "Google identity verified. Music session and playback access are not verified."
        case .musicConnected: "Music session verified. Playback eligibility requires separate source evidence."
        case .cleanupRequired: "Local Google credential cleanup needs retry. Music access is locked."
        }
    }
}
/// A trusted source implementation must supply actual Music identity, credential,
/// provenance and expiry. Profile/channel display metadata is not a session proof.
public struct VerifiedMusicSession: Sendable {
    public let googleSubject: String
    public let account: Account
    public let credential: Data
    public let proofReference: String
    public let expiresAt: Date
    public init(googleSubject: String, account: Account, credential: Data, proofReference: String, expiresAt: Date) throws {
        guard !googleSubject.isEmpty, !credential.isEmpty, credential.count <= 131_072,
              !proofReference.isEmpty, proofReference.utf8.count <= 512 else { throw DesktopOAuthError.invalidGrant }
        self.googleSubject = googleSubject; self.account = account; self.credential = credential
        self.proofReference = proofReference; self.expiresAt = expiresAt
    }
}
public protocol MusicSessionVerifying: Sendable {
    func verify(profile: ValidatedGoogleProfile, challenge: AuthenticationChallenge) async throws -> VerifiedMusicSession?
}
public struct UnverifiedMusicSessionBridge: MusicSessionVerifying {
    public init() {}
    public func verify(profile: ValidatedGoogleProfile, challenge: AuthenticationChallenge) async throws -> VerifiedMusicSession? { nil }
}

/// Owns one Google candidate independently of the Music directory. Registered as
/// a lifecycle participant so account switches/sign-out/removal fence its work.
public actor GoogleConnectionCoordinator: AccountLifecycleParticipant {
    public nonisolated let participantID = "google-authorization"
    private let configuration: DesktopOAuthConfiguration?
    private let storage: any GoogleGrantStorage
    private let transport: any OAuthTokenTransport
    private let verifier: any GoogleIDTokenVerifier
    private let secretSource: (any GoogleClientSecretSource)?
    private let browser: any OAuthBrowser
    private let makeListener: @Sendable () -> any OAuthCallbackListener
    private let bridge: any MusicSessionVerifying
    private let clock: any ConnectionClock
    private weak var lifecycle: AccountLifecycle?
    private var epoch = UUID()
    private var busy = false
    private var cleaning = 0
    private var flow: DesktopOAuthFlow?
    private var permit: UUID?
    private var binding: GoogleGrantBinding?
    private var accessDeadline: TimeInterval = 0
    private var pendingRevocation: Task<Void, Never>?
    private var state: GoogleConnectionState
    public init(configuration: DesktopOAuthConfiguration?, bridge: any MusicSessionVerifying = UnverifiedMusicSessionBridge()) throws {
        self.configuration = configuration; self.bridge = bridge
        storage = try GoogleKeychainGrantStore(); transport = DirectOAuthTokenTransport()
        verifier = GoogleJWTVerifier(); secretSource = AppOwnedGoogleClientSecret(); browser = NativeOAuthBrowser()
        makeListener = { NativeOAuthLoopback() }; clock = SystemConnectionClock()
        state = configuration == nil ? .configurationMissing : .disconnected
    }
    init(configuration: DesktopOAuthConfiguration?, storage: any GoogleGrantStorage, transport: any OAuthTokenTransport,
         verifier: any GoogleIDTokenVerifier, browser: any OAuthBrowser, makeListener: @escaping @Sendable () -> any OAuthCallbackListener,
         bridge: any MusicSessionVerifying = UnverifiedMusicSessionBridge(), clock: any ConnectionClock = SystemConnectionClock()) {
        self.configuration = configuration; self.storage = storage; self.transport = transport; self.verifier = verifier
        self.browser = browser; self.makeListener = makeListener; self.bridge = bridge; self.clock = clock; secretSource = nil
        state = configuration == nil ? .configurationMissing : .disconnected
    }
    public func attach(to lifecycle: AccountLifecycle) { self.lifecycle = lifecycle }
    public func connectionState() -> GoogleConnectionState { state }
    public func inspectStoredAuthorization() async {
        guard !busy, cleaning == 0, permit == nil else { return }
        let operation = epoch
        do {
            let stored = try await storage.hasStoredGrant()
            guard operation == epoch else { return }
            if stored { state = .storedAuthorization }
        } catch { if operation == epoch { state = .cleanupRequired } }
    }
    private func check(_ operation: UUID) throws { try Task.checkCancellation(); guard epoch == operation, cleaning == 0 else { throw DesktopOAuthError.stale } }
    public func authenticate(_ challenge: AuthenticationChallenge) async throws {
        guard let configuration, let lifecycle else { throw DesktopOAuthError.configurationMissing }
        guard !busy, cleaning == 0 else { throw DesktopOAuthError.busy }
        busy = true
        let operation = UUID(); epoch = operation; state = .authorizing
        defer { busy = false }
        let listener = makeListener(), capture = GoogleGrantCapture()
        let exchange = DesktopOAuthTokenExchange(transport: transport, verifier: verifier, capture: capture, secretSource: secretSource, clock: clock)
        let attempt = DesktopOAuthFlow(configuration: configuration, listener: listener, browser: browser, exchange: exchange, clock: clock)
        flow = attempt
        do {
            guard await lifecycle.isAuthenticationCurrent(challenge) else { throw DesktopOAuthError.stale }
            try check(operation)
            permit = nil; binding = nil
            if let previous = try await storage.removeStoredGrant() { revoke(previous) }
            // Old revocation work finishes before a new browser grant can be
            // issued, so a late local revoke task cannot erase its replacement.
            await pendingRevocation?.value
            try check(operation)
            let scope = GoogleGrantBinding(generation: challenge.generation, target: challenge.identity)
            let lease = try await storage.begin(scope)
            do { try check(operation) }
            catch { try await storage.discard(permit: lease); throw error }
            permit = lease; binding = scope
            let profile = try await withTaskCancellationHandler {
                try await attempt.start(generation: challenge.generation)
                for await callback in listener.callbacks {
                    try check(operation)
                    guard await lifecycle.isAuthenticationCurrent(challenge) else { throw DesktopOAuthError.stale }
                    do { return try await attempt.receive(callback, generation: challenge.generation) }
                    catch DesktopOAuthError.invalidCallback { continue }
                }
                // Cancellation closes the listener too; preserve its cause before
                // classifying a drained callback stream as a genuine deadline.
                try check(operation)
                throw DesktopOAuthError.expired
            } onCancel: { Task { await attempt.cancel() } }
            try check(operation)
            guard await lifecycle.isAuthenticationCurrent(challenge), let captured = await capture.take(), captured.grant.subject == profile.subject else { throw DesktopOAuthError.stale }
            try check(operation)
            try await storage.publish(captured.grant, permit: lease)
            try check(operation); accessDeadline = captured.deadline
            let proof = try await bridge.verify(profile: profile, challenge: challenge)
            try check(operation)
            guard await lifecycle.isAuthenticationCurrent(challenge) else { throw DesktopOAuthError.stale }
            if let proof {
                guard proof.googleSubject == profile.subject, proof.expiresAt > Date(),
                      challenge.identity == nil || challenge.identity == proof.account.context else { throw DesktopOAuthError.invalidGrant }
                try await lifecycle.completeAuthentication(challenge, account: proof.account, secret: proof.credential)
                // Reconnect may detach this participant during the lifecycle's
                // serialized installation. The Music directory is authoritative;
                // never resurrect a Google grant that detachment erased.
                if epoch == operation { state = .musicConnected }
            } else {
                await lifecycle.cancelAuthentication(challenge)
                try check(operation); state = .profileVerified
            }
            await attempt.cancel(); flow = nil
        } catch {
            await attempt.cancel()
            if let abandoned = await capture.take() { revoke(abandoned.grant) }
            await lifecycle.cancelAuthentication(challenge)
            if epoch == operation {
                do { try await disconnectGoogleAuthorization() }
                catch { state = .cleanupRequired }
            }
            throw error
        }
    }
    /// Explicit demand refresh; never launches a browser. Rotation is serialized
    /// by this owner plus the store's revocable permit, including across reentry.
    public func refreshGoogleAuthorization() async throws {
        guard !busy, cleaning == 0, let lease = permit, let scope = binding, let lifecycle,
              state == .profileVerified || state == .musicConnected else { throw DesktopOAuthError.stale }
        busy = true; defer { busy = false }
        let operation = epoch
        guard await lifecycle.isGenerationCurrent(scope.generation) else { throw DesktopOAuthError.stale }
        try check(operation)
        if clock.now() + 30 < accessDeadline { return }
        let old = try await storage.read(permit: lease)
        try check(operation)
        guard let refresh = old.refreshToken else { throw DesktopOAuthError.invalidGrant }
        var values = ["grant_type": "refresh_token", "client_id": old.clientID, "refresh_token": refresh]
        if let secret = try await secretSource?.optionalSecret(clientID: old.clientID) { values["client_secret"] = secret }
        let data: Data
        do { data = try await transport.post(DesktopOAuthTokenExchange.form(endpoint: "token", values: values)) }
        catch DesktopOAuthError.revoked {
            try check(operation)
            try await disconnectGoogleAuthorization()
            throw DesktopOAuthError.revoked
        }
        let received = clock.now()
        try check(operation)
        guard data.count <= 131_072, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
              (root["token_type"] as? String)?.lowercased() == "bearer",
              let access = root["access_token"] as? String, !access.isEmpty, access.utf8.count <= 16384,
              let expiry = DesktopOAuthTokenExchange.expiry(root["expires_in"]) else { throw DesktopOAuthError.invalidGrant }
        let scopes: Set<String>
        if let returned = root["scope"] { guard let text = returned as? String else { throw DesktopOAuthError.invalidGrant }; scopes = GoogleIdentityScopes.normalized(Set(text.split(separator: " ").map(String.init))) }
        else { scopes = old.scopes }
        guard old.scopes.isSubset(of: scopes) else { throw DesktopOAuthError.invalidGrant }
        if let token = root["id_token"] {
            guard let token = token as? String else { throw DesktopOAuthError.invalidGrant }
            let profile = try await verifier.verifyRefreshed(token, audience: old.clientID, subject: old.subject, originalNonce: old.nonce)
            guard profile.subject == old.subject else { throw DesktopOAuthError.invalidGrant }
        }
        let replacement: String?
        if let returned = root["refresh_token"] {
            guard let value = returned as? String, !value.isEmpty, value.utf8.count <= 16384 else { throw DesktopOAuthError.invalidGrant }
            replacement = value
        } else { replacement = old.refreshToken }
        guard await lifecycle.isGenerationCurrent(scope.generation) else { throw DesktopOAuthError.stale }
        try check(operation)
        try await storage.publish(.init(clientID: old.clientID, subject: old.subject, nonce: old.nonce, accessToken: access,
            refreshToken: replacement, scopes: scopes, expiresIn: expiry), permit: lease)
        try check(operation); accessDeadline = received + Double(expiry)
    }
    /// Local removal precedes best-effort remote revoke and works offline. No
    /// suspended refresh can publish through the invalidated store permit.
    public func disconnectGoogleAuthorization() async throws {
        cleaning += 1; defer { cleaning -= 1 }
        epoch = UUID()
        let oldFlow = flow
        permit = nil; binding = nil; flow = nil; accessDeadline = 0
        state = configuration == nil ? .configurationMissing : .disconnected
        let grant: GoogleGrant?
        do { grant = try await storage.removeStoredGrant() }
        catch { state = .cleanupRequired; await oldFlow?.cancel(); throw error }
        await oldFlow?.cancel()
        if let grant { revoke(grant) }
    }
    private func revoke(_ grant: GoogleGrant) {
        let token = grant.refreshToken ?? grant.accessToken
        // Bounded transport; failure never undoes local deletion.
        let previous = pendingRevocation
        pendingRevocation = Task { [transport] in
            await previous?.value
            _ = try? await transport.post(DesktopOAuthTokenExchange.revokeRequest(token: token))
        }
    }
    public func detach(previous: RequestContext, barrier: RequestContext) async throws { try await disconnectGoogleAuthorization() }
    public func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws { }
    public func removeLocal(_ account: AccountContext, context: RequestContext) async throws { try await disconnectGoogleAuthorization() }
}
