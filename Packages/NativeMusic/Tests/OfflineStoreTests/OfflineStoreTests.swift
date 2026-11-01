import XCTest
import Foundation
import Synchronization
import CryptoKit
import Security
import Darwin
@preconcurrency import AVFoundation
import Domain
import Downloads
import AccountSession
import Playback

final class Clock: WallClock, Sendable {
    let value = Mutex(Date())
    func now() -> Date { value.withLock { $0 } }
    func jump(_ seconds: Double) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
final class OfflineStoreTests: XCTestCase, @unchecked Sendable {
    func testRetainedRestartRangesReferencesAndNativeSeek() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault(); defer { Task { try? await vault.destroyIsolatedTestKeychain() } }
        let store = try EncryptedStore(root: f.root.appendingPathComponent("objects"), vault: vault)
        await store.bind(f.context)
        let owned = OwnedMedia(); let variant = try await owned.resolve(OwnedMedia.items[0], context: f.playback).outcome.get()[0]
        let url = try await owned.asset(for: variant, context: f.playback)
        let original = try Data(contentsOf: url)
        try await store.retain(file: url, variant: variant.id.rawValue, grant: f.grant(), reference: "collection-a", context: f.context)
        try await store.retain(file: url, variant: variant.id.rawValue, grant: f.grant(), reference: "collection-b", context: f.context)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "OfflineStoreTests.OfflineStoreTests/testProcessRestartChild", Bundle(for: Self.self).bundlePath]
        var env = ProcessInfo.processInfo.environment; env["W14_RESTART_ROOT"] = f.root.path
        env["W14_RESTART_NAMESPACE"] = f.namespace; child.environment = env
        let log = f.root.appendingPathComponent("restart.log"); FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log); child.standardOutput = handle; child.standardError = handle
        try child.run(); waitForOwnedTestProcess(child); try handle.close()
        let childLog = try String(contentsOf: log, encoding: .utf8)
        print("W14 child restart: " + childLog)
        XCTAssertEqual(child.terminationStatus, 0); XCTAssertTrue(childLog.contains("W14_CHILD_DECODED"))
        let restarted = try EncryptedStore(root: f.root.appendingPathComponent("objects"), vault: vault)
        await restarted.bind(f.context)
        let bytes = try await restarted.read(variant: variant.id.rawValue, offset: 65000, count: 1000, context: f.context)
        XCTAssertEqual(bytes, original[65000..<66000])
        try await restarted.reference(variant: variant.id.rawValue, reference: nil, remove: "collection-a", pinned: true, context: f.context)
        try await restarted.reference(variant: variant.id.rawValue, reference: nil, remove: "collection-b", context: f.context)
        let length = try await restarted.length(variant: variant.id.rawValue, context: f.context); XCTAssertEqual(length, original.count)
        let provider = LocalFirstOwnedAssets(store: restarted, fallback: NoNetwork())
        let native = NativePlayer(assets: provider, clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true)
        let nativeContext = f.playback
        print("C_RESTART native prepare")
        try await native.prepare(variant, context: nativeContext).outcome.get()
        print("C_RESTART native seek")
        try await native.seek(to: 1, context: nativeContext).outcome.get()
        print("C_RESTART native stop")
        try await native.stop(context: nativeContext).outcome.get()
        print("C_RESTART reader asset")
        let asset = try await provider.nativeAsset(for: variant, context: f.playback)
        let duration = try await asset.load(.duration); XCTAssertGreaterThan(duration.seconds, 1)
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.timeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 48000), duration: CMTime(seconds: 0.2, preferredTimescale: 48000))
        reader.add(output); XCTAssertTrue(reader.startReading()); XCTAssertNotNil(output.copyNextSampleBuffer()); reader.cancelReading()
        print("C_RESTART final unpin")
        try await restarted.reference(variant: variant.id.rawValue, reference: nil, pinned: false, context: f.context)
        await expect(.notRetained) { _ = try await restarted.length(variant: variant.id.rawValue, context: f.context) }
        print("C_RESTART invalidate")
        try await restarted.invalidate(context: f.context, deleteFiles: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("objects").path).count, 0)
        try await vault.destroyIsolatedTestKeychain()
    }
    /// C1 (OfflineStore Keychain-lease flake): an erase that overlaps a holder which predates its
    /// barrier waits for it instead of reporting `busy`. The failing run died in `invalidate`,
    /// after the child had finished and every earlier step had passed, on a single-shot claim.
    func testInvalidateWaitsForAnInFlightLeaseHolderThenErases() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault(); defer { Task { try? await vault.destroyIsolatedTestKeychain() } }
        let store = try EncryptedStore(root: f.root.appendingPathComponent("objects"), vault: vault)
        await store.bind(f.context)
        let held = try await vault.acquireProtectedLease(context: f.context)
        let holder = try XCTUnwrap(held, "precondition: this process now holds the lease")
        let started = ContinuousClock.now
        let erasing = Task { try await store.invalidate(context: f.context, deleteFiles: true) }
        try await Task.sleep(for: .milliseconds(250))   // far longer than any single claim, far shorter than the bound
        try await vault.releaseProtectedLease(holder)
        try await erasing.value
        let waited = started.duration(to: .now)
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(200), "the erase waited for the holder rather than racing it")
        XCTAssertLessThan(waited, KeychainVault.eraseLeaseWait, "and finished once the holder let go")
    }
    /// The wait is bounded: a lease that never lets go still ends in `busy` (retryable removal).
    func testInvalidateReportsBusyOnlyAfterTheBoundForAStuckHolder() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault(); defer { Task { try? await vault.destroyIsolatedTestKeychain() } }
        let store = try EncryptedStore(root: f.root.appendingPathComponent("objects"), vault: vault)
        await store.bind(f.context)
        let stuck = try await vault.acquireProtectedLease(context: f.context)
        XCTAssertNotNil(stuck)
        let started = ContinuousClock.now
        do { try await store.invalidate(context: f.context, deleteFiles: true); XCTFail("a stuck holder must not be erased over") }
        catch { XCTAssertEqual(error as? LifecycleError, .busy) }
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), KeychainVault.eraseLeaseWait - .milliseconds(100))
        if let stuck { try? await vault.releaseProtectedLease(stuck) }
    }
    func testProcessRestartChild() async throws {
        guard let path = ProcessInfo.processInfo.environment["W14_RESTART_ROOT"], let namespace = ProcessInfo.processInfo.environment["W14_RESTART_NAMESPACE"] else { return }
        let root = URL(fileURLWithPath: path)
        let vault = try KeychainVault(testNamespace: namespace, reopeningIsolatedKeychainURL: root.appendingPathComponent("test.keychain-db"))
        let store = try EncryptedStore(root: root.appendingPathComponent("objects"), vault: vault)
        let context = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
        await store.bind(context)
        let playback = PlaybackContext(request: context, generation: 1, occurrenceID: nil, route: nil)
        let variant = try await OwnedMedia().resolve(OwnedMedia.items[0], context: playback).outcome.get()[0]
        let provider = LocalFirstOwnedAssets(store: store, fallback: NoNetwork())
        let asset = try await provider.nativeAsset(for: variant, context: playback)
        let duration = try await asset.load(.duration); XCTAssertGreaterThan(duration.seconds, 1)
        // Keep provider/delegate alive while the asset loads.
        let bytes = try await store.read(variant: variant.id.rawValue, offset: 70000, count: 64, context: context)
        XCTAssertEqual(bytes.count, 64)
        _ = asset
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("W14_CHILD_DECODED authenticated restart range: 64 bytes; process max RSS bytes=\(usage.ru_maxrss)")
    }
    func testTamperExpiryClockKeysIdentityAndInvalidation() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault(); let clock = Clock()
        let store = try EncryptedStore(root: f.root.appendingPathComponent("objects"), vault: vault, wall: clock)
        await store.bind(f.context)
        try Data(repeating: 37, count: 200000).write(to: f.root.appendingPathComponent("input"))
        try await store.retain(file: f.root.appendingPathComponent("input"), variant: "v", grant: f.grant(), reference: "a", context: f.context)
        await expect(.invalidRange) { _ = try await store.read(variant: "v", offset: 0, count: 65537, context: f.context) }
        clock.jump(-100)
        await expect(.clockChanged) { _ = try await store.read(variant: "v", offset: 0, count: 1, context: f.context) }
        clock.jump(200)
        await expect(.clockChanged) { _ = try await store.length(variant: "v", context: f.context) }
        clock.jump(-200)
        clock.jump(100000)
        await expect(.clockChanged) { _ = try await store.length(variant: "v", context: f.context) }
        clock.jump(-99900)
        let recovered = RetentionGrant(issuer:"Owned clock revalidation",sourceEncryption:"none",expires:clock.now().addingTimeInterval(3600),renewalReference:"fresh-clock",rights:["play","seek","retain"],validatedAt:clock.now())
        try await store.revalidate(variant:"v",grant:recovered,sourceTime:clock.now(),context:f.context)
        let enumerator = FileManager.default.enumerator(at: f.root.appendingPathComponent("objects"), includingPropertiesForKeys: nil)!
        let chunks = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "chunk-1" }
        XCTAssertEqual(chunks.count, 1)
        let sibling = chunks[0].deletingLastPathComponent().appendingPathComponent("chunk-0")
        let first = try Data(contentsOf: sibling); let second = try Data(contentsOf: chunks[0])
        try first.write(to: chunks[0])
        await expect(.redownload) { _ = try await store.length(variant: "v", context: f.context) }
        try second.write(to: chunks[0]); try FileManager.default.removeItem(at: chunks[0])
        await expect(.redownload) { _ = try await store.length(variant: "v", context: f.context) }
        try second.prefix(30).write(to: chunks[0])
        await expect(.redownload) { _ = try await store.read(variant: "v", offset: 0, count: 1, context: f.context) }
        try second.write(to: chunks[0])
        let index = chunks[0].deletingLastPathComponent().appendingPathComponent("index")
        let metadata = try Data(contentsOf: index); var modified = metadata; modified[modified.count - 1] ^= 1; try modified.write(to: index)
        await expect(.redownload) { _ = try await store.length(variant: "v", context: f.context) }
        try metadata.write(to: index)
        var data = try Data(contentsOf: chunks[0]); data[30] ^= 1; try data.write(to: chunks[0])
        await expect(.redownload) { _ = try await store.length(variant: "v", context: f.context) }
        let other = RequestContext(account: nil, accountGeneration: 2, requestGeneration: 0)
        await store.bind(other)
        await expect(.reconnect) { _ = try await store.length(variant: "v", context: f.context) }
        let otherAccount = try AccountContext(accountID: UUID(), channelID: ID("other"), region: "US")
        let otherContext = RequestContext(account: otherAccount, accountGeneration: 3, requestGeneration: 0)
        await store.bind(otherContext)
        await expect(.notRetained) { _ = try await store.length(variant: "v", context: otherContext) }
        let rebound = RequestContext(account: f.context.account, accountGeneration: 4, requestGeneration: 0)
        await store.bind(rebound)
        clock.jump(1) // A genuinely later source observation, not an equal-time conflicting receipt.
        try await store.updateGrant(variant: "v", grant: RetentionGrant(issuer: "Owned license", sourceEncryption: "none", expires: clock.now().addingTimeInterval(100), renewalReference: "explicit-revoke", rights: [], validatedAt: clock.now()), context: rebound)
        await expect(.renewRights) { _ = try await store.length(variant: "v", context: rebound) }
        try await vault.deleteAll(for: OwnedMedia.account)
        await expect(.missingKey) { _ = try await store.length(variant: "v", context: rebound) }
        try await store.invalidate(context: rebound, deleteFiles: true)
        await expect(.reconnect) { _ = try await store.read(variant: "v", offset: 0, count: 1, context: rebound) }
        try await vault.destroyIsolatedTestKeychain()
    }

    func testUnsafeFilesystemAndCrashCleanup() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault()
        let objects = f.root.appendingPathComponent("objects")
        let store = try EncryptedStore(root: objects, vault: vault); await store.bind(f.context)
        let input = f.root.appendingPathComponent("input"); try Data(repeating: 8, count: 100000).write(to: input)
        try await store.retain(file: input, variant: "../escape", grant: f.grant(), reference: "a", context: f.context)
        let chunk = FileManager.default.enumerator(at: objects, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.first { $0.lastPathComponent == "chunk-0" }!
        _ = try await store.read(variant: "../escape", offset: 0, count: 1, context: f.context)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: chunk.path)
        await expect(.redownload) { _ = try await store.read(variant: "../escape", offset: 0, count: 1, context: f.context) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: chunk.path)
        let hardlink = f.root.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: chunk, to: hardlink)
        await expect(.redownload) { _ = try await store.length(variant: "../escape", context: f.context) }
        try FileManager.default.removeItem(at: hardlink)
        let saved = try Data(contentsOf: chunk); try FileManager.default.removeItem(at: chunk)
        try FileManager.default.createSymbolicLink(at: chunk, withDestinationURL: input)
        await expect(.redownload) { _ = try await store.length(variant: "../escape", context: f.context) }
        try FileManager.default.removeItem(at: chunk); try saved.write(to: chunk)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: chunk.path)
        let account = chunk.deletingLastPathComponent().deletingLastPathComponent()
        let partial = account.appendingPathComponent("abandoned.partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        await store.bind(f.context)
        // Cleanup occurs on protected access, not an unleased bind that could erase a live import.
        let length = try await store.length(variant: "../escape", context: f.context); XCTAssertEqual(length, 100000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let referenceURL = account.appendingPathComponent("key-reference")
        let keyReference = try await vault.insert(Data(repeating: 0, count: 32), for: OwnedMedia.account)
        try Data("corrupt-reference".utf8).write(to: referenceURL)
        let link = f.root.appendingPathComponent("linked-root"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: objects)
        XCTAssertThrowsError(try EncryptedStore(root: link, vault: vault))
        try await store.invalidate(context: f.context, deleteFiles: true)
        // Verify deletion by its prior opaque reference, not merely by removed files.
        let rebound = RequestContext(account: OwnedMedia.account, accountGeneration: 2, requestGeneration: 0)
        await vault.bind(rebound)
        do { _ = try await vault.read(keyReference, context: rebound); XCTFail("Orphaned account key survived") } catch { XCTAssertEqual(error as? LifecycleError, .keychain(errSecItemNotFound)) }
        print("W14 root after cleanup: \(try FileManager.default.contentsOfDirectory(atPath: objects.path))")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: objects.path).count, 0)
        try await vault.destroyIsolatedTestKeychain()
    }
    func testRenewalRequiresExplicitRightsAndConcurrentKeyCreation() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault(); let store = try EncryptedStore(root: f.root.appendingPathComponent("objects"), vault: vault)
        await store.bind(f.context)
        let file = f.root.appendingPathComponent("input"); try Data(repeating: 42, count: 150000).write(to: file)
        let absent = RetentionGrant(issuer: "Owned", sourceEncryption: "none", expires: Date().addingTimeInterval(100), renewalReference: "r", rights: [], validatedAt: Date())
        await expect(.renewRights) { try await store.retain(file: file, variant: "denied", grant: absent, reference: "a", context: f.context) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<12 { group.addTask { try await store.retain(file: file, variant: "v", grant: f.grant(), reference: "collection-\(n)", context: f.context) } }
            try await group.waitForAll()
        }
        let job = try await store.pin(ServiceID("v"), reference: ServiceID("manual-reference"), context: f.context).outcome.get()
        XCTAssertEqual(job.references.count, 13)
        let expired = RetentionGrant(issuer: "Owned", sourceEncryption: "none", expires: Date().addingTimeInterval(-1), renewalReference: "r", rights: ["play", "seek", "retain"], validatedAt: Date().addingTimeInterval(-0.2))
        try await store.updateGrant(variant: "v", grant: expired, context: f.context)
        await expect(.renewRights) { _ = try await store.length(variant: "v", context: f.context) }
        // Retention accounting and integrity are still usable while playback rights expire.
        try await store.unpin(ServiceID("v"), reference: ServiceID("manual-reference"), context: f.context).outcome.get()
        _ = try await store.verify(ServiceID("v"), context: f.context).outcome.get()
        let denied = try await store.validateEntitlement(ServiceID("v"), context: f.context)
        do { _ = try denied.outcome.get(); XCTFail("Expired bytes granted playback") } catch { XCTAssertEqual(error, .expiredMedia) }
        let freshBase=f.grant()
        let freshOrdered=RetentionGrant(issuer:freshBase.issuer,sourceEncryption:freshBase.sourceEncryption,expires:freshBase.expires,renewalReference:freshBase.renewalReference,rights:freshBase.rights,validatedAt:Date())
        try await store.updateGrant(variant: "v", grant: freshOrdered, context: f.context)
        _ = try await store.resolve(ServiceID("v"), context: f.context).outcome.get()
        try await store.removeLocal(OwnedMedia.account, context: RequestContext(account: nil, accountGeneration: 2, requestGeneration: 0))
        await store.bind(f.context)
        await expect(.reconnect) { _ = try await store.length(variant: "v", context: f.context) }
        try await vault.destroyIsolatedTestKeychain()
    }
    func testHeldKeyReadCannotDeliverAfterOwnershipBarrier() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let real = try f.vault(); let vault = HeldVault(real: real)
        let store = try EncryptedStore(root: f.root.appendingPathComponent("objects"), vault: vault); await store.bind(f.context)
        let input = f.root.appendingPathComponent("input"); try Data(repeating: 2, count: 100).write(to: input)
        try await store.retain(file: input, variant: "v", grant: f.grant(), reference: "a", context: f.context)
        let delivered = Mutex(false)
        try await store.deliver(variant: "v", offset: 0, count: 10, context: f.context) { _ in delivered.withLock { $0 = true } }
        XCTAssertTrue(delivered.withLock { $0 }); delivered.withLock { $0 = false }
        await vault.hold()
        let task = Task { try await store.deliver(variant: "v", offset: 0, count: 10, context: f.context) { _ in delivered.withLock { $0 = true } } }
        await vault.waitForHeldRead()
        try await store.detach(previous: f.context, barrier: RequestContext(account: nil, accountGeneration: 2, requestGeneration: 0))
        await vault.release()
        await expect(.reconnect) { try await task.value }
        XCTAssertFalse(delivered.withLock { $0 })
        await store.bind(f.context)
        await expect(.reconnect) { _ = try await store.read(variant: "v", offset: 0, count: 1, context: f.context) }
        try await real.destroyIsolatedTestKeychain()
    }

    func testCancelledReadAndNetworkAssetFailClosed() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let real = try f.vault(); let vault = HeldVault(real: real)
        let store = try EncryptedStore(root: f.root.appendingPathComponent("objects"), vault: vault); await store.bind(f.context)
        let input = f.root.appendingPathComponent("input"); try Data(repeating: 4, count: 100).write(to: input)
        try await store.retain(file: input, variant: "v", grant: f.grant(), reference: "a", context: f.context)
        let delivered = Mutex(false); await vault.hold()
        let task = Task { try await store.deliver(variant: "v", offset: 0, count: 10, context: f.context) { _ in delivered.withLock { $0 = true } } }
        await vault.waitForHeldRead(); task.cancel(); await vault.release()
        do { try await task.value; XCTFail("Cancelled read returned") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(delivered.withLock { $0 })
        let variant = try await OwnedMedia().resolve(OwnedMedia.items[0], context: f.playback).outcome.get()[0]
        let player = NativePlayer(assets: RemoteURL(), clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true)
        let result = await player.prepare(variant, context: f.playback)
        do { try result.outcome.get(); XCTFail("Remote URL admitted") } catch { XCTAssertEqual(error, .forbidden) }
        try await real.destroyIsolatedTestKeychain()
    }

    func testCrossAccountCiphertextAndRewriteRevisionSubstitution() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let vault = try f.vault(); let objects = f.root.appendingPathComponent("objects")
        let store = try EncryptedStore(root: objects, vault: vault); await store.bind(f.context)
        let file = f.root.appendingPathComponent("input"); try Data(repeating: 42, count: 100000).write(to: file)
        try await store.retain(file: file, variant: "v", grant: f.grant(), reference: "a", context: f.context)
        func chunks() -> [URL] { FileManager.default.enumerator(at: objects, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "chunk-0" } }
        let a = chunks()[0]; let oldA = try Data(contentsOf: a)
        let bContext = RequestContext(account: try AccountContext(accountID: UUID(), channelID: ID("other-owned-licensee"), region: "US"), accountGeneration: 2, requestGeneration: 0)
        await store.bind(bContext)
        try await store.retain(file: file, variant: "v", grant: f.grant(), reference: "b", context: bContext)
        let b = chunks().first { $0 != a }!; let originalB = try Data(contentsOf: b)
        try oldA.write(to: b)
        await expect(.redownload) { _ = try await store.read(variant: "v", offset: 0, count: 1, context: bContext) }
        try originalB.write(to: b)
        let bytes = try await store.read(variant: "v", offset: 0, count: 1, context: bContext); XCTAssertEqual(bytes, Data([42]))
        let aContext = RequestContext(account: OwnedMedia.account, accountGeneration: 3, requestGeneration: 0)
        await store.bind(aContext); try await store.delete(ServiceID("v"), context: aContext).outcome.get()
        try await store.retain(file: file, variant: "v", grant: f.grant(), reference: "a", context: aContext)
        let revised = try Data(contentsOf: a); XCTAssertNotEqual(oldA, revised)
        try oldA.write(to: a)
        await expect(.redownload) { _ = try await store.read(variant: "v", offset: 0, count: 1, context: aContext) }
        try revised.write(to: a)
        _ = try await store.length(variant: "v", context: aContext)
        try await vault.destroyIsolatedTestKeychain()
    }
    private func expect(_ expected: OfflineRecovery, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") } catch { XCTAssertEqual(error as? OfflineRecovery, expected) }
    }
}
private struct NoNetwork: NativeAssetProvider {
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { XCTFail("Fallback used for retained object"); throw DomainError.offline }
}
private struct Fixture {
    let root: URL
    let namespace = KeychainVault.applicationNamespace + ".test." + UUID().uuidString
    let context = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
    var playback: PlaybackContext { .init(request: context, generation: 1, occurrenceID: UUID(), route: nil) }
    init() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("W14-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func vault() throws -> KeychainVault { try KeychainVault(testNamespace: namespace, isolatedKeychainURL: root.appendingPathComponent("test.keychain-db")) }
    func grant() -> RetentionGrant { .init(issuer: "Owned synthetic signal license", sourceEncryption: "none: owned PCM", expires: Date().addingTimeInterval(3600), renewalReference: "owned-test-revalidation", rights: ["play", "seek", "retain"], validatedAt: Date().addingTimeInterval(-1)) }
}

private actor HeldVault: ScopedProtectedRecords {
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) async throws { try await real.replace(reference, with: bytes, context: context) }
    let real: KeychainVault
    var blocked = false; var continuation: CheckedContinuation<Void, Never>?
    var entered: CheckedContinuation<Void, Never>?
    init(real: KeychainVault) { self.real = real }
    func hold() { blocked = true }
    func waitForHeldRead() async { if continuation != nil { return }; await withCheckedContinuation { entered = $0 } }
    func release() { blocked = false; continuation?.resume(); continuation = nil }
    func eraseProtectedAccount(_ account: AccountContext, barrier: RequestContext, cleanup: @Sendable () throws -> Void) async throws { try await real.eraseProtectedAccount(account, barrier: barrier, cleanup: cleanup) }
    func acquireProtectedLease(context: RequestContext) async throws -> ProtectedRecordLease? { try await real.acquireProtectedLease(context: context) }
    func releaseProtectedLease(_ lease: ProtectedRecordLease) async throws { try await real.releaseProtectedLease(lease) }
    func protectedRecordStamp(_ name: String, lease: ProtectedRecordLease, context: RequestContext) async throws -> ProtectedRecordStamp? {
        if blocked { await withCheckedContinuation { continuation = $0; entered?.resume(); entered = nil } }
        return try await real.protectedRecordStamp(name, lease: lease, context: context)
    }
    func protectedRecord(_ name: String, lease: ProtectedRecordLease, context: RequestContext) async throws -> Data? {
        if blocked { await withCheckedContinuation { continuation = $0; entered?.resume(); entered = nil } }
        return try await real.protectedRecord(name, lease: lease, context: context)
    }
    func replaceProtectedRecord(_ name: String, value: Data?, lease: ProtectedRecordLease, context: RequestContext) async throws { try await real.replaceProtectedRecord(name, value: value, lease: lease, context: context) }

    func bind(_ context: RequestContext) async { await real.bind(context) }
    func insert(_ bytes: Data, for account: AccountContext) async throws -> CredentialReference { try await real.insert(bytes, for: account) }
    func delete(_ reference: CredentialReference, for account: AccountContext) async throws { try await real.delete(reference, for: account) }
    func deleteAll(for account: AccountContext) async throws { try await real.deleteAll(for: account) }
    func read(_ reference: CredentialReference, context: RequestContext) async throws -> Data {
        if blocked { await withCheckedContinuation { continuation = $0; entered?.resume(); entered = nil } }
        return try await real.read(reference, context: context)
    }
}

private struct RemoteURL: NativeAssetProvider {
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { URL(string: "https://invalid.example/never-requested.wav")! }
}
