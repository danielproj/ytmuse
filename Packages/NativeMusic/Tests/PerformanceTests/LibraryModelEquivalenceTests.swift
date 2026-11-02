import AccountSession
@testable import Features
import Foundation
import Testing
@testable import AppShell

/// W44-prep fixes to `LibraryCollectionModel` (incremental paging index, cached search/sort): they must change the cost, never the answer.
/// The reference for search is the original per-row locale-aware match; for sort, `LibrarySort.apply`; for paging, a plain walk over everything read.
@Suite("Library model: faster, same answers")
@MainActor
struct LibraryModelEquivalenceTests {
    private func model(songs: Int = 3_000, pageSize: Int = 100) async -> LibraryCollectionModel {
        let scale = DevelopmentPerformance.Scale(songs: songs, playlists: 10, bigPlaylistEntries: 100, queueItems: 100, pageSize: pageSize, repeatEvery: 40)
        let model = LibraryCollectionModel(source: LibrarySource(kind: .songs),
                                           reader: { _ in MusicBrowseReply(value: DevelopmentPerformance.libraryPage(for: .songs, scale: scale)!, mode: .signedIn, accountGeneration: 0) },
                                           continuer: { token in MusicBrowseReply(value: DevelopmentPerformance.continuation(token, scale: scale)!, mode: .signedIn, accountGeneration: 0) })
        await model.load()
        _ = await model.loadAll()
        return model
    }
    @Test func searchGivesTheOriginalRulesAnswerForAccentedWideAndMixedCaseQueries() async throws {
        let model = await model()
        try #require(model.entries.count == 3_000)
        for query in ["cafe", "CAFÉ", "  café   noche ", "angstrom", "ÅNGSTRÖM", "ünder", "under", "ete", "été", "zeta 12", "blue", "(live", "synthetic hall", "artist 5", "ｃａｆｅ", "nothing matches this", "Ocean Blue 4"] {
            model.query = query
            let expected = model.entries.filter { LibraryCollectionModel.matches($0, query.trimmingCharacters(in: .whitespacesAndNewlines)) }.map(\.id)
            #expect(model.visibleEntries.map(\.id) == expected, "query \(query.debugDescription)")
        }
        model.query = "cafe"
        #expect(!model.visibleEntries.isEmpty)
    }
    @Test func sortsKeepTheirOrderWithAndWithoutAQueryAndAfterMoreRowsArrive() async throws {
        let model = await model(songs: 1_000)
        for sort in LibrarySort.allCases {
            model.sort = sort; model.query = ""
            #expect(model.visibleEntries.map(\.id) == sort.apply(model.entries).map(\.id), "\(sort)")
            model.query = "synthetic album 3"
            let filteredThenSorted = sort.apply(model.entries.filter { LibraryCollectionModel.matches($0, "synthetic album 3") }).map(\.id)
            #expect(model.visibleEntries.map(\.id) == filteredThenSorted, "\(sort) with a query")
        }
    }
    @Test func theCachedViewFollowsEveryInputThatChangesIt() async throws {
        let model = LibraryCollectionModel(source: LibrarySource(kind: .songs),
                                           reader: { _ in MusicBrowseReply(value: DevelopmentPerformance.libraryPage(for: .songs, scale: .init(songs: 250, pageSize: 100))!, mode: .signedIn, accountGeneration: 0) },
                                           continuer: { token in MusicBrowseReply(value: DevelopmentPerformance.continuation(token, scale: .init(songs: 250, pageSize: 100))!, mode: .signedIn, accountGeneration: 0) })
        await model.load()
        model.sort = .titleAscending
        #expect(model.visibleEntries.count == 100)
        await model.loadMore()
        #expect(model.visibleEntries.count == 200, "rows read after the view was cached are in the next one")
        model.query = "zzzz"
        #expect(model.visibleEntries.isEmpty)
        model.query = ""
        #expect(model.visibleEntries.count == 200)
        model.sort = .titleDescending
        #expect(model.visibleEntries.first?.id == model.entries.sorted { $0.item.title.localizedStandardCompare($1.item.title) == .orderedDescending }.first?.id)
        model.accountChanged()
        #expect(model.visibleEntries.isEmpty, "nothing read for the old scope stays visible")
    }
    @Test func pagingNumbersRepeatsAndDropsReplayedOccurrencesAcrossPageBoundaries() async throws {
        // Page 1: A, B, A(occurrence o1), C(occ o9). Page 2: A again (a repeat, kept as A#2... by count), C(occ o9) (a true duplicate, dropped), D.
        func song(_ id: String, occurrence: String? = nil) -> MusicCatalogItem { MusicCatalogItem(kind: .song, title: id, videoID: id, occurrenceID: occurrence) }
        func counted(_ items: [MusicCatalogItem]) -> MusicParseAccounting { var a = MusicParseAccounting(); a.items = items.count; a.classified = items.count; return a }
        let first = [song("A"), song("B"), song("A"), song("C", occurrence: "o9")]
        let second = [song("A"), song("C", occurrence: "o9"), song("D")]
        let model = LibraryCollectionModel(source: LibrarySource(kind: .songs),
                                           reader: { _ in
                                               var accounting = MusicParseAccounting(); accounting.items = first.count; accounting.classified = first.count
                                               return MusicBrowseReply(value: MusicBrowsePage(shelves: [MusicShelf(key: "list:", title: nil, layout: .list, items: first, continuation: "t2")], accounting: accounting), mode: .signedIn, accountGeneration: 0)
                                           },
                                           continuer: { _ in
                                               var accounting = MusicParseAccounting(); accounting.items = second.count; accounting.classified = second.count
                                               return MusicBrowseReply(value: MusicContinuationPage(items: second, shelves: [], continuation: nil, accounting: accounting), mode: .signedIn, accountGeneration: 0)
                                           })
        await model.load(); await model.loadMore()
        #expect(model.entries.map(\.id) == ["song:A", "song:B", "song:A#1", "song#o9", "song:A#2", "song:D"])
        #expect(model.occurrenceDuplicates == 1)
        #expect(model.entries.map(\.ordinal) == Array(0..<6))
        #expect(model.entries.map(\.repeats) == [false, false, true, false, true, false])
        // Refreshing replaces the rows and the index with them: the same page again numbers from scratch, not from the old counts.
        await model.refresh()
        #expect(model.entries.map(\.id) == ["song:A", "song:B", "song:A#1", "song#o9"])
    }

