import AccountSession
import Foundation
import Observation

/// Creating a playlist. New playlists are private unless the person picks otherwise: `PlaylistCreator.defaultPrivacy` is the single
/// source of that default for the request and for the form.
///
/// The playlist list is read before the request leaves, so a create whose outcome is unknown can be settled by reading it again: one
/// new playlist with the requested title is the created one, none means nothing was created (and Try Again is offered), several are
/// ambiguous and are shown for the person to pick. A create is never sent again before that read.
@MainActor @Observable public final class PlaylistCreator {
    public static let defaultPrivacy = MusicPlaylistPrivacy.private

    public enum State: Equatable, Sendable {
        case idle, creating
        case created(playlistID: String)
        case failed(PlaylistFailure)
        case needsReconciliation
        /// Several new playlists carry the requested title; the person says which one is theirs.
        case ambiguous([PlaylistListing])
    }
    public private(set) var state: State = .idle
    @ObservationIgnored private let service: any PlaylistServing
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var attempt: (request: MusicPlaylistRequest, before: Set<String>)?
    /// How many reads in a row still did not show the new playlist (the library list can lag just after a create).
    @ObservationIgnored public private(set) var notSeenReads = 0
    @ObservationIgnored public private(set) var sentCount = 0

    /// W27 (New playlist visibility, default private): where the New Playlist form starts. Settings supplies the account's stored choice; a form still lets the
    /// person pick, and nothing is sent until Create.
    @ObservationIgnored public var startingVisibility: @MainActor () -> MusicPlaylistPrivacy = { PlaylistCreator.defaultPrivacy }

    public init(service: any PlaylistServing, accountScope: @escaping @MainActor () -> String = { "" }, signedIn: @escaping @MainActor () -> SearchPlayback = { .available }) {
        self.service = service; self.accountScope = accountScope; self.signedIn = signedIn
    }

    /// Creates a playlist for an explicit action. `songs` are added in the same request (at most 50).
    public func create(title: String, description: String? = nil, privacy: MusicPlaylistPrivacy = PlaylistCreator.defaultPrivacy, songs: [PlaylistAddition] = []) async {
        guard state != .creating, state != .needsReconciliation else { return }
        let request = MusicPlaylistRequest.create(title: title.trimmingCharacters(in: .whitespacesAndNewlines), description: description, privacy: privacy, videoIDs: songs.map(\.videoID))
        guard request.isWellFormed else { state = .failed(.invalid); return }
        switch signedIn() {
        case .needsSignIn: state = .failed(.needsSignIn); return
        case .sessionExpired: state = .failed(.sessionEnded); return
        case .available: break
        }
        state = .creating
        let ticket = generation, scope = accountScope()
        let listed: [PlaylistListing]
        do { listed = try await service.listing() }
        catch { guard ticket == generation else { return }; state = .failed(PlaylistEditSession.failure(for: error, reading: true)); return }
        guard ticket == generation, accountScope() == scope else { return }
        // Trying again after an unknown create: the earlier request may have landed and the list may only now show it. Look first.
        if let earlier = attempt, earlier.request == request, case .create(let wanted, _, _, _) = request {
            let late = listed.filter { !earlier.before.contains($0.playlistID) && $0.title == wanted }
            if late.count == 1 { state = .created(playlistID: late[0].playlistID); return }
            if late.count > 1 { state = .ambiguous(late); return }
        }
        let before = Set(listed.map(\.playlistID))
        attempt = (request, before); notSeenReads = 0
        sentCount += 1
        do {
            let reply = try await service.apply(request)
            guard ticket == generation, accountScope() == scope else { return }
            switch reply.result.outcome {
            case .confirmed:
                if let id = reply.result.createdPlaylistID { state = .created(playlistID: id) } else { state = .needsReconciliation }
            case .rejected(let why): state = .failed(PlaylistEditSession.failure(for: why))
            case .indeterminate: state = .needsReconciliation
            }
        } catch {
            guard ticket == generation else { return }
            let cancelled = error is CancellationError || (error as? MusicSessionError) == .cancelled
            state = cancelled ? .needsReconciliation : .failed(PlaylistEditSession.failure(for: error, reading: false))
        }
    }
    /// After an unknown outcome: read the playlist list. Nothing is sent.
    public func check() async {
        guard state == .needsReconciliation, let attempt, case .create(let title, _, _, _) = attempt.request else { return }
        guard let listing = try? await service.listing() else { return }
        let fresh = listing.filter { !attempt.before.contains($0.playlistID) && $0.title == title }
        switch fresh.count {
        case 0:
            // One read that does not show it is "not seen yet"; two in a row are "not created".
            notSeenReads += 1
            if notSeenReads >= 2 { state = .failed(.notApplied) }
        case 1: state = .created(playlistID: fresh[0].playlistID)
        default: state = .ambiguous(fresh)
        }
    }
    /// The person picks which of several look-alike new playlists is theirs.
    public func choose(_ playlistID: String) {
        guard case .ambiguous(let options) = state, options.contains(where: { $0.playlistID == playlistID }) else { return }
        state = .created(playlistID: playlistID)
    }
    public func reset() { state = .idle; attempt = nil; notSeenReads = 0 }
    public func accountChanged() { generation &+= 1; state = .idle; attempt = nil; notSeenReads = 0 }
}
