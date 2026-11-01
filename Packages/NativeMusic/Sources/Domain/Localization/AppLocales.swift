import Foundation

/// W28 (L10N01, L10N06): the exact locale set the app names. English is the source language; the 47 base and script
/// locales below are the explicit European set from the specification, and the six formatting variants share their
/// base language's translations while respecting regional formats. Nothing here advertises a locale the specification
/// does not list. Whether a catalog is COMPLETE is not stated here: `Resources/LocalizationManifest.json` records that,
/// and the generated translations in it are machine seeds pending human review (W42), never a release-quality claim.
public enum AppLocales {
  public static let sourceLanguage = "en"
  /// EU official languages, in the specification's order.
  public static let euLanguages: [String] = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "ga", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv"]
  /// Additional national and regional languages (note the two scripts of Serbian).
  public static let additionalLanguages: [String] = ["ru", "uk", "be", "nb", "nn", "is", "sq", "bs", "mk", "sr", "sr-Latn", "tr", "ca", "eu", "gl", "cy", "gd", "rm", "lb", "ka", "hy", "az", "fo"]
  public static let baseIdentifiers: [String] = euLanguages + additionalLanguages
  /// Regional formatting variants. Each inherits its base language's strings (`pt-PT` is the Portuguese seed itself).
  public static let formattingVariants: [String] = ["en-GB", "en-US", "fr-CH", "de-CH", "it-CH", "pt-PT"]
  /// Every identifier the app ships a localization (or an explicit alias) for.
  public static let allIdentifiers: [String] = baseIdentifiers + formattingVariants

  /// The base language a variant inherits from (`de-CH` → `de`); a base identifier is its own.
  public static func baseLanguage(of identifier: String) -> String? {
    if baseIdentifiers.contains(identifier) { return identifier }
    guard formattingVariants.contains(identifier) else { return nil }
    return String(identifier.prefix { $0 != "-" })
  }

  /// Picks the interface locale for a list of requested identifiers (macOS preferred languages, or an explicit choice).
  /// The first request that maps onto a shipped locale wins; a request that only differs in region or script falls to
  /// the nearest shipped identifier (`de-AT` → `de`, `sr-Cyrl-RS` → `sr`, `sr-Latn-RS` → `sr-Latn`, `pt-BR` → `pt`),
  /// and when no request matches, the interface falls back to English and ONLY the interface does (L10N03).
  public static func resolveInterface(requested: [String]) -> String {
    for request in requested { if let match = match(request) { return match } }
    return sourceLanguage
  }
  /// The shipped identifier for one request, or nil when none fits.
  public static func match(_ request: String) -> String? {
    let parts = request.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
    guard let language = parts.first?.lowercased(), language.count >= 2 else { return nil }
    let rest = parts.dropFirst()
    let script = rest.first { $0.count == 4 && $0.allSatisfy(\.isLetter) }
    let region = rest.first { ($0.count == 2 && $0.allSatisfy(\.isLetter)) || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }?.uppercased()
    if language == "sr" { return script?.lowercased() == "latn" ? "sr-Latn" : "sr" }
    // Norwegian macrolanguage: bokmål is the default written form.
    if language == "no" { return "nb" }
    if let region, formattingVariants.contains("\(language)-\(region)") { return "\(language)-\(region)" }
    return baseIdentifiers.contains(language) ? language : nil
  }

  /// CLDR plural categories a language's catalog entry must define for a count placeholder to be complete.
  public enum PluralCategory: String, CaseIterable, Sendable { case zero, one, two, few, many, other }
  public static func pluralCategories(for identifier: String) -> [PluralCategory] {
    guard let language = baseLanguage(of: identifier) else { return [.other] }
    switch language {
    case "ga": return [.one, .two, .few, .many, .other]
    case "mt": return [.one, .two, .few, .many, .other]
    case "cy": return [.zero, .one, .two, .few, .many, .other]
    case "sl": return [.one, .two, .few, .other]
    case "gd": return [.one, .two, .few, .other]
    case "lv": return [.zero, .one, .other]
    case "hr", "sr", "sr-Latn", "bs", "ro": return [.one, .few, .other]
    case "cs", "sk", "pl", "lt", "ru", "uk", "be": return [.one, .few, .many, .other]
    case "fr", "pt", "es", "it", "ca": return [.one, .many, .other]
    default: return [.one, .other]
    }
  }

  /// Right-to-left languages the app must lay out correctly as CONTENT even though none is an interface locale.
  public static func isRightToLeft(script identifier: String) -> Bool {
    let language = identifier.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
    let script = identifier.split(separator: "-").dropFirst().first { $0.count == 4 }?.lowercased()
    if let script { return ["arab", "hebr", "thaa", "syrc", "nkoo"].contains(script) }
    return ["ar", "he", "iw", "fa", "ur", "yi", "ps", "sd", "dv", "ug"].contains(language)
  }
}
