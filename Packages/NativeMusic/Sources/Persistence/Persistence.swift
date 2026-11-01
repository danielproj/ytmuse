import Foundation
import Domain
import Darwin

public struct StoredPage<T: Sendable>: Sendable {
    public let items: [T]
    /// Keyset token, scoped and validated by the relevant read. Nil means exhausted.
    public let next: String?
}
public struct QueueContinuation: Sendable {
    public let contextID: ServiceID?
    public let cursor: String?
    public init(contextID: ServiceID?, cursor: String?) { self.contextID = contextID; self.cursor = cursor }
}
public struct RestoredQueue: Sendable {
    public let queue: QueueSession
    public let continuation: QueueContinuation
    /// Persisted positions never retain a process clock anchor or audible play intent.
    public let intent: PlaybackIntent = .pause(.restored)
}

/// Owns one SQLite connection off MainActor. No provider wire data or credentials accepted.
public actor SQLiteStore: PersistenceStore, MutationOutbox {
    let db: SQLite
    private var active: RequestContext?
    // Retain authority after removal clears active; nil only before first bootstrap.
    private var acceptedGeneration: UInt64?
    private var isClosed = false
    public let directory: URL
    public init(directory: URL, context: RequestContext? = nil) throws {
        try self.init(directory: directory, context: context, migration: .init())
    }
    init(directory: URL, context: RequestContext? = nil, migration: MigrationOptions) throws {
        try SQLite.privateDirectory(directory)
        let lock = directory.appendingPathComponent("migration.lock")
        try SQLite.privateFile(lock)
        let fd = open(lock.path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { throw StorageError.permissions }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw StorageError.permissions }
        let db = try SQLite(directory.appendingPathComponent("library.sqlite"))
        try db.migrate(migration)
        // WAL lets bounded readers coexist with checkpoints. FULL sync protects commit durability.
        guard try db.scalar("PRAGMA journal_mode=WAL").string == "wal" else { throw StorageError.sqlite }
        try db.execute("PRAGMA synchronous=FULL")
        try db.execute("PRAGMA wal_autocheckpoint=1000")
        try db.execute("PRAGMA secure_delete=ON")
        try db.protectSidecars()
        self.db = db; self.directory = directory; active = context
        acceptedGeneration = context?.accountGeneration
    }
    /// Session owner calls this after invalidating old work. Only a newer account
    /// generation may switch identity (including sign-out). Same-owner per-feature
    /// query generations may arrive in any order. A removed/closed owner cannot rebind.
    public func bind(_ context: RequestContext) {
        guard !isClosed else { return }
        if let acceptedGeneration {
            guard context.accountGeneration >= acceptedGeneration else { return }
            if context.accountGeneration == acceptedGeneration {
                guard let active, active.account == context.account else { return }
            }
        }
        acceptedGeneration = context.accountGeneration
        active = context
    }
    public func close() { db.close(); active = nil; isClosed = true }
    func scope(_ context: RequestContext) throws -> String {
        guard let active, active.account == context.account, active.accountGeneration == context.accountGeneration else { throw DomainError.staleContext }
        guard let account = context.account else { throw DomainError.unauthorized }
        return Self.key(account)
    }
    static func key(_ account: AccountContext) -> String {
        // Channel IDs can contain delimiters; length framing avoids collisions.
        account.accountID.uuidString + ":\(account.channelID.rawValue.utf8.count):" + account.channelID.rawValue + ":" + account.region
    }
    func validate(_ texts: String...) throws { for text in texts { try MetadataSafety.validate(text) } }
    func result<T: Sendable>(_ context: RequestContext, _ body: () throws -> T) -> ServiceResult<T> {
        do { return ServiceResult(context: context, outcome: .success(try body())) }
        catch let error as DomainError { return ServiceResult(context: context, outcome: .failure(error)) }
        catch { return ServiceResult(context: context, outcome: .failure(.malformedResponse)) }
    }
    public func saveAccount(_ account: Account, context: RequestContext) throws {
        let key = try scope(context)
        guard account.context == context.account else { throw DomainError.staleContext }
        try validate(account.serviceIdentity.rawValue, account.displayName, account.context.channelID.rawValue)
        // Local Keychain records are addressed by random UUID, never a token-shaped string.
        if let reference = account.credential { guard UUID(uuidString: reference.rawValue) != nil else { throw StorageError.invalidInput } }
        try db.execute("INSERT INTO identities VALUES(?,?,?,?,?,?,?) ON CONFLICT(scope) DO UPDATE SET service_id=excluded.service_id,label=excluded.label,credential_ref=excluded.credential_ref", [.text(key), .text(account.id.uuidString), .text(account.context.channelID.rawValue), .text(account.context.region), .text(account.serviceIdentity.rawValue), .text(account.displayName), account.credential.map { .text($0.rawValue) } ?? .null])
    }
    public func account(context: RequestContext) throws -> Account? {
        let key = try scope(context)
        guard let row = try db.all("SELECT service_id,label,credential_ref FROM identities WHERE scope=?", [.text(key)]).first, let account = context.account else { return nil }
        return try Account(id: account.accountID, serviceIdentity: sid(row[0].string), context: account, displayName: row[1].string, credential: row[2].optional.map(CredentialReference.init))
    }
    public func removeAccount(context: RequestContext) throws {
        let key = try scope(context)
        try eraseAccount(key: key)
        active = nil
    }
    /// Lifecycle-only maintenance: detached ownership is required; no private read
    /// permission is granted while deleting an inactive identity's durable partition.
    public func removeDetachedAccount(_ account: AccountContext, barrier: RequestContext) throws {
        guard barrier.account == nil, let active, active.account == nil,
              active.accountGeneration == barrier.accountGeneration else { throw DomainError.staleContext }
        try eraseAccount(key: Self.key(account))
    }
    private func eraseAccount(key: String) throws {
        // Scrub every retained app backup as well. A corrupt backup blocks removal with
        // an explicit error, rather than reporting deletion while retaining private data.
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("backup-v") && $0.pathExtension == "sqlite" }
        for backup in backups {
            let snapshot = try SQLite(backup)
            try snapshot.integrity()
            try snapshot.execute("PRAGMA secure_delete=ON")
            try snapshot.transaction {
                try snapshot.execute("DELETE FROM preferences WHERE scope IN (?,?)", [.text("account:" + key), .text("identity:" + key)])
                try snapshot.execute("DELETE FROM identities WHERE scope=?", [.text(key)])
                if try snapshot.scalar("PRAGMA user_version").int >= 2 { try snapshot.execute("INSERT INTO entity_fts(entity_fts) VALUES('rebuild')") }
            }
            try snapshot.execute("VACUUM")
            guard try snapshot.scalar("PRAGMA journal_mode=DELETE").string == "delete" else { throw StorageError.conflict }
            snapshot.close()
        }
        try db.transaction {
            try db.execute("DELETE FROM preferences WHERE scope IN (?,?)", [.text("account:" + key), .text("identity:" + key)])
            try db.execute("DELETE FROM identities WHERE scope=?", [.text(key)])
            try db.execute("INSERT INTO entity_fts(entity_fts) VALUES('rebuild')")
        }
        try db.execute("VACUUM")
        let checkpoint = try db.all("PRAGMA wal_checkpoint(TRUNCATE)")
        guard checkpoint.first?.first?.int == 0 else { throw StorageError.conflict }
    }
    public func saveMedia(_ items: [MediaItem], context: RequestContext) throws {
        guard items.count <= 1000 else { throw StorageError.invalidInput }
        let key = try scope(context)
        try db.transaction {
            for item in items {
                try validate(item.id.rawValue, item.title)
                try db.execute("INSERT INTO entities(scope,id,kind,title,detail) VALUES(?,?,?,?,?) ON CONFLICT(scope,id) DO UPDATE SET kind=excluded.kind,title=excluded.title,detail=excluded.detail", [.text(key), .text(item.id.rawValue), .text(item.kind.rawValue), .text(item.title.precomposedStringWithCanonicalMapping), .text(try encode(MediaRecord(item)))])
            }
        }
    }
    func pageLimit(_ limit: Int) throws { guard (1...200).contains(limit) else { throw StorageError.invalidInput } }
    public func mediaPage(after: String? = nil, limit: Int = 100, context: RequestContext) throws -> StoredPage<MediaItem> {
        try pageLimit(limit); let key = try scope(context)
        let rows = try db.all("SELECT id,kind,title,detail FROM entities WHERE scope=? AND id>? ORDER BY id LIMIT ?", [.text(key), .text(after ?? ""), .integer(Int64(limit + 1))])
        let items = try rows.prefix(limit).map { try decode(MediaRecord.self, $0[3].string).value(id: $0[0].string, kind: $0[1].string, title: $0[2].string) }
        return StoredPage(items: items, next: rows.count > limit ? rows[limit - 1][0].string : nil)
    }
    public func search(_ query: String, after: String? = nil, limit: Int = 100, context: RequestContext) throws -> StoredPage<MediaItem> {
        try pageLimit(limit); let key = try scope(context)
        guard query.utf8.count <= 512 else { throw StorageError.invalidInput }
        let tokens = query.precomposedStringWithCanonicalMapping.split { !$0.isLetter && !$0.isNumber }
        guard !tokens.isEmpty else { return StoredPage(items: [], next: nil) }
        let match = tokens.map { "\"" + $0 + "\"*" }.joined(separator: " AND ")
        let rows = try db.all("SELECT e.id,e.kind,e.title,e.detail FROM entity_fts JOIN entities e ON e.row_id=entity_fts.rowid WHERE entity_fts MATCH ? AND e.scope=? AND e.id>? ORDER BY e.id LIMIT ?", [.text(match), .text(key), .text(after ?? ""), .integer(Int64(limit + 1))])
        return StoredPage(items: try rows.prefix(limit).map { try decode(MediaRecord.self, $0[3].string).value(id: $0[0].string, kind: $0[1].string, title: $0[2].string) }, next: rows.count > limit ? rows[limit - 1][0].string : nil)
    }
    public func saveCollection(_ id: ServiceID, metadata: CatalogMetadata, context: RequestContext) throws {
        let key = try scope(context); try validate(id.rawValue, metadata.title)
        try db.execute("INSERT INTO collections VALUES(?,?,?) ON CONFLICT(scope,id) DO UPDATE SET metadata=excluded.metadata", [.text(key), .text(id.rawValue), .text(try encode(CatalogRecord(metadata)))])
    }
    /// Page replacement is explicit and atomic; occurrence IDs, including duplicate media, survive.
    public func storeCollectionPage(_ id: ServiceID, entries: [PlaylistItem], startingAt: Int, replaceAll: Bool = false, context: RequestContext) throws {
        guard entries.count <= 1000, startingAt >= 0 else { throw StorageError.invalidInput }
        let key = try scope(context)
        try db.transaction {
            if replaceAll { try db.execute("DELETE FROM collection_entries WHERE scope=? AND collection=?", [.text(key), .text(id.rawValue)]) }
            for (offset, entry) in entries.enumerated() {
                try validate(occurrence(entry.occurrence), entry.media.rawValue)
                try db.execute("INSERT INTO collection_entries VALUES(?,?,?,?,?)", [.text(key), .text(id.rawValue), .integer(Int64(startingAt + offset)), .text(occurrence(entry.occurrence)), .text(entry.media.rawValue)])
            }
        }
    }
    public func collectionPage(_ id: ServiceID, after: Int = -1, limit: Int = 100, context: RequestContext) throws -> StoredPage<PlaylistItem> {
        try pageLimit(limit); let key = try scope(context)
        let rows = try db.all("SELECT ordinal,occurrence,media FROM collection_entries WHERE scope=? AND collection=? AND ordinal>? ORDER BY ordinal LIMIT ?", [.text(key), .text(id.rawValue), .integer(Int64(after)), .integer(Int64(limit + 1))])
        return StoredPage(items: try rows.prefix(limit).map { try PlaylistItem(occurrence: occurrence($0[1].string), media: sid($0[2].string)) }, next: rows.count > limit ? String(rows[limit - 1][0].int) : nil)
    }
    public func saveQueue(_ queue: QueueSession, continuation: QueueContinuation = .init(contextID: nil, cursor: nil), context: RequestContext) throws {
        try writeQueue(queue, continuation: continuation, context: context)
    }
    // Internal transaction seam permits deterministic throw/kill at the actual write boundaries.
    func writeQueue(_ queue: QueueSession, continuation: QueueContinuation, context: RequestContext, boundary: ((String) throws -> Void)? = nil) throws {
        let key = try scope(context)
        guard queue.account == context.account, queue.entries.count <= 100_000 else { throw StorageError.invalidInput }
        try validate(continuation.contextID?.rawValue ?? "", continuation.cursor ?? "")
        try db.transaction {
            let previous = try db.scalar("SELECT version FROM queues WHERE scope=?", [.text(key)]).optional
            if let previous, queue.version < (try unsigned(previous)) { throw StorageError.conflict }
            try db.execute("INSERT INTO queues VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(scope) DO UPDATE SET version=excluded.version,current=excluded.current,position=excluded.position,seed=excluded.seed,repeat_mode=excluded.repeat_mode,autoplay=excluded.autoplay,context_id=excluded.context_id,cursor=excluded.cursor", [.text(key), .text(String(queue.version)), queue.currentOccurrence.map { .text($0.uuidString) } ?? .null, .real(queue.position), queue.shuffleSeed.map { .text(String($0)) } ?? .null, .text(queue.repeatMode.rawValue), .integer(queue.autoplay ? 1 : 0), continuation.contextID.map { .text($0.rawValue) } ?? .null, continuation.cursor.map(SQLValue.text) ?? .null])
            try boundary?("header")
            try db.execute("DELETE FROM queue_entries WHERE scope=?", [.text(key)])
            for (ordinal, entry) in queue.entries.enumerated() {
                try validate(entry.media.rawValue)
                try db.execute("INSERT INTO queue_entries VALUES(?,?,?,?,?,?,?)", [.text(key), .integer(Int64(ordinal)), .text(entry.id.uuidString), .text(entry.media.rawValue), .text(entry.segment.rawValue), .integer(Int64(entry.originalOrder)), .integer(entry.consumed ? 1 : 0)])
                if ordinal == 0 { try boundary?("entry") }
            }
            try boundary?("beforeCommit")
        }
        try boundary?("afterCommit")
    }
    /// Full queue for the command owner only. UI uses queuePage, never this read per frame.
    public func restoredQueue(context: RequestContext) throws -> RestoredQueue? {
        let key = try scope(context)
        // A read transaction prevents another process changing header between page reads.
        return try db.transaction {
            guard let row = try db.all("SELECT version,current,position,seed,repeat_mode,autoplay,context_id,cursor FROM queues WHERE scope=?", [.text(key)]).first else { return nil }
            let count = try db.scalar("SELECT count(*) FROM queue_entries WHERE scope=?", [.text(key)]).int
            guard count <= 100_000 else { throw StorageError.corrupt }
            let entries = try queueRows(key: key, after: -1, limit: Int(count))
            let queue = try QueueSession(account: required(context.account), version: unsigned(row[0].string), entries: entries, currentOccurrence: row[1].optional.map(uuid), position: row[2].double, shuffleSeed: row[3].optional.map(unsigned), repeatMode: required(RepeatMode(rawValue: row[4].string)), autoplay: row[5].int == 1)
            return RestoredQueue(queue: queue, continuation: QueueContinuation(contextID: try row[6].optional.map(sid), cursor: row[7].optional))
        }
    }
    func queueRows(key: String, after: Int, limit: Int) throws -> [QueueEntry] {
        try db.all("SELECT occurrence,media,segment,original_order,consumed FROM queue_entries WHERE scope=? AND ordinal>? ORDER BY ordinal LIMIT ?", [.text(key), .integer(Int64(after)), .integer(Int64(limit))]).map {
            try QueueEntry(id: uuid($0[0].string), media: sid($0[1].string), segment: required(QueueSegment(rawValue: $0[2].string)), originalOrder: Int($0[3].int), consumed: $0[4].int == 1)
        }
    }
    public func queuePage(after: Int = -1, limit: Int = 100, context: RequestContext) throws -> [QueueEntry] { try pageLimit(limit); return try queueRows(key: scope(context), after: after, limit: limit) }
    public func queue(context: RequestContext) -> ServiceResult<QueueSession?> { result(context) { try restoredQueue(context: context)?.queue } }
    public func checkpoint(_ queue: QueueSession, context: RequestContext) -> ServiceResult<Void> {
        result(context) {
            let key = try scope(context)
            let row = try db.all("SELECT context_id,cursor FROM queues WHERE scope=?", [.text(key)]).first
            let continuation = QueueContinuation(contextID: try row?[0].optional.map(sid), cursor: row?[1].optional)
            try saveQueue(queue, continuation: continuation, context: context)
        }
    }
    func preferenceKey(_ preference: PreferenceScope, context: RequestContext) throws -> String {
        guard let active, active.account == context.account, active.accountGeneration == context.accountGeneration else { throw DomainError.staleContext }
        switch preference {
        case .global: return "global"
        case .window(let id): return "window:" + id.uuidString
        case .account(let account): guard account == context.account else { throw DomainError.staleContext }; return "account:" + (try scope(context))
        }
    }
    public func preferences(scope: PreferenceScope, context: RequestContext) -> ServiceResult<Preferences> {
        result(context) {
            let key = try preferenceKey(scope, context: context)
            guard let row = try db.all("SELECT version,payload FROM preferences WHERE scope=?", [.text(key)]).first else { return try Preferences(scope: scope, schemaVersion: 1, values: [:]) }
            return try Preferences(scope: scope, schemaVersion: Int(row[0].int), values: decode([String: PreferenceRecord].self, row[1].string).mapValues { try $0.value() })
        }
    }
    public func store(_ preferences: Preferences, context: RequestContext) -> ServiceResult<Void> {
        result(context) {
            let key = try preferenceKey(preferences.scope, context: context)
            guard preferences.values.count <= 500 else { throw StorageError.invalidInput }
            try db.execute("INSERT INTO preferences VALUES(?,?,?) ON CONFLICT(scope) DO UPDATE SET version=excluded.version,payload=excluded.payload", [.text(key), .integer(Int64(preferences.schemaVersion)), .text(try encode(preferences.values.mapValues(PreferenceRecord.init)))])
        }
    }
    public func clearPreferences(scope: PreferenceScope, context: RequestContext) throws { try db.execute("DELETE FROM preferences WHERE scope=?", [.text(try preferenceKey(scope, context: context))]) }
    public func backup() throws -> URL {
        let destination = directory.appendingPathComponent("backup-v\(try db.scalar("PRAGMA user_version").int)-\(UUID().uuidString).sqlite")
        try db.backup(to: destination); return destination
    }
}

struct CatalogRecord: Codable {
    let id: String; let title: String; let description: String?; let artwork: [String]; let related: [String]
    init(_ metadata: CatalogMetadata) { id = metadata.id.rawValue; title = metadata.title; description = metadata.description; artwork = metadata.artwork.map(\.rawValue); related = metadata.related.map(\.rawValue) }
}
