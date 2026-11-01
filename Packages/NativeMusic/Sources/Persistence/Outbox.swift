import Foundation
import Domain

extension SQLiteStore {
    public func enqueue(_ mutation: PendingMutation, context: RequestContext) -> ServiceResult<PendingMutation> {
        result(context) {
            let key = try scope(context)
            guard mutation.account == context.account, mutation.attempts == 0, mutation.outcome == .pending(mutation.id) else { throw DomainError.invalidInput(.invalidTransition) }
            try validate(mutation.target.rawValue, mutation.precondition.providerVersion ?? "")
            let intent = try encode(IntentRecord(mutation.intent))
            return try db.transaction {
                if let existing = try db.all("SELECT scope,target,intent,provider_version,snapshot FROM outbox WHERE id=?", [.text(mutation.id.uuidString)]).first {
                    guard existing[0].string == key, existing[1].string == mutation.target.rawValue, existing[2].string == intent, existing[3].optional == mutation.precondition.providerVersion, existing[4].string == String(mutation.precondition.snapshotVersion) else { throw DomainError.invalidInput(.contextMismatch) }
                    return try readMutation(mutation.id, context: context)
                }
                try db.execute("INSERT INTO outbox VALUES(?,?,?,?,?,?,0,'pending',NULL)", [.text(mutation.id.uuidString), .text(key), .text(mutation.target.rawValue), .text(intent), mutation.precondition.providerVersion.map(SQLValue.text) ?? .null, .text(String(mutation.precondition.snapshotVersion))])
                return try readMutation(mutation.id, context: context)
            }
        }
    }
    public func beginAttempt(_ id: UUID, context: RequestContext) -> ServiceResult<PendingMutation> {
        result(context) {
            let key = try scope(context)
            return try db.transaction {
                // The claim is durable BEFORE transport can begin, even with multiple connections.
                let changed = try db.execute("UPDATE outbox SET attempts=1,state='reconcile' WHERE id=? AND scope=? AND attempts=0 AND state='pending'", [.text(id.uuidString), .text(key)])
                guard changed == 1 else { throw DomainError.reconciliationRequired }
                return try readMutation(id, context: context)
            }
        }
    }
    func readMutation(_ id: UUID, context: RequestContext) throws -> PendingMutation {
        let key = try scope(context)
        guard let row = try db.all("SELECT target,intent,provider_version,snapshot,attempts,state,error FROM outbox WHERE id=? AND scope=?", [.text(id.uuidString), .text(key)]).first else { throw DomainError.unavailableContent }
        let state: SyncState
        switch row[5].string {
        case "pending": state = .pending(id)
        case "confirmed": state = .confirmed
        case "failed": state = .failed(try decode(ErrorRecord.self, row[6].string).value())
        case "cancelled": state = .failed(.invalidInput(.invalidTransition))
        case "reconcile": state = .needsReconciliation
        default: throw StorageError.corrupt
        }
        return try PendingMutation(id: id, account: required(context.account), target: sid(row[0].string), intent: decode(IntentRecord.self, row[1].string).value(), precondition: MutationPrecondition(providerVersion: row[2].optional, snapshotVersion: unsigned(row[3].string)), attempts: Int(row[4].int), outcome: state)
    }
    public func status(_ id: UUID, context: RequestContext) -> ServiceResult<PendingMutation> { result(context) { try readMutation(id, context: context) } }
    public func reconcile(_ id: UUID, context: RequestContext) -> ServiceResult<PendingMutation> {
        // Storage records the need for a provider read; it cannot assert remote success.
        result(context) {
            let key = try scope(context)
            try db.execute("UPDATE outbox SET state='reconcile' WHERE id=? AND scope=? AND attempts>0 AND state IN ('failed','reconcile')", [.text(id.uuidString), .text(key)])
            return try readMutation(id, context: context)
        }
    }
    public func commit(_ id: UUID, context: RequestContext) -> ServiceResult<PendingMutation> {
        result(context) {
            let key = try scope(context)
            return try db.transaction {
                let existing = try readMutation(id, context: context)
                guard existing.attempts > 0, existing.outcome == .needsReconciliation || existing.outcome == .confirmed else { throw DomainError.invalidInput(.invalidTransition) }
                try db.execute("UPDATE outbox SET state='confirmed',error=NULL WHERE id=? AND scope=?", [.text(id.uuidString), .text(key)])
                return try readMutation(id, context: context)
            }
        }
    }
    public func fail(_ id: UUID, error: DomainError, ambiguous: Bool, context: RequestContext) -> ServiceResult<PendingMutation> {
        result(context) {
            let key = try scope(context)
            let changed = try db.execute("UPDATE outbox SET state=?,error=? WHERE id=? AND scope=? AND state IN ('pending','reconcile','failed')", [.text(ambiguous ? "reconcile" : "failed"), .text(try encode(ErrorRecord(error))), .text(id.uuidString), .text(key)])
            guard changed == 1 else { throw DomainError.invalidInput(.invalidTransition) }
            return try readMutation(id, context: context)
        }
    }
    public func cancel(_ id: UUID, context: RequestContext) -> ServiceResult<Void> {
        result(context) {
            let key = try scope(context)
            // Retain a tombstone: deleting would let enqueue reuse the operation UUID.
            let changed = try db.execute("UPDATE outbox SET state='cancelled' WHERE id=? AND scope=? AND attempts=0 AND state='pending'", [.text(id.uuidString), .text(key)])
            guard changed == 1 else { throw DomainError.reconciliationRequired }
        }
    }
    public func pendingMutations(limit: Int = 100, context: RequestContext) throws -> [PendingMutation] {
        try pageLimit(limit); let key = try scope(context)
        return try db.all("SELECT id FROM outbox WHERE scope=? AND state IN ('pending','reconcile','failed') ORDER BY id LIMIT ?", [.text(key), .integer(Int64(limit))]).map { try readMutation(uuid($0[0].string), context: context) }
    }
}
