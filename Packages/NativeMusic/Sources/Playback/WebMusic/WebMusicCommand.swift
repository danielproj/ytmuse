import Foundation
import Domain

/// The only operations native code performs on the hidden player. Each maps to a
/// constant script body plus typed arguments for `callAsyncJavaScript`; no
/// caller-supplied or page-supplied string is ever concatenated into script text.
public enum WebMusicCommand: Sendable, Equatable {
    case loadPlaylist(String, load: UInt64)
    /// A play endpoint the service published: the playlist, optionally starting at a video and/or carrying the service's own parameters (a shuffle flag).
    case loadTarget(String, videoID: String?, params: String?, load: UInt64)
    case updateRadioQueue(MusicQueueFilterCommand, document: UInt64, load: UInt64, videoID: String, currentPlaylistID: String)
    case play, pause
    case seek(Double)
    case next, previous
    case volume(Double)
    /// P17-WEB: the sleep timer's fade. `factor` scales the page element's own volume from the level it had when the fade began; `1` puts that
    /// level back. The page refuses it (reply `ad`) while an advertisement shows, and then leaves the volume where the person had it: a fade of an
    /// ad would be a mute in effect, which the playback addendum forbids.
    case fadeVolume(Double)
    /// W18: the listening speed of spoken audio, `0.5…3`, pitch preserved. Refused by the page during an ad.
    case rate(Double)
    /// W18: returns the element to 1x. Sent only when an advertisement is showing and the element reports another speed (an ad is always 1x).
    case normalSpeed
    /// W17: jump to the live edge; reduce the page to its video picture (or restore it); WebKit's Picture in Picture for the `<video>`.
    case goLive
    case presentVideo(Bool)
    case pictureInPicture(Bool)
    /// Quality is one of the levels the page itself offered; captions on/off. Both are the page's own player settings.
    case quality(String)
    case captions(Bool)
    /// CORE-A: plays an item of the page's own queue (one after the playing item), by handing the page's router that item's own published
    /// endpoint, as a click on its row does. The page refuses it (reply `ad`) while an advertisement shows.
    case playQueueItem(String)
    /// CORE-A: the page player bar's own shuffle and repeat controls. The page reads the state back and answers `ok` only when it took; it refuses (reply
    /// `ad`) while an advertisement shows, and never clicks a control whose state it cannot read.
    case shuffle(Bool)
    case repeatMode(WebMusicRepeatMode)

    public struct Invocation: @unchecked Sendable {
        public let body: String
        /// Only `String`, `Int` and `Double`/`Bool` values, already validated.
        public let arguments: [String: Any]
    }

    /// Fails closed for an invalid identifier or a non-finite/out-of-range number.
    public func invocation() throws(WebMusicCommandError) -> Invocation {
        switch self {
        case .loadPlaylist(let id, let load):
            guard WebMusicIdentifier.isPlaylistID(id), load > 0, load <= 9_007_199_254_740_991 else { throw .invalidArgument }
            return .init(body: WebMusicScripts.loadPlaylist, arguments: ["playlistId": id, "load": Int(load)])
        case .loadTarget(let id, let video, let params, let load):
            guard WebMusicIdentifier.isPlaylistID(id), load > 0, load <= 9_007_199_254_740_991,
                  video.map({ WebMusicIdentifier.isVideoID($0) }) ?? true,
                  params.map(WebMusicIdentifier.isEndpointParams) ?? true else { throw .invalidArgument }
            return .init(body: WebMusicScripts.loadTarget, arguments: ["playlistId": id, "videoId": video ?? "", "params": params ?? "", "load": Int(load)])
        case .updateRadioQueue(let command, let document, let load, let videoID, let currentPlaylistID):
            guard load > 0, load <= 9_007_199_254_740_991, document > 0, document <= 9_007_199_254_740_991,
                  WebMusicIdentifier.isVideoID(videoID), WebMusicIdentifier.isPlaylistID(currentPlaylistID) else { throw .invalidArgument }
            return .init(body: WebMusicScripts.updateRadioQueue, arguments: ["playlistId": command.playlistID,
                "params": command.params, "playerParams": command.playerParams ?? "", "section": command.section.rawValue, "load": Int(load),
                "documentID": Int(document), "videoId": videoID, "currentPlaylistId": currentPlaylistID])
        case .play: return .init(body: WebMusicScripts.play, arguments: [:])
        case .pause: return .init(body: WebMusicScripts.pause, arguments: [:])
        case .seek(let seconds):
            guard seconds.isFinite, (0...WebMusicBridge.maximumSeconds).contains(seconds) else { throw .invalidArgument }
            return .init(body: WebMusicScripts.seek, arguments: ["seconds": seconds])
        case .next: return .init(body: WebMusicScripts.skip, arguments: ["forward": true])
        case .previous: return .init(body: WebMusicScripts.skip, arguments: ["forward": false])
        case .volume(let level):
            guard level.isFinite, (0...1).contains(level) else { throw .invalidArgument }
            return .init(body: WebMusicScripts.volume, arguments: ["level": level])
        case .fadeVolume(let factor):
            guard factor.isFinite, (0...1).contains(factor) else { throw .invalidArgument }
            return .init(body: WebMusicScripts.fadeVolume, arguments: ["factor": factor])
        case .rate(let rate):
            guard rate.isFinite, (0.5...3).contains(rate) else { throw .invalidArgument }
            return .init(body: WebMusicScripts.rate, arguments: ["rate": rate])
        case .normalSpeed: return .init(body: WebMusicScripts.normalSpeed, arguments: [:])
        case .goLive: return .init(body: WebMusicScripts.goLive, arguments: [:])
        case .presentVideo(let on): return .init(body: WebMusicScripts.presentVideo, arguments: ["on": on])
        case .pictureInPicture(let on): return .init(body: WebMusicScripts.pictureInPicture, arguments: ["on": on])
        case .quality(let level):
            guard WebMusicBridge.isQualityToken(level) else { throw .invalidArgument }
            return .init(body: WebMusicScripts.quality, arguments: ["level": level])
        case .captions(let on): return .init(body: WebMusicScripts.captions, arguments: ["on": on])
        case .playQueueItem(let id):
            guard WebMusicIdentifier.isVideoID(id) else { throw .invalidArgument }
            return .init(body: WebMusicScripts.playQueueItem, arguments: ["videoId": id])
        case .shuffle(let on): return .init(body: WebMusicScripts.setShuffle, arguments: ["on": on])
        case .repeatMode(let mode): return .init(body: WebMusicScripts.setRepeat, arguments: ["mode": mode.rawValue])
        }
    }
}
public enum WebMusicCommandError: Error, Sendable, Equatable { case invalidArgument }

