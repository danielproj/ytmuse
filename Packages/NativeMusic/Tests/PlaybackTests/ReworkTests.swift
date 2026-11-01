import Testing
import Foundation
import Domain
import Queue
import AccountSession
@testable import Playback
@testable import AppShell

actor HeldPoint {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; waiter?.resume(); waiter = nil; await withCheckedContinuation { releaseWaiter = $0 } }
    func wait() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
actor HeldQueueStore: QueuePersistence {
    var state: QueueSnapshot?
    var writes: [QueueSnapshot] = []
    var nextHold: HeldPoint?
    func arm(_ hold: HeldPoint) { nextHold = hold }
    func load(context: RequestContext) -> QueueSnapshot? { state }
    func save(_ snapshot: QueueSnapshot, context: RequestContext) async {
        if let hold = nextHold { nextHold = nil; await hold.hold() }
        state = snapshot; writes.append(snapshot)
    }
}
struct HeldOwnedAssets: NativeAssetProvider {
    let gate: HeldPoint
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL {
        await gate.hold(); return try await OwnedMedia().asset(for: variant, context: context)
    }
}
func quietSession(_ store: any QueuePersistence, generation: UInt64 = 1, assets: (any NativeAssetProvider)? = nil) async throws -> PlaybackSession {
    let media = OwnedMedia()
    return try await PlaybackSession.open(context: ownedContext(generation), persistence: store, assets: assets ?? media, resolver: media, capabilities: media, automaticTick: false, initialGain: 0.001, maximumStartGain: 0.001, gapless: false)
}
func assertQuietStarts(_ session: PlaybackSession) async {
    let observations = await session.nativeStartGains()
    #expect(!observations.isEmpty)
    #expect(observations.allSatisfy { $0 <= 0.001001 })
    print("W06 R1 native first/all start gains=\(observations)")
}

