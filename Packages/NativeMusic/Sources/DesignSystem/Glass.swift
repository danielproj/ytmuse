import SwiftUI

// V02 native Liquid Glass building blocks beyond the region surface in DesignSystem.swift (GLASS09/GLASS10).
// Every glass here resolves through `GlassPolicy`: native glass normally, a regular material when Low Power Mode or
// an inactive scene simplifies it, and an opaque outlined surface under Reduce Transparency or Increase Contrast.

/// Glass in an arbitrary token shape, for small elements (chips, search fields, hover tiles) that live inside a
/// `MusicGlassGroup`. Regions use `musicSurface`.
private struct MusicGlassModifier<S: Shape>: ViewModifier {
  let shape: S
  var tint: Color?
  var interactive: Bool
  /// Draw a hairline when the glass is simplified to a material (Low Power / inactive): a field on a material panel would otherwise have no edge.
  var edge: Bool
  private var glass = MusicGlassEnvironment()
  init(shape: S, tint: Color?, interactive: Bool, edge: Bool = false) { self.shape = shape; self.tint = tint; self.interactive = interactive; self.edge = edge }
  func body(content: Content) -> some View {
    Group {
      if glass.policy.opaque {
        content.background(Color(nsColor: .windowBackgroundColor), in: shape).overlay(shape.stroke(Color.primary.opacity(0.6), lineWidth: 1))
      } else if glass.policy.simplified {
        content.background(.regularMaterial, in: shape).overlay(shape.stroke(Color.primary.opacity(edge ? 0.28 : 0), lineWidth: 1))
      } else {
        content.glassEffect(effect, in: shape)
      }
    }
    .onReceive(MusicGlassPower.changes) { _ in glass.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
  }
  private var effect: Glass {
    var value = Glass.regular
    if let tint { value = value.tint(tint) }
    return interactive ? value.interactive() : value
  }
}

/// Identity for glass that morphs between states (a mini-player becoming Now Playing, a chip becoming a field).
private struct MusicGlassIdentity<ID: Hashable & Sendable>: ViewModifier {
  let id: ID
  let namespace: Namespace.ID
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View {
    content.glassEffectID(id, in: namespace)
      .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
  }
}

extension View {
  public func musicGlass(_ corner: MusicCorner, tint: Color? = nil, interactive: Bool = false, edge: Bool = false) -> some View {
    modifier(MusicGlassModifier(shape: corner.shape, tint: tint, interactive: interactive, edge: edge))
  }
  /// A text field on glass: plain field, token padding, interactive glass tinted while focused.
  /// `dense` fits a toolbar-like row of pickers and buttons without making it taller than a bordered field would.
  public func musicField(focused: Bool = false, dense: Bool = false) -> some View {
    textFieldStyle(.plain).padding(.horizontal, MusicSpace.sm).padding(.vertical, dense ? MusicSpace.hairline : MusicSpace.xs)
      .musicGlass(.media, tint: focused ? MusicStyle.accent.opacity(0.18) : nil, interactive: true, edge: true)
      .musicAnimation(.selection, value: focused)
  }
  public func musicGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
    modifier(MusicGlassModifier(shape: Capsule(style: .continuous), tint: tint, interactive: interactive))
  }
  /// Gives this glass an identity inside a `MusicGlassGroup` so it morphs instead of cutting.
  public func musicGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
    modifier(MusicGlassIdentity(id: id, namespace: namespace))
  }
  /// Edge-to-edge backdrop for control bars beside media (video window controls): glass, or an opaque bar when transparency is reduced.
  public func musicBarBackground() -> some View { modifier(MusicGlassModifier(shape: Rectangle(), tint: nil, interactive: false)) }
  /// A floating label over media (audio-only notice): glass in the media corner.
  public func musicOverlayLabel() -> some View { musicGlass(.media) }
}

// MARK: Hover and press

