import Foundation
import Synchronization
import Testing
@testable import OutputRoutes

/// T39.4: relay abuse tests. Each rule of the relay's scope (token, method, path, network, lifetime) is attacked at the decision layer (`CastRelayCore`, no
/// socket) AND over a real loopback connection to the server, because a rule that only holds in the pure function has not been shown to hold on the wire.
/// The server here listens on 127.0.0.1 only, inside this process.

final class RelayClock: @unchecked Sendable {
    private let lock = NSLock(); private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ seconds: Double) { lock.withLock { instant = instant.advanced(by: .seconds(seconds)) } }
}

@Suite struct CastRelayCoreTests {
    static let bytes = 4_096
    struct Rig {
        let core: CastRelayCore; let clock: RelayClock; let file: URL; let path: String
        init(limits: CastRelayLimits = CastRelayLimits(), bound: String = "192.168.1.20", receiver: String? = "192.168.1.50", name: String = "tone", ext: String = "wav") throws {
            let clock = RelayClock()
            core = CastRelayCore(bound: bound, receiver: receiver, limits: limits, now: { clock.now })
            self.clock = clock
            file = try CastFixtures.audioFile(bytes: CastRelayCoreTests.bytes, name: name, ext: ext)
            path = try core.register(file: file)
        }
        func head(_ path: String? = nil, method: String = "GET", headers: [String: String] = [:], version: String = "HTTP/1.1") -> Data {
            var text = "\(method) \(path ?? self.path) \(version)\r\nHost: 192.168.1.20\r\n"
            for (name, value) in headers { text += "\(name): \(value)\r\n" }
            return Data((text + "\r\n").utf8)
        }
        func ask(_ path: String? = nil, method: String = "GET", headers: [String: String] = [:], peer: String = "192.168.1.50") -> CastRelayDecision { core.decide(head: head(path, method: method, headers: headers), peer: peer) }
        func status(_ path: String? = nil, method: String = "GET", headers: [String: String] = [:], peer: String = "192.168.1.50") -> Int? {
            if case .respond(let response) = ask(path, method: method, headers: headers, peer: peer) { response.status } else { nil }
        }
        func cleanup() { CastFixtures.remove(file) }
    }

    // MARK: Token and path

