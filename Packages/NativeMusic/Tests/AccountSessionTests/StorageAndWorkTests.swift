import Testing
import Foundation
import Domain
import Persistence
import AccountSession

@Suite("T04 storage work and removal") struct StorageAndWorkTests {
    @Test func switchingRejectsOutOfOrderSearchMutationDownloadAndRestoresPaused() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-music-T04-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
        let store = try SQLiteStore(directory: directory, context: initial)
        let roster = SQLiteAccountDirectory(store: store, context: initial)
        let storage = SQLiteAccountParticipant(store: store, directory: roster)
        let work = ScopedAccountWork(); let vault = try testVault()
        let a = try identity(); let b = try identity("b", uuid: a.id)
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: roster, participants: [work, storage])
        try await connect(lifecycle, a); try await connect(lifecycle, b)
        try await lifecycle.switchIdentity(to: a.context)
        let ac = await lifecycle.snapshot().context
        let entry = try QueueEntry(id: UUID(), media: ServiceID("repeated-song"), segment: .user, originalOrder: 0)
        let queue = try QueueSession(account: a.context, version: 1, entries: [entry], currentOccurrence: entry.id, position: 23, shuffleSeed: 42, repeatMode: .one, autoplay: true)
        try await store.saveQueue(queue, context: ac)
        _ = try await store.store(Preferences(scope: .account(a.context), schemaVersion: 1, values: ["navigation": .text("library")]), context: ac).outcome.get()
        let operationID = UUID()
        let mutation = try PendingMutation(id: operationID, account: a.context, target: ServiceID("playlist"), intent: .playlist(.create(title: "Synthetic pending", privacy: .private)), precondition: .init(providerVersion: nil, snapshotVersion: 1), outcome: .pending(operationID))
        _ = try await store.enqueue(mutation, context: ac).outcome.get()
        let cancellation = CancellationCounter()
        for _ in 0..<3 { _ = try await work.register(context: ac) { cancellation.increment() } }
        // Out-of-order completions for independent search/mutation/download work.
        try await lifecycle.switchIdentity(to: b.context)
        let bc = await lifecycle.snapshot().context
        for request in [bc, ac, ac, bc, ac] {
            if request == ac {
                #expect(await work.accepts(request) == false)
                await #expect(throws: DomainError.staleContext) { try await store.saveQueue(queue, context: request) }
            } else { #expect(await work.accepts(request)) }
        }
        #expect(cancellation.value == 3)
        #expect(try await store.restoredQueue(context: bc) == nil)
        try await lifecycle.switchIdentity(to: a.context)
        let back = await lifecycle.snapshot().context
        let restored = try #require(try await store.restoredQueue(context: back))
        #expect(restored.intent == .pause(.restored)); #expect(restored.queue.position == 23)
        #expect(restored.queue.entries.first?.id == entry.id)
        #expect(try await store.preferences(scope: .account(a.context), context: back).outcome.get().values["navigation"] == .text("library"))
        #expect(try await store.reconcile(mutation.id, context: back).outcome.get().attempts == 0)
        try await lifecycle.expire(context: back)
        let expired = await lifecycle.snapshot().context
        #expect(try await store.restoredQueue(context: expired)?.queue.position == 23)
        #expect(try await store.reconcile(mutation.id, context: expired).outcome.get().attempts == 0)
        try await lifecycle.signOut(a.context)
        await #expect(throws: DomainError.staleContext) { try await store.account(context: expired) }
        try await lifecycle.remove(a.context); try await lifecycle.remove(b.context)
        await store.close(); try await vault.destroyIsolatedTestKeychain()
    }
    @Test func actualFileHooksDeleteOnlyTargetChannel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-music-T04-files-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try identity(); let b = try identity("other", uuid: a.id)
        let files = try PrivateAccountFiles(id: "private-artwork-and-snapshots", root: root)
        let vault = try testVault(); let directory = MemoryDirectory()
        let lifecycle = try AccountLifecycle(directory: .init(), vault: vault, store: directory, participants: [files])
        try await connect(lifecycle, a); try await connect(lifecycle, b)
        for account in [a, b] {
            let partition = root.appendingPathComponent(PrivateAccountFiles.relativePath(account.context))
            try FileManager.default.createDirectory(at: partition, withIntermediateDirectories: true)
            try Data([1, 2]).write(to: partition.appendingPathComponent("snapshot"))
        }
        try await lifecycle.remove(a.context)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(PrivateAccountFiles.relativePath(a.context)).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(PrivateAccountFiles.relativePath(b.context)).path))
        try await lifecycle.remove(b.context); try await vault.destroyIsolatedTestKeychain()
    }
}
final class CancellationCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
