import Foundation

/// W28 (L10N02): locale-aware ordering and matching. Titles are compared the way a person reads them: "Track 2" before
/// "Track 10", case and width ignored, in the order the person's language expects (Swedish å after z, German ä with a,
/// Spanish ñ after n). Diacritics are NOT folded for ordering: that would undo the language's own alphabet. Names are never
/// altered; only the comparison is.
public enum NaturalOrder {
  public static func compare(_ a: String, _ b: String, locale: Locale = .current) -> ComparisonResult {
    let options: String.CompareOptions = [.numeric, .caseInsensitive, .widthInsensitive]
    let primary = a.compare(b, options: options, range: nil, locale: locale)
    if primary != .orderedSame { return primary }
    // Total order for equal-looking titles ("é" / "e"): fall back to the exact scalars, so sorting is deterministic.
    return a.compare(b, options: [.numeric], range: nil, locale: locale)
  }
  public static func sorted(_ values: [String], locale: Locale = .current) -> [String] {
    values.sorted { compare($0, $1, locale: locale) == .orderedAscending }
  }
  /// Locale-aware search key: lowercased in the person's locale FIRST, then diacritics and width folded, so Turkish "İSTANBUL"
  /// becomes "istanbul" (folding first would turn İ into I, which Turkish lowercasing then makes the dotless "ı"). Dotless ı is
  /// finally written as i so an ASCII query finds "Iğdır". The search index and the query must both go through it.
  public static func searchKey(_ text: String, locale: Locale = .current) -> String {
    text.lowercased(with: locale).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: locale).replacingOccurrences(of: "ı", with: "i")
  }
  public static func matches(_ text: String, query: String, locale: Locale = .current) -> Bool {
    let key = searchKey(query, locale: locale)
    return key.isEmpty || searchKey(text, locale: locale).contains(key)
  }
}