extension NativePlaybackTests {
    // Real elapsed native playback. NO seek or manual position checkpoint precedes pause.
    @Test(arguments: ["pause", "quit", "account"]) func RF1ElapsedTransitionCommitsPosition(path: String) async throws {
        let store = MemoryPersistence(); let session = try await quietSession(store)
        try await session.startOwnedMedia(OwnedMedia.items)
        try await Task.sleep(for: .milliseconds(850))
        let before = await session.nativePosition()
        #expect(before > 0.5 && before < 5)
        if path == "pause" {
            try await session.pause()
            let paused = try await session.snapshot()
            #expect(paused.queue.session.position >= before - 0.15)
            try await session.resume()
            #expect(await session.nativePosition() >= before - 0.15)
            await session.close()
        } else {
            await session.close(reason: path == "account" ? .accountSwitch : .quit)
            let closed = try await session.snapshot()
            #expect(closed.playback.state == .idle && closed.playback.error == nil)
            let restored = try await quietSession(store, generation: 2)
            let saved = try await restored.snapshot()
            #expect(saved.queue.intent == .pause(.restored))
            #expect(saved.queue.session.position >= before - 0.15)
            try await restored.resume()
            #expect(await restored.nativePosition() >= before - 0.15)
            await assertQuietStarts(restored); await restored.close()
        }
        await assertQuietStarts(session)
        print("W06 R1 RF1 \(path): native elapsed before transition=\(before)")
    }
    @Test func RF1PauseCommitBeforePublishAndCompetingSelection() async throws {
        let store = HeldQueueStore(); let session = try await quietSession(store)
        try await session.startOwnedMedia(OwnedMedia.items)
        try await Task.sleep(for: .milliseconds(650))
        let old = try await session.snapshot(); let before = await session.nativePosition()
        let held = HeldPoint(); await store.arm(held)
        let pausing = Task { try await session.pause() }
        await held.wait()
        // The pause candidate has sampled the bound position, but remains unpublished.
        let uncommitted = try await session.snapshot()
        #expect(uncommitted.queue.intent == .play)
        let destination = try #require(old.queue.upcoming.first?.id)
        let selecting = Task { try await session.select(destination) }
        await held.release(); _ = try await pausing.value; _ = try await selecting.value
        let after = try await session.snapshot()
        #expect(after.queue.current?.id == destination && after.queue.session.position < 0.25)
        #expect(after.playback.context.occurrenceID == destination)
        #expect(await store.writes.contains { $0.current?.id == old.queue.current?.id && $0.intent == .pause(.user) && $0.session.position >= before - 0.15 })
        // A late old engine observation cannot overwrite the new committed occurrence.
        await session.receive(.init(context: old.playback.context, event: .position(99)))
        #expect(try await session.snapshot().queue.session.position < 0.25)
        await session.close(reason: .accountSwitch)
        let replacement = try await quietSession(store, generation: 2)
        await session.receive(.init(context: old.playback.context, event: .position(100)))
        #expect(try await replacement.snapshot().queue.current?.id == destination)
        #expect(try await replacement.snapshot().queue.session.position < 1)
        await replacement.close()
    }
    @Test func RF2ControlsBeforeFirstPrepareAndReplacement() async throws {
        let media = OwnedMedia(); let engine = NativePlayer(assets: media, clock: SystemMonotonicClock(), maximumStartGain: 0.001)
        let scope = PlaybackContext(request: ownedContext(), generation: 0, occurrenceID: nil, route: nil)
        _ = try await engine.setGain(0.0004, context: scope).outcome.get()
        _ = try await engine.setMuted(true, context: scope).outcome.get()
        for generation in 1...2 {
            let context = PlaybackContext(request: ownedContext(), generation: UInt64(generation), occurrenceID: UUID(), route: nil)
            let variant = try await media.resolve(OwnedMedia.items[generation - 1], context: context).outcome.get()[0]
            _ = try await engine.prepare(variant, context: context).outcome.get()
            #expect(abs(await engine.nativeGain() - 0.0004) < 0.000001)
            #expect(await engine.nativeMuted())
            #expect(await engine.nativeRate() == 0)
            #expect(await engine.nativeStartGains().isEmpty)
        }
        _ = await engine.stop(context: .init(request: ownedContext(2), generation: 1, occurrenceID: nil, route: nil))
        if case .failure(.staleContext) = await engine.setGain(0.5, context: scope).outcome {} else { Issue.record("Old account control admitted") }
    }
    @Test func RF2ControlsSurviveColdRestoreAndConcurrentPreparation() async throws {
        let store = MemoryPersistence(); let first = try await quietSession(store)
        try await first.startOwnedMedia(OwnedMedia.items); await first.close()
        let hold = HeldPoint(); let restored = try await quietSession(store, generation: 2, assets: HeldOwnedAssets(gate: hold))
        try await restored.setGain(0.0003); try await restored.setMuted(true)
        #expect(abs(try await restored.snapshot().gain - 0.0003) < 0.000001)
        let starting = Task { try await restored.resume() }
        await hold.wait()
        try await restored.setGain(0.0007); try await restored.setMuted(true)
        #expect(abs(await restored.nativeGain() - 0.0007) < 0.000001)
        #expect(await restored.nativeMuted())
        #expect(await restored.nativeStartGains().isEmpty, "Controls must already be native before first play")
        await hold.release(); _ = try await starting.value
        #expect(abs(await restored.nativeGain() - 0.0007) < 0.000001)
        #expect(await restored.nativeMuted())
        #expect(await restored.nativeStartGains() == [Float(0.0007)])
        async let older: Void = restored.setGain(0.0004)
        async let newer: Void = restored.setGain(0.0006)
        _ = try await (older, newer)
        let state = try await restored.snapshot()
        #expect(abs(Float(state.gain) - state.appliedGain) < 0.000001)
        await restored.close()
    }
    // Failure/EOS events below are injected, while actual AVPlayer starts are quiet.
    @Test(arguments: ["prepare", "mid-play", "mixed"]) func RF3EveryConsecutiveFailureCounts(path: String) async throws {
        let session = try await ownedSession()
        let missing = try ["missing-1", "missing-2", "missing-3", "missing-4"].map(ServiceID.init)
        let items: [ServiceID] = path == "prepare" ? [OwnedMedia.items[0]] + missing : path == "mid-play" ? [OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0]] : [OwnedMedia.items[0], OwnedMedia.items[1]] + missing
        try await session.startOwnedMedia(items)
        var state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .ended))
        if path != "prepare" {
            var delivered = 0
            while delivered < 5 {
                state = try await session.snapshot()
                if state.queue.intent != .play { break }
                await session.receive(.init(context: state.playback.context, event: .failed(.unavailableContent)))
                delivered += 1
            }
            if path == "mid-play" { #expect(delivered == 3) }
        }
        state = try await session.snapshot()
        #expect(state.failures.count == 3 && state.queue.metadata.failures?.count == 3)
        #expect(state.queue.intent == .pause(.user))
        let failures = try #require(state.queue.metadata.failures)
        #expect(Set(failures.map(\.occurrence)).count == 3)
        print("W06 R1 RF3 \(path) failed occurrences=\(failures.map(\.media))")
        await assertQuietStarts(session); await session.close()
    }
    @Test func RF3NaturalCompletionResetsAndUserSelectionStartsNewSequence() async throws {
        let session = try await ownedSession()
        try await session.startOwnedMedia([OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0]])
        var s = try await session.snapshot(); await session.receive(.init(context: s.playback.context, event: .ended))
        for _ in 0..<2 { s = try await session.snapshot(); await session.receive(.init(context: s.playback.context, event: .failed(.unavailableContent))) }
        // A successful natural completion breaks the chain; another two failures do not stop it.
        s = try await session.snapshot(); await session.receive(.init(context: s.playback.context, event: .ended))
        for _ in 0..<2 { s = try await session.snapshot(); await session.receive(.init(context: s.playback.context, event: .failed(.unavailableContent))) }
        #expect(try await session.snapshot().queue.intent == .play)
        // Explicit selection remains a Retry decision, even if this item subsequently fails.
        s = try await session.snapshot(); try await session.select(try #require(s.queue.current?.id))
        s = try await session.snapshot(); await session.receive(.init(context: s.playback.context, event: .failed(.unavailableContent)))
        #expect(try await session.snapshot().queue.current?.id == s.queue.current?.id)
        #expect(try await session.snapshot().playback.state == .failed)
        await session.close()
    }
    @Test func RF4ExplicitNextWrapAndRepeatOneDiffersFromNaturalEnd() async throws {
        let session = try await ownedSession(); try await session.startOwnedMedia(OwnedMedia.items)
        try await session.sendQueue(.repeatMode(.one))
        let first = try await session.snapshot()
        await session.receive(.init(context: first.playback.context, event: .ended))
        #expect(try await session.snapshot().queue.current?.id == first.queue.current?.id)
        try await session.next(); #expect(try await session.snapshot().queue.current?.media == OwnedMedia.items[1])
        try await session.sendQueue(.repeatMode(.all)); try await session.next()
        #expect(try await session.snapshot().queue.current?.media == OwnedMedia.items[0])
        #expect(try await session.snapshot().queue.intent == .play)
        await assertQuietStarts(session); await session.close()
    }
    @Test func RL6RealExhaustionSeekIsUnavailableWithoutErrorOrAutoplay() async throws {
        let session = try await ownedSession(); try await session.startOwnedMedia([OwnedMedia.items[1]])
        try await session.seek(7.65)
        // TH1: the 3 s is the allowance for the ~0.35 s of REAL audio that remains after the seek. It used to start at the seek, so everything a
        // loaded whole-package run spends before the audio is running again (the seek settling, the buffer refilling) was taken out of it. The
        // allowance now starts when the player reports playing (or already ended) again; getting there has its own, generous bound (a player that
        // never resumes still fails). The 3 s for the audio itself is unchanged.
        let resumeBy = ContinuousClock.now.advanced(by: .seconds(30))
        while try await ![.playing, .ended].contains(session.snapshot().playback.state), ContinuousClock.now < resumeBy { try await Task.sleep(for: .milliseconds(10)) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        // TH1 rework 2: the SETTLED end. The player reports `.ended` first and the queue clears its current item a moment later (after the checkpoint), so a
        // snapshot that stops at `.ended` can hold the half-finished state (seen once, failing after 0.68 s). Both are still asserted below.
        func settledEnd() async throws -> Bool { let now = try await session.snapshot(); return now.playback.state == .ended && now.queue.current == nil }
        while !(try await settledEnd()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let before = try await session.snapshot(); #expect(before.playback.state == .ended && before.queue.current == nil)
        let startsBefore = await session.nativeStartGains().count
        try await session.seek(2)
        let after = try await session.snapshot()
        #expect(after.playback.state == .ended && after.playback.error == nil)
        #expect(after.queue.intent == before.queue.intent && after.queue.session.version == before.queue.session.version)
        #expect(await session.nativeStartGains().count == startsBefore)
        await session.close()
    }
    @Test func RL8RequestTimePermitRejectsBothHeldOrderings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("W06-R1-gate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authority = AppPlaybackAuthority(directory: directory, offlineVault: try isolatedOwnedVault(in: directory))
        let queuedClick = authority.requestOwnedStart()
        try await authority.detach(previous: ownedContext(), barrier: .init(account: nil, accountGeneration: 9, requestGeneration: 0))
        await #expect(throws: DomainError.staleContext) { _ = try await authority.owned(request: queuedClick, initialGain: 0.001, maximumStartGain: 0.001) }
        let held = HeldPoint(); let pending = AppPlaybackAuthority(directory: directory, beforeOpen: { await held.hold() }, offlineVault: try isolatedOwnedVault(in: directory))
        let permit = pending.requestOwnedStart()
        let opening = Task { try await pending.owned(request: permit, initialGain: 0.001, maximumStartGain: 0.001) }
        await held.wait(); try await pending.detach(previous: ownedContext(), barrier: .init(account: nil, accountGeneration: 10, requestGeneration: 0))
        await held.release()
        await #expect(throws: DomainError.staleContext) { _ = try await opening.value }
        // A fresh deliberate click after the barrier may create a new paused owner.
        let fresh = try await authority.owned(request: authority.requestOwnedStart(), initialGain: 0.001, maximumStartGain: 0.001)
        #expect(try await fresh.snapshot().playback.state == .idle)
        #expect(await fresh.nativeStartGains().isEmpty)
        await fresh.close()
    }
}

extension PlaybackPolicyTests {
    @Test func RL5QuitStopsOnNewGenerationAndCheckpointsNormally() async throws {
        let context = request(try account()); let engine = TestEngine(); let clock = ManualMonotonic(); let lifecycle = TestLifecycle()
        let provider = TestProvider(account: context.account!)
        let commands = PlaybackCommands(request: context, engine: engine, resolver: provider, capabilities: provider, wall: FixedWall(date: testWall), monotonic: clock, lifecycle: lifecycle)
        _ = try await commands.execute(.select(media: sid(), occurrence: UUID()), context: context, origin: .menu).outcome.get()
        let old = await commands.snapshot().context
        clock.advance(to: .seconds(2))
        let before = await engine.recorded().count; let checkpoints = await lifecycle.checkpoints
        _ = try await commands.execute(.quit, context: context, origin: .menu).outcome.get()
        let state = await commands.snapshot()
        #expect(state.state == .idle && state.error == nil && state.position == 2)
        #expect(state.context.generation > old.generation)
        #expect(await engine.recorded().dropFirst(before).map { $0 } == ["stop"])
        #expect(await lifecycle.checkpoints == checkpoints + 1)
        await commands.receive(.init(context: old, event: .started))
        #expect(await commands.snapshot().state == .idle)
    }
}

extension NativePlaybackTests {
    @Test func RF2ReplacementDuringFadeUsesDesiredGainBeforePlay() async throws {
        let wall = ManualWall(); let clock = ManualMonotonic()
        let session = try await ownedSession(wall: wall, clock: clock)
        try await session.startOwnedMedia(OwnedMedia.items)
        try await session.setGain(0.0008); try await session.setTimer(.custom(1))
        wall.advance(1); await session.tick(); clock.advance(to: .seconds(4)); await session.tick()
        #expect(abs(await session.nativeGain() - 0.00016) < 0.000001)
        let current = try await session.snapshot()
        try await session.select(try #require(current.queue.upcoming.first?.id))
        #expect(abs(await session.nativeGain() - 0.0008) < 0.000001)
        #expect(await session.nativeStartGains().last == Float(0.0008))
        await session.tick(); #expect(await session.timerStatus() == nil)
        await session.close()
    }
}

extension NativePlaybackTests {
    @Test func RF1SlowPauseSaveRetainsFinalNativePositionAndAccountBarrier() async throws {
        let store = HeldQueueStore(); let session = try await quietSession(store)
        try await session.startOwnedMedia(OwnedMedia.items)
        try await Task.sleep(for: .milliseconds(650))
        let beforePause = await session.nativePosition()
        #expect(beforePause > 0)
        let held = HeldPoint(); await store.arm(held)
        let pausing = Task { try await session.pause() }
        await held.wait()
        // Transport now pauses before the first durable save. A held save must
        // not allow more output, and the final checkpoint must match the stop.
        let frozen = await session.nativePosition()
        try await Task.sleep(for: .milliseconds(450))
        #expect(abs(await session.nativePosition() - frozen) < 0.04)
        await held.release()
        _ = try await pausing.value
        let native = await session.nativePosition(); let paused = try await session.snapshot()
        #expect(native >= beforePause && native <= beforePause + 0.04)
        #expect(abs(paused.queue.session.position - native) < 0.15)
        let old = paused.playback.context
        let closing = Task { await session.close(reason: .accountSwitch) }
        await closing.value
        let restored = try await quietSession(store, generation: 2)
        await session.receive(.init(context: old, event: .position(99)))
        #expect(abs(try await restored.snapshot().queue.session.position - native) < 0.15)
        try await restored.resume()
        #expect(await restored.nativePosition() >= native - 0.15)
        print("W06 R1 slow-save final native=\(native), saved=\(paused.queue.session.position)")
        await restored.close()
    }
}

extension PlaybackPolicyTests {
    @Test func RF1LateOldPauseCannotStopNewSelectionAndEarlyReservationStillCancels() async throws {
        let context = request(try account()); let engine = TestEngine(); let commands = try commands(context, engine: engine)
        _ = try await commands.execute(.select(media: sid("a"), occurrence: UUID()), context: context, origin: .menu).outcome.get()
        let old = await commands.snapshot().context
        _ = try await commands.execute(.select(media: sid("b"), occurrence: UUID()), context: context, origin: .menu).outcome.get()
        let newer = await commands.snapshot()
        let late = await commands.execute(.pause(.user), context: context, origin: .menu, expectedPlaybackContext: old)
        if case .failure(.staleContext) = late.outcome {} else { Issue.record("Old pause admitted") }
        #expect(await commands.snapshot().context == newer.context)
        #expect(await commands.snapshot().state == .playing)
        let held = HeldPoint(); let occurrence = UUID()
        let selecting = Task { await commands.execute(.select(media: try sid("c"), occurrence: occurrence), context: context, origin: .menu, onSelection: { _ in await held.hold() }) }
        await held.wait()
        let reserved = PlaybackContext(request: context, generation: newer.context.generation + 1, occurrenceID: occurrence, route: nil)
        _ = try await commands.execute(.pause(.user), context: context, origin: .menu, expectedPlaybackContext: reserved).outcome.get()
        await held.release()
        if case .failure(.staleContext) = try await selecting.value.outcome {} else { Issue.record("Paused reservation started") }
        #expect(await commands.snapshot().intent == .pause(.user))
        #expect(await engine.recorded().filter { $0 == "play" }.count == 2)
    }
}

private struct HeldSecondAsset: NativeAssetProvider {
    let hold: HeldPoint
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL {
        if variant.id == OwnedMedia.items[1] { await hold.hold() }
        return try await OwnedMedia().asset(for: variant, context: context)
    }
}
extension NativePlaybackTests {
    @Test func RF3PendingUnattendedStartCannotReclassifyNewExplicitSelection() async throws {
        let hold = HeldPoint(); let session = try await quietSession(MemoryPersistence(), assets: HeldSecondAsset(hold: hold))
        try await session.startOwnedMedia([OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0], OwnedMedia.items[1]])
        let original = try await session.snapshot()
        let ending = Task { await session.receive(.init(context: original.playback.context, event: .ended)) }
        await hold.wait()
        let entries = try await session.snapshot().queue.session.entries
        let explicit = entries[2].id
        try await session.select(explicit)
        await hold.release(); await ending.value
        let current = try await session.snapshot()
        await session.receive(.init(context: current.playback.context, event: .failed(.unavailableContent)))
        let failed = try await session.snapshot()
        #expect(failed.queue.current?.id == explicit && failed.playback.state == .failed)
        #expect(failed.queue.metadata.failures?.map(\.occurrence) == [explicit])
        await assertQuietStarts(session); await session.close()
    }
}

extension NativePlaybackTests {
    @Test func RF3RepeatOneRepeatsSuccessButSkipsFailedOccurrences() async throws {
        let session = try await ownedSession()
        try await session.startOwnedMedia([OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0]])
        var state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .ended))
        try await session.sendQueue(.repeatMode(.one))
        let failedIDs = try await session.snapshot().queue.session.entries[1...3].map(\.id)
        for id in failedIDs {
            state = try await session.snapshot(); #expect(state.queue.current?.id == id)
            await session.receive(.init(context: state.playback.context, event: .failed(.unavailableContent)))
        }
        state = try await session.snapshot()
        #expect(state.queue.metadata.failures?.map(\.occurrence) == failedIDs)
        #expect(state.queue.current?.id == failedIDs.last && state.queue.intent == .pause(.user))
        await assertQuietStarts(session); await session.close()
    }
}
