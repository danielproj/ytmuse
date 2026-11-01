import Foundation

// W26 (MAC09, MAC10, section 13). The keyboard: the in-app shortcut table, the focus guard that keeps standard editing intact, and the global
// shortcuts, which are unassigned and opt-in.
//
// Pure data and rules. The AppKit side (classifying the first responder, the one key router, the Carbon hot-key registration in the app target)
// lives in AppShell and App; everything it decides with is here, so every table entry and every conflict rule is tested without a keyboard.

public struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1)
    public static let shift = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
    /// The symbols a menu shows, in the system's order.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}
/// A key by name: a lowercase character, or one of the named keys below.
public struct ShortcutKey: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let name: String
    public init(_ name: String) { self.name = name }
    public init(stringLiteral value: String) { name = value }
    public static let space: ShortcutKey = "space", left: ShortcutKey = "left", right: ShortcutKey = "right", up: ShortcutKey = "up", down: ShortcutKey = "down"
    public static let `return`: ShortcutKey = "return", escape: ShortcutKey = "escape", tab: ShortcutKey = "tab", delete: ShortcutKey = "delete"
    /// What a menu or a recorder shows.
    public var label: String {
        switch name {
        case "space": "Space"; case "left": "←"; case "right": "→"; case "up": "↑"; case "down": "↓"
        case "return": "↩"; case "escape": "⎋"; case "tab": "⇥"; case "delete": "⌫"
        default: name.uppercased()
        }
    }
    /// Keys that edit or move text or that confirm and cancel: with no modifier (or with only Shift) they belong to the focused control.
    public var isNavigationOrEditing: Bool { ["space", "left", "right", "up", "down", "return", "escape", "tab", "delete"].contains(name) }
}
public struct KeyChord: Hashable, Sendable, Codable {
    public let key: ShortcutKey
    public let modifiers: KeyModifiers
    public init(_ key: ShortcutKey, _ modifiers: KeyModifiers = []) { self.key = key; self.modifiers = modifiers }
    public var label: String { modifiers.symbols + key.label }
}

public enum ShortcutAction: String, Sendable, CaseIterable {
    case focusSearch, commandPalette, playPause, next, previous, seekForward, seekBack, revealCurrentItem, showQueue, minimize, miniPlayer, settings, closeWindow, quit
}
/// Where a shortcut may fire, relative to what has keyboard focus.
public enum FocusGuard: Sendable, Equatable {
    /// Always (a Command shortcut that no text control uses).
    case none
    /// Not while text is being edited: the text control keeps its own use of the chord (Command-Arrow moves to the line's end in a text field).
    case notWhileEditingText
    /// Not while text is being edited and not while a control (a button, slider, pop-up, switch) has focus: that control uses the key itself.
    case notWhileEditingTextOrControl
}
/// What has keyboard focus, as far as shortcuts care.
public enum ShortcutFocus: Sendable, Equatable {
    /// Nothing, or a list, a table, a scroll view or a plain view.
    case none
    /// A text field, a text view, a search field, an input method composing text.
    case textEditing
    /// A button, slider, pop-up, switch, stepper, checkbox or segmented control.
    case control
    /// Page content of a web view (the sign-in page): the page owns the keyboard.
    case webContent
}
extension FocusGuard {
    public func allows(_ focus: ShortcutFocus) -> Bool {
        switch self {
        case .none: true
        case .notWhileEditingText: focus != .textEditing && focus != .webContent
        case .notWhileEditingTextOrControl: focus == .none
        }
    }
}

public struct ShortcutEntry: Sendable, Equatable {
    public let action: ShortcutAction
    public let chord: KeyChord
    public let focusGuard: FocusGuard
    /// A standard macOS command (minimize, close, Settings, Quit): the system or SwiftUI supplies it and it is never remapped.
    public let isStandard: Bool
    /// The menu item's title (a localized key).
    public let title: String
    /// Whether the key router handles this chord itself (see `ShortcutRouter`). The others are plain menu key equivalents.
    public var isRouted: Bool { focusGuard != .none }
}

