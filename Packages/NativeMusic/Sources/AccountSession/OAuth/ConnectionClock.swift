import Foundation

/// One monotonic time domain for TTL checks and deadline scheduling. Wall-clock
/// timestamps are separate: signed JWT absolute time claims use an injected wall clock.
public protocol ConnectionClock: Sendable {
    func now() -> TimeInterval
    func sleep(until deadline: TimeInterval) async throws
}
public struct SystemConnectionClock: ConnectionClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    public init() { origin = .now }
    public func now() -> TimeInterval {
        let value = origin.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    public func sleep(until deadline: TimeInterval) async throws {
        try await clock.sleep(until: origin.advanced(by: .seconds(deadline)))
    }
}
