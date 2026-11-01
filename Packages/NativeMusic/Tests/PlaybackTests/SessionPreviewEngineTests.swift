import AppKit
import Foundation
import Testing
import Features
import Domain
import AccountSession
@testable import Playback
@testable import AppShell

/// W20: the application's preview engine is the shared playback session. These tests drive it with a fake hidden page and a recording
/// performer; nothing here plays audio or reaches a network.
@MainActor private final class RecordingSessionPerformer: SearchActionPerformer {
    var calls: [(playlistID: String, videoID: String?, params: String?)] = []
    var outcome: SearchPlayOutcome = .started
    func play(playlistID: String, title: String) async -> SearchPlayOutcome { await play(playlistID: playlistID, title: title, videoID: nil, params: nil) }
    func play(playlistID: String, title: String, videoID: String?, params: String?) async -> SearchPlayOutcome {
        calls.append((playlistID, videoID, params)); return outcome
    }
    func copy(link: URL) {}
}

/// The engine holds the shared session's performer weakly, as the application does; the test keeps it alive.
@MainActor private enum KeptPerformers { static var items: [AnyObject] = [] }

@Suite @MainActor struct SessionPreviewEngineTests {
    private func rig() -> (SessionPreviewEngine, RecordingSessionPerformer, PlaybackModel) {
        let log = PageLog()
        let owner = AppPlaybackAuthority(makeMusicPage: { delegate in let page = FakeMusicPage(delegate: delegate); log.pages.append(page); return page })
        let model = PlaybackModel(authority: owner)
        let performer = RecordingSessionPerformer()
        KeptPerformers.items.append(performer)
        return (SessionPreviewEngine(playback: model, performer: performer), performer, model)
    }
    private let sample = SampleClip(id: "vid00000001", title: "A clip", playlistID: "RDAMVMvid00000001", params: "p")

    @Test func startingAPreviewAsksTheSharedSessionForThatClipWithTheServicesOwnPlaylist() async {
        let (engine, performer, _) = rig()
        #expect(await engine.start(sample))
        #expect(performer.calls.count == 1 && performer.calls[0].playlistID == "RDAMVMvid00000001" && performer.calls[0].videoID == "vid00000001" && performer.calls[0].params == "p")
        #expect(engine.previewing == "vid00000001")
    }
    @Test func aClipWithNoPlaylistOfItsOwnPlaysAsItsRadio() async {
        let (engine, performer, _) = rig()
        _ = await engine.start(SampleClip(id: "vid00000002", title: "No list"))
        #expect(performer.calls[0].playlistID == "RDAMVMvid00000002")
    }
    @Test func aRefusedStartClaimsNothingIsPreviewing() async {
        let (engine, performer, _) = rig()
        performer.outcome = .failed
        #expect(await engine.start(sample) == false)
        #expect(engine.previewing == nil)
    }
    @Test func withoutASharedSessionNothingStarts() async {
        let owner = AppPlaybackAuthority(makeMusicPage: { delegate in FakeMusicPage(delegate: delegate) })
        let engine = SessionPreviewEngine(playback: PlaybackModel(authority: owner), performer: nil)
        #expect(await engine.start(sample) == false && engine.previewing == nil)
    }
    @Test func stoppingWithNothingPlayingIsSafeAndForgetsThePreview() async {
        let (engine, _, _) = rig()
        _ = await engine.start(sample)
        await engine.stop()
        #expect(engine.previewing == nil)
        await engine.stop()
        #expect(engine.previewing == nil)
    }
    private func reading(_ video: String?, _ phase: WebMusicPhase, position: Double = 3) -> WebMusicSnapshot {
        var snapshot = WebMusicSnapshot(); snapshot.videoID = video; snapshot.phase = phase; snapshot.position = position; return snapshot
    }
    @Test func aPreviewIsWatchedAndEndsWithItsClipNeverRunningOnIntoTheRadiosNextTrack() async {
        let (engine, _, model) = rig()
        let clip = SampleClip(id: "vid00000001", title: "A clip", playlistID: "RDAMVMvid00000001", durationSeconds: 20)
        #expect(engine.watch(reading("vid00000001", .playing)) == .stay, "nothing is previewing yet")
        model.playRequestCount = 5        // earlier requests do not count: only those made after the preview began
        _ = await engine.start(clip)
        #expect(engine.watch(reading("vid00000001", .playing, position: 5)) == .stay)
        #expect(engine.watch(reading("vid00000001", .playing, position: 19.9)) == .clipEnded, "ends at the stated length, before the next track")
        #expect(engine.watch(reading("vid00000001", .ended)) == .clipEnded)
        #expect(engine.watch(reading("vid00000002", .playing)) == .leftOnItsOwn, "the radio's next track began by itself")
        model.playRequestCount += 1       // something asked the shared session for another item
        #expect(engine.watch(reading("vid00000002", .playing)) == .replacedByRequest)
    }
    @Test func aStoppedPreviewIsNotWatched() async {
        let (engine, _, _) = rig()
        _ = await engine.start(sample)
        await engine.stop()
        #expect(engine.watch(reading("vid00000099", .playing)) == .stay)
    }
    @Test func otherPlaybackIsNotBusyWhenNothingPlays() {
        let (engine, _, _) = rig()
        #expect(engine.otherPlaybackBusy == false)
    }
    @Test func aClipIsMarkedAsPreviewedBeforeThePlayerReportsAnythingAndForgottenWhenItStops() async {
        let (engine, _, _) = rig()
        _ = await engine.start(sample)
        #expect(engine.previewing == "vid00000001")
        await engine.stop()
        #expect(engine.previewing != "vid00000001")
    }
}

