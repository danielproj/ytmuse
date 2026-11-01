import Domain
import Foundation
import Persistence

public protocol QueuePersistence: Sendable {
    func load(context: RequestContext) async throws -> QueueSnapshot?
    func save(_ snapshot: QueueSnapshot, context: RequestContext) async throws
}
/// Uses the existing FULL-sync SQLite queue transaction. The cursor envelope is queue-owned,
/// versioned local state, never a provider continuation token passed directly to an adapter.
public struct SQLiteQueuePersistence: QueuePersistence, QueuePreferences {
    public let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }
    public func load(context: RequestContext) async throws -> QueueSnapshot? {
        guard let restored = try await store.restoredQueue(context: context) else { return nil }
        var metadata = QueueMetadata()
        if let cursor = restored.continuation.cursor, cursor.hasPrefix("local-queue-v2:") {
            guard let data = Data(base64Encoded: String(cursor.dropFirst("local-queue-v2:".count))) else { throw QueueError.invalidState }
            metadata = try JSONDecoder().decode(InternedQueueMetadata.self, from: data).expanded()
        } else if let cursor = restored.continuation.cursor, cursor.hasPrefix("local-queue-v1:") {
            guard let data = Data(base64Encoded: String(cursor.dropFirst("local-queue-v1:".count))) else { throw QueueError.invalidState }
            metadata = try JSONDecoder().decode(QueueMetadata.self, from: data)
        } else {
            metadata.contextID = restored.continuation.contextID?.rawValue; metadata.cursor = restored.continuation.cursor
        }
        metadata.preference = try await replacementPreference(context: context)
        let snapshot = QueueSnapshot(session: restored.queue, metadata: metadata, playbackToken: UUID(), intent: .pause(.restored))
        return try QueueMachine(restoring: snapshot, supportsAutoplay: true).snapshot
    }
    public func save(_ snapshot: QueueSnapshot, context: RequestContext) async throws {
        // Validate BEFORE encoding; an envelope must not disguise credentials from storage guards.
        let strings = [snapshot.metadata.contextID, snapshot.metadata.cursor, snapshot.metadata.lastMedia].compactMap { $0 }
            + snapshot.metadata.recommendationSources.values.flatMap { [$0.source, $0.cursor].compactMap { $0 } }
            + snapshot.metadata.recent.map(\.media) + (snapshot.metadata.failures ?? []).map(\.media)
        for text in strings {
            let forbidden = ["bearer ", "authorization:", "cookie:", "set-cookie:", "access_token=", "refresh_token=", "signature=", "sig=", "x-goog-signature=", "sapisidhash "]
            guard text.utf8.count <= 4096, !text.contains("\0"), !forbidden.contains(where: text.lowercased().contains) else { throw QueueError.invalidState }
            if let url = URL(string: text), url.scheme != nil {
                guard url.user == nil, url.password == nil, url.query == nil else { throw QueueError.invalidState }
            }
        }
        var metadata = snapshot.metadata
        // Settings are authoritative independently of a queue writer/continuation.
        metadata.preference = .ask
        let data = try JSONEncoder().encode(InternedQueueMetadata(metadata))
        let envelope = "local-queue-v2:" + data.base64EncodedString()
        guard envelope.utf8.count <= 65_536 else { throw QueueError.invalidState }
        try await store.saveQueue(snapshot.session, continuation: .init(contextID: try snapshot.metadata.contextID.map(ServiceID.init), cursor: envelope), context: context)
    }
}
/// Each shared source/cursor is encoded once; occurrence IDs retain precise provenance.
/// V1 dictionary checkpoints remain readable and are upgraded on the next atomic save.
private struct InternedQueueMetadata: Codable {
    struct Group: Codable { let source: RecommendationContext; var occurrences: [UUID] }
    var metadata: QueueMetadata
    var groups: [Group]
    init(_ value: QueueMetadata) {
        metadata = value; metadata.recommendationSources = [:]; groups = []
        var indices: [RecommendationContext: Int] = [:]
        for (id, source) in value.recommendationSources.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if let index = indices[source] { groups[index].occurrences.append(id) }
            else { indices[source] = groups.count; groups.append(Group(source: source, occurrences: [id])) }
        }
    }
    func expanded() throws -> QueueMetadata {
        var result = metadata
        guard metadata.recommendationSources.isEmpty else { throw QueueError.invalidState }
        for group in groups {
            for id in group.occurrences {
                guard result.recommendationSources[id] == nil, result.recommendationSources.count < QueueMachine.recommendationLimit else { throw QueueError.invalidState }
                result.recommendationSources[id] = group.source
            }
        }
        return result
    }
}
public protocol QueuePreferences: Sendable {
    func replacementPreference(context: RequestContext) async throws -> ReplacementPreference
    func setReplacementPreference(_ value: ReplacementPreference, context: RequestContext) async throws
}
public actor MemoryQueuePreferences: QueuePreferences {
    private var values: [AccountContext: ReplacementPreference] = [:]
    public init() {}
    public func replacementPreference(context: RequestContext) throws -> ReplacementPreference {
        guard let account = context.account else { throw QueueError.staleContext }; return values[account] ?? .ask
    }
    public func setReplacementPreference(_ value: ReplacementPreference, context: RequestContext) throws {
        guard let account = context.account else { throw QueueError.staleContext }; values[account] = value
    }
}
extension SQLiteQueuePersistence {
    public func replacementPreference(context: RequestContext) async throws -> ReplacementPreference {
        guard let account = context.account else { throw QueueError.staleContext }
        let result = await store.preferences(scope: .account(account), context: context)
        let values = try result.outcome.get().values
        guard let stored = values["queue.replaceExplicit"] else { return .ask }
        guard case .text(let text) = stored, let preference = ReplacementPreference(rawValue: text) else { throw QueueError.invalidState }
        return preference
    }
    public func setReplacementPreference(_ value: ReplacementPreference, context: RequestContext) async throws {
        guard let account = context.account else { throw QueueError.staleContext }
        let result = await store.preferences(scope: .account(account), context: context)
        let existing = try result.outcome.get()
        var values = existing.values; values["queue.replaceExplicit"] = .text(value.rawValue)
        let saved = await store.store(try Preferences(scope: .account(account), schemaVersion: existing.schemaVersion, values: values), context: context)
        _ = try saved.outcome.get()
    }
}
public protocol QueuePlaybackBoundary: Sendable {
    func cancelScheduled(context: RequestContext) async
    func position(for snapshot: QueueSnapshot, context: RequestContext) async -> Double?
    /// Must route through the application PlaybackCommands and enforce this context/token.
    /// No queue code resolves streams or directly controls an audio engine.
    func select(_ entry: QueueEntry, token: UUID, context: RequestContext, origin: CommandOrigin) async throws
    func pause(context: RequestContext, origin: CommandOrigin) async throws
    func start(_ entry: QueueEntry, position: Double, token: UUID, context: RequestContext, origin: CommandOrigin) async throws
    func pause(_ reason: PauseReason, context: RequestContext, origin: CommandOrigin) async throws
    func start(_ snapshot: QueueSnapshot, context: RequestContext, origin: CommandOrigin) async throws
    func pause(_ reason: PauseReason, snapshot: QueueSnapshot, context: RequestContext, origin: CommandOrigin) async throws
}
extension QueuePlaybackBoundary {
    public func cancelScheduled(context: RequestContext) async {}
    public func position(for snapshot: QueueSnapshot, context: RequestContext) async -> Double? { nil }
    public func start(_ snapshot: QueueSnapshot, context: RequestContext, origin: CommandOrigin) async throws {
        if let entry = snapshot.current { try await start(entry, position: snapshot.session.position, token: snapshot.playbackToken, context: context, origin: origin) }
    }
    public func pause(_ reason: PauseReason, snapshot: QueueSnapshot, context: RequestContext, origin: CommandOrigin) async throws { try await pause(reason, context: context, origin: origin) }
    public func start(_ entry: QueueEntry, position: Double, token: UUID, context: RequestContext, origin: CommandOrigin) async throws {
        guard position == 0 else { throw QueueError.unsupported }
        try await select(entry, token: token, context: context, origin: origin)
    }
    public func pause(_ reason: PauseReason, context: RequestContext, origin: CommandOrigin) async throws { try await pause(context: context, origin: origin) }
}
public struct SaveQueuePlaylistIntent: Sendable {
    public let context: RequestContext
    public let occurrences: [PlaylistItem]
    public let privacy: PlaylistPrivacy = .private
    /// An intent for the permission-aware playlist command layer; no remote write is claimed.
    public let localOnly = true
}
public enum QueueCommand: Sendable {
    case playNext([ServiceID]), add([ServiceID]), remove(Set<UUID>), move([UUID], before: UUID?), clearUpcoming, undo
    case replace([ServiceID], source: ServiceID, cursor: String?, decision: ReplacementPreference?, remember: Bool)
    case preference(ReplacementPreference), shuffle(UInt64?), repeatMode(RepeatMode), autoplay(Bool)
    case recommendations([ServiceID], RecommendationContext), serviceEntry(QueueEntry, immutable: Bool)
    case select(UUID), previousItem, nextItem, failedAdvance(UUID), resume, pause(PauseReason), ended(UUID), checkpoint(Double)
    case checkpointFor(UUID, position: Double, pause: PauseReason?)
    case observedPlayback(UUID, position: Double, intent: PlaybackIntent)
    case startContext([ServiceID], source: ServiceID, cursor: String?, decision: ReplacementPreference?, remember: Bool, start: ContextStart)
    case failedPlayback(UUID, reason: QueueFailureReason, at: Date)
    case listened(UUID, started: Date, ended: Date), historyPaused(Bool), clearLocalHistory
}
/// Only the persistence write of a validated native handoff is retryable.
/// Validation, authorization and stale-context errors keep their original types.
public struct QueueHandoffCommitError: Error, Sendable {
    public init() {}
}

