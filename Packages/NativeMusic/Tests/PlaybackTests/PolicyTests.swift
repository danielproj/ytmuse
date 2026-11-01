import Testing
import Foundation
import Synchronization
import Domain
import Queue
@testable import Playback

final class ManualWall: WallClock {
    private let date = Mutex(Date())
    func now() -> Date { date.withLock { $0 } }
    func advance(_ seconds: Double) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
actor CountingResolver: PlaybackResolver, CapabilityProvider {
    let provider: TestProvider
    var refreshes = 0
    var hold = false
    var waiting: CheckedContinuation<Void, Never>?
    init(account: AccountContext) { provider = TestProvider(account: account) }
    func capabilities(context: RequestContext) async -> ServiceResult<AccountCapabilities> { await provider.capabilities(context: context) }
    func resolve(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<[MediaVariant]> {
        if hold { await withCheckedContinuation { waiting = $0 } }
        return await provider.resolve(media, context: context)
    }
    func setHold() { hold = true }
    func isWaiting() -> Bool { waiting != nil }
    func release() { hold = false; waiting?.resume(); waiting = nil }
    func validateEligibility(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<Capability> { await provider.validateEligibility(media, context: context) }
    func refresh(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<MediaVariant> { refreshes += 1; return .init(context: context, outcome: .success(variant)) }
    func report(_ event: ServicePlaybackEvent, context: PlaybackContext) async -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
}
@Suite struct PlaybackPolicyTests {
    @Test func T063PreparationPauseAndStaleAccountCannotStart() async throws {
        let context = request(try account()); let engine = TestEngine(); await engine.hold()
        let commands = try commands(context, engine: engine)
        let selection = Task { await commands.execute(.select(media: try sid(), occurrence: UUID()), context: context, origin: .menu) }
        while !(await engine.waiting()) { await Task.yield() }
        _ = try await commands.execute(.pause(.user), context: context, origin: .menu).outcome.get()
        await engine.release(); _ = try await selection.value.outcome.get()
        #expect(await engine.recorded().filter { $0 == "play" }.isEmpty)
        #expect(await commands.snapshot().intent == .pause(.user))
        await commands.switchAccount(.init(account: nil, accountGeneration: 2, requestGeneration: 0))
        #expect(await commands.snapshot().state == .idle)
        if case .failure(.staleContext) = await commands.execute(.play, context: context, origin: .menu).outcome {} else { Issue.record("Old account accepted") }
    }
    @Test func T063BufferingPausePreventsRecovery() async throws {
        let context = request(try account()); let engine = TestEngine(); let commands = try commands(context, engine: engine)
        _ = try await commands.execute(.select(media: try sid(), occurrence: UUID()), context: context, origin: .menu).outcome.get()
        let token = await commands.snapshot().context
        await commands.receive(.init(context: token, event: .buffering))
        _ = try await commands.execute(.pause(.user), context: context, origin: .menu).outcome.get()
        await commands.receive(.init(context: token, event: .started))
        #expect(await commands.snapshot().intent == .pause(.user))
        #expect(await engine.recorded().filter { $0 == "play" }.count == 1)
    }
    @Test func T065AuthorizationRefreshOnceThenTypedFailure() async throws {
        let context = request(try account()); let engine = TestEngine(); let provider = CountingResolver(account: context.account!)
        let commands = PlaybackCommands(request: context, engine: engine, resolver: provider, capabilities: provider, wall: FixedWall(date: testWall), monotonic: FixedMonotonic(), lifecycle: TestLifecycle())
        _ = try await commands.execute(.select(media: try sid(), occurrence: UUID()), context: context, origin: .menu).outcome.get()
        _ = try await commands.execute(.seek(7), context: context, origin: .menu).outcome.get()
        let token = await commands.snapshot().context
        await commands.receive(.init(context: token, event: .failed(.unauthorized)))
        #expect(await provider.refreshes == 1)
        #expect(await engine.recorded().contains("seek:7.0"))
        await commands.receive(.init(context: token, event: .failed(.unauthorized)))
        #expect(await provider.refreshes == 1)
        #expect(await commands.snapshot().error == .unauthorized)
        #expect(await commands.snapshot().state == .failed)
    }
    @Test func T065SeekWhileResolvingRetainsOnlyFinalTarget() async throws {
        let context = request(try account()); let engine = TestEngine(); let provider = CountingResolver(account: context.account!)
        await provider.setHold()
        let commands = PlaybackCommands(request: context, engine: engine, resolver: provider, capabilities: provider, wall: FixedWall(date: testWall), monotonic: FixedMonotonic(), lifecycle: TestLifecycle())
        let selecting = Task { await commands.execute(.select(media: try sid(), occurrence: UUID()), context: context, origin: .menu) }
        while !(await provider.isWaiting()) { await Task.yield() }
        for value in [2.0, 4, 8] { _ = try await commands.execute(.seek(value), context: context, origin: .menu).outcome.get() }
        await provider.release(); _ = try await selecting.value.outcome.get()
        #expect(await engine.recorded().filter { $0.hasPrefix("seek:") } == ["seek:8.0"])
    }
}
extension NativePlaybackTests {
    @Test func T064AllPresetsCustomCancellationAndInvalidRanges() async throws {
        let wall = ManualWall(); let session = try await ownedSession(wall: wall)
        for minutes in [5, 15, 30, 60] {
            try await session.setTimer(.minutes(minutes))
            #expect(abs((await session.timerStatus()?.remaining ?? 0) - Double(minutes * 60)) < 0.01)
        }
        try await session.setTimer(.custom(123))
        #expect(abs((await session.timerStatus()?.remaining ?? 0) - 123) < 0.01)
        await #expect(throws: DomainError.self) { try await session.setTimer(.custom(-1)) }
        try await session.setTimer(.endOfItem); #expect(await session.timerStatus()?.endOfItem == true)
        try await session.setTimer(nil); #expect(await session.timerStatus() == nil)
        try await session.setTimer(.minutes(5)); await session.close(reason: .accountSwitch)
        #expect(await session.timerStatus() == nil)
    }
    @Test func T064FiveSecondFadeRetainsOccurrenceAndSleepExpiryBlocksWake() async throws {
        let wall = ManualWall(); let clock = ManualMonotonic()
        let session = try await ownedSession(wall: wall, clock: clock)
        try await session.startOwnedMedia(OwnedMedia.items)
        let current = try await session.snapshot().queue.current?.id
        try await session.setTimer(.custom(1)); wall.advance(1); await session.tick()
        #expect(await session.timerStatus()?.fading == true)
        #expect(abs(await session.nativeGain() - 0.001) < 0.00001)
        clock.advance(to: .seconds(4)); await session.tick()
        #expect(try await session.snapshot().playback.intent == .play)
        #expect(abs(await session.nativeGain() - 0.0002) < 0.00001)
        clock.advance(to: .seconds(5)); await session.tick()
        #expect(try await session.snapshot().playback.intent == .pause(.user))
        #expect(try await session.snapshot().queue.current?.id == current)
        #expect(await session.timerStatus() == nil)
        let restoredGain = await session.nativeGain()
        print("T06 fade completed gain=\(restoredGain) configured=\(await session.configuredGain()) state=\(try await session.snapshot().playback.state) failures=\(try await session.snapshot().failures)")
        #expect(abs(restoredGain - 0.001) < 0.00001)
        try await session.resume(); try await session.setTimer(.custom(10)); await session.sleep()
        wall.advance(11); await session.wake(safeRoute: true, resumeEnabled: true)
        #expect(try await session.snapshot().playback.intent == .pause(.user))
        #expect(try await session.snapshot().queue.current?.id == current)
        await session.close()
    }
}

extension NativePlaybackTests {
    @Test func T063ExplicitFailureStaysSelectedAndSequentialStopsAtThree() async throws {
        let session = try await ownedSession()
        let missing = try ["missing-1", "missing-2", "missing-3", "missing-4"].map(ServiceID.init)
        await #expect(throws: (any Error).self) { try await session.startOwnedMedia(missing + OwnedMedia.items) }
        var state = try await session.snapshot()
        #expect(state.queue.current?.media == missing[0] && state.playback.error == .unavailableContent)
        #expect(state.queue.session.entries.allSatisfy { !$0.consumed })
        // Explicit retry again fails on the same occurrence, never silently selects a successor.
        await #expect(throws: (any Error).self) { try await session.resume() }
        #expect(try await session.snapshot().queue.current?.media == missing[0])
        try await session.startOwnedMedia([OwnedMedia.items[0]] + missing + [OwnedMedia.items[1]])
        state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .ended))
        state = try await session.snapshot()
        #expect(state.failures.count == 3)
        #expect(state.queue.metadata.failures?.count == 3)
        #expect(state.queue.metadata.failures?.map(\.reason) == [.unavailable, .unavailable, .unavailable])
        #expect(state.queue.current?.media == missing[2])
        #expect(state.queue.intent == .pause(.user))
        #expect(state.queue.session.entries.contains { $0.media == missing[3] && !$0.consumed })
        print("T06 unattended failures: \(state.failures)")
        await session.close()
    }
    @Test func T064EndItemTimerDoesNotConsumeOrAdvance() async throws {
        let session = try await ownedSession()
        try await session.startOwnedMedia(OwnedMedia.items)
        try await session.setTimer(.endOfItem)
        try await session.seek(8)
        await session.tick()
        let before = try await session.snapshot()
        #expect(before.timer?.fading == true)
        await session.receive(.init(context: before.playback.context, event: .ended))
        let after = try await session.snapshot()
        #expect(after.queue.current?.id == before.queue.current?.id)
        #expect(after.queue.intent == .pause(.user))
        #expect(after.queue.session.entries.allSatisfy { !$0.consumed })
        await session.close()
    }
}

extension PlaybackPolicyTests {
    @Test func T065PreparationAuthorizationFailureRefreshesOnce() async throws {
        let context = request(try account()); let engine = TestEngine(); let provider = CountingResolver(account: context.account!)
        await engine.failPreparation([.unauthorized, .unauthorized])
        let commands = PlaybackCommands(request: context, engine: engine, resolver: provider, capabilities: provider, wall: FixedWall(date: testWall), monotonic: FixedMonotonic(), lifecycle: TestLifecycle())
        let result = await commands.execute(.select(media: try sid(), occurrence: UUID()), context: context, origin: .menu)
        if case .failure(.unauthorized) = result.outcome {} else { Issue.record("Expected typed authorization failure") }
        #expect(await provider.refreshes == 1)
        #expect(await commands.snapshot().state == .failed)
        #expect(await engine.recorded().filter { $0 == "play" }.isEmpty)
    }
    @Test func T065PausedExpiryRetainsPositionWithoutStarting() async throws {
        let context = request(try account()); let engine = TestEngine(); let provider = CountingResolver(account: context.account!)
        let commands = PlaybackCommands(request: context, engine: engine, resolver: provider, capabilities: provider, wall: FixedWall(date: testWall), monotonic: FixedMonotonic(), lifecycle: TestLifecycle())
        _ = try await commands.execute(.select(media: sid(), occurrence: UUID()), context: context, origin: .menu).outcome.get()
        _ = try await commands.execute(.seek(6), context: context, origin: .menu).outcome.get()
        _ = try await commands.execute(.pause(.user), context: context, origin: .menu).outcome.get()
        let plays = await engine.recorded().filter { $0 == "play" }.count
        _ = try await commands.execute(.expire, context: context, origin: .menu).outcome.get()
        #expect(await commands.snapshot().state == .paused)
        #expect(await commands.snapshot().position == 6)
        #expect(await commands.snapshot().intent == .pause(.user))
        #expect(await engine.recorded().filter { $0 == "play" }.count == plays)
        #expect(await provider.refreshes == 1)
    }
}
extension NativePlaybackTests {
    @Test func T063NativeNetworkRecoveryUsesCheckpointAndPauseWins() async throws {
        let session = try await ownedSession()
        try await session.startOwnedMedia(OwnedMedia.items)
        try await session.seek(4)
        var state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .failed(.offline)))
        #expect(try await session.snapshot().playback.state == .buffering)
        try await session.recoverNetwork()
        state = try await session.snapshot()
        #expect(state.playback.state == .playing && state.playback.position >= 4)
        await session.receive(.init(context: state.playback.context, event: .buffering))
        try await session.pause()
        let paused = try await session.snapshot()
        try await session.recoverNetwork()
        let after = try await session.snapshot()
        #expect(after.playback.intent == .pause(.user) && after.playback.context == paused.playback.context)
        await session.close()
    }
}

extension NativePlaybackTests {
    @Test func T063UnattendedNativeFailureSkipsButExplicitFailureStays() async throws {
        let session = try await ownedSession()
        try await session.startOwnedMedia([OwnedMedia.items[0], OwnedMedia.items[1], OwnedMedia.items[0]])
        var state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .ended))
        state = try await session.snapshot()
        #expect(state.queue.current?.media == OwnedMedia.items[1])
        await session.receive(.init(context: state.playback.context, event: .failed(.unavailableContent)))
        let advanced = try await session.snapshot()
        #expect(advanced.queue.current?.media == OwnedMedia.items[0] && advanced.playback.state == .playing)
        #expect(advanced.queue.metadata.failures?.last?.media == OwnedMedia.items[1].rawValue)
        try await session.select(try #require(advanced.queue.current?.id))
        state = try await session.snapshot()
        await session.receive(.init(context: state.playback.context, event: .failed(.unavailableContent)))
        #expect(try await session.snapshot().queue.current?.id == state.queue.current?.id)
        #expect(try await session.snapshot().playback.state == .failed)
        await session.close()
    }
}
