import Foundation
import Testing
import Domain
@testable import YouTubeMusicAdapter

@Suite struct TransportTests {
    @Test func exactPolicyAndProtectedReferences() async throws {
        let r = try route(), probe = Probe()
        let io = DirectBoundedTransport { _, _ in await probe.record(); return .init(status: 200, body: Data()) }
        let client = BoundedNetworkClient(routes: [r], transport: io, scheduler: NetworkScheduler(interval: 0))
        try await client.bind(owner())
        _ = try await client.send(request(r), context: owner(), budget: RetryBudget())
        #expect(await probe.calls == 1)
        for url in ["http://music.example.test/read", "https://music.example.test:443/read", "https://evil.test/read", "https://music.example.test/reader", "https://u:p@music.example.test/read", "https://music.example.test/read#x", "https://music.example.test/read?token=secret", "https://music.example.test/%72ead"] {
            #expect(throws: NetworkFault.policy) { try BoundedRequest(route: r, url: URL(string: url)!, bounds: ResponseBounds()) }
        }
        #expect(throws: NetworkFault.policy) { try request(r, credential: CredentialReference("protected-reference")) }
        let other = try route(.media)
        await #expect(throws: NetworkFault.policy) { try await client.send(request(other), context: owner(), budget: RetryBudget()) }
        #expect(await probe.calls == 1)
        let c = DirectBoundedTransport.configuration()
        #expect(c.httpCookieStorage == nil && c.urlCredentialStorage == nil && c.urlCache == nil && !c.httpShouldSetCookies)
    }
    @Test func streamingStopsAtCapPlusOneAndCancellation() async throws {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let bytes = AsyncStream<UInt8>(unfolding: { counter.value += 1; return 1 })
        await #expect(throws: NetworkFault.oversized) { try await DirectBoundedTransport.collect(bytes, expected: -1, limit: 16) }
        #expect(counter.value == 17)
        let exact = AsyncStream<UInt8> { c in for _ in 0..<16 { c.yield(1) }; c.finish() }
        #expect(try await DirectBoundedTransport.collect(exact, expected: 16, limit: 16).count == 16)
        let never = AsyncStream<UInt8>(unfolding: { counter.value += 1; return 1 })
        await #expect(throws: NetworkFault.oversized) { try await DirectBoundedTransport.collect(never, expected: 17, limit: 16) }
        #expect(counter.value == 17)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await DirectBoundedTransport.collect(never, expected: -1, limit: 16) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func redirectsAndResponseLimitsAreNeverBypassedBySeam() async throws {
        let r = try route()
        for status in [301, 302, 307, 308] {
            let io = DirectBoundedTransport { _, _ in .init(status: status, body: Data()) }
            await #expect(throws: NetworkFault.redirect) { try await io.send(request(r), authorization: nil) }
        }
        let io = DirectBoundedTransport { _, _ in .init(status: 200, body: Data(repeating: 0, count: 1025)) }
        await #expect(throws: NetworkFault.oversized) { try await io.send(request(r), authorization: nil) }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://music.example.test/read")!)
        let redirect = HTTPURLResponse(url: URL(string: "https://music.example.test/read")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        #expect(await RejectNetworkRedirect().urlSession(session, task: task, willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: URL(string: "https://evil.test")!)) == nil)
    }
    @Test(arguments: [(NetworkPurpose.metadata, 6), (.media, 2), (.metadata, 3), (.media, 1)])
    func globalConcurrencyMeasured(purpose: NetworkPurpose, limit: Int) async throws {
        let r = try route(purpose), probe = Probe(), scheduler = NetworkScheduler(interval: 0)
        await scheduler.reduceUnderContention(metadata: purpose == .metadata ? limit : 6, media: purpose == .media ? limit : 2)
        let client = BoundedNetworkClient(routes: [r], transport: DirectBoundedTransport { _, _ in await probe.hold() }, scheduler: scheduler)
        try await client.bind(owner())
        let tasks = (0..<12).map { _ in Task { try await client.send(request(r), context: owner(), budget: RetryBudget(attempts: 1)) } }
        #expect(await eventually { await probe.calls == limit })
        #expect(await probe.peak == limit)
        for _ in 0..<200 {
            await probe.release()
            if await probe.finished(12) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let complete = await probe.finished(12)
        #expect(complete)
        if !complete { for task in tasks { task.cancel() }; await probe.release() }
        for task in tasks { _ = try await task.value }
        #expect(await probe.calls == 12); #expect(await probe.peak == limit)
    }
    @Test func pacingIsScopedToAccountChannelRegionAndHost() async throws {
        let clock = TestTime(), r = try route(), scheduler = NetworkScheduler(time: clock, interval: 1), probe = Probe()
        let io = DirectBoundedTransport { _, _ in await probe.record(clock.now()); return .init(status: 200, body: Data()) }
        let a = try identity(), b = try identity("other", id: a.accountID), c = try identity(region: "GB", id: a.accountID)
        for (i, account) in [a, a, b, c].enumerated() {
            let ctx = owner(UInt64(i + 1), account: account)
            let client = BoundedNetworkClient(routes: [r], transport: io, scheduler: scheduler)
            try await client.bind(ctx)
            _ = try await client.send(request(r), context: ctx, budget: RetryBudget())
        }
        #expect(await probe.times == [0, 1, 1, 1])
    }
    @Test func invalidationCancelsAndRejectsUncooperativeLateSuccess() async throws {
        let r = try route(), probe = Probe()
        let client = BoundedNetworkClient(routes: [r], transport: DirectBoundedTransport { _, _ in await probe.hold() }, scheduler: NetworkScheduler(interval: 0))
        try await client.bind(owner())
        let task = Task { try await client.send(request(r), context: owner(), budget: RetryBudget()) }
        #expect(await eventually { await probe.calls == 1 })
        try await client.bind(owner(2))
        await probe.release()
        await #expect(throws: NetworkFault.stale) { try await task.value }
        await #expect(throws: NetworkFault.stale) { try await client.bind(owner()) }
        await #expect(throws: NetworkFault.stale) { try await client.bind(owner(2, account: identity())) }
    }
    @Test func callerCancellationPropagates() async throws {
        let r = try route(), probe = Probe()
        let client = BoundedNetworkClient(routes: [r], transport: DirectBoundedTransport { _, _ in await probe.hold() }, scheduler: NetworkScheduler(interval: 0))
        try await client.bind(owner())
        let task = Task { try await client.send(request(r), context: owner(), budget: RetryBudget()) }
        #expect(await eventually { await probe.calls == 1 }); task.cancel(); await probe.release()
        await #expect(throws: NetworkFault.cancelled) { try await task.value }
    }
}

private actor SyntheticCredentials: ScopedNetworkCredentials {
    let expected: RequestContext
    var calls = 0
    init(expected: RequestContext) { self.expected = expected }
    func authorization(reference: CredentialReference, context: RequestContext) async throws -> String {
        #expect(context == expected && reference.rawValue == "protected-reference")
        calls += 1
        return "Bearer synthetic-credential-value"
    }
}
extension TransportTests {
    @Test func credentialsAreScopedAndDebugCaptureContainsNoWireText() async throws {
        let context = owner(account: try identity()), vault = SyntheticCredentials(expected: context), probe = Probe()
        let r = try NetworkRoute(host: "music.example.test", path: "/read", method: "POST", purpose: .metadata,
                                 queryNames: ["q"], credentialAllowed: true, replay: .knownRead)
        let input = try request(r, credential: CredentialReference("protected-reference"))
        let io = DirectBoundedTransport { wire, _ in
            #expect(wire.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-credential-value")
            #expect(wire.value(forHTTPHeaderField: "Cookie") == nil)
            await probe.record()
            return .init(status: 200, body: Data("synthetic-private-playlist-name".utf8))
        }
        let client = BoundedNetworkClient(routes: [r], transport: io, scheduler: NetworkScheduler(interval: 0), credentials: vault)
        try await client.bind(context)
        let envelope = await client.sendEnvelope(input, context: context, budget: try RetryBudget())
        #expect(envelope.context == context)
        let body = try envelope.outcome.get()
        #expect(body.body == Data("synthetic-private-playlist-name".utf8))
        let capture = String(describing: input) + String(reflecting: input) + String(describing: body) + String(reflecting: body) + String(reflecting: envelope)
        #expect(!capture.contains("private") && !capture.contains("credential") && !capture.contains("https") && !capture.contains("?"))
        try await client.bind(owner(2))
        let stale = await client.sendEnvelope(input, context: context, budget: try RetryBudget())
        #expect(stale.context == context)
        #expect(throws: NetworkIssue(fault: .stale)) { try stale.outcome.get() }
        #expect(await vault.calls == 1)
        #expect(await probe.calls == 1)
    }
}

extension TransportTests {
    @Test func admissionHasAnAbsoluteDeadlineAndCooldownIsAccountScoped() async throws {
        let clock = TestTime(), scheduler = NetworkScheduler(time: clock, interval: 0), r = try route()
        let a = owner(account: try identity()), b = owner(account: try identity())
        await scheduler.reduceUnderContention(metadata: 1, media: 1)
        let input = try request(r)
        try await scheduler.acquire(input, context: a)
        let brief = try BoundedRequest(route: r, url: input.url, bounds: ResponseBounds(seconds: 0.05))
        await #expect(throws: NetworkFault.timeout) { try await scheduler.acquire(brief, context: a) }
        await scheduler.release(input)
        await scheduler.postpone(input, context: a, seconds: 600)
        await #expect(throws: RateLimitBound(retryAfterSeconds: 600)) { try await scheduler.acquire(input, context: a) }
        try await scheduler.acquire(input, context: b)
        await scheduler.release(input)
    }
}
