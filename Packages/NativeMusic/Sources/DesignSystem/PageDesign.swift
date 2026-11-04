import SwiftUI

/// Page roles complement the floating player. Surfaces inside a page are quiet and opaque;
/// glass remains at the window boundary. These modifiers never claim the parent's height.
public enum MusicPageStyle {
    public static let title: Font = .largeTitle.weight(.semibold)
    public static let section: Font = .title2.weight(.semibold)
}

private struct PageInsetSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.background(Color(nsColor: .controlBackgroundColor), in: MusicCorner.feature.shape)
            .overlay(MusicCorner.feature.shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.08)))
    }
}
private struct PageAction: ViewModifier {
    var prominent: Bool
    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(MusicStyle.accentFill)
        } else { content.buttonStyle(.borderless) }
    }
}
extension View {
    public func musicPageContent(includeTopInset: Bool = true) -> some View {
        padding(.horizontal, MusicSpace.lg).padding(.top, includeTopInset ? MusicSpace.xl : 0).padding(.bottom, MusicSpace.xl)
    }
    /// Caller owns inset and width, so nested surfaces do not multiply padding.
    public func musicInsetSurface() -> some View { modifier(PageInsetSurface()) }
    public func musicPageAction(prominent: Bool = false) -> some View { modifier(PageAction(prominent: prominent)) }
    public func musicPageRow() -> some View {
        padding(.vertical, MusicSpace.xs).padding(.horizontal, MusicSpace.xs).musicHoverHighlight()
    }
}

/// The production measurement plan, shared with non-rendering geometry regression tests.
/// Child proposals are retained: a child that refuses a narrow proposal must receive that
/// same proposal in placement, rather than its measured size (which could reflow it).
struct MusicPageLayoutPlan {
    var size: CGSize
    var frames: [CGRect]
    var widths: [CGFloat?]

    func leadingPoint(at index: Int, in bounds: CGRect, direction: LayoutDirection) -> CGPoint {
        let frame = frames[index]
        return CGPoint(x: direction == .rightToLeft ? bounds.maxX - frame.minX : bounds.minX + frame.minX,
                       y: bounds.minY + frame.minY)
    }

    static func width(_ proposed: CGFloat?, ideal: CGFloat) -> CGFloat {
        guard let proposed, proposed.isFinite else { return ideal }
        return max(0, proposed)
    }

    static func hero(width proposed: CGFloat?, spacing: CGFloat,
                     artwork: CGSize, details: (CGFloat?) -> CGSize) -> Self {
        let ideal = details(nil)
        let width = width(proposed, ideal: artwork.width + spacing + ideal.width)
        var stacked = width < 540
        var detailWidth = stacked ? width : max(0, width - artwork.width - spacing)
        var measured = details(detailWidth)
        // A large intrinsic minimum cannot fit beside artwork. Stack and measure again
        // with the full available width before deciding the reported extent.
        if !stacked && artwork.width + spacing + measured.width > width {
            stacked = true
            detailWidth = width
            measured = details(detailWidth)
        }
        let origin = CGPoint(x: stacked ? 0 : artwork.width + spacing,
                             y: stacked ? artwork.height + spacing : 0)
        let extent = CGSize(width: max(width, max(artwork.width, origin.x + measured.width)),
                            height: max(artwork.height, origin.y + measured.height))
        return Self(size: extent, frames: [CGRect(origin: .zero, size: artwork), CGRect(origin: origin, size: measured)],
                    widths: [nil, detailWidth])
    }

    static func actions(width proposed: CGFloat?, ideals: [CGSize],
                        measure: (Int, CGFloat) -> CGSize) -> Self {
        guard !ideals.isEmpty else { return Self(size: .zero, frames: [], widths: []) }
        let idealWidth = ideals.reduce(0) { $0 + $1.width } + CGFloat(ideals.count - 1) * MusicSpace.sm
        let available = width(proposed, ideal: idealWidth)
        let widths = ideals.map { min(available, $0.width) }
        let sizes = widths.indices.map { measure($0, widths[$0]) }
        // Widen to an uncompressible control's minimum before forming rows. Every row
        // then fits the reported width, even for a zero or below-minimum proposal.
        let width = max(available, sizes.map(\.width).max() ?? 0)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for size in sizes {
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + MusicSpace.xs; rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + MusicSpace.sm
            rowHeight = max(rowHeight, size.height)
        }
        return Self(size: CGSize(width: width, height: y + rowHeight), frames: frames, widths: widths.map { Optional($0) })
    }
}

/// A two-part artwork header that stacks at narrow widths (including a sidebar and inline panel).
/// Uses a single copy of each child, retaining artwork demand across width changes.
public struct MusicHeroLayout: Layout {
    public var spacing: CGFloat
    public init(spacing: CGFloat = MusicSpace.lg) { self.spacing = spacing }
    private func plan(_ proposal: ProposedViewSize, _ subviews: Subviews) -> MusicPageLayoutPlan {
        guard subviews.count == 2 else { return MusicPageLayoutPlan(size: .zero, frames: [], widths: []) }
        return .hero(width: proposal.width, spacing: spacing, artwork: subviews[0].sizeThatFits(.unspecified)) {
            subviews[1].sizeThatFits(.init(width: $0, height: nil))
        }
    }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(proposal, subviews).size
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = plan(proposal, subviews)
        for index in layout.frames.indices {
            subviews[index].place(at: layout.leadingPoint(at: index, in: bounds, direction: subviews.layoutDirection),
                                  anchor: UnitPoint(x: subviews.layoutDirection == .rightToLeft ? 1 : 0, y: 0),
                                  proposal: .init(width: layout.widths[index], height: nil))
        }
    }
}

/// Wraps an action group without duplicating its controls or imposing a fixed height.
public struct MusicActionLayout: Layout {
    public init() {}
    private func plan(_ proposal: ProposedViewSize, _ subviews: Subviews) -> MusicPageLayoutPlan {
        .actions(width: proposal.width, ideals: subviews.map { $0.sizeThatFits(.unspecified) }) {
            subviews[$0].sizeThatFits(.init(width: $1, height: nil))
        }
    }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(proposal, subviews).size
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = plan(proposal, subviews)
        for index in layout.frames.indices {
            subviews[index].place(at: layout.leadingPoint(at: index, in: bounds, direction: subviews.layoutDirection),
                                  anchor: UnitPoint(x: subviews.layoutDirection == .rightToLeft ? 1 : 0, y: 0),
                                  proposal: .init(width: layout.widths[index], height: nil))
        }
    }
}
