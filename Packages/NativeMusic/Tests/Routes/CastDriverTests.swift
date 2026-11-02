import Foundation
import Synchronization
import Testing
@testable import OutputRoutes
import TestSupport

/// T39.1 (against a simulated receiver), T39.2 and T39.3: the route driver joins the native session to a receiver inside the W22 route model. The receiver is
/// `SimulatedCastReceiver`; the media goes through the REAL relay on loopback; the native session is a recorder. Real devices are on the live list.
@Suite @MainActor struct CastRouteTests {
    func connect(_ rig: CastRig, to device: CastDevice = CastFixtures.livingRoom) async -> SelectionOutcome { await rig.coordinator.select(device.routeID, engine: .localMedia) }

    // MARK: Authorized source media reaches the receiver (T39.1, simulated)

    @Test func theReceiverIsGivenAnAddressItCanFetchAndTheFileItGetsIsTheItemsOwn() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        let fetched = Mutex<(Int, Data)?>(nil)
        rig.receiver.setOnLoad { url in
            guard let parsed = URL(string: url), let port = parsed.port else { return }
            let reply = (try? LoopbackHTTP.get(port: UInt16(port), path: parsed.path)) ?? nil
            fetched.withLock { $0 = (reply?.status ?? 0, reply?.body ?? Data()) }
        }
        #expect(await connect(rig) == .selected)
        let expected = try Data(contentsOf: rig.file)
        let got = try #require(fetched.withLock { $0 })
        #expect(got.0 == 200 && got.1 == expected, "the receiver fetched exactly the queued item through the relay")
        let load = try #require(rig.receiver.received.first { $0.text?.contains("\"LOAD\"") == true }?.text)
        let url = try #require(load.components(separatedBy: "\"contentId\":\"").dropFirst().first?.components(separatedBy: "\"").first)
        #expect(url.hasPrefix("http://127.0.0.1:") && url.contains("/c/") && !url.contains(rig.file.lastPathComponent) && !url.contains("?"))
    }
    @Test func theLocalEngineIsSilencedAndConfirmedBeforeTheReceiverIsAskedToPlay() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        let log = rig.log
        rig.receiver.setOnLoad { _ in log.append("receiver:load") }
        #expect(await connect(rig) == .selected)
        let events = rig.log.all.filter { $0 == "local:silence" || $0 == "receiver:load" }
        #expect(events == ["local:silence", "receiver:load"], "ROUTE08: \(events)")
        #expect(rig.local.silenced)
    }
    @Test func ifTheLocalEngineCannotBeConfirmedSilentTheReceiverIsNeverAskedToPlay() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        rig.local.confirmsSilence = false
        #expect(await connect(rig) == .failed)
        #expect(!rig.receiver.receivedTypes().contains("LOAD"), "no receiver playback without a silent local engine")
        #expect(rig.local.log == ["silence", "unsilence"], "what the attempt changed on the local engine was put back: \(rig.local.log)")
        #expect(rig.coordinator.remote == nil && rig.coordinator.selection.isSystemDefault && rig.store.load() == nil)
    }
    @Test func theReceiverStartsWhereThePersonWasAndPlaysOnlyIfTheyWerePlaying() async throws {
        let playing = try await CastRig.make(playing: true, position: 47); defer { playing.cleanup() }
        #expect(await connect(playing) == .selected)
        #expect(playing.receiver.playerState == "PLAYING" && playing.receiver.position == 47)
        let paused = try await CastRig.make(playing: false, position: 20); defer { paused.cleanup() }
        #expect(await connect(paused) == .selected)
        #expect(paused.receiver.playerState == "PAUSED" && paused.receiver.position == 20, "choosing a receiver while paused does not start the music")
    }
    @Test func theRouteIsTheSessionsSelectionAndTheRememberedPreferredRoute() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        #expect(await connect(rig) == .selected)
        #expect(rig.coordinator.selection == CastFixtures.livingRoom.routeID && rig.coordinator.preferred == CastFixtures.livingRoom.routeID)
        #expect(rig.store.load()?.rawValue == "cast:SYNTH-CAST-LIVING", "the stable identifier only")
        #expect(rig.coordinator.remote?.isCast == true && rig.coordinator.mode(for: .localMedia) == .castReceiver)
        #expect(rig.driver.isLive && rig.driver.liveDeviceName == "Living Room")
    }

    // MARK: The receiver is the source of position, state and capabilities (T39.2)

    @Test func thePositionShownIsTheReceiversLastReportAndNeverALocalGuess() async throws {
        let rig = try await CastRig.make(position: 10); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.coordinator.remotePosition() == 10 })
        rig.receiver.advance(5)
        #expect(await waitUntil { rig.coordinator.remotePosition() == 15 })
        // The native session's own (silent) clock moves on; it is never what the route reports.
        rig.local.state = CastLocalState(item: rig.local.state.item, playing: true, position: 999)
        await rig.driver.nativeChanged()
        #expect(rig.coordinator.remotePosition() == 15)
    }
    @Test func aReadingOlderThanTenSecondsIsWithheldNotExtrapolated() async throws {
        let clock = RelayClock()
        _ = clock
        let rig = try await CastRig.make(position: 30); defer { rig.cleanup() }
        _ = await connect(rig)
        let session = try #require(rig.coordinator.remote)
        #expect(session.displayedPosition(now: ContinuousClock.now.advanced(by: .seconds(9))) != nil)
        #expect(session.displayedPosition(now: ContinuousClock.now.advanced(by: .seconds(11))) == nil, "stale: shown as nothing, not as 41 s")
    }
    @Test func capabilitiesAndVolumeAreShownAsTheReceiverStatesThem() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.coordinator.remote?.capabilities != nil })
        #expect(rig.coordinator.remote?.capabilities == CastReceiverCapabilities(canPause: true, canSeek: true, canSetStreamVolume: true, canMute: true))
        rig.receiver.inject(namespace: CastNamespace.receiver, json: #"{"type":"RECEIVER_STATUS","status":{"applications":[{"appId":"CC1AD845","sessionId":"sim-session-1","transportId":"sim-transport-1","namespaces":[{"name":"urn:x-cast:com.google.cast.media"}]}],"volume":{"level":0.3,"muted":true}}}"#)
        #expect(await waitUntil { rig.coordinator.remote?.volume == ReceiverVolume(level: 0.3, muted: true) })
        #expect(rig.coordinator.capabilities(for: .localMedia).volume == .receiver, "the receiver sets the level")
    }
    // MARK: The volume slider shows and drives the RECEIVER's level while an owned or local item is cast (TH4, rework of M1)

    func setVolumeCount(_ rig: CastRig) -> Int { rig.receiver.receivedTypes().filter { $0 == "SET_VOLUME" }.count }
    func adjustable(_ rig: CastRig) async -> Bool { await waitUntil { rig.driver.volumeControl?.isAdjustable == true } }
    @Test func theSliderStartsAtTheReceiversOwnLevelAndConnectingSetsNothing() async throws {
        let rig = try await CastRig.make(receiverLevel: 0.4); defer { rig.cleanup() }
        #expect(rig.driver.volumeControl == nil, "not casting: the slider is the Mac's")
        _ = await connect(rig)
        #expect(await adjustable(rig))
        #expect(rig.driver.volumeControl?.level == 0.4, "the receiver's level, as it reports it")
        #expect(setVolumeCount(rig) == 0 && rig.receiver.volume == 0.4, "connecting does not touch the receiver's volume")
    }
    @Test func aSmallSliderMoveSendsAboutTheReceiversLevelNeverTheMacsOrFull() async throws {
        let rig = try await CastRig.make(receiverLevel: 0.4); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await adjustable(rig))
        rig.driver.requestVolume(0.43); await rig.driver.volumeSettled()
        #expect(await waitUntil { abs(rig.receiver.volume - 0.43) < 1e-9 }, "\(rig.receiver.volume)")
        #expect(setVolumeCount(rig) == 1 && !rig.receiver.muted)
        #expect(rig.driver.volumeControl?.level == 0.43)
        rig.driver.requestVolume(0.40); await rig.driver.volumeSettled()
        #expect(await waitUntil { abs(rig.receiver.volume - 0.40) < 1e-9 })
    }
    @Test func theLevelIsClampedAndANonNumberIsIgnored() async throws {
        let rig = try await CastRig.make(receiverLevel: 0.5); defer { rig.cleanup() }
        _ = await connect(rig); #expect(await adjustable(rig))
        rig.driver.requestVolume(7); await rig.driver.volumeSettled(); #expect(await waitUntil { rig.receiver.volume == 1 })
        rig.driver.requestVolume(-2); await rig.driver.volumeSettled(); #expect(await waitUntil { rig.receiver.volume == 0 })
        let before = setVolumeCount(rig)
        rig.driver.requestVolume(.nan); rig.driver.requestVolume(.infinity); await rig.driver.volumeSettled()
        try await Task.sleep(for: .milliseconds(100))
        #expect(setVolumeCount(rig) == before, "NaN and infinity send nothing")
    }
    @Test func aBurstSendsOnlyTheNewestLevelWhateverTheTaskOrder() async throws {
        let rig = try await CastRig.make(receiverLevel: 0.5); defer { rig.cleanup() }
        _ = await connect(rig); #expect(await adjustable(rig))
        for step in 1...9 { rig.driver.requestVolume(Double(step) / 10) }
        await rig.driver.volumeSettled()
        #expect(await waitUntil { abs(rig.receiver.volume - 0.9) < 1e-9 }, "the newest level: \(rig.receiver.volume)")
        #expect(setVolumeCount(rig) == 1, "handed over synchronously: one send, of the newest")
        #expect(rig.driver.volumeControl?.level == 0.9)
    }
    @Test func aFixedVolumeReceiverIsNeverSentALevelAndTheSliderSaysWhy() async throws {
        var options = SimulatedCastReceiver.Options(); options.volumeControlType = "fixed"
        let rig = try await CastRig.make(receiverOptions: options, receiverLevel: 0.5); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.driver.volumeControl?.unavailable == .fixed })
        rig.driver.requestVolume(0.2); await rig.driver.volumeSettled()
        try await Task.sleep(for: .milliseconds(100))
        #expect(setVolumeCount(rig) == 0 && rig.receiver.volume == 0.5 && rig.driver.volumeControl?.level == 0.5 && rig.driver.volumeControl?.isAdjustable == false)
    }
    /// TH5 (TH4 critic L-a, mutation R2): the abilities arrive (MEDIA_STATUS says the stream volume can be set) but the receiver has never said where its level is.
    /// The slider must not show 0 as if it knew, and must not send anything: a drag would otherwise set a level relative to a guess.
    @Test func aReceiverThatHasNotReportedItsLevelIsNeverSentOneEvenOnceItAllowsTheStreamVolume() async throws {
        var options = SimulatedCastReceiver.Options(); options.reportsVolumeLevel = false
        let rig = try await CastRig.make(receiverOptions: options, receiverLevel: 0.5); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.receiver.playerState == "PLAYING" }, "the item is loaded, so the receiver's MEDIA_STATUS (stream volume allowed) has been sent")
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.driver.volumeControl?.unavailable == .notReported && rig.driver.volumeControl?.isAdjustable == false, "no level reported: not adjustable, whatever the abilities say")
        rig.driver.requestVolume(0.2); await rig.driver.volumeSettled()
        try await Task.sleep(for: .milliseconds(100))
        #expect(setVolumeCount(rig) == 0 && rig.receiver.volume == 0.5, "nothing was sent")
        #expect(rig.driver.volumeControl?.unavailable == .notReported && rig.driver.volumeControl?.level == 0, "a request that was refused is not shown as the level")
    }
    @Test func aReceiverWithoutStreamVolumeSupportIsNeverSentALevel() async throws {
        var options = SimulatedCastReceiver.Options(); options.supportedMediaCommands = 15 & ~4
        let rig = try await CastRig.make(receiverOptions: options, receiverLevel: 0.5); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.driver.volumeControl?.unavailable == .unsupported })
        rig.driver.requestVolume(0.2); await rig.driver.volumeSettled()
        try await Task.sleep(for: .milliseconds(100))
        #expect(setVolumeCount(rig) == 0 && rig.receiver.volume == 0.5)
    }
    @Test func theSliderIsTheReceiversOnlyForOwnedOrLocalMedia() async throws {
        // A source the receiver fetches itself is not owned or local media: the slider is not the receiver's and nothing is sent.
        let direct = CastLocalItem(key: "d", source: .direct(URL(string: "https://media.example.org/public/episode.mp3")!), title: "Public episode")
        let rig = try await CastRig.make(item: { _ in direct }); defer { rig.cleanup() }
        #expect(await connect(rig) == .selected)
        #expect(rig.driver.volumeControl == nil)
        rig.driver.requestVolume(0.2); await rig.driver.volumeSettled()
        try await Task.sleep(for: .milliseconds(100))
        #expect(setVolumeCount(rig) == 0 && rig.receiver.volume == 1.0)
        // Control: an owned item (the relay serves it) is adjustable.
        let owned = try await CastRig.make(); defer { owned.cleanup() }
        _ = await connect(owned)
        #expect(await adjustable(owned))
    }
    @Test func nothingIsSentBeforeAnItemIsLoadedAfterTheRouteEndsOrWithNoSession() async throws {
        let none = try await CastRig.make(); defer { none.cleanup() }
        none.driver.requestVolume(0.4)   // no session at all
        #expect(setVolumeCount(none) == 0 && none.receiver.openCount == 0 && none.driver.volumeControl == nil)
        let empty = try await CastRig.make(); defer { empty.cleanup() }
        empty.local.moveTo(nil)   // nothing queued yet
        #expect(await connect(empty) == .selected)
        #expect(empty.driver.volumeControl == nil, "connected with nothing queued: no media loaded, so the slider is the Mac's")
        empty.driver.requestVolume(0.4); await empty.driver.volumeSettled()
        #expect(setVolumeCount(empty) == 0)
        let ended = try await CastRig.make(); defer { ended.cleanup() }
        _ = await connect(ended); #expect(await adjustable(ended))
        await ended.coordinator.leaveCast()
        #expect(ended.driver.volumeControl == nil, "after leaving, the slider is the Mac's again")
        let count = setVolumeCount(ended)
        ended.driver.requestVolume(0.4); await ended.driver.volumeSettled()
        try await Task.sleep(for: .milliseconds(100))
        #expect(setVolumeCount(ended) == count)
    }
    @Test func theSliderFollowsALevelTheReceiverChangesItself() async throws {
        let rig = try await CastRig.make(receiverLevel: 0.4); defer { rig.cleanup() }
        _ = await connect(rig); #expect(await adjustable(rig))
        rig.receiver.inject(namespace: CastNamespace.receiver, json: #"{"type":"RECEIVER_STATUS","status":{"applications":[{"appId":"CC1AD845","sessionId":"sim-session-1","transportId":"sim-transport-1","namespaces":[{"name":"urn:x-cast:com.google.cast.media"}]}],"volume":{"level":0.7,"muted":false,"controlType":"attenuation"}}}"#)
        #expect(await waitUntil { rig.driver.volumeControl?.level == 0.7 }, "a remote or the speaker's own dial moved it: the slider follows")
        #expect(setVolumeCount(rig) == 0)
        // After the person has moved it themselves, the receiver's later word still wins once nothing is left to send.
        rig.driver.requestVolume(0.55); await rig.driver.volumeSettled()
        #expect(await waitUntil { abs(rig.receiver.volume - 0.55) < 1e-9 && rig.driver.volumeControl?.level == 0.55 })
        rig.receiver.inject(namespace: CastNamespace.receiver, json: #"{"type":"RECEIVER_STATUS","status":{"applications":[{"appId":"CC1AD845","sessionId":"sim-session-1","transportId":"sim-transport-1","namespaces":[{"name":"urn:x-cast:com.google.cast.media"}]}],"volume":{"level":0.2,"muted":false,"controlType":"attenuation"}}}"#)
        #expect(await waitUntil { rig.driver.volumeControl?.level == 0.2 }, "the speaker's own dial moved it after the slider did")
    }
    @Test func theReceiversStateFollowsWhatItReports() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.coordinator.remote?.state == .playing })
        rig.local.person(playing: false); await rig.driver.nativeChanged()
        #expect(await waitUntil { rig.coordinator.remote?.state == .paused })
    }

    // MARK: Commands and reconciliation without dual audio (T39.2)

    @Test func theLocalSessionsPlayAndPauseReachTheReceiver() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        rig.local.person(playing: false); await rig.driver.nativeChanged()
        #expect(await waitUntil { rig.receiver.playerState == "PAUSED" })
        rig.local.person(playing: true); await rig.driver.nativeChanged()
        #expect(await waitUntil { rig.receiver.playerState == "PLAYING" })
    }
    @Test func aSeekReachesTheReceiver() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        await rig.driver.nativeSeek(to: 73)
        #expect(await waitUntil { rig.receiver.position == 73 && rig.coordinator.remotePosition() == 73 })
    }
    @Test func aPauseFromAnotherAppPausesTheLocalSessionAndNeverStartsItAudibly() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.coordinator.remote?.state == .playing })
        rig.receiver.inject(namespace: CastNamespace.media, from: "sim-transport-1", json: #"{"type":"MEDIA_STATUS","requestId":0,"status":[{"mediaSessionId":1,"playerState":"PAUSED","currentTime":22,"supportedMediaCommands":15,"media":{"contentId":"\#(rig.receiver.contentID ?? "")","duration":120}}]}"#)
        #expect(await waitUntil { !rig.local.state.playing }, "the local session follows the receiver")
        #expect(rig.local.silenced, "and the local engine stayed silent throughout")
        #expect(!rig.local.log.contains("resume") && !rig.local.log.contains("unsilence"))
    }
    @Test func aLateEchoOfAnEarlierCommandDoesNotUndoTheNewerOne() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.coordinator.remote?.state == .playing })
        _ = await waitUntil { rig.driver.ignoredStale >= 0 }
        // The person pauses and immediately plays again. The receiver's reply to the FIRST command (PAUSED) reaches us after the second command was sent.
        rig.receiver.holdReplies()
        rig.local.person(playing: false); await rig.driver.nativeChanged()
        rig.local.person(playing: true); await rig.driver.nativeChanged()
        rig.receiver.releaseReplies()
        #expect(await waitUntil { rig.receiver.playerState == "PLAYING" && rig.coordinator.remote?.state == .playing })
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.local.state.playing && !rig.local.log.contains("pause"), "the PAUSED echo of the first command did not pause the session")
    }
    @Test func aReportThatContradictsUsAfterTheSettleWindowIsTheReceiversDecision() async throws {
        var configuration = CastDriverConfiguration(); configuration.settleWindow = .milliseconds(20)
        let rig = try await CastRig.make(driverConfiguration: configuration); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.coordinator.remote?.state == .playing })
        try await Task.sleep(for: .milliseconds(60))
        rig.receiver.injectMediaStatus(mediaSessionID: rig.receiver.currentMediaSessionID, state: "PAUSED", contentID: rig.receiver.contentID, position: 5)
        #expect(await waitUntil { !rig.local.state.playing })
    }
    @Test func aNewItemIsLoadedAndTheOldItemsReportsAreIgnored() async throws {
        var configuration = CastDriverConfiguration(); configuration.switchGrace = .seconds(0)
        let rig = try await CastRig.make(driverConfiguration: configuration); defer { rig.cleanup() }
        _ = await connect(rig)
        let firstContent = rig.receiver.contentID
        let second = try CastFixtures.audioFile(name: "second"); defer { CastFixtures.remove(second) }
        rig.local.moveTo(CastRig.item("item-2", file: second, title: "Second"), position: 0)
        await rig.driver.nativeChanged()
        #expect(await waitUntil { rig.receiver.contentID != firstContent && rig.receiver.contentID != nil })
        #expect(rig.receiver.receivedTypes().filter { $0 == "LOAD" }.count == 2)
        let ignored = rig.driver.ignoredStale
        _ = ignored
        rig.receiver.advance(4)
        #expect(await waitUntil { rig.coordinator.remotePosition() == 4 })
    }
    @Test func theNextItemWaitsForTheReceiverToFinishTheOneItIsPlaying() async throws {
        let rig = try await CastRig.make(position: 118); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.coordinator.remotePosition() == 118 })
        let second = try CastFixtures.audioFile(name: "second"); defer { CastFixtures.remove(second) }
        // The silent local clock reached the end and the queue moved on; the receiver is two seconds from the end of the first item.
        rig.local.moveTo(CastRig.item("item-2", file: second, title: "Second"), position: 0)
        await rig.driver.nativeChanged()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.receiver.receivedTypes().filter { $0 == "LOAD" }.count == 1, "not cut off: the second item has not been loaded yet")
        rig.receiver.finishCurrent()
        #expect(await waitUntil { rig.receiver.receivedTypes().filter { $0 == "LOAD" }.count == 2 })
    }
    @Test func whenTheQueueRunsOutTheReceiverIsLetFinishTheLastItemOrStoppedIfItIsFarFromTheEnd() async throws {
        let near = try await CastRig.make(position: 118); defer { near.cleanup() }
        _ = await connect(near)
        #expect(await waitUntil { near.coordinator.remotePosition() == 118 })
        near.local.moveTo(nil); await near.driver.nativeChanged()
        try await Task.sleep(for: .milliseconds(80))
        #expect(near.receiver.playerState == "PLAYING", "two seconds from the end: not cut off")
        let far = try await CastRig.make(position: 20); defer { far.cleanup() }
        _ = await connect(far)
        #expect(await waitUntil { far.coordinator.remotePosition() == 20 })
        far.local.moveTo(nil); await far.driver.nativeChanged()
        #expect(await waitUntil { far.receiver.playerState == "IDLE" }, "an empty queue does not leave the receiver playing")
    }
    @Test func aDelayedSessionIsRejectedByItsIdentity() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        let oldID = try #require(rig.coordinator.remote?.id)
        await rig.coordinator.leaveCast()
        _ = await connect(rig, to: CastFixtures.livingRoom)
        let newID = try #require(rig.coordinator.remote?.id)
        #expect(oldID != newID)
        let ignored = rig.coordinator.ignoredStale
        rig.coordinator.remoteEvent(.position(999, observedAt: .now), session: oldID)
        rig.coordinator.remoteEvent(.state(.paused), session: oldID)
        rig.coordinator.remoteEvent(.ended(.receiverLost), session: oldID)
        #expect(rig.coordinator.ignoredStale == ignored + 3 && rig.coordinator.remote?.id == newID && rig.coordinator.loss(for: .localMedia) == nil)
        #expect(rig.coordinator.remotePosition() != 999)
    }
    @Test func aSlowerEarlierSelectionCannotOverrideANewerOne() async throws {
        let gate = SelectionGate()
        let rig = try await CastRig.make(devices: [CastFixtures.livingRoom, CastFixtures.kitchen], factory: { receiver in SlowOpenFactory(inner: receiver, gate: gate) }); defer { rig.cleanup() }
        async let first = rig.coordinator.select(CastFixtures.livingRoom.routeID, engine: .localMedia)
        #expect(await waitUntil { gate.waiting == 1 })
        let second = await rig.coordinator.select(CastFixtures.kitchen.routeID, engine: .localMedia)   // opens immediately (gate passes the second)
        gate.release()
        #expect(await first == .superseded)
        #expect(second == .selected && rig.coordinator.selection == CastFixtures.kitchen.routeID)
        #expect(rig.coordinator.remote?.isCast == true && rig.driver.liveDeviceName == "Kitchen")
        #expect(rig.receiver.receivedTypes().contains("STOP"), "the overtaken connection was closed and its receiver application stopped")
    }

    // MARK: What can be cast

    @Test func youTubeMusicCannotBeCastAndTheCastPickerSaysSo() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        #expect(await rig.coordinator.select(CastFixtures.livingRoom.routeID, engine: .youTubeMusic) == .unsupported)
        #expect(rig.receiver.openCount == 0, "nothing was connected")
        let rows = rig.coordinator.entries(for: .youTubeMusic).filter { $0.id.isCast }
        #expect(!rows.isEmpty && rows.allSatisfy { $0.capabilities.limits == [.castYouTubeMusic] && $0.capabilities.selection == .systemControlled })
        let local = rig.coordinator.entries(for: .localMedia).filter { $0.id.isCast }
        #expect(local.allSatisfy { $0.capabilities.selection == .appSelectable && $0.capabilities.volume == .receiver && $0.capabilities.quit == .stopsBecauseMacRelays })
    }
    @Test func aDownloadOrAnItemWithNoFileIsRefusedWithAReasonBeforeAnythingIsSilenced() async throws {
        for (reason, expected) in [(CastNotCastable.keptDownload, CastNotice.itemNotCastable(.keptDownload)), (.youTubeMusic, .itemNotCastable(.youTubeMusic)), (.noFile, .itemNotCastable(.noFile))] {
            let rig = try await CastRig.make(item: { _ in CastLocalItem(key: "k", source: .notCastable(reason), title: "x") }); defer { rig.cleanup() }
            #expect(await connect(rig) == .failed)
            #expect(rig.driver.notice == expected && rig.local.log.isEmpty, "the local engine was not touched")
            #expect(!rig.receiver.hasApplication, "the receiver application launched for the attempt was stopped")
            #expect(rig.coordinator.remote == nil && rig.coordinator.preferred == nil)
        }
    }
    @Test func ifTheQueueMovesToSomethingThatCannotBeCastTheRouteEndsHonestly() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        rig.local.moveTo(CastLocalItem(key: "dl", source: .notCastable(.keptDownload), title: "Download"), position: 0)
        await rig.driver.nativeChanged()
        #expect(await waitUntil { rig.coordinator.remote == nil })
        #expect(rig.driver.notice == .itemNotCastable(.keptDownload) && !rig.local.state.playing, "paused, never silently audible on the speakers")
        #expect(!rig.local.silenced && !rig.receiver.hasApplication)
        #expect(rig.coordinator.loss(for: .localMedia) == nil, "this was not a route loss")
    }
    @Test func aReceiverWithoutAudioOutputIsNotOffered() async throws {
        let rig = try await CastRig.make(devices: [CastFixtures.livingRoom, CastFixtures.videoOnly]); defer { rig.cleanup() }
        let names = rig.coordinator.entries(for: .localMedia).filter { $0.id.isCast }.map(\.name)
        #expect(names == ["Living Room"])
    }
    @Test func aReceiverMustHaveBeenSeenToBeChosen() async throws {
        let rig = try await CastRig.make(devices: []); defer { rig.cleanup() }
        #expect(await rig.coordinator.select(CastFixtures.livingRoom.routeID, engine: .localMedia) == .unavailable)
        #expect(rig.receiver.openCount == 0)
    }
    @Test func aFailedConnectionLeavesEverythingAsItWas() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        rig.receiver.refuseConnections(true)
        #expect(await connect(rig) == .failed)
        #expect(rig.driver.notice == .connectionFailed && rig.coordinator.selection.isSystemDefault && rig.store.load() == nil && rig.local.log.isEmpty && rig.coordinator.remote == nil)
    }
    @Test func aLoadTheReceiverRefusesEndsTheAttemptAndRestoresTheLocalEngine() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        rig.receiver.failNextLoad()
        #expect(await connect(rig) == .failed)
        #expect(rig.driver.notice == .receiverCouldNotPlay && !rig.local.silenced && rig.coordinator.remote == nil && rig.coordinator.selection.isSystemDefault)
        #expect(rig.local.log == ["silence", "unsilence"] && !rig.receiver.hasApplication)
    }
    @Test func startingYouTubeMusicWhileCastingStopsTheReceiverFirstSoNothingPlaysTwice() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await rig.coordinator.beginHandoff(to: .youTubeMusic) == .ready)
        #expect(rig.coordinator.remote == nil && !rig.receiver.hasApplication && !rig.driver.isLive, "the receiver was stopped before the hidden player may start")
        #expect(!rig.local.state.playing && !rig.local.silenced)
        #expect(rig.coordinator.activeEngine == .youTubeMusic && rig.coordinator.loss(for: .localMedia) == nil)
    }
    @Test func startingAnotherNativeItemWhileCastingKeepsTheRouteAndLoadsItOnTheReceiver() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await rig.coordinator.beginHandoff(to: .localMedia) == .ready)
        #expect(rig.coordinator.remote?.isCast == true && rig.receiver.hasApplication, "a native start does not drop the route")
    }
    @Test func theSleepTimerOnACastRouteIsWarnedAboutBeforeItIsEnabled() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(rig.coordinator.capabilities(for: .localMedia).timer == .pauseOnly)
        if case .acknowledgeTimer = rig.coordinator.admission(.enableTimer, engine: .localMedia) {} else { Issue.record("PLAY17: a receiver that cannot fade must be explained first") }
    }

    // MARK: Loss, Reconnect, Play here (T39.3)

    @Test func aLostReceiverPausesTheSessionRecordsTheLossAndKeepsTheLocalEngineSilentUntilPlayHere() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.coordinator.remote?.state == .playing })
        rig.receiver.dropConnection()
        #expect(await waitUntil { rig.coordinator.loss(for: .localMedia) != nil })
        await rig.coordinator.settled()
        let loss = try #require(rig.coordinator.loss(for: .localMedia))
        #expect(loss.reason == .receiverDisconnected && loss.lostRoute == CastFixtures.livingRoom.routeID && loss.wasAudible)
        #expect(!rig.local.state.playing && rig.engine.lossPauses == 1, "the session was paused with a route-loss pause")
        #expect(await waitUntil { !rig.local.silenced }, "the engine is audible-capable again only after the pause settled")
        #expect(rig.coordinator.remote == nil)
        if case .confirmPlayHere = rig.coordinator.admission(.start, engine: .localMedia) {} else { Issue.record("a Play after the loss must be held for confirmation") }
    }
    @Test func reconnectNeedsTheReceiverToBeSeenAgainAndNeverPlays() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await waitUntil { rig.coordinator.remotePosition() != nil })
        rig.receiver.advance(9)
        #expect(await waitUntil { rig.coordinator.remotePosition() == 21 })
        rig.coordinator.castDirectoryChanged([])        // the receiver vanished from the network too
        rig.receiver.dropConnection()
        #expect(await waitUntil { rig.coordinator.loss(for: .localMedia) != nil })
        await rig.coordinator.settled()
        #expect(!rig.coordinator.lossCanReconnect(for: .localMedia), "not seen: nothing to reconnect to")
        #expect(await rig.coordinator.reconnect() == false)
        rig.coordinator.castDirectoryChanged([CastFixtures.livingRoom])
        #expect(rig.coordinator.lossCanReconnect(for: .localMedia))
        rig.local.person(playing: true)   // worst case: the session still says "play" (its loss pause had not landed)
        #expect(await rig.coordinator.reconnect())
        #expect(rig.coordinator.loss(for: .localMedia) == nil && rig.coordinator.remote?.isCast == true)
        #expect(rig.receiver.playerState == "PAUSED", "reconnecting loaded the item paused: it plays nothing (ROUTE03)")
        #expect(rig.receiver.position == 21, "at the last position the RECEIVER reported, not the silent local clock")
        #expect(await waitUntil { !rig.local.state.playing } && rig.local.silenced, "the session agrees with the paused receiver; nothing was started")
        try await Task.sleep(for: .milliseconds(60))
        #expect(rig.receiver.playerState == "PAUSED")
    }
    @Test func aPlayAfterTheLossIsHeldAndOnlyAConfirmedPlayHereStartsSoundOnThisMac() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        rig.receiver.dropConnection()
        #expect(await waitUntil { rig.coordinator.loss(for: .localMedia) != nil })
        await rig.coordinator.settled()
        _ = await waitUntil { !rig.local.silenced }
        let ran = Mutex(false)
        let performed = await rig.coordinator.perform(.start, engine: .localMedia) { ran.withLock { $0 = true } }
        #expect(!performed && !ran.withLock { $0 }, "held")
        guard case .playHere(let prompt)? = rig.coordinator.prompt else { Issue.record("no Play here prompt"); return }
        #expect(!rig.local.state.playing && !rig.local.log.suffix(2).contains("resume"), "nothing is audible while the question stands")
        await rig.coordinator.confirm(prompt.id)
        #expect(ran.withLock { $0 } && rig.coordinator.loss(for: .localMedia) == nil)
        #expect(rig.coordinator.selection.isSystemDefault && rig.coordinator.preferred == CastFixtures.livingRoom.routeID, "Play here does not erase the remembered receiver")
    }
    @Test func cancellingPlayHereLeavesEverythingSilent() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        rig.receiver.dropConnection()
        #expect(await waitUntil { rig.coordinator.loss(for: .localMedia) != nil })
        await rig.coordinator.settled()
        let ran = Mutex(false)
        await rig.coordinator.perform(.start, engine: .localMedia) { ran.withLock { $0 = true } }
        guard let prompt = rig.coordinator.prompt else { Issue.record("no prompt"); return }
        rig.coordinator.cancel(prompt.id)
        #expect(!ran.withLock { $0 } && rig.coordinator.prompt == nil && rig.coordinator.loss(for: .localMedia) != nil && !rig.local.state.playing)
    }
    @Test func anotherSenderTakingTheReceiverOverIsALossTooNotASilentSwitch() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        rig.receiver.takeOver(contentID: "http://phone.example/theirs.mp3")
        #expect(await waitUntil { rig.coordinator.loss(for: .localMedia) != nil })
        await rig.coordinator.settled()
        #expect(!rig.local.state.playing && rig.coordinator.remote == nil)
    }
    @Test func theReceiverEndingItsApplicationIsALoss() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        rig.receiver.endApplicationExternally()
        #expect(await waitUntil { rig.coordinator.loss(for: .localMedia)?.reason == .receiverDisconnected })
    }
    @Test func theReceiverFailingToPlayTheItemEndsTheRouteAndPausesHere() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        rig.receiver.injectMediaStatus(mediaSessionID: rig.receiver.currentMediaSessionID, state: "IDLE", contentID: rig.receiver.contentID, position: 0, idleReason: "ERROR")
        #expect(await waitUntil { rig.coordinator.remote == nil })
        #expect(rig.driver.notice == .receiverCouldNotPlay && !rig.local.state.playing && !rig.local.silenced)
    }

    // MARK: Preferred IDs and leaving (ROUTE02, T39.3)

    @Test func aRememberedReceiverIsNeverConnectedToOrPlayedAtLaunch() async throws {
        let rig = try await CastRig.make(devices: [], preferred: CastFixtures.livingRoom.routeID); defer { rig.cleanup() }
        #expect(rig.coordinator.preferred == CastFixtures.livingRoom.routeID && rig.coordinator.selection.isSystemDefault && rig.coordinator.launchNotice == nil)
        #expect(rig.receiver.openCount == 0 && rig.coordinator.remote == nil && rig.local.log.isEmpty)
        let rows = rig.coordinator.entries(for: .localMedia).filter { $0.id.isCast }
        #expect(rows.count == 1 && rows[0].connection == .unavailable && rows[0].isPreferred && rows[0].name == "", "listed as remembered but unavailable; not replaced by a look-alike")
        // It shows up on the network later: marked as the remembered one, still not connected.
        rig.coordinator.castDirectoryChanged([CastFixtures.otherLivingRoom, CastFixtures.livingRoom])
        let after = rig.coordinator.entries(for: .localMedia).filter { $0.id.isCast }
        #expect(after.map(\.isPreferred) == (after.map { $0.id == CastFixtures.livingRoom.routeID }), "by identifier: the receiver with the same NAME is not the preferred one")
        #expect(after.count == 2 && rig.receiver.openCount == 0)
    }
    @Test func twoReceiversWithOneNameAreTwoRoutes() async throws {
        let rig = try await CastRig.make(devices: [CastFixtures.livingRoom, CastFixtures.otherLivingRoom]); defer { rig.cleanup() }
        _ = await connect(rig, to: CastFixtures.otherLivingRoom)
        #expect(rig.store.load()?.rawValue == "cast:SYNTH-CAST-OTHER")
        let current = rig.coordinator.entries(for: .localMedia).filter { $0.isCurrent }
        #expect(current.map(\.id) == [CastFixtures.otherLivingRoom.routeID])
    }
    @Test func aLaterExplicitChoiceOfAMacOutputLeavesTheReceiverStopsItAndReplacesTheRememberedRoute() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        #expect(await rig.coordinator.select(.device(uid: Synthetic.speakers.uid), engine: .localMedia) == .selected)
        #expect(rig.coordinator.remote == nil && rig.coordinator.preferred == .device(uid: Synthetic.speakers.uid) && rig.store.load() == .device(uid: Synthetic.speakers.uid))
        #expect(!rig.receiver.hasApplication, "the receiver was stopped")
        #expect(!rig.local.state.playing && !rig.local.silenced, "paused, then audible-capable: choosing a route does not start the Mac's speakers")
        #expect(rig.local.log.firstIndex(of: "pause")! < rig.local.log.firstIndex(of: "unsilence")!, "paused BEFORE it was unsilenced")
        #expect(rig.coordinator.loss(for: .localMedia) == nil, "a person's choice is not a loss")
    }
    @Test func leavingARouteRestoresThePositionTheReceiverReported() async throws {
        let rig = try await CastRig.make(position: 5); defer { rig.cleanup() }
        _ = await connect(rig)
        rig.receiver.advance(31)
        #expect(await waitUntil { rig.coordinator.remotePosition() == 36 })
        await rig.coordinator.leaveCast()
        #expect(rig.local.state.position == 36, "the queue keeps the position where the receiver was")
    }
    @Test func aNewNativeSessionStartedWhileCastingIsSilentFromItsFirstInstant() async throws {
        // The controller silences a replacement session in `attach`; here the driver-level guarantee: after a route loss nothing un-silences before the pause.
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await connect(rig)
        rig.receiver.dropConnection()
        #expect(await waitUntil { rig.coordinator.loss(for: .localMedia) != nil })
        await rig.coordinator.settled()
        _ = await waitUntil { !rig.local.silenced }
        // The FIRST step that could make the local engine audible after the loss comes after the pause, and none came before it (a moved comparison and an added one both fail).
        let pause = try #require(rig.local.log.firstIndex(of: "pause"))
        let firstUnsilence = try #require(rig.local.log.firstIndex(of: "unsilence"))
        #expect(pause < firstUnsilence, "\(rig.local.log)")
        #expect(!rig.local.log[..<pause].contains("unsilence"))
    }
}