/// Section 13's default shortcut table, as data. The menus, the key router, the tests and the documentation all read this one list.
public enum ShortcutTable {
    public static let entries: [ShortcutEntry] = [
        ShortcutEntry(action: .focusSearch, chord: KeyChord("f", .command), focusGuard: .none, isStandard: false, title: "Find…"),
        ShortcutEntry(action: .commandPalette, chord: KeyChord("k", .command), focusGuard: .none, isStandard: false, title: "Command Palette…"),
        ShortcutEntry(action: .playPause, chord: KeyChord(.space), focusGuard: .notWhileEditingTextOrControl, isStandard: false, title: "Play/Pause"),
        ShortcutEntry(action: .next, chord: KeyChord(.right, .command), focusGuard: .notWhileEditingText, isStandard: false, title: "Next"),
        ShortcutEntry(action: .previous, chord: KeyChord(.left, .command), focusGuard: .notWhileEditingText, isStandard: false, title: "Previous"),
        ShortcutEntry(action: .seekForward, chord: KeyChord(.right, [.command, .shift]), focusGuard: .notWhileEditingText, isStandard: false, title: "Seek Forward"),
        ShortcutEntry(action: .seekBack, chord: KeyChord(.left, [.command, .shift]), focusGuard: .notWhileEditingText, isStandard: false, title: "Seek Back"),
        ShortcutEntry(action: .revealCurrentItem, chord: KeyChord("l", .command), focusGuard: .none, isStandard: false, title: "Reveal Current Item"),
        ShortcutEntry(action: .showQueue, chord: KeyChord("q", [.command, .option]), focusGuard: .none, isStandard: false, title: "Show Queue"),
        ShortcutEntry(action: .minimize, chord: KeyChord("m", .command), focusGuard: .none, isStandard: true, title: "Minimize"),
        ShortcutEntry(action: .miniPlayer, chord: KeyChord("m", [.command, .shift]), focusGuard: .none, isStandard: false, title: "Mini-player"),
        ShortcutEntry(action: .settings, chord: KeyChord(",", .command), focusGuard: .none, isStandard: true, title: "Settings…"),
        ShortcutEntry(action: .closeWindow, chord: KeyChord("w", .command), focusGuard: .none, isStandard: true, title: "Close"),
        ShortcutEntry(action: .quit, chord: KeyChord("q", .command), focusGuard: .none, isStandard: true, title: "Quit YTMuse"),
    ]
    public static func entry(for action: ShortcutAction) -> ShortcutEntry { entries.first { $0.action == action }! }
    public static func entry(for chord: KeyChord) -> ShortcutEntry? { entries.first { $0.chord == chord } }
    /// The app's other menu shortcuts (File > New Window and Open, Now Playing Full Screen, Refresh on the pages that have it, the Debug window-size seam).
    /// The menus read the first four from here; Refresh lives in the feature views, and `ShortcutDriftTests` reads every `keyboardShortcut` in the sources
    /// and requires the global-shortcut policy to refuse each, so this list cannot fall behind the menus.
    public static let otherMenu: [(chord: KeyChord, title: String)] = [
        (KeyChord("n", .command), "New Window"), (KeyChord("o", .command), "Open"), (KeyChord("p", [.command, .option]), "Now Playing Full Screen"),
        (KeyChord("r", .command), "Refresh"), (KeyChord("0", [.control, .option, .command]), "Window Size"),
    ]
    public static let newWindow = otherMenu[0].chord, open = otherMenu[1].chord, nowPlayingFullScreen = otherMenu[2].chord, windowSize = otherMenu[4].chord
    /// The title of the menu item that owns `chord`: a table entry or one of the other menu shortcuts.
    public static func menuTitle(for chord: KeyChord) -> String? { entry(for: chord)?.title ?? otherMenu.first { $0.chord == chord }?.title }
    /// Seconds a seek shortcut moves.
    public static let seekStep: Double = 10
}

