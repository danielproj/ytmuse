import Foundation

// W39 (ROUTE10, WIN03). What an explicit Quit does to a Cast session. Default: STOP the receiver. "Leave" (disconnect and let the receiver keep playing)
// exists only where the receiver fetches the media itself; when the Mac relays the media nothing can continue after quitting, so the plan is to stop and
// to SAY so, and a remembered Leave is never honoured for a relayed session. A choice the person made is remembered; the default is Stop.

public enum CastContinuation: Sendable, Equatable {
    /// The Mac serves the media (the scoped local relay): playback ends when the app does.
    case macRelays
    /// The receiver fetches the media from a public address by itself: it can keep playing without this app.
    case receiverIndependent
}
public enum CastQuitChoice: String, Sendable, Equatable { case stop, leave }
public enum CastQuitPlan: Equatable, Sendable {
    case notCasting
    /// Stop the receiver. `explainRelay` is true when the person must be told that playback cannot continue because the Mac is relaying the media.
    case stop(explainRelay: Bool)
    /// Leave the receiver playing (a remembered choice, honoured only for an independent receiver).
    case leave
    /// Ask whether to stop or leave; Stop is the default button.
    case ask
}

public enum CastQuitPolicy {
    public static func plan(isCasting: Bool, continuation: CastContinuation, remembered: CastQuitChoice?) -> CastQuitPlan {
        guard isCasting else { return .notCasting }
        switch continuation {
        case .macRelays: return .stop(explainRelay: true)
        case .receiverIndependent:
            switch remembered {
            case .leave?: return .leave
            case .stop?: return .stop(explainRelay: false)
            case nil: return .ask
            }
        }
    }
}

public protocol CastQuitChoiceStoring: Sendable {
    func load() -> CastQuitChoice?
    func save(_ choice: CastQuitChoice?)
}
public struct DefaultsCastQuitChoice: CastQuitChoiceStoring, @unchecked Sendable {
    public static let key = "local.native-music.cast-quit-choice"
    private let defaults: UserDefaults
    public init(_ defaults: UserDefaults) { self.defaults = defaults }
    public func load() -> CastQuitChoice? { defaults.string(forKey: Self.key).flatMap(CastQuitChoice.init(rawValue:)) }
    public func save(_ choice: CastQuitChoice?) { if let choice { defaults.set(choice.rawValue, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) } }
}
public final class MemoryCastQuitChoice: CastQuitChoiceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: CastQuitChoice?
    public init(_ value: CastQuitChoice? = nil) { self.value = value }
    public func load() -> CastQuitChoice? { lock.withLock { value } }
    public func save(_ choice: CastQuitChoice?) { lock.withLock { value = choice } }
}

/// A media address a receiver may fetch by itself (the only kind that makes "Leave" possible): a public https address with no embedded credentials and not
/// a Google or YouTube host. Nothing in this app produces one today; the check exists so that none can ever carry the account's playback to a receiver (ROUTE06).
public enum CastDirectSourcePolicy {
        public static let refusedSuffixes = [".google.com", ".googleapis.com", ".googlevideo.com", ".googleusercontent.com", ".gstatic.com", ".youtube.com", ".youtube-nocookie.com", ".youtu.be", ".ytimg.com", ".ggpht.com", ".withgoogle.com"]   // leading dot: a deny list, not destinations
    public static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { throw CastError.sourceNotCastable("not a plain https address") }
        if refusedSuffixes.contains(where: { host == String($0.dropFirst()) || host.hasSuffix($0) }) { throw CastError.sourceNotCastable("account media cannot be handed to a receiver") }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") || CastNetworkGate.IPv4(host) != nil { throw CastError.sourceNotCastable("not a public address") }
    }
}
