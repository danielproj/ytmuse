import Foundation
import Security
import Testing
import Domain
@testable import AccountSession

/// A vault double that records every call. Prompts are allowed only through the per-call
/// `allowingInteraction:` forms; the vault-wide `setUserInitiatedInteraction` is counted so a
/// test can prove nothing still uses it.
private actor RecordingVault: SessionVault {
    var records: [String: Data] = [:]
    var active: RequestContext?
    var events: [String] = []
    var failInsert = false
    var refuseUserDeletes = false
    var wideToggles = 0
    /// Holds the next interactive `deleteAll` (a Keychain prompt on screen) until released.
    var holdNext = false
    var entered: CheckedContinuation<Void, Never>?
    var held: CheckedContinuation<Void, Never>?
    func setFailInsert(_ value: Bool) { failInsert = value }
    func refuse(_ value: Bool) { refuseUserDeletes = value }
    func hold() { holdNext = true }
    func waitUntilHeld() async { if held != nil { return }; await withCheckedContinuation { entered = $0 } }
    func releaseHeld() { held?.resume(); held = nil }
    func releaseHeldDelete() { deleteHeld?.resume(); deleteHeld = nil }
    func setUserInitiatedInteraction(_ allowed: Bool) async { wideToggles += 1 }
    func bind(_ context: RequestContext) { if let active, context.accountGeneration < active.accountGeneration { return }; active = context }
    func insert(_ bytes: Data, for account: AccountContext) throws -> CredentialReference {
        events.append("insert")
        if failInsert { throw LifecycleError.keychain(errSecIO) }
        let reference = try CredentialReference(UUID().uuidString); records[reference.rawValue] = bytes; return reference
    }
    func read(_ reference: CredentialReference, context: RequestContext) throws -> Data {
        guard let bytes = records[reference.rawValue] else { throw LifecycleError.keychain(errSecItemNotFound) }; return bytes
    }
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) throws { records[reference.rawValue] = bytes }
    func delete(_ reference: CredentialReference, for account: AccountContext) throws { events.append("delete"); records[reference.rawValue] = nil }
    func deleteAll(for account: AccountContext) throws { events.append("deleteAll"); records = [:] }
    /// Runs inside the interactive deletion of an old record, before it is refused (to fail the roster save then).
    var duringPrompt: (@Sendable () async -> Void)?
    func setDuringPrompt(_ hook: (@Sendable () async -> Void)?) { duringPrompt = hook }
    /// Holds the next interactive single deletion (the prompt is on screen) until released.
    var holdNextDelete = false
    var deleteEntered: CheckedContinuation<Void, Never>?
    var deleteHeld: CheckedContinuation<Void, Never>?
    func holdDelete() { holdNextDelete = true }
    func waitUntilDeleteHeld() async { if deleteHeld != nil { return }; await withCheckedContinuation { deleteEntered = $0 } }
    func delete(_ reference: CredentialReference, for account: AccountContext, allowingInteraction: Bool) async throws {
        events.append(allowingInteraction ? "delete+ui" : "delete")
        if allowingInteraction, let duringPrompt { await duringPrompt() }
        if allowingInteraction && holdNextDelete {
            holdNextDelete = false
            await withCheckedContinuation { continuation in deleteHeld = continuation; deleteEntered?.resume(); deleteEntered = nil }
        }
        if allowingInteraction && refuseUserDeletes { throw LifecycleError.keychain(errSecUserCanceled) }
        if !allowingInteraction && !requiresNoPrompt { throw LifecycleError.keychain(errSecInteractionNotAllowed) }
        records[reference.rawValue] = nil
    }
    func deleteAll(for account: AccountContext, allowingInteraction: Bool) async throws {
        events.append(allowingInteraction ? "deleteAll+ui" : "deleteAll")
        if allowingInteraction && holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in held = continuation; entered?.resume(); entered = nil }
        }
        if allowingInteraction && refuseUserDeletes { throw LifecycleError.keychain(errSecUserCanceled) }
        if !allowingInteraction && !requiresNoPrompt { throw LifecycleError.keychain(errSecInteractionNotAllowed) }
        records = [:]
    }
    /// Whether a launch-time (no UI) erase succeeds.
    var requiresNoPrompt = true
    func needsPromptAtLaunch(_ value: Bool) { requiresNoPrompt = !value }
    func snapshot() -> (records: Set<String>, events: [String], wide: Int) { (Set(records.keys), events, wideToggles) }
}

