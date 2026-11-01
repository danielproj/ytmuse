import Foundation
import Testing
import Domain
@testable import Queue

private actor PauseSampleBoundary: QueuePlaybackBoundary {
    var pauses = 0
    func position(for snapshot: QueueSnapshot, context: RequestContext) -> Double? { 8 }
    func select(_ entry: QueueEntry, token: UUID, context: RequestContext, origin: CommandOrigin) {}
    func pause(context: RequestContext, origin: CommandOrigin) { pauses += 1 }
}
@Suite struct PlaybackReworkQueueTests {
    @Test func explicitNextRepeatAllNeverResurrectsProtectedEntries() throws {
        var q = try make(["a", "b"])
        try q.setRepeat(.all, supported: true)
        let protected = try [QueueSegment.advertisement, .history, .recommendation].enumerated().map { offset, segment in
            try QueueEntry(id: UUID(), media: ServiceID("protected-\(offset)"), segment: segment, originalOrder: offset + 2, consumed: true)
        }
        for entry in protected { try q.appendService(entry, immutable: entry.segment == .history) }
        try q.nextItem(repeatSupported: true); try q.nextItem(repeatSupported: true)
        #expect(try q.snapshot.current?.media.rawValue == "a")
        #expect(q.entries.filter { protected.map(\.id).contains($0.id) }.allSatisfy { $0.consumed })
    }
    @Test(arguments: [true, false]) func explicitNextCannotSkipRequiredCurrent(advertisement: Bool) throws {
        var q = try make(["a"])
        try q.setRepeat(.all, supported: true)
        let entry = try QueueEntry(id: UUID(), media: ServiceID("required"), segment: advertisement ? .advertisement : .context, originalOrder: 1)
        try q.appendService(entry, immutable: true)
        try q.nextItem(repeatSupported: true)
        #expect(q.current == entry.id)
        #expect(throws: QueueError.immutable) { try q.nextItem(repeatSupported: true) }
        #expect(q.current == entry.id && q.entries.contains { $0.id == entry.id && !$0.consumed })
    }
    @Test func failedPauseCommitDoesNotPublishCapturedPositionOrIntent() async throws {
        let context = try request(); let store = MemoryPersistence(); let playback = PauseSampleBoundary()
        let owner = try QueueCommands(machine: make(), context: context, persistence: store, playback: playback, repeatSupported: true)
        let old = try await owner.snapshot()
        await store.setFailure(true)
        await #expect(throws: QueueError.invalidState) { _ = try await owner.execute(.pause(.user), context: context, origin: .menu) }
        let after = try await owner.snapshot()
        #expect(after.session.position == old.session.position && after.session.version == old.session.version && after.intent == old.intent && after.playbackToken == old.playbackToken)
        #expect(await playback.pauses == 0)
    }
}
