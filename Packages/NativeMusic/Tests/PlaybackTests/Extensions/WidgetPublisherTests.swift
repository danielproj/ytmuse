import AppKit
import Foundation
import Testing
import SystemIntegration
import WidgetShared
@testable import SystemIntegration
@testable import AppShell

/// T25.1 / T25.2 / T25.4 (MAC06): the snapshot publisher over the REAL Now Playing owner (recording system underneath) and a store in a temporary directory.
/// It writes only when what the widget shows changed, coalesces reloads, deletes at an account barrier, redacts when the session is not active, and never writes
/// anything outside the schema.
@Suite @MainActor struct WidgetPublisherTests {
    final class Scope { var value: IntentScope?; init(_ value: IntentScope?) { self.value = value } }
    @MainActor struct Rig {
        let dir: URL, store: WidgetSnapshotStore, center: NowPlayingCenter, reloader: RecordingTimelineReloader, publisher: WidgetSnapshotPublisher, scope: Scope
        let account = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        init(interval: Duration = .milliseconds(1)) {
            dir = Scratch.make(); store = WidgetSnapshotStore(directory: dir)
            let system = NowPlayingSystem.recording()
            center = NowPlayingCenter(system: system.system)
            reloader = RecordingTimelineReloader()
            let scope = Scope(IntentScope(accountID: account, generation: 4)); self.scope = scope
            publisher = WidgetSnapshotPublisher(store: store, reloader: reloader, nowPlaying: center, liveScope: { scope.value }, reloadInterval: interval)
            center.onChange = { [publisher] in publisher.changed() }
            _ = center.activate { _ in .success }
        }
        func publish(_ item: NowPlayingItem?, caps: RemoteCapabilities? = nil) async { center.update(item, capabilities: caps); await publisher.settle() }
        func read() -> WidgetReadResult { store.read() }
        func snapshot() -> WidgetSnapshot? { if case .snapshot(let s) = store.read() { s } else { nil } }
        func clean() { Scratch.remove(dir) }
    }

