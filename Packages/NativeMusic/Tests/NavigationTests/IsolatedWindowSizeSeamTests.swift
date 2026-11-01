#if DEBUG
import Testing
import Foundation
import AppKit
@testable import AppShell

@Suite @MainActor struct IsolatedWindowSizeSeamTests {
    @Test func theSeamIsIgnoredWhenRealStoresAreOptedIn() {
        let resolved = IsolatedWindowSizeSeam.resolve([IsolatedQAStorage.realStoresKey: "1", "YTMUSE_UI_TEST_WINDOW_SIZE": "840x560", "YTMUSE_UI_TEST_WINDOW_SIZES_NEXT": "800x520"])
        #expect(resolved.creation == nil && resolved.next.isEmpty)
    }
    @Test func sizesParseUnderIsolationAndMalformedListsAreRejectedWhole() {
        let ok = IsolatedWindowSizeSeam.resolve(["YTMUSE_UI_TEST_ISOLATED": "1", "YTMUSE_UI_TEST_WINDOW_SIZE": "840x560", "YTMUSE_UI_TEST_WINDOW_SIZES_NEXT": "800x520,1240x820"])
        #expect(ok.creation == CGSize(width: 840, height: 560) && ok.next == [CGSize(width: 800, height: 520), CGSize(width: 1240, height: 820)])
        for bad in ["840", "840x", "x560", "0x560", "840x560x2", "800x520,oops", "-1x5", "20000x10"] {
            #expect(IsolatedWindowSizeSeam.parse(bad).isEmpty, "\(bad)")
        }
        #expect(IsolatedWindowSizeSeam.resolve(["YTMUSE_UI_TEST_ISOLATED": "1", "YTMUSE_UI_TEST_WINDOW_SIZE": "840x560,900x600"]).creation == nil)
    }
    @Test func theNextSizeTargetsTheBrowserWindowNotAnAttachedSheet() async throws {
        let parent = NSWindow(contentRect: .init(x: -9000, y: -9000, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        parent.alphaValue = 0; parent.orderFrontRegardless()
        parent.beginSheet(sheet, completionHandler: nil)
        for _ in 0..<20 where sheet.sheetParent == nil { try await Task.sleep(for: .milliseconds(20)) }
        defer { parent.endSheet(sheet); parent.orderOut(nil) }
        #expect(sheet.sheetParent === parent)
        #expect(IsolatedWindowSizeSeam.target(key: sheet, main: parent) === parent)
        #expect(IsolatedWindowSizeSeam.target(key: parent, main: nil) === parent)
    }
    // MARK: Placement (W18-F1): a default-size isolated window stays clear of the right-hand notification column

    @Test func theOriginIsTheVisibleFramesTopLeftPlusTheMargin() {
        let visible = CGRect(x: 0, y: 0, width: 1728, height: 1079)       // a 1728-wide screen without its menu bar
        let size = CGSize(width: 1240, height: 820)
        let origin = IsolatedWindowSizeSeam.placementOrigin(windowSize: size, in: visible)
        #expect(origin == CGPoint(x: 24, y: 1079 - 24 - 820))
        let frame = CGRect(origin: origin, size: size)
        #expect(frame.minX == visible.minX + 24 && frame.maxY == visible.maxY - 24, "top-left")
        #expect(frame.maxX < 1368, "clear of the notification banner column that starts at x 1368 (it was 1484 when centred)")
        // A visible frame that does not start at the origin (a second display, a Dock on the left).
        let shifted = IsolatedWindowSizeSeam.placementOrigin(windowSize: size, in: CGRect(x: 80, y: 40, width: 1600, height: 1000), margin: 10)
        #expect(shifted == CGPoint(x: 90, y: 40 + 1000 - 10 - 820))
    }
    @Test func placementIsOnlyForIsolatedLaunches() {
        #expect(IsolatedWindowSizeSeam.placesWindows(["YTMUSE_UI_TEST_ISOLATED": "1"]))
        // It follows the same isolation decision as the size seam (a Debug launch is isolated unless it opts into the real stores).
        #expect(IsolatedWindowSizeSeam.placesWindows([:]) == IsolatedQAStorage.requested([:]))
        #expect(!IsolatedWindowSizeSeam.placesWindows([IsolatedQAStorage.realStoresKey: "1"]), "a launch that opted into the real stores is never moved")
    }
    @Test func arrangingPlacesTheWindowAtTheTopLeftAfterTheCreationSizeAndDoesNothingWhenNotAsked() throws {
        guard let visible = NSScreen.main?.visibleFrame else { return }       // no display: nothing to place on
        func make() -> NSWindow {
            let w = NSWindow(contentRect: CGRect(x: visible.midX - 300, y: visible.midY - 200, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            w.alphaValue = 0; return w
        }
        let placed = make(); defer { placed.orderOut(nil) }
        IsolatedWindowSizeSeam.arrange(placed, creation: CGSize(width: 700, height: 450), places: true)
        #expect(placed.frame.size.width >= 700 - 1 && abs(placed.frame.minX - (visible.minX + 24)) < 1 && abs(placed.frame.maxY - (visible.maxY - 24)) < 1, "\(placed.frame) in \(visible)")
        let untouched = make(); defer { untouched.orderOut(nil) }
        let before = untouched.frame
        IsolatedWindowSizeSeam.arrange(untouched, creation: nil, places: false)
        #expect(untouched.frame == before, "not isolated: no creation size and no placement, so the window is exactly where it was")
        let sizedOnly = make(); defer { sizedOnly.orderOut(nil) }
        IsolatedWindowSizeSeam.arrange(sizedOnly, creation: CGSize(width: 700, height: 450), places: false)
        #expect(abs(sizedOnly.frame.minX - before.minX) < 1, "a size alone keeps the window's own top-left, as before")
    }
    @Test func thePlacementIsDebugOnlyAndTheModifierIsAnOrdinaryNoOpOtherwise() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/IsolatedWindowSizeSeam.swift"), encoding: .utf8)
        let debugStart = try #require(source.range(of: "#if DEBUG")), debugEnd = try #require(source.range(of: "#endif"))
        let placement = try #require(source.range(of: "static func placementOrigin"))
        #expect(debugStart.lowerBound < placement.lowerBound && placement.lowerBound < debugEnd.lowerBound, "inside the Debug block, so absent from Release")
        #expect(source.contains("if IsolatedWindowSizeSeam.configured.creation != nil || IsolatedWindowSizeSeam.placesWindowsHere { self.background"))
    }
}
#endif