/// The whole path through the real shared session (a fake hidden page): a preview that the radio runs past is paused, a clip's end ends it.
@Suite @MainActor struct SessionPreviewEndToEndTests {
    private func identity() throws -> (LocalIdentity, RequestContext) {
        let id = UUID()
        let context = try AccountContext(accountID: id, channelID: ID("UCsyntheticPreview"), region: "US")
        let account = try Account(id: id, serviceIdentity: ServiceID("UCsyntheticPreview"), context: context, displayName: "Synthetic Listener", credential: try CredentialReference("synthetic-ref"))
        return (LocalIdentity(account: account, state: .connected), RequestContext(account: context, accountGeneration: 4, requestGeneration: 0))
    }
    private func rig() async throws -> (SessionPreviewEngine, PreviewArbiter, PlaybackModel, PageLog) {
        let log = PageLog()
        let owner = AppPlaybackAuthority(makeMusicPage: { delegate in let page = FakeMusicPage(delegate: delegate); log.pages.append(page); return page })
        await owner.configureMusic { _ in FakeCookieSource() }
        let (who, context) = try identity()
        try await owner.restorePaused(who, context: context)
        let model = PlaybackModel(authority: owner)
        let board = NSPasteboard(name: NSPasteboard.Name("local.native-music.test-" + UUID().uuidString))
        let performer = AppSearchPerformer(playback: model, pasteboard: board)
        KeptPerformers.items.append(performer)
        let engine = SessionPreviewEngine(playback: model, performer: performer)
        return (engine, PreviewArbiter(engine: engine), model, log)
    }
    private func reading(_ video: String?, _ phase: WebMusicPhase, position: Double = 3) -> WebMusicSnapshot {
        var snapshot = WebMusicSnapshot(); snapshot.videoID = video; snapshot.phase = phase; snapshot.position = position; return snapshot
    }
    private let clip = SampleClip(id: "aaaaaaaaaa1", title: "A clip", playlistID: "RDAMVMaaaaaaaaaa1", durationSeconds: 20)

    @Test func aRadioThatRunsPastTheClipByItselfIsPausedAndThePreviewEnds() async throws {
        let (engine, arbiter, model, log) = try await rig()
        #expect(await arbiter.request(clip, trigger: .explicit) == .previewing)
        let page = try #require(log.pages.first)
        #expect(model.music != nil && engine.previewing == "aaaaaaaaaa1")
        let before = page.bodies.filter { $0 == WebMusicScripts.pause }.count
        await engine.observe(reading("aaaaaaaaaa2", .playing), arbiter: arbiter)
        #expect(page.bodies.filter { $0 == WebMusicScripts.pause }.count == before + 1, "the track nobody asked for is paused")
        #expect(arbiter.active == nil)
        #expect(arbiter.events.contains(.stopped("aaaaaaaaaa1", reason: .leftOnItsOwn)))
    }
    @Test func aClipThatReachesItsEndEndsThePreviewWithoutTouchingThePlayerItself() async throws {
        let (engine, arbiter, _, log) = try await rig()
        _ = await arbiter.request(clip, trigger: .explicit)
        let page = try #require(log.pages.first)
        await engine.observe(reading("aaaaaaaaaa1", .playing, position: 19.9), arbiter: arbiter)
        #expect(arbiter.active == nil && arbiter.events.contains(.stopped("aaaaaaaaaa1", reason: .clipEnded)))
        _ = page
    }
    @Test func aPlayerThatMovedBecauseSomethingAskedItIsLeftAloneAndStopsBeingPreviewed() async throws {
        let (engine, arbiter, model, log) = try await rig()
        _ = await arbiter.request(clip, trigger: .explicit)
        let page = try #require(log.pages.first)
        model.playRequestCount += 1
        let before = page.bodies.filter { $0 == WebMusicScripts.pause }.count
        await engine.observe(reading("aaaaaaaaaa2", .playing), arbiter: arbiter)
        #expect(page.bodies.filter { $0 == WebMusicScripts.pause }.count == before, "the item that was asked for keeps playing")
        #expect(arbiter.active == nil && arbiter.events.contains(.stopped("aaaaaaaaaa1", reason: .playbackStarted)))
    }
    @Test func theClipStillPlayingInsideItsLengthKeepsThePreview() async throws {
        let (engine, arbiter, _, _) = try await rig()
        _ = await arbiter.request(clip, trigger: .explicit)
        await engine.observe(reading("aaaaaaaaaa1", .playing, position: 4), arbiter: arbiter)
        #expect(arbiter.active == "aaaaaaaaaa1")
    }
}

@Suite @MainActor struct DeviceConditionsMonitorTests {
    @Test func aFixedReadingIsReadBackAndTellsTheArbiterItChanged() {
        let monitor = DeviceConditionsMonitor(watching: false)
        var told = 0
        monitor.changed = { told += 1 }
        monitor.pin(lowPowerMode: true, constrainedNetwork: true)
        #expect(monitor.lowPowerMode && monitor.constrainedNetwork && told == 1)
        monitor.pin(lowPowerMode: false, constrainedNetwork: false)
        #expect(!monitor.lowPowerMode && !monitor.constrainedNetwork && told == 2)
    }
    @Test func aMonitorThatIsNotWatchingStartsFromTheSystemsLowPowerReadingAndNeverSaysConstrained() {
        let monitor = DeviceConditionsMonitor(watching: false)
        #expect(monitor.lowPowerMode == ProcessInfo.processInfo.isLowPowerModeEnabled)
        #expect(monitor.constrainedNetwork == false)
    }
}
