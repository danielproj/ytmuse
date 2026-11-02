import SwiftUI

// PLAYER-1: the floating capsule player bar. One glass capsule at the bottom of the detail column; plain glyphs, a filled accent Play/Pause, a hairline seek
// that grows on hover. Everything the shell and the transports state about its size, place and look is here, so feature code asks for tokens.

public enum PlayerCapsule {
  public static let regularHeight: CGFloat = 56
  public static let compactHeight: CGFloat = 48
  /// The widest the capsule gets in a very wide window.
  public static let maximumWidth: CGFloat = 960
  /// From the detail column's edges and from the window's bottom.
  public static let margin: CGFloat = MusicSpace.md
  /// Between the panels' bottom edge and the capsule's top edge.
  public static let panelGap: CGFloat = MusicSpace.sm
  public static let regularPlayEdge: CGFloat = 36
  /// The compact capsule is 48 pt tall: a 36 pt circle would leave no room under it for the seek (the thumb and track must never touch it).
  public static let compactPlayEdge: CGFloat = 32
  /// The expanded player's larger controls.
  public static let largePlayEdge: CGFloat = 44
  public static let glyphEdge: CGFloat = 28
  public static let largeGlyphEdge: CGFloat = 32
  public static let volumeWidth: CGFloat = 52
  public static let titleWidth: CGFloat = 160
  public static let seekRestThickness: CGFloat = 2
  public static let seekHoverThickness: CGFloat = 4
  /// The thumb: only while dragging or keyboard-focused, never at rest or on hover.
  public static let accentDotEdge: CGFloat = 4
  /// The capsule's horizontal content padding (`TransportBar`).
  public static let contentInset: CGFloat = MusicSpace.xs
  /// Between the cover and the title (and so the seek's start).
  public static let coverGap: CGFloat = MusicSpace.sm
  /// The height of the pointer zone of the seek's real slider (a little taller than the hover track).
  public static let seekZone: CGFloat = MusicSpace.sm
  /// The least the seek's track and thumb stay inside the capsule's edge.
  public static let seekEdgeGap: CGFloat = 2
  /// Room beside the transport for an elapsed or remaining time (reserved at rest, so the buttons never move on hover).
  public static let timeSlotWidth: CGFloat = MusicSpace.xl + MusicSpace.xs
  /// The transport cluster sits this much above the capsule's centre, clear of the seek under it.
  public static let transportLift: CGFloat = 1
  public static let slimTrackThickness: CGFloat = 3
  public static let slimKnobEdge: CGFloat = 8

  public static func playEdge(compact: Bool, large: Bool = false) -> CGFloat { large ? largePlayEdge : (compact ? compactPlayEdge : regularPlayEdge) }
  public static func glyphEdge(large: Bool) -> CGFloat { large ? largeGlyphEdge : glyphEdge }
  public static func thumbEdge(compact: Bool) -> CGFloat { compact ? 6 : 8 }
  /// The width the time slots take beside the transport (none in the compact capsule: there is no room, the times stay in the accessibility tree).
  public static func timeSlot(compact: Bool) -> CGFloat { compact ? 0 : timeSlotWidth }
  /// The seek's centre line, measured up from the capsule's bottom edge: far enough that the thumb stays `seekEdgeGap` inside.
  public static func seekCentre(compact: Bool) -> CGFloat { seekEdgeGap + thumbEdge(compact: compact) / 2 }
  /// The seek starts at the title's leading edge, so it never runs under the cover (measured from the row's leading edge, inside the content inset).
  public static func seekLeading(compact: Bool) -> CGFloat { coverEdge(compact: compact) + coverGap }
  /// The seek ends this far in from the row's trailing edge: the capsule's corner radius less the content inset, so it never crosses the rounded end.
  public static func seekTrailing(compact: Bool) -> CGFloat { height(compact: compact) / 2 - contentInset }

  public static func height(compact: Bool) -> CGFloat { compact ? compactHeight : regularHeight }
  public static func coverEdge(compact: Bool) -> CGFloat { compact ? 32 : 40 }
  public static func coverRadius(compact: Bool) -> CGFloat { compact ? 10 : 12 }
  /// How far above the window's bottom the capsule's top edge is: the detail region ends there, and the panels' own 12 pt padding is the gap above the capsule.
  public static func occupiedHeight(compact: Bool) -> CGFloat { margin + height(compact: compact) }
  /// How far above the window's bottom the panels must end: the capsule's margin, its height and the gap above it.
  public static func bottomReserve(compact: Bool) -> CGFloat { margin + height(compact: compact) + panelGap }

