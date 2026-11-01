// Standalone owned-data subprocess; deliberately killed after FULL-sync commit.
import Foundation
import Domain
import Persistence
import Queue
import Darwin
@main struct QueueCrashWorker {
    static func main() async throws {
        let context = try RequestContext(account: AccountContext(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, channelID: ID("queue-synthetic"), region: "US"), accountGeneration: 1, requestGeneration: 1)
        let store = try SQLiteStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]), context: context)
        try await store.saveAccount(Account(id: context.account!.accountID, serviceIdentity: ServiceID("synthetic"), context: context.account!, displayName: "Synthetic crash", credential: nil), context: context)
        var machine = QueueMachine(account: context.account!, supportsAutoplay: true)
        try machine.replaceContext([ServiceID("a"), ServiceID("a"), ServiceID("b")], source: ServiceID("owned-context"), cursor: "owned-cursor")
        try machine.insert([ServiceID("next"), ServiceID("next")], next: true)
        machine.shuffle(314159)
        _ = try machine.ended(token: machine.playbackToken, repeatSupported: true)
        try machine.checkpoint(position: 91.5)
        try machine.bumpVersion()
        try await SQLiteQueuePersistence(store: store).save(machine.snapshot, context: context)
        kill(getpid(), SIGKILL)
    }
}
