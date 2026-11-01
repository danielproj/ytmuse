import Foundation
import Domain

/// Public local profile metadata; secret values are never accepted here. Lifecycle
/// state occupies one reserved preference per identity, so there is no roster blob
/// size or account-count limit. Existing normalized identity rows remain canonical.
public struct StoredLocalIdentity: Sendable {
    public let account: Account
    public let state: String
    public let isDefault: Bool
    public init(account: Account, state: String, isDefault: Bool) {
        self.account = account; self.state = state; self.isDefault = isDefault
    }
}
private struct IdentitySettings: Codable { let state: String; let isDefault: Bool }
extension SQLiteStore {
    public func localIdentities(context: RequestContext) throws -> [StoredLocalIdentity] {
        _ = try preferenceKey(.global, context: context)
        return try db.all("SELECT i.account,i.channel,i.region,i.service_id,i.label,i.credential_ref,p.payload FROM identities i LEFT JOIN preferences p ON p.scope='identity:'||i.scope ORDER BY i.scope").map { row in
            let context = try AccountContext(accountID: uuid(row[0].string), channelID: ID<ChannelTag>(row[1].string), region: row[2].string)
            let account = try Account(id: context.accountID, serviceIdentity: sid(row[3].string), context: context, displayName: row[4].string, credential: row[5].optional.map(CredentialReference.init))
            let settings = try row[6].optional.map { try decode(IdentitySettings.self, $0) }
            return StoredLocalIdentity(account: account, state: settings?.state ?? "signedOut", isDefault: settings?.isDefault ?? false)
        }
    }
    public func saveLocalIdentities(_ records: [StoredLocalIdentity], context: RequestContext) throws {
        _ = try preferenceKey(.global, context: context)
        guard Set(records.map { $0.account.context }).count == records.count,
              records.filter(\.isDefault).count <= 1 else { throw StorageError.invalidInput }
        // Validate each row independently; the directory has no count/aggregate cap.
        for record in records {
            try validate(record.account.serviceIdentity.rawValue, record.account.context.channelID.rawValue, record.account.displayName, record.state)
            if let reference = record.account.credential { guard UUID(uuidString: reference.rawValue) != nil else { throw StorageError.invalidInput } }
        }
        try writeLocalIdentities(records, to: db)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("backup-v") && $0.pathExtension == "sqlite" }
        for backup in backups {
            let snapshot = try SQLite(backup); try snapshot.integrity()
            try snapshot.execute("PRAGMA secure_delete=ON")
            try writeLocalIdentities(records, to: snapshot)
            try snapshot.execute("VACUUM"); snapshot.close()
        }
    }
    private func writeLocalIdentities(_ records: [StoredLocalIdentity], to connection: SQLite) throws {
        try connection.transaction {
            for record in records {
                let account = record.account, key = Self.key(account.context)
                try connection.execute("INSERT INTO identities VALUES(?,?,?,?,?,?,?) ON CONFLICT(scope) DO UPDATE SET service_id=excluded.service_id,label=excluded.label,credential_ref=excluded.credential_ref", [.text(key), .text(account.id.uuidString), .text(account.context.channelID.rawValue), .text(account.context.region), .text(account.serviceIdentity.rawValue), .text(account.displayName), account.credential.map { .text($0.rawValue) } ?? .null])
                try connection.execute("INSERT INTO preferences VALUES(?,1,?) ON CONFLICT(scope) DO UPDATE SET payload=excluded.payload", [.text("identity:" + key), .text(try encode(IdentitySettings(state: record.state, isDefault: record.isDefault)))])
            }
        }
    }
}
