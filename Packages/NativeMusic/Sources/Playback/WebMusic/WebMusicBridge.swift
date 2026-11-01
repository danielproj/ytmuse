import Foundation

/// Where a bridge message came from, copied from `WKScriptMessage.frameInfo`
/// so validation is a pure function (WKFrameInfo cannot be built in a test).
public struct WebMusicFrame: Sendable, Equatable {
    public let isMainFrame: Bool
    public let scheme: String
    public let host: String
    /// `0` is WebKit's "default port for the scheme".
    public let port: Int
    public init(isMainFrame: Bool, scheme: String, host: String, port: Int) {
        self.isMainFrame = isMainFrame; self.scheme = scheme; self.host = host; self.port = port
    }
}

/// One validated sample of YouTube Music's own player, as reported by the page.
/// Every string is bounded and every number finite; nothing here is evaluated.
public struct WebMusicSample: Sendable, Equatable {
    public let playing: Bool
    public let buffering: Bool
    public let position: Double
    public let duration: Double
    public let videoID: String?
    public let title: String?
    public let artist: String?
    public let artworkURL: URL?
    public let ad: Bool
    /// The playlist YouTube's player reports it is playing (`getPlaylistId()`), if any.
    public let playlistID: String?
    /// `ytcfg LOGGED_IN` as the page reports it; nil when the page did not say.
    public let signedIn: Bool?
    /// The requested content's video ID (the page URL's `v`), the reference both the
    /// page and the native ad continuity compare an ad creative against (N1).
    public let contentID: String?
    /// Whether the page's player bar shows shuffle on, when the page said so (best effort; nil = not reported).
    public let shuffle: Bool?
    public init(playing: Bool, buffering: Bool, position: Double, duration: Double, videoID: String?, title: String?, artist: String?, artworkURL: URL?, ad: Bool,
                playlistID: String? = nil, signedIn: Bool? = nil, contentID: String? = nil, shuffle: Bool? = nil) {
        self.playing = playing; self.buffering = buffering; self.position = position; self.duration = duration
        self.videoID = videoID; self.title = title; self.artist = artist; self.artworkURL = artworkURL; self.ad = ad
        self.playlistID = playlistID; self.signedIn = signedIn; self.contentID = contentID; self.shuffle = shuffle
    }
}

/// W17: what the page's `<video>` element and player say about the picture, live window and counterpart of the playing item.
/// A separate message from `state`, so the C1 sample schema and its key bound are untouched. Everything is bounded; nothing is page text.
public struct WebMusicMediaSample: Sendable, Equatable {
    public enum PictureInPicture: String, Sendable, Equatable { case unsupported, available, active }
    /// The video the facts belong to (the page's `getVideoData()`), so a lagging report for the outgoing track is not applied to the new one.
    public let videoID: String?
    /// `audio` (the song version), `video`, or nil when the page did not say. A live stream is `live`.
    public let representation: MediaRepresentation?
    /// The seekable window of a live stream, relative: 0 is the oldest point the player can reach.
    public let liveStart: Double?
    public let liveEnd: Double?
    /// The other version of this recording as the SERVICE published it (undocumented page signal; nil when absent).
    public let counterpartID: String?
    /// The decoded picture's size in pixels (0 x 0 when the element holds no video track).
    public let pictureWidth: Int
    public let pictureHeight: Int
    /// `getVideoPlaybackQuality().totalVideoFrames`: frames the video decoder has produced.
    public let decodedFrames: Int
    public let pictureInPicture: PictureInPicture
    /// The page is currently reduced to the video picture (the app's own presentation mode).
    public let isolated: Bool
    /// The player's current quality level and the levels it offers, as the player names them (`hd720`, `large`, ...); validated tokens only.
    public let quality: String?
    public let qualities: [String]
    public enum Captions: String, Sendable, Equatable { case unavailable, off, on }
    public let captions: Captions
    /// The speed the `<video>` element reports it is playing at (`playbackRate`), when the page said. Read only.
    public let rate: Double?
    public init(videoID: String?, representation: MediaRepresentation?, liveStart: Double? = nil, liveEnd: Double? = nil, counterpartID: String? = nil,
                pictureWidth: Int = 0, pictureHeight: Int = 0, decodedFrames: Int = 0, pictureInPicture: PictureInPicture = .unsupported, isolated: Bool = false,
                quality: String? = nil, qualities: [String] = [], captions: Captions = .unavailable, rate: Double? = nil) {
        self.rate = rate; self.quality = quality; self.qualities = qualities; self.captions = captions
        self.videoID = videoID; self.representation = representation; self.liveStart = liveStart; self.liveEnd = liveEnd; self.counterpartID = counterpartID
        self.pictureWidth = pictureWidth; self.pictureHeight = pictureHeight; self.decodedFrames = decodedFrames; self.pictureInPicture = pictureInPicture; self.isolated = isolated
    }
}

