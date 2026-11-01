import Foundation

/// Completed byte ranges of ONE variant, kept sorted, disjoint and merged. Inclusive bounds, as in `ByteRange`.
/// A range is recorded only after its bytes are durably in the staging file, so a crash can lose progress but never
/// claim bytes that are not there.
struct RangeSet: Codable, Equatable, Sendable {
    struct Span: Codable, Equatable, Sendable { var lower: Int64; var upper: Int64 }
    private(set) var spans: [Span] = []
    init() {}
    /// Rejects anything a well-formed set could not be: this is how a damaged ledger is recognised.
    init(validating spans: [Span]) throws {
        var previous: Int64?
        for span in spans {
            guard span.lower >= 0, span.upper >= span.lower, previous.map({ span.lower > $0 + 1 }) ?? true else { throw LedgerError.corrupt }
            previous = span.upper
        }
        self.spans = spans
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: try container.decode([Span].self))
    }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(spans) }

    var isEmpty: Bool { spans.isEmpty }
    var coveredBytes: Int64 { spans.reduce(0) { $0 + ($1.upper - $1.lower + 1) } }
    /// Bytes available from offset 0 without a gap.
    var contiguousPrefix: Int64 { spans.first.map { $0.lower == 0 ? $0.upper + 1 : 0 } ?? 0 }
    var highest: Int64? { spans.last?.upper }

    mutating func insert(lower: Int64, upper: Int64) {
        guard lower >= 0, upper >= lower else { return }
        var merged = Span(lower: lower, upper: upper)
        var result: [Span] = []
        var placed = false
        for span in spans {
            if span.upper + 1 < merged.lower { result.append(span) }
            else if merged.upper + 1 < span.lower { if !placed { result.append(merged); placed = true }; result.append(span) }
            else { merged = Span(lower: min(merged.lower, span.lower), upper: max(merged.upper, span.upper)) }
        }
        if !placed { result.append(merged) }
        spans = result
    }
    /// The gaps in `0..<total`, in order.
    func missing(total: Int64) -> [Span] {
        var gaps: [Span] = []; var cursor: Int64 = 0
        for span in spans {
            if span.lower > cursor { gaps.append(Span(lower: cursor, upper: min(span.lower - 1, total - 1))) }
            cursor = max(cursor, span.upper + 1)
            if cursor >= total { break }
        }
        if cursor < total { gaps.append(Span(lower: cursor, upper: total - 1)) }
        return gaps.filter { $0.lower <= $0.upper && $0.lower < total }
    }
    func isComplete(total: Int64) -> Bool { total > 0 && contiguousPrefix >= total }
    /// Drops everything at or beyond `length` (a shorter variant than the ledger remembered).
    mutating func clamp(toLength length: Int64) {
        spans = spans.compactMap { $0.lower >= length ? nil : Span(lower: $0.lower, upper: min($0.upper, length - 1)) }
    }
    mutating func removeAll() { spans = [] }
}

enum LedgerError: Error, Equatable { case corrupt, unsupportedVersion, wrongAccount }
