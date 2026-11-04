import AppKit
import DesignSystem
import Diagnostics
import Domain
import Features
import SwiftUI

/// W27. The Settings window: native categories on the left, a search field above them, one pane on the right. Every row comes from `SettingsRegistry`, so a
/// setting that has no effect cannot appear as a control: a row whose capability does not exist shows its reason instead (T27.2). The owners' own sections
/// (launch at login, notifications, Spotlight, global shortcuts) are the panes' rows for their settings, so their guards and identifiers are unchanged.
struct SettingsWindow: View {
    let accounts: LocalAccountBootstrap
    @State private var selection: SettingCategory = .appearance
    @State private var query = ""
    private var store: SettingsStore { accounts.settings }

    var body: some View {
        MusicGlassGroup {
            HStack(spacing: 0) {
                sidebar.frame(width: 200)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.musicSurface()
        }.padding(MusicSpace.lg).frame(minWidth: 780, idealWidth: 820, minHeight: 560, idealHeight: 620).musicCanvas()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            TextField("Search Settings", text: $query).musicField(dense: true).accessibilityIdentifier("settingsSearch").padding(.bottom, MusicSpace.xs)
            // At the 560 pt minimum, 48 pt outer + 24 pt sidebar insets leave 488 pt.
            // Search stays fixed; categories (12 x at least 36 pt plus gaps) scroll in the remainder.
            ScrollView {
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    ForEach(SettingCategory.allCases) { category in
                        Button { selection = category; query = "" } label: {
                            Label(category.title, systemImage: category.symbol).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, MusicSpace.xs).padding(.horizontal, MusicSpace.sm)
                                .musicSelectionBackground(selection == category && query.isEmpty).musicHoverHighlight().contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("settingsCategory." + category.rawValue)
                            .accessibilityAddTraits(selection == category ? .isSelected : [])
                    }
                    RootsReadout(accounts: accounts)
                }
            }.scrollIndicators(.automatic)
        }.padding(MusicSpace.sm)
    }

    @ViewBuilder private var detail: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { results } else { SettingsPane(accounts: accounts, category: selection) }
    }
    private var results: some View {
        let found = SettingsRegistry.search(query)
        return ScrollView {
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                if found.isEmpty { Text("No settings match “\(query)”.").foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("settingsNoResults") }
                ForEach(found) { definition in
                    Button { selection = definition.category; query = "" } label: {
                        VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                            Text(definition.title()).font(.body)
                            Text(definition.category.title).font(.footnote).foregroundStyle(MusicStyle.secondaryText)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("settingsResult." + definition.id)
                }
            }.padding(MusicSpace.md)
        }
    }
}

struct SettingsPane: View {
    let accounts: LocalAccountBootstrap
    let category: SettingCategory
    @State private var restoredNote: String?
    private var store: SettingsStore { accounts.settings }
    /// The page's Restore Defaults, through the guard. The note says what happened.
    @MainActor private func restore() async -> String {
        if let refusal = await accounts.restoreDefaults(category, confirmed: true) { return String(localized: "Nothing was changed: \(refusal)") }
        let count = SettingsRegistry.settings(in: category).filter { $0.storage != .policy && $0.availability.isControllable && !$0.restoresOnlyOnRequest }.count
        return String(localized: "Restored \(count) settings on this page.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        Label(category.title, systemImage: category.symbol).font(MusicPageStyle.section)
            .accessibilityAddTraits(.isHeader).padding(.horizontal, MusicSpace.lg).padding(.top, MusicSpace.lg)
        Form {
            switch category {
            case .account: AccountsSettingsPane(accounts: accounts)
            case .storage: StorageSettingsPane(accounts: accounts)
            case .privacy: PrivacySettingsPane(accounts: accounts)
            case .diagnostics: DiagnosticsSettingsPane(accounts: accounts)
            case .language: LanguageRegionSection()
            default:
                definitionRows
                if category == .appearance { TextSizeSection() }
            }
            if hasResettable {
                Section {
                    Button("Restore Defaults") { Task { restoredNote = await restore() } }
                        .accessibilityIdentifier(category == .appearance ? "restoreAppearance" : "restoreDefaults." + category.rawValue).musicPageAction()
                    if let restoredNote { Text(restoredNote).font(.footnote).accessibilityIdentifier("restoredNote") }
                    Text("Restores only the settings on this page. Your playlists, library and account are not changed.").font(.footnote).foregroundStyle(MusicStyle.secondaryText)
                }
            }
        }.formStyle(.grouped).controlSize(.regular).scrollContentBackground(.hidden).padding(MusicSpace.xs).accessibilityElement(children: .contain).accessibilityIdentifier("settingsPane." + category.rawValue)
        }
    }
    private var hasResettable: Bool { SettingsRegistry.settings(in: category).contains { $0.storage != .policy && $0.availability.isControllable } }

    /// The registry's rows for this category, with the owners' own sections standing in for their settings.
    @ViewBuilder private var definitionRows: some View {
        let definitions = SettingsRegistry.settings(in: category)
        if category != .updates { Section(category.title) {
            ForEach(definitions.filter { Self.customOwner(of: $0) == nil }) { SettingRow(definition: $0, store: store) }
            if category == .playback { OutputNote(accounts: accounts) }
        } }
        // W30: the Updates page is the updater's own section (the two rows are owner-held; a build without a feed says so and offers no control).
        if category == .updates, let updates = accounts.shell.updates { UpdatesSettingsSection(controller: updates, store: store) }
        if definitions.contains(where: { $0.id == "launchAtLogin" }) { ShellPreferencesSection(shell: accounts.shell) }
        if category == .integration { IntegrationSections(shell: accounts.shell) }
    }
    static func customOwner(of definition: SettingDefinition) -> String? {
        ["launchAtLogin", "resumeAfterWake", "statusTooltip", "trackChangeNotifications", "spotlightIndexing", "spotlightPrivate", "globalShortcuts", "updateChecking", "automaticInstallation"].contains(definition.id) ? definition.id : nil
    }
}

