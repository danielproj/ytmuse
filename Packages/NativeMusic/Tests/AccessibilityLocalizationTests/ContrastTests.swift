import Testing
import SwiftUI
import AppKit
import DesignSystem

// W28 T28.2: WCAG AA over every text role, album palette, appearance and accessibility mode. Normal text 4.5:1; large text and meaningful non-text 3:1.

@Suite struct ContrastModelTests {
  @Test func wcagArithmeticMatchesKnownValues() {
    #expect(abs(MusicTint.contrast(1, 0) - 21) < 1e-9, "white on black is 21:1")
    #expect(abs(MusicTint.contrast(0.5, 0.5) - 1) < 1e-9)
    let gray = ContrastColor(0.46667, 0.46667, 0.46667)   // #777 on white: the textbook 4.48:1 — just under AA for normal text.
    #expect(abs(MusicTint.contrast(1, gray.luminance) - 4.48) < 0.02)
  }
  @Test func everyRoleMeetsItsRequirementInEveryAppearanceAndMode() {
    let failures = ContrastAudit.failures()
    #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) contrast failures, first:\n" + failures.prefix(12).map(\.description).joined(separator: "\n")))
  }
  @Test func theAuditCoversEveryCombinationAndEveryPalette() {
    var seen = Set<String>()
    var tinted = 0
    for scheme in [ColorScheme.light, .dark] {
      for mode in ContrastMode.allCases {
        let samples = ContrastAudit.samples(scheme: scheme, mode: mode)
        #expect(samples.count > ContrastAudit.albumPalettes.count * 2, "\(scheme) \(mode): samples for every palette")
        seen.formUnion(samples.map(\.role))
        tinted += samples.filter { $0.palette != nil }.count
      }
    }
    #expect(ContrastAudit.albumPalettes.count >= 45, "a hue sweep at three lightnesses plus the extremes (\(ContrastAudit.albumPalettes.count))")
    #expect(tinted == 2 * 4 * ContrastAudit.albumPalettes.count * 2)
    for role in ["glyph on accent fill", "primary text on content", "secondary text on content", "error text on content", "accent glyph on content", "primary text on glass", "secondary text on tinted glass", "primary text on tinted glass", "live badge (edge)", "live badge (behind)", "advertisement badge"] {
      #expect(seen.contains(role), "role audited: \(role)")
    }
  }
  /// Controls: the colours this node replaced fail the same audit, so a passing audit is not a model that cannot fail.
  @Test func theColoursThatWereReplacedFailTheSameRules() {
    let systemRedLight = ContrastColor(1.0, 0.231, 0.188), systemRedDark = ContrastColor(1.0, 0.271, 0.227)
    #expect(ContrastAudit.worstRatio(systemRedLight, scheme: .light, over: .content) < ContrastRequirement.normalText.rawValue, "system red text on light fails 4.5:1")
    #expect(ContrastAudit.worstRatio(systemRedDark, scheme: .dark, over: .content) < ContrastRequirement.normalText.rawValue, "system red text on dark fails 4.5:1")
    #expect(MusicTint.contrast(ContrastColor(1, 0, 0).luminance, MusicPalette.badgeText.luminance) < 4.5, "white on pure red (the old Live badge) fails")
    #expect(MusicTint.contrast(ContrastColor(0.5, 0.5, 0.5).luminance, MusicPalette.badgeText.luminance) < 4.5, "white on system gray (the old Live badge) fails")
    let oldAccent = ContrastColor(0.72, 0.16, 0.24)
    #expect(ContrastAudit.worstRatio(oldAccent, scheme: .dark, over: .content) < ContrastRequirement.largeTextOrControl.rawValue, "the old accent glyph on dark fails 3:1")
    // The new ones pass with room.
    for scheme in [ColorScheme.light, .dark] {
      #expect(ContrastAudit.worstRatio(MusicPalette.error(scheme, increased: false), scheme: scheme, over: .content) >= 4.5)
      #expect(ContrastAudit.worstRatio(MusicPalette.accent(scheme, increased: false), scheme: scheme, over: .content) >= 3.0)
    }
  }
  @Test func increaseContrastIsStrongerNotWeaker() {
    for scheme in [ColorScheme.light, .dark] {
      let range = ContrastBackdrop.glass.range(scheme)
      func ratio(_ gray: Double) -> Double { ContrastAudit.worstRatio(ContrastColor(gray, gray, gray), scheme: scheme, over: .glass) }
      #expect(ratio(MusicPalette.secondary(scheme, increased: true)) > ratio(MusicPalette.secondary(scheme, increased: false)), "\(scheme) secondary text over \(range)")
      #expect(ContrastAudit.worstRatio(MusicPalette.error(scheme, increased: true), scheme: scheme, over: .content) > ContrastAudit.worstRatio(MusicPalette.error(scheme, increased: false), scheme: scheme, over: .content))
      #expect(ContrastAudit.worstRatio(MusicPalette.accent(scheme, increased: true), scheme: scheme, over: .content) > ContrastAudit.worstRatio(MusicPalette.accent(scheme, increased: false), scheme: scheme, over: .content))
    }
  }
  @Test func reducedTransparencyAndIncreasedContrastRemoveTheAlbumColourFromTextBackdrops() {
    // Opaque surfaces draw the window background, not the wash: whatever the album colour, the ratio is the same.
    for scheme in [ColorScheme.light, .dark] {
      for mode in [ContrastMode.reducedTransparency, .increasedContrastAndReducedTransparency, .increasedContrast] {
        let ratios = Set(ContrastAudit.samples(scheme: scheme, mode: mode).filter { $0.role == "secondary text on tinted glass" }.map { String(format: "%.6f", $0.ratio) })
        #expect(ratios.count == 1, "\(scheme) \(mode): \(ratios.count) distinct ratios across palettes; the album colour must not reach text")
      }
      let standard = Set(ContrastAudit.samples(scheme: scheme, mode: .standard).filter { $0.role == "secondary text on tinted glass" }.map { String(format: "%.6f", $0.ratio) })
      #expect(standard.count > 1, "control: in the standard mode the wash does vary with the palette")
    }
  }
  @Test func theWashNeverExceedsWhatTheSolverAllowsAndAlbumColourCannotCarryEssentialText() {
    for tint in ContrastAudit.albumPalettes {
      for scheme in [ColorScheme.light, .dark] {
        let opacity = tint.glassOpacity(scheme: scheme)
        #expect(opacity <= MusicTint.maximumOpacity + 1e-9)
        #expect(tint.secondaryTextContrast(opacity: opacity, scheme: scheme) >= MusicTint.minimumContrast - 1e-6 || opacity == 0 && tint.secondaryTextContrast(opacity: 0, scheme: scheme) >= MusicTint.minimumContrast)
      }
    }
  }
  @Test func theAppliedColoursAreTheAuditedOnes() {
    // Resolve the colours the views draw under the two appearances a headless process can impose, and compare with the audited constants.
    func resolve(_ color: NSColor, _ name: NSAppearance.Name) -> (Double, Double, Double) {
      var out = (0.0, 0.0, 0.0)
      NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        let c = color.usingColorSpace(.sRGB)!
        out = (c.redComponent, c.greenComponent, c.blueComponent)
      }
      return out
    }
    for (name, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
      let error = MusicPalette.error(scheme, increased: false), got = resolve(MusicStyle.errorTextNSColor, name)
      #expect(abs(got.0 - error.red) < 0.01 && abs(got.1 - error.green) < 0.01 && abs(got.2 - error.blue) < 0.01, "errorText in \(name.rawValue)")
      #expect(abs(resolve(MusicStyle.secondaryTextNSColor, name).0 - MusicPalette.secondary(scheme, increased: false)) < 0.01, "secondaryText in \(name.rawValue)")
      let accent = MusicPalette.accent(scheme, increased: false), a = resolve(MusicStyle.accentNSColor, name)
      #expect(abs(a.0 - accent.red) < 0.01 && abs(a.1 - accent.green) < 0.01, "accent in \(name.rawValue)")
    }
    // The system gives a provider the high-contrast appearances only while Increase Contrast is on, which a test process cannot switch; the mapping
    // from appearance to (dark, increased) is therefore tested by name, and the colours it selects are the audited `MusicPalette` values above.
    #expect(MusicStyle.traits(of: .aqua) == (false, false) && MusicStyle.traits(of: .darkAqua) == (true, false))
    #expect(MusicStyle.traits(of: .accessibilityHighContrastAqua) == (false, true) && MusicStyle.traits(of: .accessibilityHighContrastDarkAqua) == (true, true))
    #expect(MusicStyle.traits(of: .vibrantDark) == (true, false))
  }

  // F5: the tinted Play/Pause button as it is drawn (a filled circle under a white glyph), sampled from pixels, not only from the model.
  @MainActor private func fillPixelLuminance(of fill: Color, appearance: NSAppearance.Name) -> Double {
    let view = NSHostingView(rootView: ZStack { Circle().fill(fill); Image(systemName: "play.fill").foregroundStyle(.white).font(.system(size: 20)) }.frame(width: 60, height: 60))
    view.appearance = NSAppearance(named: appearance)
    view.frame = NSRect(x: 0, y: 0, width: 60, height: 60); view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    // A point inside the circle, clear of the glyph: left of centre.
    let c = rep.colorAt(x: 12, y: 30)!.usingColorSpace(.sRGB)!
    return ContrastColor(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)).luminance
  }
  @MainActor @Test func theTintedPlayButtonKeepsThreeToOneBehindItsWhiteGlyph() {
    for (name, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
      let drawn = fillPixelLuminance(of: MusicStyle.accentFill, appearance: name)
      #expect(MusicTint.contrast(1, drawn) >= 3.0, "\(scheme): white glyph on the drawn fill is \(MusicTint.contrast(1, drawn)):1")
      let modelled = MusicPalette.accentFill(scheme, increased: false).luminance
      #expect(abs(drawn - modelled) < 0.02, "the drawn fill is the audited one (\(drawn) vs \(modelled))")
      // Control: the lighter accent that passes as a glyph on the canvas is NOT a usable fill under a white glyph.
      let old = fillPixelLuminance(of: MusicStyle.accent, appearance: name)
      if scheme == .dark { #expect(MusicTint.contrast(1, old) < 3.0, "control: the dark accent as a fill would be \(MusicTint.contrast(1, old)):1") }
    }
    for scheme in [ColorScheme.light, .dark] { for increased in [false, true] {
      #expect(MusicTint.contrast(1, MusicPalette.accentFill(scheme, increased: increased).luminance) >= (increased ? 4.5 : 3.0), "\(scheme) increased=\(increased)")
    } }
  }
}
