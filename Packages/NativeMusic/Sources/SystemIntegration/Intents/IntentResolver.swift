import Foundation

// W24 (MAC03, T24.2). Names to entities, and the current-account rule.

public enum IntentResolver {
    /// Whether an entity may be used now: it must carry exactly the current account. Anything else is refused with the same
    /// sentence whether it is another account's or an older session's, so the refusal discloses nothing about either.
    public static func admit(_ media: IntentMedia, current: IntentScope?) -> IntentRefusal? {
        guard let current else { return .signedOut }
        return media.account == current.accountID ? nil : .staleIdentity
    }
    /// Same rule for an identifier that has not been decoded (or cannot be).
    public static func admit(encoded: String, current: IntentScope?) -> IntentRefusal? {
        guard let current else { return .signedOut }
        guard let claimed = IntentMedia.claimedAccount(of: encoded), claimed == current.accountID else { return .staleIdentity }
        return nil
    }
    /// Folds case, diacritics and punctuation for matching a spoken name; it never changes what is displayed.
    public static func fold(_ text: String) -> String {
        let decomposed = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return decomposed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(String.init).joined()
            .split(separator: " ").joined(separator: " ")
    }
    /// Resolves a name against candidates already in the app's caches. Exact folded matches win over partial ones; several equally good
    /// matches are returned together and NEVER reduced to the first (T24.2: duplicate titles require disambiguation).
    public static func resolve(_ text: String, among candidates: [IntentMedia], kind: IntentMediaKind? = nil) -> IntentResolution {
        let wanted = fold(text)
        guard !wanted.isEmpty else { return .none }
        let pool = kind.map { k in candidates.filter { $0.kind == k } } ?? candidates
        // One identity once, however many caches held it.
        var seen = Set<String>(), unique: [IntentMedia] = []
        for item in pool where seen.insert(item.identity).inserted { unique.append(item) }
        let exact = unique.filter { fold($0.title) == wanted }
        let matches = exact.isEmpty ? unique.filter { fold($0.title).contains(wanted) } : exact
        switch matches.count {
        case 0: return .none
        case 1: return .one(matches[0])
        default: return .many(matches)
        }
    }
    /// The line that tells two same-titled items apart (kind, then subtitle).
    public static func disambiguationLine(_ media: IntentMedia) -> String {
        [media.title, media.subtitle, media.kind.rawValue].compactMap { $0 }.joined(separator: " — ")
    }
}
