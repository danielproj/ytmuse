import Foundation
import Testing
@testable import AccountSession

@Suite struct OAuthFailureFeedbackTests {
    @Test func untrustedDescriptionsNeverEscapeAllowlistedCategories() throws {
        let cases: [(String, String, DesktopOAuthError)] = [
            ("invalid_client", "synthetic-secret-marker", .invalidClient),
            ("invalid_request", "synthetic-secret-marker", .invalidRequest),
            ("invalid_request", "client_secret is missing.", .missingClientSecret),
            ("invalid_request", "client_secret is missing. synthetic-secret-marker", .invalidRequest),
            ("invalid_grant", "synthetic-secret-marker", .revoked),
            ("unrecognized", "synthetic-secret-marker", .invalidGrant)]
        for (code, description, expected) in cases {
            let data = try JSONSerialization.data(withJSONObject: ["error": code, "error_description": description, "code": "synthetic-secret-marker"])
            do { try DirectOAuthTokenTransport.validateResponse(status: 400, data: data); Issue.record("Expected rejection") }
            catch { #expect(error as? DesktopOAuthError == expected); #expect(!String(reflecting: error).contains("synthetic-secret-marker")) }
        }
        #expect(throws: DesktopOAuthError.rateLimited) { try DirectOAuthTokenTransport.validateResponse(status: 429, data: Data()) }
        #expect(throws: DesktopOAuthError.temporarilyUnavailable) { try DirectOAuthTokenTransport.validateResponse(status: 503, data: Data()) }
    }
    @Test func receiptBytesNeverClaimAuthorizationSuccess() {
        for parsed in [true, false] {
            let bytes = NativeOAuthLoopback.receiptResponse(parsed: parsed)
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(text.contains("Cache-Control: no-store"))
            #expect(!text.contains("authorization completed") && !text.contains("synthetic-secret-marker"))
            #expect(text.contains(parsed ? "actual authorization result" : "Request not accepted"))
        }
    }
}