/// Tactile feedback for a plain button or tile: a quiet lift on hover, a settle on press, a hairline highlight.
/// Reduce Motion drops the scale and keeps the highlight.
public struct MusicTileButtonStyle: ButtonStyle {
  public var corner: MusicCorner
  public var edge: CGFloat?
  public init(corner: MusicCorner = .artwork, edge: CGFloat? = nil) { self.corner = corner; self.edge = edge }
  public func makeBody(configuration: Configuration) -> some View {
    Tile(configuration: configuration, corner: corner, edge: edge)
  }
  private struct Tile: View {
    let configuration: ButtonStyleConfiguration
    let corner: MusicCorner
    let edge: CGFloat?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
      configuration.label
        .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : (hovering && enabled ? 1.02 : 1)))
        .overlay((edge.map { corner.shape(edge: $0) } ?? corner.shape).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.16), lineWidth: 1).opacity(hovering && enabled ? 1 : 0).allowsHitTesting(false))
        .musicAnimation(.hoverPress, value: hovering)
        .musicAnimation(.hoverPress, value: configuration.isPressed)
        .onHover { hovering = $0 }
    }
  }
}

extension ButtonStyle where Self == MusicTileButtonStyle {
  public static var musicTile: MusicTileButtonStyle { MusicTileButtonStyle() }
  public static func musicTile(_ corner: MusicCorner, edge: CGFloat? = nil) -> MusicTileButtonStyle { MusicTileButtonStyle(corner: corner, edge: edge) }
}

/// A hover highlight for a row that is not itself a button style host (list rows, results).
private struct MusicHoverHighlight: ViewModifier {
  let corner: MusicCorner
  @State private var hovering = false
  @Environment(\.isEnabled) private var enabled
  func body(content: Content) -> some View {
    content
      .background(corner.shape.fill(Color.primary.opacity(hovering && enabled ? 0.07 : 0)))
      .musicAnimation(.hoverPress, value: hovering)
      .onHover { hovering = $0 }
  }
}
/// A card lifts a few points under the pointer: a slight scale and a soft shadow, gone under Reduce Motion (the shadow stays).
private struct MusicHoverLift: ViewModifier {
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var enabled
  func body(content: Content) -> some View {
    content
      .scaleEffect(hovering && enabled && !reduceMotion ? 1.02 : 1)
      .musicElevation(hovering && enabled ? .raised : .flat)
      .musicAnimation(.hoverPress, value: hovering)
      .onHover { hovering = $0 }
  }
}
extension View {
  public func musicHoverLift() -> some View { modifier(MusicHoverLift()) }
  public func musicHoverHighlight(_ corner: MusicCorner = .selection) -> some View { modifier(MusicHoverHighlight(corner: corner)) }
}

// MARK: Badges

/// Small status pills. The Ad pill keeps YouTube's honest advertisement state legible on any background.
public enum MusicBadgeStyle: Sendable, Equatable {
  case advertisement, live(atEdge: Bool), explicit
}
public struct MusicBadge: View {
  let text: LocalizedStringKey
  let style: MusicBadgeStyle
  public init(_ text: LocalizedStringKey, style: MusicBadgeStyle) { self.text = text; self.style = style }
  public var body: some View {
    switch style {
    case .advertisement:
      Text(text).font(.caption.bold()).padding(.horizontal, MusicSpace.xs).padding(.vertical, MusicSpace.hairline)
        .background(Color(nsColor: MusicPalette.advertisementFill.nsColor), in: Capsule()).foregroundStyle(Color(nsColor: MusicPalette.advertisementText.nsColor))
    case .live(let atEdge):
      Text(text).font(.caption.bold()).padding(.horizontal, MusicSpace.xs).padding(.vertical, MusicSpace.hairline)
        .background(Color(nsColor: (atEdge ? MusicPalette.liveBadgeAtEdge : MusicPalette.liveBadgeBehind).nsColor), in: Capsule()).foregroundStyle(Color(nsColor: MusicPalette.badgeText.nsColor))
    case .explicit:
      Text(text).font(.caption2.bold()).padding(.horizontal, MusicSpace.xxs).padding(.vertical, MusicSpace.hairline)
        .musicOutline(.badge).foregroundStyle(MusicStyle.secondaryText)
    }
  }
}

/// A hairline outlined capsule label ("Local only").
public struct MusicOutlineBadge: View {
  let text: LocalizedStringKey
  public init(_ text: LocalizedStringKey) { self.text = text }
  public var body: some View {
    Text(text).font(.caption).foregroundStyle(MusicStyle.secondaryText)
      .padding(.horizontal, MusicSpace.xs).padding(.vertical, MusicSpace.hairline)
      .overlay(Capsule().strokeBorder(.secondary.opacity(0.6)))
  }
}
