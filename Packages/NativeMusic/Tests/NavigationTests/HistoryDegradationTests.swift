import Testing
import Foundation
import AccountSession
import Domain
@testable import AppShell

@Suite(.serialized) @MainActor struct HistoryDegradationTests {
    @Test(arguments: ["healthy", "file", "symlink", "0644", "unreadable", "corrupt"])
    func realLifecycleActivationIsIndependentOfHistoryAvailability(mode: String) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("window-state"), external = base.appendingPathComponent("outside")
        if mode == "file" { try Data([1]).write(to: root) }
        if mode == "symlink" { try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true); try FileManager.default.createSymbolicLink(at: root, withDestinationURL: external) }
        if ["0644", "unreadable", "corrupt"].contains(mode) {
            let seeded = WindowRestorationStore(directory: root)
            try await seeded.remove(accountID: UUID())
            let marker = root.appendingPathComponent("removed-accounts.plist")
            if mode == "corrupt" { try Data([1,2,3]).write(to: marker) }
            try FileManager.default.setAttributes([.posixPermissions: mode == "0644" ? 0o644 : mode == "unreadable" ? 0o000 : 0o600], ofItemAtPath: marker.path)
        }
        let store = WindowRestorationStore(directory: root), ui = WindowNavigationAuthority(), work = ScopedAccountWork()
        let participant = WindowAccountParticipant(store: store, presentation: ui)
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [participant, work])
        let account = try consumerAccount(); try await connectConsumer(lifecycle, account)
        let navigation = BrowserNavigation(); ui.register(navigation)
        try await lifecycle.switchIdentity(to: account.context)
        let state = await lifecycle.snapshot()
        #expect(state.context.account == account.context)
        #expect(await lifecycle.accepts(state.context))
        #expect(try await lifecycle.reference(for: account.context, context: state.context).outcome.get() != nil)
        let token = try await work.register(context: state.context, cancel: {})
        await work.finish(token) // Another accepted account feature remains usable.
        #expect(ui.historyEnabled == (mode == "healthy"))
        if mode != "healthy" {
            #expect(ui.failure == WindowNavigationAuthority.unavailableNotice)
            #expect(navigation.session.current.query.isEmpty && navigation.session.owner == WindowOwner(account.context))
            var crafted = BrowserSession(); crafted.owner = WindowOwner(account.context)
            await #expect(throws: WindowRestorationError.storageUnavailable) { try await store.save(crafted, context: state.context) }
            await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.restore(window: crafted.windowID, context: state.context) }
        }
    }
    @Test func explicitResetRecoversWithoutRestoringPendingOrLateOldState() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = WindowRestorationStore(directory: base), account = try consumerAccount(), other = try consumerAccount(), ui = WindowNavigationAuthority()
        let participant = WindowAccountParticipant(store: store, presentation: ui)
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [participant])
        try await connectConsumer(lifecycle, account); try await connectConsumer(lifecycle, other)
        try await lifecycle.switchIdentity(to: account.context)
        let first = await lifecycle.snapshot().context
        var old = BrowserSession(); old.owner = WindowOwner(account.context); old.current.query = "old private saved state"
        try await store.save(old, context: first)
        // A persistent per-record obstruction makes the owner's flush fail.
        let file = try #require(FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).first { $0.pathExtension == "window" })
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        old.current.query = "pending state"
        await #expect(throws: WindowRestorationError.storageUnavailable) { try await store.save(old, context: first) }
        try await lifecycle.switchIdentity(to: other.context)
        let next = await lifecycle.snapshot().context
        #expect(next.account == other.context)
        #expect(await lifecycle.accepts(next))
        #expect(ui.context == next && !ui.historyEnabled)
        #expect(FileManager.default.fileExists(atPath: file.path), "No silent history deletion on activation")
        #expect(try await store.resetSavedWindowState(context: next))
        let epoch = await store.currentEpoch; ui.historyReset(context: next, enabled: true, epoch: epoch)
        #expect(ui.historyEnabled && ui.failure == nil)
        try await lifecycle.switchIdentity(to: account.context)
        let newer = await lifecycle.snapshot().context
        await #expect(throws: WindowRestorationError.staleOwner) { try await store.save(old, context: newer) }
        #expect(try await store.restore(window: old.windowID, context: newer) == nil)
        var fresh = BrowserSession(); fresh.owner = WindowOwner(account.context); fresh.historyEpoch = epoch; fresh.current.query = "new explicit state"
        try await store.save(fresh, context: newer)
        #expect(try await store.restore(window: fresh.windowID, context: newer)?.current.query == "new explicit state")
    }
    @Test func resetDoesNotFollowSymlinksOrEraseUnrelatedFilesAndKeepsRemovalRevoked() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside"), root = base.appendingPathComponent("windows")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.txt"); try Data("outside unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let store = WindowRestorationStore(directory: root), removed = try consumerAccount(), active = try consumerAccount()
        await #expect(throws: WindowRestorationError.storageUnavailable) { try await store.remove(accountID: removed.id) }
        let context = RequestContext(account: active.context, accountGeneration: 1, requestGeneration: 0)
        #expect(try await !store.bind(context))
        #expect(try await store.resetSavedWindowState(context: context))
        #expect(try Data(contentsOf: sentinel) == Data("outside unchanged".utf8))
        await #expect(throws: WindowRestorationError.removedAccount) { try await store.bind(.init(account: removed.context, accountGeneration: 2, requestGeneration: 0)) }
        let restarted = WindowRestorationStore(directory: root)
        await #expect(throws: WindowRestorationError.removedAccount) { try await restarted.bind(.init(account: removed.context, accountGeneration: 100, requestGeneration: 0)) }
        let valid = RequestContext(account: active.context, accountGeneration: 101, requestGeneration: 0)
        try await restarted.bind(valid)
        let linkedRecord = root.appendingPathComponent(UUID().uuidString + "." + String(repeating: "a", count: 64) + "." + UUID().uuidString + ".window")
        try FileManager.default.createSymbolicLink(at: linkedRecord, withDestinationURL: sentinel)
        #expect(try await restarted.resetSavedWindowState(context: valid))
        #expect(try Data(contentsOf: sentinel) == Data("outside unchanged".utf8))
        let unknown = root.appendingPathComponent("unrelated-user-file.txt"); try Data([9]).write(to: unknown)
        await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await restarted.resetSavedWindowState(context: valid) }
        #expect(try Data(contentsOf: unknown) == Data([9]))
        #expect(try Data(contentsOf: sentinel) == Data("outside unchanged".utf8))
    }
    @Test func failedRemovalStaysRevokedAndRetryableAcrossExplicitRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WindowRestorationStore(directory: root), ui = WindowNavigationAuthority(), a = try consumerAccount(), b = try consumerAccount()
        let participant = WindowAccountParticipant(store: store, presentation: ui)
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [participant])
        try await connectConsumer(lifecycle, a); try await connectConsumer(lifecycle, b); try await lifecycle.switchIdentity(to: a.context)
        let oldContext = await lifecycle.snapshot().context
        let nav = BrowserNavigation(); ui.register(nav); nav.session.current.query = "private removed record"; let old = nav.session
        try await store.save(old, context: oldContext)
        let revocations = root.appendingPathComponent("removed-accounts.plist")
        try FileManager.default.createDirectory(at: revocations, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await lifecycle.remove(a.context) }
        #expect(await lifecycle.snapshot().directory.identities.first { $0.id == a.context }?.state == .removalPending)
        #expect(nav.session.current.query.isEmpty)
        try await lifecycle.switchIdentity(to: b.context)
        let active = await lifecycle.snapshot().context
        #expect(active.account == b.context && !ui.historyEnabled)
        #expect(try await store.resetSavedWindowState(context: active))
        await #expect(throws: WindowRestorationError.staleOwner) { try await store.save(old, context: oldContext) }
        let restarted = WindowRestorationStore(directory: root)
        await #expect(throws: WindowRestorationError.removedAccount) { try await restarted.bind(.init(account: a.context, accountGeneration: 100, requestGeneration: 0)) }
        try await lifecycle.remove(a.context)
        #expect(await lifecycle.snapshot().directory.identities.contains { $0.id == a.context } == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(a.id.uuidString + ".") } == false)
    }

    @Test func staleAuthorityAndCancellationAreNotMistakenForStorageFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WindowRestorationStore(directory: root), account = try consumerAccount()
        let current = RequestContext(account: account.context, accountGeneration: 10, requestGeneration: 0)
        #expect(try await store.bind(current))
        await #expect(throws: WindowRestorationError.staleOwner) { try await store.bind(.init(account: account.context, accountGeneration: 1, requestGeneration: 0)) }
        #expect(await store.historyAvailable)
        let cancelled = Task { try await store.bind(.init(account: account.context, accountGeneration: 11, requestGeneration: 0)) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(await store.historyAvailable)
    }

}
