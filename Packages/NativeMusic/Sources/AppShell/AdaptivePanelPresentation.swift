import Observation

/// Presentation width is committed before the sheet binding changes. An adaptive
/// dismissal must not erase selection as if the user had closed the panel.
@MainActor @Observable final class AdaptivePanelPresentation<Selection: Equatable> {
    var selection: Selection?
    var allowsInline = true
    var presentsSheet: Bool { selection != nil && !allowsInline }
    func sheetChanged(_ presented: Bool) { if !presented && !allowsInline { selection = nil } }
    func toggle(_ value: Selection) { selection = selection == value ? nil : value }
}
