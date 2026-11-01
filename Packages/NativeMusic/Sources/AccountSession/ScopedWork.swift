import Foundation
import Domain

/// Search/mutation/download tasks register cancellation with the same active owner.
/// Cancellation is advisory: consumers must also gate every late completion.
public actor ScopedAccountWork: AccountLifecycleParticipant {
    public nonisolated let participantID = "scoped-work"
    private var active: RequestContext?
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    public init() {}
    public func register(context: RequestContext, cancel: @escaping @Sendable () -> Void) throws -> UUID {
        guard accepts(context) else { cancel(); throw DomainError.staleContext }
        let id = UUID(); cancellations[id] = cancel; return id
    }
    public func finish(_ id: UUID) { cancellations[id] = nil }
    public func accepts(_ context: RequestContext) -> Bool {
        guard let active else { return false }
        return active.account != nil && active.account == context.account && active.accountGeneration == context.accountGeneration
    }
    public func detach(previous: RequestContext, barrier: RequestContext) {
        guard active.map({ barrier.accountGeneration > $0.accountGeneration }) ?? true else { return }
        active = barrier
        let pending = cancellations.values; cancellations.removeAll()
        for cancel in pending { cancel() }
    }
    public func restorePaused(_ identity: LocalIdentity, context: RequestContext) {
        guard active.map({ context.accountGeneration > $0.accountGeneration }) ?? true else { return }
        active = context
    }
    public func removeLocal(_ account: AccountContext, context: RequestContext) {
        detach(previous: active ?? context, barrier: context)
    }
}

/// Command-layer bridge used when playback/mutation and system modules are composed.
/// The supplied system sink clears Now Playing, remote command targets, timers and
/// extension snapshots. It must complete before another owner can restore paused.
public protocol AccountSystemOwnership: Actor {
    func detach(barrier: RequestContext) async throws
    func restorePaused(context: RequestContext) async throws
    func removeLocal(_ account: AccountContext, barrier: RequestContext) async throws
}
public actor CommandAccountParticipant: AccountLifecycleParticipant {
    public nonisolated let participantID = "commands-and-system"
    private let playback: PlaybackCommands
    private let mutations: MutationCommands
    private let system: any AccountSystemOwnership
    public init(playback: PlaybackCommands, mutations: MutationCommands, system: any AccountSystemOwnership) {
        self.playback = playback; self.mutations = mutations; self.system = system
    }
    public func detach(previous: RequestContext, barrier: RequestContext) async throws {
        // Domain's account switch stops audio and checkpoints the previous snapshot.
        await mutations.switchAccount(barrier)
        await playback.switchAccount(barrier)
        try await system.detach(barrier: barrier)
    }
    public func restorePaused(_ identity: LocalIdentity, context: RequestContext) async throws {
        await mutations.switchAccount(context); await playback.switchAccount(context)
        try await system.restorePaused(context: context)
    }
    public func removeLocal(_ account: AccountContext, context: RequestContext) async throws {
        try await system.removeLocal(account, barrier: context)
    }
}
