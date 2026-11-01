import Foundation

/// Whether a video decoder is producing frames, derived only from a frame counter the player reports (WebKit's
/// `getVideoPlaybackQuality().totalVideoFrames`, or the native `AVPlayerItemVideoOutput` delivery count). It is the measurement behind
/// the audio-only rule: an audio-only selection must make the counter STOP, not merely hide the picture.
public struct VideoDecoderMeter: Sendable, Equatable {
    /// The counter advances roughly once per displayed frame; a decoder that has not advanced for this long has stopped.
    public static let staleAfter = 2.0
    public private(set) var frames = 0
    public private(set) var advances = 0
    public private(set) var lastAdvance: Double?
    public private(set) var samples = 0
    public init() {}
    /// `time` is seconds on the caller's own monotonic clock.
    public mutating func record(frames count: Int, at time: Double) {
        samples += 1
        // A smaller counter is a new video element or item: it restarts the count, and is not an advance.
        if count > frames { advances += 1; lastAdvance = time }
        else if count < frames { lastAdvance = nil }
        frames = count
    }
    public func isDecoding(at time: Double) -> Bool {
        guard let lastAdvance else { return false }
        return time - lastAdvance < Self.staleAfter
    }
    public mutating func reset() { self = VideoDecoderMeter() }
}

/// What the hidden player's video element looks like right now (a diagnostic read, never part of the periodic report).
public struct WebMusicVideoMeasurement: Sendable, Equatable {
    public let present: Bool
    public let pictureWidth: Int
    public let pictureHeight: Int
    public let frames: Int
    public let dropped: Int
    public let paused: Bool
    public let time: Double
    public let muted: Bool
    public let volume: Double
    /// The element's rectangle in the page viewport: x, y, width, height.
    public let rect: [Double]
    public let viewport: [Double]
    public let seekable: [Double]
    public let presenting: Bool
    /// The element's computed `object-fit` (`contain` keeps the aspect ratio).
    public let fit: String
    /// The document's `visibilityState` (WebKit presents video frames only while it is `visible`) and the element's `readyState`.
    public let visibility: String
    public let readyState: Int
    /// How many page nodes the video presentation made invisible, and whether its stylesheet is installed.
    public let hidden: Int
    public let styleInstalled: Bool
    /// Rework F1: how many advertising layers (`ytp-ad…`, `video-ads`) have a box, and whether a hit test at the centre of EVERY one lands on that
    /// layer: false when anything (the picture, an ancestor) paints above it. Ads are shown, never covered.
    public let adOverlayCount: Int
    public let adOverlaysOnTop: Bool
    /// The document's time origin: unchanged means the same document, i.e. the page was not reloaded.
    public let origin: Double
    /// A hash of the document markup, to prove that turning the presentation off restores the page exactly.
    public let digest: Int
    init?(_ value: Any?) {
        guard let object = value as? [String: Any], let present = object["present"] as? Bool else { return nil }
        func int(_ key: String) -> Int { (object[key] as? NSNumber).map { $0.doubleValue.isFinite ? Int($0.doubleValue) : 0 } ?? 0 }
        func double(_ key: String) -> Double { (object[key] as? NSNumber).map { $0.doubleValue.isFinite ? $0.doubleValue : 0 } ?? 0 }
        func list(_ key: String) -> [Double] { (object[key] as? [NSNumber])?.map { $0.doubleValue.isFinite ? $0.doubleValue : 0 } ?? [] }
        self.present = present; pictureWidth = int("width"); pictureHeight = int("height"); frames = int("frames"); dropped = int("dropped")
        paused = (object["paused"] as? Bool) ?? true; time = double("time"); muted = (object["muted"] as? Bool) ?? false; volume = double("volume")
        rect = list("rect"); viewport = list("viewport"); seekable = list("seekable"); presenting = (object["presenting"] as? Bool) ?? false
        fit = (object["fit"] as? String) ?? ""; visibility = (object["visibility"] as? String) ?? ""; readyState = int("readyState"); hidden = int("hidden"); styleInstalled = (object["styleInstalled"] as? Bool) ?? false
        adOverlayCount = int("adOverlayCount"); adOverlaysOnTop = (object["adOverlaysOnTop"] as? Bool) ?? false; origin = double("origin"); digest = int("digest")
    }
}
