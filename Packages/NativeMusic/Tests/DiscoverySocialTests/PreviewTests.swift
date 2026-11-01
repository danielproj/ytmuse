import AccountSession
import Features
import Foundation
import Testing

/// T20.1 — One active preview; explicit Play hands off without overlap; Low Power Mode or a constrained network disables default autoplay.
@Suite @MainActor struct PreviewPolicyTests {
    @Test func theDefaultChoiceIsAutomaticAndNothingStartsAtLaunch() async {
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine)
        #expect(arbiter.preference == .automatic)
        #expect(arbiter.active == nil)
        #expect(engine.starts.isEmpty, "constructing the arbiter starts nothing")
    }
    @Test func autoplayIsRefusedOnLowPowerModeOnAConstrainedNetworkAndWhenTurnedOffAndAllowedOtherwise() {
        func refusal(_ preference: PreviewAutoplayPreference, _ conditions: PreviewConditions) -> PreviewRefusal? {
            PreviewPolicy.autoplayRefusal(preference: preference, conditions: conditions)
        }
        #expect(refusal(.automatic, PreviewConditions()) == nil)
        #expect(refusal(.automatic, PreviewConditions(lowPowerMode: true)) == .lowPowerMode)
        #expect(refusal(.automatic, PreviewConditions(constrainedNetwork: true)) == .constrainedNetwork)
        #expect(refusal(.automatic, PreviewConditions(lowPowerMode: true, constrainedNetwork: true)) == .lowPowerMode)
        #expect(refusal(.automatic, PreviewConditions(playbackBusy: true)) == .playbackBusy)
        #expect(refusal(.off, PreviewConditions()) == .turnedOff)
        #expect(refusal(.off, PreviewConditions(lowPowerMode: true)) == .turnedOff)
        // The person's explicit "On" overrides the device conditions, but never interrupts other playback by itself.
        #expect(refusal(.on, PreviewConditions(lowPowerMode: true, constrainedNetwork: true)) == nil)
        #expect(refusal(.on, PreviewConditions(playbackBusy: true)) == .playbackBusy)
    }
    @Test func everyRefusalHasItsOwnWords() {
        let all: [PreviewRefusal] = [.lowPowerMode, .constrainedNetwork, .turnedOff, .playbackBusy, .engineFailed, .superseded]
        #expect(Set(all.map(\.message)).count == all.count)
        #expect(PreviewRefusal.lowPowerMode.message.contains("Low Power Mode"))
        #expect(PreviewRefusal.constrainedNetwork.message.contains("constrained"))
    }
    @Test func autoplayDoesNotStartOnLowPowerModeButAPressedPreviewDoes() async {
        let device = Device(); device.conditions = PreviewConditions(lowPowerMode: true)
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine, conditions: { device.conditions })
        let refused = await arbiter.request(clip("a"), trigger: .autoplay)
        #expect(refused == .refused(.lowPowerMode))
        #expect(engine.starts.isEmpty && arbiter.active == nil)
        #expect(arbiter.events.contains(.refused("a", .lowPowerMode)))
        let pressed = await arbiter.request(clip("a"), trigger: .explicit)
        #expect(pressed == .previewing)
        #expect(arbiter.active == "a" && engine.starts == ["a"])
    }
    @Test func autoplayDoesNotStartOnAConstrainedNetworkAndStartsWhenItClears() async {
        let device = Device(); device.conditions = PreviewConditions(constrainedNetwork: true)
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine, conditions: { device.conditions })
        #expect(await arbiter.request(clip("a"), trigger: .autoplay) == .refused(.constrainedNetwork))
        device.conditions.constrainedNetwork = false
        #expect(await arbiter.request(clip("a"), trigger: .autoplay) == .previewing)
        #expect(arbiter.activeTrigger == .autoplay)
    }
    @Test func theOffChoiceStopsAutoplayEvenOnAFastConnection() async {
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine)
        arbiter.preference = .off
        #expect(await arbiter.request(clip("a"), trigger: .autoplay) == .refused(.turnedOff))
        #expect(engine.starts.isEmpty)
    }
    @Test func autoplayNeverInterruptsOtherPlayback() async {
        let device = Device(); device.conditions = PreviewConditions(playbackBusy: true)
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine, conditions: { device.conditions })
        arbiter.preference = .on
        #expect(await arbiter.request(clip("a"), trigger: .autoplay) == .refused(.playbackBusy))
        #expect(engine.starts.isEmpty)
    }
    @Test func aPreviewThatStartedByItselfStopsWhenLowPowerModeTurnsOnButOneThePersonAskedForContinues() async {
        let device = Device()
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine, conditions: { device.conditions })
        _ = await arbiter.request(clip("auto"), trigger: .autoplay)
        #expect(arbiter.active == "auto")
        device.conditions.lowPowerMode = true
        arbiter.conditionsChanged()
        await arbiter.stop(.requested)       // a barrier behind the queued stop
        #expect(arbiter.events.contains(.stopped("auto", reason: .conditionsChanged)))
        #expect(arbiter.active == nil && engine.sounding.isEmpty)

        _ = await arbiter.request(clip("asked"), trigger: .explicit)
        device.conditions.constrainedNetwork = true
        arbiter.conditionsChanged()
        await arbiter.stop(.leftScreen)
        // The explicit one was only stopped by the explicit stop that followed, never by the conditions.
        #expect(!arbiter.events.contains(.stopped("asked", reason: .conditionsChanged)))
        #expect(arbiter.events.contains(.stopped("asked", reason: .leftScreen)))
    }
    @Test func changingTheChoiceToOffStopsAnAutoplayPreview() async {
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine)
        _ = await arbiter.request(clip("a"), trigger: .autoplay)
        arbiter.preference = .off
        await arbiter.stop(.requested)
        #expect(arbiter.events.contains(.stopped("a", reason: .conditionsChanged)))
    }
}

