import Domain
import Foundation
import Testing

actor SuspendedCapabilities: CapabilityProvider {
    let account: AccountContext
    var shouldHold = false
    var held: CheckedContinuation<Void, Never>?
    var entered: CheckedContinuation<Void, Never>?
    init(account: AccountContext) { self.account = account }
    func holdNext() { shouldHold = true }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { held?.resume(); held = nil }
    func capabilities(context: RequestContext) async -> ServiceResult<AccountCapabilities> {
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { held = $0; entered?.resume(); entered = nil }
        }
        return await TestProvider(account: account).capabilities(context: context)
    }
}
@Suite("T02.3 Transport ordering regressions") struct TransportRegressionTests {
    @Test func duplicateStartedPreservesElapsedPosition() throws {
        var m = PlaybackMachine(request: request(try account()))
        m.select(try sid(), occurrence: UUID(), now: .zero)
        m.receive(.resolved, context: m.context, now: .zero)
        m.receive(.prepared, context: m.context, now: .zero)
        m.receive(.started, context: m.context, now: .zero)
        let before = m.snapshot.position(at: .seconds(10))
        m.receive(.started, context: m.context, now: .seconds(10))
        #expect(before == 10)
        #expect(m.snapshot.position(at: .seconds(10)) == before)
    }
    @Test func spontaneousPausePreservesElapsedPosition() throws {
        var m = PlaybackMachine(request: request(try account()))
        m.select(try sid(), occurrence: UUID(), now: .zero)
        m.receive(.resolved, context: m.context, now: .zero)
        m.receive(.prepared, context: m.context, now: .zero)
        m.receive(.started, context: m.context, now: .zero)
        m.receive(.paused, context: m.context, now: .seconds(10))
        #expect(m.snapshot.position(at: .seconds(10)) == 10)
    }
    @Test func newerPauseWinsOverPendingResumeCapabilityCheck() async throws {
        let a = try account(); let ctx = request(a)
        let caps = SuspendedCapabilities(account: a); let engine = TestEngine()
        let player = PlaybackCommands(request: ctx, engine: engine, resolver: TestProvider(account: a), capabilities: caps, wall: FixedWall(date: testWall), monotonic: FixedMonotonic(), lifecycle: TestLifecycle())
        let selected = await player.execute(.select(media: try sid(), occurrence: UUID()), context: ctx, origin: .userInterface)
        _ = try selected.outcome.get()
        _ = await player.execute(.pause(.user), context: ctx, origin: .userInterface)
        let before = await engine.recorded().filter { $0 == "play" }.count
        await caps.holdNext()
        let pending = Task { await player.execute(.play, context: ctx, origin: .mediaKey) }
        await caps.waitUntilHeld()
        _ = await player.execute(.pause(.user), context: ctx, origin: .userInterface)
        await caps.release()
        let superseded = await pending.value
        #expect(throws: DomainError.staleContext) { try superseded.outcome.get() }
        #expect(await player.snapshot().intent == .pause(.user))
        #expect(await player.snapshot().state == .paused)
        #expect(await engine.recorded().filter { $0 == "play" }.count == before)
    }

