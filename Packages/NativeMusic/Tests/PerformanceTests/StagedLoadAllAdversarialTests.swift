import AccountSession
@testable import Features
import Foundation
import Testing
@testable import AppShell

// Adopted from the W44-prep critic's evidence (artifacts/harness/critiques/W44-prep-opus-01): adversarial checks of the staged-loadAll LibraryCollectionModel
// against an unoptimised reference. Each guard here was deleted by a mutation that the first worker tests did not notice; see the W44-prep rework record.

/// A continuer that can be held at one token until released, so a test can change the model while a page is in flight.
@MainActor private final class StageGate {
    var holdToken: String?
    var continuation: CheckedContinuation<Void, Never>?
    var reached = false
    func pass(_ token: String) async {
        guard token == holdToken else { return }
        reached = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil; holdToken = nil }
}

/// The original (pre-W44) id numbering: a plain walk over every item read, counting earlier rows of the same item id; true duplicates by occurrence id dropped.
private func referenceIDs(_ items: [MusicCatalogItem]) -> [String] {
    var seen = Set<String>(), counts: [String: Int] = [:], ids: [String] = []
    for item in items {
        if let occurrence = item.occurrenceID, !seen.insert(occurrence).inserted { continue }
        let earlier = counts[item.id, default: 0]; counts[item.id] = earlier + 1
        ids.append(earlier == 0 ? item.id : item.id + "#\(earlier)")
    }
    return ids
}

@Suite("Library model: staged loadAll under adversarial sequences")
@MainActor
struct StagedLoadAllAdversarialTests {
    /// Pages of 7 items; items repeat across page boundaries and some carry occurrence ids that recur later (true duplicates).
    nonisolated static func pageItems(_ index: Int) -> [MusicCatalogItem] {
        (0..<7).map { k in
            let n = index * 7 + k
            let id = "s\(n % 11)"                                  // ids repeat every 11 items: repeats straddle page boundaries
            let occurrence: String? = n % 5 == 0 ? "o\(n % 15)" : nil // occurrence ids recur: true duplicates across pages
            return MusicCatalogItem(kind: .song, title: "Title \(n % 13) Café", details: ["Artist \(n % 3)"], videoID: id, occurrenceID: occurrence)
        }
    }
    nonisolated static let pages = 40
    nonisolated static func counted(_ items: [MusicCatalogItem]) -> MusicParseAccounting { var a = MusicParseAccounting(); a.items = items.count; a.classified = items.count; return a }

    private func make(gate: StageGate, scope: @escaping @MainActor () -> String = { "" }) -> LibraryCollectionModel {
        LibraryCollectionModel(source: LibrarySource(kind: .songs),
            reader: { _ in
                let items = Self.pageItems(0)
                return MusicBrowseReply(value: MusicBrowsePage(shelves: [MusicShelf(key: "list:", title: nil, layout: .list, items: items, continuation: "p1")], accounting: Self.counted(items)), mode: .signedIn, accountGeneration: 0)
            },
            continuer: { token in
                await gate.pass(token)
                let index = Int(token.dropFirst())!
                let items = Self.pageItems(index)
                return MusicBrowseReply(value: MusicContinuationPage(items: items, shelves: [], continuation: index + 1 < Self.pages ? "p\(index + 1)" : nil, accounting: Self.counted(items)), mode: .signedIn, accountGeneration: 0)
            },
            accountScope: scope)
    }

    @Test func mixedLoadAllAndLoadMoreNumberLikeAPlainWalk() async throws {
        let gate = StageGate(); let model = make(gate: gate)
        await model.load()
        await model.loadMore(); await model.loadMore()
        // a loadAll that is stopped part-way by a page bound is not available; stop it with a failure-free cancellation-free path: read all
        _ = await model.loadAll()
        let all = (0..<Self.pages).flatMap(Self.pageItems)
        #expect(model.entries.map(\.id) == referenceIDs(all))
        #expect(model.entries.map(\.ordinal) == Array(0..<model.entries.count))
        #expect(model.accountedFor)
    }

    @Test func accountChangeDuringAStagedLoadAllLeavesNothingOfTheOldScope() async throws {
        let gate = StageGate(); let model = make(gate: gate)
        await model.load()
        gate.holdToken = "p20"                                    // hold page 20: pages 1-19 are staged, not yet all published
        let task = Task { await model.loadAll() }
        while !gate.reached { await Task.yield() }
        model.accountChanged()
        gate.release()
        _ = await task.value
        #expect(model.entries.isEmpty, "rows of the old scope must not be published after the account changed: \(model.entries.count)")
        #expect(model.visibleEntries.isEmpty)
    }

