import Testing
import Foundation
import Domain
import AccountSession
@testable import AppShell

@Suite(.serialized) @MainActor struct HistoryFactoryTests {
    @Test(arguments: [0o700, 0o755]) func sharedParentModeDoesNotGateLifecycle(mode: Int) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("history-factory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: parent.path)
        let store = await LocalAccountComposition.windowStore(in: parent), ui = WindowNavigationAuthority(), nav = BrowserNavigation()
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [WindowAccountParticipant(store: store, presentation: ui)])
        let a = try consumerAccount(), b = try consumerAccount()
        try await connectConsumer(lifecycle, a); try await connectConsumer(lifecycle, b)
        try await lifecycle.switchIdentity(to: a.context); ui.register(nav)
        let first = await lifecycle.snapshot().context
        #expect(first.account == a.context && ui.historyEnabled && ui.failure == nil)
        #expect(await lifecycle.accepts(first))
        nav.open(.library); nav.session.current.query = "private account A"
        let saved = nav.session; try await store.save(saved, context: first)
        #expect(try await store.restore(window: saved.windowID, context: first) == saved)
        let folder = parent.appendingPathComponent("window-history")
        #expect((try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            #expect((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        try await lifecycle.switchIdentity(to: b.context)
        let second = await lifecycle.snapshot().context
        #expect(nav.session.owner == WindowOwner(b.context) && nav.session.current.query.isEmpty)
        #expect(try await store.restore(window: saved.windowID, context: second) == nil)
        await #expect(throws: WindowRestorationError.staleOwner) { try await store.save(saved, context: first) }
        try await lifecycle.switchIdentity(to: a.context)
        let newer = await lifecycle.snapshot().context
        #expect(try await store.restore(window: saved.windowID, context: newer)?.current.query == "private account A")
        nav.session.current.query = "live A"; try await lifecycle.remove(a.context)
        #expect(nav.session.owner == nil && nav.session.current.query.isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix(a.id.uuidString) })
        let restarted = await LocalAccountComposition.windowStore(in: parent)
        await #expect(throws: WindowRestorationError.removedAccount) { _ = try await restarted.bind(.init(account: a.context, accountGeneration: 100, requestGeneration: 0)) }
        #expect((try fm.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber)?.intValue == mode, "Never chmod the shared parent")
    }
    @Test(arguments: ["private-mode", "parent-link"]) func historyMetadataFailuresRemainLocalAndSafe(fault: String) async throws {
        let fm = FileManager.default, base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let parent = base.appendingPathComponent("shared"), external = base.appendingPathComponent("outside")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinel = external.appendingPathComponent("keep"); try Data([7]).write(to: sentinel)
        if fault == "parent-link" { try fm.createSymbolicLink(at: parent, withDestinationURL: external) }
        else {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            let privateRoot = parent.appendingPathComponent("window-history")
            try fm.createDirectory(at: privateRoot, withIntermediateDirectories: true); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: privateRoot.path)
        }
        let store = await LocalAccountComposition.windowStore(in: parent), ui = WindowNavigationAuthority(), nav = BrowserNavigation(), work = ScopedAccountWork()
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [WindowAccountParticipant(store: store, presentation: ui), work])
        let account = try consumerAccount(); try await connectConsumer(lifecycle, account); try await lifecycle.switchIdentity(to: account.context); ui.register(nav)
        let context = await lifecycle.snapshot().context
        #expect(context.account == account.context && !ui.historyEnabled && ui.failure == WindowNavigationAuthority.unavailableNotice)
        #expect(await lifecycle.accepts(context))
        let token = try await work.register(context: context, cancel: {}); await work.finish(token)
        nav.open(.library); nav.session.current.query = "ephemeral current query"
        await #expect(throws: WindowRestorationError.storageUnavailable) { try await store.save(nav.session, context: context) }
        await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.restore(window: nav.session.windowID, context: context) }
        #expect(nav.session.current.query == "ephemeral current query")
        if fault == "private-mode" {
            // Models only the explicitly confirmed recovery action on this disposable fixture.
            let enabled = try await store.resetSavedWindowState(context: context)
            ui.historyReset(context: context, enabled: enabled, epoch: await store.currentEpoch)
            #expect(ui.historyEnabled && ui.failure == nil && nav.session.current.query.isEmpty)
            nav.session.current.query = "new verified query"; try await store.save(nav.session, context: context)
            #expect(try await store.restore(window: nav.session.windowID, context: context) == nav.session)
            #expect((try fm.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        } else {
            await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.resetSavedWindowState(context: context) }
            #expect(!fm.fileExists(atPath: external.appendingPathComponent("window-history").path), "Never follow an untrusted parent link")
            #expect(try Data(contentsOf: sentinel) == Data([7]))
        }
        try await lifecycle.signOut(account.context)
        #expect(nav.session.owner == nil && nav.session.current.query.isEmpty)
    }
}
