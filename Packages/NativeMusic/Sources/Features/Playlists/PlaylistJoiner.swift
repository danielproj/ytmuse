import AccountSession
import Foundation
import Observation

/// Joining a collaborative playlist from an invite link the person pastes. Nothing is sent from a link by itself: the link is parsed
/// strictly, the playlist is read (a read) to name it and to see whether the person already collaborates, and the join request goes out
/// only after the confirmation that names the playlist. The `jct` token lives only here, for that one request.
@MainActor @Observable public final class PlaylistJoiner {
    public struct Offer: Equatable, Sendable {
        public let playlistID: String
        public let title: String
        fileprivate let token: String
    }
    public enum State: Equatable, Sendable {
        case idle, reading
        /// The link is not a valid invite link (host, path, playlist id or token).
        case invalidLink
        case offer(Offer)
        /// The service already shows this person as able to edit the playlist: nothing is sent.
        case alreadyMember(title: String)
        case joining
        case joined(playlistID: String)
        case failed(PlaylistFailure)
        case needsReconciliation
    }
    public private(set) var state: State = .idle
    @ObservationIgnored private let service: any PlaylistServing
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var pending: Offer?
    @ObservationIgnored public private(set) var sentCount = 0

    public init(service: any PlaylistServing, accountScope: @escaping @MainActor () -> String = { "" }, signedIn: @escaping @MainActor () -> SearchPlayback = { .available }) {
        self.service = service; self.accountScope = accountScope; self.signedIn = signedIn
    }
    /// The confirmation a join needs: it names the playlist.
    public var joinPrompt: PlaylistPrompt? {
        guard case .offer(let offer) = state else { return nil }
        return PlaylistPrompt(action: .join, playlistTitle: offer.title, count: 1, names: [offer.title])
    }
    /// Reads the playlist an invite link names. Sends nothing.
    public func prepare(link: String) async {
        guard state != .reading, state != .joining else { return }
        guard let parsed = PlaylistSharing.invite(fromLink: link), MusicPlaylistRequest.isEditablePlaylistID(parsed.playlistID) else { state = .invalidLink; return }
        switch signedIn() {
        case .needsSignIn: state = .failed(.needsSignIn); return
        case .sessionExpired: state = .failed(.sessionEnded); return
        case .available: break
        }
        state = .reading
        let ticket = generation, scope = accountScope()
        do {
            let page = try await service.read(playlistID: parsed.playlistID)
            guard ticket == generation, accountScope() == scope else { return }
            let name = page.title.isEmpty ? String(localized: "this playlist") : page.title
            if page.role.canEdit { state = .alreadyMember(title: name); pending = nil; return }
            let offer = Offer(playlistID: parsed.playlistID, title: name, token: parsed.token)
            pending = offer; state = .offer(offer)
        } catch { guard ticket == generation else { return }; state = .failed(PlaylistEditSession.failure(for: error, reading: true)) }
    }
    /// Joins, for an explicit press, with the confirmation that names the playlist.
    public func join(confirmation: PlaylistPrompt?) async {
        guard case .offer(let offer) = state, let prompt = joinPrompt, confirmation == prompt else {
            if case .offer = state { state = .failed(.needsConfirmation) }
            return
        }
        let request = MusicPlaylistRequest.edit(playlistID: offer.playlistID, actions: [.joinCollaboration(token: offer.token)])
        guard request.isWellFormed else { state = .failed(.invalid); return }
        switch signedIn() {
        case .needsSignIn: state = .failed(.needsSignIn); return
        case .sessionExpired: state = .failed(.sessionEnded); return
        case .available: break
        }
        state = .joining
        let ticket = generation, scope = accountScope()
        sentCount += 1
        do {
            let reply = try await service.apply(request)
            guard ticket == generation, accountScope() == scope else { return }
            switch reply.result.outcome {
            case .confirmed: state = .joined(playlistID: offer.playlistID); pending = nil
            case .rejected(let why): state = .failed(PlaylistEditSession.failure(for: why))
            case .indeterminate: state = .needsReconciliation
            }
        } catch {
            guard ticket == generation else { return }
            let cancelled = error is CancellationError || (error as? MusicSessionError) == .cancelled
            state = cancelled ? .needsReconciliation : .failed(PlaylistEditSession.failure(for: error, reading: false))
        }
    }
    /// After an unknown outcome: read the playlist. If the service now lets this person edit it, the join happened. Nothing is sent.
    public func check() async {
        guard state == .needsReconciliation, let pending else { return }
        guard let page = try? await service.read(playlistID: pending.playlistID) else { return }
        state = page.role.canEdit ? .joined(playlistID: pending.playlistID) : .failed(.notApplied)
    }
    public func reset() { state = .idle; pending = nil }
    public func accountChanged() { generation &+= 1; state = .idle; pending = nil }
}
