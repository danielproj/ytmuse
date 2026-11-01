import Foundation

// W25 (MAC06, ARCH09). The widget extension and the app share ONE App Group and ONE small file in it. Nothing else crosses: no credential, no cookie,
// no account email, no request, no private playlist name. This module links Foundation, CryptoKit, ImageIO, SwiftUI, WidgetKit and AppIntents; it has no
// networking, WebKit, Keychain or playback code, and `WidgetSharedGuardTests` and `scripts/check-widget.py` keep it so.

public enum WidgetIdentity {
    /// The App Group's name after the Team ID prefix. The group is `<TEAMID>.local.native-music.development`: on macOS 15 and later only a group id that starts with
    /// the app's Team ID (or one a provisioning profile authorises) is reachable without a "would like to access data from other apps" prompt. The entitlement files
    /// say `$(TeamIdentifierPrefix)local.native-music.development`; the signing step fills the prefix in from the signing identity's team, and the Team ID is never
    /// written into the repository.
    public static let appGroupSuffix = "local.native-music.development"
    /// The Info.plist key (app and extension) that holds the full group id. Its value is `$(TeamIdentifierPrefix)local.native-music.development`: empty prefix in an
    /// ad-hoc or unsigned build, the team's in a signed one (`scripts/sign-bundle.sh` writes it).
    public static let appGroupInfoKey = "YTMuseAppGroup"
    /// The group id this build may use, or nil. Nil for every build without a Team ID prefix (every worktree, test and ad-hoc build): the caller then looks up
    /// no container at all, so nothing can prompt and nothing is created.
    public static func appGroup(in info: [String: Any]?) -> String? {
        guard let value = info?[appGroupInfoKey] as? String, value.range(of: "^[A-Z0-9]{10}\\." + NSRegularExpression.escapedPattern(for: appGroupSuffix) + "$", options: .regularExpression) != nil else { return nil }
        return value
    }
    /// The one widget kind (small and medium families).
    public static let widgetKind = "local.native-music.widget.now-playing"
    /// The only file the app writes into the group, besides its own short-lived temporary during an atomic replace.
    public static let snapshotFileName = "now-playing-snapshot.json"
    /// Prefix of the temporary file an atomic write stages in the same directory; a crash can leave one, and delete removes any.
    public static let temporaryPrefix = ".snapshot-staging-"
}