public enum WebMusicEvent: Sendable, Equatable {
    case state(WebMusicSample)
    case media(WebMusicMediaSample)
    case ended(videoID: String?)
    /// YouTube player error code (for example 150: not playable here). Never page text.
    case playerError(code: Int)
    /// Whether the document is the YouTube Music app (`ytmusic-app` present), and
    /// whether it is YouTube's "not optimized for your browser" page (PL1).
    case page(app: Bool, unsupportedBrowser: Bool)
}
public struct WebMusicMessage: Sendable, Equatable {
    public let document: UInt64
    public let load: UInt64
    public let event: WebMusicEvent
}

/// Fixed rejection categories. Nothing here carries page-provided text.
public enum WebMusicRejection: Error, Sendable, Equatable {
    case subframe, origin, notDictionary, oversized, malformed, unknownType, staleDocument, staleLoad
}

/// Accepts only messages from the `https://music.youtube.com` main frame of the
/// document and load generation native code currently expects, with bounded,
/// schema-checked payloads. Unknown keys, wrong types and oversized values reject.
public enum WebMusicBridge {
    public static let handlerName = "ytmusePlayer"
    public static let host = "music.youtube.com"
    static let maximumKeys = 16
    /// Displayed text is truncated to this many UTF-8 bytes on a character boundary.
    static let maximumTextBytes = 512
    /// Raw text above this is malformed (the page script bounds text to 300 UTF-16 units).
    static let maximumRawTextBytes = 1536
    static let maximumURLBytes = 2048
    static let maximumPayloadBytes = 6144
    static let maximumSeconds = 86_400.0
    static let stateKeys: Set<String> = ["type", "doc", "load", "playing", "buffering", "position", "duration", "videoId", "title", "artist", "artwork", "ad", "playlistId", "signedIn", "contentId", "shuffle"]
    static let endedKeys: Set<String> = ["type", "doc", "load", "videoId"]
    static let errorKeys: Set<String> = ["type", "doc", "load", "code"]
    static let pageKeys: Set<String> = ["type", "doc", "load", "app", "unsupported"]
    static let mediaKeys: Set<String> = ["type", "doc", "load", "videoId", "kind", "seekStart", "seekEnd", "counterpart", "width", "height", "frames", "pip", "isolated", "quality", "qualities", "captions", "rate"]
    /// A live stream's relative window is bounded like any position; pictures are bounded by what a decoder can hold.
    static let maximumPictureEdge = 16_384
    static let maximumFrames = 2_147_483_647
    /// Artwork the transport and Now Playing may fetch: YouTube's image hosts only.
    static let artworkHostSuffixes = ["ytimg.com", "googleusercontent.com", "ggpht.com"]

    public static func acceptsOrigin(_ frame: WebMusicFrame) -> Bool {
        frame.scheme.lowercased() == "https" && frame.host.lowercased() == host && (frame.port == 0 || frame.port == 443)
    }

