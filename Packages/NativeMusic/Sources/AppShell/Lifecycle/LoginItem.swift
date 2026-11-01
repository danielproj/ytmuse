import AppKit
import Foundation
import Observation

// W21 (WIN09). Launch at login is off by default; enabling it opens the app as a menu-bar app, with no window and no audio.
//
// The real login item (`SMAppService.mainApp`) is reachable from exactly one file, in the app target (`App/Sources/NativeMusicApp.swift`),
// and is chosen only by the composition root for a normal launch. No package target and no test can name it, so no test, probe or mutation can
// register, unregister or query-and-change the account holder's real login item (guard test: `LoginItemGuardTests`). Everything here talks to
// the `LoginItemService` protocol; tests and every isolated UI launch get `InMemoryLoginItemService`.

public enum LoginItemStatus: Sendable, Equatable {
    case notRegistered, enabled
    /// The system needs the person to approve it in System Settings > General > Login Items.
    case requiresApproval
    /// The service could not say (for example an unsigned development build).
    case unavailable
}
public protocol LoginItemService: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    /// True only for the in-process fake. A Debug readout shows it, so a UI run can refuse to touch the toggle unless the fake is what answers it.
    var isInProcessFake: Bool { get }
}
/// The login item as plain state: nothing leaves the process. Used by every test and every isolated launch.
public final class InMemoryLoginItemService: LoginItemService, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginItemStatus
    private var registrations = 0, unregistrations = 0
    public init(status: LoginItemStatus = .notRegistered) { current = status }
    public var isInProcessFake: Bool { true }
    public var status: LoginItemStatus { lock.withLock { current } }
    public func register() throws { lock.withLock { current = .enabled; registrations += 1 } }
    public func unregister() throws { lock.withLock { current = .notRegistered; unregistrations += 1 } }
    public var registerCount: Int { lock.withLock { registrations } }
    public var unregisterCount: Int { lock.withLock { unregistrations } }
}

/// Which login item a process gets: an isolated launch (every automated one) NEVER gets the system's, whatever the composition root offers.
/// The system service is passed as a closure so that it is not even constructed under isolation.
public enum LoginItemSelection {
    public static func choose(system: () -> any LoginItemService) -> any LoginItemService {
        LaunchStorageDecision.isIsolated ? InMemoryLoginItemService() : system()
    }
}

/// The Settings toggle's state. Registering happens only from `setEnabled`, which only the toggle calls; reading status is passive.
@MainActor @Observable public final class LoginItemModel {
    public private(set) var status: LoginItemStatus
    public private(set) var failure: String?
    @ObservationIgnored private let service: any LoginItemService
    public init(service: any LoginItemService) { self.service = service; status = service.status }
    public var usesInProcessFake: Bool { service.isInProcessFake }
    public var isOn: Bool { status == .enabled || status == .requiresApproval }
    public func refresh() { status = service.status }
    public func setEnabled(_ on: Bool) {
        failure = nil
        do { if on { try service.register() } else { try service.unregister() } }
        catch { failure = on ? String(localized: "Launch at login could not be turned on. Try again, or turn it on in System Settings > General > Login Items.")
                             : String(localized: "Launch at login could not be turned off. Try again, or turn it off in System Settings > General > Login Items.") }
        status = service.status
    }
}

/// How this process was started. A login launch opens menu-bar only: no window, no audio (and no audio ever starts at any launch).
public enum LaunchKind: Sendable, Equatable {
    case manual, login
    /// The Apple event that launched the process carries `keyAELaunchedAsLogInItem` as its property data for a login item.
    /// `propertyData` is that four-character code, or nil when the launch event carried none.
    public static func from(propertyData: UInt32?) -> LaunchKind { propertyData == AEKeyword(keyAELaunchedAsLogInItem) ? .login : .manual }
    /// A Debug-only seam for the isolated UI runs: the process is started "as a login launch" without touching any login item.
    public static func from(environment: [String: String]) -> LaunchKind? {
        #if DEBUG
        guard environment["YTMUSE_UI_TEST_ISOLATED"] != nil, environment["YTMUSE_SIMULATE_LOGIN_LAUNCH"] == "1" else { return nil }
        return .login
        #else
        return nil
        #endif
    }
}
/// Decided once per process, as early as the launch event is available; read by the first window.
@MainActor public enum LaunchContext {
    public private(set) static var kind: LaunchKind = LaunchKind.from(environment: ProcessInfo.processInfo.environment) ?? .manual
    private static var decided = LaunchKind.from(environment: ProcessInfo.processInfo.environment) != nil
    /// A login launch suppresses the very first regular window only (every later one is the person's doing).
    public private(set) static var suppressFirstWindow = LaunchKind.from(environment: ProcessInfo.processInfo.environment) == .login
    /// Reads the launch event (the delegate's `applicationWillFinishLaunching` and `applicationDidFinishLaunching`, and the first window as it
    /// attaches, each try; the first one that can see the event decides). A launch with an event but no login property data is a manual launch.
    public static func establish(from event: NSAppleEventDescriptor?) {
        guard !decided else { return }
        guard let event else { return }   // not visible yet: a later call decides
        kind = LaunchKind.from(propertyData: event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue)
        suppressFirstWindow = kind == .login
        decided = true
    }
    public static func establishFromCurrentEvent() { establish(from: NSAppleEventManager.shared().currentAppleEvent) }
    /// Consumed by the first window the app creates; false for every later one.
    public static func consumeFirstWindowSuppression() -> Bool {
        establishFromCurrentEvent()
        defer { suppressFirstWindow = false }
        return suppressFirstWindow
    }
    static func reset(kind newKind: LaunchKind = .manual) { kind = newKind; suppressFirstWindow = newKind == .login; decided = true }
}
