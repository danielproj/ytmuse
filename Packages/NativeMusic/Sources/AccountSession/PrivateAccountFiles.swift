import Foundation
import Domain

/// Register separate roots for private artwork, retained media, extension snapshots,
/// and index sidecars. Future modules must register their own removal participants.
/// Paths use the local UUID, never service input; no untrusted path traversal.
public actor PrivateAccountFiles: AccountLifecycleParticipant {
    public nonisolated let participantID: String
    private let root: URL
    public init(id: String, root: URL) throws {
        self.participantID = id; self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LifecycleError.invalidDirectory }
    }
    /// Entire local-account directory contains every channel's objects. Deleting a
    /// channel must not delete its siblings: channel/region use a safe hex encoding.
    public nonisolated static func relativePath(_ account: AccountContext) -> String {
        account.accountID.uuidString + "/" + (account.channelID.rawValue + ":" + account.region).utf8.map { String(format: "%02x", $0) }.joined()
    }
    public func detach(previous: RequestContext, barrier: RequestContext) {}
    public func restorePaused(_ identity: LocalIdentity, context: RequestContext) {}
    public func removeLocal(_ account: AccountContext, context: RequestContext) throws {
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LifecycleError.invalidDirectory }
        let parent = root.appendingPathComponent(account.accountID.uuidString)
        if FileManager.default.fileExists(atPath: parent.path) {
            guard try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LifecycleError.invalidDirectory }
        }
        let target = root.appendingPathComponent(Self.relativePath(account))
        try GuardedFiles(root: root).remove(target)
    }
}
