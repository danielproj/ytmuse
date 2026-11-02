import Domain
import Foundation
import Testing
import SystemIntegration
import WidgetShared
@testable import AppShell
import TestSupport

/// F4 (MAC05, MAC06): the surfaces are tied to the REAL account lifecycle. The playback authority hands its barrier listeners the account that is leaving, captured before it clears
/// its own scope; these tests drive the authority's own `detach`, `removeLocal` and `quit` (the calls the lifecycle makes) with the wiring `LocalAccountBootstrap` installs, and read
/// what is left in the App Group directory and the Spotlight index. Deleting any removal line in `SystemSurfaceWiring` fails one of them.
@Suite @MainActor struct SurfaceBarrierTests {
    @MainActor struct Rig {
        let media: MediaRig, dir: URL, store: WidgetSnapshotStore, index = InMemorySearchableIndex(), source = SpotlightControllerTests.Source()
        let publisher: WidgetSnapshotPublisher, controller: SpotlightController, settings: SpotlightSettings, scratch = ScratchDefaults()
        init() async throws {
            media = try await MediaRig.make()
            dir = Scratch.make(); store = WidgetSnapshotStore(directory: dir)
            settings = SpotlightSettings(defaults: scratch.defaults)
            let authority = media.authority
            let scope: @MainActor () async -> IntentScope? = { await authority.activeScope().map { IntentScope(accountID: $0.account, generation: $0.generation) } }
            publisher = WidgetSnapshotPublisher(store: store, reloader: RecordingTimelineReloader(), nowPlaying: media.model.nowPlaying, liveScope: scope, reloadInterval: .milliseconds(1))
            controller = SpotlightController(indexer: SpotlightIndexer(backend: index), settings: settings, source: source, liveScope: scope, debounce: .milliseconds(5))
            media.model.nowPlaying.onChange = { [publisher] in publisher.changed() }
            SystemSurfaceWiring.register(authority: authority, widget: publisher, spotlight: controller)
            source.rows = [.songs: [IntentFixtures.song("Saved Song", video: "vSaved", context: "OLAK5uy_ctx")], .playlists: [IntentFixtures.playlist("Private Playlist Name", id: "PLpriv")]]
            settings.setEnabled(true); settings.setIncludePrivate(true)
        }
        var account: UUID { media.context.account!.accountID }
        var token: String { WidgetScope.token(for: account) }
        /// Playing, with the widget snapshot written and the account's entries indexed.
        func start() async throws {
            try await media.play()
            await publisher.settle()
            await controller.reconcileNow()
            #expect(snapshot()?.title != nil, "precondition: the snapshot holds the playing item")
            #expect(accountTitles.isSuperset(of: ["Saved Song", "Private Playlist Name"]), "precondition: the account's entries are indexed")
        }
        func snapshot() -> WidgetSnapshot? { if case .snapshot(let s) = store.read() { s } else { nil } }
        var accountTitles: Set<String> { Set(index.entries.filter { $0.accountToken == token }.map(\.title)) }
        func clean() { Scratch.remove(dir); scratch.clean() }
        static let barrier = RequestContext(account: nil, accountGeneration: 99, requestGeneration: 0)
    }

    @Test func signingOutRemovesTheAccountsEntriesAndTheWidgetShowsSignedOut() async throws {
        let rig = try await Rig(); defer { rig.clean() }
        try await rig.start()
        try await rig.media.authority.detach(previous: rig.media.context, barrier: Rig.barrier)
        await rig.publisher.settle()
        #expect(rig.accountTitles.isEmpty, "Private Playlist Name and Saved Song are gone from Spotlight at sign-out")
        #expect(Set(rig.index.entries.map(\.title)) == SpotlightIndexTests.actionTitles, "only the account-free actions remain")
        let after = try #require(rig.snapshot())
        #expect(after.state == .signedOut && after.title == nil && after.scope == nil, "the widget no longer shows the account's item: \(after)")
    }
    @Test func switchingAwayFromAnAccountRemovesItsEntriesAndItsSnapshot() async throws {
        let rig = try await Rig(); defer { rig.clean() }
        try await rig.start()
        // A switch is a detach of the previous account followed by the next account's restore.
        try await rig.media.authority.detach(previous: rig.media.context, barrier: Rig.barrier)
        #expect(rig.accountTitles.isEmpty && rig.snapshot()?.title == nil)
    }
    @Test func removingTheAccountRemovesItsEntriesAndItsSnapshotAndRemovingAnotherLeavesThem() async throws {
        let rig = try await Rig(); defer { rig.clean() }
        try await rig.start()
        let other = try AccountContext(accountID: UUID(), channelID: ID("another-channel"), region: "US")
        try await rig.media.authority.removeLocal(other, context: RequestContext(account: other, accountGeneration: 1, requestGeneration: 1))
        #expect(rig.accountTitles.isSuperset(of: ["Saved Song", "Private Playlist Name"]) && rig.snapshot()?.title != nil, "another account's removal changes nothing here")
        try await rig.media.authority.removeLocal(rig.media.context.account!, context: rig.media.context)
        await rig.publisher.settle()
        #expect(rig.accountTitles.isEmpty, "removing the account removes its indexed private entities and its public ones")
        #expect(rig.snapshot()?.title == nil && rig.snapshot()?.state == .signedOut)
    }
    @Test func quitClearsTheWidgetAtOnceAndLeavesSpotlightsEntriesWhichStayValidWhileTheAppIsClosed() async throws {
        let rig = try await Rig(); defer { rig.clean() }
        try await rig.start()
        await rig.media.authority.quit()
        #expect(rig.store.read() == .missing, "no snapshot, so no buttons, survive the process")
        #expect(rig.accountTitles.isSuperset(of: ["Saved Song", "Private Playlist Name"]), "quit is not a removal: the index keeps what the person saved")
    }
    @Test func quitDeletesTheSnapshotEvenAfterASignOutEarlierInTheLaunchAndNothingWritesAfterIt() async throws {
        let rig = try await Rig(); defer { rig.clean() }
        try await rig.start()
        try await rig.media.authority.detach(previous: rig.media.context, barrier: Rig.barrier)
        await rig.publisher.settle()
        #expect(rig.snapshot()?.state == .signedOut, "precondition: signed out earlier in the launch, so the app is KNOWN to be signed out")
        await rig.media.authority.quit()   // the teardown that follows changes Now Playing, which used to write the signed-out snapshot back
        #expect(rig.store.read() == .missing, "quit's deletion is final")
        rig.publisher.changed(); rig.publisher.noteSignedOut(); rig.publisher.sessionActiveChanged(false); rig.publisher.scopeBound()
        await rig.publisher.settle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.store.read() == .missing && rig.store.listing().isEmpty && rig.publisher.terminated, "nothing may write after quit, whoever asks")
    }
    @Test func anAccountBecomingLiveAgainRestoresTheWidgetAndTheIndex() async throws {
        let rig = try await Rig(); defer { rig.clean() }
        try await rig.start()
        try await rig.media.authority.detach(previous: rig.media.context, barrier: Rig.barrier)
        await rig.publisher.settle()
        #expect(rig.snapshot()?.state == .signedOut)
        try await rig.media.authority.restorePaused(rig.media.identity, context: rig.media.context)
        await rig.publisher.settle(); await rig.controller.settle()
        #expect(rig.snapshot()?.state != .signedOut && rig.snapshot()?.scope != nil, "the signed-out sentence is replaced once an account is live")
        #expect(rig.accountTitles.contains("Saved Song"), "and the account's entries are indexed again")
    }
}
