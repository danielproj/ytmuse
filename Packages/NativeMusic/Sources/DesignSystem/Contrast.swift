import AppKit
import SwiftUI

// W28 (A11Y02, A11Y03, DESIGN05): the contrast model every text colour is audited against. It extends the glass-tint model in
// Tint.swift (secondary text over a washed glass backdrop) to every text role the app draws, in light and dark, with and
// without Increase Contrast and Reduce Transparency, over any album palette. Colours are chosen here, as numbers, so the audit
// and the app read the same constants; nothing is restated in a test.

/// WCAG AA, the project target.
public enum ContrastRequirement: Double, Sendable {
  /// Normal text.
  case normalText = 4.5
  /// Large text (18 pt, or 14 pt bold) and meaningful non-text (control boundaries, informative glyphs).
  case largeTextOrControl = 3.0
}

/// The accessibility conditions a surface can be in. Reduce Transparency and Increase Contrast both make surfaces opaque (see
/// `GlassPolicy.opaque`), which removes the artwork wash entirely: the album colour then touches nothing that carries text.
public enum ContrastMode: String, CaseIterable, Sendable {
  case standard, increasedContrast, reducedTransparency, increasedContrastAndReducedTransparency
  public var increased: Bool { self == .increasedContrast || self == .increasedContrastAndReducedTransparency }
  public var opaque: Bool { self != .standard }
}

