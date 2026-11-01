#if DEBUG
import Testing
import AppKit
@testable import AppShell

/// UI run 1 found `NSWindow Frame …` and `NSSplitView Subview Frames …` written to the
/// real preferences domain. Under isolation those writes are disabled at the class level.
@Suite(.serialized) @MainActor struct IsolatedWindowPersistenceTests {
    @Test func windowsAndSplitViewsCannotAutosaveOrRestoreOnceInstalled() {
        IsolatedWindowPersistence.install()
        let name = "ytmuse-isolation-test-" + UUID().uuidString
        final class SubclassWindow: NSWindow {}
        for window in [NSWindow(contentRect: .init(x: -9000, y: -9000, width: 200, height: 120), styleMask: [.titled, .resizable], backing: .buffered, defer: true),
                       SubclassWindow(contentRect: .init(x: -9000, y: -9000, width: 200, height: 120), styleMask: [.titled, .resizable], backing: .buffered, defer: true)] {
            #expect(window.setFrameAutosaveName(name))
            #expect(window.frameAutosaveName.isEmpty, "no autosave name is ever adopted")
            window.setFrame(.init(x: -9100, y: -9100, width: 260, height: 180), display: false)
            window.saveFrame(usingName: name)
            window.isRestorable = true
            #expect(!window.isRestorable)
        }
        #expect(UserDefaults.standard.object(forKey: "NSWindow Frame " + name) == nil)
        let split = NSSplitView(frame: .init(x: 0, y: 0, width: 300, height: 200))
        split.addArrangedSubview(NSView()); split.addArrangedSubview(NSView())
        split.autosaveName = name
        #expect(split.autosaveName == nil)
        split.setPosition(120, ofDividerAt: 0)
        #expect(UserDefaults.standard.dictionaryRepresentation().keys.allSatisfy { !$0.contains(name) })
    }
}
#endif
