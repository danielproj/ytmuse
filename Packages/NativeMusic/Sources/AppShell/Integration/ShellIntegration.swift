import AppKit
import Domain
import Features
import Foundation
import Observation
import Playback
import Queue
import SwiftUI
import SystemIntegration

// W26 (MAC07-MAC12, ARCH03). The shell's side of links, shortcuts, sharing, notifications and scripting.
//
// Everything here calls the commands the menus and media keys already call. Nothing in this file touches an account, a token, a cookie or a
// request; a link only navigates; sharing hands out `CanonicalLink`s on an explicit action; permissions are asked for only by the Settings toggle
// or the action that needs them.

/// The system-facing facilities the shell uses. The defaults are the in-process stand-ins; the app's composition supplies the real hot-key
/// registrar and notification center for a normal launch only, and `choose` refuses them under isolation whatever it is offered.
struct IntegrationFacilities {
    var hotKeys: any HotKeyRegistering
    var notifications: any NotificationServing
    var sharing: any SharingPresenting
    var pasteboard: NSPasteboard
    @MainActor init(hotKeys: (any HotKeyRegistering)? = nil, notifications: (any NotificationServing)? = nil, sharing: (any SharingPresenting)? = nil, pasteboard: NSPasteboard? = nil) {
        self.hotKeys = hotKeys ?? RecordingHotKeys()
        self.notifications = notifications ?? RecordingNotifications()
        self.sharing = sharing ?? RecordingSharing()
        self.pasteboard = pasteboard ?? NSPasteboard(name: NSPasteboard.Name("local.native-music.integration-" + UUID().uuidString))
    }
    /// A normal launch gets what the composition offers; an isolated launch (every automated one, every test process) never does.
    @MainActor static func choose(isolated: Bool, hotKeys: (@MainActor () -> any HotKeyRegistering)?, notifications: (@MainActor () -> any NotificationServing)?) -> IntegrationFacilities {
        if isolated { return IntegrationFacilities() }
        return IntegrationFacilities(hotKeys: hotKeys?(), notifications: notifications?(), sharing: SystemSharing(), pasteboard: .general)
    }
}
/// What the app's composition root may offer the shell. The real objects live in the app target (`NativeMusicApp.swift`), the only file that names
/// the system's hot-key and notification APIs.
///
/// W25 adds the widget's App Group directory and timeline reload and the Spotlight index. They are closures like the rest, so an isolated launch never even asks for
/// them (asking for the App Group container can create it): `LocalAccountBootstrap.resolveSystemSurfaces` replaces all three with a temporary directory, a
/// recording reloader and an in-memory index under isolation, whatever is offered here.
public struct SystemServices: Sendable {
    public var hotKeys: (@MainActor () -> any HotKeyRegistering)?
    public var notifications: (@MainActor () -> any NotificationServing)?
    public var groupDirectory: (@Sendable () -> URL?)?
    public var widgetReloader: (@MainActor () -> any WidgetTimelineReloading)?
    public var searchIndex: (@Sendable () -> any SearchableIndexBackend)?
    public init(hotKeys: (@MainActor () -> any HotKeyRegistering)? = nil, notifications: (@MainActor () -> any NotificationServing)? = nil,
                groupDirectory: (@Sendable () -> URL?)? = nil, widgetReloader: (@MainActor () -> any WidgetTimelineReloading)? = nil, searchIndex: (@Sendable () -> any SearchableIndexBackend)? = nil) {
        self.hotKeys = hotKeys; self.notifications = notifications; self.groupDirectory = groupDirectory; self.widgetReloader = widgetReloader; self.searchIndex = searchIndex
    }
    public static let none = SystemServices()
}

/// A request from outside a window (Services, Handoff, AppleScript, Reveal) to show a destination.
struct LinkRequest: Equatable { let id: Int; let destination: LinkDestination }

