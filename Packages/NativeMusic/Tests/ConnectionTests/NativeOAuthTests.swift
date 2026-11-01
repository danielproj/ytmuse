import Foundation
import Testing
@testable import AccountSession

@Suite struct NativeOAuthTests {
    @Test func strictHTTPBoundary() throws {
        func request(_ target: String = "/oauth2callback?state=synthetic&code=synthetic", headers: String = "Host: 127.0.0.1:49152", method: String = "GET") -> Data {
            Data("\(method) \(target) HTTP/1.1\r\n\(headers)\r\n\r\n".utf8)
        }
        let valid = try NativeOAuthLoopback.parse(request(), port: 49152)
        #expect(valid.host == "127.0.0.1:49152")
        #expect(valid.url.path == "/oauth2callback")
        let invalid = [request(headers: "Host: localhost:49152"), request(headers: "Host: 127.0.0.1:49153"),
            request(headers: "Host: 127.0.0.1:49152\r\nHost: 127.0.0.1:49152"), request(method: "POST"),
            request("http://127.0.0.1:49152/oauth2callback?code=synthetic"), request("/oauth2callback/other?code=synthetic"),
            request(headers: "Host: 127.0.0.1:49152\r\nTransfer-Encoding: chunked"),
            request(headers: "Host: 127.0.0.1:49152\r\nContent-Length: 1"), request() + Data("body".utf8),
            Data(repeating: 65, count: 16_385)]
        for data in invalid { #expect(throws: DesktopOAuthError.invalidCallback) { try NativeOAuthLoopback.parse(data, port: 49152) } }
    }
    @Test func realLoopbackDeliveryAndClose() async throws {
        let listener = NativeOAuthLoopback()
        let redirect = try await listener.bind()
        #expect(redirect.host == "127.0.0.1")
        #expect(redirect.port != nil)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: redirect.absoluteString + "?state=synthetic&code=synthetic")!
        let (data, response) = try await session.data(from: url)
        #expect(data == NativeOAuthLoopback.receiptBody)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var iterator = listener.callbacks.makeAsyncIterator()
        let callback = await iterator.next()
        #expect(callback?.url == url)
        await listener.close()
        #expect(await iterator.next() == nil)
        do { _ = try await listener.bind(); Issue.record("one-attempt listener rebound") }
        catch { #expect(error as? DesktopOAuthError == .busy) }
        await listener.close()
    }
    @Test func browserRejectsUntrustedOriginWithoutOpening() async {
        for value in ["http://accounts.google.com/o/oauth2/v2/auth", "https://example.com/o/oauth2/v2/auth", "https://accounts.google.com:443/o/oauth2/v2/auth", "https://accounts.google.com/other"] {
            do { try await NativeOAuthBrowser().open(URL(string: value)!); Issue.record("invalid URL accepted") }
            catch { #expect(error as? DesktopOAuthError == .invalidConfiguration) }
        }
    }
}
