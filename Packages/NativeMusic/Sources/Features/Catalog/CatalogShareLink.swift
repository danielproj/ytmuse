import AccountSession
import Foundation

/// The one place that decides which public link an entry, a search result or a page hands out for Copy Link and Share.
///
/// Only the entity's own identifier is ever used, and only when it has the shape the service uses for that kind of entity; a malformed,
/// private or unsupported identifier gives no link at all (the action is then not offered). The result is always
/// a music.youtube.com link over HTTPS with the entity's identifier as the only parameter: no `si`, no `feature`, no playback context (`list` on a
/// song, `index`, `t`), no continuation, no invite token, no local path. Nothing here reads the network or the account.
///
/// The shapes mirror `SystemIntegration.LinkShapes`, which this module may not depend on; `ShareLinkAgreementTests` round-trips every kind
/// through `LinkPolicy` and `CanonicalLink` so the two cannot drift apart.
public enum CatalogShareLink {
    private static let urlSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    private static func allURLSafe(_ text: String) -> Bool { text.unicodeScalars.allSatisfy { urlSafe.contains($0) } }

    static func isVideoID(_ text: String) -> Bool { text.utf8.count == 11 && allURLSafe(text) }
    static func isChannelID(_ text: String) -> Bool { text.utf8.count == 24 && text.hasPrefix("UC") && allURLSafe(text) }
    static func isAlbumBrowseID(_ text: String) -> Bool { text.hasPrefix("MPREb_") && (12...40).contains(text.utf8.count) && allURLSafe(text) }
    static func isPodcastBrowseID(_ text: String) -> Bool { text.hasPrefix("MPSP") && (8...72).contains(text.utf8.count) && allURLSafe(text) }
    /// An album's own playlist: `OLAK5uy_…`. A radio or mix (`RD…`), a user playlist or a special list is NOT an album and never stands in for one.
    static func isAlbumPlaylistID(_ text: String) -> Bool { text.hasPrefix("OLAK5uy_") && (13...64).contains(text.utf8.count) && allURLSafe(text) }
    private static let playlistPrefixes = ["PL", "OLAK5uy_", "RDCLAK5uy_", "RDAMPL", "RDAMVM", "RDEM", "RDGMEM", "RDMM", "RD", "UU", "FL"]
    /// A playlist id the service publishes; the personal special lists (`LM`, `SE`…) are not in the set and are never handed out.
    static func isPlaylistID(_ text: String) -> Bool {
        (13...64).contains(text.utf8.count) && allURLSafe(text) && playlistPrefixes.contains { text.hasPrefix($0) }
    }
    /// The channel an artist browse id names: a bare `UC…` id, or the library's `MPLAUC…` form of it (a followed artist). Any other `MPLA…` form,
    /// and every other prefix, gives nil; the library's own parser is the single definition of the accepted shape.
    static func artistChannelID(fromBrowseID id: String) -> String? {
        guard let channel = MusicLibraryKind.channelID(fromBrowseID: id), isChannelID(channel) else { return nil }
        return channel
    }
    /// A playlist's browse id (`VL` + list id) reduced to the list id; any other id is returned unchanged.
    static func playlistID(fromBrowseID id: String) -> String { id.hasPrefix("VL") ? String(id.dropFirst(2)) : id }

    private static func make(_ path: String, _ query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"; components.host = "music.youtube.com"; components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }
    private static func watch(_ videoID: String) -> URL? { make("/watch", [URLQueryItem(name: "v", value: videoID)]) }
    private static func playlist(_ id: String) -> URL? { make("/playlist", [URLQueryItem(name: "list", value: id)]) }

    /// The link for an entity from the identifiers its row carried. Private service media, a category, and anything whose identifier does
    /// not have the right shape give nil. A song's own `playlistID` (the radio or album it sits in) is never part of its link.
    public static func url(kind: MusicEntityKind, videoID: String?, browseID: String?, playlistID: String?, isPrivate: Bool = false) -> URL? {
        guard !isPrivate else { return nil }
        switch kind {
        case .song, .video, .episode:
            return videoID.flatMap { isVideoID($0) ? watch($0) : nil }
        case .album:
            if let list = playlistID, isAlbumPlaylistID(list) { return playlist(list) }
            return browseID.flatMap { isAlbumBrowseID($0) ? make("/browse/" + $0) : nil }
        case .playlist:
            for candidate in [playlistID, browseID] {
                guard let candidate else { continue }
                let id = Self.playlistID(fromBrowseID: candidate)
                if isPlaylistID(id) { return playlist(id) }
            }
            return nil
        case .podcast:
            if let browse = browseID, isPodcastBrowseID(browse) { return make("/browse/" + browse) }
            return playlistID.flatMap { isPlaylistID($0) ? playlist($0) : nil }
        case .artist:
            return browseID.flatMap { artistChannelID(fromBrowseID: $0) }.flatMap { make("/channel/" + $0) }
        case .category:
            return nil
        }
    }
    public static func url(for item: MusicCatalogItem) -> URL? {
        url(kind: item.kind, videoID: item.videoID, browseID: item.browseID, playlistID: item.playlistID, isPrivate: item.isPrivatelyOwned)
    }
    /// The link for a page reopened by its route, with no row to read: the browse id alone says what it is. Parameters the page was opened with
    /// (moods, genres, "show all") are dropped. Home, Explore, charts and every other service page that is not an entity give nil.
    public static func url(for target: CatalogTarget) -> URL? {
        let id = target.browseID
        if isAlbumBrowseID(id) { return make("/browse/" + id) }
        if let channel = artistChannelID(fromBrowseID: id) { return make("/channel/" + channel) }
        if isPodcastBrowseID(id) { return make("/browse/" + id) }
        if id.hasPrefix("VL") { return isPlaylistID(playlistID(fromBrowseID: id)) ? playlist(playlistID(fromBrowseID: id)) : nil }
        return nil
    }

    /// Hands a link to the performer's share presentation (the system share sheet in a normal launch, a recording stand-in under isolation).
    /// Returns the sentence to show when nothing was presented, nil when the sheet was opened. Nothing is copied or sent by the app.
    @MainActor public static func share(_ link: URL?, via performer: any SearchActionPerformer) -> String? {
        guard let link else { return String(localized: "This item has no link.") }
        return performer.share(link: link) ? nil : String(localized: "Sharing isn’t available right now.")
    }
}
