import Domain
import DesignSystem
import SwiftUI

/// W28 (L10N03): the three independent language choices. Each picker writes its own preference and nothing else; the interface language is
/// limited to the shipped locales and falls back to English alone, the content language may be any language (mixed scripts are supported for
/// content), and the content region is a hint that never decides what the service allows.
public struct LanguageRegionSection: View {
  @AppStorage(LanguageRegionPreferences.interfaceKey) private var interface = LanguageRegionPreferences.systemToken
  @AppStorage(LanguageRegionPreferences.contentLanguageKey) private var contentLanguage = LanguageRegionPreferences.systemToken
  @AppStorage(LanguageRegionPreferences.contentRegionKey) private var contentRegion = LanguageRegionPreferences.systemToken
  public init() {}
  /// Languages offered for content beyond the interface set: scripts the interface does not ship but content may use.
  static let extraContentLanguages = ["ar", "he", "fa", "hi", "ja", "ko", "th", "zh-Hans", "zh-Hant"]
  /// A language's own name in itself, so a person can find it whatever the interface language.
  static func endonym(_ identifier: String) -> String {
    let locale = Locale(identifier: identifier)
    return locale.localizedString(forIdentifier: identifier)?.localizedCapitalized ?? identifier
  }
  static let regions: [String] = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }
    .sorted { NaturalOrder.compare(Locale.current.localizedString(forRegionCode: $0) ?? $0, Locale.current.localizedString(forRegionCode: $1) ?? $1) == .orderedAscending }
  public var body: some View {
    Section {
      Picker("Interface language", selection: $interface) {
        Text("Same as macOS").tag(LanguageRegionPreferences.systemToken)
        ForEach(AppLocales.baseIdentifiers, id: \.self) { Text(Self.endonym($0)).tag($0) }
      }.accessibilityIdentifier("interfaceLanguagePicker")
      Picker("Language of music and lyrics", selection: $contentLanguage) {
        Text("Same as macOS").tag(LanguageRegionPreferences.systemToken)
        ForEach(AppLocales.baseIdentifiers + Self.extraContentLanguages, id: \.self) { Text(Self.endonym($0)).tag($0) }
      }.accessibilityIdentifier("contentLanguagePicker")
      Picker("Region for recommendations", selection: $contentRegion) {
        Text("Same as macOS").tag(LanguageRegionPreferences.systemToken)
        ForEach(Self.regions, id: \.self) { region in Text(Locale.current.localizedString(forRegionCode: region) ?? region).tag(region) }
      }.accessibilityIdentifier("contentRegionPicker")
      Text("The region only changes what is suggested. It never unlocks music or features your account or location doesn’t allow.")
        .font(.footnote).foregroundStyle(MusicStyle.secondaryText)
      Text("Menus and spoken messages change after you relaunch YTMuse.")
        .font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("languageRelaunchNote")
      Button("Restore Language Defaults") {
        interface = LanguageRegionPreferences.systemToken; contentLanguage = LanguageRegionPreferences.systemToken; contentRegion = LanguageRegionPreferences.systemToken
      }.musicPageAction().accessibilityIdentifier("restoreLanguageDefaults")
    } header: { Text("Language and region") }
  }
}
