import Foundation
import Testing
@testable import OutputRoutes
import TestSupport

/// The coordinator with a scripted directory, an in-memory preferred-route store and a recording engine per kind.
@MainActor struct Rig {
    let coordinator: OutputRouteCoordinator
    let directory: ScriptedDirectory
    let store: MemoryPreferredRoute
    let music: RecordingEngine
    let local: RecordingEngine
    static func make(devices: [OutputDevice] = [Synthetic.speakers, Synthetic.buds], defaultUID: String? = Synthetic.buds.uid, preferred: OutputRouteID? = nil,
                     localBackend: OutputBackend = .avPlayer, now: (@MainActor () -> ContinuousClock.Instant)? = nil) async -> Rig {
        let directory = ScriptedDirectory(devices, defaultUID: defaultUID)
        let store = MemoryPreferredRoute(preferred)
        let coordinator = OutputRouteCoordinator(directory: directory, store: store, now: now)
        coordinator.start()
        let music = RecordingEngine(.youTubeMusic), local = RecordingEngine(.localMedia, backend: localBackend)
        await coordinator.register(music); await coordinator.register(local)
        return Rig(coordinator: coordinator, directory: directory, store: store, music: music, local: local)
    }
    func engine(_ kind: OutputEngineKind) -> RecordingEngine { kind == .youTubeMusic ? music : local }
}

/// T22.1: a disconnect wins over every later resume, whatever the engine was doing, and reconnecting resumes nothing.
@Suite @MainActor struct RouteLossTests {
    @Test(arguments: [OutputEngineKind.youTubeMusic, .localMedia])
    func aDisconnectWhileAnEngineIsPlayingPreparingOrSeekingPausesItWithARouteLossRecord(kind: OutputEngineKind) async {
        // "Playing", "preparing" and "seeking" are all `isAudibleOrWanted` for an engine; each engine's own adapter maps its states (PlaybackTests).
        for situation in ["playing", "preparing", "seeking"] {
            let rig = await Rig.make()
            rig.engine(kind).audible = true
            rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
            let loss = rig.coordinator.loss(for: kind)
            #expect(loss?.reason == .deviceDisconnected, "\(situation)")
            #expect(loss?.engine == kind && loss?.wasAudible == true, "\(situation)")
            await rig.coordinator.settled()
            #expect(rig.engine(kind).log == ["pauseForRouteLoss"], "\(situation): paused once, as a route-loss pause")
        }
    }
    @Test func unpluggingHeadphonesFromTheBuiltInJackIsALossEvenThoughTheDeviceStays() async {
        let rig = await Rig.make(devices: [Synthetic.jackHeadphones], defaultUID: Synthetic.speakers.uid)
        rig.local.audible = true
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        #expect(rig.coordinator.loss?.reason == .headphonesUnplugged)
        await rig.coordinator.settled()
        #expect(rig.local.log == ["pauseForRouteLoss"])
    }
    @Test func theLossIsRecordedBeforeAnythingAwaitsSoNoResumePathCanSlipThrough() async {
        let rig = await Rig.make()
        rig.local.audible = true; rig.music.audible = true
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        // No await since the announcement: the record and the refusal already stand, and the pause was issued INSIDE the announcement's turn.
        #expect(rig.local.log == ["pauseForRouteLoss"] && rig.music.log == ["pauseForRouteLoss"], "both engines were told to pause before the announcement returned")
        #expect(rig.coordinator.loss != nil)
        if case .confirmPlayHere = rig.coordinator.admission(.start, engine: .localMedia) {} else { Issue.record("a Play after a loss must be held for confirmation") }
        if case .confirmPlayHere = rig.coordinator.admission(.start, engine: .youTubeMusic) {} else { Issue.record("so must the hidden player's") }
    }
    @Test func theLossWinsOverEveryLaterResumeRequest() async {
        let rig = await Rig.make()
        rig.music.audible = true
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        await rig.coordinator.settled()
        var ran = 0
        for _ in 0..<3 { _ = await rig.coordinator.perform(.start, engine: .youTubeMusic) { ran += 1 } }
        #expect(ran == 0, "a wake, a media key or a queued Play cannot start sound after a loss")
        #expect(rig.music.log == ["pauseForRouteLoss"] && rig.local.log.isEmpty)
        // The local engine's route was the same lost device: it holds the loss too (quietly), so it cannot start on the speakers either.
        var localRan = 0
        _ = await rig.coordinator.perform(.start, engine: .localMedia) { localRan += 1 }
        #expect(localRan == 0 && rig.coordinator.loss(for: .localMedia)?.wasAudible == false)
    }
    @Test func reconnectingTheOutputNeverResumesAnything() async {
        let rig = await Rig.make()
        rig.local.audible = true
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        await rig.coordinator.settled()
        rig.directory.change([Synthetic.speakers, Synthetic.buds], defaultUID: Synthetic.buds.uid)
        #expect(rig.coordinator.loss != nil && rig.coordinator.lossCanReconnect(for: .localMedia), "the loss stands; Reconnect is offered")
        #expect(!rig.local.audible && rig.local.log == ["pauseForRouteLoss"], "nothing started by itself")
        #expect(await rig.coordinator.reconnect())
        #expect(rig.coordinator.loss == nil && !rig.local.audible && !rig.local.log.contains("start"), "Reconnect re-points the engine and resumes nothing")
        if case .allowed = rig.coordinator.admission(.start, engine: .localMedia) {} else { Issue.record("after Reconnect a person's Play is allowed") }
    }
    @Test func theSystemMovingToAnotherLiveOutputIsNotALoss() async {
        let rig = await Rig.make()
        rig.local.audible = true
        // A person picks the speakers in Control Center; the earbuds are still connected.
        rig.directory.change([Synthetic.speakers, Synthetic.buds], defaultUID: Synthetic.speakers.uid)
        #expect(rig.coordinator.loss == nil && rig.local.log.isEmpty, "sound continues where the person put it")
        #expect(rig.coordinator.currentOutput(for: .localMedia)?.uid == Synthetic.speakers.uid)
    }
    @Test func plugInHeadphonesIsNotALoss() async {
        let rig = await Rig.make(devices: [Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        rig.local.audible = true
        rig.directory.change([Synthetic.jackHeadphones], defaultUID: Synthetic.speakers.uid)
        #expect(rig.coordinator.loss == nil && rig.local.log.isEmpty)
    }
    @Test func aLateOrDuplicateAnnouncementChangesNothing() async {
        let rig = await Rig.make()
        rig.local.audible = true
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        await rig.coordinator.settled()
        let first = rig.coordinator.loss
        for _ in 0..<3 { rig.directory.announceAgain() }
        await rig.coordinator.settled()
        #expect(rig.coordinator.loss == first && rig.local.log == ["pauseForRouteLoss"], "no second pause, no second record")
    }
    @Test func aDeviceThatLeavesWhileNothingHasSoundedIsNoLossButOneThatDidIsOneEvenWhenPaused() async {
        let quiet = await Rig.make()
        quiet.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        #expect(quiet.coordinator.loss == nil, "nothing ever played on it")
        let used = await Rig.make()
        _ = await used.coordinator.perform(.start, engine: .localMedia) {}
        used.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        #expect(used.coordinator.loss?.wasAudible == false, "paused by a person, but sound would now come out of the speakers")
        var ran = false
        _ = await used.coordinator.perform(.start, engine: .localMedia) { ran = true }
        #expect(!ran && used.coordinator.prompt != nil)
    }
    @Test func aPinnedDeviceThatVanishesIsALossToo() async {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.dac], defaultUID: Synthetic.speakers.uid)
        #expect(await rig.coordinator.select(.device(uid: Synthetic.dac.uid), engine: .localMedia) == .selected)
        rig.local.audible = true
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        #expect(rig.coordinator.loss?.lostRoute == .device(uid: Synthetic.dac.uid))
        await rig.coordinator.settled()
        #expect(rig.local.log.last == "pauseForRouteLoss")
    }
    @Test func selectingARouteAfterALossClearsItButOnlyThatChoiceDoes() async {
        let rig = await Rig.make()
        rig.local.audible = true
        rig.directory.change([Synthetic.speakers, Synthetic.dac], defaultUID: Synthetic.speakers.uid)
        await rig.coordinator.settled()
        #expect(rig.coordinator.loss != nil)
        #expect(await rig.coordinator.select(.device(uid: Synthetic.dac.uid), engine: .localMedia) == .selected)
        #expect(rig.coordinator.loss(for: .localMedia) == nil, "a later, explicit choice outranks the remembered route")
    }
}

