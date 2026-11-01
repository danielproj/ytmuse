@preconcurrency import AVFoundation
import Domain
import Foundation
import Synchronization

/// Process-wide backpressure: one constant-memory analysis decoder, with at most
/// sixteen cancellation-aware waiting requests. No render-thread participation.
actor NativeNormalizationLane {
    static let shared = NativeNormalizationLane()
    private var busy = false
    private var waiting: [(UUID, CheckedContinuation<Bool,Never>)] = []
    private func cancel(_ id:UUID) {
        guard let index=waiting.firstIndex(where:{$0.0==id}) else{return}
        waiting.remove(at:index).1.resume(returning:false)
    }
    private func release() {
        if waiting.isEmpty {busy=false} else {waiting.removeFirst().1.resume(returning:true)}
    }
    func analyze(session:NativeAssetSession,track:AVAssetTrack) async throws ->Float {
        try Task.checkCancellation()
        if busy {
            guard waiting.count<16 else{throw DomainError.transientTransport}
            let id=UUID()
            let admitted=await withTaskCancellationHandler {
                await withCheckedContinuation {waiting.append((id,$0))}
            } onCancel: {Task{await self.cancel(id)}}
            guard admitted else{throw CancellationError()}
        } else {busy=true}
        defer{release()}
        try Task.checkCancellation()
        return try await IncrementalDecodedPlayer.analyze(session:session,track:track)
    }
}

/// AVAssetReader exposes thread-safe cancellation; all read iteration remains on
/// the analysis lane. This box confines cross-thread access to cancellation only.
final class NativeReaderCancellation: @unchecked Sendable {
    private struct Handle: @unchecked Sendable { let reader:AVAssetReader }
    private struct State: Sendable { var cancelled=false;var handle:Handle? }
    private let state=Mutex(State())
    func install(_ reader:AVAssetReader) {
        let handle=Handle(reader:reader)
        state.withLock { value in value.handle=handle;if value.cancelled {handle.reader.cancelReading()} }
    }
    func cancel() { state.withLock { value in value.cancelled=true;value.handle?.reader.cancelReading() } }
}
