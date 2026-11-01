import Foundation
import CryptoKit
import Security

public enum DesktopOAuthError: Error, Equatable { case invalidClient, invalidRequest, missingClientSecret, networkFailure, rateLimited, revoked, temporarilyUnavailable, configurationMissing, invalidConfiguration, busy, invalidCallback, expired, stale, denied, invalidGrant, randomFailure }
/// Only Google's documented identity aliases are equivalent. API scopes remain
/// exact strings; openid never aliases to a profile/email or API grant.
public enum GoogleIdentityScopes {
    public static func normalized(_ scopes: Set<String>) -> Set<String> {
        Set(scopes.map {
            switch $0 {
            case "https://www.googleapis.com/auth/userinfo.profile": "profile"
            case "https://www.googleapis.com/auth/userinfo.email": "email"
            default: $0
            }
        })
    }
}
public struct DesktopOAuthConfiguration: Sendable {
    public let clientID: String
    public let scopes: Set<String>
    public static func fromApplicationInfo(_ info: [String: Any]) throws -> Self? {
        guard let raw = info["YTMuseGoogleDesktopClientID"] else { return nil }
        guard let value = raw as? String else { throw DesktopOAuthError.invalidConfiguration }
        if value.isEmpty || value == "$(YTMUSE_GOOGLE_DESKTOP_CLIENT_ID)" { return nil }
        return try Self(clientID: value)
    }
    public init(clientID: String, scopes: Set<String> = ["openid", "profile"]) throws {
        let prefix = clientID.hasSuffix(".apps.googleusercontent.com") ? String(clientID.dropLast(".apps.googleusercontent.com".count)) : ""
        guard !prefix.isEmpty, prefix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }), clientID.hasSuffix(".apps.googleusercontent.com"), clientID.utf8.count <= 512,
              !clientID.contains(where: { $0.isWhitespace }), !scopes.isEmpty,
              GoogleIdentityScopes.normalized(scopes).isSubset(of: ["openid", "profile", "https://www.googleapis.com/auth/youtube.readonly"]), scopes.contains("openid") else { throw DesktopOAuthError.invalidConfiguration }
        self.clientID = clientID; self.scopes = scopes
    }
}
/// A host supplies a listener bound exclusively to 127.0.0.1 on an ephemeral port.
/// This lane neither opens a browser nor starts a listener automatically.
public protocol OAuthLoopbackListener: Sendable {
    func bind() async throws -> URL
    func close() async
}
public protocol OAuthBrowser: Sendable { func open(_ authorizationURL: URL) async throws }
public struct OAuthCodeExchange: Sendable, RedactedGoogleValue {
    public let clientID: String
    public let redirect: URL
    public let code: String
    public let verifier: String
    public init(clientID: String, redirect: URL, code: String, verifier: String) {
        self.clientID = clientID; self.redirect = redirect; self.code = code; self.verifier = verifier
    }
}
/// Implementations keep token material in protected memory, validate granted scopes,
/// and validate OIDC signature/JWKS, issuer, audience, expiry and nonce. No default
/// implementation accepts an unverified JWT. No value here establishes Music login.
public protocol OAuthProfileExchange: Sendable {
    func exchange(_ request: OAuthCodeExchange, expectedNonce: String, scopes: Set<String>) async throws -> ValidatedGoogleProfile
}
public struct ValidatedGoogleProfile: Sendable, Equatable {
    public let subject: String
    public init(subject: String) throws {
        guard !subject.isEmpty, subject.utf8.count <= 255 else { throw DesktopOAuthError.invalidGrant }
        self.subject = subject
    }
}
public struct OAuthCallback: Sendable, RedactedGoogleValue {
    public let method: String
    public let url: URL
    public let host: String
    public init(method: String, url: URL, host: String) { self.method = method; self.url = url; self.host = host }
}
/// Independent Google profile candidate; deliberately has no AccountLifecycle
/// credential-installation path. Only a future verified Music bridge may publish it.
public actor DesktopOAuthFlow {
    private struct Attempt {
        let id: UUID; let generation: UInt64; let state: String; let nonce: String
        let verifier: String; let redirect: URL; let expires: TimeInterval
    }
    private let configuration: DesktopOAuthConfiguration?
    private let listener: any OAuthLoopbackListener
    private let browser: any OAuthBrowser
    private let exchange: any OAuthProfileExchange
    private var attempt: Attempt?
    private var reservation: UUID?
    private var closing = 0
    private var bindingID: UUID?
    private let clock: any ConnectionClock
    private var expires: TimeInterval?
    private var deadlineTask: Task<Void, Never>?
    public init(configuration: DesktopOAuthConfiguration?, listener: any OAuthLoopbackListener,
                browser: any OAuthBrowser, exchange: any OAuthProfileExchange, clock: any ConnectionClock = SystemConnectionClock()) {
        self.clock = clock; self.configuration = configuration; self.listener = listener; self.browser = browser; self.exchange = exchange
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DesktopOAuthError.randomFailure }
        return base64(Data(bytes))
    }
    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public func start(generation: UInt64) async throws {
        if let expires, clock.now() >= expires { await cancel() }
        guard let configuration else { throw DesktopOAuthError.configurationMissing }
        guard reservation == nil, closing == 0, bindingID == nil else { throw DesktopOAuthError.busy }
        let id = UUID(); reservation = id; bindingID = id
        let deadline = clock.now() + 180; expires = deadline
        deadlineTask = Task { [weak self, clock] in
            do { try await clock.sleep(until: deadline); await self?.expire(id) } catch { }
        }
        var bound = false
        do {
            let redirect = try await listener.bind()
            bound = true
            guard reservation == id else { throw DesktopOAuthError.stale }
            guard clock.now() < deadline else { throw DesktopOAuthError.expired }
            guard redirect.scheme == "http", redirect.host == "127.0.0.1", let port = redirect.port, (1024...65535).contains(port),
                  redirect.path == "/oauth2callback", redirect.query == nil, redirect.fragment == nil,
                  redirect.user == nil, redirect.password == nil else { throw DesktopOAuthError.invalidConfiguration }
            let state = try Self.random(), nonce = try Self.random(), verifier = try Self.random()
            attempt = Attempt(id: id, generation: generation, state: state, nonce: nonce, verifier: verifier, redirect: redirect, expires: deadline)
            var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            url.queryItems = ["client_id": configuration.clientID, "redirect_uri": redirect.absoluteString, "response_type": "code",
                              "scope": configuration.scopes.sorted().joined(separator: " "), "state": state, "nonce": nonce, "access_type": "offline",
                              "code_challenge": Self.base64(Data(SHA256.hash(data: Data(verifier.utf8)))), "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
            try Task.checkCancellation()
            try await browser.open(url.url!)
            guard reservation == id else { throw DesktopOAuthError.stale }
            bindingID = nil
        } catch {
            // Keep the binding barrier until a late bind is closed. A newer start
            // cannot acquire this shared listener while cleanup is suspended.
            if reservation == id {
                reservation = nil; attempt = nil; expires = nil
                deadlineTask?.cancel(); deadlineTask = nil
            }
            if bound {
                closing += 1
                await listener.close()
                closing -= 1
            }
            if bindingID == id { bindingID = nil }
            throw error
        }
    }
    private func expire(_ id: UUID) async {
        guard reservation == id, let expires, clock.now() >= expires else { return }
        await cancel()
    }
    public func cancel() async {
        attempt = nil; reservation = nil; expires = nil
        deadlineTask?.cancel(); deadlineTask = nil
        // Invalidate immediately, and block new attempts through asynchronous close.
        closing += 1
        await listener.close()
        closing -= 1
    }
    public func receive(_ callback: OAuthCallback, generation: UInt64) async throws -> ValidatedGoogleProfile {
        guard let a = attempt, let configuration else { throw DesktopOAuthError.invalidCallback }
        guard clock.now() < a.expires else { await cancel(); throw DesktopOAuthError.expired }
        guard generation == a.generation else { await cancel(); throw DesktopOAuthError.stale }
        guard callback.method == "GET", callback.url.scheme == "http", callback.url.host == "127.0.0.1",
              callback.url.port == a.redirect.port, callback.host == "127.0.0.1:\(a.redirect.port!)",
              callback.url.path == a.redirect.path, callback.url.fragment == nil,
              callback.url.user == nil, callback.url.password == nil,
              let parts = URLComponents(url: callback.url, resolvingAgainstBaseURL: false),
              let params = parts.queryItems, params.count <= 8,
              Set(params.map(\.name)).count == params.count,
              params.allSatisfy({ ($0.value?.utf8.count ?? 0) <= 8192 }),
              params.first(where: { $0.name == "state" })?.value == a.state else { throw DesktopOAuthError.invalidCallback }
        attempt = nil // consume before any suspension or exchange
        closing += 1
        await listener.close()
        closing -= 1
        do {
            guard reservation == a.id else { throw DesktopOAuthError.stale }
            guard params.first(where: { $0.name == "error" }) == nil else { throw DesktopOAuthError.denied }
            guard let code = params.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw DesktopOAuthError.invalidCallback }
            let profile = try await exchange.exchange(.init(clientID: configuration.clientID, redirect: a.redirect, code: code, verifier: a.verifier), expectedNonce: a.nonce, scopes: configuration.scopes)
            try Task.checkCancellation()
            guard reservation == a.id else { throw DesktopOAuthError.stale }
            guard clock.now() < a.expires else { throw DesktopOAuthError.expired }
            reservation = nil; expires = nil; deadlineTask?.cancel(); deadlineTask = nil; return profile
        } catch { if reservation == a.id { reservation = nil; expires = nil; deadlineTask?.cancel(); deadlineTask = nil }; throw error }
    }
}
