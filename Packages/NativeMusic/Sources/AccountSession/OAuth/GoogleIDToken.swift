import Foundation
import Security

public struct GooglePublicDocument: Sendable {
    public let data: Data
    public let lifetime: TimeInterval
    public init(data: Data, lifetime: TimeInterval) { self.data = data; self.lifetime = lifetime }
}
public protocol GooglePublicDocumentTransport: Sendable {
    func get(_ url: URL) async throws -> GooglePublicDocument
}
private final class GoogleNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
public actor DirectGooglePublicDocuments: GooglePublicDocumentTransport {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config, delegate: GoogleNoRedirect(), delegateQueue: nil)
    }
    public func get(_ url: URL) async throws -> GooglePublicDocument {
        guard [GoogleJWTVerifier.discoveryURL, GoogleJWTVerifier.keysURL].contains(url) else { throw DesktopOAuthError.invalidConfiguration }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= 131_072 else { throw DesktopOAuthError.invalidGrant }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 131_072 else { throw DesktopOAuthError.invalidGrant }
            data.append(byte)
        }
        let directives = (http.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let maxAge = directives.first { $0.hasPrefix("max-age=") }.flatMap { Double($0.dropFirst(8)) } ?? 0
        let age = max(0, Double(http.value(forHTTPHeaderField: "Age") ?? "0") ?? 0)
        let lifetime = directives.contains("no-store") || directives.contains("no-cache") ? 0 : max(0, min(21_600, maxAge - age))
        return .init(data: data, lifetime: lifetime)
    }
}

