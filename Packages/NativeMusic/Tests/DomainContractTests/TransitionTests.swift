import Domain
import Foundation
import Testing

@Suite("T02.3 Intent and transitions") struct TransitionTests {
    func ready() throws -> PlaybackMachine {
        var m = PlaybackMachine(request: request(try account()))
        m.select(try sid(), occurrence: UUID(), now: .zero)
        m.receive(.resolved, context: m.context, now: .zero)
        m.receive(.prepared, context: m.context, now: .zero)
        return m
    }
    @Test func pauseDuringPrepareAndLatestSeekWin() throws {
        var m = PlaybackMachine(request: request(try account()))
        m.select(try sid(), occurrence: UUID(), now: .zero)
        #expect(try m.seek(10, now: .zero).isEmpty)
        #expect(try m.seek(25, now: .zero).isEmpty)
        m.receive(.resolved, context: m.context, now: .zero)
        _ = m.pause(.user, now: .zero)
        #expect(m.receive(.prepared, context: m.context, now: .zero) == [.seek(25, revision: 2)])
        #expect(m.receive(.seekCompleted(revision: 1), context: m.context, now: .zero).isEmpty)
        #expect(m.state == .seeking)
        #expect(m.receive(.seekCompleted(revision: 2), context: m.context, now: .zero).isEmpty)
        #expect(m.state == .paused && m.position == 25 && m.intent == .pause(.user))
        #expect(m.receive(.started, context: m.context, now: .zero) == [.pause])
        #expect(m.state == .paused)
    }
    @Test func delayedActorPreparationHonorsPauseAndSeek() async throws {
        let context = request(try account()); let engine = TestEngine(); await engine.hold()
        let useCases = try commands(context, engine: engine)
        let start = Task { await useCases.execute(.select(media: try sid(), occurrence: UUID()), context: context, origin: .siri) }
        for _ in 0..<10_000 { if await engine.waiting() { break }; await Task.yield() }
        #expect(await engine.waiting())
        _ = await useCases.execute(.seek(17), context: context, origin: .shortcut)
        _ = await useCases.execute(.pause(.user), context: context, origin: .mediaKey)
        await engine.release(); _ = try await start.value
        let calls = await engine.recorded()
        #expect(calls.contains("seek:17.0") && !calls.contains("play"))
        #expect(await useCases.snapshot().state == .paused)
        #expect(await useCases.snapshot().pauseReason == .user)
    }
    @Test func endAdvancesOnceAndExpiryRefreshesOnce() throws {
        var m = try ready()
        #expect(m.receive(.ended, context: m.context, now: .zero).filter { $0 == .advance }.count == 1)
        #expect(m.receive(.ended, context: m.context, now: .zero).isEmpty)
        #expect(m.expire() == [.refreshAuthorization])
        #expect(m.expire() == [.stop])
        #expect(m.error == .expiredMedia)
    }
    @Test func networkRouteSleepQuitAndRevocationHaveExplicitOutcomes() throws {
        var m = try ready(); let token = m.context
        m.receive(.started, context: token, now: .zero)
        m.receive(.buffering, context: token, now: .seconds(4))
        #expect(m.state == .buffering && m.position == 4)
        #expect(m.receive(.networkRecovered, context: token, now: .seconds(5)) == [.play])
        _ = m.pause(.user, now: .seconds(5))
        #expect(m.receive(.networkRecovered, context: token, now: .seconds(6)).isEmpty)
        _ = m.resume(); m.receive(.started, context: token, now: .seconds(7))
        _ = m.sleep(now: .seconds(8))
        #expect(m.wake(safeRoute: true, resumeEnabled: true) == [.play])
        _ = m.sleep(now: .seconds(9)); _ = m.pause(.user, now: .seconds(10))
        #expect(m.wake(safeRoute: true, resumeEnabled: true).isEmpty)
        _ = m.changeRoute(try RouteID("headphones-disconnected"), now: .seconds(11))
        #expect(m.intent == .pause(.routeLoss))
        #expect(m.wake(safeRoute: true, resumeEnabled: true).isEmpty)
        #expect(m.receive(.started, context: token, now: .seconds(12)).isEmpty)
        let route = m.context
        #expect(m.receive(.entitlementRevoked, context: route, now: .seconds(13)).contains(.stop))
        #expect(m.error == .forbidden && m.intent == .pause(.entitlementRevoked))
        #expect(m.receive(.started, context: route, now: .seconds(14)).isEmpty)
        let beforeQuit = m.context
        #expect(m.quit(now: .seconds(15)).contains(.checkpoint))
        #expect(m.state == .idle && m.intent == .pause(.quit))
        #expect(m.receive(.started, context: beforeQuit, now: .seconds(16)).isEmpty)
    }
    @Test func monotonicTimelineAndWallJumpsDoNotExtendRights() throws {
        var m = try ready(); m.receive(.started, context: m.context, now: .seconds(10))
        #expect(m.snapshot.position(at: .seconds(15)) == 5)
        #expect(m.snapshot.position(at: .seconds(5)) == 0)
        try m.setRate(2, now: .seconds(15))
        #expect(m.snapshot.position(at: .seconds(18)) == 11)
        _ = m.pause(.user, now: .seconds(18))
        #expect(m.snapshot.position(at: .seconds(1000)) == 11)
        let a = try account()
        let entitlement = try OfflineEntitlement(account: a, media: sid(), source: "Synthetic grant", rights: [.play], expiresAt: testWall.addingTimeInterval(10), renewAfter: nil, lastValidatedAt: testWall, validation: .available)
        #expect(entitlement.permits(.play, context: a, now: testWall.addingTimeInterval(9)))
        #expect(!entitlement.permits(.play, context: a, now: testWall.addingTimeInterval(10)))
        #expect(!entitlement.permits(.play, context: a, now: testWall.addingTimeInterval(-100)))
        #expect(!entitlement.permits(.seek, context: a, now: testWall))
        let lease = try EntitlementLease(entitlement: entitlement, validatedAt: testWall, monotonic: .seconds(100))
        #expect(lease.permits(.play, context: a, wall: testWall.addingTimeInterval(9), monotonic: .seconds(109)))
        // Wall time is still inside its valid interval, but elapsed time has exhausted the grant.
        #expect(!lease.permits(.play, context: a, wall: testWall.addingTimeInterval(1), monotonic: .seconds(111)))
        #expect(!lease.permits(.play, context: a, wall: testWall.addingTimeInterval(-1), monotonic: .seconds(101)))
        #expect(m.snapshot.position(at: .seconds(1000)) == 11)
    }
    @Test func seededPropertiesReproduceStaleEventIsolationAndPauseSafety() throws {
        let seeds = try FixtureManifest.load().seeds
        var staleProbes = 0; var pausedCompletions = 0; var endProbes = 0
        for seed in seeds {
            var rng = SeededGenerator(seed: seed)
            var m = PlaybackMachine(request: request(try account(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)))
            for step in 0..<256 {
                let old = m.context
                m.select(try sid("media-\(rng.next() % 8)"), occurrence: seededUUID(&rng), now: .seconds(step))
                let token = m.context
                let target = Double(rng.next() % 10_000)
                _ = try m.seek(target, now: .seconds(step))
                let paused = rng.next() % 2 == 0
                if paused { _ = m.pause(.user, now: .seconds(step)) }
                let events: [PlaybackEvent] = [.prepared, .started, .ended, .receiverPosition(99999), .failed(.offline)]
                let before = m.snapshot
                for event in events {
                    #expect(m.receive(event, context: old, now: .seconds(step + 1)).isEmpty, "seed=\(seed), step=\(step)")
                    #expect(m.state == before.state && m.position == before.position && m.context == token)
                    staleProbes += 1
                }
                m.receive(.resolved, context: token, now: .seconds(step))
                #expect(m.receive(.prepared, context: token, now: .seconds(step)) == [.seek(target, revision: m.seekRevision)])
                let effects = m.receive(.seekCompleted(revision: m.seekRevision), context: token, now: .seconds(step))
                #expect(effects.contains(.play) == !paused, "seed=\(seed), step=\(step)")
                if paused { #expect(m.state == .paused); pausedCompletions += 1 }
                #expect(m.receive(.ended, context: token, now: .seconds(step)).contains(.advance))
                #expect(m.receive(.ended, context: token, now: .seconds(step)).isEmpty); endProbes += 1
            }
        }
        #expect(staleProbes == 7680 && pausedCompletions > 500 && endProbes == 1536)
        print("W02 property evidence: seeds=\(seeds), scenarios=1536, stale-event probes=\(staleProbes), paused completions=\(pausedCompletions), duplicate-end probes=\(endProbes)")
    }
}