@Suite @MainActor struct PreviewArbitrationTests {
    @Test func askingForAnotherClipStopsTheFirstBeforeTheSecondStartsAndNeverOverlaps() async {
        let log = Timeline(); let engine = TimelineEngine(log: log)
        let arbiter = makeArbiter(engine: engine)
        _ = await arbiter.request(clip("a"), trigger: .explicit)
        _ = await arbiter.request(clip("b"), trigger: .explicit)
        #expect(log.events == ["engine.start:a", "engine.stop", "engine.start:b"])
        #expect(engine.maxSounding == 1)
        #expect(arbiter.active == "b" && engine.sounding == ["b"])
        #expect(arbiter.isPreviewing("b") && !arbiter.isPreviewing("a"))
    }
    @Test func theSameClipAskedTwiceIsNotRestarted() async {
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine)
        _ = await arbiter.request(clip("a"), trigger: .autoplay)
        _ = await arbiter.request(clip("a"), trigger: .explicit)
        #expect(engine.starts == ["a"] && engine.stops == 0)
        #expect(arbiter.activeTrigger == .explicit, "a press turns an automatic preview into one the person asked for")
    }
    @Test func manyRapidRequestsNeverLeaveTwoSoundingAndTheStateMatchesTheEngine() async {
        // `async let` does not promise which request is made first, so this asserts what must hold in every order; the order-dependent
        // behaviour (an overtaken request never starts) is the next test, which holds the engine to make the order certain.
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine)
        async let first = arbiter.request(clip("a"), trigger: .explicit)
        async let second = arbiter.request(clip("b"), trigger: .explicit)
        async let third = arbiter.request(clip("c"), trigger: .explicit)
        let results = await [first, second, third]
        #expect(engine.maxSounding == 1, "no two clips ever sounded together")
        #expect(engine.sounding.count == 1 && arbiter.active == engine.sounding.first, "what the arbiter says is previewing is what sounds")
        #expect(results.contains(.previewing), "the request that was not overtaken previews")
        for result in results { if case .refused(let why) = result { #expect(why == .superseded) } }
    }
    @Test func aRequestThatANewerOneOvertookNeverStarts() async {
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine)
        engine.holdStarts = true
        let first = Task { await arbiter.request(clip("a"), trigger: .explicit) }
        while !engine.isHolding { await Task.yield() }
        let second = Task { await arbiter.request(clip("b"), trigger: .explicit) }
        let third = Task { await arbiter.request(clip("c"), trigger: .explicit) }
        for _ in 0..<30 { await Task.yield() }
        engine.holdStarts = false
        engine.release()
        #expect(await first.value == .previewing)
        #expect(await second.value == .refused(.superseded), "b was overtaken by c before its turn")
        #expect(await third.value == .previewing)
        #expect(engine.starts == ["a", "c"], "b never reached the engine")
        #expect(arbiter.active == "c" && engine.sounding == ["c"] && engine.maxSounding == 1)
    }
    @Test func aSuccessfulStartClearsTheLastRefusal() async {
        let engine = TimelineEngine(); engine.failing = ["bad"]
        let arbiter = makeArbiter(engine: engine)
        _ = await arbiter.request(clip("bad"), trigger: .explicit)
        #expect(arbiter.lastRefusal == .engineFailed)
        _ = await arbiter.request(clip("good"), trigger: .explicit)
        #expect(arbiter.lastRefusal == nil)
    }
    @Test func aFailedStartLeavesNothingActiveAndSaysSo() async {
        let engine = TimelineEngine(); engine.failing = ["bad"]
        let arbiter = makeArbiter(engine: engine)
        _ = await arbiter.request(clip("a"), trigger: .explicit)
        let result = await arbiter.request(clip("bad"), trigger: .explicit)
        #expect(result == .refused(.engineFailed))
        #expect(arbiter.active == nil, "the first preview was stopped to make room; nothing is claimed to be playing")
        #expect(arbiter.lastRefusal == .engineFailed)
        #expect(engine.sounding.isEmpty)
    }
    @Test func stoppingEndsThePreviewAndWaitsUntilItIsSilent() async {
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine)
        _ = await arbiter.request(clip("a"), trigger: .explicit)
        await arbiter.stop(.requested)
        #expect(arbiter.active == nil && engine.sounding.isEmpty)
        await arbiter.stop(.requested)
        #expect(engine.stops == 1, "stopping with nothing previewing asks the engine for nothing")
    }
    @Test func theSharedSessionPlayingSomethingElseEndsThePreview() async {
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine)
        _ = await arbiter.request(clip("a"), trigger: .explicit)
        await arbiter.playbackStartedElsewhere()
        #expect(arbiter.active == nil)
        #expect(arbiter.events.contains(.stopped("a", reason: .playbackStarted)))
    }
    @Test func anAccountChangeStopsThePreviewAndDiscardsAStartThatWasInFlight() async {
        let engine = TimelineEngine()
        let arbiter = makeArbiter(engine: engine)
        _ = await arbiter.request(clip("a"), trigger: .explicit)
        arbiter.accountChanged()
        await arbiter.stop(.requested)
        #expect(arbiter.active == nil && engine.sounding.isEmpty)
        #expect(arbiter.events.contains(.stopped("a", reason: .accountChanged)))

        engine.holdStarts = true
        let inFlight = Task { await arbiter.request(clip("late"), trigger: .explicit) }
        while !engine.isHolding { await Task.yield() }
        arbiter.accountChanged()
        engine.holdStarts = false
        engine.release()
        #expect(await inFlight.value == .refused(.superseded))
        await arbiter.stop(.requested)
        #expect(arbiter.active == nil)
        #expect(engine.sounding.isEmpty, "a clip that finished starting after the account changed is not left sounding")
    }
    @Test func theEventLogIsBounded() async {
        let arbiter = makeArbiter()
        for index in 0..<260 { _ = await arbiter.request(clip("c\(index)"), trigger: .explicit) }
        #expect(arbiter.events.count <= 200)
    }
}

