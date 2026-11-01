import Diagnostics
import Domain
import Downloads
import Features
import Foundation
import Observation
import OutputRoutes
import SystemIntegration
import Updates

/// W27. Connects each owner-held setting to the SettingsStore, so one table and one reset reach every behaviour the Settings screen shows. Each binding calls
/// the OWNER'S own method (never a shortcut around its guards): the login item registers only through `LoginItemModel`, notifications ask the system only through
/// `NotificationSettingsModel`, the download engine sets its budget through its own command, and so on. A reset calls the owner's reset and nothing else.
@MainActor @Observable final class DownloadSettingsMirror {
    /// Read through the engine after each change; the toggle shows this.
    private(set) var automaticOnExpensive = false
    @ObservationIgnored let engine: (any DownloadsSettingsControlling)?
    init(engine: (any DownloadsSettingsControlling)?) { self.engine = engine }
    func refresh() async { automaticOnExpensive = await engine?.automaticOnExpensiveAllowed() ?? false }
    func set(_ on: Bool) async { _ = await engine?.setAutomaticOnExpensive(enabled: on); await refresh() }
}

@MainActor enum SettingsOwners {
    static let gibibyte = Double(1 << 30)

    static let profilingKey = "settings.profiling"
    static func attach(to store: SettingsStore, shell: ShellCoordinator, downloads: DownloadsModel, downloadMirror: DownloadSettingsMirror, outputs: @escaping @MainActor () -> OutputController?,
                       profiler: @escaping @MainActor () -> LocalProfiler?) {
        store.attach(owner: "diagnostics", SettingOwnerBinding(
            read: { _ in .bool(store.backing.setting(forKey: profilingKey) as? Bool ?? false) },
            write: { _, value in
                let on = value.boolValue ?? false
                try? store.backing.setSetting(on ? true : nil, forKey: profilingKey); profiler()?.setEnabled(on)
            },
            reset: { try? store.backing.setSetting(nil, forKey: profilingKey); profiler()?.setEnabled(false) }))
        store.attach(owner: "loginItem", SettingOwnerBinding(
            read: { _ in .bool(shell.loginItem.isOn) },
            write: { _, value in if let on = value.boolValue { shell.loginItem.setEnabled(on) } },
            reset: { if shell.loginItem.isOn { shell.loginItem.setEnabled(false) } }))
        store.attach(owner: "miniPlayer", SettingOwnerBinding(
            read: { _ in .bool(shell.miniPlayer?.preferences.pinned ?? MiniPlayerPreferences.load(from: shell.preferences).pinned) },
            write: { _, value in
                guard let on = value.boolValue else { return }
                if let mini = shell.miniPlayer { mini.setPinned(on) }
                else { var prefs = MiniPlayerPreferences.load(from: shell.preferences); prefs.pinned = on; prefs.save(to: shell.preferences) }
            },
            reset: {
                if let mini = shell.miniPlayer { mini.setPinned(false) }
                else { var prefs = MiniPlayerPreferences.load(from: shell.preferences); prefs.pinned = false; prefs.save(to: shell.preferences) }
            }))
        store.attach(owner: "downloads", SettingOwnerBinding(
            read: { id in
                switch id {
                case "downloadStorage": return .double((Double(downloads.snapshot.storage.budgetBytes) / gibibyte * 10).rounded() / 10)
                case "smartDownloads": return .bool(downloads.snapshot.smartDownloadsEnabled)
                case "automaticOnExpensive": return .bool(downloadMirror.automaticOnExpensive)
                default: return nil
                }
            },
            write: { id, value in
                switch id {
                case "downloadStorage": if let gib = value.doubleValue { downloads.setBudget(bytes: Int64(gib * gibibyte)) }
                case "smartDownloads": if let on = value.boolValue { downloads.setSmartDownloads(on) }
                case "automaticOnExpensive": if let on = value.boolValue { await downloadMirror.set(on) }
                default: break
                }
            },
            reset: {
                downloads.setBudget(bytes: SettingsRegistry.defaultDownloadBudgetBytes)
                downloads.setSmartDownloads(false)
                await downloadMirror.set(false)
            }))
        store.attach(owner: "spotlight", SettingOwnerBinding(
            read: { id in id == "spotlightIndexing" ? .bool(shell.spotlightSettings.enabled) : .bool(shell.spotlightSettings.includePrivate) },
            write: { id, value in
                guard let on = value.boolValue else { return }
                if id == "spotlightIndexing" { shell.spotlightSettings.setEnabled(on) } else { shell.spotlightSettings.setIncludePrivate(on) }
            },
            reset: { shell.spotlightSettings.setIncludePrivate(false); shell.spotlightSettings.setEnabled(false) }))
        store.attach(owner: "notifications", SettingOwnerBinding(
            read: { id in id == "downloadErrorNotifications" ? .bool(shell.notifications?.statusOn ?? false) : .bool(shell.notifications?.isOn ?? false) },
            write: { id, value in
                guard let on = value.boolValue else { return }
                if id == "downloadErrorNotifications" { await shell.notifications?.setStatusEnabled(on) } else { await shell.notifications?.setEnabled(on) }
            },
            reset: { await shell.notifications?.setEnabled(false); await shell.notifications?.setStatusEnabled(false) }))
        // W30: "Update checking" and "Automatic installation" are the updater's own state. Each write calls the controller's method (which ignores a build without a feed), and nothing
        // here installs: the explicit restart is `UpdateController.restartToInstall`, reachable only from the Restart to Update button.
        store.attach(owner: "updates", SettingOwnerBinding(
            read: { id in
                guard let updates = shell.updates else { return nil }
                return id == "updateChecking" ? .text(updates.state.mode.settingsValue) : .bool(updates.state.automaticInstallation)
            },
            write: { id, value in
                guard let updates = shell.updates else { return }
                if id == "updateChecking" {
                    switch value.textValue { case "daily": updates.setDailyChecks(true); case "manualOnly": updates.setDailyChecks(false); case "askOnce": updates.resetChoices(); default: break }
                } else if let on = value.boolValue { updates.setAutomaticInstallation(on) }
            },
            reset: { shell.updates?.resetChoices() }))
        store.attach(owner: "shortcuts", SettingOwnerBinding(
            read: { _ in .text((shell.globalShortcuts?.assigned.isEmpty ?? true) ? "unassigned" : "assigned") },
            reset: { if let service = shell.globalShortcuts { for action in GlobalShortcutAction.allCases { service.clear(action) } } }))
        store.attach(owner: "outputs", SettingOwnerBinding(
            read: { _ in .text(outputs()?.coordinator.preferred.map { $0.isSystemDefault ? "systemDefault" : "chosen" } ?? "systemDefault") },
            reset: { await outputs()?.coordinator.resetToSystemDefault() }))
    }
}
