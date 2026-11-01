import Testing
import AppKit
import SwiftUI
import DesignSystem

// W28 rework 1 (F6, A11Y02): the text-size setting really scales content, measured from rendered pixels.

@Suite struct ContentScaleTests {
  /// The inked extent (columns and rows with dark pixels) of a view rendered on white.
  @MainActor private func ink(_ view: some View, width: Double, height: Double) -> (width: Int, height: Int, touchesRightEdge: Bool, touchesBottom: Bool) {
    let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading).background(Color.white).environment(\.colorScheme, .light))
    host.appearance = NSAppearance(named: .aqua)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height); host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
    for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
      guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent < 0.5 else { continue }
      minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    return (maxX < 0 ? 0 : maxX - minX + 1, maxY < 0 ? 0 : maxY - minY + 1, maxX >= rep.pixelsWide - 2, maxY >= rep.pixelsHigh - 2)
  }
  private let sentence = "Your queue is empty and the quick brown fox jumps over the lazy dog"
  @MainActor @Test func contentIsLaidOutSmallerAndDrawnLargerByTheChosenFactor() {
    func page(_ scale: Double) -> some View { Text(verbatim: sentence).foregroundStyle(.black).font(.body).fixedSize(horizontal: false, vertical: true).musicContentZoom().environment(\.musicContentScale, scale) }
    let normal = ink(page(1.0), width: 600, height: 400), large = ink(page(2.0), width: 600, height: 400)
    #expect(normal.width > 100, "the control renders text (\(normal))")
    // One line at 100%; at 200% the line is twice as large, so it wraps in the same 600 pt and the block is taller, never clipped.
    #expect(large.height >= Int(Double(normal.height) * 1.8), "the page text is about twice as tall: \(normal.height) → \(large.height)")
    #expect(!large.touchesRightEdge && !large.touchesBottom, "nothing is cut off at the right or the bottom: \(large)")
    let glyphHeight = { (scale: Double) in ink(Text(verbatim: "Hxg").foregroundStyle(.black).font(.body).musicContentZoom().environment(\.musicContentScale, scale), width: 300, height: 200).height }
    #expect(Double(glyphHeight(1.5)) / Double(glyphHeight(1.0)) > 1.35, "150% draws letters about 1.5 times as tall")
  }
  @MainActor @Test func aRowKeepsItsControlsWhenTheTextIsLarge() {
    // A row of a title that wraps and two buttons at the end: at 150% the buttons are still inside the row.
    func row(_ scale: Double) -> some View {
      HStack { Text(verbatim: "A rather long song title that has to wrap at large sizes").foregroundStyle(.black); Spacer(); Image(systemName: "arrow.up").foregroundStyle(.black); Image(systemName: "arrow.down").foregroundStyle(.black) }
        .musicContentZoom().environment(\.musicContentScale, scale)
    }
    let large = ink(row(1.5), width: 500, height: 300)
    #expect(!large.touchesRightEdge, "the trailing controls stay inside the row at 150% (\(large))")
  }
  @Test func storedValuesAreClampedAndTheChoicesAreTheOfferedOnes() {
    #expect(MusicContentScale.choices == [1.0, 1.25, 1.5, 2.0])
    #expect(MusicContentScale.normalised(0.2) == 1.0 && MusicContentScale.normalised(9) == 2.0 && MusicContentScale.normalised(.nan) == 1.0 && MusicContentScale.normalised(1.5) == 1.5)
  }
}
