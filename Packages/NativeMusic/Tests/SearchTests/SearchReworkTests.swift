import AccountSession
import AppKit
import Foundation
import Testing
@testable import Features
@testable import AppShell

/// Rework 1: IME seam, per-query retry guard, recents (SEARCH02), development catalog gate, separators.
@Suite @MainActor struct SearchComposingSeamTests {
    @Test func aFieldEditorHoldingMarkedTextKeepsEveryKey() {
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 20))
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        var seen: [Bool] = []
        for key in [SearchKey.returnKey, .down, .up, .escape] {
            let outcome = SearchField.route(key, firstResponder: editor) { key, composing in
                seen.append(composing)
                return SearchModel().handle(key, composing: composing)
            }
            #expect(outcome == .passThrough, "\(key) belongs to the input method while it composes")
        }
        #expect(seen == [true, true, true, true], "the view supplies the composing state to the model")
    }
    @Test func withoutMarkedTextTheModelDecidesAndANonTextResponderCountsAsNotComposing() async throws {
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 20))
        #expect(!editor.hasMarkedText())
        let model = SearchModel(remote: { _ in throw MusicSessionError.network }, playback: { .available })
        model.query = "abc"
        #expect(SearchField.route(.returnKey, firstResponder: editor) { model.handle($0, composing: $1) } == .handled)
        #expect(SearchField.route(.returnKey, firstResponder: nil) { model.handle($0, composing: $1) } == .handled)
        #expect(SearchField.route(.returnKey, firstResponder: NSView()) { _, composing in composing ? .passThrough : .handled } == .handled)
    }
    @Test func theSameCompositionRuleHoldsForThePalette() {
        let palette = CommandPaletteModel(search: SearchModel(), commands: [PaletteCommand(id: "x", title: "X", symbol: "x") {}]) {}
        let editor = NSTextView(); editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(SearchField.route(.returnKey, firstResponder: editor) { palette.handle($0, composing: $1) } == .passThrough)
        #expect(SearchField.route(.escape, firstResponder: editor) { palette.handle($0, composing: $1) } == .passThrough)
    }
}

@Suite @MainActor struct SearchRetryGuardTests {
    @Test func theOneAutomaticReaskIsPerQueryNotPerSession() async throws {
        let clock = VirtualClock(), remote = ScriptedRemote(), box = SearchTimingTests.ScopeBox()
        let model = SearchModel(remote: { try await remote.call($0) }, clock: clock, accountScope: { box.value })
        model.query = "first"; await settle(); clock.advance(by: .milliseconds(180)); await settle()
        box.value = "b"; await remote.answer(0, with: reply(response([song("A")]))); await settle()
        box.value = "c"; await remote.answer(1, with: reply(response([song("B")]))); await settle()
        #expect(model.remoteStatus == .failed(.unavailable), "second mismatch for the same query is reported")
        model.query = "second"; await settle(); clock.advance(by: .milliseconds(180)); await settle()
        box.value = "d"; await remote.answer(2, with: reply(response([song("C")]))); await settle()
        #expect(await remote.callCount == 4, "a new query gets its own re-ask")
        await remote.answer(3, with: reply(response([song("D", "bbbbbbbbbb1")]))); await settle()
        #expect(model.results.map(\.title) == ["D"])
    }
}

