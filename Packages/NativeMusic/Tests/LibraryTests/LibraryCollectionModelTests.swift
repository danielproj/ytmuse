import AccountSession
import Features
import Foundation
import Testing
import YouTubeMusicAdapter

/// A scripted service for the collection tests: pages and tokens are answered from what the test sets, every call is counted, and a
/// reply can be held until the test releases it. Nothing here is a transport.
actor LibraryScript {
    private(set) var pageCalls: [String] = []
    private(set) var tokenCalls: [String] = []
    var pages: [String: MusicBrowsePage] = [:]
    var tokens: [String: MusicContinuationPage] = [:]
    var failures: [String: MusicSessionError] = [:]
    var held: [CheckedContinuation<Void, Never>] = []
    var holdTokens = false
    var mode: MusicSearchReply.Mode = .signedIn
    func setPage(_ id: String, _ page: MusicBrowsePage) { pages[id] = page }
    func setToken(_ token: String, _ page: MusicContinuationPage) { tokens[token] = page }
    func fail(_ key: String, _ error: MusicSessionError?) { failures[key] = error }
    func hold(_ value: Bool) { holdTokens = value }
    func release() { let all = held; held = []; for c in all { c.resume() } }
    func setMode(_ value: MusicSearchReply.Mode) { mode = value }
    var heldCount: Int { held.count }
    func page(_ source: LibrarySource) async throws -> MusicBrowseReply<MusicBrowsePage> {
        pageCalls.append(source.browseID)
        if let error = failures[source.browseID] { throw error }
        guard let page = pages[source.browseID] else { throw MusicSessionError.unrecognised }
        return MusicBrowseReply(value: page, mode: mode, accountGeneration: 1)
    }
    func token(_ token: String) async throws -> MusicBrowseReply<MusicContinuationPage> {
        tokenCalls.append(token)
        if holdTokens { await withCheckedContinuation { held.append($0) } }
        if let error = failures[token] { throw error }
        guard let page = tokens[token] else { throw MusicSessionError.unrecognised }
        return MusicBrowseReply(value: page, mode: mode, accountGeneration: 1)
    }
}
@MainActor func makeCollection(_ source: LibrarySource, script: LibraryScript, scope: Box<String> = Box("scope-1"), now: Box<Date> = Box(Date(timeIntervalSince1970: 1_000_000)),
                               maximumPages: Int = 400) -> LibraryCollectionModel {
    LibraryCollectionModel(source: source, reader: { try await script.page($0) }, continuer: { try await script.token($0) }, accountScope: { scope.value },
                           now: { now.value }, maximumPages: maximumPages)
}
func item(_ title: String, video: String? = nil, artist: String? = nil, occurrence: String? = nil, kind: MusicEntityKind = .song) -> MusicCatalogItem {
    MusicCatalogItem(kind: kind, title: title, details: artist.map { [$0] } ?? [], videoID: kind == .song ? (video ?? "v" + title.filter { $0.isLetter || $0.isNumber }.prefix(10).padding(toLength: 10, withPad: "x", startingAt: 0)) : nil,
                     browseID: kind == .song ? nil : "MPREb_" + title.filter { $0.isLetter || $0.isNumber }, links: artist.map { [MusicLink(kind: .artist, title: $0, browseID: "UC" + $0.filter(\.isLetter).padding(toLength: 22, withPad: "x", startingAt: 0))] } ?? [],
                     occurrenceID: occurrence)
}
func pageOf(_ items: [MusicCatalogItem], title: String? = nil, token: String? = nil, skipped: Int = 0, unsupported: Int = 0) -> MusicBrowsePage {
    var acc = MusicParseAccounting()
    acc.sections = 1; acc.shelves = 1; acc.items = items.count + skipped + unsupported; acc.classified = items.count; acc.skipped = skipped; acc.unsupported = unsupported
    return MusicBrowsePage(shelves: [MusicShelf(key: "s", title: title, layout: .list, items: items, continuation: token)], accounting: acc)
}
func continuationOf(_ items: [MusicCatalogItem], token: String? = nil) -> MusicContinuationPage {
    var acc = MusicParseAccounting(); acc.items = items.count; acc.classified = items.count
    return MusicContinuationPage(items: items, shelves: [], continuation: token, accounting: acc)
}