/// Queue transactions are serialized independently of network-dependent playback resolution.
/// A committed token is visible before dispatch; a newer selection/pause supersedes old work.
public actor QueueCommands {
    private var machine: QueueMachine
    private let context: RequestContext
    private let persistence: any QueuePersistence
    private let preferences: any QueuePreferences
    private let playback: any QueuePlaybackBoundary
    private let repeatSupported: Bool
    private var undo: [QueueMachine] = []
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var preferencesLoaded = false
    public init(machine: QueueMachine, context: RequestContext, persistence: any QueuePersistence, playback: any QueuePlaybackBoundary, repeatSupported: Bool, preferences: (any QueuePreferences)? = nil) throws {
        guard machine.account == context.account else { throw QueueError.staleContext }
        self.machine = machine; self.context = context; self.persistence = persistence; self.playback = playback; self.repeatSupported = repeatSupported
        self.preferences = preferences ?? (persistence as? any QueuePreferences) ?? MemoryQueuePreferences()
    }
    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    private func loadPreferences() async throws {
        if !preferencesLoaded {
            machine.setPreference(try await preferences.replacementPreference(context: context)); preferencesLoaded = true
        }
    }
    public func snapshot() throws -> QueueSnapshot { try machine.snapshot }
    public func previewNext() throws -> QueueSnapshot { try machine.previewNext(repeatSupported: repeatSupported) }
    public func canUndo() -> Bool { !undo.isEmpty }
    public func restore(context: RequestContext) async throws {
        guard context == self.context else { throw QueueError.staleContext }
        await acquire(); defer { release() }
        if let state = try await persistence.load(context: context) {
            guard state.session.account == context.account else { throw QueueError.staleContext }
            machine = try QueueMachine(restoring: state, supportsAutoplay: machine.supportsAutoplay); undo = []
        }
        preferencesLoaded = false; try await loadPreferences()
    }
    public func playlistIntent(context: RequestContext) throws -> SaveQueuePlaylistIntent {
        guard context == self.context else { throw QueueError.staleContext }
        return SaveQueuePlaylistIntent(context: context, occurrences: machine.entries.filter { !$0.consumed && $0.segment != .advertisement && $0.segment != .history && !machine.metadata.immutable.contains($0.id) }.map { PlaylistItem(occurrence: .synthetic($0.id), media: $0.media) })
    }
    public func reserveHandoff(context: RequestContext) async throws -> QueueHandoff? {
        guard context == self.context else { throw QueueError.staleContext }
        await acquire(); defer { release() }
        var next = machine
        guard let plan = try next.reserveHandoff(repeatSupported: repeatSupported) else { return nil }
        if machine.metadata.handoff == nil {
            try next.bumpVersion(); try await persistence.save(next.snapshot, context: context); machine = next
        }
        return plan
    }
    public func cancelHandoff(context: RequestContext) async throws {
        guard context == self.context else { throw QueueError.staleContext }
        await acquire(); defer { release() }
        await playback.cancelScheduled(context: context)
        guard machine.metadata.handoff != nil else { return }
        var next = machine; next.clearHandoff()
        try next.bumpVersion(); try await persistence.save(next.snapshot, context: context); machine = next
    }
    public func adoptHandoff(_ plan: QueueHandoff, position: Double, started: Date?, ended: Date, context: RequestContext) async throws -> QueueSnapshot {
        guard context == self.context else { throw QueueError.staleContext }
        await acquire(); defer { release() }
        var next = machine
        try next.adoptHandoff(plan, position: position, started: started, ended: ended, repeatSupported: repeatSupported)
        try next.bumpVersion()
        do { try await persistence.save(next.snapshot, context: context) }
        catch { throw QueueHandoffCommitError() }
        machine = next; undo = []; return try next.snapshot
    }
    private enum Dispatch { case none, start(QueueSnapshot), pause(PauseReason, QueueSnapshot) }
    @discardableResult public func execute(_ command: QueueCommand, context: RequestContext, origin: CommandOrigin) async throws -> QueueSnapshot {
        guard context == self.context else { throw QueueError.staleContext }
        let dispatch = try await commit(command)
        // The transaction gate is released. Other edits, engine ends, checkpoints and
        // newer transport intent can enter while the boundary awaits source resolution.
        switch dispatch {
        case .none: break
        case .pause(let reason, let snapshot):
            if machine.playbackToken == snapshot.playbackToken {
                do { try await playback.pause(reason, snapshot: snapshot, context: context, origin: origin) }
                catch { if machine.playbackToken == snapshot.playbackToken { throw error } }
            }
        case .start(let snapshot):
            if machine.playbackToken == snapshot.playbackToken, machine.intent == .play, snapshot.current != nil {
                do { try await playback.start(snapshot, context: context, origin: origin) }
                catch { if machine.playbackToken == snapshot.playbackToken { throw error } }
            }
        }
        // A superseded dispatch must never return an older published state to a surface.
        return try machine.snapshot
    }
    private func commit(_ command: QueueCommand) async throws -> Dispatch {
        await acquire(); defer { release() }
        try await loadPreferences()
        var cancelPlan = false
        switch command {
        case .checkpoint, .checkpointFor, .listened: break
        case .observedPlayback(_, _, let intent) where intent == .play: break
        default:
            cancelPlan = true
        }
        var next = machine
        var edits = undo; var undoable = true; var selects = false; var transition = false
        var pause: PauseReason?; var preference: ReplacementPreference?
        switch command {
        case .playNext(let media): try next.insert(media, next: true); selects = try next.continueIfExhausted()
        case .add(let media): try next.insert(media, next: false); selects = try next.continueIfExhausted()
        case .remove(let ids): try next.remove(ids)
        case .move(let ids, let target): try next.move(ids, before: target)
        case .clearUpcoming: next.clearUpcoming()
        case .replace(let media, let source, let cursor, let decision, let remember):
            try next.replaceContext(media, source: source, cursor: cursor, decision: decision, remember: remember)
            if let id = next.current { try next.select(id); selects = true } else { next.pause(.user); pause = .user }
            if remember, let decision, decision != .ask { preference = decision }
            transition = true; undoable = false
        case .startContext(let media, let source, let cursor, let decision, let remember, let start):
            try next.replaceContext(media, source: source, cursor: cursor, decision: decision, remember: remember, start: start)
            if let id = next.current { try next.select(id); selects = true } else { next.pause(.user); pause = .user }
            if remember, let decision, decision != .ask { preference = decision }
            transition = true; undoable = false
        case .preference(let value): next.setPreference(value); preference = value; undoable = false
        case .shuffle(let seed): next.shuffle(seed)
        case .repeatMode(let mode): try next.setRepeat(mode, supported: repeatSupported)
        case .autoplay(let enabled): try next.setAutoplay(enabled)
        case .recommendations(let media, let source):
            try next.recommend(media, source: source); selects = try next.continueIfExhausted(); undoable = false; transition = true
        case .serviceEntry(let entry, let immutable):
            try next.appendService(entry, immutable: immutable); selects = try next.continueIfExhausted(); undoable = false; transition = true
        case .select(let id): try next.select(id); selects = true; undoable = false; transition = true
        case .previousItem: try next.previousItem(); selects = true; undoable = false; transition = true
        case .nextItem, .failedAdvance:
            if case .failedAdvance(let token) = command {
                guard token == next.playbackToken, next.intent == .play else { return .none }
            }
            try next.nextItem(repeatSupported: repeatSupported)
            if next.current != nil { selects = true } else { next.pause(.user); pause = .user }
            undoable = false; transition = true
        case .resume: try next.resume(); selects = true; undoable = false; transition = true
        case .pause(let reason):
            // Commit position and pause together, before publishing the new token.
            // Only the exact currently bound occurrence can supply this sample.
            if let position = await playback.position(for: try next.snapshot, context: context) { try next.checkpoint(position: position) }
            next.pause(reason); pause = reason; undoable = false; transition = true
        case .ended(let token):
            guard next.intent == .play else { return .none }
            guard try next.ended(token: token, repeatSupported: repeatSupported) else { return .none }
            selects = next.intent == .play; undoable = false; transition = true
        case .checkpoint(let position): try next.checkpoint(position: position); undoable = false
        case .observedPlayback(let token, let position, let intent):
            if token == next.playbackToken, next.current != nil {
                try next.checkpoint(position: position); transition = next.intent != intent; next.observe(intent)
            } else if case .pause(let reason) = intent, next.current == nil, next.intent == .play, next.exhaustedToken == token {
                next.pause(reason); transition = true
            } else { return .none }
            undoable = false
        case .checkpointFor(let token, let position, let reason):
            if token == next.playbackToken {
                try next.checkpoint(position: position)
            } else {
                // An exhausted engine still owns global route/user pause observations.
                // It cannot overwrite a newer occurrence or a cold-restored session.
                guard reason != nil, next.current == nil, next.intent == .play, next.exhaustedToken == token else { return .none }
            }
            if let reason { next.pause(reason); transition = true }
            undoable = false
        case .failedPlayback(let token, let reason, let date): next.recordFailure(token: token, reason: reason, at: date); undoable = false
        case .listened(let id, let start, let end): try next.recordListening(occurrence: id, started: start, ended: end); undoable = false
        case .historyPaused(let paused): next.history(paused: paused); undoable = false
        case .clearLocalHistory: next.clearLocalHistory(); undoable = false; transition = true
        case .undo:
            guard let previous = edits.popLast() else { return .none }
            next.restoreEdit(previous); undoable = false
        }
        if transition || selects { edits = [] }
        if undoable && !selects { edits.append(machine); edits = Array(edits.suffix(20)) }
        if cancelPlan {
            await playback.cancelScheduled(context: context)
            next.clearHandoff()
        }
        try next.compactConsumed()
        if let preference {
            try await preferences.setReplacementPreference(preference, context: context)
            machine.setPreference(preference) // Independent setting survives a failed queue checkpoint.
        }
        try next.bumpVersion()
        try await persistence.save(next.snapshot, context: context)
        machine = next; undo = edits
        if let pause { return .pause(pause, try next.snapshot) }
        return selects ? .start(try next.snapshot) : .none
    }
}
