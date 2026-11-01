import Domain
import Foundation

/// Uses only permission-aware Domain commands. Binding is installed at generation allocation,
/// before any provider or engine awaits; a later selection/pause cannot renew an old binding.
public actor PlaybackQueueBoundary: QueuePlaybackBoundary {
    private let commands: PlaybackCommands
    private var binding: (context: PlaybackContext, token: UUID)?
    private var pausedBinding: (context: PlaybackContext, token: UUID)?
    private var revision: UInt64 = 0
    private var sourceOwner: RequestContext?
    private var sourceVersion: UInt64?
    private var preparation: (@Sendable (QueueSnapshot, PlaybackContext) async throws -> Void)?
    private var cancellation: (@Sendable () async -> Void)?
    public func attachScheduling(prepare: @escaping @Sendable (QueueSnapshot, PlaybackContext) async throws -> Void, cancel: @escaping @Sendable () async -> Void) { preparation = prepare; cancellation = cancel }
    public func cancelScheduled(context: RequestContext) async { guard sourceOwner == nil || sourceOwner == context else { return }; await cancellation?() }
    public func adoptPrepared(_ snapshot: QueueSnapshot, engineContext: PlaybackContext) throws {
        try admit(snapshot, context: engineContext.request)
        guard snapshot.current?.id == engineContext.occurrenceID else { throw QueueError.staleContext }
        revision += 1; binding = (engineContext, snapshot.playbackToken); pausedBinding = nil
    }
    public init(commands: PlaybackCommands) { self.commands = commands }
    /// Queue-origin dispatches carry their committed version, so a delayed older
    /// arrival cannot supersede a newer selection or pause. One boundary per owner.
    private func admit(_ snapshot: QueueSnapshot, context: RequestContext) throws {
        guard snapshot.session.account == context.account,
              sourceOwner == nil || sourceOwner == context,
              sourceVersion.map({ snapshot.session.version > $0 }) ?? true else { throw QueueError.staleContext }
        sourceOwner = context; sourceVersion = snapshot.session.version
    }
    public func start(_ snapshot: QueueSnapshot, context: RequestContext, origin: CommandOrigin) async throws {
        try admit(snapshot, context: context)
        guard snapshot.intent == .play, let entry = snapshot.current else { throw QueueError.invalidState }
        try await startPrepared(entry, position: snapshot.session.position, token: snapshot.playbackToken, context: context, origin: origin, snapshot: snapshot)
    }
    public func pause(_ reason: PauseReason, snapshot: QueueSnapshot, context: RequestContext, origin: CommandOrigin) async throws {
        try admit(snapshot, context: context)
        let previous = binding
        detach(); let ticket = revision
        if let previous, previous.context.request == context,
           previous.context.occurrenceID == snapshot.session.currentOccurrence {
            // Keep a scoped checkpoint-only correlation to the newly committed pause
            // token. Hardware pause can follow a slow save; its final frozen position
            // must be durable too. This token never authorizes EOS advancement.
            pausedBinding = (previous.context, snapshot.playbackToken)
        }
        let result = await commands.execute(.pause(reason), context: context, origin: origin, expectedPlaybackContext: previous?.context)
        if revision == ticket { pausedBinding = nil }
        guard result.context == context else { throw QueueError.staleContext }
        _ = try result.outcome.get()
    }
    public func select(_ entry: QueueEntry, token: UUID, context: RequestContext, origin: CommandOrigin) async throws {
        try await start(entry, position: 0, token: token, context: context, origin: origin)
    }
    public func start(_ entry: QueueEntry, position: Double, token: UUID, context: RequestContext, origin: CommandOrigin) async throws {
        try await startPrepared(entry, position: position, token: token, context: context, origin: origin, snapshot: nil)
    }
    private func startPrepared(_ entry: QueueEntry, position: Double, token: UUID, context: RequestContext, origin: CommandOrigin, snapshot: QueueSnapshot?) async throws {
        revision += 1; let selection = revision; binding = nil; pausedBinding = nil
        let prepare = preparation
        let result = await commands.execute(.selectAt(media: entry.media, occurrence: entry.id, position: position), context: context, origin: origin, onSelection: { engineContext in
            try await self.bind(engineContext, token: token, revision: selection)
        }, onPrepared: { scope in if let snapshot { try await prepare?(snapshot, scope) } })
        guard selection == revision, result.context == context else { throw QueueError.staleContext }
        do { _ = try result.outcome.get() }
        catch { binding = nil; throw error }
    }
    private func bind(_ context: PlaybackContext, token: UUID, revision: UInt64) throws {
        guard self.revision == revision else { throw DomainError.staleContext }
        binding = (context, token)
    }
    public func position(for snapshot: QueueSnapshot, context: RequestContext) async -> Double? {
        guard let bound = binding, bound.token == snapshot.playbackToken,
              bound.context.request == context, bound.context.occurrenceID == snapshot.session.currentOccurrence else { return nil }
        let ticket = revision
        let position = await commands.position(for: bound.context)
        guard revision == ticket, binding?.token == bound.token, binding?.context == bound.context else { return nil }
        return position
    }
    public func pause(context: RequestContext, origin: CommandOrigin) async throws { try await pause(.user, context: context, origin: origin) }
    public func pause(_ reason: PauseReason, context: RequestContext, origin: CommandOrigin) async throws {
        detach()
        let result = await commands.execute(.pause(reason), context: context, origin: origin)
        guard result.context == context else { throw QueueError.staleContext }
        _ = try result.outcome.get()
    }
    public func currentSnapshot(for context: PlaybackContext) async -> PlaybackSnapshot? {
        let snapshot = await commands.snapshot()
        return snapshot.context == context ? snapshot : nil
    }
    public func token(for context: PlaybackContext) -> UUID? { binding?.context == context ? binding?.token : nil }
    public func pausedCheckpointToken(for context: PlaybackContext) async -> UUID? {
        guard let paused = pausedBinding, paused.context == context else { return nil }
        // An unprepared resolver has no authoritative playback position and must
        // not replace a deliberately committed queue checkpoint (W05 F3).
        guard await commands.position(for: context) != nil,
              pausedBinding?.context == context, pausedBinding?.token == paused.token else { return nil }
        return paused.token
    }
    public func tokenForPause(_ context: PlaybackContext) -> UUID? {
        guard let binding, binding.context.request == context.request,
              binding.context.occurrenceID == context.occurrenceID, context.generation >= binding.context.generation else { return nil }
        return binding.token
    }
    public func detach() { revision += 1; binding = nil; pausedBinding = nil }
}

