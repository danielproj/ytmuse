import Foundation
import Testing
@testable import Features
@testable import AppShell
@testable import Domain
import TestSupport

/// T27.1. Every row of section 16, read from the specification itself, against the registry.
@Suite @MainActor struct SettingsRegistryTests {
    /// The section 16 table, parsed from `Docs/Product-Specification.md`: (setting, default) in file order.
    static func specTable() throws -> [(label: String, text: String)] {
        let spec = try SettingsSources.text("Docs/Product-Specification.md")
        let lines = spec.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: "# 16 Settings and chosen defaults"))
        var rows: [(String, String)] = []
        var inTable = false
        for line in lines[(start + 1)...] {
            if line.hasPrefix("# ") { break }
            if line.hasPrefix("| Setting | Default |") { inTable = true; continue }
            if inTable, line.hasPrefix("| -") { continue }
            if inTable, line.hasPrefix("|") {
                let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                rows.append((cells[1], cells[2]))
            } else if inTable { break }
        }
        return rows
    }

    @Test func theRegistryHoldsEverySectionSixteenRowWithItsExactLabelAndDefaultInTheSpecificationsOrder() throws {
        let spec = try Self.specTable()
        #expect(spec.count == 24, "the specification's table has 24 rows (\(spec.count))")
        let registry = SettingsRegistry.specRows
        #expect(registry.map(\.label) == spec.map(\.label), "the same rows in the same order")
        for (row, expected) in zip(registry, spec) {
            #expect(row.defaultText == expected.text, "\(row.label): default text")
            #expect(!row.settings.isEmpty, "\(row.label) has at least one setting behind it")
        }
    }

    @Test func aFreshStoreReadsEveryDefaultTheSpecificationNames() throws {
        let (store, backing, _) = try memoryStore(account: UUID())
        #expect(backing.settingKeys(withPrefix: "settings.").allSatisfy { $0 == SettingsRegistry.schemaVersionKey }, "a fresh store writes nothing but its schema version")
        let expected: [String: SettingValue] = [
            "appearance": .text("system"), "appearanceStyle": .text("standard"), "artworkAccent": .bool(true), "motion": .text("full"), "restoreSession": .bool(true), "crossfade": .double(0), "equalizer": .text("flat"),
            "normalization": .bool(false), "newPlaylistVisibility": .text("private"), "headphoneDisconnect": .text("pauseNoResume"),
            "autoplayRadio": .text("onWhereSupported"), "replaceExplicitQueue": .text("ask"), "songVideo": .text("audioWhenPermitted"), "analytics": .text("off"),
            "updateChecking": .text("askOnce"), "automaticInstallation": .bool(false), "backgroundControl": .text("menuBar"), "dockIcon": .text("followsWindows"),
            "downloadErrorNotifications": .bool(false), "launchAtLogin": .bool(false), "miniPlayerOnTop": .bool(false),
            "automaticOnExpensive": .bool(false), "trackChangeNotifications": .bool(false), "spotlightIndexing": .bool(false), "spotlightPrivate": .bool(false),
            "downloadStorage": .double(20), "globalShortcuts": .text("unassigned"), "outputRoute": .text("systemDefault"),
        ]
        for definition in SettingsRegistry.definitions where !definition.specRow.isEmpty {
            let want = try #require(expected[definition.id], "a default is pinned for \(definition.id)")
            #expect(definition.defaultValue == want, "\(definition.id) default")
            if definition.isStored || definition.storage == .policy { #expect(store.value(definition.id) == want, "\(definition.id) reads its default on a fresh store") }
        }
        let spec = try Self.specTable()
        #expect(Set(SettingsRegistry.definitions.filter { !$0.specRow.isEmpty }.map(\.id)) == Set(expected.keys), "every spec-row setting is pinned, and nothing else")
        #expect(spec.count == Set(SettingsRegistry.definitions.map(\.specRow)).subtracting([""]).count)
        #expect(SettingsRegistry.defaultDownloadBudgetBytes == 20 << 30, "Download storage: 20 GiB aggregate")
    }

    @Test func definitionsAreWellFormed() {
        let ids = SettingsRegistry.definitions.map(\.id)
        #expect(Set(ids).count == ids.count, "unique ids")
        let keys = SettingsRegistry.definitions.compactMap(\.storedKey)
        #expect(Set(keys).count == keys.count, "unique stored keys")
        for definition in SettingsRegistry.definitions {
            #expect(!definition.effect.isEmpty, "\(definition.id) states its downstream effect")
            #expect(!definition.title().isEmpty)
            if case .unavailable(let reason) = definition.availability {
                #expect(!reason.isEmpty, "\(definition.id) says why it is unavailable")
                #expect(definition.control == .readOnly && !definition.isStored, "\(definition.id): an unavailable capability has no control and stores nothing")
            }
            if definition.control == .readOnly { #expect(!definition.isStored, "\(definition.id): a read-only row stores nothing") }
            if let store = Optional(definition), store.isStored, case .choice(let choices) = store.control, case .text(let value) = store.defaultValue { #expect(choices.contains { $0.value == value }, "\(definition.id) default is one of its choices") }
        }
        // The preferences the app already had keep their keys, so nothing a person chose before this build is lost.
        #expect(SettingsRegistry.definition("appearance")?.storedKey == "appearance")
        #expect(SettingsRegistry.definition("resumeAfterWake")?.storedKey == ShellPreferenceKey.resumeAfterWake)
        #expect(SettingsRegistry.definition("statusTooltip")?.storedKey == ShellPreferenceKey.statusTooltip)
    }

    /// T27.2: the capabilities the app cannot honour are stated, not pretended. This is the set that fails release coverage until the capability exists.
    @Test func theRowsThatCannotBeHonouredAreExactlyTheKnownOnesAndEachSaysWhy() throws {
        let unavailable = Set(SettingsRegistry.definitions.filter { !$0.availability.isControllable }.map(\.id))
        #expect(unavailable == ["autoplayRadio"], "the rows that could be built now (system notifications, replacing the explicit queue, the updater) are built")
        // Audio quality and Smart Downloads were removed (2026-11-05): YouTube Music's player chooses its own quality and offers no downloads on the Mac.
        #expect(SettingsRegistry.definition("audioQuality") == nil && SettingsRegistry.definition("smartDownloads") == nil, "no row for something that cannot be configured")
        // CORE-B C5: autoplay is not a feature that is missing. YouTube Music's own player continues playback, and the row must not say "Not built yet".
        let autoplay = try #require(SettingsRegistry.definition("autoplayRadio")?.availability.note)
        #expect(autoplay.contains("YouTube Music") && autoplay.contains("Start Radio") && !autoplay.contains("Not built yet") && !autoplay.contains("W05"))
        // Scoped rows work in a named situation only.
        let scoped = Set(SettingsRegistry.definitions.filter { if case .scoped = $0.availability { true } else { false } }.map(\.id))
        #expect(scoped == ["crossfade", "equalizer", "normalization", "replaceExplicitQueue", "downloadStorage", "updateChecking", "automaticInstallation"])
        // Window scope: no section 16 row is per window, so no setting uses it. The store supports it (tested with a synthetic definition) and Docs/Settings.md says so.
        #expect(Set(SettingsRegistry.definitions.map(\.scope)) == [.global, .account])
    }

    @Test func everyCategoryThatListsRowsOwnsAtLeastOneAndTheRestAreCustomPanes() {
        let withRows = Set(SettingsRegistry.definitions.map(\.category))
        let custom: Set<SettingCategory> = [.account, .storage, .language]
        #expect(Set(SettingCategory.allCases).subtracting(withRows) == custom)
        for category in SettingCategory.allCases { #expect(!category.title.isEmpty && !category.symbol.isEmpty) }
    }
}

/// Scopes and reset (T27.1: reset per category changes only that category).
@Suite @MainActor struct SettingsScopeAndResetTests {
    @Test func globalAccountAndWindowValuesLiveApartAndSwitchingAccountChangesOnlyTheAccountScope() async throws {
        let a = UUID(), b = UUID()
        let (store, backing, box) = try memoryStore(account: a)
        try await store.set("appearance", .text("dark"))                    // global
        try await store.set("newPlaylistVisibility", .text("public"))       // account
        box.account = b
        #expect(store.text("appearance") == "dark", "global survives an account switch")
        #expect(store.text("newPlaylistVisibility") == "private", "the other account starts at its default")
        try await store.set("newPlaylistVisibility", .text("unlisted"))
        box.account = a
        #expect(store.text("newPlaylistVisibility") == "public", "switching back restores the first account's choice")
        #expect(backing.setting(forKey: SettingsStore.accountPrefix + a.uuidString + ".newPlaylistVisibility") as? String == "public")
        #expect(backing.setting(forKey: SettingsStore.accountPrefix + b.uuidString + ".newPlaylistVisibility") as? String == "unlisted")
        #expect(backing.setting(forKey: "appearance") as? String == "dark")
        box.account = nil
        await #expect(throws: SettingsError.noAccount) { try await store.set("newPlaylistVisibility", .text("public")) }
        #expect(store.text("newPlaylistVisibility") == "private", "no account reads the default and nothing is written")
    }

    @Test func windowScopeIsKeptPerWindowAndOnlyForAWindow() throws {
        let (store, backing, _) = try memoryStore()
        let definition = SettingDefinition(id: "syntheticWindow", specRow: "", category: .general, scope: .window, title: "x", control: .toggle, defaultValue: .bool(false), storage: .stored(key: "syn"), effect: "test")
        let w1 = UUID(), w2 = UUID()
        #expect(throws: SettingsError.windowRequired) { _ = try store.key(for: definition) }
        let k1 = try #require(try store.key(for: definition, window: w1)), k2 = try #require(try store.key(for: definition, window: w2))
        #expect(k1 != k2 && k1.hasPrefix(SettingsStore.windowPrefix + w1.uuidString))
        try backing.setSetting(true, forKey: k1)
        try store.removeWindow(w1)
        #expect(backing.setting(forKey: k1) == nil)
    }
    /// Review: the window scope is stated honestly. The store can keep a per-window value (above), but no section 16 row is window-scoped in this build, so the scope is
    /// reserved and the Settings window offers none. When a row adopts it this test is the one to change, with the row.
    @Test func noSectionSixteenRowIsWindowScopedSoTheWindowScopeIsReservedAndSaysSo() throws {
        #expect(SettingsRegistry.definitions.allSatisfy { $0.scope != .window }, "a window-scoped row appeared: update Docs/Settings.md and the Settings window with it")
        #expect(Set(SettingsRegistry.definitions.map(\.scope)) == [.global, .account])
        let doc = try SettingsSources.text("Docs/Settings.md")
        #expect(doc.contains("reserved") && doc.contains("window scope"), "the documentation says the window scope is reserved")
    }

    /// The privacy reset leaves no account-scope key behind, including those of an account that is no longer on this Mac (an interrupted removal) or is not the live one.
    @Test func theLocalResetDeletesTheSettingsOfEveryAccountIncludingOnesNotLive() async throws {
        let a = UUID(), b = UUID()
        let (store, _, box) = try memoryStore(account: a)
        try await store.set("newPlaylistVisibility", .text("public"))
        box.account = b; try await store.set("newPlaylistVisibility", .text("unlisted"))
        box.account = nil
        #expect(store.accountIDsWithSettings() == [a, b])
        try await store.resetAll()
        #expect(store.accountIDsWithSettings().isEmpty, "no account's settings survive the privacy reset")
    }

    @Test func removingAnAccountDeletesItsSettingsAndNoOthers() async throws {
        let a = UUID(), b = UUID()
        let (store, backing, box) = try memoryStore(account: a)
        try await store.set("newPlaylistVisibility", .text("public")); try await store.set("appearance", .text("dark"))
        box.account = b; try await store.set("newPlaylistVisibility", .text("unlisted"))
        #expect(store.accountIDsWithSettings() == [a, b])
        try store.removeAccount(a)
        #expect(store.accountIDsWithSettings() == [b])
        #expect(backing.setting(forKey: "appearance") as? String == "dark", "the global scope is untouched")
        #expect(store.text("newPlaylistVisibility") == "unlisted")
    }

    @Test func restoringOneCategoryChangesOnlyThatCategoryAndNeverTheOthers() async throws {
        let (store, backing, _) = try memoryStore(account: UUID())
        try await store.set("appearance", .text("dark")); try await store.set("artworkAccent", .bool(false)); try await store.set("appearanceStyle", .text("ytmuse"))
        try await store.set("restoreSession", .bool(false)); try await store.set("crossfade", .double(6)); try await store.set("equalizer", .text("bass")); try await store.set("newPlaylistVisibility", .text("public"))
        let before = Dictionary(uniqueKeysWithValues: backing.settingKeys(withPrefix: "").compactMap { key in backing.setting(forKey: key).map { (key, "\($0)") } })
        let outcome = try await store.reset(.appearance)
        #expect(Set(outcome.restored) == ["appearance", "appearanceStyle", "artworkAccent"] && outcome.notApplicable == ["motion"])
        #expect(store.text("appearance") == "system" && store.bool("artworkAccent") && store.text("appearanceStyle") == "standard", "Restore Defaults returns the Style to Standard too")
        #expect(!store.bool("restoreSession") && store.double("crossfade") == 6 && store.text("equalizer") == "bass" && store.text("newPlaylistVisibility") == "public", "the other pages are untouched")
        let after = Dictionary(uniqueKeysWithValues: backing.settingKeys(withPrefix: "").compactMap { key in backing.setting(forKey: key).map { (key, "\($0)") } })
        #expect(Set(before.keys).subtracting(after.keys).sorted() == ["appearance", "appearanceStyle", "settings.artworkAccent"], "exactly the appearance keys were removed")
        for (key, value) in after { #expect(before[key] == value, "\(key) unchanged") }
        _ = try await store.reset(.playback)
        #expect(store.double("crossfade") == 0 && store.text("equalizer") == "flat")
        #expect(!store.bool("restoreSession") && store.text("newPlaylistVisibility") == "public", "General and Library still keep their choices")
        _ = try await store.reset(.library)
        #expect(store.text("newPlaylistVisibility") == "private")
    }

    @Test func aResetCallsEachOwnerOnceAndOnlyForItsCategory() async throws {
        let (store, _, _) = try memoryStore()
        var calls: [String: Int] = [:]
        for owner in ["loginItem", "miniPlayer", "downloads", "spotlight", "notifications", "shortcuts", "outputs", "diagnostics", "updates"] {
            store.attach(owner: owner, SettingOwnerBinding(read: { _ in nil }, reset: { calls[owner, default: 0] += 1 }))
        }
        _ = try await store.reset(.downloads)
        #expect(calls == ["downloads": 1], "three download settings, one owner reset: \(calls)")
        calls = [:]; _ = try await store.reset(.integration)
        #expect(calls == ["notifications": 1, "spotlight": 1, "shortcuts": 1])
        calls = [:]; _ = try await store.reset(.general)
        #expect(calls == ["loginItem": 1, "miniPlayer": 1])
        calls = [:]; _ = try await store.reset(.playback)
        #expect(calls.isEmpty, "the remembered output has its own action: Restore Defaults on Playback does not forget it")
        try await store.restoreOne("outputRoute")
        #expect(calls == ["outputs": 1])
        calls = [:]; _ = try await store.reset(.updates)
        #expect(calls == ["updates": 1], "the two update rows are one owner, reset once")
        calls = [:]; _ = try await store.reset(.privacy); _ = try await store.reset(.appearance)
        #expect(calls.isEmpty, "policy rows have nothing to reset")
        // The local privacy reset restores EVERYTHING, the remembered output included, and every owner exactly once.
        calls = [:]; try await store.resetAll()
        #expect(calls == ["loginItem": 1, "miniPlayer": 1, "downloads": 1, "spotlight": 1, "notifications": 1, "shortcuts": 1, "outputs": 1, "diagnostics": 1, "updates": 1], "\(calls)")
    }

    /// Addendum 3 / review 2: each category's Restore Defaults changes only the keys and the owners of ITS OWN settings, for every category.
    @Test func everyCategoryResetTouchesOnlyItsOwnKeysAndOwners() async throws {
        for category in SettingCategory.allCases {
            let (store, backing, _) = try memoryStore(account: UUID())
            var calls: [String] = []
            for owner in ["loginItem", "miniPlayer", "downloads", "spotlight", "notifications", "shortcuts", "outputs", "diagnostics", "updates"] {
                store.attach(owner: owner, SettingOwnerBinding(read: { _ in nil }, reset: { calls.append(owner) }))
            }
            // Every stored setting of every category is changed to a non-default value first.
            for definition in SettingsRegistry.definitions where definition.isStored {
                let value: SettingValue
                switch definition.control {
                case .toggle: value = .bool(!(definition.defaultValue.boolValue ?? false))
                case .choice(let choices): value = .text(choices.first { .text($0.value) != definition.defaultValue }!.value)
                case .slider(let range, _): value = .double(range.upperBound)
                case .readOnly: continue
                }
                try await store.set(definition.id, value)
            }
            let before = Dictionary(uniqueKeysWithValues: backing.settingKeys(withPrefix: "").compactMap { key in backing.setting(forKey: key).map { (key, "\($0)") } })
            _ = try await store.reset(category)
            let after = Dictionary(uniqueKeysWithValues: backing.settingKeys(withPrefix: "").compactMap { key in backing.setting(forKey: key).map { (key, "\($0)") } })
            let own = Set(SettingsRegistry.settings(in: category).filter { !$0.restoresOnlyOnRequest }.compactMap { definition in try? store.key(for: definition) })
            let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
            #expect(changed.isSubset(of: own), "\(category): changed \(changed.subtracting(own)) outside its own keys")
            let ownOwners = Set(SettingsRegistry.settings(in: category).filter { !$0.restoresOnlyOnRequest }.compactMap { definition -> String? in if case .owner(let o) = definition.storage { o } else { nil } })
            #expect(Set(calls) == ownOwners && calls.count == ownOwners.count, "\(category): owners reset \(calls), expected \(ownOwners)")
        }
    }
    @Test func aRefusingGuardStopsEveryResetBeforeAnythingChanges() async throws {
        let (store, backing, _) = try memoryStore(account: UUID())
        var resets = 0
        store.attach(owner: "loginItem", SettingOwnerBinding(read: { _ in nil }, reset: { resets += 1 }))
        try await store.set("appearance", .text("dark"))
        struct Refused: Error {}
        store.preflight = { throw Refused() }
        await #expect(throws: Refused.self) { _ = try await store.reset(.appearance) }
        await #expect(throws: Refused.self) { _ = try await store.reset(.general) }
        await #expect(throws: Refused.self) { try await store.resetAll() }
        await #expect(throws: Refused.self) { try await store.restoreOne("outputRoute") }
        #expect(backing.setting(forKey: "appearance") as? String == "dark" && resets == 0, "nothing was restored and no owner was asked")
    }
    @Test func aGuardedStoreOnTheRealDomainRefusesEveryWriteAndRemovalAtTheCall() throws {
        // A private suite NAME (not a file in the temporary folder) is a real domain by derivation; no flag can say otherwise. The suite itself is private, so a broken
        // guard could only write this throwaway name, never the product's domain.
        let name = "ytmuse-th2-real-domain-" + UUID().uuidString
        let raw = InMemoryDefaults()
        let real = GuardedDefaults(store: raw, domain: name)
        try #require(real.isRealDomain, "a domain that is not a scratch file is real")
        #expect(throws: GuardRefusal.self) { try real.set("dark", forKey: "appearance") }
        #expect(throws: GuardRefusal.self) { try real.remove("appearance") }
        #expect(throws: GuardRefusal.self) { try real.removeAll() }
        #expect(raw.object(forKey: "appearance") == nil)
        #expect(throws: GuardRefusal.self) { _ = try SettingsStore(backing: real) }   // even the schema stamp is a write
    }

    /// TH2: the real/throwaway decision is derived from the domain alone. Only an absolute path that really lies inside the temporary folder is a throwaway.
    @Test func aDomainIsAThrowawayOnlyWhenItIsAFileInsideTheTemporaryFolder() throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let temp = scratch.url.appendingPathComponent("temp", isDirectory: true), outside = scratch.url.appendingPathComponent("outside", isDirectory: true)
        for directory in [temp, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: temp.appendingPathComponent("link"), withDestinationURL: outside)
        func throwaway(_ domain: String) -> Bool { GuardedDefaults.isThrowaway(domain, temporary: temp) }
        #expect(throwaway(temp.appendingPathComponent("ytmuse-ui-test-defaults-X.plist").path), "a scratch file is a throwaway")
        #expect(throwaway(temp.appendingPathComponent("not-yet-created.plist").path), "it need not exist yet")
        #expect(!throwaway("local.native-music.development"), "the product's domain is real")
        #expect(!throwaway("ytmuse-settings-test-name"), "a bare suite name is real")
        #expect(!throwaway(temp.path), "the temporary folder itself is not a file in it")
        #expect(!throwaway("/Users/someone/Library/Preferences/local.native-music.development.plist"), "a path in Preferences is real")
        #expect(!throwaway(temp.path + "/../outside/x.plist"), "a dot-dot escape is real")
        #expect(!throwaway(temp.appendingPathComponent("link/x.plist").path), "a link inside the folder that leaves it is real")
        // TH2 rework (critic M1): both together. The file does not exist, so `link/..` used to be removed lexically and the path read as `<temp>/x.plist`, while the kernel
        // writes `outside/x.plist`. `outside` is inside this test's own scratch folder, so a broken guard could only ever write there.
        #expect(!throwaway(temp.path + "/link/../x.plist"), "a symlink followed by .. is real")
        #expect(!throwaway(temp.path + "/./x.plist") && !throwaway(temp.path + "/sub/../x.plist"), "no dot components at all")
        let probe = InMemoryDefaults()
        let combined = GuardedDefaults(store: probe, domain: temp.path + "/link/../x.plist")
        #expect(combined.isRealDomain, "through the wrapper too")
        #expect(throws: GuardRefusal.self) { try combined.set("v", forKey: "k") }   // isolated process: refused before anything is written
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("x.plist").path) && !FileManager.default.fileExists(atPath: temp.appendingPathComponent("x.plist").path))
        #expect(!throwaway(""), "the empty name is real")
        // The same through the wrapper: no argument can make a path outside the folder a throwaway, and the product name is refused at the call.
        let store = InMemoryDefaults()
        #expect(GuardedDefaults(store: store, domain: "local.native-music.development").isRealDomain)
        #expect(!GuardedDefaults(store: store, domain: FileManager.default.temporaryDirectory.appendingPathComponent("x-" + UUID().uuidString + ".plist").path).isRealDomain)
    }

    @Test func invalidWritesAreRefusedAndChangeNothing() async throws {
        let (store, backing, _) = try memoryStore(account: UUID())
        await #expect(throws: SettingsError.unknownSetting) { try await store.set("nope", .bool(true)) }
        await #expect(throws: SettingsError.outOfRange) { try await store.set("appearance", .text("sepia")) }
        await #expect(throws: SettingsError.outOfRange) { try await store.set("crossfade", .double(13)) }
        await #expect(throws: SettingsError.outOfRange) { try await store.set("crossfade", .double(.nan)) }
        await #expect(throws: SettingsError.wrongType) { try await store.set("artworkAccent", .text("yes")) }
        await #expect(throws: SettingsError.notChoosable) { try await store.set("motion", .text("reduced")) }
        await #expect(throws: SettingsError.notChoosable) { try await store.set("autoplayRadio", .text("off")) }
        await #expect(throws: SettingsError.notChoosable) { try await store.set("updateChecking", .text("daily")) }
        await #expect(throws: SettingsError.notChoosable) { try await store.set("launchAtLogin", .bool(true)) }   // owner not attached: refused, never silently stored
        #expect(backing.settingKeys(withPrefix: "settings.").allSatisfy { $0 == SettingsRegistry.schemaVersionKey })
        #expect(backing.setting(forKey: "appearance") == nil)
    }

    /// The app's isolated preferences are a suite NAMED BY AN ABSOLUTE PATH; Restore Defaults must clear a value kept there.
    @Test func restoreDefaultsClearsAValueKeptInAPathNamedSuite() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let path = scratch.url.appendingPathComponent("prefs.plist").path
        let defaults = GuardedDefaults(store: ScratchDefaults.open(path: path), domain: path)
        let store = try SettingsStore(backing: defaults)
        try await store.set("appearance", .text("dark"))
        #expect((defaults.value(forKey: "appearance") as? String) == "dark" && store.text("appearance") == "dark")
        _ = try await store.reset(.appearance)
        #expect((defaults.value(forKey: "appearance") as? String) == nil && store.text("appearance") == "system")
        try? defaults.removeAll()
    }

    /// A value an EARLIER PROCESS left in the plist (the UI test relaunches the app on the same file). The plist is written by a helper process here would be ideal; a crafted
    /// file loads the same way for this purpose.
    @Test func restoreDefaultsClearsAValueAnEarlierProcessLeftInThePlist() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let path = scratch.url.appendingPathComponent("earlier.plist").path
        try PropertyListSerialization.data(fromPropertyList: ["appearance": "dark", SettingsRegistry.schemaVersionKey: 1], format: .binary, options: 0).write(to: URL(fileURLWithPath: path))
        let defaults = GuardedDefaults(store: ScratchDefaults.open(path: path), domain: path)
        let store = try SettingsStore(backing: defaults)
        #expect(store.text("appearance") == "dark")
        _ = try await store.reset(.appearance)
        // Removing a key a file-named suite loaded from disk does not change what THIS process reads (the file is updated); the default is said explicitly instead.
        #expect(store.text("appearance") == "system" && store.isDefault("appearance"), "this process reads the default")
        try? defaults.removeAll()
    }

    @Test func aDamagedStoredValueReadsAsTheDefaultAndIsNotRewritten() throws {
        let (store, backing, _) = try memoryStore()
        try backing.setSetting("garbage", forKey: "settings.artworkAccent"); try backing.setSetting(99.0, forKey: "settings.crossfadeSeconds"); try backing.setSetting("sepia", forKey: "appearance")
        #expect(store.bool("artworkAccent") && store.double("crossfade") == 0 && store.text("appearance") == "system")
        #expect(backing.setting(forKey: "appearance") as? String == "sepia")
    }

    @Test func theSchemaVersionIsWrittenAndANewerStoreIsNeverOverwritten() throws {
        let backing = MemorySettingsBacking()
        try backing.setSetting("dark", forKey: "appearance")   // a store written before settings had a schema version
        let store = try SettingsStore(backing: backing)
        #expect(backing.setting(forKey: SettingsRegistry.schemaVersionKey) as? Int == SettingsRegistry.schemaVersion)
        #expect(store.text("appearance") == "dark", "a legacy key keeps its value")
        let newer = MemorySettingsBacking(); try newer.setSetting(SettingsRegistry.schemaVersion + 1, forKey: SettingsRegistry.schemaVersionKey)
        #expect(throws: SettingsError.newerSchema) { _ = try SettingsStore(backing: newer) }
        #expect(newer.setting(forKey: SettingsRegistry.schemaVersionKey) as? Int == SettingsRegistry.schemaVersion + 1)
    }
}

@Suite @MainActor struct SettingsSearchTests {
    @Test func everyWordMustMatchIgnoringCaseAndDiacritics() {
        #expect(SettingsRegistry.search("CROSSFADE").map(\.id) == ["crossfade", "equalizer", "normalization"], "one section 16 row, three controls")
        #expect(SettingsRegistry.search("spotlight private").map(\.id).contains("spotlightPrivate"))
        #expect(SettingsRegistry.search("équalizer").map(\.id) == ["equalizer"])
        #expect(SettingsRegistry.search("zzzz-nothing").isEmpty && SettingsRegistry.search("   ").isEmpty)
        #expect(SettingsRegistry.search("hot key").map(\.id) == ["globalShortcuts"])
    }
    @Test func everySettingCanBeFoundByItsOwnTitle() {
        for definition in SettingsRegistry.definitions {
            #expect(SettingsRegistry.search(definition.title()).contains { $0.id == definition.id }, "\(definition.id) is searchable by its title")
        }
    }
}
