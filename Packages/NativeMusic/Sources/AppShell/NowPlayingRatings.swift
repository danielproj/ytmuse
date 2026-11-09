import AccountSession
import Features
import Foundation
import Observation

/// The rating of the song that is playing, so the player surfaces can offer Like and Dislike for every song and not only for one that was
/// shown on a page first. A song from a mix, a radio or the queue carries no rating of its own (the queue rows of a `next` answer have
/// none), so each time a new song starts this reads that song's own `next` once, signed, and keeps the like button it published
/// (`MusicWatchRatingParser`). Nothing is read during an advertisement, signed out, for owned media, or under the development and
/// UI-automation launches (`read` is nil there). Nothing here writes: a press still goes through `LibraryControlPress` and the one ledger.
///
/// Ratings belong to an account: everything is forgotten when the account scope changes, and an answer that arrives after the scope changed
/// is dropped.
@MainActor @Observable final class NowPlayingRatings {
    /// Why a song has no rating to offer yet.
    enum Gap: Equatable { case reading, notOffered, signedOut, failed }
    typealias Reader = @MainActor (String) async throws -> MusicItemControls.Like?

    private(set) var ratings: [String: MusicItemControls.Like] = [:]
    private(set) var gaps: [String: Gap] = [:]
    @ObservationIgnored private var order: [String] = []
    /// The song the last report was about; a new read starts only when this changes.
    @ObservationIgnored private(set) var current: String?
    @ObservationIgnored private var scope: String?
    @ObservationIgnored private let read: Reader?
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    static let limit = 64

    init(read: Reader?, accountScope: @escaping @MainActor () -> String, signedIn: @escaping @MainActor () -> SearchPlayback) {
        self.read = read; self.accountScope = accountScope; self.signedIn = signedIn
    }

    func like(for videoID: String) -> MusicItemControls.Like? { ratings[videoID] }
    func gap(for videoID: String) -> Gap? { ratings[videoID] == nil ? gaps[videoID] : nil }

    /// One player report. Cheap when the song has not changed (reports arrive several times a second).
    func observe(videoID: String?, isAd: Bool) {
        resetIfScopeChanged()
        guard !isAd, let videoID, Self.isVideoID(videoID), videoID != current else { return }
        current = videoID
        gaps = [:]   // only the song that is playing can be missing a rating
        guard let read else { return }
        guard signedIn() == .available else { gaps[videoID] = .signedOut; return }
        gaps[videoID] = .reading
        let scope = self.scope
        Task { [weak self] in
            let outcome: Result<MusicItemControls.Like?, any Error>
            do { outcome = .success(try await read(videoID)) } catch { outcome = .failure(error) }
            self?.settleRead(videoID, scope: scope, outcome)
        }
    }

    /// After a press the person made that the ledger did not reject: the service now holds `status`, so a later read of this song's page that
    /// clears the ledger's entry falls back to the right state, not the one read before the press.
    func settle(_ videoID: String, to status: MusicLikeStatus) {
        guard let like = ratings[videoID] else { return }
        ratings[videoID] = .init(videoID: videoID, status: status, dislikeExposed: like.dislikeExposed)
    }

    private func settleRead(_ videoID: String, scope: String?, _ outcome: Result<MusicItemControls.Like?, any Error>) {
        guard scope == self.scope, accountScope() == scope else { return }
        switch outcome {
        case .success(let like?):
            if ratings[videoID] == nil { order.append(videoID) }
            ratings[videoID] = like
            gaps[videoID] = nil
            while order.count > Self.limit { ratings[order.removeFirst()] = nil }
        case .success(nil):
            gaps[videoID] = .notOffered
        case .failure(let error):
            switch error as? MusicSessionError {
            case .notSignedIn?, .signedOut?: gaps[videoID] = .signedOut
            default: gaps[videoID] = .failed
            }
        }
    }
    /// The video-id shape the adapter accepts (`MusicBrowseParser.isVideoID`), so an id the page reported in any other shape is never sent.
    static func isVideoID(_ id: String) -> Bool { id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil }
    private func resetIfScopeChanged() {
        let now = accountScope()
        guard now != scope else { return }
        scope = now; ratings = [:]; gaps = [:]; order = []; current = nil
    }
}
