import Domain
import Foundation

public enum ReplacementPreference: String, Codable, Sendable { case ask, keep, replace }
public enum QueueError: Error, Equatable { case confirmationRequired, immutable, missingOccurrence, invalidState, staleContext, busy, unsupported }
public struct RecommendationContext: Codable, Hashable, Sendable {
    public let source: String
    public let cursor: String?
    public init(source: String, cursor: String? = nil) { self.source = source; self.cursor = cursor }
}
public struct LocalListening: Codable, Equatable, Sendable {
    public let occurrence: UUID
    public let media: String
    public let started: Date
    public let ended: Date
}
public enum QueueFailureReason: String, Codable, Sendable {
    case unavailable, unauthorized, forbidden, expired, offline, other
    public init(_ error: DomainError) {
        switch error {
        case .unavailableContent, .regionRestricted: self = .unavailable
        case .unauthorized: self = .unauthorized
        case .forbidden: self = .forbidden
        case .expiredMedia: self = .expired
        case .offline: self = .offline
        default: self = .other
        }
    }
}
public struct LocalPlaybackFailure: Codable, Sendable {
    public let occurrence: UUID
    public let media: String
    public let reason: QueueFailureReason
    public let at: Date
}
/// Durable intent authorizes exactly one anticipated logical native transition.
/// Cold restoration discards it and stays paused; no source credentials are stored.
public struct QueueHandoff: Codable, Equatable, Sendable {
    public let id: UUID
    public let currentToken: UUID
    public let nextToken: UUID
    public let nextOccurrence: UUID
    public let sourceVersion: UInt64
}
/// Versioned metadata stored in the same SQLite transaction as the queue header/entries.
public struct QueueMetadata: Codable, Sendable {
    public var schema = 1
    public var handoff: QueueHandoff?
    public var contextID: String?
    public var cursor: String?
    public var preference: ReplacementPreference = .ask
    public var immutable: Set<UUID> = []
    public var recommendationSources: [UUID: RecommendationContext] = [:]
    public var recent: [LocalListening] = []
    public var historyPaused = false
    public var failures: [LocalPlaybackFailure]?
    public var lastMedia: String?
    public var contextCursor = 0
    public init() {}
}
public struct QueueSnapshot: Sendable {
    public let session: QueueSession
    public let metadata: QueueMetadata
    /// A fresh token for each selection/repetition. Old engine completions cannot advance twice.
    public let playbackToken: UUID
    public let intent: PlaybackIntent
    public var current: QueueEntry? { session.entries.first { $0.id == session.currentOccurrence } }
    public var upcoming: [QueueEntry] { session.entries.filter { !$0.consumed && $0.id != session.currentOccurrence } }
}
public enum ContextStart: Sendable { case preserveShuffle, ordered, shuffled(seed: UInt64) }
public struct QueueMachine: Sendable {
    public private(set) var entries: [QueueEntry] = []
    public private(set) var current: UUID?
    public private(set) var position = 0.0
    public private(set) var seed: UInt64?
    public private(set) var repeatMode: RepeatMode = .off
    public private(set) var autoplay: Bool
    public private(set) var metadata = QueueMetadata()
    public private(set) var version: UInt64 = 0
    public private(set) var playbackToken = UUID()
    private(set) var exhaustedToken: UUID?
    public private(set) var intent: PlaybackIntent = .pause(.restored)
    public let account: AccountContext
    public let supportsAutoplay: Bool
    public static let historyLimit = 100
    public static let entryLimit = 100_000
    public static let recommendationLimit = 1_000
    public init(account: AccountContext, supportsAutoplay: Bool) { self.account = account; self.supportsAutoplay = supportsAutoplay; autoplay = supportsAutoplay }
    public init(restoring snapshot: QueueSnapshot, supportsAutoplay: Bool) throws {
        self.init(account: snapshot.session.account, supportsAutoplay: supportsAutoplay)
        entries = snapshot.session.entries; current = snapshot.session.currentOccurrence; position = snapshot.session.position
        seed = snapshot.session.shuffleSeed; repeatMode = snapshot.session.repeatMode; autoplay = snapshot.session.autoplay && supportsAutoplay
        metadata = snapshot.metadata; metadata.handoff = nil; version = snapshot.session.version
        guard metadata.schema == 1, entries.count <= Self.entryLimit, metadata.recent.count <= Self.historyLimit, (metadata.failures?.count ?? 0) <= Self.historyLimit,
              metadata.contextCursor >= 0, !entries.contains(where: { $0.id == current && $0.consumed }), metadata.immutable.isSubset(of: Set(entries.map(\.id))),
              Set(metadata.recommendationSources.keys).isSubset(of: Set(entries.map(\.id))) else { throw QueueError.invalidState }
        try compactConsumed()
        updateContextCursor()
        // Playback token and audible intent are deliberately never restored.
    }
    public var snapshot: QueueSnapshot {
        get throws { QueueSnapshot(session: try QueueSession(account: account, version: version, entries: entries, currentOccurrence: current, position: position, shuffleSeed: seed, repeatMode: repeatMode, autoplay: autoplay), metadata: metadata, playbackToken: playbackToken, intent: intent) }
    }
    public mutating func bumpVersion() throws { guard version < .max else { throw QueueError.invalidState }; version += 1 }
    private func editable(_ e: QueueEntry) -> Bool { !e.consumed && e.id != current && e.segment != .advertisement && !metadata.immutable.contains(e.id) }
    private func explicit(_ e: QueueEntry) -> Bool { [.user, .playNext, .addToQueue].contains(e.segment) }
    private func entry(_ media: ServiceID, segment: QueueSegment, order: Int) throws -> QueueEntry { try QueueEntry(media: media, segment: segment, originalOrder: order) }
    private mutating func pruneMetadata() {
        let activeIDs = Set(entries.filter { !$0.consumed || $0.id == current }.map(\.id))
        metadata.immutable.formIntersection(activeIDs)
        metadata.recommendationSources = metadata.recommendationSources.filter { activeIDs.contains($0.key) }
    }
    /// Retain source context for repeat/unshuffle, but only a bounded tail of consumed
    /// recommendations, ads and replaced contexts. Dropped ads are never reintroduced.
    mutating func compactConsumed() throws {
        entries = try entries.map { e in
            guard e.consumed, e.segment != .advertisement, metadata.immutable.contains(e.id) else { return e }
            return try QueueEntry(id: e.id, media: e.media, segment: .history, originalOrder: e.originalOrder, consumed: true)
        }
        let disposable = entries.filter { $0.consumed && $0.id != current && [.history, .advertisement, .recommendation].contains($0.segment) }
        let retained = Set(disposable.suffix(Self.historyLimit).map(\.id))
        entries.removeAll { $0.consumed && $0.id != current && [.history, .advertisement, .recommendation].contains($0.segment) && !retained.contains($0.id) }
        pruneMetadata()
    }
    /// First still-unconsumed original in this loaded context, independent of playback
    /// permutation. This local consumption cursor is never the provider page cursor.
    private mutating func updateContextCursor() {
        let context = entries.filter { $0.segment == .context }
        metadata.contextCursor = context.filter { !$0.consumed }.map(\.originalOrder).min()
            ?? context.map { $0.originalOrder + 1 }.max() ?? 0
    }
    mutating func continueIfExhausted() throws -> Bool {
        guard current == nil, intent == .play, let first = entries.first(where: { !$0.consumed }) else { return false }
        current = first.id; position = 0; playbackToken = UUID(); return true
    }
    public mutating func resume() throws {
        if current == nil { current = entries.first(where: { !$0.consumed })?.id }
        intent = .play; playbackToken = UUID()
    }
    /// Passive same-generation transport observations retain completion identity.
    mutating func observe(_ intent: PlaybackIntent) { self.intent = intent }
    public mutating func pause(_ reason: PauseReason) {
        intent = .pause(reason); playbackToken = UUID()
    }
    public mutating func insert(_ media: [ServiceID], next: Bool) throws {
        guard entries.count + media.count <= Self.entryLimit else { throw QueueError.invalidState }
        let added = try media.enumerated().map { try entry($0.element, segment: next ? .playNext : .addToQueue, order: $0.offset) }
        let index = next ? entries.firstIndex(where: { !$0.consumed && $0.id != current }) : entries.firstIndex(where: { !$0.consumed && $0.id != current && $0.segment == .recommendation })
        entries.insert(contentsOf: added, at: index ?? entries.endIndex)
    }
    public mutating func replaceContext(_ media: [ServiceID], source: ServiceID, cursor: String? = nil, decision: ReplacementPreference? = nil, remember: Bool = false, start: ContextStart = .preserveShuffle) throws {
        let pending = entries.filter { !$0.consumed && $0.id != current && explicit($0) }
        let choice = decision ?? metadata.preference
        if !pending.isEmpty && choice == .ask { throw QueueError.confirmationRequired }
        guard !entries.contains(where: { !$0.consumed && ($0.segment == .advertisement || metadata.immutable.contains($0.id)) }) else { throw QueueError.immutable }
        let protectedHistory = try entries.filter { $0.consumed }.map { e in
            try QueueEntry(id: e.id, media: e.media, segment: e.segment == .advertisement ? .advertisement : .history, originalOrder: e.originalOrder, consumed: true)
        }
        let retained = choice == .keep ? pending : []
        guard media.count + retained.count + protectedHistory.count <= Self.entryLimit else { throw QueueError.invalidState }
        var context = try media.enumerated().map { try entry($0.element, segment: .context, order: $0.offset) }
        switch start { case .ordered: seed = nil; case .shuffled(let value): seed = value; case .preserveShuffle: break }
        if let seed { var random = QueueRandom(seed: seed); if context.count > 1 { for i in stride(from: context.count - 1, through: 1, by: -1) { context.swapAt(i, Int(random.next() % UInt64(i + 1))) } } }
        // Shuffle Play permutes the whole new context before choosing its current occurrence.
        entries = protectedHistory + Array(context.prefix(1)) + retained.filter { $0.segment == .playNext } + Array(context.dropFirst()) + retained.filter { $0.segment != .playNext }
        current = context.first?.id; position = 0; playbackToken = UUID(); intent = .pause(.user)
        metadata.contextID = source.rawValue; metadata.cursor = cursor; metadata.contextCursor = 0
        if remember, choice != .ask { metadata.preference = choice }
        try compactConsumed()
        updateContextCursor()
    }
    public mutating func setPreference(_ preference: ReplacementPreference) { metadata.preference = preference }
    public mutating func remove(_ ids: Set<UUID>) throws {
        guard ids.isSubset(of: Set(entries.map(\.id))) else { throw QueueError.missingOccurrence }
        guard entries.filter({ ids.contains($0.id) }).allSatisfy(editable) else { throw QueueError.immutable }
        entries.removeAll { ids.contains($0.id) }; pruneMetadata(); updateContextCursor()
    }
    public mutating func clearUpcoming() { entries.removeAll(where: editable); pruneMetadata(); updateContextCursor() }
    /// Selection order is caller order, shared by keyboard and drag commands. Target is an occurrence.
    public mutating func move(_ ids: [UUID], before target: UUID?) throws {
        guard Set(ids).count == ids.count, !ids.isEmpty else { throw QueueError.invalidState }
        let selected = try ids.map { id in guard let e = entries.first(where: { $0.id == id }) else { throw QueueError.missingOccurrence }; guard editable(e) else { throw QueueError.immutable }; return e }
        if let target { guard !ids.contains(target), let e = entries.first(where: { $0.id == target }), editable(e) else { throw QueueError.immutable } }
        var reordered = entries.filter { !ids.contains($0.id) }
        let recommendationStart = reordered.firstIndex { !$0.consumed && $0.id != current && $0.segment == .recommendation } ?? reordered.endIndex
        let requested = target.flatMap { id in reordered.firstIndex { $0.id == id } } ?? recommendationStart
        let destination = min(requested, recommendationStart)
        let promoted = try selected.map { e in
            try QueueEntry(id: e.id, media: e.media, segment: e.segment == .recommendation ? .addToQueue : e.segment, originalOrder: e.originalOrder, consumed: e.consumed)
        }
        reordered.insert(contentsOf: promoted, at: destination)
        // Never shift a protected slot, even indirectly through moving another item across it.
        for (i, e) in entries.enumerated() where !editable(e) { guard reordered[i].id == e.id else { throw QueueError.immutable } }
        entries = reordered
    }
    public mutating func shuffle(_ value: UInt64?) {
        let indices = entries.indices.filter { editable(entries[$0]) && entries[$0].segment == .context }
        var context = indices.map { entries[$0] }.sorted { $0.originalOrder < $1.originalOrder }
        if let value { var random = QueueRandom(seed: value); if context.count > 1 { for i in stride(from: context.count - 1, through: 1, by: -1) { context.swapAt(i, Int(random.next() % UInt64(i + 1))) } } }
        for (i, e) in zip(indices, context) { entries[i] = e }; seed = value
    }
    public mutating func setRepeat(_ mode: RepeatMode, supported: Bool) throws { guard supported || mode == .off else { throw QueueError.unsupported }; repeatMode = mode }
    public mutating func setAutoplay(_ enabled: Bool) throws {
        guard !enabled || supportsAutoplay else { throw QueueError.unsupported }; autoplay = enabled
        if !enabled { entries.removeAll { $0.segment == .recommendation && !$0.consumed && $0.id != current }; pruneMetadata() }
    }
    public mutating func recommend(_ media: [ServiceID], source: RecommendationContext) throws {
        guard autoplay else { return }
        guard metadata.recommendationSources.count + media.count <= Self.recommendationLimit else { throw QueueError.invalidState }
        var previous = entries.last(where: { !$0.consumed })?.media ?? entries.first(where: { $0.id == current })?.media
        if previous == nil { previous = try metadata.lastMedia.map(ServiceID.init) }
        for media in media where media != previous {
            guard entries.count < Self.entryLimit else { throw QueueError.invalidState }
            let e = try entry(media, segment: .recommendation, order: entries.count)
            entries.append(e); metadata.recommendationSources[e.id] = source; previous = media
        }
    }
    /// Only a verified service boundary may install immutable entries, including advertisements.
    public mutating func appendService(_ entry: QueueEntry, immutable: Bool) throws {
        guard entries.count < Self.entryLimit, !entries.contains(where: { $0.id == entry.id }) else { throw QueueError.invalidState }
        if entry.consumed && immutable && entry.segment != .advertisement {
            entries.append(try QueueEntry(id: entry.id, media: entry.media, segment: .history, originalOrder: entry.originalOrder, consumed: true))
        } else { entries.append(entry) }
        if !entry.consumed && (immutable || entry.segment == .advertisement) { metadata.immutable.insert(entry.id) }
        try compactConsumed()
    }
    public mutating func checkpoint(position: Double) throws { guard position.isFinite, position >= 0 else { throw QueueError.invalidState }; self.position = position }
    public mutating func select(_ id: UUID) throws {
        guard let e = entries.first(where: { $0.id == id }), !e.consumed, e.segment != .advertisement, !metadata.immutable.contains(id) else { throw QueueError.immutable }
        guard let destination = entries.firstIndex(where: { $0.id == id }) else { throw QueueError.missingOccurrence }
        guard !entries.prefix(destination).contains(where: { !$0.consumed && ($0.segment == .advertisement || metadata.immutable.contains($0.id)) }) else { throw QueueError.immutable }
        for index in 0..<destination where !entries[index].consumed {
            let previous = entries[index]
            entries[index] = try QueueEntry(id: previous.id, media: previous.media, segment: previous.segment, originalOrder: previous.originalOrder, consumed: true)
        }
        current = id; position = 0; playbackToken = UUID(); intent = .play
        updateContextCursor(); try compactConsumed()
    }
    public mutating func previousItem() throws {
        guard let current, let index = entries.firstIndex(where: { $0.id == current }), index > 0 else { return }
        let target = entries[index - 1]
        guard target.segment != .advertisement, !metadata.immutable.contains(target.id), target.segment != .history else { throw QueueError.immutable }
        entries[index - 1] = try QueueEntry(id: target.id, media: target.media, segment: target.segment, originalOrder: target.originalOrder)
        try select(target.id)
    }
    public mutating func nextItem(repeatSupported: Bool) throws {
        guard let entry = entries.first(where: { $0.id == current }) else { return }
        guard entry.segment != .advertisement, entry.segment != .history, !metadata.immutable.contains(entry.id) else { throw QueueError.immutable }
        _ = try ended(token: playbackToken, repeatSupported: repeatSupported, repeatCurrent: false)
    }
    @discardableResult public mutating func ended(token: UUID, repeatSupported: Bool, repeatCurrent: Bool = true) throws -> Bool {
        guard token == playbackToken, let current, let index = entries.firstIndex(where: { $0.id == current }) else { return false }
        let old = entries[index]
        metadata.lastMedia = old.media.rawValue
        if repeatCurrent && repeatMode == .one && repeatSupported && old.segment != .advertisement && !metadata.immutable.contains(old.id) {
            position = 0; playbackToken = UUID(); intent = .play; return true
        }
        // Consumed non-ad immutable items become non-repeatable history before their
        // immutable-ID metadata expires. Consumed advertisements retain their segment.
        let segment: QueueSegment = metadata.immutable.contains(old.id) && old.segment != .advertisement ? .history : old.segment
        entries[index] = try QueueEntry(id: old.id, media: old.media, segment: segment, originalOrder: old.originalOrder, consumed: true)
        if !entries.contains(where: { !$0.consumed }), repeatMode == .all, repeatSupported {
            entries = try entries.map { e in
                guard e.segment != .advertisement, !metadata.immutable.contains(e.id), e.segment != .recommendation, e.segment != .history else { return e }
                return try QueueEntry(id: e.id, media: e.media, segment: e.segment, originalOrder: e.originalOrder)
            }
            metadata.contextCursor = 0
        }
        self.current = entries.first(where: { !$0.consumed })?.id
        exhaustedToken = self.current == nil ? token : nil
        position = 0; playbackToken = UUID()
        // Natural exhaustion preserves active play intent for late arrivals. Explicit
        // pauses and cold restoration never acquire that intent from an end event.
        updateContextCursor(); try compactConsumed()
        return true
    }
    public func previewNext(repeatSupported: Bool = true) throws -> QueueSnapshot {
        var copy = self
        guard intent == .play, try copy.ended(token: playbackToken, repeatSupported: repeatSupported) else { throw QueueError.invalidState }
        return try copy.snapshot
    }
    mutating func clearHandoff() { metadata.handoff = nil }
    mutating func reserveHandoff(repeatSupported: Bool) throws -> QueueHandoff? {
        if let existing = metadata.handoff { return existing }
        guard let currentEntry = entries.first(where: { $0.id == current }), currentEntry.segment != .advertisement,
              !metadata.immutable.contains(currentEntry.id), let next = try previewNext(repeatSupported: repeatSupported).current,
              next.segment != .advertisement, !metadata.immutable.contains(next.id) else { return nil }
        let plan = QueueHandoff(id: UUID(), currentToken: playbackToken, nextToken: UUID(), nextOccurrence: next.id, sourceVersion: version)
        metadata.handoff = plan; return plan
    }
    mutating func adoptHandoff(_ plan: QueueHandoff, position: Double, started: Date?, ended: Date, repeatSupported: Bool) throws {
        guard metadata.handoff == plan, playbackToken == plan.currentToken, intent == .play,
              try previewNext(repeatSupported: repeatSupported).current?.id == plan.nextOccurrence, let old = current else { throw QueueError.staleContext }
        if let started { try recordListening(occurrence: old, started: started, ended: max(started, ended)) }
        _ = try self.ended(token: plan.currentToken, repeatSupported: repeatSupported)
        playbackToken = plan.nextToken; metadata.handoff = nil
        try checkpoint(position: position)
    }
    public mutating func recordFailure(token: UUID, reason: QueueFailureReason, at: Date) {
        guard token == playbackToken, !metadata.historyPaused,
              let entry = entries.first(where: { $0.id == current }) else { return }
        var failures = metadata.failures ?? []
        failures.append(LocalPlaybackFailure(occurrence: entry.id, media: entry.media.rawValue, reason: reason, at: at))
        metadata.failures = Array(failures.suffix(Self.historyLimit))
    }
    public mutating func recordListening(occurrence: UUID, started: Date, ended: Date) throws {
        guard ended >= started, started.timeIntervalSince1970.isFinite, ended.timeIntervalSince1970.isFinite,
              let e = entries.first(where: { $0.id == occurrence }), e.segment != .advertisement else { throw QueueError.invalidState }
        guard !metadata.historyPaused else { return }
        metadata.recent.append(.init(occurrence: occurrence, media: e.media.rawValue, started: started, ended: ended))
        metadata.recent = Array(metadata.recent.suffix(Self.historyLimit))
    }
    public mutating func history(paused: Bool) { metadata.historyPaused = paused }
    public mutating func clearLocalHistory() { metadata.recent = []; metadata.failures = nil }
    /// Undo edits only; transport/consumption never rewind. A playback transition clears the command owner's undo stack.
    mutating func restoreEdit(_ old: QueueMachine) {
        let revision = version; let position = position; let recent = metadata.recent; let paused = metadata.historyPaused; let preference = metadata.preference
        self = old; version = revision; self.position = position; metadata.recent = recent; metadata.historyPaused = paused; metadata.preference = preference
    }
}
struct QueueRandom {
    var seed: UInt64
    mutating func next() -> UInt64 { seed &+= 0x9e3779b97f4a7c15; var z = seed; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9; z = (z ^ (z >> 27)) &* 0x94d049bb133111eb; return z ^ (z >> 31) }
}
