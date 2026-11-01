import Testing
import Foundation
import AppKit
import SwiftUI
@testable import AppShell

private final class ScrollFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
struct ScrollFixtureCase: Sendable { let query: String; let width: Double; let height: Double; let requested: Double; var lateGrowth = false }
// Scroll restoration lives in the generic collection page. W12's Library replaced that page when the development Library is enabled
// (YTMUSE_UI_DEVELOPMENT_LIBRARY=1), so this suite runs against the page it measures: development data WITHOUT the library flag.
// (V02 rework 1: the condition makes that explicit; before it the suite aborted on a page that no longer exists under the library flag.)
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1" && ProcessInfo.processInfo.environment["YTMUSE_UI_DEVELOPMENT_LIBRARY"] != "1"))
@MainActor struct ScrollViewIntegrationTests {
    @Test(arguments: [ScrollFixtureCase(query: "1", width: 1663, height: 1084, requested: 205), ScrollFixtureCase(query: "1", width: 1240, height: 820, requested: 250), ScrollFixtureCase(query: "", width: 1240, height: 820, requested: 320), ScrollFixtureCase(query: "1", width: 1663, height: 1084, requested: 160, lateGrowth: true)])
    func realRootBackRestoresMeasuredOffset(c: ScrollFixtureCase) async throws {
        let accounts = LocalAccountBootstrap(); await accounts.load()
        var session = BrowserSession(); session.owner = accounts.windowAuthority.context.account.map(WindowOwner.init); session.historyEpoch = await accounts.windowStore?.currentEpoch
        session.open(.library); session.current.selection = ["development-0"]; if c.lateGrowth { session.current.filter = "Downloaded only" }
        let navigation = BrowserNavigation(session: session)
        let root = LocalAccountRoot(accounts: accounts, navigation: navigation).modifier(MainWindowContract(state: MainWindowContractState()))
        let controller = NSHostingController(rootView: root); controller.sizingOptions = [.minSize]; controller.sceneBridgingOptions = [.toolbars, .title]
        let window = ScrollFixtureWindow(contentRect: CGRect(x: -24000, y: -24000, width: c.width, height: c.height), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbarStyle = .unified; window.contentViewController = controller; window.alphaValue = 0; window.ignoresMouseEvents = true; window.orderFrontRegardless()
        window.setFrame(CGRect(x: -24000, y: -24000, width: c.width, height: c.height), display: true) // Invisible host setup, not native acceptance.
        defer { window.orderOut(nil); window.contentViewController = nil }
        func settle(_ count: Int) async throws { for _ in 0..<count { controller.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) } }
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        func destinationScroll() throws -> NSScrollView {
            try #require(descendants(controller.view).compactMap { $0 as? NSScrollView }.first { let r = $0.convert($0.bounds, to: nil); return r.minX > 220 && r.width > 300 && ($0.documentView?.frame.height ?? 0) > 500 })
        }
        func offset(_ scroll: NSScrollView) -> Double { scroll.contentView.bounds.minY + scroll.contentInsets.top }
        func dump(_ label: String, _ scroll: NSScrollView) {
            print("REAL_SCROLL \(label) query=\(c.query) window=\(window.frame.size) stored=\(navigation.session.current.scrollOffset) clip=\(scroll.contentView.bounds) doc=\(String(describing: scroll.documentView?.frame)) insets=\(scroll.contentInsets) visible=\(scroll.documentVisibleRect) frameInWindow=\(scroll.convert(scroll.bounds,to:nil))")
        }
        try await settle(30)
        if c.lateGrowth {
            let empty = descendants(controller.view).compactMap { $0 as? NSScrollView }.first { $0.convert($0.bounds,to:nil).minX > 220 && $0.frame.width > 300 && ($0.documentView?.frame.height ?? 0) > 100 }
            print("REAL_GROWTH before=\(String(describing: empty?.documentView?.frame.height))")
            navigation.session.current.filter = "All"
        }
        navigation.session.current.query = c.query; try await settle(30)
        let scroll = try destinationScroll(); dump("initial", scroll)
        let initialContent = scroll.documentView?.frame.height ?? -1
        scroll.contentView.scroll(to: NSPoint(x: 0, y: c.requested)); scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(30); dump("save", scroll)
        let saved = offset(scroll), savedContent = scroll.documentView?.frame.height ?? -1
        #expect(abs(initialContent - savedContent) < 1, "The same bounded filtered content must not acquire phantom height merely by realizing rows")
        #expect(saved > 50 && abs(navigation.session.current.scrollOffset - saved) < 0.5)
        navigation.open(.downloads); navigation.session.current.query = "2"; navigation.session.current.filter = "Downloaded only"
        try await settle(30)
        navigation.back()
        var samples: [[String: Double]] = []
        for _ in 0..<125 {
            try await settle(2)
            let current = try destinationScroll()
            samples.append(["live": offset(current), "stored": navigation.session.current.scrollOffset, "content": current.documentView?.frame.height ?? -1, "inset": current.contentInsets.top])
        }
        let restored = try destinationScroll(); dump("Back", restored)
        print("REAL_SCROLL_SAMPLES saved=\(saved) samples=\(samples)")
        #expect(navigation.session.current.query == c.query && navigation.session.current.filter == "All" && navigation.session.current.selection == ["development-0"])
        #expect(abs((restored.documentView?.frame.height ?? -1) - savedContent) < 1, "Same query/filter/viewport must preserve the measured document extent across reappearance")
        #expect(abs(offset(restored) - saved) < 12, "Measure actual native scroll geometry after real view disappearance/recreation, never the issued policy command")
        #expect(abs(navigation.session.current.scrollOffset - offset(restored)) < 0.5)
        // A later independent native offset must not be pinned by restoration.
        let changed = saved / 2
        restored.contentView.scroll(to: NSPoint(x: 0, y: changed)); restored.reflectScrolledClipView(restored.contentView)
        try await settle(20)
        #expect(abs(offset(restored) - changed) < 0.5 && abs(navigation.session.current.scrollOffset - changed) < 0.5)
        navigation.forward(); try await settle(20)
        #expect(navigation.session.current.destination == .downloads && navigation.session.current.query == "2" && navigation.session.current.filter == "Downloaded only")
        // Supersede an actually appeared pending destination. Its expiry cannot save
        // its target into the newer empty Downloads entry.
        navigation.open(.search); navigation.session.current.query = "1"; navigation.session.current.scrollOffset = 160
        try await settle(2)
        navigation.open(.downloads); navigation.session.current.query = "2"; navigation.session.current.filter = "Downloaded only"
        try await settle(110)
        #expect(navigation.session.current.destination == .downloads && navigation.session.current.scrollOffset == 0)
        window.orderOut(nil); window.contentViewController = nil; await accounts.shutdown()
    }
}
