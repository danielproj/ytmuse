import AppKit
import Foundation
import Observation
import SwiftUI

// W21 (WIN02, WIN04). Which windows keep the Dock icon, and the activation policy that follows from them.
//
// Only a window that registers itself with a role counts. The hidden player's host window, the mini-player, the status popover, sheets, panels
// and alerts never register as regular, so none of them is ever "the last regular window". The hidden player's host window is also kept out of
// the Windows menu, Command-` cycling and Mission Control (`WebKitMusicPage.applyHostWindowRules`).

public enum ShellWindowRole: String, Sendable, Equatable, CaseIterable {
    /// A browser window (the default window and every Command-N window).
    case browser
    /// The full-screen Now Playing window.
    case nowPlaying
    /// The Settings window.
    case settings
    /// The separate mini-player (a utility panel; never a document window).
    case miniPlayer
    /// Everything else: the hidden player, the status popover, sheets, panels, alerts.
    case auxiliary
    /// Whether a visible (or minimized) window of this role keeps the Dock icon and the application menu.
    public var keepsDockPresence: Bool { self == .browser || self == .nowPlaying || self == .settings }
}
public enum DockPresence: Sendable, Equatable { case regular, accessory }

@MainActor public protocol ApplicationActivating: AnyObject {
    var presence: DockPresence { get }
    var isHidden: Bool { get }
    func setPresence(_ presence: DockPresence)
    func activate()
}
@MainActor final class SystemApplication: ApplicationActivating {
    var presence: DockPresence { NSApplication.shared.activationPolicy() == .regular ? .regular : .accessory }
    var isHidden: Bool { NSApplication.shared.isHidden }
    func setPresence(_ presence: DockPresence) { NSApplication.shared.setActivationPolicy(presence == .regular ? .regular : .accessory) }
    func activate() { NSApplication.shared.activate() }
}

