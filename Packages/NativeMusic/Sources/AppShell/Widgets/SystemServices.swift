import Foundation

// W25 (MAC06). The widget timeline reload, abstractly. Production: `WidgetCenter` in the app target (`App/Sources/SystemWidgetSupport.swift`). Everything else
// (every isolated launch, every test): `RecordingTimelineReloader`. The app's offers are the fields of `SystemServices` (ShellIntegration.swift).

/// Asks the system to reload the widget's timeline.
@MainActor public protocol WidgetTimelineReloading: AnyObject, Sendable {
    func reloadNowPlaying()
}
@MainActor public final class RecordingTimelineReloader: WidgetTimelineReloading {
    public private(set) var reloads = 0
    public init() {}
    public func reloadNowPlaying() { reloads += 1 }
}
