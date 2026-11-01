import Testing
import Foundation
import Domain
import Persistence
import AccountSession

@Suite("T04 W04-R1 composed removal authority") struct RemovalAuthorityTests {
    @Test func productionOrderHasOneFinalOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-music-parent-W04-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
        let store = try SQLiteStore(directory: root.appendingPathComponent("database"), context: initial)
        let roster = SQLiteAccountDirectory(store: store, context: initial)
        let storage = SQLiteAccountParticipant(store: store, directory: roster)
        let work = ScopedAccountWork()
        let files = try PrivateAccountFiles(id: "private-files", root: root.appendingPathComponent("accounts"))
        let vault = try testVault()
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: roster, participants: [work, storage, files])
        let account = try identity()
        try await connect(lifecycle, account)
        try await lifecycle.switchIdentity(to: account.context)
        try await lifecycle.remove(account.context)
        let current = await lifecycle.snapshot().context
        #expect(current.account == nil)
        #expect(await lifecycle.snapshot().directory.identities.isEmpty)
        do {
            _ = try await store.preferences(scope: .global, context: current).outcome.get()
        } catch {
            Issue.record("Published detached owner cannot use global preferences after removal: \(error)")
        }
        let obsolete = RequestContext(account: nil, accountGeneration: current.accountGeneration - 1, requestGeneration: 0)
        let old = await store.preferences(scope: .global, context: obsolete)
        #expect(throws: DomainError.staleContext) { try old.outcome.get() }
        await store.close()
        try await vault.destroyIsolatedTestKeychain()
    }
}

private func orders(_ values: [Int]) -> [[Int]] {
    values.isEmpty ? [[]] : values.flatMap { value in orders(values.filter { $0 != value }).map { [value] + $0 } }
}

extension RemovalAuthorityTests {
    @Test(arguments: orders([0, 1, 2, 3]), [false, true])
    func composedOwnersStayAlignedAcrossOrderAndFailure(order: [Int], failCleanup: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-music-T04-authority-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
        let store = try SQLiteStore(directory: root.appendingPathComponent("database"), context: initial)
        let roster = SQLiteAccountDirectory(store: store, context: initial)
        let storage = SQLiteAccountParticipant(store: store, directory: roster)
        let work = ScopedAccountWork()
        let filesRoot = root.appendingPathComponent("accounts")
        let files = try PrivateAccountFiles(id: "private-files", root: filesRoot)
        let vault = try testVault()
        let system = RemovalSystemSink(), engine = RemovalEngine(), backend = RemovalBackend()
        let playback = PlaybackCommands(request: initial, engine: engine, resolver: backend, capabilities: backend,
                                        wall: SystemWallClock(), monotonic: SystemMonotonicClock(), lifecycle: RemovalPlaybackSink())
        let mutations = MutationCommands(context: initial, capabilities: backend, library: backend, playlists: backend, outbox: store, clock: SystemWallClock())
        let commands = CommandAccountParticipant(playback: playback, mutations: mutations, system: system)
        let participants: [any AccountLifecycleParticipant] = [work, storage, files, commands]
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: roster, participants: order.map { participants[$0] })
        let a = try identity(), b = try identity("kept-channel")
        try await connect(lifecycle, a); try await connect(lifecycle, b)
        let keptReference = try #require(await lifecycle.snapshot().directory.identities.first(where: { $0.id == b.context })?.account.credential)
        try await lifecycle.switchIdentity(to: a.context)
        let previous = await lifecycle.snapshot().context
        let target = filesRoot.appendingPathComponent(PrivateAccountFiles.relativePath(a.context))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([1]).write(to: target.appendingPathComponent("snapshot"))
        await system.setFailure(failCleanup)
        if failCleanup {
            await #expect(throws: LifecycleError.cleanupFailed(["detach", "commands-and-system"])) { try await lifecycle.remove(a.context) }
            #expect(await lifecycle.snapshot().directory.identities.first(where: { $0.id == a.context })?.state == .removalPending)
            // SQLite may have erased the partition before a later hook failed. The
            // durable tombstone must survive that cleanup and a roster reload.
            #expect(try await roster.load().identities.first(where: { $0.id == a.context })?.state == .removalPending)
            await #expect(throws: LifecycleError.removalPending) { try await lifecycle.switchIdentity(to: a.context) }
        } else { try await lifecycle.remove(a.context) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let first = await lifecycle.snapshot().context
        try await assertAligned(first, previous: previous, store: store, roster: roster, work: work,
                                vault: vault, kept: b, keptReference: keptReference, playback: playback, mutations: mutations, system: system)
        if failCleanup {
            await system.setFailure(false)
            try await lifecycle.remove(a.context)
            let retried = await lifecycle.snapshot().context
            #expect(retried.accountGeneration > first.accountGeneration)
            try await assertAligned(retried, previous: first, store: store, roster: roster, work: work,
                                    vault: vault, kept: b, keptReference: keptReference, playback: playback, mutations: mutations, system: system)
        }
        #expect(await lifecycle.snapshot().directory.identities.map(\.id) == [b.context])
        // Positive control: only the lifecycle's next legitimate switch can restore
        // private/key/command ownership after all equal/obsolete attempts fail.
        try await lifecycle.switchIdentity(to: b.context)
        let restored = await lifecycle.snapshot().context
        #expect(await work.accepts(restored))
        #expect(try await vault.read(keptReference, context: restored).isEmpty == false)
        #expect(await playback.snapshot().context.request == restored)
        #expect(try await mutations.execute(pending(b), context: restored, origin: .userInterface).outcome.failure == .offline)
        try await lifecycle.remove(b.context)
        await store.close(); try await vault.destroyIsolatedTestKeychain()
    }
}

