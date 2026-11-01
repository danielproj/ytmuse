import Foundation

public struct QueuePageBoundary: Sendable {
    public let previous: QueueRow?
    public let following: [QueueRow]
    public init(previous: QueueRow? = nil, following: [QueueRow] = []) { self.previous = previous; self.following = Array(following.prefix(2)) }
}
public struct QueuePageMove: Equatable, Sendable {
    public let occurrences: [UUID]
    public let before: UUID?
}
/// Only occurrence identities cross the UI/command seam. A page end has a global successor.
public enum QueuePageMoves {
    public static func drag(rows: [QueueRow], boundary: QueuePageBoundary, source: IndexSet, destination: Int) -> QueuePageMove? {
        guard !source.isEmpty, source.allSatisfy({ rows.indices.contains($0) && rows[$0].editable }), (0...rows.count).contains(destination) else { return nil }
        let remaining = rows.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.filter { $0 < destination }.count
        let target = insertion < remaining.count ? remaining[insertion] : boundary.following.first
        guard target?.editable != false else { return nil }
        return QueuePageMove(occurrences: source.map { rows[$0].id }, before: target?.id)
    }
    public static func up(rows: [QueueRow], boundary: QueuePageBoundary, index: Int) -> QueuePageMove? {
        guard rows.indices.contains(index), rows[index].editable, let previous = index > 0 ? rows[index - 1] : boundary.previous, previous.editable else { return nil }
        return QueuePageMove(occurrences: [rows[index].id], before: previous.id)
    }
    public static func down(rows: [QueueRow], boundary: QueuePageBoundary, index: Int) -> QueuePageMove? {
        guard rows.indices.contains(index), rows[index].editable else { return nil }
        let after = Array(rows.dropFirst(index + 1).prefix(2)) + boundary.following
        guard let next = after.first, next.editable else { return nil }
        let target = after.dropFirst().first
        guard target?.editable != false else { return nil }
        return QueuePageMove(occurrences: [rows[index].id], before: target?.id)
    }
}
