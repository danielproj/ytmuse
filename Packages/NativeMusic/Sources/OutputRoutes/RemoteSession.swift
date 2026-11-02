import Foundation

// W22 (ROUTE08, ROUTE09, DATA03). A remote (AirPlay external-playback) session as the app knows it: an identifier and a generation so a delayed
// event from an earlier session is ignored, and a position that is only ever what the RECEIVER side reported, with the instant it was observed.
// The app never advances this position with a local timer.

public enum RemoteState: Sendable, Equatable { case connecting, playing, paused, stopped }
/// What kind of receiver the remote session is on. W39 added Cast beside AirPlay external playback; both share this one session model (ROUTE08, DATA03).
public enum RemoteKind: Sendable, Equatable { case airPlay, cast(CastDeviceID) }
/// A receiver's own reported level (Cast). nil fields were not reported.
public struct ReceiverVolume: Equatable, Sendable {
    public let level: Double?, muted: Bool?
    /// The receiver says its volume is fixed (it ignores a level it is sent).
    public let fixed: Bool
    public init(level: Double?, muted: Bool?, fixed: Bool = false) { self.level = level; self.muted = muted; self.fixed = fixed }
}
public enum RemoteEnd: Sendable, Equatable {
    /// A person chose another route (or turned AirPlay off) in the system picker.
    case chosenByPerson
    /// The receiver went away without a choice: a route loss.
    case receiverLost
}
public struct PositionReading: Equatable, Sendable {
    public let seconds: Double
    public let observedAt: ContinuousClock.Instant
    public init(seconds: Double, observedAt: ContinuousClock.Instant) { self.seconds = seconds; self.observedAt = observedAt }
}
public enum RemoteEvent: Sendable, Equatable {
    case position(Double, observedAt: ContinuousClock.Instant)
    case state(RemoteState)
    /// W39: what the receiver says it can do with the item (pause, seek, stream volume, mute). Shown as reported.
    case capabilities(CastReceiverCapabilities)
    case volume(ReceiverVolume)
    case ended(RemoteEnd)
}

public struct RemoteSession: Equatable, Sendable {
    public let id: UUID
    public let generation: UInt64
    public let kind: RemoteKind
    public private(set) var state: RemoteState
    public private(set) var reading: PositionReading?
    public private(set) var capabilities: CastReceiverCapabilities?
    public private(set) var volume: ReceiverVolume?
    init(id: UUID, generation: UInt64, kind: RemoteKind = .airPlay) { self.id = id; self.generation = generation; self.kind = kind; state = .connecting }
    public var isCast: Bool { if case .cast = kind { true } else { false } }
    mutating func apply(state new: RemoteState) { state = new }
    mutating func apply(capabilities new: CastReceiverCapabilities) { capabilities = new }
    mutating func apply(volume new: ReceiverVolume) { volume = new }
    mutating func apply(reading new: PositionReading) {
        // Observations can arrive out of order: an older reading never replaces a newer one.
        if let reading, reading.observedAt > new.observedAt { return }
        reading = new
    }
    /// The position to show: exactly the receiver's last report, or nil when it has not reported or the report is older than `staleAfter`.
    /// Never extrapolated; a stale reading is withheld rather than guessed forward.
    public func displayedPosition(now: ContinuousClock.Instant, staleAfter: Duration = .seconds(10)) -> Double? {
        guard let reading, now - reading.observedAt <= staleAfter else { return nil }
        return reading.seconds
    }
}
