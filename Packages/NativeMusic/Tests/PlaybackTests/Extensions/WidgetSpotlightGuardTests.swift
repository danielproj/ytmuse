import Foundation
import Testing
import WidgetShared

/// Real-data safety and T25.4 (MAC05, MAC06, ARCH09): no package source, test, probe or script can reach the account holder's real Spotlight index, installed widgets,
/// WidgetCenter or `~/Library/Group Containers`; the widget side links and names nothing that could make a request, hold a credential, play audio or poll; the
/// entitlement files hold exactly the one App Group. Each rule is proved on planted lines, and each sweep asserts it looked at a real population.
@Suite struct WidgetSpotlightGuardTests {
    struct Rule { let name: String; let pattern: String; let allowedFiles: Set<String> }
    private static func p(_ parts: String...) -> String { parts.joined() }
    /// Patterns are assembled from pieces so this file never contains a form it forbids.
    static let systemRules: [Rule] = [
        Rule(name: "the system's searchable index", pattern: p("CSSearchable", "Index|CSSearchable", "Item\\b|CSSearch", "Query|Core", "Spotlight"), allowedFiles: ["App/Sources/SystemSearchableIndex.swift"]),
        Rule(name: "a Spotlight command line tool", pattern: p("\\bmd", "util\\b|\\bmd", "import\\b|\\bmd", "find\\b|\\bmd", "ls\\b"), allowedFiles: []),
        Rule(name: "WidgetCenter", pattern: p("Widget", "Center\\b"), allowedFiles: ["App/Sources/SystemWidgetSupport.swift"]),
        Rule(name: "the real App Group container call", pattern: p("containerURL\\s*\\(\\s*for", "SecurityApplicationGroupIdentifier"),
             allowedFiles: ["App/Sources/SystemWidgetSupport.swift", "Extensions/Sources/NativeMusicWidget/NativeMusicWidgetBundle.swift"]),
        Rule(name: "the Group Containers folder", pattern: p("Group ", "Containers"),
             allowedFiles: ["Packages/NativeMusic/Sources/WidgetShared/WidgetSnapshotStore.swift", "Packages/NativeMusic/Tests/PlaybackTests/Extensions/WidgetSnapshotTests.swift",
                        // W27: the destructive-action guard NAMES the real container to recognise and refuse it (a comparison of paths, no I/O); its own sweep (SettingsGuardTests) holds it to that.
                        "Packages/NativeMusic/Sources/Domain/DestructiveGuard.swift"]),
        Rule(name: "installed-widget or Notification Center tooling", pattern: p("\\bplugin", "kit\\b|\\bchro", "nod\\b|notificationcenter", "ui\\b|\\bls", "register\\b"), allowedFiles: []),
    ]
    static let directories = ["Packages/NativeMusic/Sources", "Packages/NativeMusic/Tests", "Tests", "App", "Extensions", "Tools", "scripts"]
    static let scriptExtensions: Set<String> = ["swift", "py", "sh", "bash", "zsh", "command", "js", "jxa", "rb", "pl"]
    static let thisFile = "Packages/NativeMusic/Tests/PlaybackTests/Extensions/WidgetSpotlightGuardTests.swift"
    /// The scripts that check this very thing name the patterns, as data, to look for them.
    static let checkers: Set<String> = ["scripts/check-widget.py", "scripts/check-intents.py"]

    static func files() -> [(relative: String, text: String)] {
        let root = WidgetSources.root.path + "/"
        var found: [(String, String)] = []
        for directory in directories {
            for url in WidgetSources.files(under: directory, extensions: scriptExtensions) {
                found.append((url.path.replacingOccurrences(of: root, with: ""), WidgetSources.text(url)))
            }
        }
        return found
    }
    /// A comment is prose; the rules are about code.
    static func offences(in text: String, relative: String, rules: [Rule] = systemRules) -> [String] {
        guard relative != thisFile, !checkers.contains(relative) else { return [] }
        let code = relative.hasSuffix(".swift") ? WidgetSources.code(text) : text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        return rules.filter { code.range(of: $0.pattern, options: .regularExpression) != nil && !$0.allowedFiles.contains(relative) }.map { "\(relative): \($0.name)" }
    }

