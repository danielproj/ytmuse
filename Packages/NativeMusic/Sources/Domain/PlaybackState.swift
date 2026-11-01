import Foundation

public enum PlaybackState: String, CaseIterable, Sendable { case idle, resolving, preparing, ready, playing, paused, buffering, seeking, ended, failed }
public enum PauseReason: String, Sendable { case user, routeLoss, accountSwitch, sleep, quit, entitlementRevoked, network, restored }
public enum PlaybackIntent: Equatable, Sendable { case play, pause(PauseReason) }
public struct PlaybackSnapshot: Sendable {
    public let context: PlaybackContext
    public let state: PlaybackState
    public let item: ServiceID?
    public let position: Double
    public let monotonicAnchor: Duration
    public let rate: Double
    public let intent: PlaybackIntent
    public let error: DomainError?
    public var pauseReason: PauseReason? { if case .pause(let reason) = intent { reason } else { nil } }
    public func position(at instant: Duration) -> Double {
        guard state == .playing else { return position }
        let elapsed = max(.zero, instant - monotonicAnchor).components
        return position + (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) * rate
    }
}
public enum PlaybackEvent: Sendable {
    case resolved, prepared, started, paused, buffering, networkRecovered
    case seekCompleted(revision: UInt64)
    case ended, failed(DomainError), entitlementRevoked
    case receiverPosition(Double)

