import AccountSession
import Foundation

/// Playlist changes over the signed client. A change is sent only for an explicit user action (the playlist editing session is the one
/// caller), is built from occurrence ids the service itself published, and counts as made only on the service's positive statement.
extension SignedMusicClient {
    /// Sends one playlist request. A failure before anything was sent throws; once the request has left, a lost connection or an
    /// unreadable answer is `indeterminate`, because the service may have applied it: the playlist is read before anything is repeated.
    public func editPlaylist(_ request: MusicPlaylistRequest, session: MusicCookieSession) async throws -> MusicSignedResult<MusicPlaylistOutcome> {
        guard request.isWellFormed else { throw MusicSessionError.policy }
        let (endpoint, body) = Self.wire(request)
        let sent = PlaylistSubmission()
        do {
            let (root, rotation) = try await post(endpoint, body: body, session: session, limit: 1_000_000, onSubmit: { sent.mark() })
            if Self.loggedOut(root) { throw MusicSessionError.signedOut }
            return .init(value: Self.classify(request, root), rotation: rotation)
        } catch {
            let mapped = (error as? MusicSessionError) ?? DirectSignedMusicTransport.classify(error)
            switch mapped {
            case .signedOut, .policy, .stale, .notSignedIn, .invalidSession: throw mapped
            case .rateLimited: return .init(value: .init(outcome: .rejected(.rateLimited)), rotation: [])
            case .server: return .init(value: .init(outcome: .rejected(.unavailable)), rotation: [])
            case .cancelled, .network, .timedOut, .oversized, .unrecognised:
                if sent.value {
                    return .init(value: .init(outcome: .indeterminate(mapped == .unrecognised || mapped == .oversized ? .unrecognisedAnswer : .noAnswer)), rotation: [])
                }
                throw mapped == .cancelled && !(error is MusicSessionError) ? error : mapped
            default: throw mapped
            }
        }
    }
    private final class PlaylistSubmission: @unchecked Sendable {
        private let lock = NSLock(); private var flag = false
        func mark() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }

    /// The endpoint and body of a playlist request: the shapes the service's own web client sends (`playlist/create`, `browse/edit_playlist`,
    /// `playlist/delete`). A new playlist's privacy is always stated, never left to a default.
    static func wire(_ request: MusicPlaylistRequest) -> (endpoint: String, body: [String: Any]) {
        switch request {
        case .create(let title, let description, let privacy, let videos):
            var body: [String: Any] = ["title": title, "privacyStatus": privacy.rawValue]
            if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["description"] = description }
            if !videos.isEmpty { body["videoIds"] = videos }
            return ("playlist/create", body)
        case .delete(let id):
            return ("playlist/delete", ["playlistId": id])
        case .edit(let id, let actions):
            return ("browse/edit_playlist", ["playlistId": id, "actions": actions.map(wire)])
        }
    }
    static func wire(_ action: MusicPlaylistEditAction) -> [String: Any] {
        switch action {
        case .add(let video, let mode):
            // ytmusicapi `add_playlist_items` (4da34b6, lines 444-464): `if duplicates: action["dedupeOption"] = "DEDUPE_OPTION_SKIP"`,
            // and without it "an error will be returned if there are duplicates (no items are added)". Kaset (`:1617`) sends none and
            // relies on the server de-duping. So SKIP (skip the check) is how a duplicate is *kept*; leaving it off is how one is *skipped*.
            var result: [String: Any] = ["action": "ACTION_ADD_VIDEO", "addedVideoId": video]
            if mode == .keepDuplicates { result["dedupeOption"] = "DEDUPE_OPTION_SKIP" }
            return result
        case .remove(let video, let occurrence):
            return ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": video, "setVideoId": occurrence]
        case .moveBefore(let occurrence, let successor):
            var result: [String: Any] = ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": occurrence]
            if let successor { result["movedSetVideoIdSuccessor"] = successor }
            return result
        case .rename(let title): return ["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title]
        case .describe(let text): return ["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": text]
        case .setPrivacy(let privacy): return ["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": privacy.rawValue]
        case .createInviteLink: return ["action": "ACTION_CREATE_COLLABORATION_INVITE_LINK"]
        case .closeToContributions: return ["action": "ACTION_SET_CLOSED_TO_CONTRIBUTIONS", "closedToContributions": true]
        case .joinCollaboration(let token): return ["action": "ACTION_JOIN_COLLABORATION", "joinCollaborationToken": token]
        }
    }

    /// Reads the answer. An `error` object (or `errors`) means refused; a created playlist needs its id; an edit needs the service's own
    /// `STATUS_SUCCEEDED` (any other status is a refusal); a delete has no status the app has seen, so only an explicit success status
    /// counts and a bare 200 is not evidence (the playlist list is then read).
    static func classify(_ request: MusicPlaylistRequest, _ root: [String: Any]) -> MusicPlaylistOutcome {
        if root["error"] != nil { return .init(outcome: .rejected(.service)) }
        if let errors = root["errors"] as? [Any], !errors.isEmpty { return .init(outcome: .rejected(.service)) }
        switch request {
        case .create:
            guard let id = root["playlistId"] as? String, MusicPlaylistRequest.isEditablePlaylistID(id) else { return .init(outcome: .indeterminate(.unrecognisedAnswer)) }
            return .init(outcome: .confirmed, createdPlaylistID: id)
        case .delete:
            return .init(outcome: status(root) == "STATUS_SUCCEEDED" ? .confirmed : status(root) != nil ? .rejected(.service) : .indeterminate(.unrecognisedAnswer))
        case .edit:
            switch status(root) {
            case "STATUS_SUCCEEDED": return .init(outcome: .confirmed, added: addedOccurrences(root), inviteLink: root["collaborationInviteLink"] as? String)
            case nil: return .init(outcome: .indeterminate(.unrecognisedAnswer))
            default: return .init(outcome: .rejected(.service))
            }
        }
    }
    private static func status(_ root: [String: Any]) -> String? { root["status"] as? String }
    /// The occurrences an add reported: `playlistEditResults[].playlistEditVideoAddedResultData` (or the flattened form).
    private static func addedOccurrences(_ root: [String: Any]) -> [MusicPlaylistAddedOccurrence] {
        var result: [MusicPlaylistAddedOccurrence] = []
        for entry in root["playlistEditResults"] as? [[String: Any]] ?? [] {
            let data = (entry["playlistEditVideoAddedResultData"] as? [String: Any]) ?? entry
            if let video = data["videoId"] as? String, let set = data["setVideoId"] as? String,
               MusicPlaylistRequest.isVideoID(video), MusicPlaylistRequest.isOccurrenceID(set) { result.append(.init(videoID: video, setVideoID: set)) }
        }
        return result
    }
}
