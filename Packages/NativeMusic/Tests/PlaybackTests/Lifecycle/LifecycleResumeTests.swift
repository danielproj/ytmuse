import Foundation
import Testing
import Domain
@testable import Playback
@testable import AppShell

/// WIN09: a manual cold launch restores the last session paused, from this Mac's own record, and never plays.
@Suite @MainActor struct LifecycleResumeTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-life-resume-" + UUID().uuidString) }
    private func record(position: Double = 42) -> MusicResumeRecord {
        MusicResumeRecord(playlistID: "PLsyntheticLife", playlistTitle: "Synthetic Mix", videoID: lifecycleVideo, title: "Synthetic Song", artist: "Synthetic Artist", position: position, duration: 200)
    }
    @Test func theStoreRoundTripsPrivatelyAndRemovingTheAccountRemovesTheRecord() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicResumeFileStore(directory: root)
        let (identity, context) = try lifecycleIdentity()
        let account = identity.id.accountID.uuidString
        #expect(try await store.load(account: account) == nil)
        try await store.save(record(), account: account)
        #expect(try await store.load(account: account) == record())
        let file = root.appendingPathComponent(account + ".plist")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        try await store.removeLocal(identity.id, context: context)
        #expect(try await store.load(account: account) == nil && !FileManager.default.fileExists(atPath: file.path))
        await #expect(throws: MusicResumeFileStore.Failure.invalidAccount) { try await store.save(record(), account: "../escape") }
    }
    @Test func aRecordOnDiskIsTrustedOnlyAfterEveryFieldPassesTheRulesOfARequest() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicResumeFileStore(directory: root)
        let account = UUID().uuidString
        for bad in [MusicResumeRecord(playlistID: "not a playlist", playlistTitle: nil, videoID: nil, title: nil, artist: nil, position: 1, duration: 2),
                    MusicResumeRecord(playlistID: "PLsyntheticLife", playlistTitle: nil, videoID: "bad id", title: nil, artist: nil, position: 1, duration: 2),
                    MusicResumeRecord(playlistID: "PLsyntheticLife", playlistTitle: nil, videoID: nil, title: nil, artist: nil, position: -1, duration: 2),
                    MusicResumeRecord(playlistID: "PLsyntheticLife", playlistTitle: nil, videoID: nil, title: String(repeating: "a", count: 2_000), artist: nil, position: 1, duration: 2),
                    MusicResumeRecord(playlistID: "PLsyntheticLife", playlistTitle: nil, videoID: nil, title: nil, artist: nil, position: .nan, duration: 2)] {
            #expect(!bad.isValid)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: root.appendingPathComponent(account + ".plist"))
        #expect(try await store.load(account: account) == nil, "a corrupt file restores nothing and raises nothing")
    }
    @Test func onlyWorthwhilePlaybackIsRecordedAndNeverAnAdOrAFailure() throws {
        var snapshot = WebMusicSnapshot()
        #expect(MusicResumePolicy.record(snapshot, position: 1) == nil, "idle")
        snapshot.phase = .playing; snapshot.playlistID = "PLsyntheticLife"; snapshot.title = "Song"; snapshot.videoID = lifecycleVideo; snapshot.duration = 100
        #expect(MusicResumePolicy.record(snapshot, position: 12.5)?.position == 12.5)
        snapshot.isAd = true; #expect(MusicResumePolicy.record(snapshot, position: 1) == nil, "an ad is not the session")
        snapshot.isAd = false; snapshot.restored = true; #expect(MusicResumePolicy.record(snapshot, position: 1) == nil, "a restored item has not played yet")
        snapshot.restored = false; snapshot.phase = .failed(.timedOut); #expect(MusicResumePolicy.record(snapshot, position: 1) == nil)
        snapshot.phase = .ended; #expect(MusicResumePolicy.record(snapshot, position: 1) == nil)
    }
    @Test func aChangeWritesAtOnceAndAPlayingItemWritesAtMostEveryInterval() {
        var policy = MusicResumePolicy(interval: .seconds(20))
        var snapshot = WebMusicSnapshot(); snapshot.phase = .playing; snapshot.videoID = lifecycleVideo; snapshot.intent = true
        let start = ContinuousClock.now
        var decisions: [String: Bool] = [:]
        decisions["first sight"] = policy.shouldSave(snapshot, now: start)
        decisions["+5s"] = policy.shouldSave(snapshot, now: start + .seconds(5))
        decisions["+19s"] = policy.shouldSave(snapshot, now: start + .seconds(19))
        decisions["+20s"] = policy.shouldSave(snapshot, now: start + .seconds(20))
        snapshot.phase = .paused; snapshot.intent = false
        decisions["paused"] = policy.shouldSave(snapshot, now: start + .seconds(21))
        decisions["paused later"] = policy.shouldSave(snapshot, now: start + .seconds(100))
        snapshot.videoID = lifecycleOtherVideo
        decisions["new item"] = policy.shouldSave(snapshot, now: start + .seconds(101))
        #expect(decisions == ["first sight": true, "+5s": false, "+19s": false, "+20s": true, "paused": true, "paused later": false, "new item": true], "\(decisions)")
    }
    @Test func aColdLaunchShowsTheLastSessionPausedLoadingAndPlayingNothing() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await LifecycleRig.make()
        let store = MusicResumeFileStore(directory: root)
        try await store.save(record(position: 42), account: rig.identity.id.accountID.uuidString)
        rig.model.resumeStore = store
        await rig.model.restoreLastSession()
        let player = try #require(rig.model.music)
        try await Task.sleep(for: .milliseconds(150))   // long enough for any play a launch might have started on its own
        #expect(rig.log.pages.isEmpty, "no page, no load, no network, no sound: nothing was created behind the restored item")
        #expect(player.snapshot.phase == .paused && !player.snapshot.intent && player.snapshot.restored)
        #expect(player.snapshot.title == "Synthetic Song" && player.snapshot.artist == "Synthetic Artist" && player.timeline.position == 42)
        let state = rig.model.shellState
        #expect(state.hasItem && !state.isPlaying && !state.canSkip && !state.canSeek, "paused; skip and seek wait for Play")
        #expect(rig.model.nowPlaying.isActive, "media keys can start it: an explicit action")
    }
    @Test func playingARestoredItemLoadsItsPlaylistAndItemThenMovesToWhereItWas() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await LifecycleRig.make()
        let store = MusicResumeFileStore(directory: root)
        try await store.save(record(position: 42), account: rig.identity.id.accountID.uuidString)
        rig.model.resumeStore = store
        await rig.model.restoreLastSession()
        _ = rig.model.remote(.play)           // a media key: an explicit action
        for _ in 0..<400 where rig.log.pages.first?.loads.isEmpty ?? true { try await Task.sleep(for: .milliseconds(5)) }
        let page = try #require(rig.log.pages.first)
        let components = URLComponents(url: try #require(page.loads.last), resolvingAgainstBaseURL: false)
        #expect(components?.queryItems?.first { $0.name == "list" }?.value == "PLsyntheticLife" && components?.queryItems?.first { $0.name == "v" }?.value == lifecycleVideo)
        page.commitLast(); page.send(lifecycleState(position: 0))
        for _ in 0..<100 where !page.bodies.contains(WebMusicScripts.seek) { try await Task.sleep(for: .milliseconds(5)) }
        let seek = page.commands.first { $0.body == WebMusicScripts.seek }
        #expect(seek?.arguments["seconds"] as? Double == 42, "back to where it was, once the item plays")
        #expect(!rig.model.shellState.hasItem || rig.model.music?.snapshot.restored == false)
    }
    @Test func nothingIsRestoredAfterSomethingWasAlreadyPlayedOrWithoutARecordOrAnAccount() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await LifecycleRig.make()
        let store = MusicResumeFileStore(directory: root)
        rig.model.resumeStore = store
        await rig.model.restoreLastSession()
        #expect(rig.model.music == nil, "no record: nothing")
        try await store.save(record(), account: rig.identity.id.accountID.uuidString)
        _ = try await rig.play()
        let playing = rig.model.music
        await rig.model.restoreLastSession()
        #expect(rig.model.music === playing && rig.model.shellState.isPlaying, "a player that is already running is never replaced by a restored item")
        let detached = try await LifecycleRig.make()
        try await detached.authority.detach(previous: detached.context, barrier: RequestContext(account: nil, accountGeneration: 8, requestGeneration: 0))
        detached.model.resumeStore = store
        await detached.model.restoreLastSession()
        #expect(detached.model.music == nil, "no account: nothing")
    }
    @Test func quitAndSleepWriteTheSessionBeforeThePlayerIsDropped() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await LifecycleRig.make()
        let store = MusicResumeFileStore(directory: root)
        rig.model.resumeStore = store
        let (_, page) = try await rig.play(state: lifecycleState(position: 77))
        page.send(lifecycleState(position: 77))
        await rig.model.saveResumeNow()
        let saved = try await store.load(account: rig.identity.id.accountID.uuidString)
        #expect(saved?.playlistID == "PLsyntheticLife" && saved?.title == "Synthetic Song" && saved?.position == 77)
        // The quit path saves first, then drops the player (source order is the contract).
        let composition = try LifecycleSources.source("Sources/AppShell/LocalAccountComposition.swift")
        // Scoped to the body of the bootstrap's own quit (`func shutdown()`): the app's static closure also mentions the authority's quit, as its
        // fallback when the bootstrap is gone, and that is not the sequence that runs.
        let start = try #require(composition.range(of: "func shutdown() async {"))
        let end = try #require(composition.range(of: "\n    }\n", range: start.upperBound..<composition.endIndex))
        let body = composition[start.upperBound..<end.lowerBound]
        let save = try #require(body.range(of: "saveResumeNow()")), quit = try #require(body.range(of: "authority.quit()"))
        #expect(save.lowerBound < quit.lowerBound)
        // An ad is never written over the session.
        page.send(lifecycleState(position: 0, duration: 15, video: lifecycleAdVideo, ad: true))
        await rig.model.saveResumeNow()
        #expect(try await store.load(account: rig.identity.id.accountID.uuidString)?.position == 77)
    }
}

