import Foundation
import MediaPlayer
import Synchronization

// W23 (MAC01, MAC02, ARCH03). The vocabulary of the system's remote commands and the one place the app registers for them.
//
// Media keys, AirPods buttons, Control Center and the Lock Screen widget all reach the app through MPRemoteCommandCenter and nothing else: no
// event tap, no global key monitor, no IOHID access, no private MediaRemote framework (`SystemMediaGuardTests` sweeps the sources, the built
// binary's symbols and its entitlements). The commands below are the ones the app can answer. Each is enabled only while the playback owner can
// actually perform it right now, so the system never offers a button the handler would then refuse.

/// One remote command the app answers.
public enum RemoteCommandKind: String, CaseIterable, Sendable, Hashable {
    case play, pause, toggle, next, previous, seek, skipForward, skipBackward, changeRate, like, dislike, save
}

/// A remote command with its argument, as the playback owner receives it.
public enum RemoteTransportCommand: Sendable, Equatable {
    case play, pause, toggle, next, previous
    case seek(Double)
    /// A jump in seconds: positive forward, negative back (podcast episodes).
    case skip(Double)
    /// A listening speed (podcast episodes).
    case rate(Double)
    /// Like, dislike and Save to Library act on the item that is playing through the library ledger. Each carries the state the SYSTEM asked for
    /// (a press on an off button asks for on, a press on an on button asks for off), so a press made against a stale button can never invert.
    case setLike(Bool), setDislike(Bool), setSave(Bool)
    public var kind: RemoteCommandKind {
        switch self {
        case .play: .play
        case .pause: .pause
        case .toggle: .toggle
        case .next: .next
        case .previous: .previous
        case .seek: .seek
        case .skip(let seconds): seconds < 0 ? .skipBackward : .skipForward
        case .rate: .changeRate
        case .setLike: .like
        case .setDislike: .dislike
        case .setSave: .save
        }
    }
}
public enum RemoteCommandOutcome: Sendable, Equatable { case success, refused, noActionableItem }

/// The argument a system event carried, reduced to plain values so a fake system can deliver one without MediaPlayer's event classes.
public enum RemoteCommandInput: Sendable, Equatable {
    case none
    case position(Double)
    case interval(Double)
    case rate(Double)
    /// A like, dislike or bookmark event: `negative` is true when the person pressed a button that showed as on (they want it off).
    case feedback(negative: Bool)
}

/// Turns what the system delivered into the owner's command. Pure.
public enum RemoteEventMapping {
    /// The state a feedback press asks for. An event that says nothing asks for on.
    private static func wanted(_ input: RemoteCommandInput) -> Bool {
        if case .feedback(let negative) = input { return !negative }
        return true
    }
    public static func command(_ kind: RemoteCommandKind, _ input: RemoteCommandInput) -> RemoteTransportCommand? {
        switch kind {
        case .play: return .play
        case .pause: return .pause
        case .toggle: return .toggle
        case .next: return .next
        case .previous: return .previous
        case .like: return .setLike(wanted(input))
        case .dislike: return .setDislike(wanted(input))
        case .save: return .setSave(wanted(input))
        case .seek:
            guard case .position(let seconds) = input, seconds.isFinite, seconds >= 0 else { return nil }
            return .seek(seconds)
        case .skipForward, .skipBackward:
            guard case .interval(let seconds) = input, seconds.isFinite, seconds > 0 else { return nil }
            return .skip(kind == .skipBackward ? -seconds : seconds)
        case .changeRate:
            guard case .rate(let rate) = input, rate.isFinite, rate > 0 else { return nil }
            return .rate(rate)
        }
    }
}

/// Which commands the owner can perform right now, and why not for the others. The owner computes it from live state on every change and again,
/// fresh, when a command arrives, so the enable flags and the handler's answer cannot disagree.
public struct RemoteCapabilities: Sendable, Equatable {
    /// True once an item is loaded (even paused or restored). False: nothing to act on.
    public var hasItem: Bool
    public var enabled: Set<RemoteCommandKind>
    /// A sentence for each command that is off while an item exists. Shown wherever the app has a place to say why.
    public var reasons: [RemoteCommandKind: String]
    /// The episode jump lengths the system should offer, when the item is a podcast episode.
    public var skipBack: Int?
    public var skipForward: Int?
    /// The speeds the system's speed control may offer (an episode only).
    public var rates: [Double]
    /// Whether the system's Like, Dislike and Save buttons show as on.
    public var active: Set<RemoteCommandKind>
    public init(hasItem: Bool = false, enabled: Set<RemoteCommandKind> = [], reasons: [RemoteCommandKind: String] = [:], skipBack: Int? = nil,
                skipForward: Int? = nil, rates: [Double] = [], active: Set<RemoteCommandKind> = []) {
        self.hasItem = hasItem; self.enabled = enabled; self.reasons = reasons; self.skipBack = skipBack; self.skipForward = skipForward
        self.rates = rates; self.active = active
    }
    public static let none = RemoteCapabilities()
    public func allows(_ kind: RemoteCommandKind) -> Bool { hasItem && enabled.contains(kind) }
}

