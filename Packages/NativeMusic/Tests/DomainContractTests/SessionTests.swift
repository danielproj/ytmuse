import Foundation
import Domain
import Testing

actor TestAccounts: AccountService {
    var holdFirst = true
    var continuation: CheckedContinuation<Void, Never>?
    var revoked: AccountContext?
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func model(_ context: RequestContext) -> ServiceResult<Account> {
        guard let a = context.account else { return .init(context: context, outcome: .failure(.unauthorized)) }
        return .init(context: context, outcome: .success(try! Account(id: a.accountID, serviceIdentity: sid("synthetic-identity"), context: a, displayName: "Synthetic", credential: nil)))
    }
    func identities(context: RequestContext) -> ServiceResult<[Account]> { .init(context: context, outcome: .success([])) }
    func authenticate(context: RequestContext) -> ServiceResult<Account> { model(context) }
    func refresh(context: RequestContext) -> ServiceResult<Account> { model(context) }
    func capabilities(context: RequestContext) -> ServiceResult<AccountCapabilities> { .init(context: context, outcome: .failure(.unsupported)) }
    func switchIdentity(to account: AccountContext, context: RequestContext) async -> ServiceResult<Account> {
        if holdFirst { holdFirst = false; await withCheckedContinuation { continuation = $0 } }
        return model(context)
    }
    func revoke(context: RequestContext) -> ServiceResult<Void> { revoked = context.account; return .init(context: context, outcome: .success(())) }
    func removeLocalIdentity(_ account: AccountContext, context: RequestContext) -> ServiceResult<Void> { revoked = account; return .init(context: context, outcome: .success(())) }
}
@Suite("T02.2 Session commands") struct SessionTests {
    @Test func lateIdentityCannotReplaceNewerAccountAndSignOutDetachesCommands() async throws {
        let a = try account(); let b = try account(); let c = try account()
        let context = request(a); let engine = TestEngine(); let player = try commands(context, engine: engine)
        let backend = TestMutations()
        let mutations = MutationCommands(context: context, capabilities: TestProvider(account: a), library: backend, playlists: backend, outbox: backend, clock: FixedWall(date: testWall))
        let accounts = TestAccounts()
        let sessions = SessionCommands(context: context, accounts: accounts, playback: player, mutations: mutations)
        let first = Task { await sessions.switchAccount(to: b) }
        for _ in 0..<10_000 { if await accounts.waiting() { break }; await Task.yield() }
        #expect(await accounts.waiting())
        let second = await sessions.switchAccount(to: c)
        #expect(try second.outcome.get()?.context == c)
        await accounts.release()
        let late = await first.value
        #expect(throws: DomainError.staleContext) { try late.outcome.get() }
        let active = await sessions.context()
        #expect(active.account == c && active.accountGeneration == 3)
        #expect(await player.snapshot().context.request == active)
        #expect(await player.snapshot().pauseReason == .accountSwitch)
        let signedOut = await sessions.execute(.revoke, context: active, origin: .userInterface)
        _ = try signedOut.outcome.get()
        #expect(await sessions.context().account == nil)
        #expect(await player.snapshot().context.request.account == nil)
        #expect(await accounts.revoked == c)
        let stale = await player.execute(.play, context: active, origin: .mediaKey)
        #expect(throws: DomainError.staleContext) { try stale.outcome.get() }
    }
}
