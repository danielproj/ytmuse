import Foundation
import Testing
import Domain
import Persistence
import Features
@testable import Queue

func request(_ channel: String = "queue-synthetic", generation: UInt64 = 1) throws -> RequestContext {
    try RequestContext(account: AccountContext(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, channelID: ID(channel), region: "US"), accountGeneration: generation, requestGeneration: 1)
}
func ids(_ values: [String]) throws -> [ServiceID] { try values.map(ServiceID.init) }
func make(_ values: [String] = ["a", "b", "a", "c"]) throws -> QueueMachine {
    var q = QueueMachine(account: try request().account!, supportsAutoplay: true)
    try q.replaceContext(ids(values), source: ServiceID("synthetic-album"))
    return q
}
actor MemoryPersistence: QueuePersistence {
    var stored: QueueSnapshot?; var fails = false; var saves = 0
    func setFailure(_ value: Bool) { fails = value }
    func load(context: RequestContext) -> QueueSnapshot? { stored }
    func save(_ snapshot: QueueSnapshot, context: RequestContext) throws { if fails { throw QueueError.invalidState }; stored = snapshot; saves += 1 }
}
actor RecordingPlayback: QueuePlaybackBoundary {
    var selections: [UUID] = []; var pauses = 0
    func select(_ entry: QueueEntry, token: UUID, context: RequestContext, origin: CommandOrigin) { selections.append(entry.id) }
    func pause(context: RequestContext, origin: CommandOrigin) { pauses += 1 }
}
func commands(_ q: QueueMachine, store: MemoryPersistence = MemoryPersistence(), playback: RecordingPlayback = RecordingPlayback()) throws -> QueueCommands {
    try QueueCommands(machine: q, context: request(), persistence: store, playback: playback, repeatSupported: true)
}

