import Foundation

public enum CommandOrigin: String, CaseIterable, Sendable { case userInterface, menu, mediaKey, siri, shortcut, widget, appleScript, link }
public enum PlaybackQualityPreference: String, CaseIterable, Sendable { case auto, bestAvailable, dataSaver }
public enum PlaybackCommand: Sendable {
    case select(media: ServiceID, occurrence: UUID), selectAt(media: ServiceID, occurrence: UUID, position: Double), play, pause(PauseReason), seek(Double), gain(Double), rate(Double)
    case quality(PlaybackQualityPreference)
    case route(RouteID?), sleep, wake(safeRoute: Bool, resumeEnabled: Bool), expire, quit
}
public protocol PlaybackLifecycleSink: Actor {
    func checkpoint(_ snapshot: PlaybackSnapshot) async
    func advance(context: PlaybackContext) async
}
/// One actor owns intent. Every caller, including extensions, supplies a scoped command.
/// Concrete engines must also enforce context at the hardware boundary on every operation.
public actor PlaybackCommands {
    private var machine: PlaybackMachine
    private let engine: any PlaybackEngine
    private let resolver: any PlaybackResolver
    private let capabilities: any CapabilityProvider
    private let wall: any WallClock
    private let monotonic: any MonotonicClock
    private let lifecycle: any PlaybackLifecycleSink
    private var seekAuthorizationRevision: UInt64 = 0
    private var variant: MediaVariant?
    private var quality: PlaybackQualityPreference = .bestAvailable
    // Identity generations do not change for repeated Play/Pause on the same item.
    // Reserve intent ordering before an authorization await, without granting play intent.
    private var transportRevision: UInt64 = 0
    private func advanceTransportRevision() {
        precondition(transportRevision < .max, "Transport revision exhausted")
        transportRevision += 1
    }
    public init(request: RequestContext, engine: any PlaybackEngine, resolver: any PlaybackResolver, capabilities: any CapabilityProvider, wall: any WallClock, monotonic: any MonotonicClock, lifecycle: any PlaybackLifecycleSink) {
        machine = PlaybackMachine(request: request); self.engine = engine; self.resolver = resolver; self.capabilities = capabilities; self.wall = wall; self.monotonic = monotonic; self.lifecycle = lifecycle
    }
    public func snapshot() -> PlaybackSnapshot { machine.snapshot }
    /// Sample the current authoritative timeline without changing transport intent.
    /// Queue pauses call this under their transaction gate before rotating the token.
    public func position(for context: PlaybackContext) -> Double? {
        guard machine.context == context else { return nil }
        return machine.checkpointPosition(at: monotonic.now())
    }
    public func resolveUpcoming(_ media: ServiceID, occurrence: UUID, from current: PlaybackContext) async throws -> (PlaybackContext, MediaVariant) {
        try check(current)
        let revision = transportRevision; let seek = seekAuthorizationRevision
        guard current.generation < .max else { throw DomainError.staleContext }
        let next = PlaybackContext(request: current.request, generation: current.generation + 1, occurrenceID: occurrence, route: current.route)
        let permission = await resolver.validateEligibility(media, context: next)
        try check(current)
        guard permission.context == next, let account = current.request.account else { throw DomainError.staleContext }
        switch try permission.outcome.get().decision(for: account, now: wall.now()) {
        case .allowed: break
        case .denied(let error), .retry(let error), .verify(let error): throw error
        }
        let variants = await resolver.resolve(media, context: next)
        try check(current)
        guard revision == transportRevision, seek == seekAuthorizationRevision, variants.context == next else { throw DomainError.staleContext }
        let sorted = try variants.outcome.get().sorted { quality == .dataSaver ? ($0.bitrate ?? Int.max) < ($1.bitrate ?? Int.max) : ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }
        guard let selected = sorted.first else { throw DomainError.unavailableContent }
        guard selected.expiresAt.map({ wall.now() < $0 }) ?? true else { throw DomainError.expiredMedia }
        return (next, selected)
    }
    /// The queue has durably adopted a previously authorized native transition.
    /// Update intent/identity without stop/prepare/play or a second resolver dispatch.
    public func adoptUpcoming(_ media: ServiceID, variant: MediaVariant, next: PlaybackContext, from previous: PlaybackContext, position: Double) throws -> PlaybackSnapshot {
        try check(previous)
        guard machine.intent == .play else { throw DomainError.staleContext }
        var replacement = machine
        guard let occurrence = next.occurrenceID else { throw DomainError.staleContext }
        replacement.select(media, occurrence: occurrence, now: monotonic.now())
        guard replacement.context == next else { throw DomainError.staleContext }
        _ = replacement.receive(.resolved, context: next, now: monotonic.now())
        _ = replacement.receive(.prepared, context: next, now: monotonic.now())
        _ = replacement.receive(.started, context: next, now: monotonic.now())
        _ = replacement.receive(.receiverPosition(position), context: next, now: monotonic.now())
        machine = replacement; self.variant = variant; advanceTransportRevision()
        return machine.snapshot
    }
    public func variantExpiry() -> Date? { variant?.expiresAt }
    public func switchAccount(_ context: RequestContext) async {
        guard context.accountGeneration > machine.context.request.accountGeneration else { return }
        advanceTransportRevision()
        variant = nil
        let previous = machine.snapshot
        let effects = machine.switchAccount(context, now: monotonic.now())
        await perform(effects.filter { $0 != .checkpoint }, context: machine.context)
        await lifecycle.checkpoint(previous)
    }
    public func execute(_ command: PlaybackCommand, context: RequestContext, origin: CommandOrigin, onSelection: (@Sendable (PlaybackContext) async throws -> Void)? = nil, expectedPlaybackContext: PlaybackContext? = nil, onPrepared: (@Sendable (PlaybackContext) async throws -> Void)? = nil) async -> ServiceResult<PlaybackSnapshot> {
        guard context == machine.context.request else { return ServiceResult(context: context, outcome: .failure(.staleContext)) }
        if let expected = expectedPlaybackContext {
            // An early selection reservation may be one generation ahead of the
            // machine while its onSelection callback is suspended. Pause must cancel
            // that reservation, but an older occurrence can never pause a newer one.
            guard expected.request == context, expected.generation >= machine.context.generation,
                  expected.generation != machine.context.generation || expected == machine.context else {
                return ServiceResult(context: context, outcome: .failure(.staleContext))
            }
        }
        switch command {
        case .select, .selectAt, .play, .pause, .route, .sleep, .wake, .quit: advanceTransportRevision()
        case .seek, .gain, .rate, .expire, .quality: break
        }
        let commandRevision = transportRevision
        do {
            switch command {
            case .select, .selectAt:
                let media: ServiceID; let occurrence: UUID; let position: Double
                switch command {
                case .select(let id, let idOccurrence): media = id; occurrence = idOccurrence; position = 0
                case .selectAt(let id, let idOccurrence, let seconds): media = id; occurrence = idOccurrence; position = seconds
                default: preconditionFailure("Selection command required")
                }
                guard position.isFinite, position >= 0 else { throw DomainError.invalidInput(.invalidRange) }
                let revision = transportRevision
                let previousContext = machine.context
                let previousSeek = machine.seekRevision
                var selectedMachine = machine
                selectedMachine.select(media, occurrence: occurrence, now: monotonic.now())
                if position > 0 { _ = try selectedMachine.seek(position, now: monotonic.now()) }
                let token = selectedMachine.context
                // Reserve the exact generation before provider/engine work. A boundary
                // may reject superseded intent before it can replace active transport.
                if let onSelection { try await onSelection(token) }
                guard revision == transportRevision, machine.context == previousContext,
                      machine.seekRevision == previousSeek else { throw DomainError.staleContext }
                machine = selectedMachine; variant = nil
                // Stop the previous transport before any asynchronous eligibility work.
                try await accept(engine.stop(context: token), context: token)
                let caps = await capabilities.capabilities(context: context)
                try check(token)
                let resolvedCaps = try value(caps, context: context)
                guard resolvedCaps.context == context.account else { throw DomainError.staleContext }
                try resolvedCaps.require(.playback, now: wall.now())
                let eligibility = await resolver.validateEligibility(media, context: token)
                let permission = try acceptValue(eligibility, context: token)
                guard let account = context.account else { throw DomainError.unauthorized }
                switch permission.decision(for: account, now: wall.now()) {
                case .allowed: break
                case .denied(let e), .verify(let e), .retry(let e): throw e
                }
                let variants: [MediaVariant]
                do { variants = try await acceptValue(resolver.resolve(media, context: token), context: token) }
                catch DomainError.unauthorized { variants = try await acceptValue(resolver.resolve(media, context: token), context: token) }
                let ordered = variants.sorted {
                    if quality == .dataSaver { return ($0.bitrate ?? Int.max) < ($1.bitrate ?? Int.max) }
                    return ($0.bitrate ?? 0) > ($1.bitrate ?? 0)
                }
                guard let selected = ordered.first else { throw DomainError.unavailableContent }
                guard selected.expiresAt.map({ wall.now() < $0 }) ?? true else { throw DomainError.expiredMedia }
                variant = selected
                machine.receive(.resolved, context: token, now: monotonic.now())
                do { try await accept(engine.prepare(selected, context: token), context: token) }
                catch DomainError.unauthorized {
                    let replacement = try await acceptValue(resolver.refresh(selected, context: token), context: token)
                    guard replacement.expiresAt.map({ wall.now() < $0 }) ?? true else { throw DomainError.expiredMedia }
                    variant = replacement
                    _ = machine.expire()
                    try await accept(engine.prepare(replacement, context: token), context: token)
                }
                if let onPrepared { try await onPrepared(token); try check(token) }
                let effects = machine.receive(.prepared, context: token, now: monotonic.now())
                await perform(effects, context: token)
            case .play:
                // Resume revalidates account capability instead of treating a prior badge as permission.
                let token = machine.context
                let revision = transportRevision
                let result = await capabilities.capabilities(context: context)
                try check(token)
                guard revision == transportRevision else { throw DomainError.staleContext }
                let caps = try value(result, context: context)
                guard caps.context == context.account else { throw DomainError.staleContext }
                try caps.require(.playback, now: wall.now())
                await perform(machine.resume(), context: token)
                guard revision == transportRevision else { throw DomainError.staleContext }
            case .pause(let reason): await perform(machine.pause(reason, now: monotonic.now()), context: machine.context)
            case .seek(let seconds):
                guard variant?.seekable ?? true else { throw DomainError.unsupported }
                seekAuthorizationRevision += 1; let permissionRevision = seekAuthorizationRevision
                let token = machine.context; let transport = transportRevision
                try await accept(engine.validateSeek(context: token), context: token)
                try check(token)
                guard permissionRevision == seekAuthorizationRevision, transport == transportRevision else { throw DomainError.staleContext }
                if let error = await perform(try machine.seek(seconds, now: monotonic.now()), context: token, nonfatalSeekDenial: true) { throw error }
            case .quality(let preference): quality = preference
            case .gain(let gain):
                guard gain.isFinite, (0...1).contains(gain) else { throw DomainError.invalidInput(.invalidRange) }
                try await accept(engine.setGain(gain, context: machine.context), context: machine.context)
            case .rate(let rate):
                guard rate.isFinite, (0.5...3).contains(rate) else { throw DomainError.invalidInput(.invalidRange) }
                try machine.setRate(rate, now: monotonic.now())
                try await accept(engine.setRate(rate, context: machine.context), context: machine.context)
            case .route(let route): await perform(machine.changeRoute(route, now: monotonic.now()), context: machine.context)
            case .sleep: await perform(machine.sleep(now: monotonic.now()), context: machine.context)
            case .wake(let safe, let enabled): await perform(machine.wake(safeRoute: safe, resumeEnabled: enabled), context: machine.context)
            case .expire: await perform(machine.expire(), context: machine.context)
            case .quit: await perform(machine.quit(now: monotonic.now()), context: machine.context)
            }
            guard context == machine.context.request else { throw DomainError.staleContext }
            if let error = machine.error { throw error }
            return ServiceResult(context: context, outcome: .success(machine.snapshot))
        } catch let error as DomainError {
            if error != .staleContext, commandRevision == transportRevision {
                switch command {
                case .select, .selectAt:
                    _ = machine.receive(.failed(error), context: machine.context, now: monotonic.now())
                    _ = await engine.stop(context: machine.context)
                default: break
                }
            }
            return ServiceResult(context: context, outcome: .failure(error))
        } catch { return ServiceResult(context: context, outcome: .failure(.transientTransport)) }
    }
    public func receive(_ event: ScopedEngineEvent) async {
        guard await engine.validatesObservation(event), event.context == machine.context else { return }
        if case .failed(let error) = event.event, error == .unauthorized {
            await perform(machine.expire(failure: error), context: machine.context); return
        }
        let translated: PlaybackEvent
        switch event.event {
        case .prepared: translated = .prepared
        case .started: translated = .started
        case .paused: translated = .paused
        case .position(let seconds): translated = .receiverPosition(seconds)
        case .buffering: translated = .buffering
        case .ended: translated = .ended
        case .failed(let error): translated = error == .offline ? .buffering : .failed(error)
        case .entitlementRevoked: translated = .entitlementRevoked
        }
        // Observation ordering uses capture time. Termination/authority takes effect at
        // receipt, preserving elapsed position through delivery without restoring rights.
        let instant = translated.ordersByObservationTime ? event.observedAt ?? monotonic.now() : monotonic.now()
        let effects = machine.receive(translated, context: event.context, now: instant)
        // Revocation invalidates the old generation before stopping the current engine.
        await perform(effects, context: machine.context)
    }
    private func check(_ context: PlaybackContext) throws(DomainError) {
        guard machine.context == context else { throw .staleContext }
    }
    private func value<T>(_ result: ServiceResult<T>, context: RequestContext) throws(DomainError) -> T {
        guard result.context == context else { throw .staleContext }
        return try result.outcome.get()
    }
    private func acceptValue<T>(_ result: PlaybackResult<T>, context: PlaybackContext) throws(DomainError) -> T {
        try check(context)
        guard result.context == context else { throw .staleContext }
        return try result.outcome.get()
    }
    private func accept(_ result: PlaybackResult<Void>, context: PlaybackContext) throws(DomainError) { try acceptValue(result, context: context) }
    @discardableResult private func perform(_ effects: [PlaybackEffect], context: PlaybackContext, nonfatalSeekDenial: Bool = false) async -> DomainError? {
        for effect in effects {
            guard machine.context == context else { return .staleContext }
            do {
                switch effect {
                case .play:
                    guard machine.intent == .play, machine.state != .seeking else { continue }
                    let revision = transportRevision
                    let seekRevision = machine.seekRevision
                    let response = await engine.play(context: context)
                    try check(context)
                    // An older acknowledgement cannot finish a newer intent or seek.
                    guard revision == transportRevision, seekRevision == machine.seekRevision else {
                        if case .pause = machine.intent { await perform([.pause], context: context) }
                        continue
                    }
                    try accept(response, context: context)
                    await perform(machine.receive(.started, context: context, now: monotonic.now()), context: context)
                    // Same-generation wake/play can resume without selecting a new item.
                    // Publish actual accepted transport so the queue retains its EOS binding.
                    if machine.context == context, machine.state == .playing { await lifecycle.checkpoint(machine.snapshot) }
                case .pause:
                    let revision = transportRevision
                    let response = await engine.pause(context: context)
                    try check(context)
                    guard revision == transportRevision else { continue }
                    try accept(response, context: context)
                case .stop: try await accept(engine.stop(context: context), context: context)
                case .seek(let target, let revision):
                    do { try await accept(engine.seek(to: target, context: context), context: context) }
                    catch let error as DomainError {
                        if error == .forbidden || error == .unsupported {
                            machine.rejectSeek(revision: revision, now: monotonic.now())
                            if nonfatalSeekDenial { return error }
                        }
                        throw error
                    }
                    await perform(machine.receive(.seekCompleted(revision: revision), context: context, now: monotonic.now()), context: context)
                case .checkpoint: await lifecycle.checkpoint(machine.snapshot)
                case .advance: await lifecycle.advance(context: context)
                case .refreshAuthorization:
                    guard let variant else { throw DomainError.expiredMedia }
                    let target = machine.snapshot.position(at: monotonic.now())
                    _ = machine.receive(.receiverPosition(target), context: context, now: monotonic.now())
                    _ = machine.receive(.buffering, context: context, now: monotonic.now())
                    let refreshed = try await acceptValue(resolver.refresh(variant, context: context), context: context)
                    guard refreshed.expiresAt.map({ wall.now() < $0 }) ?? true else { throw DomainError.expiredMedia }
                    self.variant = refreshed
                    try await accept(engine.prepare(refreshed, context: context), context: context)
                    if target > 0 {
                        guard refreshed.seekable else { throw DomainError.unsupported }
                        try await accept(engine.seek(to: target, context: context), context: context)
                    }
                    if machine.intent == .play { await perform([.play], context: context) }
                    else { _ = machine.receive(.paused, context: context, now: monotonic.now()) }
                }
            } catch let error as DomainError {
                guard machine.context == context else { return .staleContext }
                // Superseded native acknowledgements cannot fail/stop a replacement.
                if error == .staleContext { return error }
                _ = machine.receive(.failed(error), context: context, now: monotonic.now())
                _ = await engine.stop(context: context)
                return error
            } catch { return .transientTransport }
        }
        return nil
    }
}

