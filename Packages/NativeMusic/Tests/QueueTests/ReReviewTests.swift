import Foundation
import Testing
import Domain
import Persistence
@testable import Queue

@Suite struct QueuePassiveTransportTests {
    /// Real command owner, actual forwarding boundary and actual lifecycle sink;
    /// only media resolution/engine behavior is synthetic. No system sleep/audio claim.
    @Test(arguments: ["sleep-wake", "pause-play"]) func R21PassiveResumeKeepsBindingAndEndAdvancesOnce(path: String) async throws {
        let context = try request(); let engine = QueueHeldEngine(holdFirstPlay: false)
        let (owner, domain, boundary, lifecycle) = try await composedQueue(make(["a", "b", "c"]), persistence: MemoryPersistence(), engine: engine)
        _ = try await owner.execute(.resume, context: context, origin: .menu)
        let initial = try await owner.snapshot(); let originalContext = await domain.snapshot().context
        if path == "sleep-wake" {
            _ = try await domain.execute(.sleep, context: context, origin: .menu).outcome.get()
        } else { _ = try await domain.execute(.pause(.user), context: context, origin: .mediaKey).outcome.get() }
        let paused = try await owner.snapshot()
        #expect(paused.intent == .pause(path == "sleep-wake" ? .sleep : .user))
        #expect(paused.playbackToken == initial.playbackToken)
        #expect(await boundary.token(for: originalContext) == paused.playbackToken)
        if path == "sleep-wake" {
            _ = try await domain.execute(.wake(safeRoute: true, resumeEnabled: true), context: context, origin: .menu).outcome.get()
        } else { _ = try await domain.execute(.play, context: context, origin: .mediaKey).outcome.get() }
        let resumed = try await owner.snapshot()
        #expect(resumed.intent == .play && resumed.playbackToken == initial.playbackToken)
        #expect(await domain.snapshot().context == originalContext)
        await domain.receive(ScopedEngineEvent(context: originalContext, event: .ended))
        let next = try await owner.snapshot(); let newContext = await domain.snapshot().context
        #expect(next.current?.media.rawValue == "b" && next.playbackToken != initial.playbackToken)
        #expect(newContext.occurrenceID == next.session.currentOccurrence && newContext.generation > originalContext.generation)
        #expect(await boundary.token(for: newContext) == next.playbackToken)
        #expect(await engine.plays.count == 3)
        // Same old engine end and old queue token cannot consume b or schedule c.
        await domain.receive(ScopedEngineEvent(context: originalContext, event: .ended))
        _ = try await owner.execute(.ended(initial.playbackToken), context: context, origin: .menu)
        #expect(try await owner.snapshot().session.currentOccurrence == next.session.currentOccurrence)
        #expect(try await owner.snapshot().session.version == next.session.version)
        #expect(await engine.plays.count == 3)
        #expect(await lifecycle.error == nil)
    }
    @Test(arguments: ["item", "route", "account", "queue-pause"]) func R21GenuineInvalidationStillRejectsOldCompletion(kind: String) async throws {
        let context = try request(); let engine = QueueHeldEngine(holdFirstPlay: false)
        let (owner, domain, boundary, lifecycle) = try await composedQueue(make(["a", "b", "c"]), persistence: MemoryPersistence(), engine: engine)
        _ = try await owner.execute(.resume, context: context, origin: .menu)
        let initial = try await owner.snapshot(); let oldContext = await domain.snapshot().context
        switch kind {
        case "item": _ = try await owner.execute(.select(initial.session.entries[1].id), context: context, origin: .menu)
        case "route": _ = try await domain.execute(.route(ID("owned-route")), context: context, origin: .menu).outcome.get()
        case "account":
            await lifecycle.detach(reason: .accountSwitch)
            await domain.switchAccount(RequestContext(account: nil, accountGeneration: context.accountGeneration + 1, requestGeneration: 0))
        default: _ = try await owner.execute(.pause(.user), context: context, origin: .menu)
        }
        let barrier = try await owner.snapshot()
        #expect(barrier.playbackToken != initial.playbackToken)
        #expect(await boundary.token(for: oldContext) == nil)
        await domain.receive(ScopedEngineEvent(context: oldContext, event: .ended))
        _ = try await owner.execute(.ended(initial.playbackToken), context: context, origin: .menu)
        let after = try await owner.snapshot()
        #expect(after.session.currentOccurrence == barrier.session.currentOccurrence && after.intent == barrier.intent)
        if kind == "route" {
            _ = try await owner.execute(.resume, context: context, origin: .menu)
            let rebound = await domain.snapshot().context
            #expect(rebound.generation > oldContext.generation)
            await domain.receive(ScopedEngineEvent(context: rebound, event: .ended))
            #expect(try await owner.snapshot().current?.media.rawValue == "b")
        }
    }
}

