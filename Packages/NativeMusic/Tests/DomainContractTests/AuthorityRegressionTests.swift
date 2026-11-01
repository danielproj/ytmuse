import Domain
import Foundation
import Testing

@Suite("T02.3 Authority and terminal ordering") struct AuthorityRegressionTests {
    @Test func delayedCurrentContextRevocationStillStopsPlayback() throws {
        var m = PlaybackMachine(request: request(try account()))
        m.select(try sid(), occurrence: UUID(), now: .zero)
        m.receive(.resolved, context: m.context, now: .zero)
        m.receive(.prepared, context: m.context, now: .zero)
        m.receive(.started, context: m.context, now: .zero)
        let current = m.context
        // A newer position observation is not renewed source permission.
        m.receive(.receiverPosition(20), context: current, now: .seconds(20))
        let effects = m.receive(.entitlementRevoked, context: current, now: .seconds(10))
        #expect(effects.contains(.stop))
        #expect(m.state == .failed && m.error == .forbidden)
        #expect(m.intent == .pause(.entitlementRevoked))
        #expect(m.context.generation > current.generation)
        #expect(m.position == 20 && m.anchor == .seconds(20))
        #expect(m.snapshot.position(at: .seconds(100)) == 20)
        #expect(m.receive(.started, context: current, now: .seconds(30)).isEmpty)
    }
    @Test func revocationFromAnOldPlaybackContextStaysIgnored() throws {
        var m = PlaybackMachine(request: request(try account()))
        m.select(try sid("first"), occurrence: UUID(), now: .zero)
        let old = m.context
        m.select(try sid("second"), occurrence: UUID(), now: .seconds(1))
        #expect(m.receive(.entitlementRevoked, context: old, now: .seconds(20)).isEmpty)
        #expect(m.state == .resolving && m.error == nil)
    }

