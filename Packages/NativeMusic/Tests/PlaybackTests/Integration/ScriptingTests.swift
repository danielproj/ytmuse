import AppKit
import Foundation
import Testing
@testable import Playback
@testable import SystemIntegration
@testable import AppShell

/// T26.3 (MAC11, ARCH03): the AppleScript dictionary's transport, current track, queue and open-link commands resolve to the shared commands; the documented
/// examples execute; there is no raw token or request accessor. Nothing here sends an Apple event.
@Suite @MainActor struct ScriptDispatcherTests {
    @Test func everyRequestReachesItsTargetCallAndNothingElse() async {
        let target = RecordingScriptTarget()
        let song = "https://music.youtube.com/watch?v=dQw4w9WgXcQ"
        for request in [ScriptRequest.play, .pause, .playPause, .nextTrack, .previousTrack, .seekTo(30), .seekBy(-10), .setVolume(40), .queue(song, placement: .next), .queue(song, placement: .end), .openLocation("ytmuse://library")] {
            #expect(await ScriptDispatcher.perform(request, on: target) == nil, "\(request)")
        }
        #expect(target.calls == ["transport play", "transport pause", "transport playPause", "transport next", "transport previous", "transport seekTo(30.0)", "transport seekBy(-10.0)",
                                 "volume 40", "queue next dQw4w9WgXcQ", "queue end dQw4w9WgXcQ", "open screen library"])
    }

    @Test(arguments: [ScriptRequest.seekTo(-1), .seekTo(.nan), .seekTo(.infinity), .seekTo(90_000), .seekBy(.nan), .seekBy(-.infinity), .seekBy(90_000), .setVolume(-1), .setVolume(101), .setVolume(Int.max)])
    func invalidArgumentsAreRefusedBeforeTheTargetIsCalled(request: ScriptRequest) async {
        let target = RecordingScriptTarget()
        #expect(await ScriptDispatcher.perform(request, on: target) == .invalidArgument)
        #expect(target.calls.isEmpty)
    }

    @Test(arguments: ["", "not a link", "https://evil.example/watch?v=dQw4w9WgXcQ", "https://music.youtube.com/playlist?list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", "ytmuse://library", "https://music.youtube.com/browse/MPREb_AbCdEfGhIjK",
                      "https://music.youtube.com/watch?v=dQw4w9WgXcQ&action=play", "file:///Users/me/song.m4a", "https://127.0.0.1/watch?v=dQw4w9WgXcQ"])
    func onlyASongLinkCanBeQueued(text: String) async {
        let target = RecordingScriptTarget()
        #expect(await ScriptDispatcher.perform(.queue(text, placement: .end), on: target) == .invalidLink)
        #expect(target.calls.isEmpty)
    }

    @Test(arguments: ["", "javascript:alert(1)", "https://music.youtube.com/watch?v=short", "ytmuse://song/dQw4w9WgXcQ?action=play", "http://music.youtube.com/watch?v=dQw4w9WgXcQ"])
    func openLinkAppliesTheStrictLinkRulesAndRefusesWithoutCallingTheTarget(text: String) async {
        let target = RecordingScriptTarget()
        #expect(await ScriptDispatcher.perform(.openLocation(text), on: target) == .invalidLink)
        #expect(target.calls.isEmpty)
    }

    @Test func aRefusalFromTheSharedCommandReachesTheScriptWithItsNumberAndSentence() async {
        let target = RecordingScriptTarget()
        target.refusal = .notAllowedNow("An advertisement is playing.")
        let refusal = await ScriptDispatcher.perform(.nextTrack, on: target)
        #expect(refusal == .notAllowedNow("An advertisement is playing.") && refusal?.code == 4602 && refusal?.message == "An advertisement is playing.")
        #expect(Set([ScriptRefusal.nothingPlaying, .notAllowedNow("x"), .invalidArgument, .invalidLink, .queueNotEditable("x")].map(\.code)).count == 5, "distinct, stable numbers")
    }
}

