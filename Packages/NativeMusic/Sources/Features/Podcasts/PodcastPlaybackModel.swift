import AccountSession
import Foundation
import Observation

/// What the podcast controls read from the player each time it reports. The playback owner (AppShell) fills it from the hidden player.
public struct EpisodePlayerReading: Equatable, Sendable {
    public var videoID: String?
    public var position: Double
    public var duration: Double
    public var playing: Bool
    public var ended: Bool
    public var advertisement: Bool
    /// The player will take a seek now (an item is loaded, it is not an ad, its length is known).
    public var canSeek: Bool
    /// The playlist the player was started on (a show's playlist when an episode was started from it).
    public var playlistID: String?
    public init(videoID: String?, position: Double, duration: Double, playing: Bool, ended: Bool = false, advertisement: Bool = false, canSeek: Bool = true, playlistID: String? = nil) {
        self.videoID = videoID; self.position = position; self.duration = duration; self.playing = playing; self.ended = ended
        self.advertisement = advertisement; self.canSeek = canSeek; self.playlistID = playlistID
    }
}
/// The two things the podcast controls ask of the player. Both are refused (false) when the player cannot honour them; the model reports it.
@MainActor public protocol EpisodePlayerControlling: AnyObject {
    var reading: EpisodePlayerReading { get }
    /// The listening speed the player last confirmed (1 when none).
    var confirmedRate: Double { get }
    func seek(to seconds: Double) async -> Bool
    func setRate(_ rate: Double) async -> Bool
}

public enum PodcastNotice: Equatable, Sendable {
    case rateRefused, seekRefused, couldNotSave
    public var message: String {
        switch self {
        case .rateRefused: String(localized: "The player didn’t change the speed. It keeps its current speed.")
        case .seekRefused: String(localized: "The player can’t move to that point right now.")
        case .couldNotSave: String(localized: "Your podcast settings couldn’t be saved on this Mac. They apply until you quit.")
        }
    }
}

/// Podcast playback on top of the single playback owner: the show's speed, the jump buttons, resuming where this Mac left off, and the episode
/// progress record. It never starts playback by itself (a person pressing Play on an episode registers it with `episodeStarting`), and it
/// sends nothing to the service.
@MainActor @Observable public final class PodcastPlaybackModel {
    public private(set) var state = PodcastLocalState()
    public private(set) var notice: PodcastNotice?
    /// The episode the person started (or the player is on), with its show.
    public private(set) var current: (videoID: String, show: String?)?
    @ObservationIgnored private let store: (any PodcastLocalStoring)?
    @ObservationIgnored private let accountKey: @MainActor () -> String?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private weak var player: (any EpisodePlayerControlling)?
    @ObservationIgnored private var recorder = EpisodeProgressRecorder()
    @ObservationIgnored private var pendingResume: String?
    /// The show playlist the person started an episode from: the show's next episodes, which the player moves on to by itself, are episodes too.
    @ObservationIgnored private var episodePlaylist: (id: String, show: String?)?
    @ObservationIgnored private var lastVideo: String?
    @ObservationIgnored private var adjusting = false
    /// A speed the player refused for an item is not asked for again on every reading; it is asked again for another item or another speed.
    @ObservationIgnored private var refused: (video: String, rate: Double)?
    @ObservationIgnored private var loadedAccount: String?
    @ObservationIgnored private var generation: UInt64 = 0

    public init(store: (any PodcastLocalStoring)?, accountKey: @escaping @MainActor () -> String?, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.accountKey = accountKey; self.clock = clock
    }
    public func attach(_ player: any EpisodePlayerControlling) { self.player = player }

    // MARK: Loading and account scope

