import Foundation
import Domain

public struct CredentialRefreshResult: Sendable {
    public let context: RequestContext
    public let reference: CredentialReference
}
/// Shared by credential scope, never by a feature's query generation.
public actor CredentialRefreshCoordinator {
    public static let shared = CredentialRefreshCoordinator()
    private struct Key: Hashable { let scope: NetworkAccountScope; let reference: CredentialReference }
    private struct Flight {
        let id: UUID; let task: Task<Void, Never>; let deadline: Task<Void, Never>?
        var waiters: [UUID: NetworkWaiter<CredentialReference>]; var expired = false
    }
    private var flights: [Key: Flight] = [:]
    private let finalizationSeconds: TimeInterval?
    private let time: any NetworkTime
    /// Suitable only for cancellation-safe refresh providers. No real rotating credential provider is installed here.
    public init() { finalizationSeconds = nil; time = ContinuousNetworkTime() }
    /// An explicitly owned rotating provider may finish protected retention after callers abandon their waits.
    /// It must atomically fence its own protected-store commit; this coordinator only publishes references.
    public init(ownedFinalizationSeconds: TimeInterval, time: any NetworkTime = ContinuousNetworkTime()) throws {
        guard ownedFinalizationSeconds.isFinite, ownedFinalizationSeconds > 0, ownedFinalizationSeconds <= 120 else { throw NetworkFault.input }
        finalizationSeconds = ownedFinalizationSeconds; self.time = time
    }
    func invalidate(scope: NetworkAccountScope) {
        for key in flights.keys where key.scope == scope {
            guard let flight = flights.removeValue(forKey: key) else { continue }
            flight.task.cancel(); flight.deadline?.cancel()
            for waiter in flight.waiters.values { waiter.resolve(.failure(NetworkFault.stale)) }
        }
    }
    func invalidate(account: AccountContext) {
        for scope in Set(flights.keys.map(\.scope)) where scope.account == account { invalidate(scope: scope) }
    }
    public func invalidateAll() { for scope in Set(flights.keys.map(\.scope)) { invalidate(scope: scope) } }
    func refresh(reference: CredentialReference, scope: NetworkAccountScope,
                 perform: @escaping @Sendable () async throws -> CredentialReference) async throws -> CredentialReference {
        try Task.checkCancellation()
        let key = Key(scope: scope, reference: reference), waiterID = UUID(), waiter = NetworkWaiter<CredentialReference>()
        guard flights[key]?.expired != true else { throw NetworkFault.timeout }
        guard flights[key] != nil || flights.count < 128 else { throw NetworkFault.rateLimited }
        if var flight = flights[key] { flight.waiters[waiterID] = waiter; flights[key] = flight }
        else {
            let id = UUID()
            let task = Task {
                let result: Result<CredentialReference, Error>
                do { result = .success(try await perform()) } catch { result = .failure(DirectBoundedTransport.sanitize(error)) }
                self.complete(key, id: id, result: result)
            }
            let deadline: Task<Void, Never>?
            if let seconds = finalizationSeconds {
                let until = time.now() + seconds, time = time
                deadline = Task {
                    do { try await time.sleep(until: until); try Task.checkCancellation(); self.expire(key, id: id) } catch { }
                }
            } else { deadline = nil }
            flights[key] = Flight(id: id, task: task, deadline: deadline, waiters: [waiterID: waiter])
        }
        do {
            let reference = try await waiter.value { Task { await self.cancel(key, waiter: waiterID) } }
            try Task.checkCancellation(); return reference
        } catch { throw DirectBoundedTransport.sanitize(error) }
    }
    func waiterCount(reference: CredentialReference, context: RequestContext) -> Int { flights[Key(scope: NetworkAccountScope(context), reference: reference)]?.waiters.values.filter { $0.pending }.count ?? 0 }
    func isExpired(reference: CredentialReference, context: RequestContext) -> Bool { flights[Key(scope: NetworkAccountScope(context), reference: reference)]?.expired == true }
    private func cancel(_ key: Key, waiter id: UUID) {
        guard var flight = flights[key] else { return }
        flight.waiters[id] = nil
        if finalizationSeconds != nil || flight.waiters.values.contains(where: { $0.pending }) { flights[key] = flight }
        else { flights[key] = nil; flight.task.cancel() }
    }
    private func complete(_ key: Key, id: UUID, result: Result<CredentialReference, Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights[key] = nil; flight.deadline?.cancel()
        if !flight.expired { for waiter in flight.waiters.values { waiter.resolve(result) } }
    }
    private func expire(_ key: Key, id: UUID) {
        guard var flight = flights[key], flight.id == id else { return }
        flight.expired = true; flight.task.cancel()
        for waiter in flight.waiters.values { waiter.resolve(.failure(NetworkFault.timeout)) }
        flight.waiters = [:]; flights[key] = flight
        // Keep a tombstone until an uncooperative provider really exits: no overlapping rotation on timeout.
    }
}
/// Explicit refresh only: never a 401 retry loop. Use the same coordinator across feature facades.
public actor CredentialRefreshGate {
    private let coordinator: CredentialRefreshCoordinator
    private let fence: NetworkAccountFence?
    private var scope: NetworkAccountScope?
    public init(coordinator: CredentialRefreshCoordinator = .shared, fence: NetworkAccountFence? = nil) {
        self.coordinator = coordinator; self.fence = fence
    }
    public func bind(_ context: RequestContext) async throws {
        let next = NetworkAccountScope(context), old = scope
        if let old { guard next.generation > old.generation || next == old else { throw NetworkFault.stale } }
        try fence?.publish(context); scope = next
    }
    public func invalidate(account: AccountContext? = nil) async {
        if let account { await coordinator.invalidate(account: account) }
        else if let scope { await coordinator.invalidate(scope: scope) }
    }
    public func refreshScoped(reference: CredentialReference, context: RequestContext, caller: NetworkQueryToken? = nil,
                              perform: @escaping @Sendable () async throws -> CredentialReference) async throws -> CredentialRefreshResult {
        do {
            try Task.checkCancellation(); try validate(context, caller: caller)
            guard context.account != nil else { throw NetworkFault.authentication }
            let reference = try await coordinator.refresh(reference: reference, scope: NetworkAccountScope(context), perform: perform)
            try Task.checkCancellation(); try validate(context, caller: caller)
            return .init(context: context, reference: reference)
        } catch { throw DirectBoundedTransport.sanitize(error) }
    }
    public func refresh(reference: CredentialReference, context: RequestContext, caller: NetworkQueryToken? = nil,
                        perform: @escaping @Sendable () async throws -> CredentialReference) async throws -> CredentialReference {
        try await refreshScoped(reference: reference, context: context, caller: caller, perform: perform).reference
    }
    /// Refresh producers belong to the account credential owner, not to a feature query.
    public func refreshAccount(reference: CredentialReference, context: RequestContext, caller: NetworkQueryToken? = nil,
                               perform: @escaping @Sendable (RequestContext) async throws -> CredentialReference) async throws -> CredentialRefreshResult {
        let producer = RequestContext(account: context.account, accountGeneration: context.accountGeneration, requestGeneration: 0)
        return try await refreshScoped(reference: reference, context: context, caller: caller) { try await perform(producer) }
    }
    private func validate(_ context: RequestContext, caller: NetworkQueryToken?) throws {
        guard scope == NetworkAccountScope(context) else { throw NetworkFault.stale }
        try fence?.validate(context); try caller?.validate(context)
    }
}
