import AppIntents
import Foundation
import MediaIntents
import Testing
@testable import SystemIntegration

/// A channel that only records, so each intent's mapping to ONE command can be asserted without the app.
@MainActor final class RecordingIntentChannel: IntentCommandChannel {
    var commands: [IntentCommand] = []
    var scope: IntentScope? = IntentScope(accountID: UUID(), generation: 1)
    var reply: IntentOutcome = .done("Done.")
    private(set) var startups = 0
    func awaitReady() async { startups += 1 }
    func currentScope() async -> IntentScope? { scope }
    func candidates(kind: IntentMediaKind?, matching text: String?, limit: Int) async -> [IntentMedia] { [] }
    func perform(_ command: IntentCommand) async -> IntentOutcome { commands.append(command); return reply }
}

/// T24.1 (MAC03): each intent is exactly one command through the channel, and the schema intents refuse what the app cannot honour instead of ignoring it.
@Suite @MainActor struct IntentDefinitionTests {
    private func rig() -> (IntentHub, RecordingIntentChannel, IntentScope) {
        let hub = IntentHub(), channel = RecordingIntentChannel(); hub.startupTimeout = .milliseconds(100); hub.install(channel)
        return (hub, channel, channel.scope!)
    }
    private func perform<I: AppIntent>(_ intent: I, in hub: IntentHub) async throws {
        try await IntentHub.$current.withValue(hub) { _ = try await intent.perform() }
    }
    private func thrown<I: AppIntent>(_ intent: I, in hub: IntentHub) async -> IntentRefusal? {
        do { try await perform(intent, in: hub); return nil } catch let refusal as IntentRefusal { return refusal } catch { return .failed("\(error)") }
    }

