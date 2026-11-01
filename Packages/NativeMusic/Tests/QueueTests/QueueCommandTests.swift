import Foundation
import Testing
import Domain
import Persistence
import Features
@testable import Queue

@Suite struct QueueCommandTests {
    @Test func removingOneDuplicateAndUndoPreservesOtherOccurrences() async throws {
        let owner = try commands(make(["duplicate", "duplicate", "duplicate", "other"]))
        let context = try request(); let original = try await owner.snapshot()
        let removed = original.session.entries[1].id
        let remaining = try await owner.execute(.remove([removed]), context: context, origin: .menu)
        #expect(remaining.session.entries.map(\.id) == original.session.entries.filter { $0.id != removed }.map(\.id))
        #expect(remaining.session.entries.filter { $0.media.rawValue == "duplicate" }.count == 2)
        let undone = try await owner.execute(.undo, context: context, origin: .menu)
        #expect(undone.session.entries.map(\.id) == original.session.entries.map(\.id))
    }

    @Test func T054OfflineUndoAndFailedCommit() async throws {
        let store = MemoryPersistence(); let player = RecordingPlayback()
        let owner = try commands(make(), store: store, playback: player); let context = try request()
        let before = try await owner.snapshot()
        await store.setFailure(true)
        await #expect(throws: QueueError.invalidState) { try await owner.execute(.add(ids(["lost"])), context: context, origin: .menu) }
        #expect(try await owner.snapshot().session.version == before.session.version)
        #expect(await !owner.canUndo())
        await store.setFailure(false)
        _ = try await owner.execute(.add(ids(["offline", "offline"])), context: context, origin: .menu)
        _ = try await owner.execute(.checkpoint(23.5), context: context, origin: .menu)
        _ = try await owner.execute(.listened(before.current!.id, started: Date(timeIntervalSince1970: 10), ended: Date(timeIntervalSince1970: 20)), context: context, origin: .menu)
        let undone = try await owner.execute(.undo, context: context, origin: .menu)
        #expect(undone.session.entries.map(\.id) == before.session.entries.map(\.id))
        #expect(undone.session.position == 23.5 && undone.metadata.recent.count == 1)
        _ = try await owner.execute(.clearUpcoming, context: context, origin: .menu)
        #expect(try await owner.snapshot().session.entries.count == 1)
        _ = try await owner.execute(.undo, context: context, origin: .menu)
        #expect(try await owner.snapshot().session.entries.count == 4)
        #expect(await player.selections.isEmpty)
    }
    @Test func transitionInvalidatesUndoAndRejectsStale() async throws {
        let player = RecordingPlayback(); let owner = try commands(make(), playback: player); let context = try request()
        _ = try await owner.execute(.add(ids(["pending"])), context: context, origin: .shortcut)
        _ = try await owner.execute(.resume, context: context, origin: .shortcut)
        let before = try await owner.snapshot()
        let after = try await owner.execute(.ended(before.playbackToken), context: context, origin: .shortcut)
        #expect(await !owner.canUndo())
        let duplicate = try await owner.execute(.ended(before.playbackToken), context: context, origin: .shortcut)
        #expect(after.session.currentOccurrence == duplicate.session.currentOccurrence && after.session.version == duplicate.session.version)
        #expect(await player.selections.count == 2)
        await #expect(throws: QueueError.staleContext) { try await owner.execute(.clearUpcoming, context: request(generation: 2), origin: .shortcut) }
    }
    @Test func saveIntentPreservesDuplicatesAndExcludesAds() async throws {
        var q = try make(["a", "a"])
        try q.appendService(QueueEntry(media: ServiceID("ad"), segment: .advertisement, originalOrder: 2), immutable: true)
        let owner = try commands(q)
        let intent = try await owner.playlistIntent(context: request())
        #expect(intent.occurrences.count == 2 && intent.occurrences[0].media == intent.occurrences[1].media)
        #expect(intent.occurrences[0].occurrence != intent.occurrences[1].occurrence)
        #expect(intent.privacy == .private && intent.localOnly)
    }
    @Test func T054SQLiteReopenPausedWithAllState() async throws {
        let context = try request()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-T05-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(directory: directory, context: context)
        try await store.saveAccount(Account(id: context.account!.accountID, serviceIdentity: ServiceID("synthetic-identity"), context: context.account!, displayName: "Queue synthetic", credential: nil), context: context)
        let persistence = SQLiteQueuePersistence(store: store)
        let player = RecordingPlayback()
        let owner = try QueueCommands(machine: make(), context: context, persistence: persistence, playback: player, repeatSupported: true)
        _ = try await owner.execute(.preference(.keep), context: context, origin: .menu)
        _ = try await owner.execute(.shuffle(314159), context: context, origin: .menu)
        _ = try await owner.execute(.resume, context: context, origin: .menu)
        let initial = try await owner.snapshot()
        _ = try await owner.execute(.ended(initial.playbackToken), context: context, origin: .menu)
        _ = try await owner.execute(.checkpoint(47.25), context: context, origin: .menu)
        _ = try await owner.execute(.recommendations(ids(["rec"]), .init(source: "radio", cursor: "next")), context: context, origin: .menu)
        let expected = try await owner.snapshot()
        await store.close()
        let reopened = try SQLiteStore(directory: directory, context: context)
        let restoredPlayer = RecordingPlayback()
        let restored = try QueueCommands(machine: make([]), context: context, persistence: SQLiteQueuePersistence(store: reopened), playback: restoredPlayer, repeatSupported: true)
        try await restored.restore(context: context)
        let actual = try await restored.snapshot()
        #expect(actual.session.entries.map(\.id) == expected.session.entries.map(\.id))
        #expect(actual.session.entries.map(\.consumed) == expected.session.entries.map(\.consumed))
        #expect(actual.session.currentOccurrence == expected.session.currentOccurrence && actual.session.position == 47.25)
        #expect(actual.session.shuffleSeed == 314159 && actual.metadata.contextCursor == 1 && actual.metadata.preference == .keep)
        #expect(actual.metadata.recommendationSources == expected.metadata.recommendationSources)
        #expect(actual.intent == .pause(.restored) && actual.playbackToken != expected.playbackToken)
        #expect(await restoredPlayer.selections.isEmpty)
        _ = try await restored.execute(.clearUpcoming, context: context, origin: .menu)
        _ = try await restored.execute(.undo, context: context, origin: .menu)
        await reopened.close()
    }
    @Test @MainActor func featureBindingsAndPrompt() async throws {
        let owner = try commands(make()); let feature = QueueState(commands: owner, context: try request())
        await feature.refresh()
        let current = feature.currentOccurrence
        try await feature.send(.playNext(ids(["pending"])))
        try await feature.send(.replace(ids(["new"]), source: ServiceID("album-new"), cursor: "cursor", decision: nil, remember: false))
        #expect(feature.replacementNeedsDecision && feature.currentOccurrence == current)
        try await feature.send(.replace(ids(["new"]), source: ServiceID("album-new"), cursor: "cursor", decision: .keep, remember: true))
        #expect(!feature.replacementNeedsDecision && feature.snapshot?.metadata.cursor == "cursor")
        await feature.prepareSaveAsPlaylist()
        #expect(feature.playlistIntent?.occurrences.count == 2 && feature.error == nil)
    }
}

