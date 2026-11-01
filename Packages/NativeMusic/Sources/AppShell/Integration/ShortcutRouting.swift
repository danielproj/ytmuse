import AppKit
import SwiftUI
import SystemIntegration
import WebKit

// W26 (MAC10, section 13). The AppKit side of the keyboard: what has focus, the one local key router, and the menu that is built from the table.
//
// The router is a LOCAL event monitor: it sees only this application's own key events, after the system has delivered them to the app. It is not
// an event tap and not a global monitor (`scripts/check-system-media.py` fails on both and still passes this). It handles exactly the chords the
// table marks as guarded: Space, Command-Right/Left and Command-Shift-Right/Left. Those are the ones a text field or a control also uses, so a
// menu key equivalent alone would take them from the field. Every other chord is an ordinary menu key equivalent.

enum ShortcutFocusClassifier {
    /// What keyboard focus is, for the focus guard. Pure over the responder; creating the responders offscreen is how the tests exercise it.
    @MainActor static func classify(_ responder: NSResponder?) -> ShortcutFocus {
        guard let responder else { return .none }
        if let view = responder as? NSView, Self.isInsideWebView(view) { return .webContent }
        if let text = responder as? NSTextView { return text.isFieldEditor || text.isEditable ? .textEditing : .none }
        if let client = responder as? any NSTextInputClient, client.hasMarkedText() { return .textEditing }
        if let field = responder as? NSTextField { return field.isEditable ? .textEditing : .none }
        // Lists and tables are controls to AppKit but not to a person: Space and Command-Arrow do nothing in them that playback should give way to.
        if responder is NSTableView || responder is NSScrollView || responder is NSCollectionView || responder is NSBrowser { return .none }
        if responder is NSControl { return .control }
        // SwiftUI's own controls: their role says what they are.
        if let element = responder as? any NSAccessibilityProtocol {
            switch element.accessibilityRole() {
            case .some(.textField), .some(.textArea), .some(.comboBox): return .textEditing
            case .some(.button), .some(.popUpButton), .some(.menuButton), .some(.checkBox), .some(.radioButton), .some(.slider), .some(.incrementor), .some(.disclosureTriangle), .some(.colorWell): return .control
            default: break
            }
        }
        return .none
    }
    @MainActor private static func isInsideWebView(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current { if candidate is WKWebView { return true }; current = candidate.superview }
        return false
    }
}

/// Runs a table action. The shell conforms; tests record.
@MainActor protocol ShortcutPerforming: AnyObject {
    func perform(_ action: ShortcutAction)
}

/// `NSEvent` is not `Sendable`; the event is created, handled and returned on the main thread, so carrying it through `assumeIsolated` is safe.
private struct RoutedEvent: @unchecked Sendable { let event: NSEvent? }

