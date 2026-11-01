import XCTest
import Foundation
@preconcurrency import AVFoundation
import Domain
import Queue
import AccountSession
@testable import Downloads
@testable import Playback

actor KeptQueuePersistence: QueuePersistence {
    var state: QueueSnapshot?
    func load(context: RequestContext) -> QueueSnapshot? { state }
    func save(_ snapshot: QueueSnapshot, context: RequestContext) { state = snapshot }
}
actor PlayRecorder { var played: [PlayableDownload] = []; func add(_ p: PlayableDownload) { played.append(p) } }

/// F4: a kept item plays through the native AVFoundation session from the W14 encrypted store, offline. Headless: the session renders
/// its decoded output into a buffer (`manualDecodedRendering`), at the 0.001 gain cap, so nothing is audible.
final class PlayableDownloadsTests: XCTestCase, @unchecked Sendable {
    private func sineWave(_ env: Env, name: String, seconds: Int = 3, hz: Double = 440) throws -> URL {
        let url = env.root.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        for offset in stride(from: 0, to: seconds * 48000, by: 4096) {
            let count = min(4096, seconds * 48000 - offset)
            let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!; block.frameLength = UInt32(count)
            for c in 0..<2 { for i in 0..<count { block.floatChannelData![c][i] = 0.5 * Float(sin(Double(offset + i) * 2 * .pi * hz / 48000)) } }
            try file.write(from: block)
        }
        return url
    }
    private func peak(_ block: AVAudioPCMBuffer) -> Float { (0..<Int(block.frameLength)).map { max(abs(block.floatChannelData![0][$0]), abs(block.floatChannelData![1][$0])) }.max() ?? 0 }

