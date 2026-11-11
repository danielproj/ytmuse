import AccountSession
import Foundation
import Observation

/// One short clip a source offered for a preview or a Sample. `id` is the media id the clip plays from.
public struct SampleClip: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String?
    public let thumbnails: [MusicThumbnail]
    /// The playlist the source named for this clip's own Play (the full item), and the parameters it attached. Never derived here.
    public let playlistID: String?
    public let params: String?
    /// How long the clip is, when the source said. A preview ends there.
    public let durationSeconds: Double?
    public init(id: String, title: String, artist: String? = nil, thumbnails: [MusicThumbnail] = [], playlistID: String? = nil, params: String? = nil, durationSeconds: Double? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.thumbnails = thumbnails; self.playlistID = playlistID; self.params = params; self.durationSeconds = durationSeconds
    }
}
/// Plays one clip as a preview through the shared playback session. There is exactly one engine and it holds at most one clip.
@MainActor public protocol PreviewEngine: AnyObject {
    /// Starts the clip as a preview. true when it is playing as a preview. The engine stops anything it was previewing before.
    func start(_ clip: SampleClip) async -> Bool
    /// Returns once the preview no longer makes sound or holds the video picture.
    func stop() async
}

public enum PreviewEvent: Equatable, Sendable {
    case started(String, PreviewTrigger)
    case stopped(String, reason: PreviewStopReason)
    case refused(String, PreviewRefusal)
    case handedOff(String)
}
public enum PreviewStopReason: Sendable, Equatable {
    case replaced, requested, handedOffToPlayback, playbackStarted, conditionsChanged, accountChanged, leftScreen
    /// The clip reached its end (the preview ends there; it does not run on into what follows).
    case clipEnded
    /// The player moved on to another item by itself while a preview owned it (a radio's next track).
    case leftOnItsOwn
}
public enum PreviewRequestResult: Sendable, Equatable { case previewing, refused(PreviewRefusal) }
public enum PreviewHandoffOutcome: Sendable, Equatable {
    case started
    /// The clip names nothing to play (no playlist of its own and no media id).
    case nothingToPlay
    case notStarted(SearchPlayOutcome)
}

/// DISC04: one preview at a time, no audio overlap, and Play hands the clip to the shared playback session.
///
/// Rules this type keeps:
/// - at most one clip is previewing; asking for another stops the first (and waits for it to stop) before the second starts;
/// - a preview that starts by itself (`autoplay`) obeys `PreviewPolicy` (Low Power Mode, constrained connection, the person's
///   choice, something else playing). It is stopped again when the conditions turn against it. A press on Preview is never refused by
///   the policy;
/// - Play (`play`) stops the preview first, waits until it is silent and only then asks the shared playback session to play the clip's
///   own item, so the two never sound at once;
/// - requests are carried out strictly in the order they were made; a request that a newer one has overtaken does not start;
/// - nothing starts at launch or on its own account: a request comes from a focused clip or a press.
@MainActor @Observable public final class PreviewArbiter {
    public private(set) var active: String?
    public private(set) var activeTrigger: PreviewTrigger?
    public private(set) var lastRefusal: PreviewRefusal?
    public var preference: PreviewAutoplayPreference = .automatic {
        didSet { if preference != oldValue { conditionsChanged() } }
    }
    /// The last events, newest last (bounded). A measurement for tests and diagnostics: it holds ids, never media.
    @ObservationIgnored public private(set) var events: [PreviewEvent] = []
    @ObservationIgnored private let engine: any PreviewEngine
    @ObservationIgnored private let conditions: @MainActor () -> PreviewConditions
    @ObservationIgnored private var ticket: UInt64 = 0
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    public init(engine: any PreviewEngine, conditions: @escaping @MainActor () -> PreviewConditions = { PreviewConditions() }) {
        self.engine = engine; self.conditions = conditions
    }

    public var autoplayRefusal: PreviewRefusal? { PreviewPolicy.autoplayRefusal(preference: preference, conditions: conditions()) }
    public func isPreviewing(_ id: String) -> Bool { active == id }

