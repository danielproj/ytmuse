import Domain
import Foundation

/// W27 (section 16). The one table of every setting the app has: its category, the scope it is kept in, its default, who owns the behaviour behind it, and
/// whether the capability behind it exists. Settings are DATA here so that one table test can hold every row of section 16 to its exact default and its
/// downstream effect, and so a row the app cannot honour is stated as such (with the reason) instead of being a control that does nothing.

public enum SettingCategory: String, CaseIterable, Sendable, Identifiable {
    case account, general, appearance, playback, library, downloads, integration, privacy, updates, language, storage, diagnostics
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .account: String(localized: "Accounts")
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .playback: String(localized: "Playback")
        case .library: String(localized: "Library")
        case .downloads: String(localized: "Downloads")
        case .integration: String(localized: "Integration")
        case .privacy: String(localized: "Privacy")
        case .updates: String(localized: "Updates")
        case .language: String(localized: "Language")
        case .storage: String(localized: "Storage")
        case .diagnostics: String(localized: "Diagnostics")
        }
    }
    public var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .playback: "play.circle"
        case .library: "music.note.list"
        case .downloads: "arrow.down.circle"
        case .integration: "puzzlepiece.extension"
        case .privacy: "hand.raised"
        case .updates: "arrow.triangle.2.circlepath"
        case .language: "globe"
        case .storage: "internaldrive"
        case .diagnostics: "stethoscope"
        }
    }
}

/// Where a value lives. Global: this Mac. Account: the signed-in account (switching account changes only these). Window: one window.
public enum SettingScope: String, CaseIterable, Sendable { case global, account, window }

public enum SettingValue: Equatable, Sendable {
    case bool(Bool), int(Int), double(Double), text(String)
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var intValue: Int? { if case .int(let v) = self { v } else { nil } }
    public var doubleValue: Double? { if case .double(let v) = self { v } else if case .int(let v) = self { Double(v) } else { nil } }
    public var textValue: String? { if case .text(let v) = self { v } else { nil } }
    public var description: String {
        switch self { case .bool(let v): v ? "on" : "off"; case .int(let v): String(v); case .double(let v): String(v); case .text(let v): v }
    }
}

public enum SettingControl: Sendable, Equatable {
    case toggle
    case choice([SettingChoice])
    case slider(ClosedRange<Double>, step: Double)
    /// A fixed policy: shown with its current effect, nothing to change.
    case readOnly
}
public struct SettingChoice: Sendable, Equatable, Identifiable {
    public let value: String
    public let title: String
    public var id: String { value }
    public init(_ value: String, _ title: String) { self.value = value; self.title = title }
}

/// Whether the capability behind a setting exists. `unavailable` rows have no control: they show the reason (T27.2).
public enum SettingAvailability: Sendable, Equatable {
    case available
    /// Works, in a limited situation the note names.
    case scoped(String)
    /// Cannot be offered on this Mac / with this service; the reason is shown in place of a control.
    case unavailable(String)
    public var isControllable: Bool { if case .unavailable = self { false } else { true } }
    public var note: String? { switch self { case .available: nil; case .scoped(let n), .unavailable(let n): n } }
}

/// How the setting's value is held.
public enum SettingStorage: Sendable, Equatable {
    /// In the settings store (user defaults keyed by scope), under `key` for the global scope.
    case stored(key: String)
    /// Held by the component that owns the behaviour (login item, mini-player, download engine, output routes, notification and Spotlight opt-ins,
    /// global shortcuts). The settings store reads and resets it through the owner's binding.
    case owner(String)
    /// A fixed policy. Nothing is stored.
    case policy
}