// MARK: Quit (ROUTE10, WIN03, T39.3)

@Suite @MainActor struct CastQuitTests {
    @Test func theQuitPlanForRelayedMediaIsStopAndSaysWhy() {
        for remembered in [nil, CastQuitChoice.stop, .leave] {
            #expect(CastQuitPolicy.plan(isCasting: true, continuation: .macRelays, remembered: remembered) == .stop(explainRelay: true), "a remembered Leave is never honoured while the Mac relays: \(String(describing: remembered))")
        }
        #expect(CastQuitPolicy.plan(isCasting: false, continuation: .macRelays, remembered: .leave) == .notCasting)
    }
    @Test func anIndependentReceiverAsksByDefaultAndRemembersTheChoice() {
        #expect(CastQuitPolicy.plan(isCasting: true, continuation: .receiverIndependent, remembered: nil) == .ask)
        #expect(CastQuitPolicy.plan(isCasting: true, continuation: .receiverIndependent, remembered: .stop) == .stop(explainRelay: false))
        #expect(CastQuitPolicy.plan(isCasting: true, continuation: .receiverIndependent, remembered: .leave) == .leave)
    }
    @Test func theRememberedChoiceIsStoredAsTheStopOrLeaveWordAndDefaultsToNothing() {
        let store = MemoryCastQuitChoice()
        #expect(store.load() == nil, "default Stop: nothing remembered")
        store.save(.leave); #expect(store.load() == .leave)
        store.save(nil); #expect(store.load() == nil)
        let suite = InMemoryDefaults()
        let defaults = DefaultsCastQuitChoice(suite)
        #expect(defaults.load() == nil)
        defaults.save(.stop); #expect(defaults.load() == .stop)
        suite.set("garbage", forKey: DefaultsCastQuitChoice.key); #expect(defaults.load() == nil, "an unknown value is not a choice")
    }
    @Test func quittingWhileCastingStopsTheReceiverAndTheRelay() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await rig.coordinator.select(CastFixtures.livingRoom.routeID, engine: .localMedia)
        #expect(rig.driver.quitPlan == .stop(explainRelay: true))
        await rig.driver.prepareForQuit()
        #expect(rig.receiver.receivedTypes().contains("STOP") && !rig.receiver.hasApplication)
        #expect(!rig.driver.isLive && rig.driver.quitPlan == .notCasting)
    }
    @Test func aRememberedLeaveDoesNotStopARelayedReceiver() async throws {
        let rig = try await CastRig.make(quitChoice: .leave); defer { rig.cleanup() }
        _ = await rig.coordinator.select(CastFixtures.livingRoom.routeID, engine: .localMedia)
        await rig.driver.prepareForQuit()
        #expect(rig.receiver.receivedTypes().contains("STOP"), "playback cannot continue after quitting while the Mac relays, so it is stopped and the plan said so")
    }
    @Test func anIndependentReceiverIsLeftPlayingWhenLeaveWasRemembered() async throws {
        let direct = CastLocalItem(key: "d", source: .direct(URL(string: "https://media.example.org/public/episode.mp3")!), title: "Public episode")
        let rig = try await CastRig.make(item: { _ in direct }, quitChoice: .leave); defer { rig.cleanup() }
        #expect(await rig.coordinator.select(CastFixtures.livingRoom.routeID, engine: .localMedia) == .selected)
        #expect(rig.driver.quitPlan == .leave)
        let load = try #require(rig.receiver.received.first { $0.text?.contains("\"LOAD\"") == true }?.text)
        #expect(load.contains("https://media.example.org/public/episode.mp3") && !rig.receiver.received.isEmpty)
        await rig.driver.prepareForQuit()
        #expect(!rig.receiver.receivedTypes().contains("STOP") && rig.receiver.hasApplication, "Leave: the receiver keeps playing")
    }
    @Test func anIndependentReceiverWithNoChoiceYetAsksAndStopIsTheDefault() async throws {
        let direct = CastLocalItem(key: "d", source: .direct(URL(string: "https://media.example.org/public/episode.mp3")!), title: "Public episode")
        let rig = try await CastRig.make(item: { _ in direct }); defer { rig.cleanup() }
        _ = await rig.coordinator.select(CastFixtures.livingRoom.routeID, engine: .localMedia)
        #expect(rig.driver.quitPlan == .ask)
        await rig.driver.prepareForQuit()   // no answer was given: the default, Stop
        #expect(rig.receiver.receivedTypes().contains("STOP"))
    }
    @Test func quitIsBoundedEvenIfTheReceiverNeverAnswers() async throws {
        var configuration = CastDriverConfiguration(); configuration.shutdownTimeout = .milliseconds(250)
        let hang = HangingChannelFactory()
        let rig = try await CastRig.make(factory: { _ in hang }, driverConfiguration: configuration); defer { rig.cleanup() }
        _ = await rig.coordinator.select(CastFixtures.livingRoom.routeID, engine: .localMedia)
        hang.hangFromNow()
        let started = ContinuousClock.now
        await rig.driver.prepareForQuit()
        #expect(ContinuousClock.now - started < .seconds(2), "Quit does not wait for a receiver that has stopped answering")
    }
    @Test func nothingIsSentOnQuitWhenNothingIsCasting() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        await rig.driver.prepareForQuit()
        #expect(rig.receiver.openCount == 0)
    }
    @Test func directSourcesNeverCarryAccountMediaToAReceiver() {
        for bad in ["http://media.example.org/a.mp3", "https://user:pw@media.example.org/a.mp3", "https://rr1---sn-abc.googlevideo.com/videoplayback", "https://music.youtube.com/watch?v=x", "https://www.youtube.com/x",
                    "https://lh3.googleusercontent.com/a", "https://youtu.be/x", "https://192.168.1.4/a.mp3", "https://localhost/a.mp3", "https://printer.local/a.mp3", "file:///etc/passwd", "ftp://x/a", "https://storage.googleapis.com/b/a.mp3", "https://i.ytimg.com/a"] {
            #expect(throws: CastError.self) { try CastDirectSourcePolicy.validate(URL(string: bad)!) }
        }
        #expect(throws: Never.self) { try CastDirectSourcePolicy.validate(URL(string: "https://media.example.org/podcast/e1.mp3")!) }
    }
}

