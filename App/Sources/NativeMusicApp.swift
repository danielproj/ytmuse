import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
@preconcurrency import UserNotifications
import AppShell
import Foundation
import SystemIntegration
import YouTubeMusicAdapter

/// The login item for a normal launch (WIN09). This is the ONLY place in the repository that names `SMAppService`: no package target and no test
/// can reach it, so none can register, unregister or change the account holder's real login item (`LoginItemGuardTests` sweeps for that). It is
/// used only when the Settings toggle is pressed; launching the app never registers anything.
struct SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
    var isInProcessFake: Bool { false }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// The global hot keys for a normal launch (W26, MAC09). This file and its Carbon calls are the ONLY place the repository names the system's hot-key
/// registration: no package target and no test can reach it (`SystemMediaGuardTests` and `check-system-media.py` sweep for that), and the composition
/// root never builds it for an isolated launch. It uses the public `RegisterEventHotKey`, which delivers only the chords that were registered. It is not
/// an event tap and not a global monitor, and nothing is registered until the person has recorded a shortcut in Settings.
@MainActor final class SystemHotKeys: HotKeyRegistering {
    var isInProcessFake: Bool { false }
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x59544D55   // 'YTMU'
    /// The key codes come from `HotKeyCodes`, the table the conflict policy also reads: a key the policy accepts is a key this can register.
    private static func carbon(_ modifiers: KeyModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
    private func installHandlerOnce() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else { return OSStatus(eventNotHandledErr) }
            let registrar = Unmanaged<SystemHotKeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { registrar.actions[identifier.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        return status == noErr
    }
    func register(_ chord: KeyChord, handler action: @escaping @MainActor () -> Void) -> HotKeyHandle? {
        guard let code = HotKeyCodes.code(for: chord.key), installHandlerOnce() else { return nil }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: nextID)
        guard RegisterEventHotKey(code, Self.carbon(chord.modifiers), identifier, GetApplicationEventTarget(), 0, &reference) == noErr, let reference else { return nil }
        nextID += 1
        actions[identifier.id] = action
        return Handle(owner: self, id: identifier.id, reference: reference)
    }
    /// The system's own enabled shortcuts (Spotlight, Mission Control, screenshots…), read for the conflict check. Read-only.
    func systemReservedChords() -> Set<KeyChord> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
                var result: Set<KeyChord> = []
        for entry in list {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true, let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let key = HotKeyCodes.key(forCode: code), let bits = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { continue }
            var modifiers: KeyModifiers = []
            if bits & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
            if bits & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
            if bits & UInt32(optionKey) != 0 { modifiers.insert(.option) }
            if bits & UInt32(controlKey) != 0 { modifiers.insert(.control) }
            result.insert(KeyChord(key, modifiers))
        }
        return result
    }
    private final class Handle: HotKeyHandle {
        private weak var owner: SystemHotKeys?
        private let id: UInt32
        private var reference: EventHotKeyRef?
        init(owner: SystemHotKeys, id: UInt32, reference: EventHotKeyRef) { self.owner = owner; self.id = id; self.reference = reference }
        func unregister() {
            guard let reference else { return }
            UnregisterEventHotKey(reference); self.reference = nil
            MainActor.assumeIsolated { owner?.actions[id] = nil }
        }
    }
}

/// The notification center for a normal launch (W26, MAC08). The ONLY place the repository names it, so no test can request real authorization (that would
/// put a permission prompt in front of the account holder). The center is not touched until the person turns "Notify when the song changes" on.
@MainActor final class SystemNotifications: NotificationServing {
    var isInProcessFake: Bool { false }
    private func map(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }
    func authorization() async -> NotificationAuthorization { map(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus) }
    func requestAuthorization() async -> NotificationAuthorization {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
        return granted ? .authorized : .denied
    }
    func post(_ notification: SongNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let subtitle = notification.subtitle { content.body = subtitle }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: SongNotification.identifier, content: content, trigger: nil))
    }
    func post(_ notification: StatusNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let body = notification.body { content.body = body }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    }
}

@main
struct NativeMusicApp: App {
    @NSApplicationDelegateAdaptor(PlaybackApplicationDelegate.self) private var playbackDelegate
    /// The app target is the composition root for the signed Music client so UI
    /// modules never import the service adapter.
    private let scenes: NativeMusicScenes = {
        LaunchStorageDecision.establish()   // first: nothing may open before storage is decided
        UILanguageOverride.applyFromStore()   // W28: before any string is looked up, so String(localized:) and the menu bar follow an explicit interface language
        // An automated (isolated) launch never gets the real login item: it toggles a fake that lives and dies with the process.
        let loginItem = LoginItemSelection.choose(system: { SystemLoginItemService() })
        // The hot keys and the notification center are offered here and refused inside the shell for an isolated launch (`IntegrationFacilities.choose`).
        // W25: the same for the App Group container, WidgetCenter and the Spotlight index: they are closures, asked for only by a normal launch, and an isolated launch
        // (and every test) is given a temporary directory, a recording reloader and an in-memory index by the shell whatever is offered.
        let system = SystemServices(hotKeys: { SystemHotKeys() }, notifications: { SystemNotifications() }, groupDirectory: { SystemWidgetContainer.directory() },
                                    widgetReloader: { SystemWidgetReloader() }, searchIndex: { SystemSearchableIndex() })
        // W28 (L10N03): the content language and region chosen in Settings are asked for on every request (the hl and gl of the request context).
        let contentLocale: ContentLocaleProvider = { let hint = ContentLocaleSetting.current(); return ContentLocaleHint(hl: hint.hl, gl: hint.gl) }
        guard let publicClient = try? PublicMusicClient(locale: contentLocale) else { return NativeMusicScenes(loginItem: loginItem, system: system) }
        return NativeMusicScenes(musicReader: SignedMusicClient(publicClient: publicClient, locale: contentLocale), listening: YouTubeMusicListening.policy, loginItem: loginItem, system: system)
    }()
    var body: some Scene { scenes }
}
