import AccountSession
import Domain
import Foundation
import Playback

// W21 (WIN09). A manual cold launch restores the last session paused: the item YouTube Music was on, and where it was. This Mac keeps one small
// private file per account (the isolated scratch root under QA isolation), written when the track or the play state changes, now and then while
// playing, and at sleep and quit. Nothing here is a service read or a write, and nothing plays at launch: Play is the person's.

struct MusicResumeRecord: Codable, Equatable, Sendable {
    var playlistID: String
    var playlistTitle: String?
    var videoID: String?
    var title: String?
    var artist: String?
    var position: Double
    var duration: Double
    /// A record read from disk is trusted only after every field passes the same rules the hidden player applies to a request.
    var isValid: Bool {
        WebMusicIdentifier.isPlaylistID(playlistID) && (videoID.map { WebMusicIdentifier.isVideoID($0) } ?? true)
            && position.isFinite && position >= 0 && position <= 86_400 && duration.isFinite && duration >= 0 && duration <= 86_400
            && [playlistTitle, title, artist].allSatisfy { ($0?.count ?? 0) <= 1_536 }
    }
}
protocol MusicResumeStoring: Sendable {
    func save(_ record: MusicResumeRecord, account: String) async throws
    func load(account: String) async throws -> MusicResumeRecord?
    func clear(account: String) async throws
}

actor MusicResumeFileStore: MusicResumeStoring, AccountLifecycleParticipant {
    nonisolated let participantID = "music-resume"
    enum Failure: Error { case invalidAccount }
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    private func file(_ account: String) throws -> URL {
        guard let id = UUID(uuidString: account) else { throw Failure.invalidAccount }
        return directory.appendingPathComponent(id.uuidString + ".plist")
    }
    func save(_ record: MusicResumeRecord, account: String) throws {
        let url = try file(account)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(record).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func load(account: String) throws -> MusicResumeRecord? {
        let url = try file(account)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024, let record = try? PropertyListDecoder().decode(MusicResumeRecord.self, from: data), record.isValid else { return nil }
        return record
    }
    func clear(account: String) throws {
        let url = try file(account)
        try GuardedFiles(root: directory).remove(url)
    }
    func detach(previous: RequestContext, barrier: RequestContext) async throws {}
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {}
    /// Removing an account removes what this Mac kept for it.
    func removeLocal(_ account: AccountContext, context: RequestContext) async throws { try? clear(account: account.accountID.uuidString) }
}

/// The store the playback owner holds before the account directory is known; saves before `bind` are dropped, loads answer nothing.
actor LateBoundMusicResumeStore: MusicResumeStoring {
    private var target: (any MusicResumeStoring)?
    func bind(_ store: any MusicResumeStoring) { target = store }
    func save(_ record: MusicResumeRecord, account: String) async throws { try await target?.save(record, account: account) }
    func load(account: String) async throws -> MusicResumeRecord? { try await target?.load(account: account) }
    func clear(account: String) async throws { try await target?.clear(account: account) }
}

/// Decides when the last session is worth writing. A change of item or of play state writes at once; a playing item writes at most every
/// `interval`; an advertisement, a failure and an item that has not started write nothing.
struct MusicResumePolicy {
    var interval: Duration = .seconds(20)
    private var lastKey: String?
    private var lastSave: ContinuousClock.Instant?
    init(interval: Duration = .seconds(20)) { self.interval = interval }
    static func record(_ snapshot: WebMusicSnapshot, position: Double) -> MusicResumeRecord? {
        guard !snapshot.isAd, !snapshot.restored, !snapshot.isFailed, let playlist = snapshot.playlistID,
              [WebMusicPhase.playing, .paused, .buffering].contains(snapshot.phase), snapshot.title != nil || snapshot.videoID != nil else { return nil }
        let record = MusicResumeRecord(playlistID: playlist, playlistTitle: snapshot.playlistTitle, videoID: snapshot.videoID, title: snapshot.title, artist: snapshot.artist,
                                       position: max(0, position), duration: max(0, snapshot.duration))
        return record.isValid ? record : nil
    }
    mutating func shouldSave(_ snapshot: WebMusicSnapshot, now: ContinuousClock.Instant, force: Bool = false) -> Bool {
        let key = "\(snapshot.videoID ?? "")|\(snapshot.phase)|\(snapshot.intent)"
        defer { lastKey = key }
        if force || key != lastKey { lastSave = now; return true }
        guard snapshot.phase == .playing, let last = lastSave, now - last >= interval else { return false }
        lastSave = now; return true
    }
}

extension PlaybackModel {
    /// Writes the last session now (sleep, quit); a no-op without a store, an account, or anything worth keeping.
    func saveResumeNow() async {
        guard let store = resumeStore, let player = music, !player.isClosed, let account = await authority.activeAccountID(),
              let record = MusicResumePolicy.record(player.snapshot, position: player.timeline.latestPosition) else { return }
        try? await store.save(record, account: account.uuidString)
    }
    /// Called with every published reading of the hidden player; saves on the policy's schedule.
    func noteForResume(_ snapshot: WebMusicSnapshot) {
        guard resumeStore != nil, let player = music, !player.isClosed, let record = MusicResumePolicy.record(snapshot, position: player.timeline.latestPosition),
              resumePolicy.shouldSave(snapshot, now: .now) else { return }
        Task { [weak self] in
            // F7: the record belongs to THIS player. The account is only known after a hop; if the player was closed or replaced meanwhile (an account
            // switch, sign-out, removal, quit), the record is dropped, never written under whichever account is active by then.
            guard let self, let store = self.resumeStore else { return }
            let account = await self.authority.activeAccountID()
            guard Self.resumeWriteAllowed(player: player, current: self.music, closed: player.isClosed), let account else { return }
            try? await store.save(record, account: account.uuidString)
        }
    }
    /// The fence on a queued resume write: the player that produced the record is still the one owner, and open.
    static func resumeWriteAllowed(player: WebMusicPlayer, current: WebMusicPlayer?, closed: Bool) -> Bool { current === player && !closed }
    /// Cold or manual launch: shows the last session paused, loading nothing, once the account is restored. Never plays.
    func restoreLastSession() async {
        guard restoreEnabled(), let store = resumeStore, music == nil, session == nil, !starting, let account = await authority.activeAccountID(),
              let record = try? await store.load(account: account.uuidString) else { return }
        let request = authority.requestOwnedStart()
        guard let player = try? await authority.youtubeMusic(request: request) else { return }
        guard player.restoreLastSession(playlistID: record.playlistID, playlistTitle: record.playlistTitle, videoID: record.videoID, title: record.title,
                                        artist: record.artist, position: record.position, duration: record.duration) else { return }
        attachRestored(player)
    }
}
