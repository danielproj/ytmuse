import Foundation

/// SEC03. What a diagnostic may never carry: cookies, authorization headers, tokens, signed query parameters, email addresses, private playlist names and
/// private search strings. The redactor works on TEXT, so it is applied at every point text enters the diagnostics (when an event is recorded, again when a
/// bundle is built, and to the error path of both) and cannot be bypassed by a new field.
///
/// Two layers. Patterns catch the shapes secrets take whatever their value (a Bearer token, `SAPISID=...`, a JWT, a `sig=` query item, an email address,
/// a long opaque run). The context catches what has no shape: a playlist called "Mum's 60th", a search the person typed, an account's display name. The
/// context lists the exact strings the app knows are private right now; they are matched ignoring case, diacritics and URL / JSON escaping.
public struct RedactionContext: Sendable, Equatable {
    /// Strings that are private to the person: account labels and handles, playlist names, search terms, device names, file names the person chose.
    public var privateStrings: Set<String>
    public init(privateStrings: Set<String> = []) { self.privateStrings = privateStrings }
    public static let empty = RedactionContext()
    public func adding(_ values: some Sequence<String>) -> RedactionContext { var copy = self; copy.privateStrings.formUnion(values); return copy }
}

public enum DiagnosticRedactor {
    public static let placeholder = "<redacted>"
    /// Strings shorter than this are not matched from the context: a one-letter playlist name would otherwise erase every occurrence of that letter.
    public static let minimumPrivateLength = 3