@Suite(.serialized) struct C1AccountCleanupTests {
    private func connected() async throws -> (AccountLifecycle, RecordingVault, MemoryDirectory, Account, String) {
        let vault = RecordingVault(), store = MemoryDirectory()
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: store, participants: [])
        let account = try identity("c1-cleanup")
        try await connect(lifecycle, account)
        let reference = try #require(await store.value.identities.first?.account.credential?.rawValue)
        return (lifecycle, vault, store, account, reference)
    }

    // MARK: L1 — Sign In Again writes the new record before deleting the old one

    @Test func aFailedWriteOfTheNewRecordLeavesTheWorkingSessionUntouched() async throws {
        let (lifecycle, vault, store, account, first) = try await connected()
        await vault.setFailInsert(true)
        let challenge = try await lifecycle.beginAuthentication(for: account.context)
        await #expect(throws: LifecycleError.keychain(errSecIO)) {
            try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("replacement".utf8))
        }
        let state = await vault.snapshot()
        #expect(state.records == [first], "the old record was never deleted")
        #expect(await store.value.identities.first?.account.credential?.rawValue == first)
        #expect(await store.value.identities.first?.state == .connected, "still a working, connected session")
        #expect(!state.events.contains("delete+ui"), "nothing was deleted before the new record existed")
    }
    @Test func aFailedDirectoryCommitRemovesOnlyTheNewRecord() async throws {
        let (lifecycle, vault, store, account, first) = try await connected()
        await store.setFailure(true)
        let challenge = try await lifecycle.beginAuthentication(for: account.context)
        await #expect(throws: (any Error).self) {
            try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("replacement".utf8))
        }
        #expect(await vault.snapshot().records == [first], "the new record was rolled back, the old one kept")
        #expect(!(await vault.snapshot().events.contains("delete+ui")))
    }
    @Test func aRefusedDeletionOfTheOldRecordRollsTheWholeReconnectBack() async throws {
        let (lifecycle, vault, store, account, first) = try await connected()
        await vault.refuse(true)
        let challenge = try await lifecycle.beginAuthentication(for: account.context)
        await #expect(throws: LifecycleError.cleanupFailed(["previous-credential"])) {
            try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("replacement".utf8))
        }
        #expect(await vault.snapshot().records == [first], "the new record is withdrawn: nothing beside the undeletable old one")
        #expect(await store.value.identities.first?.account.credential?.rawValue == first, "the entry returns to the old reference")
        await vault.refuse(false)
        let retry = try await lifecycle.beginAuthentication(for: account.context)
        try await lifecycle.completeAuthentication(retry, account: account, secret: Data("replacement".utf8))
        let after = await vault.snapshot()
        #expect(after.records.count == 1 && !after.records.contains(first), "retry: only the new record remains")
    }
    @Test func aSuccessfulReconnectWritesFirstDeletesLastAndNeverUsesTheVaultWideSwitch() async throws {
        let (lifecycle, vault, _, account, first) = try await connected()
        let challenge = try await lifecycle.beginAuthentication(for: account.context)
        try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("replacement".utf8))
        let state = await vault.snapshot()
        #expect(Array(state.events.suffix(2)) == ["insert", "delete+ui"], "the old record is deleted only after the new one exists: \(state.events)")
        #expect(state.wide == 0, "the vault-wide interaction switch is no longer used (L2)")
        #expect(state.records.count == 1 && !state.records.contains(first))
    }

    // MARK: REWORK 1 (critic probe) — refused deletion AND a failed rollback save keeps the working new session

    @Test func aRefusedDeletionWithAFailedRollbackSaveKeepsTheNewSessionAndDefersTheOldRecord() async throws {
        let vault = RecordingVault(), store = MemoryDirectory(), ledger = MemoryStaleCredentialLedger()
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: store, participants: [], staleLedger: ledger)
        let account = try identity("c1-double-failure")
        try await connect(lifecycle, account)
        let first = try #require(await store.value.identities.first?.account.credential?.rawValue)
        await vault.refuse(true)
        // The user refuses the prompt AND the disk fails when the roster is rolled back.
        await vault.setDuringPrompt { await store.setFailure(true) }
        let challenge = try await lifecycle.beginAuthentication(for: account.context)
        await #expect(throws: LifecycleError.cleanupFailed(["previous-credential", "directory"])) {
            try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("replacement".utf8))
        }
        await store.setFailure(false)
        let state = await vault.snapshot()
        let durable = try #require(await store.value.identities.first?.account.credential?.rawValue)
        let live = try #require(await lifecycle.snapshot().directory.identities.first?.account.credential?.rawValue)
        #expect(durable != first && live == durable, "the roster, durable and live, points at the NEW record")
        #expect(state.records.contains(durable), "and that record still exists: the session works")
        #expect(state.records.contains(first), "the old record is not deleted yet")
        let marked = await ledger.pending().map(\.reference.rawValue)
        #expect(marked == [first], "the old record is marked for deferred deletion")
        // Launch settles it without a prompt only if no prompt is needed; here one is needed, so it waits.
        await vault.needsPromptAtLaunch(true)
        _ = try await AccountLifecycle.open(vault: vault, store: store, participants: [], staleLedger: ledger)
        let waiting = await vault.snapshot().records.contains(first), stillMarked = !(await ledger.pending().isEmpty)
        #expect(waiting && stillMarked, "no prompt at launch: deferred to the next explicit action")
        let launchTried = await vault.snapshot().events.last
        #expect(launchTried == "delete", "launch tried the deletion once with the Keychain UI off, never with a prompt allowed")
        // The next explicit Sign In Again may ask, and then deletes it.
        await vault.refuse(false); await vault.setDuringPrompt(nil)
        let relaunched = try await AccountLifecycle.open(vault: vault, store: store, participants: [], staleLedger: ledger)
        let again = try await relaunched.beginAuthentication(for: account.context)
        try await relaunched.completeAuthentication(again, account: account, secret: Data("third".utf8))
        let after = await vault.snapshot()
        let markersLeft = await ledger.pending().count
        #expect(!after.records.contains(first) && after.records.count == 1 && markersLeft == 0, "old record erased, ledger empty, one session left")
    }
    @Test func quittingDuringTheOldRecordPromptLeavesAMarkerTheNextLaunchSettlesWithoutAPrompt() async throws {
        let vault = RecordingVault(), store = MemoryDirectory(), ledger = MemoryStaleCredentialLedger()
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: store, participants: [], staleLedger: ledger)
        let account = try identity("c1-quit-in-prompt")
        try await connect(lifecycle, account)
        let first = try #require(await store.value.identities.first?.account.credential?.rawValue)
        await vault.holdDelete()
        let challenge = try await lifecycle.beginAuthentication(for: account.context)
        let reconnecting = Task { try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("replacement".utf8)) }
        await vault.waitUntilDeleteHeld()
        // The prompt is on screen and the process ends here: the roster already points at the new record.
        let markedBefore = await ledger.pending().map(\.reference.rawValue)
        #expect(markedBefore == [first], "the marker was written before the prompt")
        let relaunched = try await AccountLifecycle.open(vault: vault, store: store, participants: [], staleLedger: ledger)
        _ = relaunched
        let state = await vault.snapshot()
        #expect(!state.records.contains(first) && state.records.count == 1, "launch erased the old record")
        let leftAtLaunch = await ledger.pending().count
        #expect(leftAtLaunch == 0)
        await vault.releaseHeldDelete()
        _ = try? await reconnecting.value
    }
    @Test func signingOutOrRemovingForgetsTheAccountsStaleMarkers() async throws {
        for removal in [false, true] {
            let vault = RecordingVault(), store = MemoryDirectory(), ledger = MemoryStaleCredentialLedger()
            let lifecycle = try await AccountLifecycle.open(vault: vault, store: store, participants: [], staleLedger: ledger)
            let account = try identity("c1-forget-" + String(removal))
            try await connect(lifecycle, account)
            try await ledger.add(account: account.id, reference: try CredentialReference(UUID().uuidString))
            if removal { try await lifecycle.remove(account.context) } else { try await lifecycle.signOut(account.context) }
            let left = await ledger.pending().count
            #expect(left == 0, "the erase of the whole account covers its stale records, so their markers go (remove: \(removal))")
        }
    }
    @Test func aMarkerForAReferenceTheRosterPointsAtIsNeverDeleted() async throws {
        let vault = RecordingVault(), store = MemoryDirectory(), ledger = MemoryStaleCredentialLedger()
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: store, participants: [], staleLedger: ledger)
        let account = try identity("c1-live-marker")
        try await connect(lifecycle, account)
        let live = try #require(await store.value.identities.first?.account.credential)
        try await ledger.add(account: account.id, reference: live)
        _ = try await AccountLifecycle.open(vault: vault, store: store, participants: [], staleLedger: ledger)
        let kept = await vault.snapshot().records.contains(live.rawValue), dropped = await ledger.pending().isEmpty
        #expect(kept, "a live session record is never erased as stale")
        #expect(dropped, "the marker is dropped")
    }
    @Test func theFileLedgerRoundTripsAndRefusesAFileThatIsNotAReferenceList() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c1-stale-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = FileStaleCredentialLedger(url: url)
        let reference = try CredentialReference(UUID().uuidString), owner = UUID()
        try await ledger.add(account: owner, reference: reference)
        try await ledger.add(account: owner, reference: reference)
        let rows = try await ledger.pending()
        #expect(rows.count == 1 && rows[0].account == owner && rows[0].reference == reference)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        try await ledger.remove(reference: reference)
        let emptied = try await ledger.pending().isEmpty
        #expect(emptied)
        try Data("{\"not\":\"a list\"}".utf8).write(to: url)
        await #expect(throws: (any Error).self) { _ = try await ledger.pending() }
    }

    // MARK: L2 — the interaction window is the single deletion call

    @Test func signOutAndRemoveAllowPromptsPerCallAndNeverVaultWide() async throws {
        let (lifecycle, vault, _, account, _) = try await connected()
        try await lifecycle.signOut(account.context)
        try await lifecycle.remove(account.context)
        let state = await vault.snapshot()
        #expect(state.events.filter { $0.hasPrefix("deleteAll") } == ["deleteAll+ui", "deleteAll+ui"])
        #expect(state.wide == 0)
    }
    @Test func theRealVaultRestoresPromptsAfterEveryPerCallDeletionEvenWhenItFails() async throws {
        let vault = try testVault()
        // Through the existential, exactly as the lifecycle calls it, so the vault's own form (not the
        // protocol extension's toggling default) is the one dispatched.
        let seen: any SessionVault = vault
        let account = try identity("c1-window")
        let unknown = try CredentialReference(UUID().uuidString)
        // A record that does not exist is accepted as deleted; the window opens and must close.
        try await seen.delete(unknown, for: account.context, allowingInteraction: true)
        #expect(await !vault.isUserInitiatedInteraction(), "restored after a succeeding single deletion")
        try await seen.deleteAll(for: account.context, allowingInteraction: true)
        #expect(await !vault.isUserInitiatedInteraction(), "restored after a succeeding erase")
        // A failing call restores too: a destroyed (closed) vault refuses inside the window.
        try await vault.destroyIsolatedTestKeychain()
        await #expect(throws: (any Error).self) { try await seen.delete(unknown, for: account.context, allowingInteraction: true) }
        #expect(await !vault.isUserInitiatedInteraction(), "restored after a failing call")
    }

    // MARK: QL2 — quitting during the Sign Out prompt leaves a durable erase-pending marker

    @Test func signOutKeepsTheCredentialReferenceUntilTheRecordsAreErasedAndLaunchFinishesTheJob() async throws {
        let (lifecycle, vault, store, account, reference) = try await connected()
        await vault.hold()
        let signingOut = Task { try await lifecycle.signOut(account.context) }
        await vault.waitUntilHeld()
        // The Keychain prompt is on screen and the user quits: this is the durable state at exit.
        let identity = try #require(await store.value.identities.first)
        #expect(identity.state == .signedOut, "signed out at once")
        #expect(identity.account.credential?.rawValue == reference, "the reference stays recorded until the erase succeeds")
        // Next launch: a new lifecycle over the same store and the same Keychain.
        let relaunched = try await AccountLifecycle.open(vault: vault, store: store, participants: [])
        #expect(await vault.snapshot().records.isEmpty, "launch erased the records the interrupted sign-out left")
        let cleared = try #require(await store.value.identities.first)
        #expect(cleared.state == .signedOut && cleared.account.credential == nil, "and cleared the marker")
        _ = relaunched
        await vault.releaseHeld()
        _ = try? await signingOut.value
    }
    @Test func aRecordThatNeedsAPromptStaysPendingAtLaunchWithoutAskingAnyone() async throws {
        let (lifecycle, vault, store, account, reference) = try await connected()
        await vault.refuse(true)
        await #expect(throws: LifecycleError.cleanupFailed(["keychain"])) { try await lifecycle.signOut(account.context) }
        #expect(await store.value.identities.first?.account.credential?.rawValue == reference, "the failed erase stays discoverable")
        await vault.refuse(false)
        await vault.needsPromptAtLaunch(true)
        _ = try await AccountLifecycle.open(vault: vault, store: store, participants: [])
        #expect(await vault.snapshot().events.last == "deleteAll", "launch tried once with the Keychain UI off")
        #expect(await store.value.identities.first?.account.credential?.rawValue == reference, "and left the marker for the next explicit action")
        #expect(await vault.snapshot().records.count == 1)
    }
}

