import DesignSystem
import SwiftUI

/// The General page's menu bar rows (W27 owns the categories): launch at login, resuming after a wake, and the status item's track tooltip.
/// Launch at login is registered only from this toggle, never at launch, never by a test.
struct ShellPreferencesSection: View {
    let shell: ShellCoordinator
    @AppStorage(ShellPreferenceKey.resumeAfterWake) private var resumeAfterWake = true
    @AppStorage(ShellPreferenceKey.statusTooltip) private var tooltip = true
    var body: some View {
        // W27: the notification, shortcut and Spotlight sections belong to the Integration page (`IntegrationSections`).
        menuBarSection
    }
    private var menuBarSection: some View {
        Section("Menu bar and sleep") {
            Toggle("Launch YTMuse at login", isOn: Binding(get: { shell.loginItem.isOn }, set: { shell.loginItem.setEnabled($0) }))
                .accessibilityIdentifier("launchAtLogin")
            Text(note).font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("launchAtLoginNote")
            #if DEBUG
            // Debug only: which login item answers the toggle. A UI run reads this BEFORE it touches the toggle and refuses unless it says "in-process fake".
            Text(shell.loginItem.usesInProcessFake ? "in-process fake" : "SYSTEM LOGIN ITEM").font(.caption2).accessibilityIdentifier("loginItemService")
            #endif
            Toggle("Resume playback after the Mac wakes", isOn: $resumeAfterWake).accessibilityIdentifier("resumeAfterWake")
            Toggle("Show the playing track in the menu bar tooltip", isOn: $tooltip).accessibilityIdentifier("statusTooltip")
        }.onAppear { shell.loginItem.refresh() }
    }
    private var note: LocalizedStringKey {
        if let failure = shell.loginItem.failure { return LocalizedStringKey(failure) }
        switch shell.loginItem.status {
        case .requiresApproval: return "Approve YTMuse in System Settings > General > Login Items to finish."
        case .unavailable: return "Launch at login is not available for this build."
        default: return "At login YTMuse opens in the menu bar only, with no window and no audio."
        }
    }
}

/// W25 (MAC05): the two Spotlight choices. Both off by default; the second only matters once the first is on.
struct SpotlightPreferencesSection: View {
    let settings: SpotlightSettings
    var body: some View {
        Section("Spotlight") {
            Toggle("Show saved songs, albums and artists in Spotlight", isOn: Binding(get: { settings.enabled }, set: { settings.setEnabled($0) })).accessibilityIdentifier("spotlightIndexing")
            Toggle("Also show my playlists and listening history", isOn: Binding(get: { settings.includePrivate }, set: { settings.setIncludePrivate($0) }))
                .disabled(!settings.enabled).accessibilityIdentifier("spotlightIndexPrivate")
            Text("Off until you turn it on. Playlists and history are private: they are shown only if you choose to, and are removed from Spotlight when you sign out, remove the account or turn this off.")
                .font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("spotlightNote")
        }
    }
}