@MainActor @Suite struct LibraryCollectionModelTests {
    private let songs = LibrarySource(kind: .songs)

    // MARK: Complete incremental reading (LIB03)

    @Test func everyPageIsReadAndTheFirstResponseIsNeverAssumedToBeTheLibrary() async throws {
        let script = LibraryScript()
        await script.setPage(songs.browseID, try libraryPage("library-songs.json"))
        await script.setToken("LIBSONGS-2", try libraryContinuation("library-songs-page2.json"))
        await script.setToken("LIBSONGS-3", try libraryContinuation("library-songs-page3.json"))
        let model = makeCollection(songs, script: script)
        await model.load()
        #expect(model.entries.count == 7 && model.hasMore && !model.isComplete && !model.coversEverything)
        let completed = await model.loadAll()
        #expect(completed)
        #expect(model.entries.count == 14 && model.isComplete)
        let tokenCalls = await script.tokenCalls
        #expect(tokenCalls == ["LIBSONGS-2", "LIBSONGS-3"])
        #expect(model.accountedFor, "every parsed item is a row, left out, or a counted duplicate")
        #expect(model.entries.map(\.ordinal) == Array(0..<14))
    }
    @Test func aSongListedTwiceStaysTwoRowsWithDistinctIdsAndIsFlagged() async throws {
        let script = LibraryScript()
        await script.setPage(songs.browseID, try libraryPage("library-songs.json"))
        let model = makeCollection(songs, script: script)
        await model.load()
        let repeated = model.entries.filter(\.repeats)
        #expect(repeated.count == 1 && Set(model.entries.map(\.id)).count == model.entries.count)
        #expect(model.occurrenceDuplicates == 0 && model.entries.filter { $0.item.videoID == repeated[0].item.videoID }.count == 2)
    }
    @Test func onlyTheServicesOwnOccurrenceIdMakesATrueDuplicateAndItIsCounted() async throws {
        let script = LibraryScript()
        let rows = [item("A", occurrence: "o1"), item("B", occurrence: "o2"), item("A", occurrence: "o1")]
        await script.setPage(songs.browseID, pageOf(rows))
        let model = makeCollection(songs, script: script)
        await model.load()
        #expect(model.entries.count == 2 && model.occurrenceDuplicates == 1 && model.accountedFor)
    }
    @Test func aPageThatReplaysThePreviousOneEndsPagingAndAddsNothing() async throws {
        let script = LibraryScript()
        let first = [item("A"), item("B")]
        await script.setPage(songs.browseID, pageOf(first, token: "t1"))
        await script.setToken("t1", continuationOf([item("C"), item("D")], token: "t2"))
        await script.setToken("t2", continuationOf([item("C"), item("D")], token: "t3"))     // the same page again
        let model = makeCollection(songs, script: script)
        await model.load(); await model.loadAll()
        #expect(model.entries.map(\.item.title) == ["A", "B", "C", "D"])
        #expect(model.pagingEnded == .noNewEntries && model.hasMore == false && model.replayedPages == 1)
        let calls = await script.tokenCalls
        #expect(model.accountedFor && calls == ["t1", "t2"])
    }
    @Test func aTokenReturnedUnchangedEndsPaging() async throws {
        let script = LibraryScript()
        await script.setPage(songs.browseID, pageOf([item("A")], token: "t1"))
        await script.setToken("t1", continuationOf([item("B")], token: "t1"))
        let model = makeCollection(songs, script: script)
        await model.load(); await model.loadAll()
        #expect(model.entries.count == 2 && model.pagingEnded == .repeatedToken && !model.hasMore)
        let tokenCalls = await script.tokenCalls
        #expect(tokenCalls == ["t1"])
    }
    @Test func aFailedPageKeepsItsTokenAndTheNextRequestRetriesIt() async throws {
        let script = LibraryScript()
        await script.setPage(songs.browseID, pageOf([item("A")], token: "t1"))
        await script.fail("t1", .network)
        let model = makeCollection(songs, script: script)
        await model.load(); await model.loadMore()
        #expect(model.moreFailure == .offline && model.hasMore && model.entries.count == 1)
        await script.fail("t1", nil); await script.setToken("t1", continuationOf([item("B")]))
        await model.loadMore()
        #expect(model.moreFailure == nil && model.entries.count == 2 && model.isComplete)
        let tokenCalls = await script.tokenCalls
        #expect(tokenCalls == ["t1", "t1"])
    }
    @Test func aSecondRequestWhileOneIsInFlightDoesNothing() async throws {
        let script = LibraryScript()
        await script.setPage(songs.browseID, pageOf([item("A")], token: "t1"))
        await script.setToken("t1", continuationOf([item("B")]))
        await script.hold(true)
        let model = makeCollection(songs, script: script)
        await model.load()
        let first = Task { await model.loadMore() }
        await settle()
        // As a task, so a model that did send the second request could not hang this test on the held reply.
        let second = Task { await model.loadMore() }
        await settle()
        let inFlight = await script.tokenCalls
        #expect(inFlight == ["t1"] && model.loadingMore)
        await script.release(); await first.value; await second.value
        await script.release()
        #expect(model.entries.count == 2 && !model.loadingMore)
    }
    @Test func pagingIsBoundedByThePageLimit() async throws {
        let script = LibraryScript()
        await script.setPage(songs.browseID, pageOf([item("S0")], token: "t0"))
        for index in 0..<10 { await script.setToken("t\(index)", continuationOf([item("S\(index + 1)")], token: "t\(index + 1)")) }
        let model = makeCollection(songs, script: script, maximumPages: 3)
        await model.load()
        let completed = await model.loadAll()
        let count = await script.tokenCalls.count
        #expect(!completed && count == 3 && model.hasMore)
    }

