import AccountSession
import Features
import Foundation
import Observation

/// The rating of the song that is playing, so the player surfaces can offer Like and Dislike for every song and not only for one that was
/// shown on a page first. It is the rating the hidden page's own player bar shows: the page is the account's signed-in YouTube Music, and its
/// like button's data names the song it belongs to (`WebMusicScripts.playerBarDetection`, `ytmuseRating`), so nothing extra is requested.
///
/// 0.1.10 read the rating from a separate signed `next` request's player overlay instead. The account's answer to that request carried no
/// usable like button (the buttons said "doesn't offer a rating" for every song), while the anonymous answer did; the page's player bar shows
/// the account's real rating, Dislike included, so it replaced that request.
///
/// The rating is taken once per song start: a press goes to the service through the ledger, not through the page, so the page keeps showing
/// the state from before the press; `settle` records what the press set. Nothing is taken during an advertisement or signed out, and
/// everything is forgotten when the account scope changes.
@MainActor @Observable final class NowPlayingRatings {
    /// Why a song has no rating to offer yet.
    enum Gap: Equatable { case reading, notOffered, signedOut }

    private(set) var ratings: [String: MusicItemControls.Like] = [:]
    private(set) var gaps: [String: Gap] = [:]
    @ObservationIgnored private var order: [String] = []
    /// The song the last report was about, when it started, and whether its rating has been taken.
    @ObservationIgnored private(set) var current: String?
    @ObservationIgnored private var started: Date = .distantPast
    @ObservationIgnored private var taken = false
    @ObservationIgnored private var scope: String?
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private let now: @MainActor () -> Date
    static let limit = 64
    /// How long a song may play before a page that still shows no rating for it is reported as not offering one.
    static let patience: TimeInterval = 5

    init(accountScope: @escaping @MainActor () -> String, signedIn: @escaping @MainActor () -> SearchPlayback, now: @escaping @MainActor () -> Date = Date.init) {
        self.accountScope = accountScope; self.signedIn = signedIn; self.now = now
    }

    func like(for videoID: String) -> MusicItemControls.Like? { ratings[videoID] }
    func gap(for videoID: String) -> Gap? { ratings[videoID] == nil ? gaps[videoID] : nil }

    /// One player report: the song, whether an advertisement shows, and the rating the page shows for that song (nil when it shows none).
    func observe(videoID: String?, isAd: Bool, rating: MusicLikeStatus?) {
        resetIfScopeChanged()
        guard !isAd, let videoID, Self.isVideoID(videoID) else { return }
        if videoID != current { current = videoID; started = now(); taken = false; gaps = [:] }
        guard !taken else { return }
        guard signedIn() == .available else { gaps[videoID] = .signedOut; return }
        if let rating {
            if ratings[videoID] == nil { order.append(videoID) }
            ratings[videoID] = .init(videoID: videoID, status: rating, dislikeExposed: true)
            while order.count > Self.limit { ratings[order.removeFirst()] = nil }
            gaps[videoID] = nil
            taken = true
            return
        }
        // A song that has just started may not have its rating on the page yet; one that has played a while without it is not offered one.
        let gap: Gap = now().timeIntervalSince(started) >= Self.patience ? .notOffered : .reading
        if gaps[videoID] != gap { gaps[videoID] = gap }
    }

    /// After a press the person made that the ledger did not reject: the service now holds `status`, so a later read of this song's page that
    /// clears the ledger's entry falls back to the right state, not the one shown before the press.
    func settle(_ videoID: String, to status: MusicLikeStatus) {
        guard let like = ratings[videoID] else { return }
        ratings[videoID] = .init(videoID: videoID, status: status, dislikeExposed: like.dislikeExposed)
    }

    /// The video-id shape the adapter accepts (`MusicBrowseParser.isVideoID`).
    static func isVideoID(_ id: String) -> Bool { id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil }
    private func resetIfScopeChanged() {
        let now = accountScope()
        guard now != scope else { return }
        scope = now; ratings = [:]; gaps = [:]; order = []; current = nil; taken = false
    }
}
