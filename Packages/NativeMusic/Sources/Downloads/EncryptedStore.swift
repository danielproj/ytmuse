import Foundation
import CryptoKit
import Domain
import AccountSession
import Darwin

public enum OfflineRecovery: String, Error, Sendable { case reconnect, staleGrant, storageUnavailable, seekNotPermitted, renewRights, redownload, missingKey, clockChanged, notRetained, invalidRange, storageFull }
/// Supplied by a rights adapter, never inferred from ciphertext, Premium status or download success.
public struct RetentionGrant: Codable, Sendable, Equatable {
    public let rights: Set<String>
    public let validatedAt: Date
    public let issuer: String
    public let sourceEncryption: String
    public let expires: Date
    public let renewalReference: String
    public init(issuer: String, sourceEncryption: String, expires: Date, renewalReference: String, rights: Set<String>, validatedAt: Date) {
        self.rights = rights; self.validatedAt = validatedAt
        self.issuer = issuer; self.sourceEncryption = sourceEncryption; self.expires = expires; self.renewalReference = renewalReference
    }
}
public enum OfflineSecurityStage: Sendable { case beforePending, afterPending, afterFiles }
public actor EncryptedStore: AccountLifecycleParticipant, OfflineMediaStore {
    public nonisolated let participantID = "encrypted-offline-store"
    public static let chunkSize = 64 * 1024
    private struct Index: Codable {
        var objectID: UUID; var size: Int; var chunks: Int; var grant: RetentionGrant; var references: Set<String>; var pinned: Bool
        var highWater: Date
    }
    private let root: URL
    private let files: PrivateDirectory
    private let vault: any ScopedProtectedRecords
    private let wall: any WallClock
    private let monotonic: any MonotonicClock
    private var wallAnchor: Date
    private var monotonicAnchor: Duration
    private var verified: [UUID: String] = [:]
    private struct ValidationProgress { var phase=0; var offset=0; var hash=SHA256(); var before="" }
    private struct HashProgress { var offset=0; var hash=SHA256() }
    private struct ContinueRead: Error {}
    private var validation: [UUID: ValidationProgress] = [:]
    private var hashes: [UUID: HashProgress] = [:]
    private func withReadable<T: Sendable>(context: RequestContext, operation: (ProtectedRecordLease) async throws -> T) async throws -> T {
        while true {
            do { return try await withObject(context: context, operation: operation) }
            catch is ContinueRead { try Task.checkCancellation(); _ = try scope(context); await Task.yield() }
        }
    }
    private struct PreparedImport: Sendable { let id: UUID; let size: Int; let chunks: Int; let staging: URL; let output: PrivateDirectory }
    private struct ImportWork { let account: AccountContext; let task: Task<PreparedImport, Error> }
    private var imports: [UUID: ImportWork] = [:]
    private var variantBusy: Set<String> = []
    private var variantWaiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private func cancelVariantWaiter(_ key: String, _ id: UUID) { variantWaiters[key]?.removeValue(forKey: id)?.resume() }
    private func takeVariant(_ key: String, context: RequestContext) async throws {
        while variantBusy.contains(key) {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { variantWaiters[key, default: [:]][id] = $0 }
            } onCancel: { Task { await self.cancelVariantWaiter(key, id) } }
            try Task.checkCancellation(); _ = try scope(context)
        }
        variantBusy.insert(key)
    }
    private func releaseVariant(_ key: String) {
        variantBusy.remove(key)
        let waits = variantWaiters.removeValue(forKey: key)?.values
        if let waits { for waiter in waits { waiter.resume() } }
    }
    private let importStep: (@Sendable (Int) async throws -> Void)?
    public func activeImportCount() -> Int { imports.count }
    /// W27: what the store's files occupy on disk, in the ledger's own terms (`DownloadPolicy.onDiskBytes`): every object's ciphertext chunks (framing included) plus its
    /// index files, charged at least the per-object allowance. An object whose index outgrew the allowance makes this larger than the ledger, which the Storage page reports.
    public func onDiskObjectBytes() -> Int64 {
        let fileManager = FileManager.default
        guard let accounts = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return 0 }
        func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var total: Int64 = 0
        for account in accounts {
            for object in (try? fileManager.contentsOfDirectory(at: account, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                guard (try? object.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                var chunks: Int64 = 0, metadata: Int64 = 0
                for file in (try? fileManager.contentsOfDirectory(at: object, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                    if file.lastPathComponent.hasPrefix("chunk-") { chunks += size(file) } else { metadata += size(file) }
                }
                total += chunks + max(metadata, DownloadPolicy.perObjectMetadataAllowance)
            }
        }
        return total
    }
    private let securityStep: (@Sendable (OfflineSecurityStage) async throws -> Void)?
    private struct Checkpoint: Codable {
        enum State: String, Codable { case pending, current, tombstone }
        let state: State; let digest: String?; let highWater: Date
        var revision: UUID? = nil
        var validationTime: Date? = nil
        var clockEpoch: UUID? = nil
        var grantHistory: RetentionGrant? = nil
    }
    private struct CachedKey { let version: Data; let key: SymmetricKey; let until: ContinuousClock.Instant }
    private var cachedKeys: [AccountContext: CachedKey] = [:]
    private var keyExpiry: Task<Void, Never>?
    /// How long a decrypted master key may stay in memory. One second in the product, always. `package` (not public): only this package's tests may lengthen it, to count key
    /// retrievals for a whole decode without the count depending on how long the machine took to decode (TH2).
    private var keyLifetime: Duration = .seconds(1)
    #if DEBUG   // TH5: a test hook is Debug only; the product's lifetime is fixed at one second
    package func setKeyLifetimeForTests(_ lifetime: Duration) { keyLifetime = lifetime }
    #endif
    private struct ClockFault: Codable {
        let floor: Date // unauthenticated local observation, never source authority
        var blocked: Bool? = true
        var validatedAt: Date? = nil
        var authenticatedFloor: Date? = nil
        var recovery: UUID? = nil
    }
    private static let clockFaultName = "offline.clock-fault.v3"
    deinit { keyExpiry?.cancel() }
    private func cacheKey(_ key: SymmetricKey, version: Data, context: RequestContext) {
        keyExpiry?.cancel()
        let lifetime = keyLifetime
        cachedKeys = [context.account!: CachedKey(version: version, key: key, until: .now.advanced(by: lifetime))]
        keyExpiry = Task.detached { [weak self] in
            do { try await Task.sleep(for: lifetime); await self?.expireKey(version, context: context) } catch {}
        }
    }
    private func expireKey(_ version: Data, context: RequestContext) {
        if cachedKeys[context.account!]?.version == version { cachedKeys[context.account!] = nil }
    }
    private var floorCommits: [String: ContinuousClock.Instant] = [:]
    public func clearReadCaches(context: RequestContext) { if active?.accountGeneration == context.accountGeneration, active?.account == context.account { cachedKeys.removeAll(); keyExpiry?.cancel(); verified.removeAll(); validation.removeAll(); hashes.removeAll() } }
    public func readCacheCount() -> Int { cachedKeys.filter { $0.value.until > .now }.count }
    private static let masterName = "offline.master.v2"
    private func checkpointName(_ dir: URL) -> String { "offline.object.v2." + dir.lastPathComponent }
    private func withObject<T: Sendable>(context: RequestContext, operation: (ProtectedRecordLease) async throws -> T) async throws -> T {
        _ = try scope(context)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var lease: ProtectedRecordLease?
        repeat {
            try Task.checkCancellation(); _ = try scope(context)
            do { lease = try await vault.acquireProtectedLease(context: context) }
            catch DomainError.unauthorized { _ = try scope(context); throw OfflineRecovery.missingKey }
            if lease == nil { try await Task.sleep(for: .milliseconds(5)) }
        } while lease == nil && ContinuousClock.now < deadline
        guard let lease else { throw LifecycleError.busy }
        do {
            _ = try scope(context)
            cleanPartials(context)
            let result = try await operation(lease)
            _ = try scope(context)
            try await vault.releaseProtectedLease(lease)
            _ = try scope(context); try Task.checkCancellation()
            return result
        } catch {
            let original = error
            // Releasing an exact lease is cleanup only, including after detach.
            // Release failures propagate; they must not become a successful security commit.
            try await vault.releaseProtectedLease(lease)
            _ = try scope(context)
            throw original
        }
    }
    private var readStats: [String:Int] = [:]
    public func storageMetrics() -> [String: Int] { files.metrics.snapshot().merging(readStats) { _,n in n } }
    private var active: RequestContext?
    public init(root: URL, vault: any ScopedProtectedRecords, wall: any WallClock = SystemWallClock(), monotonic: any MonotonicClock = SystemMonotonicClock(), securityStep: (@Sendable (OfflineSecurityStage) async throws -> Void)? = nil, importStep: (@Sendable (Int) async throws -> Void)? = nil) throws {
        self.root = root; self.vault = vault; self.wall = wall; self.securityStep = securityStep; self.importStep = importStep
        self.monotonic = monotonic; wallAnchor = wall.now(); monotonicAnchor = monotonic.now()
        files = try PrivateDirectory(root: root)
    }
    private struct DecoderObserver {
        let variant: String
        let invalidated: @Sendable (DomainError) -> Void
        let drain: @Sendable () async -> Void
    }
    private var decoderObservers: [UUID: DecoderObserver] = [:]
    func observeDecoder(variant: String, context: RequestContext, invalidated: @escaping @Sendable (DomainError) -> Void, drain: @escaping @Sendable () async -> Void) throws -> UUID {
        _ = try scope(context)
        guard decoderObservers.count < 32 else { throw OfflineRecovery.storageUnavailable }
        let id = UUID(); decoderObservers[id] = DecoderObserver(variant: variant, invalidated: invalidated, drain: drain); return id
    }
    func removeDecoderObserver(_ id: UUID) { decoderObservers[id] = nil }
    private func retractDecoders(variant: String? = nil, error: DomainError) -> [@Sendable () async -> Void] {
        let ids = decoderObservers.filter { variant == nil || $0.value.variant == variant }.map(\.key)
        var drains: [@Sendable () async -> Void] = []
        for id in ids { if let observer = decoderObservers.removeValue(forKey: id) { observer.invalidated(error); drains.append(observer.drain) } }
        return drains
    }
    public func bind(_ context: RequestContext) async {
        if let active, context.accountGeneration <= active.accountGeneration, context.account != active.account { return }
        if let active, context.accountGeneration < active.accountGeneration { return }
        if active?.account != context.account || active?.accountGeneration != context.accountGeneration { cachedKeys.removeAll(); keyExpiry?.cancel(); floorCommits.removeAll(); verified.removeAll(); validation.removeAll(); hashes.removeAll() }
        if active?.account != context.account || active?.accountGeneration != context.accountGeneration {
            for work in imports.values { work.task.cancel() }
            let waits = variantWaiters.values.flatMap { $0.values }; variantWaiters.removeAll()
            for waiter in waits { waiter.resume() }
        }
        let drains = active?.account != context.account || active?.accountGeneration != context.accountGeneration ? retractDecoders(error: .unauthorized) : []
        active = context
        for drain in drains { await drain() }
        await vault.bind(context)
    }
    private func cleanPartials(_ context: RequestContext) {
        // The protected lease excludes live imports in other instances/processes.
        // Crash leftovers contain ciphertext only. Cleanup is scoped to this identity;
        // failures remain local to offline access, never block another identity's activation.
        if let account = context.account, let dir = try? directory(accountDirectory(account)) {
            for entry in (try? dir.entries()) ?? [] {
                if entry.hasSuffix(".partial") {
                    if let child = try? dir.directory(entry), !child.isStagingBusy() { try? dir.remove(entry) }
                } else if entry.hasSuffix(".write") { try? dir.remove(entry) }
                else if let object = try? dir.directory(entry) {
                    for temporary in (try? object.entries()) ?? [] where temporary.hasSuffix(".write") { try? object.remove(temporary) }
                }
            }
        }
    }
    private func scope(_ context: RequestContext) throws -> URL {
        guard active?.account == context.account, active?.accountGeneration == context.accountGeneration, let a = context.account else { throw OfflineRecovery.reconnect }
        return accountDirectory(a)
    }
    private func accountDirectory(_ a: AccountContext) -> URL {
        let identity = "\(a.accountID)|\(a.channelID.rawValue.utf8.count):\(a.channelID.rawValue)|\(a.region)"
        return root.appendingPathComponent(Self.digest(Data(identity.utf8)))
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func directory(_ url: URL, create: Bool = false) throws -> PrivateDirectory {
        let parts = url.pathComponents.dropFirst(root.pathComponents.count)
        guard url.pathComponents.starts(with: root.pathComponents), parts.count <= 2 else { throw OfflineRecovery.redownload }
        var current = files
        for part in parts { current = try current.directory(part, create: create) }
        return current
    }
    private func exists(_ url: URL) throws -> Bool {
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL.path != root.standardizedFileURL.path, !(try files.exists(parent.lastPathComponent)) { return false }
        return try directory(parent).exists(url.lastPathComponent)
    }
    private func remove(_ url: URL) throws { try directory(url.deletingLastPathComponent()).remove(url.lastPathComponent) }
    private func object(_ variant: String, _ context: RequestContext) throws -> URL { try scope(context).appendingPathComponent(Self.digest(Data(variant.utf8))) }
    private func key(_ context: RequestContext, lease: ProtectedRecordLease, create: Bool = false) async throws -> SymmetricKey {
        _ = try scope(context)
        let stamp = try await vault.protectedRecordStamp(Self.masterName, lease: lease, context: context)
        _ = try scope(context)
        if let version = stamp?.version, let cached = cachedKeys[context.account!], cached.version == version, cached.until > .now { return cached.key }
        cachedKeys[context.account!] = nil
        let existing = try await vault.protectedRecord(Self.masterName, lease: lease, context: context)
        _ = try scope(context)
        if let existing {
            guard existing.count == 32 else { throw OfflineRecovery.missingKey }
            let key = SymmetricKey(data: existing)
            if let version = stamp?.version { cacheKey(key, version: version, context: context) }
            return key
        }
        guard create else { throw OfflineRecovery.missingKey }
        let key = SymmetricKey(size: .bits256)
        try await vault.replaceProtectedRecord(Self.masterName, value: key.withUnsafeBytes { Data($0) }, lease: lease, context: context)
        _ = try scope(context)
        return key
    }
    private func checkpoint(_ dir: URL, lease: ProtectedRecordLease, context: RequestContext) async throws -> Checkpoint? {
        let data = try await vault.protectedRecord(checkpointName(dir), lease: lease, context: context)
        _ = try scope(context)
        guard let data else { return nil }
        do { return try JSONDecoder().decode(Checkpoint.self, from: data) }
        catch { throw OfflineRecovery.redownload }
    }
    /// Single boundary for every grant installation, regardless of file readability.
    /// Only protected history (or a digest-authenticated current index) can establish
    /// equal-time idempotence/restriction. Pending/tombstone recovery needs newer proof.
    private func checkGrantInstallation(_ grant: RetentionGrant, prior: Checkpoint?, knownCurrent: RetentionGrant? = nil, untrackedExisting: Bool = false, lease: ProtectedRecordLease, context: RequestContext) async throws {
        _ = try scope(context)
        // Receipt ordering belongs to this item; the account floor bounds time,
        // not callbacks for unrelated variants.
        let highest = prior?.validationTime ?? .distantPast
        guard grant.validatedAt >= highest else { throw OfflineRecovery.staleGrant }
        if prior == nil, untrackedExisting, grant.validatedAt == highest { throw OfflineRecovery.staleGrant }
        if let prior, grant.validatedAt == (prior.validationTime ?? highest) {
            guard prior.state == .current, let old=prior.grantHistory ?? knownCurrent else { throw OfflineRecovery.staleGrant }
            if grant == old { return }
            guard grant.issuer == old.issuer, grant.sourceEncryption == old.sourceEncryption,
                  grant.renewalReference == old.renewalReference,
                  grant.rights.isSubset(of:old.rights),grant.expires <= old.expires,
                  grant.rights != old.rights || grant.expires < old.expires else { throw OfflineRecovery.staleGrant }
        }
    }
    /// Pending is durable BEFORE any file mutation. No error path rolls it back.
    private func commit(_ dir: URL, bytes: Data?, highWater: Date, validationTime: Date? = nil, grant: RetentionGrant? = nil, installsGrant: Bool = false, lease: ProtectedRecordLease, context: RequestContext, publish: () throws -> Void) async throws {
        let prior = try await checkpoint(dir, lease: lease, context: context)
        if installsGrant {
            guard let grant else { throw OfflineRecovery.staleGrant }
            try await checkGrantInstallation(grant,prior:prior,untrackedExisting:try exists(dir),lease:lease,context:context)
        }
        if try exists(dir) { try directory(dir).requireWritable() }
        try directory(dir.deletingLastPathComponent()).requireWritable()
        let clockBytes=try await vault.protectedRecord(Self.clockFaultName,lease:lease,context:context)
        let clockState=try clockBytes.map{try JSONDecoder().decode(ClockFault.self,from:$0)}
        _ = try scope(context)
        let priorFloor=prior?.clockEpoch == clockState?.recovery ? (prior?.highWater ?? highWater) : (clockState?.floor ?? highWater)
        let floor=max(priorFloor,highWater)
        try await securityStep?(.beforePending); _ = try scope(context)
        let revision = UUID()
        let validation = max(prior?.validationTime ?? .distantPast, validationTime ?? .distantPast)
        let pending = Checkpoint(state: .pending, digest: nil, highWater: floor, revision: revision, validationTime: validation, clockEpoch:clockState?.recovery,grantHistory:grant ?? prior?.grantHistory)
        try await vault.replaceProtectedRecord(checkpointName(dir), value: JSONEncoder().encode(pending), lease: lease, context: context)
        _ = try scope(context); try await securityStep?(.afterPending); _ = try scope(context)
        try publish()
        try await securityStep?(.afterFiles); _ = try scope(context)
        if let bytes {
            guard try directory(dir).read("index", maximum: 1_048_636) == bytes else { throw OfflineRecovery.redownload }
        }
        let final = Checkpoint(state: bytes == nil ? .tombstone : .current, digest: bytes.map(Self.digest), highWater: floor, revision: revision, validationTime: validation, clockEpoch:clockState?.recovery,grantHistory:grant ?? prior?.grantHistory)
        try await vault.replaceProtectedRecord(checkpointName(dir), value: JSONEncoder().encode(final), lease: lease, context: context)
        _ = try scope(context)
        if let validationTime {
            let next=ClockFault(floor:clockState?.floor ?? wall.now(),blocked:clockState?.blocked ?? false,validatedAt:clockState?.validatedAt,authenticatedFloor:max(clockState?.authenticatedFloor ?? .distantPast,validationTime),recovery:clockState?.recovery)
            try await vault.replaceProtectedRecord(Self.clockFaultName,value:JSONEncoder().encode(next),lease:lease,context:context)
            _ = try scope(context)
        }
    }
    // Each record write gets a fresh 256-bit salt and derived AES key, including metadata
    // rewrites. CryptoKit also generates a fresh 96-bit GCM nonce. No counter resets or
    // reused per-account nonce sequences across process restarts.
    private func encrypt(_ bytes: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: aad, outputByteCount: 32)
        return salt + (try AES.GCM.seal(bytes, using: derived, authenticating: aad).combined!)
    }
    private func decrypt(_ bytes: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard bytes.count >= 60 else { throw OfflineRecovery.redownload }
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: bytes.prefix(32), info: aad, outputByteCount: 32)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: bytes.dropFirst(32)), using: derived, authenticating: aad)
    }
    private func aad(_ dir: URL, _ name: String) -> Data { Data((dir.deletingLastPathComponent().lastPathComponent + "/" + dir.lastPathComponent + "/" + name).utf8) }
    private func seal(_ data: Data, at dir: URL, name: String, key: SymmetricKey) throws {
        try directory(dir).write(encrypt(data, key: key, aad: aad(dir, name)), name: name)
    }
    private func open(_ dir: URL, name: String, key: SymmetricKey, maximum: Int, binding: String = "") throws -> Data {
        do {
            let bytes = try directory(dir).read(name, maximum: maximum + 60)
            return try decrypt(bytes, key: key, aad: aad(dir, name + binding))
        } catch { throw OfflineRecovery.redownload }
    }
    private func index(_ dir: URL, _ key: SymmetricKey, lease: ProtectedRecordLease, context: RequestContext, requirePlayback: Bool = true) async throws -> Index {
        guard (try exists(dir)) else { throw OfflineRecovery.notRetained }
        let bytes = try directory(dir).read("index", maximum: 1_048_636)
        guard let authority = try await checkpoint(dir, lease: lease, context: context), authority.state == .current,
              authority.digest == Self.digest(bytes) else { throw OfflineRecovery.redownload }
        let i: Index
        do { i = try JSONDecoder().decode(Index.self, from: decrypt(bytes, key: key, aad: aad(dir, "index"))) } catch { throw OfflineRecovery.redownload }
        var trustedFloor = max(i.highWater, authority.highWater)
        guard i.size > 0, i.size <= 32 * 1024 * 1024 * 1024, i.chunks == (i.size - 1) / Self.chunkSize + 1 else { throw OfflineRecovery.redownload }
        if !requirePlayback { return i }
        let clockData = try await vault.protectedRecord(Self.clockFaultName, lease: lease, context: context)
        let clockState = try clockData.map { try JSONDecoder().decode(ClockFault.self, from: $0) }
        _ = try scope(context)
        if let clockState {
            guard clockState.blocked == false else { throw OfflineRecovery.clockChanged }
            if authority.clockEpoch != clockState.recovery { trustedFloor=clockState.floor }
            trustedFloor=max(max(trustedFloor,authority.validationTime ?? i.grant.validatedAt),max(clockState.floor,clockState.authenticatedFloor ?? .distantPast))
        }
        let elapsed = (monotonic.now() - monotonicAnchor).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        if wall.now() < trustedFloor.addingTimeInterval(-2) || abs(wall.now().timeIntervalSince(wallAnchor) - seconds) >= 5 {
            let fault = ClockFault(floor: max(trustedFloor, wallAnchor),validatedAt:clockState?.validatedAt,authenticatedFloor:clockState?.authenticatedFloor,recovery:clockState?.recovery)
            try await vault.replaceProtectedRecord(Self.clockFaultName, value: JSONEncoder().encode(fault), lease: lease, context: context)
            _ = try scope(context); throw OfflineRecovery.clockChanged
        }
        guard i.grant.rights.isSuperset(of: ["play", "retain"]), wall.now() >= i.grant.validatedAt, !i.grant.issuer.isEmpty, !i.grant.sourceEncryption.isEmpty, !i.grant.renewalReference.isEmpty, wall.now() < i.grant.expires else {
            try await persistReadTime(dir, lease: lease, context: context)
            throw OfflineRecovery.renewRights
        }
        return i
    }
    /// Preparation holds only its staging descriptor/flock, never the account lease.
    /// Actual source file I/O, chunk encryption and fsync run on a detached utility task.
    public func retain(file: URL, variant: String, grant: RetentionGrant, reference: String, context: RequestContext) async throws {
        let variantKey = try object(variant, context).path
        try await takeVariant(variantKey, context: context)
        defer { releaseVariant(variantKey) }
        try Task.checkCancellation(); _ = try scope(context)
        guard grant.rights.isSuperset(of: ["play", "retain"]), wall.now() >= grant.validatedAt, grant.expires > wall.now(), !grant.issuer.isEmpty, !grant.sourceEncryption.isEmpty, !grant.renewalReference.isEmpty else { throw OfflineRecovery.renewRights }
        let dir = try object(variant, context)
        let setup: (SymmetricKey, String?)? = try await withObject(context: context) { lease in
            let k = try await key(context, lease: lease, create: true)
            if try exists(dir) {
                do {
                    var i = try await index(dir, k, lease: lease, context: context)
                    i.references.insert(reference); try await save(i, dir, k, lease: lease, context: context)
                    return nil
                } catch let error as OfflineRecovery {
                    guard [.redownload,.renewRights,.clockChanged,.notRetained].contains(error) else { throw error }
                }
            }
            let authority = try await checkpoint(dir, lease: lease, context: context)
            try await checkGrantInstallation(grant,prior:authority,untrackedExisting:try exists(dir),lease:lease,context:context)
            return (k, authority.map { $0.revision?.uuidString ?? ($0.state.rawValue + ($0.digest ?? "")) })
        }
        guard let (k, startingRevision) = setup else { return }
        let token = UUID()
        let staging = dir.deletingLastPathComponent().appendingPathComponent(token.uuidString + ".partial")
        let output = try directory(staging, create: true); try output.lockStaging()
        let step = importStep; let aadPrefix = aad(dir, "")
        let task = Task.detached(priority: .utility) { [weak self] () throws -> PreparedImport in
            guard file.isFileURL else { throw OfflineRecovery.redownload }
            let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw OfflineRecovery.redownload }
            var original = stat()
            guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG, original.st_nlink == 1, original.st_size > 0, original.st_size <= 32 * 1024 * 1024 * 1024 else { Darwin.close(fd); throw OfflineRecovery.redownload }
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
            let id = UUID(); var size = 0; var count = 0
            while let bytes = try input.read(upToCount: Self.chunkSize), !bytes.isEmpty {
                try Task.checkCancellation()
                guard let self else { throw OfflineRecovery.reconnect }
                try await self.importCheckpoint(context, grant: grant)
                let name = "chunk-\(count)"
                let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                let associated = aadPrefix + Data((name + id.uuidString).utf8)
                let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: k, salt: salt, info: associated, outputByteCount: 32)
                try output.write(salt + AES.GCM.seal(bytes, using: derived, authenticating: associated).combined!, name: name)
                size += bytes.count; count += 1
                try await step?(count); try Task.checkCancellation()
                await Task.yield()
            }
            var final = stat()
            guard fstat(fd, &final) == 0, final.st_dev == original.st_dev, final.st_ino == original.st_ino,
                  final.st_size == original.st_size, final.st_size == size, final.st_nlink == 1,
                  final.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec, final.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
                  final.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec, final.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else { throw OfflineRecovery.redownload }
            return PreparedImport(id: id, size: size, chunks: count, staging: staging, output: output)
        }
        imports[token] = ImportWork(account: context.account!, task: task)
        defer {
            imports[token] = nil
            if let parent = try? directory(staging.deletingLastPathComponent()), parent.matches(staging.lastPathComponent, directory: output) { try? parent.remove(staging.lastPathComponent) }
        }
        let prepared = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation(); try importCheckpoint(context, grant: grant)
        try await withObject(context: context) { lease in
            let authority = try await checkpoint(dir, lease: lease, context: context)
            let currentRevision = authority.map { $0.revision?.uuidString ?? ($0.state.rawValue + ($0.digest ?? "")) }
            // A newer source/security/reference decision wins over this older import.
            guard currentRevision == startingRevision else { throw DomainError.reconciliationRequired }
            let currentKey = try await key(context, lease: lease)
            guard currentKey.withUnsafeBytes({ Data($0) }) == k.withUnsafeBytes({ Data($0) }) else { throw OfflineRecovery.missingKey }
            try importCheckpoint(context, grant: grant); try Task.checkCancellation()
            let i = Index(objectID: prepared.id, size: prepared.size, chunks: prepared.chunks, grant: grant, references: [reference], pinned: false, highWater: max(wall.now(), authority?.highWater ?? wall.now()))
            let bytes = try encrypt(JSONEncoder().encode(i), key: k, aad: aad(dir, "index"))
            try prepared.output.write(bytes, name: "index")
            try await commit(dir, bytes: bytes, highWater: i.highWater, validationTime: grant.validatedAt, grant: grant, installsGrant: true, lease: lease, context: context) {
                let parent = try directory(dir.deletingLastPathComponent())
                guard parent.matches(staging.lastPathComponent, directory: prepared.output) else { throw OfflineRecovery.redownload }
                if try exists(dir) { try remove(dir) }
                try parent.publish(staging.lastPathComponent, as: dir.lastPathComponent)
            }
        }
    }
    private func importCheckpoint(_ context: RequestContext, grant: RetentionGrant) throws {
        _ = try scope(context)
        guard grant.validatedAt <= wall.now(), wall.now() < grant.expires else { throw OfflineRecovery.renewRights }
    }
    private func save(_ i: Index, _ dir: URL, _ k: SymmetricKey, lease: ProtectedRecordLease, context: RequestContext, installsGrant: Bool = false) async throws {
        let prior = try await checkpoint(dir, lease: lease, context: context)
        let clockBytes=try await vault.protectedRecord(Self.clockFaultName,lease:lease,context:context)
        let clockState=try clockBytes.map{try JSONDecoder().decode(ClockFault.self,from:$0)}
        _ = try scope(context)
        var i = i
        if prior?.clockEpoch != clockState?.recovery { i.highWater=max(wall.now(),clockState?.authenticatedFloor ?? .distantPast) }
        else { i.highWater=max(i.highWater,prior?.highWater ?? i.highWater) }
        let bytes = try encrypt(JSONEncoder().encode(i), key: k, aad: aad(dir, "index"))
        try await commit(dir, bytes: bytes, highWater: i.highWater, validationTime: i.grant.validatedAt, grant: i.grant, installsGrant: installsGrant, lease: lease, context: context) { try directory(dir).write(bytes, name: "index") }
    }
    /// At most 64 bounded work units or 50 ms per protected slice. Release/reacquire
    /// authority between slices; no playback-long lease or whole-object actor loop.
    private func validateComplete(_ dir: URL, _ i: Index, _ k: SymmetricKey) throws {
        if validation.count >= 8, validation[i.objectID] == nil { validation.removeAll() }
        var progress = validation[i.objectID] ?? ValidationProgress()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        var units=0
        defer { readStats["maxValidationUnits"] = max(readStats["maxValidationUnits"] ?? 0,units) }
        while units < 64, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if progress.phase == 1 {
                let bytes = try open(dir, name: "chunk-\(progress.offset)", key: k, maximum: Self.chunkSize, binding: i.objectID.uuidString)
                guard bytes.count == min(Self.chunkSize, i.size-progress.offset*Self.chunkSize) else { validation[i.objectID]=nil; throw OfflineRecovery.redownload }
            } else {
                progress.hash.update(data: try directory(dir).signature("chunk-\(progress.offset)", maximum: Self.chunkSize+60))
            }
            progress.offset += 1; units += 1
            if progress.offset == i.chunks {
                if progress.phase == 0 {
                    let fingerprint=progress.hash.finalize().map{String(format:"%02x",$0)}.joined()
                    if verified[i.objectID] == fingerprint { validation[i.objectID]=nil; return }
                    progress.before=fingerprint; progress.phase=1
                } else if progress.phase == 1 { progress.phase=2 }
                else {
                    let after=progress.hash.finalize().map{String(format:"%02x",$0)}.joined()
                    validation[i.objectID]=nil
                    guard after == progress.before else { throw OfflineRecovery.redownload }
                    if verified.count>=8{verified.removeAll()};verified[i.objectID]=after;return
                }
                progress.offset=0;progress.hash=SHA256()
            }
        }
        readStats["validationYields",default:0] += 1
        readStats["maxValidationUnits"] = max(readStats["maxValidationUnits"] ?? 0,units)
        validation[i.objectID]=progress;throw ContinueRead()
    }
    public func length(variant: String, context: RequestContext) async throws -> Int {
        // Absence grants nothing. Avoid creating a Keychain lease merely to fall back
        // to the independently licensed bundled-owned route. Existing objects ALWAYS
        // enter the protected authority boundary below (including restored folders).
        guard try exists(object(variant, context)) else { throw OfflineRecovery.notRetained }
        return try await withReadable(context: context) { lease in try await lengthLocked(variant: variant, context: context, lease: lease) }
    }
    private func lengthLocked(variant: String, context: RequestContext, lease: ProtectedRecordLease) async throws -> Int {
        let dir = try object(variant, context)
        guard (try exists(dir)) else { throw OfflineRecovery.notRetained }
        let k = try await key(context, lease: lease); let i = try await index(dir, k, lease: lease, context: context)
        try validateComplete(dir, i, k)
        return i.size
    }
    /// Maximum returned plaintext is one chunk. Every chunk is authenticated before release.
    public func read(variant: String, offset: Int, count: Int, context: RequestContext) async throws -> Data {
        try await withReadable(context: context) { lease in try await readLocked(variant: variant, offset: offset, count: count, context: context, lease: lease) }
    }
    private enum ReadPurpose { case arbitrary, decoder }
    private func readLocked(variant: String, offset: Int, count: Int, context: RequestContext, lease: ProtectedRecordLease, purpose: ReadPurpose = .arbitrary) async throws -> Data {
        try Task.checkCancellation()
        let k = try await key(context, lease: lease); let dir = try object(variant, context); var i = try await index(dir, k, lease: lease, context: context)
        guard purpose == .decoder || offset == 0 || i.grant.rights.contains("seek") else { throw OfflineRecovery.seekNotPermitted }
        guard offset >= 0, count >= 0, count <= Self.chunkSize, offset <= i.size, count <= i.size - offset else { throw OfflineRecovery.invalidRange }
        try validateComplete(dir, i, k)
        var result = Data(); var cursor = offset
        while cursor < offset + count {
            let n = cursor / Self.chunkSize
            let bytes = try open(dir, name: "chunk-\(n)", key: k, maximum: Self.chunkSize, binding: i.objectID.uuidString)
            guard bytes.count == min(Self.chunkSize, i.size - n * Self.chunkSize) else { throw OfflineRecovery.redownload }
            let start = cursor % Self.chunkSize; let take = min(bytes.count - start, offset + count - cursor)
            result.append(bytes[start..<start+take]); cursor += take
        }
        try await persistReadTime(dir, lease: lease, context: context)
        try Task.checkCancellation(); _ = try scope(context); return result
    }
    private func persistReadTime(_ dir: URL, lease: ProtectedRecordLease, context: RequestContext) async throws {
        let data = try await vault.protectedRecord(Self.clockFaultName, lease: lease, context: context)
        let prior = try data.map { try JSONDecoder().decode(ClockFault.self, from: $0) }
        _ = try scope(context)
        if let prior { guard prior.blocked == false else { throw OfflineRecovery.clockChanged } }
        let elapsed = (monotonic.now()-monotonicAnchor).components
        let seconds=Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18
        let floor=max(prior?.floor ?? wallAnchor,wallAnchor)
        if wall.now()<floor.addingTimeInterval(-2) || abs(wall.now().timeIntervalSince(wallAnchor)-seconds)>=5 {
            try await vault.replaceProtectedRecord(Self.clockFaultName,value:JSONEncoder().encode(ClockFault(floor:floor,validatedAt:prior?.validatedAt,authenticatedFloor:prior?.authenticatedFloor,recovery:prior?.recovery)),lease:lease,context:context)
            _ = try scope(context);throw OfflineRecovery.clockChanged
        }
        if let prior, wall.now()<=prior.floor { return }
        if let last=floorCommits["account"],last.duration(to: .now) < .seconds(1){return}
        let next=ClockFault(floor:max(floor,wall.now()),blocked:false,validatedAt:prior?.validatedAt,authenticatedFloor:prior?.authenticatedFloor,recovery:prior?.recovery)
        try await vault.replaceProtectedRecord(Self.clockFaultName,value:JSONEncoder().encode(next),lease:lease,context:context)
        _ = try scope(context);floorCommits["account"] = .now
    }
    /// Delivers under the same actor barrier as ownership/rights changes: no await between
    /// final validation and the native consumer. A held callback cannot cross sign-out.
    public func deliver(variant: String, offset: Int, count: Int, context: RequestContext, consumer: @Sendable (Data) -> Void) async throws {
        try await withReadable(context: context) { lease in
            let bytes = try await readLocked(variant: variant, offset: offset, count: count, context: context, lease: lease)
            _ = try scope(context); try Task.checkCancellation()
            consumer(bytes)
        }
    }
    /// Module-internal decoder seam. Byte addressing by a decoder is not a user seek.
    /// The complete current play/retain grant, owner, clock and chunk checks still apply.
    func deliverDecoderBytes(variant: String, offset: Int, count: Int, context: RequestContext, consumer: @Sendable (Data) -> Void) async throws {
        try await withReadable(context: context) { lease in
            let bytes = try await readLocked(variant: variant, offset: offset, count: count, context: context, lease: lease, purpose: .decoder)
            _ = try scope(context); try Task.checkCancellation(); consumer(bytes)
        }
    }
    public func userSeekAllowed(variant: String, context: RequestContext) async throws -> Bool {
        try await withObject(context: context) { lease in
            let k = try await key(context, lease: lease)
            let i = try await index(object(variant, context), k, lease: lease, context: context)
            return i.grant.rights.contains("seek")
        }
    }
    public func reference(variant: String, reference: String?, remove: String? = nil, pinned: Bool? = nil, context: RequestContext) async throws {
        try await withObject(context: context) { lease in try await referenceLocked(variant: variant, reference: reference, remove: remove, pinned: pinned, context: context, lease: lease) }
    }
    private func referenceLocked(variant: String, reference: String?, remove: String? = nil, pinned: Bool? = nil, context: RequestContext, lease: ProtectedRecordLease) async throws {
        let k = try await key(context, lease: lease); let dir = try object(variant, context); var i = try await index(dir, k, lease: lease, context: context, requirePlayback: false)
        if let reference { i.references.insert(reference) }; if let remove { i.references.remove(remove) }; if let pinned { i.pinned = pinned }
        if i.references.isEmpty && !i.pinned { try await commit(dir, bytes: nil, highWater: max(i.highWater, wall.now()), lease: lease, context: context) { try self.remove(dir) } } else { try await save(i, dir, k, lease: lease, context: context) }
    }
    public func detach(previous: RequestContext, barrier: RequestContext) async throws { await bind(barrier) }
    public func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws { await bind(context) }
    public func removeLocal(_ account: AccountContext, context: RequestContext) async throws {
        guard active.map({ context.accountGeneration >= $0.accountGeneration }) ?? true else { throw OfflineRecovery.reconnect }
        await bind(context)
        guard active?.account == nil, active?.accountGeneration == context.accountGeneration, context.account == nil else { throw OfflineRecovery.reconnect }
        let work = imports.values.filter { $0.account == account }.map { $0.task }
        for task in work { task.cancel() }
        for task in work { _ = await task.result }
        guard active?.account == nil, active?.accountGeneration == context.accountGeneration else { throw OfflineRecovery.reconnect }
        let dir = accountDirectory(account)
        let name=dir.lastPathComponent; let files=self.files
        try await vault.eraseProtectedAccount(account, barrier: context) {
            if try files.exists(name) { try files.remove(name) }
        }
        guard active?.account == nil, active?.accountGeneration == context.accountGeneration else { throw OfflineRecovery.reconnect }
    }
    /// Renewal replaces only the explicit source grant; encrypted bytes confer no rights.
    public func updateGrant(variant: String, grant: RetentionGrant, context: RequestContext) async throws {
        try await withObject(context: context) { lease in try await updateGrantLocked(variant: variant, grant: grant, context: context, lease: lease) }
        if !grant.rights.isSuperset(of: ["play", "retain"]) || grant.expires <= wall.now() { for drain in retractDecoders(variant: variant, error: .expiredMedia) { await drain() } }
    }
    private func updateGrantLocked(variant: String, grant: RetentionGrant, context: RequestContext, lease: ProtectedRecordLease) async throws {
        // A future ordinary callback must not mutate index/clock/floor state.
        guard grant.validatedAt <= wall.now() else { throw OfflineRecovery.renewRights }
        let k=try await key(context,lease:lease);let dir=try object(variant,context)
        var i=try await index(dir,k,lease:lease,context:context,requirePlayback:false)
        if grant == i.grant { return }
        let authority=try await checkpoint(dir,lease:lease,context:context)
        try await checkGrantInstallation(grant,prior:authority,knownCurrent:i.grant,lease:lease,context:context)
        i.grant=grant;i.highWater=wall.now()
        try await save(i,dir,k,lease:lease,context:context,installsGrant:true)
    }
    /// The source adapter MUST authenticate a genuinely fresh source-time observation
    /// and bind it to this new grant. A local Date(), retry or retained byte is not evidence.
    public func revalidate(variant: String, grant: RetentionGrant, sourceTime: Date, context: RequestContext) async throws {
        try await withObject(context: context) { lease in
            let k = try await key(context, lease: lease); let dir = try object(variant, context)
            var i = try await index(dir, k, lease: lease, context: context, requirePlayback: false)
            let authority = try await checkpoint(dir, lease: lease, context: context)
            let faultData = try await vault.protectedRecord(Self.clockFaultName, lease: lease, context: context)
            let clockState = try faultData.map { try JSONDecoder().decode(ClockFault.self, from: $0) }
            let faultFloor = clockState?.floor
            _ = try scope(context)
            // Local observed floors may be poisoned by a restart under a forward
            // clock. Only authenticated grant/source observations bound recovery.
            let floor=max(clockState?.authenticatedFloor ?? .distantPast,authority?.validationTime ?? i.grant.validatedAt)
            guard grant.validatedAt > max(i.grant.validatedAt, authority?.validationTime ?? .distantPast), sourceTime >= floor,
                  sourceTime >= grant.validatedAt, abs(sourceTime.timeIntervalSince(wall.now())) <= 2,
                  grant.expires > sourceTime, grant.rights.isSuperset(of: ["play", "retain"]),
                  !grant.issuer.isEmpty, !grant.sourceEncryption.isEmpty, !grant.renewalReference.isEmpty else { throw OfflineRecovery.clockChanged }
            i.grant = grant; i.highWater = max(floor, sourceTime)
            try await save(i, dir, k, lease: lease, context: context, installsGrant: true)
            try await vault.replaceProtectedRecord(Self.clockFaultName, value: JSONEncoder().encode(ClockFault(floor:sourceTime,blocked:false,validatedAt:grant.validatedAt,authenticatedFloor:max(floor,sourceTime),recovery:UUID())), lease: lease, context: context)
            _ = try scope(context)
            wallAnchor = wall.now(); monotonicAnchor = monotonic.now()
        }
    }
    public func invalidate(context: RequestContext, deleteFiles: Bool) async throws {
        let dir = try scope(context)
        let decoderDrains = retractDecoders(error: .unauthorized)
        active = RequestContext(account: nil, accountGeneration: context.accountGeneration, requestGeneration: context.requestGeneration)
        cachedKeys.removeAll(); keyExpiry?.cancel(); verified.removeAll(); validation.removeAll(); hashes.removeAll()
        let work=imports.values.filter{$0.account==context.account}.map{$0.task}
        for task in work { task.cancel() }
        for task in work { _ = await task.result }
        for drain in decoderDrains { await drain() }
        guard active?.account == nil, active?.accountGeneration == context.accountGeneration else { throw OfflineRecovery.reconnect }
        // Whole-identity invalidation is sign-out/revocation, matching W04.
        // Per-item entitlement revocation uses updateGrant and does not remove sessions.
        let barrier=active!; let name=dir.lastPathComponent; let files=self.files
        try await vault.eraseProtectedAccount(context.account!, barrier: barrier) {
            if deleteFiles, try files.exists(name) { try files.remove(name) }
        }
    }
    private func domain(_ error: Error) -> DomainError {
        switch error as? OfflineRecovery {
        case .reconnect, .missingKey: .unauthorized
        case .storageUnavailable: .transientTransport
        case .staleGrant, .seekNotPermitted: .forbidden
        case .renewRights, .clockChanged: .expiredMedia
        case .notRetained: .unavailableContent
        case .invalidRange: .invalidInput(.invalidRange)
        default: .malformedResponse
        }
    }
    public func validateEntitlement(_ media: ServiceID, context: RequestContext) async -> ServiceResult<OfflineEntitlement> {
        do { return try await withObject(context: context) { lease in
            let k = try await key(context, lease: lease); let i = try await index(object(media.rawValue, context), k, lease: lease, context: context)
            let value = try OfflineEntitlement(account: context.account!, media: media, source: i.grant.issuer,
                rights: Set(i.grant.rights.compactMap(OfflineRight.init(rawValue:))), expiresAt: i.grant.expires,
                renewAfter: nil, lastValidatedAt: i.grant.validatedAt, validation: .available)
            return .init(context: context, outcome: .success(value))
        } } catch { return .init(context: context, outcome: .failure(domain(error))) }
    }
    public func verify(_ media: ServiceID, context: RequestContext) async -> ServiceResult<Verification> {
        do { return try await withReadable(context: context) { lease in
            let k = try await key(context, lease: lease); let dir = try object(media.rawValue, context)
            let i = try await index(dir, k, lease: lease, context: context, requirePlayback: false)
            try validateComplete(dir, i, k)
            if hashes.count>=8, hashes[i.objectID]==nil{hashes.removeAll()}
            var progress=hashes[i.objectID] ?? HashProgress()
            let end=min(i.chunks,progress.offset+64)
            while progress.offset<end {
                try Task.checkCancellation()
                progress.hash.update(data:try open(dir,name:"chunk-\(progress.offset)",key:k,maximum:Self.chunkSize,binding:i.objectID.uuidString));progress.offset += 1
            }
            if progress.offset<i.chunks{hashes[i.objectID]=progress;throw ContinueRead()}
            hashes[i.objectID]=nil
            _ = try scope(context)
            return .init(context: context, outcome: .success(.verified(hash: progress.hash.finalize().map { String(format: "%02x", $0) }.joined(), at: wall.now())))
        } } catch { return .init(context: context, outcome: .failure(domain(error))) }
    }
    public func resolve(_ media: ServiceID, context: RequestContext) async -> ServiceResult<LocalAsset> {
        do {
            let verification = try await verify(media, context: context).outcome.get()
            let entitlement = try await validateEntitlement(media, context: context).outcome.get()
            return .init(context: context, outcome: .success(LocalAsset(reference: media, entitlement: entitlement, verification: verification)))
        } catch { return .init(context: context, outcome: .failure(error as? DomainError ?? domain(error))) }
    }
    public func pin(_ media: ServiceID, reference: ServiceID, context: RequestContext) async -> ServiceResult<DownloadJob> {
        do {
            let verification = try await verify(media, context: context).outcome.get()
            try await self.reference(variant: media.rawValue, reference: reference.rawValue, context: context)
            return try await withObject(context: context) { lease in
            let k = try await key(context, lease: lease); let i = try await index(object(media.rawValue, context), k, lease: lease, context: context, requirePlayback: false)
            let job = try DownloadJob(account: context.account!, media: media, variant: media, ranges: [ByteRange(lower: 0, upper: Int64(i.size - 1))], state: .completed, size: Int64(i.size), retries: 0, references: Set(try i.references.map(ServiceID.init)), verification: verification)
            return .init(context: context, outcome: .success(job))
        } } catch { return .init(context: context, outcome: .failure(error as? DomainError ?? domain(error))) }
    }
    public func unpin(_ media: ServiceID, reference: ServiceID, context: RequestContext) async -> ServiceResult<Void> {
        do { try await self.reference(variant: media.rawValue, reference: nil, remove: reference.rawValue, context: context); return .init(context: context, outcome: .success(())) }
        catch { return .init(context: context, outcome: .failure(domain(error))) }
    }
    public func delete(_ media: ServiceID, context: RequestContext) async -> ServiceResult<Void> {
        do {
            _ = try scope(context)
            for drain in retractDecoders(variant: media.rawValue, error: .unavailableContent) { await drain() }
            return try await withObject(context: context) { lease in
            let dir = try object(media.rawValue, context)
            try await commit(dir, bytes: nil, highWater: wall.now(), lease: lease, context: context) {
                if try exists(dir) { try self.remove(dir) }
            }
            return .init(context: context, outcome: .success(()))
        } }
        catch { return .init(context: context, outcome: .failure(domain(error))) }
    }

}
