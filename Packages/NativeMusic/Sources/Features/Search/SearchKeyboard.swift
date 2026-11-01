import Foundation

/// The keys search and the palette own while a text field is being edited.
public enum SearchKey: Sendable, Equatable { case up, down, returnKey, escape, space, other }
public enum SearchKeyOutcome: Sendable, Equatable {
    /// Consumed: the field must not also act on it.
    case handled
    /// Left to the field and the system, exactly as if search were not there.
    case passThrough
}

extension SearchModel {
    /// Keyboard rules for the field. Arrows move through results, Return acts on the
    /// selection (or searches now), Escape clears. Space and every other key are never
    /// consumed, so typing, the caret, IME composition and the system's Space handling
    /// stay native. `composing` is true while an input method holds marked text: the
    /// keys then belong to it.
    public func handle(_ key: SearchKey, composing: Bool = false, perform: (@MainActor (SearchResult) -> Void)? = nil) -> SearchKeyOutcome {
        guard !composing else { return .passThrough }
        switch key {
        case .down, .up:
            guard !results.isEmpty else { return .passThrough }
            moveSelection(by: key == .down ? 1 : -1); return .handled
        case .returnKey:
            if let result = selectedResult {
                if let perform { perform(result) } else { Task { await activate(result) } }
                return .handled
            }
            guard !trimmedQuery.isEmpty else { return .passThrough }
            submit(); return .handled
        case .escape:
            guard !query.isEmpty else { return .passThrough }
            clear(); return .handled
        case .space, .other:
            return .passThrough
        }
    }
}
