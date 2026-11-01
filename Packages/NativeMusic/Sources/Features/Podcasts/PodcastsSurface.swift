import AccountSession
import Foundation
import Observation
import SwiftUI

/// What it takes to start one episode in the hidden player: the show's playlist the player starts from, and the episode inside it.
public struct EpisodePlayRequest: Equatable, Sendable {
    public let videoID: String
    public let playlistID: String
    public let showID: String?
    public let title: String
}
public enum EpisodePlayTargets {
    /// A show's playlist is its `MPSP…` page id without the prefix (the hidden player takes a playlist id). Nil for any other id.
    public static func playlistID(forShow browseID: String) -> String? {
        guard browseID.hasPrefix("MPSP") else { return nil }
        let rest = String(browseID.dropFirst(4))
        return rest.range(of: #"^[A-Za-z0-9_-]{2,128}$"#, options: .regularExpression) != nil ? rest : nil
    }
    /// The request for an episode, or nil with the reason it cannot be made.
    public static func request(videoID: String?, title: String, showBrowseID: String?, publishedShowPlaylist: String? = nil) -> EpisodePlayRequest? {
        guard let videoID, videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
        guard let list = publishedShowPlaylist ?? showBrowseID.flatMap(playlistID(forShow:)) else { return nil }
        return EpisodePlayRequest(videoID: videoID, playlistID: list, showID: showBrowseID, title: title)
    }
}

/// How a show's own Play/Shuffle reaches the podcast controls (see `CatalogPageModel.podcastStart`). Called only after the start has happened.
public struct PodcastStartRegistration {
    public var began: @MainActor (_ show: String, _ playlistID: String) -> Void
    public init(began: @escaping @MainActor (_ show: String, _ playlistID: String) -> Void) { self.began = began }
}

/// One episode page: loaded from the service for the active account scope, with the same fences as every catalog read.
@MainActor @Observable public final class EpisodePageModel {
    public enum Phase: Equatable, Sendable { case idle, loading, loaded(MusicEpisodePage), failed(CatalogFailure) }
    public typealias Reader = @Sendable (String) async throws -> MusicBrowseReply<MusicEpisodePage>
    public let browseID: String
    public private(set) var phase: Phase = .idle
    public private(set) var readAt = Date.distantPast
    public private(set) var signedIn = false
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var generation: UInt64 = 0

    public init(browseID: String, reader: @escaping Reader, accountScope: @escaping @MainActor () -> String = { "" }, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.browseID = browseID; self.reader = reader; self.accountScope = accountScope; self.clock = clock
    }
    public var page: MusicEpisodePage? { if case .loaded(let page) = phase { page } else { nil } }
    public func load() async { if case .idle = phase { await read() } else if case .failed = phase { await read() } }
    public func refresh() async { await read() }
    public func accountChanged() { generation &+= 1; phase = .idle; signedIn = false }
    private func read() async {
        generation &+= 1; let ticket = generation, scope = accountScope()
        if page == nil { phase = .loading }
        do {
            let reply = try await reader(browseID)
            guard ticket == generation, accountScope() == scope else { return }
            // The reply must be the page asked for: a different episode answering is never shown under this one.
            guard reply.value.videoID == EpisodePageModel.videoID(ofBrowseID: browseID) else { phase = .failed(.unrecognised); return }
            signedIn = reply.mode == .signedIn
            readAt = clock(); phase = .loaded(reply.value)
        } catch {
            guard ticket == generation, accountScope() == scope else { return }
            if page == nil { phase = .failed(CatalogFailure(error)) }
        }
    }
    /// `MPED<videoId>` → the video id; nil for any other id.
    public static func videoID(ofBrowseID id: String) -> String? {
        guard id.hasPrefix("MPED") else { return nil }
        let rest = String(id.dropFirst(4))
        return rest.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil ? rest : nil
    }
    public var chapters: [EpisodeChapter] {
        guard let page else { return [] }
        let text = page.description.map(\.text).joined()
        return EpisodeChapters.parse(description: text, duration: EpisodeDuration.seconds(from: page.info.durationText))
    }
}

/// Podcasts and lyrics for the shell: episode pages, the playback controls for spoken audio, and the lyrics panel's models.
@MainActor @Observable public final class PodcastsSurface {
    public typealias Starter = @MainActor (EpisodePlayRequest) async -> SearchPlayOutcome
    public let playback: PodcastPlaybackModel
    public let lyrics: LyricsModel
    public let follow: LyricsFollowModel
    public let ledger: LibraryWriteLedger?
    /// The order the show's episode list is shown in (a view over the service's order).
    public var episodeSort: EpisodeSort = .serviceOrder
    public private(set) var feedback: [String: String] = [:]
    @ObservationIgnored private let reader: EpisodePageModel.Reader
    @ObservationIgnored private let starter: Starter
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let signedInState: @MainActor () -> SearchPlayback
    @ObservationIgnored private var pages: [String: EpisodePageModel] = [:]
    @ObservationIgnored private var pageOrder: [String] = []