@Suite struct QueueSharedProvenanceTests {
    @Test(arguments: [(50, 1000), (12, 4096), (25, 300), (1000, 4096)]) func R22SharedCursorStoredOnceAndReloaded(batch: Int, cursorLength: Int) async throws {
        let context = try request(); let (store, directory) = try await queueSQLite("queue-intern-", context: context)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SQLiteQueuePersistence(store: store)
        let owner = try QueueCommands(machine: make(["seed"]), context: context, persistence: persistence, playback: RecordingPlayback(), repeatSupported: true)
        let source = RecommendationContext(source: "owned-radio", cursor: String(repeating: "c", count: cursorLength))
        let appended = try await owner.execute(.recommendations(ids((0..<batch).map { "r\($0)" }), source), context: context, origin: .menu)
        let raw = try #require(await store.restoredQueue(context: context))
        let envelope = try #require(raw.continuation.cursor)
        #expect(envelope.hasPrefix("local-queue-v2:") && envelope.utf8.count <= 65536)
        let data = try #require(Data(base64Encoded: String(envelope.dropFirst("local-queue-v2:".count))))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((payload["groups"] as? [Any])?.count == 1)
        await store.close()
        let reopened = try SQLiteStore(directory: directory, context: context)
        let recovered = try #require(await SQLiteQueuePersistence(store: reopened).load(context: context))
        #expect(recovered.session.entries.map(\.id) == appended.session.entries.map(\.id))
        #expect(recovered.metadata.recommendationSources == appended.metadata.recommendationSources)
        #expect(recovered.metadata.recommendationSources.count == batch)
        #expect(recovered.metadata.recommendationSources.values.allSatisfy { $0 == source })
        print("W05 R2 shared-provenance batch=\(batch) cursor=\(cursorLength) envelope=\(envelope.utf8.count)")
        await reopened.close()
    }
    @Test func R22DistinctContextsAndExplicitTotalBounds() async throws {
        let context = try request(); let (store, directory) = try await queueSQLite("queue-intern-bounds-", context: context)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SQLiteQueuePersistence(store: store)
        let owner = try QueueCommands(machine: make(["seed"]), context: context, persistence: persistence, playback: RecordingPlayback(), repeatSupported: true)
        let sources = [RecommendationContext(source: "radio", cursor: nil), .init(source: "radio", cursor: ""), .init(source: "another-radio", cursor: "page")]
        for (i, source) in sources.enumerated() { _ = try await owner.execute(.recommendations(ids(["r\(i)"]), source), context: context, origin: .menu) }
        let before = try await owner.snapshot()
        let decoded = try #require(await persistence.load(context: context))
        #expect(decoded.metadata.recommendationSources == before.metadata.recommendationSources)
        #expect(Set(decoded.metadata.recommendationSources.values).count == 3)
        await #expect(throws: QueueError.invalidState) {
            try await owner.execute(.recommendations(ids((0..<1001).map { "too-many-\($0)" }), .init(source: "radio")), context: context, origin: .menu)
        }
        #expect(try await owner.snapshot().session.version == before.session.version)
        // Distinct 4096-byte contexts still obey the total checkpoint bound. A failed
        // candidate leaves the preceding queue/provenance available for ordinary edits.
        var rejected = false
        for i in 0..<20 {
            let prior = try await owner.snapshot()
            do { _ = try await owner.execute(.recommendations(ids(["large-\(i)"]), .init(source: "radio-\(i)", cursor: String(repeating: "x", count: 4096))), context: context, origin: .menu) }
            catch QueueError.invalidState {
                #expect(try await owner.snapshot().session.version == prior.session.version)
                #expect(try await persistence.load(context: context)?.metadata.recommendationSources == prior.metadata.recommendationSources)
                rejected = true; break
            }
        }
        #expect(rejected)
        _ = try await owner.execute(.autoplay(false), context: context, origin: .menu)
        #expect(try await owner.snapshot().metadata.recommendationSources.isEmpty)
        await store.close()
    }
}

