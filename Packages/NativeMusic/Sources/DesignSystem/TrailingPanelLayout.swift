import SwiftUI

/// The page and the queue/lyrics panel beside it. `reveal` (0 closed, 1 open) is the layout's animatable value, so opening or closing the panel lays the page
/// out again at every frame of the motion, exactly as a live window resize does: text re-wraps and grids re-flow continuously. A plain `HStack` with a
/// transition instead lays the page out once, at its final width, and interpolates every view from its old place to its new one, so cards hop between
/// rows and lines jump while the panel slides in.
///
/// The panel keeps one width throughout (it slides in from the trailing edge, it never squeezes), and that width is what an `HStack` would give it: the
/// panel's own answer for half the row. Subview 0 is the page; subview 1, when present, is the panel.
public struct MusicTrailingPanelLayout: Layout {
  public var reveal: CGFloat
  public init(reveal: CGFloat) { self.reveal = reveal }
  public var animatableData: CGFloat {
    get { reveal }
    set { reveal = newValue }
  }
  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }
  public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let page = subviews.first else { return }
    let frames = Self.frames(in: bounds, reveal: reveal, panelWidth: subviews.count > 1 ? panelWidth(subviews[1], bounds) : nil, rightToLeft: subviews.layoutDirection == .rightToLeft)
    page.place(at: frames.page.origin, anchor: .topLeading, proposal: ProposedViewSize(frames.page.size))
    if subviews.count > 1, let panel = frames.panel { subviews[1].place(at: panel.origin, anchor: .topLeading, proposal: ProposedViewSize(panel.size)) }
  }
  private func panelWidth(_ panel: LayoutSubview, _ bounds: CGRect) -> CGFloat {
    min(bounds.width, panel.sizeThatFits(ProposedViewSize(width: bounds.width / 2, height: bounds.height)).width)
  }
  /// Where the page and the panel go for a given reveal (pure, for tests). Right-to-left, the panel enters from the left edge instead.
  public static func frames(in bounds: CGRect, reveal: CGFloat, panelWidth: CGFloat?, rightToLeft: Bool) -> (page: CGRect, panel: CGRect?) {
    guard let panelWidth else { return (bounds, nil) }
    let shown = panelWidth * min(1, max(0, reveal))
    let pageWidth = max(0, bounds.width - shown)
    if rightToLeft {
      return (CGRect(x: bounds.minX + shown, y: bounds.minY, width: pageWidth, height: bounds.height),
              CGRect(x: bounds.minX + shown - panelWidth, y: bounds.minY, width: panelWidth, height: bounds.height))
    }
    return (CGRect(x: bounds.minX, y: bounds.minY, width: pageWidth, height: bounds.height),
            CGRect(x: bounds.minX + pageWidth, y: bounds.minY, width: panelWidth, height: bounds.height))
  }
}

/// Performs `body` with the token's animation and runs `completion` once that motion has finished (at once when motion is off).
@MainActor public func musicWithAnimation(_ motion: MusicMotion, reduceMotion: Bool, lowPower: Bool, visible: Bool, _ body: () -> Void, completion: @escaping () -> Void) {
  if let animation = motion.animation(reduceMotion: reduceMotion, lowPower: lowPower, visible: visible) {
    withAnimation(animation, completionCriteria: .logicallyComplete, body, completion: completion)
  } else {
    var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
    withTransaction(transaction, body)
    completion()
  }
}
