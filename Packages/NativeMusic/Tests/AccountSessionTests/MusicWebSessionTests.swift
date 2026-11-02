import Foundation
import Testing
import Domain
import Features
@testable import AccountSession
import TestSupport

/// In-memory SessionVault with KeychainVault's generation semantics: reads and
/// in-place replacement require the exact bound active context.
private actor MemorySessionVault: SessionVault {
    var records: [AccountContext: [String: Data]] = [:]
    var active: RequestContext?
    var replacements = 0
    var failReads = false
    func breakReads() { failReads = true }
    /// A Keychain fault when the rotated record is written back (after a request the service already answered).
    var failReplace = false
    func breakReplace() { failReplace = true }
    /// When false, replace skips the generation check so tests prove the
    /// coordinator's own fence rather than the vault's.
    var enforce = true
    func lax() { enforce = false }
    func bind(_ context: RequestContext) {
        if let active, context.accountGeneration < active.accountGeneration { return }
        active = context
    }
    func insert(_ bytes: Data, for account: AccountContext) throws -> CredentialReference {
        let reference = try CredentialReference(UUID().uuidString)
        records[account, default: [:]][reference.rawValue] = bytes
        return reference
    }
    func read(_ reference: CredentialReference, context: RequestContext) throws -> Data {
        guard let active, active == context, let account = context.account else { throw DomainError.staleContext }
        if failReads { throw LifecycleError.keychain(errSecInteractionNotAllowed) }
        guard let bytes = records[account]?[reference.rawValue] else { throw LifecycleError.keychain(errSecItemNotFound) }
        return bytes
    }
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) throws {
        guard !enforce || active == context, let account = context.account else { throw DomainError.staleContext }
        if failReplace { throw LifecycleError.keychain(errSecInteractionNotAllowed) }
        guard records[account]?[reference.rawValue] != nil else { throw LifecycleError.keychain(errSecItemNotFound) }
        records[account]![reference.rawValue] = bytes; replacements += 1
    }
    func delete(_ reference: CredentialReference, for account: AccountContext) { records[account]?[reference.rawValue] = nil }
    func deleteAll(for account: AccountContext) { records[account] = nil }
    func values(_ account: AccountContext) -> [Data] { Array(records[account]?.values ?? [:].values) }
    func count() -> Int { records.values.reduce(0) { $0 + $1.count } }
    func replaced() -> Int { replacements }
}
private actor MemoryWebStores: MusicWebsiteDataStores {
    var removed: [UUID] = []
    var wiped: [UUID] = []
    var events: [String] = []
    var confirm = true
    /// Refuse this many removal attempts before confirming (lingering web process).
    var refusals = 0
    var hang = false
    func wipe(_ identifier: UUID) -> Bool { wiped.append(identifier); events.append("wipe"); return true }
    func remove(_ identifier: UUID) async -> Bool {
        if hang { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
        removed.append(identifier); events.append("remove")
        if refusals > 0 { refusals -= 1; return false }
        return confirm
    }
    func refuse(times: Int) { refusals = times }
    func hangForever() { hang = true }
    func wipes() -> [UUID] { wiped }
    func log() -> [String] { events }
    func refuse() { confirm = false }
    func accept() { confirm = true }
    func removals() -> [UUID] { removed }
}
private actor MemoryLedger: MusicSignInLedger {
    var ids: [UUID] = []
    var log: [String] = []
    var holdAdd = false
    var gate: CheckedContinuation<Void, Never>?
    func add(_ identifier: UUID) async {
        ids.append(identifier); log.append("add")
        if holdAdd { holdAdd = false; await withCheckedContinuation { gate = $0 } }
    }
    func holdNextAdd() { holdAdd = true }
    func addHeld() -> Bool { gate != nil }
    func releaseAdd() { gate?.resume(); gate = nil }
    func remove(_ identifier: UUID) { ids.removeAll { $0 == identifier }; log.append("remove") }
    func pending() -> [UUID] { ids }
    func seed(_ identifier: UUID) { ids.append(identifier) }
    func events() -> [String] { log }
}
private enum ReaderStep: Sendable { case identity(MusicAccountIdentity), library(MusicLibraryPlaylists), failure(MusicSessionError) }
private actor ScriptedReader: MusicSessionReading {
    var menu: ReaderStep
    var library: ReaderStep = .library(.init(playlists: [.init(id: "PLsynthetic", title: "Synthetic Mix", countText: "3 songs", itemCount: 3)], complete: true))
    var rotation: [MusicSessionCookie] = []
    var hold = false
    var holdLibrary = false
    var gate: CheckedContinuation<Void, Never>?
    var seen: [MusicCookieSession] = []
    init(_ menu: ReaderStep) { self.menu = menu }
    func set(menu: ReaderStep) { self.menu = menu }
    func set(library: ReaderStep) { self.library = library }
    func rotate(_ cookies: [MusicSessionCookie]) { rotation = cookies }
    func holdNext() { hold = true }
    func holdNextLibrary() { holdLibrary = true }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
    func sessions() -> [MusicCookieSession] { seen }
    func accountMenu(session: MusicCookieSession) async throws -> MusicSignedResult<MusicAccountIdentity> {
        seen.append(session)
        if hold { hold = false; await withCheckedContinuation { gate = $0 } }
        switch menu {
        case .identity(let value): return .init(value: value, rotation: rotation)
        case .failure(let error): throw error
        case .library: throw MusicSessionError.unrecognised
        }
    }
    func likedPlaylists(session: MusicCookieSession) async throws -> MusicSignedResult<MusicLibraryPlaylists> {
        if holdLibrary { holdLibrary = false; await withCheckedContinuation { gate = $0 } }
        switch library {
        case .library(let value): return .init(value: value, rotation: [])
        case .failure(let error): throw error
        case .identity: throw MusicSessionError.unrecognised
        }
    }
    func avatar(_ url: URL) async throws -> Data { throw MusicSessionError.unrecognised }
    // Search: records whether each call was signed (`session != nil`) or anonymous.
    var searchFailure: MusicSessionError?
    var holdSearch = false
    var searchCalls: [(query: String, signed: Bool)] = []
    func failSearch(_ error: MusicSessionError?) { searchFailure = error }
    func holdNextSearch() { holdSearch = true }
    func calls() -> [(query: String, signed: Bool)] { searchCalls }
    func search(query: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicSearchResponse> {
        searchCalls.append((query, session != nil))
        if holdSearch { holdSearch = false; await withCheckedContinuation { gate = $0 } }
        if let searchFailure, session != nil || searchFailure != .signedOut { throw searchFailure }
        let item = MusicSearchItem(kind: .song, title: session != nil ? "signed:" + query : "anonymous:" + query, subtitle: nil, videoID: "aaaaaaaaaa1")
        return .init(value: MusicSearchResponse(top: nil, items: [item], suggestion: nil, skippedRows: 0), rotation: session != nil ? rotation : [])
    }
    // Browse (W11): same scope rules as search.
    var browseFailure: MusicSessionError?
    var holdAnonymousBrowse = false
    func holdNextAnonymousBrowse() { holdAnonymousBrowse = true }
    var browseCalls: [(id: String, signed: Bool)] = []
    func failBrowse(_ error: MusicSessionError?) { browseFailure = error }
    func browses() -> [(id: String, signed: Bool)] { browseCalls }
    func browse(id: String, params: String?, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicBrowsePage> {
        browseCalls.append((id, session != nil))
        if holdSearch { holdSearch = false; await withCheckedContinuation { gate = $0 } }
        if session == nil, holdAnonymousBrowse { holdAnonymousBrowse = false; await withCheckedContinuation { gate = $0 } }
        if let browseFailure, session != nil || browseFailure != .signedOut { throw browseFailure }
        let shelf = MusicShelf(key: "k", title: session != nil ? "signed:" + id : "anonymous:" + id, layout: .carousel, items: [])
        return .init(value: MusicBrowsePage(shelves: [shelf]), rotation: session != nil ? rotation : [])
    }
    func continuation(token: String, session: MusicCookieSession?) async throws -> MusicSignedResult<MusicContinuationPage> {
        browseCalls.append((token, session != nil))
        return .init(value: MusicContinuationPage(items: [], shelves: [], continuation: nil), rotation: session != nil ? rotation : [])
    }
    // Library and writes (W12): signed only. Every call is recorded; nothing here is a transport.
    var libraryFailure: MusicSessionError?
    var holdLibraryRead = false
    var libraryCalls: [String] = []
    var writeCalls: [MusicWriteRequest] = []
    var writeOutcome: MusicWriteOutcome = .confirmed
    func failLibrary(_ error: MusicSessionError?) { libraryFailure = error }
    func holdNextLibraryRead() { holdLibraryRead = true }
    func libraryRequests() -> [String] { libraryCalls }
    func writes() -> [MusicWriteRequest] { writeCalls }
    func setWrite(_ outcome: MusicWriteOutcome) { writeOutcome = outcome }
    func library(id: String, session: MusicCookieSession) async throws -> MusicSignedResult<MusicBrowsePage> {
        libraryCalls.append(id)
        if holdLibraryRead { holdLibraryRead = false; await withCheckedContinuation { gate = $0 } }
        if let libraryFailure { throw libraryFailure }
        return .init(value: MusicBrowsePage(shelves: [MusicShelf(key: "k", title: "signed:" + id, layout: .list, items: [])]), rotation: rotation)
    }
    func libraryContinuation(token: String, session: MusicCookieSession) async throws -> MusicSignedResult<MusicContinuationPage> {
        libraryCalls.append(token)
        return .init(value: MusicContinuationPage(items: [], shelves: [], continuation: nil), rotation: rotation)
    }
    func write(_ request: MusicWriteRequest, session: MusicCookieSession) async throws -> MusicSignedResult<MusicWriteOutcome> {
        writeCalls.append(request)
        if holdLibraryRead { holdLibraryRead = false; await withCheckedContinuation { gate = $0 } }
        if let libraryFailure { throw libraryFailure }
        return .init(value: writeOutcome, rotation: rotation)
    }
}
@MainActor private final class ScriptedPresenter: MusicWebSignInPresenting {
    enum Outcome { case session, cancel, timeout }
    var outcome: Outcome = .session
    var accounts: [UUID] = []
    var stores: [UUID] = []
    /// Ledger contents observed when WebKit would construct the store.
    var ledgerAtBegin: [[UUID]] = []
    var ledger: MemoryLedger?
    var finished: [MusicSignInFailure?] = []
    var verified = 0
    func begin(store: UUID, account: UUID, now: @escaping @Sendable () -> Date) async throws -> MusicCookieSession {
        accounts.append(account); stores.append(store)
        if let ledger { ledgerAtBegin.append(await ledger.pending()) }
        switch outcome {
        case .session: return try webSession(account: account, now: now())
        case .cancel: throw CancellationError()
        case .timeout: throw MusicSessionError.timedOut
        }
    }
    func verifying() { verified += 1 }
    func finish(_ failure: MusicSignInFailure?) { finished.append(failure) }
}
private enum Marker {
    static let sapisid = "SYNTHETIC-LIFECYCLE-SAPISID", sid = "SYNTHETIC-LIFECYCLE-SID", rotated = "SYNTHETIC-LIFECYCLE-ROTATED"
    static let all = [sapisid, sid, rotated]
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
}
private struct StillClock: WallClock { func now() -> Date { Marker.now } }
private func webSession(account: UUID, now: Date) throws -> MusicCookieSession {
    func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: ".youtube.com", .path: "/", .expires: now.addingTimeInterval(86_400)])!
    }
    return try MusicCookieSession(accountID: account, cookies: [cookie("SAPISID", Marker.sapisid), cookie("SID", Marker.sid)], now: now)
}
private let listener = MusicAccountIdentity(serviceID: "UCsyntheticChannel000000", displayName: "Synthetic Listener",
                                            handle: "@synthetic-listener", photoURL: nil)