    @Test func theRightPathServesTheWholeFile() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        guard case .respond(let response) = rig.ask() else { Issue.record("dropped"); return }
        #expect(response.status == 200 && response.body == .init(file: rig.file.resolvingSymlinksInPath(), offset: 0, length: UInt64(Self.bytes)))
        let headers = Dictionary(uniqueKeysWithValues: response.headers.map { ($0.name, $0.value) })
        #expect(headers["Content-Type"] == "audio/wav" && headers["Content-Length"] == "\(Self.bytes)" && headers["Accept-Ranges"] == "bytes" && headers["Cache-Control"] == "no-store")
    }
    @Test func theTokenIsLongRandomAndDifferentEveryTime() throws {
        var seen = Set<String>()
        for _ in 0..<50 {
            let core = CastRelayCore(bound: "127.0.0.1", receiver: nil)
            #expect(core.token.count >= 22 && core.token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            seen.insert(core.token)
        }
        #expect(seen.count == 50)
    }
    @Test(arguments: ["/", "/c", "/c/", "/c//", "/index.html", "/favicon.ico", "/robots.txt"]) func guessedPathsAreNotFound(path: String) throws {
        let rig = try Rig(); defer { rig.cleanup() }
        #expect(rig.status(path) == 404)
    }
    @Test func aWrongOrTruncatedOrExtendedTokenIsNotFound() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let parts = rig.path.split(separator: "/").map(String.init)   // c, token, tag.ext
        #expect(rig.status("/c/\(parts[1].dropLast())X/\(parts[2])") == 404 && rig.status("/c/\(String(parts[1].dropLast()))/\(parts[2])") == 404)
        #expect(rig.status("/c/\(parts[1])x/\(parts[2])") == 404 && rig.status("/c/\(parts[1].uppercased())/\(parts[2])") == 404 && rig.status("/c/AAAAAAAAAAAAAAAAAAAAAA/\(parts[2])") == 404)
        #expect(rig.status("/x/\(parts[1])/\(parts[2])") == 404, "the prefix is part of the secret path")
    }
    @Test func aWrongItemTagOrExtensionIsNotFound() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let parts = rig.path.split(separator: "/").map(String.init)
        let tag = parts[2].split(separator: ".")[0]
        #expect(rig.status("/c/\(parts[1])/\(tag).mp3") == 404 && rig.status("/c/\(parts[1])/\(tag)") == 404 && rig.status("/c/\(parts[1])/other.wav") == 404)
    }
    @Test(arguments: ["?x=1", "#frag", "%2e%2e", "/..", "/../x", "/%2E%2E/", "\\..\\", "/./", ";x", "//", "%00", "%2F"]) func trailingTricksAfterTheRightPathAreNotFound(suffix: String) throws {
        let rig = try Rig(); defer { rig.cleanup() }
        #expect(rig.status(rig.path + suffix) == 404, "\(suffix)")
    }
    @Test func traversalAttemptsNeverReachAnyFileBecauseThePathNeverNamesOne() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let attempts = ["/c/\(rig.core.token)/../../../../etc/passwd", "/c/\(rig.core.token)/..%2f..%2fetc%2fpasswd", "/c/\(rig.core.token)/%2e%2e/%2e%2e/etc/passwd",
                        "/../../../../etc/passwd", "/etc/passwd", "/Users", "/c/\(rig.core.token)/" + rig.file.lastPathComponent, rig.file.path, "file://" + rig.file.path, "http://evil.example/x"]
        for attempt in attempts {
            guard case .respond(let response) = rig.ask(attempt) else { Issue.record("dropped"); continue }
            #expect(response.status == 404 && response.body == nil, "\(attempt)")
        }
    }
    @Test func theServedFileIsFixedOnRegistrationNotChosenByTheRequest() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let other = try CastFixtures.audioFile(bytes: 100, name: "secret", ext: "wav"); defer { CastFixtures.remove(other) }
        guard case .respond(let response) = rig.ask(), let body = response.body else { Issue.record("no body"); return }
        #expect(body.file == rig.file.resolvingSymlinksInPath() && body.file != other)
    }
    @Test func aNewItemRetiresTheOldOnesPath() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let second = try CastFixtures.audioFile(bytes: 300, name: "second", ext: "mp3"); defer { CastFixtures.remove(second) }
        let newPath = try rig.core.register(file: second)
        #expect(newPath != rig.path && rig.status(rig.path) == 404 && rig.status(newPath) == 200, "only the current item can be fetched")
    }

    // MARK: Methods and bodies

    @Test(arguments: ["POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE", "CONNECT", "PROPFIND", "get", "G ET"]) func onlyGETIsServed(method: String) throws {
        let rig = try Rig(); defer { rig.cleanup() }
        guard case .respond(let response) = rig.core.decide(head: rig.head(method: method), peer: "192.168.1.50") else { Issue.record("dropped"); return }
        #expect(response.status == 405 || response.status == 400, "\(method) -> \(response.status)")
        #expect(response.body == nil)
    }
    @Test func theMethodIsRefusedBeforeThePathSoTheAnswerSaysNothingAboutWhichPathsExist() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        #expect(rig.status(rig.path, method: "POST") == 405 && rig.status("/nothing/here", method: "POST") == 405)
        guard case .respond(let response) = rig.ask(method: "DELETE") else { return }
        #expect(response.headers.contains { $0.name == "Allow" && $0.value == "GET" })
    }
    @Test func aGETThatCarriesABodyOrTransferEncodingIsRefused() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        #expect(rig.status(headers: ["Content-Length": "10"]) == 400 && rig.status(headers: ["Transfer-Encoding": "chunked"]) == 400)
        #expect(rig.status(headers: ["Content-Length": "0"]) == 200)
    }
    @Test func malformedHeadsAreRefused() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        for raw in ["GET\r\n\r\n", "GET /x\r\n\r\n", "GET /x HTTP/2\r\n\r\n", "GET /x HTTP/1.1\r\nbad header line\r\n\r\n", "GET /x HTTP/1.1\r\n: nameless\r\n\r\n", "GET /x HTTP/1.1\r\nBad Name: v\r\n\r\n", "GET /x HTTP/1.1\nHost: x\n\n"] {
            guard case .respond(let response) = rig.core.decide(head: Data(raw.utf8), peer: "192.168.1.50") else { Issue.record("dropped \(raw.debugDescription)"); continue }
            #expect(response.status == 400, "\(raw.debugDescription) -> \(response.status)")
        }
        #expect(rig.core.decide(head: Data([0xFF, 0xFE, 0x0D, 0x0A, 0x0D, 0x0A]), peer: "192.168.1.50") != .drop)
        guard case .respond(let nul) = rig.core.decide(head: Data("GET /x\0 HTTP/1.1\r\n\r\n".utf8), peer: "192.168.1.50") else { return }
        #expect(nul.status == 400)
    }
    @Test func anOversizedHeadIsRefusedAndTooManyHeadersToo() throws {
        var limits = CastRelayLimits(); limits.maxHeadBytes = 512
        let rig = try Rig(limits: limits); defer { rig.cleanup() }
        #expect(rig.status(headers: ["X-Long": String(repeating: "a", count: 600)]) == 431)
        let plenty = Rig.self; _ = plenty
        var many: [String: String] = [:]; for index in 0..<60 { many["X-\(index)"] = "v" }
        let big = try Rig(); defer { big.cleanup() }
        #expect(big.status(headers: many) == 400)
    }

    // MARK: Range

    @Test func aSingleRangeIsServedExactly() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        func range(_ value: String) -> (Int, CastRelayResponse.Body?, String?)? {
            guard case .respond(let response) = rig.ask(headers: ["Range": value]) else { return nil }
            return (response.status, response.body, response.headers.first { $0.name == "Content-Range" }?.value)
        }
        let size = UInt64(Self.bytes)
        #expect(range("bytes=0-99")?.0 == 206 && range("bytes=0-99")?.1?.length == 100 && range("bytes=0-99")?.2 == "bytes 0-99/\(size)")
        #expect(range("bytes=100-")?.1 == .init(file: rig.file.resolvingSymlinksInPath(), offset: 100, length: size - 100))
        #expect(range("bytes=-50")?.1 == .init(file: rig.file.resolvingSymlinksInPath(), offset: size - 50, length: 50))
        #expect(range("bytes=4000-999999")?.1?.length == size - 4000, "an end past the file is clamped")
        #expect(range("bytes=-999999")?.1?.offset == 0 && range("bytes=-999999")?.1?.length == size, "a suffix longer than the file is the file")
        #expect(range("bytes=\(size - 1)-\(size - 1)")?.1?.length == 1)
    }
    @Test(arguments: ["bytes=4096-", "bytes=9999-10000", "bytes=-0", "bytes=5-2", "bytes=0-1,5-6", "bytes=0-1, 3-4", "bytes=a-b", "bytes=", "bytes=-", "items=0-5", "bytes=0-5-9", "bytes=99999999999999999999-", "bytes=0-99999999999999999999"])
    func anUnsatisfiableOrAbusiveRangeIsRefused(value: String) throws {
        let rig = try Rig(); defer { rig.cleanup() }
        guard case .respond(let response) = rig.ask(headers: ["Range": value]) else { Issue.record("dropped"); return }
        #expect(response.status == 416 && response.body == nil, "\(value) -> \(response.status)")
        #expect(response.headers.contains { $0.name == "Content-Range" && $0.value == "bytes */\(Self.bytes)" })
    }

    // MARK: Network

    @Test func onlyTheReceiversOwnAddressIsServed() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        #expect(rig.status(peer: "192.168.1.50") == 200)
        for stranger in ["192.168.1.51", "192.168.1.20", "10.0.0.5", "8.8.8.8", "127.0.0.1", "0.0.0.0", "169.254.1.1", "::1", "fe80::1", "", "192.168.1.50 ", "192.168.1.050", "not-an-address", "192.168.1.50.1"] {
            #expect(rig.ask(peer: stranger) == .drop, "\(stranger) must be dropped without a word")
        }
    }
    @Test func aLoopbackBindServesLoopbackPeersOnlyAndNobodyElse() throws {
        let rig = try Rig(bound: "127.0.0.1", receiver: nil); defer { rig.cleanup() }
        #expect(rig.status(peer: "127.0.0.1") == 200 && rig.status(peer: "127.0.0.2") == 200)
        #expect(rig.ask(peer: "192.168.1.50") == .drop && rig.ask(peer: "10.0.0.1") == .drop)
    }
    @Test func aPublicBindNeverServesLoopbackPeers() throws {
        let rig = try Rig(bound: "192.168.1.20", receiver: nil); defer { rig.cleanup() }
        #expect(rig.ask(peer: "127.0.0.1") == .drop, "loopback is only allowed when the relay itself is bound to loopback")
    }
    @Test func peersAreCheckedBeforeAnythingIsRevealed() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        #expect(rig.core.decide(head: Data("garbage".utf8), peer: "8.8.8.8") == .drop)
        #expect(rig.core.requestCount == 0, "a refused peer does not even use up the request budget")
    }

    // MARK: Lifetime and budget

    @Test func afterItsLifetimeEveryRequestIsNotFoundAndNothingCanBeRegistered() throws {
        var limits = CastRelayLimits(); limits.maxLifetime = .seconds(100)
        let rig = try Rig(limits: limits); defer { rig.cleanup() }
        rig.clock.advance(99); #expect(rig.status() == 200)
        rig.clock.advance(2); #expect(rig.status() == 404 && rig.core.isExpired)
        #expect(throws: CastRelayError.expired) { try rig.core.register(file: rig.file) }
        rig.clock.advance(0); #expect(rig.status() == 404, "stays expired")
    }
    @Test func revokingEndsItAtOnce() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        #expect(rig.status() == 200)
        rig.core.revoke()
        #expect(rig.status() == 404)
    }
    @Test func theRequestBudgetIsFinite() throws {
        var limits = CastRelayLimits(); limits.maxRequests = 5
        let rig = try Rig(limits: limits); defer { rig.cleanup() }
        for _ in 0..<5 { #expect(rig.status() == 200) }
        #expect(rig.status() == 429 && rig.status() == 429)
    }

    // MARK: What may be registered

    @Test(arguments: ["txt", "swift", "plist", "sh", "html", "pdf", "key", "sqlite", "db", "json", "mp4", "mov", "exe", "", "wav.exe"]) func onlyAudioFilesCanBeRegistered(ext: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w39-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(ext.isEmpty ? "noextension" : "thing.\(ext)")
        try Data("x".utf8).write(to: file)
        let core = CastRelayCore(bound: "127.0.0.1", receiver: nil)
        #expect(throws: CastRelayError.self) { try core.register(file: file) }
    }
    @Test func aDirectoryOrASymlinkToAForbiddenTargetCannotBeRegistered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w39-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir.wav"), withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let core = CastRelayCore(bound: "127.0.0.1", receiver: nil)
        #expect(throws: CastRelayError.notRegularFile) { try core.register(file: folder.appendingPathComponent("dir.wav")) }
        let secret = folder.appendingPathComponent("secret.txt"); try Data("s".utf8).write(to: secret)
        let link = folder.appendingPathComponent("innocent.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(throws: CastRelayError.unsupportedType("txt")) { try core.register(file: link) }
        #expect(throws: (any Error).self) { try core.register(file: folder.appendingPathComponent("missing.wav")) }
    }
    @Test func aFileThatChangesAfterRegistrationIsNoLongerServed() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        #expect(rig.status() == 200)
        try Data(count: 10).write(to: rig.file)   // replaced by a different file
        #expect(rig.status() == 404)
    }
    @Test func aFileOverTheSizeCapCannotBeRegistered() throws {
        var limits = CastRelayLimits(); limits.maxFileBytes = 1_000
        let file = try CastFixtures.audioFile(bytes: 2_000); defer { CastFixtures.remove(file) }
        let core = CastRelayCore(bound: "127.0.0.1", receiver: nil, limits: limits)
        #expect(throws: CastRelayError.tooLarge) { try core.register(file: file) }
    }

    // MARK: What a response may contain

    @Test func noResponseNamesAFilesystemPathTheTokenOrAnAccount() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let heads = [rig.ask(), rig.ask("/nope"), rig.ask(method: "POST"), rig.ask(headers: ["Range": "bytes=9999-"])].compactMap { decision -> String? in
            if case .respond(let response) = decision { String(decoding: response.head, as: UTF8.self) } else { nil }
        }
        #expect(heads.count == 4)
        for head in heads {
            #expect(!head.contains(rig.file.path) && !head.contains(rig.file.lastPathComponent) && !head.contains(NSUserName()) && !head.contains("Server:") && !head.lowercased().contains("set-cookie"))
        }
        #expect(!heads[1].contains(rig.core.token), "a 404 never echoes the token")
    }
    @Test func everyResponseClosesTheConnection() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        if case .respond(let response) = rig.ask() { #expect(String(decoding: response.head, as: UTF8.self).contains("Connection: close\r\n")) }
    }
}

