import XCTest
import Foundation
import CryptoKit
import Synchronization
import Darwin
import Domain
import AccountSession
import Downloads
import Playback

private func stageEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(actual, expected, file: file, line: line) }
private func stageNotEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotEqual(actual, expected, file: file, line: line) }
private struct AuthorityClock: WallClock { let time: Date; func now() -> Date { time } }
private enum InjectedCommitFailure: Error { case requested }
private actor CommitGate {
    var reached = false
    var waiting: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    private func watchdog() { guard waiting != nil || observer != nil else{return};XCTFail("Bounded security gate timed out");waiting?.resume();waiting=nil;observer?.resume();observer=nil;reached=true }
    func pause() async { Task{[weak self] in try? await Task.sleep(for:.seconds(5));await self?.watchdog()};reached = true; observer?.resume(); observer = nil; await withCheckedContinuation { waiting = $0 } }
    func entered() async { if reached { return };Task{[weak self] in try? await Task.sleep(for:.seconds(5));await self?.watchdog()}; await withCheckedContinuation { observer = $0 } }
    func resume() { waiting?.resume(); waiting = nil }
}
private actor FailingProtectedVault: ScopedProtectedRecords {
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) async throws { try await real.replace(reference, with: bytes, context: context) }
    let real: KeychainVault
    var failCurrent = false
    init(_ real: KeychainVault) { self.real = real }
    func arm() { failCurrent = true }
    func bind(_ context: RequestContext) async { await real.bind(context) }
    func insert(_ bytes: Data, for account: AccountContext) async throws -> CredentialReference { try await real.insert(bytes, for: account) }
    func read(_ reference: CredentialReference, context: RequestContext) async throws -> Data { try await real.read(reference, context: context) }
    func delete(_ reference: CredentialReference, for account: AccountContext) async throws { try await real.delete(reference, for: account) }
    func deleteAll(for account: AccountContext) async throws { try await real.deleteAll(for: account) }
    func eraseProtectedAccount(_ account: AccountContext, barrier: RequestContext, cleanup: @Sendable () throws -> Void) async throws { try await real.eraseProtectedAccount(account, barrier: barrier, cleanup: cleanup) }
    func acquireProtectedLease(context: RequestContext) async throws -> ProtectedRecordLease? { try await real.acquireProtectedLease(context: context) }
    func releaseProtectedLease(_ lease: ProtectedRecordLease) async throws { try await real.releaseProtectedLease(lease) }
    func protectedRecordStamp(_ name: String, lease: ProtectedRecordLease, context: RequestContext) async throws -> ProtectedRecordStamp? { try await real.protectedRecordStamp(name, lease: lease, context: context) }
    func protectedRecord(_ name: String, lease: ProtectedRecordLease, context: RequestContext) async throws -> Data? { try await real.protectedRecord(name, lease: lease, context: context) }
    func replaceProtectedRecord(_ name: String, value: Data?, lease: ProtectedRecordLease, context: RequestContext) async throws {
        if failCurrent, let value, name.hasPrefix("offline.object.v2."),
           (try JSONSerialization.jsonObject(with: value) as? [String: Any])?["state"] as? String == "current" {
            failCurrent = false; throw InjectedCommitFailure.requested
        }
        try await real.replaceProtectedRecord(name, value: value, lease: lease, context: context)
    }
}
private struct AuthorityFixture {
    let root: URL
    let namespace: String
    let time: Date
    let context: RequestContext
    var objects: URL { root.appendingPathComponent("objects") }
    var input: URL { root.appendingPathComponent("input") }
    var clock: AuthorityClock { .init(time: time) }
    var recordName: String { "offline.object.v2." + SHA256.hash(data: Data("v".utf8)).map { String(format: "%02x", $0) }.joined() }
    init(root: URL? = nil, namespace: String? = nil, time: Date? = nil) throws {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("W14-stage-A-" + UUID().uuidString)
        self.namespace = namespace ?? KeychainVault.applicationNamespace + ".test.stage-a." + UUID().uuidString
        self.time = time ?? Date()
        context = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func grant(_ rights: Set<String> = ["play", "seek", "retain"], offset: TimeInterval = -30) -> RetentionGrant {
        .init(issuer: "Stage A owned authority", sourceEncryption: "none: owned bytes", expires: time.addingTimeInterval(3600), renewalReference: "stage-a-explicit", rights: rights, validatedAt: time.addingTimeInterval(offset))
    }
    func vault() throws -> KeychainVault { try KeychainVault(testNamespace: namespace, isolatedKeychainURL: root.appendingPathComponent("isolated.keychain-db")) }
    func store(_ vault: any ScopedProtectedRecords, step: (@Sendable (OfflineSecurityStage) async throws -> Void)? = nil) async throws -> EncryptedStore {
        let store = try EncryptedStore(root: objects, vault: vault, wall: clock, securityStep: step)
        await store.bind(context); return store
    }
    func seed(_ store: EncryptedStore) async throws {
        try Data(repeating: 9, count: 150_000).write(to: input)
        try await store.retain(file: input, variant: "v", grant: grant(), reference: "collection-a", context: context)
    }
    func index() throws -> URL {
        try XCTUnwrap(FileManager.default.enumerator(at: objects, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first { $0.lastPathComponent == "index" })
    }
    func child(_ expectation: String, crash: String? = nil) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "OfflineStoreTests.StageAAuthorityTests/testChildOpen", Bundle(for: StageAAuthorityTests.self).bundlePath]
        var env = ProcessInfo.processInfo.environment
        env["W14_STAGE_A_ROOT"] = root.path; env["W14_STAGE_A_NAMESPACE"] = namespace
        env["W14_STAGE_A_TIME"] = String(time.timeIntervalSince1970); env["W14_STAGE_A_EXPECT"] = expectation
        if let crash { env["W14_STAGE_A_CRASH"] = crash }
        process.environment = env
        let output = root.appendingPathComponent(UUID().uuidString + ".child.log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output); process.standardOutput = handle; process.standardError = handle
        try process.run(); waitForOwnedTestProcess(process); try handle.close()
        let text = try String(contentsOf: output, encoding: .utf8)
        print("STAGE_A_CHILD expected=\(expectation) crash=\(crash ?? "none") exit=\(process.terminationStatus)\n" + text)
        stageEqual(process.terminationStatus, crash == nil ? 0 : 73)
        if crash == nil { XCTAssertTrue(text.contains("STAGE_A_CHILD_OBSERVED=" + expectation)) }
    }
}
final class StageAAuthorityTests: XCTestCase, @unchecked Sendable {
    private func outcome(_ operation: () async throws -> Void) async -> String {
        do { try await operation(); return "success" } catch let error as OfflineRecovery { return error.rawValue } catch { return String(describing: error) }
    }
    private func deny(_ store: EncryptedStore, _ f: AuthorityFixture, expected: String = "redownload") async {
        let length = await outcome { _ = try await store.length(variant: "v", context: f.context) }
        let read = await outcome { _ = try await store.read(variant: "v", offset: 0, count: 1, context: f.context) }
        stageEqual(length, expected); stageEqual(read, expected)
    }
    func testChildOpen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["W14_STAGE_A_ROOT"], let namespace = env["W14_STAGE_A_NAMESPACE"], let time = env["W14_STAGE_A_TIME"], let expected = env["W14_STAGE_A_EXPECT"] else { return }
        let f = try AuthorityFixture(root: URL(fileURLWithPath: root), namespace: namespace, time: Date(timeIntervalSince1970: Double(time)!))
        let vault = try KeychainVault(testNamespace: namespace, reopeningIsolatedKeychainURL: f.root.appendingPathComponent("isolated.keychain-db"))
        let crash = env["W14_STAGE_A_CRASH"]
        let store = try await f.store(vault, step: { stage in
            if (crash == "pending" && stage == .afterPending) || (crash == "files" && stage == .afterFiles) { _exit(73) }
        })
        if crash != nil { try await store.updateGrant(variant: "v", grant: f.grant([],offset:crash == "pending" ? -25 : -15), context: f.context); XCTFail("Crash hook not reached"); return }
        let actual = await outcome {
            let bytes = try await store.read(variant: "v", offset: 0, count: 1, context: f.context)
            stageEqual(bytes, Data([9]))
        }
        stageEqual(actual, expected); print("STAGE_A_CHILD_OBSERVED=" + actual)
    }
    func testReplayRevocationAndCurrentControl() async throws {
        let f = try AuthorityFixture(); let vault = try f.vault(); let store = try await f.store(vault)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.seed(store)
        stageEqual(try await store.read(variant: "v", offset: 0, count: 1, context: f.context), Data([9]))
        let index = try f.index(); let old = try Data(contentsOf: index)
        try f.child("success")
        // All grant fields are identical to the positive control except rights.
        try await store.updateGrant(variant: "v", grant: f.grant([]), context: f.context)
        await deny(store, f, expected: "renewRights")
        let current = try Data(contentsOf: index); try current.write(to: index)
        await deny(store, f, expected: "renewRights"); try f.child("renewRights")
        try old.write(to: index)
        await deny(store, f)
        let fresh = try await f.store(vault); await deny(fresh, f)
        try f.child("redownload")
        // An explicit fresh authorized import, not open, can establish a new revision.
        try await fresh.retain(file: f.input, variant: "v", grant: f.grant(offset:-20), reference: "fresh", context: f.context)
        stageEqual(try await fresh.read(variant: "v", offset: 0, count: 1, context: f.context), Data([9]))
        try f.child("success")
        try await vault.destroyIsolatedTestKeychain()
    }
    func testDeleteReplayAndMissingAuthorityCannotEnroll() async throws {
        let f = try AuthorityFixture(); let vault = try f.vault(); let store = try await f.store(vault)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.seed(store)
        let dir = try f.index().deletingLastPathComponent()
        let saved = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: dir.path).map { ($0, try Data(contentsOf: dir.appendingPathComponent($0))) })
        try await store.delete(ServiceID("v"), context: f.context).outcome.get()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (name, data) in saved { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: data, attributes: [.posixPermissions: 0o600]) }
        await deny(store, f); try f.child("redownload")
        let fresh = try await f.store(vault); await deny(fresh, f)
        try await fresh.retain(file: f.input, variant: "v", grant: f.grant(offset:-20), reference: "fresh", context: f.context)
        let candidateLease = try await vault.acquireProtectedLease(context: f.context)
        let lease = try XCTUnwrap(candidateLease)
        // Simulates a legacy valid container without enrollment; leaves the master key intact.
        try await vault.replaceProtectedRecord(f.recordName, value: nil, lease: lease, context: f.context)
        try await vault.releaseProtectedLease(lease)
        await deny(fresh, f); try f.child("redownload")
        try await fresh.retain(file: f.input, variant: "v", grant: f.grant(offset:-10), reference: "explicit", context: f.context)
        stageEqual(try await fresh.read(variant: "v", offset: 0, count: 1, context: f.context), Data([9]))
        try await vault.destroyIsolatedTestKeychain()
    }
    func testReferenceAndPinSnapshotsAreNotReplayable() async throws {
        let f = try AuthorityFixture(); let vault = try f.vault(); let store = try await f.store(vault)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.seed(store); let index = try f.index(); let old = try Data(contentsOf: index)
        try await store.reference(variant: "v", reference: "collection-b", pinned: true, context: f.context)
        let current = try Data(contentsOf: index)
        try old.write(to: index); await deny(store, f)
        try current.write(to: index)
        stageEqual(try await store.length(variant: "v", context: f.context), 150_000)
        try await store.reference(variant: "v", reference: nil, remove: "collection-a", context: f.context)
        try await store.reference(variant: "v", reference: nil, remove: "collection-b", context: f.context)
        stageEqual(try await store.length(variant: "v", context: f.context), 150_000)
        try await store.reference(variant: "v", reference: nil, pinned: false, context: f.context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirOf(index).path))
        try await vault.destroyIsolatedTestKeychain()
    }
    private func dirOf(_ index: URL) -> URL { index.deletingLastPathComponent() }
    func testFailureAfterPendingAndFailureAtFinalProtectedWrite() async throws {
        let f = try AuthorityFixture(); let real = try f.vault(); let vault = FailingProtectedVault(real)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let initial = try await f.store(vault); try await f.seed(initial)
        let index = try f.index(); let old = try Data(contentsOf: index)
        let failing = try await f.store(vault, step: { if $0 == .afterPending { throw InjectedCommitFailure.requested } })
        let failed = await outcome { try await failing.updateGrant(variant: "v", grant: f.grant([]), context: f.context) }
        stageNotEqual(failed, "success")
        try old.write(to: index); await deny(initial, f); try f.child("redownload")
        try await initial.retain(file: f.input, variant: "v", grant: f.grant(offset:-20), reference: "revalidated", context: f.context)
        let beforeFinalFailure = try Data(contentsOf: index)
        await vault.arm()
        let finalFailure = await outcome { try await initial.updateGrant(variant: "v", grant: f.grant([],offset:-15), context: f.context) }
        stageNotEqual(finalFailure, "success")
        try beforeFinalFailure.write(to: index); await deny(initial, f); try f.child("redownload")
        try await initial.retain(file: f.input, variant: "v", grant: f.grant(offset:-10), reference: "fresh", context: f.context)
        stageEqual(try await initial.length(variant: "v", context: f.context), 150_000)
        try await real.destroyIsolatedTestKeychain()
    }
    func testActualProcessCrashWindowsDoNotRestoreAuthority() async throws {
        let f = try AuthorityFixture(); let vault = try f.vault(); let store = try await f.store(vault)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.seed(store)
        for stage in ["pending", "files"] {
            let index = try f.index(); let old = try Data(contentsOf: index)
            try f.child("crash", crash: stage)
            try old.write(to: index)
            await deny(store, f); try f.child("redownload")
            try await store.retain(file: f.input, variant: "v", grant: f.grant(offset:stage == "pending" ? -20 : -10), reference: "fresh", context: f.context)
            stageEqual(try await store.length(variant: "v", context: f.context), 150_000)
        }
        try await vault.destroyIsolatedTestKeychain()
    }
    func testLeaseExclusionStaleReleaseAndMasterPurpose() async throws {
        let f = try AuthorityFixture(); let vault = try f.vault(); let store = try await f.store(vault)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.seed(store)
        let firstMaybe = try await vault.acquireProtectedLease(context: f.context)
        let first = try XCTUnwrap(firstMaybe)
        let competing = try KeychainVault(testNamespace: f.namespace, reopeningIsolatedKeychainURL: f.root.appendingPathComponent("isolated.keychain-db"))
        await competing.bind(f.context)
        let unavailable = try await competing.acquireProtectedLease(context: f.context)
        XCTAssertNil(unavailable)
        try await vault.releaseProtectedLease(first)
        let secondMaybe = try await competing.acquireProtectedLease(context: f.context)
        let second = try XCTUnwrap(secondMaybe)
        try await vault.releaseProtectedLease(first) // Must not erase the new token.
        let stillOwned = try await competing.protectedRecord(f.recordName, lease: second, context: f.context)
        XCTAssertNotNil(stillOwned)
        try await competing.releaseProtectedLease(second)
        let unrelated = try await vault.insert(Data(repeating: 7, count: 32), for: OwnedMedia.account)
        let accountDirectory = try f.index().deletingLastPathComponent().deletingLastPathComponent()
        try Data(unrelated.rawValue.utf8).write(to: accountDirectory.appendingPathComponent("key-reference"))
        stageEqual(try await store.read(variant: "v", offset: 0, count: 1, context: f.context), Data([9]))
        let thirdMaybe = try await vault.acquireProtectedLease(context: f.context)
        let third = try XCTUnwrap(thirdMaybe)
        try await vault.replaceProtectedRecord("offline.master.v2", value: nil, lease: third, context: f.context)
        try await vault.releaseProtectedLease(third)
        stageEqual(await outcome { _ = try await store.read(variant: "v", offset: 0, count: 1, context: f.context) }, "missingKey")
        // The 32-byte unrelated credential remains present but cannot substitute for a named master.
        stageEqual(try await vault.read(unrelated, context: f.context), Data(repeating: 7, count: 32))
        try await vault.destroyIsolatedTestKeychain()
    }
    func testStaleMutatorCannotPublishAndAnotherAccountSurvivesCleanup() async throws {
        let f = try AuthorityFixture(); let vault = try f.vault(); let original = try await f.store(vault)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.seed(original)
        let gate = CommitGate()
        let held = try await f.store(vault, step: { if $0 == .beforePending { await gate.pause() } })
        let oldGrant=f.grant()
        let freshHeld=RetentionGrant(issuer:oldGrant.issuer,sourceEncryption:oldGrant.sourceEncryption,expires:oldGrant.expires,renewalReference:oldGrant.renewalReference,rights:oldGrant.rights,validatedAt:f.time)
        let pending = Task { try await held.updateGrant(variant: "v", grant: freshHeld, context: f.context) }
        await gate.entered()
        let barrier = RequestContext(account: nil, accountGeneration: 2, requestGeneration: 0)
        try await held.detach(previous: f.context, barrier: barrier)
        let next = RequestContext(account: OwnedMedia.account, accountGeneration: 3, requestGeneration: 0)
        let current = try EncryptedStore(root: f.objects, vault: vault, wall: f.clock); await current.bind(next)
        let revoke = Task { try await current.updateGrant(variant: "v", grant: f.grant([]), context: next) }
        await gate.resume()
        stageNotEqual(await outcome { try await pending.value }, "success")
        try await revoke.value
        stageEqual(await outcome { _ = try await current.read(variant: "v", offset: 0, count: 1, context: next) }, "renewRights")
        let other = try AccountContext(accountID: UUID(), channelID: ID("owned-other"), region: "US")
        let otherContext = RequestContext(account: other, accountGeneration: 4, requestGeneration: 0)
        await current.bind(otherContext)
        try await current.retain(file: f.input, variant: "v", grant: f.grant(), reference: "other", context: otherContext)
        let cleanupBarrier = RequestContext(account: nil, accountGeneration: 5, requestGeneration: 0)
        try await current.removeLocal(OwnedMedia.account, context: cleanupBarrier)
        let ownerAfter = RequestContext(account: OwnedMedia.account, accountGeneration: 6, requestGeneration: 0)
        await vault.bind(ownerAfter)
        _ = try await vault.insert(Data("fresh-owned-authentication".utf8),for:OwnedMedia.account)
        let candidateLease = try await vault.acquireProtectedLease(context: ownerAfter)
        let lease = try XCTUnwrap(candidateLease)
        let master = try await vault.protectedRecord("offline.master.v2", lease: lease, context: ownerAfter)
        let checkpoint = try await vault.protectedRecord(f.recordName, lease: lease, context: ownerAfter)
        XCTAssertNil(master); XCTAssertNil(checkpoint)
        try await vault.releaseProtectedLease(lease)
        let otherAfter = RequestContext(account: other, accountGeneration: 7, requestGeneration: 0)
        await current.bind(otherAfter)
        stageEqual(try await current.read(variant: "v", offset: 0, count: 1, context: otherAfter), Data([9]))
        try await vault.destroyIsolatedTestKeychain()
    }
}