    public init(playback: PodcastPlaybackModel, lyrics: LyricsModel, follow: LyricsFollowModel, ledger: LibraryWriteLedger?, reader: @escaping EpisodePageModel.Reader,
                starter: @escaping Starter, accountScope: @escaping @MainActor () -> String = { "" }, signedIn: @escaping @MainActor () -> SearchPlayback = { .available }) {
        self.playback = playback; self.lyrics = lyrics; self.follow = follow; self.ledger = ledger; self.reader = reader; self.starter = starter
        self.accountScope = accountScope; self.signedInState = signedIn
    }
    public var playbackState: SearchPlayback { signedInState() }

    public func page(forBrowseID id: String) -> EpisodePageModel {
        if let model = pages[id] { pageOrder.removeAll { $0 == id }; pageOrder.append(id); return model }
        let model = EpisodePageModel(browseID: id, reader: reader, accountScope: accountScope)
        pages[id] = model; pageOrder.append(id)
        while pageOrder.count > 12 { pages[pageOrder.removeFirst()] = nil }
        return model
    }
    public func accountChanged() {
        for model in pages.values { model.accountChanged() }
        playback.accountChanged(); lyrics.accountChanged(); follow.clear(); feedback = [:]
        Task { await playback.load() }
    }
    /// The rows of an episode list with their progress, in the chosen order.
    public func rows(for items: [MusicCatalogItem], pageReadAt: Date) -> [EpisodeRow] {
        episodeSort.apply(to: items.map { EpisodeRow(item: $0, progress: playback.progress(for: $0, pageReadAt: pageReadAt)) })
    }
    /// Plays one episode, from an explicit press. The player is told it is an episode first, so its speed and place are restored.
    public func play(_ request: EpisodePlayRequest) async {
        feedback[request.videoID] = nil
        // The episode is registered only once the start has happened: a start that did not happen (failed, stale, or refused because another start
        // is in flight) leaves whatever is playing registered exactly as it was.
        switch await starter(request) {
        case .started: playback.episodeStarting(videoID: request.videoID, show: request.showID, playlistID: request.playlistID)
        case .busy: break
        case .stale: feedback[request.videoID] = String(localized: "Your account changed before this started. Try again.")
        case .failed: feedback[request.videoID] = String(localized: "YouTube Music couldn’t start this episode. Try again.")
        }
    }
    public func feedbackText(for videoID: String) -> String? { feedback[videoID] }
}

private struct PodcastsSurfaceKey: EnvironmentKey { static let defaultValue: PodcastsSurface? = nil }
public extension EnvironmentValues {
    /// The shell's podcast and lyrics surface; nil where the shell offers none.
    var podcastsSurface: PodcastsSurface? {
        get { self[PodcastsSurfaceKey.self] }
        set { self[PodcastsSurfaceKey.self] = newValue }
    }
}
