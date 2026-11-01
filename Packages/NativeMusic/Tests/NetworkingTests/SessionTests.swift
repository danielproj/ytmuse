import Foundation
import Testing
@testable import YouTubeMusicAdapter

final class SyntheticProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "music.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        let status = mode == "redirect" ? 302 : 200
        let headers = mode == "advertised" ? ["Content-Length": "1000000"] : ["Content-Type": "application/json"]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if mode == "stall" { return }
        client?.urlProtocol(self, didLoad: Data(repeating: 32, count: mode == "overflow" ? 33 : 16))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Suite struct SessionTests {
    @Test func actualURLSessionCollectorAndDeadline() async throws {
        let io = DirectBoundedTransport(protocolClasses: [SyntheticProtocol.self]), r = try route()
        func input(_ mode: String) throws -> BoundedRequest {
            try BoundedRequest(route: r, url: URL(string: "https://music.example.test/read?q=" + mode)!, bounds: ResponseBounds(bytes: 32, seconds: 0.1))
        }
        #expect(try await io.send(input("exact"), authorization: nil).body.count == 16)
        for mode in ["advertised", "overflow"] {
            await #expect(throws: NetworkFault.oversized) { try await io.send(input(mode), authorization: nil) }
        }
        await #expect(throws: NetworkFault.timeout) { try await io.send(input("stall"), authorization: nil) }
        await #expect(throws: NetworkFault.redirect) { try await io.send(input("redirect"), authorization: nil) }
    }
}
