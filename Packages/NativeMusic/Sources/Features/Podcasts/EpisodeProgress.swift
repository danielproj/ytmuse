import AccountSession
import Domain
import Foundation

/// What this Mac heard of one episode. It is this Mac's own record: it is never sent to the service and never shown as synced. YouTube's own
/// player reports its progress to YouTube Music by itself when the hidden player plays an episode; the app neither writes nor imitates that.
public struct EpisodeProgressRecord: Codable, Equatable, Sendable {
    public let videoID: String
    public var position: Double
    public var duration: Double?
    public var updatedAt: Date
    /// The episode was played to its end here (or the person marked it played).
    public var played: Bool
    /// The show's page id, when known, so the show's speed applies on resume.
    public var showID: String?
    public init(videoID: String, position: Double, duration: Double?, updatedAt: Date, played: Bool, showID: String? = nil) {
        self.videoID = videoID; self.position = position; self.duration = duration; self.updatedAt = updatedAt; self.played = played; self.showID = showID
    }
    /// The sync contract for this Mac's progress (SYNC07): it is never synchronised, so it is "Local only" and can never read as confirmed by the
    /// service. A service that reports progress is a separate figure (`MusicEpisodeInfo`); `EpisodeProgressResolver` keeps the two apart.
    public var sync: SyncState { .localOnly }
}

/// The thresholds that turn a stream of position reports into a record. Plain numbers, named, in one place.
public enum EpisodeProgressPolicy {
    /// Under this many seconds heard, an episode counts as not started (a stray tap leaves no record).
    public static let startedAfter = 5.0
    /// Within this many seconds of the end, the episode counts as played.
    public static let playedWithin = 1.0
    /// A position report is stored when it moved this far since the last stored one (or on pause, end, or change of episode).
    public static let storeEvery = 5.0
}

/// How an episode's progress is shown. `origin` says whose figure it is; an episode nobody reported on has none.
public struct EpisodeProgress: Equatable, Sendable {
    public enum Origin: Equatable, Sendable { case thisMac, youTubeMusic }
    public enum Status: Equatable, Sendable {
        case unplayed
        /// `fraction` is nil when the length is unknown (no percentage is shown then).
        case inProgress(fraction: Double?)
        case played
    }
    public let status: Status
    public let origin: Origin?
    /// Where playback resumes, in seconds, ONLY when this Mac recorded the exact position. A service percentage is not a position.
    public let resumePosition: Double?
    public init(status: Status, origin: Origin?, resumePosition: Double?) { self.status = status; self.origin = origin; self.resumePosition = resumePosition }
    public static let unplayed = EpisodeProgress(status: .unplayed, origin: nil, resumePosition: nil)
    /// The plain-language provenance line: "On this Mac" for local progress, "From YouTube Music" for the service's. Nil when there is none.
    public var provenance: String? {
        switch origin {
        case .thisMac?: String(localized: "On this Mac")
        case .youTubeMusic?: String(localized: "From YouTube Music")
        case nil: nil
        }
    }
    public var isPlayed: Bool { status == .played }
}

public enum EpisodeProgressResolver {
    /// Combines what the service's page printed with this Mac's record.
    ///
    /// - A service that reports progress (part played, or played to the end) is believed unless this Mac listened after the page was read.
    /// - A service that reports nothing (an anonymous read, or an unplayed episode) never hides a local record: the local figure is shown, marked "On this Mac".
    /// - A "Played" LABEL on a row is never read as played (every real row carries one).
    public static func resolve(service: MusicEpisodeInfo?, local: EpisodeProgressRecord?, pageReadAt: Date) -> EpisodeProgress {
        if let service, service.servicePlayedToEnd || service.serviceInProgress {
            if let local, local.updatedAt >= pageReadAt { return fromLocal(local) }
            if service.servicePlayedToEnd { return EpisodeProgress(status: .played, origin: .youTubeMusic, resumePosition: nil) }
            return EpisodeProgress(status: .inProgress(fraction: (service.progressPercent ?? 0) / 100), origin: .youTubeMusic, resumePosition: nil)
        }
        if let local { return fromLocal(local) }
        return .unplayed
    }
    static func fromLocal(_ record: EpisodeProgressRecord) -> EpisodeProgress {
        if record.played { return EpisodeProgress(status: .played, origin: .thisMac, resumePosition: nil) }
        guard record.position >= EpisodeProgressPolicy.startedAfter else { return .unplayed }
        let fraction = record.duration.flatMap { $0 > 0 ? min(max(record.position / $0, 0), 1) : nil }
        return EpisodeProgress(status: .inProgress(fraction: fraction), origin: .thisMac, resumePosition: record.position)
    }
}