@MainActor final class ShortcutKeyRouter {
    private let performer: any ShortcutPerforming
    private let role: (NSWindow) -> ShellWindowRole?
    private var monitor: Any?
    /// How many events the router swallowed or ran (the tests and the Debug readout).
    private(set) var handled = 0
    init(performer: any ShortcutPerforming, role: @escaping (NSWindow) -> ShellWindowRole?) { self.performer = performer; self.role = role }
    isolated deinit { remove() }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: Self.monitorHandler(for: self))
    }
    /// The closure AppKit calls for every key-down, exactly as `install()` registers it (a test calls this very closure). It holds the router weakly.
    static func monitorHandler(for router: ShortcutKeyRouter) -> (NSEvent) -> NSEvent? {
        { [weak router] event in
            // The handler runs on the main thread (AppKit delivers key events there); the closure is not annotated, so assert it.
            MainActor.assumeIsolated { RoutedEvent(event: Self.monitorResult(of: router, for: event)) }.event
        }
    }
    /// Which window an event belongs to; a test points it at an offscreen window.
    var windowProvider: (NSEvent) -> NSWindow? = { $0.window ?? NSApp.keyWindow }
    /// What the monitor hands back to AppKit: nil when the router ran the event or gave it to the focused control (the event is consumed, so the menu's
    /// key equivalent for the same chord cannot fire a second time), the event itself when it is none of the router's business or the router is gone.
    /// (A first version coalesced the router's nil back into the event, which turned "consumed" into "pass on": Space and Command-Right ran twice. T26 pins the closure.)
    static func monitorResult(of router: ShortcutKeyRouter?, for event: NSEvent, in window: NSWindow? = nil) -> NSEvent? {
        guard let router else { return event }
        return router.handle(event, in: window)
    }
    func remove() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }

    static func chord(for event: NSEvent) -> KeyChord? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        // Space, arrows, function keys, digits and marks are named by key code: `charactersIgnoringModifiers` keeps Shift (Shift-Command-3 arrives as "#"),
        // which would hide a shifted chord from the conflict check and from the registrar. Letters are read from the layout in use.
        if let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1, let scalar = characters.unicodeScalars.first,
           scalar.isASCII, ("a"..."z").contains(characters) { return KeyChord(ShortcutKey(characters), modifiers) }
        if let key = HotKeyCodes.key(forCode: UInt32(event.keyCode)) { return KeyChord(key, modifiers) }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else { return nil }
        return KeyChord(ShortcutKey(characters), modifiers)
    }
    /// Seeking repeats while the keys are held; the toggles do not (holding Space must not flicker playback).
    private static func repeats(_ action: ShortcutAction) -> Bool { action == .seekForward || action == .seekBack }

    /// The router's decision for one event: the event to keep delivering, or nil when it was run or handed to the focused control.
    func handle(_ event: NSEvent, in explicit: NSWindow? = nil) -> NSEvent? {
        guard event.type == .keyDown, let chord = Self.chord(for: event), ShortcutTable.entry(for: chord)?.isRouted == true else { return event }
        let window = explicit ?? windowProvider(event)
        let eligible = window.map { candidate in
            guard candidate.sheetParent == nil, let role = role(candidate) else { return false }
            return role == .browser || role == .miniPlayer || role == .nowPlaying
        } ?? false
        let focus = ShortcutFocusClassifier.classify(window?.firstResponder)
        switch ShortcutRouter.route(chord, focus: focus, windowAllowsShortcuts: eligible) {
        case .passThrough: return event
        case .perform(let action):
            handled += 1
            if event.isARepeat, !Self.repeats(action) { return nil }
            performer.perform(action)
            return nil
        case .deliverToFocus:
            // The focused control uses the key itself: hand it the event, and keep the menu's key equivalent for the same chord from firing.
            guard let responder = window?.firstResponder, !(responder is NSWindow) else { return event }
            handled += 1
            responder.keyDown(with: event)
            return nil
        }
    }
}

// MARK: The menus, built from the table

/// One menu item of the table's shortcuts, as data. `MainWindowCommands` builds its buttons from this list, and `ShortcutTableTests` checks it
/// against `ShortcutTable` so a table entry cannot be missing from the menus or carry a different chord there.
struct ShortcutMenuItem: Equatable {
    let action: ShortcutAction
    let chord: KeyChord
    let group: Group
    enum Group { case search, playback, window }
    /// Standard commands are supplied by the system's own menus (Minimize, Close, Settings…); the rest are ours.
    static var items: [ShortcutMenuItem] {
        ShortcutTable.entries.compactMap { entry in
            let group: Group
            switch entry.action {
            case .focusSearch, .commandPalette: group = .search
            case .playPause, .next, .previous, .seekForward, .seekBack, .revealCurrentItem, .showQueue: group = .playback
            case .miniPlayer: group = .window
            case .minimize, .settings, .closeWindow, .quit: return nil
            }
            return ShortcutMenuItem(action: entry.action, chord: entry.chord, group: group)
        }
    }
}
extension KeyChord {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case .space: .space
        case .left: .leftArrow
        case .right: .rightArrow
        case .up: .upArrow
        case .down: .downArrow
        case .return: .return
        case .escape: .escape
        case .tab: .tab
        case .delete: .delete
        default: KeyEquivalent(key.name.first ?? " ")
        }
    }
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}