    public static func validate(_ body: Any, frame: WebMusicFrame, document: UInt64, load: UInt64) -> Result<WebMusicMessage, WebMusicRejection> {
        guard frame.isMainFrame else { return .failure(.subframe) }
        guard acceptsOrigin(frame) else { return .failure(.origin) }
        guard let object = body as? [String: Any] else { return .failure(.notDictionary) }
        guard object.count <= maximumKeys, payloadBytes(object) <= maximumPayloadBytes else { return .failure(.oversized) }
        guard let type = object["type"] as? String else { return .failure(.malformed) }
        let keys: Set<String>
        switch type {
        case "state": keys = stateKeys
        case "ended": keys = endedKeys
        case "error": keys = errorKeys
        case "page": keys = pageKeys
        case "media": keys = mediaKeys
        default: return .failure(.unknownType)
        }
        guard Set(object.keys).isSubset(of: keys) else { return .failure(.malformed) }
        guard let doc = generation(object["doc"]), let messageLoad = generation(object["load"]) else { return .failure(.malformed) }
        // A document generation is assigned by native code before each full load;
        // older documents and documents native code did not load are rejected.
        guard document > 0, doc == document else { return .failure(.staleDocument) }
        guard load > 0, messageLoad == load else { return .failure(.staleLoad) }
        let event: WebMusicEvent
        switch type {
        case "state":
            guard let playing = bool(object["playing"]), let buffering = bool(object["buffering"]), let ad = bool(object["ad"]),
                  let position = seconds(object["position"]), let duration = seconds(object["duration"]),
                  let videoID = optionalVideoID(object["videoId"]), let title = optionalText(object["title"]),
                  let artist = optionalText(object["artist"]), let artwork = optionalArtwork(object["artwork"]),
                  let playlist = optionalPlaylistID(object["playlistId"]), let content = optionalVideoID(object["contentId"]) else { return .failure(.malformed) }
            let signedIn: Bool?
            if let raw = object["signedIn"] { guard let value = bool(raw) else { return .failure(.malformed) }; signedIn = value } else { signedIn = nil }
            let shuffle: Bool?
            if let raw = object["shuffle"] { guard let value = bool(raw) else { return .failure(.malformed) }; shuffle = value } else { shuffle = nil }
            event = .state(.init(playing: playing, buffering: buffering, position: position, duration: duration,
                                 videoID: videoID.value, title: title.value, artist: artist.value, artworkURL: artwork.value, ad: ad,
                                 playlistID: playlist.value, signedIn: signedIn, contentID: content.value, shuffle: shuffle))
        case "ended":
            guard let videoID = optionalVideoID(object["videoId"]) else { return .failure(.malformed) }
            event = .ended(videoID: videoID.value)
        case "page":
            guard let app = bool(object["app"]), let unsupported = bool(object["unsupported"]) else { return .failure(.malformed) }
            event = .page(app: app, unsupportedBrowser: unsupported)
        case "media":
            guard let videoID = optionalVideoID(object["videoId"]), let counterpart = optionalVideoID(object["counterpart"]),
                  let width = count(object["width"], limit: maximumPictureEdge), let height = count(object["height"], limit: maximumPictureEdge),
                  let frames = count(object["frames"], limit: maximumFrames), let isolated = bool(object["isolated"]),
                  let pip = (object["pip"] as? String).flatMap(WebMusicMediaSample.PictureInPicture.init(rawValue:)) else { return .failure(.malformed) }
            let captions: WebMusicMediaSample.Captions
            switch object["captions"] {
            case nil: captions = .unavailable
            case let raw as String: guard let value = WebMusicMediaSample.Captions(rawValue: raw) else { return .failure(.malformed) }; captions = value
            default: return .failure(.malformed)
            }
            guard let quality = optionalQualityToken(object["quality"]), let levels = optionalQualityList(object["qualities"]) else { return .failure(.malformed) }
            // The element's speed: a finite number in (0, 16] or absent. Anything else is malformed, never clamped.
            var rate: Double?
            if let raw = object["rate"] {
                guard let number = raw as? NSNumber, !isBoolean(number), number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue <= 16 else { return .failure(.malformed) }
                rate = number.doubleValue
            }
            let representation: MediaRepresentation?
            switch object["kind"] as? String {
            case "audio"?: representation = .audio
            case "video"?: representation = .video
            case "live"?: representation = .live
            case ""?, nil: representation = nil
            default: return .failure(.malformed)
            }
            // The window exists only for a live stream and only as a pair.
            var start: Double?, end: Double?
            if object["seekStart"] != nil || object["seekEnd"] != nil {
                guard representation == .live, let a = seconds(object["seekStart"]), let b = seconds(object["seekEnd"]), LiveWindow(start: a, end: b) != nil else { return .failure(.malformed) }
                start = a; end = b
            }
            event = .media(.init(videoID: videoID.value, representation: representation, liveStart: start, liveEnd: end, counterpartID: counterpart.value,
                                 pictureWidth: width, pictureHeight: height, decodedFrames: frames, pictureInPicture: pip, isolated: isolated,
                                 quality: quality.value, qualities: levels, captions: captions, rate: rate))
        default:
            guard let number = object["code"] as? NSNumber, !isBoolean(number), let code = Int(exactly: number.doubleValue), (0...9999).contains(code) else { return .failure(.malformed) }
            event = .playerError(code: code)
        }
        return .success(.init(document: doc, load: messageLoad, event: event))
    }