    /// Reads this account's saved podcast settings and progress. A switch of account drops everything of the old one first.
    public func load() async {
        let key = accountKey()
        if key != loadedAccount { accountChanged() }
        generation &+= 1; let ticket = generation
        loadedAccount = key
        guard let key, let store else { return }
        do {
            let loaded = try await store.load(account: key)
            guard ticket == generation, key == accountKey() else { return }
            // Progress recorded while loading is newer than what was on disk; keep it.
            var merged = loaded
            for (id, record) in state.progress where (merged.progress[id]?.updatedAt ?? .distantPast) < record.updatedAt { merged.progress[id] = record }
            if state.preferences != PodcastPlaybackPreferences(), loaded.preferences == PodcastPlaybackPreferences() { merged.preferences = state.preferences }
            state = merged
        } catch { if ticket == generation { notice = .couldNotSave } }
    }
    public func accountChanged() {
        generation &+= 1; state = PodcastLocalState(); current = nil; episodePlaylist = nil; pendingResume = nil; lastVideo = nil; recorder.forgetAll(); notice = nil; loadedAccount = nil
    }

    // MARK: Preferences

    public var skip: PodcastSkipIntervals { state.preferences.skip }
    public func rate(forShow show: String?) -> Double { state.preferences.rate(forShow: show) }
    /// Sets a show's speed. False (nothing changes) outside `0.5…3`. If the show is playing now the player is asked too.
    @discardableResult public func setRate(_ rate: Double, forShow show: String) async -> Bool {
        guard state.preferences.setRate(rate, forShow: show) else { return false }
        persist()
        if current?.show == show { return await apply(rate: rate) }
        return true
    }
    public func clearRate(forShow show: String) async {
        state.preferences.clearRate(forShow: show); persist()
        if current?.show == show { _ = await apply(rate: state.preferences.rate(forShow: show)) }
    }
    @discardableResult public func setDefaultRate(_ rate: Double) -> Bool {
        let accepted = state.preferences.setDefaultRate(rate)
        if accepted { persist() }
        return accepted
    }
    @discardableResult public func setSkip(back: Int, forward: Int) -> Bool {
        guard let intervals = PodcastSkipIntervals(back: back, forward: forward) else { return false }
        state.preferences.skip = intervals; persist(); return true
    }

    // MARK: Playing

    /// The person pressed Play on an episode: it is recorded from now on, and resumes where this Mac stopped (once, when the player has it loaded).
    public func episodeStarting(videoID: String, show: String?, playlistID: String? = nil) {
        current = (videoID, show)
        episodePlaylist = playlistID.map { ($0, show) }
        recorder.know(videoID, show: show)
        notice = nil
        if let record = state.progress[videoID], EpisodeProgressResolver.fromLocal(record).resumePosition != nil { pendingResume = videoID } else { pendingResume = nil }
    }
    /// A show's own Play or Shuffle started the show's playlist: every episode the player reports from it is that show's episode (its speed, progress
    /// and resume apply), exactly as for an episode started from its own row. Nothing is current until the player reports one.
    public func showStarting(show: String, playlistID: String) {
        episodePlaylist = (playlistID, show); current = nil; pendingResume = nil; notice = nil
    }
    /// A reading from the player. Applies the speed for the item that is playing, performs a pending resume, and records progress.
    public func observe(_ reading: EpisodePlayerReading) {
        if let id = reading.videoID {
            // A show's playlist the person started: whatever it reports is that show's episode (checked on every reading, so the first one cannot be missed).
            if !recorder.knows(id), let list = episodePlaylist, reading.playlistID == list.id {
                recorder.know(id, show: list.show); current = (id, list.show)
                if let record = state.progress[id], EpisodeProgressResolver.fromLocal(record).resumePosition != nil { pendingResume = id }
            }
            if id != lastVideo {
                lastVideo = id
                if !recorder.knows(id) { if current?.videoID != id { current = nil } }
                else if current?.videoID != id { current = (id, state.progress[id]?.showID) }
            }
        }
        if reading.videoID == nil { lastVideo = nil }
        if let record = recorder.observe(.init(videoID: reading.videoID, position: reading.position, duration: reading.duration, playing: reading.playing,
                                               ended: reading.ended, advertisement: reading.advertisement), now: clock(), existing: reading.videoID.flatMap { state.progress[$0] }) {
            state.store(record); persist()
        }
        guard !reading.advertisement, let id = reading.videoID, !adjusting else { return }
        let isEpisode = recorder.knows(id)
        let desired = isEpisode ? state.preferences.rate(forShow: current?.videoID == id ? current?.show : state.progress[id]?.showID) : PodcastRate.normal
        // The speed follows the item: an episode plays at its show's speed and anything else (a song after an episode) at normal speed. The
        // player's own speed is what it reports, so a speed an ad or a new item took away is corrected here, to the episode and never to an ad.
        let needsRate: Bool
        if let player { needsRate = abs(player.confirmedRate - desired) > 0.001 && (reading.canSeek || reading.playing) && !(refused?.video == id && refused?.rate == desired) }
        else { needsRate = false }
        var resume: Double?
        if pendingResume == id, reading.canSeek, reading.duration > 0, let record = state.progress[id], let position = EpisodeProgressResolver.fromLocal(record).resumePosition {
            resume = min(position, max(reading.duration - 1, 0)); pendingResume = nil
        }
        guard needsRate || resume != nil else { return }
        adjusting = true
        Task { [weak self] in
            if needsRate {
                let done = await self?.apply(rate: desired) ?? true
                if !done { self?.refused = (id, desired) }
            }
            // Then the place: resuming happens once, after the speed, so the seek is not undone by a re-load.
            if let resume { _ = await self?.player?.seek(to: resume) }
            await self?.finishAdjust()
        }
    }
    private func finishAdjust() { adjusting = false }

