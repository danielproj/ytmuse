import Foundation

// W17: how one recording is presented (song, music video, live stream), when a switch between presentations may keep the playback
// position, what a live stream can and cannot do, and who owns the video picture. Everything here is pure: no WebKit, no AVFoundation,
// no clock. The hidden YouTube Music player and the native AVKit player both feed it.

/// How a recording is presented. A song is the audio version, a video is the picture version; a live stream has no fixed length.
public enum MediaRepresentation: String, Sendable, Equatable, CaseIterable {
    case audio, video, live
}

/// The service's own identity for one playable asset: where it comes from, its id and, when the publisher states one, the recording
/// version. Never a title, an artist or a duration: those are shared by unrelated recordings.
public struct MediaAssetIdentity: Hashable, Sendable {
    public let source: String
    public let assetID: String
    public let version: String?
    public init(source: String, assetID: String, version: String? = nil) { self.source = source; self.assetID = assetID; self.version = version }
    public static func youTubeMusic(_ videoID: String, version: String? = nil) -> MediaAssetIdentity { .init(source: "youtube-music", assetID: videoID, version: version) }
}

/// A relation the SERVICE published between the audio and the video version of one recording (YouTube Music's song/video pair).
/// It is never inferred: it can only be built from two identities of one source with different asset ids.
public struct PublishedCounterpart: Hashable, Sendable {
    public let audio: MediaAssetIdentity
    public let video: MediaAssetIdentity
    public init?(audio: MediaAssetIdentity, video: MediaAssetIdentity) {
        guard audio.source == video.source, audio.assetID != video.assetID, !audio.assetID.isEmpty, !video.assetID.isEmpty else { return nil }
        self.audio = audio; self.video = video
    }
    /// The other half of the pair, when `asset` is one half of it.
    public func counterpart(of asset: MediaAssetIdentity) -> (asset: MediaAssetIdentity, representation: MediaRepresentation)? {
        if asset.source == audio.source, asset.assetID == audio.assetID { return (video, .video) }
        if asset.source == video.source, asset.assetID == video.assetID { return (audio, .audio) }
        return nil
    }
}

/// Every pair the service has published so far in this session, keyed by asset. Empty means: the app knows no counterpart of anything.
public struct RepresentationCatalog: Sendable, Equatable {
    private var byAsset: [String: PublishedCounterpart] = [:]
    public init() {}
    private static func key(_ asset: MediaAssetIdentity) -> String { asset.source + "\u{0}" + asset.assetID }
    public mutating func publish(_ pair: PublishedCounterpart) {
        byAsset[Self.key(pair.audio)] = pair; byAsset[Self.key(pair.video)] = pair
    }
    public func counterpart(of asset: MediaAssetIdentity) -> (asset: MediaAssetIdentity, representation: MediaRepresentation)? {
        byAsset[Self.key(asset)]?.counterpart(of: asset)
    }
    public var count: Int { Set(byAsset.values).count }
    public mutating func removeAll() { byAsset = [:] }
}

/// MEDIA02: a switch between presentations keeps the position only when the service published the pair AND both halves state the
/// same recording version (or state none) AND, once the target's length is known, the two timelines agree. Everything else restarts
/// and says why. Title, artist and duration alone never map two assets.
public enum RepresentationTransition {
    public struct Current: Sendable, Equatable {
        public let asset: MediaAssetIdentity
        public let representation: MediaRepresentation
        public let position: Double
        public let duration: Double?
        public let isAdvertisement: Bool
        public init(asset: MediaAssetIdentity, representation: MediaRepresentation, position: Double, duration: Double?, isAdvertisement: Bool = false) {
            self.asset = asset; self.representation = representation; self.position = position; self.duration = duration; self.isAdvertisement = isAdvertisement
        }
    }
    public struct Target: Sendable, Equatable {
        public let asset: MediaAssetIdentity
        public let representation: MediaRepresentation
        public init(asset: MediaAssetIdentity, representation: MediaRepresentation) { self.asset = asset; self.representation = representation }
    }
    public enum RestartReason: String, Sendable, Equatable {
        /// The service published no link between the two assets: they may be different recordings, whatever they are called.
        case noPublishedCounterpart
        case versionDiffers
        case timelinesDiffer
        /// A live stream has no recording or fixed timeline to carry a position across.
        case liveStream
        public var message: String {
            switch self {
            case .noPublishedCounterpart: String(localized: "YouTube Music does not say these are the same recording, so it starts from the beginning.")
            case .versionDiffers: String(localized: "These are different versions of the recording, so it starts from the beginning.")
            case .timelinesDiffer: String(localized: "The two versions differ in length, so it starts from the beginning.")
            case .liveStream: String(localized: "A live stream has no position to carry over, so it starts from the beginning.")
            }
        }
    }
    public enum RefusalReason: String, Sendable, Equatable {
        case advertisement, nothingPlaying
        public var message: String {
            switch self {
            case .advertisement: String(localized: "Switching is unavailable while an ad plays.")
            case .nothingPlaying: String(localized: "Nothing is playing to switch.")
            }
        }
    }
    public enum Plan: Sendable, Equatable {
        /// The target is the asset already playing.
        case keep
        case continued(at: Double)
        case restart(RestartReason)
        case refused(RefusalReason)
    }
    /// The longest difference between the two versions' lengths that is still one timeline (frame/encoder padding, not an intro).
    public static let durationTolerance = 2.0

