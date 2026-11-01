import AccountSession
import Foundation

/// A piece of a change that cannot be merged on its own.
public struct PlaylistPlanConflict: Equatable, Sendable {
    public let kind: PlaylistConflict.Kind
    public let piece: PlaylistIntent
}
/// What to do about a change now that the playlist has been read again: the actions that can go out as they are, the parts already
/// true, and the parts that collide with a different change and need the person.
public struct PlaylistPlan: Equatable, Sendable {
    public var actions: [MusicPlaylistEditAction] = []
    public var satisfied: [String] = []
    public var conflicts: [PlaylistPlanConflict] = []
    public var isEmpty: Bool { actions.isEmpty && conflicts.isEmpty }
}

/// The merge rule for a change made against one view of a playlist when the service now shows another (SYNC05/06).
///
/// Everything is expressed through occurrence ids, so a reorder somewhere else in the playlist cannot move this change to the wrong
/// place, and the merge never produces "set the whole order": every action names one occurrence (or one field).
///
/// - add / remove: never collide with a reorder. A removal of an occurrence that is already gone is already true.
/// - move: placed before the same occurrence in the new order (or before the next surviving one if that occurrence is gone). It
///   collides only when the same occurrence was also relocated by the other change and does not already sit where this one puts it.
///   "Relocated" is decided from the longest common subsequence of the two orders: an occurrence that every longest common
///   subsequence must contain stayed put; one that some longest common subsequence leaves out may have moved, and that is ambiguous.
/// - rename / describe / privacy: applied when the field is as the person saw it, already true when it already says the new value,
///   a collision when it was changed to something else.
public enum PlaylistReconciler {
    public static func plan(for intent: PlaylistIntent, base: PlaylistSnapshot, remote: PlaylistSnapshot, found: [String: Int] = [:]) -> PlaylistPlan {
        var plan = PlaylistPlan()
        switch intent {
        case .add(let songs, let mode):
            var found = found
            var present = Set(remote.occurrences.map(\.videoID)), addedNow = Set<String>()
            for song in songs {
                if let seen = found[song.videoID], seen > 0 { found[song.videoID] = seen - 1; plan.satisfied.append(song.title); continue }
                if mode == .skipExisting, present.contains(song.videoID) || addedNow.contains(song.videoID) { plan.satisfied.append(song.title); continue }
                plan.actions.append(.add(videoID: song.videoID, duplicates: mode))
                addedNow.insert(song.videoID); present.insert(song.videoID)
            }
        case .remove(let songs):
            for song in songs {
                guard let current = remote.occurrence(song.setVideoID) else { plan.satisfied.append(song.title); continue }
                guard current.videoID == song.videoID else {
                    plan.conflicts.append(.init(kind: .occurrenceChanged(occurrence: song), piece: .remove([song]))); continue
                }
                plan.actions.append(.remove(videoID: current.videoID, setVideoID: current.setVideoID))
            }
        case .move(let song, let anchor):
            switch planMove(song, before: anchor, base: base, remote: remote) {
            case .action(let action): plan.actions.append(action)
            case .satisfied: plan.satisfied.append(song.title)
            case .conflict(let kind): plan.conflicts.append(.init(kind: kind, piece: intent))
            }
        case .rename(let title):
            if remote.title == title { plan.satisfied.append(title) }
            else if remote.title == base.title { plan.actions.append(.rename(title)) }
            else { plan.conflicts.append(.init(kind: .titleChanged(theirs: remote.title), piece: intent)) }
        case .describe(let text):
            if remote.details == text { plan.satisfied.append(text) }
            else if remote.details == base.details { plan.actions.append(.describe(text)) }
            else { plan.conflicts.append(.init(kind: .descriptionChanged(theirs: remote.details), piece: intent)) }
        case .setPrivacy(let privacy):
            if remote.privacy == privacy { plan.satisfied.append(privacy.rawValue) }
            else if remote.privacy == base.privacy { plan.actions.append(.setPrivacy(privacy)) }
            else { plan.conflicts.append(.init(kind: .privacyChanged(theirs: remote.privacy), piece: intent)) }
        }
        return plan
    }

