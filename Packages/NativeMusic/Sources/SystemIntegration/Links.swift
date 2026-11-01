import Foundation

// W26 (MAC07, T26.2). Which links the app accepts, and the canonical public links it hands out.
//
// A link NAVIGATES, nothing else. It never plays audio, runs a command, or changes the account: opening a song's link shows the song's page, and
// starting playback there is the same explicit press as anywhere else. This file is pure: it takes a URL or text and returns a destination or a
// refusal. It never fetches anything, never follows a redirect and never resolves a name, so a link to an unknown host (or to a local-network
// address) costs nothing and reaches nothing (`LinkPolicyTests` sweep this directory for any networking API).
//
// Universal links are out of scope: they need a domain the project controls (an `apple-app-site-association` file served over HTTPS), and no
// domain is under the project's control. The app registers its own `ytmuse` scheme only, and `youtube.com` links are never claimed.

public enum LinkItemKind: String, Sendable, CaseIterable {
    case song, album, artist, playlist, podcast, episode
}
/// An item page a link can open: a kind and a service identifier whose shape was checked for that kind.
public struct LinkItem: Equatable, Hashable, Sendable {
    public let kind: LinkItemKind
    public let identifier: String
    public init?(kind: LinkItemKind, identifier: String) {
        guard LinkShapes.matches(identifier, kind: kind) else { return nil }
        self.kind = kind; self.identifier = identifier
    }
}
/// A top-level screen the app's own scheme can open (`ytmuse://library`).
public enum LinkScreen: String, Sendable, CaseIterable { case home, explore, search, library, downloads, history, uploads, podcasts, queue }
public enum LinkDestination: Equatable, Sendable {
    case item(LinkItem)
    case screen(LinkScreen)
}
/// One refusal. The reasons exist for tests and the log; every one reaches the person as the SAME sentence (`message`), so a refusal never says
/// which part of a link was wrong, and never echoes the link.
public enum LinkRefusal: Error, Equatable, Sendable {
    case notALink, tooLong, scheme, host, credentials, port, fragment, path, identifier, query, encoded, characters
    public static var message: String { String(localized: "This link cannot be opened. Use a YouTube Music link to a song, album, artist or playlist.") }
}

enum LinkShapes {
    private static let urlSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    static func allURLSafe(_ text: Substring) -> Bool { text.unicodeScalars.allSatisfy { urlSafe.contains($0) } }
    static func allURLSafe(_ text: String) -> Bool { allURLSafe(Substring(text)) }
    /// A YouTube video id: 11 URL-safe characters.
    static func isVideoID(_ text: String) -> Bool { text.utf8.count == 11 && allURLSafe(text) }
    /// Playlist ids start with a prefix YouTube uses for playlists, albums-as-playlists, mixes and uploads; `LM` (Liked Music) and other special
    /// ids are never accepted from a link.
    static let playlistPrefixes = ["PL", "OLAK5uy_", "RDCLAK5uy_", "RDAMPL", "RDAMVM", "RDEM", "RDGMEM", "RDMM", "RD", "UU", "FL"]
    static func isPlaylistID(_ text: String) -> Bool {
        guard (13...64).contains(text.utf8.count), allURLSafe(text) else { return false }
        return playlistPrefixes.contains { text.hasPrefix($0) }
    }
    static func isChannelID(_ text: String) -> Bool { text.utf8.count == 24 && text.hasPrefix("UC") && allURLSafe(text) }
    static func isAlbumID(_ text: String) -> Bool { text.hasPrefix("MPREb_") && (12...40).contains(text.utf8.count) && allURLSafe(text) }
    static func isPodcastID(_ text: String) -> Bool { text.hasPrefix("MPSP") && (8...72).contains(text.utf8.count) && allURLSafe(text) }
    static func isEpisodeID(_ text: String) -> Bool { text.hasPrefix("MPED") && (8...72).contains(text.utf8.count) && allURLSafe(text) }
    static func matches(_ text: String, kind: LinkItemKind) -> Bool {
        switch kind {
        case .song: isVideoID(text)
        case .playlist: isPlaylistID(text)
        case .artist: isChannelID(text)
        case .album: isAlbumID(text)
        case .podcast: isPodcastID(text)
        case .episode: isEpisodeID(text)
        }
    }
    /// Characters that make a link ambiguous or invisible: controls, whitespace, bidirectional overrides, zero-width and format characters.
    static func hasHiddenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .privateUse, .unassigned, .surrogate: true
            default: false
            }
        }
    }
}

