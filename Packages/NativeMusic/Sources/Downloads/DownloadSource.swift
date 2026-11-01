import Foundation
import CryptoKit
import Domain
import Darwin

/// An explicit permission to keep a copy, exactly as the source states it. The scheduler never invents one: a source that
/// cannot state a permission cannot be downloaded from. Maps onto the W14 `RetentionGrant`.
public struct DownloadPermission: Sendable, Equatable {
    public var issuer: String
    public var sourceEncryption: String
    public var validatedAt: Date
    public var expires: Date
    public var renewAfter: Date?
    public var renewalReference: String
    public var rights: Set<String>
    public init(issuer: String, sourceEncryption: String, validatedAt: Date, expires: Date, renewAfter: Date?, renewalReference: String, rights: Set<String> = ["play", "seek", "retain"]) {
        self.issuer = issuer; self.sourceEncryption = sourceEncryption; self.validatedAt = validatedAt; self.expires = expires; self.renewAfter = renewAfter; self.renewalReference = renewalReference; self.rights = rights
    }
    var grant: RetentionGrant { RetentionGrant(issuer: issuer, sourceEncryption: sourceEncryption, expires: expires, renewalReference: renewalReference, rights: rights, validatedAt: validatedAt) }
}
/// What a source says about the exact bytes it will serve. `variant` plus `validator` identify one byte sequence:
/// bytes are never combined across two different descriptors (OFF07).
public struct SourceDescriptor: Sendable, Equatable {
    public var variant: String
    public var validator: String?
    public var length: Int64?
    public var supportsRanges: Bool
    public var urlExpiresAt: Date?
    public var sha256: String?
    public var permission: DownloadPermission
    public init(variant: String, validator: String? = nil, length: Int64?, supportsRanges: Bool, urlExpiresAt: Date? = nil, sha256: String? = nil, permission: DownloadPermission) {
        self.variant = variant; self.validator = validator; self.length = length; self.supportsRanges = supportsRanges; self.urlExpiresAt = urlExpiresAt; self.sha256 = sha256; self.permission = permission
    }
    func sameBytes(as other: SourceDescriptor) -> Bool { variant == other.variant && validator == other.validator && length == other.length }
}
public struct SourceRead: Sendable {
    public let data: Data
    /// True when nothing follows (needed when the total length is unknown).
    public let endOfStream: Bool
    public init(data: Data, endOfStream: Bool) { self.data = data; self.endOfStream = endOfStream }
}
public enum SourceFailure: Error, Equatable, Sendable {
    /// The address that served the bytes lapsed: describe again and continue.
    case urlExpired
    case transient(retryAfter: TimeInterval?)
    case unavailable
    case permissionDenied
    case unauthorized
}
/// The item a source is asked about. `location` is a source-private hint kept in the job record (a file path for a local file).
public struct SourceItem: Sendable, Equatable {
    public let media: ServiceID
    public let location: String?
    public init(media: ServiceID, location: String? = nil) { self.media = media; self.location = location }
}
/// A place media may be kept from. Registered by the composition root per `MediaOrigin`; a fake transport in tests.
public protocol DownloadSource: Sendable {
    func describe(item: SourceItem, context: RequestContext) async throws -> SourceDescriptor
    func read(item: SourceItem, descriptor: SourceDescriptor, offset: Int64, count: Int, context: RequestContext) async throws -> SourceRead
    /// A fresh permission for an item already kept (OFF08). Throws `.permissionDenied` when the source no longer allows it.
    func renew(item: SourceItem, descriptor: SourceDescriptor, context: RequestContext) async throws -> DownloadPermission
    /// SHA-256 (lower-case hex) of the first `length` bytes the source serves for this descriptor, when the source can state it
    /// without a network fetch (a local file). Lets a finished copy be checked against what the source really holds, so
    /// bytes that were never written cannot pass as complete.
    func contentDigest(item: SourceItem, descriptor: SourceDescriptor, length: Int64) async throws -> String?
}
public extension DownloadSource {
    func contentDigest(item: SourceItem, descriptor: SourceDescriptor, length: Int64) async throws -> String? { nil }
}