    private struct Rig { let scheduler: DownloadScheduler; let store: EncryptedStore; let vault: KeychainVault; let media: ServiceID; let playable: PlayableDownload }
    private func keep(_ env: Env, _ file: URL) async throws -> Rig {
        let kit = try env.realStore()
        let scheduler = try DownloadScheduler(ledgerRoot: env.ledgerURL, sink: kit.sink, sources: [.localFile: LocalFileDownloadSource(issuer: "File chosen on this Mac")], wall: SystemWallClock(), volume: env.volume,
                                              configuration: .init(chunkBytes: 64 * 1024, persistEveryChunks: 4, minimumBudget: 1024), wake: WakeRecorder().scheduler)
        await scheduler.bind(env.context)
        let added = await scheduler.addLocalFile(file); XCTAssertEqual(added, .done)
        await scheduler.settleBounded()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.phase, .available)
        let found = await scheduler.playable(row.media); let playable = try XCTUnwrap(found)
        return Rig(scheduler: scheduler, store: kit.store, vault: kit.vault, media: row.media, playable: playable)
    }
    private func session(_ env: Env, _ rig: Rig) async throws -> PlaybackSession {
        let assets = RetainedAssets(store: rig.store, contentType: { _ in rig.playable.contentType })
        let playback = RetainedPlayback { media in await rig.scheduler.playable(media) }
        return try await PlaybackSession.open(context: env.context, persistence: KeptQueuePersistence(), assets: assets, resolver: playback, capabilities: playback, automaticTick: false,
                                              initialGain: 0.001, initiallyMuted: false, maximumStartGain: 0.001, manualDecodedRendering: true)
    }

    func testAKeptFilePlaysThroughTheNativeSessionFromTheEncryptedStoreWithNoNetwork() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let file = try sineWave(env, name: "Kept Tone.wav")
        let rig = try await keep(env, file); defer { Task { try? await rig.vault.destroyIsolatedTestKeychain() } }
        // The cleartext source is gone: only the encrypted object can be the thing that plays.
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(rig.playable.contentType, "com.microsoft.waveform-audio")
        let player = try await session(env, rig)
        try await player.startOwnedMedia([rig.media])
        var loudest: Float = 0
        for _ in 0..<8 { let block = try await player.renderSelected(1024); loudest = max(loudest, peak(block)) }
        XCTAssertGreaterThan(loudest, 1e-5, "the decoder produced the tone")
        XCTAssertLessThanOrEqual(loudest, 0.001 * 0.5 + 1e-4, "at the 0.001 gain cap: nothing audible")
        let snapshot = try await player.snapshot()
        XCTAssertEqual(snapshot.queue.current?.media, rig.media)
        XCTAssertTrue(snapshot.media?.userSeekable ?? false, "the retained grant carries the seek right")
        XCTAssertEqual(snapshot.media?.duration ?? 0, 3, accuracy: 0.2)
        try await player.seek(1.5)
        let after = try await player.renderSelected(1024); XCTAssertGreaterThan(peak(after), 1e-5, "playback continues after a seek")
        await player.close()
    }
    func testAnItemThatIsNotDownloadedCannotBePlayedAndSignOutRetractsPlayback() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let rig = try await keep(env, try sineWave(env, name: "Gone.wav")); defer { Task { try? await rig.vault.destroyIsolatedTestKeychain() } }
        let missing = try ServiceID("local-file:" + UUID().uuidString)
        let nothing = await rig.scheduler.playable(missing); XCTAssertNil(nothing)
        let playback = RetainedPlayback { media in await rig.scheduler.playable(media) }
        let ctx = PlaybackContext(request: env.context, generation: 1, occurrenceID: nil, route: nil)
        let unresolved = await playback.resolve(missing, context: ctx)
        XCTAssertThrowsError(try unresolved.outcome.get())
        let resolved = try await playback.resolve(rig.media, context: ctx).outcome.get()
        XCTAssertEqual(resolved.first?.authorization.rawValue, RetainedMediaAdmission.authorization)
        // After the account's keys are erased the same item no longer reads: it is never "playable" from a stale record.
        try await rig.store.invalidate(context: env.context, deleteFiles: false)
        let assets = RetainedAssets(store: rig.store, contentType: { _ in rig.playable.contentType })
        let variant = try XCTUnwrap(resolved.first)
        do { _ = try await assets.assetSession(for: variant, context: PlaybackContext(request: env.context, generation: 1, occurrenceID: nil, route: nil)); XCTFail("an erased account's copy was opened") } catch {}
    }
    func testTheRetainedProviderRefusesAVariantWithoutTheRetainedAuthorization() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let rig = try await keep(env, try sineWave(env, name: "A.wav")); defer { Task { try? await rig.vault.destroyIsolatedTestKeychain() } }
        let assets = RetainedAssets(store: rig.store, contentType: { _ in rig.playable.contentType })
        let id = try ServiceID(rig.playable.variant)
        let foreign = try MediaVariant(id: id, codec: "c", container: "c", bitrate: nil, sampleRate: nil, expiresAt: nil, seekable: true, authorization: ID("owned-bundle-only"))
        do { _ = try await assets.assetSession(for: foreign, context: PlaybackContext(request: env.context, generation: 1, occurrenceID: nil, route: nil)); XCTFail("a variant without the retained authorization opened") } catch {}
    }
    func testTheNativePlayerAdmitsOnlyTheRetainedSchemeWithItsAuthorization() throws {
        let env = try Env(); defer { env.cleanup() }
        let good = try MediaVariant(id: ServiceID("v"), codec: "c", container: "c", bitrate: nil, sampleRate: nil, expiresAt: nil, seekable: true, authorization: ID(RetainedMediaAdmission.authorization))
        let wrong = try MediaVariant(id: ServiceID("v"), codec: "c", container: "c", bitrate: nil, sampleRate: nil, expiresAt: nil, seekable: true, authorization: ID("something-else"))
        func session(_ scheme: String, _ access: NativeAssetSession.DecodedAccess) -> NativeAssetSession { NativeAssetSession(asset: AVURLAsset(url: URL(string: scheme + "://media/x")!), userSeekable: true, decodedAccess: access, authorizeUserSeek: {}) }
        XCTAssertTrue(RetainedMediaAdmission.admits(session(RetainedMediaAdmission.scheme, .authorizedNative), variant: good))
        XCTAssertFalse(RetainedMediaAdmission.admits(session(RetainedMediaAdmission.scheme, .authorizedNative), variant: wrong), "authorization is required")
        XCTAssertFalse(RetainedMediaAdmission.admits(session(RetainedMediaAdmission.scheme, .unavailable), variant: good), "an unauthorised session is refused")
        XCTAssertFalse(RetainedMediaAdmission.admits(session("https", .authorizedNative), variant: good), "a network URL is never admitted")
    }
    func testPlayIsOfferedOnlyForKeptPlayableItemsAndOnlyWhenSomethingCanPlayThem() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let rig = try await keep(env, try sineWave(env, name: "P.wav")); defer { Task { try? await rig.vault.destroyIsolatedTestKeychain() } }
        var row = try await rig.scheduler.onlyRow()
        XCTAssertFalse(row.actions.contains(.play), "no handler, no Play: nothing is promised that cannot run")
        let refused = await rig.scheduler.perform(.play, job: row.id); XCTAssertEqual(refused, .refused(.unsupported))
        let recorder = PlayRecorder()
        await rig.scheduler.installPlayHandler { await recorder.add($0); return true }
        row = try await rig.scheduler.onlyRow(); XCTAssertEqual(row.actions.first, .play)
        let done = await rig.scheduler.perform(.play, job: row.id); XCTAssertEqual(done, .done)
        let played = await recorder.played; XCTAssertEqual(played.first?.media, rig.media); XCTAssertEqual(played.first?.title, "P")
        XCTAssertEqual(played.first?.variant, rig.playable.variant)
    }
}
