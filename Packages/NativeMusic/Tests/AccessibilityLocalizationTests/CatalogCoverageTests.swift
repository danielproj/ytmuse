import Testing
import Foundation
import Domain

// W28 T28.4: an independent, Swift-side audit of the catalog the Python tool writes (scripts/check-localization.py is the other half). Every key in
// every locale for the core set, plurals complete for each language's CLDR categories, placeholders unchanged, names unchanged, and the manifest
// listing exactly the set the specification names, with no release-quality claim for machine seeds.

@Suite struct CatalogCoverageTests {
  struct Core { let simple: [(id: String, text: String)]; let plural: [(id: String, forms: [String: String])] }
  static func core() throws -> Core {
    var simple: [(String, String)] = [], plural: [(String, [String: String])] = []
    for line in try Repo.text("Resources/L10N/core-en.txt").split(separator: "\n") {
      let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
      if parts[0].hasPrefix("Q") {
        plural.append((parts[0], ["other": parts[1]]))
      } else if parts[0].hasPrefix("P") {
        var forms: [String: String] = [:]
        for part in parts[1].split(separator: "\t") { let pair = part.split(separator: ":", maxSplits: 1).map(String.init); forms[pair[0]] = pair[1] }
        plural.append((parts[0], forms))
      } else { simple.append((parts[0], parts[1])) }
    }
    return Core(simple: simple, plural: plural)
  }
  static func catalog() throws -> [String: [String: Any]] { try Repo.json("Resources/Localizable.xcstrings")["strings"] as! [String: [String: Any]] }
  static func placeholders(_ text: String) -> [String] {
    let expression = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:l{0,2})[@d]"#)
    let plain = text.replacingOccurrences(of: "%%", with: "")
    return expression.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).map { String(plain[Range($0.range, in: plain)!]) }.map { $0.replacingOccurrences(of: #"%\d+\$"#, with: "%", options: .regularExpression) }.sorted()
  }
  static func localizations(_ entry: [String: Any]) -> [String: Any] { entry["localizations"] as? [String: Any] ?? [:] }
  static func value(_ localization: Any?) -> String? { ((localization as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
  static func state(_ localization: Any?) -> String? { ((localization as? [String: Any])?["stringUnit"] as? [String: Any])?["state"] as? String }
  static func pluralUnits(_ localization: Any?) -> [String: [String: Any]]? { (((localization as? [String: Any])?["variations"] as? [String: Any])?["plural"]) as? [String: [String: Any]] }
  /// The locales translated for EVERY key (the account holder's main languages, 2026-11-01); every other locale carries only its first seeded keys.
  static let full = ["ru", "de", "es", "fr", "de-CH"]
  static let partial = AppLocales.baseIdentifiers.filter { $0 != "en" && !["ru", "de", "es", "fr"].contains($0) } + ["pt-PT"]
  static let explicit = full + partial

  @Test func everyKeyIsTranslatedInTheFullyTranslatedLocalesWithTheirPluralCategories() throws {
    let core = try Self.core(), strings = try Self.catalog()
    #expect(core.simple.count > 1000 && core.plural.count > 40, "the key set was read (\(core.simple.count), \(core.plural.count))")
    var problems: [String] = []
    for locale in Self.explicit {
      let isFull = Self.full.contains(locale)
      for item in core.simple {
        guard let entry = strings[item.text] else { problems.append("catalog lacks \(item.text)"); continue }
        guard let value = Self.value(Self.localizations(entry)[locale]), !value.isEmpty else { if isFull { problems.append("\(locale): \(item.id) missing") }; continue }
        if Self.placeholders(value) != Self.placeholders(item.text) { problems.append("\(locale): \(item.id) placeholders \(Self.placeholders(value)) vs \(Self.placeholders(item.text))") }
        if Self.state(Self.localizations(entry)[locale]) != "needs_review" { problems.append("\(locale): \(item.id) not marked as a machine seed") }
      }
      for item in core.plural {
        guard let entry = strings[item.forms["other"]!] else { problems.append("catalog lacks \(item.id)"); continue }
        guard let units = Self.pluralUnits(Self.localizations(entry)[locale]) else { if isFull { problems.append("\(locale): \(item.id) has no plural entry") }; continue }
        let need = Set(AppLocales.pluralCategories(for: locale).map(\.rawValue))
        if Set(units.keys) != need { problems.append("\(locale): \(item.id) plural categories \(units.keys.sorted()) vs \(need.sorted())") }
        for (category, unit) in units {
          let text = ((unit["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
          if text.isEmpty { problems.append("\(locale): \(item.id).\(category) empty") }
        }
      }
    }
    #expect(problems.isEmpty, Comment(rawValue: problems.prefix(30).joined(separator: "\n")))
  }
  @Test func catalogsLocalizeIntoNothingOutsideTheSpecificationSet() throws {
    let allowed = Set(AppLocales.allIdentifiers)
    var used = Set<String>()
    for entry in try Self.catalog().values { used.formUnion(Self.localizations(entry).keys) }
    #expect(used.isSubset(of: allowed), "unexpected locale identifiers: \(used.subtracting(allowed).sorted())")
    #expect(used.contains("de-CH") && used.contains("pt-PT") && used.contains("sr-Latn") && used.contains("en"))
    for inheriting in ["en-GB", "en-US", "fr-CH", "it-CH"] { #expect(!used.contains(inheriting), "\(inheriting) inherits its base language; it carries no strings of its own") }
  }
  @Test func productNamesAreKeptAsSuppliedInEveryTranslation() throws {
    let core = try Self.core(), strings = try Self.catalog()
    let names = ["YTMuse", "YouTube Music", "Google", "Mac", "macOS"]
    for item in core.simple {
      for name in names where item.text.contains(name) {
        for locale in Self.explicit {
          guard let raw = Self.value(Self.localizations(strings[item.text]!)[locale]) else { continue }
          let value = locale.hasPrefix("de") ? raw.replacingOccurrences(of: "YouTube-Music", with: "YouTube Music") : raw   // a German hyphenated compound keeps the spelling
          #expect(value.contains(name), "\(locale) changed '\(name)' in \(item.id): \(value)")
        }
      }
    }
  }
  /// Formats every translation with arguments of the right kinds (a name for `%@`, a number for `%lld`), positional specifiers included.
  static func arguments(for text: String, name: String) -> [CVarArg] {
    let expression = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(?:l{0,2})([@d])"#)
    var kinds: [Int: Character] = [:]; var next = 1
    for match in expression.matches(in: text.replacingOccurrences(of: "%%", with: ""), range: NSRange(text.replacingOccurrences(of: "%%", with: "").startIndex..., in: text.replacingOccurrences(of: "%%", with: ""))) {
      let plain = text.replacingOccurrences(of: "%%", with: "")
      let position = Range(match.range(at: 1), in: plain).flatMap { Int(plain[$0]) } ?? next
      next += 1
      kinds[position] = Range(match.range(at: 2), in: plain).map { plain[$0] }?.first ?? "@"
    }
    return (1...max(1, kinds.keys.max() ?? 1)).map { kinds[$0] == "d" ? (7 as CVarArg) : (name as CVarArg) }
  }
  @Test func everyTranslationFormatsWithItsArguments() throws {
    let core = try Self.core(), strings = try Self.catalog()
    // A mix of scripts and directions as the supplied artist or account name: it must come through byte-for-byte.
    let names = ["Beyoncé", "Sigur Rós", "الشيخ إمام", "שלמה ארצי", "宇多田ヒカル", "Наталья Ветлицкая", "A\u{200F}b"]
    for locale in Self.explicit {
      for item in core.simple where item.text.contains("%") {
        guard let value = Self.value(Self.localizations(strings[item.text]!)[locale]) else { continue }
        for name in names {
          let formatted = String(format: value, arguments: Self.arguments(for: value, name: name))
          if item.text.contains("%@") { #expect(formatted.contains(name), "\(locale) \(item.id): name altered by formatting: \(formatted)") }
        }
      }
      for item in core.plural {
        guard let units = Self.pluralUnits(Self.localizations(strings[item.forms["other"]!]!)[locale]) else { continue }
        for (category, unit) in units {
          let text = (unit["stringUnit"] as! [String: Any])["value"] as! String
          guard text.contains("%lld") else { continue }
          #expect(String(format: text, arguments: Self.arguments(for: text, name: "Beyoncé")).contains("7"), "\(locale) \(item.id).\(category) does not print its count")
        }
      }
    }
  }
  @Test func theManifestSaysWhatIsCompleteAndWhatFallsBackToEnglish() throws {
    let manifest = try Repo.json("Resources/LocalizationManifest.json")
    #expect(manifest["baseLocales"] as? [String] == AppLocales.baseIdentifiers)
    #expect(manifest["formattingVariants"] as? [String] == AppLocales.formattingVariants)
    #expect(manifest["completeLocales"] as? [String] == ["en", "fr", "de", "es", "ru", "en-GB", "en-US", "fr-CH", "de-CH"], "only the five main languages and the variants that share their strings are complete")
    let complete = Set(manifest["completeLocales"] as! [String]), partial = Set(manifest["partialLocales"] as! [String])
    #expect(complete.isDisjoint(with: partial) && complete.union(partial) == Set(AppLocales.allIdentifiers))
    #expect(partial.count == 44, "every other locale is registered and falls back to English")
    #expect(manifest["releaseQualityClaim"] as? Bool == false, "machine seeds are not a release-quality claim")
    let locales = manifest["locales"] as! [String: [String: Any]]
    #expect(Set(locales.keys) == Set(AppLocales.allIdentifiers))
    for (id, entry) in locales where id != "en" {
      let review = entry["review"] as? String
      #expect(review == "pending-W42" || review == "inherits-base", "\(id) review state \(review ?? "nil")")
      let isComplete = entry["complete"] as? Bool ?? false
      #expect(isComplete == complete.contains(id), "\(id): the complete flag agrees with completeLocales")
      #expect((entry["coverage"] as? Double ?? 0) < 1 || isComplete, "\(id): a locale below full coverage is never reported complete")
    }
    let strings = try Self.catalog()
    #expect(manifest["catalogKeyCount"] as? Int == strings.count)
    let ru = locales["ru"]!, mt = locales["mt"]!
    #expect(ru["coverage"] as? Double == 1.0 && (mt["coverage"] as? Double ?? 1) < 0.1, "coverage is reported as measured: Russian full, Maltese only its first seeds")
  }

  // N1: the English values are the SOURCE strings, not whatever the generator was fed.
  static func register(_ path: String) throws -> [String: String] {
    var out: [String: String] = [:]
    for line in try Repo.text(path).split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
      let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
      if parts.count == 2 { out[parts[0]] = parts[1] }
    }
    return out
  }
  @Test func theEnglishValuesAreTheSourceStringsAndNoIdentifierIsEchoedAsText() throws {
    let strings = try Self.catalog()
    let values = try Self.register("Resources/L10N/english-values.txt"), ones = try Self.register("Resources/L10N/english-plurals.txt")
    #expect(values["detailSeparator"] == " • ", "the subtitle separator is punctuation, written down explicitly")
    let identifier = try NSRegularExpression(pattern: #"^[a-z]+[A-Z][a-z]+[A-Za-z0-9]*$"#)
    var problems: [String] = []
    for (key, entry) in strings {
      for (locale, localization) in Self.localizations(entry) {
        guard let value = Self.value(localization) else { continue }
        if locale == "en", value != (values[key] ?? key) { problems.append("en \(key.prefix(50)): '\(value)' is not the source string") }
        if value == key, identifier.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil { problems.append("\(locale): the value of \(key) is the identifier itself") }
      }
    }
    // The singular forms of counted English keys that had one on main are still there ("1 seconds remaining" was the regression).
    for (key, one) in ones {
      let units = Self.pluralUnits(Self.localizations(strings[key] ?? [:])["en"])
      let got = (units?["one"]?["stringUnit"] as? [String: Any])?["value"] as? String
      if got != one { problems.append("English singular of \(key) is \(got ?? "missing"), expected \(one)") }
    }
    // ("%lld more files" was the uploads screen's and left with it.)
    for key in ["%lld seconds remaining", "Fading · %lld seconds remaining"] { #expect(ones[key] != nil, "\(key) is registered with its singular") }
    #expect(problems.isEmpty, Comment(rawValue: problems.prefix(20).joined(separator: "\n")))
    // Control: the detector does flag an echoed identifier and a value different from its source.
    #expect(identifier.firstMatch(in: "detailSeparator", range: NSRange(location: 0, length: 15)) != nil && identifier.firstMatch(in: "macOS", range: NSRange(location: 0, length: 5)) == nil)
  }
  // N2: the QA-only exclusion is an explicit list of exact keys; user-facing wording that merely contains "Diagnostic" or "Development" is translated.
  @Test func theQAExclusionIsAnExplicitListNeverAPattern() throws {
    let qa = Set(try Repo.text("Resources/L10N/qa-keys.txt").split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init))
    let core = try Self.core(), strings = try Self.catalog()
    #expect(qa.count > 20 && qa.contains("Simulate output loss"))
    for key in ["Diagnostics", "Diagnostics could not be read.", "Display label",
                "Off. YTMuse contains no analytics SDK and sends no diagnostics anywhere. You can export a redacted support bundle yourself."] {
      #expect(!qa.contains(key), "\(key) is user wording, not QA-only")
      #expect(core.simple.contains { $0.text == key }, "\(key) is a translatable key")
      for locale in ["ru", "de", "es", "fr"] { #expect(Self.value(Self.localizations(strings[key] ?? [:])[locale]) != nil, "\(locale) translates \(key)") }
    }
    let generator = try Repo.text("scripts/l10n/source_keys.py")
    #expect(!generator.contains("QA_ONLY"), "no substring pattern decides what is QA-only")
    #expect(generator.contains("def is_qa(key): return key in QA"), "the exclusion is membership in the explicit list")
    for key in qa { #expect(!key.contains("*") && !key.hasPrefix("^"), "the list holds exact keys: \(key)") }
  }
}