private struct Harness {
    let lifecycle: AccountLifecycle
    let coordinator: MusicSessionCoordinator
    let vault: MemorySessionVault
    let stores: MemoryWebStores
    let ledger: MemoryLedger
    let reader: ScriptedReader
    let presenter: ScriptedPresenter
    let work: ScopedAccountWork
}
@MainActor private func harness(_ menu: ReaderStep = .identity(listener)) async throws -> Harness {
    let vault = MemorySessionVault(), stores = MemoryWebStores(), ledger = MemoryLedger(), reader = ScriptedReader(menu), presenter = ScriptedPresenter()
    presenter.ledger = ledger
    let coordinator = MusicSessionCoordinator(vault: vault, reader: reader, stores: stores, ledger: ledger, presenter: presenter, clock: StillClock(), region: "GB",
                                              removalDelays: [.zero, .zero, .zero], pause: { _ in await Task.yield() })
    let work = ScopedAccountWork()
    let lifecycle = try await AccountLifecycle.open(vault: vault, store: MemoryDirectory(), participants: [coordinator, work])
    await coordinator.attach(to: lifecycle)
    return Harness(lifecycle: lifecycle, coordinator: coordinator, vault: vault, stores: stores, ledger: ledger, reader: reader, presenter: presenter, work: work)
}
private func signIn(_ h: Harness, for account: AccountContext? = nil) async throws {
    let challenge = try await h.lifecycle.beginAuthentication(for: account)
    do { try await h.coordinator.signIn(challenge); await h.coordinator.settleRemovals() }
    catch { await h.lifecycle.cancelAuthentication(challenge); await h.coordinator.settleRemovals(); throw error }
}