/// Turns the hidden player's reports into this Mac's progress record for the episodes it was told are episodes. A pure value: the caller stores what `observe` returns.
public struct EpisodeProgressRecorder: Sendable {
    public struct Reading: Sendable, Equatable {
        public var videoID: String?
        public var position: Double
        public var duration: Double
        public var playing: Bool
        public var ended: Bool
        public var advertisement: Bool
        public init(videoID: String?, position: Double, duration: Double, playing: Bool, ended: Bool = false, advertisement: Bool = false) {
            self.videoID = videoID; self.position = position; self.duration = duration; self.playing = playing; self.ended = ended; self.advertisement = advertisement
        }
    }
    private var known: [String: String?] = [:]
    private var lastStored: [String: Double] = [:]
    private var lastPlaying: [String: Bool] = [:]
    public init() {}
    /// An episode the person started from a podcast surface. Only these are recorded (a song is never given an episode record).
    public mutating func know(_ videoID: String, show: String?) { known[videoID] = .some(show) }
    public func knows(_ videoID: String) -> Bool { known[videoID] != nil }
    public mutating func forget(_ videoID: String) { known[videoID] = nil; lastStored[videoID] = nil; lastPlaying[videoID] = nil }
    public mutating func forgetAll() { known = [:]; lastStored = [:]; lastPlaying = [:] }

    public mutating func observe(_ reading: Reading, now: Date, existing: EpisodeProgressRecord?) -> EpisodeProgressRecord? {
        guard let id = reading.videoID, let show = known[id], !reading.advertisement, reading.position.isFinite, reading.position >= 0 else { return nil }
        let wasPlaying = lastPlaying[id] ?? false
        lastPlaying[id] = reading.playing
        let duration: Double? = reading.duration.isFinite && reading.duration > 0 ? reading.duration : existing?.duration
        let atEnd = reading.ended || (duration.map { reading.position >= $0 - EpisodeProgressPolicy.playedWithin && reading.position > 0 } ?? false)
        if atEnd {
            if existing?.played == true && existing?.position == reading.position { return nil }
            lastStored[id] = reading.position
            return EpisodeProgressRecord(videoID: id, position: reading.position, duration: duration, updatedAt: now, played: true, showID: show ?? existing?.showID)
        }
        guard reading.position >= EpisodeProgressPolicy.startedAfter else { return nil }
        let last = lastStored[id] ?? existing?.position ?? -.infinity
        let paused = wasPlaying && !reading.playing
        guard abs(reading.position - last) >= EpisodeProgressPolicy.storeEvery || (paused && reading.position != last) else { return nil }
        lastStored[id] = reading.position
        // Listening again after having played it to the end starts a new listen: the episode is in progress again.
        return EpisodeProgressRecord(videoID: id, position: reading.position, duration: duration, updatedAt: now, played: false, showID: show ?? existing?.showID)
    }
}

/// Everything this Mac keeps about podcasts for one account: playback choices and episode progress. One small private file per account.
public struct PodcastLocalState: Codable, Equatable, Sendable {
    public var preferences = PodcastPlaybackPreferences()
    public var progress: [String: EpisodeProgressRecord] = [:]
    public init() {}
    /// Keep the table bounded: the most recently updated records win.
    public static let maximumRecords = 5_000
    public mutating func store(_ record: EpisodeProgressRecord) {
        progress[record.videoID] = record
        if progress.count > Self.maximumRecords {
            for stale in progress.values.sorted(by: { $0.updatedAt < $1.updatedAt }).prefix(progress.count - Self.maximumRecords) { progress[stale.videoID] = nil }
        }
    }
}
public protocol PodcastLocalStoring: Sendable {
    func load(account: String) async throws -> PodcastLocalState
    func save(_ state: PodcastLocalState, account: String) async throws
    func clear(account: String) async throws
}
