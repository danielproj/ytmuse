import Foundation
import Domain

extension SQLiteStore {
    public func saveMembership(_ membership: LibraryMembership, context: RequestContext) throws {
        let key = try scope(context); guard membership.account == context.account else { throw DomainError.staleContext }
        try validate(membership.entity.rawValue, membership.sortKey)
        try db.execute("INSERT INTO memberships VALUES(?,?,?,?,?,?) ON CONFLICT(scope,entity) DO UPDATE SET status=excluded.status,sync=excluded.sync,sort_date=excluded.sort_date,sort_key=excluded.sort_key", [.text(key), .text(membership.entity.rawValue), membership.serviceStatus.map { .integer($0 ? 1 : 0) } ?? .null, .text(try encode(SyncRecord(membership.sync))), membership.sortDate.map { .real($0.timeIntervalSince1970) } ?? .null, .text(membership.sortKey)])
    }
    public func membership(_ id: ServiceID, context: RequestContext) throws -> LibraryMembership? {
        let key = try scope(context)
        guard let row = try db.all("SELECT status,sync,sort_date,sort_key FROM memberships WHERE scope=? AND entity=?", [.text(key), .text(id.rawValue)]).first else { return nil }
        let date: Date? = if case .null = row[2] { nil } else { Date(timeIntervalSince1970: row[2].double) }
        let status: Bool? = if case .null = row[0] { nil } else { row[0].int == 1 }
        return try LibraryMembership(account: required(context.account), entity: id, serviceStatus: status, sync: decode(SyncRecord.self, row[1].string).value(), sortDate: date, sortKey: row[3].string)
    }
    public func appendHistory(_ entry: HistoryEntry, context: RequestContext) throws {
        let key = try scope(context); guard entry.account == context.account else { throw DomainError.staleContext }; try validate(entry.item.rawValue)
        try db.execute("INSERT INTO history VALUES(?,?,?,?,?,?,?) ON CONFLICT(scope,id) DO UPDATE SET ended=excluded.ended,sync=excluded.sync", [.text(entry.id.uuidString), .text(key), .text(entry.item.rawValue), .real(entry.startedAt.timeIntervalSince1970), entry.endedAt.map { .real($0.timeIntervalSince1970) } ?? .null, .text(entry.provenance.rawValue), .text(try encode(SyncRecord(entry.sync)))])
    }
    /// A bounded recent view, with an explicit provenance. No remote clear implied.
    public func recentHistory(provenance: HistoryProvenance, limit: Int = 100, context: RequestContext) throws -> [HistoryEntry] {
        try pageLimit(limit); let key = try scope(context)
        return try db.all("SELECT id,media,started,ended,sync FROM history WHERE scope=? AND provenance=? ORDER BY started DESC,id LIMIT ?", [.text(key), .text(provenance.rawValue), .integer(Int64(limit))]).map { row in
            let ended: Date? = if case .null = row[3] { nil } else { Date(timeIntervalSince1970: row[3].double) }
            return try HistoryEntry(id: uuid(row[0].string), account: required(context.account), item: sid(row[1].string), startedAt: Date(timeIntervalSince1970: row[2].double), endedAt: ended, provenance: provenance, sync: decode(SyncRecord.self, row[4].string).value())
        }
    }
    public func clearHistory(provenance: HistoryProvenance, before: Date? = nil, context: RequestContext) throws {
        let key = try scope(context)
        if let before { try db.execute("DELETE FROM history WHERE scope=? AND provenance=? AND started<?", [.text(key), .text(provenance.rawValue), .real(before.timeIntervalSince1970)]) }
        else { try db.execute("DELETE FROM history WHERE scope=? AND provenance=?", [.text(key), .text(provenance.rawValue)]) }
    }
    public func saveDownload(_ job: DownloadJob, context: RequestContext) throws {
        let key = try scope(context); guard job.account == context.account, job.ranges.count <= 10000, job.references.count <= 10000 else { throw StorageError.invalidInput }
        try validate(job.media.rawValue, job.variant.rawValue)
        try db.transaction {
            try db.execute("INSERT INTO downloads VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(scope,id) DO UPDATE SET media=excluded.media,variant=excluded.variant,state=excluded.state,size=excluded.size,retries=excluded.retries,verification=excluded.verification", [.text(job.id.uuidString), .text(key), .text(job.media.rawValue), .text(job.variant.rawValue), .text(try encode(DownloadStateRecord(job.state))), job.size.map(SQLValue.integer) ?? .null, .integer(Int64(job.retries)), .text(try encode(VerificationRecord(job.verification)))])
            try db.execute("DELETE FROM download_ranges WHERE scope=? AND job=?", [.text(key), .text(job.id.uuidString)])
            try db.execute("DELETE FROM download_refs WHERE scope=? AND job=?", [.text(key), .text(job.id.uuidString)])
            for range in job.ranges { try db.execute("INSERT INTO download_ranges VALUES(?,?,?,?)", [.text(key), .text(job.id.uuidString), .integer(range.lower), .integer(range.upper)]) }
            for ref in job.references { try validate(ref.rawValue); try db.execute("INSERT INTO download_refs VALUES(?,?,?)", [.text(key), .text(job.id.uuidString), .text(ref.rawValue)]) }
        }
    }
    public func download(_ id: UUID, context: RequestContext) throws -> DownloadJob? {
        let key = try scope(context)
        return try db.transaction {
            guard let row = try db.all("SELECT media,variant,state,size,retries,verification FROM downloads WHERE scope=? AND id=?", [.text(key), .text(id.uuidString)]).first else { return nil }
            let ranges = try db.all("SELECT lower,upper FROM download_ranges WHERE scope=? AND job=? ORDER BY lower LIMIT 10001", [.text(key), .text(id.uuidString)]).map { try ByteRange(lower: $0[0].int, upper: $0[1].int) }
            let refs = try db.all("SELECT reference FROM download_refs WHERE scope=? AND job=? LIMIT 10001", [.text(key), .text(id.uuidString)]).map { try sid($0[0].string) }
            guard ranges.count <= 10000, refs.count <= 10000 else { throw StorageError.corrupt }
            let size: Int64? = if case .null = row[3] { nil } else { row[3].int }
            return try DownloadJob(id: id, account: required(context.account), media: sid(row[0].string), variant: sid(row[1].string), ranges: ranges, state: decode(DownloadStateRecord.self, row[2].string).value(), size: size, retries: Int(row[4].int), references: Set(refs), verification: decode(VerificationRecord.self, row[5].string).value())
        }
    }
    public func saveArtwork(_ artwork: ArtworkCacheEntry, context: RequestContext) throws {
        let key = try scope(context); try validate(artwork.sourceKey.rawValue, artwork.contentHash)
        let policy = CacheRecord(artwork.policy)
        if case .noStore = artwork.policy { try db.execute("DELETE FROM artwork WHERE scope=? AND source=?", [.text(key), .text(artwork.sourceKey.rawValue)]); return }
        try db.execute("INSERT INTO artwork VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(scope,source,width,height) DO UPDATE SET policy=excluded.policy,hash=excluded.hash,bytes=excluded.bytes,last_used=excluded.last_used", [.text(key), .text(artwork.sourceKey.rawValue), .integer(Int64(artwork.width)), .integer(Int64(artwork.height)), .text(try encode(policy)), .text(artwork.contentHash), .integer(artwork.bytes), .real(artwork.lastUsedAt.timeIntervalSince1970)])
    }
    public func artwork(_ id: ServiceID, width: Int, height: Int, context: RequestContext) throws -> ArtworkCacheEntry? {
        let key = try scope(context)
        guard let row = try db.all("SELECT policy,hash,bytes,last_used FROM artwork WHERE scope=? AND source=? AND width=? AND height=?", [.text(key), .text(id.rawValue), .integer(Int64(width)), .integer(Int64(height))]).first else { return nil }
        return try ArtworkCacheEntry(sourceKey: id, width: width, height: height, policy: decode(CacheRecord.self, row[0].string).value(), contentHash: row[1].string, bytes: row[2].int, lastUsedAt: Date(timeIntervalSince1970: row[3].double))
    }
    /// Restores a verified backup into a NEW directory. The original and its WAL remain intact.
    /// Migration errors themselves roll back to the previous usable schema automatically.
    public static func recover(backup: URL, into directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw StorageError.conflict }
        let source = try SQLite(backup, readOnly: true)
        try source.integrity()
        let version = try source.scalar("PRAGMA user_version").int
        guard (1...2).contains(version) else { throw StorageError.unsupportedVersion }
        // Verify required structure before copying; complete migration validates subsequent use.
        _ = try source.scalar("SELECT scope FROM identities LIMIT 1")
        let parent = directory.deletingLastPathComponent()
        let free = try FileManager.default.attributesOfFileSystem(forPath: parent.path)[.systemFreeSize] as? Int64 ?? 0
        let size = try FileManager.default.attributesOfItem(atPath: backup.path)[.size] as? Int64 ?? 0
        guard free > max(16 * 1024 * 1024, size * 3) else { throw StorageError.insufficientSpace }
        try SQLite.privateDirectory(directory)
        try source.backup(to: directory.appendingPathComponent("library.sqlite"))
        // No cleanup/wipe on error: partial recovery output remains separately inspectable.
    }
}
struct DownloadStateRecord: Codable {
    let state: String; var error: ErrorRecord? = nil
    init(_ value: DownloadState) {
        switch value { case .queued: state = "queued"; case .running: state = "running"; case .paused: state = "paused"; case .completed: state = "completed"; case .cancelled: state = "cancelled"; case .failed(let e): state = "failed"; error = ErrorRecord(e) }
    }
    func value() throws -> DownloadState {
        switch state { case "queued": .queued; case "running": .running; case "paused": .paused; case "completed": .completed; case "cancelled": .cancelled; case "failed": .failed(try required(error).value()); default: throw StorageError.corrupt }
    }
}
struct VerificationRecord: Codable {
    let state: String; var hash: String? = nil; var date: Date? = nil; var error: ErrorRecord? = nil
    init(_ value: Verification) {
        switch value { case .unknown: state = "unknown"; case .verified(let h, let d): state = "verified"; hash = h; date = d; case .failed(let e): state = "failed"; error = ErrorRecord(e) }
    }
    func value() throws -> Verification {
        switch state { case "unknown": .unknown; case "verified": .verified(hash: try required(hash), at: try required(date)); case "failed": .failed(try required(error).value()); default: throw StorageError.corrupt }
    }
}
struct CacheRecord: Codable {
    let state: String; var date: Date? = nil
    init(_ value: CachePolicy) { switch value { case .noStore: state = "noStore"; case .until(let d): state = "until"; date = d; case .revalidate: state = "revalidate" } }
    func value() throws -> CachePolicy { switch state { case "noStore": .noStore; case "until": .until(try required(date)); case "revalidate": .revalidate; default: throw StorageError.corrupt } }
}
