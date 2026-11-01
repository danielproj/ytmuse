import SwiftUI

/// V02 design tokens (GLASS07 grid, GLASS08 corners). Feature code reads these through the
/// `Music*` components in this module and never states a literal radius, material or animation.

/// One radius scale. Nested shapes are concentric: an inner radius is the outer radius minus
/// the inset between them (`MusicRadius.inner(of:inset:)`), never a second literal.
public enum MusicRadius {
  /// Badges and hairline chips.
  public static let xs: CGFloat = 4
  /// Thumbnails in dense rows, selection highlights, small inset media.
  public static let sm: CGFloat = 8
  /// Card artwork, inset media, video pictures.
  public static let md: CGFloat = 12
  /// Large artwork and popovers.
  public static let lg: CGFloat = 16
  /// Region panels (the glass surfaces of a window).
  public static let xl: CGFloat = 24
  /// The floating player and hero surfaces.
  public static let xxl: CGFloat = 32
  public static let scale: [CGFloat] = [xs, sm, md, lg, xl, xxl]
  /// The radius of a shape nested `inset` points inside a shape of radius `outer`.
  public static func inner(of outer: CGFloat, inset: CGFloat) -> CGFloat { max(0, outer - inset) }
}

/// The semantic corner roles feature code asks for. Each maps to one `MusicRadius` step.
public enum MusicCorner: String, CaseIterable, Sendable {
  case badge, selection, thumbnail, artwork, media, feature, panel, player
  /// Media sitting at the standard inset (`MusicSpace.sm`) inside the player: concentric with its corner, derived and not a scale step.
  case playerInset
  /// Media sitting at the standard inset (`MusicStyle.spacing`) inside a panel: concentric with its corner.
  case panelInset
  public var radius: CGFloat {
    switch self {
    case .badge: MusicRadius.xs
    case .selection, .thumbnail: MusicRadius.sm
    case .artwork, .media: MusicRadius.md
    case .feature: MusicRadius.lg
    case .panel: MusicRadius.xl
    case .player: MusicRadius.xxl
    case .playerInset: MusicRadius.inner(of: MusicRadius.xxl, inset: MusicSpace.sm)
    case .panelInset: MusicRadius.inner(of: MusicRadius.xl, inset: MusicSpace.md)
    }
  }
  /// The corner of something nested `inset` points inside a shape of this role.
  public func inner(inset: CGFloat) -> CGFloat { MusicRadius.inner(of: radius, inset: inset) }
  public var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
  /// The radius for an element of `edge` points: concentric roles keep their derived value only where the element can carry it, so a small thumbnail is
  /// never a circle (a quarter of the edge at most).
  public func radius(forEdge edge: CGFloat) -> CGFloat { min(radius, edge * 0.25) }
  public func shape(edge: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius(forEdge: edge), style: .continuous) }
}

public enum MusicShape {
  public static func rounded(_ corner: MusicCorner) -> RoundedRectangle { corner.shape }
  /// A custom radius, always derived from the scale (a concentric inner shape).
  public static func concentric(in outer: MusicCorner, inset: CGFloat) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: outer.inner(inset: inset), style: .continuous)
  }
}

/// The 4-point layout grid. Spacing, padding and fixed edges are multiples of `grid`.
public enum MusicSpace {
  public static let grid: CGFloat = 4
  /// Half a grid step: only for hairline padding inside badges, never for layout edges.
  public static let hairline: CGFloat = 2
  public static let xxs: CGFloat = 4
  public static let xs: CGFloat = 8
  public static let sm: CGFloat = 12
  public static let md: CGFloat = 16
  public static let lg: CGFloat = 24
  public static let xl: CGFloat = 32
  public static let xxl: CGFloat = 48
  public static let scale: [CGFloat] = [xxs, xs, sm, md, lg, xl, xxl]
  /// Whether `value` sits on the grid, within `tolerance` (pixel rounding of native controls).
  public static func isOnGrid(_ value: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
    let remainder = value.truncatingRemainder(dividingBy: grid)
    return min(abs(remainder), abs(grid - abs(remainder))) <= tolerance
  }
}

/// Depth: a soft shadow per level. Reduced to nothing under increased contrast, where borders carry depth.
public enum MusicElevation: String, CaseIterable, Sendable {
  case flat, raised, floating, hero
  public var radius: CGFloat {
    switch self { case .flat: 0; case .raised: 8; case .floating: 16; case .hero: 28 }
  }
  public var offset: CGFloat {
    switch self { case .flat: 0; case .raised: 2; case .floating: 6; case .hero: 12 }
  }
  public var opacity: Double {
    switch self { case .flat: 0; case .raised: 0.10; case .floating: 0.16; case .hero: 0.24 }
  }
}

private struct MusicElevationModifier: ViewModifier {
  let level: MusicElevation
  var tint: Color?
  @Environment(\.colorSchemeContrast) private var contrast
  func body(content: Content) -> some View {
    if level == .flat || contrast == .increased { content }
    else {
      content.shadow(color: (tint ?? .black).opacity(level.opacity), radius: level.radius, x: 0, y: level.offset)
    }
  }
}

extension View {
  public func musicElevation(_ level: MusicElevation, tint: Color? = nil) -> some View {
    modifier(MusicElevationModifier(level: level, tint: tint))
  }
  /// Clips to a token corner (artwork, media and thumbnails).
  public func musicClip(_ corner: MusicCorner) -> some View { clipShape(corner.shape) }
  /// Clips an element of known size: the corner, capped to a quarter of its edge.
  public func musicClip(_ corner: MusicCorner, edge: CGFloat) -> some View { clipShape(corner.shape(edge: edge)) }
  /// A fine outline in a token corner.
  public func musicOutline(_ corner: MusicCorner, _ style: some ShapeStyle = Color.secondary.opacity(0.7)) -> some View {
    overlay(corner.shape.strokeBorder(style))
  }
  /// A dashed outline in a token corner (drop targets).
  public func musicDashedOutline(_ corner: MusicCorner, _ style: some ShapeStyle, lineWidth: CGFloat = 1) -> some View {
    overlay(corner.shape.strokeBorder(style, style: StrokeStyle(lineWidth: lineWidth, dash: [MusicSpace.xxs, MusicSpace.xxs])))
  }
  /// A list-row selection background in the selection corner.
  public func musicSelectionBackground(_ selected: Bool) -> some View {
    background(selected ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear), in: MusicCorner.selection.shape)
  }
}