enum LinkNavigation {
    /// Navigation only: a page opens, nothing plays, nothing is changed.
    @MainActor @discardableResult static func apply(_ destination: LinkDestination, to navigation: BrowserNavigation) -> Bool {
        switch destination {
        case .item(let item):
            guard let kind = NativeItemKind(rawValue: item.kind.rawValue), let route = try? NativeItemRoute(kind: kind, identifier: item.identifier) else { return false }
            navigation.open(.library, item: route); return true
        case .screen(let screen):
            guard let destination = BrowserDestination(rawValue: screen.rawValue) else { return false }
            navigation.open(destination); return true
        }
    }
}

// MARK: Sharing

/// Presents the share sheet for one link and says whether it did (false: there was nowhere to anchor it).
@MainActor protocol SharingPresenting: AnyObject { @discardableResult func present(_ url: URL) -> Bool }
/// The system share sheet, anchored on the key window. Presented only from an explicit person action (a menu command, Share… on an item or page, or
/// the player's ⋯ menu); the link is chosen at that moment and a sheet that is dismissed is simply gone.
@MainActor final class SystemSharing: SharingPresenting {
    @discardableResult func present(_ url: URL) -> Bool {
        guard let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else { return false }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1), of: view, preferredEdge: .minY)
        return true
    }
}
@MainActor final class RecordingSharing: SharingPresenting {
    private(set) var presented: [URL] = []
    @discardableResult func present(_ url: URL) -> Bool { presented.append(url); return true }
}

/// Which song the player is playing, as a link item: the YouTube Music song of the player's own reading (never an advertisement, a closed or idle
/// player, or an identifier without a video id's shape). Nothing for owned or local media, which has no player reading. The playlist, radio or queue
/// the song plays from is not part of it.
enum CurrentSongShare {
    @MainActor static func item(for player: WebMusicPlayer?) -> LinkItem? {
        guard let player, WebMusicQueueSummary.isActive(player), !player.snapshot.isAd, let id = player.snapshot.videoID else { return nil }
        return LinkItem(kind: .song, identifier: id)
    }
}
private struct ShareCurrentSongKey: EnvironmentKey { static let defaultValue: (@MainActor () -> Void)? = nil }
extension EnvironmentValues {
    /// Shares the song that is playing now (the shell's `shareCurrentSong`, whose facilities are the recording stand-in under isolation); nil where
    /// no shell provides it, which hides the player's Share button.
    var shareCurrentSong: (@MainActor () -> Void)? {
        get { self[ShareCurrentSongKey.self] }
        set { self[ShareCurrentSongKey.self] = newValue }
    }
}

// MARK: Notifications (opt-in)

