import Foundation

public protocol OAuthTokenTransport: Sendable {
    func post(_ request: URLRequest) async throws -> Data
}
private final class OAuthNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
public actor DirectOAuthTokenTransport: OAuthTokenTransport {
    private let session: URLSession
    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCredentialStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 30
        session = URLSession(configuration: c, delegate: OAuthNoRedirect(), delegateQueue: nil)
    }
    public func post(_ request: URLRequest) async throws -> Data {
        do { return try await perform(request) }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw DesktopOAuthError.networkFailure
        }
    }
    private func perform(_ request: URLRequest) async throws -> Data {
        guard let url = request.url, url.scheme == "https", url.host == "oauth2.googleapis.com", url.port == nil,
              ["/token", "/revoke"].contains(url.path), url.query == nil, url.user == nil, url.password == nil, url.fragment == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }).isSubset(of: ["content-type", "accept"]),
              request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded",
              request.httpMethod == "POST", (request.httpBody?.count ?? 0) <= 32_768 else { throw DesktopOAuthError.invalidConfiguration }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...599).contains(http.statusCode),
              http.expectedContentLength <= 131_072 else { throw DesktopOAuthError.invalidGrant }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 131_072 else { throw DesktopOAuthError.invalidGrant }; data.append(byte)
        }
        try Self.validateResponse(status: http.statusCode, data: data)
        return data
    }
    static func validateResponse(status: Int, data: Data) throws {
        guard data.count <= 131_072 else { throw DesktopOAuthError.invalidGrant }
        if status == 200 { return }
        if status == 429 { throw DesktopOAuthError.rateLimited }
        if status >= 500 { throw DesktopOAuthError.temporarilyUnavailable }
        if [400, 401].contains(status), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch root["error"] as? String {
            case "invalid_client", "unauthorized_client": throw DesktopOAuthError.invalidClient
            case "invalid_request":
                if root["error_description"] as? String == "client_secret is missing." { throw DesktopOAuthError.missingClientSecret }
                throw DesktopOAuthError.invalidRequest
            case "invalid_grant", "invalid_token": throw DesktopOAuthError.revoked
            default: break
            }
        }
        throw DesktopOAuthError.invalidGrant
    }
}
/// A production verifier must perform cryptographic JWT validation. This boundary
/// intentionally has no permissive implementation or unsigned decode fallback.
public protocol GoogleIDTokenVerifier: Sendable {
    func verify(_ token: String, audience: String, nonce: String) async throws -> ValidatedGoogleProfile
    func verifyRefreshed(_ token: String, audience: String, subject: String, originalNonce: String) async throws -> ValidatedGoogleProfile
}
public extension GoogleIDTokenVerifier {
    func verifyRefreshed(_ token: String, audience: String, subject: String, originalNonce: String) async throws -> ValidatedGoogleProfile {
        let profile = try await verify(token, audience: audience, nonce: originalNonce)
        guard profile.subject == subject else { throw DesktopOAuthError.invalidGrant }
        return profile
    }
}
public struct DesktopOAuthTokenExchange: OAuthProfileExchange {
    private let transport: any OAuthTokenTransport
    private let verifier: any GoogleIDTokenVerifier
    private var capture: GoogleGrantCapture?
    private let clock: any ConnectionClock
    private let secretSource: (any GoogleClientSecretSource)?
    // No AccountLifecycle dependency; this consumer cannot assert a Music grant.
    public init(transport: any OAuthTokenTransport = DirectOAuthTokenTransport(), verifier: any GoogleIDTokenVerifier, secretSource: (any GoogleClientSecretSource)? = nil) {
        self.transport = transport; self.verifier = verifier; self.secretSource = secretSource; clock = SystemConnectionClock()
    }
    init(transport: any OAuthTokenTransport, verifier: any GoogleIDTokenVerifier, capture: GoogleGrantCapture, secretSource: (any GoogleClientSecretSource)?, clock: any ConnectionClock) {
        self.transport = transport; self.verifier = verifier; self.capture = capture; self.secretSource = secretSource; self.clock = clock
    }
    public static func form(endpoint: String, values: [String: String]) throws -> URLRequest {
        guard ["token", "revoke"].contains(endpoint) else { throw DesktopOAuthError.invalidConfiguration }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/\(endpoint)")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(values.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        return request
    }
    public func exchange(_ request: OAuthCodeExchange, expectedNonce: String, scopes: Set<String>) async throws -> ValidatedGoogleProfile {
        guard scopes.contains("openid"), !expectedNonce.isEmpty else { throw DesktopOAuthError.invalidGrant }
        var values = ["grant_type": "authorization_code", "client_id": request.clientID,
               "redirect_uri": request.redirect.absoluteString, "code": request.code, "code_verifier": request.verifier]
        if let secret = try await secretSource?.optionalSecret(clientID: request.clientID) { values["client_secret"] = secret }
        let http = try Self.form(endpoint: "token", values: values)
        let data = try await transport.post(http)
        let received = clock.now()
        guard data.count <= 131_072, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
              let tokenType = root["token_type"] as? String, tokenType.lowercased() == "bearer",
              let access = root["access_token"] as? String, !access.isEmpty, access.utf8.count <= 16384,
              let expiry = Self.expiry(root["expires_in"]),
              let granted = root["scope"] as? String, GoogleIdentityScopes.normalized(scopes).isSubset(of: GoogleIdentityScopes.normalized(Set(granted.split(separator: " ").map(String.init)))),
              let id = root["id_token"] as? String, !id.isEmpty else { throw DesktopOAuthError.invalidGrant }
        try Task.checkCancellation()
        let profile = try await verifier.verify(id, audience: request.clientID, nonce: expectedNonce)
        try Task.checkCancellation()
        if let refresh = root["refresh_token"] { guard let value = refresh as? String, !value.isEmpty, value.utf8.count <= 16384 else { throw DesktopOAuthError.invalidGrant } }
        await capture?.set(.init(clientID: request.clientID, subject: profile.subject, nonce: expectedNonce,
            accessToken: access, refreshToken: root["refresh_token"] as? String,
            scopes: GoogleIdentityScopes.normalized(Set(granted.split(separator: " ").map(String.init))), expiresIn: expiry), deadline: received + Double(expiry))
        // Pending tokens stay protected in memory until the flow checks deadline/generation.
        return profile
    }
    static func expiry(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              (1...86_400).contains(number.doubleValue) else { return nil }
        return number.intValue
    }
    public static func refreshRequest(clientID: String, refreshToken: String) throws -> URLRequest {
        try form(endpoint: "token", values: ["grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken])
    }
    public static func revokeRequest(token: String) throws -> URLRequest { try form(endpoint: "revoke", values: ["token": token]) }
}
