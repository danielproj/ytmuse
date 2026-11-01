import Foundation
import Domain
import Testing
@testable import YouTubeMusicAdapter

final class ManualNetworkTime: NetworkTime, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = 0.0
    private var sleepers: [UUID: (Double, NetworkWaiter<Void>)] = [:]
    private var registrations = 0
    func now() -> Double { lock.withLock { instant } }
    func wallNow() -> Date { Date(timeIntervalSince1970: now()) }
    var sleepCount: Int { lock.withLock { registrations } }
    var sleeping: Int { lock.withLock { sleepers.count } }
    func sleep(until: Double) async throws {
        try Task.checkCancellation()
        let id = UUID(), waiter = NetworkWaiter<Void>()
        lock.withLock {
            registrations += 1
            if instant >= until { waiter.resolve(.success(())) } else { sleepers[id] = (until, waiter) }
        }
        try await waiter.value { self.lock.withLock { self.sleepers[id] = nil } }
    }
    func advance(_ seconds: Double) {
        let ready = lock.withLock {
            instant += seconds
            let ready = sleepers.filter { $0.value.0 <= instant }
            for id in ready.keys { sleepers[id] = nil }
            return ready.values.map { $0.1 }
        }
        for waiter in ready { waiter.resolve(.success(())) }
    }
}
actor ReworkResults {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
actor CancellationLoader {
    var started = false, cancelled = false
    func load() async throws -> BoundedResponse {
        started = true
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled = true; throw error }
        return .init(status: 200, body: Data())
    }
}

