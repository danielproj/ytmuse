import Foundation
import Domain

/// Neutral, purpose-separated protected storage. No name or lease is loaded from writable media.
public struct ProtectedRecordLease: Sendable {
    public let account: AccountContext
    public let token: UUID
    public let epoch: UUID?
    public init(account: AccountContext, token: UUID, epoch: UUID? = nil) { self.account = account; self.token = token; self.epoch = epoch }
}
public struct ProtectedRecordStamp: Sendable {
    public let version: Data?
    public init(version: Data?) { self.version = version }
}
public protocol ScopedProtectedRecords: SessionVault {
    func eraseProtectedAccount(_ account: AccountContext, barrier: RequestContext, cleanup: @Sendable () throws -> Void) async throws
    func acquireProtectedLease(context: RequestContext) async throws -> ProtectedRecordLease?
    func releaseProtectedLease(_ lease: ProtectedRecordLease) async throws
    func protectedRecordStamp(_ name: String, lease: ProtectedRecordLease, context: RequestContext) async throws -> ProtectedRecordStamp?
    func protectedRecord(_ name: String, lease: ProtectedRecordLease, context: RequestContext) async throws -> Data?
    func replaceProtectedRecord(_ name: String, value: Data?, lease: ProtectedRecordLease, context: RequestContext) async throws
}

public extension ScopedProtectedRecords {
    func eraseProtectedAccount(_ account: AccountContext, barrier: RequestContext, cleanup: @Sendable () throws -> Void) async throws { throw DomainError.unsupported }
    // Legacy witnesses remain correct but uncacheable; concrete Keychain implementation
    // queries attributes only, never fetching master material to validate its version.
    func protectedRecordStamp(_ name: String, lease: ProtectedRecordLease, context: RequestContext) async throws -> ProtectedRecordStamp? {
        try await protectedRecord(name, lease: lease, context: context).map { _ in ProtectedRecordStamp(version: nil) }
    }
}
