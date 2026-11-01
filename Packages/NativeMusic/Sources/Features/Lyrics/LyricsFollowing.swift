import AccountSession
import Foundation
import Observation

/// Which timed line is current. Exactly one line is current, or none: before the first line starts, or when the source gave no timing.
public enum TimedLyrics {
    /// The index of the last line whose start is at or before `position`; nil before the first line. `lines` must be in the source's order.
    public static func currentIndex(in lines: [MusicTimedLyricLine], at position: Double) -> Int? {
        guard position.isFinite, !lines.isEmpty else { return nil }
        var low = 0, high = lines.count
        // The last start <= position (starts are non-decreasing: the parser refuses anything else).
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].start <= position { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}

/// How the panel follows playback. Following scrolls to the current line; a person's own scrolling takes over and nothing scrolls the panel
/// again until they ask to return.
public enum LyricsFollowMode: Equatable, Sendable { case following, manual }

/// What the panel should do now. A pure decision so it can be checked without a window.
public struct LyricsScrollAction: Equatable, Sendable {
    public let index: Int
    /// False when Reduce Motion is on: the panel jumps to the line without animating.
    public let animated: Bool
}
public enum LyricsAutoScroll {
    /// Scrolls only while following, only when the current line changed, and never animates under Reduce Motion.
    public static func action(current: Int?, shown: Int?, mode: LyricsFollowMode, reduceMotion: Bool) -> LyricsScrollAction? {
        guard mode == .following, let current, current != shown else { return nil }
        return LyricsScrollAction(index: current, animated: !reduceMotion)
    }
}

/// The state behind a timed-lyrics panel: the current line, the follow mode, and whether a tap on a line may move playback.
@MainActor @Observable public final class LyricsFollowModel {
    public private(set) var lines: [MusicTimedLyricLine] = []
    public private(set) var current: Int?
    public private(set) var mode: LyricsFollowMode = .following
    /// The panel has scrolled to this line last (the view reports it).
    public private(set) var shown: Int?
    @ObservationIgnored private let seek: @MainActor (Double) async -> Bool
    @ObservationIgnored private let canSeek: @MainActor () -> Bool
    public init(seek: @escaping @MainActor (Double) async -> Bool = { _ in false }, canSeek: @escaping @MainActor () -> Bool = { false }) { self.seek = seek; self.canSeek = canSeek }

    public func setLines(_ lines: [MusicTimedLyricLine]) { self.lines = lines; current = nil; shown = nil; mode = .following }
    public func clear() { setLines([]) }
    /// A position from the player. Only the current line changes; the follow mode does not.
    public func update(position: Double) {
        let index = TimedLyrics.currentIndex(in: lines, at: position)
        if index != current { current = index }
    }
    /// The person scrolled the panel themselves.
    public func userScrolled() { if !lines.isEmpty { mode = .manual } }
    /// "Return to current line": follow again and report where to scroll.
    public func returnToCurrent() { mode = .following; shown = nil }
    public func didScroll(to index: Int) { shown = index }
    /// The scroll the panel should perform now, if any.
    public func pendingScroll(reduceMotion: Bool) -> LyricsScrollAction? { LyricsAutoScroll.action(current: current, shown: shown, mode: mode, reduceMotion: reduceMotion) }
    /// The button is offered when the person scrolled away and there is a current line to return to.
    public var canReturn: Bool { mode == .manual && current != nil }
    /// A line can move playback only when the source gave its time and the player will take a seek now.
    public var linesSeekable: Bool { !lines.isEmpty && canSeek() }
    /// Seeks to the start the source printed for a line. False (and nothing happens) when seeking is not supported right now.
    @discardableResult public func seek(toLine index: Int) async -> Bool {
        guard lines.indices.contains(index), canSeek() else { return false }
        let done = await seek(lines[index].start)
        if done { mode = .following; shown = nil }
        return done
    }
}