/// What the one key router does with a key press (section 13).
public enum ShortcutRouting: Equatable, Sendable {
    /// Run the action.
    case perform(ShortcutAction)
    /// The control that has focus uses the key (a text field moves its cursor, a button activates). The router hands the event to it and swallows
    /// it, so the menu's key equivalent for the same chord never fires.
    case deliverToFocus
    /// Not a routed chord: the menus and the system see it as usual.
    case passThrough
}
public enum ShortcutRouter {
    /// `windowAllowsShortcuts`: the key window is one of the app's own browser, mini-player or Now Playing windows and not a sheet or a panel. Any
    /// other window (Settings, the sign-in sheet, the command palette, an alert) keeps its keys.
    public static func route(_ chord: KeyChord, focus: ShortcutFocus, windowAllowsShortcuts: Bool) -> ShortcutRouting {
        guard let entry = ShortcutTable.entry(for: chord), entry.isRouted else { return .passThrough }
        // Text being edited, or a web page, always keeps its keys, in every window.
        if focus == .textEditing || focus == .webContent { return .deliverToFocus }
        // Another window of the app (Settings, a sheet, an alert): its focused control keeps the key; with nothing focused the menu may act.
        guard windowAllowsShortcuts else { return focus == .control ? .deliverToFocus : .passThrough }
        guard entry.focusGuard.allows(focus) else { return .deliverToFocus }
        return .perform(entry.action)
    }
}

// MARK: Global shortcuts (MAC09)

/// The actions a global shortcut can run. There are three groups and nothing else: show/hide, play/pause and next/previous.
public enum GlobalShortcutAction: String, Sendable, CaseIterable, Codable {
    case showHide, playPause, next, previous
    public var title: String {
        switch self {
        case .showHide: String(localized: "Show or hide YTMuse")
        case .playPause: String(localized: "Play/Pause")
        case .next: String(localized: "Next")
        case .previous: String(localized: "Previous")
        }
    }
}
/// The keys a global shortcut can use, with the virtual key code each registers under (the ANSI layout's key positions; letters are also read from the
/// layout in use when recorded). ONE table: the policy's "can this key be used" is "is it here", the recorder names keys from it and the app target's
/// hot-key registrar registers from it, so a key the policy accepts is a key the registrar can register.
public enum HotKeyCodes {
    public static let codes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "space": 49, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    public static func code(for key: ShortcutKey) -> UInt32? { codes[key.name] }
    public static func key(forCode code: UInt32) -> ShortcutKey? { codes.first { $0.value == code }.map { ShortcutKey($0.key) } }
    static let arrows: Set<String> = ["left", "right", "up", "down"]
    static func isFunctionKey(_ name: String) -> Bool { name.hasPrefix("f") && name.count > 1 && Int(name.dropFirst()) != nil }
    /// A key that types a character (a letter, digit or punctuation mark).
    static func isPrintable(_ name: String) -> Bool { name.count == 1 }
}