@Suite @MainActor struct PreviewHandoffTests {
    @Test func playStopsThePreviewWaitsUntilItIsSilentAndOnlyThenAsksThePlaybackSession() async {
        let log = Timeline(); let engine = TimelineEngine(log: log); let performer = RecordingPerformer(log: log)
        var soundingAtPlay: [String]?
        performer.atPlay = { soundingAtPlay = engine.sounding }
        let arbiter = makeArbiter(engine: engine)
        let sample = clip("a", playlist: "RDAMVMa", params: "p1")
        _ = await arbiter.request(sample, trigger: .explicit)
        let outcome = await arbiter.play(sample, performer: performer)
        #expect(outcome == .started)
        #expect(soundingAtPlay == [], "nothing was sounding when the shared session was asked to play")
        #expect(log.events == ["engine.start:a", "engine.stop", "performer.play:RDAMVMa"])
        #expect(performer.plays == [.init(playlistID: "RDAMVMa", title: "Clip a", videoID: "a", params: "p1")])
        #expect(arbiter.active == nil)
        #expect(arbiter.events.last == .handedOff("a"))
        #expect(engine.maxSounding == 1)
    }
    @Test func playingADifferentClipWhileAnotherPreviewsEndsThatPreviewToo() async {
        let log = Timeline(); let engine = TimelineEngine(log: log); let performer = RecordingPerformer(log: log)
        let arbiter = makeArbiter(engine: engine)
        _ = await arbiter.request(clip("a"), trigger: .explicit)
        _ = await arbiter.play(clip("b", playlist: "RDAMVMb"), performer: performer)
        #expect(log.events == ["engine.start:a", "engine.stop", "performer.play:RDAMVMb"])
        #expect(arbiter.active == nil)
    }
    @Test func playWithNothingPreviewingJustPlaysAndDoesNotTouchTheEngine() async {
        let engine = TimelineEngine(); let performer = RecordingPerformer()
        let arbiter = makeArbiter(engine: engine)
        #expect(await arbiter.play(clip("a", playlist: "RDAMVMa"), performer: performer) == .started)
        #expect(engine.starts.isEmpty && engine.stops == 0)
    }
    @Test func aClipWithNoPlaylistOfItsOwnPlaysAsItsRadioFromThatTrack() async {
        let performer = RecordingPerformer()
        let arbiter = makeArbiter()
        _ = await arbiter.play(clip("zzzzzzzzzzz"), performer: performer)
        #expect(performer.plays == [.init(playlistID: "RDAMVMzzzzzzzzzzz", title: "Clip zzzzzzzzzzz", videoID: nil, params: nil)])
    }
    @Test func aRefusedStartIsReportedAndThePreviewIsAlreadyGone() async {
        let engine = TimelineEngine(); let performer = RecordingPerformer(); performer.outcome = .failed
        let arbiter = makeArbiter(engine: engine)
        _ = await arbiter.request(clip("a"), trigger: .explicit)
        #expect(await arbiter.play(clip("a", playlist: "RDAMVMa"), performer: performer) == .notStarted(.failed))
        #expect(arbiter.active == nil && engine.sounding.isEmpty)
        #expect(!arbiter.events.contains(.handedOff("a")))
    }
    @Test func twoPlaysInARowSendTwoRequestsOneEachAndNeverOverlap() async {
        let engine = TimelineEngine(); let performer = RecordingPerformer()
        let arbiter = makeArbiter(engine: engine)
        _ = await arbiter.request(clip("a"), trigger: .explicit)
        _ = await arbiter.play(clip("a", playlist: "RDAMVMa"), performer: performer)
        _ = await arbiter.request(clip("b"), trigger: .explicit)
        _ = await arbiter.play(clip("b", playlist: "RDAMVMb"), performer: performer)
        #expect(performer.plays.count == 2)
        #expect(engine.maxSounding == 1)
    }
}

