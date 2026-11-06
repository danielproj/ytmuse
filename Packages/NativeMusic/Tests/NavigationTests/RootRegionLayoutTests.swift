import Testing
import Foundation
import AppKit
import SwiftUI
import Observation
import DesignSystem
import Domain
@testable import AppShell

@MainActor @Observable private final class Frames { var values: [String: CGRect] = [:] }
private struct MeasuredFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}
private final class OffscreenContractWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
struct RootMode: Sendable { let qa: Bool; let banner: Bool }
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct RootRegionLayoutTests {
    @Test func publicWindowContractTracksToolbarAndKeepsOwnership() async throws {
        let a = MainWindowContractState(), b = MainWindowContractState()
        func host(_ state: MainWindowContractState) -> (NSHostingController<some View>, NSWindow) {
            let controller = NSHostingController(rootView: Color.clear.modifier(MainWindowContract(state: state)))
            controller.sizingOptions = [.minSize]
            let window = OffscreenContractWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1240, height: 820), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.toolbar = NSToolbar(identifier: NSToolbar.Identifier(UUID().uuidString)); window.toolbarStyle = .unified
            window.contentViewController = controller; window.ignoresMouseEvents = true; window.alphaValue = 0; window.orderFrontRegardless()
            return (controller, window)
        }
        let (ca, wa) = host(a), (cb, wb) = host(b)
        defer { wa.orderOut(nil); wb.orderOut(nil); wa.contentViewController = nil; wb.contentViewController = nil }
        for _ in 0..<25 { ca.view.layoutSubtreeIfNeeded(); cb.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let bBefore = b.snapshot, aChrome = a.chrome
        wa.toolbar?.isVisible = false // Only this test-owned toolbar; no personalization or OS setting.
        for _ in 0..<25 { ca.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        #expect(a.chrome.height <= aChrome.height)
        #expect(a.chrome.height == wa.frame.height - wa.contentLayoutRect.height)
        #expect(wa.minSize == NSSize(width: 840, height: 560) && wb.minSize == NSSize(width: 840, height: 560))
        #expect(b.snapshot == bBefore && a.snapshot["window"] != b.snapshot["window"], "One window's toolbar update cannot rebind another owner's metrics")
        print("WINDOW_OWNERSHIP a=\(a.snapshot) b=\(b.snapshot)")
    }
    @Test(arguments: [1240.0, 1160.0, 840.0], [RootMode(qa: true, banner: false), RootMode(qa: false, banner: false), RootMode(qa: true, banner: true), RootMode(qa: false, banner: true)])
    func realisticToolbarOuterContract(width: Double, mode: RootMode) async throws {
        let accounts = LocalAccountBootstrap(), panels = AdaptivePanelPresentation<BrowserShell.TrailingPanel>(), frames = Frames()
        await accounts.load(); #expect(!accounts.failure && accounts.developmentQueue != nil)
        var session = BrowserSession(); session.owner = accounts.windowAuthority.context.account.map(WindowOwner.init); session.historyEpoch = await accounts.windowStore?.currentEpoch
        if mode.banner { session.open(.library); accounts.playback.error = String(repeating: "Disposable long error. ", count: 20); accounts.windowAuthority.historyUnavailable() }
        let navigation = BrowserNavigation(session: session)
        let contract = MainWindowContractState()
        // The YTMuse style's geometry (its sidebar panel in the system column); Standard is the default since APPEARANCE-STYLE, so it is stated.
        let root = LocalAccountRoot(accounts: accounts, panels: panels, navigation: navigation, showsQAReadouts: mode.qa).modifier(MainWindowContract(state: contract))
            .environment(\.musicAppStyle, .ytmuse)
            .overlayPreferenceValue(BrowserRegionAnchors.self) { anchors in GeometryReader { g in
                let origin = g.frame(in: .global).origin
                Color.clear.preference(key: MeasuredFrames.self, value: anchors.mapValues { g[$0].offsetBy(dx: origin.x, dy: origin.y) })
            }}.onPreferenceChange(MeasuredFrames.self) { frames.values = $0 }
        let controller = NSHostingController(rootView: root); controller.sizingOptions = [.minSize]; controller.sceneBridgingOptions = [.toolbars, .title]
        let height = width == 840 ? 560.0 : 820.0
        let window = OffscreenContractWindow(contentRect: CGRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "YTMuse"; window.toolbarStyle = .unified; window.contentViewController = controller; window.ignoresMouseEvents = true; window.alphaValue = 0; window.orderFrontRegardless()
        window.setFrame(CGRect(x: -20000, y: -20000, width: width, height: height), display: true) // Offscreen fixture only, never acceptance.
        defer { window.orderOut(nil); window.contentViewController = nil }
        for _ in 0..<20 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        panels.selection = .queue
        for _ in 0..<50 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let edge = window.frame.height - window.contentLayoutRect.height
        let minimumOuter = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
        print("ROOT width=\(width) qa=\(mode.qa) banner=\(mode.banner) outer=\(window.frame) layout=\(window.contentLayoutRect) safeTop=\(controller.view.safeAreaInsets.top) min=\(window.minSize) contentMin=\(window.contentMinSize) minimumOuter=\(minimumOuter) toolbarItems=\(window.toolbar?.items.count ?? 0) frames=\(frames.values)")
        #expect((window.toolbar?.items.count ?? 0) > 0)
        #expect(abs(minimumOuter.width - 840) <= 1 && abs(minimumOuter.height - 560) <= 1)
        #expect(abs(window.minSize.width - 840) <= 1 && abs(window.minSize.height - 560) <= 1)
        #expect(abs(window.frame.width - width) <= 1 && abs(window.frame.height - height) <= 1)
        let player = try #require(frames.values["player"]), detail = try #require(frames.values["detail"]), title = try #require(frames.values["destinationTitle"])
        var chromeBottom = edge
        // Private class names are test/repro diagnostics ONLY, never product behavior.
        func census(_ view: NSView) {
            let r = view.convert(view.bounds, to: nil), top = window.frame.height - r.maxY, name = String(describing: type(of: view))
            if (name.contains("TitlebarBackground") || name.contains("ScrollPocket")), !view.isHidden, view.alphaValue > 0, r.minX >= 200, r.width > 300, r.height > 0, r.height <= edge + 2, top < 300 {
                print("CHROME \(name) top=\(top) bottom=\(top + r.height) rect=\(r)")
                chromeBottom = max(chromeBottom, top + r.height)
                #expect(top + r.height <= edge + 1, "Detail chrome must coincide with the actual toolbar edge")
            }
            for child in view.subviews { census(child) }
        }
        if let theme = window.contentView?.superview { census(theme) }
        #expect(detail.maxY <= player.minY + 1)
        // Actual sidebar table geometry and native bottom scroll-edge occlusion.
        // Private pocket class names are test diagnostics ONLY; never product logic.
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        func topRect(_ v: NSView, _ rect: CGRect) -> CGRect {
            let r = v.convert(rect, to: nil)
            return CGRect(x: r.minX, y: window.frame.height - r.maxY, width: r.width, height: r.height)
        }
        let views = descendants(try #require(window.contentView?.superview))
        let sidebar = try #require(frames.values["sidebar"])
        #expect(sidebar.minX >= -1 && sidebar.maxX <= player.minX + 1)
        #expect(sidebar.minY >= edge - 1 && sidebar.maxY <= height + 1 && sidebar.height > 0)
        let tables = views.compactMap { $0 as? NSTableView }.filter { topRect($0, $0.bounds).maxX < 300 }
        #expect(tables.count == 1, "Real sidebar table must be inspected, not an empty census")
        for table in tables {
            let scroll = try #require(table.enclosingScrollView)
            let clip = topRect(scroll.contentView, scroll.contentView.bounds)
            #expect(clip.width > 0 && clip.height > 0, "Inspect a real, nonempty sidebar viewport")
            #expect(clip.minX >= sidebar.minX - 1 && clip.maxX <= sidebar.maxX + 1)
            #expect(clip.minY >= sidebar.minY - 1 && clip.maxY <= sidebar.maxY + 1)
            #expect(table.numberOfRows >= 10)
            table.scrollRowToVisible(table.numberOfRows - 1)
            for _ in 0..<15 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let last = topRect(table, table.rect(ofRow: table.numberOfRows - 1))
            let afterClip = topRect(scroll.contentView, scroll.contentView.bounds)
            let afterSidebar = try #require(frames.values["sidebar"])
            print("SIDEBAR_AFTER_SCROLL last=\(last) clip=\(afterClip) sidebar=\(afterSidebar)")
            #expect(last.height > 0 && last.minY >= afterClip.minY - 1 && last.maxY <= afterClip.maxY + 1,
                    "Last navigation row must be fully visible after real table scrolling")
            #expect(last.maxY <= afterSidebar.maxY + 1 && last.maxX <= afterSidebar.maxX + 1)
            let bottomPockets = views.filter {
                let r = topRect($0, $0.bounds)
                return String(describing: type(of: $0)).contains("ScrollPocket") && !$0.isHidden && $0.alphaValue > 0
                    && r.minX < 300 && r.height > 0 && r.minY >= afterClip.midY
            }.map { topRect($0, $0.bounds) }
            #expect(!bottomPockets.contains { $0.intersection(last).height > 1 }, "Native bottom chrome must not cover the last navigation row")
        }
        var headerBottom = edge
        if let banner = frames.values["banner"] { headerBottom = max(headerBottom, banner.maxY) }
        if let qa = frames.values["debugRow"] { headerBottom = max(headerBottom, qa.maxY) }
        #expect(title.minY >= max(headerBottom, chromeBottom) - 1 && title.maxY <= player.minY + 1)
        #expect((frames.values["debugRow"] != nil) == mode.qa)
        #expect((frames.values["banner"] != nil) == mode.banner)
        for key in ["banner", "debugRow", "destinationTitle", "collectionQuery", "collectionFilter", "panelPicker", "queueFooter", "nextPage", "player"] {
            guard let r = frames.values[key] else { continue }
            #expect(r.minX >= -1 && r.maxX <= width + 1 && r.minY >= chromeBottom - 1 && r.maxY <= height + 1, "Required control clips chrome/window: \(key)")
            if ["collectionQuery", "collectionFilter", "panelPicker"].contains(key) { #expect(r.minY >= headerBottom - 1 && r.maxY <= player.minY + 1) }
        }
        if width >= 1120 {
            let panel = try #require(frames.values["panel"]), list = try #require(frames.values["queueList"]), footer = try #require(frames.values["queueFooter"]), next = try #require(frames.values["nextPage"])
            #expect(panel.maxY <= player.minY + 1 && list.maxY <= footer.minY + 1 && footer.maxY <= player.minY + 1 && next.maxY <= player.minY + 1)
        } else { #expect(!panels.allowsInline && panels.selection == .queue) }
        if mode.banner {
            func fields(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap(fields) }
            let field = try #require(fields(controller.view).first { $0.isEditable && !$0.isHidden }); #expect(window.makeFirstResponder(field)); field.stringValue = "root editor"
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            // V02 rework 1: the first editable field is the current page's query. With the development Library (W12's collections) that field edits the
            // collection model's own query, not the window session's (the generic collection page W12 replaced did). Either way typing reaches the page
            // under the banner; only the state it must land in follows the page.
            if accounts.library.development { #expect(accounts.library.model.query == "root editor") } else { #expect(navigation.session.current.query == "root editor") }
        }
        if width == 840 {
            window.setContentSize(NSSize(width: 800, height: 520)) // Test-owned host only: measure constraint enforcement, not acceptance.
            for _ in 0..<15 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            print("CLAMP requestedContent800x520 outer=\(window.frame.size) contentLayout=\(window.contentLayoutRect)")
            #expect(window.frame.width >= 840 && window.frame.width <= 860 && window.frame.height >= 560 && window.frame.height <= 580)
        }
        window.orderOut(nil); window.contentViewController = nil; await accounts.shutdown()
    }
}
