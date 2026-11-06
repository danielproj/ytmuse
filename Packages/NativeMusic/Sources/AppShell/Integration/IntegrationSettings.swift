import AppKit
import DesignSystem
import SwiftUI
import SystemIntegration

// W26 (MAC08, MAC09). The Settings panes for the two opt-in system features: song-change notifications and the global shortcuts.
// Both are off or unassigned until the person acts here, and neither asks the system for anything before that.

struct NotificationSettingsSection: View {
    let shell: ShellCoordinator
    var body: some View {
        Section("Notifications") {
            if let model = shell.notifications {
                Toggle("Notify when the song changes", isOn: Binding(get: { model.isOn }, set: { on in Task { await model.setEnabled(on) } }))
                    .accessibilityIdentifier("songNotifications")
                Text(model.note ?? String(localized: "Off by default. Turning it on asks macOS for permission to show notifications. They show the title and artist only."))
                    .font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("songNotificationsNote")
                #if DEBUG
                Text(model.usesInProcessFake ? "in-process fake" : "SYSTEM NOTIFICATIONS").font(.caption2).accessibilityIdentifier("notificationService")
                #endif
            }
        }
    }
}

struct GlobalShortcutsSection: View {
    let shell: ShellCoordinator
    @State private var recording: GlobalShortcutAction?
    @State private var message: String?
    @State private var revision = 0
    var body: some View {
        Section("Global shortcuts") {
            Text("Work from any app. None is set until you record one. A shortcut needs Command, Control or Option and cannot replace a standard editing or system shortcut.")
                .font(.footnote).foregroundStyle(MusicStyle.secondaryText)
            if let service = shell.globalShortcuts {
                ForEach(GlobalShortcutAction.allCases, id: \.self) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        let chord = service.assigned[action]
                        Text(recording == action ? String(localized: "Press a shortcut…") : chord?.label ?? String(localized: "Not set"))
                            .foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("globalShortcutValue." + action.rawValue)
                        Button(recording == action ? "Cancel" : "Record") { message = nil; recording = recording == action ? nil : action }
                            .accessibilityIdentifier("globalShortcutRecord." + action.rawValue).musicAction(.secondary)
                        Button("Clear") { service.clear(action); revision += 1; message = nil }.disabled(chord == nil)
                            .accessibilityIdentifier("globalShortcutClear." + action.rawValue).musicAction(.inline)
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("globalShortcutMessage") }
                ShortcutRecorder(active: recording != nil) { chord in
                    guard let action = recording else { return }
                    if let refusal = service.assign(chord, to: action) { message = refusal.message } else { message = nil }
                    recording = nil; revision += 1
                } cancelled: { recording = nil }
                .frame(width: 0, height: 0)
                #if DEBUG
                Text(service.usesInProcessFake ? "in-process fake" : "SYSTEM HOT KEYS").font(.caption2).accessibilityIdentifier("hotKeyService")
                #endif
            }
        }.id(revision)
    }
}

/// Captures one key chord while `active`. It lives in the Settings window only, takes the key as a Command chord too (so a menu never fires
/// while a shortcut is being chosen), and Escape cancels.
struct ShortcutRecorder: NSViewRepresentable {
    let active: Bool
    let chosen: (KeyChord) -> Void
    let cancelled: () -> Void
    func makeNSView(context: Context) -> RecorderView { RecorderView() }
    func updateNSView(_ view: RecorderView, context: Context) {
        view.chosen = chosen; view.cancelled = cancelled
        view.isRecording = active
        if active, view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        if !active, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }
    final class RecorderView: NSView {
        var chosen: (KeyChord) -> Void = { _ in }
        var cancelled: () -> Void = {}
        var isRecording = false
        override var acceptsFirstResponder: Bool { isRecording }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return false }
            keyDown(with: event); return true
        }
        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { cancelled(); return }   // Escape
            guard let chord = ShortcutKeyRouter.chord(for: event) else { NSSound.beep(); return }
            chosen(chord)
        }
    }
}