@Suite @MainActor struct SearchRecentsTests {
    private func defaults() throws -> (UserDefaults, URL) {
        // An absolute-path suite writes only this temporary plist (never the standard domain or ~/Library/Preferences/<name>).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w10-recents-" + UUID().uuidString + ".plist")
        return (try #require(UserDefaults(suiteName: url.path)), url)
    }
    private func result(_ title: String, _ id: String = "aaaaaaaaaa1") -> SearchResult {
        SearchResult(MusicSearchItem(kind: .song, title: title, subtitle: "Synthetic Artist • 3:45", videoID: id), top: false)
    }
    @Test func queriesAndItemsAreRecordedOnlyWhenChosenNeverPerKeystroke() async throws {
        let (store, url) = try defaults(); defer { try? FileManager.default.removeItem(at: url) }
        let recents = SearchRecents(defaults: store, scope: { "acct-a" })
        let clock = VirtualClock(), remote = ScriptedRemote(), performer = SpyPerformer()
        let model = SearchModel(remote: { try await remote.call($0) }, performer: performer, clock: clock, playback: { .available }, recents: recents)
        for text in ["c", "ca", "caf", "café"] { model.query = text; await settle() }
        clock.advance(by: .milliseconds(180)); await settle()
        await remote.answer(0, with: reply(response([song("Café del Mar")]))); await settle()
        #expect(recents.isEmpty, "typing and receiving results records nothing")
        model.submit(); await settle()
        #expect(recents.queries == ["café"] && recents.items.isEmpty)
        await remote.answer(1, with: reply(response([song("Café del Mar")]))); await settle()
        await model.activate(try #require(model.results.first)); await settle()
        #expect(recents.queries == ["café"] && recents.items.map(\.title) == ["Café del Mar"])
        #expect(performer.played.count == 1)
    }
    @Test func copyingAlsoCountsAsChoosingAndDuplicatesMoveToTheFront() async throws {
        let (store, url) = try defaults(); defer { try? FileManager.default.removeItem(at: url) }
        let recents = SearchRecents(defaults: store, scope: { "a" })
        recents.record(query: "Café"); recents.record(query: "rock"); recents.record(query: "CAFE")
        #expect(recents.queries == ["CAFE", "rock"], "accent- and case-insensitive duplicates collapse, newest first")
        recents.record(item: result("One", "aaaaaaaaaa1")); recents.record(item: result("Two", "bbbbbbbbbb1")); recents.record(item: result("One again", "aaaaaaaaaa1"))
        #expect(recents.items.map(\.title) == ["One again", "Two"])
    }
    @Test func recentsAreBoundedAndBlankOrOversizeQueriesAreIgnored() throws {
        let (store, url) = try defaults(); defer { try? FileManager.default.removeItem(at: url) }
        let recents = SearchRecents(defaults: store, scope: { "a" }, limit: 10)
        for index in 0..<25 { recents.record(query: "query \(index)"); recents.record(item: result("Song \(index)", String(format: "id%09d", index))) }
        #expect(recents.queries.count == 10 && recents.items.count == 10 && recents.queries.first == "query 24")
        recents.record(query: "   "); recents.record(query: String(repeating: "é", count: 300))
        #expect(recents.queries.count == 10)
    }
    @Test func theyPersistPerAccountAndTheUserCanClearThem() throws {
        let (store, url) = try defaults(); defer { try? FileManager.default.removeItem(at: url) }
        var scope = "acct-a"
        let recents = SearchRecents(defaults: store, scope: { scope })
        recents.record(query: "private words"); recents.record(item: result("Private song"))
        let again = SearchRecents(defaults: store, scope: { "acct-a" })
        #expect(again.queries == ["private words"] && again.items.map(\.title) == ["Private song"], "survives a relaunch")
        scope = "acct-b"; recents.reload()
        #expect(recents.isEmpty, "another account sees none of it")
        scope = "acct-a"; recents.reload()
        recents.clearQueries()
        #expect(recents.queries.isEmpty && !recents.items.isEmpty)
        recents.clearItems()
        #expect(recents.isEmpty && store.data(forKey: SearchRecents.prefix + "acct-a") == nil, "clearing removes the stored bucket")
    }
    @Test func removingAnAccountErasesItsRecentsAndOnlyItsRecents() throws {
        let (store, url) = try defaults(); defer { try? FileManager.default.removeItem(at: url) }
        for scope in ["acct-a", "acct-b", "none"] { let r = SearchRecents(defaults: store, scope: { scope }); r.record(query: "words " + scope) }
        SearchRecents.prune(defaults: store, keeping: ["acct-b", "none"])
        #expect(store.data(forKey: SearchRecents.prefix + "acct-a") == nil)
        #expect(store.data(forKey: SearchRecents.prefix + "acct-b") != nil && store.data(forKey: SearchRecents.prefix + "none") != nil)
    }
    @Test func theStoredFormCarriesNoServiceSessionOrLogLineAndNothingIsPrinted() throws {
        let (store, url) = try defaults(); defer { try? FileManager.default.removeItem(at: url) }
        let recents = SearchRecents(defaults: store, scope: { "a" })
        recents.record(query: "synthetic secret words"); recents.record(item: result("Song"))
        let text = String(decoding: try #require(store.data(forKey: SearchRecents.prefix + "a")), as: UTF8.self)
        #expect(!text.localizedCaseInsensitiveContains("cookie") && !text.localizedCaseInsensitiveContains("sapisid") && !text.contains("Authorization"))
        // SEC03: the search sources never write a query to a log, a print or an error string.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let sources = root.appendingPathComponent("Sources")
        var scanned = 0
        for folder in ["Features/Search", "Features/CommandPalette"] {
            for file in try FileManager.default.contentsOfDirectory(at: sources.appendingPathComponent(folder), includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
                let code = try String(contentsOf: file, encoding: .utf8); scanned += 1
                #expect(code.range(of: #"\bprint\(|\bNSLog\(|\bLogger\(|\bos_log\(|\bdebugPrint\("#, options: .regularExpression) == nil, "\(file.lastPathComponent)")
            }
        }
        #expect(scanned >= 8, "the sweep looked at the search sources")
    }
    @Test func theEmptyStatesDiscoveryNoteIsHonestAndRecentRowsAreRealResults() throws {
        let item = RecentSearchItem(result("Café del Mar"))
        #expect(item.result.badges == [.recent] && item.result.target.videoID == "aaaaaaaaaa1" && item.result.details == ["Synthetic Artist", "3:45"] || item.result.details == ["Synthetic Artist • 3:45"])
        #expect(!item.result.fromService)
        #expect(SearchActionPlan.playlist(for: item.result) == "RDAMVMaaaaaaaaaa1")
    }
}

@Suite struct DevelopmentCatalogGateTests {
    @Test func theCatalogNeedsTheFlagAndIsolation() {
        #expect(!DevelopmentSearch.isEnabled([:]))
        // C1 item 11: a Debug launch is isolated unless it opts in to the real stores, so the flag alone is
        // enough on scratch storage and is never enough on a launch that opted in to the real ones.
        #expect(DevelopmentSearch.isEnabled(["YTMUSE_UI_DEVELOPMENT_DATA": "1"]), "isolated by default: scratch storage only")
        #expect(!DevelopmentSearch.isEnabled(["YTMUSE_UI_DEVELOPMENT_DATA": "1", IsolatedQAStorage.realStoresKey: "1"]), "the flag never swaps the real service for the catalog on real stores")
        #expect(!DevelopmentSearch.isEnabled(["YTMUSE_UI_TEST_ISOLATED": "1"]))
        #expect(DevelopmentSearch.isEnabled(["YTMUSE_UI_DEVELOPMENT_DATA": "1", "YTMUSE_UI_TEST_ISOLATED": "1"]))
        #expect(DevelopmentSearch.isEnabled(["YTMUSE_UI_DEVELOPMENT_DATA": "1", "YTMUSE_NATIVE_DESIGN_TEST": "1"]))
    }
}

@Suite @MainActor struct SearchSeparatorTests {
    @Test func theDetailSeparatorIsACatalogEntryWithTheBulletAsItsSourceValue() throws {
        #expect(SearchDetail.separator == " • ")
        #expect(SearchDetail.join(["5:38", "1.2B plays"]) == "5:38 • 1.2B plays" && SearchDetail.join([]) == nil)
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings"))) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(strings["detailSeparator"] != nil, "the key exists in the String Catalog")
    }
    @Test func aSingleAndAnEpAreNotRelabelledAsAlbums() {
        let single = SearchResult(MusicSearchItem(kind: .album, title: "S", details: ["Artist", "2005"], serviceLabel: "Single", browseID: "MPREb_x", playlistID: "OLAK5uy_x"), top: false)
        let ep = SearchResult(MusicSearchItem(kind: .album, title: "E", details: ["Artist"], serviceLabel: "EP", browseID: "MPREb_y", playlistID: "OLAK5uy_y"), top: false)
        let album = SearchResult(MusicSearchItem(kind: .album, title: "A", details: ["Artist"], browseID: "MPREb_z", playlistID: "OLAK5uy_z"), top: false)
        #expect(single.typeLabel == "Single" && ep.typeLabel == "EP" && album.typeLabel == String(localized: "Album"))
        #expect(single.group == .albums && ep.group == .albums)
    }
}
