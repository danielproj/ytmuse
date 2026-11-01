import Foundation
import Testing
import Domain
import Persistence
import Features
@testable import Queue

func queueSQLite(_ prefix: String, context: RequestContext) async throws -> (SQLiteStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
    let store = try SQLiteStore(directory: directory, context: context)
    try await store.saveAccount(Account(id: context.account!.accountID, serviceIdentity: ServiceID("synthetic"), context: context.account!, displayName: "Synthetic queue rework", credential: nil), context: context)
    return (store, directory)
}

@Suite struct QueueReworkPersistenceTests {
    /// Each variant actually commits >=1000 recommendations AND >=1000 ads, then changes
    /// context and restarts. The long cursor is synthetic, 4096 bytes, not source evidence.
    @Test(arguments: [0, 4096]) func F1LongAutoplayAndAdsStayBounded(cursorLength: Int) async throws {
        let context = try request(); let (store, directory) = try await queueSQLite("queue-long-", context: context)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SQLiteQueuePersistence(store: store)
        let owner = try QueueCommands(machine: make(["seed"]), context: context, persistence: persistence, playback: RecordingPlayback(), repeatSupported: true)
        _ = try await owner.execute(.resume, context: context, origin: .menu)
        let source = RecommendationContext(source: "synthetic-radio", cursor: cursorLength == 0 ? nil : String(repeating: "c", count: cursorLength))
        var sizes: [Int] = []; var consumedAdIDs = Set<UUID>()
        for i in 0..<1000 {
            _ = try await owner.execute(.recommendations(ids(["recommendation-\(i)"]), source), context: context, origin: .menu)
            let ad = try QueueEntry(media: ServiceID("ad-\(i)"), segment: .advertisement, originalOrder: i)
            consumedAdIDs.insert(ad.id)
            _ = try await owner.execute(.serviceEntry(ad, immutable: true), context: context, origin: .menu)
            // First pass consumes seed, recommendation and ad; later passes start the
            // late recommendation automatically and consume it and the ad.
            for _ in 0..<(i == 0 ? 3 : 2) {
                _ = try await owner.execute(.ended(try await owner.snapshot().playbackToken), context: context, origin: .menu)
            }
            let snapshot = try await owner.snapshot()
            #expect(snapshot.session.entries.count <= QueueMachine.historyLimit + 1)
            #expect(snapshot.metadata.immutable.isEmpty && snapshot.metadata.recommendationSources.isEmpty)
            #expect(snapshot.session.entries.filter { $0.segment == .advertisement }.allSatisfy { $0.consumed })
            if i % 100 == 99 {
                let stored = try #require(await store.restoredQueue(context: context))
                sizes.append(stored.continuation.cursor!.utf8.count)
                let reread = try #require(await persistence.load(context: context))
                #expect(reread.session.currentOccurrence == snapshot.session.currentOccurrence)
            }
        }
        // Metadata has no per-play UUID/cursor growth after the bounded tail fills.
        #expect(sizes.count == 10 && sizes.max()! < 2048 && sizes.max()! - sizes.min()! < 128)
        _ = try await owner.execute(.replace(ids(["fresh-context"]), source: ServiceID("fresh"), cursor: "distinct-source-page", decision: .replace, remember: false), context: context, origin: .menu)
        await store.close()
        let reopened = try SQLiteStore(directory: directory, context: context)
        let resumedPlayer = RecordingPlayback()
        let restored = try QueueCommands(machine: make([]), context: context, persistence: SQLiteQueuePersistence(store: reopened), playback: resumedPlayer, repeatSupported: true)
        try await restored.restore(context: context)
        let recovered = try await restored.snapshot()
        #expect(recovered.intent == .pause(.restored) && recovered.metadata.cursor == "distinct-source-page")
        #expect(recovered.session.entries.count <= QueueMachine.historyLimit + 1)
        #expect(recovered.metadata.immutable.isEmpty && recovered.metadata.recommendationSources.isEmpty)
        #expect(await resumedPlayer.selections.isEmpty)
        _ = try await restored.execute(.recommendations(ids(["after-restart"]), source), context: context, origin: .menu)
        _ = try await restored.execute(.repeatMode(.all), context: context, origin: .menu)
        _ = try await restored.execute(.resume, context: context, origin: .menu)
        for _ in 0..<4 { _ = try await restored.execute(.ended(try await restored.snapshot().playbackToken), context: context, origin: .menu) }
        let after = try await restored.snapshot()
        #expect(after.session.entries.filter { consumedAdIDs.contains($0.id) }.allSatisfy { $0.consumed })
        #expect(!consumedAdIDs.contains(after.session.currentOccurrence ?? UUID()))
        print("W05 F1 cursor=\(cursorLength) recommendations=1000 ads=1000 envelopeSamples=\(sizes) retained=\(after.session.entries.count)")
        await reopened.close()
    }
    @Test func F6ContiguousCursorAndSourcePageAreDistinct() async throws {
        var q = try make((0..<150).map { "t\($0)" }); q.shuffle(42)
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        #expect(q.entries.filter { $0.consumed }.map(\.originalOrder) == [0, 135])
        #expect(q.metadata.contextCursor == 1)
        let context = try request(); let (store, directory) = try await queueSQLite("queue-cursor-", context: context)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await SQLiteQueuePersistence(store: store).save(q.snapshot, context: context)
        let recovered = try #require(await SQLiteQueuePersistence(store: store).load(context: context))
        #expect(recovered.metadata.contextCursor == 1)
        var restored = try QueueMachine(restoring: recovered, supportsAutoplay: true)
        restored.shuffle(nil)
        #expect(try restored.snapshot.upcoming.contains { $0.originalOrder == 1 })
        #expect(try restored.snapshot.upcoming.contains { $0.originalOrder == 134 })
        #expect(try !restored.snapshot.upcoming.contains { $0.originalOrder == 135 })
        await store.close()
    }
    @Test func F8RealPreferenceReloadScopesAndDefaultContinuationWriter() async throws {
        let base = try request().account!
        let accounts = try [
            base,
            AccountContext(accountID: base.accountID, channelID: ID("different-channel"), region: "US"),
            AccountContext(accountID: base.accountID, channelID: base.channelID, region: "GB"),
            AccountContext(accountID: UUID(), channelID: base.channelID, region: "US")
        ]
        let expected: [ReplacementPreference] = [.keep, .replace, .ask, .replace]
        let context = try request(); let (store, directory) = try await queueSQLite("queue-pref-", context: context)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (i, account) in accounts.enumerated() {
            let scope = RequestContext(account: account, accountGeneration: UInt64(i + 2), requestGeneration: 1)
            await store.bind(scope)
            try await store.saveAccount(Account(id: account.accountID, serviceIdentity: ServiceID("synthetic"), context: account, displayName: "Synthetic scope", credential: nil), context: scope)
            let persistence = SQLiteQueuePersistence(store: store)
            #expect(try await persistence.replacementPreference(context: scope) == .ask)
            var q = QueueMachine(account: account, supportsAutoplay: true)
            try q.replaceContext(ids(["first", "second"]), source: ServiceID("source"))
            try q.insert(ids(["pending"]), next: true)
            let owner = try QueueCommands(machine: q, context: scope, persistence: persistence, playback: RecordingPlayback(), repeatSupported: true)
            if i == 0 {
                _ = try await owner.execute(.replace(ids(["first", "second"]), source: ServiceID("remembered"), cursor: nil, decision: .keep, remember: true), context: scope, origin: .menu)
            } else { _ = try await owner.execute(.preference(expected[i]), context: scope, origin: .menu) }
            // A regular checkpoint writer with NO queue-owned envelope cannot erase settings.
            let checkpoint = try await owner.snapshot()
            try await store.saveQueue(checkpoint.session, context: scope)
        }
        await store.close()
        let reopened = try SQLiteStore(directory: directory)
        for (i, account) in accounts.enumerated() {
            let scope = RequestContext(account: account, accountGeneration: UInt64(i + 100), requestGeneration: 1)
            await reopened.bind(scope)
            let persistence = SQLiteQueuePersistence(store: reopened)
            let owner = try QueueCommands(machine: QueueMachine(account: account, supportsAutoplay: true), context: scope, persistence: persistence, playback: RecordingPlayback(), repeatSupported: true)
            try await owner.restore(context: scope)
            #expect(try await owner.snapshot().metadata.preference == expected[i])
            if expected[i] == .ask {
                await #expect(throws: QueueError.confirmationRequired) { try await owner.execute(.replace(ids(["new"]), source: ServiceID("new-source"), cursor: nil, decision: nil, remember: false), context: scope, origin: .menu) }
            } else {
                let changed = try await owner.execute(.replace(ids(["new"]), source: ServiceID("new-source"), cursor: nil, decision: nil, remember: false), context: scope, origin: .menu)
                #expect(changed.session.entries.contains { $0.media.rawValue == "pending" } == (expected[i] == .keep))
            }
        }
        await reopened.close()
    }
    @Test func F8ShufflePlayStartsShuffledAndPersistsMode() async throws {
        let context = try request(); let (store, directory) = try await queueSQLite("queue-shuffle-play-", context: context)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try QueueCommands(machine: make(), context: context, persistence: SQLiteQueuePersistence(store: store), playback: RecordingPlayback(), repeatSupported: true)
        let media = try ids((0..<20).map { "n\($0)" })
        let shuffled = try await owner.execute(.startContext(media, source: ServiceID("new"), cursor: "source-page", decision: .replace, remember: false, start: .shuffled(seed: 42)), context: context, origin: .menu)
        #expect(shuffled.session.shuffleSeed == 42 && shuffled.current?.media.rawValue != "n0")
        #expect(shuffled.metadata.contextCursor == 0 && shuffled.metadata.cursor == "source-page")
        let reloaded = try QueueCommands(machine: make([]), context: context, persistence: SQLiteQueuePersistence(store: store), playback: RecordingPlayback(), repeatSupported: true)
        try await reloaded.restore(context: context)
        #expect(try await reloaded.snapshot().current?.media == shuffled.current?.media)
        #expect(try await reloaded.snapshot().session.shuffleSeed == 42)
        let preserved = try await reloaded.execute(.replace(media, source: ServiceID("next"), cursor: nil, decision: .replace, remember: false), context: context, origin: .menu)
        #expect(preserved.session.shuffleSeed == 42 && preserved.current?.media == shuffled.current?.media)
        let ordered = try await reloaded.execute(.startContext(media, source: ServiceID("ordered"), cursor: nil, decision: .replace, remember: false, start: .ordered), context: context, origin: .menu)
        #expect(ordered.session.shuffleSeed == nil && ordered.current?.media.rawValue == "n0")
        await store.close()
    }
}

