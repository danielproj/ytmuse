import Foundation

/// One upload the person started. The record holds no file contents and no credential. The service's own words are kept verbatim
/// in `serverMessage`, and nothing in it is a claim about quotas or formats beyond what the service itself said.
public struct UploadJob: Identifiable, Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case queued, uploading, processing, completed, failed, cancelled, interrupted }
    public enum Reason: String, Codable, Sendable {
        case offline, serverRefused, processingFailed, unavailable, needsSignIn, sessionEnded, rateLimited, fileChanged, fileUnreadable
        case appClosed, accountChanged, resumeRejected, byUser
    }
    /// After the service confirmed processing: whether the Uploads lists were read again, and whether that read worked.
    public enum Listing: String, Codable, Sendable { case notRefreshed, refreshed, refreshFailed }

    public let id: UUID
    public let account: String
    public var source: UploadSource
    public internal(set) var phase: Phase
    public internal(set) var reason: Reason?
    public internal(set) var serverMessage: String?
    public internal(set) var bytesSent: Int64
    /// The transport's identifier for this upload (what processing is asked about, and what a resumable transport continues).
    public internal(set) var handle: String?
    public internal(set) var attempts: Int
    public internal(set) var listing: Listing?
    /// Cancelled while the service already had the file: it may still finish processing it.
    public internal(set) var serverMayStillProcess: Bool
    /// Why the last status check could not say, while the job waits in processing.
    public internal(set) var checkNote: String?
    public let createdAt: Date
    public internal(set) var updatedAt: Date

    public init(id: UUID = UUID(), account: String, source: UploadSource, now: Date = Date()) {
        self.id = id; self.account = account; self.source = source; phase = .queued; reason = nil; serverMessage = nil; bytesSent = 0; handle = nil
        attempts = 1; listing = nil; serverMayStillProcess = false; checkNote = nil; createdAt = now; updatedAt = now
    }
    public var isActive: Bool { [.queued, .uploading, .processing].contains(phase) }
    public var isTerminal: Bool { [.completed, .failed, .cancelled].contains(phase) }
    public var fraction: Double? { source.byteCount > 0 ? min(1, Double(bytesSent) / Double(source.byteCount)) : nil }
    /// Phases a job may move to from this one. A completed or cancelled job never moves again; a failed or interrupted one only by a
    /// new explicit attempt (`restart`).
    static func allowed(from phase: Phase) -> Set<Phase> {
        switch phase {
        case .queued: [.uploading, .cancelled, .failed, .interrupted]
        case .uploading: [.processing, .failed, .cancelled, .interrupted]
        case .processing: [.completed, .failed, .cancelled, .interrupted]
        case .interrupted: [.queued, .uploading, .cancelled, .failed, .processing]
        case .failed: [.queued]
        case .completed, .cancelled: []
        }
    }
    mutating func move(to next: Phase, reason: Reason? = nil, message: String? = nil, now: Date = Date()) -> Bool {
        guard Self.allowed(from: phase).contains(next) else { return false }
        phase = next; self.reason = reason; serverMessage = message.map { String($0.prefix(500)) }; updatedAt = now
        return true
    }
}

public extension UploadJob.Reason {
    var message: String {
        switch self {
        case .offline: String(localized: "You’re offline. The upload stopped and nothing was queued.")
        case .serverRefused: String(localized: "YouTube Music didn’t accept this file.")
        case .processingFailed: String(localized: "YouTube Music couldn’t process this file.")
        case .unavailable: String(localized: "YouTube Music couldn’t take this upload right now.")
        case .needsSignIn: String(localized: "Sign in to YouTube Music to upload.")
        case .sessionEnded: String(localized: "Your session ended. Sign in again to upload.")
        case .rateLimited: String(localized: "YouTube Music is asking for a pause. Try again in a moment.")
        case .fileChanged: String(localized: "The file changed after it was chosen. Choose it again.")
        case .fileUnreadable: String(localized: "This app can’t read the file any more. Choose it again.")
        case .appClosed: String(localized: "The app closed before this upload finished.")
        case .accountChanged: String(localized: "The account changed, so this upload was stopped.")
        case .resumeRejected: String(localized: "YouTube Music can’t continue this upload.")
        case .byUser: String(localized: "You cancelled this upload.")
        }
    }
}
