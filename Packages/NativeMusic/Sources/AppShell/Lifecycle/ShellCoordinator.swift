import AppKit
import Features
import Foundation
import Observation
import Playback
import Updates
import SwiftUI
import SystemIntegration

/// W21. The one owner of the app's shell: the permanent status item and popover, the mini-player, full-screen Now Playing, the window census
/// and activation policy, the power lifecycle and the login item. It is created once with the one playback owner (so Command-N windows, the
/// status item and the mini-player all share exactly one account, one player and one Now Playing owner, WIN04) and started once at launch.
/// It is also the production `ShellCommanding`: every shell surface calls it, and it calls the shared playback commands (ARCH03).
@MainActor @Observable final class ShellCoordinator: ShellCommanding {
    let playback: PlaybackModel
    @ObservationIgnored let windows: ShellWindowRegistry
    @ObservationIgnored let loginItem: LoginItemModel
    @ObservationIgnored let preferences: UserDefaults
    @ObservationIgnored private let application: any ApplicationActivating
    @ObservationIgnored private let installsStatusItem: Bool
    @ObservationIgnored private(set) var statusItem: StatusItemController?
    @ObservationIgnored private(set) var miniPlayer: MiniPlayerController?
    @ObservationIgnored private(set) var nowPlayingFullScreen: NowPlayingFullScreen?
    @ObservationIgnored private(set) var power: PowerLifecycleCoordinator?
    /// W26: the system-facing facilities (global shortcuts, notifications, sharing, the clipboard), the key router and the link request browser windows watch.
    @ObservationIgnored let facilities: IntegrationFacilities
    @ObservationIgnored var shortcutRouter: ShortcutKeyRouter?
    @ObservationIgnored var globalShortcuts: GlobalShortcutService?
    @ObservationIgnored var notifications: NotificationSettingsModel?
    /// Raised by Services, Handoff and AppleScript; a browser window navigates when it sees a newer one.
    var linkRequest: LinkRequest?
    @ObservationIgnored var servicesProvider: NSObject?
    /// W30: the updater (BUILD06). Nil until the composition installs it; a build without a feed holds an unavailable one.
    var updates: UpdateController?
    @ObservationIgnored private var powerObserver: SystemPowerObserver?
    @ObservationIgnored private(set) var started = false
    /// Raised by the queue buttons of the shell surfaces; a browser window shows its queue panel when it sees a newer value.
    private(set) var queueRequest = 0
    /// Raised by "Choose Output…" (menu bar, command palette); the output button of a visible window opens its popover.
    private(set) var outputPickerRequest = 0
    func showOutputPicker() { showMainWindow(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in outputPickerRequest += 1 } }
    /// W24: searches App Intents ask for wait here until a visible window performs them (see `SearchRequestInbox`).
    let searchInbox = SearchRequestInbox()
    /// W25: the Spotlight opt-in (off by default); the composition wires it to the indexer.
    let spotlightSettings: SpotlightSettings
    // Seams the composition fills in (SwiftUI's window actions exist only inside the scene graph; the like and panel content come from the app's surfaces).
    @ObservationIgnored var openMainWindowAction: (@MainActor () -> Void)?
    @ObservationIgnored var openSettingsAction: (@MainActor () -> Void)?
    @ObservationIgnored var likeControlProvider: (@MainActor (String) -> LibraryControl?)?
    /// W23: every ledger control the song published (like, dislike, save), for the remote commands. Falls back to the like provider alone.
    @ObservationIgnored var libraryControlsProvider: (@MainActor (String) -> [LibraryControl])?
    @ObservationIgnored var likePress: (@MainActor (LibraryControl) async -> Void)?
    /// Why the playing song has no rating control yet (its rating is being read, was not offered, needs sign-in, or could not be read). Nil: no reason known.
    @ObservationIgnored var ratingGapProvider: (@MainActor (String) -> LikeUnavailable?)?
    /// Whether a Dislike press took: the ledger shows the song as disliked and has not rejected the change. Only then does the song skip.
    @ObservationIgnored var ratingHeld: (@MainActor (LibraryControl) -> Bool)?
    @ObservationIgnored var queuePanelProvider: (@MainActor () -> AnyView)?
    @ObservationIgnored var lyricsPanelProvider: (@MainActor () -> AnyView)?
    @ObservationIgnored var artworkContextProvider: (@MainActor () -> ShellArtworkContext)?
    @ObservationIgnored var quitAction: @MainActor () -> Void = { PlaybackApplicationDelegate.requestQuit() }