/// Composition seam for the single native playback owner. Attach before the first selection.
/// Queue commits serialize end/checkpoint events even when selection resolution is suspended.
/// Tokens prevent a delayed checkpoint from overwriting a newly selected occurrence's position.
public actor QueuePlaybackLifecycle: PlaybackLifecycleSink {
    private var owner: QueueCommands?
    private var boundary: PlaybackQueueBoundary?
    private var request: RequestContext?
    public private(set) var error: String?
    public init() {}
    public func attach(owner: QueueCommands, boundary: PlaybackQueueBoundary, context: RequestContext) {
        self.owner = owner; self.boundary = boundary; request = context
    }
    public func detach(reason: PauseReason = .accountSwitch) async {
        if let owner, let request {
            do { _ = try await owner.execute(.pause(reason), context: request, origin: .userInterface) }
            catch { self.error = SafeErrorText.describe(error) }
        }
        await boundary?.detach(); owner = nil; boundary = nil; request = nil
    }
    public func checkpoint(_ snapshot: PlaybackSnapshot) async {
        guard let owner, let boundary, let request, request == snapshot.context.request else { return }
        do {
            if let token = await boundary.token(for: snapshot.context) {
                // A passive pause/play preserves the same occurrence and engine context.
                _ = try await owner.execute(.observedPlayback(token, position: snapshot.position, intent: snapshot.intent), context: request, origin: .userInterface)
            } else if let token = await boundary.pausedCheckpointToken(for: snapshot.context) {
                _ = try await owner.execute(.checkpointFor(token, position: snapshot.position, pause: nil), context: request, origin: .userInterface)
            } else if let reason = snapshot.pauseReason, let token = await boundary.tokenForPause(snapshot.context) {
                // A genuine route-generation change invalidates the old correlation.
                _ = try await owner.execute(.checkpointFor(token, position: snapshot.position, pause: reason), context: request, origin: .userInterface)
                await boundary.detach()
            }
        }
        catch { self.error = SafeErrorText.describe(error) }
    }
    public func advance(context: PlaybackContext) async {
        guard let owner, let boundary, let request, request == context.request,
              let token = await boundary.token(for: context),
              let snapshot = await boundary.currentSnapshot(for: context) else { return }
        do {
            // EOS can precede an awaited play acknowledgement. Reconcile the actual
            // Domain intent for this exact generation before deciding whether to advance.
            _ = try await owner.execute(.observedPlayback(token, position: snapshot.position, intent: snapshot.intent), context: request, origin: .userInterface)
            _ = try await owner.execute(.ended(token), context: request, origin: .userInterface)
        }
        catch { self.error = SafeErrorText.describe(error) }
    }
}
