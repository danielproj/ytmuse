import Foundation

/// W28 (L10N03): three independent choices. Interface language, source (content) language and content region never
/// derive one from another: changing one leaves the other two untouched. Only the interface language falls back to
/// English; the content language is a request hint for the service, and the region is a request hint that NEVER decides
/// what the service allows (`ContentRequestHints.decidesAvailability` is false, and capability decisions take no region).
public struct LanguageRegionPreferences: Equatable, Sendable {
  public enum Choice: Equatable, Sendable {
    /// Follow the system (macOS preferred languages / region).
    case system
    case identifier(String)
  }
  public var interfaceLanguage: Choice
  public var contentLanguage: Choice
  public var contentRegion: Choice
  public init(interfaceLanguage: Choice = .system, contentLanguage: Choice = .system, contentRegion: Choice = .system) {
    self.interfaceLanguage = interfaceLanguage; self.contentLanguage = contentLanguage; self.contentRegion = contentRegion
  }
  public static let defaults = LanguageRegionPreferences()

  /// The interface locale to load strings for. An unsupported explicit choice falls back to English ALONE — it never
  /// changes the content language or region.
  public func effectiveInterface(systemPreferred: [String]) -> String {
    switch interfaceLanguage {
    case .system: AppLocales.resolveInterface(requested: systemPreferred)
    case .identifier(let value): AppLocales.resolveInterface(requested: [value])
    }
  }
  /// What to ask the service for. Any well-formed BCP-47 language may be requested as content, whether or not it is an
  /// interface locale (Unicode and mixed scripts are supported for content); malformed values are dropped.
  public func contentRequest(systemPreferred: [String], systemRegion: String?) -> ContentRequestHints {
    let language: String
    switch contentLanguage {
    case .system: language = systemPreferred.first.flatMap(Self.normalizedLanguage) ?? AppLocales.sourceLanguage
    case .identifier(let value): language = Self.normalizedLanguage(value) ?? AppLocales.sourceLanguage
    }
    let region: String?
    switch contentRegion {
    case .system: region = systemRegion.flatMap(Self.normalizedRegion)
    case .identifier(let value): region = Self.normalizedRegion(value)
    }
    return ContentRequestHints(language: language, region: region)
  }
  /// `language[-Script][-REGION]` with the case the service expects; nil when it is not well formed.
  public static func normalizedLanguage(_ value: String) -> String? {
    let parts = value.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
    var out = [first.lowercased()]
    for part in parts.dropFirst() {
      if part.count == 4, part.allSatisfy({ $0.isASCII && $0.isLetter }) { out.append(part.prefix(1).uppercased() + part.dropFirst().lowercased()) }
      else if part.count == 2, part.allSatisfy({ $0.isASCII && $0.isLetter }) { out.append(part.uppercased()) }
      else { return nil }
    }
    return out.joined(separator: "-")
  }
  public static func normalizedRegion(_ value: String) -> String? {
    value.count == 2 && value.allSatisfy({ $0.isASCII && $0.isLetter }) ? value.uppercased() : nil
  }
  /// The locale identifier used to format dates, numbers and plurals for an interface language: the system-selected region is kept where it
  /// applies (`de` + system region CH → `de_CH`; `fr` + CH → `fr_CH`), never the CONTENT region, which is a service hint only.
  public static func formattingIdentifier(interface: String, systemRegion: String?) -> String {
    let underscored = interface.replacingOccurrences(of: "-", with: "_")
    // A formatting variant (de-CH, pt-PT, en-GB...) already names its region; the system region only completes a bare language or script.
    guard !AppLocales.formattingVariants.contains(interface), let region = systemRegion.flatMap(normalizedRegion) else { return underscored }
    return underscored + "_" + region
  }
  // Persistence keys (the one preferences store; see AppPreferences).
  public static let interfaceKey = "uiLanguage", contentLanguageKey = "contentLanguage", contentRegionKey = "contentRegion"
  public static let systemToken = "system"
  public init(stored interface: String?, content: String?, region: String?) {
    func choice(_ value: String?) -> Choice { guard let value, value != Self.systemToken, !value.isEmpty else { return .system }; return .identifier(value) }
    self.init(interfaceLanguage: choice(interface), contentLanguage: choice(content), contentRegion: choice(region))
  }
  public var storedValues: (interface: String, content: String, region: String) {
    func text(_ choice: Choice) -> String { if case .identifier(let value) = choice { return value }; return Self.systemToken }
    return (text(interfaceLanguage), text(contentLanguage), text(contentRegion))
  }
}

/// The language and region hints sent with requests. They shape wording and ordering of what the service returns; the
/// service still decides availability for the account and its real location.
public struct ContentRequestHints: Equatable, Sendable {
  public let language: String
  public let region: String?
  public init(language: String, region: String?) { self.language = language; self.region = region }
  /// Always false: a content region is a hint, never a way around a service restriction.
  public static let decidesAvailability = false
  /// The two-letter region for a service `gl` parameter, or nil when none was chosen.
  public var gl: String? { region }
  /// The `hl` for a service request: the language and, when given, the script (`zh-Hans`), WITHOUT the region (the region travels as `gl`).
  public var hl: String {
    let parts = language.split(separator: "-").map(String.init)
    guard let first = parts.first else { return AppLocales.sourceLanguage }
    if let script = parts.dropFirst().first(where: { $0.count == 4 }) { return first + "-" + script }
    return first
  }
}
