import Foundation
import Darwin
import Testing
import Domain
import AccountSession
@testable import AppShell

@Suite(.serialized) @MainActor struct RecoveryContinuityTests {
    @Test(arguments: [false, true]) func markerAndFoundationLeftoverRecover_H10(leftover: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try consumerAccount(), first = WindowRestorationStore(directory: root)
        let one = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 0)
        #expect(try await first.bind(one))
        var session = BrowserSession(); session.owner = WindowOwner(account.context); session.current.query = "valid private record"
        try await first.save(session, context: one)
        #expect(try await first.restore(window: session.windowID, context: one) == session)
        let marker = root.appendingPathComponent("reset-in-progress.plist")
        try Data([1]).write(to: marker); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        let stage = root.appendingPathComponent("history-epoch.plist.sb-ee3e07bf-gplhtd")
        if leftover { try Data([7]).write(to: stage); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stage.path) }
        let restarted = WindowRestorationStore(directory: root), two = RequestContext(account: account.context, accountGeneration: 2, requestGeneration: 0)
        #expect(try await !restarted.bind(two))
        await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await restarted.restore(window: session.windowID, context: two) }
        #expect(try await restarted.resetSavedWindowState(context: two))
        #expect(!FileManager.default.fileExists(atPath: marker.path) && !FileManager.default.fileExists(atPath: stage.path))
        #expect(try await restarted.restore(window: session.windowID, context: two) == nil)
    }
    @Test(arguments: ["save", "restore", "close"])
    func actualPersistenceFailurePreservesTwoLiveWindows(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WindowRestorationStore(directory: root), ui = WindowNavigationAuthority(), account = try consumerAccount()
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 0)
        let participant = WindowAccountParticipant(store: store, presentation: ui)
        try await participant.restorePaused(.init(account: account), context: context)
        let first = BrowserNavigation(), second = BrowserNavigation(); ui.register(first); ui.register(second)
        first.open(.library); first.session.current.query = "current live query"; first.session.current.selection = ["occurrence"]
        first.session.current.filter = "Downloaded only"; first.session.current.scrollOffset = 480
        second.open(.downloads); second.session.current.query = "other live query"; second.open(.explore); second.back()
        let a = first.session, b = second.session
        try await store.save(a, context: context)
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "window" })
        if kind == "restore" {
            try Data([1,2,3]).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.restore(window: a.windowID, context: context) }
        } else {
            try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            if kind == "close" { ui.close(first) }
            await #expect(throws: WindowRestorationError.storageUnavailable) { try await store.save(a, context: context) }
        }
        ui.historyUnavailable() // Same actual error handler as BrowserShell; failure above is real I/O.
        #expect(first.session == a && second.session == b)
        #expect(first.session.canBack && second.session.canForward)
        #expect(!ui.historyEnabled && ui.failure != nil && ui.accepts(context))
        first.session.current.query = "newer unsaved edit"; let edited = first.session
        ui.register(first) // Reappearing while persistence is off must also preserve current-owner state.
        #expect(first.session == edited)
        #expect(!ui.installRestored(a, context: context, revision: first.revision, into: first))
        #expect(first.session == edited)
        await #expect(throws: WindowRestorationError.storageUnavailable) { try await store.save(b, context: context) }
    }
    @Test func interruptedRecoveryValidatesStagesAndProtectsActivePublishers() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("windows"), outside = base.appendingPathComponent("outside.txt")
        try Data("outside sentinel".utf8).write(to: outside)
        let account = try consumerAccount(), store = WindowRestorationStore(directory: root)
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 0)
        #expect(try await store.bind(context))
        var privateRecord = BrowserSession(); privateRecord.owner = WindowOwner(account.context); privateRecord.current.query = "private record control"
        try await store.save(privateRecord, context: context)
        let record = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "window" })
        let marker = root.appendingPathComponent("reset-in-progress.plist")
        try Data([1]).write(to: marker); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        let stage = root.appendingPathComponent(record.lastPathComponent + ".sb-ee3e07bf-AbC123")
        try Data([4]).write(to: stage); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stage.path)
        let fd = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        #expect(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.resetSavedWindowState(context: context) }
        #expect(try Data(contentsOf: stage) == Data([4]), "An active publishing lock protects its staging file")
        _ = flock(fd, LOCK_UN); Darwin.close(fd)
        let unsafe = root.appendingPathComponent("removed-accounts.plist.sb-ee3e07bf-Sym123")
        try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: outside)
        await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.resetSavedWindowState(context: context) }
        #expect(try Data(contentsOf: outside) == Data("outside sentinel".utf8))
        #expect(FileManager.default.fileExists(atPath: record.path))
        try FileManager.default.removeItem(at: unsafe)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: stage.path)
        await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.resetSavedWindowState(context: context) }
        #expect(try Data(contentsOf: stage) == Data([4]))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stage.path)
        let finderMetadata = root.appendingPathComponent(".DS_Store"); try Data([9]).write(to: finderMetadata)
        await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.resetSavedWindowState(context: context) }
        #expect(try Data(contentsOf: finderMetadata) == Data([9]))
        try FileManager.default.removeItem(at: finderMetadata)
        let restarted = WindowRestorationStore(directory: root)
        let next = RequestContext(account: account.context, accountGeneration: 2, requestGeneration: 0)
        #expect(try await !restarted.bind(next))
        #expect(try await restarted.resetSavedWindowState(context: next))
        #expect(!FileManager.default.fileExists(atPath: stage.path) && !FileManager.default.fileExists(atPath: record.path))
        let final = WindowRestorationStore(directory: root)
        let third = RequestContext(account: account.context, accountGeneration: 3, requestGeneration: 0)
        #expect(try await final.bind(third))
        #expect(try await final.restore(window: privateRecord.windowID, context: third) == nil)
    }
    @Test func privacyBarriersStillRetractBeforeWaitsWhenHistoryIsOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WindowRestorationStore(directory: root), ui = WindowNavigationAuthority(), held = HeldStorageParticipant()
        let participant = WindowAccountParticipant(store: store, presentation: ui)
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [participant, held])
        let a = try consumerAccount(), b = try consumerAccount()
        try await connectConsumer(lifecycle, a); try await connectConsumer(lifecycle, b); try await lifecycle.switchIdentity(to: a.context)
        let current = await lifecycle.snapshot().context
        let first = BrowserNavigation(), second = BrowserNavigation(); ui.register(first); ui.register(second)
        first.open(.library); first.session.current.query = "live first"; second.open(.downloads); second.session.current.query = "live second"
        let saved = first.session; try await store.save(saved, context: current)
        let record = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "window" })
        try Data([1]).write(to: record); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.restore(window: saved.windowID, context: current) }
        ui.historyUnavailable(); #expect(first.session.current.query == "live first" && second.session.current.query == "live second")
        await held.arm(); let switching = Task { try await lifecycle.switchIdentity(to: b.context) }
        try await consumerEventually { await held.entered }
        #expect(first.session.current.query.isEmpty && second.session.current.query.isEmpty)
        await held.release(); try await switching.value
        first.session.current.query = "B private while persistence off"; second.session.current.selection = ["B selection"]
        try await lifecycle.remove(b.context)
        #expect(first.session.current.query.isEmpty && second.session.current.selection.isEmpty)
    }
    @Test func directBindStoreRestoreAndParticipantAuthorityControls() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let account = try consumerAccount(), bad = base.appendingPathComponent("broken")
        try Data([1]).write(to: bad)
        let direct = WindowRestorationStore(directory: bad), context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 0)
        #expect(try await !direct.bind(context), "H01: exercise bind before detach can mask its own availability catch")
        let store = WindowRestorationStore(directory: base.appendingPathComponent("healthy"))
        #expect(try await store.bind(context))
        var valid = BrowserSession(); valid.owner = WindowOwner(account.context); valid.current.query = "valid private positive control"
        try await store.save(valid, context: context)
        #expect(try await store.restore(window: valid.windowID, context: context) == valid)
        var blocked = valid; blocked.windowID = UUID()
        let obstruction = base.appendingPathComponent("healthy").appendingPathComponent(account.id.uuidString + "." + WindowOwner(account.context).partition + "." + blocked.windowID.uuidString + ".window")
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: false)
        await #expect(throws: WindowRestorationError.storageUnavailable) { try await store.save(blocked, context: context) }
        try FileManager.default.removeItem(at: obstruction)
        await #expect(throws: WindowRestorationError.storageUnavailable) { _ = try await store.restore(window: valid.windowID, context: context) } // H04: storage healthy again, guard alone protects the verified record.
        let other = try consumerAccount(), next = RequestContext(account: other.context, accountGeneration: 2, requestGeneration: 0)
        #expect(try await !store.bind(next), "Recovered physical storage does not admit another owner's pending flush or gate its account")
        let ui = WindowNavigationAuthority(), participant = WindowAccountParticipant(store: store, presentation: ui)
        await #expect(throws: WindowRestorationError.staleOwner) { try await participant.restorePaused(.init(account: account), context: context) }
        let cancelled = Task { try await participant.restorePaused(.init(account: other), context: .init(account: other.context, accountGeneration: 3, requestGeneration: 0)) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

}
