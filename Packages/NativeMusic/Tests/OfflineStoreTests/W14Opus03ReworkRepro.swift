// W14 ordinary grant ordering regressions, derived from preserved Opus03 Q1/Q4.
// Uses synthetic receipts and injected clocks; no live source authorization.
// Isolated test Keychains, temp directories, synthetic bytes only. No native playback.
import XCTest
import Foundation
import Synchronization
import Domain
import Downloads
import AccountSession
import Playback

private final class QClock: WallClock, Sendable {
    let value: Mutex<Date>
    init(_ d: Date) { value = Mutex(d) }
    func now() -> Date { value.withLock { $0 } }
    func set(_ d: Date) { value.withLock { $0 = d } }
}
private struct QFix {
    let root: URL
    let namespace = KeychainVault.applicationNamespace + ".test.opus03." + UUID().uuidString
    let ctx = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
    var url: URL { root.appendingPathComponent("test.keychain-db") }
    var objects: URL { root.appendingPathComponent("objects") }
    init() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("W14-opus03-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    func vault() throws -> KeychainVault { try KeychainVault(testNamespace: namespace, isolatedKeychainURL: url) }
    func reopen() throws -> KeychainVault { try KeychainVault(testNamespace: namespace, reopeningIsolatedKeychainURL: url) }
    func grant(_ rights: Set<String> = ["play", "seek", "retain"], validated: Date, expires: Date) -> RetentionGrant {
        .init(issuer: "opus03 synthetic authority", sourceEncryption: "none: synthetic", expires: expires, renewalReference: "opus03", rights: rights, validatedAt: validated)
    }
    func input(_ n: Int = 100_000) throws -> URL { let u = root.appendingPathComponent("input-\(n)"); try Data((0..<n).map { UInt8($0 % 239) }).write(to: u); return u }
    func metadata(_ vault: KeychainVault) async throws -> [String:Data] {
        var result: [String:Data] = [:]
        for case let u as URL in FileManager.default.enumerator(at:objects,includingPropertiesForKeys:nil)!.allObjects where u.lastPathComponent == "index" {
            result[u.path] = try Data(contentsOf:u)
        }
        let candidate = try await vault.acquireProtectedLease(context:ctx)
        let lease = try XCTUnwrap(candidate)
        do {
            result["clock"] = try await vault.protectedRecord("offline.clock-fault.v3",lease:lease,context:ctx)
            try await vault.releaseProtectedLease(lease)
        } catch { try? await vault.releaseProtectedLease(lease); throw error }
        return result
    }

}
private func outcome(_ op: () async throws -> Void) async -> String {
    do { try await op(); return "success" }
    catch let e as OfflineRecovery { return "OfflineRecovery.\(e.rawValue)" }
    catch let e as LifecycleError { return "LifecycleError.\(e)" }
    catch let e as DomainError { return "DomainError.\(e)" }
    catch { return "other:\(error)" }
}

final class W14Opus03ReworkRepro: XCTestCase, @unchecked Sendable {
    /// Q1 (N3 effective history): can a stale grant undo a newer revocation through retain (re-import)?
    func testQ1StaleGrantThroughRetainAfterRevocation() async throws {
        let f = try QFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault(); let t = Date()
        let s = try EncryptedStore(root: f.objects, vault: v, wall: QClock(t)); await s.bind(f.ctx)
        let file = try f.input()
        let older = f.grant(validated: t.addingTimeInterval(-30), expires: t.addingTimeInterval(3600))
        try await s.retain(file: file, variant: "v", grant: older, reference: "a", context: f.ctx)
        try await s.retain(file: file, variant: "w", grant: older, reference: "a", context: f.ctx)
        try await s.updateGrant(variant: "v", grant: f.grant([], validated: t.addingTimeInterval(-1), expires: t.addingTimeInterval(3600)), context: f.ctx)
        let revoked = await outcome { _ = try await s.length(variant: "v", context: f.ctx) }
        let viaUpdate = await outcome { try await s.updateGrant(variant: "v", grant: older, context: f.ctx) }
        let afterUpdate = await outcome { _ = try await s.length(variant: "v", context: f.ctx) }
        let viaRetain = await outcome { try await s.retain(file: file, variant: "v", grant: older, reference: "late-job", context: f.ctx) }
        let afterRetain = await outcome { _ = try await s.length(variant: "v", context: f.ctx) }
        let restarted = try EncryptedStore(root: f.objects, vault: try f.reopen()); await restarted.bind(f.ctx)
        let afterRestart = await outcome { _ = try await restarted.read(variant: "v", offset: 70_000, count: 8, context: f.ctx) }
        // Same for a deleted object (tombstone retains the protected validation maximum).
        try await s.updateGrant(variant: "w", grant: f.grant([], validated: t.addingTimeInterval(-1), expires: t.addingTimeInterval(3600)), context: f.ctx)
        _ = await s.delete(try ServiceID("w"), context: f.ctx)
        let tombRetain = await outcome { try await s.retain(file: file, variant: "w", grant: older, reference: "late-job", context: f.ctx); _ = try await s.length(variant: "w", context: f.ctx) }
        let equalConflict = await outcome { try await s.retain(file: file, variant: "v", grant: f.grant(validated:t.addingTimeInterval(-1),expires:t.addingTimeInterval(3600)), reference:"equal", context:f.ctx) }
        XCTAssertEqual(equalConflict,"OfflineRecovery.staleGrant")
        let newer = f.grant(validated:t,expires:t.addingTimeInterval(3600))
        try await restarted.retain(file:file,variant:"v",grant:newer,reference:"fresh",context:f.ctx)
        try await restarted.retain(file:file,variant:"w",grant:newer,reference:"fresh",context:f.ctx)
        // A healthy retain adds a reference, preserving its already-current grant.
        try await restarted.retain(file:file,variant:"v",grant:older,reference:"shared",context:f.ctx)
        let freshRead = try await restarted.read(variant:"v",offset:70_000,count:8,context:f.ctx)
        XCTAssertEqual(freshRead,try Data(contentsOf:file).subdata(in:70_000..<70_008))
        let staleOther = await outcome { try await restarted.retain(file:file,variant:"new-variant",grant:older,reference:"stale",context:f.ctx) }
        XCTAssertEqual(staleOther,"success")
        print("OPUS03 Q1 revoked=\(revoked) updateGrant(older)=\(viaUpdate) lengthAfterUpdate=\(afterUpdate) retain(older, existing revoked)=\(viaRetain) lengthAfterRetain=\(afterRetain) readAfterRestart=\(afterRestart) | tombstone retain(older)+length=\(tombRetain)")
        XCTAssertEqual(revoked, "OfflineRecovery.renewRights")
        XCTAssertEqual(viaRetain,"OfflineRecovery.staleGrant");XCTAssertEqual(afterRetain,"OfflineRecovery.renewRights")
        XCTAssertEqual(afterRestart,"OfflineRecovery.renewRights");XCTAssertEqual(tombRetain,"OfflineRecovery.staleGrant")
        try await v.destroyIsolatedTestKeychain()
    }