/// Keeps a file the account holder chose on this Mac, or a bundled owned signal. The "permission" is the holder's own
/// declaration of ownership, valid for a fixed app policy window and renewed on use; it is not a service rule.
public struct LocalFileDownloadSource: DownloadSource {
    public static let validity: TimeInterval = 400 * 24 * 3600
    /// W29 (SEC05): the most one read returns, whatever the caller asks for. The scheduler asks for its chunk size (1 MiB); a count taken from anywhere else must not become an allocation of the file's size.
    public static let maximumRead = 8 * 1024 * 1024
    public static let renewBefore: TimeInterval = 30 * 24 * 3600
    private let resolve: @Sendable (SourceItem) throws -> URL
    private let issuer: String
    private let wall: any WallClock
    /// Bundled owned media is retained under its own identifier, which is what the owned native asset seam looks up.
    private let exactVariant: Bool
    /// `resolve` maps an item to its file; the default reads the path the job recorded.
    public init(issuer: String, wall: any WallClock = SystemWallClock(), exactVariant: Bool = false, resolve: @escaping @Sendable (SourceItem) throws -> URL = { item in
        guard let path = item.location else { throw SourceFailure.unavailable }
        return URL(fileURLWithPath: path)
    }) {
        self.issuer = issuer; self.wall = wall; self.exactVariant = exactVariant; self.resolve = resolve
    }
    private func permission() -> DownloadPermission {
        let now = wall.now()
        return DownloadPermission(issuer: issuer, sourceEncryption: "none: file held by the account holder", validatedAt: now, expires: now.addingTimeInterval(Self.validity), renewAfter: now.addingTimeInterval(Self.validity - Self.renewBefore), renewalReference: "holder-declared-ownership")
    }
    private func open(_ url: URL) throws -> (Int32, stat) {
        guard url.isFileURL else { throw SourceFailure.unavailable }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SourceFailure.unavailable }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0 else { Darwin.close(fd); throw SourceFailure.unavailable }
        return (fd, st)
    }
    public func describe(item: SourceItem, context: RequestContext) async throws -> SourceDescriptor {
        let media = item.media
        let url = try resolve(item)
        let (fd, st) = try open(url); defer { Darwin.close(fd) }
        // The validator ties resumed ranges to this exact file: a changed file is a different byte sequence.
        let validator = "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        let digest = SHA256.hash(data: Data(media.rawValue.utf8) + Data(validator.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return SourceDescriptor(variant: exactVariant ? media.rawValue : "\(media.rawValue)#\(digest)", validator: validator, length: Int64(st.st_size), supportsRanges: true, permission: permission())
    }
    public func read(item: SourceItem, descriptor: SourceDescriptor, offset: Int64, count: Int, context: RequestContext) async throws -> SourceRead {
        try Task.checkCancellation()
        let (fd, st) = try open(try resolve(item)); defer { Darwin.close(fd) }
        let validator = "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        guard validator == descriptor.validator else { throw SourceFailure.urlExpired }   // the file changed: describe again
        guard offset >= 0, count >= 0 else { throw SourceFailure.unavailable }
        var buffer = Data(count: max(0, min(count, Self.maximumRead, Int(st.st_size) - Int(offset))))
        guard !buffer.isEmpty else { return SourceRead(data: Data(), endOfStream: true) }
        let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
        guard n >= 0 else { throw SourceFailure.transient(retryAfter: nil) }
        buffer.removeSubrange(n...)
        return SourceRead(data: buffer, endOfStream: offset + Int64(n) >= Int64(st.st_size))
    }
    public func contentDigest(item: SourceItem, descriptor: SourceDescriptor, length: Int64) async throws -> String? {
        let (fd, st) = try open(try resolve(item)); defer { Darwin.close(fd) }
        let validator = "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        guard validator == descriptor.validator, Int64(st.st_size) >= length else { throw SourceFailure.urlExpired }
        var hasher = SHA256(); var offset: Int64 = 0; var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while offset < length {
            try Task.checkCancellation()
            let want = Int(min(Int64(buffer.count), length - offset))
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(offset)) }
            guard n > 0 else { throw SourceFailure.transient(retryAfter: nil) }
            hasher.update(data: Data(buffer[0..<n])); offset += Int64(n)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public func renew(item: SourceItem, descriptor: SourceDescriptor, context: RequestContext) async throws -> DownloadPermission {
        // Renewing a holder's own declaration needs nothing from the source file; the retained copy is already the holder's.
        permission()
    }
}

/// The store operations the scheduler needs. `EncryptedStoreSink` is the production implementation (W14 encrypted objects).
public protocol RetentionSink: Sendable {
    func retain(file: URL, variant: String, grant: RetentionGrant, reference: String, context: RequestContext) async throws
    func addReference(variant: String, reference: String, context: RequestContext) async throws
    func removeReference(variant: String, reference: String, context: RequestContext) async throws
    func setPinned(variant: String, pinned: Bool, context: RequestContext) async throws
    func retainedLength(variant: String, context: RequestContext) async throws -> Int
    /// Verifies the stored copy and returns the SHA-256 of its plaintext when the store can state it.
    @discardableResult func verify(variant: String, context: RequestContext) async throws -> String?
    func updateGrant(variant: String, grant: RetentionGrant, context: RequestContext) async throws
    func delete(variant: String, context: RequestContext) async throws
    func bind(_ context: RequestContext) async
}
public struct EncryptedStoreSink: RetentionSink {
    public let store: EncryptedStore
    public init(store: EncryptedStore) { self.store = store }
    public func retain(file: URL, variant: String, grant: RetentionGrant, reference: String, context: RequestContext) async throws {
        try await store.retain(file: file, variant: variant, grant: grant, reference: reference, context: context)
    }
    public func addReference(variant: String, reference: String, context: RequestContext) async throws {
        try await store.reference(variant: variant, reference: reference, context: context)
    }
    public func removeReference(variant: String, reference: String, context: RequestContext) async throws {
        try await store.reference(variant: variant, reference: nil, remove: reference, context: context)
    }
    public func setPinned(variant: String, pinned: Bool, context: RequestContext) async throws {
        try await store.reference(variant: variant, reference: nil, pinned: pinned, context: context)
    }
    public func retainedLength(variant: String, context: RequestContext) async throws -> Int { try await store.length(variant: variant, context: context) }
    @discardableResult public func verify(variant: String, context: RequestContext) async throws -> String? {
        guard let id = try? ServiceID(variant) else { throw OfflineRecovery.notRetained }
        // The store slices verification internally and returns once it has settled.
        switch await store.verify(id, context: context).outcome {
        case .success(.verified(let hash, _)): return hash
        case .success: throw DomainError.malformedResponse
        case .failure(let error): throw error
        }
    }
    public func updateGrant(variant: String, grant: RetentionGrant, context: RequestContext) async throws {
        try await store.updateGrant(variant: variant, grant: grant, context: context)
    }
    public func delete(variant: String, context: RequestContext) async throws {
        guard let id = try? ServiceID(variant) else { return }
        try await store.delete(id, context: context).outcome.get()
    }
    public func bind(_ context: RequestContext) async { await store.bind(context) }
}
