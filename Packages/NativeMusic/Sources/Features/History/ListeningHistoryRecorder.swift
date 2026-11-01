import Domain
import Foundation

/// One local play: what was heard, on this Mac. It is the app's own record. It was never sent anywhere and is not YouTube Music's
/// history (`LocalHistoryRecord.sync` is `.localOnly` for every record).
public struct LocalHistoryRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let videoID: String
    public let title: String
    public let artist: String?
    public let startedAt: Date
    /// Seconds actually heard when the play was recorded.
    public let listenedSeconds: Double
    public init(id: UUID = UUID(), videoID: String, title: String, artist: String?, startedAt: Date, listenedSeconds: Double) {
        self.id = id; self.videoID = videoID; self.title = title; self.artist = artist; self.startedAt = startedAt; self.listenedSeconds = listenedSeconds
    }
    /// Local history is never synchronised: it is "Local only" (SYNC07) and can never read as confirmed by the service.
    public var sync: SyncState { .localOnly }
}

/// Where local plays are kept, per account. Implemented by the app over a private file; tests use a store in a scratch directory.
public protocol LocalHistoryStoring: Sendable {
    func append(_ record: LocalHistoryRecord, account: String) async throws
    func recent(account: String, limit: Int) async throws -> [LocalHistoryRecord]
    /// Removes this Mac's record only. Nothing is sent to the service.
    func clear(account: String) async throws
}

/// One reading of the player (derived from the bridge's validated state), as the recorder sees it.
public struct ListeningObservation: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case track
        /// An advertisement is playing: never listening to the track.
        case advertisement
        /// A short preview or sample: never a play of the full item.
        case preview
    }
    public var videoID: String?
    public var title: String?
    public var artist: String?
    public var position: Double
    public var duration: Double
    public var playing: Bool
    public var buffering: Bool
    public var ended: Bool
    public var content: Content
    /// A monotonic clock reading in seconds (it never jumps with the wall clock), and the wall time for the record.
    public var monotonic: Double
    public var wall: Date
    public init(videoID: String?, title: String? = nil, artist: String? = nil, position: Double, duration: Double, playing: Bool, buffering: Bool = false,
                ended: Bool = false, content: Content = .track, monotonic: Double, wall: Date = Date()) {
        self.videoID = videoID; self.title = title; self.artist = artist; self.position = position; self.duration = duration; self.playing = playing
        self.buffering = buffering; self.ended = ended; self.content = content; self.monotonic = monotonic; self.wall = wall
    }
}

/// Turns real playback progress into local plays under an adapter-defined `ListeningPolicy`.
///
/// A play is recorded once, when the time actually heard in one continuous occurrence reaches the policy's threshold. Heard time
/// grows only while the player is playing the track (not buffering, not paused, not an advertisement or a preview) and only by
/// what the clock and the position agree on: a seek or a jump adds nothing. An end report never makes a play by itself, a
/// repeated end report changes nothing, and a track that is skipped, or sought to its end, before the threshold is not a play.
public struct ListeningHistoryRecorder: Sendable {
    public let policy: ListeningPolicy
    private struct Occurrence {
        var videoID: String
        var title: String?
        var artist: String?
        var duration: Double
        var startedAt: Date
        var heard: Double = 0
        /// Clock time spent playing the track; heard time can never exceed it by more than the tolerance (a race ahead is not listening).
        var playingClock: Double = 0
        var lastPosition: Double?
        var lastClock: Double?
        var recorded = false
        var ended = false
    }
    private var current: Occurrence?
    public init(policy: ListeningPolicy) { self.policy = policy }

    /// Feeds one reading. Returns the play to record when this reading is the one that completes it (at most one per occurrence).
    public mutating func observe(_ reading: ListeningObservation) -> LocalHistoryRecord? {
        // An advertisement or a preview is not the track: nothing counts and the track's occurrence is left as it was (the same
        // content resumes after an ad), but the clock baseline is dropped so the gap is never counted.
        guard reading.content == .track else { current?.lastClock = nil; current?.lastPosition = nil; return nil }
        guard let video = reading.videoID else { return nil }
        if reading.ended {
            // The end of an occurrence is bookkeeping only. A duplicate end report is the same no-op.
            if current?.videoID == video { current?.ended = true; current?.lastClock = nil; current?.lastPosition = nil }
            return nil
        }
        var replay = false
        if let existing = current, existing.videoID == video, existing.ended, reading.playing, !reading.buffering,
           reading.position < max(0, existing.duration - 1) { replay = true }
        if current?.videoID != video || replay {
            current = Occurrence(videoID: video, title: nil, artist: nil, duration: reading.duration, startedAt: reading.wall)
        }
        guard var occurrence = current else { return nil }
        if let title = reading.title { occurrence.title = title }
        if let artist = reading.artist { occurrence.artist = artist }
        if reading.duration > 0 { occurrence.duration = reading.duration }
        defer { current = occurrence }
        guard reading.playing, !reading.buffering, !occurrence.ended else {
            occurrence.lastClock = nil; occurrence.lastPosition = nil
            return nil
        }
        if let lastClock = occurrence.lastClock, let lastPosition = occurrence.lastPosition {
            let clock = reading.monotonic - lastClock, moved = reading.position - lastPosition
            // Playback advances the position about as fast as the clock; far more than that is a seek, and a rewind adds nothing.
            if clock > 0 {
                occurrence.playingClock += clock
                if moved > 0, moved <= clock + policy.seekTolerance { occurrence.heard += moved }
                occurrence.heard = min(occurrence.heard, occurrence.playingClock + policy.seekTolerance)
            }
        }
        occurrence.lastClock = reading.monotonic; occurrence.lastPosition = reading.position
        guard !occurrence.recorded, let threshold = policy.threshold(duration: occurrence.duration), occurrence.heard >= threshold else { return nil }
        occurrence.recorded = true
        return LocalHistoryRecord(videoID: occurrence.videoID, title: occurrence.title ?? "", artist: occurrence.artist, startedAt: occurrence.startedAt, listenedSeconds: occurrence.heard)
    }
}
