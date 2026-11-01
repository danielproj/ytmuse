import AccountSession
import Artwork
import Features
import Playback
import Foundation
import Testing
import YouTubeMusicAdapter
@testable import AppShell

/// Rework 1: shuffle with the service's own parameters, play-from-track, bounded paging, pacing, rich-text edges, restored songs, staleness.
@MainActor @Suite struct CatalogShuffleTests {
    private func model(_ capture: Capture, id: String, performer: StubPerformer) async throws -> CatalogPageModel {
        let script = ServiceScript()
        let target = CatalogTarget(browseID: id)
        await script.setPages(target, [try realPage(capture)])
        let model = makeModel(target, script: script, performer: performer)
        await model.load()
        return model
    }

    @Test func theServicesShuffleOnTheRealAlbumAndPlaylistIsThePlaylistWithItsParameters() async throws {
        let performer = StubPerformer()
        let album = try await model(.album, id: "MPREb_K8qWMWVqXGi", performer: performer)
        let actions = try #require(album.pageActions)
        #expect(CatalogActionPlan.shufflePublished(actions))
        #expect(CatalogActionPlan.target(for: .shuffle, in: actions) == .init(playlistID: "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c", params: "wAEB8gECKAE%3D"))
        #expect(CatalogActionPlan.target(for: .play, in: actions) == .init(playlistID: "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c"), "Play carries no parameters")
        await album.perform(.shuffle)
        await album.perform(.play)
        #expect(performer.targets.count == 2)
        #expect(performer.targets[0].playlist == "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c" && performer.targets[0].params == "wAEB8gECKAE%3D" && performer.targets[0].video == nil)
        #expect(performer.targets[1].params == nil, "the two controls no longer send the same thing")
        #expect(album.feedback["page:shuffle"] == .started)
        let playlist = try await model(.playlist, id: "VLPLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", performer: performer)
        await playlist.perform(.shuffle)
        #expect(performer.targets.last?.playlist == "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN" && performer.targets.last?.params == "wAEB8gECKAE%3D")
    }
    @Test func theArtistsShuffleIsItsOwnPlaylistWithParameters() async throws {
        let performer = StubPerformer()
        let artist = try await model(.artist, id: "UCRr1xG_2WIDs18a6cIiCxeA", performer: performer)
        await artist.perform(.shuffle)
        #expect(performer.targets.last?.playlist == "RDAOni3jl65KF37F9JYsJM8DGg" && performer.targets.last?.params == "wAEB8gECGAE%3D")
    }
    @Test func aPageThatPublishesNoShuffleOffersNone() async throws {
        let performer = StubPerformer()
        let show = try await model(.podcast, id: "MPSPPLZr1D7YmlHJw", performer: performer)
        #expect(!CatalogActionPlan.offers(for: try #require(show.pageActions), playback: .available).contains { $0.action == .shuffle })
        await show.perform(.shuffle)
        #expect(performer.targets.isEmpty)
        if case .failed? = show.feedback["page:shuffle"] {} else { Issue.record("an unpublished action is refused, not guessed") }
    }
    @Test func aShuffleThatWouldOnlyReplayPlayInOrderIsNeverOffered() {
        let same = MusicPageActions(play: "PLx", shuffle: "PLx")
        #expect(!CatalogActionPlan.shufflePublished(same))
        #expect(!CatalogActionPlan.offers(for: same, playback: .available).contains { $0.action == .shuffle })
        #expect(CatalogActionPlan.target(for: .shuffle, in: same) == nil)
        #expect(CatalogActionPlan.shufflePublished(MusicPageActions(play: "PLx", shuffle: "PLx", shuffleParams: "wAEB")))
        #expect(CatalogActionPlan.shufflePublished(MusicPageActions(play: "PLx", shuffle: "RDAOy")), "a distinct service playlist is a real shuffle")
        #expect(CatalogActionPlan.shufflePublished(MusicPageActions(shuffle: "RDAOy")))
        #expect(!CatalogActionPlan.shufflePublished(MusicPageActions(play: "PLx")))
    }
    @Test func aPerformerThatCannotCarryParametersRefusesInsteadOfPlayingInOrder() async {
        final class Plain: SearchActionPerformer {
            var played = 0
            func play(playlistID: String, title: String) async -> SearchPlayOutcome { played += 1; return .started }
            func copy(link: URL) {}
        }
        let plain = Plain()
        #expect(await plain.play(playlistID: "PLx", title: "t", videoID: nil, params: "wAEB") == .failed && plain.played == 0)
        #expect(await plain.play(playlistID: "PLx", title: "t", videoID: nil, params: nil) == .started && plain.played == 1)
    }