@Suite struct QueueAdmissionAndDelayedCheckpointTests {
    @Test func R23DelayedCheckpointCannotModifyNewCurrent() async throws {
        let context = try request(); let owner = try commands(make(["a", "b", "c"]))
        let old = try await owner.execute(.resume, context: context, origin: .menu)
        _ = try await owner.execute(.select(old.session.entries[1].id), context: context, origin: .menu)
        let current = try await owner.execute(.checkpoint(27.5), context: context, origin: .menu)
        _ = try await owner.execute(.checkpointFor(old.playbackToken, position: 999, pause: nil), context: context, origin: .menu)
        _ = try await owner.execute(.checkpointFor(old.playbackToken, position: 777, pause: .sleep), context: context, origin: .menu)
        let after = try await owner.snapshot()
        #expect(after.session.currentOccurrence == current.session.currentOccurrence)
        #expect(after.session.position == 27.5 && after.intent == .play)
        #expect(after.session.version == current.session.version)
        #expect(after.playbackToken == current.playbackToken)
    }
    @Test func R24CommittedSourceVersionAndTokenAdmissionIsDeterministic() async throws {
        let context = try request(); let engine = QueueHeldEngine(holdFirstPlay: false)
        let (_, domain, boundary, _) = try await composedQueue(make(["a", "b"]), persistence: MemoryPersistence(), engine: engine)
        var q = try make(["a", "b"]); try q.resume(); try q.bumpVersion()
        let older = try q.snapshot
        try q.select(q.entries[1].id); try q.bumpVersion()
        let newer = try q.snapshot
        // Deliberately deliver source commits out of order, without a probabilistic race.
        try await boundary.start(newer, context: context, origin: .menu)
        let admitted = await domain.snapshot().context
        await #expect(throws: QueueError.staleContext) { try await boundary.start(older, context: context, origin: .menu) }
        #expect(await domain.snapshot().context == admitted)
        #expect(await boundary.token(for: admitted) == newer.playbackToken)
        #expect(await engine.plays.count == 1)
        // Equal source version with another token is not a second admission either.
        var sameVersion = q; try sameVersion.resume()
        await #expect(throws: QueueError.staleContext) { try await boundary.start(sameVersion.snapshot, context: context, origin: .menu) }
        q.pause(.user); try q.bumpVersion()
        try await boundary.pause(.user, snapshot: q.snapshot, context: context, origin: .menu)
        await #expect(throws: QueueError.staleContext) { try await boundary.start(newer, context: context, origin: .menu) }
        #expect(await boundary.token(for: admitted) == nil)
        #expect(await engine.plays.count == 1)
    }
}

@Suite struct QueueResumeAcknowledgementTests {
    @Test func R21EndDuringWakeAcknowledgementStillAdvancesOnce() async throws {
        let context = try request(); let engine = QueueHeldEngine(holdFirstPlay: false)
        let (owner, domain, boundary, lifecycle) = try await composedQueue(make(["a", "b", "c"]), persistence: MemoryPersistence(), engine: engine)
        _ = try await owner.execute(.resume, context: context, origin: .menu)
        let oldContext = await domain.snapshot().context
        _ = try await domain.execute(.sleep, context: context, origin: .menu).outcome.get()
        await engine.holdNextPlay()
        let wake = Task { await domain.execute(.wake(safeRoute: true, resumeEnabled: true), context: context, origin: .menu) }
        await engine.waitForPlay()
        #expect(try await owner.snapshot().intent == .pause(.sleep))
        #expect(await domain.snapshot().intent == .play)
        await domain.receive(ScopedEngineEvent(context: oldContext, event: .ended))
        let advanced = try await owner.snapshot()
        #expect(advanced.current?.media.rawValue == "b" && advanced.intent == .play)
        #expect(await boundary.token(for: await domain.snapshot().context) == advanced.playbackToken)
        await engine.releasePlay(); _ = await wake.value
        await domain.receive(ScopedEngineEvent(context: oldContext, event: .ended))
        #expect(try await owner.snapshot().session.currentOccurrence == advanced.session.currentOccurrence)
        #expect(await lifecycle.error == nil)
    }
}