    @Test func refreshDuringAStagedLoadAllGivesAConsistentList() async throws {
        let gate = StageGate(); let model = make(gate: gate)
        await model.load()
        gate.holdToken = "p20"
        let task = Task { await model.loadAll() }
        while !gate.reached { await Task.yield() }
        await model.refresh()                                     // replaces the rows with page 0 again; the held page must be dropped
        gate.release()
        _ = await task.value
        let ids = model.entries.map(\.id)
        #expect(Set(ids).count == ids.count, "ids are unique")
        #expect(model.entries.map(\.ordinal) == Array(0..<ids.count), "ordinals are consecutive")
        // Whatever was read after the refresh, it must be a prefix of a plain walk from the start.
        let all = referenceIDs((0..<Self.pages).flatMap(Self.pageItems))
        #expect(Array(all.prefix(ids.count)) == ids, "the list after a refresh is a prefix of the plain walk")
        // Reading on to the end then gives the full plain walk.
        _ = await model.loadAll()
        #expect(model.entries.map(\.id) == all)
    }

    @Test func queryAndSortChangesWhileStagedPagesArriveFollowEveryInput() async throws {
        let gate = StageGate(); let model = make(gate: gate)
        await model.load()
        gate.holdToken = "p20"
        let task = Task { await model.loadAll() }
        while !gate.reached { await Task.yield() }
        for sort in LibrarySort.allCases {
            model.sort = sort
            for query in ["", "cafe", "title 1", "ARTIST 2"] {
                model.query = query
                let reference = sort.apply(model.entries.filter { query.isEmpty || LibraryCollectionModel.matches($0, query) }).map(\.id)
                #expect(model.visibleEntries.map(\.id) == reference, "\(sort) \(query) mid-load")
            }
        }
        gate.release()
        _ = await task.value
        for sort in LibrarySort.allCases {
            model.sort = sort
            for query in ["", "cafe", "title 1", "ARTIST 2"] {
                model.query = query
                let reference = sort.apply(model.entries.filter { query.isEmpty || LibraryCollectionModel.matches($0, query) }).map(\.id)
                #expect(model.visibleEntries.map(\.id) == reference, "\(sort) \(query) after load")
            }
        }
    }

    @Test func aRefreshThatChangesOneTitleKeepsIdsButMakesANewGenerationAndAnUnequalList() async throws {
        final class TitleBox: @unchecked Sendable { var title = "Before" }
        let box = TitleBox()
        let model = LibraryCollectionModel(source: LibrarySource(kind: .songs),
            reader: { _ in
                let items = [MusicCatalogItem(kind: .song, title: "A", videoID: "a"), MusicCatalogItem(kind: .song, title: box.title, videoID: "b")]
                return MusicBrowseReply(value: MusicBrowsePage(shelves: [MusicShelf(key: "list:", title: nil, layout: .list, items: items, continuation: nil)], accounting: Self.counted(items)), mode: .signedIn, accountGeneration: 0)
            }, continuer: { _ in throw MusicSessionError.unrecognised })
        await model.load()
        let first = model.visibleEntries, g1 = model.visibleGeneration
        _ = model.visibleEntries
        #expect(model.visibleGeneration == g1, "a cache hit keeps the generation")
        box.title = "After"
        await model.refresh()
        let second = model.visibleEntries
        #expect(second.map(\.id) == first.map(\.id))
        #expect(second.map(\.item.title) == ["A", "After"])
        #expect(model.visibleGeneration != g1, "a changed row must change the generation the equatable list compares")
        }

    // MARK: Bounds and headings on the staged path (mutations the first worker tests let survive)

