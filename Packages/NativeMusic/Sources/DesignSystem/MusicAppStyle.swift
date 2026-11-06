import AppKit
import Domain
import SwiftUI

// APPEARANCE-STYLE: the Standard style beside the app's own look. Every branch on the style lives here, in the design system, so feature and
// shell code never picks a material or a window background itself (SourceGuardTests). The YTMuse branch of every decision is today's code path,
// unchanged (YTMuseLookParityTests pins it against a rendering recorded before this work).

private struct MusicAppStyleKey: EnvironmentKey { static let defaultValue = AppStyle.defaultStyle }
private struct MusicTranslucentWindowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  /// The app style of this window, injected once at the window root (AppShell's `appAppearance()` / `appStyle(...)`).
  /// A view outside any root reads the default style, the same one a fresh install uses (WindowRootStyleTests keeps every root injecting it).
  public var musicAppStyle: AppStyle {
    get { self[MusicAppStyleKey.self] }
    set { self[MusicAppStyleKey.self] = newValue }
  }
  /// True inside a window whose background is the system window material (`musicWindowMaterial`): the canvas stands down there so the
  /// material, and the desktop behind it, show.
  public var musicTranslucentWindow: Bool {
    get { self[MusicTranslucentWindowKey.self] }
    set { self[MusicTranslucentWindowKey.self] = newValue }
  }
}

/// What lies behind a window's content.
public enum MusicWindowBackdrop: Equatable, Sendable {
  /// The app's own canvas (`MusicCanvas`): near-black in dark, the window background with a faint accent wash in light.
  case ytmuseCanvas
  /// Standard, in a window that may be translucent: the system window material, so the desktop shows through behind the window.
  case systemMaterial
  /// Standard elsewhere (sheets, Settings, the mini-player, the popover, full screen), or under Reduce Transparency / Increase Contrast:
  /// the opaque system window background.
  case systemOpaque

  /// `translucentWindow`: the window is one that may show the desktop (the main window). `opaque`: `GlassPolicy.opaque`.
  public static func resolve(style: AppStyle, translucentWindow: Bool, opaque: Bool) -> Self {
    switch style {
    case .ytmuse: .ytmuseCanvas
    case .standard: translucentWindow && !opaque ? .systemMaterial : .systemOpaque
    }
  }
}

/// The scrim laid inside glass panels (`musicSurface`, the player capsule), per style.
///
/// YTMuse: 0.5 black in dark, none in light. Behind the glass is the app's own opaque canvas, so the glass backdrop already sits inside
/// `MusicTint.backdropRange`.
///
/// Standard: none. The account holder asked for the panels without the black (2026-11-06), so Standard panels are plain Liquid Glass over the
/// window material, as in Finder. Their legibility over the wallpaper rests on the system material, as every system app's does; it is not
/// computed. (A scrim solved for any desktop, 0.76 black / 0.90 white, was tried first and made the panels near-solid.) Under Increase
/// Contrast or Reduce Transparency the panels are opaque system surfaces, audited in StandardStyleContrastTests.
public enum MusicGlassScrim {
  public static func opacity(_ scheme: ColorScheme, style: AppStyle) -> Double {
    switch style {
    case .ytmuse: scheme == .dark ? MusicPalette.darkGlassScrim : 0
    case .standard: 0
    }
  }
  public static func color(_ scheme: ColorScheme, style: AppStyle) -> Color {
    let opacity = opacity(scheme, style: style)
    if opacity == 0 { return .clear }
    return Color.black.opacity(opacity)
  }
}

/// The window material Standard puts behind a translucent window (GLASS09: the system's own material, not an imitation blur).
private struct MusicWindowMaterial: ViewModifier {
  let enabled: Bool
  @Environment(\.musicAppStyle) private var style
  private var glass = MusicGlassEnvironment()
  func body(content: Content) -> some View {
    let translucent = MusicWindowBackdrop.resolve(style: style, translucentWindow: enabled, opaque: glass.policy.opaque) == .systemMaterial
    // The material is set from an empty sibling, not by wrapping `content`: a branch around `content` would rebuild the whole window (its
    // navigation, scroll positions and web views) at every Style switch. Set from a sibling, the window background follows live and the
    // content keeps its identity; with the material off, the window is exactly today's (opaque system background, glass sampling in-window).
    content.environment(\.musicTranslucentWindow, translucent)
      .background { MusicWindowMaterialSetter(enabled: translucent) }
  }
}

private struct MusicWindowMaterialSetter: View {
  let enabled: Bool
  var body: some View {
    if enabled {
      Color.clear.containerBackground(.thinMaterial, for: .window).accessibilityHidden(true).allowsHitTesting(false)
    } else {
      Color.clear.accessibilityHidden(true).allowsHitTesting(false)
    }
  }
}

extension View {
  /// A window root. `enabled`: the window may be translucent under the Standard style (the main window). Under YTMuse, Reduce
  /// Transparency or Increase Contrast, or when not enabled, the window background is untouched.
  public func musicWindowMaterial(enabled: Bool) -> some View { modifier(MusicWindowMaterial(enabled: enabled)) }
}
