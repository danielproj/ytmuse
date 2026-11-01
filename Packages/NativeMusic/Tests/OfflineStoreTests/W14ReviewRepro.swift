// W14 independent critic (opus-01) bounded repro. Temporary; archived under
// artifacts/harness/critiques/W14-opus-01/repro/ and removed from the test target afterwards.
// Uses only isolated test Keychains, temp directories and the repository's owned synthetic WAVE.
import XCTest
import Foundation
import Synchronization
import Darwin
@preconcurrency import AVFoundation
import Domain
import Downloads
import AccountSession
import Playback

private final class RClock: WallClock, Sendable {
    let value = Mutex(Date())
    func now() -> Date { value.withLock { $0 } }
    func jump(_ seconds: Double) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
private actor CountingVault: ScopedProtectedRecords {
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) async throws { try await real.replace(reference, with: bytes, context: context) }
    let real: KeychainVault; var reads = 0; var materialReads = 0
    init(real: KeychainVault) { self.real = real }
    func eraseProtectedAccount(_ account: AccountContext, barrier: RequestContext, cleanup: @Sendable () throws -> Void) async throws { try await real.eraseProtectedAccount(account, barrier: barrier, cleanup: cleanup) }
    func acquireProtectedLease(context: RequestContext) async throws -> ProtectedRecordLease? { try await real.acquireProtectedLease(context: context) }
    func releaseProtectedLease(_ lease: ProtectedRecordLease) async throws { try await real.releaseProtectedLease(lease) }
    func protectedRecordStamp(_ name: String, lease: ProtectedRecordLease, context: RequestContext) async throws -> ProtectedRecordStamp? { try await real.protectedRecordStamp(name, lease: lease, context: context) }
    func protectedRecord(_ name: String, lease: ProtectedRecordLease, context: RequestContext) async throws -> Data? {
        reads += 1; if name == "offline.master.v2" { materialReads += 1 }
        return try await real.protectedRecord(name, lease: lease, context: context)
    }
    func replaceProtectedRecord(_ name: String, value: Data?, lease: ProtectedRecordLease, context: RequestContext) async throws { try await real.replaceProtectedRecord(name, value: value, lease: lease, context: context) }