    // MARK: F7 — a track continues its collection

    @Test func playOnAnAlbumTrackContinuesTheAlbumFromThatTrack() async throws {
        let performer = StubPerformer()
        let album = try await model(.album, id: "MPREb_K8qWMWVqXGi", performer: performer)
        let track = try #require(album.shelves.first?.items.first { $0.position == "5" })
        let target = try #require(CatalogActionPlan.target(for: track))
        #expect(target.playlistID == "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c" && target.videoID == track.videoID && target.params == nil)
        #expect(CatalogActionPlan.continuesCollection(track))
        await album.perform(.play, on: track)
        #expect(performer.targets.last?.playlist == target.playlistID && performer.targets.last?.video == track.videoID)
    }
    @Test func aSongSeededOnlyWithItsOwnRadioStillPlaysThatRadio() throws {
        let pick = try #require(try realPage(.home).shelves.first?.items.first)
        #expect(CatalogActionPlan.target(for: pick) == .init(playlistID: "RDAMVMZ85lxckrtzg"))
        #expect(!CatalogActionPlan.continuesCollection(pick))
        let bare = MusicCatalogItem(kind: .song, title: "x", videoID: "aaaaaaaaaaa")
        #expect(CatalogActionPlan.target(for: bare) == .init(playlistID: "RDAMVMaaaaaaaaaaa"))
    }
    @Test(arguments: [Capture.album, .playlist, .artist]) func everyRealTrackTargetIsAnIdThePlayerAccepts(capture: Capture) throws {
        for item in try realPage(capture).shelves.flatMap(\.items) where item.kind == .song || item.kind == .video {
            guard let target = CatalogActionPlan.target(for: item) else { Issue.record("no target for \(item.title)"); continue }
            #expect(WebMusicIdentifier.isPlaylistID(target.playlistID) && (target.videoID.map(WebMusicIdentifier.isVideoID) ?? true) && (target.params.map(WebMusicIdentifier.isEndpointParams) ?? true), "\(capture) \(item.title)")
            if capture != .artist, item.availability == .available { #expect(target.videoID == item.videoID, "inside a collection the row's own playlist is used") }
        }
    }
}

@MainActor @Suite struct CatalogBoundedPagingTests {
    private let playlist = CatalogTarget(browseID: "VLPLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")
    private func item(_ n: Int) -> MusicCatalogItem { MusicCatalogItem(kind: .song, title: "t\(n)", videoID: String(format: "vid%08d", n), occurrenceID: "o\(n)") }
    private func continuation(items: [MusicCatalogItem], next: String?) -> MusicContinuationPage {
        var acc = MusicParseAccounting(); acc.items = items.count; acc.classified = items.count
        return MusicContinuationPage(items: items, shelves: [], continuation: next, accounting: acc)
    }
    private func loaded(_ script: ServiceScript) async throws -> CatalogPageModel {
        let first = try realPage(.playlist)
        await script.setPages(playlist, [first])
        let model = makeModel(playlist, script: script)
        await model.load()
        return model
    }

