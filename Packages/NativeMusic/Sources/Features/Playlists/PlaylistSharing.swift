import AccountSession
import Foundation

/// The canonical link to a playlist, and what a link given to the app may mean. Only an explicit Copy Link or Share action by the
/// person hands a link out; nothing is sent to the service, and nothing is ever shared on the person's behalf.
public enum PlaylistSharing {
    private static let hosts: Set<String> = ["music.youtube.com", "www.youtube.com", "youtube.com", "m.youtube.com"]
    private static let idPattern = #"^[A-Za-z0-9_-]{10,128}$"#

    /// The Music site's `/playlist?list=<id>` link, or nil if the id is not one the service uses. A `VL…` page id is accepted and
    /// reduced to the playlist id.
    public static func canonicalURL(playlistID: String) -> URL? {
        let id = MusicPlaylistRequest.playlistID(fromBrowseID: playlistID)
        guard id.range(of: idPattern, options: .regularExpression) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "https"; components.host = "music.youtube.com"; components.path = "/playlist"
        components.queryItems = [URLQueryItem(name: "list", value: id)]
        return components.url
    }
    /// The playlist id a pasted link names. Strict: https only, a YouTube host, the `/playlist` path, exactly one `list` value of a valid
    /// shape, no user, password, port or fragment. Tracking parameters are ignored and dropped.
    public static func playlistID(fromLink text: String) -> String? {
        guard text.utf8.count <= 2048, let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let host = components.host?.lowercased(), hosts.contains(host), components.path == "/playlist" else { return nil }
        let lists = (components.queryItems ?? []).filter { $0.name == "list" }
        guard lists.count == 1, let id = lists[0].value, id.range(of: idPattern, options: .regularExpression) != nil else { return nil }
        return id
    }
    /// A collaboration invite link's playlist and its `jct` join token. Strict like `playlistID(fromLink:)`, and in addition: exactly one
    /// `jct` value of a valid shape. The token is for joining only and is never part of the plain share link.
    public static func invite(fromLink text: String) -> (playlistID: String, token: String)? {
        guard let id = playlistID(fromLink: text), let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let tokens = (components.queryItems ?? []).filter { $0.name == "jct" }
        guard tokens.count == 1, let token = tokens[0].value, MusicPlaylistRequest.isJoinToken(token) else { return nil }
        return (id, token)
    }
    /// The invite link the service returned, in canonical form, only if it names this playlist and carries a valid token; otherwise nil
    /// (the person is told no link came back, and nothing the service printed is shown as a link).
    public static func inviteLink(from text: String?, playlistID: String) -> URL? {
        guard let text, let parsed = invite(fromLink: text), parsed.playlistID == MusicPlaylistRequest.playlistID(fromBrowseID: playlistID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"; components.host = "music.youtube.com"; components.path = "/playlist"
        components.queryItems = [URLQueryItem(name: "list", value: parsed.playlistID), URLQueryItem(name: "jct", value: parsed.token)]
        return components.url
    }
    /// What the person should know before sharing: a private playlist's link opens only for them.
    public static func note(for privacy: MusicPlaylistPrivacy?) -> String? {
        switch privacy {
        case .private?: String(localized: "This playlist is private, so only you can open its link. Change its visibility first to share it.")
        case .unlisted?: String(localized: "Anyone with the link can open this playlist.")
        case .public?: String(localized: "This playlist is public.")
        case nil: nil
        }
    }
}