public enum GlobalShortcutRefusal: Equatable, Sendable, Error {
    /// A global shortcut needs Command, Control or Option (Shift alone, or no modifier, would take a letter away from every app).
    case needsModifier
    /// A standard editing or window command that every app and every text field uses.
    case standardEditing(String)
    /// A shortcut the system reserves (Spotlight, the app switcher, Mission Control, screenshots, Force Quit, the Dock, input-source switching).
    case system(String)
    /// One of YTMuse's own shortcuts: the table, or any other menu shortcut the app defines.
    case appShortcut(String)
    /// Option (with or without Shift) and nothing else on a letter, digit or mark types a character or starts an accent in every text field.
    case entersText
    /// Another global shortcut of this app.
    case alreadyAssigned(GlobalShortcutAction)
    /// The system's own list of enabled shortcuts (`CopySymbolicHotKeys`) holds this chord.
    case takenBySystemSetting
    /// The app cannot register this key (only letters, digits, the marks on the main keys, arrows, Space and F1-F12 can be).
    case unsupportedKey
    /// The registration itself was refused (another app may hold the chord). Nothing is saved.
    case couldNotRegister
    public var message: String {
        switch self {
        case .needsModifier: String(localized: "A global shortcut needs Command, Control or Option.")
        case .standardEditing(let name): String(localized: "This is the standard \(name) shortcut, which every app uses.")
        case .system(let name): String(localized: "macOS uses this shortcut for \(name).")
        case .appShortcut(let name): String(localized: "YTMuse already uses this shortcut for \(name).")
        case .entersText: String(localized: "With only Option (and Shift) this shortcut would type a character in every text field. Add Command or Control.")
        case .alreadyAssigned(let action): String(localized: "This shortcut already runs “\(action.title)”.")
        case .takenBySystemSetting: String(localized: "macOS lists this shortcut among its own enabled shortcuts.")
        case .unsupportedKey: String(localized: "This key cannot be used: choose a letter, a digit, an arrow, Space or F1 to F12.")
        case .couldNotRegister: String(localized: "This shortcut could not be registered. Another app may be using it; choose another.")
        }
    }
}
public enum GlobalShortcutPolicy {
    /// Standard editing, navigation and window chords, never available (and never taken from the text fields and menus that use them).
    static let editing: [KeyChord: String] = [
        KeyChord("c", .command): "Copy", KeyChord("v", .command): "Paste", KeyChord("x", .command): "Cut", KeyChord("z", .command): "Undo",
        KeyChord("z", [.command, .shift]): "Redo", KeyChord("a", .command): "Select All", KeyChord("f", .command): "Find", KeyChord("h", .command): "Hide",
        KeyChord("h", [.command, .option]): "Hide Others", KeyChord("n", .command): "New", KeyChord("o", .command): "Open", KeyChord("p", .command): "Print",
        KeyChord("s", .command): "Save", KeyChord("w", .command): "Close", KeyChord("q", .command): "Quit", KeyChord("m", .command): "Minimize",
        KeyChord(",", .command): "Settings", KeyChord("a", [.command, .shift]): "Select All", KeyChord("delete", .command): "Delete",
        KeyChord("b", .command): "Bold", KeyChord("i", .command): "Italic", KeyChord("u", .command): "Underline", KeyChord("g", .command): "Find Next",
        KeyChord("g", [.command, .shift]): "Find Previous", KeyChord("e", .command): "Use Selection for Find", KeyChord("j", .command): "Jump to Selection",
        KeyChord("d", .command): "Duplicate", KeyChord("t", .command): "New Tab or Fonts", KeyChord("[", .command): "Back", KeyChord("]", .command): "Forward",
        KeyChord("/", .command): "Help", KeyChord("/", [.command, .shift]): "Help search", KeyChord("space", [.command, .control]): "Emoji & Symbols",
        KeyChord("v", [.command, .option, .shift]): "Paste and Match Style", KeyChord("v", [.command, .option]): "Paste Style", KeyChord("c", [.command, .option]): "Copy Style",
        KeyChord(";", .command): "Check Spelling", KeyChord(";", [.command, .shift]): "Show Spelling", KeyChord("[", [.command, .shift]): "Previous Tab",
        KeyChord("]", [.command, .shift]): "Next Tab", KeyChord("m", [.command, .option]): "Minimize All", KeyChord("w", [.command, .option]): "Close All",
        KeyChord("space", .option): "typing a no-break space", KeyChord("space", [.option, .shift]): "typing a no-break space",
        KeyChord("=", .command): "Zoom In", KeyChord("-", .command): "Zoom Out", KeyChord("0", .command): "Actual Size", KeyChord("delete", .option): "Delete Word",
    ]
    /// Chords the system reserves in its default configuration.
    static let system: [KeyChord: String] = [
        KeyChord("space", .command): "Spotlight", KeyChord("space", [.command, .option]): "Finder search", KeyChord("space", .control): "switching the input source",
        KeyChord("space", [.control, .option]): "switching the input source", KeyChord("tab", .command): "the app switcher", KeyChord("tab", [.command, .shift]): "the app switcher",
        KeyChord("`", .command): "switching windows", KeyChord("`", [.command, .shift]): "switching windows", KeyChord("escape", [.command, .option]): "Force Quit",
        KeyChord("3", [.command, .shift]): "screenshots", KeyChord("4", [.command, .shift]): "screenshots", KeyChord("5", [.command, .shift]): "screenshots",
        KeyChord("q", [.command, .control]): "locking the screen", KeyChord("q", [.command, .shift]): "logging out", KeyChord("d", [.command, .option]): "showing the Dock",
        KeyChord("up", .control): "Mission Control", KeyChord("down", .control): "Application windows", KeyChord("left", .control): "moving to the previous Space",
        KeyChord("right", .control): "moving to the next Space", KeyChord("f", [.command, .control]): "full screen", KeyChord("d", [.command, .control]): "the dictionary",
        KeyChord("8", [.command, .option]): "Zoom", KeyChord("f5", [.command]): "VoiceOver", KeyChord("space", [.command, .shift]): "Spotlight",
        KeyChord("t", [.command, .control]): "Look Up", KeyChord("3", [.command, .control, .shift]): "screenshots", KeyChord("4", [.command, .control, .shift]): "screenshots",
    ]
    /// Keys a Carbon hot key can be registered for: exactly the keys `HotKeyCodes` has a code for.
    public static func isSupported(_ key: ShortcutKey) -> Bool { HotKeyCodes.code(for: key) != nil }
    /// The shapes that belong to the text system, whatever the key: arrows with Command, Option or Shift only (cursor movement and selection) or with Control
    /// (Spaces and Mission Control); Control or Control-Shift on a letter (the Emacs-style bindings Control-A, E, K, N, P and the rest).
    static func textSystemName(_ chord: KeyChord) -> String? {
        let mods = chord.modifiers, name = chord.key.name
        if HotKeyCodes.arrows.contains(name) {
            if mods.isSubset(of: [.command, .shift, .option]) { return "text navigation and selection" }
            if mods == .control || mods == [.control, .shift] { return "text selection and Spaces" }
            return nil
        }
        if HotKeyCodes.isPrintable(name), mods.contains(.control), !mods.contains(.command), !mods.contains(.option) { return "Control-key text editing" }
        return nil
    }
    /// `assigned`: the other global shortcuts (the action being set is excluded by the caller). `systemTaken`: chords the system reports as enabled
    /// symbolic hot keys (`CopySymbolicHotKeys`), supplied by the app target; empty in tests and in an isolated launch.
    public static func validate(_ chord: KeyChord, for action: GlobalShortcutAction, assigned: [GlobalShortcutAction: KeyChord], systemTaken: Set<KeyChord> = []) -> GlobalShortcutRefusal? {
        // The named conflicts first, so a standard or system chord says what it is even when its key could not be registered anyway.
        if let name = editing[chord] { return .standardEditing(name) }
        if let name = system[chord] { return .system(name) }
        guard !chord.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .needsModifier }
        if let name = textSystemName(chord) { return .standardEditing(name) }
        if let title = ShortcutTable.menuTitle(for: chord) { return .appShortcut(String(localized: String.LocalizationValue(title))) }
        if HotKeyCodes.isPrintable(chord.key.name), chord.modifiers.contains(.option), chord.modifiers.isSubset(of: [.option, .shift]) { return .entersText }
        guard isSupported(chord.key) else { return .unsupportedKey }
        if let other = assigned.first(where: { $0.key != action && $0.value == chord })?.key { return .alreadyAssigned(other) }
        if systemTaken.contains(chord) { return .takenBySystemSetting }
        return nil
    }
}