    // MARK: Field validators (a nil result means malformed; `.value == nil` means absent/empty)
    private struct Field<Value> { let value: Value? }
    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }
    private static func generation(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= 9_007_199_254_740_991, double.rounded() == double else { return nil }
        return UInt64(double)
    }
    /// A quality level as the player names it: short lowercase alphanumerics (`hd1080`, `large`, `auto`). Nothing else passes.
    static func isQualityToken(_ value: String) -> Bool {
        (2...12).contains(value.utf8.count) && value.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) }
    }
    private static func optionalQualityToken(_ value: Any?) -> Field<String>? {
        guard let value else { return .init(value: nil) }
        guard let string = value as? String else { return nil }
        if string.isEmpty { return .init(value: nil) }
        return isQualityToken(string) ? .init(value: string) : nil
    }
    private static func optionalQualityList(_ value: Any?) -> [String]? {
        guard let value else { return [] }
        guard let string = value as? String else { return nil }
        if string.isEmpty { return [] }
        let tokens = string.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count <= 12, tokens.allSatisfy(isQualityToken) else { return nil }
        return tokens
    }
    private static func count(_ value: Any?, limit: Int) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= Double(limit), double.rounded() == double else { return nil }
        return Int(double)
    }
    private static func seconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        // The page reports NaN/Infinity duration as 0 before metadata loads.
        guard double.isFinite, double >= 0, double <= maximumSeconds else { return nil }
        return double
    }
    private static func optionalText(_ value: Any?) -> Field<String>? {
        guard let value else { return .init(value: nil) }
        guard let string = value as? String, string.utf8.count <= maximumRawTextBytes else { return nil }
        let cleaned = String(string.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = truncated(cleaned, bytes: maximumTextBytes)
        return .init(value: bounded.isEmpty ? nil : bounded)
    }
    /// Truncates on a Character boundary so long CJK/emoji titles stay valid text.
    static func truncated(_ text: String, bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = "", used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= limit - 3 else { break }
            result.append(character); used += size
        }
        return result + "…"
    }
    private static func optionalPlaylistID(_ value: Any?) -> Field<String>? {
        guard let value else { return .init(value: nil) }
        guard let string = value as? String else { return nil }
        if string.isEmpty { return .init(value: nil) }
        return WebMusicIdentifier.isPlaylistID(string) ? .init(value: string) : nil
    }
    private static func optionalVideoID(_ value: Any?) -> Field<String>? {
        guard let value else { return .init(value: nil) }
        guard let string = value as? String else { return nil }
        if string.isEmpty { return .init(value: nil) }
        return WebMusicIdentifier.isVideoID(string) ? .init(value: string) : nil
    }
    private static func optionalArtwork(_ value: Any?) -> Field<URL>? {
        guard let value else { return .init(value: nil) }
        guard let string = value as? String, string.utf8.count <= maximumURLBytes else { return nil }
        if string.isEmpty { return .init(value: nil) }
        // A non-allowlisted artwork URL is dropped, not fatal: the sample stays useful.
        return .init(value: allowedArtwork(string))
    }
    static func allowedArtwork(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(),
              artworkHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }
    private static func payloadBytes(_ object: [String: Any]) -> Int {
        object.reduce(0) { total, entry in
            let value: Int
            switch entry.value {
            case let string as String: value = string.utf8.count
            case is NSNumber: value = 8
            default: value = maximumPayloadBytes + 1 // nested objects/arrays are never part of the schema
            }
            return total + entry.key.utf8.count + value
        }
    }
}

/// Identifiers that may cross into a page command. They travel only as
/// `callAsyncJavaScript` arguments, never interpolated into script text.
public enum WebMusicIdentifier {
    public static func isVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy(isIDByte)
    }
    /// Playlist IDs as the library read publishes them (`PL…`, `LM`, `RDCLAK…`, `OLAK…`).
    public static func isPlaylistID(_ value: String) -> Bool {
        (2...128).contains(value.utf8.count) && value.utf8.allSatisfy(isIDByte)
    }
    /// The opaque parameters the service attached to a play endpoint (a shuffle flag, for one), exactly as it published them.
    public static func isEndpointParams(_ value: String) -> Bool {
        (1...1024).contains(value.utf8.count) && value.utf8.allSatisfy { isIDByte($0) || $0 == 0x25 || $0 == 0x3D || $0 == 0x2B || $0 == 0x2F || $0 == 0x2E }
    }
    private static func isIDByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
    }
}