    func playing() throws -> PlaybackMachine {
        var m = PlaybackMachine(request: request(try account()))
        m.select(try sid(), occurrence: UUID(), now: .zero)
        m.receive(.resolved, context: m.context, now: .zero)
        m.receive(.prepared, context: m.context, now: .zero)
        m.receive(.started, context: m.context, now: .zero)
        m.receive(.receiverPosition(20), context: m.context, now: .seconds(20))
        return m
    }
    @Test func oldAccountItemAndRouteAuthorityCannotAffectCurrentSession() throws {
        let events: [PlaybackEvent] = [.entitlementRevoked, .failed(.expiredMedia), .ended]
        for event in events {
            for change in 0..<3 {
                var m = try playing(); let old = m.context
                switch change {
                case 0: _ = m.switchAccount(request(try account(), generation: 2), now: .seconds(30))
                case 1: m.select(try sid("new-item"), occurrence: UUID(), now: .seconds(30))
                default: _ = m.changeRoute(try RouteID("new-route"), now: .seconds(30))
                }
                let before = m.snapshot
                for capture in [Duration.seconds(10), .seconds(40)] {
                    #expect(m.receive(event, context: old, now: capture).isEmpty)
                    #expect(m.context == before.context && m.state == before.state && m.intent == before.intent)
                    #expect(m.position == before.position && m.anchor == before.monotonicAnchor && m.error == before.error)
                }
            }
        }
    }
    @Test func delayedCurrentFailureAndEndTerminateWithoutRegressingTimeline() throws {
        for event in [PlaybackEvent.failed(.expiredMedia), .ended] {
            var m = try playing(); let current = m.context
            let effects = m.receive(event, context: current, now: .seconds(10))
            #expect(effects.contains(.stop))
            #expect(m.position == 20 && m.anchor == .seconds(20))
            #expect(m.snapshot.position(at: .seconds(100)) == 20)
            switch event {
            case .failed:
                #expect(m.state == .failed && m.error == .expiredMedia)
                #expect(!effects.contains(.advance))
            case .ended:
                #expect(m.state == .ended && effects.filter { $0 == .advance }.count == 1)
                #expect(m.receive(.ended, context: current, now: .seconds(5)).isEmpty)
            default: Issue.record("Unexpected test event")
            }
            #expect(m.receive(.receiverPosition(999), context: current, now: .seconds(30)).isEmpty)
            #expect(m.receive(.started, context: current, now: .seconds(30)).isEmpty)
            #expect(m.receive(.networkRecovered, context: current, now: .seconds(30)).isEmpty)
        }
    }
    @Test func lifecycleCompletionsUseRevisionAndStateRatherThanObservationAge() throws {
        var m = PlaybackMachine(request: request(try account()))
        m.select(try sid(), occurrence: UUID(), now: .zero)
        _ = try m.seek(40, now: .seconds(20))
        _ = m.pause(.user, now: .seconds(20))
        m.receive(.resolved, context: m.context, now: .seconds(5))
        #expect(m.state == .preparing)
        #expect(m.receive(.prepared, context: m.context, now: .seconds(10)) == [.seek(40, revision: 1)])
        #expect(m.state == .seeking)
        #expect(m.receive(.seekCompleted(revision: 0), context: m.context, now: .seconds(30)).isEmpty)
        #expect(m.state == .seeking)
        #expect(m.receive(.seekCompleted(revision: 1), context: m.context, now: .seconds(15)).isEmpty)
        #expect(m.state == .paused && m.intent == .pause(.user))
        #expect(m.position == 40 && m.anchor == .seconds(20))
        #expect(m.receive(.started, context: m.context, now: .seconds(10)).isEmpty)
        #expect(m.state == .paused)
    }
    @Test func commandRevocationStopsEngineAndSupersedesPendingPlay() async throws {
        let a = try account(); let ctx = request(a); let clock = ManualMonotonic(); let engine = TestEngine()
        let caps = SuspendedCapabilities(account: a)
        let player = PlaybackCommands(request: ctx, engine: engine, resolver: TestProvider(account: a), capabilities: caps, wall: FixedWall(date: testWall), monotonic: clock, lifecycle: TestLifecycle())
        _ = await player.execute(.select(media: try sid(), occurrence: UUID()), context: ctx, origin: .userInterface)
        let old = await player.snapshot().context
        clock.advance(to: .seconds(20))
        await player.receive(.init(context: old, event: .position(20), observedAt: .seconds(20)))
        _ = await player.execute(.pause(.user), context: ctx, origin: .mediaKey)
        await caps.holdNext()
        let pending = Task { await player.execute(.play, context: ctx, origin: .mediaKey) }
        await caps.waitUntilHeld()
        let before = await engine.recorded()
        clock.advance(to: .seconds(30))
        await player.receive(.init(context: old, event: .entitlementRevoked, observedAt: .seconds(10)))
        let revoked = await player.snapshot()
        #expect(revoked.state == .failed && revoked.error == .forbidden && revoked.intent == .pause(.entitlementRevoked))
        #expect(revoked.context.generation > old.generation)
        #expect(revoked.position == 20 && revoked.monotonicAnchor == .seconds(30))
        #expect(await engine.recorded().count == before.count + 1)
        #expect(await engine.recorded().last == "stop")
        await caps.release()
        let stale = await pending.value
        #expect(throws: DomainError.staleContext) { try stale.outcome.get() }
        #expect(await player.snapshot().intent == .pause(.entitlementRevoked))
        // An old-context authority event cannot stop a new selected item.
        _ = await player.execute(.select(media: try sid("new-item"), occurrence: UUID()), context: ctx, origin: .userInterface)
        let newState = await player.snapshot(); let count = await engine.recorded().count
        await player.receive(.init(context: old, event: .entitlementRevoked, observedAt: .seconds(40)))
        #expect(await player.snapshot().context == newState.context)
        #expect(await player.snapshot().state == .playing)
        #expect(await engine.recorded().count == count)
    }
    @Test func delayedAuthorityAndEndUseReceiptTimeAtCommandBoundary() async throws {
        for event in [EngineEvent.entitlementRevoked, .failed(.expiredMedia), .ended] {
            let ctx = request(try account()); let clock = ManualMonotonic(); let engine = TestEngine(); let sink = TestLifecycle()
            let provider = TestProvider(account: ctx.account!)
            let player = PlaybackCommands(request: ctx, engine: engine, resolver: provider, capabilities: provider, wall: FixedWall(date: testWall), monotonic: clock, lifecycle: sink)
            _ = await player.execute(.select(media: try sid(), occurrence: UUID()), context: ctx, origin: .userInterface)
            let token = await player.snapshot().context
            clock.advance(to: .seconds(20))
            await player.receive(.init(context: token, event: .position(20), observedAt: .seconds(20)))
            clock.advance(to: .seconds(30))
            let sampledBeforeDelivery = await player.snapshot().position(at: clock.now())
            await player.receive(.init(context: token, event: event, observedAt: .seconds(10)))
            let after = await player.snapshot()
            #expect(after.position == sampledBeforeDelivery && after.position == 30)
            #expect(after.monotonicAnchor == .seconds(30))
            #expect(await engine.recorded().last == "stop")
            switch event {
            case .entitlementRevoked:
                #expect(after.state == .failed && after.error == .forbidden)
                #expect(after.intent == .pause(.entitlementRevoked) && after.context.generation > token.generation)
            case .failed: #expect(after.state == .failed && after.error == .expiredMedia)
            case .ended:
                #expect(after.state == .ended)
                #expect(await sink.advances == 1)
                await player.receive(.init(context: token, event: .ended, observedAt: .seconds(5)))
                #expect(await sink.advances == 1)
            default: Issue.record("Unexpected test event")
            }
        }
    }
    @Test func seededAuthorityEventsCannotBeSuppressedByNewerPositions() throws {
        var probes = 0
        for seed in try FixtureManifest.load().seeds {
            var rng = SeededGenerator(seed: seed)
            for step in 0..<64 {
                let latest = Int(rng.next() % 1000 + 1)
                let captured = Int(rng.next() % UInt64(latest))
                for event in [PlaybackEvent.entitlementRevoked, .failed(.expiredMedia), .ended] {
                    var m = try playing(); let context = m.context
                    let instant = Duration.seconds(latest + 20)
                    let position = Double(rng.next() % 10000)
                    m.receive(.receiverPosition(position), context: context, now: instant)
                    let effects = m.receive(event, context: context, now: .seconds(captured))
                    #expect(effects.contains(.stop), "seed=\(seed), step=\(step)")
                    #expect(m.position == position && m.anchor == instant, "seed=\(seed), step=\(step)")
                    switch event {
                    case .entitlementRevoked: #expect(m.context.generation > context.generation && m.error == .forbidden)
                    case .failed: #expect(m.state == .failed && m.error == .expiredMedia)
                    case .ended: #expect(m.state == .ended && effects.contains(.advance))
                    default: Issue.record("Unexpected authority test event")
                    }
                    probes += 1
                }
            }
        }
        #expect(probes == 1152)
        print("W02 authority properties: seeds=6, older authority/terminal probes=\(probes)")
    }
}