@Suite @MainActor struct SamplesModelTests {
    private func model(_ source: ScriptedSamplesSource, device: Device = Device(), playback: SearchPlayback = .available,
                       engine: TimelineEngine = TimelineEngine(), performer: RecordingPerformer = RecordingPerformer()) -> (SamplesModel, TimelineEngine, RecordingPerformer) {
        let arbiter = makeArbiter(engine: engine, conditions: { device.conditions })
        Retained.keep(performer)
        return (SamplesModel(source: source, arbiter: arbiter, performer: performer, signedIn: { playback }), engine, performer)
    }
    @Test func aSourceWithNoRouteSaysSoAndIsNeverRead() async {
        let source = ScriptedSamplesSource(unresolved: "No route.")
        let (samples, engine, _) = model(source)
        #expect(samples.state == .unresolved("No route."))
        await samples.load()
        #expect(samples.state == .unresolved("No route.") && source.reads == 0 && samples.readCount == 0)
        #expect(engine.starts.isEmpty)
    }
    @Test func theApplicationsOwnSourceIsUnresolvedAndSaysWhy() async {
        let (samples, _, _) = model(ScriptedSamplesSource(unresolved: UnresolvedSamplesSource().unresolved))
        guard case .unresolved(let reason) = samples.state else { Issue.record("expected the unresolved state"); return }
        #expect(reason.contains("Samples aren’t available yet"))
        #expect(!reason.contains("unavailable for your account"), "an unresolved route is not an account restriction")
        await #expect(throws: SamplesFailure.self) { _ = try await UnresolvedSamplesSource().clips() }
    }
    @Test func loadedClipsKeepTheSourcesOrderAndDropRepeats() async {
        let (samples, _, _) = model(ScriptedSamplesSource(.success([clip("a"), clip("b"), clip("a"), clip("c")])))
        await samples.load()
        #expect(samples.clips.map(\.id) == ["a", "b", "c"])
    }
    @Test func noClipsIsAnAnswerAndAFailureIsADifferentOne() async {
        let (empty, _, _) = model(ScriptedSamplesSource(.success([])))
        await empty.load()
        #expect(empty.state == .empty)
        let (failed, _, _) = model(ScriptedSamplesSource(.failure(.offline)))
        await failed.load()
        #expect(failed.state == .failed(.offline))
        #expect(empty.state != failed.state)
    }
    @Test func signedOutAndEndedSessionsAreNotReadAndSayWhichIsWhich() async {
        let source = ScriptedSamplesSource(.success([clip("a")]))
        let (out, _, _) = model(source, playback: .needsSignIn)
        await out.load()
        #expect(out.state == .failed(.needsSignIn))
        let (ended, _, _) = model(source, playback: .sessionExpired)
        await ended.load()
        #expect(ended.state == .failed(.sessionEnded))
        #expect(source.reads == 0)
    }
    @Test func focusingAClipPreviewsItByItselfOnlyWhenThePolicyAllows() async {
        let device = Device()
        let (samples, engine, _) = model(ScriptedSamplesSource(.success([clip("a"), clip("b")])), device: device)
        await samples.load()
        await samples.focus("a")
        #expect(samples.arbiter.active == "a")
        await samples.focus("b")
        #expect(samples.arbiter.active == "b" && engine.maxSounding == 1)
        device.conditions.lowPowerMode = true
        await samples.focus("a")
        #expect(samples.arbiter.active == "b", "Low Power Mode: focusing does not start another preview by itself")
        await samples.preview("a")
        #expect(samples.arbiter.active == "a", "a press still does")
    }
    @Test func focusingNothingOrAnUnknownClipEndsThePreview() async {
        let (samples, engine, _) = model(ScriptedSamplesSource(.success([clip("a")])))
        await samples.load()
        await samples.focus("a")
        await samples.focus(nil)
        #expect(samples.arbiter.active == nil && engine.sounding.isEmpty)
        await samples.preview("a")
        await samples.focus("not-a-clip")
        #expect(samples.arbiter.active == nil)
    }
    @Test func playHandsTheClipToTheSharedSessionAfterThePreviewIsSilent() async {
        let (samples, engine, performer) = model(ScriptedSamplesSource(.success([clip("a", playlist: "RDAMVMa")])))
        await samples.load()
        await samples.preview("a")
        performer.atPlay = { #expect(engine.sounding.isEmpty) }
        await samples.play("a")
        #expect(samples.handoff == .started)
        #expect(performer.plays.count == 1 && samples.arbiter.active == nil)
    }
    @Test func aSignedOutAccountLoadsNoClipsSoThereIsNothingToPlay() async {
        let (out, _, performer) = model(ScriptedSamplesSource(.success([clip("a", playlist: "RDAMVMa")])), playback: .needsSignIn)
        await out.load()
        await out.play("a")
        #expect(performer.plays.isEmpty && out.clips.isEmpty)
    }
    @Test func playAfterSigningOutSendsNothing() async {
        final class Flag: @unchecked Sendable { var playback = SearchPlayback.available }
        let flag = Flag()
        let engine = TimelineEngine(); let performer = RecordingPerformer()
        Retained.keep(performer)
        let samples = SamplesModel(source: ScriptedSamplesSource(.success([clip("a", playlist: "RDAMVMa")])), arbiter: makeArbiter(engine: engine), performer: performer, signedIn: { flag.playback })
        await samples.load()
        flag.playback = .needsSignIn
        await samples.play("a")
        #expect(performer.plays.isEmpty)
        #expect(samples.handoff == .notStarted(.failed))
        flag.playback = .sessionExpired
        await samples.play("a")
        #expect(performer.plays.isEmpty && samples.handoff == .notStarted(.stale))
        flag.playback = .available
        await samples.play("a")
        #expect(performer.plays.count == 1 && samples.handoff == .started)
    }
    @Test func leavingTheScreenStopsThePreview() async {
        let (samples, engine, _) = model(ScriptedSamplesSource(.success([clip("a")])))
        await samples.load()
        await samples.preview("a")
        await samples.leaveScreen()
        #expect(samples.focused == nil && engine.sounding.isEmpty)
    }
    @Test func anAccountChangeClearsTheClipsTheFocusAndThePreview() async {
        let (samples, engine, _) = model(ScriptedSamplesSource(.success([clip("a")])))
        await samples.load()
        await samples.preview("a")
        samples.accountChanged()
        await samples.arbiter.stop(.requested)
        #expect(samples.state == .idle && samples.focused == nil && samples.handoff == nil && engine.sounding.isEmpty)
    }
    @Test func loadingStartsNoPreview() async {
        let (samples, engine, _) = model(ScriptedSamplesSource(.success([clip("a"), clip("b")])))
        await samples.load()
        #expect(engine.starts.isEmpty, "clips appearing on screen do not start a sound")
    }
}

/// F6: a preview is one clip. It ends with the clip and never runs on into what follows.
@Suite struct PreviewWatcherTests {
    private func watch(video: String?, phase: PreviewPlayerPhase, position: Double = 5, duration: Double? = 30, before: Int = 3, now: Int = 3, clip: String = "clip") -> PreviewWatch {
        PreviewWatcher.evaluate(clip: clip, durationSeconds: duration, videoID: video, phase: phase, position: position, playRequestsAtStart: before, playRequestsNow: now)
    }
    @Test func theClipPlayingInsideItsLengthIsStillThePreview() {
        #expect(watch(video: "clip", phase: .active) == .stay)
        #expect(watch(video: "clip", phase: .paused) == .stay)
        #expect(watch(video: nil, phase: .active) == .stay, "nothing reported yet")
    }
    @Test func theClipEndingEndsThePreview() {
        #expect(watch(video: "clip", phase: .ended) == .clipEnded)
        #expect(watch(video: "clip", phase: .active, position: 29.9) == .clipEnded, "within a quarter second of the stated length")
        #expect(watch(video: "clip", phase: .active, position: 29.0) == .stay)
    }
    @Test func withoutAStatedLengthTheEndIsWhatThePlayerReports() {
        #expect(watch(video: "clip", phase: .active, position: 9_999, duration: nil) == .stay)
        #expect(watch(video: "clip", phase: .ended, duration: nil) == .clipEnded)
        #expect(watch(video: "clip", phase: .active, position: 9_999, duration: 0) == .stay, "a zero length is no length")
        #expect(watch(video: "clip", phase: .active, position: .nan) == .stay)
    }
    @Test func aPlayerThatRanOnIntoAnotherItemByItselfIsStopped() {
        // The next track of a radio: another item, playing, and nobody asked the player for anything since the preview began.
        #expect(watch(video: "next-track", phase: .active) == .leftOnItsOwn)
    }
    @Test func aPlayerThatMovedBecauseSomethingAskedItYieldsWithoutBeingTouched() {
        #expect(watch(video: "other", phase: .active, before: 3, now: 4) == .replacedByRequest)
    }
    @Test func anotherItemThatIsNotPlayingIsNotAContinuation() {
        #expect(watch(video: "other", phase: .paused) == .stay)
        #expect(watch(video: "other", phase: .ended) == .stay)
        #expect(watch(video: "other", phase: .other) == .stay)
    }
}
