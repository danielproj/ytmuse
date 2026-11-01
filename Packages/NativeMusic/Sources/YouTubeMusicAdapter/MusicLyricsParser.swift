import AccountSession
import Foundation

/// Reads a song's `next` response (where its Lyrics tab is) and the lyrics `browse` page it points to.
///
/// Built on the real anonymous captures in `Fixtures/W18-real`. The lyrics page there is PLAIN text in a `musicDescriptionShelfRenderer`
/// with a source footer and carries no timing; this parser returns that text byte for byte (line breaks, quotes and spacing untouched) and
/// the footer verbatim. Timed lines are returned only from a shape that prints a start time per line, and a timed answer that is not
/// well-formed is refused whole rather than repaired: nothing is ever inferred, interpolated or reordered.
///
/// Internal notes (not surfaced anywhere): the timed shape (`timedLyricsModel.lyricsData.timedLyricsData[]` with a `cueRange`) is the reference
/// clients' form for a signed response and has NOT been observed from the service; it is exercised on a `synthetic-test-only` fixture and is on
/// the end-of-project live list.
public enum MusicLyricsParser {
    // MARK: next

    public static func parseWatchNext(_ root: [String: Any]) throws(MusicSessionError) -> MusicWatchNext {
        guard root["error"] == nil,
              let single = (root["contents"] as? [String: Any])?["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbed = ((single["tabbedRenderer"] as? [String: Any])?["watchNextTabbedResultsRenderer"] as? [String: Any]),
              let tabs = tabbed["tabs"] as? [[String: Any]], !tabs.isEmpty else { throw .unrecognised }
        var result: [MusicWatchNextTab] = []
        for entry in tabs {
            guard let tab = entry["tabRenderer"] as? [String: Any] else { throw .unrecognised }
            let unselectable = tab["unselectable"] as? Bool ?? false
            let target = MusicBrowseParser.endpoint(tab["endpoint"])
            let content = tab["content"] as? [String: Any]
            switch target?.pageType {
            case "MUSIC_PAGE_TYPE_TRACK_LYRICS": result.append(.init(kind: .lyrics, browseID: target?.browseID, unselectable: unselectable))
            case "MUSIC_PAGE_TYPE_TRACK_RELATED": result.append(.init(kind: .related, browseID: target?.browseID, unselectable: unselectable))
            default:
                result.append(.init(kind: content?["musicQueueRenderer"] != nil ? .upNext : .other, browseID: nil, unselectable: unselectable))
            }
        }
        // A page without the up-next queue is not a watch-next page: "no lyrics" must never be read off an unrecognised response.
        guard result.contains(where: { $0.kind == .upNext }) else { throw .unrecognised }
        return MusicWatchNext(tabs: result)
    }

    // MARK: lyrics browse

    public static func parseLyrics(_ root: [String: Any]) throws(MusicSessionError) -> MusicLyricsResult {
        guard root["error"] == nil, let contents = root["contents"] as? [String: Any] else { throw .unrecognised }
        if let timed = try timedDocument(contents) { return .lyrics(timed) }
        let lists = contents["sectionListRenderer"] as? [String: Any]
        let entries = lists?["contents"] as? [[String: Any]] ?? []
        for entry in entries {
            if let shelf = entry["musicDescriptionShelfRenderer"] as? [String: Any] {
                // Verbatim: no trimming, no normalisation. The text is the source's.
                let text = MusicBrowseParser.runs(shelf["description"]).compactMap { $0["text"] as? String }.joined()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none(.emptyPage) }
                let footer = MusicBrowseParser.runs(shelf["footer"]).compactMap { $0["text"] as? String }.joined()
                return .lyrics(MusicLyricsDocument(body: .plain(text), sourceFooter: footer.isEmpty ? nil : footer))
            }
            if entry["messageRenderer"] != nil { return .none(.emptyPage) }
        }
        if contents["messageRenderer"] != nil { return .none(.emptyPage) }
        throw .unrecognised
    }

    private static func timedDocument(_ contents: [String: Any]) throws(MusicSessionError) -> MusicLyricsDocument? {
        guard let element = contents["elementRenderer"] as? [String: Any] else { return nil }
        var node: Any? = element
        for key in ["newElement", "type", "componentType", "model", "timedLyricsModel", "lyricsData"] { node = (node as? [String: Any])?[key] }
        guard let data = node as? [String: Any] else { return nil }
        guard let lines = data["timedLyricsData"] as? [[String: Any]], !lines.isEmpty, lines.count <= 5_000 else { throw .unrecognised }
        var result: [MusicTimedLyricLine] = []
        var previous = 0.0
        for line in lines {
            guard let text = line["lyricLine"] as? String, text.utf8.count <= 4_096,
                  let cue = line["cueRange"] as? [String: Any], let start = milliseconds(cue["startTimeMilliseconds"]) else { throw .unrecognised }
            let end = milliseconds(cue["endTimeMilliseconds"])
            // Out-of-order or overlapping-backwards timing is not repaired: the document is refused.
            guard start >= previous, end.map({ $0 >= start }) ?? true else { throw .unrecognised }
            previous = start
            result.append(MusicTimedLyricLine(text: text, start: start / 1000, end: end.map { $0 / 1000 }))
        }
        let footer = data["sourceMessage"] as? String
        return MusicLyricsDocument(body: .timed(result), sourceFooter: footer?.isEmpty == false ? footer : nil)
    }
    private static func milliseconds(_ value: Any?) -> Double? {
        let number: Double?
        if let string = value as? String { number = Double(string) }
        else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { number = n.doubleValue }
        else { number = nil }
        guard let number, number.isFinite, number >= 0, number <= 86_400_000 else { return nil }
        return number
    }
}
