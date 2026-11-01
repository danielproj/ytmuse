import AppIntents
import SwiftUI
import WidgetKit
import WidgetShared

// W25 (MAC06, ARCH09). The widget extension's entry point.
//
// It reads ONE file from the App Group (the redacted snapshot the app writes) and draws it. It has no player, no network client, no Keychain access group, no
// store of the app's and no timer: the timeline policy is `.never` and the app asks for a reload (WidgetCenter) when something the widget shows changed. Its
// buttons are App Intents that the system runs in the APP's process (`AudioPlaybackIntent`), where the app's own gates decide. The sandbox entitlement and the
// Team-ID-prefixed App Group are all it holds (`scripts/check-widget.py` reads them from the built bundle).

/// The only place the extension names the App Group container. Everything else is injected, which is how the tests run the same code over a temporary directory.
enum SnapshotLocation {
    /// Nil, with no lookup, unless this extension carries a Team-ID-prefixed group id in its own Info.plist (the signing step writes it): then the widget shows "Open YTMuse".
    static func directory() -> URL? {
        guard let group = WidgetIdentity.appGroup(in: Bundle.main.infoDictionary) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
}

struct NativeMusicNowPlayingWidget: Widget {
    init() {}
    var body: some WidgetConfiguration { NowPlayingWidgetConfiguration.make(directory: { SnapshotLocation.directory() }) }
}

@main struct NativeMusicWidgetBundle: WidgetBundle {
    var body: some Widget { NativeMusicNowPlayingWidget() }
}

/// Pulls the shared widget-button intent into this extension's App Intents metadata.
struct NativeMusicWidgetIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [WidgetSharedIntentsPackage.self] }
}
