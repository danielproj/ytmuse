import Foundation

struct Migration { let version: Int; let statements: [String] }
let migrations: [Migration] = [
    Migration(version: 1, statements: [
        "CREATE TABLE identities(scope TEXT PRIMARY KEY, account TEXT NOT NULL, channel TEXT NOT NULL, region TEXT NOT NULL, service_id TEXT NOT NULL, label TEXT NOT NULL, credential_ref TEXT, UNIQUE(account,channel,region))",
        "CREATE TABLE entities(row_id INTEGER PRIMARY KEY, scope TEXT NOT NULL REFERENCES identities(scope) ON DELETE CASCADE, id TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, detail TEXT NOT NULL, UNIQUE(scope,id))",
        "CREATE INDEX entity_page ON entities(scope,id)",
        "CREATE TABLE collections(scope TEXT NOT NULL REFERENCES identities(scope) ON DELETE CASCADE, id TEXT NOT NULL, metadata TEXT NOT NULL, PRIMARY KEY(scope,id))",
        "CREATE TABLE collection_entries(scope TEXT NOT NULL, collection TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=0), occurrence TEXT NOT NULL, media TEXT NOT NULL, PRIMARY KEY(scope,collection,occurrence), UNIQUE(scope,collection,ordinal), FOREIGN KEY(scope,collection) REFERENCES collections(scope,id) ON DELETE CASCADE)",
        "CREATE TABLE queues(scope TEXT PRIMARY KEY REFERENCES identities(scope) ON DELETE CASCADE, version TEXT NOT NULL, current TEXT, position REAL NOT NULL CHECK(position>=0), seed TEXT, repeat_mode TEXT NOT NULL, autoplay INTEGER NOT NULL, context_id TEXT, cursor TEXT)",
        "CREATE TABLE queue_entries(scope TEXT NOT NULL REFERENCES queues(scope) ON DELETE CASCADE, ordinal INTEGER NOT NULL, occurrence TEXT NOT NULL, media TEXT NOT NULL, segment TEXT NOT NULL, original_order INTEGER NOT NULL, consumed INTEGER NOT NULL, PRIMARY KEY(scope,occurrence), UNIQUE(scope,ordinal))",
        "CREATE TABLE preferences(scope TEXT PRIMARY KEY, version INTEGER NOT NULL, payload TEXT NOT NULL)",
        "CREATE TABLE outbox(id TEXT PRIMARY KEY, scope TEXT NOT NULL REFERENCES identities(scope) ON DELETE CASCADE, target TEXT NOT NULL, intent TEXT NOT NULL, provider_version TEXT, snapshot TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL, error TEXT)",
        "CREATE INDEX outbox_scope_state ON outbox(scope,state,id)",
        "CREATE TABLE memberships(scope TEXT NOT NULL REFERENCES identities(scope) ON DELETE CASCADE, entity TEXT NOT NULL, status INTEGER, sync TEXT NOT NULL, sort_date REAL, sort_key TEXT NOT NULL, PRIMARY KEY(scope,entity))",
        "CREATE TABLE history(id TEXT NOT NULL, scope TEXT NOT NULL REFERENCES identities(scope) ON DELETE CASCADE, media TEXT NOT NULL, started REAL NOT NULL, ended REAL, provenance TEXT NOT NULL, sync TEXT NOT NULL, PRIMARY KEY(scope,id))",
        "CREATE INDEX history_recent ON history(scope,provenance,started DESC,id)",
        "CREATE TABLE downloads(id TEXT NOT NULL, scope TEXT NOT NULL REFERENCES identities(scope) ON DELETE CASCADE, media TEXT NOT NULL, variant TEXT NOT NULL, state TEXT NOT NULL, size INTEGER, retries INTEGER NOT NULL, verification TEXT NOT NULL, PRIMARY KEY(scope,id), UNIQUE(scope,media,variant))",
        "CREATE TABLE download_ranges(scope TEXT NOT NULL, job TEXT NOT NULL, lower INTEGER NOT NULL, upper INTEGER NOT NULL, PRIMARY KEY(scope,job,lower), FOREIGN KEY(scope,job) REFERENCES downloads(scope,id) ON DELETE CASCADE)",
        "CREATE TABLE download_refs(scope TEXT NOT NULL, job TEXT NOT NULL, reference TEXT NOT NULL, PRIMARY KEY(scope,job,reference), FOREIGN KEY(scope,job) REFERENCES downloads(scope,id) ON DELETE CASCADE)",
        "CREATE TABLE artwork(scope TEXT NOT NULL REFERENCES identities(scope) ON DELETE CASCADE, source TEXT NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL, policy TEXT NOT NULL, hash TEXT NOT NULL, bytes INTEGER NOT NULL, last_used REAL NOT NULL, PRIMARY KEY(scope,source,width,height))"
    ]),
    Migration(version: 2, statements: [
        "CREATE VIRTUAL TABLE entity_fts USING fts5(title, content='entities', content_rowid='row_id', tokenize='unicode61 remove_diacritics 2')",
        "CREATE TRIGGER entity_ai AFTER INSERT ON entities BEGIN INSERT INTO entity_fts(rowid,title) VALUES(new.row_id,new.title); END",
        "CREATE TRIGGER entity_ad AFTER DELETE ON entities BEGIN INSERT INTO entity_fts(entity_fts,rowid,title) VALUES('delete',old.row_id,old.title); END",
        "CREATE TRIGGER entity_au AFTER UPDATE ON entities BEGIN INSERT INTO entity_fts(entity_fts,rowid,title) VALUES('delete',old.row_id,old.title); INSERT INTO entity_fts(rowid,title) VALUES(new.row_id,new.title); END",
        "INSERT INTO entity_fts(entity_fts) VALUES('rebuild')"
    ])
]

/// Fault seam is internal; production migrations always run the checked-in statements.
struct MigrationOptions: Sendable {
    var target = 2
    var availableBytes: Int64? = nil
    var afterStatement: (@Sendable (Int, Int) throws -> Void)? = nil
}
extension SQLite {
    func migrate(_ options: MigrationOptions = .init()) throws {
        let current = Int(try scalar("PRAGMA user_version").int)
        guard current <= options.target, options.target <= 2 else { throw StorageError.unsupportedVersion }
        guard current < options.target else { try integrity(); return }
        try checkFreeSpace(availableBytes: options.availableBytes)
        // Serialize schema upgrade/open across processes. Normal SQLite transactions serialize writes.
        // The caller holds the migration lock before opening this connection.
        if current > 0 {
            let destination = url.deletingLastPathComponent().appendingPathComponent("backup-v\(current)-\(UUID().uuidString).sqlite")
            try backup(to: destination)
        }
        try transaction {
            for migration in migrations where migration.version > current && migration.version <= options.target {
                for (index, statement) in migration.statements.enumerated() {
                    try execute(statement)
                    try options.afterStatement?(migration.version, index)
                }
                try execute("PRAGMA user_version=\(migration.version)")
            }
            try integrity()
        }
    }
}
