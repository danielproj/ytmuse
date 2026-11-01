import Foundation
import Domain

struct NetworkAccountScope: Hashable, Sendable {
    let account: AccountContext?
    let generation: UInt64
    init(_ context: RequestContext) { account = context.account; generation = context.accountGeneration }
}
/// Shared application/session epoch. Query generations never enter this fence.
/// Concurrent explicit background account owners may share an epoch; advancing it fences ALL older owners.
/// Background work intended to survive an active-account switch needs its own explicitly scoped fence.
public final class NetworkAccountFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64?
    public init() {}
    public func publish(_ context: RequestContext) throws {
        try lock.withLock {
            guard generation.map({ context.accountGeneration >= $0 }) ?? true else { throw NetworkFault.stale }
            generation = context.accountGeneration
        }
    }
    public func validate(_ context: RequestContext) throws {
        try lock.withLock {
            guard generation.map({ context.accountGeneration >= $0 }) ?? true else { throw NetworkFault.stale }
        }
    }
}
/// A per-feature query owner. Pass its token to shared reads/refreshes; advancing another owner cannot stale it.
public final class NetworkQueryOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var context: RequestContext?
    public init() {}
    public func bind(_ context: RequestContext) throws -> NetworkQueryToken {
        try lock.withLock {
            if let old = self.context {
                guard context.accountGeneration > old.accountGeneration ||
                    (context.accountGeneration == old.accountGeneration && context.account == old.account && context.requestGeneration >= old.requestGeneration) else { throw NetworkFault.stale }
            }
            self.context = context
        }
        return NetworkQueryToken(context: context, owner: self)
    }
    fileprivate func matches(_ context: RequestContext) -> Bool { lock.withLock { self.context == context } }
}
public struct NetworkQueryToken: Sendable {
    public let context: RequestContext
    private let owner: NetworkQueryOwner
    fileprivate init(context: RequestContext, owner: NetworkQueryOwner) { self.context = context; self.owner = owner }
    func validate(_ context: RequestContext) throws {
        guard self.context == context, owner.matches(context) else { throw NetworkFault.stale }
    }
}
/// Continuation registration and cancellation can race in either order. Resolution is exactly once.
/// Cancellation resolves the caller synchronously, independently of a cooperative underlying loader.
final class NetworkWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    var pending: Bool { lock.withLock { result == nil } }
    @discardableResult func resolve(_ value: Result<Value, Error>) -> Bool {
        let state: (Bool, CheckedContinuation<Value, Error>?) = lock.withLock {
            guard result == nil else { return (false, nil) }
            result = value; let c = continuation; continuation = nil; return (true, c)
        }
        state.1?.resume(with: value)
        return state.0
    }
    func value(onCancel: @escaping @Sendable () -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                let value: Result<Value, Error>? = lock.withLock { () -> Result<Value, Error>? in
                    if let result { return result }
                    continuation = c; return nil as Result<Value, Error>?
                }
                if let value { c.resume(with: value) }
            }
        } onCancel: {
            self.resolve(.failure(NetworkFault.cancelled)); onCancel()
        }
    }
}

/// A facade's account binding can be checked synchronously by its shared producer's completion.
final class NetworkAccountBinding: @unchecked Sendable {
    private let lock = NSLock()
    private var scope: NetworkAccountScope?
    func set(_ scope: NetworkAccountScope) { lock.withLock { self.scope = scope } }
    func validate(_ context: RequestContext) throws {
        try lock.withLock { guard scope == NetworkAccountScope(context) else { throw NetworkFault.stale } }
    }
}
