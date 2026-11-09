import AppKit
import Foundation
import Testing
import WebKit
@testable import Playback

/// The hidden player's page must be laid out wider than YouTube Music's compact-player breakpoint (`max-width: 615px`) whatever its frame:
/// the signed-in page drops Shuffle, Repeat and the Like/Dislike group below it, and the app reads all four from them. Real WebKit, a local
/// blank page and no network: what is measured is the width the page's own media queries see.
@MainActor @Suite struct WebMusicLayoutWidthTests {
    @Test func zoomKeepsNarrowFramesAtTheMinimumLayoutWidth() {
        #expect(NonInteractiveWebView.pageZoom(forWidth: 480) == 0.6)
        #expect(NonInteractiveWebView.pageZoom(forWidth: 800) == 1)
        #expect(NonInteractiveWebView.pageZoom(forWidth: 1600) == 1)
        #expect(NonInteractiveWebView.pageZoom(forWidth: 0) == 1)
        #expect(NonInteractiveWebView.pageZoom(forWidth: .nan) == 1)
        #expect(NonInteractiveWebView.minimumLayoutWidth > 615)
    }

    @Test func thePageNeverSeesTheCompactPlayerBreakpoint() async throws {
        let view = NonInteractiveWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 360), configuration: WKWebViewConfiguration())
        view.pageZoom = NonInteractiveWebView.pageZoom(forWidth: view.frame.width)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil }
        view.loadHTMLString("<!doctype html><html><head><meta name=viewport content=\"width=device-width\"></head><body></body></html>", baseURL: nil)
        for _ in 0..<200 where view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(25)) }

        func measure() async throws -> (width: Double, compact: Bool) {
            let value = try await view.callAsyncJavaScript("return [window.innerWidth, window.matchMedia('(max-width: 615px)').matches];",
                                                           arguments: [:], in: nil, contentWorld: .page)
            let pair = try #require(value as? [Any])
            return (try #require((pair[0] as? NSNumber)?.doubleValue), try #require(pair[1] as? Bool))
        }
        // The hidden page's own frame (480 pt): laid out at the minimum width, not as a compact player.
        var seen = try await measure()
        #expect(seen.width >= 616 && !seen.compact, "480 pt frame laid out at \(seen.width) px")
        // A narrow inline video surface, through the frame changes AppKit makes when the view is moved into a host.
        view.setFrameSize(NSSize(width: 320, height: 180))
        seen = try await measure()
        #expect(seen.width >= 616 && !seen.compact, "320 pt frame laid out at \(seen.width) px")
        // A wide window is left at its own size.
        view.setFrameSize(NSSize(width: 1200, height: 700))
        seen = try await measure()
        #expect(view.pageZoom == 1 && seen.width >= 1199 && !seen.compact, "1200 pt frame laid out at \(seen.width) px")
    }
}
