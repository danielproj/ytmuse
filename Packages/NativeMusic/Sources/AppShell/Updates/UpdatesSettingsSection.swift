import DesignSystem
import Features
import SwiftUI
import Updates

/// W30 (BUILD06, T30.3). The Updates part of Settings. Off until the person opts in; nothing here contacts anything unless the person presses Check Now or
/// has chosen the daily check. A build without a feed says so and offers no control.
struct UpdatesSettingsSection: View {
    let controller: UpdateController
    /// The two rows are written through the settings store, so this page and Restore Defaults use the same owner binding.
    let store: SettingsStore
    var body: some View {
        Section("Updates") {
            if let reason = controller.unavailable {
                Text(reason.message).font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("updatesUnavailable")
            } else {
                Picker("Check for updates", selection: Binding(get: { store.text("updateChecking") }, set: { value in Task { try? await store.set("updateChecking", .text(value)) } })) {
                    Text("Ask me once").tag("askOnce"); Text("Once a day").tag("daily"); Text("Only when I choose Check Now").tag("manualOnly")
                }.accessibilityIdentifier("updatesDaily")
                Text(controller.state.mode == .undecided ? "Not asked yet. Nothing is checked until you choose." : "A check downloads one small signed file from GitHub. It sends no account, listening or device information.")
                    .font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("updatesNote")
                Toggle("Download updates automatically", isOn: Binding(get: { store.bool("automaticInstallation") }, set: { value in Task { try? await store.set("automaticInstallation", .bool(value)) } }))
                    .accessibilityIdentifier("updatesAutomatic")
                Text("An update is downloaded and verified in the background, never while music is playing. It is installed only when you press Restart to Update.")
                    .font(.footnote).foregroundStyle(MusicStyle.secondaryText)
                HStack {
                    Button("Check Now") { Task { await controller.checkNow() } }.accessibilityIdentifier("updatesCheckNow")
                    if case .offered = controller.status { Button("Download Update") { Task { await controller.download() } }.accessibilityIdentifier("updatesDownload") }
                    if case .ready = controller.status {
                        Button("Restart to Update") { controller.restartToInstall(confirmation: .fromPersonAction()) }
                            .disabled(controller.restartBlockedByPlayback).accessibilityIdentifier("updatesRestart")
                    }
                }
                Text(statusText).font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("updatesStatus")
                if case .ready = controller.status, controller.installFailure != nil {
                    Text("The update could not be installed. Nothing was changed; you can try again.").font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("updatesInstallFailure")
                }
                if case .ready = controller.status, controller.restartBlockedByPlayback {
                    Text("Playback is active. Pause or stop it to restart into the update.").font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("updatesPlaybackHold")
                }
            }
        }
    }
    private var statusText: LocalizedStringKey {
        switch controller.status {
        case .idle: "No check yet."
        case .checking: "Checking…"
        case .upToDate: "YTMuse is up to date."
        case .offered(let version): "Version \(version) is available."
        case .downloading(let version): "Downloading version \(version)…"
        case .ready(let version): "Version \(version) is ready. Restart to finish."
        case .failed: "The update could not be verified or installed. Nothing was changed."
        }
    }
}

/// The one-time question (BUILD06 "ask before enabling automatic checks"). Either answer is recorded and the question is not asked again.
struct UpdateAskOnceModifier: ViewModifier {
    let shell: ShellCoordinator
    func body(content: Content) -> some View {
        content.alert("Check for updates once a day?", isPresented: Binding(get: { shell.updates?.shouldAskOnce == true }, set: { _ in }), actions: {
            Button("Check Daily") { shell.updates?.answerAskOnce(checkDaily: true) }
            Button("Not Now") { shell.updates?.answerAskOnce(checkDaily: false) }
        }, message: {
            Text("YTMuse can look for a new version once a day. The check downloads one small signed file and sends no account, listening or device information. You can change this in Settings.")
        })
    }
}
extension View { func updateAskOnce(_ shell: ShellCoordinator) -> some View { modifier(UpdateAskOnceModifier(shell: shell)) } }
