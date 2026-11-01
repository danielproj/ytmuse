import Foundation

// W22 (ROUTE03, ROUTE09). When does the sound's way out disappear, and what is remembered about it?

public enum RouteLossReason: Sendable, Equatable {
    /// The headphone jack of the built-in output went from headphones back to speakers.
    case headphonesUnplugged
    /// An external output (USB, Bluetooth, HDMI ...) is gone.
    case deviceDisconnected
    /// The AirPlay receiver stopped receiving without a person choosing another route.
    case receiverDisconnected
}

public enum RouteAssessment: Equatable, Sendable {
    case unchanged
    /// The same output now drives something else (headphones plugged in): sound continues, nothing was lost.
    case moved(RouteIdentity)
    case lost(RouteLossReason)
}

public enum RouteLossPolicy {
    /// Compares the output the sound was leaving through with what the system offers now. A device that is no longer a live output, or a built-in
    /// output that stopped driving headphones, is a LOSS; any other change (the person picked another output, a new device was attached) is not.
    public static func assess(audible: RouteIdentity, in now: OutputSnapshot) -> RouteAssessment {
        guard let device = now.device(uid: audible.uid) else { return .lost(.deviceDisconnected) }
        let wasHeadphones = audible.dataSource.map { BuiltInDataSource(code: $0) == .headphones } ?? false
        if wasHeadphones, device.builtInSource != .headphones { return .lost(.headphonesUnplugged) }
        return device.identity == audible ? .unchanged : .moved(device.identity)
    }
}

/// A route that went away while it was the way out (or the chosen route), until a person reconnects, plays here, or picks another route.
public struct RouteLoss: Equatable, Sendable {
    public let reason: RouteLossReason
    /// The engine that was making sound when the route went away; nil when nothing was playing.
    public let engine: OutputEngineKind?
    /// What went away (nil for a receiver, which has no CoreAudio identity).
    public let lost: RouteIdentity?
    /// The route the person had chosen at the time.
    public let lostRoute: OutputRouteID
    /// The route generation that was current when it happened; later events from that route are stale.
    public let generation: UInt64
    public let wasAudible: Bool
    public init(reason: RouteLossReason, engine: OutputEngineKind?, lost: RouteIdentity?, lostRoute: OutputRouteID, generation: UInt64, wasAudible: Bool) {
        self.reason = reason; self.engine = engine; self.lost = lost; self.lostRoute = lostRoute; self.generation = generation; self.wasAudible = wasAudible
    }
    /// The lost output is a live output again. Reconnecting does not resume anything (ROUTE03); it only makes "Reconnect" available.
    public func canReconnect(in snapshot: OutputSnapshot, casts: [CastDevice] = []) -> Bool {
        if let device = lostRoute.castDeviceID { return casts.contains { $0.id == device } }   // W39: a receiver is back when it is seen on the network again
        guard let lost else { return false }
        return snapshot.device(uid: lost.uid) != nil
    }
}

public protocol PreferredRouteStoring: Sendable {
    func load() -> OutputRouteID?
    func save(_ route: OutputRouteID?)
}
/// The preferred route in the app's preferences, as the stable identifier string only.
public struct DefaultsPreferredRoute: PreferredRouteStoring, @unchecked Sendable {
    public static let key = "local.native-music.preferred-output-route"
    private let defaults: UserDefaults
    public init(_ defaults: UserDefaults) { self.defaults = defaults }
    public func load() -> OutputRouteID? { defaults.string(forKey: Self.key).flatMap(OutputRouteID.init(persisted:)) }
    public func save(_ route: OutputRouteID?) { if let route { defaults.set(route.rawValue, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) } }
}
public final class MemoryPreferredRoute: PreferredRouteStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: OutputRouteID?
    public init(_ value: OutputRouteID? = nil) { self.value = value }
    public func load() -> OutputRouteID? { lock.withLock { value } }
    public func save(_ route: OutputRouteID?) { lock.withLock { value = route } }
}
