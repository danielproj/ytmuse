import Foundation

// W24 (MAC03, MAC04, ARCH03, ARCH09). The value types of the App Intents layer.
//
// Intents run IN the app process. They never play audio, hold credentials or read stores themselves: every command goes through the
// `IntentCommandChannel`, which the app implements over the same `PlaybackModel` / library / search models the window uses (ARCH03). An
// entity is a small value that carries the account and generation it was read under; the channel refuses one that is not the current
// session's, so a Shortcut saved under another or an older account can never act on this one (T24.2).

/// The live session an intent runs in: the account and the generation of that account's session. The generation is a per-launch counter
/// (`AccountLifecycle`), so it is NEVER written into an entity identifier; it only fences work that is in flight (DATA03).
public struct IntentScope: Hashable, Sendable, Codable {
    public let accountID: UUID
    public let generation: UInt64
    public init(accountID: UUID, generation: UInt64) { self.accountID = accountID; self.generation = generation }
}

/// What kind of thing an entity is. `mix` is only ever a radio the service itself presented as one (a seed the person met while browsing);
/// no id prefix or title makes something a mix.
public enum IntentMediaKind: String, Codable, Sendable, CaseIterable {
    case song, album, artist, playlist, mix
}

/// The identifiers a start needs, exactly as the catalog item or search result published them. Never guessed from a title.
public struct IntentMediaTarget: Codable, Hashable, Sendable {
    public var videoID: String?
    public var playlistID: String?
    public var browseID: String?
    public var params: String?
    public init(videoID: String? = nil, playlistID: String? = nil, browseID: String? = nil, params: String? = nil) {
        self.videoID = videoID; self.playlistID = playlistID; self.browseID = browseID; self.params = params
    }
}

/// One thing an intent can act on. Its encoded form is the entity identifier.
///
/// An identifier is bound to the **account** (the stable `AccountContext.accountID`), not to a session: a Shortcut saved today keeps working after a
/// relaunch and after signing in to the SAME account again, and is refused for any other account (T24.2). What a session change must still stop
/// is work in flight, which the hub fences separately (`IntentHub.resolved`).
public struct IntentMedia: Hashable, Sendable, Codable, Identifiable {
    public let account: UUID
    public let kind: IntentMediaKind
    public let title: String
    /// Artist, year, owner: what tells two items with the same title apart.
    public let subtitle: String?
    public let target: IntentMediaTarget
    public init(account: UUID, kind: IntentMediaKind, title: String, subtitle: String? = nil, target: IntentMediaTarget) {
        self.account = account; self.kind = kind; self.title = String(title.prefix(Self.titleLimit)); self.subtitle = subtitle.map { String($0.prefix(Self.titleLimit)) }; self.target = target
    }
    /// Convenience for code that holds the live scope: only its account is used.
    public init(scope: IntentScope, kind: IntentMediaKind, title: String, subtitle: String? = nil, target: IntentMediaTarget) {
        self.init(account: scope.accountID, kind: kind, title: title, subtitle: subtitle, target: target)
    }
    static let titleLimit = 160
    public var id: String { encoded }
    /// What the item IS, independent of the context it was listed in: two rows of the same song (Songs and Liked songs list it under different
    /// watch contexts) are one item. Songs are their video; everything else is the page or playlist it starts.
    public var identity: String {
        let key = kind == .song ? (target.videoID ?? target.playlistID ?? target.browseID ?? "") : (target.playlistID ?? target.browseID ?? target.videoID ?? "")
        return [account.uuidString, kind.rawValue, key].joined(separator: "|")
    }

    // MARK: Identifier

