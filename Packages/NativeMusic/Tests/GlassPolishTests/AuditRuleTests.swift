import Testing
import SwiftUI
@testable import DesignSystem

/// The audit rules on constructed frames, so a rule that stopped detecting anything would fail here before it could
/// pass every real surface vacuously. Each rule has a case that must be flagged and one that must stay silent.
@Suite struct LayoutAuditRuleTests {
    private func frame(_ name: String, _ rect: CGRect, group: String = "g", kind: AuditKind = .element, within: String? = nil, align: String? = nil, top: String? = nil, grid: Bool = false, scrolls: Bool = false) -> AuditFrame {
        AuditFrame(tag: AuditTag(name: name, group: group, kind: kind, container: within, alignLeading: align, alignTop: top, onGrid: grid, scrolls: scrolls), rect: rect)
    }
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    private func rules(_ frames: [AuditFrame], expecting: [String] = []) -> Set<AuditViolation.Rule> {
        Set(LayoutAudit.evaluate(frames, bounds: bounds, expecting: expecting).map(\.rule))
    }
    @Test func siblingsThatOverlapAreFlaggedAndTouchingOnesAreNot() {
        #expect(rules([frame("a", CGRect(x: 0, y: 0, width: 100, height: 40)), frame("b", CGRect(x: 90, y: 0, width: 100, height: 40))]) == [.overlap])
        #expect(rules([frame("a", CGRect(x: 0, y: 0, width: 100, height: 40)), frame("b", CGRect(x: 100, y: 0, width: 100, height: 40))]).isEmpty, "edge contact is not overlap")
        #expect(rules([frame("a", CGRect(x: 0, y: 0, width: 100, height: 40), group: "x"), frame("b", CGRect(x: 50, y: 0, width: 100, height: 40), group: "y")]).isEmpty, "different groups are not siblings")
    }
    @Test func aDeliberateLayerMayOverlap() {
        #expect(rules([frame("art", CGRect(x: 0, y: 0, width: 100, height: 100)), frame("badge", CGRect(x: 80, y: 80, width: 40, height: 40), kind: .layer)]).isEmpty)
    }
    @Test func containmentIsEnforced() {
        let container = frame("box", CGRect(x: 10, y: 10, width: 200, height: 100), group: "outer", kind: .region)
        #expect(!rules([container, frame("in", CGRect(x: 20, y: 20, width: 50, height: 20), within: "box")]).contains(.containment))
        #expect(rules([container, frame("out", CGRect(x: 180, y: 20, width: 50, height: 20), within: "box")]).contains(.containment))
        #expect(rules([frame("orphan", CGRect(x: 0, y: 0, width: 5, height: 5), within: "nowhere")]) == [.missing], "a container that was never reported is itself a finding")
    }
    @Test func scrollContentMayRunPastTheContainerVerticallyButNeverHorizontally() {
        let box = frame("box", CGRect(x: 0, y: 0, width: 200, height: 100), group: "outer", kind: .region)
        #expect(!rules([box, frame("tall", CGRect(x: 10, y: 10, width: 100, height: 900), within: "box", scrolls: true)]).contains(.containment))
        #expect(rules([box, frame("tallNotScrolling", CGRect(x: 10, y: 10, width: 100, height: 900), within: "box")]).contains(.containment), "control: the same frame fails when it does not scroll")
        #expect(rules([box, frame("wide", CGRect(x: 10, y: 10, width: 400, height: 50), within: "box", scrolls: true)]).contains(.containment))
    }
    @Test func aContainerMayBeNamedAsAnAlternative() {
        let panel = frame("panel", CGRect(x: 0, y: 0, width: 200, height: 100), group: "outer", kind: .region)
        #expect(rules([panel, frame("list", CGRect(x: 10, y: 10, width: 50, height: 50), within: "sheet|panel")]).isEmpty)
        #expect(rules([panel, frame("list", CGRect(x: 10, y: 10, width: 500, height: 50), within: "sheet|panel")]).contains(.containment))
        #expect(rules([frame("list", CGRect(x: 10, y: 10, width: 50, height: 50), within: "sheet|panel")]) == [.missing])
    }
    @Test func gridOffsetsAreMeasuredFromTheContainer() {
        let box = frame("box", CGRect(x: 10, y: 10, width: 200, height: 100), group: "outer", kind: .region)
        #expect(!rules([box, frame("on", CGRect(x: 18, y: 26, width: 50, height: 20), within: "box", grid: true)]).contains(.grid))
        #expect(rules([box, frame("off", CGRect(x: 15, y: 26, width: 50, height: 20), within: "box", grid: true)]).contains(.grid))
    }
    @Test func leadingEdgesMustCoincide() {
        #expect(rules([frame("a", CGRect(x: 24, y: 0, width: 50, height: 20), group: "1", align: "k"), frame("b", CGRect(x: 24.3, y: 50, width: 50, height: 20), group: "2", align: "k")]).isEmpty)
        #expect(rules([frame("a", CGRect(x: 24, y: 0, width: 50, height: 20), group: "1", align: "k"), frame("b", CGRect(x: 28, y: 50, width: 50, height: 20), group: "2", align: "k")]) == [.leadingAlignment])
    }
    @Test func outerMarginsMustBeEqualAndOnTheGrid() {
        let left = frame("sidebar", CGRect(x: 12, y: 12, width: 200, height: 400), group: "panels", kind: .region)
        let right = frame("detail", CGRect(x: 224, y: 12, width: 564, height: 400), group: "panels", kind: .region)
        #expect(rules([left, right]).isEmpty, "12 pt at both ends")
        let player = frame("player", CGRect(x: 8, y: 520, width: 784, height: 72), group: "panels", kind: .region)
        #expect(rules([left, right, player]).contains(.outerMargin), "the player sits 8 pt from the leading edge, the sidebar 12 pt")
        let skew = frame("skew", CGRect(x: 13, y: 520, width: 775, height: 72), group: "panels", kind: .region)
        #expect(rules([skew]).contains(.outerMargin), "13 pt is off the grid")
    }
    /// The critic's MA mutant: the player floats over both panels. Each region sits in its own group, so only a cross-group rule sees it.
    @Test func aRegionCoveringAnotherRegionIsFlaggedWhateverTheirGroups() {
        let sidebar = frame("sidebar", CGRect(x: 12, y: 12, width: 200, height: 400), group: "panels", kind: .region)
        let detail = frame("detail", CGRect(x: 224, y: 12, width: 564, height: 400), group: "panels", kind: .region)
        let separate = frame("player", CGRect(x: 12, y: 424, width: 776, height: 124), group: "outer", kind: .region)
        #expect(!rules([sidebar, detail, separate]).contains(.overlap), "control: the player below the panels is fine")
        let floating = frame("player", CGRect(x: 12, y: 300, width: 776, height: 124), group: "outer", kind: .region)
        #expect(rules([sidebar, detail, floating]).contains(.overlap), "the player over the panels is an occlusion")
        let layer = frame("overlay", CGRect(x: 12, y: 300, width: 776, height: 124), group: "outer", kind: .layer)
        #expect(!rules([sidebar, detail, layer]).contains(.overlap), "a declared layer (the expanded player) may cover")
    }
    @Test func aBandIsExcludedFromRegionsButNotHeldToTheOuterMargin() {
        let detail = frame("detail", CGRect(x: 224, y: 100, width: 564, height: 300), group: "panels", kind: .region)
        let band = frame("banner", CGRect(x: 224, y: 0, width: 576, height: 100), group: "chrome", kind: .band)
        #expect(rules([detail, band]).isEmpty, "flush with the window edge is fine for a band")
        let covering = frame("banner", CGRect(x: 224, y: 60, width: 576, height: 100), group: "chrome", kind: .band)
        #expect(rules([detail, covering]).contains(.overlap), "a band running into a panel is an overlap (the 4.5 pt minimum-size regression)")
    }
    @Test func aRegionOrBandThatLeavesTheWindowContentIsFlagged() {
        let band = frame("banner", CGRect(x: 224, y: -4.5, width: 576, height: 100), group: "chrome", kind: .band)
        #expect(rules([band]).contains(.containment), "a banner under the toolbar edge (the 4.5 pt minimum-size regression)")
        #expect(!rules([frame("banner", CGRect(x: 224, y: 0, width: 576, height: 100), group: "chrome", kind: .band)]).contains(.containment))
        #expect(rules([frame("detail", CGRect(x: 12, y: 12, width: 900, height: 100), group: "p", kind: .region)]).contains(.containment), "past the trailing edge")
    }
    @Test func pageTitlesMustShareOneTop() {
        #expect(rules([frame("a", CGRect(x: 24, y: 24, width: 80, height: 40), group: "1", top: "t"), frame("b", CGRect(x: 24, y: 24.4, width: 80, height: 40), group: "2", top: "t")]).isEmpty)
        #expect(rules([frame("a", CGRect(x: 24, y: 24, width: 80, height: 40), group: "1", top: "t"), frame("b", CGRect(x: 24, y: 45, width: 80, height: 40), group: "2", top: "t")]) == [.topAlignment])
    }
    @Test func theTopEdgeKeepsAGridAlignedMarginToo() {
        #expect(rules([frame("sheet panel", CGRect(x: 12, y: 12, width: 100, height: 100), group: "p", kind: .region)]).isEmpty)
        #expect(rules([frame("sheet panel", CGRect(x: 12, y: 13.5, width: 100, height: 100), group: "p", kind: .region)]).contains(.outerMargin))
    }
    @Test func emptyAndMissingFramesAreFindings() {
        #expect(rules([frame("zero", CGRect(x: 0, y: 0, width: 0, height: 20))]) == [.empty])
        #expect(rules([], expecting: ["player"]) == [.missing])
    }
}