/// "Notify when the song changes". Off by default; turning it on is the only thing that asks the system for permission.
@MainActor @Observable final class NotificationSettingsModel {
    static let key = "notifications.songChange"
    /// W27: the second opt-in, for download and error messages (also off by default; in-app messages always show).
    static let statusKey = "notifications.downloadsAndErrors"
    private(set) var isOn: Bool
    private(set) var statusOn: Bool
    private(set) var status: NotificationAuthorization = .notDetermined
    private(set) var note: String?
    @ObservationIgnored private let service: any NotificationServing
    @ObservationIgnored private let preferences: UserDefaults
    init(service: any NotificationServing, preferences: UserDefaults) {
        self.service = service; self.preferences = preferences
        isOn = preferences.bool(forKey: Self.key)
        statusOn = preferences.bool(forKey: Self.statusKey)
    }
    /// Turning the download and error messages on asks macOS for permission (the only thing that does); turning them off asks for nothing.
    func setStatusEnabled(_ on: Bool) async {
        note = nil
        guard on else { preferences.set(false, forKey: Self.statusKey); statusOn = false; return }
        var state = await service.authorization()
        if state == .notDetermined { state = await service.requestAuthorization() }
        status = state
        if state == .authorized { preferences.set(true, forKey: Self.statusKey); statusOn = true }
        else {
            preferences.set(false, forKey: Self.statusKey); statusOn = false
            note = String(localized: "Notifications are turned off for YTMuse. Turn them on in System Settings > Notifications, then try again.")
        }
    }
    /// A download finished or failed, or the sign-in ended. Posts only when this opt-in is on and the system still allows it; never asks for permission.
    func statusEvent(_ notification: StatusNotification) async {
        guard statusOn else { return }
        let state = await service.authorization()
        status = state
        guard state == .authorized else { return }
        await service.post(notification)
    }
    var usesInProcessFake: Bool { service.isInProcessFake }
    func setEnabled(_ on: Bool) async {
        note = nil
        guard on else { preferences.set(false, forKey: Self.key); isOn = false; return }
        var state = await service.authorization()
        if state == .notDetermined { state = await service.requestAuthorization() }
        status = state
        if state == .authorized { preferences.set(true, forKey: Self.key); isOn = true }
        else {
            preferences.set(false, forKey: Self.key); isOn = false
            note = String(localized: "Notifications are turned off for YTMuse. Turn them on in System Settings > Notifications, then try again.")
        }
    }
    /// A song started. Posts only when the feature is on and the system still allows it; never asks for permission.
    func songChanged(title: String?, artist: String?, isAdvertisement: Bool) async {
        guard isOn, let notification = SongNotification.make(title: title, artist: artist, isAdvertisement: isAdvertisement) else { return }
        let state = await service.authorization()
        status = state
        guard state == .authorized else { return }
        await service.post(notification)
    }
}

// MARK: The shell

extension ShellCoordinator {
    func startIntegration() {
        let router = ShortcutKeyRouter(performer: self, role: { [weak self] in self?.windows.role(of: $0) })
        router.install(); shortcutRouter = router
        let shortcuts = GlobalShortcutService(store: GlobalShortcutStore(defaults: preferences), registrar: facilities.hotKeys, perform: { [weak self] in self?.performGlobal($0) })
        shortcuts.reapply(); globalShortcuts = shortcuts
        let model = NotificationSettingsModel(service: facilities.notifications, preferences: preferences)
        notifications = model
        playback.songChanged = { title, artist, isAd in Task { await model.songChanged(title: title, artist: artist, isAdvertisement: isAd) } }
        ScriptingHost.target = self
        let provider = LinkServicesProvider(shell: self)
        servicesProvider = provider
        NSApp.servicesProvider = provider
    }
    func stopIntegration() {
        shortcutRouter?.remove(); shortcutRouter = nil
        globalShortcuts?.stop(); globalShortcuts = nil
        playback.songChanged = nil
        if ScriptingHost.target === self { ScriptingHost.target = nil }
        if (NSApp.servicesProvider as AnyObject?) === servicesProvider { NSApp.servicesProvider = nil }
        servicesProvider = nil
    }
    private func performGlobal(_ action: GlobalShortcutAction) {
        switch action {
        case .playPause: togglePlayPause()
        case .next: next()
        case .previous: previous()
        case .showHide: toggleVisibility()
        }
    }
    /// Show or hide: hides the app when it is in front with a window up, otherwise brings the main window forward.
    func toggleVisibility() {
        if NSApp.isActive, windows.windows(role: .browser).contains(where: { $0.isVisible && !$0.isMiniaturized }) { NSApp.hide(nil) }
        else { NSApp.unhide(nil); showMainWindow() }
    }

    // MARK: Links

