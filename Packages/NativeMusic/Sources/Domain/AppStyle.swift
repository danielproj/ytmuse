/// The app's look, beside `Appearance` (which picks light or dark). `standard` (the default since 2026-11-06, the account holder's choice) is the
/// macOS look: the main window is translucent behind itself (the desktop shows through the sidebar and the glass panels, as in Finder), and the
/// other windows and sheets use the system window background. `ytmuse` is the app's own deep-dark canvas, scrimmed glass panels and red accent.
/// Stored under `key` in `AppPreferences.store`.
public enum AppStyle: String, CaseIterable, Sendable {
    case ytmuse, standard
    public static let key = "appearanceStyle"
    /// The style of an install that never chose one, and of a value this version does not know.
    public static let defaultStyle = AppStyle.standard
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? Self.defaultStyle
    }
}