@Suite @MainActor struct MusicWebSessionTests {
    @Test func verifiedSignInInstallsActiveAccountWithKeychainRecordAsOnlyCredential() async throws {
        let h = try await harness()
        try await signIn(h)
        let snapshot = await h.lifecycle.snapshot()
        let identity = try #require(snapshot.directory.identities.first)
        #expect(snapshot.directory.identities.count == 1)
        #expect(identity.state == .connected && identity.account.displayName == "Synthetic Listener")
        #expect(identity.account.context.channelID.rawValue == "UCsyntheticChannel000000" && identity.account.context.region == "GB")
        #expect(identity.account.context.accountID == h.presenter.accounts.first)
        let store = try #require(h.presenter.stores.first)
        #expect(store != identity.id.accountID, "the attempt store is unrelated to the account UUID")
        #expect(h.presenter.ledgerAtBegin == [[store]], "the attempt ID is recorded before WebKit constructs the store")
        #expect(await h.stores.removals() == [store], "a successful install leaves no web store holding the Google session")
        let events = await h.ledger.events()
        #expect(await h.ledger.pending().isEmpty)
        #expect(events == ["add", "remove"])
        #expect(identity.account.credential != nil)
        #expect(snapshot.context.account == identity.id && snapshot.context.accountGeneration > 0, "handover: installed identity is the active owner")
        let stored = await h.vault.values(identity.id)
        #expect(stored.count == 1)
        #expect(try MusicCookieSession.decode(stored[0], accountID: identity.id.accountID).sapisid == Marker.sapisid)
        #expect(h.presenter.verified == 1 && h.presenter.finished == [nil])
        #expect(await h.coordinator.status() == .signedIn("Synthetic Listener"))
    }
    @Test func verificationFailuresInstallNothingAndDiscardTheFreshWebStore() async throws {
        let cases: [(MusicSessionError, MusicSignInFailure)] = [(.signedOut, .signedOut), (.unrecognised, .unrecognised),
                                                               (.network, .network), (.oversized, .unrecognised)]
        for (error, failure) in cases {
            let h = try await harness(.failure(error))
            await #expect(throws: error) { try await signIn(h) }
            #expect(await h.lifecycle.snapshot().directory.identities.isEmpty)
            #expect(await h.vault.count() == 0)
            #expect(await h.stores.removals() == h.presenter.stores)
            #expect(await h.ledger.pending().isEmpty)
            #expect(h.presenter.finished == [failure])
            #expect(await h.lifecycle.snapshot().reconnectPending == false)
        }
    }
    @Test func cancelAndTimeoutEndCleanly() async throws {
        for (outcome, failure) in [(ScriptedPresenter.Outcome.cancel, MusicSignInFailure?.none), (.timeout, .timedOut)] {
            let h = try await harness()
            h.presenter.outcome = outcome
            if outcome == .cancel { await #expect(throws: CancellationError.self) { try await signIn(h) } }
            else { await #expect(throws: MusicSessionError.timedOut) { try await signIn(h) } }
            #expect(await h.vault.count() == 0)
            #expect(await h.stores.removals() == h.presenter.stores)
            #expect(await h.ledger.pending().isEmpty)
            #expect(h.presenter.finished == [failure])
            #expect(await h.coordinator.status() == .signedOut)
        }
    }
    @Test func reconnectRequiresTheSameMusicAccountAndDuplicatesAreRefused() async throws {
        let h = try await harness()
        try await signIn(h)
        let account = try #require(await h.lifecycle.snapshot().directory.identities.first).id
        await #expect(throws: MusicSessionError.duplicateAccount) { try await signIn(h) }
        await h.reader.set(menu: .identity(.init(serviceID: "UCotherSyntheticAccount0", displayName: "Other", handle: nil, photoURL: nil)))
        await #expect(throws: MusicSessionError.differentAccount) { try await signIn(h, for: account) }
        #expect(h.presenter.accounts.last == account.accountID, "reconnect binds the session to the existing account")
        let stores = h.presenter.stores
        #expect(Set(stores).count == stores.count && !stores.contains(account.accountID), "every attempt, including reconnect, uses a new store ID")
        #expect(await h.stores.removals() == stores, "the different-account attempt's store (another person's session) is removed")
        #expect(await h.ledger.pending().isEmpty)
        await h.reader.set(menu: .identity(listener))
        try await signIn(h, for: account)
        let after = try #require(await h.lifecycle.snapshot().directory.identities.first)
        #expect(after.id == account && after.state == .connected)
        #expect(await h.vault.values(account).count == 1, "reconnect replaces, never accumulates, the exact record")
    }
    @Test func proofReadsIdentityAndLibraryAndWritesRotationBack() async throws {
        let h = try await harness()
        try await signIn(h)
        await h.reader.rotate([.init(name: "__Secure-3PSIDCC", value: Marker.rotated, expires: Marker.now.addingTimeInterval(3600))])
        guard case .signedIn(let proof) = await h.coordinator.proof() else { Issue.record("expected proof"); return }
        #expect(proof.identity == listener && proof.library.playlists.map(\.title) == ["Synthetic Mix"])
        let account = try #require(await h.lifecycle.snapshot().context.account)
        #expect(await h.vault.replaced() >= 1)
        let stored = try MusicCookieSession.decode(try #require(await h.vault.values(account).first), accountID: account.accountID)
        #expect(stored.cookieHeader.contains("__Secure-3PSIDCC=" + Marker.rotated) && stored.rotatedAt == Marker.now)
    }
    @Test func signedOutResponseExpiresWithoutDeletingLocalDataAndUnknownIsNotEmpty() async throws {
        let h = try await harness()
        try await signIn(h)
        let account = try #require(await h.lifecycle.snapshot().context.account)
        await h.reader.set(library: .failure(.unrecognised))
        #expect(await h.coordinator.proof() == .unrecognised)
        #expect(await h.lifecycle.snapshot().directory.identities.first?.state == .connected)
        await h.reader.set(library: .failure(.network))
        #expect(await h.coordinator.proof() == .failed(.network))
        await h.reader.set(menu: .failure(.signedOut))
        #expect(await h.coordinator.proof() == .expired)
        let snapshot = await h.lifecycle.snapshot()
        #expect(snapshot.directory.identities.first?.state == .expired)
        #expect(snapshot.directory.identities.first?.account.credential != nil)
        #expect(await h.vault.values(account).count == 1, "expiry keeps the local record until explicit sign-out")
        #expect(await h.coordinator.status() == .expired)
        #expect(await h.coordinator.proof() == .expired)
    }
    @Test func staleGenerationCannotPublishOrWriteRotation() async throws {
        let h = try await harness()
        await h.vault.lax()
        try await signIn(h)
        let first = try #require(await h.lifecycle.snapshot().context.account)
        await h.reader.rotate([.init(name: "__Secure-3PSIDCC", value: Marker.rotated, expires: Marker.now.addingTimeInterval(3600))])
        await h.reader.holdNext()
        let pending = Task { await h.coordinator.proof() }
        while !(await h.reader.waiting()) { await Task.yield() }
        try await h.lifecycle.signOut(first)
        await h.reader.release()
        #expect(await pending.value == .none)
        #expect(await h.vault.replaced() == 0)
        #expect(await h.vault.count() == 0)
        #expect(await h.stores.removals() == h.presenter.stores, "sign-out makes no WebKit call: only the attempt store was ever removed")
        #expect(await h.lifecycle.snapshot().directory.identities.first?.state == .signedOut)
    }
    @Test func switchDuringFinalReadCannotPublishTheOldAccountsLibrary() async throws {
        let h = try await harness()
        try await signIn(h)
        let first = try #require(await h.lifecycle.snapshot().context.account)
        await h.lifecycle.cancelAuthentication()
        let other = MusicAccountIdentity(serviceID: "UCsecondSyntheticAccount", displayName: "Second", handle: nil, photoURL: nil)
        await h.reader.set(menu: .identity(other))
        try await signIn(h)
        try await h.lifecycle.switchIdentity(to: first)
        await h.reader.set(menu: .identity(listener))
        await h.reader.holdNextLibrary()
        let pending = Task { await h.coordinator.proof() }
        while !(await h.reader.waiting()) { await Task.yield() }
        let second = try #require(await h.lifecycle.snapshot().directory.identities.first { $0.id != first }).id
        try await h.lifecycle.switchIdentity(to: second)
        await h.reader.release()
        #expect(await pending.value == .none, "a library read started for the first account is never shown for the second")
        #expect(await h.lifecycle.snapshot().context.account == second)
    }
    @Test func searchIsSignedForAConnectedAccountAndAnonymousWithoutOne() async throws {
        let h = try await harness()
        let before = try await h.coordinator.search(query: "q1")
        #expect(before.mode == .anonymous && before.response.items.first?.title == "anonymous:q1" && !before.sessionExpired)
        try await signIn(h)
        let after = try await h.coordinator.search(query: "q2")
        #expect(after.mode == .signedIn && after.response.items.first?.title == "signed:q2")
        #expect(after.accountGeneration == (await h.lifecycle.snapshot().context.accountGeneration) && after.accountGeneration > before.accountGeneration)
        let calls = await h.reader.calls()
        #expect(calls.map(\.signed) == [false, true] && calls.map(\.query) == ["q1", "q2"])
    }
    @Test func searchRotationIsWrittenBackAndAServiceEndedSessionExpiresThenAnswersAnonymously() async throws {
        let h = try await harness()
        try await signIn(h)
        await h.reader.rotate([.init(name: "__Secure-3PSIDCC", value: Marker.rotated, expires: Marker.now.addingTimeInterval(3600))])
        _ = try await h.coordinator.search(query: "rotate")
        #expect(await h.vault.replaced() >= 1)
        await h.reader.failSearch(.signedOut)
        let reply = try await h.coordinator.search(query: "ended")
        #expect(reply.mode == .anonymous && reply.sessionExpired && reply.response.items.first?.title == "anonymous:ended")
        #expect(await h.lifecycle.snapshot().directory.identities.first?.state == .expired)
        let again = try await h.coordinator.search(query: "later")
        #expect(again.mode == .anonymous && again.sessionExpired, "an expired identity keeps answering anonymously and says so")
        await h.reader.failSearch(.network)
        await #expect(throws: MusicSessionError.network) { try await h.coordinator.search(query: "down") }
    }
    @Test func aSearchStartedForOneAccountIsNeverReturnedAfterASwitch() async throws {
        let h = try await harness()
        try await signIn(h)
        let first = try #require(await h.lifecycle.snapshot().context.account)
        await h.lifecycle.cancelAuthentication()
        let other = MusicAccountIdentity(serviceID: "UCsecondSyntheticAccount", displayName: "Second", handle: nil, photoURL: nil)
        await h.reader.set(menu: .identity(other))
        try await signIn(h)
        try await h.lifecycle.switchIdentity(to: first)
        await h.reader.holdNextSearch()
        let pending = Task { try await h.coordinator.search(query: "held") }
        while !(await h.reader.waiting()) { await Task.yield() }
        let second = try #require(await h.lifecycle.snapshot().directory.identities.first { $0.id != first }).id
        try await h.lifecycle.switchIdentity(to: second)
        await h.reader.release()
        await #expect(throws: MusicSessionError.stale) { try await pending.value }
    }
    @Test func anAnonymousSearchIsDroppedWhenTheAccountScopeChangesMeanwhile() async throws {
        let h = try await harness()
        await h.reader.holdNextSearch()
        let pending = Task { try await h.coordinator.search(query: "held") }
        while !(await h.reader.waiting()) { await Task.yield() }
        try await signIn(h)
        await h.reader.release()
        await #expect(throws: MusicSessionError.stale) { try await pending.value }
    }
    @Test func browseIsSignedForAConnectedAccountAnonymousWithoutOneAndWritesRotationBack() async throws {
        let h = try await harness()
        let before = try await h.coordinator.browse(id: "FEmusic_home")
        #expect(before.mode == .anonymous && before.value.shelves.first?.title == "anonymous:FEmusic_home" && !before.sessionExpired)
        try await signIn(h)
        await h.reader.rotate([.init(name: "__Secure-3PSIDCC", value: Marker.rotated, expires: Marker.now.addingTimeInterval(3600))])
        let after = try await h.coordinator.browse(id: "FEmusic_home", params: "ggM8")
        #expect(after.mode == .signedIn && after.value.shelves.first?.title == "signed:FEmusic_home" && after.accountGeneration > before.accountGeneration)
        #expect(await h.vault.replaced() >= 1)
        _ = try await h.coordinator.continuation(token: "tok")
        #expect(await h.reader.browses().map(\.signed) == [false, true, true])
    }
    @Test func aServiceEndedSessionExpiresOnBrowseThenAnswersAnonymouslyAndSaysSo() async throws {
        let h = try await harness()
        try await signIn(h)
        await h.reader.failBrowse(.signedOut)
        let reply = try await h.coordinator.browse(id: "FEmusic_home")
        #expect(reply.mode == .anonymous && reply.sessionExpired && reply.value.shelves.first?.title == "anonymous:FEmusic_home")
        #expect(await h.lifecycle.snapshot().directory.identities.first?.state == .expired)
        await h.reader.failBrowse(.network)
        await #expect(throws: MusicSessionError.network) { try await h.coordinator.browse(id: "FEmusic_charts") }
    }
    @Test func aBrowseStartedForOneAccountIsNeverReturnedAfterASwitchOrAScopeChange() async throws {
        let h = try await harness()
        await h.reader.holdNextSearch()
        let pending = Task { try await h.coordinator.browse(id: "FEmusic_home") }
        while !(await h.reader.waiting()) { await Task.yield() }
        try await signIn(h)
        await h.reader.release()
        await #expect(throws: MusicSessionError.stale) { try await pending.value }
    }
    @Test func theAnonymousAnswerAfterAnEndedSessionIsDroppedWhenTheScopeChangesMeanwhile() async throws {
        let h = try await harness()
        try await signIn(h)
        let first = try #require(await h.lifecycle.snapshot().context.account)
        await h.lifecycle.cancelAuthentication()
        let other = MusicAccountIdentity(serviceID: "UCsecondSyntheticAccount", displayName: "Second", handle: nil, photoURL: nil)
        await h.reader.set(menu: .identity(other))
        try await signIn(h)
        try await h.lifecycle.switchIdentity(to: first)
        await h.reader.failBrowse(.signedOut)
        await h.reader.holdNextAnonymousBrowse()
        let pending = Task { try await h.coordinator.browse(id: "FEmusic_home") }
        while !(await h.reader.waiting()) { await Task.yield() }
        let second = try #require(await h.lifecycle.snapshot().directory.identities.first { $0.id != first }).id
        try await h.lifecycle.switchIdentity(to: second)
        await h.reader.release()
        await #expect(throws: MusicSessionError.stale) { try await pending.value }
    }
    // W12: library reads and writes are signed only and held to the account scope.
    @Test func libraryReadsAndWritesNeedAConnectedAccountAndNeverFallBackToAnonymous() async throws {
        let h = try await harness()
        await #expect(throws: MusicSessionError.notSignedIn) { try await h.coordinator.library(id: "FEmusic_liked_videos") }
        await #expect(throws: MusicSessionError.notSignedIn) { try await h.coordinator.libraryContinuation(token: "tok") }
        await #expect(throws: MusicSessionError.notSignedIn) { try await h.coordinator.write(.rate(videoID: "aaaaaaaaaa1", status: .like)) }
        let earlyLibrary = await h.reader.libraryRequests(), earlyWrites = await h.reader.writes()
        #expect(earlyLibrary.isEmpty && earlyWrites.isEmpty, "nothing was sent without an account")
        try await signIn(h)
        await h.reader.rotate([.init(name: "__Secure-3PSIDCC", value: Marker.rotated, expires: Marker.now.addingTimeInterval(3600))])
        let page = try await h.coordinator.library(id: "FEmusic_liked_videos")
        #expect(page.mode == .signedIn && page.value.shelves.first?.title == "signed:FEmusic_liked_videos")
        _ = try await h.coordinator.libraryContinuation(token: "tok")
        let reply = try await h.coordinator.write(.savePlaylist(playlistID: "OLAK5uy_abc", saved: true))
        #expect(reply.outcome == .confirmed && reply.accountGeneration == page.accountGeneration)
        let libraryRequests = await h.reader.libraryRequests(), writes = await h.reader.writes()
        #expect(libraryRequests == ["FEmusic_liked_videos", "tok"] && writes == [.savePlaylist(playlistID: "OLAK5uy_abc", saved: true)])
        #expect(await h.vault.replaced() >= 1, "rotated cookies are written back after a signed read or write")
    }
    /// A change the service confirmed must not be reported as "not made" because the rotated cookies could not be saved afterwards. A
    /// read in the same position still fails (nothing was confirmed to anyone).
    @Test func aConfirmedWriteSurvivesAKeychainFaultWhileSavingTheRotation() async throws {
        let h = try await harness()
        try await signIn(h)
        await h.reader.rotate([.init(name: "__Secure-3PSIDCC", value: Marker.rotated, expires: Marker.now.addingTimeInterval(3600))])
        await h.vault.breakReplace()
        let reply = try await h.coordinator.write(.rate(videoID: "aaaaaaaaaa1", status: .like))
        #expect(reply.outcome == .confirmed, "the service's answer is kept")
        let writes = await h.reader.writes()
        #expect(writes.count == 1)
        await #expect(throws: MusicSessionError.keychain) { try await h.coordinator.library(id: "FEmusic_liked_videos") }
    }
    @Test func aServiceEndedSessionExpiresTheIdentityOnALibraryReadOrWriteAndStaysFailedNeverAnonymous() async throws {
        let h = try await harness()
        try await signIn(h)
        await h.reader.failLibrary(.signedOut)
        await #expect(throws: MusicSessionError.signedOut) { try await h.coordinator.library(id: "FEmusic_liked_videos") }
        #expect(await h.lifecycle.snapshot().directory.identities.first?.state == .expired)
        await #expect(throws: MusicSessionError.signedOut) { try await h.coordinator.write(.rate(videoID: "aaaaaaaaaa1", status: .like)) }
        let writes = await h.reader.writes()
        #expect(writes.isEmpty, "an expired identity sends nothing")
    }
    @Test func aLibraryReadOrWriteStartedForOneAccountIsNeverReturnedAfterASwitch() async throws {
        let h = try await harness()
        try await signIn(h)
        let first = try #require(await h.lifecycle.snapshot().context.account)
        await h.reader.holdNextLibraryRead()
        let read = Task { try await h.coordinator.library(id: "FEmusic_liked_videos") }
        while !(await h.reader.waiting()) { await Task.yield() }
        let other = MusicAccountIdentity(serviceID: "UCsecondSyntheticAccount", displayName: "Second", handle: nil, photoURL: nil)
        await h.reader.set(menu: .identity(other))
        try await signIn(h)
        await h.reader.release()
        await #expect(throws: MusicSessionError.stale) { try await read.value }
        try await h.lifecycle.switchIdentity(to: first)
        await h.reader.holdNextLibraryRead()
        let write = Task { try await h.coordinator.write(.follow(channelID: "UC_kRDKYrUlrbtrSiyu5Tflg", params: nil, following: true)) }
        while !(await h.reader.waiting()) { await Task.yield() }
        let second = try #require(await h.lifecycle.snapshot().directory.identities.first { $0.id != first }).id
        try await h.lifecycle.switchIdentity(to: second)
        await h.reader.release()
        await #expect(throws: MusicSessionError.stale) { try await write.value }
    }
    @Test func unconfirmedRemovalStaysInTheLedgerAndReconciliationTouchesOnlyLedgerIDs() async throws {
        let h = try await harness()
        await h.stores.refuse()
        try await signIn(h)
        let store = try #require(h.presenter.stores.first)
        #expect(await h.ledger.pending() == [store], "an unconfirmed removal is never forgotten")
        let interrupted = UUID()
        await h.ledger.seed(interrupted)
        await h.stores.accept()
        await h.coordinator.reconcileWebStores()
        #expect(await h.ledger.pending().isEmpty)
        #expect(Set((await h.stores.removals()).suffix(2)) == [store, interrupted])
        let account = try #require(await h.lifecycle.snapshot().context.account)
        let before = await h.stores.removals().count
        try await h.lifecycle.remove(account)
        #expect(await h.stores.removals().count == before, "removal makes no WebKit call")
        let remaining = await h.lifecycle.snapshot().directory.identities
        #expect(await h.vault.count() == 0)
        #expect(remaining.isEmpty)
    }
    @Test func attemptDataIsWipedImmediatelyEvenWhenDirectoryRemovalFails() async throws {
        let h = try await harness()
        await h.stores.refuse()
        try await signIn(h)
        let store = try #require(h.presenter.stores.first)
        #expect(await h.stores.wipes() == [store], "cookies and website data are wiped as soon as the attempt ends")
        #expect(await h.stores.log().first == "wipe", "wipe precedes any removal attempt")
        #expect(await h.stores.removals().count == 4, "one immediate attempt plus the bounded backoff, after sign-in returned")
        #expect(await h.ledger.pending() == [store], "the ledger is cleared only after removal is confirmed")
    }
    @Test func removalKeepsRetryingAfterTheSheetClosesThenClearsTheLedger() async throws {
        let h = try await harness()
        await h.stores.refuse(times: 2)
        try await signIn(h)
        let store = try #require(h.presenter.stores.first)
        #expect(await h.stores.removals() == [store, store, store])
        #expect(await h.ledger.pending().isEmpty)
        #expect(h.presenter.finished == [nil], "the sheet closed before the retries finished")
    }
    @Test func reconciliationCannotDiscardAnAttemptWhoseLedgerWriteIsInFlight() async throws {
        let h = try await harness()
        await h.ledger.holdNextAdd()
        let challenge = try await h.lifecycle.beginAuthentication()
        let pending = Task { try await h.coordinator.signIn(challenge) }
        while !(await h.ledger.addHeld()) { await Task.yield() }
        let store = try #require(await h.ledger.pending().first)
        await h.coordinator.reconcileWebStores()
        #expect(!(await h.stores.removals().contains(store)), "N1: the in-flight attempt is protected before its first suspension")
        await h.ledger.releaseAdd()
        try await pending.value
        await h.coordinator.settleRemovals()
        let left = await h.ledger.pending()
        #expect(await h.stores.removals().first == store)
        #expect(left.isEmpty)
    }
    @Test func unconfirmedEarlierAttemptsAreRetriedBeforeTheNextSignIn() async throws {
        let h = try await harness()
        let earlier = UUID()
        await h.ledger.seed(earlier)
        try await signIn(h)
        #expect(await h.stores.removals().contains(earlier))
        #expect(await h.ledger.pending().isEmpty)
    }
    @Test func terminationDrainIsBoundedEvenIfRemovalNeverReturns() async throws {
        let h = try await harness()
        await h.ledger.seed(UUID())
        await h.stores.hangForever()
        let started = ContinuousClock.now
        await h.coordinator.drainRemovals(within: .milliseconds(50))
        #expect(ContinuousClock.now - started < .seconds(5), "quit is never blocked")
        #expect(await h.ledger.pending().count == 1, "unconfirmed removal stays ledgered for the next launch")
    }
    @Test func passkeySuppressionIsOnByDefaultAndCanBeDisabled() throws {
        #expect(MusicWebSignInOptions().suppressPasskeys)
        let scratch = ScratchDefaults(); defer { scratch.clean() }
        let defaults = scratch.defaults
        #expect(MusicWebSignInOptions(defaults: defaults).suppressPasskeys)
        defaults.set(false, forKey: MusicWebSignInOptions.suppressPasskeysKey)
        #expect(!MusicWebSignInOptions(defaults: defaults).suppressPasskeys)
        #expect(!MusicWebSignInOptions(defaults: defaults).safariApplicationName)
    }
    @Test func unknownHeaderAndLocalKeychainFaultsNeverExpireTheIdentity() async throws {
        let h = try await harness()
        try await signIn(h)
        await h.reader.set(menu: .failure(.unrecognised))
        #expect(await h.coordinator.proof() == .unrecognised)
        #expect(await h.lifecycle.snapshot().directory.identities.first?.state == .connected)
        await h.reader.set(menu: .identity(listener))
        await h.vault.breakReads()
        #expect(await h.coordinator.proof() == .failed(.keychain))
        #expect(await h.lifecycle.snapshot().directory.identities.first?.state == .connected, "a Keychain fault is local, not a service expiry")
        #expect(MusicSignInFeedback.message(for: MusicSessionError.keychain).contains("Keychain"))
    }
    @Test func fileLedgerIsOwnerOnlyAndHoldsOnlyIDs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-ledger-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("attempts/web-sign-in-attempts.json")
        let ledger = FileMusicSignInLedger(url: url)
        let first = UUID(), second = UUID()
        try await ledger.add(first); try await ledger.add(second); try await ledger.add(first)
        #expect(try await ledger.pending() == [first, second])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "[\"\(first.uuidString)\",\"\(second.uuidString)\"]")
        try await ledger.remove(first)
        #expect(try await FileMusicSignInLedger(url: url).pending() == [second], "survives a new process instance")
    }
    @Test func accountsSurfaceUsesMusicWordingAndNeverShowsSessionValues() async throws {
        let h = try await harness(.failure(.unrecognised))
        let model = AccountsModel(lifecycle: h.lifecycle, music: MusicSessionSurface(signIn: WebMusicSignIn(),
            authenticate: { [coordinator = h.coordinator] in try await coordinator.signIn($0) },
            status: { [coordinator = h.coordinator] in await coordinator.status() },
            proof: { [coordinator = h.coordinator] in await coordinator.proof() }))
        await model.refresh()
        #expect(model.authenticationLabel == "Sign in to YouTube Music" && model.canAuthenticate && model.authenticationCanConnectMusic)
        #expect(model.connectionStatus == MusicSessionStatus.signedOut.explanation)
        await model.authenticate()
        let unrecognised = try #require(model.message)
        #expect(unrecognised == MusicSignInFeedback.message(for: MusicSignInFailure.unrecognised) && model.identities.isEmpty)
        h.presenter.outcome = .cancel
        await model.authenticate()
        #expect(model.message == "Sign-in cancelled.")
        h.presenter.outcome = .session
        await h.reader.set(menu: .identity(listener))
        await model.authenticate()
        #expect(model.message == nil && model.activeConnected)
        guard case .signedIn = model.proof else { Issue.record("expected visible proof"); return }
        #expect(model.connectionStatus == MusicSessionStatus.signedIn("Synthetic Listener").explanation)
        var surfaces = [unrecognised, model.connectionStatus, String(describing: model.proof), String(reflecting: model.proof)]
        for error in [MusicSessionError.signedOut, .unrecognised, .network, .cleanupRequired, .policy] { surfaces.append(MusicSignInFeedback.message(for: error)) }
        var dumped = ""; dump(await h.lifecycle.snapshot(), to: &dumped); surfaces.append(dumped)
        for surface in surfaces { for marker in Marker.all { #expect(!surface.contains(marker)) } }
    }
}