    public static func plan(current: Current?, target: Target, catalog: RepresentationCatalog) -> Plan {
        guard let current else { return .refused(.nothingPlaying) }
        if current.isAdvertisement { return .refused(.advertisement) }
        if current.asset == target.asset { return .keep }
        if current.representation == .live || target.representation == .live { return .restart(.liveStream) }
        guard let published = catalog.counterpart(of: current.asset), published.asset.source == target.asset.source,
              published.asset.assetID == target.asset.assetID, published.representation == target.representation else { return .restart(.noPublishedCounterpart) }
        if let a = current.asset.version, let b = target.asset.version, a != b { return .restart(.versionDiffers) }
        let position = current.position.isFinite ? max(0, current.position) : 0
        return .continued(at: position)
    }
    /// Once the target is loaded its length is known: a carried position stays valid only inside one agreed timeline.
    public static func settle(_ plan: Plan, current: Current, targetDuration: Double?) -> Plan {
        guard case .continued(let position) = plan else { return plan }
        guard let a = current.duration, let b = targetDuration, a > 0, b > 0 else { return .restart(.timelinesDiffer) }
        guard abs(a - b) <= durationTolerance else { return .restart(.timelinesDiffer) }
        return .continued(at: min(position, max(0, b - 0.5)))
    }

    public enum AudioOnlyUnavailable: String, Error, Sendable, Equatable {
        case alreadyAudio, noAudioVersionPublished, liveStream, nothingPlaying
        /// The page has not said whether this is a song or a video (rework F9), so no switch can be offered.
        case presentationUnknown
        public var message: String {
            switch self {
            case .alreadyAudio: String(localized: "This is already the audio version.")
            case .presentationUnknown: String(localized: "YouTube Music did not say whether this is a song or a video, so it cannot be switched here.")
            case .noAudioVersionPublished: String(localized: "YouTube Music has published no audio version of this video, so the video keeps playing. The picture is not hidden to fake audio only.")
            case .liveStream: String(localized: "A live stream has no audio-only version here, so the video keeps playing.")
            case .nothingPlaying: String(localized: "Nothing is playing.")
            }
        }
    }
    /// Audio only is the song version, asked of the service, never a cover over a decoding video.
    public static func audioOnlyTarget(for current: Current?, catalog: RepresentationCatalog) -> Result<Target, AudioOnlyUnavailable> {
        guard let current else { return .failure(.nothingPlaying) }
        switch current.representation {
        case .audio: return .failure(.alreadyAudio)
        case .live: return .failure(.liveStream)
        case .video:
            guard let published = catalog.counterpart(of: current.asset), published.representation == .audio else { return .failure(.noAudioVersionPublished) }
            return .success(.init(asset: published.asset, representation: .audio))
        }
    }
}