@Suite struct ReworkTests {
    @Test(arguments: [NetworkPurpose.metadata, .media])
    func cooledAndPacedBacklogsDoNotTakeTransferSlots(purpose: NetworkPurpose) async throws {
        let clock = ManualNetworkTime(), scheduler = NetworkScheduler(time: clock, interval: 1)
        let a = owner(account: try identity()), b = owner(account: try identity()), r = try route(purpose)
        let input = try BoundedRequest(route: r, url: request(r).url, bounds: ResponseBounds(seconds: 5))
        for cooled in [false, true] {
            if cooled { await scheduler.postpone(input, context: a, seconds: 2) }
            else { try await scheduler.acquire(input, context: a); await scheduler.release(input) }
            let pending = (0..<6).map { _ in Task { try await scheduler.acquire(input, context: a); await scheduler.release(input) } }
            #expect(await eventually { await scheduler.queuedCount == 6 })
            let counts = await scheduler.transferCounts
            #expect(counts.0 == 0 && counts.1 == 0)
            let brief = try BoundedRequest(route: r, url: input.url, bounds: ResponseBounds(seconds: 0.1))
            try await scheduler.acquire(brief, context: b); await scheduler.release(brief)
            for task in pending { task.cancel() }
            for task in pending { await #expect(throws: NetworkFault.cancelled) { try await task.value } }
            #expect(await eventually { await scheduler.queuedCount == 0 })
            clock.advance(5)
        }
    }
    @Test func admissionDeadlineCancellationAndFairReleaseUseNotifications() async throws {
        let clock = ManualNetworkTime(), scheduler = NetworkScheduler(time: clock, interval: 0), r = try route()
        let input = try request(r), context = owner(), results = ReworkResults()
        await scheduler.reduceUnderContention(metadata: 1, media: 1)
        try await scheduler.acquire(input, context: context)
        let brief = try BoundedRequest(route: r, url: input.url, bounds: ResponseBounds(seconds: 0.5))
        let expired = Task { try await scheduler.acquire(brief, context: context) }
        #expect(await eventually { await scheduler.queuedCount == 1 && clock.sleeping > 0 })
        clock.advance(0.5)
        await #expect(throws: NetworkFault.timeout) { try await expired.value }
        let cancelled = Task { try await scheduler.acquire(input, context: context) }
        #expect(await eventually { await scheduler.queuedCount == 1 }); cancelled.cancel()
        await #expect(throws: NetworkFault.cancelled) { try await cancelled.value }
        #expect(await eventually { await scheduler.queuedCount == 0 })
        var tasks: [Task<Void, Error>] = []
        for i in 0..<3 {
            tasks.append(Task {
                try await scheduler.acquire(input, context: context)
                await results.append(String(i)); await scheduler.release(input)
            })
            #expect(await eventually { await scheduler.queuedCount == i + 1 })
        }
        let before = clock.sleepCount
        // No clock advance or periodic wakeup is needed to hand off all three ready requests.
        await scheduler.release(input)
        for task in tasks { try await task.value }
        #expect(await results.values == ["0", "1", "2"])
        #expect(clock.sleepCount - before <= 3)
    }
    @Test func resourceAndOtherAccountInvalidationLeaveR2LoadingAndCaching() async throws {
        let coordinator = SourceCacheCoordinator(), cache = SourceCache(coordinator: coordinator)
        let context = owner(account: try identity()), other = try identity(), probe = Probe()
        let r1 = UUID(), r2 = UUID(), policy = try SourceRetention(seconds: 600, freshness: .stable)
        try await cache.bind(context)
        _ = try await cache.read(resource: r1, context: context, policy: policy, visible: true) { .init(status: 200, body: Data([1])) }
        let task = Task { try await cache.read(resource: r2, context: context, policy: policy, visible: true) { await probe.hold() } }
        #expect(await eventually { await probe.calls == 1 })
        await cache.invalidate(resource: r1, context: context); await cache.invalidate(account: other)
        await probe.release()
        #expect(try await task.value?.context == context)
        #expect(await cache.cached(resource: r1, context: context) == nil)
        #expect(await cache.cached(resource: r2, context: context) != nil)
    }
    @Test(arguments: [false, true]) func cancelledCachePeerCannotPoisonStore(cancelCreator: Bool) async throws {
        let coordinator = SourceCacheCoordinator(), cache = SourceCache(coordinator: coordinator), context = owner(account: try identity())
        let probe = Probe(), results = ReworkResults(), resource = UUID(), policy = try SourceRetention(seconds: 600, freshness: .stable)
        try await cache.bind(context)
        func start() -> Task<CacheRead?, Error> {
            Task {
                do { return try await cache.read(resource: resource, context: context, policy: policy, visible: true) { await probe.hold() } }
                catch { await results.append(String(describing: error)); throw error }
            }
        }
        let first = start()
        #expect(await eventually { await coordinator.waiterCount(resource: resource, context: context) == 1 })
        let second = start()
        #expect(await eventually { await coordinator.waiterCount(resource: resource, context: context) == 2 })
        let abandoned = cancelCreator ? first : second, valid = cancelCreator ? second : first
        abandoned.cancel()
        #expect(await eventually { await results.values == ["cancelled"] })
        #expect(await probe.calls == 1)
        await probe.release()
        await #expect(throws: NetworkFault.cancelled) { try await abandoned.value }
        #expect(try await valid.value?.context == context)
        #expect(await cache.cached(resource: resource, context: context) != nil)
    }
    @Test func soleAbandonedReadCancelsLoaderAndReleasesTransferPermit() async throws {
        let context = owner(account: try identity()), loader = CancellationLoader(), scheduler = NetworkScheduler(interval: 0)
        let r = try route(), coordinator = SourceCacheCoordinator(), cache = SourceCache(coordinator: coordinator)
        let client = BoundedNetworkClient(routes: [r], transport: DirectBoundedTransport { _, _ in try await loader.load() }, scheduler: scheduler)
        try await client.bind(context); try await cache.bind(context)
        let task = Task { try await cache.read(resource: UUID(), context: context, policy: SourceRetention(seconds: 600, freshness: .stable), visible: true) {
            try await client.send(request(r), context: context, budget: RetryBudget(attempts: 1))
        } }
        #expect(await eventually { await loader.started }); task.cancel()
        await #expect(throws: NetworkFault.cancelled) { try await task.value }
        #expect(await eventually { await loader.cancelled })
        #expect(await eventually { await scheduler.transferCounts.0 == 0 })
    }
    @Test func sharedFeaturesCoalesceRebindResponsesAndStaleOnlyTheirOwnQueryToken() async throws {
        let coordinator = SourceCacheCoordinator(), fence = NetworkAccountFence(), account = try identity(), resource = UUID(), probe = Probe()
        let library = SourceCache(coordinator: coordinator, fence: fence), search = SourceCache(coordinator: coordinator, fence: fence)
        let lib = owner(query: 2, account: account), query = owner(query: 7, account: account)
        let libOwner = NetworkQueryOwner(), searchOwner = NetworkQueryOwner()
        let libToken = try libOwner.bind(lib), searchToken = try searchOwner.bind(query)
        let policy = try SourceRetention(seconds: 600, freshness: .membership)
        try await library.bind(lib); try await search.bind(query)
        let first = Task { try await library.read(resource: resource, context: lib, policy: policy, visible: true, caller: libToken) { await probe.hold() } }
        #expect(await eventually { await probe.calls == 1 })
        let second = Task { try await search.read(resource: resource, context: query, policy: policy, visible: true, caller: searchToken) { await probe.hold() } }
        #expect(await eventually { await coordinator.waiterCount(resource: resource, context: lib) == 2 })
        let next = owner(query: 3, account: account), token = try libOwner.bind(next)
        try await library.bind(next) // must not invalidate search or the shared flight
        await probe.release()
        await #expect(throws: NetworkFault.stale) { try await first.value }
        #expect(try await second.value?.context == query)
        #expect(await library.cached(resource: resource, context: next, caller: token)?.context == next)
        #expect(await probe.calls == 1)
    }
    @Test(arguments: [false, true]) func refreshWaitersCancelIndependentlyAndRebind(cancelCreator: Bool) async throws {
        let coordinator = CredentialRefreshCoordinator(), a = CredentialRefreshGate(coordinator: coordinator), b = CredentialRefreshGate(coordinator: coordinator)
        let account = try identity(), x = owner(query: 2, account: account), y = owner(query: 7, account: account)
        let reference = try CredentialReference("opaque-reference"), probe = Probe(), results = ReworkResults()
        try await a.bind(x); try await b.bind(y)
        func start(_ gate: CredentialRefreshGate, _ context: RequestContext) -> Task<CredentialRefreshResult, Error> {
            Task {
                do { return try await gate.refreshScoped(reference: reference, context: context) { _ = await probe.hold(); return reference } }
                catch { await results.append(String(describing: error)); throw error }
            }
        }
        let first = start(a, x)
        #expect(await eventually { await coordinator.waiterCount(reference: reference, context: x) == 1 })
        let second = start(b, y)
        #expect(await eventually { await coordinator.waiterCount(reference: reference, context: y) == 2 })
        let abandoned = cancelCreator ? first : second, valid = cancelCreator ? second : first
        abandoned.cancel()
        #expect(await eventually { await results.values == ["cancelled"] })
        await probe.release()
        await #expect(throws: NetworkFault.cancelled) { try await abandoned.value }
        let reply = try await valid.value
        #expect(reply.reference == reference && reply.context == (cancelCreator ? y : x))
        #expect(await probe.calls == 1)
    }
    @Test func soleRefreshCancellationAndBoundedOwnedFinalizationAreExplicit() async throws {
        let reference = try CredentialReference("opaque-reference"), context = owner(account: try identity()), loader = CancellationLoader()
        let gate = CredentialRefreshGate(coordinator: CredentialRefreshCoordinator())
        try await gate.bind(context)
        let first = Task { try await gate.refresh(reference: reference, context: context) { _ = try await loader.load(); return reference } }
        #expect(await eventually { await loader.started }); first.cancel()
        await #expect(throws: NetworkFault.cancelled) { try await first.value }
        #expect(await eventually { await loader.cancelled })
        let clock = ManualNetworkTime(), probe = Probe()
        let coordinator = try CredentialRefreshCoordinator(ownedFinalizationSeconds: 2, time: clock)
        let owned = CredentialRefreshGate(coordinator: coordinator)
        try await owned.bind(context)
        let abandoned = Task { try await owned.refresh(reference: reference, context: context) { _ = await probe.hold(); return reference } }
        #expect(await eventually { await probe.calls == 1 && clock.sleeping > 0 }); abandoned.cancel()
        await #expect(throws: NetworkFault.cancelled) { try await abandoned.value }
        clock.advance(2)
        #expect(await eventually { await coordinator.isExpired(reference: reference, context: context) })
        await #expect(throws: NetworkFault.timeout) { try await owned.refresh(reference: reference, context: context) { Issue.record("overlapping rotation"); return reference } }
        await owned.invalidate(); try await owned.bind(owner(2)); await probe.release()
        await #expect(throws: NetworkFault.stale) { try await owned.refresh(reference: reference, context: context) { Issue.record("removed credential resurrected"); return reference } }
    }
    @Test func sharedFenceRejectsForgottenOwnerAtAdmissionAndCompletion() async throws {
        let fence = NetworkAccountFence(), scheduler = NetworkScheduler(interval: 0, fence: fence), probe = Probe(), r = try route()
        let io = DirectBoundedTransport { _, _ in await probe.hold() }
        let a = BoundedNetworkClient(routes: [r], transport: io, scheduler: scheduler), b = BoundedNetworkClient(routes: [r], transport: io, scheduler: scheduler)
        let old = owner(account: try identity()), next = owner(2, account: try identity())
        try await a.bind(old)
        let task = Task { try await a.send(request(r), context: old, budget: RetryBudget(attempts: 1)) }
        #expect(await eventually { await probe.calls == 1 })
        try await b.bind(next); await probe.release()
        await #expect(throws: NetworkFault.stale) { try await task.value }
        await #expect(throws: NetworkFault.stale) { try await a.send(request(r), context: old, budget: RetryBudget(attempts: 1)) }
        #expect(await probe.calls == 1)
    }
    @Test func meaningfulRetryAfterIsNotShortenedAndImplausibleCooldownExpires() async throws {
        let clock = ManualNetworkTime(), scheduler = NetworkScheduler(time: clock, interval: 0), r = try route(), context = owner()
        let input = try request(r)
        await scheduler.postpone(input, context: context, seconds: 600)
        clock.advance(300)
        await #expect(throws: RateLimitBound(retryAfterSeconds: 300)) { try await scheduler.acquire(input, context: context) }
        clock.advance(300)
        try await scheduler.acquire(input, context: context); await scheduler.release(input)
        await scheduler.postpone(input, context: context, seconds: 315360000)
        await #expect(throws: RateLimitBound(retryAfterSeconds: 315360000)) { try await scheduler.acquire(input, context: context) }
        clock.advance(NetworkScheduler.cooldownHorizon)
        try await scheduler.acquire(input, context: context); await scheduler.release(input)
    }
}

private final class CleanupProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var starts = 0
    nonisolated(unsafe) private static var stops = 0
    static var counts: (Int, Int) { lock.withLock { (starts, stops) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "music.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.starts += 1 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    }
    override func stopLoading() { Self.lock.withLock { Self.stops += 1 } }
}
extension ReworkTests {
    @Test func explicitSessionCleanupStopsTransferAndRejectsReuse() async throws {
        let io = DirectBoundedTransport(protocolClasses: [CleanupProtocol.self]), r = try route()
        let task = Task { try await io.send(request(r), authorization: nil) }
        #expect(await eventually { CleanupProtocol.counts.0 == 1 })
        io.shutdown(); io.shutdown() // idempotent; does not affect any other transport
        await #expect(throws: NetworkFault.cancelled) { try await task.value }
        #expect(await eventually { CleanupProtocol.counts.1 == 1 })
        await #expect(throws: NetworkFault.cancelled) { try await io.send(request(r), authorization: nil) }
        #expect(CleanupProtocol.counts.0 == 1)
    }
    @Test func accountProducerSurvivesQuerySupersessionAndInvalidPeerCannotSuppressCaching() async throws {
        let account = try identity(), x = owner(query: 2, account: account), y = owner(query: 7, account: account)
        let producer = owner(query: 0, account: account), scheduler = NetworkScheduler(interval: 0), r = try route(), probe = Probe()
        let client = BoundedNetworkClient(routes: [r], transport: DirectBoundedTransport { _, _ in await probe.hold() }, scheduler: scheduler)
        let coordinator = SourceCacheCoordinator(), cache = SourceCache(coordinator: coordinator, fence: scheduler.fence), resource = UUID()
        let queryOwner = NetworkQueryOwner(), token = try queryOwner.bind(x)
        try await client.bind(producer); try await cache.bind(x)
        let first = Task { try await cache.readShared(resource: resource, context: x, policy: SourceRetention(seconds: 0, freshness: .dynamic), visible: true, caller: token) { shared in
            #expect(shared == producer); return try await client.send(request(r), context: shared, budget: RetryBudget(attempts: 1))
        } }
        #expect(await eventually { await probe.calls == 1 })
        let second = Task { try await cache.readShared(resource: resource, context: y, policy: SourceRetention(seconds: 600, freshness: .stable), visible: true) { _ in
            Issue.record("shared resource loaded twice"); return .init(status: 200, body: Data())
        } }
        #expect(await eventually { await coordinator.waiterCount(resource: resource, context: y) == 2 })
        _ = try queryOwner.bind(owner(query: 3, account: account))
        await probe.release()
        await #expect(throws: NetworkFault.stale) { try await first.value }
        #expect(try await second.value?.context == y)
        #expect(await cache.cached(resource: resource, context: y) != nil)
        #expect(await probe.calls == 1)
    }
}

extension ReworkTests {
    @Test func movingOneFacadeDoesNotGloballyCancelAnotherAccountOwner() async throws {
        let coordinator = SourceCacheCoordinator(), a = SourceCache(coordinator: coordinator), b = SourceCache(coordinator: coordinator)
        let old = owner(account: try identity()), next = owner(2, account: try identity()), probe = Probe(), resource = UUID()
        try await a.bind(old); try await b.bind(old)
        let pending = Task { try await b.read(resource: resource, context: old, policy: SourceRetention(seconds: 600, freshness: .stable), visible: true) { await probe.hold() } }
        #expect(await eventually { await probe.calls == 1 })
        try await a.bind(next) // deliberate background owner b is not tied to a's active-session fence
        await probe.release()
        #expect(try await pending.value?.context == old)
        #expect(await b.cached(resource: resource, context: old) != nil)
        #expect(await a.cached(resource: resource, context: old) == nil)
    }
}

extension ReworkTests {
    @Test func sharedFenceAlsoRejectsLateCacheAndRefreshPublications() async throws {
        let fence = NetworkAccountFence(), context = owner(account: try identity()), next = owner(2, account: try identity())
        let coordinator = SourceCacheCoordinator(), cache = SourceCache(coordinator: coordinator, fence: fence)
        let refresh = CredentialRefreshGate(coordinator: CredentialRefreshCoordinator(), fence: fence), reference = try CredentialReference("opaque-reference")
        let data = Probe(), credential = Probe(), resource = UUID()
        try await cache.bind(context); try await refresh.bind(context)
        let read = Task { try await cache.read(resource: resource, context: context, policy: SourceRetention(seconds: 600, freshness: .stable), visible: true) { await data.hold() } }
        let rotated = Task { try await refresh.refreshScoped(reference: reference, context: context) { _ = await credential.hold(); return reference } }
        #expect(await eventually { await data.calls == 1 })
        #expect(await eventually { await credential.calls == 1 })
        try fence.publish(next)
        await data.release(); await credential.release()
        await #expect(throws: NetworkFault.stale) { try await read.value }
        await #expect(throws: NetworkFault.stale) { try await rotated.value }
        #expect(await cache.cached(resource: resource, context: context) == nil)
        try await refresh.bind(next)
        #expect(try await refresh.refreshScoped(reference: reference, context: next) { reference }.context == next)
    }
}
