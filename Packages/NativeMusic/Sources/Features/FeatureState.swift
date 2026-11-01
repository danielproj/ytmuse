import Domain
import Observation

/// Each destination owns its own request generation and observable data.
/// Timeline sampling uses PlaybackSnapshot.position(at:) without publishing global ticks.
@MainActor @Observable public final class FeatureState<Value: Sendable> {
    public private(set) var value: Value?
    public private(set) var error: DomainError?
    public private(set) var isLoading = false
    private var gate: RequestGate
    public init(account: AccountContext? = nil) { gate = RequestGate(account: account) }
    public func begin() -> RequestContext { isLoading = true; error = nil; return gate.next() }
    public func switchAccount(_ account: AccountContext?) { _ = gate.switchAccount(account); value = nil; error = nil; isLoading = false }
    @discardableResult public func receive(_ response: ServiceResult<Value>) -> Bool {
        guard gate.accepts(response.context) else { return false }
        isLoading = false
        switch response.outcome { case .success(let value): self.value = value; error = nil
        case .failure(let error): self.error = error }
        return true
    }
}
