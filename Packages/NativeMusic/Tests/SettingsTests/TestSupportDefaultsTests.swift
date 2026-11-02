import Foundation
import Testing
import TestSupport

/// TH3: the two preference stores every test now uses (`InMemoryDefaults`, `ScratchDefaults`) and the path test that stops a store before it can name a real file. Names only:
/// the Preferences folder is listed, never read.
@Suite struct TestSupportDefaultsTests {
    static var preferencesFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true) }
    static func preferenceNames(containing fragment: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: preferencesFolder.path)) ?? []).filter { $0.contains(fragment) }
    }

    @Test func aScratchStoreIsARealStoreInsideItsOwnFolderAndLeavesNothingInPreferences() async throws {
        let scratch = ScratchDefaults(label: "probe")
        let id = scratch.folder.lastPathComponent
        #expect(id.hasPrefix("ytmuse-test-defaults-") && ScratchPaths.isThrowaway(scratch.path))
        #expect(scratch.folder.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        scratch.defaults.set("dark", forKey: "appearance"); scratch.defaults.set(3, forKey: "count"); scratch.defaults.synchronize()
        // A second instance over the same file sees what the first wrote (the real behaviour the Spotlight and update tests need).
        let again = scratch.reopen()
        #expect(again.string(forKey: "appearance") == "dark" && again.integer(forKey: "count") == 3)
        // The plist is in the scratch folder (cfprefsd writes it asynchronously).
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: scratch.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)); scratch.defaults.synchronize() }
        #expect(FileManager.default.fileExists(atPath: scratch.path), "the store's plist is inside the scratch folder")
        #expect(Self.preferenceNames(containing: id).isEmpty, "nothing with this store's name was created in ~/Library/Preferences")
        scratch.clean()
        #expect(!FileManager.default.fileExists(atPath: scratch.folder.path), "clean removes the folder and the plist")
        #expect(Self.preferenceNames(containing: id).isEmpty)
    }

    @Test func aScratchStoreIsRemovedWhenItsOwnerGoesAway() throws {
        var folder: URL?
        do { let scratch = ScratchDefaults(); scratch.defaults.set(1, forKey: "k"); folder = scratch.folder; #expect(FileManager.default.fileExists(atPath: scratch.folder.path)) }
        #expect(!FileManager.default.fileExists(atPath: try #require(folder).path), "deinit removed the folder")
    }

    @Test func thePathTestAcceptsOnlyAFileInsideTheTemporaryFolder() throws {
        let temporary = FileManager.default.temporaryDirectory
        let folder = temporary.appendingPathComponent("ytmuse-th3-paths-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        // A link inside the temporary folder that leaves it (to the account holder's Preferences folder: the link is only resolved, never written through).
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: Self.preferencesFolder)
        #expect(ScratchPaths.isThrowaway(folder.appendingPathComponent("x.plist").path), "a file in a folder inside the temporary folder")
        #expect(ScratchPaths.isThrowaway(temporary.appendingPathComponent("x.plist").path), "a file directly in the temporary folder")
        #expect(!ScratchPaths.isThrowaway(folder.appendingPathComponent("link/x.plist").path), "a link that leaves the temporary folder")
        #expect(!ScratchPaths.isThrowaway(temporary.path + "/../ytmuse-th3-escape.plist"), "a dot-dot escape")
        #expect(!ScratchPaths.isThrowaway(Self.preferencesFolder.appendingPathComponent("local.native-music.development.plist").path), "the Preferences folder")
        #expect(!ScratchPaths.isThrowaway(temporary.path + "/Library/Preferences/x.plist"), "a path that names a Preferences folder is never a throwaway, even under the temporary folder")
        #expect(!ScratchPaths.isThrowaway("ytmuse-settings-test-name"), "a bare suite name is a preferences domain, not a path")
        #expect(!ScratchPaths.isThrowaway("local.native-music.development"))
        #expect(!ScratchPaths.isThrowaway(""))
        // TH5 (TH3 critic L4): a link as the FILE itself (the folder test resolves only the folder), a dangling one, and `missing/../link/..`.
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("leaf.plist"), withDestinationURL: Self.preferencesFolder.appendingPathComponent("ytmuse-th5-never-created.plist"))
        #expect(!ScratchPaths.isThrowaway(folder.appendingPathComponent("leaf.plist").path), "a link as the file itself, dangling or not, even though its folder is inside the temporary folder")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("tmplink"), withDestinationURL: temporary)
        #expect(!ScratchPaths.isThrowaway(folder.path + "/missing/../link/../x.plist"), "missing/../link/.. walks out through the link on disk but collapses to the folder lexically")
        #expect(!ScratchPaths.isThrowaway(folder.path + "/./x.plist"), "a dot component is refused")
        // Control: a link INSIDE the temporary folder to a file also inside it is still a link, and refused; an ordinary new file beside it is accepted.
        #expect(!ScratchPaths.isThrowaway(folder.appendingPathComponent("tmplink").path), "any link as the leaf is refused")
        #expect(ScratchPaths.isThrowaway(folder.appendingPathComponent("new.plist").path), "control: a plain file name in the same folder is accepted")
        // The sibling-name case: a folder whose name merely starts with the temporary folder's name is not inside it.
        #expect(!ScratchPaths.isThrowaway(temporary.path + "-sibling/x.plist"), "a sibling folder named like the temporary folder plus a suffix")
        #expect(!ScratchPaths.isThrowaway("/Users/someone/Library/Preferences/x.plist"), "a Preferences path spelled out")
    }

    /// TH5 (TH3 critic L5): `InMemoryDefaults` must answer the way `UserDefaults` does, or a test that passes against it can fail (or pass wrongly) against the real thing.
    /// Every stored kind a product setting uses is read back through every scalar getter from both a real store (`ScratchDefaults`, a plist in its own folder) and the
    /// in-memory one, and the answers must be equal. The matrix has numbers, numeric strings, booleans and non-values; a getter that disagrees names the value.
    @Test func theInMemoryStoreConvertsNumbersAndStringsLikeARealStore() {
        let real = ScratchDefaults(label: "bridging"); defer { real.clean() }
        let memory = InMemoryDefaults()
        let stored: [(String, Any)] = [
            ("true", true), ("false", false), ("zero", 0), ("seven", 7), ("minus", -3), ("big", 300), ("float", Float(1.5)), ("double", 2.75), ("fraction", 0.5), ("negative double", -2.7), ("two point seven", 2.7),
            ("numeric string", "42"), ("decimal string", "3.9"), ("word", "abc"), ("yes", "YES"), ("lower yes", "yes"), ("true word", "true"), ("TRUE", "TRUE"), ("no", "no"), ("one", "1"), ("zero string", "0"), ("Yes", "Yes"), ("True", "True"), ("plus", "+5"), ("minus string", "-7"), ("Y", "Y"), ("t", "t"), ("2", "2"),
            ("empty", ""), ("padded", " 12 "), ("leading zero", "007"), ("exponent", "1e3"), ("data", Data([1, 2])), ("array", [1, 2]), ("strings", ["a", "b"]), ("mixed", ["a", 1]), ("dictionary", ["k": 1]),
        ]
        var disagreements: [String] = []
        for (name, value) in stored {
            real.defaults.set(value, forKey: name); memory.set(value, forKey: name)
            func check<T: Equatable>(_ getter: String, _ r: T, _ m: T) { if r != m { disagreements.append("\(name) \(getter): real \(r) memory \(m)") } }
            check("bool", real.defaults.bool(forKey: name), memory.bool(forKey: name))
            check("integer", real.defaults.integer(forKey: name), memory.integer(forKey: name))
            check("float", real.defaults.float(forKey: name), memory.float(forKey: name))
            check("double", real.defaults.double(forKey: name), memory.double(forKey: name))
            check("string", real.defaults.string(forKey: name), memory.string(forKey: name))
            check("data", real.defaults.data(forKey: name), memory.data(forKey: name))
            check("stringArray", real.defaults.stringArray(forKey: name), memory.stringArray(forKey: name))
            check("array", (real.defaults.array(forKey: name) as? [Int]), (memory.array(forKey: name) as? [Int]))
            check("dictionary", (real.defaults.dictionary(forKey: name) as? [String: Int]), (memory.dictionary(forKey: name) as? [String: Int]))
        }
        // A key nobody set reads as the zero value from both.
        #expect(real.defaults.bool(forKey: "absent") == memory.bool(forKey: "absent") && real.defaults.integer(forKey: "absent") == memory.integer(forKey: "absent")
                && real.defaults.string(forKey: "absent") == memory.string(forKey: "absent") && real.defaults.double(forKey: "absent") == memory.double(forKey: "absent"))
        #expect(disagreements.isEmpty, "in-memory answers that differ from a real store: \(disagreements)")
        // Control: the comparison can fail. A store that answered `integer(forKey:)` by an exact cast (the old behaviour) disagrees on 2.7.
        #expect(real.defaults.integer(forKey: "two point seven") == 2, "the real store truncates 2.7 to 2, so the matrix really exercises the conversion")
        #expect(real.defaults.integer(forKey: "numeric string") == 42 && real.defaults.string(forKey: "seven") == "7", "and reads numeric strings and numbers across kinds")
    }

    @Test func theInMemoryStoreAnswersEveryAccessorFromMemoryAndWritesNoFile() throws {
        func tempNames() -> Set<String> { Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("ytmuse-test-inmemory-") }) }
        let before = tempNames()
        let store = InMemoryDefaults()
        store.set(true, forKey: "bool"); store.set(7, forKey: "int"); store.set(Float(1.5), forKey: "float"); store.set(2.5, forKey: "double"); store.set("s", forKey: "string")
        store.set(Data([1, 2]), forKey: "data"); store.set(URL(string: "https://example.invalid/x"), forKey: "url"); store.set(["a", "b"], forKey: "strings")
        store.set(["k": 1], forKey: "dict"); store.set([1, 2], forKey: "array"); store.setValue("v", forKey: "kvc")
        #expect(store.bool(forKey: "bool") && store.integer(forKey: "int") == 7 && store.float(forKey: "float") == 1.5 && store.double(forKey: "double") == 2.5)
        #expect(store.string(forKey: "string") == "s" && store.data(forKey: "data") == Data([1, 2]) && store.url(forKey: "url")?.host == "example.invalid")
        #expect(store.stringArray(forKey: "strings") == ["a", "b"] && store.dictionary(forKey: "dict")?["k"] as? Int == 1 && (store.array(forKey: "array") as? [Int]) == [1, 2])
        #expect(store.object(forKey: "kvc") as? String == "v" && store.value(forKey: "kvc") as? String == "v")
        store.register(defaults: ["registered": "fallback"])
        #expect(store.string(forKey: "registered") == "fallback", "a registered default answers while nothing is set")
        store.set("own", forKey: "registered"); #expect(store.string(forKey: "registered") == "own")
        store.removeObject(forKey: "registered"); #expect(store.string(forKey: "registered") == "fallback", "removing falls back to the registered default")
        #expect(store.dictionaryRepresentation()["int"] as? Int == 7 && !store.isEmpty)
        _ = store.synchronize()
        for key in store.dictionaryRepresentation().keys { store.removeObject(forKey: key) }
        #expect(store.isEmpty, "removing every key empties the memory")
        #expect(tempNames().subtracting(before).isEmpty, "no file was created for the store, even after synchronize")
    }
}
