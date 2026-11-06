import AppKit
import DesignSystem
import Domain
import SwiftUI
import Testing

/// APPEARANCE-STYLE: Standard panels are plain Liquid Glass with NO scrim (the account holder asked for the black to go, 2026-11-06). Their
/// legibility over the wallpaper therefore rests on the system window material, as every system app's does, and is the account holder's visual
/// check. What IS computed and held here: the panels really carry no scrim, the opaque fallback under Increase Contrast / Reduce Transparency is
/// the system window background with every text role passing on it, and a control records why the material is load-bearing.
@Suite struct StandardStyleContrastTests {
  static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
  static func gray(_ value: Double) -> Double { ContrastColor(value, value, value).luminance }
  /// The system window background's luminance in an appearance (what Standard's opaque surfaces are).
  static func windowBackground(_ name: NSAppearance.Name) -> Double {
    var luminance = 0.0
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
      let c = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
      luminance = ContrastColor(c.redComponent, c.greenComponent, c.blueComponent).luminance
    }
    return luminance
  }

  @Test func standardPanelsCarryNoScrim() {
    for scheme in [ColorScheme.dark, .light] {
      #expect(MusicGlassScrim.opacity(scheme, style: .standard) == 0, "\(scheme): no black (or white) wash inside Standard glass")
    }
    #expect(MusicGlassScrim.opacity(.dark, style: .ytmuse) == MusicPalette.darkGlassScrim, "YTMuse keeps its deep-dark scrim")
    #expect(MusicPalette.standardCardTint > 0 && MusicPalette.standardCardTint <= 0.1, "a Standard card is a faint tint that still marks the group, not a dark slab")
    #expect(MusicStyle.card(.ytmuse) == MusicStyle.card, "YTMuse cards are unchanged")
  }

  /// GLASS05: under Increase Contrast or Reduce Transparency, Standard's panels and window are the opaque system window background. Every text
  /// role meets WCAG on it, in the appearance the system actually uses for each mode (high-contrast appearances under Increase Contrast).
  @Test func theOpaqueStandardFallbackPassesForEveryRole() {
    var checked = 0
    for (scheme, increased, name) in [(ColorScheme.dark, false, NSAppearance.Name.darkAqua), (.dark, true, .accessibilityHighContrastDarkAqua),
                                      (.light, false, .aqua), (.light, true, .accessibilityHighContrastAqua)] {
      let background = Self.windowBackground(name)
      let roles: [(String, Double, ContrastRequirement)] = [
        ("primary", MusicPalette.primaryLuminance(scheme), .normalText),
        ("secondary", Self.gray(MusicPalette.secondary(scheme, increased: increased)), .normalText),
        ("error", MusicPalette.error(scheme, increased: increased).luminance, .normalText),
        ("accent glyph", MusicPalette.accent(scheme, increased: increased).luminance, .largeTextOrControl),
      ]
      for (role, luminance, requirement) in roles {
        let ratio = MusicTint.contrast(luminance, background)
        #expect(ratio >= requirement.rawValue, "\(role) \(name.rawValue): \(String(format: "%.2f", ratio)):1 on the window background, needs \(requirement.rawValue)")
        checked += 1
      }
    }
    #expect(checked == 16)
  }

  /// Control, and the record of the trade-off: with no scrim, if the window material contributed nothing, secondary text over a white desktop
  /// would fail. Legibility in Standard rests on the system material (it darkens in dark and lightens in light); this is not computed here.
  @Test func withoutTheSystemMaterialAWhiteDesktopWouldFail() {
    let secondary = Self.gray(MusicPalette.secondary(.dark, increased: false))
    #expect(MusicTint.contrast(secondary, Self.linear(1)) < 4.5)
    let scrim = MusicGlassScrim.opacity(.dark, style: .standard)
    #expect(MusicTint.contrast(secondary, Self.linear((1 - scrim) * 1)) < 4.5, "nothing in Standard's own drawing protects text over a white desktop")
  }
}

extension StandardStyleContrastTests {
  /// Model only: AppKit's standard accent hues on the opaque content background, without native control treatments.
  /// Some system hues (notably yellow on light) fall below 3:1 as bare glyphs. Native controls own their contrast treatment;
  /// this records that limit explicitly rather than claiming the brand palette test covers the system accent.
  @Test func modeledSystemAccentGlyphs() {
    let accents: [(String, NSColor)] = [("blue", .systemBlue), ("purple", .systemPurple), ("pink", .systemPink),
      ("red", .systemRed), ("orange", .systemOrange), ("yellow", .systemYellow), ("green", .systemGreen), ("graphite", .systemGray)]
    var checked = 0
    for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
      let background = Self.windowBackground(appearance)
      NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        for (name, color) in accents {
          let c = color.usingColorSpace(.sRGB)!
          let ratio = MusicTint.contrast(ContrastColor(c.redComponent, c.greenComponent, c.blueComponent).luminance, background)

          // Graphite is approximated by systemGray. These high-contrast appearances
          // resolve the same hue values; this model does not cover separate HC variants.
          let dark = appearance == .darkAqua || appearance == .accessibilityHighContrastDarkAqua
          #expect((ratio >= 3) == (dark || !["orange", "yellow", "green"].contains(name)))

          print("System accent model: \(appearance.rawValue) \(name) \(String(format: "%.2f", ratio)):1; 3:1 \(ratio >= 3 ? "met" : "requires system treatment")")
          checked += 1
        }
      }
    }
    #expect(checked == 32)
  }
}


extension StandardStyleContrastTests {
  @Test @MainActor func productionFillGlyphMatchesApprovedTable() {
    let accents: [(String, NSColor, Bool, Bool)] = [
      ("blue", .systemBlue, false, false), ("purple", .systemPurple, false, false),
      ("pink", .systemPink, false, false), ("red", .systemRed, false, false),
      ("orange", .systemOrange, true, true), ("yellow", .systemYellow, true, true),
      ("green", .systemGreen, true, true), ("graphite", .systemGray, false, true),
    ]
    var checked = 0
    for (scheme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
      NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        for (name, accent, lightBlack, darkBlack) in accents {
          let fill = Color(nsColor: accent)
          let expectedBlack = scheme == .dark ? darkBlack : lightBlack
          #expect(MusicFillGlyph.color(on: fill, in: env) == (expectedBlack ? Color.black : .white), "\(name) \(scheme)")
          let resolved = fill.resolve(in: env)
          let luminance = ContrastColor(Double(resolved.red), Double(resolved.green), Double(resolved.blue)).luminance
          // The 3:1 floor holds by construction; the table above pins the chosen glyph.
          #expect(MusicTint.contrast(expectedBlack ? 0 : 1, luminance) >= 3)
          checked += 1
        }
      }
    }
    #expect(checked == 16)
  }

  // Color.resolve(in:) does not select high-contrast variants. Those rows pin the production
  // decision; ContrastTests.theTintedPlayButtonKeepsThreeToOneBehindItsWhiteGlyph covers the darker fill.
  @Test @MainActor func productionYTMuseFillGlyphStaysWhite() {
    var checked = 0
    for (scheme, appearance) in [
      (ColorScheme.light, NSAppearance.Name.aqua),
      (.dark, .darkAqua),
      (.light, .accessibilityHighContrastAqua),
      (.dark, .accessibilityHighContrastDarkAqua),
    ] {
      NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        #expect(MusicFillGlyph.color(on: MusicStyle.accentFill, in: env) == .white, "\(appearance.rawValue)")
        checked += 1
      }
    }
    #expect(checked == 4)
  }
}
