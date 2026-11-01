import Domain
import Features
import Foundation
import Testing

@Suite("T02.2 Generation isolation") struct GenerationTests {
    @MainActor @Test func featureRejectsOldQueryAccountChannelRegionAndError() throws {
        let a = try account(); let state = FeatureState<String>(account: a)
        let old = state.begin(); let current = state.begin()
        #expect(!state.receive(.init(context: old, outcome: .success("obsolete"))))
        #expect(state.receive(.init(context: current, outcome: .success("current"))))
        #expect(state.value == "current")
        for changed in [try account(), try account(a.accountID, channel: "other-channel"), try account(a.accountID, region: "GE")] {
            state.switchAccount(changed); _ = state.begin()
            #expect(!state.receive(.init(context: current, outcome: .failure(.unauthorized))))
            #expect(state.value == nil && state.error == nil && state.isLoading)
        }
    }
    @Test func oldPreparationSeekReceiverCommandAndEndCannotMutate() throws {
        var machine = PlaybackMachine(request: request(try account()))
        machine.select(try sid("first"), occurrence: UUID(), now: .zero)
        let old = machine.context
        machine.select(try sid("second"), occurrence: UUID(), now: .seconds(1))
        let current = machine.context
        for event in [.resolved, .prepared, .started, .seekCompleted(revision: 1), .receiverPosition(99), .ended, .failed(.offline)] as [PlaybackEvent] {
            #expect(machine.receive(event, context: old, now: .seconds(5)).isEmpty)
            #expect(machine.state == .resolving && machine.context == current && machine.position == 0)
        }
        _ = machine.changeRoute(try RouteID("test-route"), now: .seconds(6))
        #expect(machine.context.generation > current.generation)
        #expect(machine.receive(.prepared, context: current, now: .seconds(7)).isEmpty)
        let routeContext = machine.context
        _ = machine.switchAccount(request(try account(), generation: 2), now: .seconds(8))
        #expect(machine.receive(.started, context: routeContext, now: .seconds(9)).isEmpty)
        #expect(machine.item == nil && machine.intent == .pause(.accountSwitch))
    }
    @Test func delayedActorPreparationAfterAccountSwitchDoesNotPlay() async throws {
        let context = request(try account()); let engine = TestEngine(); await engine.hold()
        let useCases = try commands(context, engine: engine)
        let task = Task { await useCases.execute(.select(media: try sid(), occurrence: UUID()), context: context, origin: .userInterface) }
        for _ in 0..<10_000 { if await engine.waiting() { break }; await Task.yield() }
        #expect(await engine.waiting())
        let next = request(try account(), generation: 2)
        await useCases.switchAccount(next)
        await engine.release()
        let response = try await task.value
        #expect(throws: DomainError.staleContext) { try response.outcome.get() }
        #expect(await useCases.snapshot().context.request == next)
        #expect(await useCases.snapshot().state == .idle)
        #expect(!(await engine.recorded()).contains("play"))
        let stale = await useCases.execute(.play, context: context, origin: .widget)
        #expect(throws: DomainError.staleContext) { try stale.outcome.get() }
    }
    @Test func cursorsRemainScopedAndExpire() throws {
        let a = try account(); let context = request(a); let collection = try sid("collection")
        let cursor = PageCursor(reference: try ID("test-cursor-reference"), context: context, collection: collection, expiresAt: testWall.addingTimeInterval(1))
        try cursor.validate(for: context, collection: collection, now: testWall)
        #expect(throws: DomainError.staleContext) { try cursor.validate(for: request(a, query: 2), collection: collection, now: testWall) }
        #expect(throws: DomainError.staleContext) { try cursor.validate(for: context, collection: sid("other"), now: testWall) }
        #expect(throws: DomainError.expiredMedia) { try cursor.validate(for: context, collection: collection, now: testWall.addingTimeInterval(1)) }
    }
}

@Suite("T02.2 Account ownership ordering") struct AccountOwnershipTests {
    @Test func anOlderSwitchCannotRestoreCommandOwnership() async throws {
        let original = request(try account()); let engine = TestEngine(); let useCases = try commands(original, engine: engine)
        let newer = request(try account(), generation: 3)
        await useCases.switchAccount(newer)
        await useCases.switchAccount(request(try account(), generation: 2))
        #expect(await useCases.snapshot().context.request == newer)
        let stale = await useCases.execute(.select(media: try sid(), occurrence: UUID()), context: original, origin: .link)
        #expect(throws: DomainError.staleContext) { try stale.outcome.get() }
        #expect(!(await engine.recorded()).contains("prepare"))
    }
    @Test func allTypedErrorsKeepRequestScope() throws {
        let context = request(try account())
        let errors: [DomainError] = [.unauthorized, .forbidden, .unsupported, .unavailableContent, .regionRestricted, .rateLimited(retryAfter: testWall), .offline, .malformedResponse, .expiredMedia, .transientTransport]
        for error in errors {
            let result = ServiceResult<String>(context: context, outcome: .failure(error))
            #expect(result.context == context)
            #expect(throws: error) { try result.outcome.get() }
        }
    }
}
