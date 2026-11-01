import Domain
import Queue
import Foundation
import OutputRoutes
import Synchronization
@preconcurrency import AVFoundation

public enum SleepTimer: Equatable, Sendable {
    case minutes(Int), custom(TimeInterval), endOfItem
    public var seconds: Double? {
        switch self { case .minutes(let value): Double(value) * 60; case .custom(let value): value; case .endOfItem: nil }
    }
}
public struct TimerStatus: Sendable {
    public let remaining: Double?
    public let endOfItem: Bool
    public let fading: Bool
}
public struct PlaybackSessionSnapshot: Sendable {
    public let playback: PlaybackSnapshot
    public let queue: QueueSnapshot
    public let media: NativeMediaInfo?
    public let timer: TimerStatus?
    public let nextPreparationError: DomainError?
    public let failures: [String]
    public let gain: Double
    public let muted: Bool
    public let appliedGain: Float
    public let nativeStartGain: Float?
}
private actor SessionLifecycle: PlaybackLifecycleSink {
    private weak var session: PlaybackSession?
    func attach(_ session: PlaybackSession) { self.session = session }
    func checkpoint(_ snapshot: PlaybackSnapshot) async { await session?.checkpoint(snapshot) }
    func advance(context: PlaybackContext) async { await session?.advance(context) }
}
/// The only product transport owner. Every surface uses this actor; low-level Domain play
/// is intentionally not exported. Queue resume reselects from the committed checkpoint,
/// including a late EOS received while paused (L1), so it cannot play a dead ended player.
public actor PlaybackSession {
    private let commands: PlaybackCommands
    let engine: NativePlayer
    private let queue: QueueCommands
    private let boundary: PlaybackQueueBoundary
    private let queueLifecycle: QueuePlaybackLifecycle
    let context: RequestContext
    private let wall: any WallClock
    private let clock: any MonotonicClock
    private var events: Task<Void, Never>?
    private var ticking: Task<Void, Never>?
    private var stopped = false
    /// W23 (R2-1): told after every engine event that can change WHAT is playing or whether it plays (not position ticks), so the playback owner can
    /// keep Now Playing right with no window open. Set and cleared synchronously from the owner; called from this actor's own turn.
    private nonisolated let changeObserver = Mutex<(@Sendable () -> Void)?>(nil)
    /// W39: told the target of every seek that took effect (a person's seek, a restart of the item), so a Cast receiver can be sought to the same place.
    private nonisolated let seekObserver = Mutex<(@Sendable (Double) -> Void)?>(nil)
    public nonisolated func setSeekObserver(_ handler: (@Sendable (Double) -> Void)?) { seekObserver.withLock { $0 = handler } }
    /// W39 (ROUTE08): a Cast receiver renders this session's item; the local engine stays a silent clock. See `NativePlayer.setRemoteRendering`.
    @discardableResult public func setRemoteRendering(_ on: Bool) async -> Bool { await engine.setRemoteRendering(on) }
    public func isRemoteRendering() async -> Bool { await engine.isRemoteRendering() }
    public nonisolated func setChangeObserver(_ handler: (@Sendable () -> Void)?) { changeObserver.withLock { $0 = handler } }
    private var timer: SleepTimer?
    private var deadline: Date?
    private var fadeStart: Duration?
    private var fadingContext: PlaybackContext?
    private var gain: Double = 0.08
    private var gainRevision: UInt64 = 0
    private var muteRevision: UInt64 = 0
    private var rateRevision: UInt64 = 0
    private var effectsRevision: UInt64 = 0
    /// The effects the engine is configured with now (crossfade, equalizer, normalization, balance, gain).
    public func currentEffects() -> AudioEffects { appliedEffects }
    private var desiredEffects = try! AudioEffects()
    private var appliedEffects = try! AudioEffects()
    private var sequenceRevision: UInt64 = 0
    private var muted = false
    private var nextPreparationError: DomainError?
    private var failures: [String] = []
    private var consecutiveFailures = 0
    private var unattendedContext: PlaybackContext?
    private var lastPositionCheckpoint: Duration?
    private var preparingNext = false
    private var speculationRevision: UInt64 = 0
    private var nextTask: Task<Void, Never>?
    private var activeOperations = 0
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var adoptionInProgress = false
    /// `sequenceRevision` at the moment a handoff was abandoned and its queue pause is still owed.
    private var abandonedHandoffSequence: UInt64?
    private var adoptionSnapshot: PlaybackSessionSnapshot?
    private var handoffCommitRetries = 0
    private var renderRereads = 0
    private var renderHookForMeasurement: (@Sendable () async -> Void)?
    private var handoffAttemptRetries = 0
    private var handoffPersistenceFailures = 0
    private var adoptionWaiters: [CheckedContinuation<Void, Never>] = []
    private var failedNext: (token: UUID, occurrence: UUID, retryAfter: Date)?
    private var preparedNext: (QueueHandoff, QueueEntry, PlaybackContext, MediaVariant)?
    private var listeningStarted: Date?
    private var listeningOccurrence: UUID?
    private var listeningContext: PlaybackContext?
    private var closedIntervalContext: PlaybackContext?
    private var unheardAdoption: (context: PlaybackContext, started: Date)?
    private var refreshed: PlaybackContext?
    private var scrub: Task<Void, Never>?
    private var scrubRevision: UInt64 = 0
    private init(commands: PlaybackCommands, engine: NativePlayer, queue: QueueCommands, boundary: PlaybackQueueBoundary, queueLifecycle: QueuePlaybackLifecycle, context: RequestContext, wall: any WallClock, clock: any MonotonicClock) {
        self.commands = commands; self.engine = engine; self.queue = queue; self.boundary = boundary; self.queueLifecycle = queueLifecycle; self.context = context; self.wall = wall; self.clock = clock
    }
    public static func open(context: RequestContext, persistence: any QueuePersistence, assets: any NativeAssetProvider, resolver: any PlaybackResolver, capabilities: any CapabilityProvider, wall: any WallClock = SystemWallClock(), clock: any MonotonicClock = SystemMonotonicClock(), automaticTick: Bool = true, initialGain: Double = 0.08, initiallyMuted: Bool = false, maximumStartGain: Float? = nil, manualDecodedRendering: Bool = false, effects: AudioEffects = try! AudioEffects(), gapless: Bool = true) async throws -> PlaybackSession {
        guard let account = context.account else { throw DomainError.unauthorized }
        let engine = NativePlayer(assets: assets, clock: clock, initialGain: initialGain, initiallyMuted: initiallyMuted, maximumStartGain: maximumStartGain, manualDecodedRendering: manualDecodedRendering, preferGapless: gapless, initialEffects: effects, wall: wall)
        let relay = SessionLifecycle()
        let commands = PlaybackCommands(request: context, engine: engine, resolver: resolver, capabilities: capabilities, wall: wall, monotonic: clock, lifecycle: relay)
        let boundary = PlaybackQueueBoundary(commands: commands)
        let lifecycle = QueuePlaybackLifecycle()
        let queue = try QueueCommands(machine: QueueMachine(account: account, supportsAutoplay: false), context: context, persistence: persistence, playback: boundary, repeatSupported: true)
        try await queue.restore(context: context)
        await lifecycle.attach(owner: queue, boundary: boundary, context: context)
        let session = PlaybackSession(commands: commands, engine: engine, queue: queue, boundary: boundary, queueLifecycle: lifecycle, context: context, wall: wall, clock: clock)
        await session.initializeControls(gain: initialGain, muted: initiallyMuted, effects: effects)
        await boundary.attachScheduling(prepare: { [weak session] snapshot, scope in await session?.scheduleFollowing(scope) }, cancel: { [weak session] in await session?.cancelSpeculation() })
        await engine.setHandoffHandler { [weak session] id, old, next, variant, position in
            guard let session else { throw DomainError.staleContext }
            do { try await session.adoptFollowing(id, from: old, next: next, variant: variant, position: position) }
            catch {
                // The adoption barrier is released by now, so the queue's own pause can be
                // committed (the barrier drops lifecycle checkpoints while it is held).
                await session.settleAbandonedHandoff()
                throw error
            }
        }
        await relay.attach(session); await session.start(automaticTick: automaticTick)
        return session
    }
    private func scheduleFollowing(_ scope: PlaybackContext) {
        guard !stopped, nextTask == nil, preparedNext == nil else { return }
        nextTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareFollowing(scope)
            await self.finishSpeculation()
        }
    }
    private func finishSpeculation() { nextTask = nil }
    private func cancelSpeculation() async {
        speculationRevision += 1
        nextTask?.cancel()
        preparedNext = nil
        await engine.cancelPlannedNext()
    }
    private func prepareFollowing(_ scope: PlaybackContext) async {
        guard !Task.isCancelled, !stopped, preparedNext == nil, !preparingNext, timer == nil, await engine.canPlanNext(context: scope) else { return }
        preparingNext = true; defer { preparingNext = false }
        let sequence = speculationRevision
        var attempted: (UUID, UUID)?
        do {
            let before = try await queue.snapshot()
            guard before.current?.id == scope.occurrenceID, before.intent == .play,
                  before.playbackToken == (await boundary.token(for: scope)) else { return }
            let nextSnapshot = try await queue.previewNext()
            guard let entry = nextSnapshot.current else { return }
            if let failedNext, failedNext.token == before.playbackToken, failedNext.occurrence == entry.id, wall.now() < failedNext.retryAfter { return }
            attempted = (before.playbackToken, entry.id)
            guard let plan = try await queue.reserveHandoff(context: context) else { return }
            let (next, variant) = try await commands.resolveUpcoming(entry.media, occurrence: entry.id, from: scope)
            guard !Task.isCancelled, !stopped, sequence == speculationRevision, try await queue.snapshot().metadata.handoff?.id == plan.id else { throw DomainError.staleContext }
            let result = await engine.bindQueueNext(plan, next: next, variant: variant, context: scope)
            _ = try result.outcome.get()
            guard !Task.isCancelled, !stopped, sequence == speculationRevision else { throw DomainError.staleContext }
            preparedNext = (plan, entry, next, variant); nextPreparationError = nil
        } catch {
            preparedNext = nil
            if sequence == speculationRevision, !stopped {
                let ownerRevision = sequenceRevision
                do { try await queue.cancelHandoff(context: context) }
                catch { nextPreparationError = (error as? DomainError) ?? .transientTransport; return }
                guard ownerRevision == sequenceRevision, !stopped else { return }
                // A queue that changed state under the speculation (for example a
                // sleep/pause between preview and reservation) is a race, not a
                // failure of the next item: it must not hold off re-planning.
                if let queueError = error as? QueueError, [.invalidState, .staleContext, .busy].contains(queueError) { return }
                if let attempted, (error as? DomainError) != .staleContext { failedNext = (attempted.0, attempted.1, wall.now().addingTimeInterval(5)) }
                nextPreparationError = (error as? DomainError) ?? .transientTransport
            }
            // A failed speculative item does not fail or consume current playback.
        }
    }
    private func adoptFollowing(_ id: UUID, from previous: PlaybackContext, next: PlaybackContext, variant: MediaVariant, position: Double) async throws {
        guard !stopped, let (plan, entry, scope, _) = preparedNext, plan.id == id, scope == next,
              (await commands.snapshot()).context == previous else { throw DomainError.staleContext }
        var stable: PlaybackSessionSnapshot
        repeat {
            while activeOperations > 0 { await withCheckedContinuation { operationWaiters.append($0) } }
            stable = try await snapshot()
        } while activeOperations > 0
        guard stable.playback.context == previous, stable.queue.current?.id == previous.occurrenceID, !stopped, preparedNext?.0.id == id else { throw DomainError.staleContext }
        adoptionSnapshot = stable; adoptionInProgress = true
        defer { adoptionSnapshot = nil; adoptionInProgress = false; let waiters = adoptionWaiters; adoptionWaiters.removeAll(); for waiter in waiters { waiter.resume() } }
        let ended = wall.now()
        let started = listeningOccurrence == previous.occurrenceID ? listeningStarted : nil
        var committed: QueueSnapshot?
        // Bounded by count and elapsed time, below the ~0.68 s of already-queued
        // output: the pump and every control wait on this barrier meanwhile.
        let retryStart = ContinuousClock.now
        var retryDelay = Self.handoffRetryInitialMilliseconds
        while committed == nil {
            do {
                committed = try await queue.adoptHandoff(plan, position: position, started: started, ended: ended, context: context)
            } catch is QueueHandoffCommitError {
                guard !stopped else { throw DomainError.staleContext }
                let elapsed = retryStart.duration(to: .now)
                guard handoffAttemptRetries < Self.handoffRetryLimit,
                      elapsed + .milliseconds(retryDelay) <= .milliseconds(Self.handoffRetryBudgetMilliseconds) else {
                    try await abandonUncommittedHandoff(previous: previous, entry: entry)
                }
                handoffCommitRetries += 1; handoffAttemptRetries += 1
                // Keep the native transition and its heard position. Retrying a save
                // must never resolve/re-prepare B or report A as a source failure.
                try await Task.sleep(for: .milliseconds(retryDelay))
                retryDelay *= 2
                guard !stopped else { throw DomainError.staleContext }
            }
        }
        handoffAttemptRetries = 0
        let snapshot = committed!
        listeningStarted = nil; listeningOccurrence = nil
        // Quit has already stopped output. Leave its queued pause to checkpoint the
        // committed occurrence; reopening a player merely to publish an ID is wrong.
        guard !stopped else { return }
        let heardPosition = await engine.pendingHandoffPosition(id) ?? position
        do {
            try await engine.adoptPreparedNative(id, from: previous, to: next)
            _ = try await commands.adoptUpcoming(entry.media, variant: variant, next: next, from: previous, position: heardPosition)
            try await boundary.adoptPrepared(snapshot, engineContext: next)
        } catch {
            guard !stopped else { return }
            // A provider/backend can disappear independently of UI operations. Once
            // committed, the queue remains authoritative: revalidate B at its heard
            // position through the ordinary selection owner, never replay old A.
            preparedNext = nil
            failures.append("Committed transition: \(SafeErrorText.describe(error))")
            failures = Array(failures.suffix(100))
            let recovery = try await queue.execute(.checkpointFor(snapshot.playbackToken, position: heardPosition, pause: nil), context: context, origin: .userInterface)
            try await boundary.start(recovery, context: context, origin: .userInterface)
            throw error
        }
        preparedNext = nil; unheardAdoption = (next, ended); unattendedContext = next
        if heardPosition > 0 { observeListening(await commands.snapshot()) }
    }
    static let handoffRetryLimit = 2
    static let handoffRetryInitialMilliseconds = 100
    static let handoffRetryBudgetMilliseconds = 400
    /// A handoff whose durable save keeps failing is not adopted. The queue's last
    /// durable state (A current) stays authoritative: output stops at A's end, the
    /// staged B is withdrawn from the engine, nothing is credited to B and the save
    /// fault is reported in `failures`. Ordinary controls then respond normally; a
    /// later resume or selection re-saves (and fails visibly while the fault lasts).
    private func abandonUncommittedHandoff(previous: PlaybackContext, entry: QueueEntry) async throws -> Never {
        handoffAttemptRetries = 0
        preparedNext = nil; speculationRevision += 1; nextTask?.cancel()
        _ = await commands.execute(.pause(.user), context: context, origin: .userInterface)
        await engine.cancelPlannedNext()
        abandonedHandoffSequence = sequenceRevision
        handoffPersistenceFailures += 1
        failures.append("Queue could not save the handoff to \(entry.media.rawValue); playback paused at the end of the previous item")
        failures = Array(failures.suffix(100))
        // Thrown into the adoption handler: the backend was replaced above, so the
        // pump treats it as superseded rather than as a failure of either item.
        throw DomainError.transientTransport
    }
    /// The pause above reaches Domain only: the adoption barrier suppresses the lifecycle
    /// checkpoint, so the saved queue would stay at `intent=play` with the stale handoff
    /// and a later plain Play would replay the end of A. Once the barrier is released,
    /// commit the queue's pause (intent, position, handoff cleared). A newer control has
    /// bumped `sequenceRevision` and owns the queue state, so it is left alone.
    fileprivate func settleAbandonedHandoff() async {
        guard let abandoned = abandonedHandoffSequence else { return }
        abandonedHandoffSequence = nil
        guard !stopped, sequenceRevision == abandoned else { return }
        do { _ = try await queue.execute(.pause(.user), context: context, origin: .userInterface) }
        catch {
            guard !stopped else { return }
            failures.append("Queue could not record the pause after the abandoned handoff: \(SafeErrorText.describe(error))")
            failures = Array(failures.suffix(100))
        }
    }
    func handoffPersistenceFailureCountForMeasurement() -> Int { handoffPersistenceFailures }
    /// Device-free transport harness enters the same queue owner and selected graph.
    func renderSelected(_ frames: UInt32, throughPump: Bool = false) async throws -> AVAudioPCMBuffer {
        // TH1: this harness entry reads the context, then awaits the engine. A transition that the session itself finishes in between (the adoption of the
        // prepared next item, a speculative plan) moves the engine to the new context, and the engine rightly refuses the old one (`staleContext`, thrown at its
        // first guard, before any audio is produced). The device-driven pump re-reads the context on its next turn; this entry used to hand the refusal to the
        // test, which then failed at random. It now re-reads once the context has really moved on (bounded, so a context that never settles still throws).
        var attempts = 0
        var state = await commands.snapshot()
        let output: AVAudioPCMBuffer
        while true {
            if let hook = renderHookForMeasurement { renderHookForMeasurement = nil; await hook() }
            do { output = try await engine.renderSelected(frames, context: state.context, throughPump: throughPump); break }
            catch DomainError.staleContext where attempts < Self.renderRereadLimit {
                // The engine moves to the next occurrence a moment BEFORE the command owner does (`adoptFollowing` calls `adoptPreparedNative`, then
                // `adoptUpcoming`), so the owner's context can still be the old one while the engine's is already new: wait for the adoption barrier
                // every control waits on, then read again. A refusal with no adoption running and no change of context is a real one and is thrown.
                let adopting = adoptionInProgress
                await awaitAdoption()
                let fresh = await commands.snapshot()
                guard adopting || fresh.context != state.context else { throw DomainError.staleContext }
                attempts += 1; renderRereads += 1; state = fresh
            }
        }
        let current = await commands.snapshot()
        await commands.receive(.init(context: current.context, event: .position(await engine.nativePosition()), observedAt: clock.now()))
        if !stopped {
            let state = await commands.snapshot()
            observeListening(state); scheduleFollowing(state.context)
        }
        return output
    }
    func unattendedFailureCountForMeasurement() -> Int { consecutiveFailures }
    func handoffRetryCountForMeasurement() -> Int { handoffCommitRetries }
    /// TH1: how many times `renderSelected` re-read the context after the engine refused a context the session had itself moved past.
    func renderRereadsForMeasurement() -> Int { renderRereads }
    /// TH1 test seam: runs inside `renderSelected` after the context was read and before the engine is entered (a deterministic stand-in for the session's own transition).
    func setRenderHookForMeasurement(_ hook: (@Sendable () async -> Void)?) { renderHookForMeasurement = hook }
    static let renderRereadLimit = 3
    func nextReadyForMeasurement() -> Bool { preparedNext != nil }
    func queueSnapshotForMeasurement() async throws -> QueueSnapshot { try await queue.snapshot() }
    private func initializeControls(gain: Double, muted: Bool, effects: AudioEffects) { self.gain = gain; self.muted = muted; desiredEffects = effects; appliedEffects = effects }
    private func start(automaticTick: Bool) async {
        let stream = await engine.observations()
        events = Task { [weak self] in
            for await event in stream { guard !Task.isCancelled else { break }; await self?.receive(event) }
        }
        if automaticTick {
            ticking = Task { [weak self] in
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)); guard !Task.isCancelled else { break }; await self?.tick() }
            }
        }
    }
    func nativeStartGains() async -> [Float] { await engine.nativeStartGains() }
    func nativeMuted() async -> Bool { await engine.nativeMuted() }
    func nativePosition() async -> Double { await engine.nativePosition() }
    func nativeSeekCount() async -> UInt64 { await engine.nativeSeekCount() }
    func configuredGain() async -> Float { await engine.configuredGain() }
    func nativeGain() async -> Float { await engine.nativeGain() }
    public func isClosed() -> Bool { stopped }
    public func snapshot() async throws -> PlaybackSessionSnapshot {
        if let adoptionSnapshot { return adoptionSnapshot }
        let persistenceError = await queueLifecycle.error.map { ["Queue checkpoint: " + $0] } ?? []
        return .init(playback: await commands.snapshot(), queue: try await queue.snapshot(), media: await engine.mediaInfo(), timer: timerStatus(), nextPreparationError: nextPreparationError, failures: failures + persistenceError, gain: gain, muted: muted, appliedGain: await engine.nativeGain(), nativeStartGain: await engine.nativeStartGains().last)
    }
    /// Starts a context. `replacement` is the person's Replace explicit queue choice (W27): songs they queued themselves are dropped (`.replace`), kept after the new
    /// context's first song (`.keep`), or the start is refused with `QueueError.confirmationRequired` until they decide (`.ask`). A fresh session has none queued,
    /// so every choice behaves alike then.
    public func startOwnedMedia(_ items: [ServiceID], replacement: ReplacementPreference = .replace) async throws {
        try await requireActive(); defer { finishOperation() }; try await recordCurrentInterval(suppressCurrent: true); nextPreparationError = nil; sequenceRevision += 1; consecutiveFailures = 0; unattendedContext = nil
        _ = try await queue.execute(.replace(items, source: ServiceID("owned-test-context"), cursor: nil, decision: replacement, remember: false), context: context, origin: .userInterface)
    }
    public func sendQueue(_ command: QueueCommand, origin: CommandOrigin = .userInterface) async throws {
        try await requireActive(); defer { finishOperation() }; failedNext = nil
        switch command {
        case .select, .replace, .startContext, .resume, .previousItem, .nextItem:
            try await recordCurrentInterval(suppressCurrent: true); nextPreparationError = nil
            sequenceRevision += 1; consecutiveFailures = 0; unattendedContext = nil; cancelScrub()
        case .pause: sequenceRevision += 1; cancelScrub()
        default: break
        }
        _ = try await queue.execute(command, context: context, origin: origin)
    }
    public func playPause() async throws {
        try await requireActive(); defer { finishOperation() }
        let state = await commands.snapshot()
        if state.intent == .play { try await pause(.user) }
        else { try await resume() }
    }
    public func pause(_ reason: PauseReason = .user) async throws {
        try await requireActive(); defer { finishOperation() }; sequenceRevision += 1; cancelScrub()
        _ = await commands.execute(.pause(reason), context: context, origin: .userInterface)
        _ = try await queue.execute(.pause(reason), context: context, origin: .userInterface)
    }
    public func resume() async throws {
        try await requireActive(); defer { finishOperation() }; try await recordCurrentInterval(suppressCurrent: true); nextPreparationError = nil; sequenceRevision += 1; consecutiveFailures = 0; unattendedContext = nil
        // Resume always resolves at the last committed position with a fresh EOS token.
        _ = try await queue.execute(.resume, context: context, origin: .userInterface)
    }
    public func next() async throws {
        try await requireActive(); defer { finishOperation() }; try await recordCurrentInterval(suppressCurrent: true); nextPreparationError = nil; sequenceRevision += 1; consecutiveFailures = 0; unattendedContext = nil; cancelScrub()
        _ = try await queue.execute(.nextItem, context: context, origin: .userInterface)
    }
    public func select(_ occurrence: UUID) async throws {
        try await requireActive(); defer { finishOperation() }; try await recordCurrentInterval(suppressCurrent: true); nextPreparationError = nil; sequenceRevision += 1; consecutiveFailures = 0; unattendedContext = nil; cancelScrub()
        _ = try await queue.execute(.select(occurrence), context: context, origin: .userInterface)
    }
    public func previous(directItem: Bool = false) async throws {
        try await requireActive(); defer { finishOperation() }; try await recordCurrentInterval(suppressCurrent: true); nextPreparationError = nil; sequenceRevision += 1; consecutiveFailures = 0; unattendedContext = nil
        let state = await commands.snapshot()
        if !directItem, state.position(at: clock.now()) > 3 { try await seek(0); return }
        let queueState = try await queue.snapshot()
        if let current = queueState.current, let index = queueState.session.entries.firstIndex(where: { $0.id == current.id }), index > 0 {
            _ = try await queue.execute(.previousItem, context: context, origin: .userInterface)
        } else { try await seek(0) }
    }
    public func seek(_ position: Double) async throws {
        try await requireActive(); defer { finishOperation() }; cancelScrub()
        try await applySeek(position)
    }
    private func applySeek(_ position: Double) async throws {
        try await requireActive(); defer { finishOperation() }
        // TH1 rework 2: the window between the player reporting the end and the queue committing the exhaustion (`.ended` is set first; the end's checkpoint is
        // written and `current` cleared a moment later). A seek there is refused exactly like one past the end, and BEFORE it touches anything: it must not
        // reach the command owner, save a checkpoint or change the queue version, nor take the queue lock the end's checkpoint holds, nor bump
        // `sequenceRevision` (which would cancel the very advance that commits the exhaustion). It used to wait for the lock, then cancel the handoff, seek the
        // ended item and checkpoint, so the queue version moved.
        guard await commands.snapshot().state != .ended else { return }
        sequenceRevision += 1; failedNext = nil
        try await queue.cancelHandoff(context: context); preparedNext = nil
        // Exhaustion has no seekable current occurrence. Keep intent/queue unchanged.
        guard try await queue.snapshot().current != nil, let info = await engine.mediaInfo() else { return }
        let state = await commands.snapshot()
        let target = min(position, info.duration)
        let response = await commands.execute(.seek(target), context: context, origin: .userInterface)
        _ = try response.outcome.get()
        guard state.context == (await commands.snapshot()).context else { throw DomainError.staleContext }
        await checkpoint(await commands.snapshot())
        seekObserver.withLock { $0 }?(target)
    }
    /// UI scrub preview stays in MainActor; gesture end sends exactly one seek.
    /// Repeated keyboard requests replace the pending target and commit after 120 ms idle.
    public func coalescedSeek(_ position: Double) {
        guard !stopped else { return }
        cancelScrub(); let revision = scrubRevision
        scrub = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)); await self?.commitScrub(position, revision: revision) } catch {}
        }
    }
    private func commitScrub(_ position: Double, revision: UInt64) async {
        guard scrubRevision == revision else { return }
        // Do not cancel this task through public seek(). Retain its handle while
        // awaiting permission so a genuinely newer scrub can still cancel it.
        try? await applySeek(position)
        if scrubRevision == revision { scrub = nil }
    }
    private func cancelScrub() { scrubRevision += 1; scrub?.cancel(); scrub = nil }
    public func setGain(_ value: Double) async throws {
        try await requireActive(); defer { finishOperation() }
        guard value.isFinite, (0...1).contains(value) else { throw DomainError.invalidInput(.invalidRange) }
        gainRevision += 1; let ticket = gainRevision
        let previous = gain; gain = value
        do { try await queue.cancelHandoff(context: context); preparedNext = nil }
        catch { if ticket == gainRevision { gain = previous }; throw error }
        guard ticket == gainRevision, !stopped else { return }
        let scope = PlaybackContext(request: context, generation: 0, occurrenceID: nil, route: nil)
        let result = await engine.setGain(value, context: scope)
        // A same-owner control/prepare/fade can supersede an acknowledgement. The
        // latest desired setting remains authoritative; this is not a user error.
        if ticket != gainRevision { return }
        if case .failure(.staleContext) = result.outcome, !stopped, await engine.controlsOwned(by: context) { return }
        if case .failure = result.outcome { gain = previous }
        _ = try result.outcome.get()
    }
    public func setMuted(_ value: Bool) async throws {
        try await requireActive(); defer { finishOperation() }
        muteRevision += 1; let ticket = muteRevision; let previous = muted; muted = value
        do { try await queue.cancelHandoff(context: context); preparedNext = nil }
        catch { if ticket == muteRevision { muted = previous }; throw error }
        guard ticket == muteRevision, !stopped else { return }
        let scope = PlaybackContext(request: context, generation: 0, occurrenceID: nil, route: nil)
        let result = await engine.setMuted(value, context: scope)
        guard ticket == muteRevision else { return }
        if case .failure = result.outcome { muted = previous }
        _ = try result.outcome.get()
    }
    public func setQuality(_ preference: PlaybackQualityPreference) async throws {
        try await requireActive(); defer { finishOperation() }; _ = try await commands.execute(.quality(preference), context: context, origin: .userInterface).outcome.get()
    }
    public func setRate(_ rate: Double) async throws {
        try await requireActive(); defer { finishOperation() }
        guard rate.isFinite, (0.5...3).contains(rate) else { throw DomainError.invalidInput(.invalidRange) }
        rateRevision += 1; let ticket = rateRevision
        try await queue.cancelHandoff(context: context); preparedNext = nil
        guard ticket == rateRevision, !stopped else { return }
        _ = try await commands.execute(.rate(rate), context: context, origin: .userInterface).outcome.get()
    }
    public func configureEffects(_ effects: AudioEffects) async throws {
        try await requireActive(); defer { finishOperation() }; effectsRevision += 1; let ticket = effectsRevision; desiredEffects = effects
        do {
            try await queue.cancelHandoff(context: context); preparedNext = nil
            guard ticket == effectsRevision, !stopped else { return }
            _ = try await engine.configureEffects(effects, context: commands.snapshot().context).outcome.get()
            if ticket == effectsRevision { appliedEffects = effects }
        } catch { if ticket == effectsRevision { desiredEffects = appliedEffects }; throw error }
    }
    // MARK: W17 native video (owned and local media)
    /// Audio only: stops the video decoder. Never covers a decoding picture.
    public func setVideoDecoding(_ enabled: Bool) async throws {
        try await requireActive(); defer { finishOperation() }
        _ = try await engine.setVideoDecoding(enabled, context: commands.snapshot().context).outcome.get()
    }
    /// What a native video surface attaches to; nil without a prepared item that holds a video track.
    public func videoHandle() async -> NativeVideoHandle? {
        guard !stopped else { return nil }
        return await engine.videoHandle(context: commands.snapshot().context)
    }
    public func startVideoMeasurement() async throws {
        try await requireActive(); defer { finishOperation() }
        _ = try await engine.startVideoMeasurement(context: commands.snapshot().context).outcome.get()
    }
    public func videoFramesDelivered() async -> Int { await engine.videoFramesDelivered() }
    public func setBalance(_ balance: Double) async throws {
        let current = desiredEffects
        try await configureEffects(AudioEffects(bands: current.bands, normalizationDB: current.normalizationDB, normalize: current.normalize, balance: Float(balance), gain: current.gain, crossfade: current.crossfade))
    }
    public func setTimer(_ timer: SleepTimer?) async throws {
        try await requireActive(); defer { finishOperation() }
        if timer != nil {
            try await queue.cancelHandoff(context: context); preparedNext = nil
            let state = await commands.snapshot()
            if await engine.nativeRate() > 0 { await commands.receive(.init(context: state.context, event: .started)) }
        }
        if let seconds = timer?.seconds { guard seconds.isFinite, seconds > 0 else { throw DomainError.invalidInput(.invalidRange) } }
        self.timer = timer; deadline = timer?.seconds.map { wall.now().addingTimeInterval($0) }; fadeStart = nil; fadingContext = nil
        let state = await commands.snapshot()
        if state.item != nil { _ = await engine.setFadeFactor(1, context: state.context) }
    }
    public func timerStatus() -> TimerStatus? {
        timer.map { .init(remaining: deadline.map { max(0, $0.timeIntervalSince(wall.now())) }, endOfItem: $0 == .endOfItem, fading: fadeStart != nil) }
    }
    /// W21: whether a sleep timer has run out (its wall deadline passed, or it is already fading out). A wake never resumes after this.
    public func timerHasExpired() -> Bool {
        (deadline.map { wall.now() >= $0 } ?? false) || fadeStart != nil
    }
    /// Wall deadline counts time asleep. Fade uses monotonic time; no wall adjustment
    /// can extend a fade or permit wake autoplay after an expired timer.
    public func tick() async {
        let before = await commands.snapshot()
        await tickOnce()
        let after = await commands.snapshot()
        // The session may have paused itself (sleep timer, fade end) or changed item: tell the owner, and only then.
        if before.state != after.state || before.intent != after.intent || before.context != after.context { notifyChanged() }
    }
    private func tickOnce() async {
        await awaitAdoption()
        guard !stopped else { return }
        activeOperations += 1; defer { finishOperation(notify: false) }
        let state = await commands.snapshot()
        if state.state == .playing { scheduleFollowing(state.context) }
        if let deadline, wall.now() >= deadline, fadeStart == nil {
            if state.pauseReason == .sleep || state.state != .playing {
                try? await pause(.user); timer = nil; self.deadline = nil
            } else { fadeStart = clock.now(); fadingContext = state.context }
        }
        if timer == .endOfItem, fadeStart == nil, state.state == .playing,
           let info = await engine.mediaInfo(), info.duration - state.position(at: clock.now()) <= 5 * state.rate {
            fadeStart = clock.now(); fadingContext = state.context
        }
        if let fadeStart {
            guard state.context == fadingContext else { try? await setTimer(nil); return }
            let elapsed = clock.now() - fadeStart
            let parts = elapsed.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            _ = await engine.setFadeFactor(max(0, 1 - seconds / 5), context: state.context)
            if seconds >= 5 {
                try? await pause(.user); try? await setTimer(nil)
            }
        }
        if let expiry = await commands.variantExpiry(), expiry.timeIntervalSince(wall.now()) <= 15,
           refreshed != state.context, state.item != nil {
            refreshed = state.context
            _ = await commands.execute(.expire, context: context, origin: .userInterface)
        }
    }
    public func recoverNetwork() async throws {
        try await requireActive(); defer { finishOperation() }
        let state = await commands.snapshot()
        guard state.state == .buffering, state.intent == .play else { return }
        await checkpoint(state)
        // Queue resume revalidates rights and resolves at the interrupted checkpoint.
        _ = try await queue.execute(.resume, context: context, origin: .userInterface)
    }
    // W22: the output seam. The session forwards to its one engine; nothing here is reachable without an injected applier.
    public func configureOutput(applier: any LocalOutputApplying) async { await engine.configureOutput(applier: applier) }
    @discardableResult public func setOutput(uid: String?) async -> Bool { await engine.setOutput(uid: uid) }
    public func outputBackend() async -> OutputBackend { await engine.outputBackend() }
    public nonisolated var routePickerPlayer: AVPlayer { engine.routePickerPlayer }
    public nonisolated func silenceNow() { engine.silenceNow() }
    public func observeExternalPlayback(_ handler: @escaping @Sendable (Bool) -> Void) async { await engine.observeExternalPlayback(handler) }
    public func isExternalPlaybackActive() async -> Bool { await engine.isExternalPlaybackActive() }
    /// Invoked by a route provider; tests inject this lifecycle event without
    /// modifying the machine's physical/global audio route.
    public func routeInvalidated(_ route: RouteID?) async {
        await awaitAdoption()
        guard !stopped else { return }
        activeOperations += 1; defer { finishOperation() }; sequenceRevision += 1; cancelScrub()
        try? await queue.cancelHandoff(context: context); preparedNext = nil
        _ = await commands.execute(.route(route), context: context, origin: .userInterface)
    }
    public func sleep() async {
        await awaitAdoption()
        guard !stopped else { return }
        activeOperations += 1; defer { finishOperation() }; cancelScrub()
        _ = await commands.execute(.sleep, context: context, origin: .userInterface)
    }
    public func wake(safeRoute: Bool, resumeEnabled: Bool) async {
        await awaitAdoption()
        guard !stopped else { return }
        activeOperations += 1; defer { finishOperation() }
        if deadline.map({ wall.now() >= $0 }) == true || fadeStart != nil {
            try? await pause(.user); try? await setTimer(nil)
        }
        await tick()
        closedIntervalContext = nil
        _ = await commands.execute(.wake(safeRoute: safeRoute, resumeEnabled: resumeEnabled), context: context, origin: .userInterface)
    }
    public func close(reason: PauseReason = .quit) async {
        guard !stopped else { return }; stopped = true; sequenceRevision += 1
        nextTask?.cancel(); preparedNext = nil
        events?.cancel(); ticking?.cancel(); cancelScrub(); timer = nil; deadline = nil; fadeStart = nil
        // Reserve Quit in Domain and stop native output before any durable queue
        // checkpoint can suspend. Late provider completions see the new generation.
        _ = await commands.execute(.quit, context: context, origin: .userInterface)
        await awaitAdoption()
        try? await recordCurrentInterval()
        await queueLifecycle.detach(reason: reason)
    }
    private func awaitAdoption() async {
        while adoptionInProgress { await withCheckedContinuation { adoptionWaiters.append($0) } }
    }
    private func requireActive() async throws {
        await awaitAdoption()
        guard !stopped else { throw DomainError.staleContext }
        activeOperations += 1
    }
    /// Every operation the session performs ends here, so every state change the SESSION makes (not only engine events) reaches the owner: a
    /// sleep-timer pause, the three-failures pause, a wake, a route invalidation, a queue advance. `tick` runs every second and tells the owner only when it changed something.
    private func finishOperation(notify: Bool = true) {
        activeOperations -= 1
        if activeOperations == 0 {
            let waiters = operationWaiters; operationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        if notify { notifyChanged() }
    }
    private func notifyChanged() { changeObserver.withLock { $0 }?() }
    func receive(_ event: ScopedEngineEvent) async {
        defer { if case .position = event.event {} else { notifyChanged() } }
        await awaitAdoption()
        guard !stopped else { return }
        let sequence = sequenceRevision
        let before = await commands.snapshot()
        guard before.context == event.context else { return }
        await commands.receive(event)
        switch event.event {
        case .started:
            let current = await commands.snapshot()
            if current.context == event.context, current.state == .playing { beginInterval(event.context) }
        case .position:
            observeListening(await commands.snapshot())
            let now = clock.now()
            if lastPositionCheckpoint.map({ now - $0 >= .seconds(5) }) ?? true {
                lastPositionCheckpoint = now; await checkpoint(await commands.snapshot())
            }
        case .buffering, .failed(.offline): await checkpoint(await commands.snapshot())
        default: break
        }
        let after = await commands.snapshot()
        if case .failed = event.event, after.context == before.context, let error = after.error, before.intent == .play, before.state != .failed, sequenceRevision == sequence {
            let current = try? await queue.snapshot()
            guard sequenceRevision == sequence, let current,
                  current.current?.id == before.context.occurrenceID,
                  current.playbackToken == (await boundary.token(for: before.context)) else { return }
            if sequenceRevision == sequence {
                _ = try? await queue.execute(.failedPlayback(current.playbackToken, reason: QueueFailureReason(error), at: wall.now()), context: context, origin: .userInterface)
            }
            guard sequenceRevision == sequence else { return }
            failures.append("\(before.item?.rawValue ?? "Unknown"): \(SafeErrorText.describe(error))")
            failures = Array(failures.suffix(100))
            if unattendedContext == before.context,
               current.current?.segment != .advertisement,
               !(current.current.map { current.metadata.immutable.contains($0.id) } ?? false) {
                consecutiveFailures += 1
                if consecutiveFailures >= 3 { try? await pause(.user) }
                else { await advanceQueue(current.playbackToken, sequence: sequence, skipFailed: true) }
            }
        }
    }
    private func recordCurrentInterval(suppressCurrent: Bool = false) async throws {
        if suppressCurrent { closedIntervalContext = await commands.snapshot().context }
        guard let started = listeningStarted else { unheardAdoption = nil; return }
        listeningStarted = nil
        closedIntervalContext = listeningContext; listeningContext = nil
        let occurrence = listeningOccurrence; listeningOccurrence = nil
        let queueState = try await queue.snapshot()
        if let occurrence, queueState.session.entries.contains(where: { $0.id == occurrence && $0.segment != .advertisement }) {
            _ = try await queue.execute(.listened(occurrence, started: started, ended: max(started, wall.now())), context: context, origin: .userInterface)
        }
    }
    private func beginInterval(_ scope: PlaybackContext) {
        guard listeningStarted == nil, closedIntervalContext != scope, unheardAdoption?.context != scope else { return }
        listeningContext = scope
        listeningOccurrence = scope.occurrenceID; listeningStarted = wall.now()
    }
    private func observeListening(_ state: PlaybackSnapshot) {
        guard state.state == .playing, state.position > 0,
              let pending = unheardAdoption, pending.context == state.context else { return }
        unheardAdoption = nil
        beginInterval(state.context)
        listeningStarted = pending.started
    }
    fileprivate func checkpoint(_ state: PlaybackSnapshot) async {
        guard !adoptionInProgress else { return }
        if state.state == .playing { beginInterval(state.context); await queueLifecycle.checkpoint(state); return }
        // Commit the pause/stop checkpoint (captured position, intent) before the
        // history write: awaiting the interval first let a competing select publish
        // ahead of the pause, which then landed on the new occurrence (W06 RF1).
        await queueLifecycle.checkpoint(state)
        try? await recordCurrentInterval()
    }
    fileprivate func advance(_ token: PlaybackContext) async {
        let sequence = sequenceRevision
        guard !stopped, let bound = await boundary.token(for: token) else { return }
        let state = await commands.snapshot()
        guard state.context == token, sequenceRevision == sequence else { return }
        if timer == .endOfItem || fadeStart != nil {
            try? await pause(.user); try? await setTimer(nil); return
        }
        await checkpoint(state)
        guard state.intent == .play, sequenceRevision == sequence else { return }
        consecutiveFailures = 0
        try? await recordCurrentInterval()
        await advanceQueue(bound, sequence: sequence)
    }
    private func advanceQueue(_ bound: UUID, sequence: UInt64, skipFailed: Bool = false) async {
        defer { notifyChanged() }
        var failure = skipFailed
        var nextToken = bound
        while !stopped, sequenceRevision == sequence {
            do {
                let queueState = try await queue.execute(failure ? .failedAdvance(nextToken) : .ended(nextToken), context: context, origin: .userInterface)
                guard queueState.current != nil else { return }
                guard !stopped, sequenceRevision == sequence else { return }
                let current = await commands.snapshot()
                guard sequenceRevision == sequence else { return }
                if current.error != nil { throw current.error! }
                unattendedContext = current.context; return
            } catch {
                guard !stopped, sequenceRevision == sequence else { return }
                let current = try? await queue.snapshot()
                guard sequenceRevision == sequence else { return }
                consecutiveFailures += 1
                if let current {
                    _ = try? await queue.execute(.failedPlayback(current.playbackToken, reason: QueueFailureReason((error as? DomainError) ?? .transientTransport), at: wall.now()), context: context, origin: .userInterface)
                }
                guard sequenceRevision == sequence else { return }
                failures.append("\(current?.current?.media.rawValue ?? "Unknown"): \(SafeErrorText.describe(error))")
                failures = Array(failures.suffix(100))
                guard consecutiveFailures < 3, let current, current.intent == .play,
                      current.current?.segment != .advertisement,
                      !(current.current.map { current.metadata.immutable.contains($0.id) } ?? false) else { try? await pause(.user); return }
                nextToken = current.playbackToken; failure = true
            }
        }
    }
}