/// The saved global shortcuts: nothing is assigned until the person records one. A stored value that no longer validates (a table that grew a
/// conflicting entry) is ignored rather than registered.
public struct GlobalShortcutStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    private func key(_ action: GlobalShortcutAction) -> String { "shortcuts.global." + action.rawValue }
    public func chord(for action: GlobalShortcutAction) -> KeyChord? {
        guard let data = defaults.data(forKey: key(action)), let chord = try? JSONDecoder().decode(KeyChord.self, from: data) else { return nil }
        return GlobalShortcutPolicy.validate(chord, for: action, assigned: [:]) == nil ? chord : nil
    }
    public var assigned: [GlobalShortcutAction: KeyChord] {
        var result: [GlobalShortcutAction: KeyChord] = [:]
        for action in GlobalShortcutAction.allCases { if let chord = chord(for: action) { result[action] = chord } }
        return result
    }
    public func set(_ chord: KeyChord?, for action: GlobalShortcutAction) {
        if let chord, let data = try? JSONEncoder().encode(chord) { defaults.set(data, forKey: key(action)) } else { defaults.removeObject(forKey: key(action)) }
    }
}

/// Registers system-wide hot keys. The real conformer is in the app target (public Carbon `RegisterEventHotKey`, which delivers only the chords
/// registered and neither taps nor monitors other input); everything else, including every test and every isolated launch, gets the recording one.
@MainActor public protocol HotKeyRegistering: AnyObject {
    /// Registers `chord` and runs `handler` when it is pressed. Returns false when the system refused the registration (another app holds it).
    func register(_ chord: KeyChord, handler: @escaping @MainActor () -> Void) -> HotKeyHandle?
    /// Chords the system's own settings reserve (enabled symbolic hot keys), for the conflict check. Empty when it cannot say.
    func systemReservedChords() -> Set<KeyChord>
    var isInProcessFake: Bool { get }
}
@MainActor public protocol HotKeyHandle: AnyObject { func unregister() }