  /// Where the capsule sits, in the coordinates of `column` (the detail column: the area beside the sidebar that holds the detail panel and the inline
  /// trailing panel): `margin` in from its edges and up from the window's bottom, capped at `maximumWidth` and centred in the column.
  public static func frame(column: CGRect, windowHeight: CGFloat, compact: Bool) -> CGRect {
    let width = max(0, min(column.width - 2 * margin, maximumWidth))
    let height = height(compact: compact)
    return CGRect(x: column.midX - width / 2, y: windowHeight - margin - height, width: width, height: height)
  }
}

/// The capsule's chrome: its glass, height and elevation. The row inside is the caller's (`MusicCapsuleRow`).
public struct TransportBar<Content: View>: View {
  let content: Content
  let tint: MusicTint?
  let morph: MusicMorph?
  let compact: Bool
  @Environment(\.colorScheme) private var scheme
  public init(tint: MusicTint? = nil, morph: MusicMorph? = nil, compact: Bool = false, @ViewBuilder content: () -> Content) {
    self.tint = tint; self.morph = morph; self.compact = compact; self.content = content()
  }
  public var body: some View {
    content.padding(.horizontal, MusicSpace.xs).frame(maxWidth: .infinity).frame(height: PlayerCapsule.height(compact: compact))
      .musicCapsuleSurface(height: PlayerCapsule.height(compact: compact), tint: tint?.glassColor(scheme: scheme), morph: morph).musicElevation(.floating)
      .musicAnimation(.artworkColor, value: tint)
  }
}

/// Leading group, centre group, trailing group. The centre group is centred in the row whatever the sides hold (each side gets only the room the centre
/// leaves it), and the row mirrors in right-to-left.
public struct MusicCapsuleRow: Layout {
  public var spacing: CGFloat
  public init(spacing: CGFloat = MusicSpace.sm) { self.spacing = spacing }
  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let natural = sizes.reduce(0) { $0 + $1.width } + spacing * 2
    return CGSize(width: proposal.width ?? natural, height: proposal.height ?? (sizes.map(\.height).max() ?? 0))
  }
  public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 3 else { return }
    let rtl = subviews.layoutDirection == .rightToLeft
    let centre = subviews[1].sizeThatFits(.unspecified)
    let trailing = subviews[2].sizeThatFits(.unspecified)
    let room = max(0, (bounds.width - centre.width) / 2 - spacing)
    let mid = CGPoint(x: bounds.midX, y: bounds.midY)
    let edgeX = { (leading: Bool) -> CGFloat in (leading != rtl) ? bounds.minX : bounds.maxX }
    subviews[0].place(at: CGPoint(x: edgeX(true), y: mid.y), anchor: rtl ? .trailing : .leading, proposal: ProposedViewSize(width: room, height: bounds.height))
    subviews[1].place(at: mid, anchor: .center, proposal: ProposedViewSize(centre))
    subviews[2].place(at: CGPoint(x: edgeX(false), y: mid.y), anchor: rtl ? .leading : .trailing, proposal: ProposedViewSize(width: min(trailing.width, room), height: bounds.height))
  }
}

// MARK: Buttons

/// The look of a capsule glyph: no box. Accent plus a small dot underneath when `isOn`; clearly dimmed when disabled; a faint disc under the pointer.
public struct MusicGlyphFace<Content: View>: View {
  let content: Content
  let isOn: Bool
  let pressed: Bool
  let edge: CGFloat
  @State private var hovering = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.colorSchemeContrast) private var contrast
  public init(isOn: Bool = false, pressed: Bool = false, edge: CGFloat = PlayerCapsule.glyphEdge, @ViewBuilder content: () -> Content) { self.isOn = isOn; self.pressed = pressed; self.edge = edge; self.content = content() }
  public var body: some View {
    content
      .font(.system(size: edge * 15 / PlayerCapsule.glyphEdge, weight: .medium))
      .foregroundStyle(color)
      .frame(width: edge, height: edge)
      .background(Circle().fill(Color.primary.opacity(hovering && enabled ? 0.10 : 0)))
      .overlay(alignment: .bottom) {
        if isOn { Circle().fill(MusicStyle.accent).frame(width: PlayerCapsule.accentDotEdge, height: PlayerCapsule.accentDotEdge) }
      }
      .contentShape(Circle())
      .opacity(pressed ? 0.6 : 1)
      .musicAnimation(.hoverPress, value: hovering)
      .onHover { hovering = $0 }
  }
  private var color: Color {
    if !enabled { return Color.primary.opacity(contrast == .increased ? 0.45 : 0.30) }
    return isOn ? MusicStyle.accent : Color.primary.opacity(contrast == .increased ? 1 : 0.80)
  }
}