public struct SettingDefinition: Identifiable, Sendable {
    public let id: String
    /// The exact first column of the section 16 row this setting belongs to.
    public let specRow: String
    public let category: SettingCategory
    public let scope: SettingScope
    public let title: @Sendable () -> String
    public let detail: @Sendable () -> String
    public let control: SettingControl
    public let defaultValue: SettingValue
    public let storage: SettingStorage
    public let availability: SettingAvailability
    public let keywords: [String]
    /// Plain statement of the downstream effect the table test observes.
    public let effect: String
    /// True for a setting that Restore Defaults on its page does NOT touch; it has its own explicit action (the remembered output route).
    public let restoresOnlyOnRequest: Bool
    public init(id: String, specRow: String, category: SettingCategory, scope: SettingScope = .global, title: @autoclosure @escaping @Sendable () -> String, detail: @autoclosure @escaping @Sendable () -> String = "",
                control: SettingControl, defaultValue: SettingValue, storage: SettingStorage, availability: SettingAvailability = .available, keywords: [String] = [], effect: String, restoresOnlyOnRequest: Bool = false) {
        self.restoresOnlyOnRequest = restoresOnlyOnRequest
        self.id = id; self.specRow = specRow; self.category = category; self.scope = scope; self.title = title; self.detail = detail; self.control = control
        self.defaultValue = defaultValue; self.storage = storage; self.availability = availability; self.keywords = keywords; self.effect = effect
    }
    public var storedKey: String? { if case .stored(let key) = storage { key } else { nil } }
    public var isStored: Bool { storedKey != nil }
    /// A policy or unavailable row has no per-user value.
    public var hasUserValue: Bool { storage != .policy && availability.isControllable }
}

/// One row of the section 16 table and the settings that implement it.
public struct SettingsSpecRow: Sendable {
    public let label: String
    public let defaultText: String
    public let settings: [SettingDefinition]
}

public enum SettingsRegistry {
    public static let schemaVersion = 1
    public static let schemaVersionKey = "settings.schemaVersion"

    // The words of the reasons are kept here so the Settings screen, the Diagnostics bundle and the tests read the same sentences.
    static var youTubeMusicOwnsRadio: String { String(localized: "YouTube Music’s own player decides what plays after the queue ends; this app has no switch for it. To start a radio yourself, choose Start Radio where it is offered.") }
    static var noExplicitQueue: String { String(localized: "YouTube Music keeps its own queue, so this choice applies to music from files on this Mac.") }
    static var artworkAccentUnderStandard: String { String(localized: "With the Standard style there is no tinted window background, so only the player is tinted.") }
    /// A note a setting carries because of ANOTHER setting's current value (shown under the control, which stays usable). Today: the artwork
    /// tint reaches only the player under the Standard style, which paints no canvas for it to tint.
    public static func dependentNote(for id: String, style: AppStyle) -> String? {
        id == "artworkAccent" && style == .standard ? artworkAccentUnderStandard : nil
    }
    static var updatesNeedAFeed: String { String(localized: "Works in a signed release build that has an update feed. A source build has none: it checks nothing and installs nothing, and says so on this page.") }

