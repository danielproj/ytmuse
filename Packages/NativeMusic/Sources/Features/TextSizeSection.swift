import DesignSystem
import SwiftUI

/// W28 rework 1 (A11Y02): "Text size" in Settings > Appearance. Scales the content of pages, the queue and the lyrics (`musicContentZoom`).
public struct TextSizeSection: View {
  @AppStorage(MusicContentScale.storageKey) private var stored = 1.0
  public init() {}
  public var body: some View {
    Section {
      Picker("Text size", selection: Binding(get: { MusicContentScale.normalised(stored) }, set: { stored = $0 })) {
        ForEach(MusicContentScale.choices, id: \.self) { Text(verbatim: "\(Int(($0 * 100).rounded()))%").tag($0) }
      }.pickerStyle(.segmented).accessibilityIdentifier("textSizePicker")
      Text("Scales the text of lists, details and lyrics.").font(.footnote).foregroundStyle(MusicStyle.secondaryText)
    }
  }
}
