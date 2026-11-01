import Foundation
import Domain
import Testing
@testable import YouTubeMusicAdapter

@Suite struct RetryTests {
    @Test(arguments: [401, 403, 429, 500, 503]) func typedStatusAndNoAuthLoop(status: Int) async throws {
        let r = try route(), clock = TestTime(), probe = Probe()
        let client = BoundedNetworkClient(routes: [r], transport: DirectBoundedTransport { _, _ in
            await probe.record(clock.now()); return .init(status: status, body: Data(), retryAfter: status == 429 ? "600" : nil)
        }, scheduler: NetworkScheduler(time: clock, interval: 0), time: clock, jitter: { 0.5 })
        try await client.bind(owner())
        do { _ = try await client.send(request(r), context: owner(), budget: RetryBudget()); Issue.record("expected error") }
        catch {
            if status == 429 { #expect((error as? RateLimitBound)?.retryAfterSeconds == 600); #expect(clock.now() == 0) }
            else { #expect(error as? NetworkFault == (status == 401 ? .authentication : status == 403 ? .forbidden : .server)) }
        }
        #expect(await probe.calls == (status == 401 || status == 403 || status == 429 ? 1 : 3))
        if status == 500 { #expect(await probe.times == [0, 1, 3]) }
        if status == 429 {
            await #expect(throws: RateLimitBound(retryAfterSeconds: 600)) {
                try await client.send(request(r), context: owner(), budget: RetryBudget())
            }
            #expect(await probe.calls == 1)
        }
    }
    @Test(arguments: [ReplaySafety.mutation, .unknown]) func postIsNotRetrySafe(replay: ReplaySafety) async throws {
        let r = try route(replay: replay), probe = Probe()
        let client = BoundedNetworkClient(routes: [r], transport: DirectBoundedTransport { _, _ in
            await probe.record(); throw URLError(.timedOut)
        }, scheduler: NetworkScheduler(interval: 0))
        try await client.bind(owner())
        await #expect(throws: NetworkFault.timeout) { try await client.send(request(r), context: owner(), budget: RetryBudget()) }
        #expect(await probe.calls == 1)
    }
    @Test func retryAfterDateAndBudgetAreHonored() async throws {
        #expect(BoundedNetworkClient.retryAfter("Thu, 01 Jan 1970 00:00:10 GMT", now: Date(timeIntervalSince1970: 0)) == 10)
        #expect(BoundedNetworkClient.retryAfter("-2", now: Date()) == nil)
        #expect(BoundedNetworkClient.retryAfter(String(repeating: "9", count: 512), now: Date()) == .greatestFiniteMagnitude)
        let r = try route(), clock = TestTime(), probe = Probe()
        let client = BoundedNetworkClient(routes: [r], transport: DirectBoundedTransport { _, _ in
            await probe.record(clock.now()); return .init(status: await probe.calls == 1 ? 429 : 200, body: Data(), retryAfter: "4")
        }, scheduler: NetworkScheduler(time: clock, interval: 0), time: clock, jitter: { 0 })
        try await client.bind(owner())
        _ = try await client.send(request(r), context: owner(), budget: RetryBudget())
        #expect(await probe.times == [0, 4])
    }
    @Test func wireErrorsAreUnconditionallyRedacted() async throws {
        let privateText = "https://music.example.test/read?q=private-synthetic-query&token=synthetic-secret"
        let cases: [(URLError.Code, NetworkFault)] = [(.cannotFindHost, .dns), (.notConnectedToInternet, .offline), (.timedOut, .timeout), (.secureConnectionFailed, .transport)]
        for (code, expected) in cases {
            let r = try route(), probe = Probe()
            let client = BoundedNetworkClient(routes: [r], transport: DirectBoundedTransport { _, _ in
                await probe.record(); throw NSError(domain: NSURLErrorDomain, code: code.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: privateText, NSURLErrorFailingURLStringErrorKey: privateText])
            }, scheduler: NetworkScheduler(interval: 0))
            try await client.bind(owner())
            do { _ = try await client.send(request(r), context: owner(), budget: RetryBudget(attempts: 1)); Issue.record("missing fault") }
            catch {
                #expect(error as? NetworkFault == expected)
                let log = NetworkDiagnostic(id: UUID(), fault: DirectBoundedTransport.sanitize(error)).description
                #expect(!log.contains("private") && !log.contains("secret") && !log.contains("https") && !log.contains("?"))
            }
            #expect(await probe.calls == 1)
        }
    }
}