/// F7 / F8: the resume record is fenced to the player and account that produced it, the restore guard is pinned, and the store lives under the app directory.
@Suite @MainActor struct LifecycleResumeFenceTests {
    actor RecordingStore: MusicResumeStoring {
        var saves: [(MusicResumeRecord, String)] = []
        var stored: MusicResumeRecord?
        init(_ stored: MusicResumeRecord? = nil) { self.stored = stored }
        func save(_ record: MusicResumeRecord, account: String) { saves.append((record, account)) }
        func load(account: String) -> MusicResumeRecord? { stored }
        func clear(account: String) {}
        func saved() -> [(MusicResumeRecord, String)] { saves }
    }
    @Test func aQueuedWriteFromAClosedOrReplacedPlayerIsNeverWritten() async throws {
        let rig = try await LifecycleRig.make()
        let (player, _) = try await rig.play()
        #expect(PlaybackModel.resumeWriteAllowed(player: player, current: player, closed: false))
        #expect(!PlaybackModel.resumeWriteAllowed(player: player, current: nil, closed: false), "released by a switch")
        #expect(!PlaybackModel.resumeWriteAllowed(player: player, current: player, closed: true), "closed")
        let other = try await LifecycleRig.make()
        let (second, _) = try await other.play()
        #expect(!PlaybackModel.resumeWriteAllowed(player: player, current: second, closed: false), "a different owner")
    }
    @Test func anAccountSwitchBetweenTheReadingAndTheWriteLosesTheRecordInsteadOfMisfilingIt() async throws {
        let rig = try await LifecycleRig.make()
        let store = RecordingStore()
        rig.model.resumeStore = store
        let (player, page) = try await rig.play()
        // A reading is noted for account A, then the account barrier passes (the owner closes the player) before the queued write resolves its account.
        rig.model.noteForResume(player.snapshot)
        try await rig.authority.detach(previous: rig.context, barrier: RequestContext(account: nil, accountGeneration: 9, requestGeneration: 0))
        try await rig.authority.restorePaused(rig.identity, context: RequestContext(account: rig.context.account, accountGeneration: 10, requestGeneration: 0))
        try await Task.sleep(for: .milliseconds(80))
        let saves = await store.saved()
        #expect(saves.allSatisfy { $0.1 == rig.identity.id.accountID.uuidString }, "only ever filed under the account that produced it")
        page.send(lifecycleState(position: 20))
        #expect(rig.model.music == nil || rig.model.music?.isClosed == false)
        // The fence is applied between the account lookup and the write, in that order.
        let source = try LifecycleSources.source("Sources/AppShell/Lifecycle/MusicResume.swift")
        let lookup = try #require(source.range(of: "await self.authority.activeAccountID()"))
        let fence = try #require(source.range(of: "Self.resumeWriteAllowed(player: player, current: self.music, closed: player.isClosed)"))
        let write = try #require(source.range(of: "try? await store.save(record, account: account.uuidString)\n        }\n    }\n    /// The fence"))
        #expect(lookup.lowerBound < fence.lowerBound && fence.lowerBound < write.lowerBound)
    }
    @Test func theRestoreGuardNeverReplacesARunningNativeSessionOrAPlayingPlayer() async throws {
        let record = MusicResumeRecord(playlistID: "PLsyntheticLife", playlistTitle: nil, videoID: lifecycleVideo, title: "Synthetic Song", artist: nil, position: 5, duration: 100)
        let rig = try await LifecycleRig.make()
        rig.model.resumeStore = RecordingStore(record)
        let session = try await ownedSession()
        rig.model.session = session                       // the owner is playing owned/kept media
        await rig.model.restoreLastSession()
        #expect(rig.model.music == nil && rig.model.session === session, "a restore never touches a running native session")
        #expect(await rig.authority.currentMusic() == nil && rig.log.pages.isEmpty)
        await session.close()
        let busy = try await LifecycleRig.make()
        busy.model.resumeStore = RecordingStore(record)
        busy.model.starting = true                        // a start is in flight
        await busy.model.restoreLastSession()
        #expect(busy.model.music == nil, "nor does it race a start in flight")
    }
    @Test func theResumeStoreIsBuiltOnlyUnderTheAppDirectoryWhichIsTheIsolatedRootInAnIsolatedLaunch() throws {
        let composition = try LifecycleSources.source("Sources/AppShell/LocalAccountComposition.swift")
        #expect(composition.contains("MusicResumeFileStore(directory: appDirectory.appendingPathComponent(\"music-resume\"))"))
        #expect(composition.components(separatedBy: "MusicResumeFileStore(").count == 2, "built in one place")
        #expect(composition.contains("appDirectory = isolated.root"), "under isolation the app directory is the scratch root")
        for line in composition.components(separatedBy: "\n") where line.contains("FileStore(directory:") && !line.contains("//") {
            #expect(line.contains("appDirectory"), "every per-account file store sits under the app directory: \(line)")
        }
    }
}
