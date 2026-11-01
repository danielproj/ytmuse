import Foundation

/// What the upload route can do, as the route itself reports it. Nothing here is assumed on the service's behalf: a size limit
/// exists only when the route published one, and resuming is offered only when the route says it can.
public struct UploadCapability: Equatable, Sendable {
    public enum Availability: Equatable, Sendable { case available, unavailable(String) }
    public enum Resumption: Equatable, Sendable { case unsupported, supported }
    public var availability: Availability
    public var resumption: Resumption
    public var maximumFileBytes: Int64?
    public init(availability: Availability, resumption: Resumption = .unsupported, maximumFileBytes: Int64? = nil) {
        self.availability = availability; self.resumption = resumption; self.maximumFileBytes = maximumFileBytes
    }
    public var isAvailable: Bool { availability == .available }
    /// The production state until the real Music upload route lands (W37).
    public static var notYet: UploadCapability { UploadCapability(availability: .unavailable(String(localized: "Uploading arrives in a later update"))) }
}

/// One upload as the transport receives it: the leased file, what it is, and where to continue from when resuming.
public struct UploadRequest: Sendable {
    public let jobID: UUID
    public let fileURL: URL
    public let byteCount: Int64
    public let metadata: UploadMetadata
    /// Present only for a resumed upload: the transport's own handle for the earlier attempt.
    public let resumeHandle: String?
    public init(jobID: UUID, fileURL: URL, byteCount: Int64, metadata: UploadMetadata, resumeHandle: String? = nil) {
        self.jobID = jobID; self.fileURL = fileURL; self.byteCount = byteCount; self.metadata = metadata; self.resumeHandle = resumeHandle
    }
}
/// What the service says about a file it has received.
public enum UploadProcessing: Equatable, Sendable {
    case processing
    case completed
    /// The service's own reason, verbatim and bounded; nil when it gave none.
    case failed(String?)
}
public enum UploadTransportError: Error, Equatable, Sendable {
    case offline, unavailable, needsSignIn, sessionEnded, rateLimited
    /// The service answered and refused this file; its words are kept as they are.
    case refused(String?)
    /// The service cannot continue the earlier attempt.
    case resumeRejected
    case cancelled
}

/// The seam to the service's upload route. Tests and test mode use a scripted one; the application's real composition holds
/// `UnavailableUploadTransport` until the Music locker route is built and observed (W37). A generic video upload is never a substitute.
public protocol UploadTransport: Sendable {
    var capability: UploadCapability { get }
    /// Sends the file. `handle` reports the transport's identifier for this upload as soon as there is one (so a resumable one can be
    /// continued after a restart); the return value is the identifier the service will report processing under.
    /// An upload must stop when its task is cancelled (the queue cancels the task and also calls `cancel(handle:)`, and starts nothing else
    /// until that call returns).
    func upload(_ request: UploadRequest, progress: @escaping @Sendable (Int64) -> Void, handle: @escaping @Sendable (String) -> Void) async throws -> String
    func processing(handle: String) async throws -> UploadProcessing
    /// Ends whatever access this upload held. Best effort; a processing file the service already has is not taken back.
    func cancel(handle: String?) async
}

/// The production transport until W37: there is no upload route, and every call says so. Nothing is sent anywhere.
public struct UnavailableUploadTransport: UploadTransport {
    public init() {}
    public var capability: UploadCapability { .notYet }
    public func upload(_ request: UploadRequest, progress: @escaping @Sendable (Int64) -> Void, handle: @escaping @Sendable (String) -> Void) async throws -> String { throw UploadTransportError.unavailable }
    public func processing(handle: String) async throws -> UploadProcessing { throw UploadTransportError.unavailable }
    public func cancel(handle: String?) async {}
}
