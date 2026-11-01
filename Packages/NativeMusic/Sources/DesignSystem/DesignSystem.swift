import AppKit
import Combine
import SwiftUI

public enum MusicStyle {
  public static let compact: CGFloat = MusicSpace.xs
  public static let spacing: CGFloat = MusicSpace.md
  public static let inset: CGFloat = MusicSpace.lg
  public static let radius: CGFloat = MusicRadius.xl
  /// The gray of secondary text per appearance (dark was 0.78: 4.1:1 over a 0.10 glass backdrop; 0.86 in rework 1, too close to primary text; 0.82 since rework 2, 4.6:1 at that backdrop).
  /// Increase Contrast darkens it (light) or lightens it (dark) further: `MusicPalette.secondary`.
  public static func secondaryGray(_ scheme: ColorScheme) -> Double { MusicPalette.secondary(scheme, increased: false) }
  /// An appearance-adaptive colour: the four system appearances (standard and high-contrast, light and dark) each get their own colour.
  /// Dark or light, standard or high contrast, for an appearance name. The system hands a colour provider the high-contrast appearances only while
  /// Increase Contrast is on, so the mapping is by name (testable) and unknown or derived appearances fall back to the nearest of the four.
  public static func traits(of name: NSAppearance.Name) -> (dark: Bool, increased: Bool) {
    switch name {
    case .aqua: return (false, false)
    case .darkAqua: return (true, false)
    case .accessibilityHighContrastAqua: return (false, true)
    case .accessibilityHighContrastDarkAqua: return (true, true)
    default:
      guard let match = NSAppearance(named: name)?.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua]), match != name else { return (false, false) }
      return traits(of: match)
    }
  }
  static func adaptive(_ pick: @escaping (_ dark: Bool, _ increased: Bool) -> NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      let match = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua]) ?? .aqua
      let traits = traits(of: match)
      return pick(traits.dark, traits.increased)
    }
  }
  // Opaque adaptive text colors keep secondary copy readable over native glass. The NSColor forms are public so a test can resolve each appearance.
  public static let secondaryTextNSColor = adaptive { dark, increased in
    NSColor(white: MusicPalette.secondary(dark ? .dark : .light, increased: increased), alpha: 1)
  }
  /// Error text: audited at 4.5:1 on the content canvas (the system red is not).
  public static let errorTextNSColor = adaptive { dark, increased in MusicPalette.error(dark ? .dark : .light, increased: increased).nsColor }
  public static let accentNSColor = adaptive { dark, increased in MusicPalette.accent(dark ? .dark : .light, increased: increased).nsColor }
  /// The fill of the prominent Play/Pause buttons (a white glyph sits on it): see `MusicPalette.accentFill`.
  public static let accentFillNSColor = adaptive { dark, increased in MusicPalette.accentFill(dark ? .dark : .light, increased: increased).nsColor }
  public static let accentFill = Color(nsColor: accentFillNSColor)
  public static let secondaryText = Color(nsColor: secondaryTextNSColor)
  public static let errorText = Color(nsColor: errorTextNSColor)
  public static let accent = Color(nsColor: accentNSColor)
}

/// Low Power Mode changes, delivered on the main queue. Foundation may post
/// `NSProcessInfoPowerStateDidChange` on any thread, and the handlers write view
/// state, so they must never run off the main actor (the NP1 crash class).
public enum MusicGlassPower {
  public static var changes: AnyPublisher<Notification, Never> {
    NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
      .receive(on: DispatchQueue.main).eraseToAnyPublisher()
  }
}

/// Shared policy; no clocks, polling, artwork dependence or account state.
public struct GlassPolicy: Equatable, Sendable {
  public var opaque: Bool
  public var simplified: Bool
  public var animates: Bool
  public init(
    reduceTransparency: Bool, increasedContrast: Bool, reduceMotion: Bool,
    lowPower: Bool, active: Bool
  ) {
    opaque = reduceTransparency || increasedContrast
    simplified = lowPower || !active
    animates = !reduceMotion && !lowPower && active
  }
}

struct MusicGlassEnvironment: DynamicProperty {
  @Environment(\.accessibilityReduceTransparency) var transparency
  @Environment(\.colorSchemeContrast) var contrast
  @Environment(\.accessibilityReduceMotion) var motion
  @Environment(\.scenePhase) var phase
  @State var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
  var policy: GlassPolicy {
    GlassPolicy(
      reduceTransparency: transparency, increasedContrast: contrast == .increased,
      reduceMotion: motion, lowPower: lowPower, active: phase == .active)
  }
}

