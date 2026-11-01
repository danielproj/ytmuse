import AppKit
import Foundation
import MediaPlayer
import Synchronization

/// Where the item is audible now (W22). MediaPlayer has no key for an output route (macOS shows the real route itself), so the route is part of what the
/// app publishes ABOUT the item: it changes the state the system is told (a lost route is a pause, a receiver's own position is the elapsed time) and it
/// goes in the same update as the item, so an item or account change never leaves the previous route behind.
public struct NowPlayingRoute: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case thisMac, airPlay, cast }
    public var kind: Kind
    public var name: String?
    public init(kind: Kind, name: String? = nil) { self.kind = kind; self.name = name }
}

/// What the app's playback session publishes to the system (MAC01).
public struct NowPlayingItem: Sendable, Equatable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var artwork: Data?
    public var duration: Double
    public var elapsed: Double
    public var playing: Bool
    /// An advertisement is playing. The system is shown the honest Ad state: no title, artist, artwork or clock of the song the ad interrupts.
    public var advertisement: Bool
    /// The listening speed while playing (W18): 1 for music; an episode at 1.5× advances the system's extrapolated clock 1.5 seconds per second.
    public var rate: Double
    /// A live stream: it has no duration and no elapsed time to publish.
    public var live: Bool
    /// The route the item is audible on (W22). Nil: unknown.
    public var route: NowPlayingRoute?
    /// The service's id of the item, so a change of item is a change of everything the system shows about it.
    public var itemID: String?
    public init(title: String, artist: String?, album: String?, artwork: Data?, duration: Double, elapsed: Double, playing: Bool, advertisement: Bool, rate: Double = 1,
                live: Bool = false, route: NowPlayingRoute? = nil, itemID: String? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.artwork = artwork
        self.duration = duration; self.elapsed = elapsed; self.playing = playing; self.advertisement = advertisement
        self.rate = rate.isFinite && (0.5...3).contains(rate) ? rate : 1
        self.live = live; self.route = route; self.itemID = itemID
    }
}

/// Pure mapping, unit-testable without the system singletons.
public enum NowPlayingMapping {
    /// What the system shows for an advertisement (MAC01, Playback addendum): the honest state, never the song's title or picture.
    public static var advertisementTitle: String { String(localized: "Advertisement") }

    public static func info(_ item: NowPlayingItem) -> [String: Any] {
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: item.live && !item.advertisement,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if item.advertisement {
            // An ad is YouTube's, not the person's: its title, artist and picture are not invented, the song's are not borrowed, and the clock of
            // the song it interrupts is not shown. The ad still plays, so the state says playing; the clock has nothing to say.
            info[MPMediaItemPropertyTitle] = advertisementTitle
            info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
            return info
        }
        info[MPMediaItemPropertyTitle] = item.title
        if let artist = item.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if !item.live {
            if item.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = item.duration }
            // The elapsed time is the position AT THE MOMENT OF THIS UPDATE: the system extrapolates from here at the published rate, so the
            // anchor is the call itself and the rate is 0 whenever the clock is not advancing (paused, buffering, ended).
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, min(item.elapsed, item.duration > 0 ? item.duration : item.elapsed))
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = item.playing ? item.rate : 0.0
        return info
    }
    /// Whether a new item differs from what the system already extrapolates from
    /// the last published one by more than drift (WIN10: no per-sample rewrites).
    public static func needsUpdate(from last: NowPlayingItem, elapsedSince: Duration, to item: NowPlayingItem, tolerance: Double = 1.5) -> Bool {
        if last.title != item.title || last.artist != item.artist || last.album != item.album || last.artwork != item.artwork
            || last.duration != item.duration || last.playing != item.playing || last.advertisement != item.advertisement || last.rate != item.rate
            || last.live != item.live || last.route != item.route || last.itemID != item.itemID { return true }
        // A live stream and an advertisement publish no elapsed time, so a moving position is not a change: only their state and metadata are.
        guard !item.live, !item.advertisement else { return false }
        let parts = elapsedSince.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let expected = last.elapsed + (last.playing && !last.advertisement && !last.live ? seconds * last.rate : 0)
        return abs(item.elapsed - expected) > tolerance
    }
    public static func state(_ item: NowPlayingItem?) -> MPNowPlayingPlaybackState {
        guard let item else { return .stopped }
        return item.playing ? .playing : .paused
    }
    /// A readable name for the state (the Debug census and logs print this, never the raw number).
    public static func stateName(_ state: MPNowPlayingPlaybackState) -> String {
        switch state {
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }
    public static func status(_ outcome: RemoteCommandOutcome) -> MPRemoteCommandHandlerStatus {
        switch outcome {
        case .success: .success
        case .refused: .commandFailed
        case .noActionableItem: .noActionableNowPlayingItem
        }
    }
    /// What the item alone allows. The playback owner knows more (a podcast's jumps, a live stream's window, the library controls) and supplies its own
    /// `RemoteCapabilities`; this is the floor for a caller that does not.
    public static func capabilities(for item: NowPlayingItem?) -> RemoteCapabilities {
        guard let item else { return .none }
        var enabled: Set<RemoteCommandKind> = [.play, .pause, .toggle]
        var reasons: [RemoteCommandKind: String] = [:]
        let adReason = String(localized: "An advertisement is playing. It cannot be skipped or sought.")
        if item.advertisement {
            for kind in [RemoteCommandKind.next, .previous, .seek] { reasons[kind] = adReason }
        } else {
            enabled.formUnion([.next, .previous])
            if !item.live && item.duration > 0 { enabled.insert(.seek) }
            else { reasons[.seek] = item.live ? String(localized: "A live stream cannot be sought.") : String(localized: "This item’s length is not known.") }
        }
        return RemoteCapabilities(hasItem: true, enabled: enabled, reasons: reasons)
    }
    /// The enabled commands by name.
    public static func enabled(_ item: NowPlayingItem?) -> Set<String> { Set(capabilities(for: item).enabled.map(\.rawValue)) }
}

