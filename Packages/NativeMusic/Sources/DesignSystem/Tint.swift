import SwiftUI

/// Artwork-derived light for glass (GLASS04/GLASS11). The artwork never decides whether text is readable: the opacity at which a tint may wash
/// glass is solved so that secondary text keeps its contrast over the tinted backdrop, at the WORST backdrop the glass can plausibly have.
///
/// This is a model, not a measurement: `Glass.tint` is not a linear alpha wash, and the real backdrop is whatever sits under the glass. The model
/// takes the luminance range realistic glass has under a window in each appearance (see `backdropRange`) and requires the contrast at both ends.
/// The measurement on a real console stays with `Tests/DesignSystem/MeasureGlassContrast.swift`.
public struct MusicTint: Equatable, Sendable {
  public let red: Double, green: Double, blue: Double
  public init(red: Double, green: Double, blue: Double) {
    self.red = min(1, max(0, red)); self.green = min(1, max(0, green)); self.blue = min(1, max(0, blue))
  }
  /// WCAG contrast the tinted backdrop must keep with the app's secondary text.
  public static let minimumContrast = 4.5
  /// The strongest wash glass ever receives.
  public static let maximumOpacity = 0.18
  /// Relative luminance of the glass backdrop under a window, lightest and darkest plausible: dark glass is not darker than 0.03 nor lighter than 0.10;
  /// light glass is not lighter than 0.95 nor darker than 0.70. Contrast with text of fixed luminance is monotonic in the backdrop, so the ends decide.
  public static func backdropRange(_ scheme: ColorScheme) -> ClosedRange<Double> { scheme == .dark ? 0.03...0.10 : 0.70...0.95 }
  /// Luminance of `MusicStyle.secondaryText` (opaque gray; see `MusicStyle.secondaryGray`).
  static func secondaryTextLuminance(_ scheme: ColorScheme) -> Double { MusicTint.linear(MusicStyle.secondaryGray(scheme)) }
  static func linear(_ component: Double) -> Double { component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4) }
  static func encoded(_ luminance: Double) -> Double { luminance <= 0.0031308 ? luminance * 12.92 : 1.055 * pow(luminance, 1 / 2.4) - 0.055 }
  public var luminance: Double { 0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue) }
  public static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
  /// The worst contrast of secondary text over the backdrop washed with this tint at `opacity`, across the plausible backdrop range.
  public func secondaryTextContrast(opacity: Double, scheme: ColorScheme) -> Double {
    let range = Self.backdropRange(scheme)
    return [range.lowerBound, range.upperBound].map { backdrop in
      // Alpha blending happens on the encoded (sRGB) channels, so the blend is done there, not on luminance.
      let gray = Self.encoded(backdrop)
      let blended = { (channel: Double) in (1 - opacity) * gray + opacity * channel }
      let washed = 0.2126 * Self.linear(blended(red)) + 0.7152 * Self.linear(blended(green)) + 0.0722 * Self.linear(blended(blue))
      return Self.contrast(washed, Self.secondaryTextLuminance(scheme))
    }.min() ?? 0
  }
  /// The largest opacity up to `maximumOpacity` that keeps `minimumContrast` at the worst backdrop (0 when even the plain backdrop falls short).
  public func glassOpacity(scheme: ColorScheme) -> Double {
    var opacity = Self.maximumOpacity
    while opacity > 0.005, secondaryTextContrast(opacity: opacity, scheme: scheme) < Self.minimumContrast { opacity -= 0.005 }
    return opacity > 0.005 ? opacity : 0
  }
  public var color: Color { Color(red: red, green: green, blue: blue) }
  /// `share` is this layer's fraction of the solved wash: two layers over the same pixels (the expanded player's glass tint and its radial light) take
  /// half each, so together they stay within the one wash the model was solved for.
  public func glassColor(scheme: ColorScheme, share: Double = 1) -> Color {
    Color(red: red, green: green, blue: blue).opacity(glassOpacity(scheme: scheme) * min(1, max(0, share)))
  }
}