public enum AccountCommand: Sendable { case authenticate, refresh, revoke, removeLocal }
/// Serializes active identity/request generations without exposing session credentials.
public actor SessionCommands {
    private var gate: RequestGate
    private let accounts: any AccountService
    private let playback: PlaybackCommands
    private let mutations: MutationCommands
    public init(context: RequestContext, accounts: any AccountService, playback: PlaybackCommands, mutations: MutationCommands) {
        gate = RequestGate(context: context); self.accounts = accounts; self.playback = playback; self.mutations = mutations
    }
    public func context() -> RequestContext { gate.context }
    public func execute(_ command: AccountCommand, context: RequestContext, origin: CommandOrigin) async -> ServiceResult<Account?> {
        guard gate.accepts(context) else { return .init(context: context, outcome: .failure(.staleContext)) }
        switch command {
        case .authenticate, .refresh:
            let result: ServiceResult<Account>
            if case .authenticate = command { result = await accounts.authenticate(context: context) }
            else { result = await accounts.refresh(context: context) }
            guard gate.accepts(context), result.context == context else { return .init(context: context, outcome: .failure(.staleContext)) }
            return .init(context: context, outcome: result.outcome.map(Optional.some))
        case .revoke, .removeLocal:
            guard let account = context.account else { return .init(context: context, outcome: .failure(.unauthorized)) }
            // Invalidate command ownership before removing credentials/private state.
            let detached = await switchAccount(to: nil)
            guard case .success = detached.outcome, gate.accepts(detached.context) else { return detached }
            let result: ServiceResult<Void>
            if case .revoke = command { result = await accounts.revoke(context: context) }
            else { result = await accounts.removeLocalIdentity(account, context: context) }
            guard gate.accepts(detached.context), result.context == context else { return .init(context: context, outcome: .failure(.staleContext)) }
            return .init(context: context, outcome: result.outcome.map { nil })
        }
    }
    public func switchAccount(to account: AccountContext?) async -> ServiceResult<Account?> {
        let context = gate.switchAccount(account)
        await mutations.switchAccount(context)
        guard gate.accepts(context) else { return ServiceResult(context: context, outcome: .failure(.staleContext)) }
        await playback.switchAccount(context)
        guard gate.accepts(context) else { return ServiceResult(context: context, outcome: .failure(.staleContext)) }
        guard let account else { return ServiceResult(context: context, outcome: .success(nil)) }
        let result = await accounts.switchIdentity(to: account, context: context)
        guard gate.accepts(result.context), result.context == context else { return ServiceResult(context: context, outcome: .failure(.staleContext)) }
        return ServiceResult(context: context, outcome: result.outcome.map(Optional.some))
    }
}