    @Test func laterHistoryPagesKeepTheirDayHeadings() async throws {
        let script = LibraryScript()
        let first = pageOf([item("A"), item("B")], title: "Today", token: "t1")
        await script.setPage(LibrarySource.history.browseID, first)
        var acc = MusicParseAccounting(); acc.items = 4; acc.classified = 4
        let shelfOne = MusicShelf(key: "y", title: "Yesterday", layout: .list, items: [item("C"), item("D")])
        await script.setToken("t1", MusicContinuationPage(items: [item("A2")], shelves: [shelfOne], continuation: nil, accounting: acc))
        let model = makeCollection(.history, script: script)
        await model.load(); await model.loadAll()
        #expect(model.entries.map(\.section) == ["Today", "Today", "Today", "Yesterday", "Yesterday"], "rows that continue a day stay under it; a new shelf brings its own heading")
    }

    // MARK: Search, sort and selection are views (LIB02)

    private func loaded(_ rows: [MusicCatalogItem], source: LibrarySource? = nil) async throws -> LibraryCollectionModel {
        let script = LibraryScript()
        let source = source ?? songs
        await script.setPage(source.browseID, pageOf(rows))
        let model = makeCollection(source, script: script)
        await model.load()
        return model
    }
    @Test func serviceOrderIsTheDefaultAndSortingNeverTouchesIt() async throws {
        let model = try await loaded([item("Charlie", artist: "Zed"), item("alpha", artist: "Yan"), item("Bravo", artist: "Xi"), item("alpha", artist: "Wu")])
        let service = model.entries.map(\.id)
        #expect(model.sort == .service && model.visibleEntries.map(\.id) == service)
        for sort in LibrarySort.allCases {
            model.sort = sort
            _ = model.visibleEntries
            #expect(model.entries.map(\.id) == service, "sorting by \(sort) changed the stored order")
        }
        model.sort = .titleAscending
        #expect(model.visibleEntries.map(\.item.title) == ["alpha", "alpha", "Bravo", "Charlie"])
        model.sort = .titleDescending
        #expect(model.visibleEntries.map(\.item.title) == ["Charlie", "Bravo", "alpha", "alpha"])
        model.sort = .artist
        #expect(model.visibleEntries.map(\.artistName) == ["Wu", "Xi", "Yan", "Zed"])
        model.sort = .service
        #expect(model.visibleEntries.map(\.id) == service)
    }
    @Test func sortingIsStableForEqualKeys() async throws {
        let model = try await loaded([item("Same", video: "v0000000001", artist: "One"), item("Other"), item("Same", video: "v0000000002", artist: "Two"), item("Same", video: "v0000000003", artist: "Three")])
        model.sort = .titleAscending
        let same = model.visibleEntries.filter { $0.item.title == "Same" }.map(\.ordinal)
        #expect(same == [0, 2, 3], "equal titles keep the service's order")
        model.sort = .titleDescending
        #expect(model.visibleEntries.filter { $0.item.title == "Same" }.map(\.ordinal) == [0, 2, 3])
    }
    @Test func entriesWithNoArtistFollowTheOthersInServiceOrder() async throws {
        let model = try await loaded([item("A"), item("B", artist: "Zed"), item("C"), item("D", artist: "Ann")])
        model.sort = .artist
        #expect(model.visibleEntries.map(\.item.title) == ["D", "B", "A", "C"])
    }
    @Test func artistSortIsOnlyOfferedWhereTheDataPermitsIt() async throws {
        let withArtists = try await loaded([item("A", artist: "Zed")])
        #expect(withArtists.availableSorts.contains(.artist))
        let without = try await loaded([item("A")])
        #expect(!without.availableSorts.contains(.artist))
        let albums = try await loaded([item("A", artist: "Zed", kind: .album)], source: LibrarySource(kind: .artists))
        #expect(!albums.availableSorts.contains(.artist), "an artists collection has no artist to sort by")
    }
    @Test func searchFiltersTheLoadedRowsIgnoringCaseAndDiacriticsWithoutChangingThem() async throws {
        let model = try await loaded([item("Café del Mar", artist: "Development Artist"), item("Noche Cálida", artist: "Other"), item("Zeta", artist: "Cafe Crew")])
        model.query = "cafe"
        #expect(model.visibleEntries.map(\.item.title) == ["Café del Mar", "Zeta"], "matches the title and the detail line")
        model.query = "CÁLIDA noche"
        #expect(model.visibleEntries.map(\.item.title) == ["Noche Cálida"])
        #expect(model.entries.count == 3)
        model.query = "nothing like this"
        #expect(model.state == .noMatches)
        model.query = ""
        #expect(model.state == .content(stale: false, refreshFailed: nil))
    }
    @Test func searchAndSortOnAnUnfinishedCollectionAreDeclaredPartial() async throws {
        let script = LibraryScript()
        await script.setPage(songs.browseID, pageOf([item("B"), item("A")], token: "t1"))
        let model = makeCollection(songs, script: script)
        await model.load()
        model.sort = .titleAscending
        #expect(!model.coversEverything && model.hasMore, "the view shows its coverage note while this is true")
    }
    @Test func selectionIsAViewStateKeptAcrossSortAndPrunedByARefresh() async throws {
        let script = LibraryScript()
        await script.setPage(songs.browseID, pageOf([item("A"), item("B"), item("C")]))
        let model = makeCollection(songs, script: script)
        await model.load()
        let ids = model.entries.map(\.id)
        model.toggle(ids[0]); model.toggle(ids[2])
        model.sort = .titleDescending
        #expect(model.selection == [ids[0], ids[2]] && model.selectedEntries.map(\.item.title) == ["A", "C"])
        model.selectAllVisible()
        #expect(model.selection.count == 3)
        model.clearSelection()
        #expect(model.selection.isEmpty && model.entries.count == 3)
        model.toggle(ids[0]); model.toggle(ids[1])
        await script.setPage(songs.browseID, pageOf([item("B"), item("C")]))
        await model.refresh()
        #expect(model.selection == [ids[1]], "a row that is gone is no longer selected")
    }