/// A colour as encoded sRGB components.
public struct ContrastColor: Equatable, Sendable {
  public let red: Double, green: Double, blue: Double
  public init(_ red: Double, _ green: Double, _ blue: Double) { self.red = red; self.green = green; self.blue = blue }
  public var luminance: Double { 0.2126 * MusicTint.linear(red) + 0.7152 * MusicTint.linear(green) + 0.0722 * MusicTint.linear(blue) }
  public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// The text and glyph colours of the app, per appearance and contrast setting.
public enum MusicPalette {
  /// Body text (`.primary`): black on light, white on dark; the system draws it at full strength under Increase Contrast.
  public static func primaryLuminance(_ scheme: ColorScheme) -> Double { scheme == .dark ? 1 : 0 }
  public static func secondary(_ scheme: ColorScheme, increased: Bool) -> Double {
    scheme == .dark ? (increased ? 0.92 : 0.82) : (increased ? 0.20 : 0.34)
  }
  /// Error text: the system red is 2.5:1 on light and 2.1:1 on dark glass, so errors use a deeper red on light and a lighter one on dark.
  public static func error(_ scheme: ColorScheme, increased: Bool) -> ContrastColor {
    if scheme == .dark { return increased ? ContrastColor(1.00, 0.70, 0.68) : ContrastColor(1.00, 0.58, 0.55) }
    return increased ? ContrastColor(0.55, 0.00, 0.04) : ContrastColor(0.66, 0.00, 0.05)
  }
  /// The brand accent, as text-adjacent glyphs and progress: it must hold 3:1 against the content canvas.
  public static func accent(_ scheme: ColorScheme, increased: Bool) -> ContrastColor {
    if scheme == .dark { return increased ? ContrastColor(1.00, 0.68, 0.72) : ContrastColor(1.00, 0.55, 0.60) }
    return increased ? ContrastColor(0.52, 0.06, 0.14) : ContrastColor(0.62, 0.10, 0.18)
  }
  /// The FILL behind the white glyph of the prominent Play/Pause buttons. The lighter `accent` that passes as a glyph on the canvas (1.00, 0.55, 0.60 in dark) is only
  /// 2.2:1 under a white glyph, so the fill is its own, deeper colour in both appearances (white on it is 6.2:1 or better).
  public static func accentFill(_ scheme: ColorScheme, increased: Bool) -> ContrastColor {
    increased ? ContrastColor(0.55, 0.06, 0.14) : ContrastColor(0.72, 0.16, 0.24)
  }
  /// The glyph drawn on `accentFill`.
  public static let glyphOnAccentFill = ContrastColor(1, 1, 1)
  /// Badge fills with white text (Live): the pure system red and gray were 4.0:1.
  public static let liveBadgeAtEdge = ContrastColor(0.70, 0.04, 0.08)
  public static let liveBadgeBehind = ContrastColor(0.35, 0.35, 0.35)
  public static let badgeText = ContrastColor(1, 1, 1)
  /// The yellow Ad badge keeps black text (19.6:1).
  public static let advertisementFill = ContrastColor(1, 1, 0)
  public static let advertisementText = ContrastColor(0, 0, 0)
}

/// The luminance a surface can have behind text. Glass is whatever lies under the window (see `MusicTint.backdropRange`); the content canvas is the
/// window background and the cards drawn on it, which is calmer.
public enum ContrastBackdrop: Sendable {
  case glass, content
  public func range(_ scheme: ColorScheme) -> ClosedRange<Double> {
    switch self {
    case .glass: MusicTint.backdropRange(scheme)
    case .content: scheme == .dark ? 0.008...0.05 : 0.78...1.0
    }
  }
}

public struct ContrastSample: Equatable, Sendable, CustomStringConvertible {
  public let role: String
  public let scheme: ColorScheme
  public let mode: ContrastMode
  /// Index into the palettes audited, nil when no album colour is involved.
  public let palette: Int?
  public let ratio: Double
  public let requirement: ContrastRequirement
  public var passes: Bool { ratio >= requirement.rawValue }
  public var description: String { "\(role) \(scheme) \(mode.rawValue) palette=\(palette.map(String.init) ?? "-") \(String(format: "%.2f", ratio)):1 (needs \(requirement.rawValue))" }
}

public enum ContrastAudit {
  /// Album palettes: the extremes (white, black, mid gray), the six saturated primaries and secondaries, and a hue sweep at three lightnesses.
  /// The artwork accent is a vivid-weighted average (ArtworkAccent), so these cover what it can produce.
  public static let albumPalettes: [MusicTint] = {
    var out = [MusicTint(red: 1, green: 1, blue: 1), MusicTint(red: 0, green: 0, blue: 0), MusicTint(red: 0.5, green: 0.5, blue: 0.5),
               MusicTint(red: 1, green: 0, blue: 0), MusicTint(red: 0, green: 1, blue: 0), MusicTint(red: 0, green: 0, blue: 1),
               MusicTint(red: 1, green: 1, blue: 0), MusicTint(red: 0, green: 1, blue: 1), MusicTint(red: 1, green: 0, blue: 1)]
    for lightness in [0.3, 0.55, 0.8] {
      for step in 0..<12 {
        let c = NSColor(hue: Double(step) / 12, saturation: 0.9, brightness: lightness, alpha: 1).usingColorSpace(.sRGB)!
        out.append(MusicTint(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent))
      }
    }
    return out
  }()
  static func contrast(_ a: Double, _ b: Double) -> Double { MusicTint.contrast(a, b) }
  /// The worst ratio of a foreground luminance against the backdrop range (ends decide: contrast is monotonic in the backdrop).
  static func worst(_ foreground: Double, over range: ClosedRange<Double>) -> Double {
    min(contrast(foreground, range.lowerBound), contrast(foreground, range.upperBound))
  }
  /// The worst contrast of a colour over a backdrop class in an appearance (public so a test can hold an old colour up as a control).
  public static func worstRatio(_ foreground: ContrastColor, scheme: ColorScheme, over backdrop: ContrastBackdrop) -> Double {
    worst(foreground.luminance, over: backdrop.range(scheme))
  }
  /// Every audited role for one appearance and mode, over every album palette that can reach it. Roles on the content canvas never see the
  /// palette (palette = nil); text on glass sees the washed backdrop at the opacity the tint model allows, which is zero when the surface is opaque.
  public static func samples(scheme: ColorScheme, mode: ContrastMode, palettes: [MusicTint] = albumPalettes) -> [ContrastSample] {
    var out: [ContrastSample] = []
    func add(_ role: String, _ palette: Int?, _ ratio: Double, _ requirement: ContrastRequirement) {
      out.append(ContrastSample(role: role, scheme: scheme, mode: mode, palette: palette, ratio: ratio, requirement: requirement))
    }
    let secondary = MusicTint.linear(MusicPalette.secondary(scheme, increased: mode.increased))
    let primary = MusicPalette.primaryLuminance(scheme)
    let error = MusicPalette.error(scheme, increased: mode.increased).luminance
    let accent = MusicPalette.accent(scheme, increased: mode.increased).luminance
    // Content canvas: no album colour involved.
    add("primary text on content", nil, worst(primary, over: ContrastBackdrop.content.range(scheme)), .normalText)
    add("secondary text on content", nil, worst(secondary, over: ContrastBackdrop.content.range(scheme)), .normalText)
    add("error text on content", nil, worst(error, over: ContrastBackdrop.content.range(scheme)), .normalText)
    add("accent glyph on content", nil, worst(accent, over: ContrastBackdrop.content.range(scheme)), .largeTextOrControl)
    // The glyph of a prominent control on its tinted fill (Play/Pause).
    add("glyph on accent fill", nil, contrast(MusicPalette.accentFill(scheme, increased: mode.increased).luminance, MusicPalette.glyphOnAccentFill.luminance), .largeTextOrControl)
    // Glass: the artwork wash is part of the backdrop unless the surface is opaque.
    add("primary text on glass", nil, worst(primary, over: ContrastBackdrop.glass.range(scheme)), .normalText)
    for (index, tint) in palettes.enumerated() {
      let opacity = mode.opaque ? 0 : tint.glassOpacity(scheme: scheme)
      let ratio = washedSecondaryContrast(tint: tint, opacity: opacity, scheme: scheme, textLuminance: secondary)
      add("secondary text on tinted glass", index, ratio, .normalText)
      // The strongest wash the player ever draws (the expanded player's glass tint plus radial light, each at half share) is bounded by the same solved opacity.
      add("primary text on tinted glass", index, washedContrast(tint: tint, opacity: opacity, scheme: scheme, textLuminance: primary), .normalText)
    }
    // Badges are fixed colours: they do not depend on appearance.
    add("live badge (edge)", nil, contrast(MusicPalette.liveBadgeAtEdge.luminance, MusicPalette.badgeText.luminance), .normalText)
    add("live badge (behind)", nil, contrast(MusicPalette.liveBadgeBehind.luminance, MusicPalette.badgeText.luminance), .normalText)
    add("advertisement badge", nil, contrast(MusicPalette.advertisementFill.luminance, MusicPalette.advertisementText.luminance), .normalText)
    return out
  }
  static func washedContrast(tint: MusicTint, opacity: Double, scheme: ColorScheme, textLuminance: Double) -> Double {
    let range = MusicTint.backdropRange(scheme)
    return [range.lowerBound, range.upperBound].map { backdrop in
      let gray = MusicTint.encoded(backdrop)
      let blended = { (channel: Double) in (1 - opacity) * gray + opacity * channel }
      let washed = 0.2126 * MusicTint.linear(blended(tint.red)) + 0.7152 * MusicTint.linear(blended(tint.green)) + 0.0722 * MusicTint.linear(blended(tint.blue))
      return contrast(washed, textLuminance)
    }.min() ?? 0
  }
  static func washedSecondaryContrast(tint: MusicTint, opacity: Double, scheme: ColorScheme, textLuminance: Double) -> Double {
    washedContrast(tint: tint, opacity: opacity, scheme: scheme, textLuminance: textLuminance)
  }
  public static func failures(palettes: [MusicTint] = albumPalettes) -> [ContrastSample] {
    var out: [ContrastSample] = []
    for scheme in [ColorScheme.light, .dark] { for mode in ContrastMode.allCases { out += samples(scheme: scheme, mode: mode, palettes: palettes).filter { !$0.passes } } }
    return out
  }
}
