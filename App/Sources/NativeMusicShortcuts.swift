import AppIntents
import SystemIntegration
import WidgetShared

// W24 (MAC03, MAC04). The app's App Shortcuts and the metadata packaging.
//
// The intents, entities and schemas live in the `SystemIntegration` package and run IN this process: no intent extension, no App Group snapshot for them and
// nothing here plays audio, holds a credential or reads a store (ARCH09). W25 adds the widget's button intent (WidgetShared), which the system also runs here. This target only declares which package's intents
// belong to the app (`AppIntentsPackage`) so the build generates their metadata into the app bundle, and lists the shortcuts with their phrases.
// Phrases live in `Resources/AppShortcuts.xcstrings`, each with the app's name, as the system requires.
//
// What this does NOT establish: that Siri recognises any of these phrases in any language. That is a live observation (W41), reported separately
// from compiling and from the Shortcuts app listing the actions.

struct YTMuseAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [SystemIntegrationIntentsPackage.self, WidgetSharedIntentsPackage.self] }
}

struct YTMuseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumePlaybackIntent(), phrases: ["Play \(.applicationName)", "Resume \(.applicationName)", "Resume music in \(.applicationName)"],
                    shortTitle: "Play or Resume", systemImageName: "play.fill")
        AppShortcut(intent: PausePlaybackIntent(), phrases: ["Pause \(.applicationName)", "Pause music in \(.applicationName)"],
                    shortTitle: "Pause", systemImageName: "pause.fill")
        AppShortcut(intent: NextTrackIntent(), phrases: ["Next song in \(.applicationName)", "Skip this song in \(.applicationName)"],
                    shortTitle: "Next Song", systemImageName: "forward.end.fill")
        AppShortcut(intent: PreviousTrackIntent(), phrases: ["Previous song in \(.applicationName)", "Go back in \(.applicationName)"],
                    shortTitle: "Previous Song", systemImageName: "backward.end.fill")
        AppShortcut(intent: LikeCurrentSongIntent(), phrases: ["Like this song in \(.applicationName)", "Like this in \(.applicationName)"],
                    shortTitle: "Like This Song", systemImageName: "heart")
        AppShortcut(intent: SaveCurrentSongIntent(), phrases: ["Save this song in \(.applicationName)", "Save this to my library in \(.applicationName)"],
                    shortTitle: "Save to Library", systemImageName: "bookmark")
        AppShortcut(intent: ShowPlayerIntent(), phrases: ["Show the player in \(.applicationName)", "Show what is playing in \(.applicationName)"],
                    shortTitle: "Show Player", systemImageName: "play.circle")
        AppShortcut(intent: ShowQueueIntent(), phrases: ["Show the queue in \(.applicationName)"],
                    shortTitle: "Show Queue", systemImageName: "list.bullet")
        AppShortcut(intent: SetSleepTimerIntent(), phrases: ["Set a sleep timer in \(.applicationName)", "Sleep timer in \(.applicationName)"],
                    shortTitle: "Sleep Timer", systemImageName: "moon.zzz")
        AppShortcut(intent: SearchInAppIntent(), phrases: ["Search in \(.applicationName)", "Search \(.applicationName)"],
                    shortTitle: "Search", systemImageName: "magnifyingglass")
    }
}
