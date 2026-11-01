import Testing
import Foundation
import Domain
import AccountSession
@testable import AppShell
@testable import Playback

extension NativePlaybackTests {
    @Test func T061ActualAppCompositionSQLiteRestoreAndAccountBarrier() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("W06-composition-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authority = AppPlaybackAuthority(directory: directory, offlineVault: try isolatedOwnedVault(in: directory))
        let first = try await authority.owned(request: authority.requestOwnedStart(), initialGain: 0.001, maximumStartGain: 0.001)
        #expect(try await first.snapshot().playback.state == .idle)
        try await first.startOwnedMedia(OwnedMedia.items)
        try await first.seek(5)
        try await first.pause()
        let old = try await first.snapshot()
        let second = try await authority.owned(request: authority.requestOwnedStart(), initialGain: 0.001, maximumStartGain: 0.001)
        let restored = try await second.snapshot()
        #expect(restored.queue.current?.id == old.queue.current?.id)
        #expect(abs(restored.queue.session.position - 5) < 0.15)
        #expect(restored.queue.intent == .pause(.restored))
        #expect(restored.playback.state == .idle)
        #expect(restored.playback.context.request.accountGeneration > old.playback.context.request.accountGeneration)
        await #expect(throws: DomainError.staleContext) { try await first.resume() }
        try await authority.detach(previous: restored.playback.context.request, barrier: .init(account: nil, accountGeneration: 100, requestGeneration: 0))
        await #expect(throws: DomainError.staleContext) { try await second.resume() }
    }
}