actor FailingQueuePlayback: QueuePlaybackBoundary {
    func select(_ entry: QueueEntry, token: UUID, context: RequestContext, origin: CommandOrigin) throws { throw DomainError.offline }
    func pause(context: RequestContext, origin: CommandOrigin) {}
}
@Suite struct QueueReworkIntentTests {
    @Test @MainActor func F7CommittedFailureRefreshesFeatureCurrentAndError() async throws {
        let context = try request()
        var q = try make(["a", "b"]); try q.resume()
        let owner = try QueueCommands(machine: q, context: context, persistence: MemoryPersistence(), playback: FailingQueuePlayback(), repeatSupported: true)
        let feature = QueueState(commands: owner, context: context); await feature.refresh()
        await feature.send(.ended(try await owner.snapshot().playbackToken))
        #expect(feature.snapshot?.current?.media.rawValue == "b" && feature.error != nil)
        #expect(feature.currentOccurrence == (try await owner.snapshot().session.currentOccurrence))
    }
    @Test(arguments: [PauseReason.user, .routeLoss, .accountSwitch, .quit]) func F5PausedExhaustionDoesNotRestart(reason: PauseReason) async throws {
        let context = try request(); let player = RecordingPlayback(); let owner = try commands(make(["seed"]), playback: player)
        _ = try await owner.execute(.resume, context: context, origin: .menu)
        _ = try await owner.execute(.ended(try await owner.snapshot().playbackToken), context: context, origin: .menu)
        #expect(try await owner.snapshot().intent == .play)
        _ = try await owner.execute(.pause(reason), context: context, origin: .menu)
        let count = await player.selections.count
        let added = try await owner.execute(.recommendations(ids(["late"]), .init(source: "radio")), context: context, origin: .menu)
        #expect(added.session.currentOccurrence == nil && added.intent == .pause(reason))
        _ = try await owner.execute(.add(ids(["explicit-late"])), context: context, origin: .menu)
        #expect(await player.selections.count == count)
    }
    @Test func F5NaturalExhaustionContinuesButColdRestoreDoesNot() async throws {
        let context = try request(); let store = MemoryPersistence(); let player = RecordingPlayback(); let owner = try commands(make(["seed"]), store: store, playback: player)
        _ = try await owner.execute(.resume, context: context, origin: .menu)
        _ = try await owner.execute(.ended(try await owner.snapshot().playbackToken), context: context, origin: .menu)
        let continued = try await owner.execute(.recommendations(ids(["late"]), .init(source: "radio")), context: context, origin: .menu)
        #expect(continued.current?.media.rawValue == "late" && continued.intent == .play)
        _ = try await owner.execute(.ended(continued.playbackToken), context: context, origin: .menu)
        let explicit = try await owner.execute(.add(ids(["user-late"])), context: context, origin: .menu)
        #expect(explicit.current?.media.rawValue == "user-late")
        _ = try await owner.execute(.ended(explicit.playbackToken), context: context, origin: .menu)
        let restoredPlayer = RecordingPlayback(); let restored = try commands(make([]), store: store, playback: restoredPlayer)
        try await restored.restore(context: context)
        let waiting = try await restored.execute(.recommendations(ids(["cold-late"]), .init(source: "radio")), context: context, origin: .menu)
        #expect(waiting.session.currentOccurrence == nil && waiting.intent == .pause(.restored))
        #expect(await restoredPlayer.selections.isEmpty)
    }
}