    func bind(_ context: RequestContext) async { await real.bind(context) }
    func insert(_ bytes: Data, for account: AccountContext) async throws -> CredentialReference { try await real.insert(bytes, for: account) }
    func delete(_ reference: CredentialReference, for account: AccountContext) async throws { try await real.delete(reference, for: account) }
    func deleteAll(for account: AccountContext) async throws { try await real.deleteAll(for: account) }
    func read(_ reference: CredentialReference, context: RequestContext) async throws -> Data { reads += 1; return try await real.read(reference, context: context) }
    func count() -> Int { reads }
    func materialCount() -> Int { materialReads }
}
private struct RFixture {
    let root: URL
    let namespace = KeychainVault.applicationNamespace + ".test.critic." + UUID().uuidString
    let context = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
    var playback: PlaybackContext { .init(request: context, generation: 1, occurrenceID: UUID(), route: nil) }
    init() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("W14-critic-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func vault() throws -> KeychainVault { try KeychainVault(testNamespace: namespace, isolatedKeychainURL: root.appendingPathComponent("test.keychain-db")) }
    func grant(_ rights: Set<String> = ["play", "seek", "retain"], now: Date = Date()) -> RetentionGrant {
        .init(issuer: "Critic synthetic authority", sourceEncryption: "none: synthetic", expires: now.addingTimeInterval(3600), renewalReference: "critic-renewal", rights: rights, validatedAt: now.addingTimeInterval(-1))
    }
    var objects: URL { root.appendingPathComponent("objects") }
    func file(named name: String) -> URL? { FileManager.default.enumerator(at: objects, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.first { $0.lastPathComponent == name } }
}
private struct NoFallback: NativeAssetProvider {
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { XCTFail("fallback used"); throw DomainError.offline }
}
/// Overrides nativeAsset so the default file-only extension guard is bypassed and NativePlayer's own guard is reached.
private struct OverridingProvider: NativeAssetProvider {
    let url: URL
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { url }
    func nativeAsset(for variant: MediaVariant, context: PlaybackContext) async throws -> AVURLAsset { AVURLAsset(url: url) }
}

final class W14ReviewRepro: XCTestCase, @unchecked Sendable {
    private func outcome(_ op: () async throws -> Void) async -> String {
        do { try await op(); return "success" } catch let e as OfflineRecovery { return "OfflineRecovery.\(e.rawValue)" } catch { return "other:\(error)" }
    }

    /// F1: replaying a single prior authenticated index record restores a revoked grant.
    func testR1ManifestReplayRestoresRevokedGrant() async throws {
        let f = try RFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault()
        let store = try EncryptedStore(root: f.objects, vault: vault); await store.bind(f.context)
        let input = f.root.appendingPathComponent("input"); try Data((0..<200_000).map { UInt8($0 % 251) }).write(to: input)
        try await store.retain(file: input, variant: "v", grant: f.grant(), reference: "a", context: f.context)
        let index = try XCTUnwrap(f.file(named: "index"))
        let preRevocation = try Data(contentsOf: index)
        let revoked = RetentionGrant(issuer: "Critic synthetic authority", sourceEncryption: "none: synthetic", expires: Date().addingTimeInterval(3600), renewalReference: "revoked", rights: [], validatedAt: Date().addingTimeInterval(-1))
        try await store.updateGrant(variant: "v", grant: revoked, context: f.context)
        let afterRevoke = await outcome { _ = try await store.read(variant: "v", offset: 70_000, count: 16, context: f.context) }
        let revokedIndex = try Data(contentsOf: index)
        // Control: re-writing the current (revoked) record keeps refusing.
        try revokedIndex.write(to: index)
        let control = await outcome { _ = try await store.read(variant: "v", offset: 70_000, count: 16, context: f.context) }
        // Replay: write back the earlier record's exact bytes (no key access, no clock change).
        try preRevocation.write(to: index)
        var replayed = Data()
        let afterReplay = await outcome { replayed = try await store.read(variant: "v", offset: 70_000, count: 16, context: f.context) }
        let fresh = try EncryptedStore(root: f.objects, vault: vault); await fresh.bind(RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0))
        let afterRestart = await outcome { _ = try await fresh.read(variant: "v", offset: 0, count: 16, context: f.context) }
        let expected = try Data(contentsOf: input)[70_000..<70_016]
        print("W14_CRITIC R1 afterRevoke=\(afterRevoke) control=\(control) afterReplay=\(afterReplay) replayedBytesMatch=\(replayed == expected) afterRestart=\(afterRestart)")
        XCTAssertEqual(afterRevoke, "OfflineRecovery.renewRights")
        XCTAssertEqual(control, "OfflineRecovery.renewRights")
        XCTAssertEqual(afterReplay, "OfflineRecovery.redownload")
        XCTAssertEqual(afterRestart, "OfflineRecovery.redownload")
        try await vault.destroyIsolatedTestKeychain()
    }

    /// F1 variant: a deleted object directory restored from a byte copy is accepted again.
    func testR2DeletedObjectDirectoryReplay() async throws {
        let f = try RFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault()
        let store = try EncryptedStore(root: f.objects, vault: vault); await store.bind(f.context)
        let input = f.root.appendingPathComponent("input"); try Data(repeating: 9, count: 150_000).write(to: input)
        try await store.retain(file: input, variant: "v", grant: f.grant(), reference: "a", context: f.context)
        let dir = try XCTUnwrap(f.file(named: "index")).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let saved = try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: dir.appendingPathComponent($0))) })
        try await store.delete(ServiceID("v"), context: f.context).outcome.get()
        let afterDelete = await outcome { _ = try await store.length(variant: "v", context: f.context) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (n, d) in saved { let u = dir.appendingPathComponent(n); FileManager.default.createFile(atPath: u.path, contents: d, attributes: [.posixPermissions: 0o600]) }
        let afterRestore = await outcome { _ = try await store.read(variant: "v", offset: 100_000, count: 8, context: f.context) }
        print("W14_CRITIC R2 afterDelete=\(afterDelete) afterRestore=\(afterRestore)")
        XCTAssertEqual(afterDelete, "OfflineRecovery.notRetained")
        XCTAssertEqual(afterRestore, "OfflineRecovery.redownload")
        try await vault.destroyIsolatedTestKeychain()
    }

    /// F2 regression: public arbitrary ranges remain seek-gated; the native decoder
    /// has its own internal play-authorized range path and must fully decode without seek.
    func testR3PlayOnlyGrantSequentialAndNativeDecode() async throws {
        let f = try RFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault()
        let store = try EncryptedStore(root: f.objects, vault: vault); await store.bind(f.context)
        let owned = OwnedMedia(); let variant = try await owned.resolve(OwnedMedia.items[0], context: f.playback).outcome.get()[0]
        let url = try await owned.asset(for: variant, context: f.playback)
        try await store.retain(file: url, variant: variant.id.rawValue, grant: f.grant(["play", "retain"]), reference: "a", context: f.context)
        let first = await outcome { _ = try await store.read(variant: variant.id.rawValue, offset: 0, count: 65_536, context: f.context) }
        let second = await outcome { _ = try await store.read(variant: variant.id.rawValue, offset: 65_536, count: 65_536, context: f.context) }
        let provider = LocalFirstOwnedAssets(store: store, fallback: NoFallback())
        let asset = try await provider.nativeAsset(for: variant, context: f.playback)
        var decodedBuffers = 0; var readerStatus = "n/a"; var loadError = "none"
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(output); _ = reader.startReading()
            while output.copyNextSampleBuffer() != nil { decodedBuffers += 1 }
            readerStatus = "\(reader.status.rawValue) error=\(String(describing: reader.error))"
        } catch { loadError = "\(error)" }
        // Control: identical flow with seek present decodes to completion.
        let store2Root = f.root.appendingPathComponent("objects2")
        let store2 = try EncryptedStore(root: store2Root, vault: vault); await store2.bind(f.context)
        try await store2.retain(file: url, variant: variant.id.rawValue, grant: f.grant(), reference: "a", context: f.context)
        let provider2 = LocalFirstOwnedAssets(store: store2, fallback: NoFallback())
        let asset2 = try await provider2.nativeAsset(for: variant, context: f.playback)
        let tracks2 = try await asset2.loadTracks(withMediaType: .audio)
        let reader2 = try AVAssetReader(asset: asset2)
        let output2 = AVAssetReaderTrackOutput(track: tracks2[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader2.add(output2); _ = reader2.startReading()
        var controlBuffers = 0; while output2.copyNextSampleBuffer() != nil { controlBuffers += 1 }
        print("W14_CRITIC R3 playOnly first64K=\(first) next64K=\(second) nativeLoadError=\(loadError) nativeDecodedBuffers=\(decodedBuffers) readerStatus=\(readerStatus) | control(seek) buffers=\(controlBuffers) status=\(reader2.status.rawValue)")
        withExtendedLifetime((provider, provider2, asset, asset2)) {}
        XCTAssertEqual(first, "success"); XCTAssertEqual(second, "OfflineRecovery.seekNotPermitted"); XCTAssertEqual(loadError, "none"); XCTAssertGreaterThan(decodedBuffers, 0); XCTAssertTrue(readerStatus.hasPrefix("2 ")); XCTAssertEqual(reader2.status, .completed)
        try await vault.destroyIsolatedTestKeychain()
    }

    /// Positive check: high-water alone detects a rollback in a fresh store instance (fresh anchors).
    func testR4RestartRollbackDetectedByHighWater() async throws {
        let f = try RFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault(); let clock = RClock()
        let store = try EncryptedStore(root: f.objects, vault: vault, wall: clock); await store.bind(f.context)
        let input = f.root.appendingPathComponent("input"); try Data(repeating: 1, count: 70_000).write(to: input)
        try await store.retain(file: input, variant: "v", grant: f.grant(now: clock.now()), reference: "a", context: f.context)
        _ = try await store.read(variant: "v", offset: 0, count: 8, context: f.context)
        let controlStore = try EncryptedStore(root: f.objects, vault: vault, wall: clock); await controlStore.bind(f.context)
        let control = await outcome { _ = try await controlStore.read(variant: "v", offset: 0, count: 8, context: f.context) }
        clock.jump(-100)
        let restarted = try EncryptedStore(root: f.objects, vault: vault, wall: clock); await restarted.bind(f.context)
        let rolled = await outcome { _ = try await restarted.read(variant: "v", offset: 0, count: 8, context: f.context) }
        print("W14_CRITIC R4 control=\(control) restartRollback=\(rolled)")
        XCTAssertEqual(control, "success"); XCTAssertEqual(rolled, "OfflineRecovery.clockChanged")
        try await vault.destroyIsolatedTestKeychain()
    }

    /// F4: an in-process wall/monotonic divergence cannot be recovered by explicit revalidation (anchors are immutable).
    func testR5DivergenceNotRecoverableByRenewal() async throws {
        let f = try RFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault(); let clock = RClock()
        let store = try EncryptedStore(root: f.objects, vault: vault, wall: clock); await store.bind(f.context)
        let input = f.root.appendingPathComponent("input"); try Data(repeating: 1, count: 70_000).write(to: input)
        try await store.retain(file: input, variant: "v", grant: f.grant(now: clock.now()), reference: "a", context: f.context)
        clock.jump(10)
        let jumped = await outcome { _ = try await store.length(variant: "v", context: f.context) }
        try await store.updateGrant(variant: "v", grant: f.grant(now: clock.now()), context: f.context)
        let grantOnly = await outcome { _ = try await store.length(variant: "v", context: f.context) }
        XCTAssertEqual(grantOnly,"OfflineRecovery.clockChanged")
        clock.jump(1)
        try await store.revalidate(variant:"v",grant:f.grant(now:clock.now()),sourceTime:clock.now(),context:f.context)
        let renewed = await outcome { _ = try await store.length(variant:"v",context:f.context) }
        let freshStore = try EncryptedStore(root: f.objects, vault: vault, wall: clock); await freshStore.bind(f.context)
        let fresh = await outcome { _ = try await freshStore.length(variant: "v", context: f.context) }
        print("W14_CRITIC R5 forwardJump10s=\(jumped) afterExplicitRenewal=\(renewed) newStoreInstance=\(fresh)")
        XCTAssertEqual(jumped, "OfflineRecovery.clockChanged"); XCTAssertEqual(renewed, "success")
        try await vault.destroyIsolatedTestKeychain()
    }

    /// Guard check: NativePlayer's own scheme/identity guard (not the default extension) refuses network and non-owned encrypted assets.
    func testR6NativePlayerGuardReached() async throws {
        let f = try RFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let variant = try await OwnedMedia().resolve(OwnedMedia.items[0], context: f.playback).outcome.get()[0]
        func prepare(_ url: String, _ context: PlaybackContext) async -> String {
            let player = NativePlayer(assets: OverridingProvider(url: URL(string: url)!), clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true)
            do { try await player.prepare(variant, context: context).outcome.get(); _ = await player.stop(context: context); return "success" } catch { return "\(error)" }
        }
        let https = await prepare("https://127.0.0.1:1/never-requested.wav", f.playback)
        let other = try AccountContext(accountID: UUID(), channelID: ID("critic-other"), region: "US")
        let otherPlayback = PlaybackContext(request: RequestContext(account: other, accountGeneration: 1, requestGeneration: 0), generation: 1, occurrenceID: UUID(), route: nil)
        let encryptedOther = await prepare("owned-encrypted://media/x.wav", otherPlayback)
        XCTAssertEqual(https, "forbidden"); XCTAssertEqual(encryptedOther, "forbidden")
        let encryptedOwnedNoDelegate = await prepare("owned-encrypted://media/x.wav", f.playback)
        print("W14_CRITIC R6 httpsOverride=\(https) ownedSchemeOtherAccount=\(encryptedOther) ownedSchemeOwnedAccountNoDelegate=\(encryptedOwnedNoDelegate)")
    }

    /// F3 quantification: Keychain reads and index rewrites per native decode; a non-writable object directory blocks reads of intact data.
    func testR7PerRangeKeychainAndIndexRewrite() async throws {
        let f = try RFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let real = try f.vault(); let vault = CountingVault(real: real)
        let store = try EncryptedStore(root: f.objects, vault: vault); await store.bind(f.context)
        await store.setKeyLifetimeForTests(.seconds(3600))   // TH2: the retrieval count must not depend on how long the decode takes (the product's key lives one second)
        let owned = OwnedMedia(); let variant = try await owned.resolve(OwnedMedia.items[0], context: f.playback).outcome.get()[0]
        let url = try await owned.asset(for: variant, context: f.playback)
        try await store.retain(file: url, variant: variant.id.rawValue, grant: f.grant(), reference: "a", context: f.context)
        let index = try XCTUnwrap(f.file(named: "index"))
        func ino() throws -> UInt64 { var st = stat(); guard stat(index.path, &st) == 0 else { throw OfflineRecovery.redownload }; return UInt64(st.st_ino) }
        let inoBefore = try ino(); let readsBefore = await vault.count(); let materialBefore = await vault.materialCount()
        let provider = LocalFirstOwnedAssets(store: store, fallback: NoFallback())
        let asset = try await provider.nativeAsset(for: variant, context: f.playback)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output); _ = reader.startReading(); while output.copyNextSampleBuffer() != nil {}
        let readsAfter = await vault.count(); let materialAfter = await vault.materialCount(); let inoAfter = try ino()
        let size = try Data(contentsOf: url).count
        // Non-writable (0500, still passes the 0o077 mode check) object directory: intact data, but reads now fail.
        let dir = index.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let readOnly = await outcome { _ = try await store.read(variant: variant.id.rawValue, offset: 0, count: 16, context: f.context) }
        let lengthReadOnly = await outcome { _ = try await store.length(variant: variant.id.rawValue, context: f.context) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        print("W14_CRITIC R7 objectBytes=\(size) chunks=\((size - 1) / 65536 + 1) protectedReadsDuringFullDecode=\(readsAfter - readsBefore) masterRetrievals=\(materialAfter-materialBefore) indexInodeChanged=\(inoBefore != inoAfter) readerStatus=\(reader.status.rawValue) | readOnlyDir read=\(readOnly) length=\(lengthReadOnly)")
        XCTAssertEqual(readOnly, "success"); XCTAssertEqual(lengthReadOnly, "success"); XCTAssertEqual(inoBefore, inoAfter); XCTAssertLessThan(materialAfter - materialBefore, 8)
        withExtendedLifetime((provider, asset)) {}
        try await real.destroyIsolatedTestKeychain()
    }

    /// Plausible residual probe: a concurrent create:false key load can fail an import with missingKey.
    func testR8ConcurrentReadDuringFirstImport() async throws {
        var failures: [String] = []
        for _ in 0..<20 {
            let f = try RFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let vault = try f.vault()
            let store = try EncryptedStore(root: f.objects, vault: vault); await store.bind(f.context)
            let input = f.root.appendingPathComponent("input"); try Data(repeating: 3, count: 1000).write(to: input)
            let grant = f.grant(); let context = f.context
            async let r: Void = { _ = try? await store.read(variant: "x", offset: 0, count: 1, context: context) }()
            async let i: String = { do { try await store.retain(file: input, variant: "v", grant: grant, reference: "a", context: context); return "ok" } catch { return "\(error)" } }()
            _ = await r; let result = await i
            if result != "ok" { failures.append(result) }
            try await vault.destroyIsolatedTestKeychain()
        }
        XCTAssertTrue(failures.isEmpty)
        print("W14_CRITIC R8 importFailuresOf20=\(failures.count) \(Set(failures))")
    }

    /// Test-oracle probe: T14's revoked grant uses validatedAt=Date() against an injected clock that is earlier,
    /// so its renewRights expectation is met by validatedAt, not by the rights check. Here validatedAt is in the past.
    func testR9RevocationWithPastValidationHitsRightsGuard() async throws {
        let f = try RFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault(); let clock = RClock()
        let store = try EncryptedStore(root: f.objects, vault: vault, wall: clock); await store.bind(f.context)
        let input = f.root.appendingPathComponent("input"); try Data(repeating: 5, count: 100_000).write(to: input)
        try await store.retain(file: input, variant: "v", grant: f.grant(now: clock.now()), reference: "a", context: f.context)
        let fixtureStyle = RetentionGrant(issuer: "x", sourceEncryption: "none", expires: Date().addingTimeInterval(100), renewalReference: "r", rights: [], validatedAt: Date())
        let tFixture = clock.now() < fixtureStyle.validatedAt
        let positive = f.grant(now:clock.now())
        let revoked = RetentionGrant(issuer:positive.issuer,sourceEncryption:positive.sourceEncryption,expires:positive.expires,renewalReference:positive.renewalReference,rights:[],validatedAt:positive.validatedAt)
        try await store.updateGrant(variant: "v", grant: revoked, context: f.context)
        let len = await outcome { _ = try await store.length(variant: "v", context: f.context) }
        let r0 = await outcome { _ = try await store.read(variant: "v", offset: 0, count: 8, context: f.context) }
        print("W14_CRITIC R9 t14StyleValidatedAtAfterInjectedClock=\(tFixture) revokedPastValidation length=\(len) read0=\(r0)")
        XCTAssertEqual(len, "OfflineRecovery.renewRights"); XCTAssertEqual(r0, "OfflineRecovery.renewRights")
        try await vault.destroyIsolatedTestKeychain()
    }
}