    init(playback: PlaybackModel, loginItem: any LoginItemService, application: any ApplicationActivating = SystemApplication(),
         preferences: UserDefaults = AppPreferences.store, installsStatusItem: Bool = true, windows: ShellWindowRegistry? = nil,
         facilities: IntegrationFacilities = IntegrationFacilities()) {
        self.playback = playback
        self.facilities = facilities
        self.application = application
        self.preferences = preferences
        self.spotlightSettings = SpotlightSettings(defaults: preferences)
        self.installsStatusItem = installsStatusItem
        self.windows = windows ?? ShellWindowRegistry(application: application)
        self.loginItem = LoginItemModel(service: loginItem)
        // The remote commands (media keys, Control Center) reach the library ledger through the same like path the mini-player uses.
        playback.remoteLibrary = self
        // A search an intent asked for belongs to the account that was live when it was asked: an account barrier (switch, sign-out, removal, quit) withdraws it, so
        // the person's words are never run, and never recorded to the recents, under the account that comes next. A waiting intent is told it was not performed.
        let inbox = searchInbox
        playback.authority.onBarrier { await MainActor.run { inbox.clear() } }
    }

    var transport: ShellTransportState { playback.shellState }

    /// Once, when the application has finished launching: the status item, the power observers, and (for a login launch) the menu-bar-only presence.
    func start() {
        guard !started else { return }
        started = true
        if installsStatusItem {
            let controller = StatusItemController(shell: self, preferences: preferences)
            controller.install(); statusItem = controller
        }
        // The key router, global shortcuts, Services and the scripting target belong to the real app shell; the unit tests that start a shell without a status item do not take them.
        if installsStatusItem { startIntegration() }
        let coordinator = PowerLifecycleCoordinator(transport: playback, resumePreference: { [preferences] in ShellPreferences.resumeAfterWake(preferences) })
        power = coordinator
        powerObserver = SystemPowerObserver { event in Task { @MainActor in await coordinator.handle(event) } }
        if LaunchContext.kind == .login {
            // A login launch is menu-bar only: no window and no audio. The first window the app creates is hidden, not destroyed, so Show YTMuse can bring it.
            application.setPresence(.accessory)
        }
    }
    /// Quit: close the shell's own windows, remove the status item and stop listening, before the checkpointed termination replies.
    func stop() {
        // Quit lets go of the media keys at once (whether or not the shell ever started), so another media application can take them.
        playback.endNowPlaying()
        guard started else { return }
        started = false
        power?.stop(); powerObserver?.stop(); powerObserver = nil
        miniPlayer?.close(); nowPlayingFullScreen?.close()
        statusItem?.remove(); statusItem = nil
        stopIntegration()
    }

    // MARK: ShellCommanding (every surface goes through here)

    func togglePlayPause() { playback.shellTogglePlayPause() }
    func next() { playback.shellNext() }
    func previous() { playback.shellPrevious() }
    func setVolume(_ level: Double) { playback.shellSetVolume(level) }
    func quit() { quitAction() }

