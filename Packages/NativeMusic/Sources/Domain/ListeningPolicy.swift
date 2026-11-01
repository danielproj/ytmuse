import Foundation

/// When listening counts as a play. A service adapter defines its own policy (what its player reports and what the app can
/// observe differ per service); the recorder only applies it. The numbers are about time actually heard: buffering, an
/// advertisement, a preview, a seek or a repeated end report never add to it.
public struct ListeningPolicy: Sendable, Equatable {
    /// The most listening a play ever needs, however long the item is.
    public let maximumSeconds: Double
    /// The share of the item's length that counts for a short item.
    public let fractionOfDuration: Double
    /// Position progress beyond the elapsed clock time that is still ordinary playback (timer jitter); more than this is a seek.
    public let seekTolerance: Double
    public init(maximumSeconds: Double, fractionOfDuration: Double, seekTolerance: Double) {
        self.maximumSeconds = maximumSeconds; self.fractionOfDuration = fractionOfDuration; self.seekTolerance = seekTolerance
    }
    /// Seconds heard that make a play, or nil while the item's length is unknown (nothing counts before the player says how long it is).
    public func threshold(duration: Double) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        return min(maximumSeconds, duration * fractionOfDuration)
    }
}
