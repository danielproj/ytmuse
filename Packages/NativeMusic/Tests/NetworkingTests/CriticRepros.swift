import Foundation
import Domain
import Testing
@testable import YouTubeMusicAdapter

// Temporary W07 Opus critic reproductions. Not product code; removed after the run.
// Each test asserts the CORRECT behaviour; a failure demonstrates the finding. Observations are printed as CRITIC lines.

final class CriticStreamProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var chunks = 0
    nonisolated(unsafe) static var stopped = 0
    nonisolated(unsafe) static var evilHits = 0
    private var timer: DispatchSourceTimer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.host == "evil.example.test" {
            Self.lock.withLock { Self.evilHits += 1 }
            let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self); return
        }
        let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        if mode == "redirect" {
            let r = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://evil.example.test/x"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://evil.example.test/x")!), redirectResponse: r)
            // OHHTTPStubs pattern: deliver the 3xx as the final response in case the delegate refuses the hop.
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now(), repeating: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Self.lock.withLock { Self.chunks += 1 }
            self.client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 64))
        }
        timer = t; t.resume()
    }
    override func stopLoading() { timer?.cancel(); timer = nil; Self.lock.withLock { Self.stopped += 1 } }
    static func reset() { lock.withLock { chunks = 0; stopped = 0; evilHits = 0 } }
    static func snapshot() -> (Int, Int, Int) { lock.withLock { (chunks, stopped, evilHits) } }
}

final class CountingTime: NetworkTime, @unchecked Sendable {
    let base = ContinuousNetworkTime(); let lock = NSLock(); var sleeps = 0
    func now() -> TimeInterval { base.now() }
    func wallNow() -> Date { base.wallNow() }
    func sleep(until: TimeInterval) async throws { lock.withLock { sleeps += 1 }; try await base.sleep(until: until) }
    var count: Int { lock.withLock { sleeps } }
}