    // MARK: Distinct states (LIB01)

    @Test func emptyIsDistinctFromEveryFailure() async throws {
        let script = LibraryScript()
        await script.setPage(songs.browseID, pageOf([]))
        let model = makeCollection(songs, script: script)
        await model.load()
        #expect(model.state == .empty && model.isComplete)
    }
    @Test func offlineRestrictedUnrecognisedAndFailedAreEachTheirOwnState() async throws {
        let cases: [(MusicSessionError, LibraryViewState)] = [
            (.network, .offline), (.timedOut, .offline), (.notSignedIn, .restricted(.needsSignIn)), (.signedOut, .restricted(.sessionEnded)),
            (.policy, .restricted(.notAvailableHere)), (.unrecognised, .unrecognised), (.rateLimited, .failed(.rateLimited)), (.server, .failed(.unavailable))]
        var seen: [LibraryViewState] = []
        for (error, expected) in cases {
            let script = LibraryScript()
            await script.fail(songs.browseID, error)
            let model = makeCollection(songs, script: script)
            await model.load()
            #expect(model.state == expected, "\(error)")
            seen.append(model.state)
        }
        #expect(!seen.contains(.empty), "no failure is ever shown as an empty library")
    }
    @Test func anUnreadablePageIsUnrecognisedNotEmpty() async throws {
        let script = LibraryScript()
        // A page whose every entry was of a kind this collection doesn't hold, or unreadable, is a layout we don't know.
        await script.setPage(songs.browseID, pageOf([], skipped: 3))
        let model = makeCollection(songs, script: script)
        await model.load()
        #expect(model.state == .unrecognised)
        let albums = LibrarySource(kind: .albums)
        await script.setPage(albums.browseID, pageOf([item("S1"), item("S2")]))
        let wrong = makeCollection(albums, script: script)
        await wrong.load()
        #expect(wrong.state == .unrecognised && wrong.entries.isEmpty)
    }
    @Test func aSignedOutReplyIsRestrictedNeverAnonymousContent() async throws {
        let script = LibraryScript()
        await script.setPage(songs.browseID, pageOf([item("A")]))
        await script.setMode(.anonymous)
        let model = makeCollection(songs, script: script)
        await model.load()
        #expect(model.state == .restricted(.needsSignIn) && model.entries.isEmpty)
    }
    @Test func aSavedCopyIsShownWithTheRefreshFailureAndIsLabelledStaleAfterFifteenMinutes() async throws {
        let script = LibraryScript()
        let clock = Box(Date(timeIntervalSince1970: 1_000_000))
        await script.setPage(songs.browseID, pageOf([item("A")]))
        let model = makeCollection(songs, script: script, now: clock)
        await model.load()
        #expect(model.state == .content(stale: false, refreshFailed: nil))
        clock.value = clock.value.addingTimeInterval(14 * 60)
        #expect(model.state == .content(stale: false, refreshFailed: nil))
        clock.value = clock.value.addingTimeInterval(2 * 60)
        #expect(model.state == .content(stale: true, refreshFailed: nil), "visible library membership goes stale after 15 minutes")
        await script.fail(songs.browseID, .network)
        await model.refresh()
        #expect(model.state == .content(stale: true, refreshFailed: .offline) && model.entries.count == 1, "the older rows stay and the failure is said")
    }
    @Test func historyGoesStaleAfterFiveMinutes() async throws {
        let script = LibraryScript()
        let clock = Box(Date(timeIntervalSince1970: 1_000_000))
        await script.setPage(LibrarySource.history.browseID, pageOf([item("A")]))
        let model = makeCollection(.history, script: script, now: clock)
        await model.load()
        clock.value = clock.value.addingTimeInterval(4 * 60)
        #expect(!model.isStale)
        clock.value = clock.value.addingTimeInterval(2 * 60)
        #expect(model.isStale)
    }
    @Test func aSecondLoadShowsTheSavedCopyAndRefreshesOnlyWhenStale() async throws {
        let script = LibraryScript()
        let clock = Box(Date(timeIntervalSince1970: 1_000_000))
        await script.setPage(songs.browseID, pageOf([item("A")]))
        let first = makeCollection(songs, script: script, now: clock)
        await first.load()
        let one = await script.pageCalls.count
        #expect(one == 1)
        await first.refresh()
        let two = await script.pageCalls.count
        #expect(two == 2)
    }

