import AccountSession
import Features
import Foundation
import Testing
import YouTubeMusicAdapter

/// T11.1 (paging through the model) and T11.2 (refresh), plus cache / stale / fencing.
@MainActor @Suite struct CatalogPageModelTests {
    private let playlist = CatalogTarget(browseID: "VLPLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")
    private func continuation(_ name: String) throws -> MusicContinuationPage { try MusicBrowseParser.parseContinuation(try syntheticData(name)) }

    // MARK: T11.1 — lazy pagination, duplicates, no first-page-only collection, nothing fabricated

    @Test func walksEveryContinuationPageAndDropsOnlyTheRepeatedBoundary() async throws {
        let script = ServiceScript()
        let first = try realPage(.playlist)
        await script.setPages(playlist, [first])
        await script.setContinuation(try #require(first.continuation), try continuation("continuation-playlist-shelf.json"))
        await script.setContinuation("SYNTHETICnextShelfToken-2", try continuation("continuation-append-action.json"))
        await script.setContinuation("SYNTHETICappendToken-4", try continuation("continuation-playlist-last.json"))
        let model = makeModel(playlist, script: script)
        await model.load()
        #expect(model.shelves[0].items.count == 16 && model.pageContinuation != nil && !model.isComplete)
        var guardrail = 0
        while model.pageContinuation != nil, guardrail < 10 { await model.loadMorePage(); guardrail += 1 }
        // 16 first-page rows + (5 − 2 repeated) + 3 + 2 = 24 distinct tracks, in service order.
        let tracks = model.shelves[0].items
        #expect(tracks.count == 24 && Set(tracks.map(\.id)).count == 24)
        #expect(model.duplicatesDropped == 2 && model.isComplete && model.pageContinuation == nil)
        #expect(Array(tracks.prefix(16)) == first.shelves[0].items)
        #expect(await script.tokenCalls.count == 3)
        // The accounting still balances after merging pages: repeated rows are counted as duplicates, not classified twice.
        let a = model.accounting
        #expect(a.items == a.classified + a.skipped + a.unsupported + a.duplicates)
        #expect(a.duplicates == 2 && a.classified == 24)
    }

    @Test func aShelfTokenAppendsToThatShelfOnly() async throws {
        let script = ServiceScript()
        let target = CatalogTarget(browseID: "MPSPPLZr1D7YmlHJw")
        let first = try realPage(.podcast)
        await script.setPages(target, [first])
        let token = try #require(first.shelves[0].continuation)
        await script.setContinuation(token, try continuation("continuation-playlist-last.json"))
        let model = makeModel(target, script: script)
        await model.load()
        let key = model.shelves[0].key
        await model.loadMore(shelf: key)
        #expect(model.shelves[0].items.count == 22 && model.shelves[0].continuation == nil)
        #expect(model.isComplete)
    }

    @Test func aSecondRequestWhileOneIsInFlightDoesNothing() async throws {
        let script = ServiceScript()
        let first = try realPage(.playlist)
        await script.setPages(playlist, [first])
        await script.setContinuation(try #require(first.continuation), try continuation("continuation-playlist-last.json"))
        let model = makeModel(playlist, script: script)
        await model.load()
        await script.setHold(tokens: true)
        let one = Task { await model.loadMorePage() }
        await settle()
        #expect(model.loadingMore.contains("page"))
        // The second request is a task too, so a model that wrongly sent it would block on the held reply instead of hanging this test.
        let two = Task { await model.loadMorePage() }
        await settle()
        let sentWhileHeld = await script.tokenCalls.count
        #expect(sentWhileHeld == 1, "only one request reached the service while the first was in flight")
        await script.release()
        await one.value; await two.value
        let sent = await script.tokenCalls.count
        #expect(sent == 1 && !model.loadingMore.contains("page"))
    }
    @Test func aFailedPageKeepsTheTokenAndTheNextRequestRetriesTheSamePage() async throws {
        let script = ServiceScript()
        let first = try realPage(.playlist)
        let token = try #require(first.continuation)
        await script.setPages(playlist, [first])
        await script.setFailure(token, .network)
        let model = makeModel(playlist, script: script)
        await model.load()
        await model.loadMorePage()
        #expect(model.moreFailures["page"] == .offline && model.pageContinuation == token && model.shelves[0].items.count == 16)
        await script.setFailure(token, nil)
        await script.setContinuation(token, try continuation("continuation-playlist-last.json"))
        await model.loadMorePage()
        #expect(model.moreFailures["page"] == nil && model.shelves[0].items.count == 18)
        #expect(await script.tokenCalls == [token, token])
    }

    @Test func pageContinuationWithSectionsAddsShelvesOnceAndKeepsGoing() async throws {
        let script = ServiceScript()
        let first = try realPage(.home)
        await script.setPages(.home, [first])
        await script.setContinuation(try #require(first.continuation), try continuation("continuation-section-list.json"))
        let model = makeModel(.home, script: script)
        await model.load()
        #expect(model.shelves.count == 2)
        await model.loadMorePage()
        #expect(model.shelves.map(\.title) == ["Quick picks", "New releases", "More shelves (synthetic)"] && model.pageContinuation == "SYNTHETICpageToken-3")
        // The same sections arriving again are not listed twice.
        await script.setContinuation("SYNTHETICpageToken-3", try continuation("continuation-section-list.json"))
        await model.loadMorePage()
        #expect(model.shelves.count == 3)
    }

    @Test func unknownVariantsAreReportedNotHidden() async throws {
        let script = ServiceScript()
        await script.setPages(.home, [try MusicBrowseParser.parse(try syntheticData("unknown-variants-page.json"))])
        let model = makeModel(.home, script: script)
        await model.load()
        #expect(model.leftOut == 3 && model.accounting.duplicates == 1 && model.accounting.unsupportedSections == 1)
    }

    // MARK: T11.2 — refresh keeps what is visible

    @Test func refreshWhileScrolledKeepsTheAnchorTheOrderAndAddsNewShelvesAfter() async throws {
        let script = ServiceScript()
        let original = try realPage(.home)
        // The service now sends the shelves reversed, drops "Quick picks" and puts a new shelf first.
        let reshuffled = pageOf([shelf("carousel:Fresh mix", ["f1"]), original.shelves[1], shelf("carousel:Another", ["x"])], continuation: "tok")
        await script.setPages(.home, [original, reshuffled])
        let model = makeModel(.home, script: script)
        await model.load()
        model.anchor = "list:Quick picks"
        let before = model.shelves.map(\.key)
        await model.refresh()
        // Quick picks is the anchor: kept in place although the service dropped it. Nothing moved; the new shelves follow.
        #expect(model.shelves.map(\.key) == before + ["carousel:Fresh mix", "carousel:Another"])
        #expect(model.anchor == "list:Quick picks" && model.phase == .loaded && !model.isRefreshing && model.refreshFailure == nil)
        // A second refresh with the anchor elsewhere drops the shelf the service no longer sends.
        model.anchor = "carousel:New releases"
        await script.setPages(.home, [reshuffled])
        await model.refresh()
        #expect(model.shelves.map(\.key) == ["carousel:New releases", "carousel:Fresh mix", "carousel:Another"])
        #expect(model.anchor == "carousel:New releases")
    }

    @Test func refreshKeepsEntryOrderInsideAVisibleShelf() async throws {
        let script = ServiceScript()
        let a = pageOf([shelf("S", ["one", "two", "three"])])
        let b = pageOf([shelf("S", ["three", "four", "one"])])
        await script.setPages(.home, [a, b])
        let model = makeModel(.home, script: script)
        await model.load()
        await model.refresh()
        #expect(model.shelves[0].items.map(\.title) == ["one", "three", "four"])
    }

    @Test func aPaginatedShelfKeepsItsLoadedPagesAcrossARefresh() async throws {
        let script = ServiceScript()
        let first = try realPage(.playlist)
        await script.setPages(playlist, [first, first])
        await script.setContinuation(try #require(first.continuation), try continuation("continuation-playlist-last.json"))
        let model = makeModel(playlist, script: script)
        await model.load()
        await model.loadMorePage()
        #expect(model.shelves[0].items.count == 18)
        await model.refresh()
        #expect(model.shelves[0].items.count == 18, "loaded pages survive a refresh of the first page")
    }

    // MARK: cached and stale are distinguished

    @Test func aFreshCachedPageIsShownLabelledAndNotRefetched() async throws {
        let script = ServiceScript()
        let cache = CatalogCache()
        let now = Box(Date(timeIntervalSince1970: 1_000_000))
        await script.setPages(.home, [try realPage(.home)])
        let first = makeModel(.home, script: script, cache: cache, now: now)
        await first.load()
        #expect(first.origin == .live && first.fetchedAt == now.value && !first.isStale)
        now.value = now.value.addingTimeInterval(120)
        let second = makeModel(.home, script: script, cache: cache, now: now)
        await second.load()
        #expect(second.origin == .cached && !second.isStale && second.phase == .loaded && second.shelves == first.shelves)
        #expect(await script.pageCalls.count == 1, "a fresh saved copy is not asked for again")
    }
    @Test func aStaleCachedPageIsShownThenRefreshedLive() async throws {
        let script = ServiceScript()
        let cache = CatalogCache()
        let now = Box(Date(timeIntervalSince1970: 1_000_000))
        await script.setPages(.home, [try realPage(.home)])
        await makeModel(.home, script: script, cache: cache, now: now).load()
        now.value = now.value.addingTimeInterval(3600)
        let model = makeModel(.home, script: script, cache: cache, now: now)
        #expect(!model.hasContent)
        await script.setHold(pages: true)
        let task = Task { await model.load() }
        await settle()
        // While the refresh is held the person sees the saved copy, labelled cached and stale.
        #expect(model.origin == .cached && model.isStale && model.isRefreshing && model.hasContent && model.phase == .loaded)
        await script.release(); await task.value
        let calls = await script.pageCalls.count
        #expect(model.origin == .live && !model.isStale && model.fetchedAt == now.value && calls == 2)
    }
    @Test func aFailedRefreshKeepsTheOlderPageAndSaysSo() async throws {
        let script = ServiceScript()
        let cache = CatalogCache()
        let now = Box(Date(timeIntervalSince1970: 1_000_000))
        await script.setPages(.home, [try realPage(.home)])
        await makeModel(.home, script: script, cache: cache, now: now).load()
        now.value = now.value.addingTimeInterval(3600)
        await script.setFailure(CatalogTarget.home.key, .network)
        let model = makeModel(.home, script: script, cache: cache, now: now)
        await model.load()
        #expect(model.phase == .loaded && model.hasContent && model.origin == .cached && model.isStale && model.refreshFailure == .offline)
        #expect(model.shelves.count == 2)
    }
    @Test func aFirstLoadFailureIsAFailureNotAnEmptyPage() async throws {
        let script = ServiceScript()
        await script.setFailure(CatalogTarget.home.key, .rateLimited)
        let model = makeModel(.home, script: script)
        await model.load()
        #expect(model.phase == .failed(.rateLimited) && !model.hasContent)
        await script.setFailure(CatalogTarget.home.key, nil)
        await script.setPages(.home, [try realPage(.home)])
        await model.load()
        #expect(model.phase == .loaded && model.hasContent)
    }
    @Test func theCacheIsKeyedByAccountScopeAndBounded() async throws {
        let cache = CatalogCache(limit: 2)
        let entry = CatalogCache.Entry(page: pageOf([]), fetchedAt: .now, signedIn: false)
        cache.store(entry, scope: "a", key: "1"); cache.store(entry, scope: "a", key: "2"); cache.store(entry, scope: "b", key: "1")
        #expect(cache.count == 2 && cache.entry(scope: "a", key: "1") == nil && cache.entry(scope: "b", key: "1") != nil && cache.entry(scope: "a", key: "2") != nil)
        #expect(cache.entry(scope: "a", key: "2") != nil && cache.entry(scope: "c", key: "2") == nil)
    }

    // MARK: fencing

    @Test func aReplyForAnotherAccountScopeIsDroppedAndAskedOnce_thenReported() async throws {
        let script = ServiceScript()
        await script.setPages(.home, [try realPage(.home)])
        let scope = Box("scope-1")
        let model = makeModel(.home, script: script, scope: scope)
        await script.setHold(pages: true)
        let task = Task { await model.load() }
        await settle()
        scope.value = "scope-2"
        await script.setHold(pages: false)
        await script.release(); await task.value
        // The first reply belonged to scope-1: dropped, asked again under scope-2, and shown.
        #expect(await script.pageCalls.count == 2 && model.phase == .loaded && model.hasContent)
        // Two mismatches in a row are reported, never looped.
        let again = makeModel(.explore, script: script, scope: scope)
        await script.setPages(.explore, [pageOf([shelf("E", ["e"])])])
        await script.setHold(pages: true)
        let t2 = Task { await again.load() }
        await settle()
        scope.value = "scope-3"
        await script.release(); await settle()
        scope.value = "scope-4"
        await script.release(); await t2.value
        await script.setHold(pages: false)
        #expect(again.phase == .failed(.scopeChanged))
    }
    @Test func aStaleRequestCannotReplaceANewerOne() async throws {
        let script = ServiceScript()
        await script.setPages(.home, [pageOf([shelf("OLD", ["o"])]), pageOf([shelf("NEW", ["n"])])])
        let model = makeModel(.home, script: script)
        await script.setHold(pages: true)
        let first = Task { await model.load() }
        await settle()
        model.accountChanged()          // starts a newer request
        await settle()
        await script.setHold(pages: false)
        await script.release(); await first.value; await settle()
        #expect(model.shelves.map(\.key) == ["NEW"] || model.shelves.isEmpty)
        #expect(!model.shelves.contains { $0.key == "OLD" })
    }
    @Test func accountChangeClearsTheCacheAndFeedback() async throws {
        let script = ServiceScript()
        let cache = CatalogCache()
        await script.setPages(.home, [try realPage(.home)])
        let model = makeModel(.home, script: script, cache: cache)
        await model.load()
        #expect(cache.count == 1)
        model.accountChanged(); await settle()
        #expect(model.feedback.isEmpty)
    }
}