    @Test func noSourceTestProbeOrScriptReachesTheRealSpotlightIndexWidgetCenterOrTheGroupContainers() throws {
        let all = Self.files()
        #expect(all.count > 400, "the sweep must look at the real population, not an empty one (\(all.count) files)")
        #expect(all.contains { $0.relative == "App/Sources/SystemSearchableIndex.swift" } && all.contains { $0.relative == "App/Sources/SystemWidgetSupport.swift" }, "the allowed files are in the population")
        var found: [String] = []
        for file in all { found += Self.offences(in: file.text, relative: file.relative) }
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
        // The allowed files really do hold the calls, so the allowance is not an empty exemption.
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.relative, $0.text) })
        #expect(byName["App/Sources/SystemSearchableIndex.swift"]?.contains("CSSearchableIndex") == true)
        #expect(byName["App/Sources/SystemWidgetSupport.swift"]?.contains("WidgetCenter") == true && byName["Extensions/Sources/NativeMusicWidget/NativeMusicWidgetBundle.swift"]?.contains("containerURL") == true)
    }
    @Test func everyRuleFiresOnItsOwnSampleAndAnAllowedFileOrACommentDoesNot() {
        let samples: [String: String] = [
            "the system's searchable index": "let i = CSSearchable" + "Index.default()",
            "a Spotlight command line tool": "subprocess.run(['md" + "util', '-E', '/'])",
            "WidgetCenter": "Widget" + "Center.shared.reloadAllTimelines()",
            "the real App Group container call": "FileManager.default.containerURL(forSecurity" + "ApplicationGroupIdentifier: g)",
            "the Group Containers folder": "let p = home + \"/Library/Group " + "Containers/x\"",
            "installed-widget or Notification Center tooling": "os.system('plugin" + "kit -m')",
        ]
        #expect(Set(samples.keys) == Set(Self.systemRules.map(\.name)), "a sample exists for every rule")
        for rule in Self.systemRules {
            let hit = Self.offences(in: samples[rule.name] ?? "", relative: "Packages/NativeMusic/Tests/PlaybackTests/Planted.swift")
            #expect(hit.contains { $0.contains(rule.name) }, "\(rule.name) must flag its sample")
        }
        #expect(Self.offences(in: "// " + (samples["WidgetCenter"] ?? ""), relative: "Planted.swift").isEmpty, "a Swift comment is not code")
        #expect(Self.offences(in: "# " + (samples["a Spotlight command line tool"] ?? ""), relative: "scripts/planted.py").isEmpty, "a script comment is not code")
        #expect(Self.offences(in: samples["WidgetCenter"] ?? "", relative: "App/Sources/SystemWidgetSupport.swift").isEmpty, "the one allowed file may")
        #expect(!Self.offences(in: samples["WidgetCenter"] ?? "", relative: "Extensions/Sources/NativeMusicWidget/Other.swift").isEmpty, "the extension may not reload widgets")
        #expect(Self.offences(in: "let name = \"Widget\"", relative: "Planted.swift").isEmpty, "a near miss is not flagged")
    }

    // MARK: T25.4 — the widget side

    static let allowedImports: Set<String> = ["Foundation", "SwiftUI", "WidgetKit", "AppIntents", "AppKit", "CryptoKit", "ImageIO", "UniformTypeIdentifiers", "DesignSystem", "WidgetShared"]
    static let widgetSideRules: [(name: String, pattern: String)] = [
        ("a network API", p("\\bURL", "Session\\b|\\bURL", "Request\\b|\\bNW", "Connection\\b|\\bNW", "PathMonitor\\b|\\bNSURL", "Connection\\b")),
        ("WebKit", p("\\bWK", "WebView\\b|\\bWK", "WebsiteDataStore\\b")),
        ("the Keychain", p("\\bSec", "Item\\w*|\\bkSec", "Class\\w*|\\bKey", "chain\\w*")),
        ("a player", p("\\bAV", "Player\\b|\\bAVAudio", "Engine\\b|\\bMPNowPlaying", "InfoCenter\\b|\\bMPRemote", "CommandCenter\\b")),
        ("a timer or polling loop", p("\\bTimer\\.|\\bTimer\\(|\\bDispatch", "Source\\w*|\\basync", "After\\b|\\bTask\\.", "sleep\\b|\\bTimeline", "View\\b")),
        ("a scheduled timeline policy", p("policy:\\s*\\.(after|at", "End)\\b|\\.at", "End\\b")),
    ]
    static func widgetSideFiles() -> [(relative: String, text: String)] {
        let root = WidgetSources.root.path + "/"
        return (WidgetSources.files(under: "Packages/NativeMusic/Sources/WidgetShared") + WidgetSources.files(under: "Extensions/Sources/NativeMusicWidget"))
            .map { ($0.path.replacingOccurrences(of: root, with: ""), WidgetSources.text($0)) }
    }
    static func widgetSideOffences(_ text: String, relative: String) -> [String] {
        var found: [String] = []
        for module in Set(text.components(separatedBy: "\n").compactMap { $0.hasPrefix("import ") ? String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil }) where !allowedImports.contains(module) {
            found.append("\(relative): imports \(module)")
        }
        let code = WidgetSources.code(text)
        for rule in widgetSideRules where code.range(of: rule.pattern, options: .regularExpression) != nil { found.append("\(relative): names \(rule.name)") }
        return found
    }
    @Test func theWidgetSideImportsOnlyWhatItNeedsAndNamesNoNetworkKeychainPlayerTimerOrScheduledReload() {
        let files = Self.widgetSideFiles()
        #expect(files.count >= 9, "WidgetShared and the extension entry were found (\(files.count) files)")
        var found: [String] = []
        for file in files { found += Self.widgetSideOffences(file.text, relative: file.relative) }
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
        let planted: [(String, String)] = [("import WebKit\n", "imports WebKit"), ("import Playback\n", "imports Playback"), ("import Security\n", "imports Security"),
                                           ("let s = URL" + "Session.shared", "a network API"), ("let q = Sec" + "ItemAdd", "the Keychain"),
                                           ("let t = Timer" + ".scheduledTimer", "a timer or polling loop"), ("Timeline(entries: [], policy: .after(d))", "a scheduled timeline policy"),
                                           ("let p = AV" + "Player()", "a player")]
        for (line, expect) in planted { #expect(Self.widgetSideOffences(line, relative: "Planted.swift").contains { $0.contains(expect) }, "\(expect) must be flagged") }
        #expect(Self.widgetSideOffences("import SwiftUI\nimport WidgetKit\nlet x = 1 // URL" + "Session in a comment", relative: "Planted.swift").isEmpty)
    }
    @Test func theWidgetsModuleDependsOnTheDesignSystemOnlyAndNothingUnderTheWidgetSideLinksPlaybackAccountsOrStores() throws {
        let manifest = WidgetSources.text(WidgetSources.root.appendingPathComponent("Packages/NativeMusic/Package.swift"))
        #expect(manifest.contains(".target(name: \"WidgetShared\", dependencies: [\"DesignSystem\"])"), "the module's whole dependency list")
        let graph = try #require(try JSONSerialization.jsonObject(with: Data(WidgetSources.text(WidgetSources.root.appendingPathComponent("scripts/module-dependencies.json")).utf8)) as? [String: [String]])
        #expect(graph["WidgetShared"] == ["DesignSystem"])
        for forbidden in ["Playback", "AccountSession", "Persistence", "StreamResolver", "Downloads", "YouTubeMusicAdapter", "Queue", "AppShell", "Features"] {
            #expect(graph["DesignSystem"]?.contains(forbidden) != true && graph["Domain"]?.contains(forbidden) != true, "the widget's transitive closure excludes \(forbidden)")
        }
        let project = WidgetSources.text(WidgetSources.root.appendingPathComponent("App/NativeMusic.xcodeproj/project.pbxproj"))
        #expect(project.components(separatedBy: "productName = WidgetShared;").count == 3, "exactly two uses of the WidgetShared product: the app's and the extension's")
        #expect(project.contains("com.apple.product-type.app-extension") && project.components(separatedBy: "com.apple.product-type.app-extension").count == 2, "exactly one app extension target")
    }
    @Test func theEntitlementFilesHoldExactlyTheSandboxAndTheOneBuildVariableGroupAndAdHocBuildsHoldNoGroup() throws {
        func plist(_ path: String) throws -> [String: Any] {
            try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: WidgetSources.root.appendingPathComponent(path)), format: nil) as? [String: Any])
        }
        let template = "$(TeamIdentifierPrefix)local.native-music.development"
        let app = try plist("App/NativeMusic.entitlements"), widget = try plist("Extensions/NativeMusicWidget.entitlements")
        #expect(app.keys.sorted() == ["com.apple.security.application-groups"] && app["com.apple.security.application-groups"] as? [String] == [template], "the app: the one group, no Keychain group, no exception")
        #expect(widget.keys.sorted() == ["com.apple.security.app-sandbox", "com.apple.security.application-groups"] && widget["com.apple.security.app-sandbox"] as? Bool == true
                && widget["com.apple.security.application-groups"] as? [String] == [template], "the extension: sandbox and the one group, no network client, no Keychain group, no file access")
        // No Team ID is ever written into the repository: the group is a build variable in both files and in both Info.plists.
        for path in ["App/NativeMusic.entitlements", "Extensions/NativeMusicWidget.entitlements", "App/Info.plist", "Extensions/NativeMusicWidget-Info.plist"] {
            let text = WidgetSources.text(WidgetSources.root.appendingPathComponent(path))
            #expect(text.range(of: "[A-Z0-9]{10}\\.local\\.native-music", options: .regularExpression) == nil, "\(path) names a literal team")
            #expect(text.contains(template), "\(path) holds the build-variable form")
        }
        // Every Xcode build signs with files that hold no group, so it needs no profile and never touches the group.
        #expect(try plist("App/NativeMusic-adhoc.entitlements").isEmpty)
        #expect(try plist("Extensions/NativeMusicWidget-adhoc.entitlements").keys.sorted() == ["com.apple.security.app-sandbox"])
        let info = try plist("Extensions/NativeMusicWidget-Info.plist")
        #expect((info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension")
        let identity = WidgetSources.text(WidgetSources.root.appendingPathComponent("Packages/NativeMusic/Sources/WidgetShared/WidgetIdentity.swift"))
        #expect(identity.contains("appGroupSuffix = \"local.native-music.development\""), "the code names the suffix the entitlements prefix")
    }
    @Test func neitherTheAppNorTheExtensionLooksUpTheContainerWithoutATeamPrefixedGroupIdAndTheEmbedPhaseDefaultsToNo() {
        // The lookup is guarded by the Info.plist group id (nil for every ad-hoc / unsigned / worktree build) and comes after the guard, in both places that name it.
        for path in ["App/Sources/SystemWidgetSupport.swift", "Extensions/Sources/NativeMusicWidget/NativeMusicWidgetBundle.swift"] {
            let code = WidgetSources.code(WidgetSources.text(WidgetSources.root.appendingPathComponent(path)))
            let guardAt = code.range(of: "WidgetIdentity.appGroup(in:")?.lowerBound, lookupAt = code.range(of: "containerURL(")?.lowerBound
            #expect(guardAt != nil && lookupAt != nil && guardAt! < lookupAt!, "\(path): the team-prefix guard comes before the container lookup")
        }
        let embed = WidgetSources.text(WidgetSources.root.appendingPathComponent("scripts/embed-widget.sh"))
        #expect(embed.contains("YTMUSE_EMBED_WIDGET:-NO") && !WidgetSources.code(embed.components(separatedBy: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")).contains("codesign"), "the embed phase defaults to NO and signs nothing")
        let build = WidgetSources.text(WidgetSources.root.appendingPathComponent("scripts/build.sh"))
        #expect(build.contains("embed=NO; [[ -n \"$identity\" ]] && embed=YES"), "only a build that will be signed with an identity embeds the extension")
    }
    /// R2-1: T25 itself must run every suite of this node, or a deleted removal line is only caught by T50.
    @Test func theT25SuiteRunsEverySuiteInTheExtensionsTestFolder() throws {
        let folder = WidgetSources.files(under: "Packages/NativeMusic/Tests/PlaybackTests/Extensions")
        var suites = Set<String>()
        for url in folder { for match in WidgetSources.text(url).matches(of: /@Suite[^\n]*struct (\w+)/) { suites.insert(String(match.output.1)) } }
        #expect(suites.count >= 9 && suites.contains("SurfaceBarrierTests"), "the suites were found: \(suites.sorted())")
        let script = WidgetSources.text(WidgetSources.root.appendingPathComponent("scripts/test.sh"))
        let block = try #require(script.components(separatedBy: "if [[ \"$2\" == T25 ]]; then").dropFirst().first?.components(separatedBy: "if [[ \"$2\" == T24 ]]; then").first)
        let required = try #require(block.components(separatedBy: "for required in ").dropFirst().first?.components(separatedBy: "; do").first)
        let filter = try #require(block.components(separatedBy: "counted_swift_test '").dropFirst().first?.components(separatedBy: "'").first)
        for suite in suites {
            #expect(required.split(separator: " ").contains(Substring(suite)), "\(suite) is in T25's required-class list")
            #expect(filter.split(separator: "|").contains(Substring(suite)), "\(suite) is in T25's test filter")
        }
    }
    @Test func theGroupIdIsReadFromTheInfoPlistAndOnlyATeamPrefixedOneIsAccepted() {
        let key = WidgetIdentity.appGroupInfoKey
        #expect(WidgetIdentity.appGroup(in: [key: "ABCDE12345.local.native-music.development"]) == "ABCDE12345.local.native-music.development")
        for refused in ["local.native-music.development", ".local.native-music.development", "group.local.native-music.development", "abcde12345.local.native-music.development",
                        "ABCDE1234.local.native-music.development", "ABCDE123456.local.native-music.development", "ABCDE12345.local.native-music.developmentX", "$(TeamIdentifierPrefix)local.native-music.development", ""] {
            #expect(WidgetIdentity.appGroup(in: [key: refused]) == nil, "\(refused) is not a usable group")
        }
        #expect(WidgetIdentity.appGroup(in: nil) == nil && WidgetIdentity.appGroup(in: [:]) == nil && WidgetIdentity.appGroup(in: [key: 5]) == nil)
    }
    @Test func theSharedModuleIsTheWidgetsOnlyAppGroupWriterContractNoOtherFileNameIsUsed() {
        let identity = WidgetSources.text(WidgetSources.root.appendingPathComponent("Packages/NativeMusic/Sources/WidgetShared/WidgetIdentity.swift"))
        #expect(identity.contains("snapshotFileName = \"now-playing-snapshot.json\""))
        // Every write into the group goes through the store's `write`; nothing else in WidgetShared or the app writes a file by another route.
        for file in Self.widgetSideFiles() where !file.relative.hasSuffix("WidgetSnapshotStore.swift") {
            let code = WidgetSources.code(file.text)
            #expect(!code.contains(".write(to:") && !code.contains("createFile("), "\(file.relative) writes no file")
        }
    }
}