/// A glass region. Native Liquid Glass normally; opaque with a visible boundary under Reduce Transparency or
/// Increase Contrast; regular material when Low Power or inactive (GLASS05).
/// Identity that lets one glass surface become another (the mini-player becoming Now Playing and back). Both surfaces carry the same
/// identity inside one `MusicGlassGroup`; native glass morphs the SHAPE, and the opaque/material fallbacks morph their backing shape.
public struct MusicMorph {
  public let id: String
  public let namespace: Namespace.ID
  public init(_ id: String, in namespace: Namespace.ID) { self.id = id; self.namespace = namespace }
}

private struct MusicSurface: ViewModifier {
  var corner: MusicCorner
  var tint: Color?
  var interactive: Bool
  var morph: MusicMorph?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var glass = MusicGlassEnvironment()
  init(corner: MusicCorner, tint: Color?, interactive: Bool, morph: MusicMorph?) { self.corner = corner; self.tint = tint; self.interactive = interactive; self.morph = morph }
  func body(content: Content) -> some View {
    Group {
      if glass.policy.opaque {
        content.background { matched(shape.fill(Color(nsColor: .windowBackgroundColor))) }
          .overlay(shape.stroke(Color.primary.opacity(0.6), lineWidth: 1))
      } else if glass.policy.simplified {
        content.background { matched(shape.fill(.regularMaterial)) }
      } else if let morph {
        content.glassEffect(effect, in: shape).glassEffectID(morph.id, in: morph.namespace)
          .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
      } else {
        content.glassEffect(effect, in: shape)
      }
    }
    .onReceive(MusicGlassPower.changes) { _ in
      glass.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    .transaction { if !glass.policy.animates { $0.animation = nil } }
  }
  private var effect: Glass {
    var value = Glass.regular
    if let tint { value = value.tint(tint) }
    return interactive ? value.interactive() : value
  }
  private var shape: RoundedRectangle { corner.shape }
  @ViewBuilder private func matched<S: View>(_ backing: S) -> some View {
    if let morph, !reduceMotion { backing.matchedGeometryEffect(id: morph.id, in: morph.namespace) } else { backing }
  }
}

private struct MusicButtons: ViewModifier {
  var prominent: Bool
  private var glass = MusicGlassEnvironment()
  func body(content: Content) -> some View {
    Group {
      if glass.policy.opaque || glass.policy.simplified {
        if prominent {
          content.buttonStyle(.borderedProminent)
        } else {
          content.buttonStyle(.bordered)
        }
      } else {
        if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
      }
    }
    .onReceive(MusicGlassPower.changes) { _ in
      glass.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    .transaction { if !glass.policy.animates { $0.animation = nil } }
  }
}

/// Static backdrop; zero ongoing decorative work, including hidden/occluded windows.
public struct MusicCanvas: View {
  private let artworkAccent: Color?
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  public init(artworkAccent: Color? = nil) { self.artworkAccent = artworkAccent }
  public var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)
      if !reduceTransparency && contrast != .increased {
        LinearGradient(
          colors: [(artworkAccent ?? MusicStyle.accent).opacity(0.10), .clear, .primary.opacity(0.04)],
          startPoint: .topLeading, endPoint: .bottomTrailing)
      }
    }.ignoresSafeArea().accessibilityHidden(true).allowsHitTesting(false)
  }
}

/// Window visibility and Low Power state published by the window root (`musicWindowEnvironment`), so every
/// descendant's motion stops while the window is hidden without each one observing the window (MOTION, WIN10).
private struct MusicWindowVisibleKey: EnvironmentKey { static let defaultValue = true }
private struct MusicLowPowerKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  public var musicWindowVisible: Bool {
    get { self[MusicWindowVisibleKey.self] }
    set { self[MusicWindowVisibleKey.self] = newValue }
  }
  public var musicLowPower: Bool {
    get { self[MusicLowPowerKey.self] }
    set { self[MusicLowPowerKey.self] = newValue }
  }
}

/// Resolves a `MusicMotion` token against Reduce Motion, Low Power Mode and window/scene visibility.
private struct MusicMotionModifier<Value: Equatable>: ViewModifier {
  let motion: MusicMotion
  let value: Value
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.musicWindowVisible) private var visible
  @Environment(\.musicLowPower) private var lowPower
  @Environment(\.scenePhase) private var phase
  func body(content: Content) -> some View {
    content.animation(motion.animation(reduceMotion: reduceMotion, lowPower: lowPower, visible: visible && phase != .background), value: value)
  }
}