/// T22.2: the persisted route is an identifier, a missing one never plays through another, and equal names are not equal devices.
@Suite @MainActor struct PreferredRouteTests {
    @Test func aMissingPreferredRouteAtLaunchStaysOnTheSystemOutputAndStartsNothing() async {
        let rig = await Rig.make(devices: [Synthetic.speakers], defaultUID: Synthetic.speakers.uid, preferred: .device(uid: Synthetic.dac.uid))
        #expect(rig.coordinator.selection == .systemDefault && rig.coordinator.launchNotice == .preferredUnavailable)
        #expect(rig.local.applied.isEmpty && rig.music.applied.isEmpty, "no engine was pointed anywhere")
        #expect(rig.local.log.isEmpty && rig.music.log.isEmpty, "and nothing was started")
        #expect(rig.store.load() == .device(uid: Synthetic.dac.uid), "the choice is kept for when the device returns; it is not erased")
        #expect(rig.coordinator.loss == nil)
    }
    @Test func theSameDisplayNameIsNotTheSameDevice() async {
        // The remembered pair of earbuds is gone; a different pair with the identical name is connected.
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.otherBuds], defaultUID: Synthetic.speakers.uid, preferred: .device(uid: Synthetic.buds.uid))
        #expect(Synthetic.buds.name == Synthetic.otherBuds.name)
        #expect(rig.coordinator.selection == .systemDefault && rig.coordinator.launchNotice == .preferredUnavailable)
        #expect(rig.local.applied.isEmpty, "the look-alike was never substituted")
        let entries = rig.coordinator.entries(for: .localMedia)
        #expect(entries.first { $0.id == .device(uid: Synthetic.otherBuds.uid) }?.isCurrent == false)
        #expect(await rig.coordinator.select(.device(uid: Synthetic.buds.uid), engine: .localMedia) == .unavailable, "choosing the missing one is refused, not redirected")
        #expect(rig.coordinator.selection == .systemDefault)
    }
    @Test func thePersistedRouteIsAnIdentifierNeverAName() async {
        let rig = await Rig.make()
        #expect(await rig.coordinator.select(.device(uid: Synthetic.buds.uid), engine: .localMedia) == .selected)
        let saved = rig.store.load()
        #expect(saved?.rawValue == "coreaudio:SYNTH-BT-BUDS" && !(saved?.rawValue.contains("Synthetic") ?? true), "\(String(describing: saved))")
        #expect(OutputRouteID(persisted: "Synthetic Buds") == nil, "a display name is not an identifier")
        #expect(OutputRouteID(persisted: "coreaudio:") == nil && OutputRouteID(persisted: "") == nil)
        #expect(OutputRouteID(persisted: "system-default") == .systemDefault)
        let data = try? JSONEncoder().encode(saved), back = data.flatMap { try? JSONDecoder().decode(OutputRouteID.self, from: $0) }
        #expect(back == saved)
        #expect((try? JSONDecoder().decode(OutputRouteID.self, from: Data("\"Synthetic Buds\"".utf8))) == nil)
    }
    @Test func aPresentPreferredRouteIsRestoredAndPointsOnlyTheLocalEngine() async {
        let rig = await Rig.make(preferred: .device(uid: Synthetic.speakers.uid))
        #expect(rig.coordinator.selection == .device(uid: Synthetic.speakers.uid) && rig.coordinator.launchNotice == nil)
        #expect(rig.local.applied == [Synthetic.speakers.uid], "the local engine is pointed at the remembered device")
        #expect(rig.music.applied.isEmpty, "the hidden player is never pointed anywhere")
        #expect(rig.local.log == ["apply:SYNTH-BUILT-IN"], "applying the route started nothing")
    }
    @Test func theSystemOutputIsTheDefaultUntilAPersonChooses() async {
        let rig = await Rig.make()
        #expect(rig.coordinator.selection == .systemDefault && rig.coordinator.preferred == nil && rig.store.load() == nil)
        #expect(rig.coordinator.entries(for: .localMedia).first?.isCurrent == true)
    }
    @Test func aLaterSelectionOverridesTheRememberedRoute() async {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds, Synthetic.dac], defaultUID: Synthetic.speakers.uid, preferred: .device(uid: Synthetic.buds.uid))
        #expect(await rig.coordinator.select(.device(uid: Synthetic.dac.uid), engine: .localMedia) == .selected)
        #expect(rig.store.load() == .device(uid: Synthetic.dac.uid) && rig.coordinator.selection == .device(uid: Synthetic.dac.uid))
        #expect(await rig.coordinator.select(.systemDefault, engine: .localMedia) == .selected)
        #expect(rig.store.load() == .systemDefault, "choosing the system output is a choice too")
    }
    @Test func aDamagedStoredValueFallsBackToTheSystemOutput() {
        let defaults = InMemoryDefaults()
        defaults.set("not a route", forKey: DefaultsPreferredRoute.key)
        #expect(DefaultsPreferredRoute(defaults).load() == nil)
        DefaultsPreferredRoute(defaults).save(.device(uid: "SYNTH-X"))
        #expect(DefaultsPreferredRoute(defaults).load() == .device(uid: "SYNTH-X"))
        DefaultsPreferredRoute(defaults).save(nil)
        #expect(DefaultsPreferredRoute(defaults).load() == nil)
    }
}

