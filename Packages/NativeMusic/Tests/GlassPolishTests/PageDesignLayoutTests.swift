import SwiftUI
import Testing
@testable import DesignSystem

/// Pure production planning only: no host, renderer, app, or accessibility client.
@Suite struct PageDesignLayoutTests {
    private func hero(_ width: CGFloat?) -> MusicPageLayoutPlan {
        .hero(width: width, spacing: 24, artwork: CGSize(width: 200, height: 200)) { proposed in
            let width = max(120, min(proposed ?? 300, 300))
            return CGSize(width: width, height: width < 300 ? 120 : 80)
        }
    }

    @Test func heroProbesReturnFiniteContentContainingSizes() {
        let cases: [(CGFloat?, CGSize)] = [
            (nil, CGSize(width: 524, height: 304)),
            (.infinity, CGSize(width: 524, height: 304)),
            (0, CGSize(width: 200, height: 344)),
            (100, CGSize(width: 200, height: 344)),
            (180, CGSize(width: 200, height: 344)),
            (400, CGSize(width: 400, height: 304)),
            (540, CGSize(width: 540, height: 200)),
            (800, CGSize(width: 800, height: 200))
        ]
        for (proposal, expected) in cases {
            let plan = hero(proposal)
            #expect(plan.size == expected)
            #expect(plan.size.width.isFinite && plan.size.height.isFinite)
            #expect(plan.frames.count == 2)
            for frame in plan.frames { #expect(CGRect(origin: .zero, size: plan.size).contains(frame)) }
            #expect(!plan.frames[0].intersects(plan.frames[1]))
        }
    }

    @Test func heroStacksAnUncompressibleDetailAndRetainsItsMeasurementProposal() {
        let plan = MusicPageLayoutPlan.hero(width: 600, spacing: 24, artwork: CGSize(width: 200, height: 200)) { _ in
            CGSize(width: 900, height: 60)
        }
        #expect(plan.size == CGSize(width: 900, height: 284))
        #expect(plan.frames[1] == CGRect(x: 0, y: 224, width: 900, height: 60))
        #expect(plan.widths[0] == nil && plan.widths[1] == 600)
    }

    @Test func heroLeadingEdgesReflectForBothCompositionsWithoutReorderingChildren() {
        for width: CGFloat in [400, 800] {
            let plan = hero(width)
            let bounds = CGRect(x: 37, y: 19, width: plan.size.width, height: plan.size.height)
            for index in plan.frames.indices {
                let ltr = plan.leadingPoint(at: index, in: bounds, direction: .leftToRight)
                let rtl = plan.leadingPoint(at: index, in: bounds, direction: .rightToLeft)
                #expect(ltr.x + rtl.x == bounds.minX + bounds.maxX)
                #expect(ltr.y == rtl.y)
            }
            #expect(plan.leadingPoint(at: 0, in: bounds, direction: .leftToRight) == CGPoint(x: 37, y: 19))
            #expect(plan.leadingPoint(at: 0, in: bounds, direction: .rightToLeft) == CGPoint(x: bounds.maxX, y: 19))
            let detailLTR = plan.leadingPoint(at: 1, in: bounds, direction: .leftToRight)
            let detailRTL = plan.leadingPoint(at: 1, in: bounds, direction: .rightToLeft)
            #expect(detailLTR == (width == 400 ? CGPoint(x: 37, y: 243) : CGPoint(x: 261, y: 19)))
            #expect(detailRTL == (width == 400 ? CGPoint(x: 437, y: 243) : CGPoint(x: 613, y: 19)))
        }
    }

    private let controls = [CGSize(width: 80, height: 30), CGSize(width: 90, height: 40), CGSize(width: 100, height: 20)]
    private func actions(_ width: CGFloat?) -> MusicPageLayoutPlan {
        // These native-control stand-ins refuse widths below their intrinsic minima.
        .actions(width: width, ideals: controls) { index, _ in controls[index] }
    }

    @Test func actionProbesHonorMinimumControlsAndHaveNoTrailingGap() {
        let cases: [(CGFloat?, CGSize)] = [
            (nil, CGSize(width: 294, height: 40)),
            (.infinity, CGSize(width: 294, height: 40)),
            (0, CGSize(width: 100, height: 106)),
            (60, CGSize(width: 100, height: 106)),
            (200, CGSize(width: 200, height: 68)),
            (500, CGSize(width: 500, height: 40))
        ]
        for (proposal, expected) in cases {
            let plan = actions(proposal)
            #expect(plan.size == expected)
            #expect(plan.size.width.isFinite && plan.size.height.isFinite)
            #expect(plan.frames.count == controls.count)
            for frame in plan.frames { #expect(CGRect(origin: .zero, size: plan.size).contains(frame)) }
            for index in 1..<plan.frames.count { #expect(!plan.frames[index - 1].intersects(plan.frames[index])) }
        }
        #expect(actions(0).widths == [0, 0, 0])
        #expect(actions(nil).frames.last?.maxX == 294)
    }

    @Test func everyWrappedActionRowStartsAtTheDirectionalLeadingEdge() {
        let plan = actions(200)
        let bounds = CGRect(x: 37, y: 19, width: 200, height: 68)
        let ltr = plan.frames.indices.map { plan.leadingPoint(at: $0, in: bounds, direction: .leftToRight) }
        let rtl = plan.frames.indices.map { plan.leadingPoint(at: $0, in: bounds, direction: .rightToLeft) }
        #expect(ltr == [CGPoint(x: 37, y: 19), CGPoint(x: 129, y: 19), CGPoint(x: 37, y: 67)])
        #expect(rtl == [CGPoint(x: 237, y: 19), CGPoint(x: 145, y: 19), CGPoint(x: 237, y: 67)])
        // Points are leading anchors; physical rectangles must fit in either direction.
        for index in rtl.indices {
            let frame = CGRect(x: rtl[index].x - controls[index].width, y: rtl[index].y,
                               width: controls[index].width, height: controls[index].height)
            #expect(bounds.contains(frame))
        }
    }

    @Test func aCompressibleActionKeepsTheWidthUsedToMeasureItsWrappedHeight() {
        let plan = MusicPageLayoutPlan.actions(width: 100, ideals: [CGSize(width: 300, height: 20)]) { _, width in
            CGSize(width: width, height: 60)
        }
        #expect(plan.size == CGSize(width: 100, height: 60))
        #expect(plan.widths == [100])
        #expect(MusicPageLayoutPlan.actions(width: .infinity, ideals: []) { _, _ in .zero }.size == .zero)
    }
}
