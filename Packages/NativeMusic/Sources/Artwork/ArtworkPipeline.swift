import Foundation
import Domain

private struct ArtworkKey: Hashable, Sendable {
    let owner: ArtworkOwner
    let resource: ArtworkResource
    let size: ArtworkSize
    let policy: ArtworkCachePolicy
    var ownerDigest: String { artworkDigest(owner.account.accountID.uuidString) }
    var digest: String {
        let mode: String
        switch policy { case .noStore: mode = "none"; case .memory: mode = "memory"; case .disk: mode = "disk" }
        let values = [owner.account.channelID.rawValue, owner.account.region, resource.namespace, resource.identifier, resource.revision,
                      String(size.pixelWidth), String(size.pixelHeight), mode, String(policy.deadline?.timeIntervalSince1970.bitPattern ?? 0)]
        return artworkDigest(try! JSONEncoder().encode(values))
    }
}
private struct ArtworkWork: Sendable {
    let decoded: DecodedArtwork
    let policy: ArtworkCachePolicy
    let diskHit: Bool
}

/// One foreground authority domain. Switching current owner invalidates ALL previous
/// foreground work, even if the previous account's facade was forgotten by its feature.
public actor ArtworkPipeline {
    private struct Waiter {
        let context: RequestContext
        let continuation: CheckedContinuation<ArtworkResponse, any Error>
    }
    private struct Job {
        let token: UUID
        let generation: UInt64
        var waiters: [UUID: Waiter]
        var task: Task<Void, Never>?
    }
    private struct Cached { let image: ArtworkImage; let expires: Date; var used: UInt64 }
    private let source: any ArtworkSource
    private let configuration: ArtworkConfiguration
    private let clock: any WallClock
    private let decoder = ArtworkDecoder()
    private let authority = ArtworkAuthority()
    private let disk: ArtworkDiskStore
    /// W27: where this pipeline keeps its disk cache (the destructive-action guard reads it).
    public nonisolated let cacheDirectory: URL
    private var current: (owner: ArtworkOwner, generation: UInt64)?
    private var highwater: UInt64?
    private var removedAccounts: Set<UUID> = []
    private var jobs: [ArtworkKey: Job] = [:]
    private var pending: [ArtworkKey] = []
    private var memory: [ArtworkKey: Cached] = [:]
    private var sequence: UInt64 = 0
    private var counters = ArtworkCounters()
    private var pressureSource: DispatchSourceMemoryPressure?

    public init(source: any ArtworkSource, diskDirectory: URL,
                configuration: ArtworkConfiguration = .default, clock: any WallClock = SystemWallClock()) {
        self.source = source; self.configuration = configuration; self.clock = clock
        disk = ArtworkDiskStore(root: diskDirectory, configuration: configuration); cacheDirectory = diskDirectory
    }
    /// Call only from the authoritative account lifecycle, never from an image view.
    /// Generation is global and monotonic: equal values permit only the same current owner.
    public func setAccountGeneration(owner: ArtworkOwner, generation: UInt64) throws {
        guard owner.account.channelID.rawValue.utf8.count <= 512 else { throw ArtworkError.invalidResource }
        guard !removedAccounts.contains(owner.account.accountID),
              highwater.map({ generation > $0 || (generation == $0 && current?.owner == owner) }) ?? true else { throw ArtworkError.staleAccount }
        if current?.owner == owner && current?.generation == generation { return }
        invalidateJobs(error: ArtworkError.staleAccount)
        current = (owner, generation); highwater = generation
        authority.set(owner, generation: generation)
    }
    /// Sign-out/session revocation without deleting retained account files. A new owner
    /// subsequently requires a strictly newer generation; forgotten facades lose access.
    public func invalidateForeground(generation: UInt64) throws {
        guard highwater.map({ generation > $0 || (generation == $0 && current == nil) }) ?? true else { throw ArtworkError.staleAccount }
        invalidateJobs(error: ArtworkError.staleAccount)
        current = nil; highwater = generation; authority.set(nil, generation: generation)
    }
    /// Permanently tombstones this account in this pipeline, cancels work and purges all
    /// channels/regions. Re-adding an account uses a new local UUID.
    public func removeAccount(accountID: UUID) async throws {
        removedAccounts.insert(accountID)
        if current?.owner.account.accountID == accountID { current = nil; authority.set(nil, generation: highwater ?? 0) }
        for key in Array(jobs.keys) where key.owner.account.accountID == accountID { cancelJob(key, error: ArtworkError.staleAccount) }
        for key in Array(memory.keys) where key.owner.account.accountID == accountID { evict(key) }
        do { try await disk.remove(owner: artworkDigest(accountID.uuidString)) }
        catch { counters.storageFailures += 1; throw ArtworkError.storageUnavailable }
    }
    /// W27: the bytes this account's artwork occupies on disk.
    public func cacheBytes(accountID: UUID) async -> Int { (try? await disk.bytes(owner: artworkDigest(accountID.uuidString))) ?? 0 }
    /// W27: clears ONE account's cached artwork (memory and disk) without tombstoning the account or revoking anyone's authority.
    public func clearCache(accountID: UUID) async throws {
        for key in Array(jobs.keys) where key.owner.account.accountID == accountID { cancelJob(key, error: CancellationError()) }
        for key in Array(memory.keys) where key.owner.account.accountID == accountID { evict(key) }
        do { try await disk.remove(owner: artworkDigest(accountID.uuidString)) }
        catch { counters.storageFailures += 1; throw ArtworkError.storageUnavailable }
    }
    /// Clears account cache without revoking the current authority. Pending results are cancelled.
    public func clearCaches() async throws {
        invalidateJobs(error: CancellationError())
        memory.removeAll(); counters.memoryBytes = 0
        do { try await disk.clear() } catch { counters.storageFailures += 1; throw ArtworkError.storageUnavailable }
    }
    /// Explicitly install the OS pressure hook at composition, with no timer or polling.
    public func startPressureMonitoring() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            let critical = source?.data.contains(.critical) == true
            Task { await self?.handlePressure(critical ? .critical : .warning) }
        }
        pressureSource = source; source.resume()
    }
    public func stopPressureMonitoring() { pressureSource?.cancel(); pressureSource = nil }
    public func handlePressure(_ pressure: ArtworkPressure) {
        // Distinguish pipeline pressure from caller cancellation; consumers own bounded recovery.
        invalidateJobs(error: ArtworkError.pressureRevoked)
        let target = pressure == .critical ? 0 : configuration.memoryBytes / 2
        trimMemory(adding: 0, target: target)
    }
    public func purgeExpired() async throws {
        purgeExpiredMemory()
        do { try await disk.purge(now: clock.now()) }
        catch { counters.storageFailures += 1; throw ArtworkError.storageUnavailable }
    }
    private func purgeExpiredMemory() {
        let now = clock.now()
        for key in Array(memory.keys) where memory[key]!.expires <= now { evict(key) }
    }
    public func snapshot() -> ArtworkCounters {
        var value = counters
        value.pendingLoads = pending.count; value.waiters = jobs.values.reduce(0) { $0 + $1.waiters.count }
        return value
    }
    public func nativeSnapshot() async -> ArtworkNativeCounters { await decoder.snapshot() }
    public func diskSnapshot() async -> ArtworkDiskCounters { await disk.snapshot() }
    /// Consumers cancel their own task on query supersession/disappearance, then compare the
    /// echoed context with their latest query before UI publication. Peers retain independent tasks.
    public func image(for request: ArtworkRequest) async throws -> ArtworkResponse {
        try Task.checkCancellation()
        guard let account = request.context.account else { throw ArtworkError.staleAccount }
        let owner = ArtworkOwner(account: account)
        guard authorized(owner, request.context.accountGeneration) else { throw ArtworkError.staleAccount }
        if let deadline = request.policy.deadline, !deadline.timeIntervalSince1970.isFinite { throw ArtworkError.invalidPolicy }
        let key = ArtworkKey(owner: owner, resource: request.resource, size: request.size, policy: request.policy)
        purgeExpiredMemory()
        sequence &+= 1
        if let cached = memory[key], cached.expires > clock.now() {
            memory[key]?.used = sequence; counters.memoryHits += 1
            return ArtworkResponse(context: request.context, image: cached.image)
        }
        if memory[key] != nil { evict(key) }
        guard jobs.values.reduce(0, { $0 + $1.waiters.count }) < configuration.maximumWaiters else { throw ArtworkError.overloaded }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                let waiter = Waiter(context: request.context, continuation: continuation)
                if jobs[key] != nil {
                    jobs[key]?.waiters[waiterID] = waiter; counters.coalescedWaiters += 1
                } else {
                    guard jobs.count < configuration.maximumPendingLoads else { continuation.resume(throwing: ArtworkError.overloaded); return }
                    jobs[key] = Job(token: UUID(), generation: request.context.accountGeneration, waiters: [waiterID: waiter])
                    pending.append(key); pump()
                }
            }
        } onCancel: { Task { await self.cancelWaiter(key: key, id: waiterID) } }
    }
    private func authorized(_ owner: ArtworkOwner, _ generation: UInt64) -> Bool {
        !removedAccounts.contains(owner.account.accountID) && current?.owner == owner && current?.generation == generation
    }
    private func pump() {
        while counters.activeLoads < configuration.maximumConcurrentLoads, !pending.isEmpty {
            let key = pending.removeFirst()
            guard var job = jobs[key], job.task == nil else { continue }
            counters.activeLoads += 1; counters.peakActiveLoads = max(counters.peakActiveLoads, counters.activeLoads)
            let token = job.token, generation = job.generation
            job.task = Task { [source, decoder, disk, configuration, clock, authority] in
                let result: Result<ArtworkWork, any Error>
                do {
                    try Task.checkCancellation()
                    if key.policy.allowsDisk, let record = await disk.read(key: key.digest, owner: key.ownerDigest, now: clock.now()) {
                        do {
                            let decoded = try await decoder.decode(record.png, size: key.size, configuration: configuration, persist: false, savedPalette: record.palette)
                            guard decoded.image.cgImage.width == record.width, decoded.image.cgImage.height == record.height else { throw ArtworkError.invalidImage }
                            result = .success(ArtworkWork(decoded: decoded, policy: .disk(until: record.expires), diskHit: true))
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            await disk.remove(key: key.digest, owner: key.ownerDigest)
                            result = try await Self.load(key, generation: generation, source: source, decoder: decoder, configuration: configuration, authority: authority, onStart: { await self.recordSourceLoad() })
                        }
                    } else { result = try await Self.load(key, generation: generation, source: source, decoder: decoder, configuration: configuration, authority: authority, onStart: { await self.recordSourceLoad() }) }
                } catch is CancellationError { result = .failure(CancellationError()) }
                catch let error as ArtworkError { result = .failure(error) }
                catch let error as DomainError { result = .failure(error) }
                catch { result = .failure(ArtworkError.sourceUnavailable) }
                await self.finish(key: key, token: token, result: result)
            }
            jobs[key] = job
        }
    }
    private func recordSourceLoad() { counters.sourceLoads += 1 }
    private static func load(_ key: ArtworkKey, generation: UInt64, source: any ArtworkSource, decoder: ArtworkDecoder, configuration: ArtworkConfiguration, authority: ArtworkAuthority, onStart: @Sendable () async -> Void) async throws -> Result<ArtworkWork, any Error> {
        try Task.checkCancellation()
        guard authority.isCurrent(key.owner, generation: generation) else { throw ArtworkError.staleAccount }
        await onStart()
        try Task.checkCancellation()
        guard authority.isCurrent(key.owner, generation: generation) else { throw ArtworkError.staleAccount }
        let data = try await source.load(resource: key.resource, owner: key.owner, generation: generation, maximumBytes: configuration.maximumInputBytes)
        try Task.checkCancellation()
        guard data.bytes.count <= configuration.maximumInputBytes else { throw ArtworkError.inputTooLarge }
        if let deadline = data.policy.deadline, !deadline.timeIntervalSince1970.isFinite { throw ArtworkError.invalidPolicy }
        let policy = key.policy.restricted(by: data.policy)
        let decoded = try await decoder.decode(data.bytes, size: key.size, configuration: configuration, persist: policy.allowsDisk)
        return .success(ArtworkWork(decoded: decoded, policy: policy, diskHit: false))
    }
    private func finish(key: ArtworkKey, token: UUID, result: Result<ArtworkWork, any Error>) async {
        // Active includes cancelled-but-uncooperative producers until they actually stop.
        defer { counters.activeLoads -= 1; pump() }
        guard let job = jobs[key], job.token == token, authorized(key.owner, job.generation) else { return }
        switch result {
        case .failure(let error):
            jobs.removeValue(forKey: key)
            for waiter in job.waiters.values { waiter.continuation.resume(throwing: error) }
        case .success(let work):
            counters.decodes += 1
            if work.diskHit { counters.diskHits += 1 } else { counters.paletteExtractions += 1 }
            counters.decodedBytes += work.decoded.image.byteCost
            counters.largestDecodedBytes = max(counters.largestDecodedBytes, work.decoded.image.byteCost)
            if !work.decoded.offMain { counters.mainThreadWorkViolations += 1 }
            if work.policy.allowsDisk, let expiry = work.policy.deadline, expiry > clock.now(), !work.diskHit {
                await disk.write(ArtworkDiskRecord(publication: token, key: key.digest, owner: key.ownerDigest, expires: expiry,
                                                  width: work.decoded.image.cgImage.width, height: work.decoded.image.cgImage.height,
                                                  palette: work.decoded.image.palette, pngHash: artworkDigest(work.decoded.png), png: work.decoded.png), now: clock.now(), authority: authority, owner: key.owner, generation: job.generation)
            }
            guard let latest = jobs[key], latest.token == token, !latest.waiters.isEmpty, authorized(key.owner, latest.generation) else {
                if !work.diskHit { await disk.remove(key: key.digest, owner: key.ownerDigest, publication: token) }
                return
            }
            if let expiry = work.policy.deadline, expiry > clock.now(), work.decoded.image.byteCost <= configuration.memoryBytes {
                trimMemory(adding: work.decoded.image.byteCost, target: configuration.memoryBytes)
                sequence &+= 1
                memory[key] = Cached(image: work.decoded.image, expires: expiry, used: sequence)
                counters.memoryBytes += work.decoded.image.byteCost; counters.peakMemoryBytes = max(counters.peakMemoryBytes, counters.memoryBytes)
            }
            jobs.removeValue(forKey: key)
            for waiter in latest.waiters.values { waiter.continuation.resume(returning: ArtworkResponse(context: waiter.context, image: work.decoded.image)) }
        }
    }
    private func cancelWaiter(key: ArtworkKey, id: UUID) {
        guard let waiter = jobs[key]?.waiters.removeValue(forKey: id) else { return }
        counters.cancelledWaiters += 1; waiter.continuation.resume(throwing: CancellationError())
        if jobs[key]?.waiters.isEmpty == true { counters.abandonedLoads += 1; cancelJob(key, error: CancellationError()) }
    }
    private func cancelJob(_ key: ArtworkKey, error: any Error) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        pending.removeAll { $0 == key }; job.task?.cancel()
        for waiter in job.waiters.values { waiter.continuation.resume(throwing: error) }
    }
    private func invalidateJobs(error: any Error) { for key in Array(jobs.keys) { cancelJob(key, error: error) } }
    private func evict(_ key: ArtworkKey) {
        if let old = memory.removeValue(forKey: key) { counters.memoryBytes -= old.image.byteCost; counters.memoryEvictions += 1 }
    }
    private func trimMemory(adding: Int, target: Int) {
        while counters.memoryBytes + adding > target || (adding > 0 && memory.count >= configuration.maximumEntries) {
            guard let oldest = memory.min(by: { $0.value.used < $1.value.used })?.key else { break }
            evict(oldest)
        }
    }
}
