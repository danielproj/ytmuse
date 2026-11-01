import AppShell
import Foundation
import WidgetKit
import WidgetShared

// W25 (MAC06, ARCH09). The ONLY file in the repository that names `WidgetCenter`, and (with the extension's entry file) the only one that names the real App
// Group container. No package target and no test can reach either, so none can reload, query or alter the account holder's installed widgets or touch their
// real `~/Library/Group Containers` folder (`WidgetGroupGuardTests` sweeps for both). `NativeMusicApp` builds these only for a normal launch: an isolated
// launch or a test process is given a temporary directory and a recording reloader by the shell, whatever is passed here.

/// Asks WidgetCenter to reload the now-playing widget's timeline. Called by the snapshot publisher, coalesced, only when the snapshot content changed.
@MainActor final class SystemWidgetReloader: WidgetTimelineReloading {
    func reloadNowPlaying() { WidgetCenter.shared.reloadTimelines(ofKind: WidgetIdentity.widgetKind) }
}

enum SystemWidgetContainer {
    /// The App Group container, or nil. Nil WITHOUT a lookup unless this build carries a Team-ID-prefixed group id in its Info.plist (only a signed build does: the
    /// signing step writes the prefix in). Every ad-hoc, unsigned and worktree build therefore never asks the system for the container: nothing is created and
    /// nothing can prompt. Never called for an isolated launch either.
    static func directory(info: [String: Any]? = Bundle.main.infoDictionary) -> URL? {
        guard let group = WidgetIdentity.appGroup(in: info) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
}
