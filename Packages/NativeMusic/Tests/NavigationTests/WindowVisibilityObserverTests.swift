import Testing
import AppKit
@testable import AppShell

/// W09-F1. A window that exists but has not been ordered on screen yet. `isVisible` is overridden so the test controls
/// exactly which signal accompanies the change: `orderOn(announcing:)` can flip it with no occlusion notification at all
/// (the order that left the tint and artwork gates closed), with only KVO, or silently.
@MainActor private final class StagedWindow: NSWindow {
    var onScreen = false
    override var isVisible: Bool { onScreen }
    override var isMiniaturized: Bool { false }
    override var occlusionState: NSWindow.OcclusionState { onScreen ? [.visible] : [] }
    func set(onScreen value: Bool, kvo: Bool) {
        if kvo { willChangeValue(forKey: "visible") }
        onScreen = value
        if kvo { didChangeValue(forKey: "visible") }
    }
}

@Suite(.serialized) @MainActor struct WindowVisibilityObserverTests {
    private final class Reports { var values: [Bool] = [] }
    private func attached() -> (StagedWindow, WindowVisibility.ObserverView, Reports) {
        let reports = Reports()
        let window = StagedWindow(contentRect: CGRect(x: -20000, y: -20000, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = container
        let observer = WindowVisibility.ObserverView(changed: { reports.values.append($0) })
        container.addSubview(observer)   // attaches before the window is ordered on screen
        return (window, observer, reports)
    }
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func attachingBeforeTheWindowIsOrderedOnScreenReportsHidden() async {
        let (window, _, reports) = attached()
        await settle { !reports.values.isEmpty }
        #expect(reports.values.last == false)
        window.close()
    }
    @Test func orderingOnScreenWithNoOcclusionNotificationOpensTheGate() async {
        let (window, _, reports) = attached()
        await settle { !reports.values.isEmpty }
        window.set(onScreen: true, kvo: true)   // no didChangeOcclusionState, key or main notification
        await settle { reports.values.last == true }
        #expect(reports.values.last == true, "a window ordered on screen after the observer attached must become visible")
        window.close()
    }
    @Test(arguments: [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeScreenNotification])
    func windowLevelNotificationsRereadTheState(name: Notification.Name) async {
        let (window, _, reports) = attached()
        await settle { !reports.values.isEmpty }
        window.set(onScreen: true, kvo: false)   // flipped silently; only the notification announces it
        NotificationCenter.default.post(name: name, object: window)
        await settle { reports.values.last == true }
        #expect(reports.values.last == true, "\(name.rawValue) must re-read the visibility")
        window.close()
    }
    @Test func aWindowThatLeavesTheScreenStopsDecorativeWork() async {
        let (window, _, reports) = attached()
        window.set(onScreen: true, kvo: false)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await settle { reports.values.last == true }
        window.set(onScreen: false, kvo: true)
        await settle { reports.values.last == false }
        #expect(reports.values.last == false, "MOTION04/WIN10: a hidden window must report hidden")
        window.close()
    }
    @Test func detachingTheViewReportsHiddenAndStopsObserving() async {
        let (window, observer, reports) = attached()
        window.set(onScreen: true, kvo: true)
        await settle { reports.values.last == true }
        observer.removeFromSuperview()
        await settle { reports.values.last == false }
        #expect(reports.values.last == false)
        let count = reports.values.count
        window.set(onScreen: false, kvo: true); window.set(onScreen: true, kvo: true)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(reports.values.count == count, "a detached observer ignores the old window")
        window.close()
    }
}