/// T22.3: callbacks from an old route, session or choice change nothing; the old engine is silent before the new one starts; the receiver's position is used.
@Suite @MainActor struct RouteHandoffTests {
    @Test func aLateCompletionOfAnOlderChoiceIsIgnored() async {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds, Synthetic.dac], defaultUID: Synthetic.speakers.uid)
        let coordinator = rig.coordinator
        // While the first choice is still being applied (the engine is slow), a second choice completes.
        var inner: SelectionOutcome?
        rig.local.duringApply = { @MainActor in
            rig.local.duringApply = nil
            inner = await coordinator.select(.device(uid: Synthetic.dac.uid), engine: .localMedia)
        }
        let outer = await coordinator.select(.device(uid: Synthetic.buds.uid), engine: .localMedia)
        #expect(inner == .selected && outer == .superseded)
        #expect(coordinator.selection == .device(uid: Synthetic.dac.uid) && rig.store.load() == .device(uid: Synthetic.dac.uid), "the older choice's late completion changed nothing")
        #expect(coordinator.ignoredStale >= 1)
    }
    @Test(arguments: [(OutputEngineKind.youTubeMusic, OutputEngineKind.localMedia), (.localMedia, .youTubeMusic)])
    func theOldEngineIsSilentBeforeTheNewOneMayStart(from: OutputEngineKind, to: OutputEngineKind) async {
        let rig = await Rig.make()
        rig.engine(from).audible = true
        let generation = rig.coordinator.generation
        let outcome = await rig.coordinator.beginHandoff(to: to)
        #expect(outcome == .ready)
        #expect(rig.engine(from).log == ["stopForHandoff"] && !rig.engine(from).audible, "the old engine confirmed silence before `ready` was returned")
        #expect(rig.engine(to).log.isEmpty, "the new engine has not been touched yet: the caller starts it only after `ready`")
        #expect(rig.coordinator.generation > generation && rig.coordinator.activeEngine == to)
        rig.engine(to).started()
        #expect(!rig.engine(from).audible && rig.engine(to).audible, "exactly one engine sounds")
    }
    @Test func aHandoffIsRefusedWhenTheOldEngineCannotBeConfirmedSilent() async {
        let rig = await Rig.make()
        rig.music.audible = true; rig.music.confirmsStop = false
        #expect(await rig.coordinator.beginHandoff(to: .localMedia) == .refused, "never two uncontrolled players")
        #expect(rig.coordinator.activeEngine == nil)
    }
    @Test func aNewerHandoffSupersedesAnOlderOneWhoseStopIsStillInFlight() async {
        let rig = await Rig.make()
        rig.music.audible = true; rig.local.audible = true
        let coordinator = rig.coordinator
        var second: HandoffOutcome?
        // The music engine's stop (for the first handoff, to local) is still in flight when a newer handoff, to music, begins and completes.
        rig.music.duringStop = { @MainActor in
            rig.music.duringStop = nil
            second = await coordinator.beginHandoff(to: .youTubeMusic)
        }
        let first = await coordinator.beginHandoff(to: .localMedia)
        #expect(second == .ready && first == .superseded, "the older handoff must not start its engine")
        #expect(coordinator.activeEngine == .youTubeMusic && coordinator.ignoredStale >= 1)
    }
    @Test func aLocalToAirPlayHandoffSilencesTheDecodedGraphAndNeverTheAVPlayer() async {
        let graph = await Rig.make(localBackend: .decodedGraph)
        graph.local.audible = true
        #expect(await graph.coordinator.remoteBegan() == nil, "the system picker cannot reach the decoded graph, so no remote session starts")
        #expect(graph.local.log == ["stopForHandoff"] && graph.coordinator.remote == nil, "it is silenced instead of playing beside a receiver")
        let player = await Rig.make(localBackend: .avPlayer)
        let id = await player.coordinator.remoteBegan()
        #expect(id != nil && player.coordinator.remote?.id == id && player.local.log.isEmpty, "the AVPlayer itself is handed to the receiver by AVFoundation")
    }
    @Test func eventsFromAnEarlierRemoteSessionAreIgnored() async throws {
        let rig = await Rig.make()
        let first = try #require(await rig.coordinator.remoteBegan())
        rig.coordinator.remoteEvent(.ended(.chosenByPerson), session: first)
        let second = try #require(await rig.coordinator.remoteBegan())
        let now = ContinuousClock.now
        rig.coordinator.remoteEvent(.position(99, observedAt: now), session: first)
        rig.coordinator.remoteEvent(.state(.playing), session: first)
        rig.coordinator.remoteEvent(.ended(.receiverLost), session: first)
        #expect(rig.coordinator.remote?.id == second && rig.coordinator.remote?.reading == nil && rig.coordinator.remote?.state == .connecting)
        #expect(rig.coordinator.loss == nil, "a late 'receiver lost' from the old session cannot pause the new one")
        #expect(rig.coordinator.ignoredStale == 3)
        rig.coordinator.remoteEvent(.position(12, observedAt: now), session: second)
        #expect(rig.coordinator.remote?.reading?.seconds == 12)
    }
    @Test func theReceiversPositionIsShownAsReportedNeverExtrapolatedAndNeverStale() throws {
        var session = RemoteSession(id: UUID(), generation: 1)
        let origin = ContinuousClock.now
        #expect(session.displayedPosition(now: origin) == nil, "nothing reported, nothing shown")
        session.apply(reading: PositionReading(seconds: 40, observedAt: origin))
        #expect(session.displayedPosition(now: origin.advanced(by: .seconds(4))) == 40, "four seconds later it still says what the receiver said")
        #expect(session.displayedPosition(now: origin.advanced(by: .seconds(11))) == nil, "an old report is withheld rather than guessed forward")
        session.apply(reading: PositionReading(seconds: 55, observedAt: origin.advanced(by: .seconds(5))))
        session.apply(reading: PositionReading(seconds: 41, observedAt: origin.advanced(by: .seconds(1))))   // arrived late
        #expect(session.reading?.seconds == 55, "an older observation never replaces a newer one")
    }
    @Test func aBadPositionIsDropped() async throws {
        let rig = await Rig.make()
        let id = try #require(await rig.coordinator.remoteBegan())
        rig.coordinator.remoteEvent(.position(-1, observedAt: .now), session: id)
        rig.coordinator.remoteEvent(.position(.infinity, observedAt: .now), session: id)
        rig.coordinator.remoteEvent(.position(.nan, observedAt: .now), session: id)
        #expect(rig.coordinator.remote?.reading == nil && rig.coordinator.ignoredStale == 3)
    }
    @Test func aReceiverThatDisappearsIsARouteLossAndAChoiceInThePickerIsNot() async throws {
        let lost = await Rig.make()
        lost.local.audible = true
        let id = try #require(await lost.coordinator.remoteBegan())
        lost.coordinator.remoteEvent(.ended(.receiverLost), session: id)
        #expect(lost.coordinator.remote == nil && lost.coordinator.loss?.reason == .receiverDisconnected)
        await lost.coordinator.settled()
        #expect(lost.local.log == ["pauseForRouteLoss"])
        let chosen = await Rig.make()
        chosen.local.audible = true
        let other = try #require(await chosen.coordinator.remoteBegan())
        chosen.coordinator.remoteEvent(.ended(.chosenByPerson), session: other)
        #expect(chosen.coordinator.loss == nil && chosen.local.log.isEmpty)
    }
    @Test func theGenerationOnlyMovesForwardAcrossEveryRouteChange() async throws {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds, Synthetic.dac], defaultUID: Synthetic.speakers.uid)
        var seen = [rig.coordinator.generation]
        _ = await rig.coordinator.select(.device(uid: Synthetic.dac.uid), engine: .localMedia); seen.append(rig.coordinator.generation)
        _ = await rig.coordinator.beginHandoff(to: .youTubeMusic); seen.append(rig.coordinator.generation)
        rig.directory.change([Synthetic.speakers, Synthetic.buds], defaultUID: Synthetic.speakers.uid); seen.append(rig.coordinator.generation)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 }, "\(seen)")
    }
}

