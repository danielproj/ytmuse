import Foundation
import Testing
import Domain
@testable import AccountSession
@testable import Domain
import Security
import SystemIntegration
import WidgetShared
@testable import Persistence
@testable import Features
@testable import AppShell

extension SQLiteStore {
    /// One private canary in every private table of the account (the same population `RemovalTests` seeds), including an UNSENT outbox write.
    func settingsSeedEveryPrivateTable(_ context: RequestContext) throws {
        let account = context.account!, item = try ServiceID("private-media")
        try saveMedia([MediaItem(id: item, kind: .song, title: "W27PRIVATECANARY", artists: [], duration: 5, artwork: [], explicit: false, availability: .available)], context: context)
        let collection = try ServiceID("collection")
        try savePlaylist(Playlist(metadata: .init(id: collection, title: "W27PRIVATECANARY"), owner: ServiceID("synthetic-owner"), privacy: .private, permissions: [:], providerVersion: nil, snapshotVersion: 1), context: context)
        try storeCollectionPage(collection, entries: [.init(occurrence: .synthetic(UUID()), media: item)], startingAt: 0, context: context)
        let entry = try QueueEntry(id: UUID(), media: item, segment: .user, originalOrder: 0)
        try saveQueue(QueueSession(account: account, version: 1, entries: [entry], currentOccurrence: entry.id, position: 1, shuffleSeed: nil, repeatMode: .off, autoplay: false), context: context)
        _ = try store(Preferences(scope: .account(account), schemaVersion: 1, values: ["navigation": .text("W27PRIVATECANARY")]), context: context).outcome.get()
        let id = UUID()
        _ = try enqueue(PendingMutation(id: id, account: account, target: collection, intent: .library(.save(true)), precondition: .init(providerVersion: nil, snapshotVersion: 1), outcome: .pending(id)), context: context).outcome.get()
        try saveMembership(.init(account: account, entity: item, serviceStatus: true, sync: .localOnly, sortDate: nil, sortKey: "private"), context: context)
        try appendHistory(.init(account: account, item: item, startedAt: Date(timeIntervalSince1970: 10), endedAt: nil, provenance: .local, sync: .localOnly), context: context)
        try saveDownload(DownloadJob(account: account, media: item, variant: ServiceID("variant"), ranges: [ByteRange(lower: 0, upper: 10)], state: .paused, size: 11, retries: 0, references: [collection], verification: .unknown), context: context)
        try saveArtwork(.init(sourceKey: ServiceID("art"), width: 32, height: 32, policy: .revalidate, contentHash: "hash", bytes: 2, lastUsedAt: Date()), context: context)
    }
    func settingsPrivateTableCounts(_ account: AccountContext) throws -> [String: Int64] {
        let key = Self.key(account)
        var counts: [String: Int64] = [:]
        for table in ["entities", "collections", "collection_entries", "queues", "queue_entries", "outbox", "memberships", "history", "downloads", "download_ranges", "download_refs", "artwork"] {
            counts[table] = try db.scalar("SELECT count(*) FROM \(table) WHERE scope=?", [.text(key)]).int
        }
        return counts
    }
}

/// Records every path the eraser asks to remove, then lets the guarded file system decide.
final class RecordingFileSystem: ErasureFileSystem, @unchecked Sendable {
    let inner: any ErasureFileSystem
    private let lock = NSLock()
    private(set) var attempts: [URL] = []
    init(_ inner: any ErasureFileSystem) { self.inner = inner }
    func remove(_ url: URL) throws { lock.withLock { attempts.append(url) }; try inner.remove(url) }
    func exists(_ url: URL) -> Bool { inner.exists(url) }
}

/// Everything a destructive-action test needs, all injected and all under one temporary folder: a real account lifecycle over a real SQLite store and an isolated test
/// Keychain file (the settings store is a lifecycle participant, as in the app), a Spotlight index in memory, an App Group stand-in directory, an owned-audio folder and a
/// preferences suite.
@MainActor final class ErasureWorld {
    let scratch: Scratch
    let root: URL, neighbour: URL, groupDirectory: URL, ownedAudio: URL, artworkDirectory: URL
    let store: SQLiteStore
    let lifecycle: AccountLifecycle
    let vault: KeychainVault
    let keychainURL: URL
    let namespace: String
    let a: Account, b: Account
    let guarded: GuardedDefaults, defaults: UserDefaults, suite: String
    let settings: SettingsStore
    let accountBox = AccountBox(nil)
    let index = InMemorySearchableIndex()
    let widgetStore: WidgetSnapshotStore
    let login = InMemoryLoginItemService()
    var clearedCachesFor: [UUID] = [], clearedAllCaches = 0, ownedAudioErased = 0
    let log = DiagnosticLogBox()

