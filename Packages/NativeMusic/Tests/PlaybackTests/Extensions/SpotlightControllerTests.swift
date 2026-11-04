import AccountSession
import Features
import Foundation
import Testing
import WidgetShared
@testable import SystemIntegration
@testable import AppShell
import TestSupport

/// T25.3 (MAC05): the controller turns the library the windows already loaded into entries, honours the opt-in, follows changes, and removes an account's entries
/// when the account goes. Over a fake source and the in-memory index; nothing is requested and the system's index is never called.
@Suite @MainActor struct SpotlightControllerTests {
    final class Source: SpotlightSource {
        var rows: [MusicLibraryKind: [MusicCatalogItem]] = [:]
        var history: [LocalHistoryRecord] = []
        func libraryRows(_ kind: MusicLibraryKind) -> [MusicCatalogItem] { rows[kind] ?? [] }
        func localHistory() -> [LocalHistoryRecord] { history }
    }
    final class Live {
        var scope: IntentScope?; var reads = 0; var after: (reads: Int, scope: IntentScope?)?
        init(_ scope: IntentScope?) { self.scope = scope }
        /// The scope as a reader sees it; after `after.reads` reads it changes (an account switch or a sign-in landing mid-refresh).
        func read() -> IntentScope? { reads += 1; if let after, reads > after.reads { return after.scope }; return scope }
    }
    @MainActor struct Rig {
        let source = Source(), index = InMemorySearchableIndex(), settings: SpotlightSettings, live: Live, controller: SpotlightController, scratch = ScratchDefaults()
        let account = WidgetFixtures.account
        init() {
            settings = SpotlightSettings(defaults: scratch.defaults)
            live = Live(IntentScope(accountID: WidgetFixtures.account, generation: 3))
            let live = self.live
            controller = SpotlightController(indexer: SpotlightIndexer(backend: index), settings: settings, source: source, liveScope: { live.read() }, debounce: .milliseconds(5))
            source.rows = [
                .songs: [IntentFixtures.song("Saved Song", video: "vSaved", context: "OLAK5uy_ctx")],
                .likedSongs: [IntentFixtures.song("Liked Song", video: "vLiked", context: "PLliked")],
                .albums: [IntentFixtures.album("Saved Album", id: "alb1")],
                .artists: [IntentFixtures.artist("Library Artist", id: "art1")],
                .following: [IntentFixtures.artist("Followed Artist", id: "art2")],
                .playlists: [IntentFixtures.playlist("Private Playlist Name", id: "PLpriv")],
            ]
            source.history = [LocalHistoryRecord(videoID: "vHist", title: "Listened Song", artist: "Synthetic Artist", startedAt: Date(), listenedSeconds: 60)]
        }
        func cleanUp() { scratch.clean() }
        var titles: Set<String> { Set(index.entries.map(\.title)) }
    }