    /// What "keep mine" sends for one conflict: the same piece, forced against the playlist as it is now. A change whose target is gone
    /// or changed has nothing to force.
    public static func forcedAction(for conflict: PlaylistConflict) -> MusicPlaylistEditAction? {
        switch conflict.piece {
        case .move(let song, let anchor):
            guard let current = conflict.theirs.occurrence(song.setVideoID), current.videoID == song.videoID else { return nil }
            let target = resolvedAnchor(anchor, moving: song, base: conflict.mine, remote: conflict.theirs)
            if case .missing = target { return nil }
            return .moveBefore(setVideoID: song.setVideoID, successorSetVideoID: target.id)
        case .rename(let title): return .rename(title)
        case .describe(let text): return .describe(text)
        case .setPrivacy(let privacy): return .setPrivacy(privacy)
        case .add, .remove: return nil
        }
    }

    // MARK: Move

    private enum MovePlan { case action(MusicPlaylistEditAction), satisfied, conflict(PlaylistConflict.Kind) }
    private enum Anchor {
        case end, before(String), missing
        var id: String? { if case .before(let id) = self { id } else { nil } }
    }
    /// The occurrence a move should sit before in the remote order. The person's anchor if it is still there; otherwise the next
    /// occurrence after it (in the order the person saw) that still exists, else the end.
    private static func resolvedAnchor(_ anchor: PlaylistOccurrence?, moving song: PlaylistOccurrence, base: PlaylistSnapshot, remote: PlaylistSnapshot) -> Anchor {
        guard let anchor else { return .end }
        if anchor.setVideoID == song.setVideoID { return .missing }
        if let there = remote.occurrence(anchor.setVideoID), there.videoID == anchor.videoID { return .before(anchor.setVideoID) }
        guard let start = base.index(of: anchor.setVideoID) else { return .missing }
        for later in base.occurrences[(start + 1)...] where later.setVideoID != song.setVideoID {
            if let there = remote.occurrence(later.setVideoID), there.videoID == later.videoID { return .before(later.setVideoID) }
        }
        return .end
    }
    private static func planMove(_ song: PlaylistOccurrence, before anchor: PlaylistOccurrence?, base: PlaylistSnapshot, remote: PlaylistSnapshot) -> MovePlan {
        guard let current = remote.occurrence(song.setVideoID) else { return .conflict(.occurrenceRemoved(occurrence: song)) }
        guard current.videoID == song.videoID else { return .conflict(.occurrenceChanged(occurrence: song)) }
        let target = resolvedAnchor(anchor, moving: song, base: base, remote: remote)
        guard case .missing = target else {
            let position = remote.index(of: song.setVideoID)!
            switch target {
            case .end where position == remote.occurrences.count - 1: return .satisfied
            case .before(let id) where remote.index(of: id) == position + 1: return .satisfied
            default: break
            }
            if mayHaveMoved(song.setVideoID, base: base.occurrences.map(\.setVideoID), remote: remote.occurrences.map(\.setVideoID)) {
                return .conflict(.movedElsewhere(occurrence: song))
            }
            return .action(.moveBefore(setVideoID: song.setVideoID, successorSetVideoID: target.id))
        }
        return .conflict(.occurrenceChanged(occurrence: song))
    }

    /// True when the other change may have relocated `id`: some longest common subsequence of the two orders (restricted to the
    /// occurrences both have) leaves it out. If the middle that differs is too large to decide exactly, the answer is "may have".
    static func mayHaveMoved(_ id: String, base: [String], remote: [String]) -> Bool {
        let inRemote = Set(remote), inBase = Set(base)
        let a = base.filter { inRemote.contains($0) }, b = remote.filter { inBase.contains($0) }
        guard a.contains(id) else { return false }
        if a == b { return false }
        guard let whole = lcs(a, b) else { return true }
        guard let without = lcs(a.filter { $0 != id }, b.filter { $0 != id }) else { return true }
        return without == whole
    }
    /// Length of the longest common subsequence, with the common ends peeled off first so the usual single move costs almost nothing.
    /// nil when the part that differs is too large to compute exactly.
    private static func lcs(_ a: [String], _ b: [String]) -> Int? {
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        let x = Array(a[start..<endA]), y = Array(b[start..<endB])
        let shared = start + (a.count - endA)
        if x.isEmpty || y.isEmpty { return shared }
        guard x.count * y.count <= 4_000_000 else { return nil }
        var previous = [Int](repeating: 0, count: y.count + 1), current = previous
        for i in 1...x.count {
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return shared + previous[y.count]
    }
}
