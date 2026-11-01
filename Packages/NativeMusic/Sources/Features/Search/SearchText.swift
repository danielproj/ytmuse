import Foundation

/// Unicode-aware text matching for local search. Folding is deliberately lossy so a
/// query typed without accents, with decomposed accents, in another case or in
/// half/full width still finds a title; it is never used to decide what a record IS.
///
/// Order matters: canonical composition, then locale-independent lowercasing, then
/// the fold. Folding before lowercasing maps Turkish `İ` to `I`, which then lowercases
/// to dotless `ı` and no caller typing `istanbul` could match.
public enum SearchText {
    public static func fold(_ text: String) -> String {
        var value = text.precomposedStringWithCanonicalMapping.lowercased()
        for (from, to) in special where value.contains(from) { value = value.replacingOccurrences(of: from, with: to) }
        value = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        return value.precomposedStringWithCanonicalMapping
    }
    /// Letters the system fold leaves alone but a keyboard without them types as the base form.
    private static let special: [(String, String)] = [("ß", "ss"), ("æ", "ae"), ("œ", "oe"), ("ø", "o"), ("đ", "d"), ("ł", "l"), ("ı", "i"), ("þ", "th"), ("ð", "d")]

    /// Folded word tokens. Runs of Han, kana or Hangul have no word separators, so each
    /// character is its own token; every other script splits on non-letters/digits.
    public static func tokens(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        func flush() { if !current.isEmpty { result.append(current); current = "" } }
        for character in fold(text) {
            if isIdeographic(character) { flush(); result.append(String(character)) }
            else if character.isLetter || character.isNumber || character.unicodeScalars.contains(where: { $0.properties.generalCategory == .nonspacingMark }) { current.append(character) }
            else { flush() }
        }
        flush()
        return result
    }
    static func isIdeographic(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FA1F: true
            default: false
            }
        }
    }
    /// How many single-character edits a token of this length may be away and still count.
    /// Short tokens are exact only: one edit on three letters is a different word.
    public static func allowedEdits(forLength length: Int) -> Int {
        switch length { case ..<4: 0; case 4...7: 1; default: 2 }
    }
    /// Damerau-Levenshtein (adjacent transposition counts as one edit), bounded: nil above `limit`.
    public static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int? {
        if abs(a.count - b.count) > limit { return nil }
        if a.isEmpty || b.isEmpty { let d = max(a.count, b.count); return d <= limit ? d : nil }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { value = min(value, previous2[j - 2] + 1) }
                current[j] = value; rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return nil }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count] <= limit ? previous[b.count] : nil
    }
}

/// How a query matched a title, best first. Only `.tolerant` involves a guess.
public enum SearchMatchQuality: Int, Comparable, Sendable {
    case tolerant = 1, substring = 2, tokenPrefix = 3, prefix = 4, exact = 5
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A query folded once so it can be matched against many titles.
public struct FoldedQuery: Sendable, Equatable {
    /// Exactly what was typed, never rewritten.
    public let original: String
    public let folded: String
    public let tokens: [String]
    /// Alphabetic words, in typed order; matched as word prefixes, in any order.
    private let words: [String]
    /// Maximal runs of ideographs, in typed order. A run has no word breaks, so it must
    /// appear contiguously and in order in the title; its characters are never reordered.
    private let runs: [String]
    public init(_ original: String) {
        self.original = original
        folded = SearchText.fold(original).trimmingCharacters(in: .whitespacesAndNewlines)
        tokens = SearchText.tokens(original)
        words = tokens.filter { !$0.contains(where: SearchText.isIdeographic) }
        var found: [String] = [], run = ""
        for character in folded {
            if SearchText.isIdeographic(character) { run.append(character) }
            else if !run.isEmpty { found.append(run); run = "" }
        }
        if !run.isEmpty { found.append(run) }
        runs = found
    }
    public var isEmpty: Bool { tokens.isEmpty }

    /// Best way this query matches `title`, or nil. Tolerance is tried only when no
    /// exact, prefix or substring reading exists, and applies to alphabetic words of
    /// four or more characters; ideographs and short words must match exactly.
    public func match(_ title: String) -> SearchMatchQuality? {
        guard !isEmpty else { return nil }
        let titleFolded = SearchText.fold(title).trimmingCharacters(in: .whitespacesAndNewlines)
        if titleFolded == folded { return .exact }
        if titleFolded.hasPrefix(folded) { return .prefix }
        let titleWords = SearchText.tokens(title).filter { !$0.contains(where: SearchText.isIdeographic) }
        let runsPresent = runs.allSatisfy { titleFolded.contains($0) }
        if runsPresent, wordsPrefixMatch(titleWords) { return words.isEmpty ? .substring : .tokenPrefix }
        if titleFolded.contains(folded) { return .substring }
        return runsPresent && tolerantMatch(titleWords) ? .tolerant : nil
    }
    private func wordsPrefixMatch(_ titleWords: [String]) -> Bool {
        var used = Set<Int>()
        for word in words {
            guard let index = titleWords.indices.first(where: { !used.contains($0) && titleWords[$0].hasPrefix(word) }) else { return false }
            used.insert(index)
        }
        return true
    }
    private func tolerantMatch(_ titleWords: [String]) -> Bool {
        var used = Set<Int>()
        var tolerated = false
        for word in words {
            if let index = titleWords.indices.first(where: { !used.contains($0) && titleWords[$0].hasPrefix(word) }) { used.insert(index); continue }
            let characters = Array(word)
            let allowed = SearchText.allowedEdits(forLength: characters.count)
            guard allowed > 0 else { return false }
            let found = titleWords.indices.first { index in
                guard !used.contains(index) else { return false }
                let candidate = Array(titleWords[index])
                // A word may be a typo of a whole word, or of the start of one being typed.
                let whole = SearchText.distance(characters, candidate, limit: allowed) != nil
                let start = candidate.count > characters.count && SearchText.distance(characters, Array(candidate.prefix(characters.count)), limit: allowed) != nil
                return whole || start
            }
            guard let found else { return false }
            used.insert(found); tolerated = true
        }
        return tolerated
    }
}

/// Offers a respelling taken from words already present in local titles. It never
/// rewrites the query: the caller shows it and the person chooses to apply it.
public enum SearchCorrection {
    public static func suggest(for query: FoldedQuery, vocabulary titles: [String]) -> String? {
        guard !query.isEmpty else { return nil }
        var words: [String: (display: String, count: Int)] = [:]
        for title in titles {
            let originals = title.split { !$0.isLetter && !$0.isNumber }
            let folded = SearchText.tokens(title)
            guard originals.count == folded.count else { continue }
            for (original, key) in zip(originals, folded) { words[key, default: (String(original), 0)].count += 1 }
        }
        var replaced = false
        var parts: [String] = []
        let spoken = query.original.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard spoken.count == query.tokens.count else { return nil }
        for (original, token) in zip(spoken, query.tokens) {
            if words.keys.contains(where: { $0.hasPrefix(token) }) { parts.append(String(original)); continue }
            let characters = Array(token)
            let allowed = SearchText.allowedEdits(forLength: characters.count)
            guard allowed > 0, !characters.contains(where: SearchText.isIdeographic) else { return nil }
            let best = words.filter { SearchText.distance(characters, Array($0.key), limit: allowed) != nil }
                .max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }
            guard let best else { return nil }
            parts.append(best.value.display); replaced = true
        }
        return replaced ? parts.joined(separator: " ") : nil
    }
}