/// T22.4: the capability table governs volume, grouping, the timer and quit; nothing offers what the route cannot honour.
@Suite @MainActor struct RouteCapabilityTests {
    typealias C = RouteCapabilities
    @Test func theTableForEveryEngineBackendAndRoute() {
        // (engine, backend, mode) -> (selection, volume, timer, grouping)
        let rows: [(OutputEngineKind, OutputBackend, RouteMode, C.Selection, C.Volume, C.Timer, C.Grouping)] = [
            (.youTubeMusic, .hiddenWebPlayer, .systemOutput(.builtIn), .systemControlled, .appLevel, .fadeThenPause, .notOffered),
            (.youTubeMusic, .hiddenWebPlayer, .systemOutput(.bluetooth), .systemControlled, .appLevel, .fadeThenPause, .notOffered),
            (.youTubeMusic, .hiddenWebPlayer, .systemOutput(.airPlay), .systemControlled, .appLevel, .fadeThenPause, .notOffered),
            (.localMedia, .avPlayer, .systemOutput(.builtIn), .appSelectable, .appLevel, .fadeThenPause, .notOffered),
            (.localMedia, .avPlayer, .systemOutput(.usb), .appSelectable, .appLevel, .fadeThenPause, .notOffered),
            (.localMedia, .avPlayer, .systemOutput(.bluetooth), .appSelectable, .appLevel, .fadeThenPause, .notOffered),
            (.localMedia, .avPlayer, .systemOutput(.airPlay), .systemPickerOnly, .appLevel, .fadeThenPause, .systemPickerOnly),
            (.localMedia, .avPlayer, .externalPlayback, .systemPickerOnly, .receiver, .pauseOnly, .systemPickerOnly),
            (.localMedia, .decodedGraph, .systemOutput(.builtIn), .appSelectable, .appLevel, .fadeThenPause, .notOffered),
            (.localMedia, .decodedGraph, .systemOutput(.airPlay), .systemPickerOnly, .appLevel, .fadeThenPause, .systemPickerOnly),
            (.localMedia, .decodedGraph, .externalPlayback, .systemControlled, .appLevel, .fadeThenPause, .notOffered),
        ]
        for (engine, backend, mode, selection, volume, timer, grouping) in rows {
            let caps = C.resolve(engine: engine, backend: backend, mode: mode)
            #expect(caps.selection == selection && caps.volume == volume && caps.timer == timer && caps.grouping == grouping, "\(engine) \(backend) \(mode): \(caps)")
            #expect(caps.quit == .stopsPlayback, "quit ends the sound on every route this node provides")
        }
    }
    @Test func nothingIsOfferedThatARouteCannotHonour() {
        for engine in [OutputEngineKind.youTubeMusic, .localMedia] {
            for backend in [OutputBackend.avPlayer, .decodedGraph, .hiddenWebPlayer] {
                for mode in [RouteMode.systemOutput(.builtIn), .systemOutput(.airPlay), .systemOutput(.bluetooth), .externalPlayback] {
                    let caps = C.resolve(engine: engine, backend: backend, mode: mode)
                    if caps.timer == .pauseOnly { #expect(caps.limits.contains(.fadeOnReceiver), "a timer that cannot fade must say so") }
                    if caps.selection == .systemControlled { #expect(caps.limits.contains(.chooseOutputInApp) || caps.limits.contains(.chooseAirPlayInApp)) }
                    #expect(caps.limits.contains(.changeDeviceVolume), "this app never changes the Mac's volume")
                    #expect([C.Grouping.notOffered, .systemPickerOnly].contains(caps.grouping), "grouping exists only inside the system picker")
                    if caps.volume == .receiver { #expect(caps.timer == .pauseOnly, "a receiver that sets the level cannot be faded by the app") }
                }
            }
        }
    }
    @Test func theHiddenPlayerCannotBePointedAnywhereAndSaysSo() async {
        let rig = await Rig.make()
        for route in [OutputRouteID.systemDefault, .device(uid: Synthetic.speakers.uid), .device(uid: Synthetic.buds.uid)] {
            #expect(await rig.coordinator.select(route, engine: .youTubeMusic) == .unsupported, "\(route)")
        }
        #expect(rig.music.applied.isEmpty && rig.store.load() == nil && rig.coordinator.selection == .systemDefault, "nothing was changed or remembered")
        for entry in rig.coordinator.entries(for: .youTubeMusic) {
            #expect(entry.capabilities.selection == .systemControlled && entry.capabilities.limits.contains(.chooseOutputInApp) && entry.capabilities.limits.contains(.chooseAirPlayInApp))
        }
        #expect(!rig.coordinator.offersSystemPicker(for: .youTubeMusic))
    }
    @Test func anAirPlayDeviceIsChosenInTheSystemPickerNotByTheApp() async {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.receiver], defaultUID: Synthetic.speakers.uid)
        #expect(await rig.coordinator.select(.device(uid: Synthetic.receiver.uid), engine: .localMedia) == .unsupported)
        #expect(rig.local.applied.isEmpty)
        let row = rig.coordinator.entries(for: .localMedia).first { $0.id == .device(uid: Synthetic.receiver.uid) }
        #expect(row?.capabilities.selection == .systemPickerOnly && row?.capabilities.grouping == .systemPickerOnly)
    }
    @Test func theSystemPickerIsOfferedOnlyWhereItCanReachTheEngine() async {
        let player = await Rig.make(localBackend: .avPlayer), graph = await Rig.make(localBackend: .decodedGraph)
        #expect(player.coordinator.offersSystemPicker(for: .localMedia) && !graph.coordinator.offersSystemPicker(for: .localMedia))
    }
    @Test func aRemoteSessionChangesWhatTheTimerAndTheVolumeCanDo() async throws {
        let rig = await Rig.make()
        #expect(rig.coordinator.capabilities(for: .localMedia).timer == .fadeThenPause)
        _ = try #require(await rig.coordinator.remoteBegan())
        let caps = rig.coordinator.capabilities(for: .localMedia)
        #expect(caps.timer == .pauseOnly && caps.volume == .receiver && caps.selection == .systemPickerOnly)
        #expect(await rig.coordinator.select(.device(uid: Synthetic.speakers.uid), engine: .localMedia) == .unsupported, "a playing receiver is changed in the system picker")
    }
    @Test func theListShowsEveryLiveOutputOnceWithItsStateAndHidesSoftwareDevices() async {
        let virtual = OutputDevice(uid: "SYNTH-LOOPBACK", name: "Synthetic Loopback", transportCode: 0x7669_7274)
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds, virtual], defaultUID: Synthetic.buds.uid)
        let entries = rig.coordinator.entries(for: .localMedia)
        #expect(entries.map(\.id) == [.systemDefault, .device(uid: Synthetic.speakers.uid), .device(uid: Synthetic.buds.uid)], "\(entries.map(\.id))")
        #expect(entries.allSatisfy { $0.connection == .connected })
        #expect(entries.first?.name == "Synthetic Buds" && entries.first?.isCurrent == true, "the system row names what it follows")
        #expect(entries.filter(\.isSystemOutput).map(\.name) == ["Synthetic Buds", "Synthetic Buds"], "the row for the current system output is marked")
    }
}