    @Test func aPlayingItemIsWrittenWithTitleArtistStateButtonsAndTheAccountStamp() async throws {
        let rig = Rig(); defer { rig.clean() }
        await rig.publish(WidgetFixtures.nowPlaying())
        let snapshot = try #require(rig.snapshot())
        #expect(snapshot.state == .playing && snapshot.title == "Synthetic Song" && snapshot.artist == "Synthetic Artist")
        #expect(snapshot.capabilities == WidgetCapabilities(playPause: true, next: true, previous: true))
        #expect(snapshot.scope == WidgetScope(account: rig.account, generation: 4))
        #expect(rig.reloader.reloads == 1, "the app asked for exactly one timeline reload")
    }
    @Test func theArtworkIsAThumbnailOfThePlayingItemsPicture() async throws {
        let rig = Rig(); defer { rig.clean() }
        await rig.publish(WidgetFixtures.nowPlaying(artwork: WidgetFixtures.picture(edge: 1500)))
        let snapshot = try #require(rig.snapshot())
        let artwork = try #require(snapshot.artwork)
        #expect(artwork.count <= WidgetSnapshot.artworkByteLimit && NSImage(data: artwork) != nil)
        await rig.publish(WidgetFixtures.nowPlaying("Another", id: "B"))
        #expect(rig.snapshot()?.artwork == nil, "the next item does not keep the previous picture")
    }
    @Test func aPositionTickOrRepeatedUpdateWritesNothingAndAskesForNoReload() async throws {
        let rig = Rig(); defer { rig.clean() }
        await rig.publish(WidgetFixtures.nowPlaying())
        let writes = rig.publisher.writes, reloads = rig.reloader.reloads
        for elapsed in stride(from: 11.0, to: 90.0, by: 5) {
            var tick = WidgetFixtures.nowPlaying(); tick.elapsed = elapsed
            await rig.publish(tick)
        }
        #expect(rig.publisher.writes == writes && rig.reloader.reloads == reloads, "the widget shows no clock, so a moving clock changes nothing it shows")
        await rig.publish(WidgetFixtures.nowPlaying(playing: false))
        #expect(rig.publisher.writes == writes + 1 && rig.snapshot()?.state == .paused, "a change of state is written")
    }
    @Test func aBurstOfChangesIsOneWriteAndReloadsInsideTheIntervalAreOneReload() async throws {
        let rig = Rig(interval: .seconds(3600)); defer { rig.clean() }
        for i in 0..<40 { rig.center.update(WidgetFixtures.nowPlaying("Song \(i)", id: "\(i)")) }
        await rig.publisher.settle()
        #expect(rig.publisher.writes == 1, "forty updates before the publisher ran are one write of the last one")
        #expect(rig.snapshot()?.title == "Song 39")
        #expect(rig.reloader.reloads == 1, "and one reload")
        for i in 40..<60 { await rig.publish(WidgetFixtures.nowPlaying("Song \(i)", id: "\(i)")) }
        #expect(rig.publisher.writes == 21, "twenty more changes are twenty more writes (each is different content)")
        #expect(rig.reloader.reloads == 1, "but inside the interval no further reload goes out: they wait as one trailing request (\(rig.reloader.reloads))")
    }
    @Test func theTrailingReloadIsDeliveredNotDropped() async throws {
        let rig = Rig(interval: .milliseconds(200)); defer { rig.clean() }
        await rig.publish(WidgetFixtures.nowPlaying("One", id: "1"))
        await rig.publish(WidgetFixtures.nowPlaying("Two", id: "2"))
        await rig.publish(WidgetFixtures.nowPlaying("Three", id: "3"))
        for _ in 0..<100 where rig.reloader.reloads < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(rig.reloader.reloads >= 2, "the change made inside the interval was reloaded after it: \(rig.reloader.reloads)")
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.reloader.reloads <= 3, "and not once per change: \(rig.reloader.reloads)")
        #expect(rig.snapshot()?.title == "Three")
    }
    @Test func anAdvertisementIsPublishedAsAnAdvertisementWithNoSongAndNoPicture() async throws {
        let rig = Rig(); defer { rig.clean() }
        await rig.publish(WidgetFixtures.nowPlaying())
        let ad = WidgetFixtures.nowPlaying("The Song Before The Ad", ad: true, artwork: WidgetFixtures.picture())
        await rig.publish(ad, caps: NowPlayingMapping.capabilities(for: ad))
        let snapshot = try #require(rig.snapshot())
        #expect(snapshot.state == .advertisement && snapshot.title == nil && snapshot.artist == nil && snapshot.artwork == nil)
        #expect(snapshot.capabilities == WidgetCapabilities(playPause: true, next: false, previous: false), "an ad cannot be skipped")
        let bytes = String(decoding: try Data(contentsOf: rig.store.fileURL), as: UTF8.self)
        #expect(!bytes.contains("Before The Ad"))
    }
    @Test func whenNothingIsPublishedAnymoreTheLastItemStaysPausedWithNoButtons() async throws {
        let rig = Rig(); defer { rig.clean() }
        await rig.publish(nil)
        #expect(rig.snapshot()?.state == .idle && rig.snapshot()?.title == nil, "signed in, nothing played: a contentless idle snapshot")
        await rig.publish(WidgetFixtures.nowPlaying())
        await rig.publish(nil)
        let last = try #require(rig.snapshot())
        #expect(last.state == .paused && last.title == "Synthetic Song" && last.capabilities == .none, "the last item, paused, with every button off")
    }
    static func event(_ reason: AppPlaybackAuthority.BarrierEvent.Reason, account: UUID, generation: UInt64 = 4) -> AppPlaybackAuthority.BarrierEvent {
        AppPlaybackAuthority.BarrierEvent(reason: reason, departing: (account, generation))
    }
    @Test func nobodySignedInIsNoFileUntilTheAppKnowsItIsSignedOutAndThenTheSignedOutSentence() async throws {
        let rig = Rig(); defer { rig.clean() }
        rig.scope.value = nil
        await rig.publish(WidgetFixtures.nowPlaying())
        #expect(rig.read() == .missing && rig.publisher.writes == 0, "still starting: no account yet and not known to be signed out, so nothing is claimed")
        rig.publisher.noteSignedOut(); await rig.publisher.settle()
        #expect(rig.snapshot()?.state == .signedOut, "once the app knows nobody is signed in the widget says so (F9)")
        let content = WidgetContent.make(WidgetDisplay(rig.read()), family: .medium)
        #expect(content.texts.contains(String(localized: "Sign in to YouTube Music in YTMuse.")) && content.controls.isEmpty, "the signed-out sentence, no title, no buttons")
        rig.scope.value = IntentScope(accountID: rig.account, generation: 4)
        rig.publisher.scopeBound(); await rig.publisher.settle()
        #expect(rig.snapshot()?.state != .signedOut && rig.snapshot()?.scope?.generation == 4, "an account becoming live replaces it")
    }
    @Test func signingOutReplacesTheSnapshotWithTheContentlessSignedOutOneAndReloadsAtOnce() async throws {
        let rig = Rig(interval: .seconds(3600)); defer { rig.clean() }
        await rig.publish(WidgetFixtures.nowPlaying())
        let reloads = rig.reloader.reloads
        await rig.publisher.barrier(Self.event(.detach, account: rig.account))
        let after = try #require(rig.snapshot())
        #expect(after.state == .signedOut && after.title == nil && after.scope == nil && after.capabilities == .none, "nothing of the account is left: \(after)")
        #expect(!String(decoding: try Data(contentsOf: rig.store.fileURL), as: UTF8.self).contains("Synthetic"))
        #expect(rig.reloader.reloads == reloads + 1, "the barrier reload is immediate, not behind the coalescing interval")
        // The authority clears its scope AFTER the handlers run in production; a flush that read the old scope just before must not bring the session back.
        await rig.publish(WidgetFixtures.nowPlaying("Late Update", id: "L"))
        #expect(rig.snapshot()?.state == .signedOut, "a late update for the ended session cannot bring it back")
        rig.scope.value = IntentScope(accountID: rig.account, generation: 5)   // the same account signs in again: a new session
        rig.publisher.scopeBound()
        await rig.publish(WidgetFixtures.nowPlaying("New Session", id: "N"))
        let again = try #require(rig.snapshot())
        #expect(again.title == "New Session" && again.scope?.generation == 5, "the next session writes again, under its own stamp")
    }
    @Test func quitDeletesTheFileAndReloadsAtOnceEvenInsideTheCoalescingInterval() async throws {
        let rig = Rig(interval: .seconds(3600)); defer { rig.clean() }
        await rig.publish(WidgetFixtures.nowPlaying("One", id: "1"))
        await rig.publish(WidgetFixtures.nowPlaying("Two", id: "2"))   // inside the interval: this reload is only pending
        let reloads = rig.reloader.reloads
        await rig.publisher.barrier(Self.event(.quit, account: rig.account))
        #expect(rig.read() == .missing && rig.store.listing().isEmpty, "no buttons survive the process")
        #expect(rig.reloader.reloads == reloads + 1, "and the widget was told before the process could go (F6)")
    }
    @Test func removingAnotherAccountLeavesThisAccountsSnapshotAndRemovingThisOneReplacesIt() async throws {
        let rig = Rig(); defer { rig.clean() }
        await rig.publish(WidgetFixtures.nowPlaying())
        try Data("keep".utf8).write(to: rig.dir.appendingPathComponent("unrelated"))
        await rig.publisher.barrier(Self.event(.removal, account: UUID()))
        #expect(rig.snapshot()?.title == "Synthetic Song", "a different account's removal leaves this account's snapshot")
        await rig.publisher.barrier(Self.event(.removal, account: rig.account))
        #expect(rig.snapshot()?.state == .signedOut)
        #expect(rig.store.listing() == [WidgetIdentity.snapshotFileName, "unrelated"].sorted(), "other files are never touched")
    }
    @Test func aSwitchToAnotherAccountNeverCarriesTheFirstAccountsLastItem() async throws {
        let rig = Rig(); defer { rig.clean() }
        await rig.publish(WidgetFixtures.nowPlaying("First Accounts Song"))
        await rig.publisher.barrier(Self.event(.detach, account: rig.account))
        rig.scope.value = IntentScope(accountID: UUID(), generation: 9)
        rig.publisher.scopeBound()
        await rig.publish(nil)
        let second = try #require(rig.snapshot())
        #expect(second.state == .idle && second.title == nil, "the second account starts empty: \(second)")
        #expect(second.scope?.accountToken != WidgetScope.token(for: rig.account))
    }
    @Test func everyStampCarriesThisLaunchsNonceSoAnEarlierLaunchsButtonIsRefused() async throws {
        let first = Rig(), second = Rig(); defer { first.clean(); second.clean() }
        await first.publish(WidgetFixtures.nowPlaying())
        let a = try #require(first.snapshot()?.scope)
        #expect(a.launch == WidgetLaunch.nonce && a.launch.count == 32, "this process's nonce")
        // A later launch has another nonce: the same account and generation do not match.
        let relaunched = WidgetScope(accountToken: a.accountToken, generation: a.generation, launch: String(repeating: "f", count: 32))
        #expect(WidgetCommandGate.verdict(for: WidgetCommandStamp(a), live: relaunched) == .refuse(.earlierSession), "the stale button from the previous launch is refused")
        #expect(WidgetCommandGate.verdict(for: WidgetCommandStamp(a), live: a) == .admit)
        _ = second
    }
    @Test func aSessionThatIsNotTheActiveOneIsTheLockedContentlessSnapshotAndComingBackRestoresIt() async throws {
        let rig = Rig(); defer { rig.clean() }
        await rig.publish(WidgetFixtures.nowPlaying())
        rig.publisher.sessionActiveChanged(false); await rig.publisher.settle()
        let locked = try #require(rig.snapshot())
        #expect(locked.state == .locked && locked.title == nil && locked.artist == nil && locked.artwork == nil && locked.scope == nil && locked.capabilities == .none)
        let bytes = String(decoding: try Data(contentsOf: rig.store.fileURL), as: UTF8.self)
        #expect(!bytes.contains("Synthetic"), "nothing of the song is left in the file")
        rig.publisher.sessionActiveChanged(true); await rig.publisher.settle()
        #expect(rig.snapshot()?.title == "Synthetic Song")
    }

    // MARK: T25.4 — what is actually in the group

    @Test func theGroupHoldsOneFileWithOnlySchemaKeysAndNoCanaryFedThroughAnyInputThePublisherReads() async throws {
        let rig = Rig(); defer { rig.clean() }
        // The canaries go through the publisher's REAL inputs: every field of the playing item it could read (album, item id, route name, artwork bytes) and the live scope's
        // account id. Title and artist are the two fields it writes by design, so they carry ordinary text.
        let canaries = ["SAPISID=canary-cookie", "Bearer canary-token", "person@example.com", "Private Playlist Canary", "canary-video-id", "Canary Speakers"]
        let accountIDs = [rig.account.uuidString, rig.account.uuidString.lowercased()]
        func item(ad: Bool = false, playing: Bool = true) -> NowPlayingItem {
            NowPlayingItem(title: "Synthetic Song", artist: "Synthetic Artist", album: "SAPISID=canary-cookie", artwork: WidgetFixtures.picture(), duration: 200, elapsed: 10, playing: playing,
                           advertisement: ad, route: NowPlayingRoute(kind: .airPlay, name: "Canary Speakers"), itemID: "canary-video-id")
        }
        var withEmail = item(); withEmail.album = "person@example.com Private Playlist Canary Bearer canary-token"
        var scenarios: [() async -> Void] = []
        scenarios.append { await rig.publish(item()) }
        scenarios.append { await rig.publish(withEmail) }
        scenarios.append { await rig.publish(item(playing: false)) }
        scenarios.append { await rig.publish(item(ad: true)) }
        scenarios.append { await rig.publish(nil) }
        scenarios.append { rig.publisher.sessionActiveChanged(false); await rig.publisher.settle() }
        scenarios.append { rig.publisher.sessionActiveChanged(true); await rig.publisher.settle() }
        scenarios.append { await rig.publisher.barrier(Self.event(.detach, account: rig.account)) }
        var seen = 0
        for scenario in scenarios {
            await scenario()
            let files = Scratch.bytes(in: rig.dir)
            #expect(Set(files.keys) == [WidgetIdentity.snapshotFileName], "exactly one file in the group: \(files.keys)")
            let data = try #require(files[WidgetIdentity.snapshotFileName])
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(object.keys).isSubset(of: WidgetSnapshot.allowedKeys), "only schema keys: \(object.keys)")
            if let scope = object["scope"] as? [String: Any] { #expect(Set(scope.keys).isSubset(of: WidgetScope.allowedKeys)) }
            if let caps = object["capabilities"] as? [String: Any] { #expect(Set(caps.keys).isSubset(of: WidgetCapabilities.allowedKeys)) }
            let text = String(decoding: data, as: UTF8.self)
            for canary in canaries + accountIDs { #expect(!text.contains(canary), "\(canary) must never be in the group") }
            #expect(data.count < WidgetSnapshotStore.fileByteLimit)
            seen += 1
        }
        #expect(seen == scenarios.count)
    }
}
