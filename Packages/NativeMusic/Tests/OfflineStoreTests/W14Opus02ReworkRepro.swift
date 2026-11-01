// W14 independent critic (opus-02) bounded repro. Temporary; archived under
// artifacts/harness/critiques/W14-opus-02/repro/ and removed from the test target afterwards.
// Isolated test Keychains, temp directories, owned synthetic WAVE only. Muted prepare/seek; no Play.
import XCTest
import Foundation
import Synchronization
import Security
import Darwin
@preconcurrency import AVFoundation
import CoreMedia
import Domain
import Downloads
import AccountSession
import Playback

private final class OClock: WallClock, Sendable {
    let value: Mutex<Date>
    init(_ d: Date = Date()) { value = Mutex(d) }
    func now() -> Date { value.withLock { $0 } }
    func set(_ d: Date) { value.withLock { $0 = d } }
}
private struct OTrap: NativeAssetProvider {
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { XCTFail("fallback used"); throw DomainError.offline }
}
private struct OFix {
    let root: URL
    let namespace = KeychainVault.applicationNamespace + ".test.opus02." + UUID().uuidString
    let ctx = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
    var playback: PlaybackContext { .init(request: ctx, generation: 1, occurrenceID: UUID(), route: nil) }
    var keychainURL: URL { root.appendingPathComponent("test.keychain-db") }
    var objects: URL { root.appendingPathComponent("objects") }
    init() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("W14-opus02-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    func vault() throws -> KeychainVault { try KeychainVault(testNamespace: namespace, isolatedKeychainURL: keychainURL) }
    func reopen() throws -> KeychainVault { try KeychainVault(testNamespace: namespace, reopeningIsolatedKeychainURL: keychainURL) }
    func grant(_ rights: Set<String> = ["play", "seek", "retain"], at t: Date, life: TimeInterval = 3600) -> RetentionGrant {
        .init(issuer: "opus02 synthetic authority", sourceEncryption: "none: synthetic", expires: t.addingTimeInterval(life), renewalReference: "opus02", rights: rights, validatedAt: t.addingTimeInterval(-1))
    }
    func input(_ n: Int = 100_000) throws -> URL { let u = root.appendingPathComponent("input-\(n)"); try Data((0..<n).map { UInt8($0 % 241) }).write(to: u); return u }
    func file(_ name: String) -> URL? { FileManager.default.enumerator(at: objects, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.first { $0.lastPathComponent == name } }
    var service: String { let a = OwnedMedia.account; return namespace + ":" + a.accountID.uuidString + ":\(a.channelID.rawValue.utf8.count):" + a.channelID.rawValue + ":" + a.region }
}
private func outcome(_ op: () async throws -> Void) async -> String {
    do { try await op(); return "success" }
    catch let e as OfflineRecovery { return "OfflineRecovery.\(e.rawValue)" }
    catch let e as LifecycleError { return "LifecycleError.\(e)" }
    catch let e as DomainError { return "DomainError.\(e)" }
    catch { return "other:\(error)" }
}

final class W14Opus02ReworkRepro: XCTestCase, @unchecked Sendable {
    /// O1: independent F1 replay check through restart, pin change and delete.
    func testO1ReplayRefusedThroughRestartPinAndDelete() async throws {
        let f = try OFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault()
        let s = try EncryptedStore(root: f.objects, vault: v); await s.bind(f.ctx)
        try await s.retain(file: try f.input(), variant: "v", grant: f.grant(at: Date()), reference: "a", context: f.ctx)
        let index = try XCTUnwrap(f.file("index")); let dir = index.deletingLastPathComponent()
        let validIndex = try Data(contentsOf: index)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let saved = try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: dir.appendingPathComponent($0))) })
        try await s.updateGrant(variant: "v", grant: RetentionGrant(issuer: "x", sourceEncryption: "none", expires: Date().addingTimeInterval(3600), renewalReference: "revoked", rights: [], validatedAt: Date().addingTimeInterval(-1)), context: f.ctx)
        let revoked = await outcome { _ = try await s.length(variant: "v", context: f.ctx) }
        try validIndex.write(to: index)
        let replay = await outcome { _ = try await s.read(variant: "v", offset: 0, count: 8, context: f.ctx) }
        let restarted = try EncryptedStore(root: f.objects, vault: try f.reopen()); await restarted.bind(f.ctx)
        let replayRestart = await outcome { _ = try await restarted.length(variant: "v", context: f.ctx) }
        let pinAfterReplay = await outcome { try await restarted.reference(variant: "v", reference: nil, pinned: true, context: f.ctx) }
        let del = await s.delete(try ServiceID("v"), context: f.ctx)
        let delOK: String = { if case .success = del.outcome { return "success" } else { return "failure" } }()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (n, d) in saved { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: d, attributes: [.posixPermissions: 0o600]) }
        let restored = await outcome { _ = try await restarted.read(variant: "v", offset: 0, count: 8, context: f.ctx) }
        print("OPUS02 O1 revoked=\(revoked) replayIndex=\(replay) replayAfterRestart=\(replayRestart) pinAfterReplay=\(pinAfterReplay) delete=\(delOK) restoredDirAfterDelete=\(restored)")
        XCTAssertEqual(revoked, "OfflineRecovery.renewRights")
        try await v.destroyIsolatedTestKeychain()
    }

    /// O2: protected-lease ownership vs W04 sign-out credential deletion (deleteAll) and removeLocal.
    func testO2LeaseBlocksCredentialDeletion() async throws {
        let f = try OFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault(); await v.bind(f.ctx)
        // (a) same-process live owner (simulates a lease whose release failed / was never reached)
        let credential = try await v.insert(Data("session-secret-test-only".utf8), for: OwnedMedia.account)
        let leaked = try await v.acquireProtectedLease(context: f.ctx)
        let deleteWhileHeld = await outcome { try await v.deleteAll(for: OwnedMedia.account) }
        let credentialAfter = await outcome { _ = try await v.read(credential, context: f.ctx) }
        if let leaked { try await v.releaseProtectedLease(leaked) }
        // (b) crashed owner whose PID is now another live process (pid 1, launchd: kill() -> EPERM)
        var kc: SecKeychain?; XCTAssertEqual(SecKeychainOpen(f.keychainURL.path, &kc), errSecSuccess)
        let token = UUID()
        let plant: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: f.service, kSecAttrSynchronizable as String: false,
            kSecAttrAccount as String: "protected.record.v2:protected.lock.v2", kSecUseKeychain as String: kc!,
            kSecValueData as String: Data("{\"pid\":1,\"token\":\"\(token.uuidString)\"}".utf8), kSecAttrGeneric as String: Data(token.uuidString.utf8)]
        let added = SecItemAdd(plant as CFDictionary, nil)
        let fresh = try f.reopen(); await fresh.bind(f.ctx)
        let deleteForeignPID = await outcome { try await fresh.deleteAll(for: OwnedMedia.account) }
        let credentialAfterForeign = await outcome { _ = try await fresh.read(credential, context: f.ctx) }
        let s = try EncryptedStore(root: f.objects, vault: fresh); await s.bind(f.ctx)
        let t0 = ContinuousClock.now
        let importForeign = await outcome { try await s.retain(file: try f.input(), variant: "v", grant: f.grant(at: Date()), reference: "a", context: f.ctx) }
        let waited = t0.duration(to: .now)
        let barrier = RequestContext(account: nil, accountGeneration: 2, requestGeneration: 0)
        let removeLocalForeign = await outcome { try await s.removeLocal(OwnedMedia.account, context: barrier) }
        // (c) control: crashed owner whose PID no longer exists is reclaimed
        var gone: Int32 = 99_990; while kill(gone, 0) == 0 || errno != ESRCH { gone -= 1 }
        var del: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: f.service, kSecAttrAccount as String: "protected.record.v2:protected.lock.v2", kSecMatchSearchList as String: [kc!]]
        let removedPlant = SecItemDelete(del as CFDictionary)
        var dead = plant; dead[kSecValueData as String] = Data("{\"pid\":\(gone),\"token\":\"\(token.uuidString)\"}".utf8)
        let addedDead = SecItemAdd(dead as CFDictionary, nil)
        let ctx3 = RequestContext(account: OwnedMedia.account, accountGeneration: 3, requestGeneration: 0)
        let control = try f.reopen(); await control.bind(ctx3)
        let deleteDeadPID = await outcome { try await control.deleteAll(for: OwnedMedia.account) }
        let credentialAfterDead = await outcome { _ = try await control.read(credential, context: ctx3) }
        del.removeValue(forKey: kSecMatchSearchList as String)
        print("OPUS02 O2 sameProcessHeld deleteAll=\(deleteWhileHeld) credentialAfter=\(credentialAfter) | plantedLivePID add=\(added) deleteAll=\(deleteForeignPID) credentialAfter=\(credentialAfterForeign) retain=\(importForeign) waitedMs=\(waited.components.seconds * 1000 + waited.components.attoseconds / 1_000_000_000_000_000) removeLocal=\(removeLocalForeign) | controlDeadPID(\(gone)) removedPlant=\(removedPlant) add=\(addedDead) deleteAll=\(deleteDeadPID) credentialAfter=\(credentialAfterDead)")
        XCTAssertEqual(credentialAfter,"LifecycleError.keychain(-25300)")
        XCTAssertEqual(credentialAfterForeign,"LifecycleError.keychain(-25300)")
        try await v.destroyIsolatedTestKeychain()
    }

    /// O3: an unauthenticated forward wall clock in a restarted process raises the protected floor; afterwards
    /// a correct clock plus a fresh authenticated source time cannot recover any object in the account.
    func testO3ForwardClockAfterRestartPoisonsAccountFloor() async throws {
        let f = try OFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault(); let real = Date(); let clock = OClock(real)
        let s = try EncryptedStore(root: f.objects, vault: v, wall: clock); await s.bind(f.ctx)
        try await s.retain(file: try f.input(), variant: "v", grant: f.grant(at: real, life: 7200), reference: "a", context: f.ctx)
        try await s.retain(file: try f.input(90000), variant:"existing2",grant:f.grant(at:real,life:7200),reference:"second",context:f.ctx)
        let baseline = await outcome { _ = try await s.read(variant: "v", offset: 0, count: 8, context: f.ctx) }
        // Restart with the wall clock wrongly 30 minutes ahead (grant still valid): an ordinary read succeeds.
        clock.set(real.addingTimeInterval(1800))
        let wrong = try EncryptedStore(root: f.objects, vault: try f.reopen(), wall: clock); await wrong.bind(f.ctx)
        let wrongRead = await outcome { _ = try await wrong.read(variant: "v", offset: 0, count: 8, context: f.ctx) }
        // Restart with the clock corrected.
        clock.set(real.addingTimeInterval(5))
        let fixed = try EncryptedStore(root: f.objects, vault: try f.reopen(), wall: clock); await fixed.bind(f.ctx)
        let fixedRead = await outcome { _ = try await fixed.read(variant: "v", offset: 0, count: 8, context: f.ctx) }
        let now = clock.now()
        let revalidated = await outcome { try await fixed.revalidate(variant: "v", grant: f.grant(at: now), sourceTime: now, context: f.ctx) }
        let existingAfter=await outcome{_=try await fixed.read(variant:"existing2",offset:0,count:8,context:f.ctx)}
        XCTAssertEqual(existingAfter,"success")
        let other = await outcome {
            try await fixed.retain(file: try f.input(70_000), variant: "w", grant: f.grant(at: now.addingTimeInterval(1)), reference: "b", context: f.ctx)
            _ = try await fixed.read(variant: "w", offset: 0, count: 8, context: f.ctx)
        }
        let below=await outcome{try await fixed.revalidate(variant:"v",grant:f.grant(at:now),sourceTime:real.addingTimeInterval(4),context:f.ctx)}
        XCTAssertNotEqual(below,"success")
        // Same with a one-year-ahead clock and an expired grant: the refusal path itself persists the floor.
        let f2 = try OFix(); defer { try? FileManager.default.removeItem(at: f2.root) }
        let v2 = try f2.vault(); let c2 = OClock(real)
        let s2 = try EncryptedStore(root: f2.objects, vault: v2, wall: c2); await s2.bind(f2.ctx)
        try await s2.retain(file: try f2.input(), variant: "v", grant: f2.grant(at: real), reference: "a", context: f2.ctx)
        c2.set(real.addingTimeInterval(365 * 86400))
        let y = try EncryptedStore(root: f2.objects, vault: try f2.reopen(), wall: c2); await y.bind(f2.ctx)
        let yearRead = await outcome { _ = try await y.read(variant: "v", offset: 0, count: 8, context: f2.ctx) }
        c2.set(real.addingTimeInterval(5))
        let y2 = try EncryptedStore(root: f2.objects, vault: try f2.reopen(), wall: c2); await y2.bind(f2.ctx)
        let n2 = c2.now()
        let yearRecover = await outcome { try await y2.revalidate(variant: "v", grant: f2.grant(at: n2), sourceTime: n2, context: f2.ctx) }
        print("OPUS02 O3 baseline=\(baseline) restart+30min read=\(wrongRead) correctedRestart read=\(fixedRead) freshSourceRevalidate=\(revalidated) newVariantAfterwards=\(other) | +1y expired-grant read=\(yearRead) correctedRevalidate=\(yearRecover)")
        XCTAssertEqual(baseline, "success")
        XCTAssertEqual(revalidated,"success");XCTAssertEqual(other,"success");XCTAssertEqual(yearRecover,"success")
        try await v.destroyIsolatedTestKeychain(); try await v2.destroyIsolatedTestKeychain()
    }

    func testAuthenticatedFloorCannotBeLoweredThroughAnotherObject()async throws{
        let f=try OFix();let v=try f.vault();let t=Date(timeIntervalSince1970:floor(Date().timeIntervalSince1970));let clock=OClock(t)
        defer{Task{try? await v.destroyIsolatedTestKeychain();try? FileManager.default.removeItem(at:f.root)}}
        let s=try EncryptedStore(root:f.objects,vault:v,wall:clock);await s.bind(f.ctx)
        try await s.retain(file:try f.input(),variant:"a",grant:f.grant(at:t),reference:"a",context:f.ctx)
        try await s.retain(file:try f.input(70000),variant:"b",grant:f.grant(at:t),reference:"b",context:f.ctx)
        clock.set(t.addingTimeInterval(100))
        let observed=RetentionGrant(issuer:"owned source",sourceEncryption:"none",expires:t.addingTimeInterval(3600),renewalReference:"new-source",rights:["play","retain","seek"],validatedAt:t.addingTimeInterval(4))
        try await s.revalidate(variant:"a",grant:observed,sourceTime:clock.now(),context:f.ctx)
        clock.set(t.addingTimeInterval(20))
        let below=RetentionGrant(issuer:observed.issuer,sourceEncryption:observed.sourceEncryption,expires:observed.expires,renewalReference:observed.renewalReference,rights:observed.rights,validatedAt:t.addingTimeInterval(10))
        let result=await outcome{try await s.revalidate(variant:"b",grant:below,sourceTime:clock.now(),context:f.ctx)}
        XCTAssertEqual(result,"OfflineRecovery.clockChanged")
        let reopened=try EncryptedStore(root:f.objects,vault:try f.reopen(),wall:clock);await reopened.bind(f.ctx)
        let restarted=await outcome{try await reopened.revalidate(variant:"b",grant:below,sourceTime:clock.now(),context:f.ctx)}
        XCTAssertEqual(restarted,"OfflineRecovery.clockChanged")
        clock.set(t.addingTimeInterval(101))
        let newer=RetentionGrant(issuer:observed.issuer,sourceEncryption:observed.sourceEncryption,expires:observed.expires,renewalReference:"newer-source",rights:observed.rights,validatedAt:t.addingTimeInterval(101))
        try await reopened.revalidate(variant:"b",grant:newer,sourceTime:clock.now(),context:f.ctx)
        let positive=await outcome{_=try await reopened.read(variant:"a",offset:0,count:1,context:f.ctx)}
        XCTAssertEqual(positive,"success")
        try await v.destroyIsolatedTestKeychain()
    }

    /// O4: updateGrant accepts an OLDER grant after a newer revocation (late/reordered adapter callback).
    func testO4OlderGrantAfterNewerRevocation() async throws {
        let f = try OFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault(); let t = Date()
        let s = try EncryptedStore(root: f.objects, vault: v); await s.bind(f.ctx)
        let older = RetentionGrant(issuer: "x", sourceEncryption: "none", expires: t.addingTimeInterval(3600), renewalReference: "r1", rights: ["play", "seek", "retain"], validatedAt: t.addingTimeInterval(-30))
        try await s.retain(file: try f.input(), variant: "v", grant: older, reference: "a", context: f.ctx)
        let revocation = RetentionGrant(issuer: "x", sourceEncryption: "none", expires: t.addingTimeInterval(3600), renewalReference: "r2", rights: [], validatedAt: t.addingTimeInterval(-1))
        try await s.updateGrant(variant: "v", grant: revocation, context: f.ctx)
        let afterRevocation = await outcome { _ = try await s.length(variant: "v", context: f.ctx) }
        let lateOlder = await outcome { try await s.updateGrant(variant: "v", grant: older, context: f.ctx) }
        let afterLate = await outcome { _ = try await s.length(variant: "v", context: f.ctx) }
        let revalidateOlder = await outcome { try await s.revalidate(variant: "v", grant: older, sourceTime: Date(), context: f.ctx) }
        print("OPUS02 O4 afterNewerRevocation=\(afterRevocation) updateGrant(older validatedAt)=\(lateOlder) lengthAfter=\(afterLate) | revalidate(older)=\(revalidateOlder)")
        XCTAssertEqual(afterRevocation, "OfflineRecovery.renewRights")
        XCTAssertNotEqual(lateOlder,"success");XCTAssertEqual(afterLate,"OfflineRecovery.renewRights")
        try await v.destroyIsolatedTestKeychain()
    }

    /// O5: F2/F4 positive and live seek checks through the real loader, muted engine (no Play).
    func testO5PlayOnlyDecodeReadonlyAndLiveSeekPermission() async throws {
        let f = try OFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault()
        let s = try EncryptedStore(root: f.objects, vault: v); await s.bind(f.ctx)
        let variant = try await OwnedMedia().resolve(OwnedMedia.items[0], context: f.playback).outcome.get()[0]
        let wav = try await OwnedMedia().asset(for: variant, context: f.playback)
        try await s.retain(file: wav, variant: variant.id.rawValue, grant: f.grant(["play", "retain"], at: Date()), reference: "a", context: f.ctx)
        let dir = try XCTUnwrap(f.file("index")).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let k0 = await v.protectedMetrics(); let io0 = await s.storageMetrics()
        let provider = LocalFirstOwnedAssets(store: s, fallback: OTrap())
        let asset = try await provider.nativeAsset(for: variant, context: f.playback)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(out); _ = reader.startReading()
        var frames = 0; while let b = out.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(b) }
        let k1 = await v.protectedMetrics(); let io1 = await s.storageMetrics()
        let dk = k1.reduce(into: [String: Int]()) { $0[$1.key] = $1.value - (k0[$1.key] ?? 0) }
        let dio = io1.reduce(into: [String: Int]()) { $0[$1.key] = $1.key == "maxValidationUnits" ? $1.value : $1.value - (io0[$1.key] ?? 0) }
        let publicNonzero = await outcome { _ = try await s.read(variant: variant.id.rawValue, offset: 65_536, count: 16, context: f.ctx) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // Engine: prepare muted, user seek must be refused for play-only; then grant seek -> allowed; revoke seek after prepare -> refused.
        let player = NativePlayer(assets: provider, clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true, maximumStartGain: 0.001)
        let pc = f.playback
        let prep = await player.prepare(variant, context: pc)
        let prepOK: String = { if case .success = prep.outcome { return "success" } else { return "\(prep.outcome)" } }()
        let seekPlayOnly = await player.seek(to: 10, context: pc)
        try await s.updateGrant(variant: variant.id.rawValue, grant: f.grant(["play", "retain", "seek"], at: Date()), context: f.ctx)
        let seekGranted = await player.seek(to: 10, context: pc)
        try await s.updateGrant(variant: variant.id.rawValue, grant: f.grant(["play", "retain"], at: Date().addingTimeInterval(0.1)), context: f.ctx)
        let seekRevoked = await player.seek(to: 5, context: pc)
        _ = await player.stop(context: pc)
        func r(_ x: PlaybackResult<Void>) -> String { if case .success = x.outcome { return "success" }; if case .failure(let e) = x.outcome { return "\(e)" }; return "?" }
        print("OPUS02 O5 playOnly 0500 nativeDecode status=\(reader.status.rawValue) frames=\(frames) keychainDelta=\(dk) ioDelta=\(dio) publicNonzeroRead=\(publicNonzero) | engine prepare=\(prepOK) seek(playOnly)=\(r(seekPlayOnly)) seek(afterGrant)=\(r(seekGranted)) seek(afterRevokeSeek)=\(r(seekRevoked))")
        XCTAssertEqual(reader.status, .completed)
        withExtendedLifetime((provider, asset, player)) {}
        try await v.destroyIsolatedTestKeychain()
    }
}