/// Remote mutations pass through this use case from every command origin.
/// Submission is durable before dispatch. Ambiguous outcomes require reads, never blind replay.
public actor MutationCommands {
    private var active: RequestContext
    private let capabilities: any CapabilityProvider
    private let library: any LibraryService
    private let playlists: any PlaylistService
    private let outbox: any MutationOutbox
    private let clock: any WallClock
    public init(context: RequestContext, capabilities: any CapabilityProvider, library: any LibraryService, playlists: any PlaylistService, outbox: any MutationOutbox, clock: any WallClock) {
        active = context; self.capabilities = capabilities; self.library = library; self.playlists = playlists; self.outbox = outbox; self.clock = clock
    }
    public func switchAccount(_ context: RequestContext) {
        guard context.accountGeneration > active.accountGeneration else { return }
        active = context
    }
    private func checked(_ result: ServiceResult<PendingMutation>, context: RequestContext) -> ServiceResult<PendingMutation> {
        guard active == context, result.context == context else { return .init(context: context, outcome: .failure(.staleContext)) }
        return result
    }
    public func execute(_ mutation: PendingMutation, context: RequestContext, origin: CommandOrigin) async -> ServiceResult<PendingMutation> {
        guard active == context, mutation.account == context.account else { return .init(context: context, outcome: .failure(.staleContext)) }
        let permission = await capabilities.capabilities(context: context)
        guard active == context, permission.context == context else { return .init(context: context, outcome: .failure(.staleContext)) }
        do {
            let caps = try permission.outcome.get()
            guard caps.context == mutation.account else { throw DomainError.staleContext }
            try caps.require(mutation.intent.requiredFeature, now: clock.now())
            // Repeated operation IDs consult durable status instead of dispatching twice.
            if mutation.attempts > 0 || mutation.outcome == .needsReconciliation { return checked(await outbox.reconcile(mutation.id, context: context), context: context) }
            let enqueued = await outbox.enqueue(mutation, context: context)
            guard active == context, enqueued.context == context else { throw DomainError.staleContext }
            let stored = try enqueued.outcome.get()
            guard stored.id == mutation.id, stored.account == mutation.account else { throw DomainError.staleContext }
            guard stored.attempts == 0 else { return checked(await outbox.reconcile(stored.id, context: context), context: context) }
            let claim = await outbox.beginAttempt(stored.id, context: context)
            guard active == context, claim.context == context else { throw DomainError.staleContext }
            _ = try claim.outcome.get()
            let result: Result<Void, DomainError>
            switch mutation.intent {
            case .library(let action):
                let response = await library.apply(action, target: mutation.target, operationID: mutation.id, context: context)
                guard response.context == context else { throw DomainError.staleContext }
                result = response.outcome.map { _ in () }
            case .playlist(let action):
                let response = await playlists.apply(action, target: mutation.target, operationID: mutation.id, precondition: mutation.precondition, context: context)
                guard response.context == context else { throw DomainError.staleContext }
                result = response.outcome.map { _ in () }
            }
            guard active == context else { throw DomainError.staleContext }
            switch result {
            case .success: return checked(await outbox.commit(mutation.id, context: context), context: context)
            case .failure(let error): return checked(await outbox.fail(mutation.id, error: error, ambiguous: error == .transientTransport, context: context), context: context)
            }
        } catch let error as DomainError { return .init(context: context, outcome: .failure(error)) }
        catch { return .init(context: context, outcome: .failure(.transientTransport)) }
    }
}
