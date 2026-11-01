import AppIntents
import Foundation
import MediaIntents

// W24 (MAC03, MAC04). The intents that adopt the SDK's audio schemas, and the plain intents for everything the schemas do not cover.
//
// Every `perform()` is a thin call into `IntentHub` -> the app's command channel -> the same use cases the window's buttons call. None of them
// plays audio, reads a store, holds a credential or makes a request of its own (ARCH03, ARCH09).

/// Argument checks shared by the schema intents. Pure, so the phrase/refusal matrix can test them without the app.
public enum IntentArguments {
    /// The play intent's optional arguments this app cannot honour yet. Refused by name instead of being ignored: a person who said "shuffle" or
    /// "play next" must not get something else without being told.
    public static func unsupported(queueLocation: QueueInsertion?, attributes: Set<PlaybackAttribute>) -> IntentRefusal? {
        if queueLocation != nil {
            return .unavailable(String(localized: "YouTube Music manages the upcoming items, so YTMuse can’t add to the queue or play something next."))
        }
        if attributes.contains(.shuffle) {
            return .unavailable(String(localized: "YTMuse can’t start something shuffled from outside the app yet."))
        }
        if attributes.contains(.repeat) {
            return .unavailable(String(localized: "YTMuse can’t start something on repeat from outside the app yet."))
        }
        return nil
    }
    public static func rating(_ choice: AffinityChoice) -> IntentRating {
        switch choice { case .like: .like; case .dislike: .dislike; case .unset: .none }
    }
}

// MARK: Schema: play

@AppIntent(schema: .audio.playAudio)
public struct PlayAudioIntent: AppIntent {
    public static let description = IntentDescription("Plays a song, album, artist, playlist or mix from your YouTube Music account.")
    @Parameter(title: "Item") public var audioEntity: AudioTarget
    @Parameter(title: "Where in the queue") public var queueLocation: QueueInsertion?
    @Parameter(title: "Prepared queue") public var warmupAudioQueueResult: WarmupResult?
    @Parameter(title: "Options") public var playbackAttributes: Set<PlaybackAttribute>
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        if let refusal = IntentArguments.unsupported(queueLocation: queueLocation, attributes: playbackAttributes) { throw refusal }
        guard let media = audioEntity.media else { throw IntentRefusal.notFound }
        let text = try await IntentHub.active.perform(.play(media))
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: Schema: add to library (Save)

@AppIntent(schema: .audio.addToLibrary)
public struct AddAudioToLibraryIntent: AppIntent {
    public static let description = IntentDescription("Saves the song that is playing to your YouTube Music library.")
    @Parameter(title: "Item") public var audioEntity: AudioTarget
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let media = audioEntity.media else { throw IntentRefusal.notFound }
        let text = try await IntentHub.active.perform(.save(of: media))
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: Schema: like, dislike, remove rating

@AppIntent(schema: .audio.updateAudioAffinity)
public struct UpdateAudioAffinityIntent: AppIntent {
    public static let description = IntentDescription("Likes or dislikes the song that is playing, or removes the rating.")
    @Parameter(title: "Rating") public var affinityState: AffinityChoice
    @Parameter(title: "Item") public var target: AudioTarget
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let media = target.media else { throw IntentRefusal.notFound }
        let text = try await IntentHub.active.perform(.rate(IntentArguments.rating(affinityState), of: media))
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: Media search ("Play <words> in YTMuse")

/// The SDK's media-search value (`MediaIntents.AudioSearch`). The best match is played only when ONE item in the current account's caches matches
/// clearly; several matches are returned as a choice, never reduced to the first.
public struct PlayMediaSearchIntent: AppIntent {
    public static let title: LocalizedStringResource = "Play from Search"
    public static let description = IntentDescription("Plays what you asked for by name from the library you have open in YTMuse; if several items match it asks you which one.")
    @Parameter(title: "Search") public var search: AudioSearch
    public init() {}
    public init(search: AudioSearch) { self.search = search }
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        let text: String
        switch search.criteria {
        case .searchQuery(let query):
            do { text = try await IntentHub.active.perform(.playSearch(query)) }
            catch IntentRefusal.ambiguous(let options) {
                // Several items match: ask the person, with the SDK's own choice interaction, instead of failing.
                let chosen = try await IntentChoice.pick(among: options) { lines in
                    if let chooser = IntentHub.active.chooser { return try await chooser(lines) }
                    let picked = try await self.requestChoice(between: IntentChoice.options(lines), dialog: IntentDialog(stringLiteral: String(localized: "Which one?")))
                    return IntentChoice.options(lines).firstIndex(of: picked) ?? 0
                }
                text = try await IntentHub.active.perform(.play(chosen))
            }
        case .url, .unspecified: throw IntentRefusal.unavailable(String(localized: "Tell YTMuse what to play by name."))
        @unknown default: throw IntentRefusal.unavailable(String(localized: "Tell YTMuse what to play by name."))
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Putting a choice among duplicates to the person. The lines are made distinct (two items can share every printed part), the list is bounded, and when
/// the interaction cannot be had the answer is the ambiguity itself, never a silent pick.
public enum IntentChoice {
    public static let limit = 5
    nonisolated public static func options(_ lines: [String]) -> [IntentChoiceOption] { lines.map { IntentChoiceOption(title: LocalizedStringResource(stringLiteral: $0)) } }
    public static func lines(for options: [IntentMedia]) -> [String] {
        var seen: [String: Int] = [:]
        return options.prefix(limit).map { option in
            let line = IntentResolver.disambiguationLine(option)
            seen[line, default: 0] += 1
            return seen[line]! > 1 ? "\(line) (\(seen[line]!))" : line
        }
    }
    @MainActor public static func pick(among options: [IntentMedia], ask: ([String]) async throws -> Int) async throws -> IntentMedia {
        let shown = Array(options.prefix(limit))
        guard shown.count > 1 else { throw IntentRefusal.ambiguous(options) }
        let index: Int
        do { index = try await ask(lines(for: shown)) } catch { throw IntentRefusal.ambiguous(options) }
        guard shown.indices.contains(index) else { throw IntentRefusal.ambiguous(options) }
        return shown[index]
    }
}