    @Test func everyTransportIntentIsOneCommand() async throws {
        let (hub, channel, _) = rig()
        try await perform(ResumePlaybackIntent(), in: hub); try await perform(PausePlaybackIntent(), in: hub); try await perform(TogglePlaybackIntent(), in: hub)
        try await perform(NextTrackIntent(), in: hub); try await perform(PreviousTrackIntent(), in: hub); try await perform(SeekIntent(seconds: 95), in: hub)
        try await perform(LikeCurrentSongIntent(), in: hub); try await perform(SaveCurrentSongIntent(), in: hub)
        try await perform(ShowPlayerIntent(), in: hub); try await perform(ShowQueueIntent(), in: hub); try await perform(SearchInAppIntent(query: "daft punk"), in: hub)
        #expect(channel.commands == [.resume, .pause, .toggle, .next, .previous, .seek(to: 95), .rate(.like, of: nil), .save(of: nil), .showPlayer, .showQueue, .search("daft punk")])
    }
    @Test func theSleepTimerIntentMapsEachChoiceAndRefusesALengthOutsideTheMenusRange() async throws {
        let (hub, channel, _) = rig()
        try await perform(SetSleepTimerIntent(choice: .minutes, minutes: 45), in: hub)
        try await perform(SetSleepTimerIntent(choice: .endOfItem), in: hub)
        try await perform(SetSleepTimerIntent(choice: .off), in: hub)
        #expect(channel.commands == [.sleepTimer(.minutes(45)), .sleepTimer(.endOfItem), .sleepTimer(.off)])
        for bad in [0, 1_441, -5] {
            guard case .unavailable? = await thrown(SetSleepTimerIntent(choice: .minutes, minutes: bad), in: hub) else { Issue.record("\(bad)"); return }
        }
        #expect(channel.commands.count == 3)
        let low = await thrown(SeekIntent(seconds: -1), in: hub), high = await thrown(SeekIntent(seconds: 90_000), in: hub)
        #expect(low != nil && high != nil)
        #expect(channel.commands.count == 3)
    }
    @Test func thePlayIntentSendsTheEntityOfEachKindAndNothingElse() async throws {
        let (hub, channel, scope) = rig()
        let song = intentMedia(.song, scope: scope), album = intentMedia(.album, scope: scope), artist = intentMedia(.artist, scope: scope)
        let playlist = intentMedia(.playlist, scope: scope), mix = intentMedia(.mix, scope: scope)
        let targets: [AudioTarget] = [.song(SongEntity(media: song)), .album(AlbumEntity(media: album)), .artist(ArtistEntity(media: artist)),
                                      .playlist(PlaylistEntity(media: playlist)), .mix(MixEntity(media: mix))]
        for target in targets {
            var intent = PlayAudioIntent(); intent.audioEntity = target; intent.playbackAttributes = []
            try await perform(intent, in: hub)
        }
        #expect(channel.commands == [.play(song), .play(album), .play(artist), .play(playlist), .play(mix)])
    }
    @Test func aQueuePositionShuffleOrRepeatIsRefusedByNameNotIgnored() async throws {
        let (hub, channel, scope) = rig()
        func make(_ location: QueueInsertion?, _ attributes: Set<PlaybackAttribute>) -> PlayAudioIntent {
            var intent = PlayAudioIntent(); intent.audioEntity = .song(SongEntity(media: intentMedia(scope: scope))); intent.queueLocation = location; intent.playbackAttributes = attributes
            return intent
        }
        for (location, attributes) in [(QueueInsertion.next, Set<PlaybackAttribute>()), (.tail, []), (nil, [.shuffle]), (nil, [.repeat]), (nil, [.shuffle, .repeat])] {
            guard case .unavailable(let why)? = await thrown(make(location, attributes), in: hub) else { Issue.record("\(String(describing: location)) \(attributes)"); return }
            #expect(!why.isEmpty)
        }
        #expect(channel.commands.isEmpty, "nothing was played in place of what was asked")
        try await perform(make(nil, []), in: hub)
        #expect(channel.commands.count == 1)
    }
    @Test func saveAndRateTakeTheSchemasEntitiesAndMapTheAffinityStates() async throws {
        let (hub, channel, scope) = rig()
        let song = intentMedia(scope: scope)
        var add = AddAudioToLibraryIntent(); add.audioEntity = .song(SongEntity(media: song)); try await perform(add, in: hub)
        for (state, rating) in [(AffinityChoice.like, IntentRating.like), (.dislike, .dislike), (.unset, .none)] {
            var update = UpdateAudioAffinityIntent(); update.affinityState = state; update.target = .song(SongEntity(media: song)); try await perform(update, in: hub)
            #expect(channel.commands.last == .rate(rating, of: song))
        }
        #expect(channel.commands.first == .save(of: song))
    }
    @Test func mediaSearchPlaysByWordsAndRefusesAnythingItCannotInterpret() async throws {
        let (hub, channel, _) = rig()
        try await perform(PlayMediaSearchIntent(search: AudioSearch(criteria: .searchQuery("my supermix"))), in: hub)
        #expect(channel.commands == [.playSearch("my supermix")])
        for criteria in [AudioSearch.Criteria.unspecified, .url([URL(string: "https://music.youtube.com/watch?v=x")!])] {
            guard case .unavailable? = await thrown(PlayMediaSearchIntent(search: AudioSearch(criteria: criteria)), in: hub) else { Issue.record("\(criteria)"); return }
        }
        #expect(channel.commands.count == 1, "a link is not executed from here: links open native destinations (W26)")
    }
    @Test func aRefusalIsThrownWithTheAppsOwnSentenceSoTheSystemShowsIt() async throws {
        let (hub, channel, _) = rig()
        channel.reply = .refused(.advertisement)
        let refusal = await thrown(NextTrackIntent(), in: hub)
        #expect(refusal == .advertisement)
        #expect(refusal?.localizedDescription == IntentRefusal.advertisement.message)
        channel.reply = .refused(.ambiguous([intentMedia(scope: channel.scope!)]))
        let choice = await thrown(ResumePlaybackIntent(), in: hub)
        #expect(choice != nil)
        channel.scope = nil; channel.reply = .refused(.signedOut)
        let signedOut = await thrown(PausePlaybackIntent(), in: hub)
        #expect(signedOut == .signedOut)
    }
    @Test func noChannelMeansTheAppIsNotReadyAndNoCommandIsInvented() async throws {
        let hub = IntentHub(); hub.startupTimeout = .milliseconds(60)
        let notReady = await thrown(ResumePlaybackIntent(), in: hub)
        #expect(notReady == .appNotReady)
        #expect(IntentRefusal.appNotReady.message.contains("starting"))
    }
}

