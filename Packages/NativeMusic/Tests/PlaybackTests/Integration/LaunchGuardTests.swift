import CryptoKit
import Foundation
import Testing
@testable import AppShell

/// Real-data safety, rework 1 (addendum 4 and the operator's rule): nothing in a test, script, tool, app-target file or harness artifact may launch or address YTMuse
/// from outside an isolated instance that the test itself started.
///
/// Why: Debug builds fall back to scratch storage when they lose their environment, but a RELEASE build always uses the account holder's real stores, and it
/// shares the bundle identifier and the name with the Debug app. LaunchServices resolves a name, a bundle identifier or the `ytmuse:` scheme to whichever copy it
/// finds first, and starts one that is not running. So the positive rule is: the only ways to reach the app are `XCUIApplication` (which the UI tests launch with
/// the isolation environment) and the process-id descriptor of an instance they launched, and only inside `Tests/NativeMusicUITests`. Everything that could name
/// the app another way is a finding, whatever the file is called.
enum LaunchGuard {
    struct Finding: Equatable, CustomStringConvertible {
        let file: String, rule: String
        var description: String { "\(file): \(rule)" }
    }
    /// Directories swept (repository-relative). `artifacts/harness` holds this node's own mutation and UI scripts.
    static let directories = ["Packages/NativeMusic/Tests", "Tests", "scripts", "App", "Extensions", "Tools", "artifacts/harness"]
    /// Scripts have many extensions or none: a file with one of these, or with no extension at all (whatever its first line), is read as text.
    static let scriptExtensions: Set<String> = ["swift", "py", "sh", "bash", "zsh", "command", "js", "jxa", "scpt", "applescript", "rb", "pl", "m", "mm"]
    /// The only files allowed to name a forbidden thing, each with the reason and the SHA-256 of the exact bytes that were reviewed: an edit to one of them
    /// drops its exemption (and is a finding) until the new text is reviewed and the hash here is updated.
    static let allowed: [String: (sha256: String, rules: Set<String>, reason: String)] = [
        "scripts/ui-preflight.py": ("652712f1d266fb7f76226d1b260b267259c04c226fba325cd5e60e45260369c5", ["OSA command line"],
                                    "reads window positions from System Events, never the app; its application-targeting is exempt ONLY for the System Events form"),
        "artifacts/harness/nodes/W09/rework-11/candidate-f1.py": ("94d71c222e20f0ccc0f6fad03e9fb5d85e7f5710fdad3b469c432f784028ee05", ["shell open", "process open"],
                                                                  "W09's recorded evidence script (a Debug build path, isolation environment), not run again"),
        "artifacts/harness/nodes/W09/rework-11/cua/CUA-window-art-20261027T221125Z-7e7e2e66/session.py": ("4f539f7be6a6c76412a57d8d39783d91a69a2fc79cefbc01af43f69551ba959a", ["shell open", "process open"],
                                                                                                        "W09's recorded evidence script (a Debug build path), not run again"),
    ]
    /// The one file that may address System Events (and only that); nothing else about telling an application is allowed there.
    static let systemEventsFile = "scripts/ui-preflight.py"
    private static func p(_ parts: String...) -> String { parts.joined() }
    /// (name, pattern, applies to code with comments and string literals removed instead of the raw text). The patterns are built from pieces, so this file
    /// does not itself contain a form it forbids.
    static let rules: [(name: String, pattern: String, codeOnly: Bool)] = [
        ("addresses an application by tell", p("\\btell\\s+app", "(?:lication)?\\b"), false),
        ("OSA command line", p("\\bosa", "script\\b"), false),
        ("JXA application", p("\\bAppli", "cation\\s*\\(\\s*[\"']"), false),
        ("Apple event descriptor", p("NSAppleEvent", "Descriptor\\s*(?:\\.\\s*init)?\\s*\\(\\s*(?!processIdentifier)|\\[\\s*NSAppleEvent", "Descriptor\\s+(?!descriptorWithProcessIdentifier)\\w"), true),
        ("UI test addressed by bundle identifier", p("XCUIAppli", "cation\\s*(?:\\.\\s*init)?\\s*\\(\\s*bundleIdentifier"), true),
        ("Apple script API", p("NSApple", "Script\\b|OSA", "Script\\b|NSUserApple", "ScriptTask|\\bOSA", "Kit\\b|\\bAESend", "Message|AEDetermine", "PermissionToAutomate"), true),
        // NSWorkspace opening or launching, on one line, across lines (`.shared` then `.open(` on the next) or through a variable (see `workspaceViaVariable`).
        ("workspace launch", p("NSWork", "space\\s*(?:\\.\\s*\\w+|\\(\\s*\\))*\\s*\\.\\s*(?:open|openApplication|launchApplication|launchApp|urlForApplication)\\b|\\bLS", "Open\\w*|\\bLS", "Launch\\w*|NSWork", "space\\s+sharedWorkspace\\s*\\]\\s*(?:openURLs?|openApplicationAtURL|launchApplication\\w*|openFile|openTempFile|URLForApplication\\w*|urlForApplication)\\b"), true),
        // The open command by bare name or by absolute path, in a shell line, a subprocess list, a Swift Process (executableURL / launchPath) ...
        // TH1: options may be long (`--env NAME=VALUE`, `--args`) and carry a value, and the target may be a variable (`"$APP"`, `$app`, `${app}`): `open`
        // at command position with an option, a quoted word, a variable or a path as its argument is a finding, since nothing in the repository needs the system's open command.
        ("shell open", p("(?m)(?<![\\w.-])op", "en\\s+(?:-[a-zA-Z]+\\s+)*[\"']?(?:ytmuse:|YTMuse|local\\.native-music|[^\\s\"']*\\.app\\b)|(?<![\\w.-])op", "en\\s+-[ab]\\b|(?:^|[;&|(`]|\\$\\()[ \\t]*(?:(?:exec|sudo|command|nohup|time|xargs|then|do|else)[ \\t]+)*op", "en[ \\t]+(?:-|[\"'$/~.]|\\\\)"), false),
        // A subprocess argument list whose second element is a flag, a ytmuse: URL or a variable, or a command string built with a variable, starting with the command name.
        ("process open", p("[\"']op", "en[\"']\\s*,\\s*(?:[\"'](?:-|ytmuse:)|[A-Za-z_$][\\w.$]*\\s*[,\\])])|[\"']op", "en\\s+(?:-\\w|[$%{]|ytmuse:|[^\\s\"']*\\.app\\b)|[\"']op", "en\\s*[\"']\\s*(?:\\+|%|\\.format)"), false),
        // The standard library's browser launcher goes through the same LaunchServices resolution.
        ("browser launch", p("\\bweb", "browser\\b"), false),
        // ... and the absolute path itself, anywhere: nothing here needs to call the system's open command.
        ("absolute-path open", p("/usr/bin/", "open\\b"), false),
    ]
    /// `let ws = NSWorkspace.shared` (or `ws: NSWorkspace`) and then `ws.open(` / `ws.openApplication(`: the variable's name is read from the declaration.
    static func workspaceViaVariable(_ code: String) -> Bool {
        let ws = "NSWork" + "space"
        // The last alternative is the Objective-C declaration `NSWorkspace *w = [NSWorkspace sharedWorkspace];` and the call `[w openURL:u]`.
        guard let declaration = try? NSRegularExpression(pattern: "(\\w+)\\s*(?::\\s*" + ws + "\\b[^=\\n]*)?=\\s*" + ws + "\\b|(\\w+)\\s*:\\s*" + ws + "\\b|" + ws + "\\s*\\*\\s*(\\w+)\\s*=") else { return false }
        for match in declaration.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            for group in [1, 2, 3] {
                guard group < match.numberOfRanges else { continue }
                guard let range = Range(match.range(at: group), in: code) else { continue }
                let name = String(code[range])
                if code.range(of: "\\b" + name + "\\s*\\.\\s*(?:open|openApplication|launchApplication|launchApp|urlForApplication)\\b|\\[\\s*" + name + "\\s+(?:openURLs?|openApplicationAtURL|launchApplication\\w*|openFile|openTempFile|URLForApplication\\w*)\\b", options: .regularExpression) != nil { return true }
            }
        }
        return false
    }
    /// The process-id descriptor of an instance a UI test launched is the one allowed way to send it an event, and only there.
    static let processDescriptor = p("NSAppleEvent", "Descriptor\\s*(?:\\.\\s*init)?\\s*\\(\\s*processIdentifier|NSAppleEvent", "Descriptor\\s+descriptorWithProcessIdentifier")
    static let uiTestDirectory = "Tests/NativeMusicUITests/"

    /// Line continuations are joined first (`¬` in AppleScript, a trailing backslash in shell), so a form cannot be split across lines.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "¬\\s*\\n\\s*", with: " ", options: .regularExpression).replacingOccurrences(of: "\\\\\\n\\s*", with: " ", options: .regularExpression)
    }
    static func sha256(of text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func findings(inText text: String, path: String, allowList: [String: (sha256: String, rules: Set<String>, reason: String)] = LaunchGuard.allowed) -> [Finding] {
        let raw = normalized(text)
        let code = (path.hasSuffix(".swift") || path.hasSuffix(".m") || path.hasSuffix(".mm")) ? raw.components(separatedBy: "\n").map { LoginItemGuard.stripped($0) }.joined(separator: "\n") : raw
        var result: [Finding] = []
        // An allow-listed file is exempt only while its bytes are the reviewed ones.
        var granted: Set<String> = []
        if let entry = allowList[path] {
            if sha256(of: text) == entry.sha256 { granted = entry.rules } else { result.append(Finding(file: path, rule: "allow-listed file changed since it was reviewed")) }
        }
        for rule in rules where !granted.contains(rule.name) {
            var pattern = rule.pattern
            // The System Events file may tell System Events and nothing else.
            if path == systemEventsFile, rule.name == "addresses an application by tell", sha256(of: text) == allowList[path]?.sha256 { pattern += "(?!\\s*[\\\\\"']*System Events)" }
            let target = rule.codeOnly ? code : raw
            if target.range(of: pattern, options: .regularExpression) != nil { result.append(Finding(file: path, rule: rule.name)) }
        }
        if path.hasSuffix(".swift") || path.hasSuffix(".m") || path.hasSuffix(".mm"), !result.contains(where: { $0.rule == "workspace launch" }), workspaceViaVariable(code) { result.append(Finding(file: path, rule: "workspace launch")) }
        if !path.hasPrefix(uiTestDirectory), code.range(of: processDescriptor, options: .regularExpression) != nil { result.append(Finding(file: path, rule: "process-id descriptor outside the UI tests")) }
        return result
    }
    /// Every script-like file under the swept directories (and how many were read).
    static func scan(root: URL, directories: [String] = directories) -> (findings: [Finding], files: [String]) {
        var findings: [Finding] = [], files: [String] = []
        let base = root.resolvingSymlinksInPath().path
        for directory in directories {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in walker {
                if [".build", ".git", "DerivedData", ".swiftpm"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 <= 2_000_000,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let ext = url.pathExtension
                // A file with no extension is read as text whether or not it has a `#!` line (`sh scripts/x` runs it).
                guard scriptExtensions.contains(ext) || ext.isEmpty else { continue }
                let relative = url.resolvingSymlinksInPath().path.replacingOccurrences(of: base + "/", with: "")
                files.append(relative)
                findings += Self.findings(inText: text, path: relative)
            }
        }
        return (findings, files)
    }
}

@Suite struct LaunchGuardTests {
    @Test func nothingInTheRepositoryLaunchesOrAddressesTheAppOutsideAnIsolatedInstance() async {
        let (findings, files) = await LifecycleSources.offMain { LaunchGuard.scan(root: LifecycleSources.repositoryRoot) }
        #expect(files.count > 200, "the sweep read the repository (\(files.count) files)")
        for must in ["scripts/ui-preflight.py", "scripts/test.sh", "scripts/ui-run-lock.sh", "Tests/NativeMusicUITests/NativeMusicUITests.swift", "App/Sources/NativeMusicApp.swift",
                     "artifacts/harness/nodes/W26/mutation/run-mutations.py", "artifacts/harness/nodes/W26/ui/run-ui.sh"] {
            #expect(files.contains(must), "not swept: \(must)")
        }
        #expect(findings.isEmpty, "\(findings)")
    }

    /// The forms a reviewer planted, each in the kind of file that would hide it, and a harmless control. Each plant must be found in its own file.
    static var plants: [(path: String, text: String)] {
        let tell = ScriptText.tell, osa = ScriptText.osa, app = "Appli" + "cation", descriptor = "NSAppleEvent" + "Descriptor", script = "NSApple" + "Script", workspace = "NSWork" + "space", open = "op" + "en", browser = "web" + "browser"
        return [
            ("scripts/plant1.sh", "\(osa) -e '\(tell) id \"local.native-music.development\" to play'\n"),
            ("scripts/plant1b.sh", "\(osa) -e '\(tell.replacingOccurrences(of: "application", with: "app")) id \"local.native-music.development\" to play'\n"),
            ("scripts/plant2.sh", "\(osa) -e '\(tell) \"YTMuse\" to play'\n"),
            ("scripts/plant3", "#!/bin/sh\n\(osa) <<'EOF'\n\(tell) id \"local.native-music.development\"\nEOF\n"),
            ("scripts/plant4.js", "const a = \(app)(\"local.native-music.development\"); a.play();\n"),
            ("Tests/NativeMusicUITests/Plant5.swift", "import Foundation\nlet d = \(descriptor)(bundleIdentifier: \"local.native-music.development\")\n"),
            ("Tests/NativeMusicUITests/Plant5b.swift", "let d = \(descriptor)(applicationBundleID: \"local.native-music.development\")\n"),
            ("Tests/NativeMusicUITests/Plant6.swift", "\(workspace).shared.\(open)(URL(string: \"ytmuse://library\")!)\n"),
            ("scripts/plant7.sh", "\(open) -b local.native-music.development\n"),
            ("scripts/plant7b.sh", "\(open) \"ytmuse://library\"\n"),
            ("scripts/plant7c.sh", "\(open) -a YTMuse\n"),
            ("scripts/plant8.applescript", "\(tell) ¬\n    id \"local.native-music.development\"\n    play\nend tell\n"),
            ("scripts/plant9.applescript", "\(tell)\nid \"local.native-music.development\"\nplay\n"),
            ("Tests/NativeMusicUITests/Plant10.swift", "let s = \(script)(source: \"x\")\n"),
            ("artifacts/harness/nodes/W26/plant11.py", "import subprocess\nsubprocess.run([\"\(open)\", \"-a\", \"YTMuse\"])\n"),
            ("Tools/Plant12.swift", "let r = LS" + "OpenCFURLRef(url, nil)\n"),
            ("Packages/NativeMusic/Tests/PlaybackTests/Plant13.swift", "\(workspace).shared.\(open)Application(at: url, configuration: c) { _, _ in }\n"),
            ("Packages/NativeMusic/Tests/PlaybackTests/Plant14.swift", "let d = \(descriptor)(processIdentifier: 1)\n"),
            ("Tests/NativeMusicUITests/PlantR1.swift", "import Foundation\nlet task = Process()\ntask.executableURL = URL(fileURLWithPath: \"/usr/bin/\(open)\")\ntask.arguments = [\"-b\", \"local.native-music.development\"]\n"),
            ("Tests/NativeMusicUITests/PlantR2.swift", "let p = Process.launchedProcess(launchPath: \"/usr/bin/\(open)\", arguments: [\"-a\", \"YTMuse\"])\n"),
            ("scripts/plantR3.py", "import subprocess\nsubprocess.run([\"/usr/bin/\(open)\", \"ytmuse://library\"])\n"),
            ("scripts/plantR4.sh", "/usr/bin/\(open) -b local.native-music.development\n"),
            ("Tests/NativeMusicUITests/PlantR5.swift", "let w = \(workspace).shared\n    .\(open)(URL(string: \"ytmuse://queue\")!)\n"),
            ("Tests/NativeMusicUITests/PlantR6.swift", "let ws = \(workspace).shared\nws.\(open)(URL(string: \"ytmuse://queue\")!)\n"),
            ("Tests/NativeMusicUITests/PlantR6b.swift", "func f(ws: \(workspace)) { ws.\(open)Application(at: u, configuration: c) { _, _ in } }\n"),
            ("Tests/NativeMusicUITests/PlantR7.swift", "let d = \(descriptor).init(bundleIdentifier: \"local.native-music.development\")\n"),
            ("Tests/NativeMusicUITests/PlantR8.swift", "let app = XCUI" + "Application(bundleIdentifier: \"local.native-music.development\")\n"),
            ("Tests/NativeMusicUITests/PlantR8b.swift", "let app = XCUI" + "Application.init(bundleIdentifier: \"local.native-music.development\")\n"),
            ("scripts/plantR9", "\(open) -b local.native-music.development\n"),
            ("scripts/plantR9b", "\(osa) -e '\(tell) \"YTMuse\" to quit'\n"),
            ("scripts/plant15.sh", "\(open) \\\n  -n -a YTMuse\n"),
            // TH1 (guard backlog): a long option with a value before the target, the Python standard library's browser launcher, the target held in a
            // variable (shell and Python), and Objective-C sources.
            ("scripts/plantTH1a.sh", "\(open) --env NAME=value -a YTMuse\n"),
            ("scripts/plantTH1a2.sh", "\(open) --env NAME=value --args -n YTMuse\n"),
            ("scripts/plantTH1b.py", "import \(browser)\n\(browser).\(open)(\"ytmuse://library\")\n"),
            ("scripts/plantTH1b2.py", "from \(browser) import \(open) as go\ngo(\"ytmuse://library\")\n"),
            ("scripts/plantTH1c.sh", "APP=\"$HOME/build/YTMuse.app\"\n\(open) \"$APP\"\n"),
            ("scripts/plantTH1c2.sh", "app_path=/x/y\nif true; then exec \(open) -n $app_path; fi\n"),
            ("scripts/plantTH1c3.zsh", "app=/x/y\n\(open) ${app}\n"),
            ("scripts/plantTH1d.py", "import subprocess\napp_path = find_app()\nsubprocess.run([\"\(open)\", app_path])\n"),
            ("scripts/plantTH1d2.py", "import os\nos.system(f\"\(open) {app_path}\")\n"),
            ("Tools/PlantTH1.m", "#import <AppKit/AppKit.h>\nvoid f(NSURL *u) { [[\(workspace) sharedWorkspace] \(open)URL:u]; }\n"),
            ("Tools/PlantTH1b.mm", "void f(NSURL *u, id c) {\n  \(workspace) *ws = [\(workspace) sharedWorkspace];\n  [ws \(open)ApplicationAtURL:u configuration:c completionHandler:nil];\n}\n"),
            ("Tools/PlantTH1c.m", "id d = [\(descriptor) descriptorWithBundleIdentifier:@\"local.native-music.development\"];\n"),
            ("Tools/PlantTH1d.m", "id s = [[\(script) alloc] initWithSource:@\"x\"];\n"),
            ("Tools/PlantTH1e.mm", "OSStatus r = LS" + "OpenApplication(&params, NULL);\n"),
            ("Packages/NativeMusic/Tests/PlaybackTests/PlantTH1f.m", "id d = [\(descriptor) descriptorWithProcessIdentifier:1];\n"),
            ("Extensions/plant16.zsh", "#!/bin/zsh\nexec \(osa) -l JavaScript -e 'x'\n"),
        ]
    }
    static var controls: [(path: String, text: String)] { let open = "op" + "en", browser = "web" + "browser"; return [
        ("Tests/NativeMusicUITests/Control.swift", "let app = XCUIApplication(url: u); app.launch()\nlet d = " + "NSAppleEvent" + "Descriptor(processIdentifier: pid)\n"),
        ("Tests/NativeMusicUITests/Control3.swift", "let app = XCUI" + "Application()\napp.launch()\napp.\(open)(URL(string: \"ytmuse://library\")!)\nlet running = NSWork" + "space.shared.runningApplications\nlet ws = NSWork" + "space.shared\nlet n = ws.runningApplications.count\nlet t = Process(); t.executableURL = URL(fileURLWithPath: \"/usr/bin/true\")\n"),
        ("scripts/control4", "just a text note without a shebang: reopen the window, the status is open_count=1, /usr/bin/true is harmless\n"),
        ("scripts/control.sh", "#!/bin/sh\necho hello; reopen_count=1; xcodebuild test\n"),
        ("scripts/control.py", "status = \"op\" + \"en\"\nprint(\"re\" + \"open\")\n"),
        // TH1: Objective-C comments and strings, the read-only workspace API, a Python file open, and the word in a shell variable name.
        ("Tools/ControlTH1.m", "// [[NSWork" + "space sharedWorkspace] \(open)URL:u] is not a use\nNSString *note = @\"NSWork" + "space\";\nNSArray *r = [[NSWork" + "space sharedWorkspace] runningApplications];\n"),
        ("scripts/controlTH1.py", "import json\nwith \(open)(\"notes.txt\") as f: data = f.read()\nweb_\(browser) = 1\nprint(\"opened\", data)\n"),
        ("scripts/controlTH1.sh", "#!/bin/sh\nreopen_count=1; echo \"the window was re\(open)ed\"; xcodebuild test\nexport \(browser)_note=1\n"),
        ("Tests/NativeMusicUITests/Control2.swift", "// a comment that mentions NSApple" + "Script is not a use\nlet note = \"NSWork" + "space\"\n"),
    ] }

    @Test func everyPlantedFormIsFoundInItsOwnFileAndTheControlsAreNot() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w26-launch-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (path, text) in Self.plants + Self.controls {
            let url = scratch.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let (findings, files) = LaunchGuard.scan(root: scratch)
        #expect(files.count == Self.plants.count + Self.controls.count, "every planted file was read, extensionless ones included (\(files.count))")
        for (path, _) in Self.plants { #expect(findings.contains { $0.file == path }, "NOT FOUND: \(path)") }
        for (path, _) in Self.controls { #expect(!findings.contains { $0.file == path }, "control flagged: \(findings.filter { $0.file == path })") }
        // The by-name form is a finding too (it was pinned as allowed before), and the System Events exception is one named file, not a pattern.
        #expect(findings.contains { $0.file == "scripts/plant2.sh" && $0.rule == "addresses an application by tell" })
        let events = ScriptText.tell + " \"System Events\" to get name\n"
        #expect(LaunchGuard.findings(inText: events, path: "scripts/other.py").contains { $0.rule == "addresses an application by tell" })
        // A planted file in the allowed list's neighbours is still found, and the process-id descriptor is allowed only in the UI-test directory.
        let pid = "NSAppleEvent" + "Descriptor(processIdentifier: 1)\n"
        #expect(LaunchGuard.findings(inText: pid, path: "Tests/NativeMusicUITests/A.swift").isEmpty)
        #expect(!LaunchGuard.findings(inText: pid, path: "Packages/NativeMusic/Tests/PlaybackTests/A.swift").isEmpty)
    }

    /// The System Events file may tell System Events and nothing else, and only while its bytes are the reviewed ones.
    @Test func theSystemEventsExemptionCoversOnlyTheSystemEventsForm() {
        let events = ScriptText.tell + " \"System Events\"\n"
        let ours = events + ScriptText.tell + " \"YTMuse\" to quit\n"
        let allow = ["scripts/ui-preflight.py": (sha256: LaunchGuard.sha256(of: events), rules: Set(["OSA command line"]), reason: "test")]
        let allowOurs = ["scripts/ui-preflight.py": (sha256: LaunchGuard.sha256(of: ours), rules: Set(["OSA command line"]), reason: "test")]
        #expect(LaunchGuard.findings(inText: events, path: "scripts/ui-preflight.py", allowList: allow).isEmpty, "the reviewed System Events form passes")
        #expect(LaunchGuard.findings(inText: ours, path: "scripts/ui-preflight.py", allowList: allowOurs).contains { $0.rule == "addresses an application by tell" }, "telling the app is a finding even in that file, with its hash pinned")
        #expect(LaunchGuard.findings(inText: events + "# edited\n", path: "scripts/ui-preflight.py", allowList: allow).contains { $0.rule == "allow-listed file changed since it was reviewed" }, "any edit drops the exemption")
        #expect(LaunchGuard.findings(inText: events, path: "scripts/elsewhere.py", allowList: allow).contains { $0.rule == "addresses an application by tell" })
    }

    @Test func eachAllowListedFileIsPinnedByItsExactBytes() throws {
        for (path, entry) in LaunchGuard.allowed {
            let text = try String(contentsOf: LifecycleSources.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(LaunchGuard.sha256(of: text) == entry.sha256, "\(path) changed: re-review it and update the pinned hash")
        }
    }

    @Test func theAllowListNamesRealFilesWithReasonsAndStaysSmall() {
        #expect(LaunchGuard.allowed.count == 3 && LaunchGuard.allowed.values.allSatisfy { $0.sha256.count == 64 })
        #expect(LaunchGuard.allowed["scripts/ui-preflight.py"]?.rules == ["OSA command line"], "the System Events file is exempt from the OSA command line only; its application-targeting is narrowed in code to the System Events form")
        #expect(LaunchGuard.allowed.filter { $0.value.rules.contains("addresses an application by tell") }.isEmpty)
        for (path, entry) in LaunchGuard.allowed {
            #expect(FileManager.default.fileExists(atPath: LifecycleSources.repositoryRoot.appendingPathComponent(path).path), "\(path) no longer exists: remove the entry")
            #expect(!entry.reason.isEmpty)
        }
    }

    @Test func theDocumentationWarnsAboutNameAndIdentifierAndReleaseCopies() throws {
        let doc = try IntegrationSources.text("Docs/Automation.md")
        #expect(doc.contains("not by bundle identifier, not by name") && doc.contains("Release build always uses the real stores") && doc.contains("LaunchGuardTests"))
    }
}
