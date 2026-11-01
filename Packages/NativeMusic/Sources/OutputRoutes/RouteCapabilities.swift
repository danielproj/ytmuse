import Foundation

// W22 (ROUTE01, ROUTE04, PLAY17). What each engine can do with each kind of route, from PUBLIC APIs only. `Docs/Routes.md` records the evidence behind
// every row; the picker, the volume control, the sleep-timer warning and the quit behaviour all read this one table, so no control can offer what the
// route cannot honour.

/// How the local engine draws its sound, which decides whether the system AirPlay picker can reach it. Only the hidden player has no choice at all.
public enum OutputBackend: Sendable, Equatable {
    /// `AVPlayer`: per-player output device (`audioOutputDeviceUniqueID`) and AirPlay through `AVRoutePickerView` / external playback.
    case avPlayer
    /// The authorized decoded `AVAudioEngine` graph: per-engine output device through its output unit; the picker takes an `AVPlayer` only.
    case decodedGraph
    /// YouTube Music's own web player in the hidden `WKWebView`: follows the Mac's output.
    case hiddenWebPlayer
}

/// Where the sound goes, as far as the app can tell.
public enum RouteMode: Sendable, Equatable {
    /// An ordinary Mac output (built-in, USB, Bluetooth, HDMI ...), or an AirPlay speaker the SYSTEM has made an output: the app renders the sound.
    case systemOutput(OutputTransport)
    /// AVFoundation external playback to an AirPlay receiver: the receiver renders and decides the level.
    case externalPlayback
    /// W39: a Cast receiver plays media the Mac serves through the scoped local relay; the receiver renders and decides the level.
    case castReceiver
}

public struct RouteCapabilities: Equatable, Sendable {
    public enum Selection: Sendable, Equatable {
        /// This app can point the engine at the route by its stable identifier.
        case appSelectable
        /// Only the system's AirPlay picker can choose it (the app shows the picker; it cannot enumerate or connect to receivers itself).
        case systemPickerOnly
        /// The engine plays through whatever the Mac is set to; changing it is done in the system.
        case systemControlled
    }
    public enum Volume: Sendable, Equatable {
        /// The app's own level applies; the output's own level stays the Mac's (the app never changes system volume).
        case appLevel
        /// The receiver sets the level; the app's level may not reach it.
        case receiver
    }
    public enum Timer: Sendable, Equatable {
        /// The sleep timer fades the app's sound over 5 seconds and pauses.
        case fadeThenPause
        /// The timer can pause the route but cannot fade it; the person is told before enabling it (PLAY17).
        case pauseOnly
    }
    public enum Grouping: Sendable, Equatable {
        /// The app offers no grouping controls.
        case notOffered
        /// Multiroom exists only inside the system's own picker, to the extent the system exposes it (ROUTE04).
        case systemPickerOnly
    }
    public enum QuitBehavior: Sendable, Equatable {
        /// Quitting ends the sound (the Mac renders it, or the receiver stops with the app's player).
        case stopsPlayback
        /// W39 (ROUTE10): the Mac serves the media to the receiver, so playback cannot continue after quitting. The route says so before it is used.
        case stopsBecauseMacRelays
    }
    /// What this route cannot do from inside the app; the picker states each one in plain words (ROUTE01).
    public enum Limit: Sendable, Equatable, CaseIterable {
        case chooseOutputInApp, chooseAirPlayInApp, groupReceivers, fadeOnReceiver, changeDeviceVolume
        /// W39: YouTube Music cannot be cast from this app (no sanctioned way to give a receiver the account's playback; `Docs/Cast.md`).
        case castYouTubeMusic
        /// W39: the receiver gets the original file, so the equalizer, normalization and crossfade do not apply there.
        case castIgnoresAudioEffects
    }
    public let selection: Selection
    public let volume: Volume
    public let timer: Timer
    public let grouping: Grouping
    public let quit: QuitBehavior
    public let limits: [Limit]