    // MARK: Accounting and kinds

    @Test func entriesOfAnotherKindAreCountedAndReportedNotSilentlyDropped() async throws {
        let albums = LibrarySource(kind: .albums)
        let script = LibraryScript()
        await script.setPage(albums.browseID, try libraryPage("library-albums-wrong-kinds.json"))
        let model = makeCollection(albums, script: script)
        await model.load()
        #expect(model.entries.count == 1 && model.wrongKind == 2 && model.leftOut == 2)
        #expect(model.accountedFor, "rows + left out + duplicates == parsed items")
    }
    @Test func unsupportedAndSkippedEntriesAreInTheLeftOutCount() async throws {
        let script = LibraryScript()
        await script.setPage(songs.browseID, pageOf([item("A")], skipped: 2, unsupported: 1))
        let model = makeCollection(songs, script: script)
        await model.load()
        #expect(model.leftOut == 3 && model.accountedFor)
    }
    @Test func everyKindsFixtureIsAccountedForEndToEnd() async throws {
        let names: [MusicLibraryKind: String] = [.songs: "library-songs", .albums: "library-albums", .artists: "library-artists", .following: "library-following", .playlists: "library-playlists",
                                                 .podcasts: "library-podcasts", .savedEpisodes: "library-saved-episodes", .uploads: "library-uploads"]
        for (kind, name) in names {
            let script = LibraryScript()
            let source = LibrarySource(kind: kind)
            await script.setPage(source.browseID, try libraryPage(name + ".json"))
            let model = makeCollection(source, script: script)
            await model.load()
            #expect(model.accountedFor && !model.entries.isEmpty && model.wrongKind == 0, "\(kind)")
        }
        let script = LibraryScript()
        await script.setPage(MusicLibraryKind.likedSongs.browseID, try MusicBrowseParser.parse(try realCapture("playlist"), mode: .collection))
        let liked = makeCollection(LibrarySource(kind: .likedSongs), script: script)
        await liked.load()
        #expect(liked.accountedFor && liked.entries.count == 16)
        let history = makeCollection(.history, script: script)
        await script.setPage(LibrarySource.history.browseID, try libraryPage("history.json"))
        await history.load()
        #expect(history.accountedFor && history.entries.count == 5 && history.entries.map(\.section) == ["Today", "Today", "Today", "Yesterday", "Yesterday"])
    }