/// The recording stand-in: registrations live in the process, nothing reaches the system, and a test can press a chord.
@MainActor public final class RecordingHotKeys: HotKeyRegistering {
    public private(set) var registrations: [KeyChord: @MainActor () -> Void] = [:]
    public private(set) var registerCalls = 0, unregisterCalls = 0
    public var refuse: Set<KeyChord> = []
    public var reserved: Set<KeyChord> = []
    public init() {}
    public var isInProcessFake: Bool { true }
    public func register(_ chord: KeyChord, handler: @escaping @MainActor () -> Void) -> HotKeyHandle? {
        registerCalls += 1
        guard !refuse.contains(chord), registrations[chord] == nil else { return nil }
        registrations[chord] = handler
        return Handle(owner: self, chord: chord)
    }
    public func systemReservedChords() -> Set<KeyChord> { reserved }
    public func press(_ chord: KeyChord) { registrations[chord]?() }
    private final class Handle: HotKeyHandle {
        weak var owner: RecordingHotKeys?; let chord: KeyChord
        init(owner: RecordingHotKeys, chord: KeyChord) { self.owner = owner; self.chord = chord }
        func unregister() { if owner?.registrations.removeValue(forKey: chord) != nil { owner?.unregisterCalls += 1 } }
    }
}

/// Applies the saved global shortcuts to a registrar. With nothing assigned (the default) it registers nothing at all.
@MainActor public final class GlobalShortcutService {
    public let store: GlobalShortcutStore
    private let registrar: any HotKeyRegistering
    private let perform: @MainActor (GlobalShortcutAction) -> Void
    private var handles: [GlobalShortcutAction: HotKeyHandle] = [:]
    /// The last refusal per action, for the Settings pane to show.
    public private(set) var failures: [GlobalShortcutAction: GlobalShortcutRefusal] = [:]
    public init(store: GlobalShortcutStore, registrar: any HotKeyRegistering, perform: @escaping @MainActor (GlobalShortcutAction) -> Void) {
        self.store = store; self.registrar = registrar; self.perform = perform
    }
    public var usesInProcessFake: Bool { registrar.isInProcessFake }
    public var assigned: [GlobalShortcutAction: KeyChord] { store.assigned }
    /// Registers whatever is saved. Called at launch and after a change; unassigned actions register nothing.
    public func reapply() {
        for handle in handles.values { handle.unregister() }
        handles = [:]; failures = [:]
        for (action, chord) in store.assigned {
            if let handle = registrar.register(chord, handler: { [perform] in perform(action) }) { handles[action] = handle }
            else { failures[action] = .couldNotRegister }
        }
    }
    /// Records `chord` for `action` when it passes the conflict rules; otherwise saves nothing and says why.
    @discardableResult public func assign(_ chord: KeyChord, to action: GlobalShortcutAction) -> GlobalShortcutRefusal? {
        if let refusal = GlobalShortcutPolicy.validate(chord, for: action, assigned: store.assigned, systemTaken: registrar.systemReservedChords()) { return refusal }
        store.set(chord, for: action)
        reapply()
        if let failure = failures[action] { store.set(nil, for: action); reapply(); return failure }
        return nil
    }
    public func clear(_ action: GlobalShortcutAction) { store.set(nil, for: action); reapply() }
    public func stop() { for handle in handles.values { handle.unregister() }; handles = [:] }
}