struct QueuePermissionProvider: CapabilityProvider, PlaybackResolver {
    let account: AccountContext
    func permission() throws -> Capability { try Capability(state: .supported, source: "Owned synthetic queue test", context: account, checkedAt: Date(timeIntervalSince1970: 0), expiresAt: nil) }
    func capabilities(context: RequestContext) async -> ServiceResult<AccountCapabilities> { .init(context: context, outcome: .success(try! AccountCapabilities(context: account, features: [.playback: permission()]))) }
    func validateEligibility(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<Capability> { .init(context: context, outcome: .success(try! permission())) }
    func resolve(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<[MediaVariant]> { .init(context: context, outcome: .success([try! MediaVariant(id: ServiceID("synthetic-variant"), codec: "synthetic", container: "synthetic", bitrate: nil, sampleRate: nil, expiresAt: nil, seekable: true, authorization: ID("non-secret-test-reference"))])) }
    func refresh(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<MediaVariant> { .init(context: context, outcome: .success(variant)) }
    func report(_ event: ServicePlaybackEvent, context: PlaybackContext) async -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
}
actor QueueHeldEngine: PlaybackEngine {
    var calls: [String] = []; var seekPositions: [Double] = []; var plays: [PlaybackContext] = []
    private var shouldHold: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    init(holdFirstPlay: Bool = true) { shouldHold = holdFirstPlay }
    func waitForPlay() async { if held == nil { await withCheckedContinuation { entered = $0 } } }
    func releasePlay() { held?.resume(); held = nil }
    func holdNextPlay() { shouldHold = true }
    func result(_ context: PlaybackContext) -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
    func prepare(_ variant: MediaVariant, context: PlaybackContext) -> PlaybackResult<Void> { result(context) }
    func play(context: PlaybackContext) async -> PlaybackResult<Void> {
        plays.append(context); calls.append("play")
        if shouldHold { shouldHold = false; await withCheckedContinuation { held = $0; entered?.resume(); entered = nil } }
        return result(context)
    }
    func pause(context: PlaybackContext) -> PlaybackResult<Void> { result(context) }
    func seek(to seconds: Double, context: PlaybackContext) -> PlaybackResult<Void> { seekPositions.append(seconds); calls.append("seek:\(seconds)"); return result(context) }
    func stop(context: PlaybackContext) -> PlaybackResult<Void> { result(context) }
    func setGain(_ gain: Double, context: PlaybackContext) -> PlaybackResult<Void> { result(context) }
    func setRate(_ rate: Double, context: PlaybackContext) -> PlaybackResult<Void> { result(context) }
    func scheduleNext(_ variant: MediaVariant?, context: PlaybackContext) -> PlaybackResult<Void> { result(context) }
    func events(context: PlaybackContext) -> PlaybackResult<AsyncStream<ScopedEngineEvent>> { .init(context: context, outcome: .success(AsyncStream { $0.finish() })) }
}
func composedQueue(_ machine: QueueMachine, persistence: any QueuePersistence, engine: QueueHeldEngine, source: (any CapabilityProvider & PlaybackResolver)? = nil) async throws -> (QueueCommands, PlaybackCommands, PlaybackQueueBoundary, QueuePlaybackLifecycle) {
    let context = try request(); let provider: any CapabilityProvider & PlaybackResolver = source ?? QueuePermissionProvider(account: context.account!)
    let lifecycle = QueuePlaybackLifecycle()
    let domain = PlaybackCommands(request: context, engine: engine, resolver: provider, capabilities: provider, wall: SystemWallClock(), monotonic: SystemMonotonicClock(), lifecycle: lifecycle)
    let boundary = PlaybackQueueBoundary(commands: domain)
    let owner = try QueueCommands(machine: machine, context: context, persistence: persistence, playback: boundary, repeatSupported: true)
    await lifecycle.attach(owner: owner, boundary: boundary, context: context)
    return (owner, domain, boundary, lifecycle)
}
@Suite struct QueuePlaybackBindingTests {
    @Test @MainActor func F3HeldSelectionAcceptsFeatureEditsCheckpointAndEarlyEnd() async throws {
        let context = try request(); let engine = QueueHeldEngine()
        let (owner, domain, boundary, lifecycle) = try await composedQueue(make(["a", "b", "c"]), persistence: MemoryPersistence(), engine: engine)
        let feature = QueueState(commands: owner, context: context)
        let selection = Task { await feature.send(.resume) }
        await engine.waitForPlay()
        let early = await domain.snapshot().context
        let queueToken = try await owner.snapshot().playbackToken
        #expect(await boundary.token(for: early) == queueToken)
        // These calls finish BEFORE releasing source/engine work. QueueState must accept
        // this second command while its earlier send is still awaiting playback.
        try await feature.send(.add(ids(["offline-edit"])))
        #expect(feature.snapshot?.session.entries.last?.media.rawValue == "offline-edit")
        _ = try await owner.execute(.checkpointFor(queueToken, position: 5, pause: nil), context: context, origin: .menu)
        #expect(try await owner.snapshot().session.position == 5)
        await domain.receive(ScopedEngineEvent(context: early, event: .ended))
        #expect(try await owner.snapshot().current?.media.rawValue == "b")
        #expect(await lifecycle.error == nil)
        let after = try await owner.snapshot()
        await domain.receive(ScopedEngineEvent(context: early, event: .ended))
        #expect(try await owner.snapshot().playbackToken == after.playbackToken)
        await engine.releasePlay(); await selection.value
        #expect(feature.currentOccurrence == (try await owner.snapshot().session.currentOccurrence))
        #expect(feature.error == nil)
    }
    @Test func F4RestoredResumeSeeksBeforePlayAndAdvances() async throws {
        let context = try request(); let (store, directory) = try await queueSQLite("queue-resume-", context: context)
        defer { try? FileManager.default.removeItem(at: directory) }
        var q = try make(["a", "b"]); try q.checkpoint(position: 91.5)
        try await SQLiteQueuePersistence(store: store).save(q.snapshot, context: context)
        let engine = QueueHeldEngine(holdFirstPlay: false)
        let (owner, domain, boundary, lifecycle) = try await composedQueue(make([]), persistence: SQLiteQueuePersistence(store: store), engine: engine)
        try await owner.restore(context: context)
        #expect(await engine.plays.isEmpty)
        let resumed = try await owner.execute(.resume, context: context, origin: .mediaKey)
        #expect(resumed.session.position == 91.5 && resumed.current?.media.rawValue == "a")
        #expect(await engine.seekPositions == [91.5])
        #expect(await engine.calls.prefix(2) == ["seek:91.5", "play"])
        let engineContext = await domain.snapshot().context
        #expect(await boundary.token(for: engineContext) == resumed.playbackToken)
        #expect(await domain.snapshot().position == 91.5)
        await domain.receive(ScopedEngineEvent(context: engineContext, event: .ended))
        #expect(try await owner.snapshot().current?.media.rawValue == "b")
        #expect(await engine.plays.count == 2)
        #expect(await lifecycle.error == nil)
        await store.close()
    }
    @Test(arguments: [false, true]) func F5RoutePauseAndAccountDetachPreventLateStart(exhausted: Bool) async throws {
        let context = try request(); let engine = QueueHeldEngine(holdFirstPlay: false)
        let (owner, domain, _, lifecycle) = try await composedQueue(make(["a"]), persistence: MemoryPersistence(), engine: engine)
        _ = try await owner.execute(.resume, context: context, origin: .menu)
        if exhausted { await domain.receive(ScopedEngineEvent(context: await domain.snapshot().context, event: .ended)) }
        _ = try await domain.execute(.route(ID("synthetic-route")), context: context, origin: .menu)
        #expect(try await owner.snapshot().intent == .pause(.routeLoss))
        await lifecycle.detach(reason: .accountSwitch)
        #expect(try await owner.snapshot().intent == .pause(.accountSwitch))
    }
}

@Suite struct QueueLegacyCompactionTests {
    @Test(arguments: [true, false]) func F1OldNearLimitCheckpointIsRecoveredAndCannotReplayAds(recommendations: Bool) async throws {
        let context = try request(); let (store, directory) = try await queueSQLite("queue-legacy-", context: context)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = try QueueEntry(media: ServiceID("current"), segment: .context, originalOrder: 0)
        let immutable = try QueueEntry(media: ServiceID("non-ad-immutable"), segment: .context, originalOrder: 1, consumed: true)
        var entries = [current, immutable]; var metadata = QueueMetadata(); metadata.immutable.insert(immutable.id)
        for i in 0..<(recommendations ? 200 : 1000) {
            let entry = try QueueEntry(media: ServiceID("consumed-\(i)"), segment: recommendations ? .recommendation : .advertisement, originalOrder: i, consumed: true)
            entries.append(entry)
            if recommendations { metadata.recommendationSources[entry.id] = .init(source: "synthetic-radio", cursor: String(repeating: "c", count: 120)) }
            else { metadata.immutable.insert(entry.id) }
        }
        let queue = try QueueSession(account: context.account!, version: 1, entries: entries, currentOccurrence: current.id, position: 19, shuffleSeed: nil, repeatMode: .all, autoplay: true)
        let envelope = "local-queue-v1:" + (try JSONEncoder().encode(metadata)).base64EncodedString()
        #expect(envelope.utf8.count < 65536)
        // Construct the original bounded-on-disk legacy shape, including retained consumed metadata.
        try await store.saveQueue(queue, continuation: .init(contextID: nil, cursor: envelope), context: context)
        let persistence = SQLiteQueuePersistence(store: store)
        let recovered = try #require(await persistence.load(context: context))
        #expect(recovered.session.entries.count <= QueueMachine.historyLimit + 1)
        #expect(recovered.metadata.immutable.isEmpty && recovered.metadata.recommendationSources.isEmpty)
        var machine = try QueueMachine(restoring: recovered, supportsAutoplay: true)
        try machine.resume()
        _ = try machine.ended(token: machine.playbackToken, repeatSupported: true)
        #expect(machine.current == current.id)
        #expect(machine.entries.filter { $0.segment == .advertisement }.allSatisfy { $0.consumed })
        #expect(!machine.entries.contains { $0.id == immutable.id && !$0.consumed })
        try await persistence.save(machine.snapshot, context: context)
        #expect(try await store.restoredQueue(context: context)!.continuation.cursor!.utf8.count < 2048)
        await store.close()
    }
}

actor QueueHeldResolver: CapabilityProvider, PlaybackResolver {
    let provider: QueuePermissionProvider
    private var held: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    init(account: AccountContext) { provider = QueuePermissionProvider(account: account) }
    func waitForResolution() async { if held == nil { await withCheckedContinuation { ready = $0 } } }
    func release() { held?.resume(); held = nil }
    func capabilities(context: RequestContext) async -> ServiceResult<AccountCapabilities> { await provider.capabilities(context: context) }
    func validateEligibility(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<Capability> { await provider.validateEligibility(media, context: context) }
    func resolve(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<[MediaVariant]> {
        await withCheckedContinuation { held = $0; ready?.resume(); ready = nil }
        return await provider.resolve(media, context: context)
    }
    func refresh(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<MediaVariant> { await provider.refresh(variant, context: context) }
    func report(_ event: ServicePlaybackEvent, context: PlaybackContext) async -> PlaybackResult<Void> { await provider.report(event, context: context) }
}
@Suite struct QueueResolutionReentrancyTests {
    @Test @MainActor func F3SourceResolutionDoesNotBlockEditsOrLoseLaterPause() async throws {
        let context = try request(); let resolver = QueueHeldResolver(account: context.account!); let engine = QueueHeldEngine(holdFirstPlay: false)
        let (owner, domain, boundary, _) = try await composedQueue(make(), persistence: MemoryPersistence(), engine: engine, source: resolver)
        let feature = QueueState(commands: owner, context: context)
        let selection = Task { await feature.send(.resume) }
        await resolver.waitForResolution()
        let engineContext = await domain.snapshot().context
        #expect(await boundary.token(for: engineContext) == (try await owner.snapshot().playbackToken))
        try await feature.send(.playNext(ids(["offline-user-add"])))
        #expect(feature.snapshot?.session.entries[1].media.rawValue == "offline-user-add")
        await feature.send(.checkpoint(12))
        await feature.send(.pause(.user))
        #expect(feature.snapshot?.intent == .pause(.user) && feature.snapshot?.session.position == 12)
        await resolver.release(); await selection.value
        #expect(await engine.plays.isEmpty)
        #expect(feature.snapshot?.intent == .pause(.user) && feature.error == nil)
    }
}

@Suite struct QueueHandoffSupportReworkTests {
    @Test func restoredRepeatDoesNotOverrideOwnerSupport() async throws {
        let context = try request()
        var machine = try make(["same", "same"])
        try machine.setRepeat(.one, supported: true)
        let owner = try QueueCommands(machine: machine, context: context, persistence: MemoryPersistence(), playback: RecordingPlayback(), repeatSupported: false)
        _ = try await owner.execute(.resume, context: context, origin: .menu)
        let before = try await owner.snapshot()
        let preview = try await owner.previewNext()
        #expect(preview.current?.id != before.current?.id)
        let plan = try #require(await owner.reserveHandoff(context: context))
        #expect(plan.nextOccurrence == preview.current?.id)
        let after = try await owner.adoptHandoff(plan, position: 0, started: nil, ended: Date(), context: context)
        #expect(after.current?.id == preview.current?.id)
        #expect(after.metadata.recent.isEmpty)
    }
}
