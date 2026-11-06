import AppKit
import DesignSystem
import Domain
import SwiftUI
import Testing

/// APPEARANCE-STYLE finding 1: the YTMuse style must not change at all. The expected samples below were rendered from the design system BEFORE the
/// Style work began (artifacts/harness/nodes/APPEARANCE-STYLE/work/ytmuse-baseline-before.txt), so these tests compare against the old code, not
/// against the new code's own idea of YTMuse. Each surface is rendered with YTMuse set explicitly, and with YTMuse inside a window flagged
/// translucent (YTMuse must ignore the flag). Standard is the default style (account holder, 2026-11-06), so a surface with no style set must
/// render exactly as Standard does.
@Suite(.serialized) @MainActor struct YTMuseLookParityTests {
  static let points = [(2, 2), (32, 32), (61, 61), (61, 2), (2, 61)]
  static var renderers: [AnyObject] = []
  static func samples<V: View>(_ view: V, _ scheme: ColorScheme) -> [[Int]] {
    let renderer = ImageRenderer(content: view.frame(width: 64, height: 64).environment(\.colorScheme, scheme))
    renderer.scale = 1
    // A released ImageRenderer can hand its successor the previous image (observed: a sidebar render returned the canvas rendered just
    // before it). Keeping every renderer alive for the process gives each render its own, so no sample is a stale copy of another.
    renderers.append(renderer)
    guard let image = renderer.cgImage else { return [] }
    let rep = NSBitmapImageRep(cgImage: image)
    return points.map { p in
      let c = rep.colorAt(x: p.0, y: p.1)!.usingColorSpace(.sRGB)!
      return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int(($0 * 255).rounded()) }
    }
  }
  static func close(_ a: [[Int]], _ b: [[Int]], tolerance: Int = 2) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { x, y in x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) <= tolerance } }
  }
  /// Recorded before the change (see the type comment). Keyed "surface scheme".
  static let before: [String: [[Int]]] = [
    "canvas dark": [[21, 12, 11, 255], [2, 2, 2, 255], [2, 2, 2, 255], [2, 2, 2, 255], [2, 2, 2, 255]],
    "canvasArtwork dark": [[3, 6, 20, 255], [2, 2, 2, 255], [2, 2, 2, 255], [2, 2, 2, 255], [2, 2, 2, 255]],
    "canvasModifier dark": [[21, 12, 11, 255], [2, 2, 2, 255], [2, 2, 2, 255], [2, 2, 2, 255], [2, 2, 2, 255]],
    "sidebarColumn dark": [[2, 2, 2, 255], [2, 2, 2, 255], [2, 2, 2, 255], [2, 2, 2, 255], [2, 2, 2, 255]],
    "scrim dark": [[0, 0, 0, 128], [0, 0, 0, 128], [0, 0, 0, 128], [0, 0, 0, 128], [0, 0, 0, 128]],
    "canvas light": [[248, 238, 240, 255], [255, 255, 255, 255], [249, 249, 249, 255], [255, 255, 255, 255], [255, 255, 255, 255]],
    "canvasArtwork light": [[238, 243, 253, 255], [255, 255, 255, 255], [249, 249, 249, 255], [255, 255, 255, 255], [255, 255, 255, 255]],
    "canvasModifier light": [[248, 238, 240, 255], [255, 255, 255, 255], [249, 249, 249, 255], [255, 255, 255, 255], [255, 255, 255, 255]],
    "sidebarColumn light": [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]],
    "scrim light": [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]],
  ]
  static let artwork = Color(red: 0.1, green: 0.3, blue: 0.9)
  @ViewBuilder static func surface(_ name: String, scheme: ColorScheme) -> some View {
    switch name {
    case "canvas": MusicCanvas()
    case "canvasArtwork": MusicCanvas(artworkAccent: artwork)
    case "canvasModifier": Color.clear.musicCanvas()
    case "sidebarColumn": Color.clear.musicSidebarColumn()
    default: Rectangle().fill(MusicGlassScrim.color(scheme, style: .ytmuse))
    }
  }
  static let names = ["canvas", "canvasArtwork", "canvasModifier", "sidebarColumn", "scrim"]

  @Test func theYTMuseStyleRendersExactlyWhatTheAppRenderedBeforeTheStyleWork() {
    for scheme in [ColorScheme.dark, .light] {
      for name in Self.names {
        let want = Self.before["\(name) \(scheme)"]!
        let explicit = Self.samples(Self.surface(name, scheme: scheme).environment(\.musicAppStyle, .ytmuse), scheme)
        let flagged = Self.samples(Self.surface(name, scheme: scheme).environment(\.musicAppStyle, .ytmuse).environment(\.musicTranslucentWindow, true), scheme)
        #expect(Self.close(explicit, want), "\(name) \(scheme), YTMuse: \(explicit) vs before \(want)")
        #expect(Self.close(flagged, want), "\(name) \(scheme), YTMuse in a translucent-flagged window: \(flagged) vs before \(want)")
      }
    }
    // The old scrim API is unchanged too.
    #expect(Self.close(Self.samples(Rectangle().fill(MusicStyle.glassScrim(.dark)), .dark), Self.before["scrim dark"]!))
  }
  /// Control: the comparison can fail. Standard renders something else for every canvas, so a parity test that compared nothing would be caught here.
  @Test func theStandardStyleRendersDifferentlySoTheParityCheckCanFail() {
    for scheme in [ColorScheme.dark, .light] {
      for name in ["canvas", "canvasArtwork", "canvasModifier"] {
        let standard = Self.samples(Self.surface(name, scheme: scheme).environment(\.musicAppStyle, .standard), scheme)
        #expect(!standard.isEmpty)
        #expect(!Self.close(standard, Self.before["\(name) \(scheme)"]!), "\(name) \(scheme): Standard must not look like YTMuse (\(standard))")
      }
    }
    // The default is Standard: a surface with no style set renders exactly as explicit Standard.
    for scheme in [ColorScheme.dark, .light] { for name in Self.names {
      let unset = Self.samples(Self.surface(name, scheme: scheme), scheme)
      let standard = Self.samples(Self.surface(name, scheme: scheme).environment(\.musicAppStyle, .standard), scheme)
      #expect(Self.close(unset, standard), "\(name) \(scheme): no style set must be Standard (\(unset) vs \(standard))")
    } }
    let darkSidebar = Self.samples(Color.clear.musicSidebarColumn().environment(\.musicAppStyle, .standard), .dark)
    #expect(darkSidebar.allSatisfy { $0[3] == 0 }, "Standard paints nothing behind the sidebar, so the native glass shows the window material: \(darkSidebar)")
  }
  @Test func everyYTMuseDecisionIsTodaysPath() {
    for translucent in [false, true] { for opaque in [false, true] {
      #expect(MusicWindowBackdrop.resolve(style: .ytmuse, translucentWindow: translucent, opaque: opaque) == .ytmuseCanvas)
    } }
    #expect(MusicGlassScrim.opacity(.dark, style: .ytmuse) == MusicPalette.darkGlassScrim)
    #expect(MusicGlassScrim.opacity(.light, style: .ytmuse) == 0)
    #expect(AppStyle(storedValue: "ytmuse") == .ytmuse, "a chosen YTMuse is kept")
    #expect(AppStyle(storedValue: nil) == .standard && AppStyle(storedValue: "") == .standard && AppStyle(storedValue: "unknown") == .standard, "an install that never chose, or a value from a newer version, reads as Standard (the default)")
    var environment = EnvironmentValues()
    #expect(environment.musicAppStyle == .standard && !environment.musicTranslucentWindow, "a view outside every window root gets the default style")
    environment.musicAppStyle = .ytmuse
    #expect(environment.musicAppStyle == .ytmuse)
  }
  @Test func standardIsOpaqueUnderReduceTransparencyOrIncreaseContrastAndTranslucentOnlyInTheWindowThatMayBe() {
    #expect(MusicWindowBackdrop.resolve(style: .standard, translucentWindow: true, opaque: false) == .systemMaterial)
    #expect(MusicWindowBackdrop.resolve(style: .standard, translucentWindow: true, opaque: true) == .systemOpaque, "GLASS05: an opaque window under Reduce Transparency / Increase Contrast")
    #expect(MusicWindowBackdrop.resolve(style: .standard, translucentWindow: false, opaque: false) == .systemOpaque, "sheets and secondary windows stay opaque")
    // A sheet inside the translucent main window still gets an opaque backdrop: `musicCanvas()` clears the inherited flag.
    let sheet = Self.samples(Color.clear.musicCanvas().environment(\.musicAppStyle, .standard).environment(\.musicTranslucentWindow, true), .dark)
    #expect(sheet.allSatisfy { $0[3] == 255 }, "a sheet's backdrop is opaque under Standard: \(sheet)")
    let window = Self.samples(MusicCanvas().environment(\.musicAppStyle, .standard).environment(\.musicTranslucentWindow, true), .dark)
    #expect(window.allSatisfy { $0[3] == 0 }, "the translucent main window's canvas stands down so the material shows: \(window)")
  }
}