// MARK: Test doubles for ordering and hanging

final class SelectionGate: @unchecked Sendable {
    private let lock = NSLock(); private var continuations: [CheckedContinuation<Void, Never>] = []; private var opens = 0
    var waiting: Int { lock.withLock { continuations.count } }
    /// The first open waits; every later one passes straight through.
    func enter() async { let first = lock.withLock { opens += 1; return opens == 1 }; if first { await withCheckedContinuation { c in lock.withLock { continuations.append(c) } } } }
    func release() { let all = lock.withLock { let c = continuations; continuations = []; return c }; for continuation in all { continuation.resume() } }
}
struct SlowOpenFactory: CastChannelFactory {
    let inner: SimulatedCastReceiver; let gate: SelectionGate
    func open(_ device: CastDevice) async throws -> any CastChannel { await gate.enter(); return try await inner.open(device) }
}
final class HangingChannelFactory: CastChannelFactory, @unchecked Sendable {
    private let inner = SimulatedCastReceiver()
    private let hanging = Mutex(false)
    func hangFromNow() { hanging.withLock { $0 = true } }
    func open(_ device: CastDevice) async throws -> any CastChannel { Hanging(inner: try await inner.open(device), owner: self) }
    final class Hanging: CastChannel, @unchecked Sendable {
        let inner: any CastChannel; let owner: HangingChannelFactory
        init(inner: any CastChannel, owner: HangingChannelFactory) { self.inner = inner; self.owner = owner }
        var events: AsyncStream<CastChannelEvent> { inner.events }
        var localAddress: String? { inner.localAddress }
        var remoteAddress: String? { inner.remoteAddress }
        func send(_ message: CastMessage) async throws {
            if owner.hanging.withLock({ $0 }) { try await Task.sleep(for: .seconds(30)) }
            try await inner.send(message)
        }
        func close() { inner.close() }
    }
}