/// One setting. A toggle, a picker, a slider or a fixed policy; an unavailable capability is shown as its reason, with no control.
struct SettingRow: View {
    let definition: SettingDefinition
    let store: SettingsStore
    @State private var sliderValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            control
            if !definition.detail().isEmpty { Text(definition.detail()).font(.footnote).foregroundStyle(MusicStyle.secondaryText) }
            if let note = definition.availability.note {
                Text(note).font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("settingNote." + definition.id)
            }
            Text(scopeText).font(.caption2).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("settingScope." + definition.id)
        }
    }
    private var scopeText: String {
        switch definition.scope {
        case .global: String(localized: "This Mac")
        case .account: String(localized: "This account")
        case .window: String(localized: "This window")
        }
    }
    @ViewBuilder private var control: some View {
        let id = definition.id
        if !definition.availability.isControllable || definition.control == .readOnly {
            LabeledContent(definition.title()) { Text(effectiveText).foregroundStyle(MusicStyle.secondaryText) }.accessibilityIdentifier("settingValue." + id)
        } else {
            switch definition.control {
            case .toggle:
                Toggle(definition.title(), isOn: Binding(get: { store.bool(id) }, set: { value in Task { try? await store.set(id, .bool(value)) } }))
                    .accessibilityIdentifier("setting." + id)
            case .choice(let choices):
                Picker(definition.title(), selection: Binding(get: { store.text(id) }, set: { value in Task { try? await store.set(id, .text(value)) } })) {
                    ForEach(choices) { Text($0.title).tag($0.value) }
                }.accessibilityIdentifier(id == "appearance" ? "appearancePicker" : "setting." + id)
            case .slider(let range, let step):
                if id == "downloadStorage" {
                    Picker(definition.title(), selection: Binding(get: { Int64(store.double(id) * SettingsOwners.gibibyte) }, set: { bytes in Task { try? await store.set(id, .double(Double(bytes) / SettingsOwners.gibibyte)) } })) {
                        ForEach(DownloadBudgetChoices.options(including: Int64(store.double(id) * SettingsOwners.gibibyte)), id: \.self) { Text(ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary)).tag($0) }
                    }.accessibilityIdentifier("setting." + id)
                } else {
                    LabeledContent(definition.title()) {
                        HStack {
                            Slider(value: Binding(get: { sliderValue ?? store.double(id) }, set: { sliderValue = $0 }), in: range, step: step) { editing in
                                if !editing, let value = sliderValue { Task { try? await store.set(id, .double(value)); sliderValue = nil } }
                            }.frame(width: 160).accessibilityIdentifier("setting." + id)
                            Text(String(format: "%.0f s", sliderValue ?? store.double(id))).monospacedDigit().foregroundStyle(MusicStyle.secondaryText)
                        }
                    }
                }
            case .readOnly: EmptyView()
            }
        }
    }
    private var effectiveText: String {
        let value = store.value(definition.id)
        switch value {
        case .text(let text): return Self.words[text] ?? text
        default: return value.description
        }
    }
    static let words: [String: String] = [
        "full": String(localized: "Full while visible"), "menuBar": String(localized: "Menu bar"), "followsWindows": String(localized: "Follows open windows"),
        "pauseNoResume": String(localized: "Pause, no automatic resume"), "bestAvailable": String(localized: "Best available"), "onWhereSupported": String(localized: "On where supported"),
        "ask": String(localized: "Ask"), "systemDefault": String(localized: "System default"), "chosen": String(localized: "Chosen output"), "audioWhenPermitted": String(localized: "Audio when permitted"),
        "inApp": String(localized: "In the app"), "off": String(localized: "Off"), "askOnce": String(localized: "Ask once"), "offWhilePlaying": String(localized: "Off while playing"), "unassigned": String(localized: "Unassigned"),
    ]
}

/// The output is chosen from the player's output button, where the routes are live. Forgetting the remembered one is its own action: Restore Defaults on this page
/// does not touch it.
struct OutputNote: View {
    let accounts: LocalAccountBootstrap
    @State private var note: String?
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            Text("Choose an output from the output button in the player.").font(.footnote).foregroundStyle(MusicStyle.secondaryText)
            Button("Forget Remembered Output") { Task { note = await accounts.restoreDefaults(nil, only: "outputRoute", confirmed: true).map { String(localized: "Nothing was changed: \($0)") } ?? String(localized: "The remembered output was forgotten.") } }
                .accessibilityIdentifier("forgetOutput").musicPageAction()
            if let note { Text(note).font(.footnote).accessibilityIdentifier("forgetOutputNote") }
        }
    }
}

struct IntegrationSections: View {
    let shell: ShellCoordinator
    var body: some View {
        Group {
            NotificationSettingsSection(shell: shell)
            SpotlightPreferencesSection(settings: shell.spotlightSettings)
            GlobalShortcutsSection(shell: shell)
        }
    }
}