/// The system side of the remote commands: registers one handler per command, switches them on and off, and lets exactly one owner hold them.
@MainActor public protocol RemoteCommandSystem: AnyObject {
    /// Targets this system holds right now (zero when nobody owns it).
    var registrationCount: Int { get }
    /// Registers every command for `owner`. False when another owner already holds them; the same owner asking twice changes nothing.
    func attach(owner: ObjectIdentifier, handler: @escaping @Sendable (RemoteCommandKind, RemoteCommandInput) -> MPRemoteCommandHandlerStatus) -> Bool
    /// Removes every target and switches every command off. Only the owner can.
    func detach(owner: ObjectIdentifier)
    func apply(_ capabilities: RemoteCapabilities, owner: ObjectIdentifier)
}

/// The system's now-playing information: one dictionary and one playback state.
@MainActor public protocol NowPlayingInfoSink: AnyObject {
    func publish(_ info: [String: Any]?, state: MPNowPlayingPlaybackState)
}

/// The two halves together. `live` is the real MediaPlayer (one process-wide pair); `recording()` is a stand-in that touches nothing.
public struct NowPlayingSystem {
    public let info: any NowPlayingInfoSink
    public let commands: any RemoteCommandSystem
    public init(info: any NowPlayingInfoSink, commands: any RemoteCommandSystem) { self.info = info; self.commands = commands }
    /// The real MPNowPlayingInfoCenter and MPRemoteCommandCenter. One pair for the whole process.
    @MainActor public static let live = NowPlayingSystem(info: LiveNowPlayingInfo(), commands: LiveRemoteCommands())
    /// A recording stand-in: nothing reaches the Mac's media session, so a test never takes the account holder's media keys.
    @MainActor public static func recording() -> RecordingNowPlayingSystem { RecordingNowPlayingSystem() }
}

// MARK: Real MediaPlayer

@MainActor public final class LiveNowPlayingInfo: NowPlayingInfoSink {
    public init() {}
    public func publish(_ info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = state
    }
}

@MainActor public final class LiveRemoteCommands: RemoteCommandSystem {
    private var targets: [(MPRemoteCommand, Any)] = []
    private var owner: ObjectIdentifier?
    /// Attempts by a second owner while one held the commands (a measurement: zero in a correct app).
    public private(set) var refusedOwners = 0
    public init() {}
    public var registrationCount: Int { targets.count }

    /// Built nonisolated so the closures handed to MediaPlayer are not inferred @MainActor (NP1: MediaPlayer calls them on a private queue).
    nonisolated private static func target(_ kind: RemoteCommandKind, _ handler: @escaping @Sendable (RemoteCommandKind, RemoteCommandInput) -> MPRemoteCommandHandlerStatus)
        -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in handler(kind, input(from: event)) }
    }
    nonisolated static func input(from event: MPRemoteCommandEvent) -> RemoteCommandInput {
        if let position = event as? MPChangePlaybackPositionCommandEvent { return .position(position.positionTime) }
        if let skip = event as? MPSkipIntervalCommandEvent { return .interval(skip.interval) }
        if let rate = event as? MPChangePlaybackRateCommandEvent { return .rate(Double(rate.playbackRate)) }
        if let feedback = event as? MPFeedbackCommandEvent { return .feedback(negative: feedback.isNegative) }
        return .none
    }
    private func command(_ kind: RemoteCommandKind) -> MPRemoteCommand {
        let center = MPRemoteCommandCenter.shared()
        switch kind {
        case .play: return center.playCommand
        case .pause: return center.pauseCommand
        case .toggle: return center.togglePlayPauseCommand
        case .next: return center.nextTrackCommand
        case .previous: return center.previousTrackCommand
        case .seek: return center.changePlaybackPositionCommand
        case .skipForward: return center.skipForwardCommand
        case .skipBackward: return center.skipBackwardCommand
        case .changeRate: return center.changePlaybackRateCommand
        case .like: return center.likeCommand
        case .dislike: return center.dislikeCommand
        case .save: return center.bookmarkCommand
        }
    }
    public func attach(owner new: ObjectIdentifier, handler: @escaping @Sendable (RemoteCommandKind, RemoteCommandInput) -> MPRemoteCommandHandlerStatus) -> Bool {
        if let owner { if owner == new { return true }; refusedOwners += 1; return false }
        owner = new
        for kind in RemoteCommandKind.allCases {
            let command = command(kind)
            command.isEnabled = false
            targets.append((command, command.addTarget(handler: Self.target(kind, handler))))
        }
        return true
    }
    public func detach(owner candidate: ObjectIdentifier) {
        guard owner == candidate else { return }
        for (command, target) in targets { command.removeTarget(target); command.isEnabled = false }
        targets = []; owner = nil
    }
    public func apply(_ capabilities: RemoteCapabilities, owner candidate: ObjectIdentifier) {
        guard owner == candidate else { return }
        let center = MPRemoteCommandCenter.shared()
        for kind in RemoteCommandKind.allCases { command(kind).isEnabled = capabilities.allows(kind) }
        if let back = capabilities.skipBack { center.skipBackwardCommand.preferredIntervals = [NSNumber(value: back)] }
        if let forward = capabilities.skipForward { center.skipForwardCommand.preferredIntervals = [NSNumber(value: forward)] }
        if !capabilities.rates.isEmpty { center.changePlaybackRateCommand.supportedPlaybackRates = capabilities.rates.map { NSNumber(value: $0) } }
        center.likeCommand.isActive = capabilities.active.contains(.like)
        center.dislikeCommand.isActive = capabilities.active.contains(.dislike)
        center.bookmarkCommand.isActive = capabilities.active.contains(.save)
    }
}

