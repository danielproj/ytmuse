import Testing
import Foundation
import Domain
import AccountSession

actor CompletionPromise {
    private var continuation: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; ready?.resume(); ready = nil }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
actor BlockingParticipant: AccountLifecycleParticipant {
    nonisolated let participantID = "blocking"
    let promise = CompletionPromise()
    private var held = true
    func detach(previous: RequestContext, barrier: RequestContext) async {
        if held { held = false; await promise.wait() }
    }
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) {}
    func removeLocal(_ account: AccountContext, context: RequestContext) {}
}
@Suite("T04 deterministic out-of-order races") struct RaceTests {
    @Test func suspendedSearchMutationDownloadResultsCannotCrossOwners() async throws {
        let vault = try testVault(); let store = MemoryDirectory(); let work = ScopedAccountWork()
        let lifecycle = try AccountLifecycle(directory: .init(), vault: vault, store: store, participants: [work])
        let a = try identity(); let b = try identity("b")
        try await connect(lifecycle, a); try await connect(lifecycle, b)
        for turn in 0..<12 {
            try await lifecycle.switchIdentity(to: turn.isMultiple(of: 2) ? a.context : b.context)
            let old = await lifecycle.snapshot().context
            let promises = (0..<3).map { _ in CompletionPromise() }
            var tasks: [Task<Bool, Never>] = []
            for promise in promises {
                let task = Task {
                    // Deliberately ignore cancellation, like a late provider response.
                    await promise.wait()
                    let workAccepts = await work.accepts(old)
                    let sessionAccepts = await lifecycle.accepts(old)
                    return workAccepts && sessionAccepts
                }
                tasks.append(task)
                _ = try await work.register(context: old) { task.cancel() }
                await promise.started()
            }
            try await lifecycle.switchIdentity(to: turn.isMultiple(of: 2) ? b.context : a.context)
            for index in [2, 0, 1] { await promises[index].finish(); #expect(await tasks[index].value == false) }
            #expect(await work.accepts(lifecycle.snapshot().context))
        }
        try await lifecycle.remove(a.context); try await lifecycle.remove(b.context)
        try await vault.destroyIsolatedTestKeychain()
    }
    @Test func simultaneousLifecycleActionsSerializeAndExposeDetachedOwner() async throws {
        let vault = try testVault(); let store = MemoryDirectory(); let participant = BlockingParticipant()
        let lifecycle = try AccountLifecycle(directory: .init(), vault: vault, store: store, participants: [participant])
        let a = try identity(); let b = try identity("b")
        try await connect(lifecycle, a); try await connect(lifecycle, b)
        let switching = Task { try await lifecycle.switchIdentity(to: a.context) }
        await participant.promise.started()
        #expect(await lifecycle.snapshot().context.account == nil)
        await #expect(throws: LifecycleError.busy) { try await lifecycle.switchIdentity(to: b.context) }
        await #expect(throws: LifecycleError.busy) { try await lifecycle.remove(a.context) }
        await participant.promise.finish(); try await switching.value
        #expect(await lifecycle.snapshot().context.account == a.context)
        try await lifecycle.switchIdentity(to: b.context)
        #expect(await lifecycle.snapshot().context.account == b.context)
        try await lifecycle.remove(a.context); try await lifecycle.remove(b.context)
        try await vault.destroyIsolatedTestKeychain()
    }
}
