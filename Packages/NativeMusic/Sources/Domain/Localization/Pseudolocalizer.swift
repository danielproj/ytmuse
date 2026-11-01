import Foundation

/// W28 (L10N04): pseudolocalization for layout audits. Accented letters expose clipped glyph ascenders and fonts without
/// coverage; expansion (about +40%, more for short strings) exposes fixed widths that only fit English; the bidi form
/// wraps text in right-to-left marks to expose leading/trailing assumptions. Placeholders (`%@`, `%lld`, `%1$@`) and
/// `{name}` tokens are never altered, so a pseudolocalized sentence still formats.
public enum Pseudolocalizer {
  public enum Style: Sendable { case accented, long, rightToLeft }
  private static let accents: [Character: Character] = [
    "a": "à", "b": "ƀ", "c": "ç", "d": "ð", "e": "é", "f": "ƒ", "g": "ĝ", "h": "ĥ", "i": "î", "j": "ĵ", "k": "ķ", "l": "ļ", "m": "ɱ",
    "n": "ñ", "o": "ö", "p": "þ", "q": "ǫ", "r": "ŕ", "s": "š", "t": "ţ", "u": "ü", "v": "ṽ", "w": "ŵ", "x": "ẋ", "y": "ý", "z": "ž",
    "A": "À", "B": "Ɓ", "C": "Ç", "D": "Ð", "E": "É", "F": "Ƒ", "G": "Ĝ", "H": "Ĥ", "I": "Î", "J": "Ĵ", "K": "Ķ", "L": "Ļ", "M": "Ṁ",
    "N": "Ñ", "O": "Ö", "P": "Þ", "Q": "Ǫ", "R": "Ŕ", "S": "Š", "T": "Ţ", "U": "Ü", "V": "Ṽ", "W": "Ŵ", "X": "Ẋ", "Y": "Ý", "Z": "Ž"]
  private static let filler = "·ẽẍþàñð·"
  public static func apply(_ text: String, style: Style = .accented) -> String {
    let tokens = tokenize(text)
    var out = ""
    for token in tokens {
      switch token {
      case .literal(let value): out += value
      case .text(let value): out += value.map { accents[$0].map(String.init) ?? String($0) }.joined()
      }
    }
    switch style {
    case .accented: return "[" + out + "]"
    case .long:
      // Expansion counts only the characters a translator would write, never placeholders.
      let visible = tokens.reduce(0) { sum, token in if case .text(let value) = token { sum + value.count } else { sum } }
      let extra = visible <= 6 ? visible * 2 : visible <= 12 ? Int(Double(visible) * 1.2) : Int(Double(visible) * 0.6)
      var padding = ""; while padding.count < extra { padding += filler }
      return "[" + out + " " + String(padding.prefix(max(extra, 0))) + "]"
    case .rightToLeft:
      // U+202E RIGHT-TO-LEFT OVERRIDE would reverse the glyphs; the embedding form keeps the text readable and flips layout.
      return "\u{202B}" + out + "\u{202C}"
    }
  }
  private enum Token { case literal(String), text(String) }
  private static func tokenize(_ text: String) -> [Token] {
    let pattern = #"%(?:\d+\$)?(?:l{0,2}|h{0,2}|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSp]|%%|\{[A-Za-z0-9_]+\}"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [.text(text)] }
    var tokens: [Token] = [], cursor = text.startIndex
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let range = Range(match.range, in: text) else { continue }
      if range.lowerBound > cursor { tokens.append(.text(String(text[cursor..<range.lowerBound]))) }
      tokens.append(.literal(String(text[range]))); cursor = range.upperBound
    }
    if cursor < text.endIndex { tokens.append(.text(String(text[cursor...]))) }
    return tokens
  }
  /// Format specifiers of a string, in order of appearance, for catalog audits (a translation must keep the same set).
  public static func placeholders(in text: String) -> [String] {
    tokenize(text).compactMap { if case .literal(let value) = $0, value != "%%" { value } else { nil } }
  }
}