    /// Shows a destination in a browser window (opening one if none is up). Navigation only.
    func requestOpen(_ destination: LinkDestination) {
        let hadWindow = windows.windows(role: .browser).contains { $0.isVisible || $0.isMiniaturized }
        showMainWindow()
        // After the window exists and has been shown, so a window created by this very call sees the request too.
        DispatchQueue.main.asyncAfter(deadline: .now() + (hadWindow ? 0.05 : 0.6)) { [self] in linkRequest = LinkRequest(id: (linkRequest?.id ?? 0) + 1, destination: destination) }
    }
    /// A link as text (a Service, a paste): the strict policy first, and the refusal is one sentence that names nothing.
    @discardableResult func openLink(text: String) -> LinkRefusal? {
        switch LinkPolicy.parse(text: text) {
        case .success(let destination): requestOpen(destination); return nil
        case .failure(let refusal): return refusal
        }
    }
    /// File > Open Link from Clipboard: the person's own command. Reads the clipboard only now, and says so in one sentence when it is not a link.
    func openLinkFromClipboard() {
        guard openLink(text: facilities.pasteboard.string(forType: .string) ?? "") != nil else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "This link cannot be opened")
        alert.informativeText = LinkRefusal.message
        alert.runModal()
    }
    /// Reveals the item that is playing: its page when it is a YouTube Music song, the queue otherwise.
    func revealCurrentItem() {
        if let link = currentSongItem { requestOpen(.item(link)) } else { requestOpen(.screen(.queue)) }
    }

    // MARK: Sharing

    /// The song that is playing as a link item: a YouTube Music song that is not an advertisement. Nothing for owned or local media.
    var currentSongItem: LinkItem? { CurrentSongShare.item(for: playback.music) }
    var currentShareLink: URL? { currentSongItem.map(CanonicalLink.url(for:)) }
    func shareCurrentSong() { if let url = currentShareLink { facilities.sharing.present(url) } }
    func copyCurrentSongLink() {
        guard let url = currentShareLink else { return }
        facilities.pasteboard.clearContents()
        facilities.pasteboard.setString(url.absoluteString, forType: .string)
    }
}

extension ShellCoordinator: ShortcutPerforming {
    func perform(_ action: ShortcutAction) {
        switch action {
        case .playPause: togglePlayPause()
        case .next: next()
        case .previous: previous()
        case .seekForward: _ = playback.shellSeek(by: ShortcutTable.seekStep)
        case .seekBack: _ = playback.shellSeek(by: -ShortcutTable.seekStep)
        case .revealCurrentItem: revealCurrentItem()
        case .showQueue: showQueue()
        case .miniPlayer: showMiniPlayer()
        case .settings: openSettings()
        case .quit: quit()
        // Window-level commands: Find and the palette act on the focused window, Minimize and Close are the system's own.
        case .focusSearch, .commandPalette, .minimize, .closeWindow: break
        }
    }
}

/// The Services-menu entry "Open in YTMuse": the selected text or URL goes through the same strict link policy as everything else.
@MainActor final class LinkServicesProvider: NSObject {
    private weak var shell: ShellCoordinator?
    init(shell: ShellCoordinator) { self.shell = shell }
    /// Named by the `NSMessage` of the Info.plist's Services entry.
    @objc func openLink(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL) ?? ""
        guard let refusal = shell?.openLink(text: text) else { return }
        _ = refusal
        error.pointee = LinkRefusal.message as NSString
    }
}

// MARK: Scripting (the target the Cocoa commands reach)