// MARK: Recording stand-in

@MainActor public final class RecordingNowPlayingInfo: NowPlayingInfoSink {
    public private(set) var info: [String: Any]?
    public private(set) var state: MPNowPlayingPlaybackState = .stopped
    /// Every publish, newest last (a nil info is a clear).
    public private(set) var writes: [(info: [String: Any]?, state: MPNowPlayingPlaybackState)] = []
    public init() {}
    public func publish(_ info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        self.info = info; self.state = state; writes.append((info, state))
    }
}

@MainActor public final class RecordingRemoteCommands: RemoteCommandSystem {
    public private(set) var owner: ObjectIdentifier?
    public private(set) var handler: (@Sendable (RemoteCommandKind, RemoteCommandInput) -> MPRemoteCommandHandlerStatus)?
    public private(set) var enabled: Set<RemoteCommandKind> = []
    public private(set) var capabilities = RemoteCapabilities.none
    /// Registrations ever made, and attempts a second owner made while one held the commands.
    public private(set) var attachCount = 0
    public private(set) var refusedOwners = 0
    public private(set) var detachCount = 0
    public init() {}
    public var registrationCount: Int { owner == nil ? 0 : RemoteCommandKind.allCases.count }
    public func attach(owner new: ObjectIdentifier, handler: @escaping @Sendable (RemoteCommandKind, RemoteCommandInput) -> MPRemoteCommandHandlerStatus) -> Bool {
        if let owner { if owner == new { return true }; refusedOwners += 1; return false }
        owner = new; self.handler = handler; attachCount += 1
        return true
    }
    public func detach(owner candidate: ObjectIdentifier) {
        guard owner == candidate else { return }
        owner = nil; handler = nil; enabled = []; capabilities = .none; detachCount += 1
    }
    public func apply(_ capabilities: RemoteCapabilities, owner candidate: ObjectIdentifier) {
        guard owner == candidate else { return }
        self.capabilities = capabilities
        enabled = Set(RemoteCommandKind.allCases.filter { capabilities.allows($0) })
    }
    /// What the system would do on a press: nothing when the command is switched off or nobody holds the commands; otherwise the handler answers.
    public func press(_ kind: RemoteCommandKind, _ input: RemoteCommandInput = .none) -> MPRemoteCommandHandlerStatus? {
        guard let handler, enabled.contains(kind) else { return nil }
        return handler(kind, input)
    }
    /// Delivers a command whether or not it is enabled (a late or stray delivery), for the cases that must still be refused.
    public func deliver(_ kind: RemoteCommandKind, _ input: RemoteCommandInput = .none) -> MPRemoteCommandHandlerStatus? { handler?(kind, input) }
}

@MainActor public final class RecordingNowPlayingSystem {
    public let info = RecordingNowPlayingInfo()
    public let commands = RecordingRemoteCommands()
    public init() {}
    public var system: NowPlayingSystem { NowPlayingSystem(info: info, commands: commands) }
}
