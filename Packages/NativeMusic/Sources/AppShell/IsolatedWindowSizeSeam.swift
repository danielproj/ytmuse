import AppKit
import SwiftUI

#if DEBUG

/// Debug-only, isolated-QA-only window-size seam (parent decision W09-T09.2): XCUITest's
/// synthesized edge drags do not engage live resize on this macOS, so UI tests reach a
/// size through an ordinary AppKit frame change instead. The seam never clamps: the
/// window's own minimum-size constraints (MainWindowContract) decide the final frame,
/// exactly as for a user resize. Ignored unless QA isolation is active; absent from Release.
///   YTMUSE_UI_TEST_WINDOW_SIZE=WxH          applied to each main window at creation
///   YTMUSE_UI_TEST_WINDOW_SIZES_NEXT=WxH,…  applied in order by "Apply Next Test Window Size"
@MainActor enum IsolatedWindowSizeSeam {
    static let creationKey = "YTMUSE_UI_TEST_WINDOW_SIZE"
    static let nextKey = "YTMUSE_UI_TEST_WINDOW_SIZES_NEXT"
    static func parse(_ value: String?) -> [CGSize] {
        guard let value, !value.isEmpty else { return [] }
        let sizes = value.split(separator: ",").map { part -> CGSize? in
            let pair = part.split(separator: "x")
            guard pair.count == 2, let w = Int(pair[0]), let h = Int(pair[1]), (1...10_000).contains(w), (1...10_000).contains(h) else { return nil }
            return CGSize(width: w, height: h)
        }
        return sizes.contains(nil) ? [] : sizes.compactMap { $0 }
    }
    static func resolve(_ environment: [String: String]) -> (creation: CGSize?, next: [CGSize]) {
        guard IsolatedQAStorage.requested(environment) else { return (nil, []) }
        let creation = parse(environment[creationKey])
        return (creation.count == 1 ? creation[0] : nil, parse(environment[nextKey]))
    }
    static let configured = resolve(ProcessInfo.processInfo.environment)
    /// W18-F1: where an isolated main window goes. The window used to open centred, which on a 1728-wide screen put its right edge at 1484 and the
    /// toolbar's Lyrics button under the account holder's notification banner column (x 1368-1712, y 44-230), where XCUITest cannot compute a hit point.
    /// Under QA isolation every new main window's top-left is the visible frame's top-left plus a small margin, so a default-size window stays clear of
    /// the right-hand column. A no-op without isolation (and, like the whole seam, absent from Release).
    static let placementMargin: CGFloat = 24
    static func placesWindows(_ environment: [String: String]) -> Bool { IsolatedQAStorage.requested(environment) }
    static let placesWindowsHere = placesWindows(ProcessInfo.processInfo.environment)
    static func placementOrigin(windowSize: CGSize, in visible: CGRect, margin: CGFloat = placementMargin) -> CGPoint {
        CGPoint(x: visible.minX + margin, y: visible.maxY - margin - windowSize.height)
    }
    static func place(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        window.setFrameOrigin(placementOrigin(windowSize: window.frame.size, in: visible))
    }
    /// What a new main window gets: the creation size (keeping its top-left), then the placement. Nothing at all unless asked.
    static func arrange(_ window: NSWindow, creation: CGSize?, places: Bool) {
        if let creation { apply(creation, to: window) }
        if places { place(window) }
    }
    static var hasNext: Bool { !configured.next.isEmpty }
    private static var nextIndex = 0
    /// Keeps the window's top-left corner; AppKit enforces the minimum.
    static func apply(_ size: CGSize, to window: NSWindow) {
        let frame = window.frame
        window.setFrame(CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
    static func applyNext() {
        guard hasNext, let window = target(key: NSApp.keyWindow, main: NSApp.mainWindow) else { return }
        apply(configured.next[nextIndex % configured.next.count], to: window); nextIndex += 1
    }
    /// The browser window, never an attached sheet: with the compact panel sheet open the
    /// sheet is key, but a user's edge drag resizes its parent window.
    static func target(key: NSWindow?, main: NSWindow?) -> NSWindow? {
        let candidate = key ?? main
        return candidate?.sheetParent ?? candidate
    }
}
/// Applies the creation size and the placement once per main window.
struct IsolatedWindowCreationSize: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
    final class Probe: NSView {
        private var applied = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !applied, let window else { return }
            applied = true
            DispatchQueue.main.async { IsolatedWindowSizeSeam.arrange(window, creation: IsolatedWindowSizeSeam.configured.creation, places: IsolatedWindowSizeSeam.placesWindowsHere) }
        }
    }
}
#endif

extension View {
    /// Main windows only. A no-op in Release and whenever QA isolation is not active.
    @ViewBuilder func isolatedWindowSize() -> some View {
        #if DEBUG
        if IsolatedWindowSizeSeam.configured.creation != nil || IsolatedWindowSizeSeam.placesWindowsHere { self.background(IsolatedWindowCreationSize().frame(width: 0, height: 0)) } else { self }
        #else
        self
        #endif
    }
}
