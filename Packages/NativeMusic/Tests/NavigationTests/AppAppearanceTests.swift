import AppKit
import Domain
import Testing
@testable import AppShell

@Suite @MainActor struct AppAppearanceTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func reaches(_ name: NSAppearance.Name?, window: NSWindow) async -> Bool {
        for _ in 0..<100 {
            if window.appearance?.name == name { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test func attachmentAndPreferenceChangesUpdateOnlyTheHostedWindow() async {
        let first = window(), other = window()
        defer { first.close(); other.close() }
        let view = AppAppearanceWindowBridge.Probe(preference: .light)
        first.contentView = view
        #expect(first.appearance?.name == .aqua)
        #expect(other.appearance == nil)
        view.configure(preference: .dark)
        #expect(await reaches(.darkAqua, window: first))
        #expect(other.appearance == nil)
        view.configure(preference: .system)
        #expect(await reaches(nil, window: first), "System follows macOS again instead of retaining the previous override")
    }

    @Test func reattachmentFollowsTheCurrentPreference() async {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        let view = AppAppearanceWindowBridge.Probe(preference: .dark)
        first.contentView = view
        #expect(first.appearance?.name == .darkAqua)
        view.configure(preference: .light)
        #expect(await reaches(.aqua, window: first))
        first.contentView = nil
        second.contentView = view
        #expect(second.appearance?.name == .aqua)
        #expect(view.hitTest(.zero) == nil)
    }
}