/// An immutable image MediaPlayer may read from any queue.
final class NowPlayingImage: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}
enum NowPlayingArtwork {
    /// NP1 (live crash 2026-10-29): built in a nonisolated context with an explicitly
    /// `@Sendable`, nonisolated request handler that only returns an immutable image.
    /// MediaPlayer calls it on its private access queue; a closure created inside a
    /// `@MainActor` method is inferred `@MainActor` and traps there.
    nonisolated static func make(_ data: Data) -> MPMediaItemArtwork? {
        guard let image = NSImage(data: data) else { return nil }
        let held = NowPlayingImage(image)
        let handler: @Sendable (CGSize) -> NSImage = { _ in held.image }
        return MPMediaItemArtwork(boundsSize: image.size, requestHandler: handler)
    }
}

/// Which remote commands the session admits right now. Read from whatever queue MediaPlayer delivers a command on, so a refusal (seek during an ad)
/// can be answered synchronously without assuming the main actor. The generation says which ownership the answer belongs to: a command admitted
/// under one ownership is dropped if the owner changed before it ran (an account switch, a quit, a relinquish).
final class RemoteAdmission: Sendable {
    private struct State { var active = false; var capabilities = RemoteCapabilities.none; var generation: UInt64 = 0 }
    private let state = Mutex(State())
    func set(active: Bool, capabilities: RemoteCapabilities, generation: UInt64) {
        state.withLock { $0 = State(active: active, capabilities: capabilities, generation: generation) }
    }
    func admits(_ command: RemoteTransportCommand) -> (outcome: RemoteCommandOutcome, generation: UInt64) {
        state.withLock { current in
            guard current.active, current.capabilities.hasItem else { return (.noActionableItem, current.generation) }
            return (current.capabilities.enabled.contains(command.kind) ? .success : .refused, current.generation)
        }
    }
}

/// Owns MPNowPlayingInfoCenter and MPRemoteCommandCenter for the app while an item is active, and relinquishes both when it is not (MAC01). There is
/// exactly one of these in the app (`PlaybackModel.nowPlaying`); the system object refuses a second owner. No keyboard tap, no private framework.
@MainActor public final class NowPlayingCenter {
    /// Admits synchronously (so a refused seek reports failure to the system) and starts any asynchronous work itself.
    public typealias Handler = @MainActor (RemoteTransportCommand) -> RemoteCommandOutcome
    private let system: NowPlayingSystem
    private var handler: Handler?
    private var lastArtwork: Data?
    private(set) var artworkObject: MPMediaItemArtwork?
    private var published: NowPlayingItem?
    private var capabilities = RemoteCapabilities.none
    /// Bumped on every attach and detach: a command admitted under an earlier ownership is never delivered.
    private var generation: UInt64 = 0
    nonisolated let admission = RemoteAdmission()
    public init(system: NowPlayingSystem = .live) { self.system = system }
    /// Told (on the main actor) after the published item or the enabled commands changed, or ownership ended. It carries nothing: a listener reads `current` and
    /// `currentCapabilities`. The widget snapshot publisher (W25) is the one listener; it coalesces, so a burst of calls costs one write.
    public var onChange: (@MainActor () -> Void)?
    public var isActive: Bool { handler != nil }
    /// The item the system is being shown right now (nil when nothing is published).
    public var current: NowPlayingItem? { published }
    public var currentCapabilities: RemoteCapabilities { capabilities }
    /// Remote-command targets this owner holds (zero when it has let go).
    public var registrationCount: Int { handler == nil ? 0 : system.commands.registrationCount }