    @Test func theRowBoundHoldsWhileLoadAllStagesPagesBeforeAnythingIsPublished() async throws {
        // Pages of 100 from a source that never ends. With staging, `entries.count` stays at 100 until a flush, so a bound checked on the published rows only
        // would let this run to the page bound; the bound is on the rows READ (published plus staged).
        @Sendable func page(_ index: Int) -> [MusicCatalogItem] { (0..<100).map { MusicCatalogItem(kind: .song, title: "S \(index)-\($0)", videoID: "v\(index)x\($0)") } }
        let model = LibraryCollectionModel(source: LibrarySource(kind: .songs),
            reader: { _ in
                let items = page(0)
                return MusicBrowseReply(value: MusicBrowsePage(shelves: [MusicShelf(key: "list:", title: nil, layout: .list, items: items, continuation: "p1")], accounting: Self.counted(items)), mode: .signedIn, accountGeneration: 0)
            },
            continuer: { token in
                let index = Int(token.dropFirst())!
                let items = page(index)
                return MusicBrowseReply(value: MusicContinuationPage(items: items, shelves: [], continuation: "p\(index + 1)", accounting: Self.counted(items)), mode: .signedIn, accountGeneration: 0)
            },
            maximumEntries: 250, maximumPages: 1_000)
        await model.load()
        let complete = await model.loadAll()
        #expect(!complete, "a bounded read is not complete")
        #expect(model.entries.count <= 300, "the 250-row bound held on the staged path (read \(model.entries.count) rows)")
        #expect(model.entries.count >= 250)
        #expect(model.hasMore)
    }
    @Test func rowsContinueUnderTheHeadingOfTheLastRowReadEvenWhenThatRowIsStillStaged() async throws {
        @Sendable func counted(_ items: [MusicCatalogItem]) -> MusicParseAccounting { var a = MusicParseAccounting(); a.items = items.count; a.classified = items.count; return a }
        @Sendable func songs(_ prefix: String) -> [MusicCatalogItem] { (0..<3).map { MusicCatalogItem(kind: .song, title: "\(prefix) \($0)", videoID: "\(prefix)\($0)") } }
        let model = LibraryCollectionModel(source: LibrarySource(kind: .songs),
            reader: { _ in
                let items = songs("a")
                return MusicBrowseReply(value: MusicBrowsePage(shelves: [MusicShelf(key: "list:Today", title: "Today", layout: .list, items: items, continuation: "p1")], accounting: counted(items)), mode: .signedIn, accountGeneration: 0)
            },
            continuer: { token in
                // Page 1 brings a NEW shelf (a new heading); page 2 is bare items that continue it.
                if token == "p1" {
                    let items = songs("b")
                    return MusicBrowseReply(value: MusicContinuationPage(items: [], shelves: [MusicShelf(key: "list:Yesterday", title: "Yesterday", layout: .list, items: items, continuation: "p2")], continuation: nil, accounting: counted(items)), mode: .signedIn, accountGeneration: 0)
                }
                let items = songs("c")
                return MusicBrowseReply(value: MusicContinuationPage(items: items, shelves: [], continuation: nil, accounting: counted(items)), mode: .signedIn, accountGeneration: 0)
            })
        await model.load()
        _ = await model.loadAll()
        #expect(model.entries.map(\.section) == Array(repeating: "Today", count: 3) + Array(repeating: "Yesterday", count: 6),
                "page 2's rows continue 'Yesterday' (read from the staged rows of page 1), not 'Today'")
    }

    @Test func theSavedCopyFollowsTheTokensEvenWhenTheLastPageAddedNoRows() async throws {
        // The first page offers token p1; p1 answers with the very same rows again (the service replaying a page) and no further token. Nothing new is added, but paging
        // ended: the saved copy for the scope must say "nothing left to read", not keep offering p1 (which a later load() from the saved copy would read again).
        @Sendable func counted(_ items: [MusicCatalogItem]) -> MusicParseAccounting { var a = MusicParseAccounting(); a.items = items.count; a.classified = items.count; return a }
        let items = (0..<3).map { MusicCatalogItem(kind: .song, title: "R \($0)", videoID: "r\($0)") }
        let model = LibraryCollectionModel(source: LibrarySource(kind: .songs),
            reader: { _ in MusicBrowseReply(value: MusicBrowsePage(shelves: [MusicShelf(key: "list:", title: nil, layout: .list, items: items, continuation: "p1")], accounting: counted(items)), mode: .signedIn, accountGeneration: 0) },
            continuer: { _ in MusicBrowseReply(value: MusicContinuationPage(items: items, shelves: [], continuation: nil, accounting: counted(items)), mode: .signedIn, accountGeneration: 0) })
        await model.load()
        #expect(model.savedState(scope: "")?.tokens == ["p1"])
        _ = await model.loadAll()
        #expect(model.replayedPages == 1 && model.entries.count == 3 && !model.hasMore)
        #expect(model.savedState(scope: "")?.tokens == [], "the saved copy no longer offers the page that ended paging")
        #expect(model.savedState(scope: "")?.entries == 3)
    }
}
