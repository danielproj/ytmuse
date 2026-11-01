import Foundation
import Testing
@testable import Updates

/// A one-shot HTTP server on the loopback interface that keeps the RAW bytes of the request it receives: the evidence for T30.3 is what is on the wire.
final class WireCapture: @unchecked Sendable {
    private var listener: Int32 = -1
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var captured = Data()
    private let done = DispatchSemaphore(value: 0)
    init(body: Data) {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(listener, 4)
        var bound = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(listener, $0, &length) } }
        port = UInt16(bigEndian: bound.sin_port)
        let socketHandle = listener
        Thread.detachNewThread { [self] in
            let client = accept(socketHandle, nil, nil)
            var request = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while !request.suffix(4).elementsEqual([13, 10, 13, 10]) {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                request.append(contentsOf: buffer[0..<n])
            }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            let response = Data(head.utf8) + body
            _ = response.withUnsafeBytes { write(client, $0.baseAddress, response.count) }
            Darwin.close(client)
            lock.lock(); captured = request; lock.unlock()
            done.signal()
        }
    }
    func rawRequest() -> String { _ = done.wait(timeout: .now() + 10); lock.lock(); defer { lock.unlock() }; return String(decoding: captured, as: UTF8.self) }
    func close() { Darwin.close(listener) }
}

/// T30.3: an update check carries no account data. Checked at three levels: the request the updater builds, the session it sends it through, and the
/// bytes that actually reach a socket while cookies and credentials for that very host sit in the process's shared stores.
@Suite struct RequestContentTests {
    let feedURL = URL(string: "https://github.com/\(repository)/releases/latest/download/feed.json")!

    @Test func theFeedAndAssetRequestsAreBarePlainGets() {
        for request in [UpdateRequests.feed(feedURL), UpdateRequests.asset(URL(string: "https://github.com/\(repository)/releases/download/v1.2.0/YTMuse-1.2.0.dmg")!)] {
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil && request.httpBodyStream == nil)
            #expect(request.url?.query == nil && request.url?.fragment == nil && request.url?.user == nil)
            #expect(request.httpShouldHandleCookies == false)
            #expect(Set((request.allHTTPHeaderFields ?? [:]).keys) == UpdateRequests.allowedHeaderNames)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "YTMuse-Updater")
            #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        }
    }
    @Test func theUserAgentCarriesNoVersionSystemMachineOrAccountIdentifier() {
        let agent = UpdateRequests.userAgent
        let host = ProcessInfo.processInfo.hostName
        let user = NSUserName(), full = NSFullUserName()
        #expect(agent.range(of: #"\d"#, options: .regularExpression) == nil, "no version or build number")
        for secret in [host, user, full, ProcessInfo.processInfo.operatingSystemVersionString] where !secret.isEmpty {
            #expect(!agent.localizedCaseInsensitiveContains(secret))
        }
    }
    @Test func theFeedLocationIsExactlyThePinnedRepositorysLatestDownload() {
        let policy = FeedBuilder().policy
        #expect(UpdateRequests.feedURL(feedURL.absoluteString, policy: policy) == feedURL)
        for bad in ["https://evil.example/\(repository)/releases/latest/download/feed.json", "http://github.com/\(repository)/releases/latest/download/feed.json",
                    feedURL.absoluteString + "?id=1", "https://github.com/other/repo/releases/latest/download/feed.json", "https://github.com/\(repository)/releases/latest/download/feed.json#x"] {
            #expect(UpdateRequests.feedURL(bad, policy: policy) == nil, "\(bad)")
        }
    }
    @Test func theSessionHasNoCookieJarCredentialsOrCache() {
        let c = URLSessionUpdateNetwork.configuration()
        #expect(c.httpCookieStorage == nil && c.httpShouldSetCookies == false && c.httpCookieAcceptPolicy == .never)
        #expect(c.urlCredentialStorage == nil && c.urlCache == nil)
        #expect(c.httpAdditionalHeaders?.isEmpty ?? true)
        #expect(c.waitsForConnectivity == false)
    }
    @Test func redirectsStayOnGitHubReleaseHosts() {
        for ok in ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com", "GitHub.com"] { #expect(URLSessionUpdateNetwork.allowedRedirectHost(ok), "\(ok)") }
        for bad in ["evil.example", "github.com.evil.example", "githubusercontent.com.evil.example", "notgithub.com", "", nil] { #expect(!URLSessionUpdateNetwork.allowedRedirectHost(bad), "\(bad ?? "nil")") }
    }

    @Test func theBytesOnTheWireCarryNoCookieCredentialOrIdentifier() async throws {
        let server = WireCapture(body: Data("{}".utf8))
        defer { server.close() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/\(repository)/releases/latest/download/feed.json")!
        // Stand-ins for account data, placed where a careless session would pick them up: the process-wide cookie jar and credential store, for this very host.
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "SAPISID", .value: "SECRET-SESSION-VALUE", .secure: "FALSE"])!
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let space = URLProtectionSpace(host: "127.0.0.1", port: Int(server.port), protocol: "http", realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        URLCredentialStorage.shared.setDefaultCredential(URLCredential(user: "someone@example.invalid", password: "SECRET-PASSWORD", persistence: .forSession), for: space)
        defer { URLCredentialStorage.shared.remove(URLCredential(user: "someone@example.invalid", password: "SECRET-PASSWORD", persistence: .forSession), for: space) }
        let body = try await URLSessionUpdateNetwork().get(UpdateRequests.feed(url), maxBytes: 1024)
        #expect(body == Data("{}".utf8))
        let raw = server.rawRequest()
        #expect(raw.hasPrefix("GET /\(repository)/releases/latest/download/feed.json HTTP/1.1\r\n"), "\(raw)")
        let headers = raw.components(separatedBy: "\r\n").dropFirst().filter { !$0.isEmpty }.map { $0.split(separator: ":", maxSplits: 1)[0].lowercased() }
        #expect(Set(headers).subtracting(["host", "accept", "user-agent", "accept-encoding", "connection", "accept-language", "cache-control"]).isEmpty, "unexpected headers: \(headers)")
        #expect(raw.lowercased().contains("\r\naccept-language: en\r\n"), "the language header is the constant, not the Mac's language list")
        for forbidden in ["cookie", "authorization", "referer", "origin", "x-", "secret", "sapisid", "someone@example"] { #expect(!raw.lowercased().contains(forbidden), "\(forbidden) in request") }
    }
}
