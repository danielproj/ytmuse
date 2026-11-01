import Foundation
import Domain

/// W03's outbox claims durably before send. A crash or ambiguous response leaves reconciliation required.
/// This executor never replays a claimed operation, even when the verb is POST or a provider read says absent.
public actor DurableMutationExecutor {
    private let outbox: any MutationOutbox
    public init(outbox: any MutationOutbox) { self.outbox = outbox }
    public func execute(id: UUID, context: RequestContext,
                        submit: @Sendable (PendingMutation) async throws -> OperationAcknowledgement) async -> ServiceResult<PendingMutation> {
        let claim = await outbox.beginAttempt(id, context: context)
        guard claim.context == context else { return .init(context: context, outcome: .failure(.staleContext)) }
        guard case .success(let mutation) = claim.outcome else { return claim }
        do {
            try Task.checkCancellation()
            switch try await submit(mutation) {
            case .confirmed: return await outbox.commit(id, context: context)
            case .rejected: return await outbox.fail(id, error: .malformedResponse, ambiguous: false, context: context)
            case .indeterminate: return await outbox.fail(id, error: .reconciliationRequired, ambiguous: true, context: context)
            }
        } catch {
            // Error text/URL/token never crosses the durable boundary. Submission may have happened.
            return await outbox.fail(id, error: .reconciliationRequired, ambiguous: true, context: context)
        }
    }
    public func reconcile(id: UUID, context: RequestContext,
                          observe: @Sendable (PendingMutation) async throws -> OperationAcknowledgement) async -> ServiceResult<PendingMutation> {
        let state = await outbox.reconcile(id, context: context)
        guard state.context == context else { return .init(context: context, outcome: .failure(.staleContext)) }
        guard case .success(let mutation) = state.outcome, mutation.outcome == .needsReconciliation else { return state }
        do {
            if case .confirmed = try await observe(mutation) { return await outbox.commit(id, context: context) }
        } catch { /* keep uncertainty durable; never replay */ }
        return state
    }
}