    @Test func theOptInIsOffByDefaultPersistsAndPrivateNeedsTheFirstOne() {
        let rig = Rig(); defer { rig.cleanUp() }
        #expect(!rig.settings.enabled && !rig.settings.includePrivate && rig.settings.policy == .off)
        rig.settings.setIncludePrivate(true)
        #expect(rig.settings.policy == SpotlightPolicy(enabled: false, includePrivate: false), "private without the first opt-in is nothing")
        rig.settings.setEnabled(true)
        #expect(rig.settings.policy == SpotlightPolicy(enabled: true, includePrivate: true))
        let again = SpotlightSettings(defaults: rig.scratch.reopen())
        #expect(again.enabled && again.includePrivate, "the choices are stored")
    }
    @Test func offByDefaultNothingIsIndexedWhateverTheLibraryHolds() async {
        let rig = Rig(); defer { rig.cleanUp() }
        await rig.controller.reconcileNow()
        #expect(rig.index.entries.isEmpty)
    }
    @Test func enabledIndexesSavedSongsAlbumsAndArtistsAndTheActionsButNotPlaylistsOrHistory() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.settings.setEnabled(true)
        await rig.controller.reconcileNow()
        #expect(rig.titles == Set(["Saved Song", "Liked Song", "Saved Album", "Library Artist", "Followed Artist"]).union(SpotlightIndexTests.actionTitles))
        let token = WidgetScope.token(for: rig.account)
        #expect(rig.index.entries.filter { $0.accountToken != nil }.allSatisfy { $0.accountToken == token && $0.visibility == .catalog })
    }
    @Test func thePrivateOptInAddsLibraryPlaylistsAndLocalHistory() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.settings.setEnabled(true); rig.settings.setIncludePrivate(true)
        await rig.controller.reconcileNow()
        #expect(rig.titles.isSuperset(of: ["Private Playlist Name", "Listened Song"]))
        rig.settings.setIncludePrivate(false)
        await rig.controller.reconcileNow()
        #expect(!rig.titles.contains("Private Playlist Name") && !rig.titles.contains("Listened Song") && rig.titles.contains("Saved Song"))
    }
    @Test func anItemWithNothingToOpenIsNotIndexed() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.source.rows = [.artists: [IntentFixtures.artist("No Radio Artist", id: "x", radio: nil)], .songs: [MusicCatalogItem(kind: .song, title: "No Id Song")]]
        rig.settings.setEnabled(true)
        await rig.controller.reconcileNow()
        #expect(!rig.titles.contains("No Radio Artist") && !rig.titles.contains("No Id Song"), "an entry the app could not open is not offered")
    }
    @Test func signingOutRemovesTheAccountsEntriesAndKeepsTheActionsAndSigningBackInRestoresThem() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.settings.setEnabled(true); rig.settings.setIncludePrivate(true)
        await rig.controller.reconcileNow()
        #expect(rig.titles.contains("Saved Song"))
        rig.live.scope = nil
        await rig.controller.reconcileNow()
        #expect(rig.titles == SpotlightIndexTests.actionTitles, "nothing of the account, only the actions")
        rig.live.scope = IntentScope(accountID: rig.account, generation: 4)
        await rig.controller.reconcileNow()
        #expect(rig.titles.contains("Saved Song") && rig.titles.contains("Private Playlist Name"))
    }
    @Test func removingTheAccountRemovesItsPublicAndPrivateEntriesAtOnce() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.settings.setEnabled(true); rig.settings.setIncludePrivate(true)
        await rig.controller.reconcileNow()
        await rig.controller.accountEnded(rig.account)
        #expect(rig.titles == SpotlightIndexTests.actionTitles)
        #expect(!rig.index.entries.contains { $0.accountToken == WidgetScope.token(for: rig.account) })
    }
    @Test func aChangeToTheLibraryFollowsAfterTheDebounceAsOneReconcile() async throws {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.settings.setEnabled(true)
        rig.controller.start()
        await rig.controller.settle()
        #expect(rig.titles.contains("Saved Song"))
        let runs = rig.controller.runs
        rig.source.rows[.songs] = []
        for _ in 0..<10 { rig.controller.refresh() }
        await rig.controller.settle()
        #expect(rig.controller.runs <= runs + 2, "ten refresh requests are coalesced (\(rig.controller.runs - runs) reconciles)")
        #expect(!rig.titles.contains("Saved Song") && rig.titles.contains("Liked Song"), "an unsaved song left the index")
    }

    @Test func aRefreshWhoseSessionChangedWhileItWasBeingPreparedSendsNothing() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.settings.setEnabled(true); rig.settings.setIncludePrivate(true)
        rig.live.after = (1, IntentScope(accountID: rig.account, generation: 99))   // the first read says generation 3; every later one says 99
        await rig.controller.reconcileNow()
        #expect(rig.titles.isEmpty, "the session changed between building the entries and sending them: nothing goes out (\(rig.titles))")
        rig.live.after = nil
        await rig.controller.reconcileNow()
        #expect(rig.titles.contains("Saved Song"), "the control: the same refresh in a stable session indexes")
    }
    @Test func removingTheAccountWhileARefreshIsSendingLeavesNoneOfItsEntries() async throws {
        let rig = Rig(); defer { rig.cleanUp() }
        let slow = SpotlightIndexTests.DelayedIndex(delay: .milliseconds(300))
        let settings = rig.settings, source = rig.source, live = rig.live
        let controller = SpotlightController(indexer: SpotlightIndexer(backend: slow), settings: settings, source: source, liveScope: { live.read() }, debounce: .milliseconds(5))
        settings.setEnabled(true); settings.setIncludePrivate(true)
        let running = Task { @MainActor in await controller.reconcileNow() }
        try await Task.sleep(for: .milliseconds(100))
        await controller.accountEnded(rig.account)
        await running.value
        #expect(!slow.inner.entries.contains { $0.accountToken == WidgetScope.token(for: rig.account) }, "Private Playlist Name and Saved Song stay gone: \(slow.inner.entries.map(\.title))")
    }

    // MARK: Opening a result

    @Test func openingAResultIsAcceptedOnlyForOurIdentifiersAndTheLiveAccount() {
        let token = WidgetScope.token(for: WidgetFixtures.account)
        let live = IntentScope(accountID: WidgetFixtures.account, generation: 3)
        let song = SpotlightEntry(kind: .song, title: "S", accountToken: token, target: IntentMediaTarget(videoID: "v1", playlistID: "PL1"))!
        guard case .success(let play) = SpotlightActivation.command(for: song.uniqueID, live: live), case .play(let media) = play else { Issue.record("a song plays"); return }
        #expect(media.kind == .song && media.account == WidgetFixtures.account && media.target.videoID == "v1")
        #expect(SpotlightActivation.command(for: song.uniqueID, live: nil) == .failure(.signedOut))
        #expect(SpotlightActivation.command(for: song.uniqueID, live: IntentScope(accountID: UUID(), generation: 3)) == .failure(.staleIdentity), "another account is live: the result is stale")
        #expect(SpotlightActivation.command(for: "com.apple.photos|1", live: live) == .failure(.notFound))
        #expect(SpotlightActivation.command(for: SpotlightEntry(action: .playPause).uniqueID, live: nil) == .success(.toggle), "an action needs no account (the channel applies its own gates)")
        #expect(SpotlightActivation.command(for: SpotlightEntry(action: .showQueue).uniqueID, live: live) == .success(.showQueue))
        #expect(SpotlightActivation.command(for: "ytmuse.spot.v1|\(token)|upload|v=vu", live: live) == .failure(.notFound), "removed Spotlight kinds cannot activate")
        #expect(SpotlightActivation.activityType == "com.apple.corespotlightitem" && SpotlightActivation.identifierKey == "kCSSearchableItemActivityIdentifier")
    }
}
