import AccountSession
@testable import Features
import Foundation
import Testing
import YouTubeMusicAdapter

/// TH5F (TH5 critic L1, W44-prep L-c): rows are never saved or shown under another account's or scope's key. The shell learns of a change of account in a later turn
/// (`accountChanged()` from a SwiftUI `.onChange`), so the scope can move while a page is in flight, between the pages of a `loadAll`, or between two `loadMore` calls
/// with nothing in flight. Whatever the moment, rows read for scope-1 are not filed under scope-2, no page is read with scope-1's tokens for scope-2, and rows dropped
/// because the scope moved take the paging state they moved with them.
actor ScopeTokens {
    var pages: [String: MusicContinuationPage] = [:], holdOn: Set<String> = [], held: [CheckedContinuation<Void, Never>] = []
    private(set) var calls: [String] = []
    func set(_ token: String, _ page: MusicContinuationPage) { pages[token] = page }
    func hold(_ token: String) { holdOn.insert(token) }
    var heldCount: Int { held.count }
    func release() { holdOn = []; let all = held; held = []; for continuation in all { continuation.resume() } }
    func token(_ token: String) async throws -> MusicBrowseReply<MusicContinuationPage> {
        calls.append(token)
        if holdOn.contains(token) { await withCheckedContinuation { held.append($0) } }
        guard let page = pages[token] else { throw MusicSessionError.unrecognised }
        return MusicBrowseReply(value: page, mode: .signedIn, accountGeneration: 1)
    }
}
@MainActor @Suite struct LibraryScopeMoveTests {
    let songs = LibrarySource(kind: .songs)
    func rig(_ scope: Box<String>) async -> (LibraryCollectionModel, ScopeTokens) {
        let script = LibraryScript(), tokens = ScopeTokens()
        await script.setPage(songs.browseID, pageOf([item("A")], token: "t1"))
        await tokens.set("t1", continuationOf([item("B")], token: "t2"))
        await tokens.set("t2", continuationOf([item("C")], token: "t3"))
        await tokens.set("t3", continuationOf([item("D")]))
        let model = LibraryCollectionModel(source: songs, reader: { try await script.page($0) }, continuer: { try await tokens.token($0) }, accountScope: { scope.value },
                                           now: { Date(timeIntervalSince1970: 1_000_000) }, maximumPages: 400)
        return (model, tokens)
    }
    func waitHeld(_ tokens: ScopeTokens) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await tokens.heldCount == 0, ContinuousClock.now < deadline { await Task.yield() }
    }

    /// The scope moves while a LATER page of a `loadAll` is in flight (earlier pages already staged for scope-1).
    @Test func aMoveDuringALaterPageOfLoadAllSavesNothingUnderTheNewScopeAndKeepsTheOldPagingState() async throws {
        let scope = Box("scope-1"); let (model, tokens) = await rig(scope)
        await model.load()
        await tokens.hold("t2")
        let task = Task { await model.loadAll() }
        await waitHeld(tokens)
        let held = await tokens.heldCount
        #expect(held == 1, "the window is open: page t2 is in flight, page t1 is staged")
        scope.value = "scope-2"
        await tokens.release(); _ = await task.value
        #expect(model.savedState(scope: "scope-2") == nil, "nothing read for scope-1 is filed under scope-2: \(String(describing: model.savedState(scope: "scope-2")))")
        #expect(model.entries.map(\.item.title) == ["A"], "the staged page was dropped, not published: \(model.entries.map(\.item.title))")
        #expect(model.pendingTokens == ["t1"], "and the paging state went back with it, so the dropped page is read again by whoever continues: \(model.pendingTokens)")
        let saved = model.savedState(scope: "scope-1")
        #expect(saved?.entries == 1 && saved?.tokens == ["t1"], "scope-1's own saved copy is what it was: \(String(describing: saved))")
        // Control: no move, same walk, everything is read and saved under the scope it was read for.
        let steady = Box("scope-1"); let (control, _) = await rig(steady)
        await control.load()
        let complete = await control.loadAll()
        #expect(complete && control.entries.map(\.item.title) == ["A", "B", "C", "D"] && control.savedState(scope: "scope-1")?.entries == 4 && control.savedState(scope: "scope-2") == nil)
    }
    /// The scope moves BETWEEN two `loadMore` calls, nothing in flight, before `accountChanged()`.
    @Test func aMoveBetweenTwoLoadMoreCallsReadsNothingMoreAndSavesNothingUnderTheNewScope() async throws {
        let scope = Box("scope-1"); let (model, tokens) = await rig(scope)
        await model.load(); await model.loadMore()
        #expect(model.entries.map(\.item.title) == ["A", "B"] && model.pendingTokens == ["t2"])
        scope.value = "scope-2"
        await model.loadMore()
        #expect(model.savedState(scope: "scope-2") == nil, "scope-1's rows are not filed under scope-2: \(String(describing: model.savedState(scope: "scope-2")))")
        #expect(model.entries.map(\.item.title) == ["A", "B"] && model.pendingTokens == ["t2"], "nothing was added and the tokens did not move")
        let calls = await tokens.calls
        #expect(calls == ["t1"], "no page was requested with scope-1's token for scope-2: \(calls)")
        // The shell then catches up: a clean slate, read again from the first page under the new scope.
        model.accountChanged()
        await model.load()
        #expect(model.entries.map(\.item.title) == ["A"] && model.pendingTokens == ["t1"] && model.savedState(scope: "scope-2")?.entries == 1)
    }
    /// The same two moves with the scope coming BACK: the first account's rows are still its own, and the paging resumes where it was.
    @Test func ifTheScopeComesBackPagingResumesWhereItWas() async throws {
        let scope = Box("scope-1"); let (model, _) = await rig(scope)
        await model.load(); await model.loadMore()
        scope.value = "scope-2"
        await model.loadMore()
        scope.value = "scope-1"
        await model.loadMore()
        #expect(model.entries.map(\.item.title) == ["A", "B", "C"] && model.pendingTokens == ["t3"] && model.savedState(scope: "scope-1")?.entries == 3 && model.savedState(scope: "scope-2") == nil)
    }
}