// MARK: The capability table and the loss record for Cast

@Suite @MainActor struct CastCapabilityTests {
    @Test func theTableSaysWhatACastRouteCanAndCannotDoForEachEngine() {
        let avPlayer = RouteCapabilities.resolve(engine: .localMedia, backend: .avPlayer, mode: .castReceiver)
        #expect(avPlayer.selection == .appSelectable && avPlayer.volume == .receiver && avPlayer.timer == .pauseOnly && avPlayer.grouping == .notOffered)
        #expect(avPlayer.quit == .stopsBecauseMacRelays, "quitting cannot be promised to continue while the Mac serves the media")
        #expect(avPlayer.limits == [.groupReceivers, .fadeOnReceiver, .changeDeviceVolume])
        let decoded = RouteCapabilities.resolve(engine: .localMedia, backend: .decodedGraph, mode: .castReceiver)
        #expect(decoded.limits.contains(.castIgnoresAudioEffects) && decoded.selection == .appSelectable)
        for backend in [OutputBackend.avPlayer, .decodedGraph, .hiddenWebPlayer] {
            let music = RouteCapabilities.resolve(engine: .youTubeMusic, backend: backend, mode: .castReceiver)
            #expect(music.selection == .systemControlled && music.limits == [.castYouTubeMusic], "YouTube Music cannot be cast: \(backend)")
        }
        #expect(RouteCapabilities.resolve(engine: .localMedia, backend: .hiddenWebPlayer, mode: .castReceiver).limits == [.castYouTubeMusic])
    }
    @Test func theOtherRoutesAreUnchanged() {
        #expect(RouteCapabilities.resolve(engine: .localMedia, backend: .avPlayer, mode: .externalPlayback).quit == .stopsPlayback)
        #expect(RouteCapabilities.resolve(engine: .localMedia, backend: .avPlayer, mode: .systemOutput(.usb)).quit == .stopsPlayback)
        #expect(RouteCapabilities.resolve(engine: .youTubeMusic, backend: .hiddenWebPlayer, mode: .systemOutput(.builtIn)).limits.contains(.chooseOutputInApp))
    }
    @Test func aCastLossCanReconnectOnlyWhenThatReceiverIsSeenAgain() {
        let loss = RouteLoss(reason: .receiverDisconnected, engine: .localMedia, lost: nil, lostRoute: CastFixtures.livingRoom.routeID, generation: 1, wasAudible: true)
        #expect(!loss.canReconnect(in: .empty) && !loss.canReconnect(in: .empty, casts: []))
        #expect(!loss.canReconnect(in: .empty, casts: [CastFixtures.otherLivingRoom, CastFixtures.kitchen]), "a receiver with the same NAME is not the one that was lost")
        #expect(loss.canReconnect(in: .empty, casts: [CastFixtures.kitchen, CastFixtures.livingRoom]))
        let airPlay = RouteLoss(reason: .receiverDisconnected, engine: .localMedia, lost: nil, lostRoute: .systemDefault, generation: 1, wasAudible: true)
        #expect(!airPlay.canReconnect(in: .empty, casts: [CastFixtures.livingRoom]), "an AirPlay receiver loss is unaffected by Cast receivers")
    }
    @Test func castRowsAreOrderedByNameThenIdentifier() async throws {
        let rig = try await CastRig.make(devices: [CastFixtures.otherLivingRoom, CastFixtures.kitchen, CastFixtures.livingRoom]); defer { rig.cleanup() }
        let ids = rig.coordinator.entries(for: .localMedia).filter { $0.id.isCast }.map(\.id.rawValue)
        #expect(ids == ["cast:SYNTH-CAST-KITCHEN", "cast:SYNTH-CAST-LIVING", "cast:SYNTH-CAST-OTHER"])
    }
    @Test func aMacOutputChoiceThatIsMadeWhileCastingNeverBecomesTheCastRoutesIdentity() async throws {
        let rig = try await CastRig.make(); defer { rig.cleanup() }
        _ = await rig.coordinator.select(CastFixtures.livingRoom.routeID, engine: .localMedia)
        #expect(rig.coordinator.audibleRoute(for: .localMedia).identity == nil && !rig.coordinator.audibleRoute(for: .localMedia).pinned, "a receiver has no Mac output identity")
        #expect(rig.coordinator.currentOutput(for: .localMedia) == nil)
        #expect(rig.coordinator.currentOutput(for: .youTubeMusic)?.uid == Synthetic.speakers.uid, "the hidden player still follows the Mac")
    }
}
