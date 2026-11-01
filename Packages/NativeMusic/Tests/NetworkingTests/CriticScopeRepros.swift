import Foundation
import Domain
import Testing
@testable import YouTubeMusicAdapter

// Temporary W07 Opus critic reproductions for the parent's requestGeneration-scope hypothesis. Removed after the run.
// Domain RequestGate is per feature: two features of one account may legitimately sit at different requestGenerations.
@Suite(.serialized) struct CriticScopeRepros {
    func ctx(_ account: AccountContext, accountGeneration: UInt64 = 1, query: UInt64) -> RequestContext {
        RequestContext(account: account, accountGeneration: accountGeneration, requestGeneration: query)
    }
    // Y1: per-feature BoundedNetworkClient owners (documented composition) are independent: a newer search generation
    // does not poison a library request. Expected to HOLD.
    @Test func y1PerFeatureClientsAreIndependent() async throws {
        let r = try route(), probe = Probe(), account = try identity(), scheduler = NetworkScheduler(interval: 0)
        let io = DirectBoundedTransport { _, _ in await probe.hold() }
        let library = BoundedNetworkClient(routes: [r], transport: io, scheduler: scheduler)
        let search = BoundedNetworkClient(routes: [r], transport: io, scheduler: scheduler)
        let lib = ctx(account, query: 2)
        try await library.bind(lib); try await search.bind(ctx(account, query: 6))
        let t = Task { try await library.send(request(r), context: lib, budget: RetryBudget(attempts: 1)) }
        #expect(await eventually { await probe.calls == 1 })
        try await search.bind(ctx(account, query: 7))
        await probe.release()
        var outcome = "ok"; do { _ = try await t.value } catch { outcome = "\(error)" }
        print("CRITIC Y1 library request after newer search generation on its own owner: \(outcome)")
        #expect(outcome == "ok")
    }
    // Y2: one SourceCache shared by two features. A newer search generation wipes and stale-fails the library read,
    // and the library's own (lower) generation can never bind again.
    @Test func y2SharedCacheIsPoisonedAcrossFeatures() async throws {
        let cache = SourceCache(), probe = Probe(), account = try identity()
        let policy = try SourceRetention(seconds: 600, freshness: .membership), resource = UUID()
        let lib = ctx(account, query: 2)
        try await cache.bind(lib)
        let t = Task { try await cache.read(resource: resource, context: lib, policy: policy, visible: true) { await probe.hold() } }
        #expect(await eventually { await probe.calls == 1 })
        try await cache.bind(ctx(account, query: 7))   // search feature advances its own generation
        await probe.release()
        var outcome = "ok"; do { _ = try await t.value } catch { outcome = "\(error)" }
        var rebind = "ok"; do { try await cache.bind(lib) } catch { rebind = "\(error)" }
        print("CRITIC Y2 shared cache: library read=\(outcome) library rebind=\(rebind)")
        #expect(outcome == "ok"); #expect(rebind == "ok")
    }
    // Y3: per-feature SourceCache instances (the only non-poisoning arrangement) cannot coalesce or share an identical
    // read for the same account/resource across features, because the key includes requestGeneration.
    @Test func y3PerFeatureCachesCannotCoalesceIdenticalReads() async throws {
        let probe = Probe(), account = try identity(), resource = UUID()
        let policy = try SourceRetention(seconds: 600, freshness: .stable)
        let home = SourceCache(), library = SourceCache()
        let h = ctx(account, query: 3), l = ctx(account, query: 1)
        try await home.bind(h); try await library.bind(l)
        let a = Task { try await home.read(resource: resource, context: h, policy: policy, visible: true) { await probe.hold() } }
        let b = Task { try await library.read(resource: resource, context: l, policy: policy, visible: true) { await probe.hold() } }
        _ = await eventually { await probe.calls == 2 }
        try await Task.sleep(for: .milliseconds(20))
        let loads = await probe.calls
        await probe.release(); _ = try await a.value; _ = try await b.value
        print("CRITIC Y3 identical account/resource read from two features: \(loads) loads")
        #expect(loads == 1)
    }
    // Y4: refresh gate. Shared: a newer generation from another feature cancels this feature's refresh.
    // Per-feature: the same credential reference is refreshed twice concurrently (no single flight).
    @Test func y4RefreshGateScope() async throws {
        let account = try identity(), reference = try CredentialReference("opaque-reference")
        let shared = CredentialRefreshGate(), probe = Probe()
        let lib = ctx(account, query: 2)
        try await shared.bind(lib)
        let t = Task { try await shared.refresh(reference: reference, context: lib) { _ = await probe.hold(); return reference } }
        #expect(await eventually { await probe.calls == 1 })
        try await shared.bind(ctx(account, query: 7))
        await probe.release()
        var outcome = "ok"; do { _ = try await t.value } catch { outcome = "\(error)" }
        let g1 = CredentialRefreshGate(), g2 = CredentialRefreshGate(), probe2 = Probe()
        let c1 = ctx(account, query: 2), c2 = ctx(account, query: 7)
        try await g1.bind(c1); try await g2.bind(c2)
        let x = Task { try await g1.refresh(reference: reference, context: c1) { _ = await probe2.hold(); return reference } }
        let y = Task { try await g2.refresh(reference: reference, context: c2) { _ = await probe2.hold(); return reference } }
        _ = await eventually { await probe2.calls == 2 }
        try await Task.sleep(for: .milliseconds(20))
        let performs = await probe2.calls
        await probe2.release(); _ = try? await x.value; _ = try? await y.value
        print("CRITIC Y4 shared gate: library refresh=\(outcome); per-feature gates: \(performs) concurrent refreshes of one reference")
        #expect(outcome == "ok"); #expect(performs == 1)
    }
    // Y5: account-generation invalidation is not global. Only owners the composition re-binds learn about the switch;
    // the shared scheduler admits a request from an older account generation after a newer one is in use.
    @Test func y5AccountGenerationIsNotAGlobalFence() async throws {
        let r = try route(), probe = Probe(), scheduler = NetworkScheduler(interval: 0)
        let io = DirectBoundedTransport { _, _ in await probe.record(); return .init(status: 200, body: Data()) }
        let a = try identity(), b = try identity()
        let library = BoundedNetworkClient(routes: [r], transport: io, scheduler: scheduler)
        let search = BoundedNetworkClient(routes: [r], transport: io, scheduler: scheduler)
        let oldLib = ctx(a, accountGeneration: 1, query: 4)
        try await library.bind(oldLib); try await search.bind(ctx(a, accountGeneration: 1, query: 9))
        try await search.bind(ctx(b, accountGeneration: 2, query: 0))  // account switch observed by one owner
        var outcome = "sent"
        do { _ = try await library.send(request(r), context: oldLib, budget: RetryBudget(attempts: 1)) } catch { outcome = "\(error)" }
        print("CRITIC Y5 old-account-generation library request after switch seen elsewhere: \(outcome), transport calls=\(await probe.calls)")
        #expect(outcome != "sent")
    }
}
