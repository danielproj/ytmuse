@preconcurrency import AVFoundation
import Domain
import Foundation
import Synchronization

/// A control-plane lock serializes native start/schedule against synchronous
/// provider revocation. The render thread never touches this lock or this object.
final class NativeOutputPermit: @unchecked Sendable {
    private struct State { var revoked = false; var sources: Set<UUID> = [] }
    private let state = Mutex(State())
    private let engine: AVAudioEngine
    private let node: AVAudioPlayerNode
    init(engine: AVAudioEngine, node: AVAudioPlayerNode) { self.engine = engine; self.node = node }
    func perform<T>(_ body: () throws -> T) throws -> T {
        try state.withLock { state in guard !state.revoked else { throw DomainError.staleContext }; return try body() }
    }
    func register(_ source: UUID) { state.withLock { $0.sources.insert(source) } }
    func unregister(_ source: UUID) { state.withLock { $0.sources.remove(source) } }
    // A callback captured before unregister cannot later retract another source.
    // Both operations serialize with native scheduling on the control plane.
    func retract(source: UUID) {
        state.withLock { value in
            guard value.sources.contains(source) else { return }
            value.revoked = true; node.stop(); engine.stop()
        }
    }
    func retract() { state.withLock { value in value.revoked = true; value.sources.removeAll(); node.stop(); engine.stop() } }
}