    private struct Rule { let regex: NSRegularExpression; let template: String }
    private static func rule(_ pattern: String, _ template: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> Rule {
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), template: template)
    }
    /// Names of fields whose value is a secret, anywhere (header, query item, JSON key, `key=value` line).
    private static let secretNames = "access_token|refresh_token|id_token|auth_token|token|bearer|sapisidhash|sapisid|apisid|hsid|ssid|sid|lsid|login_info|visitor_info1_live|visitor_data|po_token|potoken|"
        + "__secure-[a-z0-9_-]+|__host-[a-z0-9_-]+|signature|sig|signed|lsig|key|api_key|apikey|client_secret|secret|password|passwd|pwd|credential|sessionid|session_id|nonce|cookie|authorization|"
        // W29: every other cookie the app handles or YouTube sets, so a bare `NAME=value` fragment is covered without a `Cookie:` header around it.
        + "sidcc|socs|consent|pref|visitor_privacy_metadata|ysc|nid|1p_jar|"
        // TH2: the two bare cookies W29 missed (`OSID` is Google's per-service session, `AEC` its anti-abuse cookie); the `__Secure-` and `__Host-` forms were already covered.
        + "osid|aec"
    /// Names of fields whose value is something the person typed or chose.
    private static let privateNames = "q|query|search_query|search|term|playlist|playlist_name|list_name|display_name|displayname|handle|email|e-mail|mail|username"
    private static let rules: [Rule] = [
        // W29: a URL that travels as a PARAMETER of another URL (an encoded redirect, `continue=https%3A%2F%2F...`, possibly encoded twice or three times) has no `://` for
        // the URL pass to find. Its whole run goes: the host and every query item inside it are the secret.
        rule(#"(?<![A-Za-z0-9])(?:https?|wss?|ftp)(?:%3A|%253A|%25253A)(?:%2F|%252F|%25252F){2}[A-Za-z0-9%._~\-]*"#, "<url>"),
        // Header lines first: the whole value goes (a Cookie header is one long line of secrets).
        rule(#"(?<![A-Za-z0-9_-])((?:proxy-)?authorization|(?:set-)?cookie|x-goog-[a-z0-9-]+|x-origin|x-youtube-[a-z0-9-]+)\s*[:=]\s*[^\r\n]*"#, "$1: <redacted>"),
        // JWTs and Bearer/Basic credentials.
        rule(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*"#, "<token>"),
        rule(#"\b(bearer|basic|sapisidhash|sapisid1phash|sapisid3phash)\s+[A-Za-z0-9._~+/=-]{6,}"#, "$1 <redacted>"),
        // JSON: "field": "value"
        rule(#"("(?:"# + secretNames + "|" + privateNames + #")"\s*:\s*)"(?:[^"\\]|\\.)*""#, "$1\"<redacted>\""),
        // key=value / key: value / key = "value"
        rule(#"(?<![A-Za-z0-9])((?:"# + secretNames + "|" + privateNames + #"))\s*[=:]\s*("[^"]*"|'[^']*'|[^\s&;,"')\]}]+)"#, "$1=<redacted>"),
        // Email addresses, in the open and percent- or entity-encoded.
        // TH2: the numeric entity has hexadecimal and zero-padded forms too (`&#x40;`, `&#X0040;`, `&#0064;`).
        rule(#"[A-Za-z0-9._%+'-]+(?:@|%40|%2540|%252540|&#0*64;|&#x0*40;|&commat;)[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        // The home folder names the person.
        rule(#"/Users/[^/\s"']+(?:/[^\s"']*)?"#, "/Users/<user>/<path>", options: []),
        // Long opaque runs (base64, hex, ids): 32 or more characters of one token alphabet.
        rule(#"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/_-]{32,}={0,2}(?![A-Za-z0-9+/=_-])"#, "<opaque>", options: []),
    ]

    /// The first-party destinations a diagnostic may name (SEC02): Google sign-in, YouTube Music, and the artwork hosts. Any other host, and in particular a media
    /// host (a signed stream URL), is replaced whole. For an allowed host only the path, query and fragment go.
    public static let namedHosts: Set<String> = ["music.youtube.com", "www.youtube.com", "youtube.com", "accounts.google.com", "www.google.com", "i.ytimg.com", "yt3.ggpht.com", "lh3.googleusercontent.com"]
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"\b(https?|wss?|ftp)://(?:[^\s/@"'<>]*@)?([A-Za-z0-9.-]+)(?::\d+)?((?:[/?#](?:[^\s"'<>)\]]|<redacted>|<private>|<email>|<token>|<opaque>|<url>)*)?)"#, options: [.caseInsensitive])
    private static func redactURLs(_ text: String) -> String {
        let matches = urlPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = "", cursor = text.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: text), let schemeRange = Range(match.range(at: 1), in: text), let hostRange = Range(match.range(at: 2), in: text) else { continue }
            result += text[cursor..<whole.lowerBound]
            let host = text[hostRange].lowercased()
            let tail = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            if namedHosts.contains(host) { result += "\(text[schemeRange].lowercased())://\(host)" + (tail.isEmpty ? "" : "/<redacted>") } else { result += "<url>" }
            cursor = whole.upperBound
        }
        return result + text[cursor...]
    }

    /// TH2: JSON's `\uXXXX` escape for printable ASCII, then any run of backslashes before `/`.
    private static let unicodeEscape = try! NSRegularExpression(pattern: #"\\u00([2-7][0-9A-Fa-f])"#)
    private static func unescapeJSON(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var value = text
        let matches = unicodeEscape.matches(in: value, range: NSRange(value.startIndex..., in: value))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: value), let code = Range(match.range(at: 1), in: value).flatMap({ UInt8(value[$0], radix: 16) }), code >= 0x20, code != 0x7F else { continue }
            value.replaceSubrange(whole, with: String(UnicodeScalar(code)))
        }
        return value.replacingOccurrences(of: #"\\+/"#, with: "/", options: .regularExpression)
    }
    /// TH2: a URL without its scheme (`rr4---sn-x.googlevideo.com/videoplayback?sig=...`, `music.youtube.com/watch?v=...`, `192.168.0.2:8080/x`). A host followed by a path, query or
    /// fragment, under a top-level domain from a fixed list (so a file name such as `song.mp3` or `Info.plist/x` is not a host). A protocol-relative `//host/path` counts. Treated as the scheme form is: a named host keeps its name, anything else is replaced whole.
    private static let schemelessPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9@._%:\\-])(?<![A-Za-z0-9]/)(?<!://)((?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+(?:com|net|org|edu|gov|mil|int|io|dev|app|info|biz|xyz|tv|me|ai|co|us|uk|de|fr|es|ru|jp|cn|eu|ca|au|in|br|it|nl|ch|se|no|pl|test|example|invalid|local)(?![A-Za-z0-9-])|(?:\d{1,3}\.){3}\d{1,3})(?::\d+)?((?:[/?#](?:[^\s"'<>)\]]|<redacted>|<private>|<email>|<token>|<opaque>|<url>)*))"#, options: [.caseInsensitive])
    private static func redactSchemelessURLs(_ text: String) -> String {
        let matches = schemelessPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = "", cursor = text.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: text), let hostRange = Range(match.range(at: 1), in: text) else { continue }
            result += text[cursor..<whole.lowerBound]
            let host = text[hostRange].lowercased()
            let tail = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            if namedHosts.contains(host) { result += host + (tail == "/<redacted>" || tail.isEmpty ? tail : "/<redacted>") } else { result += "<url>" }
            cursor = whole.upperBound
        }
        return result + text[cursor...]
    }

    /// Redacted text. Idempotent: redacting redacted text changes nothing.
    public static func redact(_ text: String, context: RedactionContext = .empty) -> String {
        // W29: JSON writes `/` as `\/`; a URL inside a JSON string would otherwise hide from the URL pass.
        // TH2: the escape can be doubled (JSON inside a JSON string: `\\/`) or written as a unicode escape (`\u002f`, and `\u003d` / `\u0026` / `\u0040` for `=` `&` `@`, which Google's
        // JSON uses inside URLs). Only the escapes of printable ASCII are undone, and a run of backslashes before a slash is one escape.
        var value = unescapeJSON(text)
        // The context first, so a private name inside a URL or a header is gone before any pattern splits it.
        value = redactPrivate(value, context: context)
        value = redactURLs(value)
        value = redactSchemelessURLs(value)
        for rule in rules {
            let range = NSRange(value.startIndex..., in: value)
            value = rule.regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: rule.template)
        }
        return redactPrivate(value, context: context)
    }
    /// How many separate substitutions redaction made: the bundle preview shows it, and the tests read it to prove something was removed.
    public static func redactionCount(in original: String, context: RedactionContext = .empty) -> Int {
        let once = redact(original, context: context)
        return once.components(separatedBy: placeholder).count - 1 + once.components(separatedBy: "<email>").count - 1 + once.components(separatedBy: "<token>").count - 1
            + once.components(separatedBy: "<opaque>").count - 1 + once.components(separatedBy: "<private>").count - 1 + once.components(separatedBy: "/Users/<user>").count - 1
    }
    private static func redactPrivate(_ text: String, context: RedactionContext) -> String {
        var value = text
        // Longest first, so "Road Trip 2026" goes before "Road".
        for secret in context.privateStrings.filter({ $0.count >= minimumPrivateLength }).sorted(by: { $0.count > $1.count }) {
            for variant in variants(of: secret) {
                value = value.replacingOccurrences(of: variant, with: "<private>", options: [.caseInsensitive, .diacriticInsensitive])
            }
        }
        return value
    }
    /// The string as it can appear in a log line: plain, percent-encoded (spaces as %20 or +), JSON-escaped, and with HTML entities.
    private static func variants(of secret: String) -> [String] {
        var result = [secret]
        if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { result.append(encoded) }
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if var encoded = secret.addingPercentEncoding(withAllowedCharacters: unreserved) {
            result.append(encoded); result.append(encoded.replacingOccurrences(of: "%20", with: "+"))
            // W29: encoded again by each hop of a redirect chain (twice, three times).
            for _ in 0..<2 { guard let again = encoded.addingPercentEncoding(withAllowedCharacters: unreserved), again != encoded else { break }; encoded = again; result.append(encoded) }
        }
        if let data = try? JSONEncoder().encode(secret), let string = String(data: data, encoding: .utf8), string.count > 2 { result.append(String(string.dropFirst().dropLast())) }
        for separator in ["+", "%20", "_", "-"] { result.append(secret.replacingOccurrences(of: " ", with: separator)) }
        result.append(secret.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "'", with: "&#39;").replacingOccurrences(of: "\"", with: "&quot;"))
        var seen = Set<String>()
        return result.filter { !$0.isEmpty && seen.insert($0).inserted }.sorted { $0.count > $1.count }
    }
}
