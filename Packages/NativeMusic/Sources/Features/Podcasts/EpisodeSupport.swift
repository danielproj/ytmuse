import AccountSession
import Foundation

/// A length printed in English the way the service prints it: "14 min 45 sec", "18 min", "1 hr 3 min", "45 sec". Anything else is nil: no length
/// is guessed from a localised string this parser does not know.
public enum EpisodeDuration {
    public static func seconds(from text: String?) -> Double? {
        guard let text, text.utf8.count <= 64 else { return nil }
        let pattern = #"^\s*(?:(\d+)\s*hr?s?\.?)?\s*(?:(\d+)\s*min(?:ute)?s?\.?)?\s*(?:(\d+)\s*sec(?:ond)?s?\.?)?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> Double? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return Double(text[swiftRange])
        }
        let parts = [group(1), group(2), group(3)]
        guard parts.contains(where: { $0 != nil }) else { return nil }
        let total = (parts[0] ?? 0) * 3600 + (parts[1] ?? 0) * 60 + (parts[2] ?? 0)
        return total > 0 ? total : nil
    }
    /// "1:03:09" / "14:45", for display of positions.
    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// One episode as a list shows it: the catalog row plus its resolved progress.
public struct EpisodeRow: Identifiable, Equatable, Sendable {
    public let item: MusicCatalogItem
    public let progress: EpisodeProgress
    public var id: String { item.id }
    public var title: String { item.title }
    public var videoID: String? { item.videoID }
    public var durationSeconds: Double? { EpisodeDuration.seconds(from: item.episode?.durationText ?? item.durationText) }
    public init(item: MusicCatalogItem, progress: EpisodeProgress) { self.item = item; self.progress = progress }
}

/// The ways the episode list can be ordered. The service's own order is the default and is restorable; the others are stable views over it
/// (equal keys keep the service's order). "Newest" and "oldest" are not offered: a row prints a day and month without a year, so no date can
/// be ordered without guessing one.
public enum EpisodeSort: String, CaseIterable, Sendable, Identifiable {
    case serviceOrder, unplayedFirst, shortest, longest, titleAscending, titleDescending
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .serviceOrder: String(localized: "Show’s order")
        case .unplayedFirst: String(localized: "Unplayed first")
        case .shortest: String(localized: "Shortest first")
        case .longest: String(localized: "Longest first")
        case .titleAscending: String(localized: "Title A–Z")
        case .titleDescending: String(localized: "Title Z–A")
        }
    }
    /// Sorts rows. Rows with no readable length sort after those with one under the length orders. Equal keys keep their original order.
    public func apply(to rows: [EpisodeRow]) -> [EpisodeRow] {
        let indexed = rows.enumerated().map { ($0.offset, $0.element) }
        func stable(_ lessThan: (EpisodeRow, EpisodeRow) -> Bool) -> [EpisodeRow] {
            indexed.sorted { lessThan($0.1, $1.1) || (!lessThan($1.1, $0.1) && $0.0 < $1.0) }.map(\.1)
        }
        switch self {
        case .serviceOrder: return rows
        case .unplayedFirst:
            func rank(_ row: EpisodeRow) -> Int { switch row.progress.status { case .unplayed: 0; case .inProgress: 1; case .played: 2 } }
            return stable { rank($0) < rank($1) }
        case .shortest: return stable { ($0.durationSeconds ?? .infinity) < ($1.durationSeconds ?? .infinity) }
        case .longest: return stable { ($0.durationSeconds.map { -$0 } ?? .infinity) < ($1.durationSeconds.map { -$0 } ?? .infinity) }
        case .titleAscending: return stable { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .titleDescending: return stable { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        }
    }
}

/// A chapter: a title and the time the episode's own description printed for it.
public struct EpisodeChapter: Equatable, Sendable, Identifiable {
    public let start: Double
    public let title: String
    public var id: Double { start }
}
public enum EpisodeChapters {
    /// Chapters come only from timestamps the description itself prints, by the rules the service's own player applies: a list of timed lines
    /// starting at 0:00, at least three, each at least ten seconds after the one before, in ascending order, and none past the end when the
    /// length is known. A description that does not satisfy ALL of them has no chapters; nothing is inferred, repaired or spaced out.
    public static func parse(description: String, duration: Double?) -> [EpisodeChapter] {
        var found: [EpisodeChapter] = []
        let pattern = #"^\s*[\(\[]?(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[\)\]]?\s*(?:[-–—:|•·]\s*)?(.*?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        for line in description.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
                return String(text[swiftRange])
            }
            guard let minutes = group(2).flatMap(Double.init), let seconds = group(3).flatMap(Double.init), seconds < 60,
                  let title = group(4), !title.isEmpty else { continue }
            let hours = group(1).flatMap(Double.init) ?? 0
            if group(1) != nil, minutes >= 60 { continue }
            found.append(EpisodeChapter(start: hours * 3600 + minutes * 60 + seconds, title: title))
        }
        guard found.count >= 3, found.first?.start == 0 else { return [] }
        for (previous, next) in zip(found, found.dropFirst()) where next.start - previous.start < 10 { return [] }
        if let duration, duration > 0, let last = found.last, last.start >= duration { return [] }
        return found
    }
    /// The chapter playing at `position`: the last one that started at or before it.
    public static func current(in chapters: [EpisodeChapter], at position: Double) -> EpisodeChapter? {
        chapters.last(where: { $0.start <= position })
    }
}
