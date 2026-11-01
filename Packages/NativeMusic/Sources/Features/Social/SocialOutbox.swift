import Foundation
import Observation

/// One social action the person asked for and what came of it. The outbox is a record of explicit actions, newest first: nothing in it
/// is sent later, replayed or queued for when the connection returns.
public struct SocialOutboxEntry: Identifiable, Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        /// Left and not answered yet.
        case pending
        /// The source's positive statement.
        case confirmed
        /// The source answered and refused, or the action never left. `sent` says which.
        case failed(String, sent: Bool)
        /// The request left and the outcome is unknown: it is read again before anything is sent again.
        case unconfirmed
        /// The role or the source did not allow it, so nothing was sent.
        case denied(SocialDenial)
        /// The source has no route for this action in this app yet. Nothing was sent.
        case sourceUnresolved(String)
    }
    public let id: UUID
    public let action: SocialActionKind
    /// What it was about, in words ("Comment on “Song”").
    public let subject: String
    public internal(set) var result: Result
    public let at: Date
    public var wasSent: Bool {
        switch result { case .pending, .confirmed, .unconfirmed: true; case .failed(_, let sent): sent; case .denied, .sourceUnresolved: false }
    }
}

@MainActor @Observable public final class SocialOutbox {
    public private(set) var entries: [SocialOutboxEntry] = []
    private let limit: Int
    public init(limit: Int = 50) { self.limit = max(1, limit) }

    @discardableResult func open(_ action: SocialActionKind, subject: String, result: SocialOutboxEntry.Result = .pending, now: Date = Date()) -> UUID {
        let entry = SocialOutboxEntry(id: UUID(), action: action, subject: subject, result: result, at: now)
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        return entry.id
    }
    func settle(_ id: UUID, _ result: SocialOutboxEntry.Result) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].result = result
    }
    public func entry(_ id: UUID) -> SocialOutboxEntry? { entries.first { $0.id == id } }
    public func clear() { entries = [] }
}