@Suite struct QueuePassivePausedEndTests {
    @Test(arguments: ["sleep", "pause"]) func R21PausedWithoutResumeRejectsDelayedEnd(path: String) async throws {
        let context = try request(); let engine = QueueHeldEngine(holdFirstPlay: false)
        let (owner, domain, boundary, lifecycle) = try await composedQueue(make(["a", "b"]), persistence: MemoryPersistence(), engine: engine)
        _ = try await owner.execute(.resume, context: context, origin: .menu)
        let oldContext = await domain.snapshot().context
        if path == "sleep" { _ = try await domain.execute(.sleep, context: context, origin: .menu).outcome.get() }
        else { _ = try await domain.execute(.pause(.user), context: context, origin: .mediaKey).outcome.get() }
        let paused = try await owner.snapshot()
        #expect(await domain.snapshot().intent == paused.intent)
        #expect(paused.intent == .pause(path == "sleep" ? .sleep : .user))
        #expect(await boundary.token(for: oldContext) == paused.playbackToken)
        await domain.receive(ScopedEngineEvent(context: oldContext, event: .ended))
        await domain.receive(ScopedEngineEvent(context: oldContext, event: .ended))
        let after = try await owner.snapshot()
        #expect(after.current?.media.rawValue == "a" && after.intent == paused.intent)
        #expect(after.session.entries[0].consumed == false)
        #expect(after.session.entries[1].consumed == false)
        #expect(await domain.snapshot().intent == after.intent)
        #expect(await engine.plays.count == 1)
        #expect(await lifecycle.error == nil)
    }
}

@Suite struct W06QueueFollowupTests {
    @Test func L2StartedObservationPreservesUnrelatedUndo() async throws {
        let context = try request(); let engine = QueueHeldEngine()
        let (owner, _, _, _) = try await composedQueue(make(["a", "b"]), persistence: MemoryPersistence(), engine: engine)
        let starting = Task { try await owner.execute(.resume, context: context, origin: .menu) }
        await engine.waitForPlay()
        _ = try await owner.execute(.add(ids(["unrelated-edit"])), context: context, origin: .menu)
        #expect(await owner.canUndo())
        await engine.releasePlay(); _ = try await starting.value
        #expect(await owner.canUndo())
        _ = try await owner.execute(.undo, context: context, origin: .menu)
        #expect(try await owner.snapshot().session.entries.map(\.media.rawValue) == ["a", "b"])
    }
    @Test func L3DomainUserPauseAfterExhaustionCancelsLateRecommendations() async throws {
        let context = try request(); let engine = QueueHeldEngine(holdFirstPlay: false)
        let (owner, domain, _, _) = try await composedQueue(make(["a"]), persistence: MemoryPersistence(), engine: engine)
        _ = try await owner.execute(.resume, context: context, origin: .menu)
        let token = await domain.snapshot().context
        await domain.receive(.init(context: token, event: .ended))
        #expect(try await owner.snapshot().current == nil)
        _ = try await domain.execute(.pause(.user), context: context, origin: .menu).outcome.get()
        _ = try await owner.execute(.recommendations(ids(["late"]), RecommendationContext(source: "radio")), context: context, origin: .menu)
        #expect(try await owner.snapshot().current == nil)
        #expect(try await owner.snapshot().intent == .pause(.user))
        #expect(await engine.plays.count == 1)
        // Positive control: natural exhaustion with no intervening pause does continue.
        let (active, activeDomain, _, _) = try await composedQueue(make(["a"]), persistence: MemoryPersistence(), engine: QueueHeldEngine(holdFirstPlay: false))
        _ = try await active.execute(.resume, context: context, origin: .menu)
        await activeDomain.receive(.init(context: activeDomain.snapshot().context, event: .ended))
        _ = try await active.execute(.recommendations(ids(["late"]), RecommendationContext(source: "radio")), context: context, origin: .menu)
        #expect(try await active.snapshot().current?.media.rawValue == "late")
    }
}
