import SwiftUI

// W28 rework 1 (A11Y02, F6): scalable content text. macOS does not scale third-party SwiftUI text with Dynamic Type (measured: identical widths at every
// `DynamicTypeSize`), so the app provides the scaling itself: the content of a page, and the queue and lyrics panel, is laid out in a space smaller by the
// factor and drawn larger by the same factor. Text, controls, rows and artwork all grow together, rows keep their natural heights (nothing is clipped),
// and the page re-flows to fewer columns instead of overflowing. The chrome (sidebar, toolbar, player bar) keeps the system's own sizes.

/// The scale choices offered in Settings > Appearance.
public enum MusicContentScale {
  public static let choices: [Double] = [1.0, 1.25, 1.5, 2.0]
  public static let storageKey = "contentTextScale"
  /// A stored value clamped to a choice's range (a hand-edited preference cannot make the page unusable).
  public static func normalised(_ value: Double) -> Double { value.isFinite ? min(2.0, max(1.0, value)) : 1.0 }
}
private struct MusicContentScaleKey: EnvironmentKey { static let defaultValue = 1.0 }
extension EnvironmentValues {
  public var musicContentScale: Double {
    get { self[MusicContentScaleKey.self] }
    set { self[MusicContentScaleKey.self] = MusicContentScale.normalised(newValue) }
  }
}
private struct MusicContentZoom: ViewModifier {
  @Environment(\.musicContentScale) private var scale
  func body(content: Content) -> some View {
    if scale <= 1.0001 { content }
    else {
      GeometryReader { proxy in
        content
          .frame(width: proxy.size.width / scale, height: proxy.size.height / scale, alignment: .topLeading)
          .scaleEffect(scale, anchor: .topLeading)
          .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      }
    }
  }
}
extension View {
  /// Lays this content out at `size / scale` and draws it `scale` times larger (the identity at 100%).
  public func musicContentZoom() -> some View { modifier(MusicContentZoom()) }
}

/// W28 rework 1 (A11Y02): a row of a leading part and a trailing part that sits on one line when it fits and stacks (trailing below leading) when larger text or
/// a longer translation makes the line too long. Nothing is truncated or crushed to make a fixed row fit.
public struct MusicAdaptiveRow<Leading: View, Trailing: View>: View {
  let leading: Leading, trailing: Trailing
  public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) { self.leading = leading(); self.trailing = trailing() }
  public var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: MusicSpace.xs) { leading; Spacer(minLength: MusicSpace.xs); trailing }
      VStack(alignment: .leading, spacing: MusicSpace.xs) { leading; trailing }
    }
  }
}