    private static let prefix = "ytm1"
    /// `ytm1:<account>:<kind>:<payload>`. The account is readable in the identifier so a sweep (and a person reading a Shortcut) can see what it is
    /// bound to; the payload is the target and the names the entity was built from.
    public var encoded: String {
        let payload = (try? Self.encoder.encode(Payload(title: title, subtitle: subtitle, target: target))) ?? Data()
        return [Self.prefix, account.uuidString, kind.rawValue, Self.base64URL(payload)].joined(separator: ":")
    }
    /// Nil for anything that is not an identifier this layer wrote (wrong shape, unknown kind, oversize, a payload with nothing to play or open).
    public init?(encoded: String) {
        guard encoded.utf8.count <= 4096 else { return nil }
        let parts = encoded.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == Self.prefix, let account = UUID(uuidString: parts[1]),
              let kind = IntentMediaKind(rawValue: parts[2]), let data = Self.data(fromBase64URL: parts[3]),
              let payload = try? Self.decoder.decode(Payload.self, from: data) else { return nil }
        let target = payload.target
        guard target.videoID != nil || target.playlistID != nil || target.browseID != nil else { return nil }
        self.init(account: account, kind: kind, title: payload.title, subtitle: payload.subtitle, target: target)
    }
    /// The account an identifier claims, read without trusting the rest of it (for the refusal path, which must name nothing).
    public static func claimedAccount(of encoded: String) -> UUID? {
        let parts = encoded.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == prefix else { return nil }
        return UUID(uuidString: String(parts[1]))
    }
    private struct Payload: Codable { let title: String; let subtitle: String?; let target: IntentMediaTarget }
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder = JSONDecoder()
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func data(fromBase64URL text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// How a sleep timer is asked for. Mirrors the transport menu: minutes, the end of the current item, or off.
public enum IntentSleepTimer: Hashable, Sendable {
    case minutes(Int)
    case endOfItem
    case off
    /// The menu's own range for a custom timer.
    public static let minuteRange = 1...1440
}

/// A rating as the audio schema's affinity state spells it.
public enum IntentRating: String, Hashable, Sendable { case like, dislike, none }

/// Everything an intent can ask the app to do (MAC03). Each case is one use case the window's controls also reach.
public enum IntentCommand: Hashable, Sendable {
    case resume, pause, toggle, next, previous
    case seek(to: Double)
    case play(IntentMedia)
    /// The best-ranked result for a spoken or typed query, played only when exactly one candidate is clearly the one asked for.
    case playSearch(String)
    case search(String)
    /// Set the rating of `of` (nil: the item playing now). The channel presses the same control the window's Like button does, and only for the song that is playing.
    case rate(IntentRating, of: IntentMedia?)
    /// Save `of` (nil: the item playing now) to the library, through the same ledger the Save button uses.
    case save(of: IntentMedia?)
    case showQueue, showPlayer
    case sleepTimer(IntentSleepTimer)

    /// A stable name for logs, the donation guard and the phrase matrix. Never carries a title, a query or an identifier.
    public var name: String {
        switch self {
        case .resume: "resume"; case .pause: "pause"; case .toggle: "toggle"; case .next: "next"; case .previous: "previous"; case .seek: "seek"
        case .play: "play"; case .playSearch: "playSearch"; case .search: "search"; case .rate(let r, _): "rate-\(r.rawValue)"; case .save: "save"
        case .showQueue: "showQueue"; case .showPlayer: "showPlayer"; case .sleepTimer: "sleepTimer"
        }
    }
}

/// Why an intent did nothing. Each case is a sentence the person can act on; none names another account or a title it was not given.
public enum IntentRefusal: Error, Hashable, Sendable, LocalizedError, CustomLocalizedStringResourceConvertible {
    /// The app is still starting (or no channel exists): nothing was done.
    case appNotReady
    /// Nobody is signed in to YouTube Music, or the session ended.
    case signedOut
    /// The entity belongs to another or an older account/session than the current one.
    case staleIdentity
    case nothingPlaying
    /// An advertisement is playing: it cannot be skipped or sought.
    case advertisement
    /// The command is not available for what is playing or for this item (owned media has no like, YouTube Music has no timer here...). The text is the app's own reason.
    case unavailable(String)
    case notFound
    /// Several items match; the person must choose. The candidates carry what tells them apart.
    case ambiguous([IntentMedia])
    /// The app asked for the person's confirmation in its window (for example Play here after a route loss); nothing sounds until they answer.
    case needsConfirmation(String)
    case failed(String)

    public var errorDescription: String? { message }
    public var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
    public var message: String {
        switch self {
        case .appNotReady: String(localized: "YTMuse is still starting. Try again in a moment.")
        case .signedOut: String(localized: "Sign in to YouTube Music in YTMuse first.")
        case .staleIdentity: String(localized: "This item belongs to a different account or an earlier session. Pick it again.")
        case .nothingPlaying: String(localized: "Nothing is playing.")
        case .advertisement: String(localized: "An advertisement is playing. It cannot be skipped or sought.")
        case .unavailable(let reason): reason
        case .notFound: String(localized: "YTMuse couldn’t find that in the current account.")
        case .ambiguous(let options):
            options.isEmpty ? String(localized: "More than one item matches. Choose one.")
                : String(localized: "More than one item matches. Choose one:") + " " + options.prefix(5).map { IntentResolver.disambiguationLine($0) }.joined(separator: "; ")
        case .needsConfirmation(let text): text
        case .failed(let text): text
        }
    }
}

/// What the app did with a command: the sentence to say, or a refusal.
public enum IntentOutcome: Hashable, Sendable {
    case done(String)
    case refused(IntentRefusal)
    public var isDone: Bool { if case .done = self { true } else { false } }
    public var refusal: IntentRefusal? { if case .refused(let r) = self { r } else { nil } }
}

/// What a name resolves to in the current account's caches.
public enum IntentResolution: Hashable, Sendable {
    case none
    case one(IntentMedia)
    case many([IntentMedia])
}

/// The minimal command channel (ARCH09). The app implements it over its own models; an intent never reaches past it.
@MainActor public protocol IntentCommandChannel: AnyObject {
    /// Returns once the app has finished restoring its account (a cold launch through an intent waits here). Never starts playback.
    func awaitReady() async
    /// The current account and generation, or nil when nobody is signed in. Reads the live session, never a cache of it.
    /// The live session (account + generation), or nil when no YouTube Music account is connected. Only commands that carry an entity or start YouTube Music need it.
    func currentScope() async -> IntentScope?
    /// Items of the current account that are already in the app's models and caches (library, the last search, radios the person has met).
    /// Never makes a request the same window action would not make. `text` nil lists suggestions.
    func candidates(kind: IntentMediaKind?, matching text: String?, limit: Int) async -> [IntentMedia]
    func perform(_ command: IntentCommand) async -> IntentOutcome
}