/// T24.1/T24.4: what the build packages and the shortcuts say, against the sources the app is built from.
@Suite struct IntentInventoryTests {
    /// MAC03's verbs and the intent type that carries each.
    private let coverage: [(String, [any AppIntent.Type])] = [
        ("play / resume", [ResumePlaybackIntent.self, TogglePlaybackIntent.self]), ("pause", [PausePlaybackIntent.self]),
        ("next", [NextTrackIntent.self]), ("previous", [PreviousTrackIntent.self]), ("seek", [SeekIntent.self]),
        ("play song / album / artist / playlist / mix", [PlayAudioIntent.self, PlayMediaSearchIntent.self]), ("search", [SearchInAppIntent.self]),
        ("like", [LikeCurrentSongIntent.self, UpdateAudioAffinityIntent.self]), ("save", [SaveCurrentSongIntent.self, AddAudioToLibraryIntent.self]),
        ("queue", [ShowQueueIntent.self]), ("show player", [ShowPlayerIntent.self]), ("sleep timer", [SetSleepTimerIntent.self]),
    ]
    @Test func everyMAC03VerbHasAnIntentAndEveryIntentHasATitleOrASchema() {
        #expect(coverage.count == 12 && coverage.allSatisfy { !$0.1.isEmpty })
        let plain: [any AppIntent.Type] = [ResumePlaybackIntent.self, PausePlaybackIntent.self, TogglePlaybackIntent.self, NextTrackIntent.self, PreviousTrackIntent.self,
                                           SeekIntent.self, LikeCurrentSongIntent.self, SaveCurrentSongIntent.self, SearchInAppIntent.self, ShowPlayerIntent.self,
                                           ShowQueueIntent.self, SetSleepTimerIntent.self, PlayMediaSearchIntent.self]
        for type in plain { #expect(String(localized: type.title).isEmpty == false, Comment(rawValue: "\(type)")) }
    }
    @Test func theSourcesDeclareExactlyTheIntentsTheBuildReports() throws {
        var declared = Set<String>()
        for url in IntentSources.swiftFiles(under: "Packages/NativeMusic/Sources/SystemIntegration/Intents") {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in text.matches(of: /public struct (\w+Intent): AppIntent/) { declared.insert(String(match.1)) }
        }
        let expected: Set<String> = ["ResumePlaybackIntent", "PausePlaybackIntent", "TogglePlaybackIntent", "NextTrackIntent", "PreviousTrackIntent", "SeekIntent",
                                     "LikeCurrentSongIntent", "SaveCurrentSongIntent", "SearchInAppIntent", "ShowPlayerIntent", "ShowQueueIntent", "SetSleepTimerIntent",
                                     "PlayMediaSearchIntent", "PlayAudioIntent", "AddAudioToLibraryIntent", "UpdateAudioAffinityIntent"]
        #expect(declared == expected, "\(declared.symmetricDifference(expected))")
    }
    @Test func theShortcutPhrasesAllNameTheAppAndLiveInTheStringCatalog() throws {
        let source = try IntentSources.source("App/Sources/NativeMusicShortcuts.swift")
        let phrases = source.matches(of: /phrases: \[([^\]]*)\]/).flatMap { group in String(group.1).matches(of: /"([^"]+)"/).map { String($0.1) } }
        #expect(phrases.count >= 10)
        let keys = phrases.map { $0.replacingOccurrences(of: "\\(.applicationName)", with: "${applicationName}") }
        for (phrase, key) in zip(phrases, keys) {
            #expect(phrase.components(separatedBy: "\\(.applicationName)").count == 2, "exactly one app name in: \(phrase)")
            #expect(!phrase.contains("\\(\\.$"), "no parameter in a phrase this app cannot fill: \(phrase)")
            #expect(key.count < 80)
        }
        #expect(Set(keys).count == keys.count, "no phrase twice")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: IntentSources.root.appendingPathComponent("Resources/AppShortcuts.xcstrings"))) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        #expect(catalog?["sourceLanguage"] as? String == "en")
        #expect(Set(strings.keys) == Set(keys), "the catalog holds exactly the phrases the provider declares")
        let shortcuts = source.matches(of: /AppShortcut\(intent:/).count
        #expect((1...10).contains(shortcuts), "the system accepts at most ten shortcuts: \(shortcuts)")
        let used = source.matches(of: /AppShortcut\(intent: (\w+)\(/).map { String($0.1) }
        let declared = try IntentSources.swiftFiles(under: "Packages/NativeMusic/Sources/SystemIntegration/Intents").map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for name in used { #expect(declared.contains("public struct \(name): AppIntent"), "\(name) is an intent of the package") }
        #expect(source.contains("AppIntentsPackage") && source.contains("SystemIntegrationIntentsPackage.self"))
    }
    /// The phrase matrix: every phrase of every App Shortcut, the intent it starts, and the ONE command that intent sends (run through a recording channel).
    @Test @MainActor func everyShortcutPhraseLeadsToTheOneCommandItsIntentSends() async throws {
        let table: [String: (@MainActor () async throws -> Void, IntentCommand)] = [
            "ResumePlaybackIntent": ({ _ = try await ResumePlaybackIntent().perform() }, .resume),
            "PausePlaybackIntent": ({ _ = try await PausePlaybackIntent().perform() }, .pause),
            "NextTrackIntent": ({ _ = try await NextTrackIntent().perform() }, .next),
            "PreviousTrackIntent": ({ _ = try await PreviousTrackIntent().perform() }, .previous),
            "LikeCurrentSongIntent": ({ _ = try await LikeCurrentSongIntent().perform() }, .rate(.like, of: nil)),
            "SaveCurrentSongIntent": ({ _ = try await SaveCurrentSongIntent().perform() }, .save(of: nil)),
            "ShowPlayerIntent": ({ _ = try await ShowPlayerIntent().perform() }, .showPlayer),
            "ShowQueueIntent": ({ _ = try await ShowQueueIntent().perform() }, .showQueue),
            "SetSleepTimerIntent": ({ _ = try await SetSleepTimerIntent().perform() }, .sleepTimer(.minutes(30))),
            "SearchInAppIntent": ({ var intent = SearchInAppIntent(); intent.criteria = StringSearchCriteria(term: "radiohead"); _ = try await intent.perform() }, .search("radiohead")),
        ]
        let source = try IntentSources.source("App/Sources/NativeMusicShortcuts.swift")
        let shortcuts = source.matches(of: /AppShortcut\(intent: (\w+)\(\), phrases: \[([^\]]*)\]/).map { (String($0.1), String($0.2).matches(of: /"([^"]+)"/).map { String($0.1) }) }
        #expect(shortcuts.count == table.count && Set(shortcuts.map(\.0)) == Set(table.keys), "every shortcut is in the matrix and every row is a shortcut")
        var matrix: [String] = []
        for (name, phrases) in shortcuts {
            let (run, expected) = try #require(table[name], Comment(rawValue: name))
            let hub = IntentHub(), channel = RecordingIntentChannel(); hub.startupTimeout = .milliseconds(100); hub.install(channel)
            try await IntentHub.$current.withValue(hub) { try await run() }
            #expect(channel.commands == [expected], Comment(rawValue: "\(name) -> \(channel.commands)"))
            #expect(!phrases.isEmpty)
            for phrase in phrases { matrix.append("\(phrase.replacingOccurrences(of: "\\(.applicationName)", with: "YTMuse")) | \(name) | \(expected.name)") }
        }
        print("PHRASE-MATRIX\n" + matrix.joined(separator: "\n"))
        #expect(matrix.count == 20)
    }
    @Test func thereIsNoIntentExtensionNoPlayerNoCredentialAndNoStoreBehindAnIntent() throws {
        // ARCH09 as W24 ships it: intents run in the app process, and no extension exists FOR them. W25 (deliberately, narrowly) added exactly one extension, the widget, and
        // exactly one App Group for it, and nothing else. The group is Team-ID-prefixed through a BUILD VARIABLE (no literal team in the repository); only the signing step
        // (scripts/sign-bundle.sh, with an identity) applies the group-bearing entitlements. Every Xcode build signs with the ad-hoc files, which hold no group, and embeds no extension.
        let template = "$(TeamIdentifierPrefix)local.native-music.development"
        func plist(_ path: String) throws -> [String: Any] {
            try #require(try PropertyListSerialization.propertyList(from: Data(IntentSources.source(path).utf8), format: nil) as? [String: Any])
        }
        let app = try plist("App/NativeMusic.entitlements")
        #expect(Set(app.keys) == ["com.apple.security.application-groups"] && app["com.apple.security.application-groups"] as? [String] == [template], "the one group, as the build variable form: \(app.keys)")
        #expect(try plist("App/NativeMusic-adhoc.entitlements").isEmpty, "an ad-hoc build holds no entitlement at all")
        let project = try IntentSources.source("App/NativeMusic.xcodeproj/project.pbxproj")
        #expect(project.components(separatedBy: "com.apple.product-type.app-extension").count == 2, "exactly one app-extension target")
        #expect(project.components(separatedBy: ".appex").count == 2 && project.contains("NativeMusicWidget.appex"), "and it is the widget")
        #expect(!project.contains("com.apple.intents") && !project.contains("PBXCopyFilesBuildPhase"), "no intents extension, no copy-files embedding")
        #expect(project.contains("CODE_SIGN_ENTITLEMENTS = NativeMusic-adhoc.entitlements") && !project.contains("CODE_SIGN_ENTITLEMENTS = NativeMusic.entitlements"), "Xcode signs with the ad-hoc entitlements, never the group-bearing ones")
        let intents = IntentSources.swiftFiles(under: "Packages/NativeMusic/Sources/SystemIntegration/Intents")
        #expect(intents.count >= 6)
        let forbidden = ["import Playback", "import AccountSession", "import Persistence", "import AVFoundation", "import WebKit", "import Security", "import Downloads",
                         "SecItem", "Keychain", "URLSession", "WKWebView", "AVPlayer", "UserDefaults", "FileManager"]
        for url in intents {
            let text = try String(contentsOf: url, encoding: .utf8)
            for word in forbidden { #expect(!text.contains(word), "\(url.lastPathComponent) must not contain \(word)") }
        }
        let boundary = try IntentSources.source("Extensions/Sources/NativeMusicIntentSupport/IntentBoundary.swift")
        #expect(!boundary.contains("AppIntent") || boundary.contains("registers no"), "the extension scaffold registers no intent")
    }
    @Test func theSchemaIntentsAndEntitiesAdoptTheSDKsAudioDomainAndNoDocumentationOnlyOnes() throws {
        let text = try IntentSources.swiftFiles(under: "Packages/NativeMusic/Sources/SystemIntegration/Intents").map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for schema in ["audio.playAudio", "audio.addToLibrary", "audio.updateAudioAffinity", "audio.song", "audio.album", "audio.artist", "audio.playlist",
                       "audio.algorithmicRadioStation", "audio.warmupAudioQueueResult", "audio.queueInsertionLocation", "audio.affinityState", "audio.playbackAttributes", "system.searchInApp"] {
            #expect(text.contains("schema: ." + schema), Comment(rawValue: schema))
        }
        // A schema this app has no honest implementation for is not adopted.
        for unadopted in ["audio.warmupAudioQueue)", "audio.recognizeAudio", "audio.createStation", "audio.addToPlaylist", "audio.podcast", "audio.liveRadioStation"] {
            #expect(!text.contains("schema: ." + unadopted), Comment(rawValue: unadopted))
        }
    }
}
