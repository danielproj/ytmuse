import Foundation
import Testing
import Domain
import AccountSession
@testable import AppShell

@Suite(.serialized) @MainActor struct WindowPrivacyTests {
    @Test func realLifecycleRetractsAllWindowsBeforeHeldStorageAndRestoresOnlyMatchingOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WindowRestorationStore(directory: directory), ui = WindowNavigationAuthority()
        let participant = WindowAccountParticipant(store: store, presentation: ui), held = HeldStorageParticipant()
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [participant, held])
        let a = try consumerAccount(), b = try consumerAccount()
        try await connectConsumer(lifecycle, a); try await connectConsumer(lifecycle, b)
        try await lifecycle.switchIdentity(to: a.context)
        let aContext = await lifecycle.snapshot().context
        let first = BrowserNavigation(), second = BrowserNavigation()
        ui.register(first); ui.register(second)
        first.open(.search); first.session.current.query = "private A query"; first.session.current.selection = ["private-occurrence"]
        first.session.current.filter = "Downloaded only"; first.session.current.scrollOffset = 900
        second.open(.library, item: try NativeItemRoute(kind: .playlist, identifier: "private-playlist"))
        let outgoingFirst = first.session, outgoingSecond = second.session
        await held.arm()
        let switching = Task { try await lifecycle.switchIdentity(to: b.context) }
        try await consumerEventually { await held.entered }
        for nav in [first, second] {
            #expect(nav.session.current.query.isEmpty && nav.session.current.selection.isEmpty)
            #expect(nav.session.current.item == nil && nav.session.current.filter == "All")
            #expect(nav.session.entries.count == 1 && nav.session.current.destination == .home)
        }
        await #expect(throws: WindowRestorationError.staleOwner) { try await store.save(outgoingFirst, context: aContext) }
        await held.release(); try await switching.value
        let bContext = await lifecycle.snapshot().context
        #expect(try await store.restore(window: first.session.windowID, context: bContext) == nil)
        first.session.current.query = "B query"
        try await lifecycle.switchIdentity(to: a.context)
        let restoredContext = await lifecycle.snapshot().context
        #expect(try await store.restore(window: outgoingFirst.windowID, context: restoredContext) == outgoingFirst)
        #expect(try await store.restore(window: outgoingSecond.windowID, context: restoredContext) == outgoingSecond)
        try await lifecycle.signOut(a.context)
        #expect(first.session.current.query.isEmpty && second.session.current.item == nil)
        await #expect(throws: WindowRestorationError.staleOwner) { _ = try await store.restore(window: outgoingFirst.windowID, context: restoredContext) }
    }
    @Test func removalPurgesClosedWindowsAllChannelsAndFencesDelayedSaveRestoreAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WindowRestorationStore(directory: directory), ui = WindowNavigationAuthority()
        let participant = WindowAccountParticipant(store: store, presentation: ui)
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [participant])
        let a = try consumerAccount(), b = try consumerAccount()
        try await connectConsumer(lifecycle, a); try await connectConsumer(lifecycle, b)
        try await lifecycle.switchIdentity(to: a.context)
        let context = await lifecycle.snapshot().context
        let closed = BrowserNavigation(); ui.register(closed); closed.open(.search); closed.session.current.query = "closed private A"; let saved = closed.session
        try await store.save(saved, context: context)
        ui.close(closed); ui.savedClosed(saved.windowID, context: context)
        let reopened = BrowserNavigation(session: try #require(try await store.restore(window: saved.windowID, context: context)))
        #expect(reopened.session.current.query == "closed private A", "Positive control: closed windows really have persisted private state")
        try await lifecycle.switchIdentity(to: b.context)
        let bContext = await lifecycle.snapshot().context
        let other = BrowserNavigation(); ui.register(other); other.session.current.query = "B retained"
        try await store.save(other.session, context: bContext)
        try await lifecycle.remove(a.context)
        await #expect(throws: WindowRestorationError.staleOwner) { try await store.save(saved, context: context) }
        await #expect(throws: WindowRestorationError.staleOwner) { _ = try await store.restore(window: saved.windowID, context: context) }
        let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!filenames.contains(where: { $0.hasPrefix(a.id.uuidString + ".") }))
        let restarted = WindowRestorationStore(directory: directory)
        await #expect(throws: WindowRestorationError.removedAccount) { try await restarted.bind(.init(account: a.context, accountGeneration: 100, requestGeneration: 0)) }
        try await restarted.bind(.init(account: b.context, accountGeneration: 101, requestGeneration: 0))
        #expect(try await restarted.restore(window: other.session.windowID, context: .init(account: b.context, accountGeneration: 101, requestGeneration: 0))?.current.query == "B retained")
    }
    @Test func closingDuringDetachFlushesTrustedSnapshotAndStorageFailureStillRetracts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WindowRestorationStore(directory: directory), ui = WindowNavigationAuthority(), account = try consumerAccount()
        let participant = WindowAccountParticipant(store: store, presentation: ui)
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 0)
        try await participant.restorePaused(LocalIdentity(account: account), context: context)
        let window = BrowserNavigation(); ui.register(window); window.session.current.query = "last closed change"; let saved = window.session
        ui.close(window) // close-save task has not run yet
        try await participant.detach(previous: context, barrier: .init(account: nil, accountGeneration: 2, requestGeneration: 0))
        #expect(window.session.current.query.isEmpty, "A still-live hidden/disappeared view must redact, not only its stored snapshot")
        await #expect(throws: WindowRestorationError.staleOwner) { try await store.save(saved, context: context) }
        let next = RequestContext(account: account.context, accountGeneration: 3, requestGeneration: 0)
        try await participant.restorePaused(LocalIdentity(account: account), context: next)
        #expect(try await store.restore(window: saved.windowID, context: next)?.current.query == "last closed change")
        // An unusable root supplies a real throwing storage path, not a mocked success.
        let bad = directory.appendingPathComponent("not-a-directory"); try Data([1]).write(to: bad)
        let broken = WindowAccountParticipant(store: WindowRestorationStore(directory: bad), presentation: ui)
        let open = BrowserNavigation(); ui.register(open); open.session.current.query = "must redact even on error"
        try await broken.detach(previous: next, barrier: .init(account: nil, accountGeneration: 4, requestGeneration: 0))
        #expect(!ui.historyEnabled && ui.failure != nil)
        #expect(open.session.current.query.isEmpty && open.session.owner == nil)
    }
    @Test func allChannelRecordsArePurgedAndForeignOwnerPayloadsAreRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WindowRestorationStore(directory: directory), a = try consumerAccount(), b = try consumerAccount()
        let alternate = try AccountContext(accountID: a.id, channelID: ID("alternate-owned-channel"), region: "CH")
        var sessions: [BrowserSession] = []
        for (index, account) in [a.context, alternate, b.context].enumerated() {
            let context = RequestContext(account: account, accountGeneration: UInt64(index + 1), requestGeneration: 0)
            try await store.bind(context)
            var session = BrowserSession(); session.owner = WindowOwner(account)
            session.current.query = "private channel \(index)"
            session.current.selection = Set((0..<50_000).map { "occurrence-\($0)" })
            try await store.save(session, context: context)
            #expect(try await store.restore(window: session.windowID, context: context)?.current.selection.count == 50_000)
            sessions.append(session)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let original = try #require(files.first { $0.lastPathComponent.contains(sessions[0].windowID.uuidString) })
        let foreign = try #require(files.first { $0.lastPathComponent.contains(sessions[2].windowID.uuidString) })
        try Data(contentsOf: original).write(to: foreign, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: foreign.path)
        await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.restore(window: sessions[2].windowID, context: .init(account: b.context, accountGeneration: 3, requestGeneration: 0)) }
        try await store.remove(accountID: a.id)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!remaining.contains { $0.hasPrefix(a.id.uuidString + ".") })
        await #expect(throws: WindowRestorationError.removedAccount) { try await store.bind(.init(account: alternate, accountGeneration: 100, requestGeneration: 0)) }
    }

    @Test func delayedRestoreCannotOverwriteNewOwnerUserEditsOrClosedWindow() throws {
        let ui = WindowNavigationAuthority(), account = try consumerAccount(), other = try consumerAccount(), navigation = BrowserNavigation()
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 0)
        ui.bind(context); ui.register(navigation)
        var saved = navigation.session; saved.current.query = "restored private query"
        #expect(ui.installRestored(saved, context: context, revision: navigation.revision, into: navigation))
        let oldRevision = navigation.revision
        navigation.session.current.query = "new user edit"
        #expect(!ui.installRestored(saved, context: context, revision: oldRevision, into: navigation))
        #expect(navigation.session.current.query == "new user edit")
        let beforeSwitch = navigation.revision
        _ = ui.detach(.init(account: nil, accountGeneration: 2, requestGeneration: 0))
        ui.bind(.init(account: other.context, accountGeneration: 3, requestGeneration: 0))
        #expect(!ui.installRestored(saved, context: context, revision: beforeSwitch, into: navigation))
        #expect(navigation.session.current.query.isEmpty)
        ui.bind(.init(account: account.context, accountGeneration: 4, requestGeneration: 0))
        #expect(!ui.installRestored(saved, context: context, revision: navigation.revision, into: navigation))
        let current = RequestContext(account: account.context, accountGeneration: 4, requestGeneration: 0)
        ui.close(navigation)
        #expect(!ui.installRestored(saved, context: current, revision: navigation.revision, into: navigation))
    }

    @Test func failedOutgoingSaveAllowsOtherOwnerAndOnlyExplicitResetReenablesHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WindowRestorationStore(directory: root), ui = WindowNavigationAuthority(), account = try consumerAccount(), other = try consumerAccount()
        let participant = WindowAccountParticipant(store: store, presentation: ui)
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 0)
        try await participant.restorePaused(.init(account: account), context: context)
        let navigation = BrowserNavigation(); ui.register(navigation); navigation.session.current.query = "latest unsaved private state"; let saved = navigation.session
        try FileManager.default.removeItem(at: root); try Data([1]).write(to: root)
        try await participant.detach(previous: context, barrier: .init(account: nil, accountGeneration: 2, requestGeneration: 0))
        #expect(navigation.session.current.query.isEmpty && !ui.historyEnabled)
        let otherContext = RequestContext(account: other.context, accountGeneration: 3, requestGeneration: 0)
        try await participant.restorePaused(.init(account: other), context: otherContext)
        #expect(ui.context == otherContext && !ui.historyEnabled)
        await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.restore(window: saved.windowID, context: otherContext) }
        #expect(try Data(contentsOf: root) == Data([1]), "Activation did not silently delete the obstructing file")
        #expect(try await store.resetSavedWindowState(context: otherContext))
        let newer = RequestContext(account: account.context, accountGeneration: 4, requestGeneration: 0)
        try await participant.restorePaused(.init(account: account), context: newer)
        #expect(try await store.restore(window: saved.windowID, context: newer) == nil, "Explicit reset discarded pending old private state")
    }

    @Test func deallocatedClosedWindowStillFlushes_N11() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WindowRestorationStore(directory: root), ui = WindowNavigationAuthority(), account = try consumerAccount()
        let participant = WindowAccountParticipant(store: store, presentation: ui)
        let first = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 0)
        try await participant.restorePaused(.init(account: account), context: first)
        var id = UUID(); weak var released: BrowserNavigation?
        do { let navigation = BrowserNavigation(); released = navigation; ui.register(navigation); navigation.session.current.query = "deallocated closed state"; id = navigation.session.windowID; ui.close(navigation) }
        #expect(released == nil)
        try await participant.detach(previous: first, barrier: .init(account: nil, accountGeneration: 2, requestGeneration: 0))
        let next = RequestContext(account: account.context, accountGeneration: 3, requestGeneration: 0)
        try await participant.restorePaused(.init(account: account), context: next)
        #expect(try await store.restore(window: id, context: next)?.current.query == "deallocated closed state")
    }
    @Test func sameAccountOlderGenerationSaveCannotOverwriteNewer_N13() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WindowRestorationStore(directory: root), account = try consumerAccount()
        let one = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 0)
        try await store.bind(one)
        var old = BrowserSession(); old.owner = WindowOwner(account.context); old.current.query = "old generation"
        try await store.detach(previous: one, barrier: .init(account: nil, accountGeneration: 2, requestGeneration: 0), outgoing: [])
        let three = RequestContext(account: account.context, accountGeneration: 3, requestGeneration: 0)
        try await store.bind(three)
        var newest = old; newest.current.query = "new generation"; try await store.save(newest, context: three)
        await #expect(throws: WindowRestorationError.staleOwner) { try await store.save(old, context: one) }
        #expect(try await store.restore(window: old.windowID, context: three)?.current.query == "new generation")
    }

}