    func showMainWindow() {
        // The regular policy first, then a window across Spaces and Mission Control; a window that exists (even one hidden by a login launch) is reused.
        windows.restoreRegularPresence()
        let browsers = windows.windows(role: .browser)
        if let existing = browsers.first(where: { $0.isVisible || $0.isMiniaturized }) ?? browsers.first {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.alphaValue = 1   // a login launch hid this window without destroying it
            existing.makeKeyAndOrderFront(nil)
        } else {
            openNewBrowserWindow()
        }
    }
    private func openNewBrowserWindow() {
        if let openMainWindowAction { openMainWindowAction() }
        else {
            // No scene action yet: a reopen event makes SwiftUI create the default window.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    /// A new browser window (Command-N): same account, same player, same Now Playing owner; only its navigation is its own.
    func openAnotherWindow() { windows.restoreRegularPresence(); openNewBrowserWindow() }
    func showMiniPlayer() {
        if miniPlayer == nil {
            let controller = MiniPlayerController(preferences: preferences) { [unowned self] controller in AnyView(MiniPlayerView(shell: self, controller: controller)) }
            controller.onVisibilityChange = { [weak self] window in
                if let window { self?.windows.register(window, role: .miniPlayer) }
            }
            miniPlayer = controller
        }
        miniPlayer?.show()
    }
    func showNowPlayingFullScreen() {
        let screen = nowPlayingFullScreen ?? NowPlayingFullScreen()
        nowPlayingFullScreen = screen
        screen.onWindow = { [weak self] window in if let window { self?.windows.register(window, role: .nowPlaying) } }
        windows.restoreRegularPresence()
        screen.show(shell: self)
    }
    func showQueue() {
        let hadWindow = windows.windows(role: .browser).contains { $0.isVisible || $0.isMiniaturized }
        showMainWindow()
        // After the window exists and has been shown, so a window created by this very call sees the request too.
        DispatchQueue.main.asyncAfter(deadline: .now() + (hadWindow ? 0.05 : 0.6)) { [self] in queueRequest += 1 }
    }
    /// W24: shows (or opens) the main window and has a window run `text` in its Search, as if it had been typed. True only when a window did; a
    /// request no window took within `timeout` is withdrawn, so a late window never runs a search the person was told did not happen.
    func performSearch(_ text: String, timeout: Duration = .seconds(8)) async -> Bool {
        await searchInbox.request(text, show: { showMainWindow() }, timeout: timeout)
    }
    func openSettings() {
        windows.restoreRegularPresence()
        if let openSettingsAction { openSettingsAction() }
        else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }
    /// Keeps SwiftUI's window actions for the moments no view exists (the status item, a Dock click, a login launch).
    func captureWindowActions(openMain: @escaping @MainActor () -> Void, openSettings: @escaping @MainActor () -> Void) {
        openMainWindowAction = openMain; openSettingsAction = openSettings
    }
    /// The app's artwork pipeline, request and authority (the same ones the browser window's player uses); empty before the composition supplies them.
    func artworkContext() -> ShellArtworkContext { artworkContextProvider?() ?? ShellArtworkContext() }
    func queuePanel() -> AnyView { queuePanelProvider?() ?? AnyView(EmptyView()) }
    func lyricsPanel() -> AnyView { lyricsPanelProvider?() ?? AnyView(EmptyView()) }

    // MARK: Like and Dislike (the current YouTube Music song, through the library ledger)

    /// Whether the current song can be liked (or disliked) from a shell surface, and when it cannot, the actual cause.
    enum LikeAvailability: Equatable {
        case available(LibraryControl)
        case unavailable(LikeUnavailable)
        var control: LibraryControl? { if case .available(let control) = self { control } else { nil } }
        var reason: String? { if case .unavailable(let why) = self { why.message } else { nil } }
    }
    enum LikeUnavailable: Equatable {
        case nothingPlaying, advertisement, ownedMedia, pageNotRead
        /// The playing song's own rating is being read, the service published none, the account is signed out, the read failed, or the song
        /// offers Like but not Dislike.
        case reading, notOffered, signedOut, readFailed, dislikeNotOffered
        var message: String {
            switch self {
            case .nothingPlaying: String(localized: "Nothing is playing, so there is nothing to like.")
            case .advertisement: String(localized: "An advertisement is playing. Like returns with the next song.")
            case .ownedMedia: String(localized: "This is your own audio or a local file, not a YouTube Music song, so it has no like.")
            case .pageNotRead: String(localized: "Liking needs the song's page: open the song once and the control appears here.")
            case .reading: String(localized: "Reading this song's rating from YouTube Music…")
            case .notOffered: String(localized: "YouTube Music doesn't offer a rating for this song.")
            case .signedOut: String(localized: "Sign in to YouTube Music to like or dislike songs.")
            case .readFailed: String(localized: "This song's rating couldn't be read from YouTube Music. It's read again the next time the song plays.")
            case .dislikeNotOffered: RemoteCommandReason.noDislike
            }
        }
    }
    func likeAvailability() -> LikeAvailability { ratingAvailability(.like) }
    /// Like (`.like`) or Dislike (`.dislike`) for the playing song, or the actual reason there is none.
    func ratingAvailability(_ kind: LibraryControl.Kind) -> LikeAvailability {
        if let player = playback.music, WebMusicQueueSummary.isActive(player) {
            guard !player.snapshot.isAd else { return .unavailable(.advertisement) }
            guard let id = player.snapshot.videoID else { return .unavailable(.pageNotRead) }
            let control = kind == .like ? likeControlProvider?(id) : libraryControlsProvider?(id).first { $0.kind == kind }
            if let control { return .available(control) }
            if let gap = ratingGapProvider?(id) { return .unavailable(gap) }
            if kind == .dislike, likeControlProvider?(id) != nil { return .unavailable(.dislikeNotOffered) }
            return .unavailable(.pageNotRead)
        }
        return .unavailable(playback.shellState.source == .owned ? .ownedMedia : .nothingPlaying)
    }
    func likeControl() -> LibraryControl? { likeAvailability().control }
    func pressLike(_ control: LibraryControl) async {
        let playing = playback.music?.snapshot.videoID
        await likePress?(control)
        // Disliking the song that is playing moves on to the next one, as YouTube Music does; only once the ledger holds the dislike, and only
        // while that same song is still playing and may be skipped.
        if Self.dislikeSkips(control, playing: playing), ratingHeld?(control) == true, let player = playback.music, WebMusicQueueSummary.isActive(player),
           player.snapshot.videoID == playing, !player.snapshot.isAd, player.snapshot.canSkip {
            await player.next()
        }
        playback.refreshRemoteCapabilities()   // the system's Like button follows the ledger, whichever surface pressed it
    }
    /// A press that sets Dislike (not one that removes it) on the song that is playing.
    static func dislikeSkips(_ control: LibraryControl, playing: String?) -> Bool {
        guard control.kind == .dislike, !control.isOn, let playing else { return false }
        return control.key == .rating(videoID: playing)
    }
}

// MARK: Remote commands (W23): the shell is the library side of the one command layer

extension ShellCoordinator: RemoteLibraryControlling {
    func remoteLibraryControl(_ kind: RemoteCommandKind) -> RemoteLibraryControlState {
        guard let player = playback.music, WebMusicQueueSummary.isActive(player) else {
            return .unavailable(playback.shellState.source == .owned ? RemoteCommandReason.ownedMedia : LikeUnavailable.nothingPlaying.message)
        }
        guard !player.snapshot.isAd else { return .unavailable(LikeUnavailable.advertisement.message) }
        guard let id = player.snapshot.videoID else { return .unavailable(LikeUnavailable.pageNotRead.message) }
        var controls = libraryControlsProvider?(id) ?? []
        if controls.isEmpty, let like = likeControlProvider?(id) { controls = [like] }
        let wanted: LibraryControl.Kind
        switch kind {
        case .like: wanted = .like
        case .dislike: wanted = .dislike
        case .save: wanted = .save
        default: return .unavailable(RemoteCommandReason.noLibrary)
        }
        if let control = controls.first(where: { $0.kind == wanted }) { return .available(control) }
        if controls.isEmpty { return .unavailable((ratingGapProvider?(id) ?? .pageNotRead).message) }
        return .unavailable(kind == .dislike ? RemoteCommandReason.noDislike : RemoteCommandReason.noSave)
    }
    func remoteLibraryPress(_ control: LibraryControl) async { await pressLike(control) }
}