/// A plain glyph button style.
public struct MusicGlyphButtonStyle: ButtonStyle {
  public var isOn: Bool
  public var edge: CGFloat
  public init(isOn: Bool = false, edge: CGFloat = PlayerCapsule.glyphEdge) { self.isOn = isOn; self.edge = edge }
  public func makeBody(configuration: Configuration) -> some View {
    MusicGlyphFace(isOn: isOn, pressed: configuration.isPressed, edge: edge) { configuration.label.labelStyle(.iconOnly) }
  }
}

/// A glyph for a control that draws its own button (a menu): the same face.
public struct MusicGlyphLabel: View {
  let systemImage: String
  let isOn: Bool
  let edge: CGFloat
  public init(systemImage: String, isOn: Bool = false, edge: CGFloat = PlayerCapsule.glyphEdge) { self.systemImage = systemImage; self.isOn = isOn; self.edge = edge }
  public var body: some View { MusicGlyphFace(isOn: isOn, edge: edge) { Image(systemName: systemImage) } }
}

/// The 36 pt filled accent circle of Play/Pause, with a soft accent shadow.
public struct MusicPlayButtonStyle: ButtonStyle {
  public var edge: CGFloat
  public init(edge: CGFloat = PlayerCapsule.regularPlayEdge) { self.edge = edge }
  public func makeBody(configuration: Configuration) -> some View { Play(configuration: configuration, edge: edge) }
  private struct Play: View {
    let configuration: ButtonStyleConfiguration
    let edge: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
      configuration.label.labelStyle(.iconOnly)
        .font(.system(size: edge * 15 / PlayerCapsule.regularPlayEdge, weight: .semibold))
        .foregroundStyle(Color(nsColor: MusicPalette.glyphOnAccentFill.nsColor))
        .frame(width: edge, height: edge)
        .background(Circle().fill(MusicStyle.accentFill))
        .shadow(color: contrast == .increased ? .clear : MusicStyle.accentFill.opacity(enabled ? 0.45 : 0), radius: 7, x: 0, y: 3)
        .opacity(enabled ? 1 : 0.4)
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
        .contentShape(Circle())
        .musicAnimation(.hoverPress, value: configuration.isPressed)
    }
  }
}

extension ButtonStyle where Self == MusicGlyphButtonStyle {
  public static var musicGlyph: MusicGlyphButtonStyle { MusicGlyphButtonStyle() }
  public static func musicGlyph(on: Bool = false, edge: CGFloat = PlayerCapsule.glyphEdge) -> MusicGlyphButtonStyle { MusicGlyphButtonStyle(isOn: on, edge: edge) }
}
extension ButtonStyle where Self == MusicPlayButtonStyle {
  public static var musicPlay: MusicPlayButtonStyle { MusicPlayButtonStyle() }
  public static func musicPlay(edge: CGFloat) -> MusicPlayButtonStyle { MusicPlayButtonStyle(edge: edge) }
}

extension View {
  /// The capsule's cover: its edge, and a continuous radius of 12 pt (10 pt compact).
  public func musicCapsuleCover(compact: Bool) -> some View {
    frame(width: PlayerCapsule.coverEdge(compact: compact), height: PlayerCapsule.coverEdge(compact: compact))
      .clipShape(RoundedRectangle(cornerRadius: PlayerCapsule.coverRadius(compact: compact), style: .continuous))
  }
  /// A small status chip beside the ⋯ menu (the sleep timer's moon and remaining time).
  public func musicCapsuleChip() -> some View {
    font(.caption).monospacedDigit().foregroundStyle(MusicStyle.secondaryText).lineLimit(1)
      .padding(.horizontal, MusicSpace.xs).padding(.vertical, MusicSpace.xxs)
      .background(Capsule().fill(Color.primary.opacity(0.08)))
  }
}

// MARK: Seek and sliders

/// Where the seek is in use: at rest a 2 pt hairline; under the pointer a 4 pt track; while dragged or keyboard-focused a small thumb as well.
public enum MusicSeekState: Sendable, Equatable {
  case rest, hover, active
  public init(hovering: Bool, dragging: Bool, focused: Bool) { self = (dragging || focused) ? .active : (hovering ? .hover : .rest) }
  public var thickness: CGFloat { self == .rest ? PlayerCapsule.seekRestThickness : PlayerCapsule.seekHoverThickness }
  /// The thumb is for dragging and keyboard focus only: a pointer resting on the capsule never shows one.
  public var showsThumb: Bool { self == .active }
  public var showsTimes: Bool { self != .rest }
}

