import Testing
import Foundation
import Domain

// W28 T28.4 / T28.5: the locale set, interface fallback, and the independence of interface language, content language and content region.

@Suite struct LocaleSetTests {
  /// The specification's own tables, read from the document so the code cannot drift from it silently.
  private func specificationRows() throws -> (eu: [String], additional: [String], variants: [String]) {
    let text = try Repo.text("Docs/Product-Specification.md")
    /// The identifiers in the second cell of the table row that starts with `label`.
    func ids(_ label: String) -> [String] {
      guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("| \(label) |") }) else { return [] }
      let cells = line.split(separator: "|", omittingEmptySubsequences: true)
      return cells.count > 1 ? cells[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : []
    }
    // The variants cell continues in prose ("… pt-PT and applicable system-selected region formats"); the first six comma items start with the identifier.
    return (ids("EU languages"), ids("Additional national and regional languages"), ids("Regional formatting variants").prefix(6).map { String($0.split(separator: " ").first ?? "") })
  }
  @Test func theSetIsExactlyTheSpecificationsFortySevenAndSix() throws {
    let spec = try specificationRows()
    #expect(spec.eu.count == 24 && spec.additional.count == 23, "the table was read (\(spec.eu.count), \(spec.additional.count))")
    #expect(AppLocales.euLanguages == spec.eu)
    #expect(AppLocales.additionalLanguages == spec.additional)
    #expect(AppLocales.baseIdentifiers.count == 47 && Set(AppLocales.baseIdentifiers).count == 47)
    #expect(AppLocales.formattingVariants == spec.variants && AppLocales.formattingVariants.count == 6)
    #expect(AppLocales.allIdentifiers.count == 53)
    #expect(AppLocales.sourceLanguage == "en" && AppLocales.baseIdentifiers.contains("en"))
    // Not advertised: a European language the specification does not list stays out.
    for outside in ["lb-LU", "se", "br", "co", "oc", "sc", "ast", "zh", "ja", "ar", "he"] { #expect(!AppLocales.allIdentifiers.contains(outside), "\(outside) is not in the set") }
  }
  @Test func requestsMapOntoShippedLocalesAndOnlyEnglishIsTheFallback() {
    let cases: [(String, String)] = [
      ("de-AT", "de"), ("de-CH", "de-CH"), ("de_DE", "de"), ("fr-CA", "fr"), ("fr-CH", "fr-CH"), ("it-CH", "it-CH"), ("pt-BR", "pt"), ("pt-PT", "pt-PT"), ("en-AU", "en"),
      ("en-GB", "en-GB"), ("en-US", "en-US"), ("sr", "sr"), ("sr-RS", "sr"), ("sr-Cyrl-RS", "sr"), ("sr-Latn-RS", "sr-Latn"), ("sr-Latn", "sr-Latn"), ("no", "nb"), ("nb-NO", "nb"),
      ("nn-NO", "nn"), ("ga-IE", "ga"), ("gd", "gd"), ("rm-CH", "rm"), ("lb", "lb"), ("tr-TR", "tr"), ("ka-GE", "ka"), ("hy-AM", "hy"), ("az-Latn-AZ", "az"), ("fo-FO", "fo"),
    ]
    for (request, expected) in cases { #expect(AppLocales.match(request) == expected, "\(request) → \(AppLocales.match(request) ?? "nil"), expected \(expected)") }
    for unsupported in ["ja", "zh-Hans", "ar", "he", "ko", "x", "", "und"] {
      #expect(AppLocales.match(unsupported) == nil, "\(unsupported) is not shipped")
      #expect(AppLocales.resolveInterface(requested: [unsupported]) == "en", "an unsupported request falls back to English: \(unsupported)")
    }
    #expect(AppLocales.resolveInterface(requested: ["ja", "ar", "fr-CA", "de"]) == "fr", "the first request that maps wins")
    #expect(AppLocales.resolveInterface(requested: []) == "en")
  }
  @Test func pluralCategoriesAgreeWithTheCatalogTool() throws {
    let table = try Repo.json("Resources/L10N/plural-categories.json")
    let fallback = table["default"] as! [String]
    for id in AppLocales.allIdentifiers {
      let base = AppLocales.baseLanguage(of: id)!
      let listed = (table[base] as? [String]) ?? fallback
      #expect(AppLocales.pluralCategories(for: id).map(\.rawValue) == listed, "plural categories of \(id)")
      #expect(AppLocales.pluralCategories(for: id).contains(.other), "\(id) always has `other`")
    }
    #expect(AppLocales.pluralCategories(for: "pl").map(\.rawValue) == ["one", "few", "many", "other"])
    #expect(AppLocales.pluralCategories(for: "lv").map(\.rawValue) == ["zero", "one", "other"])
    #expect(AppLocales.pluralCategories(for: "cy").count == 6)
    #expect(AppLocales.pluralCategories(for: "de-CH") == AppLocales.pluralCategories(for: "de"))
  }
  @Test func rightToLeftContentIsRecognisedEvenThoughNoInterfaceLocaleIsRightToLeft() {
    for id in ["ar", "he", "fa", "ur", "ar-EG", "he-IL", "yi", "sr-Arab", "az-Arab"] { #expect(AppLocales.isRightToLeft(script: id), "\(id) is right-to-left") }
    for id in AppLocales.allIdentifiers { #expect(!AppLocales.isRightToLeft(script: id), "\(id) is left-to-right") }
    #expect(!AppLocales.isRightToLeft(script: "sr-Cyrl") && !AppLocales.isRightToLeft(script: "ja"))
  }
}

@Suite struct LanguageRegionIndependenceTests {
  typealias Choice = LanguageRegionPreferences.Choice
  private let system = ["de-AT", "en"]
  @Test func anUnsupportedInterfaceLanguageFallsBackToEnglishAlone() {
    let preferences = LanguageRegionPreferences(interfaceLanguage: .identifier("ja"), contentLanguage: .identifier("ja"), contentRegion: .identifier("JP"))
    #expect(preferences.effectiveInterface(systemPreferred: system) == "en", "interface falls back")
    let request = preferences.contentRequest(systemPreferred: system, systemRegion: "AT")
    #expect(request.language == "ja" && request.region == "JP", "content language and region are untouched by the interface fallback (\(request))")
  }
  @Test func eachChoiceChangesOnlyItsOwnOutput() {
    let languages: [Choice] = [.system, .identifier("fr"), .identifier("ja"), .identifier("sr-Latn")]
    let regions: [Choice] = [.system, .identifier("CH"), .identifier("US"), .identifier("zz9")]
    for ui in languages { for content in languages { for region in regions {
      let base = LanguageRegionPreferences(interfaceLanguage: ui, contentLanguage: content, contentRegion: region)
      let interface = base.effectiveInterface(systemPreferred: system), request = base.contentRequest(systemPreferred: system, systemRegion: "AT")
      for other in languages {
        var changed = base; changed.interfaceLanguage = other
        #expect(changed.contentRequest(systemPreferred: system, systemRegion: "AT") == request, "changing the interface language altered the content request")
        changed = base; changed.contentLanguage = other
        #expect(changed.effectiveInterface(systemPreferred: system) == interface, "changing the content language altered the interface")
        #expect(changed.contentRequest(systemPreferred: system, systemRegion: "AT").region == request.region, "changing the content language altered the region")
      }
      for other in regions {
        var changed = base; changed.contentRegion = other
        #expect(changed.effectiveInterface(systemPreferred: system) == interface, "changing the region altered the interface")
        #expect(changed.contentRequest(systemPreferred: system, systemRegion: "AT").language == request.language, "changing the region altered the content language")
      }
    } } }
  }
  @Test func systemChoicesFollowTheSystemAndMalformedValuesAreDropped() {
    let defaults = LanguageRegionPreferences.defaults
    #expect(defaults.effectiveInterface(systemPreferred: ["sv-SE"]) == "sv")
    let request = defaults.contentRequest(systemPreferred: ["sv-SE"], systemRegion: "se")
    #expect(request.language == "sv-SE" && request.region == "SE")
    let bad = LanguageRegionPreferences(interfaceLanguage: .system, contentLanguage: .identifier("not a language"), contentRegion: .identifier("Sweden"))
    let dropped = bad.contentRequest(systemPreferred: ["de"], systemRegion: nil)
    #expect(dropped.language == "en" && dropped.region == nil, "malformed content values are dropped, never sent: \(dropped)")
    #expect(LanguageRegionPreferences.normalizedLanguage("zh_hans_cn") == "zh-Hans-CN")
    #expect(LanguageRegionPreferences.normalizedLanguage("EN-gb") == "en-GB")
    #expect(LanguageRegionPreferences.normalizedLanguage("e") == nil && LanguageRegionPreferences.normalizedLanguage("english") == nil)
  }
  @Test func storedValuesRoundTrip() {
    let preferences = LanguageRegionPreferences(interfaceLanguage: .identifier("de-CH"), contentLanguage: .system, contentRegion: .identifier("FR"))
    let stored = preferences.storedValues
    #expect(stored.interface == "de-CH" && stored.content == "system" && stored.region == "FR")
    #expect(LanguageRegionPreferences(stored: stored.interface, content: stored.content, region: stored.region) == preferences)
    #expect(LanguageRegionPreferences(stored: nil, content: "", region: "system") == .defaults)
  }
  @Test func formattingKeepsTheSystemRegionNeverTheContentRegion() {
    #expect(LanguageRegionPreferences.formattingIdentifier(interface: "de", systemRegion: "CH") == "de_CH")
    #expect(LanguageRegionPreferences.formattingIdentifier(interface: "de-CH", systemRegion: "AT") == "de_CH", "a variant already names its region")
    #expect(LanguageRegionPreferences.formattingIdentifier(interface: "pt-PT", systemRegion: "BR") == "pt_PT")
    #expect(LanguageRegionPreferences.formattingIdentifier(interface: "sr-Latn", systemRegion: "RS") == "sr_Latn_RS")
    #expect(LanguageRegionPreferences.formattingIdentifier(interface: "en", systemRegion: nil) == "en")
    #expect(LanguageRegionPreferences.formattingIdentifier(interface: "fr", systemRegion: "xx!") == "fr", "an invalid system region is ignored")
    // The Swiss variants format numbers and dates the Swiss way.
    #expect(Locale(identifier: "de_CH").currencySymbol == "CHF" || Locale(identifier: "de_CH").currency?.identifier == "CHF")
    #expect(Locale(identifier: "pt_PT").region?.identifier == "PT")
  }
  @Test func aRegionIsOnlyAHintAndNeverDecidesAvailability() throws {
    #expect(ContentRequestHints.decidesAvailability == false)
    let context = try AccountContext(accountID: UUID(), channelID: ID<ChannelTag>("channel"), region: "DE")
    let restricted = try Capability(state: .restricted(.regionRestricted), source: "test", context: context, checkedAt: Date(timeIntervalSince1970: 0), expiresAt: nil)
    let now = Date(timeIntervalSince1970: 100)
    // For every region a person could choose, the decision for the account is the same: a content region is not an input to it.
    for region in Locale.Region.isoRegions.map(\.identifier).filter({ $0.count == 2 }) {
      let hints = LanguageRegionPreferences(contentRegion: .identifier(region)).contentRequest(systemPreferred: ["en"], systemRegion: nil)
      #expect(hints.region == region)
      #expect(restricted.decision(for: context, now: now) == .denied(.regionRestricted), "choosing \(region) did not lift the restriction")
    }
    // The only region a decision does read is the account's own, and a different account region is a different context (verification, never allowance).
    let other = try AccountContext(accountID: context.accountID, channelID: context.channelID, region: "US")
    #expect(restricted.decision(for: other, now: now) == .verify(.staleContext))
  }
  @Test func contentRegionIsReadOnlyByThePreferencesTypeTheSettingReaderAndTheView() {
    // Who may read the stored content-region key: the preferences type, the reader that feeds the clients, and the settings section.
    let allowed: Set<String> = ["LanguageRegionPreferences.swift", "LanguageRegionView.swift", "ContentLocaleSetting.swift"]
    var offenders: [String] = []
    for (path, text) in Repo.swiftFiles(under: "Packages/NativeMusic/Sources") + Repo.swiftFiles(under: "App/Sources") {
      let name = (path as NSString).lastPathComponent
      if Repo.code(text).contains("contentRegion") && !allowed.contains(name) { offenders.append(path) }
    }
    #expect(offenders.isEmpty, "contentRegion read outside the preferences type, the reader and the view: \(offenders)")
  }
}