    @Test func pendingPlayCannotOverwriteAnyNewerTransportIntent() async throws {
        let newerCommands: [PlaybackCommand] = [.pause(.user), .pause(.routeLoss), .sleep, .quit, .route(try RouteID("synthetic-route")), .select(media: try sid("new-item"), occurrence: UUID())]
        for command in newerCommands {
            let a = try account(); let ctx = request(a)
            let caps = SuspendedCapabilities(account: a); let engine = TestEngine()
            let player = PlaybackCommands(request: ctx, engine: engine, resolver: TestProvider(account: a), capabilities: caps, wall: FixedWall(date: testWall), monotonic: FixedMonotonic(), lifecycle: TestLifecycle())
            _ = await player.execute(.select(media: try sid(), occurrence: UUID()), context: ctx, origin: .userInterface)
            _ = await player.execute(.pause(.user), context: ctx, origin: .userInterface)
            await caps.holdNext()
            let pending = Task { await player.execute(.play, context: ctx, origin: .widget) }
            await caps.waitUntilHeld()
            _ = await player.execute(command, context: ctx, origin: .userInterface)
            let before = await player.snapshot()
            let starts = await engine.recorded().filter { $0 == "play" }.count
            await caps.release()
            let stale = await pending.value
            #expect(throws: DomainError.staleContext) { try stale.outcome.get() }
            let after = await player.snapshot()
            #expect(after.intent == before.intent && after.state == before.state && after.context == before.context)
            #expect(await engine.recorded().filter { $0 == "play" }.count == starts)
        }
    }
    @Test func latePlayAcknowledgementCannotOverridePauseEvenOnFailure() async throws {
        for failure in [nil, .transientTransport] as [DomainError?] {
            let a = try account(); let ctx = request(a); let engine = TestEngine()
            let player = try commands(ctx, engine: engine)
            _ = await player.execute(.select(media: try sid(), occurrence: UUID()), context: ctx, origin: .userInterface)
            _ = await player.execute(.pause(.user), context: ctx, origin: .userInterface)
            await engine.holdNextPlay(failure: failure)
            let pending = Task { await player.execute(.play, context: ctx, origin: .mediaKey) }
            await engine.waitUntilPlayHeld()
            _ = await player.execute(.pause(.user), context: ctx, origin: .userInterface)
            await engine.releasePlay(); _ = await pending.value
            let snapshot = await player.snapshot()
            #expect(snapshot.intent == .pause(.user) && snapshot.state == .paused && snapshot.error == nil)
            #expect(await engine.recorded().last == "pause")
        }
    }
    @Test func latePlayAcknowledgementCannotCompleteNewerSeek() async throws {
        let a = try account(); let ctx = request(a); let engine = TestEngine()
        let player = try commands(ctx, engine: engine)
        _ = await player.execute(.select(media: try sid(), occurrence: UUID()), context: ctx, origin: .userInterface)
        _ = await player.execute(.pause(.user), context: ctx, origin: .userInterface)
        await engine.holdNextPlay()
        let pending = Task { await player.execute(.play, context: ctx, origin: .mediaKey) }
        await engine.waitUntilPlayHeld()
        _ = await player.execute(.seek(40), context: ctx, origin: .userInterface)
        let before = await player.snapshot()
        await engine.releasePlay(); _ = await pending.value
        let after = await player.snapshot()
        #expect(before.state == .playing && after.state == .playing && after.position == 40)
        #expect(after.monotonicAnchor == before.monotonicAnchor)
    }
    @Test func notificationsCannotFinishASeekOrUndoANewerPause() throws {
        var m = PlaybackMachine(request: request(try account()))
        m.select(try sid(), occurrence: UUID(), now: .zero)
        m.receive(.resolved, context: m.context, now: .zero)
        m.receive(.prepared, context: m.context, now: .zero)
        m.receive(.started, context: m.context, now: .zero)
        _ = try m.seek(40, now: .seconds(10))
        #expect(m.receive(.started, context: m.context, now: .seconds(11)).isEmpty)
        #expect(m.receive(.paused, context: m.context, now: .seconds(12)).isEmpty)
        #expect(m.receive(.receiverPosition(11), context: m.context, now: .seconds(12)).isEmpty)
        #expect(m.state == .seeking && m.position == 40)
        _ = m.pause(.user, now: .seconds(13))
        #expect(m.receive(.started, context: m.context, now: .seconds(14)) == [.pause])
        #expect(m.state == .seeking && m.intent == .pause(.user))
        #expect(m.receive(.seekCompleted(revision: m.seekRevision), context: m.context, now: .seconds(15)).isEmpty)
        #expect(m.state == .paused && m.snapshot.position(at: .seconds(100)) == 40)
        _ = m.resume()
        // A delayed acknowledgement of the older Pause must not cancel the newer Play.
        m.receive(.paused, context: m.context, now: .seconds(16))
        m.receive(.started, context: m.context, now: .seconds(17))
        #expect(m.state == .playing && m.snapshot.position(at: .seconds(20)) == 43)
        _ = m.pause(.user, now: .seconds(20))
        #expect(m.receive(.started, context: m.context, now: .seconds(21)) == [.pause])
        #expect(m.state == .paused && m.snapshot.position(at: .seconds(100)) == 43)
    }
    @Test func duplicateAndTerminalNotificationsAreIdempotent() throws {
        var m = PlaybackMachine(request: request(try account()))
        m.select(try sid(), occurrence: UUID(), now: .zero)
        m.receive(.resolved, context: m.context, now: .zero)
        m.receive(.prepared, context: m.context, now: .zero)
        m.receive(.started, context: m.context, now: .zero)
        try m.setRate(2, now: .seconds(5))
        m.receive(.started, context: m.context, now: .seconds(10))
        #expect(m.snapshot.position(at: .seconds(10)) == 15)
        m.receive(.paused, context: m.context, now: .seconds(10))
        m.receive(.paused, context: m.context, now: .seconds(20))
        #expect(m.state == .paused && m.snapshot.position(at: .seconds(100)) == 15)
        // A spontaneous pause does not authorize a late start to run the timeline again.
        #expect(m.receive(.started, context: m.context, now: .seconds(21)) == [.pause])
        #expect(m.state == .paused && m.position == 15)
        m.receive(.ended, context: m.context, now: .seconds(22))
        #expect(m.receive(.paused, context: m.context, now: .seconds(23)).isEmpty)
        #expect(m.receive(.started, context: m.context, now: .seconds(24)).isEmpty)
        #expect(m.state == .ended)
    }

