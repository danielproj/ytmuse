import Foundation
import Testing
@testable import SystemIntegration

/// T24.3 / the W24 real-data rule: nothing in a test donates an intent or an interaction to the system, refreshes the App Shortcuts parameters or the
/// relevant intents, invokes Shortcuts or Siri, or writes the account holder's Shortcuts or Siri suggestions. The real APIs are named NOWHERE in the
/// repository (Swift sources, every test target, the UI tests, the app, and scripts / tools / fixtures in shell, Python or AppleScript); donations go to an
/// injected sink that keeps or drops them.
@Suite @MainActor struct IntentDonationGuardTests {
    struct Rule: Sendable {
        let name: String
        let pattern: String
        let planted: String          // a line the rule must flag
        var swiftOnly = false
    }
    /// The calls that reach the system's donation, Shortcuts or Siri state. Rule 2-5 are the SDK's OWN donation paths on an `AppIntent` value:
    /// `donate()` / `donate(result:)`, and `callAsFunction`, which **donates by default** when an intent is invoked like a function (`intent()`).
    nonisolated static let rules: [Rule] = [
        Rule(name: "the system's intent donation", pattern: #"IntentDonationManager|IntentDonationIdentifier"#, planted: "let x = IntentDonationManager.shared"),
        Rule(name: "refreshing the account holder's App Shortcuts", pattern: #"updateAppShortcutParameters"#, planted: "ResumeShortcuts.updateAppShortcutParameters()"),
        // NAME-AGNOSTIC (rework 2): every `donate(` in Swift is a violation unless it is on the allowlist below (`donateCallsOutsideTheAllowlist`).
        Rule(name: "an intent invoked as a constructor call (donates by default)", pattern: #"callAsFunction|Intent\([^()]*\)\("#,
             planted: "try await PausePlaybackIntent()()", swiftOnly: true),
        Rule(name: "an intent variable invoked as a function", pattern: #"(?:\b(?:try|await)\s+)+(?:[a-z]\w*[iI]|i)ntent\w*\s*\("#, planted: "_ = try await intent()", swiftOnly: true),
        Rule(name: "an intent call that names donation", pattern: #"\(\s*donate\s*:"#, planted: "try await intent(donate: true)", swiftOnly: true),
        Rule(name: "relevant intents", pattern: #"RelevantIntentManager|\bRelevantIntent\b|\bRelevantContext\b"#, planted: "RelevantIntentManager.shared.updateRelevantIntents([])"),
        Rule(name: "SiriKit interaction donation", pattern: #"INInteraction|INVoiceShortcut|INShortcut|\bimport Intents\b|requestSiriAuthorization"#, planted: "import Intents"),
        Rule(name: "activity-based Siri suggestions", pattern: #"isEligibleForPrediction"#, planted: "activity.isEligibleForPrediction = true"),
        Rule(name: "invoking the Shortcuts app", pattern: #"shortcuts://|x-apple-shortcuts|ShortcutsLink|WFWorkflow|tell\s+app(?:lication)?\s+(?:id\s+)?\\*[\"']*(?:Shortcuts|com\.apple\.shortcuts)|\bShortcuts Events\b|\bApplication\(\s*[\"']Shortcuts|com\.apple\.shortcuts\.events"#, planted: "open shortcuts://run-shortcut?name=x"),
        Rule(name: "the shortcuts command line", pattern: #"(?m)(^|[;&|`(\s])(/usr/bin/)?shortcuts\s+(run|view|list|sign)\b"#, planted: "shortcuts run \"Pause\""),
        // TH1: the same command as an argument LIST (Python `subprocess.run(["shortcuts", "run", ...])`, a Swift `Process` with `executableURL` and `arguments`),
        // where the words are separated by quotes and commas and the text rule above sees no whitespace.
        Rule(name: "the shortcuts command as an argument list", pattern: #"[\"']shortcuts[\"']\s*,\s*[\"'](?:run|view|list|sign)[\"']|/usr/bin/shortcuts\b"#, planted: "subprocess.run([\"shortcuts\", \"run\", \"Pause\"])"),
        Rule(name: "Siri / Shortcuts preferences", pattern: #"defaults\s+(write|delete)\s+com\.apple\.(Siri|assistant|shortcuts)"#, planted: "defaults write com.apple.Siri x 1"),
    ]
    /// Files that may NAME a forbidden call because they are the rule itself.
    nonisolated static let exempt: Set<String> = ["IntentDonationGuardTests.swift", "check-intent-donations.py"]
    /// Any `donate(` call in Swift whose line is not one of the app's own: its own declarations (`func donate(`), the sink call (`donations.donate(`) and the hub's gate
    /// called with a leading-dot command (`hub.donate(.play(...), origin: ...)`). `action.donate()`, `PausePlaybackIntent().donate()`, `x.donate(result:)` and a bare
    /// `donate()` are none of those, whatever the variable is called.
    nonisolated static func donateCallsOutsideTheAllowlist(in text: String) -> [String] {
        var found: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), !code.hasPrefix("///"), code.range(of: #"(?<![A-Za-z0-9_])donate\s*\("#, options: .regularExpression) != nil else { continue }
            var rest = code
            for allowed in [#"func\s+donate\s*\("#, #"\bdonations\.donate\s*\("#, #"\b(?:hub|IntentHub\.\w+)\.donate\s*\(\s*\."#, #"(?<![.\w])(?:await\s+)?donate\s*\(\s*command\s*[,:]"#] {
                rest = rest.replacingOccurrences(of: allowed, with: "", options: .regularExpression)
            }
            if rest.range(of: #"(?<![A-Za-z0-9_])donate\s*\("#, options: .regularExpression) != nil { found.append(code) }
        }
        return found
    }
    nonisolated static func violations(in text: String, file: String, swift: Bool) -> [String] {
        guard !exempt.contains(file) else { return [] }
        var found = rules.filter { (swift || !$0.swiftOnly) && text.range(of: $0.pattern, options: .regularExpression) != nil }.map { "\(file): \($0.name)" }
        if swift, !donateCallsOutsideTheAllowlist(in: text).isEmpty { found.append("\(file): a donate( call outside the allowlist") }
        return found
    }
    nonisolated static let scriptExtensions: Set<String> = ["py", "sh", "zsh", "bash", "command", "applescript", "scpt", "js", "rb", "pl", "swift"]
    /// Swift everywhere, and every script-like file under scripts/, Tools/, Fixtures/ and the test trees (extensionless ones included).
    nonisolated static var swept: [(url: URL, swift: Bool)] {
        let swiftRoots = ["Packages/NativeMusic/Sources", "Packages/NativeMusic/Tests", "Tests", "App/Sources", "Extensions/Sources"]
        var files: [(URL, Bool)] = swiftRoots.flatMap { IntentSources.swiftFiles(under: $0) }.map { ($0, true) }
        for root in ["scripts", "Tools", "Fixtures", "Tests", "App", "Extensions"] {
            let base = IntentSources.root.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 2_000_000, !url.path.contains("/.build/"), !url.path.contains(".xcodeproj/") else { continue }
                let ext = url.pathExtension
                if ext == "swift" { continue }
                if scriptExtensions.contains(ext) || (ext.isEmpty && ["scripts", "Tools"].contains(root)) { files.append((url, false)) }
            }
        }
        return files
    }

    @Test func noSourceNoTestTargetAndNoScriptCanReachADonationShortcutsOrSiriCall() async throws {
        // The sweep reads the whole repository: off the main actor, so it never delays the timing tests beside it.
        let (files, found) = await LifecycleSources.offMain { () -> ([(url: URL, swift: Bool)], [String]) in
            let files = Self.swept
            var found: [String] = []
            for (url, swift) in files {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                found += Self.violations(in: text, file: url.lastPathComponent, swift: swift)
            }
            return (files, found)
        }
        #expect(files.count > 250, "the sweep covers the whole repository, not nothing: \(files.count)")
        #expect(files.contains { $0.url.lastPathComponent == "IntentChannelTests.swift" } && files.contains { $0.url.lastPathComponent == "NativeMusicShortcuts.swift" }
                && files.contains { $0.url.path.contains("/Tests/NativeMusicUITests/") } && files.contains { $0.url.lastPathComponent == "NowPlaying.swift" })
        let scripts = files.filter { !$0.swift }.map(\.url.lastPathComponent)
        #expect(scripts.contains("test.sh") && scripts.contains("check-intents.py") && scripts.contains("generate-project.py"), "scripts are swept: \(scripts.count) files")
        #expect(found.isEmpty, "\(found)")
    }
    @Test func theRuleFlagsEachForbiddenCallAndPassesTheCodeThatIsLegitimate() {
        for rule in Self.rules {
            #expect(!Self.violations(in: rule.planted, file: "Planted.swift", swift: true).isEmpty, Comment(rawValue: "swift: " + rule.name + " / " + rule.planted))
            if !rule.swiftOnly { #expect(!Self.violations(in: rule.planted, file: "planted.py", swift: false).isEmpty, Comment(rawValue: "script: " + rule.name)) }
        }
        // The critic's three plants: two are read by name-agnostic text rules, the third (`p()`) leaves no text to match and is the symbol check's job.
        for planted in ["_ = try await action.donate()", "let r = PausePlaybackIntent().donate()", "try await PausePlaybackIntent()()", "x.donate(result: r)", "donate()"] {
            #expect(!Self.violations(in: planted, file: "Planted.swift", swift: true).isEmpty, Comment(rawValue: planted))
        }
        #expect(Self.violations(in: "let p = PausePlaybackIntent(); try await p()", file: "Planted.swift", swift: true).isEmpty, "the text rules cannot see `p()`: the symbol check (check-intent-donations.py) does")
        for clean in ["hub.donate(.play(song), origin: .userInterface, scope: scope, outcome: .done(\"x\"))", "await donations.donate(IntentDonation(command: \"play\", scope: scope))",
                      "func donate(_ donation: IntentDonation) async {}", "/// donate() is gated", "// action.donate() would donate", "@discardableResult func donate(_ command: IntentCommand, origin: IntentOrigin) async -> Bool {}", "await donate(command, origin: .intent, scope: nil, outcome: outcome)", "AppShortcut(intent: ResumePlaybackIntent(), phrases: [\"Play \\(.applicationName)\"])",
                      "let hub = IntentHub(); hub.donations = RecordingDonationSink()", "try await perform(PausePlaybackIntent(), in: hub)", "_ = try await ResumePlaybackIntent().perform()",
                      "var intent = SearchInAppIntent(); intent.criteria = x", "echo \"shortcuts are declared in the bundle\""] {
            #expect(Self.violations(in: clean, file: "Clean.swift", swift: true).isEmpty, Comment(rawValue: clean))
            #expect(Self.violations(in: clean, file: "clean.sh", swift: false).isEmpty, Comment(rawValue: clean))
        }
        #expect(Self.violations(in: "IntentDonationManager.shared", file: "IntentDonationGuardTests.swift", swift: true).isEmpty, "only the rule's own file may name them")
    }
    /// TH1 (guard backlog): the ways to reach the Shortcuts app or its command line that the first plants did not cover, each in the kind of file that would hold it,
    /// and harmless controls that must pass. Built from pieces so this file does not itself hold a form it forbids (it is exempt by name, but the pieces keep the
    /// plants honest when the exemption is ever narrowed).
    @Test func everyWayToTellShortcutsOrRunItsCommandLineIsFlaggedAndTheControlsAreNot() {
        let tell = "te" + "ll", application = "applic" + "ation", shortcuts = "short" + "cuts", events = "Short" + "cuts Events"
        let plants: [(file: String, text: String, swift: Bool)] = [
            ("a.applescript", "\(tell) \(application) \"Shortcuts\"\n  run shortcut \"Pause\"\nend \(tell)\n", false),
            ("b.applescript", "\(tell) \(application) \"\(events)\"\n  run shortcut \"Pause\"\nend \(tell)\n", false),
            ("c.sh", "osa" + "script -e '\(tell) \(application) \"Shortcuts\" to run shortcut \"Pause\"'\n", false),
            ("d.sh", "osa" + "script -e \"\(tell) app \\\"Shortcuts\\\" to activate\"\n", false),
            ("e.applescript", "\(tell) \(application) id \"com.apple.\(shortcuts)\"\n  activate\nend \(tell)\n", false),
            ("f.applescript", "\(tell) \(application)\n  \"Shortcuts\"\n", false),
            ("g.js", "const s = Appli" + "cation(\"Shortcuts\"); s.run();\n", false),
            ("h.py", "import subprocess\nsubprocess.run([\"\(shortcuts)\", \"run\", \"Pause\"], check=True)\n", false),
            ("i.py", "subprocess.check_output([ '\(shortcuts)' , 'list' ])\n", false),
            ("j.py", "subprocess.Popen([\"/usr/bin/\(shortcuts)\", \"view\", name])\n", false),
            ("k.swift", "let p = Process(); p.executableURL = URL(fileURLWithPath: \"/usr/bin/\(shortcuts)\"); p.arguments = [\"run\", \"Pause\"]\n", true),
            ("l.swift", "let p = Process(); p.arguments = [\"\(shortcuts)\", \"run\", \"Pause\"]\n", true),
            ("m.sh", "\(shortcuts) run \"Pause\"\n", false),
            ("n.sh", "cd x && /usr/bin/\(shortcuts) list\n", false),
        ]
        for plant in plants { #expect(!Self.violations(in: plant.text, file: plant.file, swift: plant.swift).isEmpty, Comment(rawValue: "NOT FLAGGED: \(plant.file): \(plant.text)")) }
        let controls: [(file: String, text: String, swift: Bool)] = [
            ("c1.sh", "echo \"the \(shortcuts) declared in the bundle are listed in the docs\"\n", false),
            ("c2.py", "subprocess.run([\"ls\", \"-l\"])\nprint(\"run\", \"list\")\n", false),
            ("c3.applescript", "\(tell) \(application) \"Finder\" to activate\n", false),
            ("c4.swift", "let names = [\"\(shortcuts)\"]\nlet verbs = [\"run\"]\n", true),
            ("c5.js", "const f = Appli" + "cation(\"Finder\");\n", false),
        ]
        for control in controls { #expect(Self.violations(in: control.text, file: control.file, swift: control.swift).isEmpty, Comment(rawValue: "control flagged: \(control.file)")) }
    }
    /// The three plants the critic named, compiled and read at the symbol level, and the real build output scanned (the T24 runner runs the same script over
    /// the package objects and the built app).
    @Test func theSymbolCheckFlagsActionDonateTheCallExpressionAndPDirectlyAndTheBuildIsClean() async throws {
        let (status, output) = await LifecycleSources.offMain { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", IntentSources.root.appendingPathComponent("scripts/check-intent-donations.py").path, "--self-test"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            do { try process.run() } catch { return (-1, "\(error)") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        #expect(status == 0 && output.contains("action.donate(), PausePlaybackIntent()() and p()"), "\(output)")
    }
    @Test func productionNeverInstallsASinkAndTheDefaultDropsEverything() throws {
        for url in IntentSources.swiftFiles(under: "Packages/NativeMusic/Sources") + IntentSources.swiftFiles(under: "App/Sources") {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains(".donations =") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                Issue.record("\(url.lastPathComponent) installs a donation sink: \(line)")
            }
        }
        #expect(IntentHub().donations is DiscardingDonationSink)
    }
}

/// T24.3: an intent never donates; only a successful action in the app's own UI could, and what it donates names no title, query or identifier.
@Suite @MainActor struct IntentDonationBehaviourTests {
    @Test func runningEveryIntentThroughTheChannelDonatesNothing() async throws {
        let hub = IntentHub(), channel = RecordingIntentChannel(), sink = RecordingDonationSink()
        hub.startupTimeout = .milliseconds(100); hub.install(channel); hub.donations = sink
        let scope = channel.scope!
        for command in [IntentCommand.resume, .pause, .toggle, .next, .previous, .seek(to: 3), .play(intentMedia(scope: scope)), .playSearch("x"), .search("x"),
                        .rate(.like, of: nil), .save(of: nil), .showQueue, .showPlayer, .sleepTimer(.off)] {
            #expect(await hub.run(command).isDone, Comment(rawValue: command.name))
        }
        #expect(sink.donations.isEmpty, "an intent is not a reason to donate")
    }
    @Test func aSuccessfulActionInTheUIDonatesItsNameAndScopeOnlyAndAFailureOrAnIntentDoesNot() async {
        let hub = IntentHub(), sink = RecordingDonationSink(); hub.donations = sink
        let scope = IntentScope(accountID: UUID(), generation: 2)
        let song = intentMedia(.song, "Private Title", scope: scope)
        #expect(await hub.donate(.play(song), origin: .userInterface, scope: scope, outcome: .done("Playing Private Title.")))
        #expect(await !hub.donate(.play(song), origin: .userInterface, scope: scope, outcome: .refused(.advertisement)))
        #expect(await !hub.donate(.play(song), origin: .intent, scope: scope, outcome: .done("ok")))
        #expect(await !hub.donate(.play(song), origin: .userInterface, scope: nil, outcome: .done("ok")))
        #expect(sink.donations == [IntentDonation(command: "play", scope: scope)])
        #expect(!"\(sink.donations)".contains("Private Title") && !"\(sink.donations)".contains(song.encoded), "no title, query or identifier leaves the app")
    }
}
