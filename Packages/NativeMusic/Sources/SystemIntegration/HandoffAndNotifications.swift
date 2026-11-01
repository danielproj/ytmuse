import Foundation

// W26 (MAC12, MAC08). Handoff and notifications: the two system features that publish something about the playing item.

// MARK: Handoff

/// What the app advertises for Handoff: the public canonical link of the item page being viewed, and the navigation context (kind and identifier),
/// nothing else. No title, account, cookie, token, signed URL or local path, and nothing for a screen that may hold private content (a playlist,
/// the Library, History, Downloads, Uploads, the queue).
///
/// Limits of the receiving side, stated because nothing here can change them:
/// - Handoff only reaches another device signed in to the same Apple Account, nearby, with Bluetooth and Wi-Fi on.
/// - The activity carries a web address, so a Mac or iPhone without YTMuse opens it in its default browser.
/// - There is no iPhone companion, and nothing here is a Spotify Connect-like server.
/// - Handing a CUSTOM activity to another YTMuse needs the two builds signed by the same team; a development build does not meet that, and the browser fallback is what the person gets.
public struct HandoffActivity: Equatable, Sendable {
    public static let activityType = "local.native-music.browse"
    public let item: LinkItem
    public var webpageURL: URL { CanonicalLink.url(for: item) }
    public var userInfo: [String: String] { ["kind": item.kind.rawValue, "identifier": item.identifier] }
    /// The kinds that are public catalog pages. A playlist can be private, so it is never advertised.
    public static let advertisedKinds: Set<LinkItemKind> = [.song, .album, .artist, .podcast, .episode]
    public init?(item: LinkItem?) {
        guard let item, Self.advertisedKinds.contains(item.kind) else { return nil }
        self.item = item
    }
    public func makeUserActivity() -> NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        configure(activity)
        return activity
    }
    /// Fills an activity (one SwiftUI made, or `makeUserActivity`'s) with exactly the public link and the navigation context.
    public func configure(_ activity: NSUserActivity) {
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.webpageURL = webpageURL
        activity.userInfo = userInfo
        activity.requiredUserInfoKeys = ["kind", "identifier"]
    }
    /// An activity that arrived from another device. Only the public link is read back, through the same strict policy as every other link; the
    /// user-info is never trusted, and anything but an item page the app advertises is refused.
    public static func destination(of activity: NSUserActivity) -> LinkDestination? {
        guard activity.activityType == activityType || activity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = activity.webpageURL, case .success(.item(let item)) = LinkPolicy.parse(url), advertisedKinds.contains(item.kind) else { return nil }
        return .item(item)
    }
}

// MARK: Notifications

public enum NotificationAuthorization: Sendable, Equatable { case notDetermined, denied, authorized }
public struct SongNotification: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    /// Replaces the previous one, so a run of skips leaves one notification and not a stack.
    public static let identifier = "local.native-music.song-changed"
    /// The notification for a song change: the title and artist the person already sees. Nothing for an advertisement, an untitled item or a
    /// restored paused item (nothing changed), and nothing that carries a link, a path or an account.
    public static func make(title: String?, artist: String?, isAdvertisement: Bool) -> SongNotification? {
        guard !isAdvertisement, let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SongNotification(title: String(title.prefix(200)), subtitle: artist.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) })
    }
}
/// W27 (Download/error notifications, system opt-in). A short message about a download or an error. Always shown in the app first; this is the opt-in system copy.
/// It carries a fixed headline and at most the item's title the person already sees: no link, path, account, cookie or error text.
public struct StatusNotification: Equatable, Sendable {
    public enum Kind: String, Sendable { case downloadFinished, downloadFailed, signInNeeded }
    public let kind: Kind
    public let title: String
    public let body: String?
    public var identifier: String { "local.native-music.status." + kind.rawValue }
    /// TH2: there is no `reason` argument any more. It was never passed, and it was a way for error text (a link, a path, a cookie) to reach a system notification.
    public static func make(_ kind: Kind, item: String? = nil) -> StatusNotification {
        let name = item?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).description
        switch kind {
        case .downloadFinished: return StatusNotification(kind: kind, title: String(localized: "Download finished"), body: name.flatMap { $0.isEmpty ? nil : $0 })
        case .downloadFailed: return StatusNotification(kind: kind, title: String(localized: "A download could not finish"), body: name.flatMap { $0.isEmpty ? nil : $0 })
        case .signInNeeded: return StatusNotification(kind: kind, title: String(localized: "Sign in to YouTube Music again"), body: String(localized: "Your session has ended. Your local data is kept."))
        }
    }
}

/// The system's notification center, as far as the app uses it. The real conformer is in the app target and is the ONLY code that names the
/// system's notification center; every test target and every isolated launch gets the recording one, so a run can never show the account holder
/// a permission prompt.
@MainActor public protocol NotificationServing: AnyObject {
    func authorization() async -> NotificationAuthorization
    /// Asks the system (the real conformer shows its permission prompt). Called only when the person turns a notification feature on.
    func requestAuthorization() async -> NotificationAuthorization
    func post(_ notification: SongNotification) async
    /// W27: the opt-in download and error messages.
    func post(_ notification: StatusNotification) async
    var isInProcessFake: Bool { get }
}
@MainActor public final class RecordingNotifications: NotificationServing {
    public private(set) var requestCount = 0
    public private(set) var posted: [SongNotification] = []
    public private(set) var postedStatus: [StatusNotification] = []
    public var current: NotificationAuthorization
    /// What a request answers when the state is `notDetermined`.
    public var answer: NotificationAuthorization
    public init(current: NotificationAuthorization = .notDetermined, answer: NotificationAuthorization = .authorized) { self.current = current; self.answer = answer }
    public var isInProcessFake: Bool { true }
    public func authorization() async -> NotificationAuthorization { current }
    public func requestAuthorization() async -> NotificationAuthorization {
        requestCount += 1
        if current == .notDetermined { current = answer }
        return current
    }
    public func post(_ notification: SongNotification) async { if current == .authorized { posted.append(notification) } }
    public func post(_ notification: StatusNotification) async { if current == .authorized { postedStatus.append(notification) } }
}
