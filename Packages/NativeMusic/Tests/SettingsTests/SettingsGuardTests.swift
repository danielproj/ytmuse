import Foundation
import Testing
@testable import Features
@testable import AppShell

/// Real-data safety (addendum) and the privacy promises, as source sweeps. Each rule is proved on planted lines first, and each sweep asserts that it looked at a
/// real population. Patterns are assembled from pieces so this file never contains a form it forbids.
@Suite struct SettingsGuardTests {
    struct Rule { let name: String; let pattern: String; let allowedFiles: Set<String> }
    private static func p(_ parts: String...) -> String { parts.joined() }

    /// Rework 1 (review finding 1). EVERY destructive API in the whole product (package sources, the app target, the extensions) may appear only inside its one guarded
    /// wrapper. The wrapper refuses a real store AT THE CALL, so a plant anywhere else (a Keychain item under the production name, `UserDefaults()`, the standard
    /// domain from a category reset, a hard-coded artwork path, a real Spotlight call, a hard-coded database path) is a sweep failure before it can ever run.
    static let destructiveRules: [Rule] = [
        Rule(name: "removes, trashes or replaces a file or folder directly", pattern: p("\\.remove", "Item\\(|\\.trash", "Item\\(|\\.replace", "Item(At)?\\(|\\.move", "Item\\(|\\.copy", "Item\\(|\\.link", "Item\\(|create", "SymbolicLink|\\bunlink", "\\(|\\brmdir", "\\(|\\brm ", "-"), allowedFiles: ["DestructiveGuard.swift", "UpdateFiles.swift"]),   // W30: the updater's one confined wrapper (its own "Updates" staging folder and the verified sibling of the installed app)
        // R2-2a: the real stores are named only inside the guard. Anything else that wants to COMPARE a path with them calls `RealStores.resolved(...)`.
        Rule(name: "names the real stores outside the guard", pattern: p("(RealStores|Real", "Roots)\\.cur", "rent\\b|real:\\s*\\w+\\s*=\\s*\\.cur", "rent\\b"), allowedFiles: ["DestructiveGuard.swift"]),
        // TH2: `RealStores.resolved(...)` is public (the updater and the destructive-action verification are in other modules) and hands out the real paths, so it is swept too:
        // only the two comparison-only callers and the guard itself may name it, and nothing may build a default `RealStores()` (the real home) of its own.
        Rule(name: "asks for the real paths outside the comparison callers", pattern: p("(RealStores|Real", "Roots)\\.resol", "ved\\b|real:\\s*(\\w+\\s*=\\s*)?\\.resol", "ved\\b|(RealStores|Real", "Roots)\\(\\)"), allowedFiles: ["DestructiveGuard.swift", "LocalDataRoots.swift", "UpdateFiles.swift"]),
        // By NAME inside a directory handle its owner opened without following links (the private artwork cache and the private download directory): the call cannot
        // leave that directory, so it cannot reach another store by a path. Both directories are the injected ones the eraser's touches name and the guard verifies.
        Rule(name: "unlinks by name outside the two private directory owners", pattern: p("unlink", "at\\("), allowedFiles: ["ArtworkDiskStore.swift", "PrivateDirectory.swift"]),
        Rule(name: "deletes or updates a Keychain item directly", pattern: p("SecItem", "Delete|SecItem", "Update"), allowedFiles: ["GuardedKeychain.swift"]),
        Rule(name: "opens the standard or an anonymous defaults store", pattern: p("UserDefaults\\.", "standard|UserDefaults", "\\(\\)|NSUser", "Defaults|CFPreferences", "Set"), allowedFiles: []),
        Rule(name: "opens a defaults suite outside the guarded store", pattern: p("UserDefaults", "\\(suiteName"), allowedFiles: ["AppPreferences.swift"]),
        Rule(name: "removes or replaces a preferences domain", pattern: p("removePersistent", "Domain|setPersistent", "Domain"), allowedFiles: ["DestructiveGuard.swift"]),
        // W28: the process's own, in-memory argument domain (never a file) is where an explicit interface language is applied at launch; it is merged, not replaced, and
        // only that one file does it. Any other volatile-domain call is still a sweep failure.
        Rule(name: "replaces a volatile defaults domain outside the language override", pattern: p("removeVolatile", "Domain|setVolatile", "Domain"), allowedFiles: ["DestructiveGuard.swift", "UILanguageOverride.swift"]),
        Rule(name: "names or deletes from the system search index", pattern: p("CSSearchable", "Index\\.default|CSSearchable", "Index\\(|deleteAll", "SearchableItems|delete", "SearchableItems"), allowedFiles: ["SystemSearchableIndex.swift"]),
    ]
    /// Names that identify a real store. Only the files that exist to recognise one may spell them.
    static let realStoreRules: [Rule] = [
        Rule(name: "names the application support folder", pattern: p("application", "SupportDirectory|Application ", "Support|NSSearchPath", "ForDirectories"), allowedFiles: ["DestructiveGuard.swift", "SettingsComposition.swift", "IsolatedQAStorage.swift", "LocalDataRoots.swift", "IsolatedQAStorage.swift"]),
        Rule(name: "names the product's directory or bundle id as a literal", pattern: p("local\\.native", "-music"), allowedFiles: ["DestructiveGuard.swift", "LocalDataRoots.swift", "SettingsComposition.swift", "KeychainVault.swift", "GoogleGrantStore.swift", "IsolatedQAStorage.swift"]),
    ]
    static let networkRule = Rule(name: "makes or names a network request", pattern: p("URL", "Session|URL", "Request\\b|NW", "Connection|CF", "Network|import Net", "work|WK", "WebView|http", "s?://"), allowedFiles: [])