/// The seek layer of the capsule, inside its content row: a hairline from the title's leading edge to the trailing inset, along the bottom. Drawing only
/// (no hit testing), with the real slider over it, nearly transparent and never removed, so keyboard, VoiceOver and the identifier keep working.
public struct MusicCapsuleSeekLayer<Control: View>: View {
  let fraction: Double, state: MusicSeekState, enabled: Bool, compact: Bool
  let control: Control
  @Environment(\.colorSchemeContrast) private var contrast
  public init(fraction: Double, state: MusicSeekState, enabled: Bool, compact: Bool, @ViewBuilder control: () -> Control) {
    self.fraction = fraction; self.state = state; self.enabled = enabled; self.compact = compact; self.control = control()
  }
  public var body: some View {
    let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
    let thumb = PlayerCapsule.thumbEdge(compact: compact)
    ZStack {
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.4 : 0.14)).frame(height: state.thickness)
            .audit("playerSeekTrack", group: "playerSeek", kind: .layer, within: "playerBar")
          Capsule().fill(MusicStyle.accent.opacity(enabled ? 1 : 0.5)).frame(width: proxy.size.width * clamped, height: state.thickness)
        }.frame(height: PlayerCapsule.seekZone)
        if state.showsThumb && enabled {
          Circle().fill(Color.white).frame(width: thumb, height: thumb)
            .audit("playerSeekThumb", group: "playerSeek", kind: .layer, within: "playerBar")
            .offset(x: (proxy.size.width - thumb) * clamped, y: (PlayerCapsule.seekZone - thumb) / 2)
        }
      }.allowsHitTesting(false).accessibilityHidden(true)
      // Not removed from accessibility and not hidden from the pointer: a control at opacity 0 would be both. The drawing above is what is seen.
      control.controlSize(.mini).opacity(0.02).transaction { $0.animation = nil }
    }
    .frame(height: PlayerCapsule.seekZone)
    .padding(.leading, PlayerCapsule.seekLeading(compact: compact)).padding(.trailing, PlayerCapsule.seekTrailing(compact: compact))
    .padding(.bottom, PlayerCapsule.seekCentre(compact: compact) - PlayerCapsule.seekZone / 2)
    .musicAnimation(.hoverPress, value: state)
  }
}

/// A time beside the transport. Invisible at rest by its colour (not its opacity: a view at opacity 0 leaves the accessibility tree), so tests and
/// VoiceOver still find it; `slot` is reserved at rest so the buttons never move when it appears.
public struct MusicTimeSlot: View {
  let text: String
  let visible: Bool
  let slot: CGFloat
  let leadingSide: Bool
  public init(_ text: String, visible: Bool, slot: CGFloat, leadingSide: Bool) { self.text = text; self.visible = visible; self.slot = slot; self.leadingSide = leadingSide }
  public var body: some View {
    Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
      .foregroundStyle(visible && slot > 0 ? MusicStyle.secondaryText : Color.clear)
      .frame(width: slot, alignment: leadingSide ? .trailing : .leading)
      .musicAnimation(.hoverPress, value: visible)
  }
}

/// A slim slider's look: a 3 pt track, an accent fill and a small knob that shows only under the pointer or while dragged or focused. Drawing only; the
/// real `Slider` is over it, nearly transparent (never removed: keyboard, VoiceOver and identifiers).
public struct MusicSlimSlider<Control: View>: View {
  let fraction: Double
  let active: Bool
  let enabled: Bool
  let thickness: CGFloat
  let control: Control
  @Environment(\.colorSchemeContrast) private var contrast
  public init(fraction: Double, active: Bool, enabled: Bool = true, thickness: CGFloat = PlayerCapsule.slimTrackThickness, @ViewBuilder control: () -> Control) {
    self.fraction = fraction; self.active = active; self.enabled = enabled; self.thickness = thickness; self.control = control()
  }
  /// The knob is for the pointer, a drag and the keyboard: never at rest.
  public static func showsKnob(active: Bool, enabled: Bool) -> Bool { active && enabled }
  public var body: some View {
    let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
    let knob = PlayerCapsule.slimKnobEdge
    ZStack {
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.4 : 0.18)).frame(height: thickness)
          Capsule().fill(MusicStyle.accent.opacity(enabled ? 1 : 0.5)).frame(width: proxy.size.width * clamped, height: thickness)
          if Self.showsKnob(active: active, enabled: enabled) {
            Circle().fill(Color.white).frame(width: knob, height: knob).offset(x: (proxy.size.width - knob) * clamped)
          }
        }.frame(height: PlayerCapsule.seekZone)
      }.allowsHitTesting(false).accessibilityHidden(true)
      control.controlSize(.mini).opacity(0.02)
    }.frame(height: PlayerCapsule.seekZone).musicAnimation(.hoverPress, value: active)
  }
}