public enum LinkPolicy {
    public static let maximumLength = 2048
    /// The only app scheme.
    public static let appScheme = "ytmuse"
    public static let musicHost = "music.youtube.com"
    /// Hosts whose song/video, playlist and channel links are accepted (as navigation to the matching item page). Exact names only: no subdomain
    /// wildcards, no trailing dot, no IP literal, no port.
    static let youtubeHosts: Set<String> = ["www.youtube.com", "youtube.com", "m.youtube.com"]
    static let shortHost = "youtu.be"

    /// Text from a paste, a drop or a Service. One line, optional surrounding white space, one URL.
    public static func parse(text: String) -> Result<LinkDestination, LinkRefusal> {
        // Only plain ASCII white space around a pasted link is dropped. Zero-width, no-break and bidirectional characters are not "white space": they are
        // refused below, wherever they sit.
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumLength else { return .failure(trimmed.isEmpty ? .notALink : .tooLong) }
        guard !LinkShapes.hasHiddenCharacters(trimmed), let url = URL(string: trimmed) else { return .failure(.characters) }
        return parse(url)
    }

    public static func parse(_ url: URL) -> Result<LinkDestination, LinkRefusal> {
        let text = url.absoluteString
        guard text.utf8.count <= maximumLength else { return .failure(.tooLong) }
        guard !LinkShapes.hasHiddenCharacters(text) else { return .failure(.characters) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased() else { return .failure(.notALink) }
        guard components.user == nil, components.password == nil else { return .failure(.credentials) }
        guard components.port == nil else { return .failure(.port) }
        guard components.fragment == nil else { return .failure(.fragment) }
        // Anything percent-encoded in the host, path or query is refused outright: no canonical link needs it, and an encoded `/`, `?`, `.` or
        // `%` is how a path or a parameter is smuggled past a check made on the decoded form.
        guard !components.percentEncodedPath.contains("%"), !(components.percentEncodedHost ?? "").contains("%"), !(components.percentEncodedQuery ?? "").contains("%") else { return .failure(.encoded) }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return .failure(.host) }
        switch scheme {
        case appScheme: return parseApp(host: host, components: components)
        case "https": return parseWeb(host: host, components: components)
        default: return .failure(.scheme)
        }
    }

    // MARK: The app's own scheme: ytmuse://<kind>/<id> and ytmuse://<screen>. No query, ever.

    private static func parseApp(host: String, components: URLComponents) -> Result<LinkDestination, LinkRefusal> {
        // A parameter on an app link would be the place to hide an action (`?action=play`). There are none: a link opens a page.
        guard components.query == nil, components.queryItems == nil else { return .failure(.query) }
        let path = components.path
        if let screen = LinkScreen(rawValue: host) {
            guard path.isEmpty || path == "/" else { return .failure(.path) }
            return .success(.screen(screen))
        }
        guard let kind = LinkItemKind(rawValue: host) else { return .failure(.host) }
        guard path.hasPrefix("/"), !path.dropFirst().contains("/") else { return .failure(.path) }
        guard let item = LinkItem(kind: kind, identifier: String(path.dropFirst())) else { return .failure(.identifier) }
        return .success(.item(item))
    }

    // MARK: Web links