    init() async throws {
        scratch = try Scratch()
        root = scratch.url.appendingPathComponent("app", isDirectory: true)
        neighbour = scratch.url.appendingPathComponent("neighbour", isDirectory: true)
        groupDirectory = scratch.url.appendingPathComponent("app-group", isDirectory: true)
        ownedAudio = scratch.url.appendingPathComponent("owned-audio", isDirectory: true)
        artworkDirectory = root.appendingPathComponent("artwork", isDirectory: true)
        for directory in [root, neighbour, groupDirectory, ownedAudio, artworkDirectory] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let context = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
        store = try SQLiteStore(directory: root.appendingPathComponent("database"), context: context)
        let directory = SQLiteAccountDirectory(store: store, context: context)
        (vault, keychainURL, namespace) = try isolatedVault()
        let (guarded, defaults, suite) = privateDefaults(scratch.url.appendingPathComponent("prefs-" + UUID().uuidString).path)
        self.guarded = guarded; self.defaults = defaults; self.suite = suite
        let box = accountBox
        settings = try SettingsStore(backing: guarded, account: { box.account })
        let files = try PrivateAccountFiles(id: "private-files", root: root.appendingPathComponent("accounts"))
        let settingsScope = SettingsAccountParticipant { [settings] in try settings.removeAccount($0) }
        lifecycle = try await AccountLifecycle.open(vault: vault, store: directory, participants: [SQLiteAccountParticipant(store: store, directory: directory), files, settingsScope])
        a = try syntheticAccount("UCsyntheticA001", name: "Synthetic Alpha"); b = try syntheticAccount("UCsyntheticB002", name: "Synthetic Beta")
        for account in [a, b] {
            let challenge = try await lifecycle.beginAuthentication()
            try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("synthetic-disposable-session".utf8))
        }
        widgetStore = WidgetSnapshotStore(directory: groupDirectory)
    }
    /// Runs `body` over a fresh world and always tears it down (database closed, test Keychain file destroyed, scratch folder removed).
    static func with(_ body: @MainActor (ErasureWorld) async throws -> Void) async throws {
        let world = try await ErasureWorld()
        do { try await body(world) } catch { await world.cleanup(); throw error }
        await world.cleanup()
    }
    func cleanup() async {
        await store.close()
        try? await vault.destroyIsolatedTestKeychain()
        try? guarded.removeAll()
        scratch.cleanup()
    }
    var roots: LocalDataRoots {
        LocalDataRoots(applicationDirectory: root, ownedAudioDirectory: ownedAudio, keychainNamespaces: [namespace], preferences: .isolatedPlist(suite), groupDirectory: groupDirectory, searchIndex: .inMemory, isolated: true)
    }
    func seed() async throws {
        try await lifecycle.switchIdentity(to: a.context)
        try await store.settingsSeedEveryPrivateTable(await lifecycle.snapshot().context)
        try widgetStore.write(WidgetSnapshot.redacted(.signedOut, serial: 1, writtenAt: Date()))
        try await SpotlightIndexer(backend: index).reconcile(desired: SpotlightController.actionEntries, accountToken: nil, policy: SpotlightPolicy(enabled: true))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("diagnostics"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("diagnostics/profile.json"))
        try Data("neighbour".utf8).write(to: neighbour.appendingPathComponent("keep.txt"))
        try Data("owned".utf8).write(to: ownedAudio.appendingPathComponent("owned.sqlite"))
        try defaults.set("dark", forKey: "appearance")
        // The account-scope settings of both accounts.
        accountBox.account = a.context.accountID; try await settings.set("newPlaylistVisibility", .text("public"))
        accountBox.account = b.context.accountID; try await settings.set("newPlaylistVisibility", .text("unlisted"))
        accountBox.account = a.context.accountID
        try login.register()
    }
    var touches: LocalDataTouches { LocalDataTouches(artworkDirectory: artworkDirectory, widgetDirectory: groupDirectory, ownedAudioDirectory: ownedAudio, keychainNamespaces: [namespace], preferences: .isolatedPlist(suite), searchIndex: .inMemory) }
    func targets(touches override: LocalDataTouches? = nil) -> LocalDataEraser.Targets {
        let lifecycle = lifecycle, index = index, widget = widgetStore, guarded = guarded, settings = settings, login = login, owned = ownedAudio
        let touches = override ?? self.touches
        return LocalDataEraser.Targets(
            identities: { await lifecycle.snapshot().directory.identities.map(\.id) },
            removeAccount: { try await lifecycle.remove($0) },
            clearAccountCaches: { [unowned self] in self.clearedCachesFor.append($0.accountID) },
            clearAllCaches: { [unowned self] in self.clearedAllCaches += 1 },
            clearSpotlight: { try await SpotlightIndexer(backend: index).removeAll() },
            clearWidgetSnapshot: { try widget.delete() },
            eraseOwnedAudio: { [unowned self] in try GuardedFiles(root: owned).remove(owned, allowRoot: true); self.ownedAudioErased += 1 },
            resetPreferences: { try await settings.resetAll(); try guarded.removeAll(); settings.refreshAfterErase() },
            diagnosticsFiles: ["diagnostics/profile.json", "diagnostics/run-marker.json"],
            clearDiagnosticsLog: { [unowned self] in self.log.cleared = true },
            turnOffLoginItem: { try? login.unregister() },
            touches: { touches })
    }
}
final class DiagnosticLogBox: @unchecked Sendable { var cleared = false }