extension ShellCoordinator: ScriptingTarget {
    var playerState: ScriptPlayerState {
        let state = transport
        if !state.hasItem { return .stopped }
        if state.isAd { return .advertisement }
        return state.isPlaying ? .playing : .paused
    }
    var currentTrack: ScriptTrack? {
        let state = transport
        guard state.hasItem else { return nil }
        if state.isAd { return ScriptTrack(name: String(localized: "Advertisement")) }
        let reading = playback.shellPosition
        return ScriptTrack(name: state.title, artist: state.artist, duration: state.isLive ? nil : reading?.duration, position: state.isLive ? nil : reading?.position,
                           url: currentShareLink?.absoluteString)
    }
    var volumePercent: Int { Int((transport.volume * 100).rounded()) }
    func transport(_ request: ScriptTransport) -> ScriptRefusal? {
        let command: RemoteTransportCommand
        switch request {
        case .play: command = .play
        case .pause: command = .pause
        case .playPause: command = .toggle
        case .next: command = .next
        case .previous: command = .previous
        case .seekTo(let seconds): command = .seek(seconds)
        case .seekBy(let delta):
            guard let target = playback.shellSeekTarget(by: delta) else { return .nothingPlaying }
            command = .seek(target)
        }
        switch playback.remote(command) {
        case .success: return nil
        case .noActionableItem: return .nothingPlaying
        case .refused: return .notAllowedNow(playback.remoteReason(command.kind) ?? String(localized: "That command is not available right now."))
        }
    }
    func setVolume(percent: Int) -> ScriptRefusal? {
        guard playback.shellState.hasItem else { return .nothingPlaying }
        // TH5: while a cast receiver is the slider (TH4) and it cannot take a level now (fixed, unable to set the stream volume, or not yet reported), nothing is
        // sent, so the script is told so with the sentence the slider shows (already localized); success would be a fake one.
        let slider = playback.volumeSlider
        if slider.isReceiver, !slider.isEnabled { return .notAllowedNow(slider.disabledReason ?? String(localized: "That command is not available right now.")) }
        playback.shellSetVolume(Double(percent) / 100)
        return nil
    }
    func queueInsert(_ item: LinkItem, placement: QueuePlacement) async -> ScriptRefusal? {
        if let player = playback.music, WebMusicQueueSummary.isActive(player) {
            return .queueNotEditable(String(localized: "YouTube Music manages the upcoming items while it plays, so this app cannot add to them."))
        }
        guard let session = playback.session else { return .nothingPlaying }
        do {
            let request = try ScriptQueueRequest(item, placement: placement)
            try await session.sendQueue(request.command, origin: request.origin)
            return nil
        } catch { return .queueNotEditable(String(localized: "The queue could not take that song.")) }
    }
    func open(_ destination: LinkDestination) -> ScriptRefusal? { requestOpen(destination); return nil }
}

/// What a script's queue insertion sends to the shared queue command, and from where. The origin is part of the request so a test can pin it: ARCH03 says an
/// AppleScript action is the same use case as the UI's, identified as a script.
struct ScriptQueueRequest {
    let command: QueueCommand
    let origin: CommandOrigin
    init(_ item: LinkItem, placement: QueuePlacement) throws {
        let media = try ServiceID(item.identifier)
        command = placement == .next ? .playNext([media]) : .add([media])
        origin = .appleScript
    }
}
/// A link dropped on a window: the same strict policy as every other surface; nil when there was nothing to read.
enum LinkDrop {
    static func destination(from text: String?) -> Result<LinkDestination, LinkRefusal>? { text.map { LinkPolicy.parse(text: $0) } }
}

extension PlaybackModel {
    /// The playing position and length in seconds (length nil when unknown or live), whichever engine plays.
    var shellPosition: (position: Double, duration: Double?)? {
        if let player = music, WebMusicQueueSummary.isActive(player) {
            let duration = player.snapshot.duration
            return (player.timeline.position, duration > 0 && !player.snapshot.isLive ? duration : nil)
        }
        if session != nil, let snapshot = timeline.snapshot, snapshot.queue.current != nil {
            let length = snapshot.media?.duration
            return (snapshot.playback.position, length.flatMap { $0 > 0 ? $0 : nil })
        }
        return nil
    }
    /// Where a relative seek would land: clamped to the item, nil when nothing is loaded.
    func shellSeekTarget(by delta: Double) -> Double? {
        guard delta.isFinite, let reading = shellPosition else { return nil }
        let wanted = max(0, reading.position + delta)
        return reading.duration.map { min(wanted, max(0, $0 - 0.5)) } ?? wanted
    }
    /// The seek shortcuts and the script's relative seek: the media key's own `seek` admission (an advertisement refuses it).
    @discardableResult func shellSeek(by delta: Double) -> RemoteCommandOutcome {
        guard let target = shellSeekTarget(by: delta) else { return .noActionableItem }
        return remote(.seek(target))
    }
}
