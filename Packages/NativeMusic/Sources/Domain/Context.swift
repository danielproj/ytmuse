import Foundation

/// Opaque local/service identifiers are distinct types. No credential values are models.
public struct ID<Tag: Sendable>: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws(DomainError) {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalidInput(.emptyIdentifier) }
        self.rawValue = rawValue
    }
}
public enum AccountTag: Sendable {}
public enum ChannelTag: Sendable {}
public enum ServiceTag: Sendable {}
public enum CredentialTag: Sendable {}
public enum AuthorizationTag: Sendable {}
public enum RouteTag: Sendable {}
public enum CursorTag: Sendable {}
public typealias ServiceID = ID<ServiceTag>
public typealias CredentialReference = ID<CredentialTag>
public typealias AuthorizationReference = ID<AuthorizationTag>
public typealias RouteID = ID<RouteTag>

public struct AccountContext: Hashable, Sendable {
    public let accountID: UUID
    public let channelID: ID<ChannelTag>
    public let region: String
    public init(accountID: UUID, channelID: ID<ChannelTag>, region: String) throws(DomainError) {
        guard region.count == 2, region.utf8.allSatisfy({ (65...90).contains($0) }) else { throw .invalidInput(.region) }
        self.accountID = accountID; self.channelID = channelID; self.region = region
    }
}
public struct RequestContext: Hashable, Sendable {
    public let account: AccountContext?
    public let accountGeneration: UInt64
    public let requestGeneration: UInt64
    public init(account: AccountContext?, accountGeneration: UInt64, requestGeneration: UInt64) {
        self.account = account; self.accountGeneration = accountGeneration; self.requestGeneration = requestGeneration
    }
}
public struct PlaybackContext: Hashable, Sendable {
    public let request: RequestContext
    public let generation: UInt64
    public let occurrenceID: UUID?
    public let route: RouteID?
    public init(request: RequestContext, generation: UInt64, occurrenceID: UUID?, route: RouteID?) {
        self.request = request; self.generation = generation; self.occurrenceID = occurrenceID; self.route = route
    }
}
public enum InputViolation: String, Error, Sendable { case emptyIdentifier, region, negativeValue, invalidRange, duplicateOccurrence, missingCurrentOccurrence, contextMismatch, invalidTransition }
public enum DomainError: Error, Equatable, Sendable {
    case unauthorized, forbidden, unsupported, unavailableContent, regionRestricted
    case rateLimited(retryAfter: Date?), offline, malformedResponse, expiredMedia, transientTransport
    case invalidInput(InputViolation), staleContext, capabilityUnknown, capabilityExpired, reconciliationRequired
}
/// Errors and successes carry identical scope; adapters must echo the initiating context.
public struct ServiceResult<Value: Sendable>: Sendable {
    public let context: RequestContext
    public let outcome: Result<Value, DomainError>
    public init(context: RequestContext, outcome: Result<Value, DomainError>) { self.context = context; self.outcome = outcome }
}
public struct PlaybackResult<Value: Sendable>: Sendable {
    public let context: PlaybackContext
    public let outcome: Result<Value, DomainError>
    public init(context: PlaybackContext, outcome: Result<Value, DomainError>) { self.context = context; self.outcome = outcome }
}
public protocol WallClock: Sendable { func now() -> Date }
public protocol MonotonicClock: Sendable { func now() -> Duration }
public struct SystemWallClock: WallClock { public init() {}; public func now() -> Date { Date() } }
public struct SystemMonotonicClock: MonotonicClock {
    private let origin = ContinuousClock.now
    public init() {}
    public func now() -> Duration { origin.duration(to: .now) }
}
public struct PageCursor: Equatable, Sendable {
    public let reference: ID<CursorTag>
    public let context: RequestContext
    public let collection: ServiceID
    public let expiresAt: Date?
    public init(reference: ID<CursorTag>, context: RequestContext, collection: ServiceID, expiresAt: Date?) {
        self.reference = reference; self.context = context; self.collection = collection; self.expiresAt = expiresAt
    }
    public func validate(for request: RequestContext, collection: ServiceID, now: Date) throws(DomainError) {
        guard context == request, self.collection == collection else { throw .staleContext }
        guard expiresAt.map({ now < $0 }) ?? true else { throw .expiredMedia }
    }
}
public struct Page<Element: Sendable>: Sendable {
    public let items: [Element]
    public let next: PageCursor?
    public init(items: [Element], next: PageCursor? = nil) { self.items = items; self.next = next }
}