/// T27.3 and the real-data safety addendum.
@Suite @MainActor struct LocalDataEraserTests {
    @Test func theLocalResetDeletesKeysSnapshotsIndexOutboxOwnedAudioAndAccountSettingsLocallyAndSendsNothing() async throws {
        try await ErasureWorld.with { world in
            try await world.seed()
            let activeContext = await world.lifecycle.snapshot().context
            let counts = try await world.store.settingsPrivateTableCounts(world.a.context)
            #expect(counts["outbox"] == 1 && counts.values.allSatisfy { $0 > 0 }, "the account has an unsent write and data in every private table before the reset: \(counts)")
            let reference = try #require(try await world.lifecycle.reference(for: world.a.context, context: activeContext).outcome.get())
            #expect(!world.index.entries.isEmpty && world.widgetStore.listing() == [WidgetIdentity.snapshotFileName] && world.login.status == .enabled)
            #expect(world.settings.accountIDsWithSettings() == [world.a.context.accountID, world.b.context.accountID])
            let recording = RecordingFileSystem(GuardedFileSystem(root: world.root))
            let eraser = LocalDataEraser(roots: world.roots, fileSystem: recording, targets: world.targets())
            let report = await eraser.eraseEverything(confirmation: nil)
            #expect(report.succeeded, "\(report)")
            #expect(report.steps.filter { $0.name == "account" }.count == 2, "both accounts were removed")
            let remaining = await world.lifecycle.snapshot().directory.identities
            #expect(remaining.isEmpty)
            // keys
            await #expect(throws: (any Error).self) { _ = try await world.vault.read(reference, context: activeContext) }
            // database rows, the unsent outbox write among them
            let after = try await world.store.settingsPrivateTableCounts(world.a.context)
            #expect(after.values.allSatisfy { $0 == 0 }, "\(after)")
            // each account's own settings went with it (the settings store is a lifecycle participant)
            #expect(world.settings.accountIDsWithSettings().isEmpty, "SEC08: account-scope settings are deleted with the account")
            // snapshot, index, owned audio, diagnostics files, preferences, login item, caches
            #expect(world.widgetStore.listing().isEmpty && world.index.entries.isEmpty)
            #expect(world.ownedAudioErased == 1 && !FileManager.default.fileExists(atPath: world.ownedAudio.path), "the owned-audio store beside the application directory is gone")
            #expect(!FileManager.default.fileExists(atPath: world.root.appendingPathComponent("diagnostics/profile.json").path) && world.log.cleared)
            #expect(world.defaults.string(forKey: "appearance") == nil && world.login.status != .enabled && world.clearedAllCaches == 1)
            // nothing outside the injected roots was touched
            #expect(FileManager.default.fileExists(atPath: world.neighbour.appendingPathComponent("keep.txt").path))
            let injected = DestructiveActionGuard.canonical(world.root)
            #expect(!recording.attempts.isEmpty && recording.attempts.allSatisfy { DestructiveActionGuard.contains(injected, DestructiveActionGuard.canonical($0)) })
            for file in try FileManager.default.contentsOfDirectory(at: world.root.appendingPathComponent("database"), includingPropertiesForKeys: nil) where file.pathExtension == "sqlite" || file.lastPathComponent.hasSuffix("-wal") {
                #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("W27PRIVATECANARY"))
            }
        }
    }

    @Test func removingAnAccountThroughTheLifecycleDeletesItsSettingsOnEveryPath() async throws {
        try await ErasureWorld.with { world in
            try await world.seed()
            // The Accounts sheet calls the lifecycle directly (AccountsModel.remove); no eraser is involved.
            try await world.lifecycle.remove(world.a.context)
            #expect(world.settings.accountIDsWithSettings() == [world.b.context.accountID], "only A's account-scope settings went; B's and the global scope stay")
            #expect(world.defaults.string(forKey: "appearance") == "dark")
        }
    }

    @Test func aStepThatFailsDoesNotStopTheOthersAndTheReportNamesIt() async throws {
        try await ErasureWorld.with { world in
            try await world.seed()
            var targets = world.targets()
            struct Boom: Error {}
            targets.clearSpotlight = { throw Boom() }
            let eraser = LocalDataEraser(roots: world.roots, fileSystem: GuardedFileSystem(root: world.root), targets: targets)
            let report = await eraser.eraseEverything(confirmation: nil)
            #expect(!report.succeeded && report.failedSteps == ["spotlight"])
            #expect(await world.lifecycle.snapshot().directory.identities.isEmpty && world.widgetStore.listing().isEmpty, "the remaining steps still ran")
            let again = await LocalDataEraser(roots: world.roots, fileSystem: GuardedFileSystem(root: world.root), targets: world.targets()).eraseEverything(confirmation: nil)
            #expect(again.succeeded && world.index.entries.isEmpty, "running it again finishes the job")
        }
    }

    @Test func clearingOneAccountsCacheTouchesNothingElse() async throws {
        try await ErasureWorld.with { world in
            try await world.seed()
            let eraser = LocalDataEraser(roots: world.roots, fileSystem: GuardedFileSystem(root: world.root), targets: world.targets())
            let report = await eraser.clearCaches(of: world.a.context, confirmation: nil)
            #expect(report.succeeded && world.clearedCachesFor == [world.a.context.accountID])
            let counts = try await world.store.settingsPrivateTableCounts(world.a.context)
            #expect(counts.values.allSatisfy { $0 > 0 } && counts["outbox"] == 1, "the account's data and queued writes stay")
            #expect(await world.lifecycle.snapshot().directory.identities.count == 2 && !world.widgetStore.listing().isEmpty && !world.index.entries.isEmpty)
        }
    }

    @Test func removingOneAccountLeavesTheOther() async throws {
        try await ErasureWorld.with { world in
            try await world.seed()
            let eraser = LocalDataEraser(roots: world.roots, fileSystem: GuardedFileSystem(root: world.root), targets: world.targets())
            let report = await eraser.removeAccount(world.a.context, confirmation: nil)
            #expect(report.succeeded)
            #expect(await world.lifecycle.snapshot().directory.identities.map(\.id) == [world.b.context])
            #expect(world.settings.accountIDsWithSettings() == [world.b.context.accountID])
        }
    }

    // MARK: Real-data safety

