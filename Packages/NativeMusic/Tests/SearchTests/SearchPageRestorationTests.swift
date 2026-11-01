import AccountSession
import Foundation
import Testing
@testable import Features

/// W09-F2: the Search visit's memory (query, scope, selected result) and how it is put back.
@Suite @MainActor struct SearchPageRestorationTests {
    @Test func theVisitRecordsQueryScopeAndSelectionAndPutsThemBackWhenTheResultArrives() async throws {
        let rig = SearchKeyboardTests.Rig(); try await rig.load()
        let chosen = try #require(rig.model.results.dropFirst(2).first).id
        rig.model.selection = chosen
        let saved = rig.model.pageMemory
        #expect(saved.query == "café" && saved.selection == [chosen] && saved.values == ["scope": "all"])
        // The person searches for something else elsewhere in the window, then comes Back.
        rig.model.scope = .library; rig.model.query = "other"; await settle()
        #expect(rig.model.selection == nil)
        rig.model.restorePage(saved)
        #expect(rig.model.query == "café" && rig.model.scope == .all)
        #expect(rig.model.selection == nil, "results arrive after the query; the selection waits for the one it names")
        await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(await rig.remote.callCount - 1, with: reply(try parsedFixture("search-all-groups.json"))); await settle()
        #expect(rig.model.selection == chosen)
        #expect(rig.model.takeRestoredSelection(chosen) && !rig.model.takeRestoredSelection(chosen), "the list is told once not to scroll over the restored offset")
    }
    @Test func aClickOrKeyBeforeTheResultsArriveEndsThePendingSelection() async throws {
        let rig = SearchKeyboardTests.Rig(); try await rig.load()
        let chosen = try #require(rig.model.results.dropFirst(2).first).id
        rig.model.selection = chosen
        let saved = rig.model.pageMemory
        rig.model.query = "other"; await settle()
        rig.model.restorePage(saved)
        rig.model.selection = "something-else"      // the person acted first
        await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(await rig.remote.callCount - 1, with: reply(try parsedFixture("search-all-groups.json"))); await settle()
        #expect(rig.model.selection != chosen, "a restored selection never overrides what the person did since")
    }
    @Test func aNewQueryOrScopeEndsAPendingSelection() async throws {
        let rig = SearchKeyboardTests.Rig(); try await rig.load()
        let chosen = try #require(rig.model.results.dropFirst(2).first).id
        rig.model.selection = chosen
        let saved = rig.model.pageMemory
        rig.model.query = "other"; await settle()
        rig.model.restorePage(saved)
        rig.model.scope = .library; await settle()
        rig.model.scope = .all; rig.model.query = "café"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(await rig.remote.callCount - 1, with: reply(try parsedFixture("search-all-groups.json"))); await settle()
        #expect(rig.model.selection != chosen)
    }
    @Test func aFreshVisitHasNoSelectedResultButKeepsTheSearchTextAndScope() async throws {
        let rig = SearchKeyboardTests.Rig(); try await rig.load()
        rig.model.selection = try #require(rig.model.results.first).id
        rig.model.beginFreshVisit()
        #expect(rig.model.selection == nil, "a new visit starts with nothing selected")
        #expect(rig.model.query == "café" && rig.model.scope == .all, "the window has one search field: its text and scope carry")
    }
    @Test func anEmptyVisitRestoresAnEmptySearch() async throws {
        let rig = SearchKeyboardTests.Rig(); try await rig.load()
        let empty = PageMemory(query: "", selection: [], values: ["scope": "all"])
        rig.model.restorePage(empty)
        #expect(rig.model.query.isEmpty && rig.model.selection == nil && rig.model.scope == .all)
    }
}