/// What a command reported back. Unrecognised replies are `.unavailable`.
public enum WebMusicCommandReply: String, Sendable, Equatable {
    case ok, router, fallback, unavailable, ad, rejected, unsupported
    case noMedia = "no-media"
    init(_ value: Any?) { self = (value as? String).flatMap(Self.init(rawValue:)) ?? .unavailable }
}

/// Full-load URLs, built only from a validated playlist ID and native generations.
public enum WebMusicNavigation {
    public static let origin = URL(string: "https://music.youtube.com/")!
    public static func playlistURL(_ playlistID: String, videoID: String? = nil, document: UInt64, load: UInt64) -> URL? {
        guard WebMusicIdentifier.isPlaylistID(playlistID), document > 0, load > 0,
              videoID.map({ WebMusicIdentifier.isVideoID($0) }) ?? true else { return nil }
        var components = URLComponents(string: "https://music.youtube.com/watch")!
        // With a video id the page starts the playlist at that track (what the site's own row click does).
        components.queryItems = (videoID.map { [URLQueryItem(name: "v", value: $0)] } ?? []) + [.init(name: "list", value: playlistID), .init(name: "ytmuse_doc", value: String(document)),
                                 .init(name: "ytmuse_load", value: String(load)), .init(name: "ytmuse_play", value: "1")]
        return components.url
    }
    /// A neutral document for a shuffle: the YouTube Music origin with the native generations and NO playlist and NO play intent, so
    /// nothing can start (least of all in order) before the service's shuffle endpoint has been routed.
    public static func hostURL(document: UInt64, load: UInt64) -> URL? {
        guard document > 0, load > 0 else { return nil }
        var components = URLComponents(string: "https://music.youtube.com/")!
        components.queryItems = [.init(name: "ytmuse_doc", value: String(document)), .init(name: "ytmuse_load", value: String(load))]
        return components.url
    }
    /// The generation encoded in a committed playback URL, if it is ours.
    public static func document(of url: URL?) -> UInt64? {
        guard let url, isPlayerDocument(url),
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ytmuse_doc" })?.value,
              let generation = UInt64(value), generation > 0 else { return nil }
        return generation
    }
    /// Main-frame navigation is limited to YouTube Music itself. Google sign-in or
    /// consent interstitials are not followed silently: they mean the session the
    /// player was given is not enough, which is reported as an observed blocker.
    public static func allowsMainFrame(_ url: URL?) -> Bool {
        guard let url else { return false }
        return isPlayerDocument(url)
    }
    static func isPlayerDocument(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == WebMusicBridge.host && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }
    /// Subframes and resources are YouTube's own business (including advertising);
    /// only non-web schemes are refused so nothing can launch another app.
    public static func allowsSubframe(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" }
        return scheme == "https" || scheme == "blob" || scheme == "data"
    }
}
