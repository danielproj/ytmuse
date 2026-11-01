import Foundation

// W26 (MAC11, ARCH03, T26.3). The AppleScript dictionary's commands as plain data, and the one place they are turned into the app's shared
// commands.
//
// The Cocoa scripting classes (in AppShell) are thin: each builds a `ScriptRequest` and calls `ScriptDispatcher`. The dispatcher validates it and
// calls the `ScriptingTarget`, whose production conformer is the shell, so an AppleScript transport command is the very call a menu item, a media
// key or the status item makes. There is no accessor for an account token, a cookie, a header or a request: the target protocol has none to give.

/// What a script can ask for. Exactly the dictionary's commands (`Resources/YTMuse.sdef`); `ScriptingDictionaryTests` pins the two lists together.
public enum ScriptRequest: Equatable, Sendable {
    case play, pause, playPause, nextTrack, previousTrack
    /// Move the position to this many seconds from the start.
    case seekTo(Double)
    /// Move the position by this many seconds (negative goes back).
    case seekBy(Double)
    /// Set the player volume, 0 through 100.
    case setVolume(Int)
    /// Add a song (a public link, or the same text the link copy gives) after the playing item, or at the end of the queue.
    case queue(String, placement: QueuePlacement)
    /// Open a link in a window: navigation only.
    case openLocation(String)
}
public enum QueuePlacement: String, Sendable { case next, end }

public enum ScriptPlayerState: String, Sendable { case stopped, playing, paused, advertisement }
/// The current track as a script may read it: public metadata and the public link only.
public struct ScriptTrack: Equatable, Sendable {
    public var name: String
    public var artist: String?
    /// Seconds; nil for a live stream.
    public var duration: Double?
    public var position: Double?
    /// The canonical public link, nil when the item has none (an owned or local file, an advertisement).
    public var url: String?
    public init(name: String, artist: String? = nil, duration: Double? = nil, position: Double? = nil, url: String? = nil) {
        self.name = name; self.artist = artist; self.duration = duration; self.position = position; self.url = url
    }
}

/// Why a request was not carried out. The text is what the script's error says.
public enum ScriptRefusal: Error, Equatable, Sendable {
    case nothingPlaying
    case notAllowedNow(String)
    case invalidArgument
    case invalidLink
    case queueNotEditable(String)
    public var message: String {
        switch self {
        case .nothingPlaying: String(localized: "Nothing is playing.")
        case .notAllowedNow(let why): why
        case .invalidArgument: String(localized: "That value is not valid for this command.")
        case .invalidLink: LinkRefusal.message
        case .queueNotEditable(let why): why
        }
    }
    /// A stable code scripts can test (`error number`): in the app's own range.
    public var code: Int {
        switch self {
        case .nothingPlaying: 4601
        case .notAllowedNow: 4602
        case .invalidArgument: 4603
        case .invalidLink: 4604
        case .queueNotEditable: 4605
        }
    }
}

/// The shared commands a script reaches. The shell conforms; tests record. No method returns or accepts a credential, a cookie, a header or a
/// request: the surface is transport, the public current track, the queue and opening a link.
@MainActor public protocol ScriptingTarget: AnyObject {
    var playerState: ScriptPlayerState { get }
    var currentTrack: ScriptTrack? { get }
    var volumePercent: Int { get }
    /// The transport commands go through the same admission as a media key: a command that is off right now (an advertisement, a restored item
    /// that must be started first) is refused with the sentence the window shows.
    func transport(_ request: ScriptTransport) -> ScriptRefusal?
    func setVolume(percent: Int) -> ScriptRefusal?
    func queueInsert(_ item: LinkItem, placement: QueuePlacement) async -> ScriptRefusal?
    /// Navigation only; shows the page, never starts playback.
    func open(_ destination: LinkDestination) -> ScriptRefusal?
}
public enum ScriptTransport: Equatable, Sendable { case play, pause, playPause, next, previous, seekTo(Double), seekBy(Double) }

@MainActor public enum ScriptDispatcher {
    /// Validates and carries out a request. `nil` is success. Every argument is checked here, so the Cocoa layer has nothing to get wrong.
    public static func perform(_ request: ScriptRequest, on target: any ScriptingTarget) async -> ScriptRefusal? {
        switch request {
        case .play: return target.transport(.play)
        case .pause: return target.transport(.pause)
        case .playPause: return target.transport(.playPause)
        case .nextTrack: return target.transport(.next)
        case .previousTrack: return target.transport(.previous)
        case .seekTo(let position):
            guard position.isFinite, position >= 0, position <= 86_400 else { return .invalidArgument }
            return target.transport(.seekTo(position))
        case .seekBy(let delta):
            guard delta.isFinite, abs(delta) <= 86_400 else { return .invalidArgument }
            return target.transport(.seekBy(delta))
        case .setVolume(let percent):
            guard (0...100).contains(percent) else { return .invalidArgument }
            return target.setVolume(percent: percent)
        case .queue(let text, let placement):
            // Only a song link can be queued. A radio, a playlist, a screen or anything else is not a queue entry.
            guard case .success(.item(let item)) = LinkPolicy.parse(text: text), item.kind == .song else { return .invalidLink }
            return await target.queueInsert(item, placement: placement)
        case .openLocation(let text):
            switch LinkPolicy.parse(text: text) {
            case .success(let destination): return target.open(destination)
            case .failure: return .invalidLink
            }
        }
    }
}
