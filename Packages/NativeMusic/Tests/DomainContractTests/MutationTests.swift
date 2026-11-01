import Domain
import Foundation
import Testing

actor TestMutations: LibraryService, PlaylistService, MutationOutbox {
    var operations: [UUID: PendingMutation] = [:]
    var claims: Set<UUID> = []
    var submissions = 0; var reconciliations = 0; var commits = 0
    var failure: DomainError?
    var holdWrite = false
    var continuation: CheckedContinuation<Void, Never>?
    func hold() { holdWrite = true }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    init(failure: DomainError? = nil) { self.failure = failure }
    func counts() -> (Int, Int, Int) { (submissions, reconciliations, commits) }
    func apply(_ action: LibraryAction, target: ServiceID, operationID: UUID, context: RequestContext) async -> ServiceResult<LibraryMembership> {
        submissions += 1
        if holdWrite { await withCheckedContinuation { continuation = $0 } }
        if let failure { return .init(context: context, outcome: .failure(failure)) }
        return .init(context: context, outcome: .success(LibraryMembership(account: context.account!, entity: target, serviceStatus: true, sync: .confirmed, sortDate: nil, sortKey: "")))
    }
    func reconcile(_ mutation: PendingMutation, context: RequestContext) -> ServiceResult<SyncState> { .init(context: context, outcome: .success(.needsReconciliation)) }
    func apply(_ action: PlaylistAction, target: ServiceID, operationID: UUID, precondition: MutationPrecondition, context: RequestContext) -> ServiceResult<Playlist> {
        submissions += 1; return .init(context: context, outcome: .failure(failure ?? .unsupported))
    }
    func items(_ playlist: ServiceID, cursor: PageCursor?, context: RequestContext) -> ServiceResult<Page<PlaylistItem>> { .init(context: context, outcome: .success(Page(items: []))) }
    func suggestions(_ playlist: ServiceID, cursor: PageCursor?, context: RequestContext) -> ServiceResult<Page<MediaItem>> { .init(context: context, outcome: .success(Page(items: []))) }
    func enqueue(_ mutation: PendingMutation, context: RequestContext) -> ServiceResult<PendingMutation> {
        if operations[mutation.id] == nil { operations[mutation.id] = mutation }
        return .init(context: context, outcome: .success(operations[mutation.id]!))
    }
    func beginAttempt(_ id: UUID, context: RequestContext) -> ServiceResult<PendingMutation> {
        guard claims.insert(id).inserted else { return .init(context: context, outcome: .failure(.reconciliationRequired)) }
        return status(id, context: context)
    }
    func update(_ id: UUID, _ outcome: SyncState, context: RequestContext) -> ServiceResult<PendingMutation> {
        guard let old = operations[id] else { return .init(context: context, outcome: .failure(.unavailableContent)) }
        let mutation = try! PendingMutation(id: id, account: old.account, target: old.target, intent: old.intent, precondition: old.precondition, attempts: 1, outcome: outcome)
        operations[id] = mutation; return .init(context: context, outcome: .success(mutation))
    }
    func reconcile(_ id: UUID, context: RequestContext) -> ServiceResult<PendingMutation> { reconciliations += 1; return status(id, context: context) }
    func commit(_ id: UUID, context: RequestContext) -> ServiceResult<PendingMutation> { commits += 1; return update(id, .confirmed, context: context) }
    func fail(_ id: UUID, error: DomainError, ambiguous: Bool, context: RequestContext) -> ServiceResult<PendingMutation> { update(id, ambiguous ? .needsReconciliation : .failed(error), context: context) }
    func cancel(_ id: UUID, context: RequestContext) -> ServiceResult<Void> { operations[id] = nil; return .init(context: context, outcome: .success(())) }
    func status(_ id: UUID, context: RequestContext) -> ServiceResult<PendingMutation> { .init(context: context, outcome: operations[id].map { .success($0) } ?? .failure(.unavailableContent)) }
}
@Suite("T02.4 Shared mutation commands") struct MutationTests {
    @Test func ambiguousWriteRequiresReconciliationAndNeverDuplicates() async throws {
        let a = try account(); let context = request(a); let backend = TestMutations(failure: .transientTransport)
        let commands = MutationCommands(context: context, capabilities: TestProvider(account: a), library: backend, playlists: backend, outbox: backend, clock: FixedWall(date: testWall))
        let mutation = try PendingMutation(account: a, target: sid(), intent: .playlist(.add([sid(), sid()])), precondition: MutationPrecondition(providerVersion: "synthetic-v1", snapshotVersion: 1), outcome: .localOnly)
        let first = await commands.execute(mutation, context: context, origin: .userInterface)
        #expect(try first.outcome.get().outcome == .needsReconciliation)
        _ = await commands.execute(mutation, context: context, origin: .appleScript)
        let counts = await backend.counts()
        #expect(counts.0 == 1 && counts.1 == 1 && counts.2 == 0)
    }
    @Test func delayedWriteAfterAccountSwitchCannotCommitActiveState() async throws {
        let a = try account(); let context = request(a); let backend = TestMutations(); await backend.hold()
        let commands = MutationCommands(context: context, capabilities: TestProvider(account: a), library: backend, playlists: backend, outbox: backend, clock: FixedWall(date: testWall))
        let mutation = try PendingMutation(account: a, target: sid(), intent: .library(.save(true)), precondition: MutationPrecondition(providerVersion: nil, snapshotVersion: 0), outcome: .localOnly)
        let write = Task { await commands.execute(mutation, context: context, origin: .siri) }
        for _ in 0..<10_000 { if await backend.waiting() { break }; await Task.yield() }
        #expect(await backend.waiting())
        await commands.switchAccount(request(try account(), generation: 2))
        await backend.release()
        let result = await write.value
        #expect(throws: DomainError.staleContext) { try result.outcome.get() }
        #expect(await backend.counts().2 == 0)
    }
    @Test func confirmedWriteAndAllEntrypointsPreservePermissionAndAccountChecks() async throws {
        let a = try account(); let context = request(a); let backend = TestMutations()
        let commands = MutationCommands(context: context, capabilities: TestProvider(account: a), library: backend, playlists: backend, outbox: backend, clock: FixedWall(date: testWall))
        let mutation = try PendingMutation(account: a, target: sid(), intent: .library(.save(true)), precondition: MutationPrecondition(providerVersion: nil, snapshotVersion: 1), outcome: .localOnly)
        let first = await commands.execute(mutation, context: context, origin: .menu)
        #expect(try first.outcome.get().outcome == .confirmed)
        _ = await commands.execute(mutation, context: context, origin: .widget)
        #expect(await backend.counts().0 == 1)
        let unknown = MutationCommands(context: context, capabilities: TestProvider(account: a, state: .unknown), library: backend, playlists: backend, outbox: backend, clock: FixedWall(date: testWall))
        for origin in CommandOrigin.allCases {
            let result = await unknown.execute(mutation, context: context, origin: origin)
            #expect(throws: DomainError.capabilityUnknown) { try result.outcome.get() }
        }
        await commands.switchAccount(request(try account(), generation: 2))
        let stale = await commands.execute(mutation, context: context, origin: .shortcut)
        #expect(throws: DomainError.staleContext) { try stale.outcome.get() }
        #expect(await backend.counts().0 == 1)
    }
}