    /// The remote-command entry point, callable from any thread. On the main thread
    /// the session's own synchronous admission decides; elsewhere the thread-safe
    /// admission snapshot answers and the command is delivered on the main actor.
    nonisolated func respond(to action: RemoteTransportCommand?) -> MPRemoteCommandHandlerStatus {
        guard let action else { return .commandFailed }
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                guard let handler = self.handler else { return .noActionableNowPlayingItem }
                return NowPlayingMapping.status(handler(action))
            }
        }
        let (outcome, stamp) = admission.admits(action)
        if outcome == .success { Task { @MainActor [weak self] in self?.deliverAdmitted(action, generation: stamp) } }
        return NowPlayingMapping.status(outcome)
    }
    /// Runs a command that was admitted off the main thread, unless the ownership it was admitted under has ended (an account switch, a quit or a
    /// relinquish in between): a stale command never reaches the new owner's item.
    func deliverAdmitted(_ action: RemoteTransportCommand, generation stamp: UInt64) {
        guard generation == stamp, let handler else { return }
        _ = handler(action)
    }
    /// The ownership a command admitted now would be stamped with (a measurement for tests).
    var ownershipGeneration: UInt64 { generation }
    /// Built nonisolated so the closure handed to MediaPlayer is not inferred @MainActor.
    nonisolated private static func systemHandler(for center: NowPlayingCenter) -> @Sendable (RemoteCommandKind, RemoteCommandInput) -> MPRemoteCommandHandlerStatus {
        { [weak center] kind, input in center?.respond(to: RemoteEventMapping.command(kind, input)) ?? .commandFailed }
    }

    /// Takes the media keys and the remote commands. False when another owner already holds them (this one then owns nothing and publishes nothing).
    /// Asking again while active replaces the handler and changes nothing else: still one registration.
    @discardableResult public func activate(_ handler: @escaping Handler) -> Bool {
        guard system.commands.attach(owner: ObjectIdentifier(self), handler: Self.systemHandler(for: self)) else { return false }
        if self.handler == nil { generation &+= 1; admission.set(active: true, capabilities: capabilities, generation: generation) }
        self.handler = handler
        return true
    }
    /// Publishes the item (nil clears it) and switches each remote command on or off. `capabilities` is the owner's own answer; without one the
    /// item alone decides. Does nothing unless this center owns the commands.
    public func update(_ item: NowPlayingItem?, capabilities supplied: RemoteCapabilities? = nil) {
        guard handler != nil else { return }
        defer { onChange?() }
        setCapabilities(item == nil ? .none : (supplied ?? NowPlayingMapping.capabilities(for: item)))
        guard let item else { clearPublication(); return }
        var info = NowPlayingMapping.info(item)
        // A new item or an ad replaces EVERYTHING: the dictionary is built from this item alone, and the artwork is dropped with the item.
        if let data = item.artwork, !item.advertisement {
            if data != lastArtwork {
                // A picture that cannot be decoded is no picture: the previous item's must not stay.
                if let artwork = NowPlayingArtwork.make(data) { lastArtwork = data; artworkObject = artwork }
                else { lastArtwork = nil; artworkObject = nil }
            }
            if let artworkObject { info[MPMediaItemPropertyArtwork] = artworkObject }
        } else { lastArtwork = nil; artworkObject = nil }
        published = item
        system.info.publish(info, state: NowPlayingMapping.state(item))
    }
    /// Changes which commands are on without touching what is shown (a library control became available, an episode started).
    public func setCapabilities(_ new: RemoteCapabilities) {
        guard handler != nil, new != capabilities else { return }
        capabilities = new
        admission.set(active: true, capabilities: new, generation: generation)
        system.commands.apply(new, owner: ObjectIdentifier(self))
        onChange?()
    }
    private func clearPublication() {
        lastArtwork = nil; artworkObject = nil
        guard published != nil else { return }
        published = nil
        system.info.publish(nil, state: .stopped)
    }
    /// Removes every target, switches every command off and clears the published item, so another media application can take the keys.
    public func relinquish() {
        defer { onChange?() }
        let wasActive = handler != nil
        handler = nil; generation &+= 1; capabilities = .none
        admission.set(active: false, capabilities: .none, generation: generation)
        if wasActive { system.commands.detach(owner: ObjectIdentifier(self)) }
        let hadPublication = published != nil
        lastArtwork = nil; artworkObject = nil
        guard wasActive || hadPublication else { return }
        published = nil
        system.info.publish(nil, state: .stopped)
    }
}
