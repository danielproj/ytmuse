import XCTest
import Foundation
import Synchronization
@preconcurrency import AVFoundation
import CoreMedia
import Domain
import Downloads
@testable import Playback
import AccountSession

private func equal<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, file: file, line: line) }
private func notNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotNil(value, file: file, line: line) }
private func positive(_ value: Int, file: StaticString = #filePath, line: UInt = #line) { XCTAssertGreaterThan(value, 0, file: file, line: line) }
private func near(_ value: Double, _ expected: Double, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(value, expected, accuracy: 0.01, file: file, line: line) }
private func failure(_ value: Result<Void, DomainError>, _ expected: DomainError, file: StaticString = #filePath, line: UInt = #line) {
    switch value { case .failure(let error): XCTAssertEqual(error, expected, file: file, line: line); case .success: XCTFail("Expected failure: \(expected)", file: file, line: line) }
}
private struct BWall: WallClock { let time: Date; func now() -> Date { time } }
private final class BMutableWall: WallClock, Sendable {
    let value: Mutex<Date>
    init(time: Date) { value = Mutex(time) }
    func now() -> Date { value.withLock { $0 } }
    func jump(_ seconds: Double) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
private struct BMono: MonotonicClock { func now() -> Duration { .zero } }
private actor BGate {
    var opened = false; var arrived = false
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var arrivals: [UUID: CheckedContinuation<Void, Never>] = [:]
    private func timeout(_ id:UUID, arrival:Bool) {
        let continuation = arrival ? arrivals.removeValue(forKey:id) : waiters.removeValue(forKey:id)
        guard let continuation else{return}
        XCTFail("Bounded owned loader gate timed out (arrival=\(arrival))")
        continuation.resume()
        // Release other owned waits so a deliberately bad plant reaches assertions
        // and normal disposal, rather than leaving an uncooperative loser alive.
        opened=true;for c in waiters.values{c.resume()};waiters.removeAll()
        for c in arrivals.values{c.resume()};arrivals.removeAll()
    }
    func wait() async {
        arrived=true;for c in arrivals.values{c.resume()};arrivals.removeAll()
        if opened{return}
        let id=UUID()
        await withCheckedContinuation{waiters[id]=$0
            Task{[weak self] in try? await Task.sleep(for:.seconds(3));await self?.timeout(id,arrival:false)}
        }
    }
    func entered() async {
        if arrived{return};let id=UUID()
        await withCheckedContinuation{arrivals[id]=$0
            Task{[weak self] in try? await Task.sleep(for:.seconds(3));await self?.timeout(id,arrival:true)}
        }
    }
    func open(){opened=true;for c in waiters.values{c.resume()};waiters.removeAll()}
}
private actor BProbe {
    let requestGate = BGate(); let failureGate = BGate(); let discarded = BGate()
    var events: [(OwnedLoaderStage, ServiceID, PlaybackContext)] = []
    let held: ServiceID; let holdFailure: Bool
    init(held: ServiceID, holdFailure: Bool = false) { self.held = held; self.holdFailure = holdFailure }
    func observe(_ stage: OwnedLoaderStage, _ id: ServiceID, _ context: PlaybackContext) async {
        events.append((stage,id,context))
        if id == held, stage == .requestStarted { await requestGate.wait() }
        if id == held, stage == .requestFailed, holdFailure { await failureGate.wait() }
        if id == held, stage == .requestFailureDiscarded { await discarded.open() }
    }
    func count(_ stage: OwnedLoaderStage, _ id: ServiceID) -> Int { events.filter { $0.0 == stage && $0.1 == id }.count }
}
private struct BFixture {
    let root: URL
    let time = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let context = RequestContext(account: OwnedMedia.account, accountGeneration: 1, requestGeneration: 0)
    var playback: PlaybackContext { .init(request: context, generation: 1, occurrenceID: nil, route: nil) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("W14-stage-B-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func vault() throws -> KeychainVault { try KeychainVault(testNamespace: KeychainVault.applicationNamespace + ".test.stage-b." + UUID().uuidString, isolatedKeychainURL: root.appendingPathComponent("isolated.keychain-db")) }
    func store(_ vault: KeychainVault, wall: (any WallClock)? = nil) async throws -> EncryptedStore {
        let store = try EncryptedStore(root: root.appendingPathComponent("objects"), vault: vault, wall: wall ?? BWall(time: time), monotonic: BMono())
        await store.bind(context); return store
    }
    func grant(_ rights: Set<String> = ["play", "seek", "retain"], order: Double = 0) -> RetentionGrant {
        .init(issuer: "Owned stage-B authority", sourceEncryption: "none: owned PCM", expires: time.addingTimeInterval(3600), renewalReference: "owned-explicit", rights: rights, validatedAt: time.addingTimeInterval(-10 + order))
    }
    func variant(_ n: Int = 0) async throws -> MediaVariant { try await OwnedMedia().resolve(OwnedMedia.items[n], context: playback).outcome.get()[0] }
    func retain(_ store: EncryptedStore, _ variant: MediaVariant, _ rights: Set<String> = ["play", "seek", "retain"]) async throws {
        let file = try await OwnedMedia().asset(for: variant, context: playback)
        try await store.retain(file: file, variant: variant.id.rawValue, grant: grant(rights), reference: "owned", context: context)
    }
}
private struct BFallbackTrap: NativeAssetProvider {
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { XCTFail("Retained route used fallback"); throw DomainError.offline }
}
private final class BCounter: Sendable { let value = Mutex(0) }
private struct BOverride: NativeAssetProvider {
    let url: URL; let calls: BCounter
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { XCTFail("Default file extension used"); throw DomainError.offline }
    func nativeAsset(for variant: MediaVariant, context: PlaybackContext) async throws -> AVURLAsset { calls.value.withLock { $0 += 1 }; return AVURLAsset(url: url) }
}
private actor BPermissions {
    let first = BGate(); let second = BGate()
    var calls = 0; let sequenced: Bool
    init(sequenced: Bool) { self.sequenced = sequenced }
    func check(_ variant: ServiceID) async {
        if variant != OwnedMedia.items[0] { return }
        calls += 1
        if calls == 1 { await first.wait() }
        else if sequenced && calls == 2 { await second.wait() }
    }
}
private struct BHeldPermissionProvider: NativeAssetProvider {
    let permissions: BPermissions
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { try await OwnedMedia().asset(for: variant, context: context) }
    func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession {
        NativeAssetSession(asset: AVURLAsset(url: try await asset(for: variant, context: context)), userSeekable: true, authorizeUserSeek: {
            await permissions.check(variant.id)
        })
    }
}
final class StageBNativeTests: XCTestCase, @unchecked Sendable {
    func testPlayOnlyFullDecodeAndActualSeekPermission() async throws {
        let f = try BFixture(); let vault = try f.vault(); let store = try await f.store(vault); let variant = try await f.variant()
        let provider = LocalFirstOwnedAssets(store: store, fallback: BFallbackTrap())
        let player = NativePlayer(assets: provider, clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true, maximumStartGain: 0.001)
        defer { Task { _ = await player.stop(context: f.playback); try? await vault.destroyIsolatedTestKeychain(); try? FileManager.default.removeItem(at: f.root) } }
        try await f.retain(store, variant, ["play", "retain"])
        _ = try await store.read(variant: variant.id.rawValue, offset: 0, count: 1, context: f.context)
        do { _ = try await store.read(variant: variant.id.rawValue, offset: 65_536, count: 16, context: f.context); XCTFail("Arbitrary seek granted") }
        catch { equal(error as? OfflineRecovery, .seekNotPermitted) }
        let delivered = Mutex(false)
        do { try await store.deliver(variant: variant.id.rawValue, offset: 65_536, count: 16, context: f.context) { _ in delivered.withLock { $0 = true } }; XCTFail("Public delivery bypassed seek") }
        catch { equal(error as? OfflineRecovery, .seekNotPermitted) }
        XCTAssertFalse(delivered.withLock { $0 })
        let asset = try await provider.nativeAsset(for: variant, context: f.playback)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var frames = 0; var buffers = 0
        while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample); buffers += 1 }
        equal(reader.status, .completed); equal(frames, 576_000); XCTAssertGreaterThan(buffers, 1)
        print("STAGE_B play-only native full decode frames=\(frames) buffers=\(buffers) sourceBytes=2304044")
        try await player.prepare(variant, context: f.playback).outcome.get()
        equal(await player.mediaInfo()?.userSeekable, false)
        let before = await player.nativePosition()
        failure(await player.seek(to: 1, context: f.playback).outcome, .forbidden)
        equal(await player.nativePosition(), before)
        notNil(await player.mediaInfo())
        try await store.updateGrant(variant: variant.id.rawValue, grant: f.grant(order: 1), context: f.context)
        try await player.seek(to: 1, context: f.playback).outcome.get()
        near(await player.nativePosition(), 1)
        equal(await player.mediaInfo()?.userSeekable, true)
        _ = try await store.read(variant: variant.id.rawValue, offset: 65_536, count: 16, context: f.context)
        try await store.updateGrant(variant: variant.id.rawValue, grant: f.grant(["play", "retain"], order: 2), context: f.context)
        let at = await player.nativePosition()
        failure(await player.seek(to: 2, context: f.playback).outcome, .forbidden); equal(await player.nativePosition(), at)
        equal(await player.mediaInfo()?.userSeekable, false)
        _ = await player.stop(context: f.playback)
        withExtendedLifetime((provider, asset)) {}
        try await vault.destroyIsolatedTestKeychain(); try FileManager.default.removeItem(at: f.root)
    }
    func testRightsOnlyPairAndNativeAdmissionEffectiveGuards() async throws {
        let f = try BFixture(); let vault = try f.vault(); let store = try await f.store(vault); let variant = try await f.variant()
        defer { Task { try? await vault.destroyIsolatedTestKeychain(); try? FileManager.default.removeItem(at: f.root) } }
        try await f.retain(store, variant)
        _ = try await store.length(variant: variant.id.rawValue, context: f.context)
        _ = try await store.read(variant: variant.id.rawValue, offset: 0, count: 1, context: f.context)
        try await store.updateGrant(variant: variant.id.rawValue, grant: f.grant([]), context: f.context)
        do { _ = try await store.length(variant: variant.id.rawValue, context: f.context); XCTFail("Revoked length accepted") } catch { equal(error as? OfflineRecovery, .renewRights) }
        do { _ = try await store.read(variant: variant.id.rawValue, offset: 0, count: 1, context: f.context); XCTFail("Revoked read0 accepted") } catch { equal(error as? OfflineRecovery, .renewRights) }
        let other = try AccountContext(accountID: UUID(), channelID: ID("owned-other"), region: "US")
        let foreign = PlaybackContext(request: RequestContext(account: other, accountGeneration: 1, requestGeneration: 0), generation: 1, occurrenceID: nil, route: nil)
        for (url, context) in [(URL(string: "https://127.0.0.1:1/closed.wav")!, f.playback), (URL(string: "owned-encrypted://media/foreign.wav")!, foreign)] {
            let calls = BCounter()
            let player = NativePlayer(assets: BOverride(url: url, calls: calls), clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true, maximumStartGain: 0.001)
            failure(await player.prepare(variant, context: context).outcome, .forbidden)
            equal(calls.value.withLock { $0 }, 1)
            _ = await player.stop(context: context)
        }
        try await vault.destroyIsolatedTestKeychain(); try FileManager.default.removeItem(at: f.root)
    }
    func testHeldNativeSeekCannotMoveReplacementAndLatestSeekWins() async throws {
        let f = try BFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try await f.variant(); let b = try await f.variant(1)
        for reuseContext in [false, true] {
            let permissions = BPermissions(sequenced: false)
            let player = NativePlayer(assets: BHeldPermissionProvider(permissions: permissions), clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true, maximumStartGain: 0.001)
            try await player.prepare(a, context: f.playback).outcome.get()
            let count = await player.nativeSeekCount()
            let old = Task { await player.seek(to: 3, context: f.playback) }
            await permissions.first.entered()
            let newer = reuseContext ? f.playback : PlaybackContext(request: f.context, generation: 2, occurrenceID: UUID(), route: nil)
            try await player.prepare(b, context: newer).outcome.get()
            await permissions.first.open()
            failure(await old.value.outcome, .staleContext)
            equal(await player.nativeSeekCount(), count)
            near(await player.nativePosition(), 0)
            try await player.seek(to: 1, context: newer).outcome.get()
            near(await player.nativePosition(), 1)
            _ = await player.stop(context: newer)
        }
        let permissions = BPermissions(sequenced: true)
        let player = NativePlayer(assets: BHeldPermissionProvider(permissions: permissions), clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true, maximumStartGain: 0.001)
        try await player.prepare(a, context: f.playback).outcome.get()
        let old = Task { await player.seek(to: 2, context: f.playback) }; await permissions.first.entered()
        let latest = Task { await player.seek(to: 4, context: f.playback) }; await permissions.second.entered()
        await permissions.second.open(); try await latest.value.outcome.get()
        await permissions.first.open(); failure(await old.value.outcome, .staleContext)
        near(await player.nativePosition(), 4)
        equal(await player.nativeSeekCount(), 1)
        _ = await player.stop(context: f.playback)
        let cancelledPermission = BPermissions(sequenced: false)
        let cancelledPlayer = NativePlayer(assets: BHeldPermissionProvider(permissions: cancelledPermission), clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true, maximumStartGain: 0.001)
        try await cancelledPlayer.prepare(a, context: f.playback).outcome.get()
        let cancelled = Task { await cancelledPlayer.seek(to: 2, context: f.playback) }
        await cancelledPermission.first.entered(); cancelled.cancel(); await cancelledPermission.first.open()
        failure(await cancelled.value.outcome, .staleContext)
        equal(await cancelledPlayer.nativeSeekCount(), 0); near(await cancelledPlayer.nativePosition(), 0)
        notNil(await cancelledPlayer.mediaInfo())
        equal(await cancelledPlayer.mediaInfo()?.userSeekable, true)
        try await cancelledPlayer.seek(to: 1, context: f.playback).outcome.get()
        _ = await cancelledPlayer.stop(context: f.playback)
    }
    func testRealLoaderFailuresRemainTypedAfterSuccessfulPreflight() async throws {
        for kind in ["revoke", "expiry", "clock", "corrupt", "owner"] {
            let f = try BFixture(); let vault = try f.vault(); let clock = BMutableWall(time: f.time)
            let store = try await f.store(vault, wall: clock); let variant = try await f.variant()
            let probe = BProbe(held: variant.id)
            let provider = LocalFirstOwnedAssets(store: store, fallback: BFallbackTrap(), observation: { stage,id,context in await probe.observe(stage,id,context) })
            let player = NativePlayer(assets: provider, clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true, maximumStartGain: 0.001)
            defer { Task { _ = await player.stop(context: f.playback); try? await vault.destroyIsolatedTestKeychain(); try? FileManager.default.removeItem(at: f.root) } }
            try await f.retain(store, variant)
            let expected: DomainError = kind == "owner" ? .unauthorized : kind == "corrupt" ? .malformedResponse : .expiredMedia
            let seen = Mutex<[DomainError]>([]); let failed = expectation(description: "typed loader " + kind)
            let events = await player.observations()
            let monitor = Task {
                for await event in events {
                    if event.context == f.playback, case .failed(let error) = event.event {
                        seen.withLock { $0.append(error) }; if error == expected { failed.fulfill() }
                    }
                }
            }
            defer { monitor.cancel() }
            let start = ContinuousClock.now
            let preparation = Task { await player.prepare(variant, context: f.playback) }
            await probe.requestGate.entered()
            equal(await probe.count(.preflightSucceeded, variant.id), 1)
            if kind == "revoke" { try await store.updateGrant(variant: variant.id.rawValue, grant: f.grant([]), context: f.context) }
            if kind == "expiry" {
                let g = f.grant()
                let expired = RetentionGrant(issuer: g.issuer, sourceEncryption: g.sourceEncryption, expires: f.time.addingTimeInterval(-1), renewalReference: g.renewalReference, rights: g.rights, validatedAt: g.validatedAt)
                try await store.updateGrant(variant: variant.id.rawValue, grant: expired, context: f.context)
            }
            if kind == "clock" { clock.jump(10) }
            if kind == "corrupt" {
                let chunk = FileManager.default.enumerator(at: f.root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.first { $0.lastPathComponent == "chunk-0" }!
                var bytes = try Data(contentsOf: chunk); bytes[60] ^= 1; try bytes.write(to: chunk)
            }
            if kind == "owner" { await store.bind(RequestContext(account: nil, accountGeneration: 2, requestGeneration: 0)) }
            await probe.requestGate.open()
            await fulfillment(of: [failed], timeout: 3)
            failure(await preparation.value.outcome, expected)
            XCTAssertLessThan(start.duration(to: .now), .seconds(3), "Typed failure must not wait for generic AV timeout")
            equal(seen.withLock { $0 }, [expected])
            if ["clock", "corrupt"].contains(kind) { positive(await probe.count(.requestFailed, variant.id)) }
            // Explicit grant/owner transitions now retract before a loader-time
            // read can occur; typed event/acknowledgement assertions above still apply.
            print("STAGE_B native loader-time failure kind=\(kind) error=\(expected) elapsed=\(start.duration(to: .now))")
            _ = await player.stop(context: f.playback)
            withExtendedLifetime(provider) {}
            try await vault.destroyIsolatedTestKeychain(); try FileManager.default.removeItem(at: f.root)
        }
    }
    func testLateActualLoaderFailureCannotPoisonNewPreparation() async throws {
        try await lateFailureControl(reuseContext: false)
        try await lateFailureControl(reuseContext: true)
    }
    private func lateFailureControl(reuseContext: Bool) async throws {
        let f = try BFixture(); let vault = try f.vault(); let store = try await f.store(vault)
        let a = try await f.variant(); let b = try await f.variant(1)
        let probe = BProbe(held: a.id, holdFailure: true)
        let provider = LocalFirstOwnedAssets(store: store, fallback: BFallbackTrap(), observation: { stage,id,context in await probe.observe(stage,id,context) })
        let player = NativePlayer(assets: provider, clock: SystemMonotonicClock(), initialGain: 0.001, initiallyMuted: true, maximumStartGain: 0.001)
        let newer = reuseContext ? f.playback : PlaybackContext(request: f.context, generation: 2, occurrenceID: UUID(), route: nil)
        defer { Task { _ = await player.stop(context: newer); try? await vault.destroyIsolatedTestKeychain(); try? FileManager.default.removeItem(at: f.root) } }
        try await f.retain(store, a); try await f.retain(store, b)
        let failures = Mutex<[ScopedEngineEvent]>([]); let events = await player.observations()
        let monitor = Task { for await event in events { if case .failed = event.event { failures.withLock { $0.append(event) } } } }
        defer { monitor.cancel() }
        let old = Task { await player.prepare(a, context: f.playback) }
        await probe.requestGate.entered()
        try await store.updateGrant(variant: a.id.rawValue, grant: f.grant([]), context: f.context)
        // Revocation is now delivered immediately, while the old request is
        // still held before I/O. Preserve the old response and then replace it.
        failure(await old.value.outcome, .expiredMedia)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while failures.withLock({ $0.isEmpty }), ContinuousClock.now < deadline { await Task.yield() }
        equal(failures.withLock { $0.count }, 1)
        try await player.prepare(b, context: newer).outcome.get()
        await probe.requestGate.open(); await probe.failureGate.open()
        try await Task.sleep(for: .milliseconds(20))
        equal(await probe.count(.preflightSucceeded, b.id), 1)
        // Cancelled old work never reaches another source read/error callback.
        equal(await probe.count(.requestFailed, a.id), 0)
        try await player.seek(to: 1, context: newer).outcome.get()
        notNil(await player.mediaInfo())
        equal(failures.withLock { $0.count }, 1)
        _ = await player.stop(context: newer)
        withExtendedLifetime(provider) {}
        try await vault.destroyIsolatedTestKeychain(); try FileManager.default.removeItem(at: f.root)
    }
}