    func testQ1bControlNewerGrantRecovers() async throws {
        let f = try QFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault(); let t = Date()
        let s = try EncryptedStore(root: f.objects, vault: v); await s.bind(f.ctx)
        let file = try f.input()
        try await s.retain(file: file, variant: "v", grant: f.grant(validated: t.addingTimeInterval(-30), expires: t.addingTimeInterval(3600)), reference: "a", context: f.ctx)
        try await s.updateGrant(variant: "v", grant: f.grant([], validated: t.addingTimeInterval(-10), expires: t.addingTimeInterval(3600)), context: f.ctx)
        let newer = await outcome { try await s.updateGrant(variant: "v", grant: f.grant(validated: t.addingTimeInterval(-1), expires: t.addingTimeInterval(3600)), context: f.ctx); _ = try await s.length(variant: "v", context: f.ctx) }
        print("OPUS03 Q1b newerGrantRecovers=\(newer)")
        XCTAssertEqual(newer, "success")
        try await v.destroyIsolatedTestKeychain()
    }

    /// Q4: an authenticated grant whose validatedAt is a few seconds ahead of the local clock.
    func testQ4SourceSlightlyAheadOfLocalClock() async throws {
        let f = try QFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault(); let real = Date(); let clock = QClock(real)
        let s = try EncryptedStore(root: f.objects, vault: v, wall: clock); await s.bind(f.ctx)
        try await s.retain(file: try f.input(), variant: "v", grant: f.grant(validated: real.addingTimeInterval(-10), expires: real.addingTimeInterval(3600)), reference: "a", context: f.ctx)
        try await s.retain(file: try f.input(90_000), variant: "u", grant: f.grant(validated: real.addingTimeInterval(-10), expires: real.addingTimeInterval(3600)), reference: "a", context: f.ctx)
        let uBefore = await outcome { _ = try await s.read(variant: "u", offset: 0, count: 8, context: f.ctx) }
        let ahead = f.grant(validated: real.addingTimeInterval(5), expires: real.addingTimeInterval(3600))
        let before = try await f.metadata(v)
        let update = await outcome { try await s.updateGrant(variant: "v", grant: ahead, context: f.ctx) }
        let after = try await f.metadata(v)
        XCTAssertTrue(before == after,"Rejected future receipt must not change current indexes or clock state")
        let read1 = await outcome { _ = try await s.read(variant: "v", offset: 0, count: 8, context: f.ctx) }
        clock.set(real.addingTimeInterval(8))
        let s2 = try EncryptedStore(root: f.objects, vault: try f.reopen(), wall: clock); await s2.bind(f.ctx)
        let read2 = await outcome { _ = try await s2.read(variant: "v", offset: 0, count: 8, context: f.ctx) }
        let uAfter = await outcome { _ = try await s2.read(variant: "u", offset: 0, count: 8, context: f.ctx) }
        let recover = await outcome { try await s2.updateGrant(variant: "v", grant: ahead, context: f.ctx); _ = try await s2.read(variant: "u", offset: 0, count: 8, context: f.ctx) }
        XCTAssertEqual(recover,"success")
        print("OPUS03 Q4 otherObjectBefore=\(uBefore) updateGrant(validatedAt=wall+5s)=\(update) readNow=\(read1) readAfterWallCatchesUp(+8s, restart)=\(read2) otherObjectAfter=\(uAfter) nowValidOrdinaryUpdateThenOther=\(recover)")
        XCTAssertEqual(update,"OfflineRecovery.renewRights");XCTAssertEqual(read1,"success");XCTAssertEqual(read2,"success");XCTAssertEqual(uAfter,"success")
        try await v.destroyIsolatedTestKeychain()
    }
}
