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
        Rule(name: "invoking the Shortcuts app", pattern: #"shortcuts://|x-apple-shortcuts|ShortcutsLink|WFWorkflow|tell\s+(?:app(?:lication)?\s+(?:id\s+)?|process\s+)?\\*[\"']*(?:Shortcuts|com\.apple\.shortcuts)|(?:-a|-b)\s+[\"']?(?:Shortcuts|com\.apple\.shortcuts)\b|\bShortcuts Events\b|\bApplication\(\s*[\"']Shortcuts|com\.apple\.shortcuts\.events"#, planted: "open shortcuts://run-shortcut?name=x"),
        Rule(name: "the shortcuts command line", pattern: #"(?m)(^|[;&|`(\s\"'])(/usr/bin/)?shortcuts\s+(run|view|list|sign)\b"#, planted: "shortcuts run \"Pause\""),
        // TH1: the same command as an argument LIST (Python `subprocess.run(["shortcuts", "run", ...])`, a Swift `Process` with `executableURL` and `arguments`),
        // where the words are separated by quotes and commas and the text rule above sees no whitespace.
        Rule(name: "the shortcuts command as an argument list", pattern: #"[\"']shortcuts[\"']\s*,\s*(?:[\"'](?:run|view|list|sign)[\"']|[A-Za-z_$][\w.$]*\s*[,\])])|/usr/bin/shortcuts\b"#, planted: "subprocess.run([\"shortcuts\", \"run\", \"Pause\"])"),
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
    /// The largest file the sweep reads as text (the launch guard's cap). TH5 (TH4 critic L-d): a larger one is REPORTED, not skipped (unless it is a known binary type).
    nonisolated static let maximumBytes = 2_000_000
    /// One file of the sweep. TH4 (L4): a file that cannot be read as UTF-8 text is reported unless it is a known binary type (the list is shared with the launch guard).
    /// TH5: so is a file over `maximumBytes`; `swept` no longer drops it before this point.
    nonisolated static func findings(inFile url: URL, swift: Bool) -> [String] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maximumBytes, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return GuardBinaryFiles.isKnownBinary(url) ? [] : ["\(url.lastPathComponent): \(GuardBinaryFiles.unreadableRule)"]
        }
        return violations(in: text, file: url.lastPathComponent, swift: swift)
    }
    nonisolated static let scriptExtensions: Set<String> = ["py", "sh", "zsh", "bash", "command", "applescript", "scpt", "js", "rb", "pl", "swift", "m", "mm"]
    /// Swift everywhere, and every script-like file under scripts/, Tools/, Fixtures/ and the test trees (extensionless ones included).
    nonisolated static var swept: [(url: URL, swift: Bool)] {
        let swiftRoots = ["Packages/NativeMusic/Sources", "Packages/NativeMusic/Tests", "Tests", "App/Sources", "Extensions/Sources"]
        var files: [(URL, Bool)] = swiftRoots.flatMap { IntentSources.swiftFiles(under: $0) }.map { ($0, true) }
        for root in ["scripts", "Tools", "Fixtures", "Tests", "App", "Extensions"] {
            let base = IntentSources.root.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true, !url.path.contains("/.build/"), !url.path.contains(".xcodeproj/") else { continue }
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
                found += Self.findings(inFile: url, swift: swift)
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
    @Test func theSweepReportsAFileItCannotReadUnlessItIsAKnownBinary() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-th4-donation-unreadable-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let odd = scratch.appendingPathComponent("hidden.py"), binary = scratch.appendingPathComponent("binary.sh"), fine = scratch.appendingPathComponent("fine.sh")
        try Data([0xFF, 0xFE, 0x73, 0x68, 0x80, 0x81]).write(to: odd)
        try (Data("bplist00".utf8) + Data([0, 1, 2, 0x80])).write(to: binary)
        try Data("echo hello\n".utf8).write(to: fine)
        #expect(Self.findings(inFile: odd, swift: false) == ["hidden.py: \(GuardBinaryFiles.unreadableRule)"])
        #expect(Self.findings(inFile: binary, swift: false).isEmpty && Self.findings(inFile: fine, swift: false).isEmpty)
    }
    /// TH5 (TH4 critic L-d): a script-like file over 2 MB is reported by this guard as well (it used to be dropped by the sweep before it was read). Plants: a clean-text
    /// file just over the cap, and one that would itself violate a rule (a donate call); controls: a file exactly at the cap and a known binary over it.
    /// The files are written and read off the main actor (the suite's): four files of about 2 MB. On the main actor it held the main thread for 5 s alone
    /// and up to 11 s in the full PlaybackTests run, and every main-actor test beside it stalled with it (a radio queue update missed its deadline,
    /// AVFoundation could not report an item ready in time). A synchronous `nonisolated` test would still run on the thread that calls it.
    @Test func theSweepReportsAFileOverTwoMegabytesInsteadOfSkippingIt() async throws {
        struct Read: Sendable { var onMain = true, failure: String?, over: [String] = [], hidden: [String] = [], exact: [String] = [], binary: [String] = [] }
        let read = await LifecycleSources.offMain { () -> Read in
            var read = Read(onMain: Thread.isMainThread)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-th5-donation-size-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let over = scratch.appendingPathComponent("big.py"), hidden = scratch.appendingPathComponent("hidden.sh"), exact = scratch.appendingPathComponent("exact.sh"), binary = scratch.appendingPathComponent("big.bin.sh")
            func filler(_ count: Int) -> Data { Data(String(repeating: "# comment\n", count: count / 10 + 1).utf8).prefix(count) }
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                try filler(2_000_001).write(to: over)
                try (Data("x.donate(result: r)\n".utf8) + filler(2_000_000)).write(to: hidden)
                try filler(2_000_000).write(to: exact)
                try (Data("bplist00".utf8) + Data(repeating: 0, count: 2_000_000)).write(to: binary)
            } catch { read.failure = "\(error)"; return read }
            read.over = Self.findings(inFile: over, swift: false); read.hidden = Self.findings(inFile: hidden, swift: false)
            read.exact = Self.findings(inFile: exact, swift: false); read.binary = Self.findings(inFile: binary, swift: false)
            return read
        }
        #expect(!read.onMain, "the files are written and read off the main thread the other tests share")
        #expect(read.failure == nil, "\(read.failure ?? "")")
        #expect(Self.maximumBytes == 2_000_000, "the launch guard's cap")
        #expect(read.over == ["big.py: \(GuardBinaryFiles.unreadableRule)"], "a text file over the cap is reported")
        #expect(read.hidden == ["hidden.sh: \(GuardBinaryFiles.unreadableRule)"], "a donate call hidden in a file over the cap is not silently unread")
        #expect(read.exact.isEmpty, "control: exactly at the cap is read, and clean")
        #expect(read.binary.isEmpty, "control: a known binary type over the cap is not a finding")
        #expect(GuardBinaryFiles.unreadableRule.contains("2 MB"), "the rule's wording names the size")
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
            // TH4: the command inside a quoted string (os.system, `-c`, shell=True), the Shortcuts process addressed through System Events or by a bare tell,
            // the open command with -a or -b, and Objective-C files (which this sweep did not read).
            ("o.py", "import os\nos.system(\"\(shortcuts) run Pause\")\n", false),
            ("p.sh", "sh -c '\(shortcuts) run Pause'\n", false),
            ("q.py", "subprocess.run(\"\(shortcuts) list\", shell=True)\n", false),
            ("r.applescript", "\(tell) \"System Events\"\n  tell process \"Shortcuts\"\n    click\n", false),
            ("s.applescript", "tell \"Shortcuts\" to activate\n", false),
            ("t.sh", "op" + "en -a Shortcuts\n", false),
            ("u.sh", "op" + "en -b com.apple.\(shortcuts)\n", false),
            ("v.m", "id c = @\"x\"; [x updateAppShortcut" + "Parameters];\n", false),
            ("w.mm", "id m = [Intent" + "DonationManager new];\n", false),
            // TH4 (L2): the verb held in a variable.
            ("x.py", "import subprocess\nsubprocess.run([\"\(shortcuts)\", verb, name])\n", false),
            ("y.py", "subprocess.run(['\(shortcuts)',action,'x'], check=True)\n", false),
            ("z.swift", "let p = Process(); p.arguments = [\"\(shortcuts)\", verb]\n", true),
        ]
        for plant in plants { #expect(!Self.violations(in: plant.text, file: plant.file, swift: plant.swift).isEmpty, Comment(rawValue: "NOT FLAGGED: \(plant.file): \(plant.text)")) }
        let controls: [(file: String, text: String, swift: Bool)] = [
            ("c1.sh", "echo \"the \(shortcuts) declared in the bundle are listed in the docs\"\n", false),
            ("c2.py", "subprocess.run([\"ls\", \"-l\"])\nprint(\"run\", \"list\")\n", false),
            ("c3.applescript", "\(tell) \(application) \"Finder\" to activate\n", false),
            ("c4.swift", "let names = [\"\(shortcuts)\"]\nlet verbs = [\"run\"]\n", true),
            ("c5.js", "const f = Appli" + "cation(\"Finder\");\n", false),
            ("c6.sh", "echo 'run the list of \(shortcuts) later'; " + "op" + "en -a Finder\n", false),
            ("c7.applescript", "tell process \"Finder\" to activate\n", false),
            ("c8.m", "NSString *note = @\"nothing here\"; [x reload];\n", false),
            ("c9.py", "names = [\"\(shortcuts)\", \"widgets\"]\nsubprocess.run([\"ls\", verb])\n", false),
        ]
        for control in controls { #expect(Self.violations(in: control.text, file: control.file, swift: control.swift).isEmpty, Comment(rawValue: "control flagged: \(control.file)")) }
        // TH4: the sweep reads Objective-C and scripts too (a list that names the extensions is what makes the plants above reachable from the repository walk).
        #expect(Self.scriptExtensions.isSuperset(of: ["m", "mm", "py", "sh", "applescript", "swift"]), "\(Self.scriptExtensions.sorted())")
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
    @Test func productionNeverInstallsASinkAndTheDefaultDropsEverything() async throws {
        // Every production source is read off the main actor, so the sweep never stalls the main-actor tests beside it.
        let (read, installs) = await LifecycleSources.offMain { () -> (Int, [String]) in
            var read = 0, installs: [String] = []
            for url in IntentSources.swiftFiles(under: "Packages/NativeMusic/Sources") + IntentSources.swiftFiles(under: "App/Sources") {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { installs.append("\(url.lastPathComponent) could not be read"); continue }
                read += 1
                for line in text.split(separator: "\n") where line.contains(".donations =") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    installs.append("\(url.lastPathComponent) installs a donation sink: \(line)")
                }
            }
            return (read, installs)
        }
        #expect(read > 100, "the sweep read the production sources (\(read) files)")
        #expect(installs.isEmpty, "\(installs)")
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
