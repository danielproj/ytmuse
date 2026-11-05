import AccountSession
import Foundation

/// Reads the answer to the signed Recap `browse` (`MusicRecapRoute.browseID`).
///
/// Internal notes (not surfaced anywhere). What has been captured, and nothing more, is recognised:
///   * the anonymous answer (Fixtures/MF-RECAP): `responseContext` only, `logged_in` = 0, NO `contents`;
///   * one signed answer (R1, 2026-11-05, sanitized): `logged_in` = 1 and `contents.singleColumnBrowseResultsRenderer.tabs[0].tabRenderer.content`
///     holding exactly one `messageRenderer` (`text.runs` plus a nested secondary text), with no Recap figures.
/// The captured message's words were replaced by placeholders before export, so what the message MEANS is unknown: it may be an upstream fault
/// as easily as a statement about the account. It is therefore read as a service message and never as "no Recap" or "unsupported account".
/// A SUCCESSFUL Recap payload has never been captured and no parser for one exists here. Anything that is not exactly the recognised envelope
/// (HTTP errors, another handler, a missing `logged_in`, contents with other renderers, a second tab, an unreadable message, an oversized
/// text) is `MusicSessionError.unrecognised`: never an empty result and never a computed summary.
///
/// Secondary text is WITHHELD: the captured message carries a nested secondary text under two keys the export redacted (`<key:7>`, `<key:22>`).
/// Their real names are not evidenced and are not derived from string lengths or other clients, so nothing under any key other than the
/// captured primary `text` is interpreted and the message's `detail` is always nil until a capture shows those names.
public enum MusicRecapParser {
    static let maximumRuns = 16
    static let maximumServices = 16
    static let maximumParameters = 32

    public static func parse(_ root: [String: Any]) throws(MusicSessionError) -> MusicRecapReading {
        // An error body is never a Recap answer, whatever else it carries.
        guard root["error"] == nil else { throw .unrecognised }
        // The answer must prove it is the handler that was asked for; a substituted or changed upstream is unreadable, not data.
        guard let parameters = serviceParameters(root, service: "GFEEDBACK"), parameters["browse_id"] == MusicRecapRoute.browseID else { throw .unrecognised }
        switch parameters["logged_in"] {
        case "0": return .needsSignIn
        case "1": break
        default: throw .unrecognised
        }
        guard let contents = root["contents"] as? [String: Any], contents.count == 1,
              let single = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = single["tabs"] as? [[String: Any]], tabs.count == 1,
              let tab = tabs[0]["tabRenderer"] as? [String: Any],
              let content = tab["content"] as? [String: Any], content.count == 1,
              let message = content["messageRenderer"] as? [String: Any] else { throw .unrecognised }
        guard let headline = try runs(message["text"], limit: MusicRecapRoute.maximumHeadlineBytes) else { throw .unrecognised }
        return .serviceMessage(MusicRecapServiceMessage(headline: headline, detail: nil))
    }

    /// The `key`/`value` pairs of one tracking service, bounded. A key given twice with different values makes the set unusable (nil).
    static func serviceParameters(_ root: [String: Any], service name: String) -> [String: String]? {
        guard let context = root["responseContext"] as? [String: Any],
              let services = context["serviceTrackingParams"] as? [[String: Any]], services.count <= maximumServices else { return nil }
        var found: [String: String]?
        for service in services where service["service"] as? String == name {
            guard found == nil, let list = service["params"] as? [[String: Any]], list.count <= maximumParameters else { return nil }
            var result: [String: String] = [:]
            for entry in list {
                guard let key = entry["key"] as? String, let value = entry["value"] as? String else { continue }
                if let existing = result[key], existing != value { return nil }
                result[key] = value
            }
            found = result
        }
        return found
    }

    /// The text of the captured `text` object: `runs[].text` joined exactly as printed, nothing else. The only capture has this representation;
    /// `simpleText` was never captured, so an object carrying it (alone, beside valid runs, or beside malformed ones) is unreadable rather than
    /// interpreted. A run that is not an object with a string `text` fails the whole message (never a plausible partial one). Over `limit` UTF-8
    /// bytes, more runs than the bound, or a control character other than a line break or tab is refused, not truncated. nil: no readable text.
    static func runs(_ value: Any?, limit: Int) throws(MusicSessionError) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        guard object["simpleText"] == nil else { throw .unrecognised }
        guard let list = object["runs"] as? [Any] else { return nil }
        guard list.count <= maximumRuns else { throw .unrecognised }
        var parts: [String] = []
        for entry in list {
            guard let run = entry as? [String: Any], let piece = run["text"] as? String else { throw .unrecognised }
            parts.append(piece)
        }
        let text = parts.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard text.utf8.count <= limit else { throw .unrecognised }
        for scalar in text.unicodeScalars where scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t" { throw .unrecognised }
        return text
    }
}
