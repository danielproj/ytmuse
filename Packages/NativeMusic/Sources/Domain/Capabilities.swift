import Foundation

public enum Feature: String, CaseIterable, Sendable {
    case playback, backgroundPlayback, audioOnly, offline, qualitySelection, libraryMutation, playlistMutation, historyMutation, collaboration, lyrics, radio, casting, samples, recap, badges
}
public enum CapabilityState: Equatable, Sendable {
    case supported
    case restricted(DomainError)
    case temporarilyUnavailable(DomainError)
    case unknown
    case failed(DomainError)
}
public struct Capability: Equatable, Sendable {
    public let state: CapabilityState
    public let source: String
    public let context: AccountContext
    public let checkedAt: Date
    public let expiresAt: Date?
    public init(state: CapabilityState, source: String, context: AccountContext, checkedAt: Date, expiresAt: Date?) throws(DomainError) {
        guard !source.isEmpty, expiresAt.map({ $0 >= checkedAt }) ?? true else { throw .invalidInput(.invalidRange) }
        self.state = state; self.source = source; self.context = context; self.checkedAt = checkedAt; self.expiresAt = expiresAt
    }
    /// Unknown is a request for verification, distinct from denied and allowed.
    public func decision(for context: AccountContext, now: Date) -> CapabilityDecision {
        guard self.context == context else { return .verify(.staleContext) }
        guard now >= checkedAt, expiresAt.map({ now < $0 }) ?? true else { return .verify(.capabilityExpired) }
        switch state {
        case .supported: return .allowed
        case .unknown: return .verify(.capabilityUnknown)
        case .restricted(let error): return .denied(error)
        case .temporarilyUnavailable(let error), .failed(let error): return .retry(error)
        }
    }
}
public enum CapabilityDecision: Equatable, Sendable { case allowed, denied(DomainError), verify(DomainError), retry(DomainError) }
public struct AccountCapabilities: Sendable {
    public let context: AccountContext
    public let features: [Feature: Capability]
    public init(context: AccountContext, features: [Feature: Capability]) throws(DomainError) {
        guard features.values.allSatisfy({ $0.context == context }) else { throw .invalidInput(.contextMismatch) }
        self.context = context; self.features = features
    }
    public func decision(_ feature: Feature, now: Date) -> CapabilityDecision {
        features[feature]?.decision(for: context, now: now) ?? .verify(.capabilityUnknown)
    }
    public func require(_ feature: Feature, now: Date) throws(DomainError) {
        switch decision(feature, now: now) {
        case .allowed: return
        case .denied(let e), .verify(let e), .retry(let e): throw e
        }
    }
}
public protocol CapabilityProvider: Sendable {
    func capabilities(context: RequestContext) async -> ServiceResult<AccountCapabilities>
}