    @Test func latePauseAcknowledgementCannotOverrideNewerPlayEvenOnFailure() async throws {
        for failure in [nil, .transientTransport] as [DomainError?] {
            let a = try account(); let ctx = request(a); let engine = TestEngine()
            let player = try commands(ctx, engine: engine)
            _ = await player.execute(.select(media: try sid(), occurrence: UUID()), context: ctx, origin: .userInterface)
            await engine.holdNextPause(failure: failure)
            let pending = Task { await player.execute(.pause(.user), context: ctx, origin: .mediaKey) }
            await engine.waitUntilPauseHeld()
            _ = await player.execute(.play, context: ctx, origin: .userInterface)
            await engine.releasePause(); _ = await pending.value
            let snapshot = await player.snapshot()
            #expect(snapshot.intent == .play && snapshot.state == .playing && snapshot.error == nil)
            #expect(await engine.recorded().last == "play")
        }
    }
    @Test func seededCurrentGenerationNotificationsPreserveIndependentTimeline() throws {
        let seeds = try FixtureManifest.load().seeds
        var duplicateStarts = 0; var spontaneousPauses = 0; var lateStarts = 0
        for seed in seeds {
            var rng = SeededGenerator(seed: seed)
            var m = PlaybackMachine(request: request(try account(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)))
            m.select(try sid(), occurrence: seededUUID(&rng), now: .zero)
            m.receive(.resolved, context: m.context, now: .zero)
            m.receive(.prepared, context: m.context, now: .zero)
            var ticks = 0
            var expectedPosition = 0.0
            for step in 0..<128 {
                _ = m.resume()
                m.receive(.started, context: m.context, now: .seconds(ticks))
                let rate = Double(rng.next() % 4 + 1) / 2
                try m.setRate(rate, now: .seconds(ticks))
                for _ in 0..<3 {
                    let elapsed = Int(rng.next() % 9 + 1)
                    ticks += elapsed; expectedPosition += Double(elapsed) * rate
                    m.receive(.started, context: m.context, now: .seconds(ticks))
                    #expect(m.snapshot.position(at: .seconds(ticks)) == expectedPosition, "seed=\(seed), step=\(step)")
                    duplicateStarts += 1
                }
                ticks += 1; expectedPosition += rate
                m.receive(.paused, context: m.context, now: .seconds(ticks))
                #expect(m.state == .paused && m.position == expectedPosition, "seed=\(seed), step=\(step)")
                spontaneousPauses += 1
                ticks += 1
                #expect(m.receive(.started, context: m.context, now: .seconds(ticks)) == [.pause])
                #expect(m.state == .paused && m.snapshot.position(at: .seconds(ticks + 10)) == expectedPosition)
                lateStarts += 1
                ticks += 1
                m.receive(.paused, context: m.context, now: .seconds(ticks))
                #expect(m.position == expectedPosition)
            }
        }
        #expect(duplicateStarts == 2304 && spontaneousPauses == 768 && lateStarts == 768)
        print("W02 correction properties: seeds=\(seeds), duplicate starts=\(duplicateStarts), spontaneous pauses=\(spontaneousPauses), rejected late starts=\(lateStarts)")
    }

    @Test func delayedCapturedPauseCannotReplaceNewerStartedTransport() async throws {
        let a = try account(); let ctx = request(a); let engine = TestEngine(); let clock = ManualMonotonic()
        let provider = TestProvider(account: a)
        let player = PlaybackCommands(request: ctx, engine: engine, resolver: provider, capabilities: provider, wall: FixedWall(date: testWall), monotonic: clock, lifecycle: TestLifecycle())
        _ = await player.execute(.select(media: try sid(), occurrence: UUID()), context: ctx, origin: .userInterface)
        let token = await player.snapshot().context
        clock.advance(to: .seconds(10))
        await player.receive(.init(context: token, event: .paused, observedAt: .seconds(10)))
        #expect(await player.snapshot().position == 10)
        clock.advance(to: .seconds(20))
        _ = await player.execute(.play, context: ctx, origin: .userInterface)
        clock.advance(to: .seconds(30))
        // Capture predates the new start, although delivery happens afterward.
        await player.receive(.init(context: token, event: .paused, observedAt: .seconds(15)))
        let playing = await player.snapshot()
        #expect(playing.state == .playing && playing.position(at: clock.now()) == 20)
        // A genuinely new spontaneous pause must still materialize elapsed position.
        await player.receive(.init(context: token, event: .paused, observedAt: .seconds(30)))
        #expect(await player.snapshot().state == .paused)
        #expect(await player.snapshot().position == 20)
    }

    @Test func spontaneousBufferRecoveryPreservesPositionAndStillHonorsUserPause() throws {
        var m = PlaybackMachine(request: request(try account()))
        m.select(try sid(), occurrence: UUID(), now: .zero)
        m.receive(.resolved, context: m.context, now: .zero)
        m.receive(.prepared, context: m.context, now: .zero)
        m.receive(.started, context: m.context, now: .zero)
        m.receive(.buffering, context: m.context, now: .seconds(10))
        #expect(m.position == 10 && m.state == .buffering)
        #expect(m.receive(.started, context: m.context, now: .seconds(20)).isEmpty)
        #expect(m.state == .playing && m.snapshot.position(at: .seconds(25)) == 15)
        m.receive(.buffering, context: m.context, now: .seconds(25))
        _ = m.pause(.user, now: .seconds(26))
        #expect(m.receive(.started, context: m.context, now: .seconds(30)) == [.pause])
        #expect(m.state == .paused && m.position == 15 && m.intent == .pause(.user))
    }
}