@Suite struct QueueDurabilityTests {
    @Test func T054KilledProcessRestoresPaused() async throws {
        let worker = try #require(ProcessInfo.processInfo.environment["QUEUE_CRASH_WORKER"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-kill-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: worker); process.arguments = [directory.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == 9)
        let context = try request(); let store = try SQLiteStore(directory: directory, context: context)
        let persistence = SQLiteQueuePersistence(store: store)
        let snapshot = try #require(await persistence.load(context: context))
        let machine = try QueueMachine(restoring: snapshot, supportsAutoplay: true)
        #expect(machine.entries.count == 5 && machine.entries.filter(\.consumed).count == 1)
        #expect(machine.entries.filter { $0.segment == .playNext }.count == 2)
        #expect(machine.seed == 314159 && machine.position == 91.5)
        #expect(machine.metadata.contextID == "owned-context" && machine.metadata.cursor == "owned-cursor" && machine.metadata.contextCursor == 1)
        #expect(machine.intent == .pause(.restored))
        await store.close()
    }
    @Test func fiveThousandEntryDuplicateQueueAndAccountIsolation() async throws {
        let context = try request(); let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-stress-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(directory: directory, context: context)
        try await store.saveAccount(Account(id: context.account!.accountID, serviceIdentity: ServiceID("synthetic"), context: context.account!, displayName: "Synthetic stress", credential: nil), context: context)
        var machine = try make((0..<5000).map { "duplicate-\($0 % 7)" }); machine.shuffle(7)
        try machine.recommend(ids((0..<25).map { "recommendation-\($0 % 3)" }), source: .init(source: "synthetic-radio"))
        for i in 0..<100 { try machine.recordListening(occurrence: machine.current!, started: Date(timeIntervalSince1970: Double(i)), ended: Date(timeIntervalSince1970: Double(i + 1))) }
        let persistence = SQLiteQueuePersistence(store: store)
        try await persistence.save(machine.snapshot, context: context)
        let restored = try #require(await persistence.load(context: context))
        #expect(restored.session.entries.map(\.id) == machine.entries.map(\.id) && restored.metadata.recent.count == 100)
        let another = try request("another-channel", generation: 2)
        await store.bind(another)
        await #expect(throws: DomainError.staleContext) { try await persistence.load(context: context) }
        #expect(try await persistence.load(context: another) == nil)
        await store.close()
    }
    @Test func envelopeCannotHideCredentials() async throws {
        let context = try request(); let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-safety-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(directory: directory, context: context)
        var machine = try make()
        try machine.recommend(ids(["recommendation"]), source: .init(source: "Authorization: synthetic-only"))
        await #expect(throws: QueueError.invalidState) { try await SQLiteQueuePersistence(store: store).save(machine.snapshot, context: context) }
        #expect(try await store.restoredQueue(context: context) == nil)
        await store.close()
    }
}

actor HeldPersistence: QueuePersistence {
    private var entered = false
    private var ready: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    func load(context: RequestContext) -> QueueSnapshot? { nil }
    func save(_ snapshot: QueueSnapshot, context: RequestContext) async {
        guard !entered else { return }
        entered = true; ready?.resume(); ready = nil
        await withCheckedContinuation { held = $0 }
    }
    func waitForWrite() async { if !entered { await withCheckedContinuation { ready = $0 } } }
    func release() { held?.resume(); held = nil }
}
@Suite struct QueueSerializationTests {
    @Test func suspendedCommitCannotLoseConcurrentEdits() async throws {
        let persistence = HeldPersistence(); let context = try request()
        let owner = try QueueCommands(machine: make(), context: context, persistence: persistence, playback: RecordingPlayback(), repeatSupported: true)
        let task = Task { try await owner.execute(.add(ids(["first"])), context: context, origin: .menu) }
        await persistence.waitForWrite()
        #expect(try await owner.snapshot().session.entries.count == 4)
        let second = Task { try await owner.execute(.add(ids(["second"])), context: context, origin: .menu) }
        await persistence.release()
        _ = try await task.value
        _ = try await second.value
        #expect(try await owner.snapshot().session.entries.suffix(2).map(\.media.rawValue) == ["first", "second"])
    }
}