// MARK: Item 8 — Google's sign-in sheet presents only in the window that asked

@Suite @MainActor struct C1SignInSheetWindowTests {
    @Test func onlyTheRequestingWindowPresentsTheSheet() {
        let rule = WebMusicSignIn.shouldPresent
        #expect(rule(true, true, 1, 1), "the window that asked presents")
        #expect(!rule(true, true, 2, 1), "a second window stays quiet")
        #expect(!rule(true, true, nil, 1), "a presenter not yet in a window stays quiet while a requester is known")
        #expect(!rule(false, true, 1, 1) && !rule(true, false, 1, 1), "not presented, or presenter disabled (accounts sheet on top)")
        #expect(rule(true, true, 1, nil) && rule(true, true, 2, nil), "with nobody recorded, presenting is not suppressed everywhere")
    }
    @Test func theAttemptRecordsTheAskingWindowAndForgetsItWhenDismissed() {
        let signIn = WebMusicSignIn(windowProvider: { 7 })
        #expect(signIn.requestingWindow == nil)
        signIn.claimRequestingWindow()
        #expect(signIn.requestingWindow == 7)
        signIn.close()
        #expect(signIn.requestingWindow == nil && !signIn.isPresented)
        signIn.claimRequestingWindow(); signIn.finish(nil)
        #expect(signIn.requestingWindow == nil, "a finished attempt is not tied to a window any more")
        signIn.claimRequestingWindow(); signIn.cancel()
        #expect(signIn.requestingWindow == nil)
    }
    @Test func theSheetModifierUsesTheRuleAndTheHostWindow() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Features/MusicSignInSheet.swift").standardizedFileURL, encoding: .utf8)
        #expect(source.contains("WebMusicSignIn.shouldPresent(isPresented:") && source.contains("requester: signIn?.requestingWindow") && source.contains("hostWindow: hostWindow"))
    }
    /// `begin` needs a real WebKit store, which a unit test must not create; its one obligation here is
    /// to name the asking window before the page is built and presented.
    @Test func beginNamesTheAskingWindowBeforeItPresentsAnything() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/AccountSession/WebSession/WebMusicSignIn.swift").standardizedFileURL, encoding: .utf8)
        let begin = try #require(source.range(of: "public func begin(store: UUID"))
        let body = String(source[begin.lowerBound...])
        let claim = try #require(body.range(of: "claimRequestingWindow()")), start = try #require(body.range(of: "start(store: store)"))
        #expect(claim.lowerBound < start.lowerBound, "the asking window is recorded before the sheet can be presented")
    }
}