    /// Preview `clip`. Returns once the clip is previewing or was refused.
    @discardableResult public func request(_ clip: SampleClip, trigger: PreviewTrigger) async -> PreviewRequestResult {
        ticket &+= 1; let mine = ticket; let gen = generation
        return await serialized { [self] in
            guard mine == ticket, gen == generation else { return .refused(.superseded) }
            if trigger == .autoplay, let refusal = autoplayRefusal { lastRefusal = refusal; record(.refused(clip.id, refusal)); return .refused(refusal) }
            if active == clip.id, activeTrigger != nil { activeTrigger = trigger == .explicit ? .explicit : activeTrigger; return .previewing }
            await stopActive(.replaced)
            guard mine == ticket, gen == generation else { return .refused(.superseded) }
            guard await engine.start(clip) else { lastRefusal = .engineFailed; record(.refused(clip.id, .engineFailed)); return .refused(.engineFailed) }
            // An account change or a newer request landed while the engine was starting: that clip must not be left sounding.
            guard gen == generation else { await engine.stop(); return .refused(.superseded) }
            active = clip.id; activeTrigger = trigger; lastRefusal = nil; record(.started(clip.id, trigger))
            return .previewing
        }
    }

    /// Stops the preview, if one is running, and returns once it is silent.
    public func stop(_ reason: PreviewStopReason = .requested) async {
        ticket &+= 1
        await serialized { [self] in await stopActive(reason) }
    }

    /// The explicit Play: the preview ends first, then the shared playback session plays the clip's own item.
    @discardableResult public func play(_ clip: SampleClip, performer: any SearchActionPerformer) async -> PreviewHandoffOutcome {
        ticket &+= 1
        return await serialized { [self] in
            let playlist = clip.playlistID
            guard playlist != nil || !clip.id.isEmpty else { return .nothingToPlay }
            await stopActive(.handedOffToPlayback)
            // The preview is silent now. A clip with no playlist of its own plays as the service's radio for that clip, starting at the clip
            // (a radio loaded without its video id need not open with it).
            let outcome = await performer.play(playlistID: playlist ?? "RDAMVM" + clip.id, title: clip.title, videoID: clip.id, params: clip.params)
            if outcome == .started { record(.handedOff(clip.id)); return .started }
            return .notStarted(outcome)
        }
    }

    /// The shared session began playing something that is not a preview: the preview yields (no overlap).
    public func playbackStartedElsewhere() async { await stop(.playbackStarted) }
    /// The device conditions changed (Low Power Mode, connection) or the choice did: a preview that started by itself and may no longer
    /// do so stops. One the person asked for continues.
    public func conditionsChanged() {
        guard active != nil, activeTrigger == .autoplay, autoplayRefusal != nil else { return }
        enqueue { [self] in if activeTrigger == .autoplay, autoplayRefusal != nil { await stopActive(.conditionsChanged) } }
    }
    /// The account changed: nothing carries over.
    public func accountChanged() {
        generation &+= 1; ticket &+= 1
        enqueue { [self] in await stopActive(.accountChanged) }
    }

    private func stopActive(_ reason: PreviewStopReason) async {
        guard let id = active else { return }
        await engine.stop()
        active = nil; activeTrigger = nil
        record(.stopped(id, reason: reason))
    }
    private func record(_ event: PreviewEvent) { events.append(event); if events.count > 200 { events.removeFirst(events.count - 200) } }

    /// Carries out `body` after every earlier request has finished, in the order the requests were made.
    @discardableResult private func enqueue(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in await previous?.value; await body() }
        tail = task
        return task
    }
    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in await previous?.value; return await body() }
        tail = Task { _ = await task.value }
        return await task.value
    }
}

/// What the shared player reports while a preview owns it, reduced to what a preview needs to know.
public enum PreviewPlayerPhase: Sendable, Equatable { case active, paused, ended, other }
public enum PreviewWatch: Sendable, Equatable {
    case stay
    /// The previewed clip finished (or reached its stated length): the preview ends and nothing follows it.
    case clipEnded
    /// The player is on a different item and nobody asked for one: it ran on by itself (a radio's next track) and must be stopped.
    case leftOnItsOwn
    /// The player is on a different item because something asked for it (another Play): the preview yields without touching the player.
    case replacedByRequest
}
/// A preview is one clip. Played through a radio, the clip is followed by the radio's next tracks; this decides, from what the player reports, whether
/// the preview is still the clip, ended with it, or has been run past it. Pure: the application acts on the answer.
public enum PreviewWatcher {
    public static func evaluate(clip: String, durationSeconds: Double?, videoID: String?, phase: PreviewPlayerPhase, position: Double,
                                playRequestsAtStart: Int, playRequestsNow: Int) -> PreviewWatch {
        guard let videoID else { return .stay }
        if videoID == clip {
            if phase == .ended { return .clipEnded }
            if let durationSeconds, durationSeconds > 0, position.isFinite, position >= durationSeconds - 0.25 { return .clipEnded }
            return .stay
        }
        // Another item. Only an item that is actually playing or loading counts; a paused leftover is not a continuation.
        guard phase == .active else { return .stay }
        return playRequestsNow == playRequestsAtStart ? .leftOnItsOwn : .replacedByRequest
    }
}