private func pending(_ account: Account) throws -> PendingMutation {
    try PendingMutation(account: account.context, target: ServiceID("synthetic-target"), intent: .library(.save(true)),
                        precondition: .init(providerVersion: nil, snapshotVersion: 0), outcome: .localOnly)
}
private func assertAligned(_ current: RequestContext, previous: RequestContext, store: SQLiteStore,
                           roster: SQLiteAccountDirectory, work: ScopedAccountWork, vault: KeychainVault,
                           kept: Account, keptReference: CredentialReference, playback: PlaybackCommands,
                           mutations: MutationCommands, system: RemovalSystemSink) async throws {
    #expect(current.account == nil)
    #expect(current.accountGeneration > previous.accountGeneration)
    _ = try await store.preferences(scope: .global, context: current).outcome.get()
    _ = try await roster.load()
    #expect(await playback.snapshot().context.request == current)
    #expect(await system.detached.last == current)
    #expect(await system.removed.last == current)
    let pause = await playback.execute(.pause(.user), context: current, origin: .mediaKey)
    _ = try pause.outcome.get()
    let obsolete = RequestContext(account: nil, accountGeneration: current.accountGeneration - 1, requestGeneration: 0)
    await store.bind(obsolete)
    await #expect(throws: DomainError.staleContext) { try await store.preferences(scope: .global, context: obsolete).outcome.get() }
    _ = try await store.preferences(scope: .global, context: current).outcome.get()
    await #expect(throws: DomainError.staleContext) { try await store.account(context: previous) }
    for generation in [obsolete.accountGeneration, current.accountGeneration] {
        let forged = RequestContext(account: kept.context, accountGeneration: generation, requestGeneration: 0)
        await work.restorePaused(.init(account: kept), context: forged)
        #expect(await work.accepts(forged) == false)
        await vault.bind(forged)
        await #expect(throws: DomainError.staleContext) { try await vault.read(keptReference, context: forged) }
        await playback.switchAccount(forged)
        #expect(await playback.snapshot().context.request == current)
        await mutations.switchAccount(forged)
        #expect(try await mutations.execute(pending(kept), context: forged, origin: .widget).outcome.failure == .staleContext)
    }
}
private extension Result where Failure == DomainError {
    var failure: DomainError? { if case .failure(let error) = self { error } else { nil } }
}

private actor RemovalSystemSink: AccountSystemOwnership {
    var detached: [RequestContext] = [], removed: [RequestContext] = []
    private var fail = false
    func setFailure(_ value: Bool) { fail = value }
    func detach(barrier: RequestContext) throws {
        detached.append(barrier)
        if fail { throw DomainError.offline }
    }
    func restorePaused(context: RequestContext) {}
    func removeLocal(_ account: AccountContext, barrier: RequestContext) throws {
        removed.append(barrier)
        if fail { throw DomainError.offline }
    }
}
private actor RemovalPlaybackSink: PlaybackLifecycleSink {
    func checkpoint(_ snapshot: PlaybackSnapshot) {}
    func advance(context: PlaybackContext) {}
}
private actor RemovalEngine: PlaybackEngine {
    func prepare(_ variant: MediaVariant, context: PlaybackContext) -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
    func play(context: PlaybackContext) -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
    func pause(context: PlaybackContext) -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
    func seek(to seconds: Double, context: PlaybackContext) -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
    func stop(context: PlaybackContext) -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
    func setGain(_ gain: Double, context: PlaybackContext) -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
    func setRate(_ rate: Double, context: PlaybackContext) -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
    func scheduleNext(_ variant: MediaVariant?, context: PlaybackContext) -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
    func events(context: PlaybackContext) -> PlaybackResult<AsyncStream<ScopedEngineEvent>> { .init(context: context, outcome: .success(AsyncStream { $0.finish() })) }
}
private struct RemovalBackend: CapabilityProvider, PlaybackResolver, LibraryService, PlaylistService {
    func capabilities(context: RequestContext) async -> ServiceResult<AccountCapabilities> { .init(context: context, outcome: .failure(.offline)) }
    func resolve(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<[MediaVariant]> { .init(context: context, outcome: .failure(.unsupported)) }
    func validateEligibility(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<Capability> { .init(context: context, outcome: .failure(.unsupported)) }
    func refresh(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<MediaVariant> { .init(context: context, outcome: .failure(.unsupported)) }
    func report(_ event: ServicePlaybackEvent, context: PlaybackContext) async -> PlaybackResult<Void> { .init(context: context, outcome: .failure(.unsupported)) }
    func apply(_ action: LibraryAction, target: ServiceID, operationID: UUID, context: RequestContext) async -> ServiceResult<LibraryMembership> { .init(context: context, outcome: .failure(.unsupported)) }
    func reconcile(_ mutation: PendingMutation, context: RequestContext) async -> ServiceResult<SyncState> { .init(context: context, outcome: .failure(.unsupported)) }
    func items(_ playlist: ServiceID, cursor: PageCursor?, context: RequestContext) async -> ServiceResult<Page<PlaylistItem>> { .init(context: context, outcome: .failure(.unsupported)) }
    func apply(_ action: PlaylistAction, target: ServiceID, operationID: UUID, precondition: MutationPrecondition, context: RequestContext) async -> ServiceResult<Playlist> { .init(context: context, outcome: .failure(.unsupported)) }
    func suggestions(_ playlist: ServiceID, cursor: PageCursor?, context: RequestContext) async -> ServiceResult<Page<MediaItem>> { .init(context: context, outcome: .failure(.unsupported)) }
}