/// MEDIA05 / live: what the player reports about a live stream's seekable window. Positions are media time in seconds.
public struct LiveWindow: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public init?(start: Double, end: Double) {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
        self.start = start; self.end = end
    }
    /// A live stream with no rewindable window (no DVR): Go live is the only motion, seeking is refused.
    public var isRewindable: Bool { end - start >= 1 }
    /// Within this many seconds of the live edge counts as live.
    public static let liveEdgeTolerance = 10.0
    public func isAtLiveEdge(position: Double) -> Bool { end - position <= Self.liveEdgeTolerance }
    public func behindLive(position: Double) -> Double { max(0, end - position) }
    /// A seek target clamped into the window the player can actually reach. Nil when there is nothing to seek in.
    public func clamp(_ target: Double) -> Double? {
        guard isRewindable, target.isFinite else { return nil }
        return min(max(target, start), end)
    }
}

/// Features a presentation cannot offer, with the actual reason (never a generic "not available").
public enum MediaFeature: String, Sendable, Equatable, CaseIterable { case download, crossfade }
public enum FeatureAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
    public var isAvailable: Bool { if case .available = self { true } else { false } }
    public var reason: String? { if case .unavailable(let reason) = self { reason } else { nil } }
}
public enum MediaCapabilityPolicy {
    /// What the hidden YouTube Music player can do with `feature` for a presentation. Live is never downloadable or crossfaded;
    /// every YouTube Music item is played by YouTube's own player, which the app can neither overlap nor retain.
    public static func availability(of feature: MediaFeature, representation: MediaRepresentation?, hiddenPlayer: Bool) -> FeatureAvailability {
        switch (feature, representation) {
        case (.download, .live?):
            return .unavailable(reason: String(localized: "A live stream has no fixed length or end, so there is nothing complete to download."))
        case (.crossfade, .live?):
            return .unavailable(reason: String(localized: "Crossfade overlaps the end of one item with the start of the next, and a live stream has no end to overlap."))
        case (.download, _) where hiddenPlayer:
            return .unavailable(reason: String(localized: "YouTube Music items play through YouTube's own player, which the app cannot save for offline use."))
        case (.crossfade, _) where hiddenPlayer:
            return .unavailable(reason: String(localized: "YouTube Music plays in its own player, so the app cannot overlap two items or process their audio."))
        default:
            return .available
        }
    }
}

/// The surfaces that can show the one video picture. At most one holds it at a time (MEDIA03: one owner across the inline preview,
/// the player window, full screen and Picture in Picture), and handing it on never reloads, restarts or duplicates the media.
public enum VideoSurface: String, Sendable, Equatable, CaseIterable { case inline, window, fullScreen, pictureInPicture }
public struct VideoSurfaceOwnership: Sendable, Equatable {
    public private(set) var holder: VideoSurface?
    public private(set) var handoffs = 0
    public init() {}
    public enum Change: Sendable, Equatable { case attached(VideoSurface), moved(from: VideoSurface, to: VideoSurface), unchanged }
    /// The picture is requested for `surface`; whichever surface held it lets go first, in the same step.
    @discardableResult public mutating func request(_ surface: VideoSurface) -> Change {
        if holder == surface { return .unchanged }
        let previous = holder
        holder = surface
        guard let previous else { return .attached(surface) }
        handoffs += 1
        return .moved(from: previous, to: surface)
    }
    /// A surface closes (window closed, full screen exited, PiP dismissed). Only the holder's release matters.
    @discardableResult public mutating func release(_ surface: VideoSurface) -> Bool {
        guard holder == surface else { return false }
        holder = nil; return true
    }
    public mutating func releaseAll() { holder = nil }
    /// How many surfaces are showing the picture right now: 0 or 1 by construction.
    public var activeSurfaces: Int { holder == nil ? 0 : 1 }
}

/// Scaling a picture into a container without cropping or distortion (aspect ratio preserved).
public struct VideoGeometry: Sendable, Equatable {
    public let picture: CGSize
    public let container: CGSize
    public init(picture: CGSize, in container: CGSize) { self.picture = picture; self.container = container }
    public var aspectRatio: Double? { picture.width > 0 && picture.height > 0 ? picture.width / picture.height : nil }
    /// The rectangle (origin relative to the container) the picture occupies, centred, scaled to fit.
    public var fitted: CGRect {
        guard picture.width > 0, picture.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / picture.width, container.height / picture.height)
        let size = CGSize(width: picture.width * scale, height: picture.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
}
