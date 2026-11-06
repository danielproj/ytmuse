import AppKit
import DesignSystem
import Domain
import SwiftUI
import Testing

@Suite @MainActor struct ContentPrimitiveTests {
  @Test func artworkSymbolScalesWithItsContainer() {
    #expect(MusicFixedArtworkSize.row.edge == 40)
    #expect(MusicFixedArtworkSize.compact.edge == 32)
    #expect(MusicArtworkPlaceholder.symbolSize(edge: 200) == 80)
    #expect(MusicArtworkPlaceholder.symbolSize(edge: 168) > MusicArtworkPlaceholder.symbolSize(edge: 40) * 4)
  }
  @Test func buttonRoleDecisions() {
    #expect(MusicActionRole.primary.treatment == .borderedProminent)
    #expect(MusicActionRole.secondary.treatment == .bordered)
    #expect(MusicActionRole.inline.treatment == .borderless)
  }
  @Test func styleDecisions() {
    #expect(MusicAccentSource.resolve(.standard) == .system)
    #expect(MusicAccentSource.resolve(.ytmuse) == .ytmuse)
    #expect(MusicAccentSource.system.color == Color.accentColor)
    #expect(MusicAccentSource.system.fill == Color.accentColor)
    #expect(MusicAccentSource.ytmuse.color == MusicStyle.accent)
    #expect(MusicAccentSource.ytmuse.fill == MusicStyle.accentFill)
    #expect(MusicContentBackground.resolve(.standard) == .systemOpaque)
    #expect(MusicContentBackground.resolve(.ytmuse) == .canvas)
    #expect(MusicArtworkSize.row.edge == 40)
    #expect(MusicArtworkSize.compact.edge == 32)
    #expect(MusicArtworkSize.card.edge == nil)
  }


  @Test func primaryUsesFillAndGlyphKeepsWhiteWhenLegible() {
    #expect(MusicActionRole.primary.tintSource == .fill)
    for mode in ContrastMode.allCases {
      for scheme in [ColorScheme.light, .dark] {
        let fill = MusicPalette.accentFill(scheme, increased: mode.increased).luminance
        #expect(MusicTint.contrast(1, fill) >= 3)
      }
    }
    #expect(MusicFillGlyph.usesBlack(luminance: 0.8))
    #expect(!MusicFillGlyph.usesBlack(luminance: 0.02))
    #expect(!MusicFillGlyph.usesBlack(luminance: 0.25))
  }

  @Test func inspectorDividerIsVertical() throws {
    let renderer = ImageRenderer(content: Color.clear.frame(width: 100, height: 60)
      .musicInspector().environment(\.musicAppStyle, .standard).environment(\.colorScheme, .light))
    renderer.scale = 1
    let cg = try #require(renderer.cgImage)
    let bitmap = NSBitmapImageRep(cgImage: cg)
    let background = try #require(bitmap.colorAt(x: 50, y: 15))
    for y in 0..<60 {
      #expect(bitmap.colorAt(x: 0, y: y) != background)
    }
    for x in 3..<100 {
      #expect(bitmap.colorAt(x: x, y: 30) == background)
    }
  }
  @Test func runtimeLabelsCompile() {
    _ = MusicChip(verbatim: "Service title", isSelected: true) {}
    _ = MusicOutlineBadge(verbatim: "Service badge", systemImage: "music.note")
  }
}
