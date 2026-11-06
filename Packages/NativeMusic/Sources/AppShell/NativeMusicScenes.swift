import SwiftUI
import AccountSession
import Features
import Domain
import DesignSystem
import SystemIntegration
/// The storage decision is the very first thing a launch does, before any preference, database,
/// Keychain item, window state or web store can be opened (Debug: isolated unless opted in; Release: real).
public enum LaunchStorageDecision {
    /// True for every automated launch (Debug QA isolation) and every unit-test process: nothing outside the process may be touched, which is why
    /// the app's composition root never builds the system's login item then.
    public static var isIsolated: Bool { isolated(environment: nil, arguments: nil) }
    /// The pure decision: nil inputs read this process's single launch decision. Release builds are never isolated (they always use the real stores).
    static func isolated(environment: [String: String]?, arguments: [String]?) -> Bool {
        #if DEBUG
        IsolatedQAStorage.requested(environment, arguments: arguments)
        #else
        false
        #endif
    }
    public static func establish() {
        #if DEBUG
        ProcessIsolation.establish(isolated: IsolatedQAStorage.launch == .isolated)
        #else
        ProcessIsolation.establish(isolated: false)
        #endif
    }
}
public struct NativeMusicScenes: Scene {
    @State private var accounts: LocalAccountBootstrap
    @AppStorage("appearance", store: AppPreferences.store) private var storedAppearance = Appearance.system.rawValue
    public init() { self.init(loginItem: InMemoryLoginItemService(), system: .none) }
    /// `loginItem` is how Settings turns launch at login on and off. The default never leaves the process; the app's composition root passes the
    /// system's login item for a normal launch only (never under test or isolation). `system` is the same for the global hot keys and the
    /// notification center (W26).
    public init(loginItem: any LoginItemService, system: SystemServices = .none) {
        LaunchStorageDecision.establish(); Self.prepareIsolation()
        let bootstrap = LocalAccountBootstrap(loginItem: loginItem, system: system); bootstrap.installShell(); bootstrap.installIntents(); bootstrap.installSystemSurfaces()
        _accounts = State(initialValue: bootstrap)
    }
    /// Composes the in-app YouTube Music web sign-in with the supplied signed reader.
    /// `listening` is the service adapter's rule for when listening counts as a play; without it no local listening record is kept.
    public init(musicReader: any MusicSessionReading, listening: ListeningPolicy? = nil, loginItem: any LoginItemService = InMemoryLoginItemService(), system: SystemServices = .none) {
        LaunchStorageDecision.establish(); Self.prepareIsolation()
        let bootstrap = LocalAccountBootstrap(musicReader: musicReader, listeningPolicy: listening, loginItem: loginItem, system: system); bootstrap.installShell(); bootstrap.installIntents(); bootstrap.installSystemSurfaces()
        _accounts = State(initialValue: bootstrap)
    }
    /// Scenes are constructed before any window exists, so isolated QA window
    /// persistence is disabled before the first frame could be autosaved.
    private static func prepareIsolation() {
        UILanguageOverride.applyFromStore()   // F2: an explicit interface language reaches String(localized:) and the menu bar, from this launch on
        #if DEBUG
        MainActor.assumeIsolated { IsolatedWindowPersistence.installIfIsolated() }
        #endif
    }
    public var body: some Scene {
        WindowGroup("YTMuse", id: "main") {
            LocalAccountRoot(accounts: accounts).modifier(MainWindowContract())
                .shellWindow(accounts.shell, role: .browser)
                .appLocale()
                .appContentScale()
                .appPreferences()
                .updateAskOnce(accounts.shell)
                .isolatedWindowSize()
                .appStyle(translucentWindow: true)
                .preferredColorScheme(Appearance(storedValue: storedAppearance).colorScheme)
        }.defaultSize(width: 1240, height: 820)
         .commands { MainWindowCommands(shell: accounts.shell) }
        Settings {
            SettingsWindow(accounts: accounts)
                .shellWindow(accounts.shell, role: .settings)
                .appLocale()
                .appPreferences()
                .appStyle()
                .preferredColorScheme(Appearance(storedValue: storedAppearance).colorScheme)
        }
    }
}
private struct MainWindowCommands: Commands {
    let shell: ShellCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusedValue(\.shellActions) private var browser
    /// A menu item's key equivalent, read from the one shortcut table (section 13) so the menus and the key router can never disagree.
    private func chord(_ action: ShortcutAction) -> (KeyEquivalent, EventModifiers) { let chord = ShortcutTable.entry(for: action).chord; return (chord.keyEquivalent, chord.eventModifiers) }
    var body: some Commands {
        // The shell opens windows from the status item, the Dock and a login launch, where no view exists: it keeps SwiftUI's own actions.
        let _ = shell.captureWindowActions(openMain: { openWindow(id: "main") }, openSettings: { openSettings() })
        CommandGroup(after: .textEditing) {
            Button("Find…") { browser?.find() }.keyboardShortcut(chord(.focusSearch).0, modifiers: chord(.focusSearch).1).disabled(browser == nil)
            Button("Command Palette…") { browser?.palette() }.keyboardShortcut(chord(.commandPalette).0, modifiers: chord(.commandPalette).1).disabled(browser == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { shell.openAnotherWindow() }.keyboardShortcut(ShortcutTable.newWindow.keyEquivalent, modifiers: ShortcutTable.newWindow.eventModifiers)
            Button("Open") { shell.showMainWindow() }.keyboardShortcut(ShortcutTable.open.keyEquivalent, modifiers: ShortcutTable.open.eventModifiers)
            Divider()
            Button("Open Link from Clipboard") { shell.openLinkFromClipboard() }
        }
        // Playback (section 13). Space and Command-Arrow are handled by the key router first, so a text field keeps them while it edits; these items
        // show the shortcut and give the same commands to the mouse.
        CommandMenu("Playback") {
            Button(shell.transport.isPlaying ? LocalizedStringKey("Pause") : LocalizedStringKey("Play")) { shell.perform(.playPause) }.keyboardShortcut(chord(.playPause).0, modifiers: chord(.playPause).1).disabled(!shell.transport.hasItem)
            Button("Next") { shell.perform(.next) }.keyboardShortcut(chord(.next).0, modifiers: chord(.next).1).disabled(!shell.transport.skipEnabled)
            Button("Previous") { shell.perform(.previous) }.keyboardShortcut(chord(.previous).0, modifiers: chord(.previous).1).disabled(!shell.transport.skipEnabled)
            Divider()
            Button("Seek Forward") { shell.perform(.seekForward) }.keyboardShortcut(chord(.seekForward).0, modifiers: chord(.seekForward).1).disabled(!shell.transport.canSeek || shell.transport.isAd)
            Button("Seek Back") { shell.perform(.seekBack) }.keyboardShortcut(chord(.seekBack).0, modifiers: chord(.seekBack).1).disabled(!shell.transport.canSeek || shell.transport.isAd)
            Divider()
            Button("Reveal Current Item") { shell.perform(.revealCurrentItem) }.keyboardShortcut(chord(.revealCurrentItem).0, modifiers: chord(.revealCurrentItem).1).disabled(!shell.transport.hasItem)
            Button("Choose Output…") { shell.showOutputPicker() }
            Button("Show Queue") { shell.perform(.showQueue) }.keyboardShortcut(chord(.showQueue).0, modifiers: chord(.showQueue).1)
            Divider()
            Button("Share Current Song…") { shell.shareCurrentSong() }.disabled(shell.currentShareLink == nil)
            Button("Copy Link to Current Song") { shell.copyCurrentSongLink() }.disabled(shell.currentShareLink == nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Mini-player") { shell.perform(.miniPlayer) }.keyboardShortcut(chord(.miniPlayer).0, modifiers: chord(.miniPlayer).1)
            Button("Now Playing Full Screen") { shell.showNowPlayingFullScreen() }.keyboardShortcut(ShortcutTable.nowPlayingFullScreen.keyEquivalent, modifiers: ShortcutTable.nowPlayingFullScreen.eventModifiers)
        }
        // Same path as the quit Apple Event: close sheets, then the checkpointed terminate.
        #if DEBUG
        // Present only when the isolated QA window-size seam is configured.
        if IsolatedWindowSizeSeam.hasNext {
            CommandGroup(after: .windowSize) {
                Button("Apply Next Test Window Size") { IsolatedWindowSizeSeam.applyNext() }
                    .keyboardShortcut(ShortcutTable.windowSize.keyEquivalent, modifiers: ShortcutTable.windowSize.eventModifiers)
            }
        }
        #endif
        CommandGroup(replacing: .appTermination) {
            Button("Quit YTMuse") { PlaybackApplicationDelegate.requestQuit() }.keyboardShortcut("q")
        }
    }
}