@Suite(.serialized) struct CriticRepros {
    // X1: byte-cap throw must stop the underlying URLSession work, not only the caller.
    @Test func x1ByteCapStopsUnderlyingTransfer() async throws {
        CriticStreamProtocol.reset()
        let io = DirectBoundedTransport(protocolClasses: [CriticStreamProtocol.self]), r = try route()
        let input = try BoundedRequest(route: r, url: URL(string: "https://music.example.test/read?q=stream")!, bounds: ResponseBounds(bytes: 256, seconds: 5))
        let start = Date()
        await #expect(throws: NetworkFault.oversized) { try await io.send(input, authorization: nil) }
        let elapsed = Date().timeIntervalSince(start)
        let (c1, s1, _) = CriticStreamProtocol.snapshot()
        try await Task.sleep(for: .milliseconds(300))
        let (c2, s2, _) = CriticStreamProtocol.snapshot()
        print("CRITIC X1 elapsed=\(elapsed) chunksAtThrow=\(c1) stoppedAtThrow=\(s1) chunksAfter300ms=\(c2) stoppedAfter300ms=\(s2)")
        #expect(s2 == 1); #expect(c2 - c1 <= 2)
    }
    // X2: deadline must stop the underlying transfer too.
    @Test func x2DeadlineStopsUnderlyingTransfer() async throws {
        CriticStreamProtocol.reset()
        let io = DirectBoundedTransport(protocolClasses: [CriticStreamProtocol.self]), r = try route()
        let input = try BoundedRequest(route: r, url: URL(string: "https://music.example.test/read?q=stream")!, bounds: ResponseBounds(bytes: 16_000_000, seconds: 0.1))
        await #expect(throws: NetworkFault.timeout) { try await io.send(input, authorization: nil) }
        let (c1, s1, _) = CriticStreamProtocol.snapshot()
        try await Task.sleep(for: .milliseconds(300))
        let (c2, s2, _) = CriticStreamProtocol.snapshot()
        print("CRITIC X2 chunksAtThrow=\(c1) stoppedAtThrow=\(s1) chunksAfter300ms=\(c2) stoppedAfter300ms=\(s2)")
        #expect(s2 == 1); #expect(c2 - c1 <= 2)
    }
    // X3: end-to-end redirect through the real session delegate; the redirect target must never be requested.
    @Test func x3RedirectEndToEnd() async throws {
        CriticStreamProtocol.reset()
        let io = DirectBoundedTransport(protocolClasses: [CriticStreamProtocol.self]), r = try route()
        let input = try BoundedRequest(route: r, url: URL(string: "https://music.example.test/read?q=redirect")!, bounds: ResponseBounds(bytes: 1024, seconds: 2))
        var outcome = "success"
        do { _ = try await io.send(input, authorization: nil) } catch { outcome = "\(error)" }
        try await Task.sleep(for: .milliseconds(100))
        let (_, _, evil) = CriticStreamProtocol.snapshot()
        print("CRITIC X3 outcome=\(outcome) evilHits=\(evil)")
        #expect(evil == 0); #expect(outcome == "redirect")
    }
    // X4: an account-scoped cooldown/pacing wait holds a GLOBAL concurrency slot, starving an unrelated account.
    @Test func x4AccountCooldownStarvesOtherAccounts() async throws {
        let scheduler = NetworkScheduler(time: ContinuousNetworkTime(), interval: 0), r = try route()
        let a = owner(account: try identity()), b = owner(account: try identity())
        let slow = try BoundedRequest(route: r, url: URL(string: "https://music.example.test/read")!, bounds: ResponseBounds(seconds: 5))
        await scheduler.postpone(slow, context: a, seconds: 2)
        let held = (0..<6).map { _ in Task { try await scheduler.acquire(slow, context: a); await scheduler.release(slow) } }
        try await Task.sleep(for: .milliseconds(100))
        let brief = try BoundedRequest(route: r, url: slow.url, bounds: ResponseBounds(seconds: 0.5))
        let start = Date(); var outcome = "admitted"
        do { try await scheduler.acquire(brief, context: b); await scheduler.release(brief) } catch { outcome = "\(error)" }
        print("CRITIC X4 accountB outcome=\(outcome) waited=\(Date().timeIntervalSince(start))")
        for t in held { t.cancel() }
        for t in held { _ = try? await t.value }
        #expect(outcome == "admitted")
    }
    // X5: rejected admissions still advance the per-key pacing reservation.
    @Test func x5RejectedAdmissionsConsumePacing() async throws {
        let clock = TestTime(), scheduler = NetworkScheduler(time: clock, interval: 1), r = try route()
        let a = owner(account: try identity())
        let normal = try request(r)
        try await scheduler.acquire(normal, context: a); await scheduler.release(normal)
        let brief = try BoundedRequest(route: r, url: normal.url, bounds: ResponseBounds(seconds: 0.5))
        for _ in 0..<5 { await #expect(throws: NetworkFault.timeout) { try await scheduler.acquire(brief, context: a) } }
        clock.advance(1.0)
        var outcome = "admitted"
        do { try await scheduler.acquire(brief, context: a); await scheduler.release(brief) } catch { outcome = "\(error)" }
        print("CRITIC X5 after one real start and 5 rejected admissions, next slot outcome=\(outcome)")
        #expect(outcome == "admitted")
    }
    // X6: SourceCache epoch is global: invalidating resource R1 fails an unrelated in-flight read of R2.
    @Test func x6ResourceInvalidationFailsUnrelatedRead() async throws {
        let cache = SourceCache(), probe = Probe(), context = owner(account: try identity())
        let policy = try SourceRetention(seconds: 600, freshness: .dynamic), r1 = UUID(), r2 = UUID()
        try await cache.bind(context)
        let t = Task { try await cache.read(resource: r2, context: context, policy: policy, visible: true) { await probe.hold() } }
        #expect(await eventually { await probe.calls == 1 })
        await cache.invalidate(resource: r1, context: context)
        await probe.release()
        var outcome = "ok"
        do { _ = try await t.value } catch { outcome = "\(error)" }
        let cached = await cache.cached(resource: r2, context: context) != nil
        print("CRITIC X6 unrelated read outcome=\(outcome) cachedAfter=\(cached)")
        #expect(outcome == "ok")
    }
    // X7: a cancelled cache caller neither returns promptly nor cancels the shared load when it is the only waiter.
    @Test func x7CancelledSoleCacheWaiter() async throws {
        let cache = SourceCache(), context = owner(account: try identity())
        let policy = try SourceRetention(seconds: 600, freshness: .dynamic), resource = UUID()
        try await cache.bind(context)
        final class Flag: @unchecked Sendable { let lock = NSLock(); var cancelled = false; var started = false }
        let flag = Flag()
        let t = Task {
            try await cache.read(resource: resource, context: context, policy: policy, visible: true) {
                flag.lock.withLock { flag.started = true }
                do { try await Task.sleep(for: .seconds(1)) } catch { flag.lock.withLock { flag.cancelled = true }; throw error }
                return BoundedResponse(status: 200, body: Data("{}".utf8))
            }
        }
        #expect(await eventually { flag.lock.withLock { flag.started } })
        let start = Date(); t.cancel()
        var outcome = "ok"
        do { _ = try await t.value } catch { outcome = "\(error)" }
        let elapsed = Date().timeIntervalSince(start)
        print("CRITIC X7 cancelled caller returned after \(elapsed)s outcome=\(outcome) loaderCancelled=\(flag.lock.withLock { flag.cancelled })")
        #expect(elapsed < 0.3)
    }
    // X8: a cancelled joined waiter must not prevent the valid caller's result from being cached.
    @Test func x8CancelledJoinerDoesNotDropCacheStore() async throws {
        var lost = 0
        for _ in 0..<20 {
            let cache = SourceCache(), probe = Probe(), context = owner(account: try identity())
            let policy = try SourceRetention(seconds: 600, freshness: .dynamic), resource = UUID()
            try await cache.bind(context)
            let a = Task { try await cache.read(resource: resource, context: context, policy: policy, visible: true) { await probe.hold() } }
            #expect(await eventually { await probe.calls == 1 })
            let b = Task { try await cache.read(resource: resource, context: context, policy: policy, visible: true) { await probe.hold() } }
            try await Task.sleep(for: .milliseconds(10))
            a.cancel()
            await probe.release()
            _ = try? await a.value
            #expect(try await b.value != nil)
            if await cache.cached(resource: resource, context: context) == nil { lost += 1 }
        }
        print("CRITIC X8 valid result not cached in \(lost)/20 runs after the creating caller was cancelled")
        #expect(lost == 0)
    }
    // X9: admission waiters poll every 10 ms (no FIFO hand-off): count wakeups.
    @Test func x9AdmissionPollingWakeups() async throws {
        let time = CountingTime(), scheduler = NetworkScheduler(time: time, interval: 0), r = try route()
        let input = try BoundedRequest(route: r, url: URL(string: "https://music.example.test/read")!, bounds: ResponseBounds(seconds: 2))
        await scheduler.reduceUnderContention(metadata: 1, media: 1)
        try await scheduler.acquire(input, context: owner())
        let base = time.count
        let waiters = (0..<50).map { _ in Task { try await scheduler.acquire(input, context: owner()); await scheduler.release(input) } }
        try await Task.sleep(for: .seconds(1))
        let wakeups = time.count - base
        print("CRITIC X9 50 waiters, 1 s blocked: \(wakeups) sleep/poll wakeups")
        for w in waiters { w.cancel() }
        await scheduler.release(input)
        for w in waiters { _ = try? await w.value }
        #expect(wakeups < 500)
    }
    // X10: Retry-After formats accepted by HTTP (RFC 850 and asctime) and a huge delta.
    @Test func x10RetryAfterFormatsAndHorizon() async throws {
        let now = Date(timeIntervalSince1970: 0)
        let rfc850 = BoundedNetworkClient.retryAfter("Thursday, 01-Jan-70 00:00:10 GMT", now: now)
        let asctime = BoundedNetworkClient.retryAfter("Thu Jan  1 00:00:10 1970", now: now)
        let huge = BoundedNetworkClient.retryAfter("315360000", now: now)
        print("CRITIC X10 rfc850=\(String(describing: rfc850)) asctime=\(String(describing: asctime)) tenYears=\(String(describing: huge))")
        #expect(rfc850 == 10); #expect(asctime == 10)
    }

    // X4b: same starvation through the public client API: a 429 Retry-After for account A on one host delays account B on another host.
    @Test func x4bClientLevelCrossAccountCrossHostStall() async throws {
        let scheduler = NetworkScheduler(time: ContinuousNetworkTime(), interval: 0), probe = Probe()
        let music = try NetworkRoute(host: "music.example.test", path: "/read", method: "GET", purpose: .metadata, queryNames: ["q"], replay: .knownRead)
        let art = try NetworkRoute(host: "art.example.test", path: "/img", method: "GET", purpose: .artwork, replay: .knownRead)
        let io = DirectBoundedTransport { wire, _ in
            await probe.record()
            return wire.url?.host == "music.example.test" ? .init(status: 429, body: Data(), retryAfter: "2") : .init(status: 200, body: Data())
        }
        let a = owner(account: try identity()), b = owner(account: try identity())
        let musicRequest = try BoundedRequest(route: music, url: URL(string: "https://music.example.test/read")!, bounds: ResponseBounds())
        let artRequest = try BoundedRequest(route: art, url: URL(string: "https://art.example.test/img")!, bounds: ResponseBounds())
        let first = BoundedNetworkClient(routes: [music], transport: io, scheduler: scheduler)
        try await first.bind(a)
        await #expect(throws: RateLimitBound(retryAfterSeconds: 2)) { try await first.send(musicRequest, context: a, budget: RetryBudget(attempts: 1)) }
        let pending = try await (0..<6).asyncMap { _ -> Task<Void, Never> in
            let c = BoundedNetworkClient(routes: [music], transport: io, scheduler: scheduler); try await c.bind(a)
            return Task { _ = try? await c.send(musicRequest, context: a, budget: RetryBudget(attempts: 1)) }
        }
        try await Task.sleep(for: .milliseconds(100))
        let other = BoundedNetworkClient(routes: [art], transport: io, scheduler: scheduler)
        try await other.bind(b)
        let start = Date()
        _ = try await other.send(artRequest, context: b, budget: RetryBudget(attempts: 1))
        let waited = Date().timeIntervalSince(start)
        print("CRITIC X4b account B artwork request waited \(waited)s behind account A music Retry-After cooldown")
        for t in pending { t.cancel() }
        for t in pending { await t.value }
        #expect(waited < 0.5)
    }
    // X11: a cancelled refresh caller is not released until the shared refresh finishes.
    @Test func x11CancelledRefreshWaiter() async throws {
        let gate = CredentialRefreshGate(), probe = Probe(), context = owner(account: try identity()), reference = try CredentialReference("opaque-reference")
        try await gate.bind(context)
        let t = Task { try await gate.refresh(reference: reference, context: context) { _ = await probe.hold(); return reference } }
        #expect(await eventually { await probe.calls == 1 })
        t.cancel()
        try await Task.sleep(for: .milliseconds(200))
        let returnedBeforeRelease = await probe.active == 0
        await probe.release()
        var outcome = "ok"; do { _ = try await t.value } catch { outcome = "\(error)" }
        print("CRITIC X11 cancelled refresh caller still pending after 200 ms=\(!returnedBeforeRelease) outcome=\(outcome)")
    }
}
extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []; for e in self { out.append(try await transform(e)) }; return out
    }
}
