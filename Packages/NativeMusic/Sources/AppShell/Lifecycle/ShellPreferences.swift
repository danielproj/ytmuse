import AppKit
import CoreGraphics
import Foundation

/// The shell's settings, all in the app's one preferences store (`AppPreferences.store`: the throwaway plist under QA isolation).
enum ShellPreferenceKey {
    static let miniPlayerPinned = "shell.miniPlayer.pinned"
    static let miniPlayerExpanded = "shell.miniPlayer.expanded"
    static let statusTooltip = "shell.statusItem.trackTooltip"
    static let resumeAfterWake = "shell.resumeAfterWake"
}

/// The mini-player's two choices. Compact is about 360 x 160 points (WIN05); expanded shows the artwork large. Both stay resizable.
struct MiniPlayerPreferences: Equatable {
    var pinned = false
    var expanded = false
    static let compactSize = CGSize(width: 360, height: 160)
    static let expandedSize = CGSize(width: 360, height: 560)
    static let minimumCompact = CGSize(width: 320, height: 148)
    static let minimumExpanded = CGSize(width: 320, height: 480)
    var defaultSize: CGSize { expanded ? Self.expandedSize : Self.compactSize }
    var minimumSize: CGSize { expanded ? Self.minimumExpanded : Self.minimumCompact }
    static func load(from store: UserDefaults) -> MiniPlayerPreferences {
        MiniPlayerPreferences(pinned: store.bool(forKey: ShellPreferenceKey.miniPlayerPinned), expanded: store.bool(forKey: ShellPreferenceKey.miniPlayerExpanded))
    }
    func save(to store: UserDefaults) {
        store.set(pinned, forKey: ShellPreferenceKey.miniPlayerPinned); store.set(expanded, forKey: ShellPreferenceKey.miniPlayerExpanded)
    }
}
enum ShellPreferences {
    /// The track tooltip on the status item is optional (WIN01); on by default.
    static func tooltipEnabled(_ store: UserDefaults) -> Bool { store.object(forKey: ShellPreferenceKey.statusTooltip) as? Bool ?? true }
    /// Resuming an interrupted session after a wake is the default (WIN08).
    static func resumeAfterWake(_ store: UserDefaults) -> Bool { store.object(forKey: ShellPreferenceKey.resumeAfterWake) as? Bool ?? true }
}

/// MOTION03: window and popover animation is off under Reduce Motion and Low Power Mode.
enum ShellMotion {
    static func animates(reduceMotion: Bool, lowPower: Bool) -> Bool { !reduceMotion && !lowPower }
    @MainActor static var animatesWindows: Bool { animates(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled) }
}
