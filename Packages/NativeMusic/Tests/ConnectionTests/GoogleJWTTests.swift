import Foundation
import Security
import Testing
@testable import AccountSession

struct SyntheticJWT: @unchecked Sendable {
    let key: SecKey
    let jwks: Data
    init(kid: String = "ephemeral-test-key") throws {
        key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        let publicKey = SecKeyCopyPublicKey(key)!
        let bytes = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        // Decode the SDK's PKCS#1 public export only to construct the public JWK.
        var offset = 0
        func read() -> Data {
            offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length & 128 != 0 { let count = length & 127; length = 0; for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 } }
            let data = bytes.subdata(in: offset..<(offset + length)); offset += length; return data
        }
        let sequence = read(); offset = 0
        func integer(_ data: Data, _ offset: inout Int) -> Data {
            offset += 1; var length = Int(data[offset]); offset += 1
            if length & 128 != 0 { let count = length & 127; length = 0; for _ in 0..<count { length = length * 256 + Int(data[offset]); offset += 1 } }
            var value = data.subdata(in: offset..<(offset + length)); offset += length
            if value.first == 0 { value.removeFirst() }; return value
        }
        let modulus = integer(sequence, &offset), exponent = integer(sequence, &offset)
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": kid, "kty": "RSA", "use": "sig", "alg": "RS256", "n": Self.encode(modulus), "e": Self.encode(exponent)]]])
    }
    static func encode(_ bytes: Data) -> String { bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    func token(nonce: String = "nonce", audience: String = "owned-test.apps.googleusercontent.com", subject: String = "synthetic-subject", changes: [String: Any] = [:], headerChanges: [String: Any] = [:]) throws -> String {
        var header: [String: Any] = ["alg": "RS256", "kid": "ephemeral-test-key"]
        header.merge(headerChanges) { _, value in value }
        var claims: [String: Any] = ["iss": "https://accounts.google.com", "sub": subject, "aud": audience,
            "iat": 1_000_000, "exp": 1_003_600, "nonce": nonce]
        claims.merge(changes) { _, value in value }
        let signing = Self.encode(try JSONSerialization.data(withJSONObject: header)) + "." + Self.encode(try JSONSerialization.data(withJSONObject: claims))
        let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signing.utf8) as CFData, nil)! as Data
        return signing + "." + Self.encode(signature)
    }
}
actor SyntheticGoogleDocuments: GooglePublicDocumentTransport {
    let jwks: Data
    let lifetime: TimeInterval
    var urls: [URL] = []
    var badDiscovery = false
    init(jwks: Data, lifetime: TimeInterval = 120) { self.jwks = jwks; self.lifetime = lifetime }
    func setBadDiscovery() { badDiscovery = true }
    func count() -> Int { urls.count }
    func get(_ url: URL) throws -> GooglePublicDocument {
        urls.append(url)
        if url == GoogleJWTVerifier.discoveryURL {
            return .init(data: try JSONSerialization.data(withJSONObject: ["issuer": "https://accounts.google.com", "jwks_uri": badDiscovery ? "https://example.com/keys" : GoogleJWTVerifier.keysURL.absoluteString, "id_token_signing_alg_values_supported": ["RS256"]]), lifetime: lifetime)
        }
        #expect(url == GoogleJWTVerifier.keysURL)
        return .init(data: jwks, lifetime: lifetime)
    }
}
@Suite struct GoogleJWTTests {
    @Test func signedClaimsAndAdverseClaims() async throws {
        let jwt = try SyntheticJWT(), documents = SyntheticGoogleDocuments(jwks: jwt.jwks)
        let verifier = GoogleJWTVerifier(transport: documents, wallNow: { Date(timeIntervalSince1970: 1_000_010) })
        let profile = try await verifier.verify(jwt.token(), audience: "owned-test.apps.googleusercontent.com", nonce: "nonce")
        #expect(profile.subject == "synthetic-subject")
        let cases: [[String: Any]] = [["aud": NSNull()], ["aud": []], ["aud": ["owned-test.apps.googleusercontent.com", "owned-test.apps.googleusercontent.com"]], ["iss": "https://example.com"], ["aud": "other"], ["exp": 1_000_000], ["iat": 1_100_000],
            ["iat": true], ["exp": true], ["nbf": 1_100_000], ["nonce": "wrong"], ["sub": ""], ["sub": "bad subject"],
            ["aud": ["owned-test.apps.googleusercontent.com", "other"]], ["azp": "other"]]
        for changes in cases {
            await #expect(throws: (any Error).self) { try await verifier.verify(jwt.token(changes: changes), audience: "owned-test.apps.googleusercontent.com", nonce: "nonce") }
        }
        for header in [["alg": "none"], ["alg": "HS256"], ["kid": "missing"], ["jku": "https://example.com/keys"], ["crit": "unknown"]] {
            await #expect(throws: (any Error).self) { try await verifier.verify(jwt.token(headerChanges: header), audience: "owned-test.apps.googleusercontent.com", nonce: "nonce") }
        }
        let forged = try SyntheticJWT()
        await #expect(throws: (any Error).self) { try await verifier.verify(forged.token(), audience: "owned-test.apps.googleusercontent.com", nonce: "nonce") }
        let multi = try jwt.token(changes: ["aud": ["owned-test.apps.googleusercontent.com", "other"], "azp": "owned-test.apps.googleusercontent.com"])
        await #expect(throws: (any Error).self) { try await verifier.verify(multi, audience: "owned-test.apps.googleusercontent.com", nonce: "nonce") }
        await #expect(throws: (any Error).self) { try await verifier.verifyRefreshed(multi, audience: "owned-test.apps.googleusercontent.com", subject: "synthetic-subject", originalNonce: "nonce") }
        _ = try await verifier.verify(jwt.token(changes: ["aud": ["owned-test.apps.googleusercontent.com"], "azp": "owned-test.apps.googleusercontent.com"]), audience: "owned-test.apps.googleusercontent.com", nonce: "nonce")
        #expect(await documents.count() == 2)
    }
    @Test func refreshedIdentityAllowsAbsentNonceButKeepsSubjectAndSignature() async throws {
        let jwt = try SyntheticJWT()
        let verifier = GoogleJWTVerifier(transport: SyntheticGoogleDocuments(jwks: jwt.jwks), wallNow: { Date(timeIntervalSince1970: 1_000_010) })
        // Null is not omitted and must fail; removal below builds an actually absent claim.
        let original = try jwt.token()
        let pieces = original.split(separator: ".").map(String.init)
        var claims = try JSONSerialization.jsonObject(with: GoogleJWTVerifier.decode(pieces[1])) as! [String: Any]
        claims.removeValue(forKey: "nonce")
        let signing = pieces[0] + "." + SyntheticJWT.encode(try JSONSerialization.data(withJSONObject: claims))
        let signature = SecKeyCreateSignature(jwt.key, .rsaSignatureMessagePKCS1v15SHA256, Data(signing.utf8) as CFData, nil)! as Data
        let token = signing + "." + SyntheticJWT.encode(signature)
        _ = try await verifier.verifyRefreshed(token, audience: "owned-test.apps.googleusercontent.com", subject: "synthetic-subject", originalNonce: "nonce")
        await #expect(throws: (any Error).self) { try await verifier.verify(token, audience: "owned-test.apps.googleusercontent.com", nonce: "nonce") }
        await #expect(throws: (any Error).self) { try await verifier.verifyRefreshed(token, audience: "owned-test.apps.googleusercontent.com", subject: "other", originalNonce: "nonce") }
        await #expect(throws: (any Error).self) { try await verifier.verifyRefreshed(jwt.token(nonce: "wrong"), audience: "owned-test.apps.googleusercontent.com", subject: "synthetic-subject", originalNonce: "nonce") }
    }
    @Test func cacheExpiryAndPinnedDiscovery() async throws {
        let jwt = try SyntheticJWT(), clock = TestConnectionClock(), documents = SyntheticGoogleDocuments(jwks: jwt.jwks)
        let verifier = GoogleJWTVerifier(transport: documents, clock: clock, wallNow: { Date(timeIntervalSince1970: 1_000_010) })
        _ = try await verifier.verify(jwt.token(), audience: "owned-test.apps.googleusercontent.com", nonce: "nonce")
        clock.advance(to: 119)
        _ = try await verifier.verify(jwt.token(), audience: "owned-test.apps.googleusercontent.com", nonce: "nonce")
        #expect(await documents.count() == 2)
        clock.advance(to: 120)
        _ = try await verifier.verify(jwt.token(), audience: "owned-test.apps.googleusercontent.com", nonce: "nonce")
        #expect(await documents.count() == 4)
        let bad = SyntheticGoogleDocuments(jwks: jwt.jwks); await bad.setBadDiscovery()
        let rejected = GoogleJWTVerifier(transport: bad)
        await #expect(throws: (any Error).self) { try await rejected.verify(jwt.token(), audience: "owned-test.apps.googleusercontent.com", nonce: "nonce") }
        #expect(await bad.count() == 1)
    }
    @Test func malformedAndDuplicateKeysNeverVerify() async throws {
        let jwt = try SyntheticJWT()
        let root = try JSONSerialization.jsonObject(with: jwt.jwks) as! [String: Any]
        let key = (root["keys"] as! [[String: Any]])[0]
        let duplicates = try JSONSerialization.data(withJSONObject: ["keys": [key, key]])
        let verifier = GoogleJWTVerifier(transport: SyntheticGoogleDocuments(jwks: duplicates))
        await #expect(throws: (any Error).self) { try await verifier.verify(jwt.token(), audience: "owned-test.apps.googleusercontent.com", nonce: "nonce") }
        for value in ["", "e30.e30.", "a.b.c", String(repeating: "a", count: 32_769)] {
            await #expect(throws: (any Error).self) { try await verifier.verify(value, audience: "owned-test.apps.googleusercontent.com", nonce: "nonce") }
        }
    }
}