    /// The single resolution of engine x backend x route. Nothing else in the app decides what a route supports.
    public static func resolve(engine: OutputEngineKind, backend: OutputBackend, mode: RouteMode) -> RouteCapabilities {
        let airPlayOutput: Bool = { if case .systemOutput(.airPlay) = mode { true } else { false } }()
        switch (engine, backend, mode) {
        case (.youTubeMusic, _, .castReceiver), (_, .hiddenWebPlayer, .castReceiver):
            return RouteCapabilities(selection: .systemControlled, volume: .appLevel, timer: .fadeThenPause, grouping: .notOffered, quit: .stopsPlayback, limits: [.castYouTubeMusic])
        case (.localMedia, .avPlayer, .castReceiver), (.localMedia, .decodedGraph, .castReceiver):
            return RouteCapabilities(selection: .appSelectable, volume: .receiver, timer: .pauseOnly, grouping: .notOffered, quit: .stopsBecauseMacRelays,
                                     limits: [.groupReceivers, .fadeOnReceiver, .changeDeviceVolume] + (backend == .decodedGraph ? [.castIgnoresAudioEffects] : []))
        case (.youTubeMusic, _, _), (_, .hiddenWebPlayer, _):
            // No public per-element output choice or AirPlay target exists for the hidden page (`Docs/Routes.md`), so it follows the Mac.
            return RouteCapabilities(selection: .systemControlled, volume: .appLevel, timer: .fadeThenPause, grouping: .notOffered, quit: .stopsPlayback,
                                     limits: [.chooseOutputInApp, .chooseAirPlayInApp, .groupReceivers, .changeDeviceVolume])
        case (.localMedia, .avPlayer, .externalPlayback):
            return RouteCapabilities(selection: .systemPickerOnly, volume: .receiver, timer: .pauseOnly, grouping: .systemPickerOnly, quit: .stopsPlayback,
                                     limits: [.groupReceivers, .fadeOnReceiver, .changeDeviceVolume])
        case (.localMedia, .avPlayer, .systemOutput):
            return RouteCapabilities(selection: airPlayOutput ? .systemPickerOnly : .appSelectable, volume: .appLevel, timer: .fadeThenPause,
                                     grouping: airPlayOutput ? .systemPickerOnly : .notOffered, quit: .stopsPlayback,
                                     limits: [.groupReceivers, .changeDeviceVolume])
        case (.localMedia, .decodedGraph, .systemOutput):
            // The decoded graph can be pointed at a device, but the system picker cannot attach to it (it takes an AVPlayer only).
            return RouteCapabilities(selection: airPlayOutput ? .systemPickerOnly : .appSelectable, volume: .appLevel, timer: .fadeThenPause,
                                     grouping: airPlayOutput ? .systemPickerOnly : .notOffered, quit: .stopsPlayback,
                                     limits: [.chooseAirPlayInApp, .groupReceivers, .changeDeviceVolume])
        case (.localMedia, .decodedGraph, .externalPlayback):
            return RouteCapabilities(selection: .systemControlled, volume: .appLevel, timer: .fadeThenPause, grouping: .notOffered, quit: .stopsPlayback,
                                     limits: [.chooseAirPlayInApp, .groupReceivers, .changeDeviceVolume])
        }
    }
    /// The AirPlay picker is offered only where it can reach the engine: a local `AVPlayer`.
    public static func offersSystemPicker(engine: OutputEngineKind, backend: OutputBackend) -> Bool { engine == .localMedia && backend == .avPlayer }
}

/// A route as the picker lists it (ROUTE01): identity, the current/connection state and the capabilities for the engine that would play on it.
public struct OutputRouteEntry: Equatable, Sendable, Identifiable {
    public enum Connection: Sendable, Equatable { case connected, unavailable }
    public let id: OutputRouteID
    public let name: String
    public let transport: OutputTransport?
    public let isCurrent: Bool
    public let connection: Connection
    public let capabilities: RouteCapabilities
    /// The route is the system output right now (for "System output (Built-in Speakers)").
    public let isSystemOutput: Bool
    /// W39: this is the route remembered from an earlier session (ROUTE02). It is only a marker; nothing connects to it by itself.
    public let isPreferred: Bool
    public init(id: OutputRouteID, name: String, transport: OutputTransport?, isCurrent: Bool, connection: Connection, capabilities: RouteCapabilities, isSystemOutput: Bool, isPreferred: Bool = false) {
        self.id = id; self.name = name; self.transport = transport; self.isCurrent = isCurrent; self.connection = connection; self.capabilities = capabilities; self.isSystemOutput = isSystemOutput; self.isPreferred = isPreferred
    }
}