/// The census of regular windows and the policy it drives. Closing the last one leaves the menu bar item and the audio, and hides the Dock icon;
/// any window that opens again restores the regular policy at once.
@MainActor public final class ShellWindowRegistry {
    private struct Entry { weak var window: NSWindow?; var role: ShellWindowRole; var closing = false; var observation: NSKeyValueObservation? }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var tokens: [NSObjectProtocol] = []
    private let application: any ApplicationActivating
    private let settle: Duration
    private let schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void
    private var pendingDemotion = 0
    /// The policy only ever drops after a regular window has been on screen: a window that is still opening (or one a login launch keeps hidden)
    /// is not "the last window closed".
    private var sawVisibleWindow = false
    /// How often the policy actually changed, for the tests and the diagnostics line.
    public private(set) var policyChanges = 0
    public init(application: any ApplicationActivating, settle: Duration = .milliseconds(350),
                schedule: @escaping @MainActor (Duration, @escaping @MainActor () -> Void) -> Void = { delay, work in
                    Task { @MainActor in try? await Task.sleep(for: delay); work() }
                }) {
        self.application = application; self.settle = settle; self.schedule = schedule
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                let closing = note.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated { self?.noteWindow(window, closing: closing) }
            })
        }
        // The application menu and Dock presence follow the app being shown again after Hide.
        tokens.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
    }
    isolated deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }

    public func register(_ window: NSWindow, role: ShellWindowRole) {
        let id = ObjectIdentifier(window)
        if var existing = entries[id] { existing.role = role; existing.closing = false; entries[id] = existing; reconcile(); return }
        var entry = Entry(window: window, role: role)
        entry.observation = window.observe(\.isVisible, options: []) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reconcile() } }
        }
        entries[id] = entry
        reconcile()
    }
    private func noteWindow(_ window: NSWindow?, closing: Bool) {
        guard let window, var entry = entries[ObjectIdentifier(window)] else { return }
        if closing { entry.closing = true; entries[ObjectIdentifier(window)] = entry }
        reconcile()
    }
    private func prune() { entries = entries.filter { $0.value.window != nil && !$0.value.closing } }
    /// Regular windows that are on screen or minimized to the Dock (a minimized window still needs the Dock icon to be restored from).
    public var regularWindowCount: Int {
        entries.values.filter { entry in
            guard !entry.closing, entry.role.keepsDockPresence, let window = entry.window else { return false }
            return window.isVisible || window.isMiniaturized
        }.count
    }
    /// A registered, still-open window of any role (the mini-player counts as itself, never as a regular one).
    public func windows(role: ShellWindowRole) -> [NSWindow] { entries.values.compactMap { $0.closing || $0.role != role ? nil : $0.window } }
    /// The role a window registered with, nil for a window the shell does not know (an alert, a panel, a sheet).
    public func role(of window: NSWindow) -> ShellWindowRole? {
        guard let entry = entries[ObjectIdentifier(window)], !entry.closing, entry.window === window else { return nil }
        return entry.role
    }
    public var registeredCount: Int { entries.values.filter { !$0.closing && $0.window != nil }.count }
    #if DEBUG
    /// "policy=regular saw=true browser:visible settings:closing ..." for a UI run's diagnostics (Debug only).
    var debugCensus: String {
        let rows = entries.values.map { "\($0.role.rawValue):" + ($0.closing ? "closing" : ($0.window?.isVisible == true ? "visible" : ($0.window?.isMiniaturized == true ? "minimized" : "hidden"))) }.sorted()
        return "policy=\(application.presence) saw=\(sawVisibleWindow) regular=\(regularWindowCount) " + rows.joined(separator: " ")
    }
    #endif
    func reconcile() {
        prune()
        // An application that is hidden (Command-H) has no visible windows without having closed any.
        guard !application.isHidden else { return }
        if regularWindowCount > 0 { sawVisibleWindow = true; promote() } else if sawVisibleWindow { demoteSoon() }
    }
    private func promote() {
        pendingDemotion += 1   // cancels any scheduled demotion
        guard application.presence != .regular else { return }
        application.setPresence(.regular); policyChanges += 1
    }
    private func demoteSoon() {
        pendingDemotion += 1; let ticket = pendingDemotion
        guard application.presence != .accessory else { return }
        // A window going full screen or changing Spaces can read as not visible for an instant; the policy only drops once the count stays zero.
        schedule(settle) { [weak self] in
            guard let self, self.pendingDemotion == ticket, !self.application.isHidden else { return }
            self.prune()
            guard self.regularWindowCount == 0, self.application.presence != .accessory else { return }
            self.application.setPresence(.accessory); self.policyChanges += 1
        }
    }
    /// Reopening from the status item, the Dock or a launch: the regular policy first, then the app comes forward.
    public func restoreRegularPresence() {
        application.setPresence(.regular); pendingDemotion += 1
        application.activate()
    }
}

/// A reference to the window a SwiftUI view lives in (never observed: reading it is not a state change).
@MainActor final class WindowBox { weak var window: NSWindow? }

/// Reports the window its view is attached to, once per attach, with no hit testing and no accessibility element.
struct HostWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Probe { Probe(found: found) }
    func updateNSView(_ view: Probe, context: Context) { view.found = found }
    final class Probe: NSView {
        var found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) { self.found = found; super.init(frame: .zero); setAccessibilityElement(false) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); found(window) }
    }
}

/// Tells the shell which role a window plays, so the census, the activation policy and a login launch can treat it correctly.
struct ShellWindowTag: ViewModifier {
    let shell: ShellCoordinator
    let role: ShellWindowRole
    func body(content: Content) -> some View {
        content.background(HostWindowReader { window in
            guard let window else { return }
            shell.windows.register(window, role: role)
            // A login launch opens menu-bar only: the first browser window is created (the scene needs it) but not shown. It is kept, so
            // Show YTMuse brings this very window; it is never shown by the launch itself.
            if role == .browser, LaunchContext.consumeFirstWindowSuppression() {
                window.alphaValue = 0
                DispatchQueue.main.async { window.orderOut(nil) }
            }
        })
    }
}
extension View {
    func shellWindow(_ shell: ShellCoordinator, role: ShellWindowRole) -> some View { modifier(ShellWindowTag(shell: shell, role: role)) }
}