    // MARK: Account scope

    @Test func aReplyForAnotherAccountScopeCannotReplaceWhatIsShown() async throws {
        let script = LibraryScript()
        let scope = Box("scope-1")
        await script.setPage(songs.browseID, pageOf([item("A")], token: "t1"))
        await script.setToken("t1", continuationOf([item("B")]))
        await script.hold(true)
        let model = makeCollection(songs, script: script, scope: scope)
        await model.load()
        let task = Task { await model.loadMore() }
        await settle()
        scope.value = "scope-2"
        model.accountChanged()
        await script.release(); await task.value
        #expect(model.entries.isEmpty && model.phase == .idle, "nothing read for the old account stays")
    }
    /// TH5 (W44-prep critic L-c): the saved copy is keyed by the scope the page was READ under, not the scope when it is written. The scope moves while a page is in
    /// flight and the shell has not (yet) called `accountChanged()`: the late reply is dropped, nothing is added to what is shown, and when the scope comes back to the
    /// one the rows were read under, a new session reads from the first page rather than serving rows that were never read for it. (The staged `loadAll` of the W44-prep
    /// branch keeps rows between pages, which is why its flush has to remember the scope too; see the node report.)
    @Test func aScopeThatMovesWhileAPageIsInFlightNeverSavesItsRowsUnderTheWrongScope() async throws {
        let script = LibraryScript()
        let scope = Box("scope-1")
        await script.setPage(songs.browseID, pageOf([item("A")], token: "t1"))
        await script.setToken("t1", continuationOf([item("B")], token: "t2"))
        await script.setToken("t2", continuationOf([item("C")]))
        await script.hold(true)
        let model = makeCollection(songs, script: script, scope: scope)
        await model.load()
        #expect(model.entries.count == 1)
        let task = Task { await model.loadAll() }
        await settle()
        scope.value = "scope-2"          // no accountChanged(): the shell has not been told yet
        await script.release(); await task.value
        #expect(model.entries.map(\.item.title) == ["A"], "the page read for scope-1 is not added once the scope is scope-2: \(model.entries.map(\.item.title))")
        // Nothing read after the move is filed under scope-2 either: a read for scope-2 starts from the first page.
        await script.hold(false)
        model.accountChanged()
        await model.load()
        #expect(model.entries.map(\.item.title) == ["A"] && model.hasMore, "a new session reads again from the first page, with its own tokens")
        let reads = await script.pageCalls.count
        #expect(reads == 2, "scope-2 had no saved copy to serve: \(reads)")
        // Control: with no move the same loadAll completes and saves its rows.
        let steady = makeCollection(songs, script: script, scope: Box("scope-9"))
        await steady.load()
        let complete = await steady.loadAll()
        #expect(complete && steady.entries.map(\.item.title) == ["A", "B", "C"], "control: without a move all pages are read")
    }
    @Test func accountChangedClearsEverythingIncludingTheSavedCopy() async throws {
        let script = LibraryScript()
        let scope = Box("scope-1")
        await script.setPage(songs.browseID, pageOf([item("A")]))
        let model = makeCollection(songs, script: script, scope: scope)
        await model.load()
        model.toggle(model.entries[0].id)
        scope.value = "scope-2"
        model.accountChanged()
        #expect(model.entries.isEmpty && model.selection.isEmpty && model.fetchedAt == nil)
        await model.load()
        let reads = await script.pageCalls.count
        #expect(reads == 2, "the old account's saved copy is not reused")
        // Signing out and back in to the same account is a new session: what was read before is gone, not served from a copy.
        model.accountChanged()
        scope.value = "scope-1"
        await model.load()
        let again = await script.pageCalls.count
        #expect(again == 3, "a flushed copy is not served when the same scope token returns")
    }
    @Test func aReadWhoseScopeChangedMidFlightIsRetriedOnceThenReported() async throws {
        let script = LibraryScript()
        let scope = Box("scope-1")
        let calls = Box(0)
        let model = LibraryCollectionModel(source: songs, reader: { source in
            let reply = try await script.page(source)
            await MainActor.run { calls.value += 1; scope.value = "scope-\(calls.value + 1)" }
            return reply
        }, continuer: { try await script.token($0) }, accountScope: { scope.value })
        await script.setPage(songs.browseID, pageOf([item("A")]))
        await model.load()
        #expect(model.state == .failed(.scopeChanged) && calls.value == 2)
    }
}