    /// Position/transport observations can be reordered; authority is not renewed by them.
    var ordersByObservationTime: Bool {
        switch self {
        case .started, .paused, .buffering, .networkRecovered, .receiverPosition: true
        case .resolved, .prepared, .seekCompleted, .ended, .failed, .entitlementRevoked: false
        }
    }
}
public enum PlaybackEffect: Equatable, Sendable { case play, pause, seek(Double, revision: UInt64), advance, refreshAuthorization, stop, checkpoint }
/// Pure transition rules shared by all command surfaces. No decoder, timer, or provider data.
public struct PlaybackMachine: Sendable {
    public private(set) var context: PlaybackContext
    public private(set) var state: PlaybackState = .idle
    public private(set) var item: ServiceID?
    public private(set) var intent: PlaybackIntent = .pause(.restored)
    public private(set) var position: Double = 0
    public private(set) var anchor: Duration = .zero
    public private(set) var rate: Double = 1
    public private(set) var error: DomainError?
    public private(set) var seekRevision: UInt64 = 0
    private var pendingSeek: Double?
    private var seekOrigin: (snapshot: PlaybackSnapshot, awaitingStart: Bool)?
    private var prepared = false
    private var awaitingStart = false
    private var endHandled = false
    private var refreshed = false
    private var preSleepIntent: PlaybackIntent?
    public init(request: RequestContext) { context = PlaybackContext(request: request, generation: 0, occurrenceID: nil, route: nil) }
    public var snapshot: PlaybackSnapshot { PlaybackSnapshot(context: context, state: state, item: item, position: position, monotonicAnchor: anchor, rate: rate, intent: intent, error: error) }
    public func checkpointPosition(at instant: Duration) -> Double? {
        guard prepared else { return nil }
        return snapshot.position(at: instant)
    }
    public mutating func select(_ media: ServiceID, occurrence: UUID, now: Duration) {
        invalidate(request: context.request, route: context.route, occurrence: occurrence)
        item = media; state = .resolving; intent = .play; position = 0; anchor = now
        prepared = false; awaitingStart = false; endHandled = false; refreshed = false; pendingSeek = nil; error = nil; preSleepIntent = nil
    }
    private mutating func invalidate(request: RequestContext, route: RouteID?, occurrence: UUID?) {
        seekOrigin = nil
        precondition(context.generation < .max, "Playback generation exhausted")
        context = PlaybackContext(request: request, generation: context.generation + 1, occurrenceID: occurrence, route: route)
    }
    public mutating func switchAccount(_ request: RequestContext, now: Duration) -> [PlaybackEffect] {
        invalidate(request: request, route: nil, occurrence: nil)
        item = nil; position = 0; anchor = now; prepared = false; awaitingStart = false; pendingSeek = nil; preSleepIntent = nil
        state = .idle; intent = .pause(.accountSwitch); error = nil
        return [.stop, .checkpoint]
    }
    public mutating func changeRoute(_ route: RouteID?, now: Duration) -> [PlaybackEffect] {
        position = snapshot.position(at: now); anchor = now
        invalidate(request: context.request, route: route, occurrence: context.occurrenceID)
        awaitingStart = false; intent = .pause(.routeLoss); state = item == nil ? .idle : .paused; preSleepIntent = nil
        return [.stop, .checkpoint]
    }
    public mutating func pause(_ reason: PauseReason, now: Duration) -> [PlaybackEffect] {
        if let origin = seekOrigin {
            let old = origin.snapshot
            seekOrigin = (PlaybackSnapshot(context: old.context, state: .paused, item: old.item, position: old.position(at: now), monotonicAnchor: now, rate: old.rate, intent: .pause(reason), error: old.error), false)
        }
        position = snapshot.position(at: now); anchor = now; intent = .pause(reason)
        if reason != .sleep { preSleepIntent = nil }
        awaitingStart = false
        if prepared, pendingSeek == nil { state = .paused }
        return [.pause, .checkpoint]
    }
    public mutating func resume() -> [PlaybackEffect] {
        guard item != nil, error == nil else { return [] }
        intent = .play
        guard prepared, pendingSeek == nil, state != .playing else { return [] }
        awaitingStart = true
        return [.play]
    }
    public mutating func seek(_ seconds: Double, now: Duration) throws(DomainError) -> [PlaybackEffect] {
        guard seconds.isFinite, seconds >= 0, item != nil else { throw .invalidInput(.invalidRange) }
        if pendingSeek == nil { seekOrigin = (snapshot, awaitingStart) }
        precondition(seekRevision < .max, "Seek revision exhausted")
        awaitingStart = false
        seekRevision += 1; pendingSeek = seconds; position = seconds; anchor = now
        guard prepared else { return [] }
        state = .seeking
        return [.seek(seconds, revision: seekRevision)]
    }
    /// A permission refusal before native movement does not establish the requested position.
    public mutating func rejectSeek(revision: UInt64, now: Duration) {
        guard revision == seekRevision, pendingSeek != nil, let origin = seekOrigin else { return }
        pendingSeek = nil; seekOrigin = nil
        position = origin.snapshot.position(at: now); anchor = now
        if case .pause = intent { state = .paused; awaitingStart = false }
        else { state = origin.snapshot.state; awaitingStart = origin.awaitingStart }
    }
    public mutating func setRate(_ value: Double, now: Duration) throws(DomainError) {
        guard value.isFinite, value > 0 else { throw .invalidInput(.invalidRange) }
        position = snapshot.position(at: now); anchor = now; rate = value
    }
    public mutating func expire(failure: DomainError = .expiredMedia) -> [PlaybackEffect] {
        guard item != nil, !refreshed else { state = .failed; error = failure; return [.stop] }
        refreshed = true
        if prepared, intent == .play, pendingSeek == nil { awaitingStart = state != .playing }
        return [.refreshAuthorization]
    }
    public mutating func sleep(now: Duration) -> [PlaybackEffect] {
        preSleepIntent = intent; return pause(.sleep, now: now)
    }
    public mutating func wake(safeRoute: Bool, resumeEnabled: Bool) -> [PlaybackEffect] {
        defer { preSleepIntent = nil }
        guard intent == .pause(.sleep), preSleepIntent == .play, safeRoute, resumeEnabled else { return [] }
        return resume()
    }
    public mutating func quit(now: Duration) -> [PlaybackEffect] {
        _ = pause(.quit, now: now)
        invalidate(request: context.request, route: context.route, occurrence: context.occurrenceID)
        state = .idle; prepared = false; awaitingStart = false; pendingSeek = nil; error = nil
        return [.stop, .checkpoint]
    }
    @discardableResult public mutating func receive(_ event: PlaybackEvent, context: PlaybackContext, now: Duration) -> [PlaybackEffect] {
        guard context == self.context else { return [] }
        // A later position is not recovery or authorization. Only observations use time
        // suppression; completions use their state/revision and authority always applies.
        if event.ordersByObservationTime, now < anchor { return [] }
        switch event {
        case .resolved:
            guard state == .resolving else { return [] }; state = .preparing
        case .prepared:
            guard state == .preparing else { return [] }; prepared = true; state = .ready
            if let target = pendingSeek { state = .seeking; return [.seek(target, revision: seekRevision)] }
            if intent == .play { awaitingStart = true; return [.play] }; state = .paused
        case .started:
            guard prepared, state != .ended, state != .failed else { return [] }
            guard intent == .play else { return [.pause] }
            // A seek owns its completion; a delayed start cannot leave seeking.
            guard pendingSeek == nil else { return [] }
            // Repeated started notifications are observations, not new clock anchors.
            guard state != .playing else { return [] }
            // Native engines may recover from buffering without a separate recovery event.
            guard awaitingStart || state == .buffering else { return [.pause] }
            position = snapshot.position(at: now); anchor = now
            state = .playing; awaitingStart = false
        case .paused:
            guard prepared, state != .ended, state != .failed, pendingSeek == nil else { return [] }
            // A delayed pause acknowledgement cannot cancel a newer requested start.
            guard !awaitingStart || intent != .play else { return [] }
            position = snapshot.position(at: now); anchor = now
            state = .paused; awaitingStart = false
        case .buffering:
            guard prepared, state != .ended, state != .failed, pendingSeek == nil else { return [] }
            position = snapshot.position(at: now); anchor = now; state = .buffering
        case .networkRecovered:
            guard state == .buffering, intent == .play else { return [] }
            awaitingStart = true; return [.play]
        case .seekCompleted(let revision):
            guard revision == seekRevision, state == .seeking else { return [] }
            pendingSeek = nil; seekOrigin = nil; anchor = max(anchor, now); state = .paused
            if intent == .play { awaitingStart = true; return [.play] }
        case .ended:
            guard prepared, !endHandled, state != .failed else { return [] }
            freezePosition(at: now)
            endHandled = true; awaitingStart = false; state = .ended
            return [.stop, .advance, .checkpoint]
        case .failed(let failure):
            freezePosition(at: now)
            awaitingStart = false; state = .failed; error = failure; return [.stop]
        case .entitlementRevoked:
            freezePosition(at: now)
            intent = .pause(.entitlementRevoked); preSleepIntent = nil
            invalidate(request: context.request, route: context.route, occurrence: context.occurrenceID)
            awaitingStart = false; state = .failed; error = .forbidden; return [.stop, .checkpoint]
        case .receiverPosition(let seconds):
            guard seconds.isFinite, seconds >= 0, prepared, pendingSeek == nil, state != .ended, state != .failed else { return [] }
            position = seconds; anchor = now
        }
        return []
    }
    private mutating func freezePosition(at instant: Duration) {
        let transitionTime = max(anchor, instant)
        position = snapshot.position(at: transitionTime)
        anchor = transitionTime
    }
}

/// Per-feature request generation. A response must match identity, channel, region AND query.
public struct RequestGate: Sendable {
    public private(set) var context: RequestContext
    public init(account: AccountContext? = nil) { context = RequestContext(account: account, accountGeneration: 0, requestGeneration: 0) }
    public init(context: RequestContext) { self.context = context }
    public mutating func next() -> RequestContext {
        precondition(context.requestGeneration < .max)
        context = RequestContext(account: context.account, accountGeneration: context.accountGeneration, requestGeneration: context.requestGeneration + 1); return context
    }
    public mutating func switchAccount(_ account: AccountContext?) -> RequestContext {
        precondition(context.accountGeneration < .max)
        context = RequestContext(account: account, accountGeneration: context.accountGeneration + 1, requestGeneration: 0); return context
    }
    public func accepts(_ result: RequestContext) -> Bool { result == context }
}
