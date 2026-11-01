import AccountSession
import Domain
import Features
import Foundation
import Observation
import Playback

/// This Mac's podcast settings and episode progress, one small private file per account inside the app's data directory (the isolated scratch
/// root under QA isolation). It is never sent anywhere and is removed with the account.
actor PodcastLocalFileStore: PodcastLocalStoring, AccountLifecycleParticipant {
    nonisolated let participantID = "podcast-local-state"
    enum Failure: Error { case invalidAccount, corrupt }
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    private func file(_ account: String) throws -> URL {
        // The account key is a UUID the app made; anything else is refused before it can become part of a path.
        guard let id = UUID(uuidString: account) else { throw Failure.invalidAccount }
        return directory.appendingPathComponent(id.uuidString + ".plist")
    }
    func load(account: String) throws -> PodcastLocalState {
        let url = try file(account)
        guard FileManager.default.fileExists(atPath: url.path) else { return PodcastLocalState() }
        let data = try Data(contentsOf: url)
        // A damaged file is set aside and the account starts clean; nothing is guessed from it.
        guard data.count <= 8 * 1024 * 1024, let state = try? PropertyListDecoder().decode(PodcastLocalState.self, from: data) else {
            try? GuardedFiles(root: url.deletingLastPathComponent()).move(url, to: url.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).plist"))
            throw Failure.corrupt
        }
        return state
    }
    func save(_ state: PodcastLocalState, account: String) throws {
        let url = try file(account)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(state).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func clear(account: String) throws {
        let url = try file(account)
        try GuardedFiles(root: directory).remove(url)
    }
    func detach(previous: RequestContext, barrier: RequestContext) async throws {}
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {}
    func removeLocal(_ account: AccountContext, context: RequestContext) async throws { try? clear(account: account.accountID.uuidString) }
}
actor LateBoundPodcastStore: PodcastLocalStoring {
    enum Failure: Error { case notBound }
    private var target: (any PodcastLocalStoring)?
    func bind(_ store: any PodcastLocalStoring) { target = store }
    func load(account: String) async throws -> PodcastLocalState { try await bound().load(account: account) }
    func save(_ state: PodcastLocalState, account: String) async throws { try await bound().save(state, account: account) }
    func clear(account: String) async throws { try await bound().clear(account: account) }
    private func bound() throws -> any PodcastLocalStoring { guard let target else { throw Failure.notBound }; return target }
}

/// The podcast controls' view of the one playback owner: what the hidden YouTube Music player reports, and the two things it is asked to do.
@MainActor final class WebMusicEpisodePlayer: EpisodePlayerControlling {
    private weak var playback: PlaybackModel?
    init(playback: PlaybackModel) { self.playback = playback }
    var reading: EpisodePlayerReading {
        guard let player = playback?.music, !player.isClosed else { return EpisodePlayerReading(videoID: nil, position: 0, duration: 0, playing: false, canSeek: false) }
        let state = player.snapshot
        return EpisodePlayerReading(videoID: state.videoID, position: player.timeline.latestPosition, duration: state.duration, playing: state.phase == .playing,
                                    ended: state.phase == .ended, advertisement: state.isAd, canSeek: state.canSeek, playlistID: state.playlistID)
    }
    var confirmedRate: Double { playback?.music?.confirmedRate ?? 1 }
    func seek(to seconds: Double) async -> Bool {
        guard let player = playback?.music, !player.isClosed, player.snapshot.canSeek else { return false }
        await player.seek(seconds)
        return player.refusal == nil
    }
    func setRate(_ rate: Double) async -> Bool { await playback?.music?.setRate(rate) ?? false }
}

extension LocalAccountBootstrap {
    /// Episode pages, the speed / jump / resume controls, episode progress and the lyrics panel. Reads go through the account coordinator
    /// (signed for the active account, anonymous otherwise, same scope fence and allowlist as every other read); the only write is Episodes for
    /// Later, through the Library's ledger, from an explicit press. A UI-automation launch never reaches the network.
    func makePodcastsSurface() -> PodcastsSurface {
        // Weak, not unowned: the surface may outlive a short-lived bootstrap (a test), and a late read must answer "nothing" rather than trap.
        let scope: @MainActor () -> String = { [weak self] in self?.searchScopeToken ?? "" }
        let signedIn: @MainActor () -> SearchPlayback = { [weak self] in self?.searchPlayback ?? .needsSignIn }
        let episodeReader: EpisodePageModel.Reader
        let lyricsReader: LyricsModel.Reader
        let blocked: Bool
        #if DEBUG
        blocked = Self.automationIsolated(ProcessInfo.processInfo.environment) && !DevelopmentCatalog.enabled
        #else
        blocked = false
        #endif
        #if DEBUG
        let development = DevelopmentPodcasts.enabled
        #else
        let development = false
        #endif
        if development {
            #if DEBUG
            episodeReader = DevelopmentPodcasts.episodeReader; lyricsReader = DevelopmentPodcasts.lyricsReader
            #else
            episodeReader = { _ in throw MusicSessionError.policy }; lyricsReader = { _ in throw MusicSessionError.policy }
            #endif
        } else if blocked {
            episodeReader = { _ in throw MusicSessionError.policy }; lyricsReader = { _ in throw MusicSessionError.policy }
        } else {
            episodeReader = { [weak self] id in
                guard let self else { throw MusicSessionError.stale }
                return try await self.awaitedMusic().episode(id: id)
            }
            lyricsReader = { [weak self] video in
                guard let self else { throw MusicSessionError.stale }
                return try await self.awaitedMusic().lyrics(videoID: video)
            }
        }
        let controls = WebMusicEpisodePlayer(playback: playback)
        let local = PodcastPlaybackModel(store: podcastStore, accountKey: { [weak self] in self?.model.active?.accountID.uuidString })
        local.attach(controls)
        let follow = LyricsFollowModel(seek: { await controls.seek(to: $0) }, canSeek: { controls.reading.canSeek })
        let surface = PodcastsSurface(
            playback: local, lyrics: LyricsModel(reader: lyricsReader, accountScope: scope), follow: follow, ledger: library.ledger, reader: episodeReader,
            starter: { [weak self] request in
                guard let performer = self?.searchPerformer else { return .failed }
                // The show's playlist starting at this episode. The episode's own watch parameters are not sent: they are the service's
                // and their meaning to the hidden player is unverified (the shuffle flag travels in the same field).
                return await performer.play(playlistID: request.playlistID, title: request.title, videoID: request.videoID, params: nil)
            }, accountScope: scope, signedIn: signedIn)
        // Every published reading of the player, plus a slow beat while an episode plays (positions are not published on every tick).
        playback.episodes = local   // the remote commands' jumps and speed go through the same podcast model as the buttons
        playback.episodeObserver = { [weak local, weak controls] in if let local, let controls { local.observe(controls.reading) } }
        let beat = Task { @MainActor [weak local, weak controls] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(EpisodeProgressPolicy.storeEvery))
                guard let local, let controls else { return }
                let reading = controls.reading
                if reading.playing, local.current != nil { local.observe(reading) }
            }
        }
        beats.append(beat)
        Task { await local.load() }
        return surface
    }
}
