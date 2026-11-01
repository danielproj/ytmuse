import DesignSystem
import Domain
import SwiftUI

public struct PreferencesView<Extra: View>: View {
  @AppStorage("appearance") private var storedAppearance = Appearance.system.rawValue
  private let extra: Extra
  public init(@ViewBuilder extra: () -> Extra) { self.extra = extra() }
  public var body: some View {
    MusicGlassGroup {
      Form {
        Picker("Appearance", selection: $storedAppearance) {
          Text("System").tag(Appearance.system.rawValue)
          Text("Light").tag(Appearance.light.rawValue)
          Text("Dark").tag(Appearance.dark.rawValue)
        }.accessibilityIdentifier("appearancePicker")
        Button("Restore Appearance Default") { storedAppearance = Appearance.system.rawValue }
          .accessibilityIdentifier("restoreAppearance").musicButtons()
        Text("Appearance is stored on this Mac and applies to all app windows.")
          .font(.footnote).foregroundStyle(MusicStyle.secondaryText)
        LanguageRegionSection()
        extra
      }.formStyle(.grouped).scrollContentBackground(.hidden).padding(MusicSpace.xs).musicSurface()
    }.padding(MusicSpace.lg).frame(width: 500, height: 440).musicCanvas()
  }
}
extension PreferencesView where Extra == EmptyView {
  public init() { self.init(extra: { EmptyView() }) }
}
