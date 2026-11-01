import AppIntents
import Foundation

// W24 (MAC03). The transport, search, like/save, queue, player and sleep-timer intents. Each is one command through the channel.

private func dialog(_ text: String) -> some IntentResult & ProvidesDialog { .result(dialog: IntentDialog(stringLiteral: text)) }

public struct ResumePlaybackIntent: AppIntent {
    public static let title: LocalizedStringResource = "Play or Resume"
    public static let description = IntentDescription("Resumes playback. After a launch it plays what you left paused, because you asked it to.")
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog { dialog(try await IntentHub.active.perform(.resume)) }
}
public struct PausePlaybackIntent: AppIntent {
    public static let title: LocalizedStringResource = "Pause"
    public static let description = IntentDescription("Pauses playback.")
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog { dialog(try await IntentHub.active.perform(.pause)) }
}
public struct TogglePlaybackIntent: AppIntent {
    public static let title: LocalizedStringResource = "Play or Pause"
    public static let description = IntentDescription("Plays when paused and pauses when playing.")
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog { dialog(try await IntentHub.active.perform(.toggle)) }
}
public struct NextTrackIntent: AppIntent {
    public static let title: LocalizedStringResource = "Next Song"
    public static let description = IntentDescription("Skips to the next item. An advertisement cannot be skipped.")
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog { dialog(try await IntentHub.active.perform(.next)) }
}
public struct PreviousTrackIntent: AppIntent {
    public static let title: LocalizedStringResource = "Previous Song"
    public static let description = IntentDescription("Goes back to the previous item. An advertisement cannot be skipped.")
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog { dialog(try await IntentHub.active.perform(.previous)) }
}
public struct SeekIntent: AppIntent {
    public static let title: LocalizedStringResource = "Seek"
    public static let description = IntentDescription("Moves to a position in the current item. An advertisement cannot be sought.")
    @Parameter(title: "Seconds", default: 0, inclusiveRange: (0, 86_400)) public var seconds: Int
    public init() {}
    public init(seconds: Int) { self.seconds = seconds }
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard (0...86_400).contains(seconds) else { throw IntentRefusal.unavailable(String(localized: "Choose a position within the item.")) }
        return dialog(try await IntentHub.active.perform(.seek(to: Double(seconds))))
    }
}
public struct LikeCurrentSongIntent: AppIntent {
    public static let title: LocalizedStringResource = "Like This Song"
    public static let description = IntentDescription("Likes the song that is playing, through the same library change the Like button makes.")
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog { dialog(try await IntentHub.active.perform(.rate(.like, of: nil))) }
}
public struct SaveCurrentSongIntent: AppIntent {
    public static let title: LocalizedStringResource = "Save This Song to Library"
    public static let description = IntentDescription("Saves the song that is playing to your YouTube Music library.")
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog { dialog(try await IntentHub.active.perform(.save(of: nil))) }
}
/// Adopts the SDK's `AppSchema.system.searchInApp` (macOS 27.0): the system's own "search in this app" intent, which is also what the deprecated
/// `.system.search` pointed to. It shows YTMuse's Search with the words, as if they had been typed, and says so honestly when no window could do it.
@AppIntent(schema: .system.searchInApp)
public struct SearchInAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Search"
    public static let description = IntentDescription("Opens Search in YTMuse with your words, as if you had typed them.")
    public static let searchScopes: [StringSearchScope] = []
    @Parameter(title: "Search for") public var criteria: StringSearchCriteria
    public init() {}
    public init(query: String) { criteria = StringSearchCriteria(term: query) }
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog { dialog(try await IntentHub.active.perform(.search(criteria.term))) }
}
public struct ShowPlayerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show Player"
    public static let description = IntentDescription("Shows what is playing.")
    public static let openAppWhenRun = true
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog { dialog(try await IntentHub.active.perform(.showPlayer)) }
}
public struct ShowQueueIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show Queue"
    public static let description = IntentDescription("Shows the queue. For YouTube Music it lists what the player reports; YouTube Music manages the upcoming items.")
    public static let openAppWhenRun = true
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog { dialog(try await IntentHub.active.perform(.showQueue)) }
}

public enum SleepTimerChoice: String, AppEnum {
    case minutes, endOfItem, off
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sleep timer"
    public static let caseDisplayRepresentations: [SleepTimerChoice: DisplayRepresentation] = [.minutes: "After some minutes", .endOfItem: "At the end of this item", .off: "Turn off"]
}
public struct SetSleepTimerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set Sleep Timer"
    public static let description = IntentDescription("Stops playback after a while, at the end of the item, or turns the timer off. Available for your own audio and downloads.")
    @Parameter(title: "Timer", default: .minutes) public var choice: SleepTimerChoice
    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 1440)) public var minutes: Int
    public init() {}
    public init(choice: SleepTimerChoice, minutes: Int = 30) { self.choice = choice; self.minutes = minutes }
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        let timer: IntentSleepTimer
        switch choice {
        case .minutes:
            guard IntentSleepTimer.minuteRange.contains(minutes) else { throw IntentRefusal.unavailable(String(localized: "Choose between 1 minute and 24 hours.")) }
            timer = .minutes(minutes)
        case .endOfItem: timer = .endOfItem
        case .off: timer = .off
        }
        return dialog(try await IntentHub.active.perform(.sleepTimer(timer)))
    }
}

/// The package marker: lets the app's own `AppIntentsPackage` pull this module's intents, entities and enums into the app's metadata.
public struct SystemIntegrationIntentsPackage: AppIntentsPackage {}