    @Test func aRepeatedTokenEndsPagingAfterOneRequest() async throws {
        let script = ServiceScript()
        let model = try await loaded(script)
        let token = try #require(model.pageContinuation)
        await script.setContinuation(token, continuation(items: [item(1)], next: token))
        for _ in 0..<25 { await model.loadMorePage() }
        let calls = await script.tokenCalls.count
        #expect(calls == 1, "the same token coming back is the end, not an invitation to ask again")
        #expect(model.pageContinuation == nil && model.pagingEnded["page"] == .repeatedToken && model.isComplete)
        #expect(model.shelves[0].items.count == 17, "the entry it did bring is kept")
    }
    @Test func aPageWithNoNewEntriesEndsPaging() async throws {
        let script = ServiceScript()
        let model = try await loaded(script)
        let token = try #require(model.pageContinuation)
        await script.setContinuation(token, continuation(items: [], next: "another-token"))
        for _ in 0..<25 { await model.loadMorePage() }
        let calls = await script.tokenCalls.count
        #expect(calls == 1 && model.pagingEnded["page"] == .noNewEntries && model.pageContinuation == nil)
    }
    @Test func aPageOfOnlyAlreadyListedEntriesEndsPagingToo() async throws {
        let script = ServiceScript()
        let model = try await loaded(script)
        let token = try #require(model.pageContinuation)
        let known = Array(model.shelves[0].items.prefix(2))
        await script.setContinuation(token, continuation(items: known, next: "another-token"))
        for _ in 0..<25 { await model.loadMorePage() }
        let calls = await script.tokenCalls.count
        #expect(calls == 1 && model.pagingEnded["page"] == .noNewEntries && model.duplicatesDropped == 2)
    }
    @Test func aShelfTokenThatRepeatsOrAddsNothingEndsThatShelf() async throws {
        let script = ServiceScript()
        let show = CatalogTarget(browseID: "MPSPPLZr1D7YmlHJw")
        let first = try realPage(.podcast)
        await script.setPages(show, [first])
        let model = makeModel(show, script: script)
        await model.load()
        let key = model.shelves[0].key, token = try #require(model.shelves[0].continuation)
        await script.setContinuation(token, continuation(items: Array(model.shelves[0].items.prefix(3)), next: token))
        for _ in 0..<25 { await model.loadMore(shelf: key) }
        let calls = await script.tokenCalls.count
        #expect(calls == 1 && model.pagingEnded[key] == .repeatedToken && model.shelves[0].continuation == nil && model.shelves[0].items.count == 20)
    }
    @Test func progressKeepsPagingAndTheLastRealPageStillEndsNormally() async throws {
        let script = ServiceScript()
        let model = try await loaded(script)
        let token = try #require(model.pageContinuation)
        await script.setContinuation(token, continuation(items: [item(1), item(2)], next: "t2"))
        await script.setContinuation("t2", continuation(items: [item(3)], next: nil))
        await model.loadMorePage(); await model.loadMorePage(); await model.loadMorePage()
        let calls = await script.tokenCalls.count
        #expect(calls == 2 && model.shelves[0].items.count == 19 && model.pagingEnded.isEmpty && model.isComplete)
    }
    @Test func theViewsArmNothingOnceThereIsNoTokenLeft() async throws {
        // The end-of-list sentinel exists only while a token does; ending paging removes it, so it cannot fire again.
        let script = ServiceScript()
        let model = try await loaded(script)
        let token = try #require(model.pageContinuation)
        await script.setContinuation(token, continuation(items: [], next: token))
        await model.loadMorePage()
        #expect(model.pageContinuation == nil && model.shelves.allSatisfy { $0.continuation == nil })
    }
}

@Suite struct ContinuationPacerTests {
    final class Time: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        private var delays: [Double] = []
        func now() -> Double { lock.withLock { value } }
        func advance(to t: Double) { lock.withLock { value = t } }
        func record(_ d: Double) { lock.withLock { delays.append(d) } }
        var recorded: [Double] { lock.withLock { delays.sorted() } }
    }
    private func pacer(_ time: Time, interval: Double = 1) -> ContinuationPacer {
        ContinuationPacer(interval: interval, now: { time.now() }, sleep: { time.record($0) })
    }
    @Test func requestsInTheSameInstantAreSpacedOneIntervalApart() async throws {
        let time = Time(), pacer = pacer(time)
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await pacer.wait(scope: "a") } }
        }
        #expect(time.recorded == [1, 2, 3, 4, 5, 6, 7], "eight requests: the first goes at once, the rest one interval apart")
    }
    @Test func eachAccountHasItsOwnSlotsAndAQuietPeriodResetsThem() async throws {
        let time = Time(), pacer = pacer(time)
        try await pacer.wait(scope: "a"); try await pacer.wait(scope: "b")
        #expect(time.recorded.isEmpty, "two accounts do not queue behind each other")
        try await pacer.wait(scope: "a")
        #expect(time.recorded == [1])
        time.advance(to: 50)
        try await pacer.wait(scope: "a")
        #expect(time.recorded == [1], "after a quiet period the next request goes at once; nothing is hoarded")
    }
    @Test func aCancelledWaitDoesNotSendAndTheTableStaysSmall() async {
        let pacer = ContinuationPacer(interval: 1, now: { 0 }, sleep: { _ in throw CancellationError() })
        _ = try? await pacer.wait(scope: "a")
        await #expect(throws: CancellationError.self) { try await pacer.wait(scope: "a") }
    }
}

