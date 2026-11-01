import AppIntents
import Foundation

// W25 (MAC06, ARCH03, ARCH09, T25.2). The widget's command channel.
//
// A widget button is an App Intent that adopts `AudioPlaybackIntent`: the SYSTEM runs such an intent in the APP's process (it is how an audio app keeps playing
// from a widget or Control Center), not in the extension. So the button's action meets the one playback owner, the one network session and the same gates the
// window's own buttons meet; the extension holds no player. If the system ever did run it inside the extension, `WidgetCommandReceiver.shared` has no handler
// there and the intent says so and does nothing: there is no independent session to fall back to.
//
// Nothing is queued. A button carries the (account, generation, launch nonce) of the snapshot it was drawn from; the app refuses it unless that is still the live scope.

public enum WidgetCommandKind: String, Codable, Sendable, CaseIterable, AppEnum {
    case playPause, next, previous
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Widget button"
    public static let caseDisplayRepresentations: [WidgetCommandKind: DisplayRepresentation] = [.playPause: "Play or Pause", .next: "Next Song", .previous: "Previous Song"]
}

/// The scope a button was drawn under.
public struct WidgetCommandStamp: Codable, Equatable, Hashable, Sendable {
    public let accountToken: String
    public let generation: UInt64
    public let launch: String
    public init(accountToken: String, generation: UInt64, launch: String) { self.accountToken = accountToken; self.generation = generation; self.launch = launch }
    public init(_ scope: WidgetScope) { self.init(accountToken: scope.accountToken, generation: scope.generation, launch: scope.launch) }
}

/// Why a widget button did nothing. None of these names an account.
public enum WidgetCommandRefusal: Error, Equatable, Sendable, LocalizedError, CustomLocalizedStringResourceConvertible {
    /// There is no handler: the intent ran outside the app (the extension has no player and does not start one).
    case appUnavailable
    /// Nobody is signed in to YouTube Music in the app.
    case signedOut
    /// The widget was drawn for a different account than the one the app is in.
    case otherAccount
    /// The widget was drawn in an earlier session of this account: before a sign-in, or in an earlier LAUNCH of the app (the stamp carries a per-launch nonce).
    case earlierSession
    /// The app refused the action itself (nothing to act on, an advertisement, Play here pending...). The text is the app's own reason.
    case refused(String)
    public var errorDescription: String? { message }
    public var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
    public var message: String {
        switch self {
        case .appUnavailable: String(localized: "Open YTMuse to use this button.")
        case .signedOut: String(localized: "Sign in to YouTube Music in YTMuse first.")
        case .otherAccount, .earlierSession: String(localized: "This widget is out of date. Open YTMuse and it will refresh.")
        case .refused(let reason): reason
        }
    }
}

public enum WidgetCommandGate {
    public enum Verdict: Equatable, Sendable { case admit, refuse(WidgetCommandRefusal) }
    /// The whole stale-command rule (T25.2): the live scope must exist, be the same account, and be the same session.
    public static func verdict(for stamp: WidgetCommandStamp, live: WidgetScope?) -> Verdict {
        guard let live else { return .refuse(.signedOut) }
        guard live.accountToken == stamp.accountToken else { return .refuse(.otherAccount) }
        guard live.launch == stamp.launch, live.generation == stamp.generation else { return .refuse(.earlierSession) }
        return .admit
    }
}

/// Where a widget button's intent meets the running app. The app installs its handler once; an extension process never does.
@MainActor public final class WidgetCommandReceiver {
    public static let shared = WidgetCommandReceiver()
    public typealias Handler = @MainActor (WidgetCommandKind, WidgetCommandStamp) async -> Result<String, WidgetCommandRefusal>
    @TaskLocal public static var current: WidgetCommandReceiver?
    public static var active: WidgetCommandReceiver { current ?? shared }
    public private(set) var handler: Handler?
    public init() {}
    public func install(_ handler: @escaping Handler) { self.handler = handler }
    public func uninstall() { handler = nil }
    public var isInstalled: Bool { handler != nil }
    public func receive(_ command: WidgetCommandKind, stamp: WidgetCommandStamp) async throws -> String {
        guard let handler else { throw WidgetCommandRefusal.appUnavailable }
        switch await handler(command, stamp) {
        case .success(let sentence): return sentence
        case .failure(let refusal): throw refusal
        }
    }
}

public struct WidgetTransportIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Widget Transport"
    public static let description = IntentDescription("A button on the YTMuse widget. It acts only if the widget still belongs to the account and session the app is in.")
    /// Not offered in Shortcuts or Siri: it exists for the widget's buttons.
    public static let isDiscoverable = false
    @Parameter(title: "Button") public var command: WidgetCommandKind
    @Parameter(title: "Account") public var accountToken: String
    @Parameter(title: "Session", default: 0) public var generation: Int
    @Parameter(title: "Launch") public var launch: String
    public init() {}
    public init(command: WidgetCommandKind, scope: WidgetScope) {
        self.command = command; self.accountToken = scope.accountToken; self.generation = Int(clamping: scope.generation); self.launch = scope.launch
    }
    @MainActor public func perform() async throws -> some IntentResult {
        guard generation >= 0 else { throw WidgetCommandRefusal.earlierSession }
        _ = try await WidgetCommandReceiver.active.receive(command, stamp: WidgetCommandStamp(accountToken: accountToken, generation: UInt64(generation), launch: launch))
        return .result()
    }
}

/// Lets the app's and the extension's own `AppIntentsPackage` pull this module's intent and enum into their metadata.
public struct WidgetSharedIntentsPackage: AppIntentsPackage {}