@Suite struct QueueRulesTests {
    @Test func T051PrecedenceAndDuplicates() throws {
        var q = try make(); let initial = q.entries.map(\.id)
        try q.insert(ids(["next-1", "next-2"]), next: true)
        try q.insert(ids(["new-1", "new-2"]), next: true)
        try q.recommend(ids(["auto"]), source: .init(source: "radio"))
        try q.insert(ids(["tail", "tail"]), next: false)
        #expect(q.entries.map(\.media.rawValue) == ["a", "new-1", "new-2", "next-1", "next-2", "b", "a", "c", "tail", "tail", "auto"])
        #expect(Set(q.entries.map(\.id)).count == 11)
        #expect(initial.allSatisfy { id in q.entries.contains { $0.id == id } })
        #expect(q.entries[1].segment == .playNext && q.entries[8].segment == .addToQueue)
    }
    @Test(arguments: [UInt64(1), 42, 314159, 0, UInt64.max]) func T052SeededDuplicateHeavy(seed: UInt64) throws {
        var random = QueueRandom(seed: seed)
        for _ in 0..<40 {
            let values = (0..<150).map { _ in "track-\(random.next() % 7)" }
            var q = try make(values); let original = q.entries
            try q.insert(ids(["extra", "extra", "extra"]), next: true)
            let current = q.current; let added = q.entries.filter { $0.segment == .playNext }.map(\.id)
            var deterministic = q
            q.shuffle(seed); deterministic.shuffle(seed)
            #expect(q.entries.map(\.id) == deterministic.entries.map(\.id))
            #expect(q.entries.filter { $0.segment == .context }.map(\.id) != original.map(\.id))
            #expect(q.current == current)
            #expect(q.entries.filter { $0.segment == .playNext }.map(\.id) == added)
            #expect(Set(q.entries.map(\.id)).count == 153)
            #expect(Set(q.entries.filter { $0.segment == .context }.map(\.id)) == Set(original.map(\.id)))
            // Consume current, all three explicit additions and TWO shuffled context
            // occurrences, including originals far away from the source prefix.
            for _ in 0..<6 { _ = try q.ended(token: q.playbackToken, repeatSupported: true) }
            let consumedSlots = q.entries.enumerated().filter { $0.element.consumed && $0.element.segment == .context }
            #expect(consumedSlots.count == 3)
            #expect(consumedSlots.filter { $0.element.originalOrder != 0 }.count == 2)
            let consumed = Set(q.entries.filter(\.consumed).map(\.id)); let active = q.current
            q.shuffle(nil)
            #expect(q.current == active)
            for (slot, entry) in consumedSlots { #expect(q.entries[slot].id == entry.id && q.entries[slot].consumed) }
            #expect(try q.snapshot.upcoming.allSatisfy { !consumed.contains($0.id) })
            #expect(Set(q.entries.filter(\.consumed).map(\.id)) == consumed)
            let eligible = q.entries.filter { !$0.consumed && $0.id != active && $0.segment == .context }
            #expect(eligible.map(\.id) == original.filter { !consumed.contains($0.id) && $0.id != active }.map(\.id))
            #expect(q.entries.filter { $0.segment == .playNext }.map(\.id) == added)
        }
    }
    @Test func T053ReplacementPreference() throws {
        var q = try make(); try q.insert(ids(["pending", "pending"]), next: true)
        #expect(throws: QueueError.confirmationRequired) { try q.replaceContext(ids(["new"]), source: ServiceID("album-2")) }
        #expect(q.entries.count == 6)
        try q.replaceContext(ids(["new", "context"]), source: ServiceID("album-2"), decision: .keep, remember: true)
        #expect(q.entries.map(\.media.rawValue) == ["new", "pending", "pending", "context"])
        try q.replaceContext(ids(["third"]), source: ServiceID("album-3"))
        #expect(q.entries.count == 3 && q.metadata.preference == .keep)
        let other = QueueMachine(account: try request("another-channel").account!, supportsAutoplay: true)
        #expect(other.metadata.preference == .ask)
        q.setPreference(.ask)
        #expect(throws: QueueError.confirmationRequired) { try q.replaceContext(ids(["x"]), source: ServiceID("x")) }
        try q.replaceContext(ids(["x"]), source: ServiceID("x"), decision: .replace)
        #expect(q.entries.count == 1 && q.metadata.preference == .ask)
    }
    @Test func T053EditableSegmentsAndProtectedSlots() throws {
        var q = try make(); try q.insert(ids(["tail"]), next: false)
        let tail = q.entries.last!.id, before = q.entries[1].id
        try q.move([tail], before: before)
        #expect(q.entries[1].id == tail)
        let ad = try QueueEntry(media: ServiceID("source-ad"), segment: .advertisement, originalOrder: 99, consumed: true)
        try q.appendService(ad, immutable: true)
        let slot = q.entries.firstIndex { $0.id == ad.id }
        #expect(throws: QueueError.immutable) { try q.move([ad.id], before: before) }
        #expect(throws: QueueError.immutable) { try q.remove([ad.id]) }
        #expect(throws: QueueError.immutable) { try q.move([before], before: nil) }
        q.clearUpcoming()
        #expect(q.entries.contains { $0.id == ad.id && $0.consumed })
        #expect(slot != nil)
    }
    @Test func T055Autoplay() throws {
        var q = try make(["a"])
        #expect(q.autoplay)
        try q.recommend(ids(["a", "b", "b", "c"]), source: .init(source: "seed-radio", cursor: "page-2"))
        #expect(q.entries.map(\.media.rawValue) == ["a", "b", "c"])
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        let playing = q.current
        try q.setAutoplay(false)
        #expect(q.entries.count == 2 && q.current == playing && q.entries[0].consumed)
        #expect(q.metadata.recommendationSources[playing!]?.source == "seed-radio")
        try q.recommend(ids(["d"]), source: .init(source: "radio"))
        #expect(q.entries.count == 2)
    }
    @Test func T055RepeatAndDuplicateEnd() throws {
        var q = try make(["a", "a"])
        try q.setRepeat(.one, supported: true)
        let token = q.playbackToken, current = q.current
        #expect(try q.ended(token: token, repeatSupported: true))
        #expect(q.current == current && !q.entries[0].consumed && token != q.playbackToken)
        #expect(try !q.ended(token: token, repeatSupported: true))
        try q.setRepeat(.all, supported: true)
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        #expect(q.current == q.entries[1].id)
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        #expect(q.current == current && q.entries.allSatisfy { !$0.consumed })
        try q.setRepeat(.off, supported: true)
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        #expect(q.current == nil)
    }
    @Test func serviceRestrictionsNeverReplayAds() throws {
        var q = try make(["a"])
        let ad = try QueueEntry(media: ServiceID("source-ad"), segment: .advertisement, originalOrder: 1)
        try q.appendService(ad, immutable: true)
        #expect(throws: QueueError.immutable) { try q.replaceContext(ids(["x"]), source: ServiceID("x")) }
        try q.setRepeat(.all, supported: true)
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        #expect(q.current == ad.id)
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        #expect(q.current == q.entries[0].id && q.entries[1].consumed)
        #expect(throws: QueueError.immutable) { try q.select(ad.id) }
        #expect(throws: QueueError.unsupported) { try q.setRepeat(.one, supported: false) }
    }
    @Test func boundedActualHistory() throws {
        var q = try make(); let id = q.current!
        for i in 0..<130 { try q.recordListening(occurrence: id, started: Date(timeIntervalSince1970: Double(i)), ended: Date(timeIntervalSince1970: Double(i + 1))) }
        #expect(q.metadata.recent.count == 100 && q.metadata.recent.first?.started == Date(timeIntervalSince1970: 30))
        q.history(paused: true)
        try q.recordListening(occurrence: id, started: .distantPast, ended: .distantFuture)
        #expect(q.metadata.recent.count == 100)
        q.clearLocalHistory(); #expect(q.metadata.recent.isEmpty)
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        #expect(q.metadata.recent.isEmpty) // advancing does not manufacture a listening event
    }
}

@Suite struct QueueAdditionalProperties {
    @Test(arguments: [UInt64(7), 211, 65537]) func duplicateInsertions(seed: UInt64) throws {
        var random = QueueRandom(seed: seed)
        var q = try make(["start", "context", "context"])
        try q.recommend(ids(["auto-1", "auto-2"]), source: .init(source: "synthetic-radio"))
        var oracle = ["start", "context", "context", "auto-1", "auto-2"]
        for _ in 0..<80 {
            let media = (0..<(Int(random.next() % 5) + 1)).map { _ in "duplicate-\(random.next() % 3)" }
            let next = random.next() % 2 == 0
            try q.insert(ids(media), next: next)
            oracle.insert(contentsOf: media, at: next ? 1 : oracle.firstIndex(of: "auto-1")!)
            #expect(q.entries.map(\.media.rawValue) == oracle)
            #expect(Set(q.entries.map(\.id)).count == oracle.count)
            #expect(q.entries.suffix(2).map(\.media.rawValue) == ["auto-1", "auto-2"])
        }
    }
    @Test func selectedLaterOccurrenceCannotRewindOrSkipAd() throws {
        var q = try make(); let selected = q.entries[2].id
        try q.select(selected)
        try q.insert(ids(["next"]), next: true)
        #expect(q.entries[3].media.rawValue == "next")
        #expect(q.entries.prefix(2).allSatisfy { $0.consumed })
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        #expect(q.entries.first { $0.id == q.current }?.media.rawValue == "next")
        let ad = try QueueEntry(media: ServiceID("ad"), segment: .advertisement, originalOrder: 99)
        try q.appendService(ad, immutable: true)
        try q.insert(ids(["after-ad"]), next: false)
        #expect(throws: QueueError.immutable) { try q.select(q.entries.last!.id) }
    }
    @Test func unsupportedAutoplayAndInvalidPosition() throws {
        var q = QueueMachine(account: try request().account!, supportsAutoplay: false)
        #expect(!q.autoplay)
        #expect(throws: QueueError.unsupported) { try q.setAutoplay(true) }
        for value in [Double.nan, .infinity, -1] { #expect(throws: QueueError.invalidState) { try q.checkpoint(position: value) } }
    }
}

@Suite struct QueueReviewRegressions {
    @Test func repeatAfterReplacementDoesNotResurrectOldContext() throws {
        var q = try make(["old", "old-2"])
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        let consumed = q.entries[0].id
        try q.replaceContext(ids(["new"]), source: ServiceID("new-source"))
        try q.setRepeat(.all, supported: true)
        _ = try q.ended(token: q.playbackToken, repeatSupported: true)
        #expect(q.entries.first { $0.id == consumed }?.consumed == true)
        #expect(q.entries.first { $0.id == q.current }?.media.rawValue == "new")
    }
    @Test func movingRecommendationPromotesItWithoutPuttingDeliberateItemsAfterAutoplay() throws {
        var q = try make(["a", "b"])
        try q.recommend(ids(["r1", "r2", "r3"]), source: .init(source: "radio"))
        let promoted = q.entries.last!.id
        try q.move([promoted], before: q.entries[1].id)
        #expect(q.entries[1].id == promoted && q.entries[1].segment == .addToQueue)
        let deliberate = q.entries[2].id
        try q.move([deliberate], before: nil)
        #expect(q.entries.map(\.media.rawValue) == ["a", "r3", "b", "r1", "r2"])
        try q.setAutoplay(false)
        #expect(q.entries.map(\.media.rawValue) == ["a", "r3", "b"])
    }
}
