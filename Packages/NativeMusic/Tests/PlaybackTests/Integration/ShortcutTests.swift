import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Playback
@testable import SystemIntegration
@testable import AppShell
import TestSupport

/// A shell that records the table actions it was asked to run.
@MainActor final class RecordingPerformer: ShortcutPerforming {
    private(set) var actions: [ShortcutAction] = []
    func perform(_ action: ShortcutAction) { actions.append(action) }
}

/// A text view and a button that record the key events they are handed, so "the focused control received the key" is observable without typing.
@MainActor final class KeyRecordingTextView: NSTextView {
    private(set) var received: [NSEvent] = []
    override func keyDown(with event: NSEvent) { received.append(event) }
}
@MainActor final class KeyRecordingButton: NSButton {
    private(set) var received: [NSEvent] = []
    override func keyDown(with event: NSEvent) { received.append(event) }
}

/// Offscreen windows with real AppKit controls, so the focus guard is exercised on the real responder classes.
@MainActor final class FocusFixtures {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: true)
    let field = NSTextField(frame: NSRect(x: 10, y: 190, width: 200, height: 24))
    let search = NSSearchField(frame: NSRect(x: 10, y: 160, width: 200, height: 24))
    let textView = KeyRecordingTextView(frame: NSRect(x: 10, y: 100, width: 200, height: 50))
    let readOnly = NSTextView(frame: NSRect(x: 10, y: 60, width: 100, height: 30))
    let button = KeyRecordingButton(title: "Press", target: nil, action: nil)
    let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let plain = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    /// Made only by the one test that needs it: a web view starts WebKit processes, and a fixture every test builds would load the main thread for the
    /// timing-sensitive suites that run beside these (the quit deadline) in a whole-package run.
    lazy var web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: WKWebViewConfiguration())
    init() {
        window.isReleasedWhenClosed = false
        textView.isEditable = true; readOnly.isEditable = false; readOnly.isSelectable = true
        for view in [field, search, textView, readOnly, button, slider, popUp, table, plain] as [NSView] { window.contentView?.addSubview(view) }
    }
    deinit { MainActor.assumeIsolated { window.orderOut(nil) } }
    func focus(_ responder: NSResponder) -> ShortcutFocus {
        window.makeFirstResponder(responder)
        return ShortcutFocusClassifier.classify(window.firstResponder)
    }
}

func keyEvent(_ chord: KeyChord, repeating: Bool = false, window: NSWindow? = nil) -> NSEvent {
    var flags: NSEvent.ModifierFlags = []
    if chord.modifiers.contains(.command) { flags.insert(.command) }
    if chord.modifiers.contains(.shift) { flags.insert(.shift) }
    if chord.modifiers.contains(.option) { flags.insert(.option) }
    if chord.modifiers.contains(.control) { flags.insert(.control) }
    let code: UInt16, characters: String
    switch chord.key {
    case .space: code = 49; characters = " "
    case .left: code = 123; characters = String(UnicodeScalar(NSLeftArrowFunctionKey)!); flags.formUnion([.function, .numericPad])
    case .right: code = 124; characters = String(UnicodeScalar(NSRightArrowFunctionKey)!); flags.formUnion([.function, .numericPad])
    default: code = 0; characters = chord.key.name
    }
    return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
                            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: code)!
}