// MARK: Item 11 — a prompt-needed Keychain read is never persisted as "expired" by a build that may not

private actor PromptNeededVault: SessionVault {
    var records: [String: Data] = [:]
    var active: RequestContext?
    var promptOnRead = false
    func prompting(_ value: Bool) { promptOnRead = value }
    func bind(_ context: RequestContext) { if let active, context.accountGeneration < active.accountGeneration { return }; active = context }
    func insert(_ bytes: Data, for account: AccountContext) throws -> CredentialReference {
        let reference = try CredentialReference(UUID().uuidString); records[reference.rawValue] = bytes; return reference
    }
    func read(_ reference: CredentialReference, context: RequestContext) throws -> Data {
        if promptOnRead { throw LifecycleError.keychain(errSecInteractionNotAllowed) }
        guard let bytes = records[reference.rawValue] else { throw LifecycleError.keychain(errSecItemNotFound) }; return bytes
    }
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) throws { records[reference.rawValue] = bytes }
    func delete(_ reference: CredentialReference, for account: AccountContext) throws { records[reference.rawValue] = nil }
    func deleteAll(for account: AccountContext) throws { records = [:] }
    func delete(_ reference: CredentialReference, for account: AccountContext, allowingInteraction: Bool) throws { records[reference.rawValue] = nil }
    func deleteAll(for account: AccountContext, allowingInteraction: Bool) throws { records = [:] }
}
private actor ExpiryLog: AccountLifecycleParticipant {
    nonisolated let participantID = "expiry-log"
    var restored: [LocalSessionState] = []
    func detach(previous: RequestContext, barrier: RequestContext) {}
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) { restored.append(identity.state) }
    func removeLocal(_ account: AccountContext, context: RequestContext) {}
    func states() -> [LocalSessionState] { restored }
}

