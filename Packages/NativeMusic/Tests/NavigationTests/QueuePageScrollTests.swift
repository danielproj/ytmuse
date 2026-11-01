import Testing
import AppKit
import SwiftUI
import Observation
import DesignSystem

/// UI run 1/2 (T09.5): after scrolling to the end of queue page 1, page 2 kept the old
/// offset, so its first row (the occurrence just moved there) was offscreen with a zero
/// frame. A new page must open at its first row.
@MainActor @Observable private final class PagedRows {
    var page = 0
    var rows: [QueueRow] { (0..<80).map { QueueRow(id: Self.ids[page * 80 + $0], title: "Synthetic queue row \(page * 80 + $0 + 1)", segment: "Test data", current: false) } }
    static let ids = (0..<160).map { _ in UUID() }
}
private struct Host: View {
    let model: PagedRows
    var body: some View { QueueList(rows: model.rows, page: model.page) { _ in } }
}
@Suite(.serialized) @MainActor struct QueuePageScrollTests {
    @Test func aNewQueuePageOpensAtItsFirstRow() async throws {
        let model = PagedRows()
        let controller = NSHostingController(rootView: Host(model: model))
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 420, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller; window.alphaValue = 0; window.ignoresMouseEvents = true; window.orderFrontRegardless()
        window.setContentSize(.init(width: 420, height: 480)) // Offscreen fixture only.
        defer { window.orderOut(nil); window.contentViewController = nil }
        func settle() async throws { for _ in 0..<15 { controller.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) } }
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        func table() throws -> NSScrollView { try #require(descendants(controller.view).compactMap { $0 as? NSScrollView }.first { ($0.documentView?.frame.height ?? 0) > 1000 }) }
        try await settle()
        let first = try table()
        let bottom = (first.documentView?.frame.height ?? 0) - first.contentView.bounds.height
        first.contentView.scroll(to: .init(x: 0, y: bottom)); first.reflectScrolledClipView(first.contentView)
        try await settle()
        #expect(first.contentView.bounds.minY > 1000, "fixture really scrolled page 1 to its end")
        model.page = 1
        try await settle()
        let second = try table()
        #expect(second.contentView.bounds.minY + second.contentInsets.top < 1, "page 2 must open at its first row")
    }
}