    public static let definitions: [SettingDefinition] = [
        // MARK: Appearance
        SettingDefinition(id: "appearance", specRow: "Appearance", category: .appearance, title: String(localized: "Appearance"), detail: String(localized: "Applies to all app windows on this Mac."),
                          control: .choice([SettingChoice("system", String(localized: "System")), SettingChoice("light", String(localized: "Light")), SettingChoice("dark", String(localized: "Dark"))]),
                          defaultValue: .text("system"), storage: .stored(key: "appearance"), keywords: ["theme", "dark", "light", "mode"],
                          effect: "The color scheme of every window (Appearance.colorScheme)."),
        // APPEARANCE-STYLE: the look beside light/dark. It belongs to the specification's Appearance row (the row's default text, System, is the
        // colour scheme's). Standard is the default (the account holder's choice, 2026-11-06); YTMuse is one choice away.
        SettingDefinition(id: "appearanceStyle", specRow: "Appearance", category: .appearance, title: String(localized: "Style"),
                          detail: String(localized: "YTMuse is the app’s own dark look. Standard follows macOS: the main window lets the desktop show through its sidebar, and other windows use the system background."),
                          control: .choice([SettingChoice(AppStyle.standard.rawValue, String(localized: "Standard")), SettingChoice(AppStyle.ytmuse.rawValue, String(localized: "YTMuse"))]),
                          defaultValue: .text(AppStyle.defaultStyle.rawValue), storage: .stored(key: AppStyle.key), keywords: ["style", "theme", "look", "glass", "translucent", "transparent", "system", "standard", "native"],
                          effect: "The app style of every window (AppStyle via the musicAppStyle environment): YTMuse canvas, or the system window material and backgrounds."),
        SettingDefinition(id: "artworkAccent", specRow: "Artwork accent", category: .appearance, title: String(localized: "Tint the window from the artwork"),
                          detail: String(localized: "A subdued tint taken from the playing artwork. Text contrast does not change."),
                          control: .toggle, defaultValue: .bool(true), storage: .stored(key: "settings.artworkAccent"), keywords: ["accent", "color", "tint", "artwork"],
                          effect: "The player accent is nil (no tint) when off."),
        SettingDefinition(id: "motion", specRow: "Motion", category: .appearance, title: String(localized: "Motion"),
                          detail: String(localized: "Full while a window is visible. Reduced automatically when macOS Reduce Motion or Low Power Mode is on."),
                          control: .readOnly, defaultValue: .text("full"), storage: .policy, keywords: ["animation", "reduce motion", "low power"],
                          effect: "ShellMotion.animates is false under Reduce Motion or Low Power Mode."),
        // MARK: General
        SettingDefinition(id: "launchAtLogin", specRow: "Launch at login", category: .general, title: String(localized: "Launch YTMuse at login"),
                          detail: String(localized: "At login YTMuse opens in the menu bar only, with no window and no audio."),
                          control: .toggle, defaultValue: .bool(false), storage: .owner("loginItem"), keywords: ["startup", "login item"],
                          effect: "The login item service is registered only by this toggle."),
        SettingDefinition(id: "backgroundControl", specRow: "Background control", category: .general, title: String(localized: "Menu bar control"),
                          detail: String(localized: "YTMuse stays in the menu bar. Closing the last window keeps playback that can continue active."),
                          control: .readOnly, defaultValue: .text("menuBar"), storage: .policy, keywords: ["menu bar", "background", "last window"],
                          effect: "Closing the last regular window leaves the status item and playback."),
        SettingDefinition(id: "dockIcon", specRow: "Dock icon", category: .general, title: String(localized: "Dock icon"),
                          detail: String(localized: "Visible while a regular window is open; hidden when YTMuse runs only in the menu bar."),
                          control: .readOnly, defaultValue: .text("followsWindows"), storage: .policy, keywords: ["dock"],
                          effect: "The activation policy follows the count of regular windows."),
        SettingDefinition(id: "restoreSession", specRow: "Restore session", category: .general, title: String(localized: "Restore the last session at launch"),
                          detail: String(localized: "After a manual launch the last song is shown paused. Nothing plays until you press Play."),
                          control: .toggle, defaultValue: .bool(true), storage: .stored(key: "settings.restoreSession"), keywords: ["resume", "last session", "launch"],
                          effect: "restoreLastSession runs at launch only when on."),
        SettingDefinition(id: "resumeAfterWake", specRow: "", category: .general, title: String(localized: "Resume playback after the Mac wakes"),
                          control: .toggle, defaultValue: .bool(true), storage: .stored(key: "shell.resumeAfterWake"), keywords: ["wake", "sleep", "resume"],
                          effect: "ShellPreferences.resumeAfterWake."),
        SettingDefinition(id: "statusTooltip", specRow: "", category: .general, title: String(localized: "Show the playing track in the menu bar tooltip"),
                          control: .toggle, defaultValue: .bool(true), storage: .stored(key: "shell.statusItem.trackTooltip"), keywords: ["tooltip", "menu bar"],
                          effect: "ShellPreferences.tooltipEnabled."),
        SettingDefinition(id: "miniPlayerOnTop", specRow: "Mini-player always on top", category: .general, title: String(localized: "Keep the mini-player on top"),
                          detail: String(localized: "The mini-player floats above other windows."),
                          control: .toggle, defaultValue: .bool(false), storage: .owner("miniPlayer"), keywords: ["pin", "float", "mini player"],
                          effect: "The mini-player window level is floating when on."),
        // MARK: Playback
        SettingDefinition(id: "headphoneDisconnect", specRow: "Headphone disconnect", category: .playback, title: String(localized: "When headphones disconnect"),
                          detail: String(localized: "Playback pauses. It does not resume by itself when they reconnect."),
                          control: .readOnly, defaultValue: .text("pauseNoResume"), storage: .policy, keywords: ["headphones", "route loss", "bluetooth"],
                          effect: "A lost route pauses; reconnecting never resumes (RouteLossPolicy)."),
        SettingDefinition(id: "crossfade", specRow: "Crossfade / EQ / normalization", category: .playback, title: String(localized: "Crossfade"), detail: String(localized: "Seconds of overlap between songs."),
                          control: .slider(0...12, step: 1), defaultValue: .double(0), storage: .stored(key: "settings.crossfadeSeconds"),
                          availability: .scoped(String(localized: "Applies to music from files on this Mac. YouTube Music plays in its own player, which this app cannot process.")),
                          keywords: ["crossfade", "fade", "overlap"], effect: "AudioEffects.crossfade of every native playback session."),
        SettingDefinition(id: "equalizer", specRow: "Crossfade / EQ / normalization", category: .playback, title: String(localized: "Equalizer"),
                          control: .choice([SettingChoice("flat", String(localized: "Flat")), SettingChoice("bass", String(localized: "Bass boost")), SettingChoice("treble", String(localized: "Treble boost")), SettingChoice("vocal", String(localized: "Vocal"))]),
                          defaultValue: .text("flat"), storage: .stored(key: "settings.equalizer"),
                          availability: .scoped(String(localized: "Applies to music from files on this Mac. YouTube Music plays in its own player, which this app cannot process.")),
                          keywords: ["eq", "equalizer", "bass", "treble"], effect: "AudioEffects.bands of every native playback session."),
        SettingDefinition(id: "normalization", specRow: "Crossfade / EQ / normalization", category: .playback, title: String(localized: "Normalize volume"),
                          control: .toggle, defaultValue: .bool(false), storage: .stored(key: "settings.normalization"),
                          availability: .scoped(String(localized: "Applies to music from files on this Mac. YouTube Music plays in its own player, which this app cannot process.")),
                          keywords: ["normalize", "loudness", "volume"], effect: "AudioEffects.normalize of every native playback session."),
        SettingDefinition(id: "autoplayRadio", specRow: "Autoplay radio", category: .playback, title: String(localized: "Autoplay radio"), detail: String(localized: "On where supported."),
                          control: .readOnly, defaultValue: .text("onWhereSupported"), storage: .policy, availability: .unavailable(youTubeMusicOwnsRadio), keywords: ["radio", "autoplay", "continue"],
                          effect: "None: YouTube Music's player continues playback."),
        SettingDefinition(id: "replaceExplicitQueue", specRow: "Replace explicit queue", category: .playback, scope: .account, title: String(localized: "When starting something new with songs queued"),
                          detail: String(localized: "What happens to songs you queued yourself (Play next, Add to queue) when you start another song or album."),
                          control: .choice([SettingChoice("ask", String(localized: "Ask")), SettingChoice("keep", String(localized: "Keep my queued songs")), SettingChoice("replace", String(localized: "Replace them"))]),
                          defaultValue: .text("ask"), storage: .stored(key: "settings.replaceExplicitQueue"), availability: .scoped(noExplicitQueue), keywords: ["queue", "replace", "keep", "ask", "play next"],
                          effect: "The queue's replacement preference of every native start: Ask shows a question, Keep carries the queued songs over, Replace drops them."),
        SettingDefinition(id: "outputRoute", specRow: "Output", category: .playback, title: String(localized: "Output"), detail: String(localized: "The system default until you choose another."),
                          control: .readOnly, defaultValue: .text("systemDefault"), storage: .owner("outputs"), keywords: ["output", "airplay", "speaker", "device", "route"],
                          effect: "The preferred route is none (system default) until chosen; forgetting it is its own action, not part of Restore Defaults.", restoresOnlyOnRequest: true),
        SettingDefinition(id: "songVideo", specRow: "Song/video preference", category: .playback, title: String(localized: "Songs or videos"),
                          detail: String(localized: "Audio when the account and the content permit."),
                          control: .readOnly, defaultValue: .text("audioWhenPermitted"), storage: .policy, keywords: ["video", "song", "audio only"],
                          effect: "Video is shown only when you ask for it; Audio Only is offered whenever the service publishes the song version."),
        // MARK: Library
        SettingDefinition(id: "newPlaylistVisibility", specRow: "New playlist visibility", category: .library, scope: .account, title: String(localized: "New playlist visibility"),
                          detail: String(localized: "Where the New Playlist form starts. Nothing is created until you press Create."),
                          control: .choice([SettingChoice("private", String(localized: "Private")), SettingChoice("unlisted", String(localized: "Unlisted")), SettingChoice("public", String(localized: "Public"))]),
                          defaultValue: .text("private"), storage: .stored(key: "settings.newPlaylistVisibility"), keywords: ["playlist", "private", "public", "unlisted"],
                          effect: "PlaylistCreator's default privacy is the account's stored choice."),
        // MARK: Downloads
        SettingDefinition(id: "downloadStorage", specRow: "Download storage", category: .downloads, title: String(localized: "Download storage"), detail: String(localized: "The most the downloads of all accounts may keep on this Mac."),
                          control: .slider(1...500, step: 1), defaultValue: .double(20), storage: .owner("downloads"),
                          availability: .scoped(String(localized: "YouTube Music has no downloads on the Mac. This limit applies to files you add from this Mac.")),
                          keywords: ["storage", "limit", "budget", "gib", "space"], effect: "The download engine's budget in bytes."),
        SettingDefinition(id: "automaticOnExpensive", specRow: "Automatic downloads on expensive networks", category: .downloads, title: String(localized: "Download automatically on expensive networks"),
                          detail: String(localized: "Cellular hotspots and other expensive connections. Low Data Mode always blocks automatic downloads."),
                          control: .toggle, defaultValue: .bool(false), storage: .owner("downloads"), keywords: ["cellular", "hotspot", "metered", "expensive"],
                          effect: "An automatic job on an expensive path runs only when on."),
        // MARK: Integration
        SettingDefinition(id: "trackChangeNotifications", specRow: "Track-change notifications", category: .integration, title: String(localized: "Notify when the song changes"),
                          control: .toggle, defaultValue: .bool(false), storage: .owner("notifications"), keywords: ["notification", "song change"],
                          effect: "Turning on asks macOS for permission; nothing is posted while off."),
        SettingDefinition(id: "downloadErrorNotifications", specRow: "Download/error notifications", category: .integration, title: String(localized: "Also show download and error messages as notifications"),
                          detail: String(localized: "Download and error messages always appear in the app. Turn this on to also get a system notification when a download finishes or fails, or when you need to sign in again."),
                          control: .toggle, defaultValue: .bool(false), storage: .owner("notifications"), keywords: ["notification", "error", "download", "failed"],
                          effect: "Turning on asks macOS for permission; a finished or failed download posts one notification only while on."),
        SettingDefinition(id: "spotlightIndexing", specRow: "Spotlight private library indexing", category: .integration, title: String(localized: "Show saved songs, albums and artists in Spotlight"),
                          control: .toggle, defaultValue: .bool(false), storage: .owner("spotlight"), keywords: ["spotlight", "search", "index"],
                          effect: "Nothing is indexed while off; turning off removes what was indexed."),
        SettingDefinition(id: "spotlightPrivate", specRow: "Spotlight private library indexing", category: .integration, title: String(localized: "Also show my playlists and listening history"),
                          control: .toggle, defaultValue: .bool(false), storage: .owner("spotlight"), keywords: ["spotlight", "private", "playlists", "history"],
                          effect: "Private items are indexed only when on and the first switch is on."),
        SettingDefinition(id: "globalShortcuts", specRow: "Global shortcuts", category: .integration, title: String(localized: "Global shortcuts"), detail: String(localized: "None is set until you record one."),
                          control: .readOnly, defaultValue: .text("unassigned"), storage: .owner("shortcuts"), keywords: ["shortcut", "hot key", "keyboard"],
                          effect: "No hot key is registered until one is recorded; reset clears all."),
        // MARK: Diagnostics (not a section 16 row: the opt-in profiler of DIAG02)
        SettingDefinition(id: "profiling", specRow: "", category: .diagnostics, title: String(localized: "Collect local performance timings"),
                          detail: String(localized: "Off. When on, YTMuse keeps a few timings (launch, search, playback start) in one small file on this Mac, never sent anywhere. Turning it off deletes the file."),
                          control: .toggle, defaultValue: .bool(false), storage: .owner("diagnostics"), keywords: ["profiling", "performance", "timings"],
                          effect: "The profiler records nothing and writes no file while off."),
        // MARK: Privacy
        SettingDefinition(id: "analytics", specRow: "Analytics and remote crash submission", category: .privacy, title: String(localized: "Analytics and remote crash reports"),
                          detail: String(localized: "Off. YTMuse contains no analytics SDK and sends no diagnostics anywhere. You can export a redacted support bundle yourself."),
                          control: .readOnly, defaultValue: .text("off"), storage: .policy, keywords: ["analytics", "telemetry", "crash", "tracking"],
                          effect: "No network route exists for diagnostics; the app has no analytics dependency."),
        // MARK: Updates
        SettingDefinition(id: "updateChecking", specRow: "Update checking", category: .updates, title: String(localized: "Check for updates"), detail: String(localized: "Ask once; a daily background check only after you opt in."),
                          control: .choice([SettingChoice("askOnce", String(localized: "Ask me once")), SettingChoice("daily", String(localized: "Once a day")), SettingChoice("manualOnly", String(localized: "Only when I choose Check Now"))]),
                          defaultValue: .text("askOnce"), storage: .owner("updates"), availability: .scoped(updatesNeedAFeed), keywords: ["update", "version"],
                          effect: "No update request is made until the person opts in; then at most one a day while the app runs (UpdateController.checkIfDue)."),
        SettingDefinition(id: "automaticInstallation", specRow: "Automatic installation", category: .updates, title: String(localized: "Download updates automatically"), detail: String(localized: "Never while music is playing. An update is only downloaded and verified; it is installed when you press Restart to Update."),
                          control: .toggle, defaultValue: .bool(false), storage: .owner("updates"), availability: .scoped(updatesNeedAFeed), keywords: ["update", "install", "restart", "download"],
                          effect: "A found update is staged in the background when idle, never swapped in without an explicit restart (UpdateController.restartToInstall)."),
    ]

