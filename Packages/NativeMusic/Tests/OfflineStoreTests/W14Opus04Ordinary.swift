// W14 opus-04 ordinary integration checks on unmodified delivered source (af30ee3).
// Normal application inputs only: synthetic grants/bytes, isolated test Keychains, injected clock,
// the store's existing importStep hook to hold an ordinary import. No guard changes, no playback.
import XCTest
import Foundation
import Synchronization
import Domain
import Downloads
import AccountSession
import Playback

private final class OClock: WallClock, Sendable {
    let value: Mutex<Date>
    init(_ d: Date) { value = Mutex(d) }
    func now() -> Date { value.withLock { $0 } }
}
private actor OGate {
    var open = false; var arrived = false
    var waiters: [CheckedContinuation<Void, Never>] = []; var arrivals: [CheckedContinuation<Void, Never>] = []
    func watchdog() { if !open { XCTFail("ordinary import gate timed out"); release(); arrivals.forEach{$0.resume()}; arrivals=[] } }
    func hold() async { Task { try? await Task.sleep(for:.seconds(5)); await self.watchdog() }; arrived = true; arrivals.forEach { $0.resume() }; arrivals = []; if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func entered() async { Task { try? await Task.sleep(for:.seconds(5)); await self.watchdog() }; if arrived { return }; await withCheckedContinuation { arrivals.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}
private struct OFix {
    let root: URL
    let namespace = KeychainVault.applicationNamespace + ".test.opus04." + UUID().uuidString
    let ctx = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
    var objects: URL { root.appendingPathComponent("objects") }
    init() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("W14-opus04-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    func vault() throws -> KeychainVault { try KeychainVault(testNamespace: namespace, isolatedKeychainURL: root.appendingPathComponent("test.keychain-db")) }
    func grant(_ rights: Set<String> = ["play", "seek", "retain"], validated: Date, expires: Date) -> RetentionGrant {
        .init(issuer: "opus04 synthetic authority", sourceEncryption: "none: synthetic", expires: expires, renewalReference: "opus04", rights: rights, validatedAt: validated)
    }
    func input(_ n: Int) throws -> URL { let u = root.appendingPathComponent("input-\(n)"); try Data((0..<n).map { UInt8($0 % 233) }).write(to: u); return u }
}
private func outcome(_ op: () async throws -> Void) async -> String {
    do { try await op(); return "success" }
    catch let e as OfflineRecovery { return "OfflineRecovery.\(e.rawValue)" }
    catch let e as DomainError { return "DomainError.\(e)" }
    catch { return "other:\(error)" }
}

final class W14Opus04Ordinary: XCTestCase, @unchecked Sendable {
    /// S1: two different items whose valid grants were obtained in one order and installed in the other.
    func testS1OutOfOrderInstallsAcrossDifferentItems() async throws {
        let f = try OFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault(); let t = Date(); let clock = OClock(t)
        let s = try EncryptedStore(root: f.objects, vault: v, wall: clock); await s.bind(f.ctx)
        try await s.retain(file: try f.input(90_000), variant: "B", grant: f.grant(validated: t.addingTimeInterval(-1), expires: t.addingTimeInterval(3600)), reference: "p", context: f.ctx)
        let a = await outcome { try await s.retain(file: try f.input(80_000), variant: "A", grant: f.grant(validated: t.addingTimeInterval(-5), expires: t.addingTimeInterval(3600)), reference: "p", context: f.ctx); _ = try await s.length(variant: "A", context: f.ctx) }
        XCTAssertEqual(a,"success")
        print("OPUS04 S1 retain(B @t-1) then retain(A, different new item, valid unexpired grant @t-5) = \(a)")
        try await v.destroyIsolatedTestKeychain()
    }

    /// S2: two concurrent ordinary downloads; the one whose grant was obtained first finishes last.
    func testS2ConcurrentDownloadsCompleteOutOfOrder() async throws {
        let f = try OFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault(); let t = Date(); let clock = OClock(t)
        let gate = OGate(); let held = Mutex(true)
        let s = try EncryptedStore(root: f.objects, vault: v, wall: clock, importStep: { n in if n == 1, held.withLock({ $0 }) { await gate.hold() } }); await s.bind(f.ctx)
        let fileA = try f.input(200_000), fileB = try f.input(70_000), ctx = f.ctx
        let gA = f.grant(validated: t.addingTimeInterval(-10), expires: t.addingTimeInterval(3600))
        let gB = f.grant(validated: t.addingTimeInterval(-2), expires: t.addingTimeInterval(3600))
        let long = Task { await outcome { try await s.retain(file: fileA, variant: "A", grant: gA, reference: "playlist", context: ctx) } }
        await gate.entered(); held.withLock { $0 = false }
        let short = await outcome { try await s.retain(file: fileB, variant: "B", grant: gB, reference: "playlist", context: ctx) }
        await gate.release()
        let longResult = await long.value
        let readA = await outcome { _ = try await s.length(variant: "A", context: ctx) }
        XCTAssertEqual(short,"success"); XCTAssertEqual(longResult,"success"); XCTAssertEqual(readA,"success")
        print("OPUS04 S2 long download A (grant @t-10) held; short download B (grant @t-2)=\(short); A publication after B=\(longResult); A length=\(readA)")
        try await v.destroyIsolatedTestKeychain()
    }

    /// S3: renewal callbacks for two different items arriving out of order.
    func testS3OutOfOrderRenewalsAcrossItems() async throws {
        let f = try OFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault(); let t = Date(); let clock = OClock(t)
        let s = try EncryptedStore(root: f.objects, vault: v, wall: clock); await s.bind(f.ctx)
        for name in ["A", "B"] { try await s.retain(file: try f.input(70_000), variant: name, grant: f.grant(validated: t.addingTimeInterval(-30), expires: t.addingTimeInterval(60)), reference: "p", context: f.ctx) }
        let renewB = await outcome { try await s.updateGrant(variant: "B", grant: f.grant(validated: t.addingTimeInterval(-1), expires: t.addingTimeInterval(7200)), context: f.ctx) }
        let renewA = await outcome { try await s.updateGrant(variant: "A", grant: f.grant(validated: t.addingTimeInterval(-5), expires: t.addingTimeInterval(7200)), context: f.ctx) }
        XCTAssertEqual(renewB,"success"); XCTAssertEqual(renewA,"success")
        print("OPUS04 S3 renew B @t-1=\(renewB); then renew A @t-5 (newer than A's own history @t-30)=\(renewA)")
        try await v.destroyIsolatedTestKeychain()
    }

    /// S4: held re-import of a revoked item while a newer revocation commits (missing dedicated case).
    func testS4HeldReimportVersusNewerRevocation() async throws {
        let f = try OFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault(); let t = Date(); let clock = OClock(t)
        let gate = OGate(); let held = Mutex(false)
        let s = try EncryptedStore(root: f.objects, vault: v, wall: clock, importStep: { n in if n == 1, held.withLock({ $0 }) { await gate.hold() } }); await s.bind(f.ctx)
        let file = try f.input(200_000), ctx = f.ctx
        try await s.retain(file: file, variant: "V", grant: f.grant(validated: t.addingTimeInterval(-40), expires: t.addingTimeInterval(3600)), reference: "a", context: ctx)
        try await s.updateGrant(variant: "V", grant: f.grant([], validated: t.addingTimeInterval(-30), expires: t.addingTimeInterval(3600)), context: ctx)
        held.withLock { $0 = true }
        let recovery = f.grant(validated: t.addingTimeInterval(-10), expires: t.addingTimeInterval(3600))
        let job = Task { await outcome { try await s.retain(file: file, variant: "V", grant: recovery, reference: "job", context: ctx) } }
        await gate.entered(); held.withLock { $0 = false }
        let revoke = await outcome { try await s.updateGrant(variant: "V", grant: f.grant([], validated: t.addingTimeInterval(-1), expires: t.addingTimeInterval(3600)), context: ctx) }
        await gate.release()
        let publish = await job.value
        let after = await outcome { _ = try await s.length(variant: "V", context: ctx) }
        print("OPUS04 S4 newer revocation during held re-import=\(revoke); held re-import publication=\(publish); length after=\(after)")
        XCTAssertEqual(revoke,"success"); XCTAssertNotEqual(publish,"success")
        XCTAssertEqual(after, "OfflineRecovery.renewRights")
        try await v.destroyIsolatedTestKeychain()
    }

    /// S5: explicit revalidate of one item when another item already installed a slightly later grant.
    func testS5RevalidateAgainstAnotherItemsLaterGrant() async throws {
        let f = try OFix(); defer { try? FileManager.default.removeItem(at: f.root) }
        let v = try f.vault(); let t = Date(); let clock = OClock(t)
        let s = try EncryptedStore(root: f.objects, vault: v, wall: clock); await s.bind(f.ctx)
        try await s.retain(file: try f.input(70_000), variant: "A", grant: f.grant(validated: t.addingTimeInterval(-30), expires: t.addingTimeInterval(3600)), reference: "p", context: f.ctx)
        try await s.retain(file: try f.input(80_000), variant: "B", grant: f.grant(validated: t.addingTimeInterval(-0.2), expires: t.addingTimeInterval(3600)), reference: "p", context: f.ctx)
        let reval = await outcome { try await s.revalidate(variant: "A", grant: f.grant(validated: t.addingTimeInterval(-0.5), expires: t.addingTimeInterval(3600)), sourceTime: t, context: f.ctx) }
        XCTAssertEqual(reval,"success")
        print("OPUS04 S5 revalidate A (fresh grant @t-0.5, sourceTime t) after B installed @t-0.2 = \(reval)")
        try await v.destroyIsolatedTestKeychain()
    }
}