/// RS256 only. Keys come only from Google's pinned discovery/JWKS endpoints;
/// header-supplied jku/x5u/jwk and algorithm negotiation are never trusted.
public actor GoogleJWTVerifier: GoogleIDTokenVerifier {
    public static let discoveryURL = URL(string: "https://accounts.google.com/.well-known/openid-configuration")!
    public static let keysURL = URL(string: "https://www.googleapis.com/oauth2/v3/certs")!
    private let transport: any GooglePublicDocumentTransport
    private let clock: any ConnectionClock
    private let wallNow: @Sendable () -> Date
    private var keys: [String: Data] = [:]
    private var validUntil: TimeInterval = -.infinity
    private var lastFetch: TimeInterval = -.infinity
    public init(transport: any GooglePublicDocumentTransport = DirectGooglePublicDocuments(), clock: any ConnectionClock = SystemConnectionClock(), wallNow: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.clock = clock; self.wallNow = wallNow
    }
    static func decode(_ value: String) throws -> Data {
        guard !value.isEmpty, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), value.count % 4 != 1 else { throw DesktopOAuthError.invalidGrant }
        let text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4)) else { throw DesktopOAuthError.invalidGrant }
        return data
    }
    private func loadKeys() async throws {
        // Bound unknown-kid requests and concurrent reentry. A transient failure is
        // an error, never a reason to use expired keys or accept an unsigned token.
        guard clock.now() - lastFetch >= 30 else { throw DesktopOAuthError.invalidGrant }
        lastFetch = clock.now()
        let discovery = try await transport.get(Self.discoveryURL)
        guard discovery.data.count <= 131_072, let document = try JSONSerialization.jsonObject(with: discovery.data) as? [String: Any],
              document["issuer"] as? String == "https://accounts.google.com",
              document["jwks_uri"] as? String == Self.keysURL.absoluteString,
              (document["id_token_signing_alg_values_supported"] as? [String])?.contains("RS256") == true else { throw DesktopOAuthError.invalidGrant }
        let receipt = try await transport.get(Self.keysURL)
        struct JWK: Decodable { let kid: String; let kty: String; let n: String; let e: String; let alg: String?; let use: String? }
        struct SetOfKeys: Decodable { let keys: [JWK] }
        guard receipt.data.count <= 131_072 else { throw DesktopOAuthError.invalidGrant }
        let jwks = try JSONDecoder().decode(SetOfKeys.self, from: receipt.data)
        guard !jwks.keys.isEmpty, jwks.keys.count <= 32 else { throw DesktopOAuthError.invalidGrant }
        var next: [String: Data] = [:]
        for key in jwks.keys {
            guard key.kty == "RSA", key.alg == nil || key.alg == "RS256", key.use == nil || key.use == "sig",
                  !key.kid.isEmpty, key.kid.utf8.count <= 256, next[key.kid] == nil else { throw DesktopOAuthError.invalidGrant }
            let modulus = try Self.decode(key.n), exponent = try Self.decode(key.e)
            guard (256...512).contains(modulus.count), modulus.first != 0, modulus.first! & 0x80 != 0,
                  exponent == Data([1, 0, 1]) else { throw DesktopOAuthError.invalidGrant }
            next[key.kid] = Self.rsaDER(modulus: modulus, exponent: exponent)
        }
        try Task.checkCancellation()
        keys = next; validUntil = clock.now() + max(0, min(21_600, receipt.lifetime, discovery.lifetime))
    }
    static func rsaDER(modulus: Data, exponent: Data) -> Data {
        func tlv(_ tag: UInt8, _ value: Data) -> Data {
            let length = value.count
            let size: [UInt8] = length < 128 ? [UInt8(length)] : length < 256 ? [0x81, UInt8(length)] : [0x82, UInt8(length >> 8), UInt8(length & 255)]
            return Data([tag] + size) + value
        }
        func integer(_ bytes: Data) -> Data { tlv(2, bytes.first! & 0x80 != 0 ? Data([0]) + bytes : bytes) }
        return tlv(0x30, integer(modulus) + integer(exponent))
    }
    public func verify(_ token: String, audience: String, nonce: String) async throws -> ValidatedGoogleProfile {
        try await verifyToken(token, audience: audience, nonce: nonce, refreshingSubject: nil)
    }
    public func verifyRefreshed(_ token: String, audience: String, subject: String, originalNonce: String) async throws -> ValidatedGoogleProfile {
        try await verifyToken(token, audience: audience, nonce: originalNonce, refreshingSubject: subject)
    }
    private func verifyToken(_ token: String, audience: String, nonce: String, refreshingSubject: String?) async throws -> ValidatedGoogleProfile {
        guard token.utf8.count <= 32_768, !audience.isEmpty, !nonce.isEmpty else { throw DesktopOAuthError.invalidGrant }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let header = try JSONSerialization.jsonObject(with: Self.decode(parts[0])) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String, !kid.isEmpty, kid.utf8.count <= 256,
              header["crit"] == nil, header["jku"] == nil, header["jwk"] == nil, header["x5u"] == nil else { throw DesktopOAuthError.invalidGrant }
        if clock.now() >= validUntil || keys[kid] == nil { try await loadKeys() }
        guard let der = keys[kid], let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA256),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, try Self.decode(parts[2]) as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: Self.decode(parts[1])) as? [String: Any] else { throw DesktopOAuthError.invalidGrant }
        let audiences = (claims["aud"] as? String).map { [$0] } ?? claims["aud"] as? [String] ?? []
        let now = wallNow().timeIntervalSince1970
        func number(_ key: String) -> Double? {
            guard let n = claims[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue.isFinite ? n.doubleValue : nil
        }
        guard ["https://accounts.google.com", "accounts.google.com"].contains(claims["iss"] as? String ?? ""),
              audiences == [audience],
              (audiences.count == 1 && claims["azp"] == nil) || claims["azp"] as? String == audience,
              let exp = number("exp"), let issued = number("iat"), exp > now, issued <= now + 60,
              issued <= exp, exp - issued <= 86_400, now - issued <= 86_400,
              claims["nbf"] == nil || (number("nbf").map { $0 <= now + 60 } ?? false),
              (refreshingSubject != nil && claims["nonce"] == nil) || claims["nonce"] as? String == nonce, let subject = claims["sub"] as? String,
              !subject.isEmpty, subject.utf8.count <= 255, refreshingSubject == nil || subject == refreshingSubject, !subject.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw DesktopOAuthError.invalidGrant }
        try Task.checkCancellation()
        return try ValidatedGoogleProfile(subject: subject)
    }
}
