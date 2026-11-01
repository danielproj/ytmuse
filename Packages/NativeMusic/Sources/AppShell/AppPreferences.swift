import Domain
import Foundation
import AppKit
import SwiftUI

/// The one preferences store the app and its packages use (appearance, sign-in
/// options, player host knob). Release: `UserDefaults.standard`. Debug with the QA
/// isolation flag: a throwaway plist in the temporary folder, so UI automation can
/// never read or change the account holder's `local.native-music.development` domain.
/// An absolute-path suite is a plain plist: it neither reads nor writes the app's
/// standard domain.
enum AppPreferences {
    struct Resolved: @unchecked Sendable {
        let store: UserDefaults
        /// Throwaway plist path (isolated mode only).
        let isolatedPath: String?
        /// True when the app created the plist itself and removes it at quit. A path
        /// named by a UI test is kept so a choice can survive that test's relaunch;
        /// the UI command sequence removes it from the temporary folder afterwards.
        let ownedByApp: Bool
    }
    static let resolved: Resolved = resolve(environment: ProcessInfo.processInfo.environment)
    static var store: UserDefaults { resolved.store }
    /// W27 rework 1: the same store behind its guard. Settings writes and removals, the settings reset and the preferences erase go through this: it is bound to THIS
    /// session's store and refuses every write and removal on the account holder's real preferences domain while the process is isolated.
    static var guarded: GuardedDefaults { guarded(for: resolved) }
    static func guarded(for resolved: Resolved) -> GuardedDefaults {
        GuardedDefaults(store: resolved.store, domain: resolved.isolatedPath ?? (Bundle.main.bundleIdentifier ?? "local.native-music.development"))
    }

    #if DEBUG
    /// A UUID token, not a path: the (sandboxed) UI runner cannot name a file in the
    /// app's temporary folder, and the app never accepts a caller-chosen location.
    static let defaultsTokenKey = "YTMUSE_UI_TEST_DEFAULTS_ID"
    static let filePrefix = "ytmuse-ui-test-defaults-"
    static func resolve(environment: [String: String], temporary: URL = FileManager.default.temporaryDirectory) -> Resolved {
        guard IsolatedQAStorage.requested(environment) else { return Resolved(store: .standard, isolatedPath: nil, ownedByApp: false) }
        let folder = temporary.resolvingSymlinksInPath().standardizedFileURL
        if let token = environment[defaultsTokenKey].flatMap(UUID.init(uuidString:)) {
            let path = folder.appendingPathComponent(filePrefix + "named-" + token.uuidString + ".plist").path
            return Resolved(store: UserDefaults(suiteName: path)!, isolatedPath: path, ownedByApp: false)
        }
        // Never fall back to the standard domain once isolation was requested.
        let path = folder.appendingPathComponent(filePrefix + UUID().uuidString + ".plist").path
        return Resolved(store: UserDefaults(suiteName: path)!, isolatedPath: path, ownedByApp: true)
    }
    /// Quit-path cleanup for an app-created throwaway plist.
    static func removeOwnedIsolatedFile() {
        guard resolved.ownedByApp, let path = resolved.isolatedPath else { return }
        let url = URL(fileURLWithPath: path)
        try? GuardedFiles(root: url.deletingLastPathComponent()).remove(url)
    }
    #else
    static func resolve(environment: [String: String]) -> Resolved { Resolved(store: .standard, isolatedPath: nil, ownedByApp: false) }
    #endif
}

extension View {
    /// Routes `@AppStorage` in this hierarchy to the app's preferences store and, in
    /// isolated QA mode, stops AppKit persisting window state for this window.
    func appPreferences() -> some View {
        #if DEBUG
        self.defaultAppStorage(AppPreferences.store)
            .background { if AppPreferences.resolved.isolatedPath != nil { IsolatedWindowState() } }
        #else
        self.defaultAppStorage(AppPreferences.store)
        #endif
    }
}

#if DEBUG
/// Isolated QA windows are not restorable (so `@SceneStorage` and window
/// restoration never write the account holder's saved application state) and do
/// not autosave frames, split-view dividers or toolbar configuration into the
/// standard defaults domain. Zero-size, no hit testing, no accessibility element.
struct IsolatedWindowState: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.neutralise() }
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); neutralise()
            // Split views and toolbars are installed after the first attach.
            DispatchQueue.main.async { [weak self] in self?.neutralise() }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func neutralise() {
            guard let window else { return }
            window.isRestorable = false
            window.setFrameAutosaveName("")
            window.toolbar?.autosavesConfiguration = false
            func clear(_ view: NSView) {
                if let split = view as? NSSplitView { split.autosaveName = nil }
                view.subviews.forEach(clear)
            }
            if let root = window.contentView?.superview ?? window.contentView { clear(root) }
        }
    }
}
#endif

#if DEBUG
import ObjectiveC

/// Isolated QA only, installed before any scene creates a window: AppKit's frame
/// and split-view autosave and window restorability are disabled at the class
/// level, so no window — main, Settings or any other scene — can write
/// `NSWindow Frame …` / `NSSplitView Subview Frames …` into the real preferences
/// domain or saved application state, even before a view is attached. Never
/// installed in a normal Debug launch; absent from Release.
@MainActor enum IsolatedWindowPersistence {
    private(set) static var installed = false
    static func installIfIsolated() {
        guard AppPreferences.resolved.isolatedPath != nil else { return }
        install()
    }
    static func install() {
        guard !installed else { return }; installed = true
        exchange(NSWindow.self, #selector(NSWindow.setFrameAutosaveName(_:)), #selector(NSWindow.ytmuseIsolatedSetFrameAutosaveName(_:)))
        exchange(NSWindow.self, #selector(NSWindow.saveFrame(usingName:)), #selector(NSWindow.ytmuseIsolatedSaveFrame(usingName:)))
        exchange(NSWindow.self, #selector(setter: NSWindow.isRestorable), #selector(NSWindow.ytmuseIsolatedSetRestorable(_:)))
        exchange(NSSplitView.self, #selector(setter: NSSplitView.autosaveName), #selector(NSSplitView.ytmuseIsolatedSetAutosaveName(_:)))
    }
    private static func exchange(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(type, original), let b = class_getInstanceMethod(type, replacement) else {
            preconditionFailure("Isolated window persistence could not be installed")
        }
        method_exchangeImplementations(a, b)
    }
}
extension NSWindow {
    /// Accepts and ignores the name: no frame is ever saved under it.
    @objc func ytmuseIsolatedSetFrameAutosaveName(_ name: String) -> Bool { true }
    @objc func ytmuseIsolatedSaveFrame(usingName name: String) {}
    /// Exchanged: calling the replacement selector invokes AppKit's original setter.
    @objc func ytmuseIsolatedSetRestorable(_ value: Bool) { ytmuseIsolatedSetRestorable(false) }
}
extension NSSplitView {
    @objc func ytmuseIsolatedSetAutosaveName(_ name: String?) { ytmuseIsolatedSetAutosaveName(nil) }
}
#endif