    @Test func loadAllGivesTheRowsOfPageByPageReadingButShowsThemInFewSteps() async throws {
        let scale = DevelopmentPerformance.Scale(songs: 6_000, playlists: 10, bigPlaylistEntries: 100, queueItems: 100, pageSize: 100, repeatEvery: 40)
        func make(_ shown: Box) -> LibraryCollectionModel {
            LibraryCollectionModel(source: LibrarySource(kind: .songs),
                                   reader: { _ in MusicBrowseReply(value: DevelopmentPerformance.libraryPage(for: .songs, scale: scale)!, mode: .signedIn, accountGeneration: 0) },
                                   continuer: { token in
                                       await shown.record()
                                       return MusicBrowseReply(value: DevelopmentPerformance.continuation(token, scale: scale)!, mode: .signedIn, accountGeneration: 0)
                                   })
        }
        let allAtOnce = Box(), oneByOne = Box()
        let fast = make(allAtOnce), slow = make(oneByOne)
        await allAtOnce.attach(fast); await oneByOne.attach(slow)
        await fast.load(); await slow.load()
        _ = await fast.loadAll()
        while slow.hasMore { await slow.loadMore() }
        #expect(fast.entries.map(\.id) == slow.entries.map(\.id))
        #expect(fast.entries.map(\.ordinal) == Array(0..<6_000))
        #expect(fast.accounting.items == slow.accounting.items && fast.occurrenceDuplicates == slow.occurrenceDuplicates && fast.isComplete)
        // The rows the screen was handed changed in a handful of steps (not 59), while page-by-page reading changed it on every page.
        let steps = await allAtOnce.distinctCounts, slowSteps = await oneByOne.distinctCounts
        #expect(steps.count <= 6, "loadAll showed the list in \(steps.count) steps: \(steps)")
        #expect(slowSteps.count == 59)
        // Every id is unique (repeats are numbered); mixing loadAll and loadMore is covered by `StagedLoadAllAdversarialTests`.
        #expect(Set(fast.entries.map(\.id)).count == 6_000)
    }
}

/// Records how many rows the model showed each time it was asked for a page.
@MainActor private final class Box {
    weak var model: LibraryCollectionModel?
    var counts: [Int] = []
    func attach(_ model: LibraryCollectionModel) { self.model = model }
    func record() { counts.append(model?.entries.count ?? -1) }
    var distinctCounts: [Int] { var seen: [Int] = []; for c in counts where seen.last != c { seen.append(c) }; return seen }
}