@Suite struct C1PromptExpiryTests {
    @Test func onlyAReleaseBuildWithARealIdentityMayPersistPromptExpiry() {
        let policy = KeychainExpiryPolicy.persistsPromptExpiry
        #expect(policy(false, .identity), "a production-signed Release build: the signature that wrote the record")
        #expect(!policy(true, .identity) && !policy(true, .adHoc) && !policy(true, .unsigned), "no Debug build ever persists it")
        #expect(!policy(false, .adHoc) && !policy(false, .unsigned), "an ad-hoc or unsigned Release build does not either")
    }
    @Test func thisTestBuildsOwnAnswerIsNo() {
        #expect(!KeychainExpiryPolicy.currentBuildPersistsPromptExpiry, "a Debug build (and an unsigned test runner) never persists it")
    }
    private func connected(persists: Bool) async throws -> (AccountLifecycle, PromptNeededVault, MemoryDirectory, ExpiryLog, Account) {
        let vault = PromptNeededVault(), store = MemoryDirectory(), log = ExpiryLog()
        let first = try await AccountLifecycle.open(vault: vault, store: store, participants: [])
        let account = try identity("c1-expiry")
        try await connect(first, account)
        let lifecycle = try await AccountLifecycle.open(vault: vault, store: store, participants: [log], persistsPromptExpiry: persists)
        return (lifecycle, vault, store, log, account)
    }
    @Test func aBuildThatMayNotPersistShowsExpiredForThisRunOnlyAndLeavesTheStoredStateAlone() async throws {
        let (lifecycle, vault, store, log, account) = try await connected(persists: false)
        let reference = try #require(await store.value.identities.first?.account.credential?.rawValue)
        await vault.prompting(true)
        try await lifecycle.switchIdentity(to: account.context)
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .expired, "this run shows Sign In Again")
        #expect(await log.states() == [.expired], "participants see the expired identity, so no player is offered")
        #expect(await store.value.identities.first?.state == .connected, "the stored roster is untouched")
        #expect(await store.value.identities.first?.account.credential?.rawValue == reference)
        // A later unrelated change must not carry the transient state into storage either.
        try await lifecycle.rename(account.context, label: "Renamed")
        #expect(await store.value.identities.first?.state == .connected, "a roster write elsewhere does not persist it")
        // The next launch, with the prompt gone, finds the session working.
        await vault.prompting(false)
        let relaunched = try await AccountLifecycle.open(vault: vault, store: store, participants: [])
        try await relaunched.switchIdentity(to: account.context)
        #expect(await relaunched.snapshot().directory.identities.first?.state == .connected)
    }
    @Test func aBuildThatMayPersistStillDoes() async throws {
        let (lifecycle, vault, store, _, account) = try await connected(persists: true)
        await vault.prompting(true)
        try await lifecycle.switchIdentity(to: account.context)
        #expect(await store.value.identities.first?.state == .expired, "production behaviour is unchanged")
    }
    @Test func signingInAgainClearsTheTransientExpiry() async throws {
        let (lifecycle, vault, store, _, account) = try await connected(persists: false)
        await vault.prompting(true)
        try await lifecycle.switchIdentity(to: account.context)
        await vault.prompting(false)
        let challenge = try await lifecycle.beginAuthentication(for: account.context)
        try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("fresh".utf8))
        #expect(await lifecycle.snapshot().directory.identities.first?.state == .connected)
        #expect(await store.value.identities.first?.state == .connected)
    }
    @Test func theCompositionAsksThePolicyAndIsolatedInstancesNeverTouchWebKitStores() throws {
        func text(_ path: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/" + path).standardizedFileURL, encoding: .utf8)
        }
        let composition = try text("AppShell/LocalAccountComposition.swift")
        #expect(composition.components(separatedBy: "persistsPromptExpiry: Bool = KeychainExpiryPolicy.currentBuildPersistsPromptExpiry").count == 3, "both open() entry points default to the policy")
        #expect(composition.contains("nonPersistentStores: webIsolated") && composition.contains("stores: IsolatedMusicDataStores()"))
        let signIn = try text("AccountSession/WebSession/WebMusicSignIn.swift")
        #expect(signIn.contains("nonPersistentStores ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: store)"))
    }
}