@Suite struct CastRelayServerTests {
    /// A server on loopback and one registered file, with the URL path to fetch it.
    struct Rig {
        let server: CastRelayServer; let port: UInt16; let path: String; let file: URL; let contents: Data
        init(limits: CastRelayLimits = CastRelayLimits(), bytes: Int = 300_000, ext: String = "wav") async throws {
            server = try CastRelayServer(bindAddress: "127.0.0.1", receiverAddress: "127.0.0.1", limits: limits)
            file = try CastFixtures.audioFile(bytes: bytes, ext: ext)
            contents = try Data(contentsOf: file)
            port = try await server.start()
            let url = try server.url(serving: file)
            path = url.path
        }
        func stop() async { server.stop(); await server.stopped(); CastFixtures.remove(file) }
    }

    @Test func aReceiverFetchesTheWholeFileAndEveryRangeOverTheWire() async throws {
        let rig = try await Rig(); defer { Task { await rig.stop() } }
        let full = try #require(try LoopbackHTTP.get(port: rig.port, path: rig.path))
        #expect(full.status == 200 && full.body == rig.contents && full.headers["content-type"] == "audio/wav")
        let part = try #require(try LoopbackHTTP.get(port: rig.port, path: rig.path, headers: ["Range": "bytes=1000-1999"]))
        #expect(part.status == 206 && part.body == rig.contents[1000...1999] && part.headers["content-range"] == "bytes 1000-1999/300000")
        let tail = try #require(try LoopbackHTTP.get(port: rig.port, path: rig.path, headers: ["Range": "bytes=-100"]))
        #expect(tail.status == 206 && tail.body == rig.contents.suffix(100))
        let open = try #require(try LoopbackHTTP.get(port: rig.port, path: rig.path, headers: ["Range": "bytes=299900-"]))
        #expect(open.body == rig.contents.suffix(100))
        #expect(rig.server.core.servedBytes == UInt64(300_000 + 1000 + 100 + 100))
    }
    @Test func theUrlHandedToTheReceiverIsTheBoundAddressThePortAndTheTokenPath() async throws {
        let rig = try await Rig(); defer { Task { await rig.stop() } }
        let url = try rig.server.url(serving: rig.file)
        #expect(url.scheme == "http" && url.host == "127.0.0.1" && url.port == Int(rig.port))
        #expect(url.path.hasPrefix("/c/\(rig.server.core.token)/") && url.query == nil && url.user == nil)
        #expect(!url.absoluteString.contains(rig.file.lastPathComponent) && !url.absoluteString.contains(rig.file.deletingLastPathComponent().lastPathComponent))
    }
    @Test func abuseOverTheWireGetsTheSameAnswersAsTheDecisionLayer() async throws {
        let rig = try await Rig(); defer { Task { await rig.stop() } }
        #expect(try LoopbackHTTP.get(port: rig.port, path: "/c/WRONG/\(rig.path.split(separator: "/").last!)")?.status == 404)
        #expect(try LoopbackHTTP.get(port: rig.port, path: rig.path + "/..")?.status == 404)
        #expect(try LoopbackHTTP.get(port: rig.port, path: "/etc/passwd")?.status == 404)
        for method in ["POST", "PUT", "DELETE", "HEAD", "OPTIONS"] { #expect(try LoopbackHTTP.get(port: rig.port, path: rig.path, method: method)?.status == 405, Comment(rawValue: method)) }
        #expect(try LoopbackHTTP.get(port: rig.port, path: rig.path, headers: ["Range": "bytes=0-1,5-6"])?.status == 416)
        #expect(try LoopbackHTTP.request(port: rig.port, raw: "this is not http\r\n\r\n")?.status == 400)
        #expect(try LoopbackHTTP.request(port: rig.port, raw: "GET \(rig.path) HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello")?.status == 400)
        // A normal request still works afterwards.
        #expect(try LoopbackHTTP.get(port: rig.port, path: rig.path)?.status == 200)
    }
    @Test func anOversizedHeadIsAnsweredOrClosedNotBuffered() async throws {
        var limits = CastRelayLimits(); limits.maxHeadBytes = 1_024
        let rig = try await Rig(limits: limits); defer { Task { await rig.stop() } }
        let reply = try LoopbackHTTP.request(port: rig.port, raw: "GET \(rig.path) HTTP/1.1\r\nX-Pad: \(String(repeating: "a", count: 20_000))\r\n\r\n")
        #expect(reply == nil || reply?.status == 431 || reply?.status == 400)
        #expect(try LoopbackHTTP.get(port: rig.port, path: rig.path)?.status == 200)
    }
    @Test func aSlowSenderThatNeverFinishesItsRequestIsCutOff() async throws {
        var limits = CastRelayLimits(); limits.readTimeout = .seconds(1)
        let rig = try await Rig(limits: limits); defer { Task { await rig.stop() } }
        let descriptor = try LoopbackHTTP.connected(port: rig.port); defer { close(descriptor) }
        LoopbackHTTP.send(descriptor, Data("GET \(rig.path) HTTP/1.1\r\nHost: x\r\n".utf8))   // no blank line, ever
        let started = ContinuousClock.now
        let rest = LoopbackHTTP.readAll(descriptor)   // returns when the server closes (or the 5 s client timeout)
        #expect(rest.isEmpty, "no reply to an incomplete request")
        #expect(ContinuousClock.now - started < .seconds(4), "the server closed the connection itself after the read timeout")
    }
    @Test func aReaderThatStopsReadingAfterTheHeadIsCutOffSoItCannotHoldTheCap() async throws {
        var limits = CastRelayLimits(); limits.maxConnections = 1; limits.idleTimeout = .seconds(1); limits.readTimeout = .seconds(30)
        let rig = try await Rig(limits: limits, bytes: 48 << 20); defer { Task { await rig.stop() } }
        let stalled = try LoopbackHTTP.connected(port: rig.port); defer { close(stalled) }
        LoopbackHTTP.send(stalled, Data("GET \(rig.path) HTTP/1.1\r\nHost: x\r\n\r\n".utf8))   // asks for 48 MiB and never reads a byte
        try await Task.sleep(for: .milliseconds(300))
        #expect(try LoopbackHTTP.get(port: rig.port, path: rig.path, headers: ["Range": "bytes=0-9"]) == nil, "the one connection slot is held by the stalled reader")
        let freed = await waitUntil(6) { ((try? LoopbackHTTP.get(port: rig.port, path: rig.path, headers: ["Range": "bytes=0-9"])) ?? nil)?.status == 206 }
        #expect(freed, "the stalled connection was cut after the idle timeout and the slot came back")
    }
    @Test func theConnectionCapIsEnforced() async throws {
        var limits = CastRelayLimits(); limits.maxConnections = 2; limits.readTimeout = .seconds(8)
        let rig = try await Rig(limits: limits); defer { Task { await rig.stop() } }
        let first = try LoopbackHTTP.connected(port: rig.port), second = try LoopbackHTTP.connected(port: rig.port); defer { close(first); close(second) }
        LoopbackHTTP.send(first, Data("GET ".utf8)); LoopbackHTTP.send(second, Data("GET ".utf8))
        try await Task.sleep(for: .milliseconds(200))
        // The third connection is accepted by the kernel but dropped by the relay without an answer.
        let reply = try LoopbackHTTP.get(port: rig.port, path: rig.path)
        #expect(reply == nil, "over the cap: closed, not served")
    }
    @Test func stoppingClosesThePortAndTheItemIsGone() async throws {
        let rig = try await Rig()
        #expect(LoopbackHTTP.isListening(port: rig.port))
        await rig.stop()
        // Cancelling a listener completes asynchronously; the port is closed within moments, not left open.
        let closed = await waitUntil(2) { !LoopbackHTTP.isListening(port: rig.port) }
        #expect(closed)
    }
    @Test func theSocketItselfGoesAwayAtTheEndOfTheLifetime() async throws {
        var limits = CastRelayLimits(); limits.maxLifetime = .seconds(1)
        let rig = try await Rig(limits: limits); defer { Task { await rig.stop() } }
        #expect(try LoopbackHTTP.get(port: rig.port, path: rig.path)?.status == 200)
        let closed = await waitUntil(3) { !LoopbackHTTP.isListening(port: rig.port) }
        #expect(closed, "the listener was closed at the end of the lifetime")
    }
    @Test func theRelayRefusesEveryAddressThatIsNotAPrivateOrLoopbackIPv4() async throws {
        for address in ["0.0.0.0", "8.8.8.8", "1.1.1.1", "172.32.0.1", "172.15.0.1", "100.64.0.1", "::", "::1", "fe80::1", "localhost", "example.com", "", "192.168.1", "192.168.1.1.1", "256.1.1.1", "192.168.01.1", "-1.0.0.1"] {
            #expect(throws: CastRelayError.self) { _ = try CastRelayServer(bindAddress: address, receiverAddress: nil) }
        }
    }
    @Test func evenAPrivateLANAddressIsRefusedInsideATestProcess() async throws {
        // The real network switch cannot be turned on here, so a LAN address (which would open a port other devices can reach) is refused.
        for address in ["192.168.1.20", "10.1.2.3", "172.16.5.5", "169.254.9.9"] {
            #expect(throws: CastRelayError.self) { _ = try CastRelayServer(bindAddress: address, receiverAddress: "192.168.1.50") }
        }
        #expect(throws: CastNetworkGate.Refusal.testProcess) { try CastNetworkGate.requireLive() }
        #expect(!CastNetworkGate.isLive)
    }
    @Test func relayCostIsMeasuredSeparatelyFromPlayback() async throws {
        // T39.4 cost measurement: CPU time of this process and wall time to serve 24 MiB over loopback in 64 KiB range requests. Printed for the report.
        let rig = try await Rig(bytes: 24 << 20); defer { Task { await rig.stop() } }
        func cpu() -> Double { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6 }
        let cpuBefore = cpu(), started = ContinuousClock.now
        var received = 0
        var offset = 0
        while offset < rig.contents.count {
            let end = min(offset + 65_535, rig.contents.count - 1)
            let reply = try #require(try LoopbackHTTP.get(port: rig.port, path: rig.path, headers: ["Range": "bytes=\(offset)-\(end)"]))
            received += reply.body.count; offset = end + 1
        }
        let wall = ContinuousClock.now - started
        let cpuSeconds = cpu() - cpuBefore
        #expect(received == rig.contents.count)
        let seconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
        print("T39.4 relay cost: \(received) bytes in \(Int(rig.contents.count / 65_536)) range requests, wall \(String(format: "%.3f", seconds)) s, process CPU \(String(format: "%.3f", cpuSeconds)) s (client and server in one process)")
        #expect(cpuSeconds >= 0)
    }
}
