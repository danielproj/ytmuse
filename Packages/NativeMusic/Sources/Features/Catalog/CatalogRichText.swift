import AccountSession
import Foundation

/// Native rich text for descriptions the service publishes (an artist's biography, an album's notes, a show's blurb).
///
/// The input is untrusted. The output is a plain `AttributedString` built from literal text: nothing is parsed as HTML or
/// Markdown, so `<script>` is shown as the characters it is, and there is no web view anywhere. Only an `https` link to a
/// host on a short allowlist survives as a link (an `http` link to an allowed host is upgraded; every other scheme,
/// `javascript:` and `file:` included, stays plain text), and a link whose visible text names a different host than its
/// target is not a link. Control characters and bidirectional overrides are removed so the text can't disguise itself.
/// The body is bounded; the attribution paragraph the service ends a description with ("From Wikipedia … under Creative
/// Commons …") is never cut, because the licence travels with the text.
public struct CatalogRichText: Sendable, Equatable {
    public let body: AttributedString
    /// The attribution paragraph, kept whole (bounded only against abuse).
    public let attribution: AttributedString?
    public let truncated: Bool
    /// The links that survived, for tests and accessibility actions.
    public let links: [URL]
    public var isEmpty: Bool { body.characters.isEmpty && attribution == nil }

    public static let collapsedLimit = 480
    public static let expandedLimit = 6_000
    static let attributionLimit = 600
    /// Hosts a description may link to: the encyclopedia and licence pages the service attributes, and YouTube itself.
    /// On YouTube's own hosts only pages that are content are linked; `/redirect?q=…` and every other path (which can carry any
    /// target) are refused. Other allowed hosts are not path-restricted.
    /// The same matcher the allowlist uses (`host == entry || host.hasSuffix("." + entry)`), so every host that is admitted as YouTube
    /// (`m.`, `gaming.`, `music.`, any subdomain) is path-restricted too. `youtu.be` is handled apart: it has no subdomains of content.
    public static func isYouTube(_ host: String) -> Bool { host == "youtube.com" || host.hasSuffix(".youtube.com") }
    static let youTubePathPrefixes = ["/watch", "/channel/", "/playlist", "/browse/", "/@", "/shorts/", "/c/"]
    public static let allowedHosts: [String] = ["wikipedia.org", "wikimedia.org", "creativecommons.org", "youtube.com", "youtu.be"]

    public static func make(_ runs: [MusicTextRun], limit: Int = collapsedLimit) -> CatalogRichText {
        let limit = max(1, min(limit, expandedLimit))
        // Flatten to characters so paragraph and link boundaries can be found, with the allowed link (if any) per character.
        var characters: [Character] = []
        var urls: [URL?] = []
        for run in runs {
            let url = safeLink(run)
            for character in sanitised(run.text) { characters.append(character); urls.append(url) }
        }
        // Collapse runs of blank lines and trim.
        var cleaned: [(Character, URL?)] = []
        var newlines = 0
        for (index, character) in characters.enumerated() {
            if character.isNewline { newlines += 1; if newlines > 2 { continue } } else { newlines = 0 }
            cleaned.append((character, urls[index]))
        }
        while let last = cleaned.last, last.0.isWhitespace || last.0.isNewline { cleaned.removeLast() }
        while let first = cleaned.first, first.0.isWhitespace || first.0.isNewline { cleaned.removeFirst() }

        // The attribution is the last blank-line-separated paragraph when it carries a link and something precedes it.
        var split = cleaned.count
        if let lastLink = cleaned.lastIndex(where: { $0.1 != nil }) {
            var start = 0, i = 0
            while i < lastLink {
                if cleaned[i].0.isNewline, i + 1 < cleaned.count, cleaned[i + 1].0.isNewline { start = i + 2 }
                i += 1
            }
            // Only the LAST paragraph can be the attribution: a link in the middle of the text must not turn everything after it into a
            // capped "attribution" (that would hide most of the description).
            var j = lastLink
            while j + 1 < cleaned.count { if cleaned[j].0.isNewline, cleaned[j + 1].0.isNewline { start = 0; break }; j += 1 }
            if start > 0 { split = start }
        }
        var bodyPart = Array(cleaned[..<split])
        while let last = bodyPart.last, last.0.isWhitespace || last.0.isNewline { bodyPart.removeLast() }
        var attributionPart = Array(cleaned[split...])
        var truncated = false
        if bodyPart.count > limit {
            var cut = limit
            if let space = bodyPart[..<cut].lastIndex(where: { $0.0.isWhitespace || $0.0.isNewline }), space > limit / 2 { cut = space }
            bodyPart = Array(bodyPart[..<cut])
            while let last = bodyPart.last, last.0.isWhitespace || last.0.isNewline || last.0 == "," { bodyPart.removeLast() }
            truncated = true
        }
        // Never hide text without a marker: an attribution cut is marked like a body cut, and "Show more" widens the cap.
        let attributionCap = limit >= expandedLimit ? 4 * attributionLimit : attributionLimit
        var attributionCut = false
        if attributionPart.count > attributionCap { attributionPart = Array(attributionPart.prefix(attributionCap)); attributionCut = true; truncated = true }
        var found: [URL] = []
        func attributed(_ part: [(Character, URL?)], ellipsis: Bool) -> AttributedString {
            var result = AttributedString()
            var index = 0
            while index < part.count {
                var end = index
                var text = ""
                while end < part.count, part[end].1 == part[index].1 { text.append(part[end].0); end += 1 }
                var piece = AttributedString(text)
                if let url = part[index].1 { piece.link = url; if !found.contains(url) { found.append(url) } }
                result.append(piece)
                index = end
            }
            if ellipsis { result.append(AttributedString("…")) }
            return result
        }
        let body = attributed(bodyPart, ellipsis: truncated)
        let attribution = attributionPart.isEmpty ? nil : attributed(attributionPart, ellipsis: attributionCut)
        return CatalogRichText(body: body, attribution: attribution, truncated: truncated, links: found)
    }

    /// Keeps tab and newline; drops every other control character, format characters that reorder text, and BOM / zero-width spaces.
    static func sanitised(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x09: result.unicodeScalars.append(scalar)
            case 0x0D: continue
            case 0x00...0x1F, 0x7F...0x9F: continue
            case 0x200B, 0xFEFF: continue
            case 0x2028, 0x2029: result.append("\n")
            case 0x202A...0x202E, 0x2066...0x2069: continue
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// The run's link if it is safe to show as one.
    static func safeLink(_ run: MusicTextRun) -> URL? {
        guard let url = run.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(), !host.isEmpty,
              allowedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        components.scheme = "https"
        guard let upgraded = components.url, upgraded.absoluteString.utf8.count <= 2048 else { return nil }
        if isYouTube(host), !youTubePathPrefixes.contains(where: { components.path.hasPrefix($0) }) { return nil }
        if host == "youtu.be", components.path.count < 2 { return nil }
        // Visible text that names a host must name the target's host.
        let visible = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if visible.lowercased().hasPrefix("http"), let shown = URLComponents(string: visible)?.host?.lowercased(), shown != host { return nil }
        return upgraded
    }
}
