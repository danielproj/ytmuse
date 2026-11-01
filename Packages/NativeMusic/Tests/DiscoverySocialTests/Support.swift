import AccountSession
import Features
import Foundation
import Testing

/// Everything in this target runs against scripted engines, performers, sources and transports. Nothing reaches a network, a real
/// account, a hidden player or any store.

func packageRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { root.deleteLastPathComponent() }
    return root
}
func repositoryRoot() -> URL { packageRoot().deletingLastPathComponent().deletingLastPathComponent() }
func fixturesRoot() -> URL { repositoryRoot().appendingPathComponent("Fixtures") }

/// One log shared by the engine and the performer, so a test can assert the order across both.
@MainActor final class Timeline {
    var events: [String] = []
}

/// A preview engine that records everything and measures overlap: how many clips sound at once.
@MainActor final class TimelineEngine: PreviewEngine {
    let log: Timeline
    private(set) var sounding: [String] = []
    private(set) var maxSounding = 0
    private(set) var starts: [String] = []
    private(set) var stops = 0
    var failing: Set<String> = []
    /// Holds a start open until released, so a test can interleave another request or an account change.
    var holdStarts = false
    private var held: CheckedContinuation<Void, Never>?
    init(log: Timeline = Timeline()) { self.log = log }
    func start(_ clip: SampleClip) async -> Bool {
        log.events.append("engine.start:" + clip.id); starts.append(clip.id)
        if holdStarts { await withCheckedContinuation { held = $0 } }
        if failing.contains(clip.id) { return false }
        sounding.append(clip.id); maxSounding = max(maxSounding, sounding.count)
        return true
    }
    func stop() async { log.events.append("engine.stop"); stops += 1; sounding.removeAll() }
    func release() { held?.resume(); held = nil }
    var isHolding: Bool { held != nil }
}

@MainActor final class RecordingPerformer: SearchActionPerformer {
    struct Play: Equatable { let playlistID: String; let title: String; let videoID: String?; let params: String? }
    let log: Timeline
    private(set) var plays: [Play] = []
    var outcome: SearchPlayOutcome = .started
    /// Runs at the moment the shared session is asked to play (a test reads the engine here).
    var atPlay: (@MainActor () -> Void)?
    init(log: Timeline = Timeline()) { self.log = log }
    func play(playlistID: String, title: String) async -> SearchPlayOutcome { await play(playlistID: playlistID, title: title, videoID: nil, params: nil) }
    func play(playlistID: String, title: String, videoID: String?, params: String?) async -> SearchPlayOutcome {
        log.events.append("performer.play:" + playlistID); atPlay?()
        plays.append(Play(playlistID: playlistID, title: title, videoID: videoID, params: params))
        return outcome
    }
    func copy(link: URL) {}
}

func clip(_ id: String, playlist: String? = nil, params: String? = nil) -> SampleClip {
    SampleClip(id: id, title: "Clip " + id, artist: "Artist " + id, playlistID: playlist, params: params)
}

/// A samples source that returns what it is told and counts its reads.
final class ScriptedSamplesSource: SamplesSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads = 0
    var reads: Int { lock.withLock { _reads } }
    let unresolvedReason: String?
    var result: Result<[SampleClip], SamplesFailure>
    init(_ result: Result<[SampleClip], SamplesFailure> = .success([]), unresolved: String? = nil) { self.result = result; unresolvedReason = unresolved }
    var unresolved: String? { unresolvedReason }
    func clips() async throws -> [SampleClip] { lock.withLock { _reads += 1 }; return try result.get() }
}

@MainActor func makeArbiter(engine: TimelineEngine = TimelineEngine(), conditions: @escaping @MainActor () -> PreviewConditions = { PreviewConditions() }) -> PreviewArbiter {
    PreviewArbiter(engine: engine, conditions: conditions)
}
/// A device whose conditions a test can change.
@MainActor final class Device {
    var conditions = PreviewConditions()
}

/// The models hold the shared playback session weakly (as the application does), so a test keeps its scripted performer alive here for the
/// length of the process. Nothing in it is shared state a test reads.
@MainActor enum Retained {
    private(set) static var items: [AnyObject] = []
    static func keep(_ item: AnyObject) { items.append(item) }
}