/// The window root: publishes visibility and Low Power to the motion tokens.
private struct MusicWindowEnvironment: ViewModifier {
  let visible: Bool
  @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
  func body(content: Content) -> some View {
    content.environment(\.musicWindowVisible, visible).environment(\.musicLowPower, lowPower)
      .onReceive(MusicGlassPower.changes) { _ in lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
  }
}

private struct MusicMatched: ViewModifier {
  let id: String
  let namespace: Namespace.ID
  let properties: MatchedGeometryProperties
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View {
    if reduceMotion { content } else { content.matchedGeometryEffect(id: id, in: namespace, properties: properties) }
  }
}

/// Appear/disappear transitions that fall back to a plain crossfade under Reduce Motion.
/// `immediate` inserts and removes without fading: for surfaces whose controls must take input the instant they exist (the bar after Back).
public enum MusicTransitionKind: Sendable {
  case reveal, slideFromTrailing, scaleIn, immediate
  /// The mini-player ↔ Now Playing swap: no fade of its own (the glass morph and matched identities carry the motion, and the incoming bar must take
  /// the next click), and a plain 0.1 s opacity crossfade under Reduce Motion, where the morph and the matched identities stand down.
  case morphSwap
}
private struct MusicTransitionModifier: ViewModifier {
  let kind: MusicTransitionKind
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View {
    content.transition(resolved)
  }
  private var resolved: AnyTransition {
    if kind == .immediate { return .identity }
    if kind == .morphSwap { return reduceMotion ? .opacity : .identity }
    if reduceMotion { return .opacity }
    switch kind {
    case .reveal: return .opacity.combined(with: .scale(scale: 0.98))
    case .slideFromTrailing: return .opacity.combined(with: .move(edge: .trailing))
    case .scaleIn: return .opacity.combined(with: .scale(scale: 0.92))
    case .immediate, .morphSwap: return .identity
    }
  }
}

/// Performs `body` with the token's animation, or without one when motion is off. For state changes made in
/// event handlers (`withAnimation` is reserved to the design system).
@MainActor public func musicWithAnimation<Result>(_ motion: MusicMotion, reduceMotion: Bool, lowPower: Bool, visible: Bool, _ body: () throws -> Result) rethrows -> Result {
  try withAnimation(motion.animation(reduceMotion: reduceMotion, lowPower: lowPower, visible: visible), body)
}

/// Event-handler animations: reads Reduce Motion, Low Power and window visibility from the environment.
public struct MusicMotionContext: DynamicProperty {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.musicWindowVisible) private var visible
  @Environment(\.musicLowPower) private var lowPower
  @Environment(\.scenePhase) private var phase
  public init() {}
  @MainActor public func perform<Result>(_ motion: MusicMotion, _ body: () throws -> Result) rethrows -> Result {
    try musicWithAnimation(motion, reduceMotion: reduceMotion, lowPower: lowPower, visible: visible && phase != .background, body)
  }
}

extension View {
  /// Animates `value` changes with the token, honouring Reduce Motion, Low Power Mode and a hidden window.
  public func musicAnimation<Value: Equatable>(_ motion: MusicMotion, value: Value) -> some View {
    modifier(MusicMotionModifier(motion: motion, value: value))
  }
  /// Same, with the caller's own visibility (a shell that knows more than the environment).
  public func musicAnimation<Value: Equatable>(_ motion: MusicMotion, value: Value, reduceMotion: Bool, lowPower: Bool, visible: Bool) -> some View {
    animation(motion.animation(reduceMotion: reduceMotion, lowPower: lowPower, visible: visible), value: value)
  }
  public func musicTransition(_ kind: MusicTransitionKind = .reveal) -> some View { modifier(MusicTransitionModifier(kind: kind)) }
  public func musicWindowEnvironment(visible: Bool) -> some View { modifier(MusicWindowEnvironment(visible: visible)) }
  public func musicSurface(_ corner: MusicCorner = .panel, tint: Color? = nil, interactive: Bool = false, morph: MusicMorph? = nil) -> some View {
    modifier(MusicSurface(corner: corner, tint: tint, interactive: interactive, morph: morph))
  }
  /// A matched-geometry identity that stands down under Reduce Motion (the swap is then a plain crossfade).
  public func musicMatched(_ id: String, in namespace: Namespace.ID, properties: MatchedGeometryProperties = .frame) -> some View {
    modifier(MusicMatched(id: id, namespace: namespace, properties: properties))
  }
  public func musicButtons(prominent: Bool = false) -> some View {
    modifier(MusicButtons(prominent: prominent))
  }
  public func musicCanvas() -> some View { background { MusicCanvas() } }
}

/// One group per control region; spacing smaller than control gaps prevents merging at rest.
public struct MusicGlassGroup<Content: View>: View {
  private let content: Content
  private let spacing: CGFloat
  public init(spacing: CGFloat = MusicStyle.compact, @ViewBuilder content: () -> Content) { self.spacing = spacing; self.content = content() }
  public var body: some View { GlassEffectContainer(spacing: spacing) { content } }
}
