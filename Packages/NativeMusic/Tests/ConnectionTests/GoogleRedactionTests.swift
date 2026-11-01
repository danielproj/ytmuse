import Foundation
import Testing
@testable import AccountSession

@Suite struct GoogleRedactionTests {
    @Test func grantAndCaptureDescriptionsAreRedactedWhileCodableIsUnchanged() async throws {
        let markers = ["synthetic-access-marker", "synthetic-refresh-marker", "synthetic-nonce-marker"]
        let grant = GoogleGrant(clientID: "synthetic-client", subject: "synthetic-subject", nonce: markers[2], accessToken: markers[0], refreshToken: markers[1], scopes: ["openid"], expiresIn: 60)
        let capture = GoogleGrantCapture()
        await capture.set(grant, deadline: 60)
        let descriptions = [String(describing: grant), String(reflecting: grant), String(describing: capture), String(reflecting: capture), String(reflecting: await capture.take())]
        for description in descriptions { for marker in markers { #expect(!description.contains(marker)) } }
        #expect(Mirror(reflecting: grant).children.isEmpty)
        #expect(Mirror(reflecting: capture).children.isEmpty)
        let roundTrip = try JSONDecoder().decode(GoogleGrant.self, from: JSONEncoder().encode(grant))
        #expect(roundTrip.accessToken == markers[0] && roundTrip.refreshToken == markers[1])
    }
}

extension GoogleRedactionTests {
    @Test func transientOAuthWrappersAreOpaqueWithoutChangingProtocolFields() throws {
        let code = "synthetic-code-marker", verifier = "synthetic-pkce-marker", state = "synthetic-state-marker"
        let redirect = URL(string: "http://127.0.0.1:49152/oauth2callback")!
        let exchange = OAuthCodeExchange(clientID: "synthetic-client", redirect: redirect, code: code, verifier: verifier)
        let url = URL(string: redirect.absoluteString + "?code=" + code + "&state=" + state)!
        let callback = OAuthCallback(method: "GET", url: url, host: "127.0.0.1:49152")
        for value: Any in [exchange, callback, Optional.some(exchange) as Any, Optional.some(callback) as Any, [exchange], [callback], ["exchange": exchange], ["callback": callback]] {
            var dumped = ""; dump(value, to: &dumped)
            for representation in [String(describing: value), String(reflecting: value), dumped] {
                for marker in [code, verifier, state] { #expect(!representation.contains(marker)) }
            }
        }
        #expect(Mirror(reflecting: exchange).children.isEmpty && Mirror(reflecting: callback).children.isEmpty)
        #expect(exchange.code == code && exchange.verifier == verifier && exchange.redirect == redirect)
        #expect(callback.url.absoluteString == url.absoluteString && callback.method == "GET" && callback.host == "127.0.0.1:49152")
        let form = try DesktopOAuthTokenExchange.form(endpoint: "token", values: ["code": exchange.code, "code_verifier": exchange.verifier])
        #expect(String(decoding: form.httpBody!, as: UTF8.self) == "code=" + code + "&code_verifier=" + verifier)
    }
}