/// T22.5: nothing sounds on speakers after a loss until Play here is confirmed, and a receiver that cannot fade the timer says so before it is enabled.
@Suite @MainActor struct PlayHereTests {
    private func lost(_ kind: OutputEngineKind = .localMedia) async -> Rig {
        let rig = await Rig.make()
        rig.engine(kind).audible = true
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        await rig.coordinator.settled()
        return rig
    }
    @Test(arguments: [OutputEngineKind.youTubeMusic, .localMedia])
    func playHereAsksFirstAndSoundsOnlyAfterConfirmation(kind: OutputEngineKind) async throws {
        let rig = await lost(kind)
        var started = 0
        let ran = await rig.coordinator.perform(.start, engine: kind) { started += 1; rig.engine(kind).started() }
        #expect(!ran && started == 0 && !rig.engine(kind).audible, "the prompt is up and nothing is audible")
        guard case .playHere(let prompt)? = rig.coordinator.prompt else { Issue.record("expected the Play here prompt"); return }
        #expect(prompt.output == Synthetic.speakers.name && prompt.reason == .deviceDisconnected && !prompt.canReconnect)
        await rig.coordinator.confirm(prompt.id)
        #expect(started == 1 && rig.engine(kind).audible && rig.coordinator.loss(for: kind) == nil && rig.coordinator.prompt == nil)
        #expect(rig.coordinator.selection == .systemDefault, "Play here means this Mac's current output")
        if kind == .localMedia { #expect(rig.local.applied.last == .some(nil), "the local engine follows the system output again") }
        else { #expect(rig.local.applied.isEmpty, "the hidden player follows the Mac already; the local engine's choice is not touched") }
    }
    @Test func playHereDoesNotRewriteTheRememberedRoute() async throws {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds], defaultUID: Synthetic.buds.uid, preferred: .device(uid: Synthetic.buds.uid))
        rig.local.audible = true
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        _ = await rig.coordinator.perform(.start, engine: .localMedia) {}
        guard case .playHere(let prompt)? = rig.coordinator.prompt else { Issue.record("expected the prompt"); return }
        await rig.coordinator.confirm(prompt.id)
        #expect(rig.store.load() == .device(uid: Synthetic.buds.uid), "a temporary Play here is not a new preference")
    }
    @Test func cancellingKeepsEverythingSilentAndTheLossStanding() async throws {
        let rig = await lost()
        var started = 0
        _ = await rig.coordinator.perform(.start, engine: .localMedia) { started += 1 }
        let id = try #require(rig.coordinator.prompt?.id)
        rig.coordinator.cancel(id)
        #expect(rig.coordinator.prompt == nil && started == 0 && rig.coordinator.loss != nil)
        await rig.coordinator.confirm(id)
        #expect(started == 0, "a cancelled prompt cannot be confirmed later")
    }
    @Test func aPromptTheRouteOutlivedIsDroppedAndNeverPlays() async throws {
        let rig = await lost()
        var started = 0
        _ = await rig.coordinator.perform(.start, engine: .localMedia) { started += 1 }
        let id = try #require(rig.coordinator.prompt?.id)
        // The outputs change while the prompt is up (a device appears): what it described is no longer what would happen.
        rig.directory.change([Synthetic.speakers, Synthetic.dac], defaultUID: Synthetic.dac.uid)
        await rig.coordinator.confirm(id)
        #expect(started == 0 && rig.coordinator.prompt == nil, "it must be asked again")
    }
    @Test func reconnectingAvoidsThePromptBecauseSoundReturnsToTheSameOutput() async {
        let rig = await lost()
        rig.directory.change([Synthetic.speakers, Synthetic.buds], defaultUID: Synthetic.buds.uid)
        #expect(await rig.coordinator.reconnect())
        var started = 0
        #expect(await rig.coordinator.perform(.start, engine: .localMedia) { started += 1 } && started == 1)
    }
    @Test func aReceiverThatCannotFadeTheTimerIsExplainedBeforeTheTimerIsEnabled() async throws {
        let rig = await Rig.make()
        let session = try #require(await rig.coordinator.remoteBegan())
        var enabled = 0
        let ran = await rig.coordinator.perform(.enableTimer, engine: .localMedia) { enabled += 1 }
        #expect(!ran && enabled == 0, "not enabled before the warning is acknowledged")
        guard case .timer(let prompt)? = rig.coordinator.prompt else { Issue.record("expected the timer warning"); return }
        await rig.coordinator.confirm(prompt.id)
        #expect(enabled == 1)
        #expect(await rig.coordinator.perform(.enableTimer, engine: .localMedia) { enabled += 1 } && enabled == 2, "told once per receiver session")
        rig.coordinator.remoteEvent(.ended(.chosenByPerson), session: session)
        _ = try #require(await rig.coordinator.remoteBegan())
        #expect(!(await rig.coordinator.perform(.enableTimer, engine: .localMedia) { enabled += 1 }) && enabled == 2, "a new receiver session is told again")
    }
    @Test func startingWithATimerAlreadyRunningOnAReceiverAlsoWarns() async throws {
        let rig = await Rig.make()
        _ = try #require(await rig.coordinator.remoteBegan())
        var started = 0
        #expect(!(await rig.coordinator.perform(.start, engine: .localMedia, timerActive: true) { started += 1 }) && started == 0)
        #expect(rig.coordinator.prompt != nil)
    }
    @Test func aLocalOutputNeedsNoTimerWarning() async {
        let rig = await Rig.make()
        var enabled = 0
        #expect(await rig.coordinator.perform(.enableTimer, engine: .localMedia) { enabled += 1 } && enabled == 1 && rig.coordinator.prompt == nil)
        #expect(await rig.coordinator.perform(.enableTimer, engine: .youTubeMusic) { enabled += 1 } && enabled == 2)
    }
}