    /// Jumps back or forward by the chosen length, clamped to the item. Refused during an ad or when nothing seekable is playing.
    @discardableResult public func skipBack() async -> Bool { await jump(by: -skip.back) }
    @discardableResult public func skipForward() async -> Bool { await jump(by: skip.forward) }
    /// Moves playback to a point the caller read from an episode's own chapter list. Refused during an ad or when nothing seekable is playing.
    @discardableResult public func seek(to seconds: Double) async -> Bool {
        guard let player, player.reading.canSeek, !player.reading.advertisement, seconds.isFinite, seconds >= 0 else { notice = .seekRefused; return false }
        let done = await player.seek(to: min(seconds, player.reading.duration > 0 ? player.reading.duration : seconds))
        notice = done ? nil : .seekRefused
        return done
    }
    private func jump(by seconds: Int) async -> Bool {
        guard let player, player.reading.canSeek, !player.reading.advertisement else { notice = .seekRefused; return false }
        let reading = player.reading
        let target = PodcastSkipIntervals.target(from: reading.position, by: seconds, duration: reading.duration)
        let done = await player.seek(to: target)
        notice = done ? nil : .seekRefused
        return done
    }
    private func apply(rate: Double) async -> Bool {
        guard PodcastRate.isValid(rate), let player else { return false }
        if abs(player.confirmedRate - rate) <= 0.001 { return true }
        let done = await player.setRate(rate)
        notice = done ? nil : .rateRefused
        return done
    }

    // MARK: Progress

    public func localRecord(_ videoID: String?) -> EpisodeProgressRecord? { videoID.flatMap { state.progress[$0] } }
    public func progress(for item: MusicCatalogItem, pageReadAt: Date) -> EpisodeProgress {
        EpisodeProgressResolver.resolve(service: item.episode, local: localRecord(item.videoID), pageReadAt: pageReadAt)
    }
    /// A local mark (this Mac only): played, or back to unplayed. Nothing is sent to the service.
    public func mark(_ videoID: String, played: Bool, duration: Double?, show: String?) {
        if played {
            state.store(EpisodeProgressRecord(videoID: videoID, position: duration ?? 0, duration: duration, updatedAt: clock(), played: true, showID: show))
        } else {
            state.progress[videoID] = nil
        }
        persist()
    }

    // MARK: Saving

    private func persist() {
        guard let store, let key = accountKey(), key == loadedAccount else { return }
        let snapshot = state, ticket = generation
        Task { [weak self] in
            do { try await store.save(snapshot, account: key) }
            catch { await MainActor.run { if let self, ticket == self.generation { self.notice = .couldNotSave } } }
        }
    }
}
