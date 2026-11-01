import Foundation
import Observation

/// Where upload jobs are kept between launches, one list per account.
public protocol UploadJobStoring: Sendable {
    func load(account: String) async throws -> [UploadJob]
    func save(_ jobs: [UploadJob], account: String) async throws
    func clear(account: String) async throws
}

/// The upload job orchestration for the signed-in account (MEDIA06): picked or dropped files become jobs; one job transfers at a time;
/// the service's processing is watched; the Uploads lists are read again only after the service itself says a file is processed.
///
/// Rules this type keeps:
/// - a job starts only for a file the person chose (picker or drop), after the local checks, and never twice: a file already in the
///   list is refused as a duplicate, and one job is one record whatever happens to it;
/// - resuming is offered only when the transport says it can resume; otherwise an interrupted job says it must start over, and
///   starting over is the person's explicit action, never automatic;
/// - nothing is queued while offline: a transfer that could not continue is shown as stopped;
/// - success needs the service's word. A file is "completed" only after the service reports processing done; a refusal or a
///   processing failure never refreshes the Uploads lists and never shows a library item;
/// - access is per account scope. An account change stops every transfer, tells the transport to drop what it held, releases every
///   file lease and ignores anything the old account's transport reports afterwards;
/// - file access is read-only and held only while a transfer runs. No code here writes, moves or deletes a chosen file;
///   cancelling or discarding a job only ends the job.
@MainActor @Observable public final class UploadQueue {
    /// How many files one choice may add at once (an app limit, not a service one).
    public static let batchLimit = 100
    public static let defaultPollDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10), .seconds(20)] + Array(repeating: .seconds(30), count: 20) + Array(repeating: .seconds(60), count: 20)

    public private(set) var jobs: [UploadJob] = []
    /// What the last choice could not add, and why.
    public private(set) var refusals: [UploadRefusal] = []
    public private(set) var storeFailure: String?
    public var capability: UploadCapability { transport.capability }

    @ObservationIgnored private let transport: any UploadTransport
    @ObservationIgnored private let store: any UploadJobStoring
    @ObservationIgnored private let access: any UploadFileAccessing
    @ObservationIgnored private let baseInspector: UploadSourceInspector
    @ObservationIgnored private let accountKey: @MainActor () -> String?
    @ObservationIgnored private let refresh: @MainActor () async -> Bool
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let pollDelays: [Duration]
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var boundKey: String?
    @ObservationIgnored private var transfers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var polls: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var leases: [UUID: UploadFileLease] = [:]
    @ObservationIgnored private var transferring: UUID?
    @ObservationIgnored private var completing: Set<UUID> = []
    @ObservationIgnored private var cancelling: Set<UUID> = []
    @ObservationIgnored private var persistChain: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var restored = false
    /// Leases handed out and not yet released (a measurement for tests: it is zero whenever nothing is transferring).
    public var openLeaseCount: Int { leases.values.filter { !$0.isReleased }.count }

    public init(transport: any UploadTransport, store: any UploadJobStoring, access: any UploadFileAccessing = ScopedUploadFileAccess(),
                inspector: UploadSourceInspector = UploadSourceInspector(), accountKey: @escaping @MainActor () -> String?,
                refresh: @escaping @MainActor () async -> Bool = { true }, pollDelays: [Duration] = UploadQueue.defaultPollDelays,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }, now: @escaping @MainActor () -> Date = { Date() }) {
        self.transport = transport; self.store = store; self.access = access; baseInspector = inspector; self.accountKey = accountKey
        self.refresh = refresh; self.pollDelays = pollDelays; self.sleep = sleep; self.now = now
    }

    public func job(_ id: UUID) -> UploadJob? { jobs.first { $0.id == id } }
    public var hasActiveJobs: Bool { jobs.contains { $0.isActive } }
    /// Whether this job can continue where it stopped: the transport says it can, and it kept the transport's own handle.
    public func canResume(_ job: UploadJob) -> Bool {
        job.phase == .interrupted && job.handle != nil && capability.isAvailable && capability.resumption == .supported
    }
    /// Starting over re-sends the file from the beginning. It is not offered for a file the service itself refused or could not
    /// process: sending the same file again would only repeat that answer. Choose a corrected file instead.
    public func canStartOver(_ job: UploadJob) -> Bool {
        guard capability.isAvailable else { return false }
        switch job.phase {
        case .interrupted: return true
        case .failed: return job.reason != .serverRefused && job.reason != .processingFailed
        default: return false
        }
    }

    // MARK: Adding files

    /// Checks the chosen files and queues the ones that pass. Returns what was refused (also kept in `refusals`).
    @discardableResult public func add(_ urls: [URL]) async -> [UploadRefusal] {
        guard capability.isAvailable else { return setRefusals(urls.map { UploadRefusal(name: $0.lastPathComponent, reason: .uploadsUnavailable) }) }
        // Nothing is queued until this account's own job list has been read: a file chosen in the moment after an account switch waits
        // for that read, and is then recorded under the new account (never the old one, never as a transfer nobody lists).
        guard let key = await ensureReady() else { return setRefusals(urls.map { UploadRefusal(name: $0.lastPathComponent, reason: .needsAccount) }) }
        let ticket = generation
        var inspector = baseInspector
        inspector.maximumFileBytes = capability.maximumFileBytes
        var refused: [UploadRefusal] = []
        var added = false
        for url in urls.prefix(Self.batchLimit) {
            let result = await inspector.inspect(url)
            guard ticket == generation, accountKey() == key else { return [] }
            switch result {
            case .failure(let reason): refused.append(UploadRefusal(name: url.lastPathComponent, reason: reason))
            case .success(let source):
                if jobs.contains(where: { $0.source.identity == source.identity && ($0.isActive || $0.phase == .completed || $0.phase == .interrupted) }) {
                    refused.append(UploadRefusal(name: source.displayName, reason: .duplicate(of: source.displayName)))
                } else {
                    jobs.append(UploadJob(account: key, source: source, now: now())); added = true
                }
            }
        }
        if urls.count > Self.batchLimit { refused.append(UploadRefusal(name: String(localized: "\(urls.count - Self.batchLimit) more files"), reason: .tooManyAtOnce(Self.batchLimit))) }
        _ = setRefusals(refused)
        if added { persist(); pump() }
        return refused
    }
    @discardableResult private func setRefusals(_ list: [UploadRefusal]) -> [UploadRefusal] { refusals = list; return list }
    public func dismissRefusals() { refusals = [] }

    // MARK: The person's actions on one job

    /// Stops a job. A file the service already holds may still be processed by it (`serverMayStillProcess`); the chosen file on this
    /// Mac is never touched.
    public func cancel(_ id: UUID) async {
        guard let job = job(id), job.isActive || job.phase == .interrupted else { return }
        let held = job.handle
        let processing = job.phase == .processing
        transfers[id]?.cancel(); transfers[id] = nil; polls[id]?.cancel(); polls[id] = nil
        update(id) { $0.serverMayStillProcess = processing; _ = $0.move(to: .cancelled, reason: .byUser, now: now()) }
        release(id)
        persist()
        // The route is told to drop the cancelled upload before anything else is started: the next transfer waits for this call, so a
        // route that does not stop at once never overlaps two transfers.
        cancelling.insert(id)
        await transport.cancel(handle: held)
        cancelling.remove(id)
        if transferring == id { transferring = nil }
        pump()
    }
    /// Continues an interrupted job where the transport can continue it. False when it cannot (nothing happens).
    @discardableResult public func resume(_ id: UUID) -> Bool {
        guard let job = job(id), canResume(job) else { return false }
        update(id) { _ = $0.move(to: .queued, now: now()) }
        persist(); pump(); return true
    }
    /// Sends the file again from the beginning, as a new attempt of the same job (never a second job).
    @discardableResult public func startOver(_ id: UUID) -> Bool {
        guard let job = job(id), canStartOver(job) else { return false }
        update(id) { $0.handle = nil; $0.bytesSent = 0; $0.attempts += 1; $0.serverMayStillProcess = false; $0.checkNote = nil; _ = $0.move(to: .queued, now: now()) }
        persist(); pump(); return true
    }
    /// Asks the service about a file that is still being processed, now.
    public func checkNow(_ id: UUID) async {
        guard job(id)?.phase == .processing else { return }
        polls[id]?.cancel(); polls[id] = nil
        var errors = 0
        let settled = await checkOnce(id, generation: generation, errors: &errors)
        if !settled, job(id)?.phase == .processing { startPolling(id, generation: generation) }
    }
    /// Removes a finished job from the list. Only the record goes: the chosen file is never touched.
    public func dismiss(_ id: UUID) {
        guard let job = job(id), job.isTerminal else { return }
        jobs.removeAll { $0.id == id }
        persist()
    }

    // MARK: Transfers

    private func pump() {
        guard transferring == nil, cancelling.isEmpty, capability.isAvailable, let next = jobs.first(where: { $0.phase == .queued }) else { return }
        transferring = next.id
        let g = generation, id = next.id
        transfers[id] = Task { [weak self] in await self?.transfer(id, generation: g) }
    }
    private func transfer(_ id: UUID, generation g: UInt64) async {
        defer { if g == generation { transfers[id] = nil; if transferring == id { transferring = nil }; pump() } }
        guard g == generation, let job = job(id), job.phase == .queued else { return }
        let lease: UploadFileLease
        do { lease = try access.open(job.source) }
        catch UploadFileAccessError.changed { fail(id, .fileChanged, nil); return }
        catch { fail(id, .fileUnreadable, nil); return }
        leases[id] = lease
        let resumeHandle = capability.resumption == .supported ? job.handle : nil
        update(id) { _ = $0.move(to: .uploading, now: now()) }
        persist()
        let request = UploadRequest(jobID: id, fileURL: lease.url, byteCount: job.source.byteCount, metadata: job.source.metadata, resumeHandle: resumeHandle)
        do {
            let handle = try await transport.upload(request, progress: { [weak self] sent in Task { @MainActor in self?.progressed(id, sent, g) } },
                                                    handle: { [weak self] known in Task { @MainActor in self?.handleKnown(id, known, g) } })
            guard g == generation, self.job(id)?.phase == .uploading else { release(id); return }
            release(id)
            update(id) { $0.handle = handle; $0.bytesSent = $0.source.byteCount; _ = $0.move(to: .processing, now: now()) }
            persist()
            startPolling(id, generation: g)
        } catch {
            release(id)
            guard g == generation, self.job(id)?.phase == .uploading else { return }
            switch (error as? UploadTransportError) ?? .unavailable {
            case .offline: stop(id, .offline)
            case .unavailable, .cancelled: stop(id, .unavailable)
            case .rateLimited: stop(id, .rateLimited)
            case .needsSignIn: fail(id, .needsSignIn, nil)
            case .sessionEnded: fail(id, .sessionEnded, nil)
            case .resumeRejected: fail(id, .resumeRejected, nil)
            case .refused(let message): fail(id, .serverRefused, message)
            }
        }
    }
    private func progressed(_ id: UUID, _ sent: Int64, _ g: UInt64) {
        guard g == generation, job(id)?.phase == .uploading else { return }
        update(id) { $0.bytesSent = max($0.bytesSent, min(sent, $0.source.byteCount)) }
    }
    private func handleKnown(_ id: UUID, _ handle: String, _ g: UInt64) {
        guard g == generation, job(id)?.phase == .uploading, job(id)?.handle != handle else { return }
        update(id) { $0.handle = handle }
        persist()
    }
    /// A transfer that could not continue for a reason that may pass: it stays in the list as stopped, to be resumed or restarted by the person.
    private func stop(_ id: UUID, _ reason: UploadJob.Reason) {
        update(id) { _ = $0.move(to: .interrupted, reason: reason, now: now()) }
        persist()
    }
    private func fail(_ id: UUID, _ reason: UploadJob.Reason, _ message: String?) {
        update(id) { _ = $0.move(to: .failed, reason: reason, message: message, now: now()) }
        persist()
    }
    private func release(_ id: UUID) { leases[id]?.release(); leases[id] = nil }

    // MARK: Processing

    private func startPolling(_ id: UUID, generation g: UInt64) {
        polls[id]?.cancel()
        polls[id] = Task { [weak self] in await self?.poll(id, generation: g) }
    }
    private func poll(_ id: UUID, generation g: UInt64) async {
        var errors = 0
        for delay in pollDelays {
            do { try await sleep(delay) } catch { return }
            if await checkOnce(id, generation: g, errors: &errors) { return }
        }
        guard g == generation, job(id)?.phase == .processing else { return }
        update(id) { $0.checkNote = String(localized: "YouTube Music is still processing this file. Check again later.") }
    }
    /// One question to the service. True when polling should stop (the job settled, or nothing more can be asked).
    private func checkOnce(_ id: UUID, generation g: UInt64, errors: inout Int) async -> Bool {
        guard g == generation, let job = job(id), job.phase == .processing, let handle = job.handle, !completing.contains(id) else { return true }
        do {
            let status = try await transport.processing(handle: handle)
            guard g == generation, self.job(id)?.phase == .processing else { return true }
            switch status {
            case .processing:
                update(id) { $0.checkNote = nil }; errors = 0; return false
            case .failed(let message):
                fail(id, .processingFailed, message); return true
            case .completed:
                completing.insert(id); defer { completing.remove(id) }
                let refreshed = await refresh()
                guard g == generation, self.job(id)?.phase == .processing else { return true }
                update(id) { $0.listing = refreshed ? .refreshed : .refreshFailed; $0.checkNote = nil; _ = $0.move(to: .completed, now: now()) }
                persist(); return true
            }
        } catch {
            guard g == generation, self.job(id)?.phase == .processing else { return true }
            switch (error as? UploadTransportError) ?? .unavailable {
            case .needsSignIn, .sessionEnded:
                update(id) { $0.checkNote = UploadJob.Reason.sessionEnded.message }; return true
            default:
                errors += 1
                update(id) { $0.checkNote = String(localized: "YouTube Music couldn’t be asked just now. Trying again.") }
                if errors >= 5 { update(id) { $0.checkNote = String(localized: "YouTube Music couldn’t be reached. Check again later.") }; return true }
                return false
            }
        }
    }

    // MARK: Account scope and restart

    /// The active account (or whether its session is live) changed: everything the old account held is stopped now, and the new
    /// account's own jobs are read. Whatever the old transport reports afterwards is ignored.
    public func accountChanged() {
        generation &+= 1
        let oldKey = boundKey
        // One cancel per transfer that was running, with the transport's handle when it had reported one.
        let held = jobs.filter { $0.phase == .uploading }.map(\.handle)
        for task in transfers.values { task.cancel() }
        for task in polls.values { task.cancel() }
        transfers = [:]; polls = [:]; transferring = nil; completing = []
        for id in Array(leases.keys) { release(id) }
        var old = jobs
        for index in old.indices where old[index].phase == .queued || old[index].phase == .uploading { _ = old[index].move(to: .interrupted, reason: .accountChanged, now: now()) }
        jobs = []; refusals = []; storeFailure = nil; restored = false; boundKey = nil
        let transport = transport
        let previous = persistChain
        persistChain = Task { [store] in
            await previous?.value
            if let oldKey, !old.isEmpty { try? await store.save(old, account: oldKey) }
            for handle in held { await transport.cancel(handle: handle) }
        }
        restoreTask = Task { [weak self] in await self?.persistChain?.value; await self?.restore() }
    }
    /// Reads this account's jobs. Anything that was queued or transferring when the app stopped is shown as interrupted; a file the
    /// service already holds goes back to being watched. Nothing is restarted by itself.
    public func restoreIfNeeded() async {
        if let task = restoreTask { await task.value }
        if restored, boundKey == accountKey() { return }
        await restore()
    }
    /// The account key this queue is bound to once its job list has been read; nil while a switch is still being settled (or with no account).
    private func ensureReady() async -> String? {
        if let task = restoreTask { await task.value }
        let key = accountKey()
        if !restored || boundKey != key { await restore() }
        guard restored, let key, boundKey == key, key == accountKey() else { return nil }
        return key
    }
    public func restore() async {
        let g = generation
        boundKey = accountKey()
        guard let key = boundKey else { jobs = []; restored = true; return }
        do {
            var loaded = try await store.load(account: key)
            guard g == generation else { return }
            restored = true
            // Whatever is running for a job that is not in this list is stopped: nothing may run unlisted.
            let listed = Set(loaded.map(\.id))
            for (id, task) in transfers where !listed.contains(id) { task.cancel(); transfers[id] = nil; release(id) }
            for (id, task) in polls where !listed.contains(id) { task.cancel(); polls[id] = nil }
            if let running = transferring, !listed.contains(running) { transferring = nil }
            var changed = false
            for index in loaded.indices where loaded[index].phase == .queued || loaded[index].phase == .uploading {
                _ = loaded[index].move(to: .interrupted, reason: .appClosed, now: now()); changed = true
            }
            jobs = loaded; storeFailure = nil
            if changed { persist() }
            for job in loaded where job.phase == .processing { startPolling(job.id, generation: g) }
        } catch {
            guard g == generation else { return }
            restored = true
            jobs = []; storeFailure = String(localized: "The upload list couldn’t be read. Jobs from before aren’t shown.")
        }
    }
    /// Waits for the work an account change started (the new account's jobs read), and for every save made so far.
    public func settled() async {
        await restoreTask?.value
        await persistChain?.value
    }

    // MARK: Bookkeeping

    private func update(_ id: UUID, _ change: (inout UploadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }
    private func persist() {
        guard let key = boundKey else { return }
        let kept = Self.pruned(jobs)
        if kept.count != jobs.count { jobs = kept }
        let snapshot = jobs
        let previous = persistChain
        persistChain = Task { [store, weak self] in
            await previous?.value
            do { try await store.save(snapshot, account: key) }
            catch { self?.storeFailed() }
        }
    }
    private func storeFailed() { storeFailure = String(localized: "The upload list couldn’t be saved. It won’t survive a restart.") }
    /// A bounded list: finished jobs beyond the newest 200 are dropped from the record (never anything still running).
    static func pruned(_ jobs: [UploadJob]) -> [UploadJob] {
        let finished = jobs.filter(\.isTerminal)
        guard finished.count > 200 else { return jobs }
        let drop = Set(finished.sorted { $0.updatedAt < $1.updatedAt }.prefix(finished.count - 200).map(\.id))
        return jobs.filter { !drop.contains($0.id) }
    }
}
