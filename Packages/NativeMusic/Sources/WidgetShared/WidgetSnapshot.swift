import CryptoKit
import Foundation

// W25 (MAC06). What the app tells the widget. It is deliberately small: a state, a title, an artist, one thumbnail, three capability flags and an opaque
// account stamp. The extension renders this and nothing else; it never learns who the account is, what the queue holds or what is in any playlist.

public enum WidgetPlaybackState: String, Codable, Sendable, CaseIterable {
    case playing, paused
    /// An advertisement is playing: the widget shows the honest state, never the song the ad interrupts.
    case advertisement
    /// Signed in, nothing played yet or nothing to show. Carries no title.
    case idle
    /// Redacted: nobody is signed in to YouTube Music, or the session ended. Carries no title, artist, picture or account stamp.
    case signedOut
    /// Redacted: the Mac's user session is not the active one. Same shape as `signedOut`.
    case locked
}

/// Which transport buttons the widget may offer. The app computes them from the same capabilities the media keys use.
public struct WidgetCapabilities: Codable, Equatable, Sendable {
    public static let allowedKeys: Set<String> = ["playPause", "next", "previous"]
    public var playPause: Bool
    public var next: Bool
    public var previous: Bool
    public init(playPause: Bool = false, next: Bool = false, previous: Bool = false) { self.playPause = playPause; self.next = next; self.previous = previous }
    public static let none = WidgetCapabilities()
}

/// A random value made once per process. The account session's generation is a per-launch counter that starts again at every launch, so on its own it cannot tell
/// this launch from the last; the nonce can. It identifies nothing and is not derived from anything.
public enum WidgetLaunch {
    public static let nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

/// The account and session a snapshot was written under. `accountToken` is a one-way digest of the account id, so the file never carries the id itself;
/// `generation` is the account session's generation within one launch; `launch` is that launch's random nonce. A command stamped with a scope the app is no
/// longer in (another account, another sign-in, another LAUNCH) is refused (T25.2).
public struct WidgetScope: Codable, Equatable, Hashable, Sendable {
    public let accountToken: String
    public let generation: UInt64
    public let launch: String
    public static let allowedKeys: Set<String> = ["accountToken", "generation", "launch"]
    public init(accountToken: String, generation: UInt64, launch: String = WidgetLaunch.nonce) { self.accountToken = accountToken; self.generation = generation; self.launch = launch }
    /// 16 bytes of SHA-256 over a fixed label and the account id, hex-encoded. Stable for an account, not reversible, not an identifier anyone else holds.
    public static func token(for account: UUID) -> String {
        let digest = SHA256.hash(data: Data(("ytmuse.widget.account.v1|" + account.uuidString.lowercased()).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    public init(account: UUID, generation: UInt64, launch: String = WidgetLaunch.nonce) { self.init(accountToken: Self.token(for: account), generation: generation, launch: launch) }
}

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let schema = 1
    public static let titleLimit = 120
    public static let artworkByteLimit = 32 * 1024
    /// Every key the file may carry. The reader refuses a file with any other key, so a field added later by mistake (an email, a token) is never rendered.
    public static let allowedKeys: Set<String> = ["schema", "state", "title", "artist", "artwork", "capabilities", "scope", "serial", "writtenAt"]

    public var schema: Int
    public var state: WidgetPlaybackState
    public var title: String?
    public var artist: String?
    /// A small JPEG thumbnail of the playing item's picture (at most `artworkByteLimit` bytes).
    public var artwork: Data?
    public var capabilities: WidgetCapabilities
    /// Nil for the redacted states.
    public var scope: WidgetScope?
    /// Increases with every write the app makes; lets a test (and a human) see the file changed.
    public var serial: UInt64
    public var writtenAt: Date

    public init(state: WidgetPlaybackState, title: String? = nil, artist: String? = nil, artwork: Data? = nil, capabilities: WidgetCapabilities = .none, scope: WidgetScope? = nil,
                serial: UInt64 = 0, writtenAt: Date = Date()) {
        self.schema = Self.schema; self.state = state
        self.title = title.map { String($0.prefix(Self.titleLimit)) }; self.artist = artist.map { String($0.prefix(Self.titleLimit)) }
        self.artwork = artwork; self.capabilities = capabilities; self.scope = scope; self.serial = serial; self.writtenAt = writtenAt
    }
    /// A redacted snapshot: no title, no artist, no picture, no scope, no buttons.
    public static func redacted(_ state: WidgetPlaybackState, serial: UInt64 = 0, writtenAt: Date = Date()) -> WidgetSnapshot {
        precondition(state == .signedOut || state == .locked, "only signedOut and locked are redacted states")
        return WidgetSnapshot(state: state, serial: serial, writtenAt: writtenAt)
    }
    public var isRedacted: Bool { state == .signedOut || state == .locked }

    /// Whether the content agrees with the state: a redacted state carries nothing; an advertisement carries no song; every other state carries a scope.
    public var isConsistent: Bool {
        guard schema == Self.schema else { return false }
        if let title, title.count > Self.titleLimit { return false }
        if let artist, artist.count > Self.titleLimit { return false }
        if let artwork, artwork.count > Self.artworkByteLimit { return false }
        switch state {
        case .signedOut, .locked: return title == nil && artist == nil && artwork == nil && scope == nil && capabilities == .none
        case .advertisement: return scope != nil && title == nil && artist == nil && artwork == nil
        case .idle: return scope != nil && title == nil && artist == nil && artwork == nil
        case .playing, .paused: return scope != nil && !(title ?? "").isEmpty
        }
    }
}
