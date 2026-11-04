import AccountSession
import Domain
import Features
import Foundation

/// This Mac's own record of what the app played, one small private file per account inside the app's data directory (the isolated
/// scratch root under QA isolation). It is never sent anywhere. Removing the account removes its file (lifecycle participant).
actor LocalHistoryFileStore: LocalHistoryStoring, AccountLifecycleParticipant {
    nonisolated let participantID = "local-history"
    enum Failure: Error { case invalidAccount, corrupt }
    private let directory: URL
    private let maximum: Int
    init(directory: URL, maximum: Int = 5_000) { self.directory = directory; self.maximum = maximum }

    private func file(_ account: String) throws -> URL {
        // The account key is a UUID the app made; anything else is refused before it can become part of a path.
        guard let id = UUID(uuidString: account) else { throw Failure.invalidAccount }
        return directory.appendingPathComponent(id.uuidString + ".plist")
    }
    private func read(_ url: URL) throws -> [LocalHistoryRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024, let list = try? PropertyListDecoder().decode([LocalHistoryRecord].self, from: data) else { throw Failure.corrupt }
        return list
    }
    private func write(_ list: [LocalHistoryRecord], to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(list).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func append(_ record: LocalHistoryRecord, account: String) throws {
        let url = try file(account)
        var list = try read(url)
        list.insert(record, at: 0)
        if list.count > maximum { list.removeLast(list.count - maximum) }
        try write(list, to: url)
    }
    func recent(account: String, limit: Int) throws -> [LocalHistoryRecord] {
        Array(try read(try file(account)).prefix(max(0, limit)))
    }
    func update(_ record: LocalHistoryRecord, account: String) throws {
        let url = try file(account)
        var list = try read(url)
        guard let index = list.firstIndex(where: { $0.id == record.id }) else { return }
        list[index] = record
        try write(list, to: url)
    }
    func clear(account: String) throws {
        let url = try file(account)
        try GuardedFiles(root: directory).remove(url)
    }

    func detach(previous: RequestContext, barrier: RequestContext) async throws {}
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {}
    /// Removing an account removes what this Mac kept for it.
    func removeLocal(_ account: AccountContext, context: RequestContext) async throws {
        try? await clear(account: account.accountID.uuidString)
    }
}

/// The store the interface holds before the account directory is known; operations before `bind` fail, they are never dropped silently.
actor LateBoundHistoryStore: LocalHistoryStoring {
    enum Failure: Error { case notBound }
    private var target: (any LocalHistoryStoring)?
    func bind(_ store: any LocalHistoryStoring) { target = store }
    func append(_ record: LocalHistoryRecord, account: String) async throws { try await bound().append(record, account: account) }
    func recent(account: String, limit: Int) async throws -> [LocalHistoryRecord] { try await bound().recent(account: account, limit: limit) }
    func update(_ record: LocalHistoryRecord, account: String) async throws { try await bound().update(record, account: account) }
    func clear(account: String) async throws { try await bound().clear(account: account) }
    private func bound() throws -> any LocalHistoryStoring { guard let target else { throw Failure.notBound }; return target }
}
