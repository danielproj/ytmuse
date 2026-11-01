import Domain
import Foundation
import OutputRoutes
import Playback

// W39. The app side of Cast: the native playback session as the Cast driver's local transport, and the scripted receivers an isolated launch lists.
// Which real network types are used is decided in `OutputComposition.swift` only; this file never names one.

/// The native session (owned and local media) as the Cast driver sees it. While a receiver renders, the session is a silent clock (`setRemoteRendering`).
@MainActor final class NativeCastTransport: CastLocalTransport {
    private weak var model: PlaybackModel?
    init(model: PlaybackModel) { self.model = model }

    func localState() async -> CastLocalState {
        guard let model, let session = model.session, let snapshot = try? await session.snapshot() else { return CastLocalState(item: nil, playing: false, position: 0) }
        guard let current = snapshot.queue.current else { return CastLocalState(item: nil, playing: snapshot.playback.intent == .play, position: snapshot.playback.position) }
        // Only the bundled owned audio is castable: a kept download is encrypted at rest and is never decrypted for a receiver (`Docs/Cast.md`).
        let source: CastLocalSource = OwnedMedia.castableFile(for: current.media).map(CastLocalSource.file) ?? .notCastable(current.media == OwnedMedia.videoItem ? .noFile : .keptDownload)
        let item = CastLocalItem(key: "\(current.id.uuidString)", source: source, title: model.title(for: current.media), artist: nil, duration: snapshot.media?.duration)
        return CastLocalState(item: item, playing: snapshot.playback.intent == .play, position: snapshot.playback.position)
    }
    /// True only when the session's engine confirms (read back from its own output state). With NO native session there is nothing that could sound, so there is
    /// nothing to silence and the answer is true; with a session, an engine that cannot confirm answers false and the receiver is never asked to play.
    func setSilenced(_ on: Bool) async -> Bool {
        guard let session = model?.session else { return true }
        return await session.setRemoteRendering(on)
    }
    func pauseLocal() async { try? await model?.session?.pause(.user); await model?.refresh() }
    func resumeLocal() async { try? await model?.session?.resume(); await model?.refresh() }
    func seekLocal(_ seconds: Double) async { try? await model?.session?.seek(seconds); await model?.refresh() }
}

#if DEBUG
/// Isolated launches only: two fixed receivers that a UI test can pick. Never browses; the simulated receiver behind them is in-process.
final class ScriptedCastDirectory: CastDirectory, @unchecked Sendable {
    static let livingRoom = CastDevice(id: CastDeviceID("SCRIPTED-CAST-LIVING")!, friendlyName: "Scripted Living Room", model: "Scripted", capabilityBits: 5)
    static let kitchen = CastDevice(id: CastDeviceID("SCRIPTED-CAST-KITCHEN")!, friendlyName: "Scripted Kitchen", model: "Scripted", capabilityBits: 5)
    private let lock = NSLock()
    private var browsing = false
    private var handlers: [UUID: @MainActor () -> Void] = [:]
    func devices() -> [CastDevice] { lock.withLock { browsing ? [Self.livingRoom, Self.kitchen] : [] } }
    @MainActor func observe(_ onChange: @escaping @MainActor () -> Void) -> OutputObservation {
        let id = UUID(); lock.withLock { handlers[id] = onChange }
        return Observation { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: id) } }
    }
    @MainActor func startBrowsing() { change(true) }
    @MainActor func stopBrowsing() { change(false) }
    @MainActor private func change(_ value: Bool) {
        let list = lock.withLock { () -> [@MainActor () -> Void] in
            guard browsing != value else { return [] }
            browsing = value; return Array(handlers.values)
        }
        for handler in list { handler() }
    }
    private final class Observation: OutputObservation {
        private let onCancel: () -> Void
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        @MainActor func cancel() { onCancel() }
    }
}
#endif
