import AppKit
import Domain
import SwiftUI

public enum MusicActionRole: CaseIterable, Sendable {
  case primary, secondary, inline
  public var tintSource: MusicActionTintSource { self == .primary ? .fill : .inherited }
  public var treatment: MusicActionTreatment {
    switch self { case .primary: .borderedProminent; case .secondary: .bordered; case .inline: .borderless }
  }
}
public enum MusicActionTintSource: Sendable { case fill, inherited }
public enum MusicActionTreatment: Equatable, Sendable { case borderedProminent, bordered, borderless }
private struct MusicAction: ViewModifier {
  let role: MusicActionRole
  @Environment(\.musicAccentFill) private var accentFill
  private var tint: Color? {
    switch role.tintSource { case .fill: accentFill; case .inherited: nil }
  }
  func body(content: Content) -> some View {
    switch role.treatment {
    case .borderedProminent: content.buttonStyle(.borderedProminent).tint(tint)
    case .bordered: content.buttonStyle(.bordered)
    case .borderless: content.buttonStyle(.borderless)
    }
  }
}
public enum MusicContentBackground: Equatable, Sendable {
  case systemOpaque, canvas
  public static func resolve(_ style: AppStyle) -> Self { style == .standard ? .systemOpaque : .canvas }
  public var color: Color { self == .systemOpaque ? Color(nsColor: .windowBackgroundColor) : .clear }
}
private struct MusicContentRegion: ViewModifier {
  @Environment(\.musicAppStyle) private var style
  func body(content: Content) -> some View {
    content.background(MusicContentBackground.resolve(style).color)
  }
}
private struct MusicInspector: ViewModifier {
  @Environment(\.musicAppStyle) private var style
  func body(content: Content) -> some View {
    content.frame(maxHeight: .infinity).background(style == .standard ? Color(nsColor: .windowBackgroundColor) : MusicStyle.canvas)
      .overlay(alignment: .leading) { HStack(spacing: 0) { Divider(); Spacer(minLength: 0) }.allowsHitTesting(false) }
  }
}
extension View {
  /// Destructive actions use Button(role: .destructive) with a secondary or inline treatment.
  public func musicAction(_ role: MusicActionRole) -> some View { modifier(MusicAction(role: role)) }
  public func musicContentRegion() -> some View { modifier(MusicContentRegion()) }
  public func musicInspector() -> some View { modifier(MusicInspector()) }
  @ViewBuilder public func musicRow(selected: Bool = false, hoverable: Bool = true) -> some View {
    let row = padding(.vertical, MusicPageStyle.rowVertical).padding(.horizontal, MusicPageStyle.rowHorizontal)
      .musicSelectionBackground(selected).contentShape(MusicCorner.selection.shape)
    if hoverable { row.musicHoverHighlight(.selection) } else { row }
  }
  public func musicCard() -> some View { contentShape(MusicCorner.feature.shape).musicHoverLift() }
}
public enum MusicArtworkSize: Sendable {
  case row, compact, card
  /// Cards take the width of their container and retain a square aspect ratio.
  public var edge: CGFloat? { switch self { case .row: MusicFixedArtworkSize.row.edge; case .compact: MusicFixedArtworkSize.compact.edge; case .card: nil } }
}
public enum MusicFixedArtworkSize: Sendable {
  case row, compact
  public var edge: CGFloat { switch self { case .row: 40; case .compact: 32 } }
}
public struct MusicArtworkPlaceholder: View {
  let symbol: String
  let corner: MusicCorner
  public init(symbol: String = "music.note", corner: MusicCorner = .artwork) { self.symbol = symbol; self.corner = corner }
  public static func symbolSize(edge: CGFloat) -> CGFloat { max(1, edge * 0.4) }
  public var body: some View {
    Rectangle().fill(.quaternary).overlay {
      GeometryReader { geometry in
        Image(systemName: symbol).font(.system(size: Self.symbolSize(edge: min(geometry.size.width, geometry.size.height))))
          .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
      .aspectRatio(1, contentMode: .fit).musicClip(corner).accessibilityHidden(true)
  }
}
public struct MusicChip: View {
  let title: Text
  let systemImage: String?
  let isSelected: Bool
  let action: () -> Void
  public init(title: LocalizedStringKey, isSelected: Bool, systemImage: String? = nil, action: @escaping () -> Void) {
    self.title = Text(title); self.isSelected = isSelected; self.systemImage = systemImage; self.action = action
  }
  public init(verbatim title: String, isSelected: Bool, systemImage: String? = nil, action: @escaping () -> Void) {
    self.title = Text(verbatim: title); self.isSelected = isSelected; self.systemImage = systemImage; self.action = action
  }
  public var body: some View {
    Button(action: action) {
      if let systemImage { Label { title } icon: { Image(systemName: systemImage) } } else { title }
    }.accessibilityLabel(title).musicAction(isSelected ? .primary : .secondary)
      .controlSize(.small).buttonBorderShape(.capsule).accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