/// T26.1 (MAC09, MAC10, section 13): every table entry, with the text-field and control focus guards.
@Suite @MainActor struct ShortcutTableTests {
    @Test func theTableIsSectionThirteenExactly() {
        let expected: [(ShortcutAction, String)] = [
            (.focusSearch, "⌘F"), (.commandPalette, "⌘K"), (.playPause, "Space"), (.next, "⌘→"), (.previous, "⌘←"), (.seekForward, "⇧⌘→"), (.seekBack, "⇧⌘←"),
            (.revealCurrentItem, "⌘L"), (.showQueue, "⌥⌘Q"), (.minimize, "⌘M"), (.miniPlayer, "⇧⌘M"), (.settings, "⌘,"), (.closeWindow, "⌘W"), (.quit, "⌘Q"),
        ]
        #expect(ShortcutTable.entries.map(\.action) == expected.map(\.0), "every entry, once, in the specification's order")
        for (action, label) in expected { #expect(ShortcutTable.entry(for: action).chord.label == label, "\(action)") }
        #expect(Set(ShortcutTable.entries.map(\.chord)).count == ShortcutTable.entries.count, "no two actions share a chord")
        #expect(Set(ShortcutAction.allCases) == Set(ShortcutTable.entries.map(\.action)), "every action has an entry")
        #expect(ShortcutTable.seekStep == 10)
    }

    @Test func everyNonStandardEntryIsInTheMenusWithTheSameChord() {
        let items = ShortcutMenuItem.items
        let nonStandard = ShortcutTable.entries.filter { !$0.isStandard }
        #expect(items.map(\.action) == nonStandard.map(\.action))
        for item in items { #expect(item.chord == ShortcutTable.entry(for: item.action).chord, "\(item.action)") }
        // The standard four are supplied by the system's own menus and never remappable.
        #expect(ShortcutTable.entries.filter(\.isStandard).map(\.action) == [.minimize, .settings, .closeWindow, .quit])
        // The source of the menus builds every key equivalent from the table, never from a literal.
        let scenes = (try? IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/NativeMusicScenes.swift")) ?? ""
        #expect(scenes.contains("ShortcutTable.entry(for: action).chord") && scenes.contains("CommandMenu(\"Playback\")"))
        for literal in ["keyboardShortcut(\"m\", modifiers: [.command, .option])", "keyboardShortcut(.space", "keyboardShortcut(.rightArrow"] { #expect(!scenes.contains(literal), "\(literal)") }
    }

    @Test func keyEquivalentsConvertForTheMenus() {
        #expect(ShortcutTable.entry(for: .playPause).chord.keyEquivalent == .space)
        #expect(ShortcutTable.entry(for: .next).chord.keyEquivalent == .rightArrow && ShortcutTable.entry(for: .next).chord.eventModifiers == .command)
        #expect(ShortcutTable.entry(for: .seekBack).chord.eventModifiers == [.command, .shift])
        #expect(ShortcutTable.entry(for: .showQueue).chord.eventModifiers == [.command, .option])
        #expect(ShortcutTable.entry(for: .revealCurrentItem).chord.keyEquivalent == KeyEquivalent("l"))
    }

    // MARK: The focus guard, per class of responder

    @Test func focusIsClassifiedFromTheRealResponderClasses() {
        let f = FocusFixtures()
        #expect(f.focus(f.field) == .textEditing, "an editable text field (its field editor)")
        #expect(f.focus(f.search) == .textEditing, "a search field")
        #expect(f.focus(f.textView) == .textEditing, "an editable text view")
        #expect(f.focus(f.readOnly) == .none, "selectable, read-only text does not take Space")
        #expect(f.focus(f.button) == .control)
        #expect(f.focus(f.slider) == .control)
        #expect(f.focus(f.popUp) == .control)
        #expect(f.focus(f.table) == .none, "a list or table is not a control for Space")
        #expect(f.focus(f.plain) == .none)
        #expect(ShortcutFocusClassifier.classify(nil) == .none)
        f.window.contentView?.addSubview(f.web)
        #expect(ShortcutFocusClassifier.classify(f.web) == .webContent, "the sign-in page owns the keyboard")
        let inner = NSView(frame: .zero); f.web.addSubview(inner)
        #expect(ShortcutFocusClassifier.classify(inner) == .webContent, "anything inside a web view")
    }

    /// The guard itself, whatever the router does with it (the router also defers to text and web content before it asks the guard).
    @Test func theFocusGuardAllowsExactlyWhatItsNameSays() {
        let all: [ShortcutFocus] = [.none, .textEditing, .control, .webContent]
        let expected: [(FocusGuard, [ShortcutFocus])] = [(.none, all), (.notWhileEditingText, [.none, .control]), (.notWhileEditingTextOrControl, [.none])]
        for (guardKind, allowed) in expected { for focus in all { #expect(guardKind.allows(focus) == allowed.contains(focus), "\(guardKind) with \(focus)") } }
    }

    @Test(arguments: ShortcutTable.entries.filter(\.isRouted).map(\.action)) func aRoutedChordPerformsOnlyWhereTheGuardAllows(action: ShortcutAction) {
        let entry = ShortcutTable.entry(for: action)
        for (focus, allowed) in [(ShortcutFocus.none, true), (.textEditing, false), (.webContent, false), (.control, entry.focusGuard == .notWhileEditingText)] {
            let routing = ShortcutRouter.route(entry.chord, focus: focus, windowAllowsShortcuts: true)
            #expect(routing == (allowed ? .perform(action) : .deliverToFocus), "\(action) with \(focus) focus")
        }
        // Another window of the app keeps its keys; with nothing focused the menu may act.
        #expect(ShortcutRouter.route(entry.chord, focus: .textEditing, windowAllowsShortcuts: false) == .deliverToFocus)
        #expect(ShortcutRouter.route(entry.chord, focus: .control, windowAllowsShortcuts: false) == .deliverToFocus)
        #expect(ShortcutRouter.route(entry.chord, focus: .none, windowAllowsShortcuts: false) == .passThrough)
    }

    @Test func onlyTheFiveGuardedChordsAreRouted() {
        #expect(ShortcutTable.entries.filter(\.isRouted).map(\.action) == [.playPause, .next, .previous, .seekForward, .seekBack])
        for entry in ShortcutTable.entries where !entry.isRouted { #expect(ShortcutRouter.route(entry.chord, focus: .textEditing, windowAllowsShortcuts: true) == .passThrough, "\(entry.action) is an ordinary menu key equivalent") }
        // Modified variants of a routed key are not the routed chord: Shift-Space, Option-Space and Control-Right are left alone.
        for chord in [KeyChord(.space, .shift), KeyChord(.space, .option), KeyChord(.right, .control), KeyChord(.right), KeyChord(.left, .option)] { #expect(ShortcutRouter.route(chord, focus: .none, windowAllowsShortcuts: true) == .passThrough, "\(chord.label)") }
    }

    // MARK: The router on real key events

    private func router(_ f: FocusFixtures, role: ShellWindowRole? = .browser) -> (ShortcutKeyRouter, RecordingPerformer) {
        let performer = RecordingPerformer()
        return (ShortcutKeyRouter(performer: performer, role: { [weak window = f.window] candidate in candidate === window ? role : nil }), performer)
    }

    @Test func everyRoutedEntryRunsFromARealKeyEventWhenNothingIsEditing() {
        let f = FocusFixtures()
        let (router, performer) = router(f)
        _ = f.focus(f.plain)
        for entry in ShortcutTable.entries.filter(\.isRouted) {
            let outcome = router.handle(keyEvent(entry.chord), in: f.window)
            #expect(outcome == nil, "\(entry.action) is consumed")
        }
        #expect(performer.actions == [.playPause, .next, .previous, .seekForward, .seekBack])
    }

    @Test func atextFieldKeepsSpaceAndCommandArrowsAndPlaybackStaysUntouched() {
        let f = FocusFixtures()
        let (router, performer) = router(f)
        for responder in [f.field, f.search, f.textView] as [NSResponder] {
            _ = f.focus(responder)
            for entry in ShortcutTable.entries.filter(\.isRouted) {
                let event = keyEvent(entry.chord)
                let outcome = router.handle(event, in: f.window)
                #expect(outcome == nil, "\(entry.action): swallowed so the menu's key equivalent cannot fire, after the field was given the key")
            }
        }
        #expect(performer.actions.isEmpty, "no playback command while text is being edited")
    }

    @Test func theKeyIsHandedToTheEditingTextViewNotRunAsPlayback() {
        let f = FocusFixtures()
        let (router, performer) = router(f)
        #expect(f.focus(f.textView) == .textEditing)
        for entry in ShortcutTable.entries.filter(\.isRouted) { _ = router.handle(keyEvent(entry.chord), in: f.window) }
        #expect(f.textView.received.count == 5, "the text view got Space and the four Command-Arrow chords itself")
        #expect(performer.actions.isEmpty)
    }

    @Test func aFocusedControlKeepsSpaceButCommandArrowStillSkips() {
        let f = FocusFixtures()
        let (router, performer) = router(f)
        _ = f.focus(f.button)
        _ = router.handle(keyEvent(KeyChord(.space)), in: f.window)
        #expect(performer.actions.isEmpty, "Space belongs to the focused button")
        _ = router.handle(keyEvent(KeyChord(.right, .command)), in: f.window)
        #expect(performer.actions == [.next], "Command-Right is not a button key")
    }

    @Test func otherWindowsAndSheetsKeepTheirKeys() {
        let f = FocusFixtures()
        let (settings, performerS) = router(f, role: .settings)
        _ = f.focus(f.plain)
        #expect(settings.handle(keyEvent(KeyChord(.space)), in: f.window) != nil, "Settings: nothing focused, the event goes on to the menus")
        _ = f.focus(f.field)
        #expect(settings.handle(keyEvent(KeyChord(.space)), in: f.window) == nil)
        let (unknown, performerU) = router(f, role: nil)
        _ = f.focus(f.plain)
        #expect(unknown.handle(keyEvent(KeyChord(.right, .command)), in: f.window) != nil, "a window the shell does not know")
        #expect(performerS.actions.isEmpty && performerU.actions.isEmpty)
        // A sheet: the window has a parent.
        let parent = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true); parent.isReleasedWhenClosed = false
        let (browser, performerB) = router(f, role: .browser)
        parent.beginSheet(f.window)
        _ = f.focus(f.plain)
        #expect(f.window.sheetParent != nil)
        #expect(browser.handle(keyEvent(KeyChord(.space)), in: f.window) != nil && performerB.actions.isEmpty, "a sheet is not a playback window")
        parent.endSheet(f.window)
    }

    @Test func holdingSpaceOrNextDoesNotRepeatButSeekingDoes() {
        let f = FocusFixtures()
        let (router, performer) = router(f)
        _ = f.focus(f.plain)
        for chord in [KeyChord(.space), KeyChord(.right, .command), KeyChord(.right, [.command, .shift])] {
            _ = router.handle(keyEvent(chord), in: f.window)
            _ = router.handle(keyEvent(chord, repeating: true), in: f.window)
        }
        #expect(performer.actions == [.playPause, .next, .seekForward, .seekForward])
    }

    @Test func unrelatedKeysAreNotTouched() {
        let f = FocusFixtures()
        let (router, performer) = router(f)
        _ = f.focus(f.plain)
        for chord in [KeyChord("a"), KeyChord("f", .command), KeyChord("k", .command), KeyChord("c", .command), KeyChord(.left, .option), KeyChord(.space, .command)] {
            #expect(router.handle(keyEvent(chord), in: f.window) != nil, "\(chord.label)")
        }
        #expect(performer.actions.isEmpty)
    }

    /// The first UI run found the monitor's closure turning "consumed" back into "pass on" (Space and Command-Right ran twice): the value AppKit receives
    /// is pinned here, for a consumed event, a pass-through event and a router that is gone.
    @Test func theMonitorHandsAppKitNilForAConsumedEventAndTheEventForEverythingElse() {
        let f = FocusFixtures()
        let (router, performer) = router(f)
        _ = f.focus(f.plain)
        let space = keyEvent(KeyChord(.space)), letter = keyEvent(KeyChord("a")), find = keyEvent(KeyChord("f", .command))
        #expect(ShortcutKeyRouter.monitorResult(of: router, for: space, in: f.window) == nil, "Space was run: consumed")
        #expect(performer.actions == [.playPause])
        #expect(ShortcutKeyRouter.monitorResult(of: router, for: letter, in: f.window) === letter, "a letter is not the router's")
        #expect(ShortcutKeyRouter.monitorResult(of: router, for: find, in: f.window) === find, "Command-F is an ordinary menu key equivalent")
        #expect(ShortcutKeyRouter.monitorResult(of: nil, for: space) === space, "with the router gone the key is not eaten")
        _ = f.focus(f.textView)
        #expect(ShortcutKeyRouter.monitorResult(of: router, for: space, in: f.window) == nil && f.textView.received.count == 1, "handed to the text view and consumed")
        #expect(performer.actions == [.playPause], "and not run as playback")
    }

    /// The exact closure `install()` hands to AppKit: a consumed event comes back nil (the first UI run found the closure turning that back into the
    /// event), and with the router gone the key is passed on.
    @Test func theClosureAppKitCallsConsumesWhatTheRouterRanAndPassesTheRest() {
        let f = FocusFixtures()
        let (router, performer) = router(f)
        router.windowProvider = { [weak window = f.window] _ in window }
        _ = f.focus(f.plain)
        let handler = ShortcutKeyRouter.monitorHandler(for: router)
        #expect(handler(keyEvent(KeyChord(.space))) == nil, "Space was run: AppKit must get nil")
        #expect(handler(keyEvent(KeyChord(.right, .command))) == nil)
        #expect(performer.actions == [.playPause, .next])
        let letter = keyEvent(KeyChord("a"))
        #expect(handler(letter) === letter)
        _ = f.focus(f.textView)
        #expect(handler(keyEvent(KeyChord(.space))) == nil && f.textView.received.count == 1, "handed to the text view, and consumed")
        #expect(performer.actions == [.playPause, .next])
        let orphan: (NSEvent) -> NSEvent? = { var gone: ShortcutKeyRouter? = ShortcutKeyRouter(performer: performer, role: { _ in .browser }); let h = ShortcutKeyRouter.monitorHandler(for: gone!); gone = nil; return h($0) }
        let space = keyEvent(KeyChord(.space))
        #expect(orphan(space) === space, "with the router gone the key is not eaten")
        // The installed monitor is built by that function and by nothing else.
        let source = (try? IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/Integration/ShortcutRouting.swift")) ?? ""
        #expect(source.contains("addLocalMonitorForEvents(matching: .keyDown, handler: Self.monitorHandler(for: self))"))
        #expect(!source.contains("?? event"), "nothing turns a consumed event back into a pass-through")
    }

    @Test func theRouterIsALocalMonitorAndInstallsOnceAndRemoves() {
        let f = FocusFixtures()
        let (router, _) = router(f)
        router.install(); router.install(); router.remove(); router.remove()
        let source = (try? IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/Integration/ShortcutRouting.swift")) ?? ""
        #expect(source.contains("addLocalMonitorForEvents") && !source.contains("addGlobalMonitorForEvents") && !source.contains("CGEvent"))
    }
}

/// T26.1 / T26.5: the global shortcuts are opt-in, unassigned by default, conflict-checked, and never steal standard editing or system shortcuts.
@Suite @MainActor struct GlobalShortcutTests {
    private func store() -> (GlobalShortcutStore, InMemoryDefaults) {
        let defaults = InMemoryDefaults()
        return (GlobalShortcutStore(defaults: defaults), defaults)
    }

    @Test func nothingIsAssignedOrRegisteredByDefault() {
        let (store, defaults) = store()
        let keys = RecordingHotKeys()
        let service = GlobalShortcutService(store: store, registrar: keys, perform: { _ in })
        service.reapply()
        #expect(store.assigned.isEmpty && service.assigned.isEmpty)
        #expect(keys.registerCalls == 0 && keys.registrations.isEmpty, "a launch with nothing recorded registers nothing with the system")
        #expect(GlobalShortcutAction.allCases == [.showHide, .playPause, .next, .previous])
    }

    @Test(arguments: [
        (KeyChord("c", .command), "standard"), (KeyChord("v", .command), "standard"), (KeyChord("x", .command), "standard"), (KeyChord("z", .command), "standard"), (KeyChord("a", .command), "standard"),
        (KeyChord("q", .command), "standard"), (KeyChord("w", .command), "standard"), (KeyChord("m", .command), "standard"), (KeyChord("h", .command), "standard"), (KeyChord(",", .command), "standard"),
        (KeyChord("left", .command), "standard"), (KeyChord("right", .command), "standard"), (KeyChord("left", .option), "standard"), (KeyChord("delete", .command), "standard"),
        (KeyChord("space", .command), "system"), (KeyChord("space", .control), "system"), (KeyChord("tab", .command), "system"), (KeyChord("3", [.command, .shift]), "system"),
        (KeyChord("up", .control), "system"), (KeyChord("escape", [.command, .option]), "system"), (KeyChord("q", [.command, .control]), "system"),
        (KeyChord("f", .command), "standard"), (KeyChord("k", .command), "app"), (KeyChord("l", .command), "app"), (KeyChord("q", [.command, .option]), "app"), (KeyChord("m", [.command, .shift]), "app"),
        (KeyChord("space"), "modifier"), (KeyChord("p"), "modifier"), (KeyChord("p", .shift), "modifier"), (KeyChord("f9"), "modifier"),
        (KeyChord("é", [.command, .option]), "unsupported"), (KeyChord("return", [.command, .option]), "unsupported"), (KeyChord("f13", .command), "unsupported"), (KeyChord("🎵", .command), "unsupported"),
    ] as [(KeyChord, String)])
    func standardEditingSystemAndAppShortcutsAreRefused(chord: KeyChord, kind: String) {
        let refusal = GlobalShortcutPolicy.validate(chord, for: .playPause, assigned: [:])
        switch (kind, refusal) {
        case ("standard", .standardEditing?), ("system", .system?), ("app", .appShortcut?), ("modifier", .needsModifier?), ("unsupported", .unsupportedKey?): break
        default: Issue.record("\(chord.label) expected \(kind), got \(String(describing: refusal))")
        }
        #expect(refusal?.message.isEmpty == false)
    }

    @Test(arguments: [KeyChord("j", [.control, .option, .command]), KeyChord("right", [.control, .option]), KeyChord("space", [.control, .option, .shift]), KeyChord("f5", .control), KeyChord("9", [.command, .shift, .option]), KeyChord("/", [.control, .option])])
    func aDistinctChordWithAModifierIsAccepted(chord: KeyChord) {
        #expect(GlobalShortcutPolicy.validate(chord, for: .playPause, assigned: [:]) == nil, "\(chord.label)")
    }

    // MARK: Rework 1: the app's own menu chords, standard editing, Option-only, keys the registrar cannot take

    @Test(arguments: [KeyChord("p", [.command, .option]), KeyChord("r", .command), KeyChord("0", [.control, .option, .command]), KeyChord("n", .command), KeyChord("o", .command)])
    func everyMenuShortcutTheAppDefinesIsRefusedEvenWhenItIsNotInTheSectionThirteenTable(chord: KeyChord) {
        let refusal = GlobalShortcutPolicy.validate(chord, for: .playPause, assigned: [:])
        guard let refusal else { Issue.record("\(chord.label) was accepted"); return }
        switch refusal { case .appShortcut, .standardEditing: break; default: Issue.record("\(chord.label): \(refusal)") }
    }

    @Test(arguments: ShortcutTable.entries.map(\.chord)) func everyTableChordIsRefusedAsTheAppsOwnOrStandard(chord: KeyChord) {
        #expect(GlobalShortcutPolicy.validate(chord, for: .next, assigned: [:]) != nil, "\(chord.label)")
    }

    @Test(arguments: [KeyChord("up", [.command, .shift]), KeyChord("down", [.command, .shift]), KeyChord("up", .option), KeyChord("down", .option), KeyChord("left", [.control, .shift]), KeyChord("right", [.control, .shift]),
                      KeyChord("up", [.option, .shift]), KeyChord("a", .control), KeyChord("e", .control), KeyChord("k", .control), KeyChord("n", .control), KeyChord("p", .control), KeyChord("f", [.control, .shift]),
                      KeyChord("space", [.control, .command]), KeyChord("[", .command), KeyChord("]", .command), KeyChord("b", .command), KeyChord("i", .command), KeyChord("g", .command),
                      KeyChord("g", [.command, .shift]), KeyChord("/", [.command, .shift]), KeyChord("u", .command), KeyChord("=", .command),
                      KeyChord("v", [.option, .shift, .command]), KeyChord(";", .command), KeyChord("[", [.shift, .command]), KeyChord("]", [.shift, .command]), KeyChord("m", [.option, .command]), KeyChord("w", [.option, .command]), KeyChord("space", .option)])
    func standardEditingAndNavigationChordsAreRefusedAsSuch(chord: KeyChord) {
        guard case .standardEditing? = GlobalShortcutPolicy.validate(chord, for: .playPause, assigned: [:]) else { Issue.record("\(chord.label): \(String(describing: GlobalShortcutPolicy.validate(chord, for: .playPause, assigned: [:])))"); return }
    }

    @Test(arguments: [KeyChord("p", .option), KeyChord("e", .option), KeyChord("3", .option), KeyChord("-", .option), KeyChord("p", [.option, .shift]), KeyChord("u", [.option, .shift]), KeyChord("/", .option)])
    func optionOnlyChordsOnLettersAndMarksAreRefusedBecauseTheyTypeACharacter(chord: KeyChord) {
        #expect(GlobalShortcutPolicy.validate(chord, for: .playPause, assigned: [:]) == .entersText, "\(chord.label)")
        #expect(GlobalShortcutRefusal.entersText.message.contains("Option"))
    }

    @Test func optionWithCommandOrControlOnAFunctionKeyOrAnArrowIsStillAvailable() {
        for chord in [KeyChord("f6", .option), KeyChord("f9", [.control, .option]), KeyChord("right", [.control, .option]), KeyChord("j", [.control, .option]), KeyChord("j", [.command, .option, .shift]), KeyChord("space", [.control, .option, .shift])] {
            #expect(GlobalShortcutPolicy.validate(chord, for: .playPause, assigned: [:]) == nil, "\(chord.label)")
        }
    }

    /// The menus' own key equivalents, read from the sources: every literal `keyboardShortcut` of the app must be refused as a global shortcut, so the list
    /// cannot fall behind a menu that grows a shortcut.
    @Test func everyKeyboardShortcutLiteralInTheSourcesIsRefusedByThePolicy() async throws {
        let sources = await LifecycleSources.offMain { LifecycleSources.swiftFiles(under: LifecycleSources.packageRoot.appendingPathComponent("Sources")).compactMap { try? String(contentsOf: $0, encoding: .utf8) } }
        let regex = try NSRegularExpression(pattern: #"\.keyboardShortcut\(\s*"(.)"\s*(?:,\s*modifiers:\s*(\[[^\]]*\]|\.\w+))?\s*\)"#)
        var found: [KeyChord] = []
        for text in sources {
            for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let keyRange = Range(match.range(at: 1), in: line) else { continue }
                    var modifiers: KeyModifiers = []
                    let spec = Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? ".command"
                    if spec.contains("command") { modifiers.insert(.command) }
                    if spec.contains("option") { modifiers.insert(.option) }
                    if spec.contains("control") { modifiers.insert(.control) }
                    if spec.contains("shift") { modifiers.insert(.shift) }
                    found.append(KeyChord(ShortcutKey(String(line[keyRange]).lowercased()), modifiers))
                }
            }
        }
        #expect(found.count >= 4, "the sweep read the menus' shortcuts (\(found.count))")
        #expect(found.contains(KeyChord("r", .command)) && found.contains(KeyChord("a", .command)), "it saw Refresh and Select All")
        for chord in found { #expect(GlobalShortcutPolicy.validate(chord, for: .playPause, assigned: [:]) != nil, "\(chord.label) is defined by a menu and the policy accepts it") }
    }

    @Test func aKeyIsSupportedExactlyWhenTheRegistrarHasACodeForIt() {
        for name in ["a", "z", "0", "9", ",", "/", "`", "space", "left", "up", "f1", "f6", "f12"] { #expect(GlobalShortcutPolicy.isSupported(ShortcutKey(name)) && HotKeyCodes.code(for: ShortcutKey(name)) != nil, "\(name)") }
        for name in ["f13", "return", "escape", "tab", "delete", "é", "🎵", "fn"] { #expect(!GlobalShortcutPolicy.isSupported(ShortcutKey(name)), "\(name)") }
        for (name, code) in HotKeyCodes.codes { #expect(HotKeyCodes.key(forCode: code) == ShortcutKey(name), "\(name) ↔ \(code)") }
        #expect(Set(HotKeyCodes.codes.values).count == HotKeyCodes.codes.count, "no two keys share a code")
        #expect(HotKeyCodes.codes.count == 26 + 10 + 11 + 5 + 12, "26 letters, 10 digits, 11 marks, Space and 4 arrows, F1 to F12")
    }

    @Test func aShiftedKeyIsNamedByItsKeyNotItsShiftedCharacter() {
        // Shift-Command-3 arrives from AppKit as "#"; the recorder names it by key code, so the screenshot chord is recognised and refused.
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: "#", charactersIgnoringModifiers: "#", isARepeat: false, keyCode: 20)!
        let chord = ShortcutKeyRouter.chord(for: event)
        #expect(chord == KeyChord("3", [.command, .shift]))
        #expect(GlobalShortcutPolicy.validate(chord!, for: .playPause, assigned: [:]) == .system("screenshots"))
        let f6 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F709}", charactersIgnoringModifiers: "\u{F709}", isARepeat: false, keyCode: 97)!
        #expect(ShortcutKeyRouter.chord(for: f6) == KeyChord("f6", .control), "function keys are recorded by key code")
    }

    @Test func eachRefusalSaysWhatIsActuallyWrong() {
        let all: [GlobalShortcutRefusal] = [.needsModifier, .standardEditing("Copy"), .system("Spotlight"), .appShortcut("Refresh"), .entersText, .alreadyAssigned(.next), .takenBySystemSetting, .unsupportedKey, .couldNotRegister]
        #expect(Set(all.map(\.message)).count == all.count, "no two reasons share a sentence")
        #expect(GlobalShortcutRefusal.couldNotRegister.message.contains("could not be registered") && !GlobalShortcutRefusal.couldNotRegister.message.contains("macOS reports"))
        #expect(GlobalShortcutRefusal.unsupportedKey.message.contains("F1") && !GlobalShortcutRefusal.unsupportedKey.message.contains("taken"))
        #expect(GlobalShortcutRefusal.takenBySystemSetting.message.contains("enabled shortcuts"))
    }

    @Test func aChordAlreadyAssignedToAnotherActionIsRefused_andReassigningTheSameActionIsNot() {
        let chord = KeyChord("j", [.control, .option, .command])
        #expect(GlobalShortcutPolicy.validate(chord, for: .next, assigned: [.playPause: chord]) == .alreadyAssigned(.playPause))
        #expect(GlobalShortcutPolicy.validate(chord, for: .playPause, assigned: [.playPause: chord]) == nil, "the action's own chord is not a conflict with itself")
        #expect(GlobalShortcutPolicy.validate(chord, for: .next, assigned: [:], systemTaken: [chord]) == .takenBySystemSetting)
    }

    @Test func assigningRegistersOnlyThatChordAndItRunsTheActionAndClearingUnregisters() {
        let (store, defaults) = store()
        let keys = RecordingHotKeys()
        var performed: [GlobalShortcutAction] = []
        let service = GlobalShortcutService(store: store, registrar: keys, perform: { performed.append($0) })
        let playPause = KeyChord("j", [.control, .option, .command]), next = KeyChord("right", [.control, .option])
        #expect(service.assign(playPause, to: .playPause) == nil && service.assign(next, to: .next) == nil)
        #expect(Set(keys.registrations.keys) == [playPause, next], "only the two recorded chords are registered")
        keys.press(playPause); keys.press(next)
        #expect(performed == [.playPause, .next])
        #expect(service.assign(playPause, to: .previous) == .alreadyAssigned(.playPause))
        #expect(store.assigned == [.playPause: playPause, .next: next], "a refused chord is not saved")
        service.clear(.playPause)
        #expect(Set(keys.registrations.keys) == [next] && store.chord(for: .playPause) == nil)
        service.stop()
        #expect(keys.registrations.isEmpty)
    }

    @Test func aChordTheSystemRefusesIsNotSavedAndAnAssignmentSurvivesARelaunch() {
        let (store, defaults) = store()
        let keys = RecordingHotKeys()
        let held = KeyChord("j", [.control, .option, .command]), good = KeyChord("k", [.control, .option, .command])
        keys.refuse = [held]
        let service = GlobalShortcutService(store: store, registrar: keys, perform: { _ in })
        #expect(service.assign(held, to: .playPause) == .couldNotRegister, "a refused registration says so, not that macOS lists the chord")
        #expect(store.chord(for: .playPause) == nil)
        #expect(service.assign(good, to: .showHide) == nil)
        let relaunched = RecordingHotKeys()
        GlobalShortcutService(store: GlobalShortcutStore(defaults: defaults), registrar: relaunched, perform: { _ in }).reapply()
        #expect(Set(relaunched.registrations.keys) == [good])
    }

    @Test func aStoredChordThatNoLongerValidatesIsIgnoredNotRegistered() {
        let (store, defaults) = store()
        store.set(KeyChord("c", .command), for: .next)   // a hand-edited preference
        #expect(store.chord(for: .next) == nil)
        let keys = RecordingHotKeys()
        GlobalShortcutService(store: store, registrar: keys, perform: { _ in }).reapply()
        #expect(keys.registrations.isEmpty)
    }

    @Test func theShellOwnsOneServiceAndTheRegistrarIsTheRecordingOneUnderTest() async throws {
        let rig = try await IntegrationRig.make(playing: false); defer { rig.cleanUp() }
        rig.shell.startIntegration()
        defer { rig.shell.stopIntegration() }
        #expect(rig.shell.globalShortcuts?.usesInProcessFake == true && rig.hotKeys.registerCalls == 0)
        let facilities = IntegrationFacilities.choose(isolated: true, hotKeys: { Issue.record("a system registrar was built for an isolated launch"); return RecordingHotKeys() },
                                                      notifications: { Issue.record("a system notification center was built for an isolated launch"); return RecordingNotifications() })
        #expect(facilities.hotKeys.isInProcessFake)
        #expect(facilities.notifications.isInProcessFake)
    }
}
