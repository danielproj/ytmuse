import Testing
import Foundation
import SwiftUI
import DesignSystem

/// The page and the queue/lyrics panel: the page narrows continuously with the reveal (it is laid out again at every frame of the motion), while the panel
/// keeps its width and slides in from the trailing edge.
@Suite struct TrailingPanelLayoutTests {
    private let bounds = CGRect(x: 0, y: 52, width: 1000, height: 700)

    @Test func closedThePageTakesEverythingAndThePanelWaitsPastTheTrailingEdge() {
        let frames = MusicTrailingPanelLayout.frames(in: bounds, reveal: 0, panelWidth: 420, rightToLeft: false)
        #expect(frames.page == bounds)
        #expect(frames.panel == CGRect(x: 1000, y: 52, width: 420, height: 700))
    }
    @Test func openThePageEndsWhereThePanelBegins() {
        let frames = MusicTrailingPanelLayout.frames(in: bounds, reveal: 1, panelWidth: 420, rightToLeft: false)
        #expect(frames.page == CGRect(x: 0, y: 52, width: 580, height: 700))
        #expect(frames.panel == CGRect(x: 580, y: 52, width: 420, height: 700))
    }
    @Test func midwayThePageIsAnIntermediateWidthAndThePanelKeepsItsOwn() {
        // The property that removes the jump: halfway through, the page is laid out at a width between the two, not at its final one.
        let frames = MusicTrailingPanelLayout.frames(in: bounds, reveal: 0.5, panelWidth: 420, rightToLeft: false)
        #expect(frames.page.width == 790)
        #expect(frames.panel?.width == 420, "the panel slides; it is never squeezed")
        #expect(frames.panel?.minX == frames.page.maxX, "no gap and no overlap between the page and the panel")
    }
    @Test func rightToLeftThePanelEntersFromTheLeftEdge() {
        let open = MusicTrailingPanelLayout.frames(in: bounds, reveal: 1, panelWidth: 420, rightToLeft: true)
        #expect(open.panel == CGRect(x: 0, y: 52, width: 420, height: 700))
        #expect(open.page == CGRect(x: 420, y: 52, width: 580, height: 700))
        let closed = MusicTrailingPanelLayout.frames(in: bounds, reveal: 0, panelWidth: 420, rightToLeft: true)
        #expect(closed.panel?.maxX == 0 && closed.page == bounds)
    }
    @Test func noPanelLeavesThePageAloneAndAnOvershootIsClamped() {
        #expect(MusicTrailingPanelLayout.frames(in: bounds, reveal: 1, panelWidth: nil, rightToLeft: false).page == bounds)
        // A spring can overshoot its target; the page never goes narrower than the open layout.
        #expect(MusicTrailingPanelLayout.frames(in: bounds, reveal: 1.08, panelWidth: 420, rightToLeft: false).page.width == 580)
    }
    @Test func theRevealIsTheAnimatedValue() {
        var layout = MusicTrailingPanelLayout(reveal: 0)
        layout.animatableData = 0.25
        #expect(layout.reveal == 0.25)
    }
}
