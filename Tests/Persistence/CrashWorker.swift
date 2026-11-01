// Synthetic subprocess only. Not a product target or a live provider.
import Foundation
import Domain
import Darwin

@main struct CrashWorker {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let operation = CommandLine.arguments[2]
        let boundary = CommandLine.arguments[3]
        let context = try syntheticContext()
        if operation == "migration" {
            let options = MigrationOptions(afterStatement: { version, index in
                if version == 2 && String(index) == boundary { crashAtBoundary() }
            })
            _ = try SQLiteStore(directory: directory, context: context, migration: options)
        } else {
            let store = try SQLiteStore(directory: directory, context: context)
            let entries = try (0..<40).map { try QueueEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", $0))!, media: ServiceID("new-\($0 % 3)"), segment: .context, originalOrder: $0, consumed: $0 < 5) }
            let queue = try QueueSession(account: context.account!, version: 2, entries: entries, currentOccurrence: entries[5].id, position: 123, shuffleSeed: UInt64.max, repeatMode: .all, autoplay: false)
            try await store.writeQueue(queue, continuation: .init(contextID: ServiceID("new-context"), cursor: "new-cursor"), context: context, boundary: { point in
                if point == boundary { crashAtBoundary() }
            })
        }
    }
    /// SIGKILL delivery can lag the syscall's return. Never continue into COMMIT
    /// while waiting for the process to terminate at a pre-commit injection point.
    static func crashAtBoundary() -> Never {
        kill(getpid(), SIGKILL)
        while true { _ = Darwin.pause() }
    }
    static func syntheticContext() throws -> RequestContext {
        RequestContext(account: try AccountContext(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, channelID: ID<ChannelTag>("synthetic-channel"), region: "US"), accountGeneration: 1, requestGeneration: 1)
    }
}