    @Test func aDestructiveActionOnAnyRealRootIsRefusedInAnIsolatedSessionBeforeAnythingIsTouched() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let real = RealStores.current
        func roots(app: URL? = nil, owned: URL? = nil, namespaces: [String]? = nil, prefs: LocalDataRoots.PreferencesRoot = .memory, group: URL? = nil, index: LocalDataRoots.IndexRoot = .inMemory) -> LocalDataRoots {
            LocalDataRoots(applicationDirectory: app ?? scratch.url, ownedAudioDirectory: owned ?? scratch.url.appendingPathComponent("owned"),
                           keychainNamespaces: namespaces ?? [KeychainVault.applicationNamespace + ".test." + UUID().uuidString], preferences: prefs, groupDirectory: group, searchIndex: index, isolated: true)
        }
        #expect(throws: Never.self) { try DestructiveActionGuard.verify(roots(), confirmation: nil) }
        // The real application directory and anything inside it (the database among it).
        for path in [real.applicationSupport, real.applicationSupport.appendingPathComponent("database"), real.applicationSupport.appendingPathComponent("accounts/anything")] {
            #expect(throws: DestructiveActionRefusal.self) { try DestructiveActionGuard.verify(roots(app: path), confirmation: nil) }
            #expect(throws: DestructiveActionRefusal.self) { try DestructiveActionGuard.verify(roots(app: path), confirmation: PersonConfirmation.fromConfirmationButton()) }
        }
        // The REAL OWNED-AUDIO store (beside, not inside, the application directory) and anything inside it.
        for path in [real.ownedAudio, real.ownedAudio.appendingPathComponent("retained"), real.ownedAudio.appendingPathComponent("database.sqlite")] {
            #expect(throws: DestructiveActionRefusal.realRoot("owned-audio directory")) { try DestructiveActionGuard.verify(roots(owned: path), confirmation: nil) }
        }
        #expect(real.containsRealPath(real.ownedAudio) && real.containsRealPath(real.applicationSupport) && !real.containsRealPath(scratch.url))
        // The real Keychain namespace, and any namespace that is not test-named.
        #expect(throws: DestructiveActionRefusal.realRoot("keychain namespace")) { try DestructiveActionGuard.verify(roots(namespaces: [real.keychainNamespace]), confirmation: nil) }
        #expect(throws: DestructiveActionRefusal.realRoot("keychain namespace")) { try DestructiveActionGuard.verify(roots(namespaces: ["some.other.namespace"]), confirmation: nil) }
        #expect(throws: DestructiveActionRefusal.realRoot("keychain namespace")) { try DestructiveActionGuard.verify(roots(namespaces: [KeychainVault.applicationNamespace + ".test.ok", real.keychainNamespace]), confirmation: nil) }
        // The standard preferences domain, the real Spotlight index, the real App Group.
        #expect(throws: DestructiveActionRefusal.realRoot("preferences domain")) { try DestructiveActionGuard.verify(roots(prefs: .standardDomain(real.preferencesDomain)), confirmation: nil) }
        #expect(throws: DestructiveActionRefusal.realRoot("Spotlight index")) { try DestructiveActionGuard.verify(roots(index: .system), confirmation: nil) }
        let realGroup = real.groupContainers.appendingPathComponent("group.local.native-music.development")
        #expect(throws: DestructiveActionRefusal.self) { try DestructiveActionGuard.verify(roots(group: realGroup), confirmation: nil) }
        // A folder that is merely not temporary is also not an isolated root.
        #expect(throws: DestructiveActionRefusal.self) { try DestructiveActionGuard.verify(roots(app: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")), confirmation: nil) }
        // A symlink in the temporary folder that points at a real root resolves to it and is refused.
        let link = scratch.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.applicationSupport)
        #expect(throws: DestructiveActionRefusal.self) { try DestructiveActionGuard.verify(roots(app: link), confirmation: nil) }
        // A session that DECLARES itself not isolated is still isolated in a test process: the process decides.
        let lying = LocalDataRoots(applicationDirectory: real.applicationSupport, ownedAudioDirectory: real.ownedAudio, keychainNamespaces: [real.keychainNamespace], preferences: .standardDomain("x"), groupDirectory: nil, searchIndex: .system, isolated: false)
        #expect(throws: DestructiveActionRefusal.self) { try DestructiveActionGuard.verify(lying, confirmation: PersonConfirmation.fromConfirmationButton()) }
    }

    /// Review finding 1: the check is made on what the destructive objects ACTUALLY hold, not on what the session declares.
    @Test func theGuardRefusesWhenTheObjectsHoldARealStoreEvenIfTheDeclaredRootsAreClean() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let real = RealStores.current
        let app = scratch.url.appendingPathComponent("app"), group = scratch.url.appendingPathComponent("group"), owned = scratch.url.appendingPathComponent("owned")
        for directory in [app, group, owned] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let namespace = KeychainVault.applicationNamespace + ".test." + UUID().uuidString
        let roots = LocalDataRoots(applicationDirectory: app, ownedAudioDirectory: owned, keychainNamespaces: [namespace], preferences: .isolatedPlist(scratch.url.appendingPathComponent("p.plist").path), groupDirectory: group, searchIndex: .inMemory, isolated: true)
        let clean = LocalDataTouches(artworkDirectory: app.appendingPathComponent("artwork"), widgetDirectory: group, ownedAudioDirectory: owned, keychainNamespaces: [namespace], preferences: roots.preferences, searchIndex: .inMemory)
        #expect(throws: Never.self) { try DestructiveActionGuard.verify(roots, touches: clean, confirmation: nil) }
        func refused(_ mutate: (inout LocalDataTouches) -> Void, _ comment: Comment) {
            var touches = clean; mutate(&touches)
            #expect(throws: DestructiveActionRefusal.self, comment) { try DestructiveActionGuard.verify(roots, touches: touches, confirmation: nil) }
        }
        refused({ $0.artworkDirectory = real.applicationSupport.appendingPathComponent("artwork") }, "a hard-coded real artwork cache")
        refused({ $0.artworkDirectory = scratch.url.appendingPathComponent("elsewhere") }, "an artwork cache outside the declared application directory")
        refused({ $0.widgetDirectory = real.groupContainers.appendingPathComponent("group.local.native-music.development") }, "the real App Group")
        refused({ $0.ownedAudioDirectory = real.ownedAudio }, "the real owned-audio store")
        refused({ $0.keychainNamespaces = [real.keychainNamespace] }, "the production Keychain namespace")
        refused({ $0.keychainNamespaces = [namespace, namespace + ".other"] }, "a namespace that was not declared")
        refused({ $0.preferences = .standardDomain(real.preferencesDomain) }, "the standard preferences domain")
        refused({ $0.preferences = .isolatedPlist(scratch.url.appendingPathComponent("other.plist").path) }, "a different preferences file")
        refused({ $0.searchIndex = .system }, "the system Spotlight index")
        // The diagnostic text names the verdict.
        var bad = clean; bad.keychainNamespaces = [real.keychainNamespace]
        #expect(DestructiveActionGuard.verdict(roots, touches: clean) == "accepted" && DestructiveActionGuard.verdict(roots, touches: bad).hasPrefix("refused"))
    }

    @Test func aSessionThatIsNotIsolatedActsOnlyWithThePersonsConfirmation() throws {
        // Evaluated on a FAKE home with the process flag forced off: nothing real is named, nothing is opened.
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let fake = RealRoots(home: scratch.url.appendingPathComponent("home"))
        let live = LocalDataRoots(applicationDirectory: fake.applicationSupport, ownedAudioDirectory: fake.ownedAudio, keychainNamespaces: [fake.keychainSessionNamespace], preferences: .standardDomain("x"), groupDirectory: nil, searchIndex: .system, isolated: false)
        #expect(throws: DestructiveActionRefusal.notConfirmed) { try DestructiveActionGuard.verify(live, confirmation: nil, real: fake, processIsolated: false) }
        #expect(throws: Never.self) { try DestructiveActionGuard.verify(live, confirmation: PersonConfirmation.fromConfirmationButton(), real: fake, processIsolated: false) }
        #expect(throws: DestructiveActionRefusal.self) { try DestructiveActionGuard.verify(live, confirmation: PersonConfirmation.fromConfirmationButton(), real: fake, processIsolated: true) }
    }

    @Test func theTestProcessIsAlwaysIsolated() {
        #expect(AppPlaybackAuthority.processIsolationRequested && LaunchStorageDecision.isIsolated && ProcessIsolation.isIsolated, "a unit-test process is isolated, so no real root can satisfy the guard")
    }

    @Test func theGuardedWrappersRefuseARealStoreAtTheCall() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let fake = RealRoots(home: scratch.url.appendingPathComponent("home"))
        // Files: a path inside the owned-audio store or the application directory is refused although the owner's own root contains it.
        for realRoot in [fake.ownedAudio, fake.applicationSupport] {
            try FileManager.default.createDirectory(at: realRoot.appendingPathComponent("db"), withIntermediateDirectories: true)
            let file = realRoot.appendingPathComponent("db/store.sqlite"); try Data("x".utf8).write(to: file)
            #expect(throws: GuardRefusal.realRoot("path")) { try GuardedFiles(root: realRoot, isolated: true, real: fake).remove(file) }
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        // Keychain: a production service name is refused in this (isolated) process; a test-namespaced one is allowed through.
        func query(_ service: String) -> CFDictionary { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "x"] as CFDictionary }
        #expect(!GuardedKeychain.allows(query(KeychainVault.applicationNamespace)) && !GuardedKeychain.allows(query(KeychainVault.applicationNamespace + ".google-candidate")) && !GuardedKeychain.allows(query(KeychainVault.applicationNamespace + ".oauth-config")))
        #expect(!GuardedKeychain.allows([kSecClass as String: kSecClassGenericPassword] as CFDictionary), "a query with no service name is refused too")
        #expect(GuardedKeychain.allows(query(KeychainVault.applicationNamespace + ".test." + UUID().uuidString)))
        // The Security call is a RECORDING FAKE: a broken guard can only reach the fake, never the real Keychain, and no production name reaches a real destructive API.
        var reached: [String] = []
        let fakeDelete: (CFDictionary) -> OSStatus = { reached.append("delete:" + (GuardedKeychain.service(of: $0) ?? "")); return errSecSuccess }
        let fakeUpdate: (CFDictionary, CFDictionary) -> OSStatus = { query, _ in reached.append("update:" + (GuardedKeychain.service(of: query) ?? "")); return errSecSuccess }
        for production in [KeychainVault.applicationNamespace, KeychainVault.applicationNamespace + ".google-candidate"] {
            #expect(GuardedKeychain.delete(query(production), backend: fakeDelete) == GuardedKeychain.refused, "refused before the Security framework is asked")
            #expect(GuardedKeychain.update(query(production), [kSecValueData as String: Data()] as CFDictionary, backend: fakeUpdate) == GuardedKeychain.refused)
        }
        #expect(reached.isEmpty, "the backend was never called for a production service name: \(reached)")
        let allowed = KeychainVault.applicationNamespace + ".test." + UUID().uuidString
        #expect(GuardedKeychain.delete(query(allowed), backend: fakeDelete) == errSecSuccess && GuardedKeychain.update(query(allowed), [kSecValueData as String: Data()] as CFDictionary, backend: fakeUpdate) == errSecSuccess)
        #expect(reached == ["delete:" + allowed, "update:" + allowed], "a test-named service reaches the backend")
    }

    /// R2-2: `isolated` may only TIGHTEN the check, and a move or a copy is held to the same rules as a delete. Everything here uses a FAKE home inside the scratch folder,
    /// so even a broken guard could only touch the scratch folder.
    @Test func isolatedFalseNeverLoosensTheCheckAndMovesAndCopiesAreGuardedLikeDeletes() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let fake = RealStores(home: scratch.url.appendingPathComponent("home"))
        let store = fake.applicationSupport.appendingPathComponent("db")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let file = store.appendingPathComponent("store.sqlite"); try Data("x".utf8).write(to: file)
        // The test process is isolated, so `isolated: false` cannot switch the real-store refusal off.
        let loose = GuardedFiles(root: fake.applicationSupport, isolated: false, real: fake)
        #expect(throws: GuardRefusal.realRoot("path")) { try loose.remove(file) }
        #expect(throws: GuardRefusal.realRoot("path")) { try loose.move(file, to: store.appendingPathComponent("moved.sqlite")) }
        #expect(throws: GuardRefusal.realRoot("path")) { try loose.copy(file, to: store.appendingPathComponent("copy.sqlite")) }
        #expect(FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: store.appendingPathComponent("moved.sqlite").path) && !FileManager.default.fileExists(atPath: store.appendingPathComponent("copy.sqlite").path))
        // Moving or copying out of, or into, the root is refused too.
        let root = scratch.url.appendingPathComponent("owner"), outside = scratch.url.appendingPathComponent("outside")
        for directory in [root, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("y".utf8).write(to: root.appendingPathComponent("a.txt")); try Data("z".utf8).write(to: outside.appendingPathComponent("b.txt"))
        let files = GuardedFiles(root: root)
        #expect(throws: GuardRefusal.outsideRoot) { try files.move(root.appendingPathComponent("a.txt"), to: outside.appendingPathComponent("a.txt")) }
        #expect(throws: GuardRefusal.outsideRoot) { try files.move(outside.appendingPathComponent("b.txt"), to: root.appendingPathComponent("b.txt")) }
        #expect(throws: GuardRefusal.outsideRoot) { try files.copy(root.appendingPathComponent("a.txt"), to: outside.appendingPathComponent("c.txt")) }
        #expect(throws: GuardRefusal.outsideRoot) { try files.move(root, to: root.appendingPathComponent("inside")) }
        try files.move(root.appendingPathComponent("a.txt"), to: root.appendingPathComponent("a2.txt"))
        try files.copy(root.appendingPathComponent("a2.txt"), to: root.appendingPathComponent("a3.txt"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a2.txt").path) && FileManager.default.fileExists(atPath: root.appendingPathComponent("a3.txt").path) && !FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    @Test func theGuardedFileSystemRefusesEverythingOutsideItsRoot() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let root = scratch.url.appendingPathComponent("app"), outside = scratch.url.appendingPathComponent("outside")
        for directory in [root, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("x".utf8).write(to: outside.appendingPathComponent("f.txt")); try Data("y".utf8).write(to: root.appendingPathComponent("in.txt"))
        let fileSystem = GuardedFileSystem(root: root)
        #expect(throws: DestructiveActionRefusal.outsideInjectedRoot) { try fileSystem.remove(root) }
        #expect(throws: DestructiveActionRefusal.outsideInjectedRoot) { try fileSystem.remove(outside.appendingPathComponent("f.txt")) }
        #expect(throws: DestructiveActionRefusal.outsideInjectedRoot) { try fileSystem.remove(root.appendingPathComponent("../outside/f.txt")) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(throws: DestructiveActionRefusal.outsideInjectedRoot) { try fileSystem.remove(root.appendingPathComponent("escape/f.txt")) }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("f.txt").path))
        try fileSystem.remove(root.appendingPathComponent("in.txt"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("in.txt").path))
        try fileSystem.remove(root.appendingPathComponent("missing.txt"))   // already gone: nothing to do, no error
        // A link INSIDE the root is unlinked, never followed.
        try fileSystem.remove(root.appendingPathComponent("escape"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path) && FileManager.default.fileExists(atPath: outside.appendingPathComponent("f.txt").path), "the link went, its destination stayed")
    }

    /// The eraser built from injected roots deletes only inside them, even when asked for a name that tries to leave (a hard-coded real path is such a request).
    @Test func theEraserNeverAsksToDeleteOutsideTheInjectedRootNorInsideARealOne() async throws {
        try await ErasureWorld.with { world in
            try await world.seed()
            let recording = RecordingFileSystem(GuardedFileSystem(root: world.root))
            var targets = world.targets()
            targets.diagnosticsFiles += ["../neighbour/keep.txt"]
            let report = await LocalDataEraser(roots: world.roots, fileSystem: recording, targets: targets).eraseEverything(confirmation: nil)
            #expect(report.failedSteps == ["diagnostics"], "the escaping name is refused: \(report)")
            #expect(FileManager.default.fileExists(atPath: world.neighbour.appendingPathComponent("keep.txt").path))
            let real = DestructiveActionGuard.canonical(RealStores.current.applicationSupport), realOwned = DestructiveActionGuard.canonical(RealStores.current.ownedAudio)
            #expect(recording.attempts.allSatisfy { !DestructiveActionGuard.contains(real, DestructiveActionGuard.canonical($0)) && !DestructiveActionGuard.contains(realOwned, DestructiveActionGuard.canonical($0)) }, "no deletion was ever asked for inside a real store")
            let injected = DestructiveActionGuard.canonical(world.root)
            #expect(recording.attempts.filter { !DestructiveActionGuard.contains(injected, DestructiveActionGuard.canonical($0)) }.count == 1, "only the one deliberately escaping name left the root, and it was refused")
        }
    }

    @Test func theEraserRefusesWhenItsTargetsHoldARealStoreEvenIfTheRootsAreClean() async throws {
        try await ErasureWorld.with { world in
            try await world.seed()
            var holdsReal = world.touches
            holdsReal.ownedAudioDirectory = RealStores.current.ownedAudio
            let eraser = LocalDataEraser(roots: world.roots, fileSystem: GuardedFileSystem(root: world.root), targets: world.targets(touches: holdsReal))
            let report = await eraser.eraseEverything(confirmation: nil)
            #expect(report.refusal != nil && report.steps.isEmpty, "refused before a single step ran: \(report)")
            #expect(await world.lifecycle.snapshot().directory.identities.count == 2 && world.ownedAudioErased == 0)
            let cleared = await eraser.clearCaches(of: world.a.context, confirmation: nil), removed = await eraser.removeAccount(world.a.context, confirmation: nil)
            #expect(cleared.refusal != nil && removed.refusal != nil)
        }
    }
}

extension ComposedBootstrapSuites {
/// The same reset on the objects the APP composes: `LocalAccountBootstrap` builds the roots, the eraser and its targets from the live owners of an isolated session.
@Suite @MainActor struct ComposedLocalDataTests {
    @Test func theComposedEraserActsOnThisSessionsInjectedRootsAndResetsTheLiveOwners() async throws {
        let bootstrap = LocalAccountBootstrap(loginItem: InMemoryLoginItemService())
        bootstrap.installSystemSurfaces(hub: IntentHub(), receiver: WidgetCommandReceiver())
        await bootstrap.load()
        let isolated = try #require(bootstrap.isolatedStorage, "a test process is an isolated session")
        let roots = try #require(bootstrap.localRoots)
        let eraser = try #require(bootstrap.eraser)
        let lifecycle = try #require(bootstrap.lifecycleHandle)
        // The roots ARE this session's injected ones, and the guard accepts them AND what the live objects hold.
        #expect(roots.isolated && roots.applicationDirectory == isolated.root && roots.keychainNamespaces == isolated.keychainNamespaces)
        #expect(roots.ownedAudioDirectory == bootstrap.playback.authority.ownedAudioDirectory && roots.ownedAudioDirectory.path.hasPrefix(isolated.root.path))
        #expect(roots.searchIndex == .inMemory && roots.groupDirectory == bootstrap.resolvedServices?.groupDirectory)
        if case .isolatedPlist(let path) = roots.preferences { #expect(path == AppPreferences.resolved.isolatedPath) } else { Issue.record("an isolated session names its throwaway preferences plist, got \(roots.preferences)") }
        let touches = eraser.targets.touches()
        #expect(touches.artworkDirectory == bootstrap.artwork?.cacheDirectory && touches.widgetDirectory == bootstrap.widgetPublisher?.directory && touches.searchIndex == .inMemory)
        #expect(Set(touches.keychainNamespaces) == Set(isolated.keychainNamespaces), "the namespaces the vaults themselves report: \(touches.keychainNamespaces)")
        #expect(throws: Never.self) { try DestructiveActionGuard.verify(roots, touches: touches, confirmation: nil) }
        let readout = RootsReadout.text(roots, touches: touches)
        #expect(readout.hasPrefix("roots: isolated; guard=accepted") && readout.contains("keychain=test,test") && !readout.contains("REAL") && !readout.contains("PRODUCTION"), Comment(rawValue: readout))
        for owner in ["loginItem", "miniPlayer", "downloads", "spotlight", "notifications", "shortcuts", "outputs", "diagnostics"] { #expect(bootstrap.settings.hasOwner(owner), "\(owner) is attached") }
        #expect(bootstrap.settings.preflight != nil, "every Restore Defaults runs the guard first")

        // Two accounts, settings of every scope, the live owners switched on, a widget snapshot, indexed entries, an owned-audio file.
        let a = try syntheticAccount("UCcomposedA0001", name: "Composed Alpha"), b = try syntheticAccount("UCcomposedB0002", name: "Composed Beta")
        for account in [a, b] {
            let challenge = try await lifecycle.beginAuthentication()
            try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("synthetic-disposable-session".utf8))
        }
        await bootstrap.model.refresh()
        await bootstrap.model.switchIdentity(a.context)
        try await bootstrap.settings.set("appearance", .text("dark")); try await bootstrap.settings.set("newPlaylistVisibility", .text("public"))
        try await bootstrap.settings.set("launchAtLogin", .bool(true)); try await bootstrap.settings.set("spotlightIndexing", .bool(true))
        #expect(bootstrap.shell.loginItem.isOn && bootstrap.shell.spotlightSettings.enabled)
        let group = try #require(roots.groupDirectory)
        try WidgetSnapshotStore(directory: group).write(WidgetSnapshot.redacted(.signedOut, serial: 1, writtenAt: Date()))
        let diagnostics = roots.applicationDirectory.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: diagnostics.appendingPathComponent("profile.json"))
        try FileManager.default.createDirectory(at: roots.ownedAudioDirectory, withIntermediateDirectories: true)
        try Data("owned".utf8).write(to: roots.ownedAudioDirectory.appendingPathComponent("owned.sqlite"))
        bootstrap.diagnosticLog.record(.sourceOutage, component: "adapter", detail: "no answer")
        #expect(bootstrap.diagnosticLog.count >= 1 && !bootstrap.settings.accountIDsWithSettings().isEmpty)

        let report = await eraser.eraseEverything(confirmation: nil)
        #expect(report.succeeded, "\(report)")
        let after = await lifecycle.snapshot()
        #expect(after.directory.identities.isEmpty, "every account was removed from this Mac")
        #expect(bootstrap.settings.accountIDsWithSettings().isEmpty && bootstrap.settings.text("appearance") == "system")
        #expect(AppPreferences.store.string(forKey: "appearance") == nil, "the preferences root was emptied")
        #expect(!bootstrap.shell.loginItem.isOn && !bootstrap.shell.spotlightSettings.enabled, "the live owners were reset")
        #expect(WidgetSnapshotStore(directory: group).read() == .missing, "the widget snapshot is gone")
        #expect(!FileManager.default.fileExists(atPath: roots.ownedAudioDirectory.path), "the owned-audio store is gone")
        #expect(!FileManager.default.fileExists(atPath: diagnostics.appendingPathComponent("profile.json").path) && bootstrap.diagnosticLog.count == 0)
        #expect(bootstrap.localRoots == roots)
        await bootstrap.shutdown()
    }

    @Test func removingAnAccountFromTheAccountsSheetDeletesItsSettings() async throws {
        let rig = try await ComposedRig.make(); defer { Task { await rig.finish() } }
        try await rig.settings.set("newPlaylistVisibility", .text("public"))
        #expect(rig.settings.accountIDsWithSettings().contains(rig.account.context.accountID))
        await rig.bootstrap.model.remove(rig.account.context)   // exactly what the Accounts sheet calls
        #expect(!rig.settings.accountIDsWithSettings().contains(rig.account.context.accountID), "the account's own settings left with it")
    }

    @Test func restoreDefaultsGoesThroughTheGuardAndTheRememberedOutputHasItsOwnAction() async throws {
        let rig = try await ComposedRig.make(); defer { Task { await rig.finish() } }
        try await rig.settings.set("crossfade", .double(3)); try await rig.settings.set("appearance", .text("dark"))
        // The composed Restore Defaults reaches the output owner only through the remembered output's own action.
        var outputResets = 0
        rig.settings.attach(owner: "outputs", SettingOwnerBinding(read: { _ in nil }, reset: { outputResets += 1 }))
        #expect(await rig.bootstrap.restoreDefaults(.playback, confirmed: true) == nil)
        #expect(rig.settings.double("crossfade") == 0 && rig.settings.text("appearance") == "dark", "only the Playback page was restored")
        #expect(outputResets == 0, "Restore Defaults on Playback did not forget the remembered output")
        #expect(await rig.bootstrap.restoreDefaults(nil, only: "outputRoute", confirmed: true) == nil)
        #expect(outputResets == 1, "Forget Remembered Output is the action that does")
        // A guard that refuses stops a restore before anything changes.
        try await rig.settings.set("crossfade", .double(3))
        let eraser = try #require(rig.bootstrap.eraser)
        let refusing = LocalDataEraser(roots: rig.bootstrap.localRoots!, fileSystem: GuardedFileSystem(root: rig.bootstrap.localRoots!.applicationDirectory), targets: {
            var targets = eraser.targets; targets.touches = { var t = eraser.targets.touches(); t.keychainNamespaces = [RealStores.current.keychainNamespace]; return t }; return targets }())
        rig.bootstrap.eraser = refusing
        let note = await rig.bootstrap.restoreDefaults(.playback, confirmed: true)
        #expect(note?.hasPrefix("refused") == true && rig.settings.double("crossfade") == 3, "refused, and nothing was restored: \(String(describing: note))")
    }

    @Test func profilingChosenBeforeLaunchRecordsTheLaunchTimingAndNothingElseUntilChosen() async throws {
        // Off (the default): no timing is kept and no file is written.
        let quiet = LocalAccountBootstrap(loginItem: InMemoryLoginItemService())
        await quiet.load()
        #expect(quiet.profiler?.isEnabled == false && quiet.profiler?.summary().isEmpty == true)
        let root = quiet.isolatedStorage?.root
        #expect(root.map { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("diagnostics/profile.json").path) } == true)
        await quiet.shutdown()
        // On: the choice is read from the preferences store at launch.
        try AppPreferences.guarded.set(true, forKey: SettingsOwners.profilingKey); defer { try? AppPreferences.guarded.remove(SettingsOwners.profilingKey) }
        let bootstrap = LocalAccountBootstrap(loginItem: InMemoryLoginItemService())
        await bootstrap.load()
        let profiler = try #require(bootstrap.profiler)
        #expect(profiler.isEnabled && profiler.summary()[.launchToAccountReady]?.count == 1, "\(profiler.summary())")
        #expect(profiler.summary()[.searchRequest] == nil && profiler.summary()[.playbackStart] == nil)
        await bootstrap.shutdown()
    }
}
}