    public static func definition(_ id: String) -> SettingDefinition? { definitions.first { $0.id == id } }
    public static func settings(in category: SettingCategory) -> [SettingDefinition] { definitions.filter { $0.category == category } }
    public static let defaultTextByRow: [String: String] = [
        "Appearance": "System", "Artwork accent": "Enabled, subdued", "Motion": "Full while visible; follows system accessibility and power state", "Launch at login": "Off",
        "Background control": "Menu bar; last window closure keeps eligible playback active", "Dock icon": "Visible with regular windows; hidden when operating only in menu bar",
        "Restore session": "On, paused after manual launch", "Headphone disconnect": "Pause; no automatic resume on reconnect",
        "Crossfade / EQ / normalization": "Off / flat and off / off", "Autoplay radio": "On where supported", "Replace explicit queue": "Ask", "Download storage": "20 GiB aggregate",
        "Automatic downloads on expensive networks": "Off", "Output": "System default until user selects another", "Song/video preference": "Audio when account and content permit",
        "Mini-player always on top": "Off", "New playlist visibility": "Private", "Track-change notifications": "Off", "Download/error notifications": "In-app by default; system notifications opt-in",
        "Spotlight private library indexing": "Off", "Global shortcuts": "Unassigned", "Analytics and remote crash submission": "Off; no analytics SDK", "Update checking": "Ask once; daily background check only after opt-in",
        "Automatic installation": "Off while playing; explicit restart required",
    ]
    /// The section 16 rows in the specification's own order. A test reads the specification and holds this list to it.
    public static let specRowOrder = ["Appearance", "Artwork accent", "Motion", "Launch at login", "Background control", "Dock icon", "Restore session", "Headphone disconnect",
        "Crossfade / EQ / normalization", "Autoplay radio", "Replace explicit queue", "Download storage", "Automatic downloads on expensive networks", "Output", "Song/video preference",
        "Mini-player always on top", "New playlist visibility", "Track-change notifications", "Download/error notifications", "Spotlight private library indexing", "Global shortcuts",
        "Analytics and remote crash submission", "Update checking", "Automatic installation"]
    /// Each row with the settings that implement it.
    public static var specRows: [SettingsSpecRow] {
        specRowOrder.map { label in SettingsSpecRow(label: label, defaultText: defaultTextByRow[label] ?? "", settings: definitions.filter { $0.specRow == label }) }
    }

    /// 20 GiB, the Download storage default.
    public static let defaultDownloadBudgetBytes: Int64 = 20 << 30

    // MARK: Search

    /// Native Settings search: every word of the query must appear in the title, detail, category, spec row or keywords, ignoring case and diacritics.
    public static func search(_ query: String, in all: [SettingDefinition] = definitions) -> [SettingDefinition] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return all.filter { definition in
            let haystack = ([definition.title(), definition.detail(), definition.category.title, definition.specRow, definition.availability.note ?? ""] + definition.keywords).joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

/// The equalizer presets: ten bands (31 Hz to 16 kHz) in decibels, within the engine's plus or minus 12.
public enum EqualizerPreset: String, CaseIterable, Sendable {
    case flat, bass, treble, vocal
    public var bands: [Float] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .treble: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]
        case .vocal: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]
        }
    }
}
