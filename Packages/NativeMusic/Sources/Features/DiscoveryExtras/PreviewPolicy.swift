import Foundation

/// What the person chose for previews that start by themselves (DISC04). `automatic` follows the device: previews do not start by
/// themselves on Low Power Mode or a constrained connection. The choice is kept for the session only; where it is stored belongs to Settings.
public enum PreviewAutoplayPreference: String, Sendable, Equatable, CaseIterable {
    case automatic, off, on
}

/// The device conditions that matter to autoplay, read when a preview is asked for and again when they change.
public struct PreviewConditions: Sendable, Equatable {
    public var lowPowerMode: Bool
    /// Low Data Mode, or a connection the system calls expensive (a metered hotspot). Both count as constrained.
    public var constrainedNetwork: Bool
    /// Something other than a preview is playing in the shared playback session.
    public var playbackBusy: Bool
    public init(lowPowerMode: Bool = false, constrainedNetwork: Bool = false, playbackBusy: Bool = false) {
        self.lowPowerMode = lowPowerMode; self.constrainedNetwork = constrainedNetwork; self.playbackBusy = playbackBusy
    }
}

public enum PreviewRefusal: Error, Sendable, Equatable {
    case lowPowerMode, constrainedNetwork, turnedOff, playbackBusy
    /// The preview engine could not start the clip.
    case engineFailed
    /// The clip was replaced by a newer request before it could start.
    case superseded
    public var message: String {
        switch self {
        case .lowPowerMode: String(localized: "Previews don’t start by themselves while Low Power Mode is on. Press Preview to hear one.")
        case .constrainedNetwork: String(localized: "Previews don’t start by themselves on a constrained connection. Press Preview to hear one.")
        case .turnedOff: String(localized: "Previews that start by themselves are turned off. Press Preview to hear one.")
        case .playbackBusy: String(localized: "Something is already playing, so previews don’t start by themselves. Press Preview to hear one; it replaces what’s playing.")
        case .engineFailed: String(localized: "This preview could not start.")
        case .superseded: String(localized: "A newer preview replaced this one.")
        }
    }
}

public enum PreviewTrigger: Sendable, Equatable {
    /// Started by focusing a clip, with no press.
    case autoplay
    /// The person pressed Preview.
    case explicit
}

public enum PreviewPolicy {
    /// nil: the preview may start by itself. Otherwise the reason it may not. An explicit press is never refused by this policy.
    public static func autoplayRefusal(preference: PreviewAutoplayPreference, conditions: PreviewConditions) -> PreviewRefusal? {
        switch preference {
        case .off: return .turnedOff
        case .on: return conditions.playbackBusy ? .playbackBusy : nil
        case .automatic:
            if conditions.lowPowerMode { return .lowPowerMode }
            if conditions.constrainedNetwork { return .constrainedNetwork }
            if conditions.playbackBusy { return .playbackBusy }
            return nil
        }
    }
}