@MainActor @Suite struct CatalogHubPacingTests {
    @Test func everyContinuationTheHubSendsWaitsForItsAccountsSlot() async throws {
        let time = ContinuationPacerTests.Time()
        let script = ServiceScript()
        let first = try realPage(.playlist)
        let target = CatalogTarget(kind: .playlist, identifier: "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")!
        await script.setPages(target, [first])
        var token = try #require(first.continuation)
        for n in 0..<6 {
            var acc = MusicParseAccounting(); acc.items = 1; acc.classified = 1
            let next = "token-\(n)"
            await script.setContinuation(token, MusicContinuationPage(items: [MusicCatalogItem(kind: .song, title: "n\(n)", videoID: String(format: "vid%08d", n), occurrenceID: "o\(n)")], shelves: [], continuation: next, accounting: acc))
            token = next
        }
        let hub = CatalogHub(artwork: CatalogArtwork(pipeline: nil, authority: ArtworkUIAuthority(), source: nil), development: false,
                             reader: { try await script.page($0) }, continuer: { try await script.token($0) }, scope: { "s" }, playback: { .available }, performer: nil,
                             pacer: ContinuationPacer(interval: 1, now: { time.now() }, sleep: { time.record($0) }))
        let route = try NativeItemRoute(kind: .playlist, identifier: "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")
        let model = try #require(hub.model(for: BrowserEntry(destination: .home, item: route)))
        await model.load()
        // A listener scrolling hard: the end of the list is "reached" over and over.
        for _ in 0..<6 { await model.loadMorePage() }
        let calls = await script.tokenCalls.count
        #expect(calls == 6)
        #expect(time.recorded == [1, 2, 3, 4, 5], "six continuations in one instant: at most one per interval")
    }
}

@MainActor @Suite struct CatalogReworkDetailTests {
    @Test func staleThresholdsFollowTheSpecPerPageKind() {
        #expect(CatalogTarget.home.staleAfter == 300 && CatalogTarget.explore.staleAfter == 300 && CatalogTarget.charts.staleAfter == 300)
        #expect(CatalogTarget(browseID: "MPREb_K8qWMWVqXGi").staleAfter == 86_400 && CatalogTarget(browseID: "UCRr1xG_2WIDs18a6cIiCxeA").staleAfter == 86_400)
        #expect(CatalogTarget(browseID: "VLPLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN").staleAfter == 600)
    }
    @Test func theLeftOutCountFollowsTheRefreshedPage() async throws {
        func page(skipped: Int) -> MusicBrowsePage {
            var p = pageOf([shelf("S", ["one", "two"])])
            p.accounting.skipped = skipped; p.accounting.items += skipped
            return p
        }
        let script = ServiceScript()
        await script.setPages(.home, [page(skipped: 3), page(skipped: 0)])
        let model = makeModel(.home, script: script)
        await model.load()
        #expect(model.leftOut == 3)
        await model.refresh()
        #expect(model.leftOut == 0, "the count describes the page now on screen")
    }
    @Test func aMergedRefreshBumpsTheRevisionTheViewReanchorsOn() async throws {
        let script = ServiceScript()
        await script.setPages(.home, [pageOf([shelf("A", ["a"])]), pageOf([shelf("A", ["a"])])])
        let model = makeModel(.home, script: script)
        await model.load()
        let before = model.mergeRevision
        await model.refresh()
        #expect(model.mergeRevision == before + 1)
    }
    @Test func aRestoredSongNeitherClaimsNorDeniesAvailabilityAndStillPlaysFromItsId() throws {
        let restored = MusicCatalogItem(kind: .song, title: "Unknown song", availability: .unknown, videoID: "aaaaaaaaaaa")
        let detail = try #require(SongDetail(item: restored))
        #expect(!detail.availabilityKnown && !detail.isAvailable)
        #expect(CatalogActionPlan.canEverPlay(restored))
        let play = try #require(detail.offers(playback: .available).first { $0.action == .play })
        #expect(play.unavailable == nil)
        #expect(SongDetail(item: MusicCatalogItem(kind: .song, title: "x", videoID: "aaaaaaaaaaa"))?.availabilityKnown == true)
    }
}

