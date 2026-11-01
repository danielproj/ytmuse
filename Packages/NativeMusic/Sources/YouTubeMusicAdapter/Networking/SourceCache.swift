import Foundation
import Domain

public enum MetadataFreshness: Sendable {
    case dynamic, membership, stable
    var seconds: TimeInterval { switch self { case .dynamic: 300; case .membership: 900; case .stable: 86400 } }
}
public struct SourceRetention: Sendable {
    public let seconds: TimeInterval
    public let freshness: MetadataFreshness
    /// Retention must be established by the source policy. Zero forbids storage.
    public init(seconds: TimeInterval, freshness: MetadataFreshness) throws {
        guard seconds.isFinite, seconds >= 0, seconds <= 86400 * 30 else { throw NetworkFault.input }
        self.seconds = seconds; self.freshness = freshness
    }
}
public struct CacheRead: Sendable {
    public let context: RequestContext
    public let response: BoundedResponse
    public let stale: Bool
}
struct CachedNetworkValue: Sendable { let response: BoundedResponse; let stale: Bool }

/// Shared backing store; inject one coordinator for an isolated application/session or deterministic test clock.
/// Default facades share this coordinator, including separate feature facades (Y3).
public actor SourceCacheCoordinator {
    public static let shared = SourceCacheCoordinator()
    private struct Key: Hashable { let scope: NetworkAccountScope; let resource: UUID }
    private struct Entry { let response: BoundedResponse; let freshUntil: TimeInterval; let retainUntil: TimeInterval; let stored: TimeInterval }
    private struct Interest {
        let waiter: NetworkWaiter<BoundedResponse>; let policy: SourceRetention; let valid: @Sendable () -> Bool
    }
    private struct Flight {
        let id: UUID; let task: Task<Void, Never>
        var waiters: [UUID: Interest]
    }
    private var entries: [Key: Entry] = [:]
    private var flights: [Key: Flight] = [:]
    private let time: any NetworkTime
    private let maxBytes: Int
    private let maxEntries: Int
    public init(time: any NetworkTime = ContinuousNetworkTime(), maxBytes: Int = 16_000_000, maxEntries: Int = 256) {
        self.time = time; self.maxBytes = max(0, min(64_000_000, maxBytes)); self.maxEntries = max(0, min(1024, maxEntries))
    }
    func invalidate(scope: NetworkAccountScope, resource: UUID? = nil) {
        for key in Set(entries.keys).union(flights.keys) where key.scope == scope && (resource == nil || key.resource == resource) {
            entries[key] = nil
            if let flight = flights.removeValue(forKey: key) {
                flight.task.cancel(); for interest in flight.waiters.values { interest.waiter.resolve(.failure(NetworkFault.stale)) }
            }
        }
    }
    func invalidate(account: AccountContext) {
        for scope in Set(entries.keys.map(\.scope)).union(flights.keys.map(\.scope)) where scope.account == account { invalidate(scope: scope) }
    }
    public func invalidateAll() {
        for scope in Set(entries.keys.map(\.scope)).union(flights.keys.map(\.scope)) { invalidate(scope: scope) }
    }
    func cached(resource: UUID, scope: NetworkAccountScope) -> CachedNetworkValue? {
        prune()
        guard let entry = entries[Key(scope: scope, resource: resource)] else { return nil }
        return .init(response: entry.response, stale: time.now() >= entry.freshUntil)
    }
    func read(resource: UUID, scope: NetworkAccountScope, policy: SourceRetention, visible: Bool,
              valid: @escaping @Sendable () -> Bool, load: @escaping @Sendable () async throws -> BoundedResponse) async throws -> CachedNetworkValue? {
        try Task.checkCancellation()
        let key = Key(scope: scope, resource: resource)
        if let entry = entries[key] {
            if time.now() >= entry.stored + policy.seconds { entries[key] = nil }
            else { entries[key] = Entry(response: entry.response, freshUntil: min(entry.freshUntil, entry.stored + policy.freshness.seconds), retainUntil: min(entry.retainUntil, entry.stored + policy.seconds), stored: entry.stored) }
        }
        if let hit = cached(resource: resource, scope: scope), !hit.stale || !visible { return hit }
        guard visible else { return nil }
        guard flights[key] != nil || flights.count < 128 else { throw NetworkFault.rateLimited }
        let waiterID = UUID(), waiter = NetworkWaiter<BoundedResponse>()
        if var flight = flights[key] {
            flight.waiters[waiterID] = Interest(waiter: waiter, policy: policy, valid: valid)
            flights[key] = flight
        } else {
            let id = UUID()
            let task = Task {
                let result: Result<BoundedResponse, Error>
                do { result = .success(try await load()) } catch { result = .failure(DirectBoundedTransport.sanitize(error)) }
                self.complete(key, id: id, result: result)
            }
            flights[key] = Flight(id: id, task: task, waiters: [waiterID: Interest(waiter: waiter, policy: policy, valid: valid)])
        }
        do {
            let response = try await waiter.value { Task { await self.cancel(key, waiter: waiterID) } }
            try Task.checkCancellation()
            return .init(response: response, stale: false)
        } catch { throw DirectBoundedTransport.sanitize(error) }
    }
    func waiterCount(resource: UUID, context: RequestContext) -> Int { flights[Key(scope: NetworkAccountScope(context), resource: resource)]?.waiters.values.filter { $0.waiter.pending }.count ?? 0 }
    private func cancel(_ key: Key, waiter id: UUID) {
        guard var flight = flights[key] else { return }
        flight.waiters[id] = nil
        if flight.waiters.values.contains(where: { $0.waiter.pending }) { flights[key] = flight }
        else { flights[key] = nil; flight.task.cancel() }
    }
    private func complete(_ key: Key, id: UUID, result: Result<BoundedResponse, Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights[key] = nil
        let interested = flight.waiters.values.filter { $0.waiter.pending && $0.valid() }
        if !interested.isEmpty, case .success(let response) = result {
            store(response, key: key, retentionSeconds: interested.map { $0.policy.seconds }.min()!, freshnessSeconds: interested.map { $0.policy.freshness.seconds }.min()!)
        }
        for interest in flight.waiters.values {
            interest.waiter.resolve(interest.valid() ? result : .failure(NetworkFault.stale))
        }
    }
    private func prune() { entries = entries.filter { $0.value.retainUntil > time.now() } }
    private func store(_ response: BoundedResponse, key: Key, retentionSeconds: TimeInterval, freshnessSeconds: TimeInterval) {
        guard (200...299).contains(response.status) else { return }
        let directives = (response.cacheControl ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !directives.contains("no-store"), !directives.contains("no-cache"), retentionSeconds > 0 else { entries[key] = nil; return }
        var fresh = freshnessSeconds
        for directive in directives {
            if directive == "no-cache" { fresh = 0 }
            if directive.hasPrefix("max-age=") {
                let raw = directive.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                fresh = min(fresh, Double(raw).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0)
            }
        }
        let age = Double(response.age ?? "0").flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? retentionSeconds
        let retention = max(0, retentionSeconds - age)
        fresh = min(max(0, fresh - age), retention)
        if !directives.contains(where: { $0.hasPrefix("max-age=") }), let expires = response.expires {
            fresh = min(fresh, max(0, expires.timeIntervalSince(time.wallNow())))
        }
        let allowedRetention = directives.contains("must-revalidate") ? min(retention, fresh) : retention
        prune()
        guard response.body.count <= maxBytes, maxEntries > 0, allowedRetention > 0 else { return }
        entries[key] = Entry(response: response, freshUntil: time.now() + fresh, retainUntil: time.now() + allowedRetention, stored: time.now())
        while entries.count > maxEntries || entries.values.reduce(0, { $0 + $1.response.body.count }) > maxBytes {
            guard let oldest = entries.min(by: { $0.value.stored < $1.value.stored })?.key else { break }
            entries[oldest] = nil
        }
    }
}


/// A facade binds account ownership only. Query supersession is a caller's optional NetworkQueryToken.
public actor SourceCache {
    private let coordinator: SourceCacheCoordinator
    private let fence: NetworkAccountFence?
    private var scope: NetworkAccountScope?
    private let binding = NetworkAccountBinding()
    public init(coordinator: SourceCacheCoordinator = .shared, fence: NetworkAccountFence? = nil) {
        self.coordinator = coordinator; self.fence = fence
    }
    public init(time: any NetworkTime, maxBytes: Int = 16_000_000, maxEntries: Int = 256) {
        coordinator = SourceCacheCoordinator(time: time, maxBytes: maxBytes, maxEntries: maxEntries); fence = nil
    }
    public func bind(_ context: RequestContext) async throws {
        let next = NetworkAccountScope(context), old = scope
        if let old { guard next.generation > old.generation || next == old else { throw NetworkFault.stale } }
        try fence?.publish(context); scope = next; binding.set(next)
    }
    public func invalidate(resource: UUID, context: RequestContext) async {
        await coordinator.invalidate(scope: NetworkAccountScope(context), resource: resource)
    }
    public func invalidate(account: AccountContext? = nil) async {
        if let account { await coordinator.invalidate(account: account) }
        else if let scope { await coordinator.invalidate(scope: scope) }
    }
    public func cached(resource: UUID, context: RequestContext, caller: NetworkQueryToken? = nil) async -> CacheRead? {
        guard (try? validate(context, caller: caller)) != nil else { return nil }
        guard let hit = await coordinator.cached(resource: resource, scope: NetworkAccountScope(context)),
              (try? validate(context, caller: caller)) != nil else { return nil }
        return .init(context: context, response: hit.response, stale: hit.stale)
    }
    public func read(resource: UUID, context: RequestContext, policy: SourceRetention, visible: Bool,
                     caller: NetworkQueryToken? = nil,
                     load: @escaping @Sendable () async throws -> BoundedResponse) async throws -> CacheRead? {
        do {
            try Task.checkCancellation(); try validate(context, caller: caller)
            let fence = fence, binding = binding
            let value = try await coordinator.read(resource: resource, scope: NetworkAccountScope(context), policy: policy, visible: visible, valid: {
                do { try binding.validate(context); try fence?.validate(context); try caller?.validate(context); return true } catch { return false }
            }, load: load)
            try Task.checkCancellation(); try validate(context, caller: caller)
            return value.map { .init(context: context, response: $0.response, stale: $0.stale) }
        } catch { throw DirectBoundedTransport.sanitize(error) }
    }
    /// The shared producer gets an account-level context (query zero), independent of ALL consuming feature owners.
    /// Bind a separate account-load NetworkClient to this context; do not capture a feature-owned client in the producer.
    public func readShared(resource: UUID, context: RequestContext, policy: SourceRetention, visible: Bool,
                           caller: NetworkQueryToken? = nil,
                           load: @escaping @Sendable (RequestContext) async throws -> BoundedResponse) async throws -> CacheRead? {
        let producer = RequestContext(account: context.account, accountGeneration: context.accountGeneration, requestGeneration: 0)
        return try await read(resource: resource, context: context, policy: policy, visible: visible, caller: caller) { try await load(producer) }
    }
    private func validate(_ context: RequestContext, caller: NetworkQueryToken?) throws {
        guard scope == NetworkAccountScope(context) else { throw NetworkFault.stale }
        try fence?.validate(context); try caller?.validate(context)
    }
}