    private static func parseWeb(host: String, components: URLComponents) -> Result<LinkDestination, LinkRefusal> {
        let isMusic = host == musicHost
        guard isMusic || youtubeHosts.contains(host) || host == shortHost else { return .failure(.host) }
        let items = components.queryItems ?? []
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value, !value.isEmpty else { return .failure(.query) }
            values[item.name] = value
        }
        // Tracking parameters YouTube adds when it shares a link. They carry no destination and are checked for shape, then dropped.
        func trackingOK() -> Bool {
            if let si = values["si"], !(1...40).contains(si.utf8.count) || !LinkShapes.allURLSafe(si) { return false }
            if let feature = values["feature"], !(1...32).contains(feature.utf8.count) || !feature.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || $0 == "_" || $0 == "-" }) { return false }
            return true
        }
        let allowed: (Set<String>) -> Bool = { Set(values.keys).isSubset(of: $0) }
        let path = components.path
        if host == shortHost {
            // https://youtu.be/<video id>[?si=...]
            guard allowed(["si", "feature"]), trackingOK() else { return .failure(.query) }
            guard path.hasPrefix("/"), !path.dropFirst().contains("/") else { return .failure(.path) }
            guard let item = LinkItem(kind: .song, identifier: String(path.dropFirst())) else { return .failure(.identifier) }
            return .success(.item(item))
        }
        switch path {
        case "/watch":
            guard allowed(["v", "list", "si", "feature"]), trackingOK() else { return .failure(.query) }
            guard let video = values["v"] else { return .failure(.query) }
            // A list that rides along with a video (a radio, a playlist the person was in) must itself be a playlist id; the link still opens the SONG.
            if let list = values["list"], !LinkShapes.isPlaylistID(list) { return .failure(.identifier) }
            guard let item = LinkItem(kind: .song, identifier: video) else { return .failure(.identifier) }
            return .success(.item(item))
        case "/playlist":
            guard allowed(["list", "si", "feature"]), trackingOK() else { return .failure(.query) }
            guard let list = values["list"], let item = LinkItem(kind: .playlist, identifier: list) else { return .failure(.identifier) }
            return .success(.item(item))
        default: break
        }
        guard allowed(["si", "feature"]), trackingOK() else { return .failure(.query) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // ["", "channel", "<id>"] or ["", "browse", "<id>"]: exactly two segments, no trailing slash, no empty or dot segment.
        guard parts.count == 3, parts[0].isEmpty, !parts[2].isEmpty, parts[2] != ".", parts[2] != ".." else { return .failure(.path) }
        switch (parts[1], isMusic) {
        case ("channel", _):
            guard let item = LinkItem(kind: .artist, identifier: parts[2]) else { return .failure(.identifier) }
            return .success(.item(item))
        case ("browse", true):
            // A music.youtube.com browse id: an album, an artist's channel, a podcast show or an episode. `VL` + a playlist id is the playlist's page.
            let id = parts[2]
            let kinds: [LinkItemKind] = [.album, .artist, .podcast, .episode]
            if let kind = kinds.first(where: { LinkShapes.matches(id, kind: $0) }), let item = LinkItem(kind: kind, identifier: id) { return .success(.item(item)) }
            if id.hasPrefix("VL"), let item = LinkItem(kind: .playlist, identifier: String(id.dropFirst(2))) { return .success(.item(item)) }
            return .failure(.identifier)
        default: return .failure(.path)
        }
    }
}

/// The public link for an item, and the only form the app ever hands out (Share, Copy Link, Services, Handoff, AppleScript). Always
/// `https://music.youtube.com/...`, always re-read through `LinkPolicy` before it is returned, and never anything but the item's own identifier:
/// no `si`, no cookie, no token, no signed URL, no local path.
public enum CanonicalLink {
    public static func url(for item: LinkItem) -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = LinkPolicy.musicHost
        switch item.kind {
        case .song: components.path = "/watch"; components.queryItems = [URLQueryItem(name: "v", value: item.identifier)]
        case .playlist: components.path = "/playlist"; components.queryItems = [URLQueryItem(name: "list", value: item.identifier)]
        case .artist: components.path = "/channel/" + item.identifier
        case .album, .podcast, .episode: components.path = "/browse/" + item.identifier
        }
        // The components were built from checked parts; a result that does not read back as the same item would be a bug, never a link to hand out.
        guard let url = components.url, case .success(.item(let back)) = LinkPolicy.parse(url), back == item else { preconditionFailure("canonical link did not round-trip") }
        return url
    }
    public static func url(kind: LinkItemKind, identifier: String) -> URL? { LinkItem(kind: kind, identifier: identifier).map(url(for:)) }
    /// The share link for the song that is playing; nil when the identifier is not a YouTube video id.
    public static func song(videoID: String) -> URL? { url(kind: .song, identifier: videoID) }
}
