@preconcurrency import AVFoundation
import Domain
import Foundation
import Synchronization

/// Trusted provider seam, not a grant inferred from an asset URL. Providers retain
/// authorization/decoder details; only typed errors and user-seek permission cross it.
public final class NativeAssetSession: @unchecked Sendable {
    public let id = UUID()
    public let asset: AVURLAsset
    /// Observed at preparation. Actual seeks must call authorizeUserSeek again.
    public enum DecodedAccess: Sendable { case unavailable, localPCM, authorizedNative }
    public enum ContentKind: Sendable { case music, spoken, live, advertisement }
    public let contentKind: ContentKind
    public let decodedAccess: DecodedAccess
    public let userSeekable: Bool
    private struct State { var closed = false; var failure: DomainError?; var retractions: [UUID: @Sendable () -> Void] = [:] }
    private let state = Mutex(State())
    private let permission: @Sendable () async throws -> Void
    private let decoderPermission: @Sendable () async throws -> Void
    private let drainWork: @Sendable () async -> Void
    private let cleanup: @Sendable () -> Void
    public let failures: AsyncStream<DomainError>
    private let output: AsyncStream<DomainError>.Continuation
    public init(asset: AVURLAsset, userSeekable: Bool, decodedAccess: DecodedAccess = .unavailable, contentKind: ContentKind = .music, authorizeUserSeek: @escaping @Sendable () async throws -> Void, authorizeDecodedRead: @escaping @Sendable () async throws -> Void = {}, drain: @escaping @Sendable () async -> Void = {}, dispose: @escaping @Sendable () -> Void = {}) {
        self.contentKind = contentKind; self.decodedAccess = decodedAccess; self.asset = asset; self.userSeekable = userSeekable; permission = authorizeUserSeek; decoderPermission = authorizeDecodedRead; drainWork = drain; cleanup = dispose
        let channel = AsyncStream<DomainError>.makeStream(bufferingPolicy: .bufferingNewest(1))
        failures = channel.stream; output = channel.continuation
    }
    public var failure: DomainError? { state.withLock { $0.failure } }
    public var isClosed: Bool { state.withLock { $0.closed } }
    public func authorizeUserSeek() async throws {
        try Task.checkCancellation()
        if let error = failure { throw error }
        guard !isClosed else { throw DomainError.staleContext }
        try await permission()
        try Task.checkCancellation()
        if let error = failure { throw error }
        guard !isClosed else { throw DomainError.staleContext }
    }
    public func authorizeDecodedRead() async throws {
        if let failure { throw failure }
        guard decodedAccess != .unavailable else { throw DomainError.unsupported }
        guard !isClosed else { throw DomainError.staleContext }
        do { try await decoderPermission() }
        catch { let category = (error as? DomainError) ?? (error as? any NativeAssetFailure)?.playbackError ?? .transientTransport; fail(category); throw category }
        guard !isClosed else { throw DomainError.staleContext }
        if let failure { throw failure }
    }
    /// Control-plane retraction only. Never invoked by a render callback.
    func retractOnInvalidation(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let valid = state.withLock { value -> Bool in
            guard !value.closed, value.failure == nil else { return false }
            value.retractions[id] = callback; return true
        }
        if !valid { callback() }; return id
    }
    func removeRetraction(_ id: UUID) { state.withLock { $0.retractions[id] = nil } }
    private func retract() {
        let callbacks = state.withLock { value in let callbacks = Array(value.retractions.values); value.retractions.removeAll(); return callbacks }
        for callback in callbacks { callback() }
    }
    /// First failure belongs only to this preparation. Disposed sessions cannot emit.
    public func fail(_ error: DomainError) {
        let accepted = state.withLock { state -> Bool in
            guard !state.closed, state.failure == nil else { return false }
            state.failure = error; return true
        }
        guard accepted else { return }
        retract()
        output.yield(error)
        // Resume pending native metadata loads without waiting for a transport timeout.
        asset.cancelLoading()
    }
    public func dispose() {
        let accepted = state.withLock { state -> Bool in
            guard !state.closed else { return false }; state.closed = true; return true
        }
        guard accepted else { return }
        retract(); output.finish(); cleanup(); asset.cancelLoading()
    }
    public func disposeAndDrain() async { dispose(); await drainWork() }
    deinit { dispose() }
}