    static func code(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: #"(?<!:)//.*$"#, with: "", options: .regularExpression) }.joined(separator: "\n")
    }
    static func offences(in text: String, file: String, rules: [Rule]) -> [String] {
        let code = Self.code(text)
        return rules.filter { code.range(of: $0.pattern, options: .regularExpression) != nil && !$0.allowedFiles.contains(file) }.map { "\(file): \($0.name)" }
    }
    /// The whole product, not the Settings corner of it.
    static var productFiles: [URL] { ["Packages/NativeMusic/Sources", "App/Sources", "Extensions"].flatMap(SettingsSources.swiftFiles(under:)) }
    static var destructiveFiles: [URL] {
        ["Packages/NativeMusic/Sources/AppShell/Settings", "Packages/NativeMusic/Sources/Diagnostics", "Packages/NativeMusic/Sources/Features/Settings"].flatMap(SettingsSources.swiftFiles(under:))
    }

    @Test func everyRuleFiresOnItsOwnPlantedLineAndNotOnACommentOrANearMiss() {
        let samples: [String: String] = [
            "removes, trashes or replaces a file or folder directly": "try FileManager.default.remove" + "Item(at: url)",
            "names the real stores outside the guard": "let files = GuardedFiles(root: x, isolated: false, real: RealStores." + "current)",
            "asks for the real paths outside the comparison callers": "let real = RealStores." + "resolved()",
            "unlinks by name outside the two private directory owners": "unlink" + "at(fd, name, 0)",
            "deletes or updates a Keychain item directly": "let status = SecItem" + "Delete(query)",
            "opens the standard or an anonymous defaults store": "let store = UserDefaults." + "standard",
            "opens a defaults suite outside the guarded store": "let store = UserDefaults" + "(suiteName: \"x\")",
            "removes or replaces a preferences domain": "defaults.removePersistent" + "Domain(forName: x)",
            "replaces a volatile defaults domain outside the language override": "defaults.setVolatile" + "Domain([:], forName: x)",
            "names or deletes from the system search index": "CSSearchable" + "Index.default()",
            "names the application support folder": "let d = FileManager.default.url(for: .application" + "SupportDirectory, in: .userDomainMask)",
            "names the product's directory or bundle id as a literal": "let id = \"local.native" + "-music.development\"",
        ]
        let all = Self.destructiveRules + Self.realStoreRules
        #expect(Set(samples.keys) == Set(all.map(\.name)), "a sample exists for every rule")
        for rule in all {
            #expect(!Self.offences(in: samples[rule.name] ?? "", file: "Planted.swift", rules: [rule]).isEmpty, "\(rule.name) fires on its sample")
            #expect(Self.offences(in: "// " + (samples[rule.name] ?? ""), file: "Planted.swift", rules: [rule]).isEmpty, "a comment is not code")
            for allowed in rule.allowedFiles { #expect(Self.offences(in: samples[rule.name] ?? "", file: allowed, rules: [rule]).isEmpty, "\(allowed) may") }
        }
        // The other forms of the same defects, each caught by the rule that owns them.
        let more: [(String, String)] = [
            ("removes, trashes or replaces a file or folder directly", "try FileManager.default.trash" + "Item(at: url, resultingItemURL: nil)"),
            ("removes, trashes or replaces a file or folder directly", "try FileManager.default.replace" + "ItemAt(a, withItemAt: b)"),
            ("removes, trashes or replaces a file or folder directly", "Darwin.un" + "link(path)"),
            ("removes, trashes or replaces a file or folder directly", "try FileManager.default.move" + "Item(at: a, to: b)"),
            ("removes, trashes or replaces a file or folder directly", "try FileManager.default.copy" + "Item(at: a, to: b)"),
            ("removes, trashes or replaces a file or folder directly", "try FileManager.default.link" + "Item(at: a, to: b)"),
            ("names the real stores outside the guard", "let real: RealRoots = .cur" + "rent"),
            ("asks for the real paths outside the comparison callers", "static let standard = X(real: .resol" + "ved())"),
            ("asks for the real paths outside the comparison callers", "let real = Real" + "Stores()"),
            ("asks for the real paths outside the comparison callers", "func f(real: RealRoots = RealStores." + "resolved(fake))"),
            ("deletes or updates a Keychain item directly", "SecItem" + "Update(query, attributes)"),
            ("opens the standard or an anonymous defaults store", "let d = UserDefaults" + "()"),
            ("removes or replaces a preferences domain", "UserDefaults.x.setPersistent" + "Domain([:], forName: id)"),
            ("replaces a volatile defaults domain outside the language override", "UserDefaults.x.setVolatile" + "Domain([:], forName: id)"),
            ("names or deletes from the system search index", "try await index.deleteAll" + "SearchableItems()"),
        ]
        for (name, line) in more { #expect(!Self.offences(in: line, file: "Planted.swift", rules: all.filter { $0.name == name }).isEmpty, "\(name) fires on \(line)") }
        #expect(Self.offences(in: "let url = \"https://example.org\"", file: "Planted.swift", rules: [Self.networkRule]).count == 1)
        #expect(Self.offences(in: "let label = \"Download storage\"; store.removeAll(); guarded.remove(key)", file: "Planted.swift", rules: all + [Self.networkRule]).isEmpty, "a near miss (the guarded wrappers' own method names) is not flagged")
    }

    @Test func everyDestructiveCallInTheWholeProductSitsInsideItsOneGuardedWrapper() {
        let files = Self.productFiles
        #expect(files.count > 300, "the sweep looked at the whole product (\(files.count) files)")
        let names = Set(files.map(\.lastPathComponent))
        for wrapper in ["DestructiveGuard.swift", "GuardedKeychain.swift", "SystemSearchableIndex.swift", "AppPreferences.swift", "SettingsComposition.swift", "KeychainVault.swift"] { #expect(names.contains(wrapper), "\(wrapper) is in the swept population") }
        var found: [String] = []
        for file in files { found += Self.offences(in: (try? String(contentsOf: file, encoding: .utf8)) ?? "", file: file.lastPathComponent, rules: Self.destructiveRules) }
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
        // Each allowance is real (the wrapper really holds the raw call), so a rule cannot pass because its wrapper was emptied or moved.
        func holds(_ rule: String, _ file: String) -> Bool {
            guard let pattern = Self.destructiveRules.first(where: { $0.name == rule })?.pattern else { return false }
            return files.filter { $0.lastPathComponent == file }.contains { (try? String(contentsOf: $0, encoding: .utf8)).map { Self.code($0).range(of: pattern, options: .regularExpression) != nil } ?? false }
        }
        #expect(holds("removes, trashes or replaces a file or folder directly", "DestructiveGuard.swift") && holds("removes, trashes or replaces a file or folder directly", "UpdateFiles.swift") && holds("deletes or updates a Keychain item directly", "GuardedKeychain.swift"))
        #expect(holds("opens a defaults suite outside the guarded store", "AppPreferences.swift") && holds("removes or replaces a preferences domain", "DestructiveGuard.swift") && holds("replaces a volatile defaults domain outside the language override", "UILanguageOverride.swift") && holds("names or deletes from the system search index", "SystemSearchableIndex.swift"))
    }

    @Test func noSettingsDiagnosticsOrStorageCodeNamesARealStoreOutsideTheFilesThatRecogniseOne() {
        let files = Self.destructiveFiles
        #expect(files.count >= 16, "the sweep looked at the real population (\(files.count) files)")
        #expect(files.contains { $0.lastPathComponent == "LocalDataRoots.swift" } && files.contains { $0.lastPathComponent == "Redaction.swift" })
        var found: [String] = []
        for file in files { found += Self.offences(in: (try? String(contentsOf: file, encoding: .utf8)) ?? "", file: file.lastPathComponent, rules: Self.realStoreRules) }
        // The user-folder names stay out of this code entirely.
        let userFolder = Rule(name: "names a user folder", pattern: Self.p("homeDirectory", "ForCurrentUser|NSHome", "Directory|desktop", "Directory|downloads", "Directory|documentDirectory|\\.Des", "ktop|\\.Down", "loads"), allowedFiles: ["LocalDataRoots.swift", "DestructiveGuard.swift"])
        for file in files { found += Self.offences(in: (try? String(contentsOf: file, encoding: .utf8)) ?? "", file: file.lastPathComponent, rules: [userFolder]) }
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
        let guardText = (try? SettingsSources.text("Packages/NativeMusic/Sources/Domain/DestructiveGuard.swift")) ?? ""
        #expect(guardText.contains("removeItem") && guardText.contains("Application Support") && guardText.contains("owned-audio"), "the wrapper file names the real roots it refuses")
    }

    @Test func settingsDiagnosticsAndStorageCodeHasNoNetwork() {
        var found: [String] = []
        for file in Self.destructiveFiles { found += Self.offences(in: (try? String(contentsOf: file, encoding: .utf8)) ?? "", file: file.lastPathComponent, rules: [Self.networkRule]) }
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
    }

    @Test func noAnalyticsOrCrashReportingSDKIsDeclaredAnywhere() throws {
        let names = ["firebase", "sentry", "crashlytics", "mixpanel", "amplitude", "posthog", "segment.io", "appcenter", "bugsnag", "telemetrydeck", "googleanalytics", "datadog", "newrelic", "instabug", "appsflyer", "adjust.com"]
        let manifests = ["Packages/NativeMusic/Package.swift", "Packages/NativeMusic/Package.resolved", "Extensions/Package.swift", "Extensions/Package.resolved", "App/NativeMusic.xcodeproj/project.pbxproj"]
        var read = 0
        for path in manifests {
            guard let text = try? SettingsSources.text(path).lowercased() else { continue }
            read += 1
            for name in names { #expect(!text.contains(name), "\(path) mentions \(name)") }
        }
        #expect(read >= 3, "the manifests were actually read")
        let sources = SettingsSources.swiftFiles(under: "Packages/NativeMusic/Sources") + SettingsSources.swiftFiles(under: "App/Sources")
        #expect(sources.count > 200)
        for file in sources {
            let imports = (try? String(contentsOf: file, encoding: .utf8))?.components(separatedBy: "\n").filter { $0.hasPrefix("import ") }.joined().lowercased() ?? ""
            for name in names { #expect(!imports.contains(name), "\(file.lastPathComponent) imports \(name)") }
        }
    }

    @Test func noTestEverBuildsAnEraserOnAnythingButItsOwnInjectedRoots() throws {
        let files = SettingsSources.swiftFiles(under: "Packages/NativeMusic/Tests")
        #expect(files.count > 50)
        var eraserSites = 0
        for file in files {
            let name = file.lastPathComponent
            if name == "SettingsGuardTests.swift" { continue }   // this file names the forms it forbids, as planted samples
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, raw) in text.components(separatedBy: "\n").enumerated() {
                let line = raw.components(separatedBy: "//").first ?? raw
                let place = "\(name):\(index + 1)"
                if line.contains("LocalDataEraser(") { eraserSites += 1; #expect(line.contains("world.roots") || line.contains("bootstrap.localRoots"), "\(place): an eraser in a test takes the injected world's (or the isolated session's) roots") }
                if line.contains("isolated: false") { #expect(name == "LocalDataTests.swift", "\(place): a test never describes a session that is not isolated, except to evaluate the guard's rule") }
                if line.contains("PersonConfirmation.from") { #expect(name == "LocalDataTests.swift", "\(place)") }
            }
        }
        #expect(eraserSites >= 5, "the sweep saw the eraser constructions (\(eraserSites))")
    }

    @Test func theDestructiveEntryPointsAllGoThroughTheGuard() throws {
        let eraser = try SettingsSources.text("Packages/NativeMusic/Sources/AppShell/Settings/LocalDataEraser.swift")
        for method in ["func eraseEverything(", "func clearCaches(", "func removeAccount("] {
            let start = try #require(eraser.range(of: method), "\(method)")
            let body = String(eraser[start.lowerBound...].prefix(400))
            #expect(body.contains("try verify(confirmation: confirmation)"), "\(method) verifies the roots AND what the objects hold before anything else")
        }
        let verify = try #require(eraser.range(of: "func verify(confirmation:"))
        #expect(String(eraser[verify.lowerBound...].prefix(260)).contains("DestructiveActionGuard.verify(roots, touches: targets.touches(), confirmation: confirmation)"), "the check reads what the destructive objects actually hold")
        // The UI passes a confirmation only for a session that is not isolated.
        let panes = try SettingsSources.text("Packages/NativeMusic/Sources/AppShell/Settings/SettingsPanes.swift")
        #expect(panes.components(separatedBy: "localRoots?.isolated == true ? nil : PersonConfirmation.fromConfirmationButton()").count - 1 >= 2)
        // The privacy reset button is behind a confirmation dialog and shows the active roots in Debug builds.
        #expect(panes.contains("confirmationDialog(\"Reset all local data on this Mac?\"") && panes.contains("RootsReadout(accounts: accounts)"))
    }

    @Test func theAdapterVersionIsTheAdaptersOwnAndTheEffectsAreAppliedToEveryNativeStart() throws {
        let signed = try SettingsSources.text("Packages/NativeMusic/Sources/YouTubeMusicAdapter/SignedMusic.swift")
        #expect(signed.contains("adapterVersion: String { YouTubeMusicAdapterInfo.version }"))
        let composition = try SettingsSources.text("Packages/NativeMusic/Sources/AppShell/Settings/SettingsComposition.swift")
        #expect(composition.contains("musicReader?.adapterVersion"))
        let panel = try SettingsSources.text("Packages/NativeMusic/Sources/AppShell/PlaybackPanel.swift")
        #expect(panel.components(separatedBy: "await applyChosenEffects(to: player)").count - 1 == 2, "the owned-audio start and the kept-file start apply the chosen effects")
        #expect(!panel.contains("applyChosenEffects(to: music") && !composition.contains("configureEffects"), "the hidden YouTube Music player is never processed")
    }
}
