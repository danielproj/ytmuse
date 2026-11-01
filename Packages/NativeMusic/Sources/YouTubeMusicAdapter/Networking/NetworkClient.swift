import Foundation
import Domain

public struct RateLimitBound: Error, Sendable, Equatable {
    /// Nil means absent or unreadable. This is a duration, never a private URL/header string.
    public let retryAfterSeconds: TimeInterval?
    public init(retryAfterSeconds: TimeInterval?) { self.retryAfterSeconds = retryAfterSeconds }
}
/// FIFO among ready requests. Cooling/paced keys never occupy a shared transfer slot.
public actor NetworkScheduler {
    public static let shared = NetworkScheduler()
    public nonisolated let fence: NetworkAccountFence
    private struct Key: Hashable { let account: AccountContext?; let host: String }
    private struct Cooldown { let until: TimeInterval; let reported: TimeInterval }
    private struct Admission {
        let id: UUID; let request: BoundedRequest; let context: RequestContext
        let deadline: TimeInterval; let waiter: NetworkWaiter<Void>
    }
    private var activeMetadata = 0, activeMedia = 0
    private var metadataLimit = 6, mediaLimit = 2
    private var next: [Key: TimeInterval] = [:]
    private var cooldown: [Key: Cooldown] = [:]
    private var queue: [Admission] = []
    private var timer: Task<Void, Never>?
    private var timerID = UUID()
    private let time: any NetworkTime
    private let interval: TimeInterval
    /// Implausible headers are surfaced unchanged, but only quarantine a key for at most one day.
    public static let cooldownHorizon: TimeInterval = 86400
    public init(time: any NetworkTime = ContinuousNetworkTime(), interval: TimeInterval = 0.2,
                fence: NetworkAccountFence = .init()) {
        self.time = time; self.interval = interval.isFinite ? max(0, interval) : 0.2; self.fence = fence
    }
    public func reduceUnderContention(metadata: Int, media: Int) {
        metadataLimit = max(1, min(6, metadata)); mediaLimit = max(1, min(2, media)); pump()
    }
    func postpone(_ request: BoundedRequest, context: RequestContext, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let key = Key(account: context.account, host: request.route.host)
        let until = time.now() + min(Self.cooldownHorizon, seconds)
        if until >= (cooldown[key]?.until ?? 0) { cooldown[key] = Cooldown(until: until, reported: seconds) }
        pump()
    }
    func acquire(_ request: BoundedRequest, context: RequestContext) async throws {
        try Task.checkCancellation(); try fence.validate(context)
        guard queue.count < 256 else { throw RateLimitBound(retryAfterSeconds: nil) }
        let id = UUID(), waiter = NetworkWaiter<Void>()
        queue.append(Admission(id: id, request: request, context: context, deadline: time.now() + request.bounds.seconds, waiter: waiter))
        pump()
        do {
            try await waiter.value { Task { await self.cancel(id) } }
            // A permit may have been handed off just before cancellation. Return it exactly once.
            if Task.isCancelled { release(request); throw NetworkFault.cancelled }
            do { try fence.validate(context) } catch { release(request); throw error }
        } catch { throw DirectBoundedTransport.sanitizePreservingLimit(error) }
    }
    var queuedCount: Int { queue.count }
    var transferCounts: (Int, Int) { (activeMetadata, activeMedia) }
    private func cancel(_ id: UUID) { queue.removeAll { $0.id == id }; pump() }
    func release(_ request: BoundedRequest) {
        if request.route.purpose == .media { activeMedia -= 1 } else { activeMetadata -= 1 }
        pump()
    }
    /// One event timer for the earliest readiness/deadline, plus release/cancel notifications. No polling.
    private func pump() {
        timer?.cancel(); timer = nil; timerID = UUID()
        let now = time.now()
        next = next.filter { $0.value > now }; cooldown = cooldown.filter { $0.value.until > now }
        var pending: [Admission] = [], wake: TimeInterval?
        for entry in queue {
            guard entry.waiter.pending else { continue }
            do { try fence.validate(entry.context) } catch { entry.waiter.resolve(.failure(error)); continue }
            let key = Key(account: entry.context.account, host: entry.request.route.host)
            if let bound = cooldown[key], bound.until > entry.deadline {
                let delay = bound.reported > Self.cooldownHorizon ? bound.reported : max(0, bound.until - now)
                entry.waiter.resolve(.failure(RateLimitBound(retryAfterSeconds: delay))); continue
            }
            let ready = max(next[key] ?? now, cooldown[key]?.until ?? now)
            if now >= entry.deadline || ready > entry.deadline {
                entry.waiter.resolve(.failure(NetworkFault.timeout)); continue
            }
            let media = entry.request.route.purpose == .media
            let capacity = media ? activeMedia < mediaLimit : activeMetadata < metadataLimit
            if ready <= now && capacity {
                if entry.waiter.resolve(.success(())) {
                    if media { activeMedia += 1 } else { activeMetadata += 1 }
                    // Rejected/cancelled waiters never reserve a future start.
                    next[key] = now + interval
                }
            } else {
                pending.append(entry)
                wake = min(wake ?? entry.deadline, entry.deadline)
                if ready > now { wake = min(wake!, ready) }
            }
        }
        queue = pending
        if let wake {
            let id = timerID, time = time
            timer = Task {
                do { try await time.sleep(until: wake); try Task.checkCancellation(); self.wake(id) } catch { }
            }
        }
    }
    private func wake(_ id: UUID) { if timerID == id { pump() } }
}
public struct RetryBudget: Sendable {
    public let attempts: Int
    public let seconds: TimeInterval
    public init(attempts: Int = 3, seconds: TimeInterval = 20) throws {
        guard (1...4).contains(attempts), seconds.isFinite, seconds > 0, seconds <= 60 else { throw NetworkFault.input }
        self.attempts = attempts; self.seconds = seconds
    }
}
/// One owner per independent feature/query generation. Share its scheduler, not its current context.
public actor BoundedNetworkClient {
    private let routes: Set<NetworkRoute>
    private let transport: DirectBoundedTransport
    private let scheduler: NetworkScheduler
    private let credentials: (any ScopedNetworkCredentials)?
    private let time: any NetworkTime
    private let jitter: @Sendable () -> Double
    private var current: RequestContext?
    private var tasks: [UUID: Task<BoundedResponse, Error>] = [:]
    public init(routes: Set<NetworkRoute>, transport: DirectBoundedTransport = .shared,
                scheduler: NetworkScheduler = .shared, credentials: (any ScopedNetworkCredentials)? = nil,
                time: any NetworkTime = ContinuousNetworkTime(), jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.routes = routes; self.transport = transport; self.scheduler = scheduler
        self.credentials = credentials; self.time = time; self.jitter = jitter
    }
    /// High-water guard includes identity at equal generation; a late bind cannot resurrect an old account.
    public func bind(_ context: RequestContext) throws {
        if let old = current {
            guard context.accountGeneration > old.accountGeneration ||
                    (context.accountGeneration == old.accountGeneration && context.account == old.account && context.requestGeneration >= old.requestGeneration) else { throw NetworkFault.stale }
        }
        try scheduler.fence.publish(context)
        if current != context { for task in tasks.values { task.cancel() }; tasks.removeAll(); current = context }
    }
    public func send(_ request: BoundedRequest, context: RequestContext, budget: RetryBudget) async throws -> BoundedResponse {
        guard current == context else { throw NetworkFault.stale }
        try scheduler.fence.validate(context)
        guard routes.contains(request.route), request.credential == nil || context.account != nil else { throw NetworkFault.policy }
        guard tasks.count < 128 else { throw RateLimitBound(retryAfterSeconds: nil) }
        let id = UUID(), transport = transport, scheduler = scheduler, credentials = credentials, time = time, jitter = jitter
        let task = Task<BoundedResponse, Error> {
            let start = time.now()
            for attempt in 0..<budget.attempts {
                try Task.checkCancellation()
                if attempt > 0 && time.now() - start >= budget.seconds { throw NetworkFault.timeout }
                try scheduler.fence.validate(context)
                var authorization: String?
                if let reference = request.credential {
                    guard let credentials else { throw NetworkFault.authentication }
                    do { authorization = try await credentials.authorization(reference: reference, context: context) }
                    catch { throw NetworkFault.authentication }
                }
                try Task.checkCancellation()
                try await scheduler.acquire(request, context: context)
                let result: Result<BoundedResponse, Error>
                do {
                    try Task.checkCancellation(); try scheduler.fence.validate(context)
                    result = .success(try await transport.send(request, authorization: authorization))
                }
                catch { result = .failure(error) }
                await scheduler.release(request)
                try Task.checkCancellation(); try scheduler.fence.validate(context)
                var delay: TimeInterval?
                switch result {
                case .success(let response):
                    if response.status == 401 { throw NetworkFault.authentication }
                    if response.status == 403 { throw NetworkFault.forbidden }
                    if response.status == 429 || response.status == 503 {
                        delay = Self.retryAfter(response.retryAfter, now: time.wallNow())
                        if let delay { await scheduler.postpone(request, context: context, seconds: delay) }
                    }
                    if (200...299).contains(response.status) { return response }
                    guard response.status == 429 || (500...599).contains(response.status) else { throw NetworkFault.http }
                    let final = attempt + 1 == budget.attempts || request.route.replay != .knownRead
                    let remaining = budget.seconds - (time.now() - start)
                    if final || (delay ?? 0) > remaining {
                        if response.status == 429 || delay != nil { throw RateLimitBound(retryAfterSeconds: delay) }
                        throw NetworkFault.server
                    }
                case .failure(let error):
                    let fault = DirectBoundedTransport.sanitize(error)
                    guard request.route.replay == .knownRead, [.timeout, .dns, .offline, .transport].contains(fault),
                          attempt + 1 < budget.attempts else { throw fault }
                }
                let random = jitter()
                let backoff = pow(2, Double(attempt)) * (0.5 + (random.isFinite ? min(1, max(0, random)) : 0.5))
                let wait = max(delay ?? 0, backoff)
                guard time.now() - start + wait <= budget.seconds else { throw NetworkFault.timeout }
                try await time.sleep(until: time.now() + wait)
            }
            throw NetworkFault.transport
        }
        tasks[id] = task
        defer { tasks[id] = nil }
        do {
            let response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard current == context else { throw NetworkFault.stale }
            try scheduler.fence.validate(context)
            try Task.checkCancellation()
            return response
        } catch {
            guard current == context else { throw NetworkFault.stale }
            try scheduler.fence.validate(context)
            if let rate = error as? RateLimitBound { throw rate }
            throw DirectBoundedTransport.sanitize(error)
        }
    }
    static func retryAfter(_ raw: String?, now: Date) -> TimeInterval? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        // A huge all-digit prefix must fail conservatively, never become an early retry through overflow.
        if text.utf8.count > 128 {
            return text.utf8.prefix(129).allSatisfy({ (48...57).contains($0) }) ? .greatestFiniteMagnitude : nil
        }
        if !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) {
            return Double(text).flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
        }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = format
            // Anchor two-digit years to the injected wall time, not the machine's current century.
            formatter.twoDigitStartDate = now.addingTimeInterval(-50 * 365.25 * 86400)
            if let date = formatter.date(from: text) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }
}

extension BoundedNetworkClient {
    public func sendEnvelope(_ request: BoundedRequest, context: RequestContext, budget: RetryBudget) async -> NetworkEnvelope {
        do { return .init(context: context, outcome: .success(try await send(request, context: context, budget: budget))) }
        catch let limit as RateLimitBound { return .init(context: context, outcome: .failure(.init(fault: .rateLimited, retryAfterSeconds: limit.retryAfterSeconds))) }
        catch { return .init(context: context, outcome: .failure(.init(fault: DirectBoundedTransport.sanitize(error)))) }
    }
}
