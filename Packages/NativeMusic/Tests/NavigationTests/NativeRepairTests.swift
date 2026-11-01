import Testing
import Foundation
import SwiftUI
import AppKit
import Domain
import AccountSession
@testable import AppShell

@Suite(.serialized) @MainActor struct NativeRepairTests {
    @Test(arguments: [false, true]) func parentCreationDoesNotDisableSaveOrRestore(parentPresent: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("window-parent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        if parentPresent { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let store = WindowRestorationStore(directory: root.appendingPathComponent("windows"))
        let account = try consumerAccount().context, context = RequestContext(account: account, accountGeneration: 1, requestGeneration: 1)
        #expect(try await store.bind(context))
        var session = BrowserSession(); session.owner = WindowOwner(account); session.historyEpoch = await store.currentEpoch
        session.current.query = "private saved query"; session.current.filter = "Downloaded only"
        try await store.save(session, context: context)
        let restored = try #require(try await store.restore(window: session.windowID, context: context))
        #expect(restored == session)
        #expect(await store.historyAvailable)
    }
    @Test func actualBootstrapFactoryCreatesFreshParentBeforeStoreAndLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-profile-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // This is the factory called by both real LocalAccountBootstrap paths, with an isolated profile.
        let store = await LocalAccountComposition.windowStore(in: root)
        #expect(FileManager.default.fileExists(atPath: root.path))
        let ui = WindowNavigationAuthority(), nav = BrowserNavigation()
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [WindowAccountParticipant(store: store, presentation: ui)])
        let account = try consumerAccount(); try await connectConsumer(lifecycle, account)
        try await lifecycle.switchIdentity(to: account.context); ui.register(nav)
        let context = await lifecycle.snapshot().context
        nav.open(.library); nav.session.current.query = "fresh profile"
        try await store.save(nav.session, context: context)
        #expect(try await store.restore(window: nav.session.windowID, context: context) == nav.session)
        #expect(ui.historyEnabled && ui.failure == nil)
        // A replacement parent link still fails closed; an equal path string is not a link bypass.
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        await #expect(throws: WindowRestorationError.storageUnavailable) { try await store.save(nav.session, context: context) }
        #expect(!(await store.historyAvailable))
    }
}