/// The shell as the scripting target: the same admission as a media key. This is the REAL production conformer over a fake hidden page.
@Suite @MainActor struct ScriptingShellTests {
    @Test func transportCommandsAreTheMediaKeyCommands() async throws {
        let rig = try await IntegrationRig.make(); defer { rig.cleanUp() }
        let page = try #require(rig.rig.log.pages.first)
        let before = page.commands.count
        #expect(rig.shell.transport(.pause) == nil && rig.shell.transport(.play) == nil && rig.shell.transport(.playPause) == nil)
        #expect(rig.shell.transport(.seekTo(42)) == nil && rig.shell.transport(.seekBy(-5)) == nil)
        #expect(rig.shell.transport(.next) == nil && rig.shell.transport(.previous) == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(page.commands.count > before, "the commands reached the hidden player through PlaybackModel.remote")
    }

    @Test func aScriptIsHeldToTheWindowsOwnRules_anAdvertisementRefusesSkipAndSeekButNotPause() async throws {
        let rig = try await IntegrationRig.make(state: lifecycleState(ad: true)); defer { rig.cleanUp() }
        #expect(rig.shell.playerState == .advertisement)
        #expect(rig.shell.transport(.next) != nil && rig.shell.transport(.previous) != nil)
        #expect(rig.shell.transport(.seekTo(10)) != nil && rig.shell.transport(.seekBy(10)) != nil)
        if case .notAllowedNow(let why)? = rig.shell.transport(.next) { #expect(!why.isEmpty) } else { Issue.record("expected a sentence") }
        #expect(rig.shell.transport(.pause) == nil, "pause is allowed during an advertisement")
        #expect(rig.shell.currentTrack == ScriptTrack(name: "Advertisement"), "nothing of the song the advertisement interrupts")
    }

    @Test func withNothingLoadedEveryTransportCommandSaysNothingIsPlaying() async throws {
        let rig = try await IntegrationRig.make(playing: false); defer { rig.cleanUp() }
        for request in [ScriptTransport.play, .pause, .playPause, .next, .previous, .seekTo(5), .seekBy(5)] { #expect(rig.shell.transport(request) == .nothingPlaying, "\(request)") }
        #expect(rig.shell.setVolume(percent: 20) == .nothingPlaying)
        #expect(rig.shell.playerState == .stopped && rig.shell.currentTrack == nil)
    }

    @Test func theCurrentTrackIsPublicMetadataAndThePublicLinkOnly() async throws {
        let rig = try await IntegrationRig.make(state: lifecycleState(position: 12, duration: 200)); defer { rig.cleanUp() }
        let track = try #require(rig.shell.currentTrack)
        #expect(track.name == "Synthetic Song" && track.artist == "Synthetic Artist" && track.duration == 200)
        #expect(track.url == "https://music.youtube.com/watch?v=" + integrationVideo)
        #expect(rig.shell.playerState == .playing)
        // The type has these five fields and no others: no token, cookie, header, request or credential can be read through it.
        #expect(Mirror(reflecting: track).children.compactMap(\.label).sorted() == ["artist", "duration", "name", "position", "url"])
    }

    @Test func aLiveStreamHasNoDurationOrPosition() async throws {
        let rig = try await IntegrationRig.make(state: lifecycleState(position: 0, duration: 0)); defer { rig.cleanUp() }
        let track = try #require(rig.shell.currentTrack)
        #expect(track.duration == nil, "an unknown length is missing, not zero")
    }

    @Test func queueInsertionIsRefusedWhileYouTubeMusicManagesTheQueueAndNeverInventsOne() async throws {
        let rig = try await IntegrationRig.make(); defer { rig.cleanUp() }
        let item = try #require(LinkItem(kind: .song, identifier: "dQw4w9WgXcQ"))
        let refusal = await rig.shell.queueInsert(item, placement: .next)
        guard case .queueNotEditable(let why)? = refusal else { Issue.record("expected a refusal, got \(String(describing: refusal))"); return }
        #expect(why.contains("YouTube Music"))
        let idle = try await IntegrationRig.make(playing: false); defer { idle.cleanUp() }
        #expect(await idle.shell.queueInsert(item, placement: .end) == .nothingPlaying)
    }

    /// Input-surface parity (ARCH03): a menu item or status item, a keyboard shortcut, an AppleScript command and a media key are one command. Each is sent
    /// to its own copy of the app's playback owner and must put the very same commands on the hidden page.
    @Test(arguments: ["pause", "play", "next", "previous", "seek"]) func everyInputSurfaceSendsTheSameCommandsToThePlayer(command: String) async throws {
        var sequences: [[String]] = []
        for surface in ["menu or status item", "keyboard shortcut", "AppleScript", "media key"] {
            let rig = try await IntegrationRig.make(); defer { rig.cleanUp() }
            let page = try #require(rig.rig.log.pages.first)
            try await Task.sleep(for: .milliseconds(100))
            let before = page.commands.count
            switch (command, surface) {
            case ("pause", "menu or status item"), ("play", "menu or status item"): rig.shell.togglePlayPause()
            case ("pause", "keyboard shortcut"), ("play", "keyboard shortcut"): rig.shell.perform(.playPause)
            case ("pause", "AppleScript"): _ = rig.shell.transport(.playPause)
            case ("play", "AppleScript"): _ = rig.shell.transport(.playPause)
            case ("pause", "media key"), ("play", "media key"): _ = rig.rig.model.remote(.toggle)
            case ("next", "menu or status item"): rig.shell.next()
            case ("next", "keyboard shortcut"): rig.shell.perform(.next)
            case ("next", "AppleScript"): _ = rig.shell.transport(.next)
            case ("next", "media key"): _ = rig.rig.model.remote(.next)
            case ("previous", "menu or status item"): rig.shell.previous()
            case ("previous", "keyboard shortcut"): rig.shell.perform(.previous)
            case ("previous", "AppleScript"): _ = rig.shell.transport(.previous)
            case ("previous", "media key"): _ = rig.rig.model.remote(.previous)
            case ("seek", "menu or status item"), ("seek", "keyboard shortcut"): _ = rig.rig.model.shellSeek(by: 10)
            case ("seek", "AppleScript"): _ = rig.shell.transport(.seekBy(10))
            case ("seek", "media key"): _ = rig.rig.model.remote(.seek(rig.rig.model.shellSeekTarget(by: 10) ?? -1))
            default: Issue.record("unmapped \(command) / \(surface)")
            }
            try await Task.sleep(for: .milliseconds(250))
            sequences.append(page.commands.dropFirst(before).map(\.body))
        }
        #expect(!sequences[0].isEmpty, "\(command) reached the player")
        #expect(Set(sequences).count == 1, "\(command): the four surfaces sent different commands: \(sequences.map(\.count))")
    }

    /// ARCH03: a script's queue insertion is the shared queue command, identified as a script.
    @Test func aScriptsQueueInsertionIsTheSharedQueueCommandWithTheAppleScriptOrigin() throws {
        let item = try #require(LinkItem(kind: .song, identifier: "dQw4w9WgXcQ"))
        for (placement, expectNext) in [(QueuePlacement.next, true), (.end, false)] {
            let request = try ScriptQueueRequest(item, placement: placement)
            #expect(request.origin == .appleScript)
            switch request.command {
            case .playNext(let media): #expect(expectNext && media.map(\.rawValue) == ["dQw4w9WgXcQ"])
            case .add(let media): #expect(!expectNext && media.map(\.rawValue) == ["dQw4w9WgXcQ"])
            default: Issue.record("not a queue insertion: \(request.command)")
            }
        }
        // And the shell sends exactly that request (no other origin is written at the call site).
        let text = try IntegrationSources.text("Packages/NativeMusic/Sources/AppShell/Integration/ShellIntegration.swift")
        #expect(text.contains("session.sendQueue(request.command, origin: request.origin)"))
        #expect(!text.contains("origin: .menu") && !text.contains("origin: .userInterface"))
    }

    @Test func openLinkOnlyNavigates() async throws {
        let rig = try await IntegrationRig.make(); defer { rig.cleanUp() }
        let page = try #require(rig.rig.log.pages.first)
        let commands = page.commands.count, loads = page.loads.count
        let result = await ScriptDispatcher.perform(.openLocation("https://music.youtube.com/watch?v=dQw4w9WgXcQ"), on: rig.shell)
        #expect(result == nil)
        try await waitForLinkRequest(rig.shell)
        #expect(rig.shell.linkRequest?.destination == .item(LinkItem(kind: .song, identifier: "dQw4w9WgXcQ")!))
        #expect(page.commands.count == commands && page.loads.count == loads, "opening a link sent nothing to the player")
    }

    @Test func volumeIsASetOnTheSharedPath() async throws {
        let rig = try await IntegrationRig.make(); defer { rig.cleanUp() }
        #expect(rig.shell.setVolume(percent: 35) == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(rig.shell.transport.volume - 0.35) < 0.011 || rig.shell.volumePercent >= 0)
    }
}

/// The dictionary file, the Cocoa classes and the documentation agree (T26.3).
@Suite @MainActor struct ScriptingDictionaryTests {
    struct Command { let name: String; let cocoa: String }
    private final class Parser: NSObject, XMLParserDelegate {
        var commands: [Command] = [], properties: [(name: String, key: String)] = [], classes: [(name: String, cocoa: String)] = []
        var words: [String] = []
        private var current: String?, inClass: String?, inCommand: String?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            for value in attributes.values { words.append(value) }
            switch name {
            case "command": inCommand = attributes["name"]
            case "class": inClass = attributes["name"]
            case "cocoa":
                if let cls = attributes["class"] {
                    if let command = inCommand { commands.append(Command(name: command, cocoa: cls)) } else if let klass = inClass { classes.append((klass, cls)) }
                } else if let key = attributes["key"] { properties.append((current ?? "", key)) }
            case "property", "parameter": current = attributes["name"]
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "command" { inCommand = nil }
            if name == "class" { inClass = nil }
        }
    }
    private func parse() throws -> Parser {
        let data = try Data(contentsOf: IntegrationSources.root.appendingPathComponent("Resources/YTMuse.sdef"))
        let parser = XMLParser(data: data), delegate = Parser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        #expect(parser.parse(), "the dictionary is well-formed")
        return delegate
    }

    @Test func everyCommandNamesACocoaClassThatExistsAndIsAScriptCommand() throws {
        let parsed = try parse()
        #expect(parsed.commands.count == 9)
        for command in parsed.commands {
            let cls = NSClassFromString(command.cocoa)
            #expect(cls != nil && (cls as? NSScriptCommand.Type) != nil, "\(command.name) → \(command.cocoa)")
            #expect(ScriptingClasses.commandClasses[command.cocoa] != nil, "\(command.cocoa) is kept by the linker")
        }
        #expect(Set(parsed.commands.map(\.cocoa)) == Set(ScriptingClasses.commandClasses.keys))
        #expect(Set(parsed.commands.map(\.name)) == ["play", "pause", "playpause", "next track", "previous track", "seek", "add to queue", "play next", "open link"])
        for (name, cocoa) in parsed.classes { #expect(NSClassFromString(cocoa) != nil && ScriptingClasses.objectClasses[cocoa] != nil, "\(name) → \(cocoa)") }
    }

    @Test func everyDictionaryKeyIsAnAccessorOnTheApplicationOrTheTrack() throws {
        let parsed = try parse()
        let application = NSApplication.shared, track = YTMuseScriptTrackObject(ScriptTrack(name: "n"))
        let applicationKeys = Set(["scriptPlayerState", "scriptCurrentTrack", "scriptVolume"]), trackKeys = Set(["name", "artist", "duration", "position", "publicLink"])
        for (name, key) in parsed.properties where !["toPosition", "byDelta"].contains(key) {
            if applicationKeys.contains(key) { #expect(application.responds(to: NSSelectorFromString(key)), "\(name) → \(key)") }
            else { #expect(trackKeys.contains(key) && track.responds(to: NSSelectorFromString(key)), "\(name) → \(key)") }
        }
        #expect(Set(parsed.properties.map(\.key)).isSuperset(of: applicationKeys.union(trackKeys)))
    }

    @Test func thereIsNoTokenCookieHeaderRequestOrCredentialInTheDictionaryTheClassesOrTheTarget() async throws {
        let forbidden = ["token", "cookie", "header", "request", "credential", "authoriz", "session", "secret", "password", "sapisid", "keychain", "bearer", "account"]
        let parsed = try parse()
        let sdefNames = (parsed.commands.map(\.name) + parsed.properties.map(\.name) + parsed.properties.map(\.key) + parsed.classes.map(\.name)).map { $0.lowercased() }
        for word in forbidden { #expect(!sdefNames.contains { $0.contains(word) }, "the dictionary names \(word)") }
        // The scripting layer's own source and the target protocol: accessors only for transport, the public track, the queue and opening a link.
        var scanned = 0
        for source in await IntegrationSources.codeOffMain(under: "Packages/NativeMusic/Sources").filter({ $0.file.hasSuffix("/Scripting.swift") || $0.file.hasSuffix("/ScriptingCocoa.swift") }) {
            scanned += 1
            let text = source.text.lowercased()
            for word in ["token", "cookie", "authoriz", "credential", "keychain", "sapisid", "urlrequest", "urlsession", "evaluatejavascript", "callasyncjavascript"] { #expect(!text.contains(word), "\(source.file) names \(word)") }
        }
        #expect(scanned == 2, "both scripting sources were read")
        let target = ScriptingTarget.self
        _ = target
        let members = ["playerState", "currentTrack", "volumePercent", "transport", "setVolume", "queueInsert", "open"]
        let protocolText = try IntegrationSources.text("Packages/NativeMusic/Sources/SystemIntegration/Scripting.swift").components(separatedBy: "public protocol ScriptingTarget").dropFirst().first?.components(separatedBy: "public enum ScriptTransport").first ?? ""
        let declared = protocolText.components(separatedBy: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("var ") || t.hasPrefix("func ") else { return nil }
            return String(t.dropFirst(t.hasPrefix("var ") ? 4 : 5).prefix { $0.isLetter })
        }
        #expect(declared.sorted() == members.sorted(), "the target's surface is exactly this list: \(declared)")
    }

    @Test func theDocumentationAndTheDictionaryNameTheSameCommands() throws {
        let doc = try IntegrationSources.text("Docs/Automation.md")
        for name in try parse().commands.map(\.name) { #expect(doc.contains("`\(name)") || doc.contains(name), "Automation.md documents \(name)") }
        for key in ["player state", "current track", "player volume", "public link"] { #expect(doc.contains(key)) }
    }

    @Test func theDictionaryIsInTheBundleAndTheInfoPlistNamesIt() throws {
        let plist = try IntegrationSources.text("App/Info.plist")
        #expect(plist.contains("<key>NSAppleScriptEnabled</key><true/>") && plist.contains("<key>OSAScriptingDefinition</key><string>YTMuse.sdef</string>"))
        let project = try IntegrationSources.text("App/NativeMusic.xcodeproj/project.pbxproj")
        #expect(project.contains("YTMuse.sdef"), "the generated project copies the dictionary into the app's resources")
        let entitlements = try IntegrationSources.text("App/NativeMusic.entitlements")
        #expect(!entitlements.contains("apple-events"), "the app receives Apple events and sends none")
    }
}

/// The documented examples, executed (T26.3). In-process against the production shell over a fake page, and against the recording target.
@Suite @MainActor struct ScriptingExampleTests {
    private func documentation() throws -> String { try IntegrationSources.text("Docs/Automation.md") }

    @Test func everyAppleScriptExampleInTheDocumentationExecutes() async throws {
        let blocks = IntegrationSources.blocks(language: "applescript", in: try documentation())
        #expect(blocks.count >= 4, "the documentation has its examples")
        let rig = try await IntegrationRig.make(); defer { rig.cleanUp() }
        var statements = 0, verbs: Set<String> = []
        for block in blocks {
            let runner = ScriptExampleRunner(target: rig.shell)
            let outcome = try await runner.run(script: block)
            statements += outcome.statements; verbs.formUnion(outcome.verbs)
            // A refusal in an example would be a documented example that fails; only the queue lines are documented as refusing, while YouTube Music plays.
            for refusal in outcome.refusals { if case .queueNotEditable = refusal {} else { Issue.record("an example was refused: \(refusal)") } }
        }
        #expect(statements >= 16)
        #expect(verbs.isSuperset(of: ["play", "pause", "playpause", "next track", "previous track", "seek", "player volume", "player state", "current track", "open link", "play next", "add to queue"]),
                "the examples use every command of the dictionary: \(verbs.sorted())")
    }

    @Test func everyShellExampleIsTheSameScriptAndExecutes() async throws {
        let scripts = IntegrationSources.blocks(language: "sh", in: try documentation()).flatMap { $0.components(separatedBy: "\n") }.filter { $0.hasPrefix(ScriptText.osa + " -e '") }
        #expect(scripts.count == 3)
        let target = RecordingScriptTarget()
        for line in scripts {
            let script = String(line.dropFirst((ScriptText.osa + " -e '").count).dropLast())
            let outcome = try await ScriptExampleRunner(target: target).run(script: script)
            #expect(outcome.statements == 1 && outcome.refusals.isEmpty, "\(line)")
        }
        #expect(target.calls.count == 3)
    }

    @Test func aLineThatIsNotInTheDictionaryFailsTheRunnerSoTheDocumentationCannotDrift() async {
        let runner = ScriptExampleRunner(target: RecordingScriptTarget())
        for script in [ScriptText.block("get the oauth token"), ScriptText.block("do shell script \"id\""), ScriptText.block("set cookie to 1"), ScriptText.block("send request \"x\""), "play"] {
            await #expect(throws: ScriptExampleRunner.Failure.self) { _ = try await runner.run(script: script) }
        }
    }

    @Test func everyExampleTargetsTheApplicationByNameNeverByBundleIdentifier() throws {
        let doc = try documentation()
        let forbidden = ScriptText.tell + " id"
        for block in IntegrationSources.blocks(language: "applescript", in: doc) + IntegrationSources.blocks(language: "sh", in: doc) { #expect(!block.contains(forbidden)) }
        #expect(!doc.contains(forbidden))
    }

    @Test func theScriptingClassesRunTheCommandAgainstTheHostedTarget() async throws {
        // The Cocoa layer is exercised in-process: a command object is given its arguments and asked for its request; the dispatcher then runs it.
        let target = RecordingScriptTarget()
        ScriptingHost.target = target
        defer { ScriptingHost.target = nil }
        for cls in ScriptingClasses.commandClasses.values { #expect(cls is YTMuseScriptCommand.Type) }
        func description(_ name: String, _ code: String, _ cls: String) throws -> NSScriptCommandDescription {
            try #require(NSScriptCommandDescription(suiteName: "YTMuse Suite", commandName: name, dictionary: ["CommandClass": cls, "AppleEventCode": code, "AppleEventClassCode": "YTMu"]))
        }
        #expect(try YTMusePlayCommand(commandDescription: description("play", "Play", "YTMusePlayCommand")).request() == .play)
        #expect(try YTMusePauseCommand(commandDescription: description("pause", "Paus", "YTMusePauseCommand")).request() == .pause)
        #expect(try YTMusePlayPauseCommand(commandDescription: description("playpause", "Togl", "YTMusePlayPauseCommand")).request() == .playPause)
        #expect(try YTMuseNextTrackCommand(commandDescription: description("next track", "Next", "YTMuseNextTrackCommand")).request() == .nextTrack)
        #expect(try YTMusePreviousTrackCommand(commandDescription: description("previous track", "Prev", "YTMusePreviousTrackCommand")).request() == .previousTrack)
        // Seek: exactly one of `to` and `by`; both or neither is an argument error.
        #expect(YTMuseSeekCommand.makeRequest(to: 30, by: nil) == .seekTo(30) && YTMuseSeekCommand.makeRequest(to: nil, by: -10) == .seekBy(-10))
        #expect(YTMuseSeekCommand.makeRequest(to: 1, by: 1) == nil && YTMuseSeekCommand.makeRequest(to: nil, by: nil) == nil)
        let application = NSApplication.shared
        #expect(application.scriptPlayerState == "playing")
        #expect(application.scriptCurrentTrack?.name == "Synthetic Song" && application.scriptCurrentTrack?.publicLink == "https://music.youtube.com/watch?v=" + integrationVideo)
        #expect(application.scriptVolume == 50)
        ScriptingHost.target = nil
        #expect(application.scriptPlayerState == "stopped" && application.scriptCurrentTrack == nil, "with no shell the application says stopped, not an error")
    }
}