/// T22.1 / ROUTE01, rework finding 1 and 7: each engine is judged against the route IT is audible on.
@Suite @MainActor struct PerEngineRouteTests {
    @Test func theHiddenPlayerPausesWhenTheSystemDefaultLeavesEvenThoughTheLocalEngineChoseAnotherDevice() async {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds, Synthetic.dac], defaultUID: Synthetic.buds.uid)
        #expect(await rig.coordinator.select(.device(uid: Synthetic.dac.uid), engine: .localMedia) == .selected)
        rig.music.audible = true   // YouTube Music plays through the AirPods (the system default)
        rig.directory.change([Synthetic.speakers, Synthetic.dac], defaultUID: Synthetic.speakers.uid)
        #expect(rig.music.log == ["pauseForRouteLoss"], "paused in the announcement's turn")
        #expect(rig.coordinator.loss(for: .youTubeMusic)?.reason == .deviceDisconnected && rig.coordinator.loss(for: .youTubeMusic)?.lost?.uid == Synthetic.buds.uid)
        #expect(rig.coordinator.loss(for: .localMedia) == nil && rig.local.log == [rig.local.log.first ?? ""].filter { $0.hasPrefix("apply") }, "the DAC is still there: the local engine is untouched")
    }
    @Test func aChosenDeviceThatLeavesDoesNotPauseTheHiddenPlayerPlayingOnTheDefault() async {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds, Synthetic.dac], defaultUID: Synthetic.buds.uid)
        #expect(await rig.coordinator.select(.device(uid: Synthetic.dac.uid), engine: .localMedia) == .selected)
        rig.music.audible = true
        rig.directory.change([Synthetic.speakers, Synthetic.buds], defaultUID: Synthetic.buds.uid)
        #expect(rig.music.log.isEmpty && rig.coordinator.loss(for: .youTubeMusic) == nil, "the page never played through the DAC")
    }
    @Test func theLocalEngineStillPausesWhenItsChosenDeviceLeaves() async {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds, Synthetic.dac], defaultUID: Synthetic.buds.uid)
        _ = await rig.coordinator.select(.device(uid: Synthetic.dac.uid), engine: .localMedia)
        rig.local.audible = true
        rig.directory.change([Synthetic.speakers, Synthetic.buds], defaultUID: Synthetic.buds.uid)
        #expect(rig.local.log.last == "pauseForRouteLoss" && rig.coordinator.loss(for: .localMedia)?.lostRoute == .device(uid: Synthetic.dac.uid))
    }
    @Test func theHiddenPlayersPickerShowsTheRouteItReallyPlaysOn() async {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds, Synthetic.dac], defaultUID: Synthetic.buds.uid)
        _ = await rig.coordinator.select(.device(uid: Synthetic.dac.uid), engine: .localMedia)
        let music = rig.coordinator.entries(for: .youTubeMusic), local = rig.coordinator.entries(for: .localMedia)
        #expect(music.filter(\.isCurrent).map(\.id) == [.systemDefault], "the page follows the system output, whatever the local engine chose")
        #expect(local.filter(\.isCurrent).map(\.id) == [.device(uid: Synthetic.dac.uid)])
        #expect(rig.coordinator.currentOutput(for: .youTubeMusic)?.uid == Synthetic.buds.uid && rig.coordinator.currentOutput(for: .localMedia)?.uid == Synthetic.dac.uid)
        let route = rig.coordinator.audibleRoute(for: .localMedia)
        #expect(route.identity?.uid == Synthetic.dac.uid && route.pinned, "the wake check compares the device the engine was pointed at")
        #expect(rig.coordinator.audibleRoute(for: .youTubeMusic).pinned == false)
    }
    @Test func lossesAreHeldPerEngineAndPlayHereClearsOnlyWhatItAccepted() async throws {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds, Synthetic.dac], defaultUID: Synthetic.buds.uid)
        _ = await rig.coordinator.select(.device(uid: Synthetic.dac.uid), engine: .localMedia)
        rig.local.audible = true; rig.music.audible = true
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)   // both the AirPods and the DAC leave
        #expect(rig.coordinator.loss(for: .localMedia) != nil && rig.coordinator.loss(for: .youTubeMusic) != nil)
        var ran = 0
        _ = await rig.coordinator.perform(.start, engine: .youTubeMusic) { ran += 1 }
        guard case .playHere(let prompt)? = rig.coordinator.prompt else { Issue.record("expected the prompt"); return }
        #expect(prompt.engine == .youTubeMusic)
        await rig.coordinator.confirm(prompt.id)
        #expect(ran == 1 && rig.coordinator.loss(for: .youTubeMusic) == nil)
        #expect(rig.coordinator.loss(for: .localMedia) != nil, "the local engine's DAC is a different loss and still needs its own Play here")
    }
    // MARK: round 2, R2-1: the OTHER engine may not start on the speakers that took over
    @Test(arguments: [(OutputEngineKind.localMedia, OutputEngineKind.youTubeMusic), (.youTubeMusic, .localMedia)])
    func afterALossTheOtherEngineAlsoNeedsPlayHereBeforeItStartsOnTheSpeakers(sounding: OutputEngineKind, other: OutputEngineKind) async throws {
        let rig = await Rig.make()   // both engines are on the system default, the earbuds
        rig.engine(sounding).audible = true
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        await rig.coordinator.settled()
        #expect(rig.engine(sounding).log.last == "pauseForRouteLoss" && rig.engine(other).log.isEmpty, "only the engine that sounded is paused")
        let held = try #require(rig.coordinator.loss(for: other), "the other engine's route was the lost device too")
        #expect(!held.wasAudible && held.lost?.uid == Synthetic.buds.uid)
        var started = 0
        let ran = await rig.coordinator.perform(.start, engine: other) { started += 1; rig.engine(other).started() }
        #expect(!ran && started == 0 && !rig.engine(other).audible, "a new item on the other engine asks first")
        guard case .playHere(let prompt)? = rig.coordinator.prompt else { Issue.record("expected Play here"); return }
        #expect(prompt.engine == other)
        await rig.coordinator.confirm(prompt.id)
        #expect(started == 1 && rig.coordinator.loss(for: other) == nil)
        #expect(rig.coordinator.loss(for: sounding) == nil, "accepting this Mac's output for the lost device clears the other engine's loss of the same device")
    }
    @Test func anEngineOnADifferentDeviceIsNotHeldByAnotherEnginesLoss() async {
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds, Synthetic.dac], defaultUID: Synthetic.buds.uid)
        _ = await rig.coordinator.select(.device(uid: Synthetic.dac.uid), engine: .localMedia)
        rig.music.audible = true
        rig.directory.change([Synthetic.speakers, Synthetic.dac], defaultUID: Synthetic.speakers.uid)   // the earbuds leave; the DAC stays
        #expect(rig.coordinator.loss(for: .youTubeMusic) != nil && rig.coordinator.loss(for: .localMedia) == nil)
        var started = 0
        #expect(await rig.coordinator.perform(.start, engine: .localMedia) { started += 1 } && started == 1, "the DAC engine plays on the DAC, not the speakers")
    }
    @Test func nothingIsHeldWhenNeitherEngineEverSoundedOnTheLostDevice() async {
        let rig = await Rig.make()
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        #expect(rig.coordinator.losses.isEmpty)
        var started = 0
        #expect(await rig.coordinator.perform(.start, engine: .youTubeMusic) { started += 1 } && started == 1)
    }
    // MARK: finding 7: the default moves before the device is announced as gone
    private final class Clock: @unchecked Sendable { var instant = ContinuousClock.now }
    @Test func aDeviceThatDisappearsJustAfterTheDefaultLeftItIsALoss() async {
        let clock = Clock()
        let rig = await Rig.make(now: { clock.instant })
        rig.music.audible = true
        // First announcement: the system already moved the default to the speakers; the earbuds are still listed.
        rig.directory.change([Synthetic.speakers, Synthetic.buds], defaultUID: Synthetic.speakers.uid)
        #expect(rig.coordinator.loss(for: .youTubeMusic) == nil && rig.music.log.isEmpty, "indistinguishable, for the moment, from a person's choice")
        clock.instant = clock.instant.advanced(by: .milliseconds(200))
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        #expect(rig.coordinator.loss(for: .youTubeMusic)?.lost?.uid == Synthetic.buds.uid, "the departure follows the move: the move was the fallback")
        #expect(rig.music.log == ["pauseForRouteLoss"])
    }
    @Test func aDeviceThatLeavesLongAfterThePersonMovedAwayIsNotALoss() async {
        let clock = Clock()
        let rig = await Rig.make(now: { clock.instant })
        rig.music.audible = true
        rig.directory.change([Synthetic.speakers, Synthetic.buds], defaultUID: Synthetic.speakers.uid)
        clock.instant = clock.instant.advanced(by: .seconds(30))
        rig.directory.change([Synthetic.speakers], defaultUID: Synthetic.speakers.uid)
        #expect(rig.coordinator.loss(for: .youTubeMusic) == nil && rig.music.log.isEmpty, "a person's choice and an unrelated unplug later")
    }
    @Test func moveToAnotherDetachableDeviceThenRemovalOfTheFirstIsALossOnlyInsideTheWindow() async {
        let clock = Clock()
        let rig = await Rig.make(devices: [Synthetic.speakers, Synthetic.buds, Synthetic.dac], defaultUID: Synthetic.buds.uid, now: { clock.instant })
        rig.music.audible = true
        rig.directory.change([Synthetic.speakers, Synthetic.buds, Synthetic.dac], defaultUID: Synthetic.dac.uid)
        rig.directory.change([Synthetic.speakers, Synthetic.dac], defaultUID: Synthetic.dac.uid)
        #expect(rig.coordinator.loss(for: .youTubeMusic) != nil, "inside the window")
    }
}
