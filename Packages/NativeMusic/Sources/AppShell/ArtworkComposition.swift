import Foundation
import AppKit
import Domain
import Artwork
import Features
import AccountSession

/// Fail closed until a reviewed account-owned adapter is injected. No endpoint or fixture grant.
public struct UnconnectedArtworkSource: ArtworkSource {
    public init() {}
    public func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData { throw DomainError.unsupported }
}
/// One shared foreground pipeline/authority is composed per application, not per window/view.
public actor ArtworkAccountParticipant: AccountLifecycleParticipant {
    public nonisolated let participantID = "foreground-artwork"
    private let pipeline: ArtworkPipeline
    private let presentation: ArtworkUIAuthority
    private var generation: UInt64 = 0
    private var wake: NSObjectProtocol?
    public init(pipeline: ArtworkPipeline, presentation: ArtworkUIAuthority) { self.pipeline = pipeline; self.presentation = presentation }
    public func start() async {
        await pipeline.startPressureMonitoring()
        try? await pipeline.purgeExpired()
        guard wake == nil else { return }
        let center = await MainActor.run { NSWorkspace.shared.notificationCenter }
        wake = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.purgeAfterWake() }
        }
    }
    /// POL-A: the decoded YouTube Music covers the bar and Now Playing hold (`WebCoverMemo`) go wherever the account's artwork goes.
    private static func dropDecodedCovers() async { await MainActor.run { WebCoverMemo.shared.removeAll() } }
    public func purgeAfterWake() async { try? await pipeline.purgeExpired() }
    public func stop() async {
        if let wake { let center = await MainActor.run { NSWorkspace.shared.notificationCenter }; center.removeObserver(wake); self.wake = nil }
        await Self.dropDecodedCovers()
        if generation < .max {
            generation += 1
            let barrier = RequestContext(account: nil, accountGeneration: generation, requestGeneration: 0)
            await presentation.bind(barrier)
            try? await pipeline.invalidateForeground(generation: generation)
        }
        await pipeline.stopPressureMonitoring()
    }
    public func detach(previous: RequestContext, barrier: RequestContext) async throws {
        // Retract delivered private pixels before another potentially slow participant suspends.
        await Self.dropDecodedCovers()
        await presentation.bind(barrier)
        try await pipeline.invalidateForeground(generation: barrier.accountGeneration)
        generation = barrier.accountGeneration
    }
    public func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {
        guard context.account == identity.id else { throw DomainError.staleContext }
        try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: identity.id), generation: context.accountGeneration)
        generation = context.accountGeneration
        await presentation.bind(context)
    }
    public func removeLocal(_ account: AccountContext, context: RequestContext) async throws {
        await Self.dropDecodedCovers()
        await presentation.removeAccount(account.accountID)
        try await pipeline.removeAccount(accountID: account.accountID)
    }
}
