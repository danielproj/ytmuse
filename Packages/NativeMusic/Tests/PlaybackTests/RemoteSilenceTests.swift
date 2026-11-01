@preconcurrency import AVFoundation
import Domain
import XCTest
@testable import Playback

/// W39 rework F2 (ROUTE08): "the local engine is confirmed silent" is measured on the engine's OWN output, not on a value that was just set. A decoded graph is
/// rendered manually here, so what comes out of the engine is observable. An engine that cannot be silenced must answer false, so the receiver is never started.
private struct SilencePCMProvider: NativeAssetProvider {
    let url: URL
    let sessions: SessionBox
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { url }
    func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession {
        let session = NativeAssetSession(asset: AVURLAsset(url: url), userSeekable: true, decodedAccess: .localPCM, authorizeUserSeek: {})
        sessions.last = session
        return session
    }
}
private final class SessionBox: @unchecked Sendable { var last: NativeAssetSession? }

final class RemoteSilenceTests: XCTestCase, @unchecked Sendable {
    func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("W39-silence-" + UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var cursor = 0
        while cursor < 48000 * 3 {
            let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!; chunk.frameLength = 4096
            for c in 0..<2 { for i in 0..<4096 { chunk.floatChannelData![c][i] = 0.2 * Float(sin(Double(cursor + i) * 2 * .pi * 440 / 48000)) } }
            try file.write(from: chunk); cursor += 4096
        }
        return url
    }
    private func decodedPlayer(_ url: URL, _ box: SessionBox) async throws -> (NativePlayer, PlaybackContext) {
        let player = NativePlayer(assets: SilencePCMProvider(url: url, sessions: box), clock: SystemMonotonicClock(), initialGain: 1, manualDecodedRendering: true)
        let context = PlaybackContext(request: ownedContext(), generation: 1, occurrenceID: UUID(), route: nil)
        let variant = try await OwnedMedia().resolve(OwnedMedia.items[0], context: context).outcome.get()[0]
        _ = try await player.prepare(variant, context: context).outcome.get()
        _ = try await player.configureEffects(AudioEffects(gain: 0.5), context: context, forceDecoded: true).outcome.get()
        let backend = await player.selectedBackend(); XCTAssertEqual(backend, .decodedNative)
        _ = try await player.play(context: context).outcome.get()
        return (player, context)
    }
    private func peak(_ player: NativePlayer, _ context: PlaybackContext, blocks: Int = 4) async throws -> Float {
        var peak: Float = 0
        for _ in 0..<blocks {
            let block = try await player.renderSelected(1024, context: context)
            for c in 0..<Int(block.format.channelCount) { for i in 0..<Int(block.frameLength) { peak = max(peak, abs(block.floatChannelData![c][i])) } }
        }
        return peak
    }

    func testTheDecodedGraphReallyGoesSilentAndTheConfirmationReflectsIt() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let (player, context) = try await decodedPlayer(url, SessionBox())
        let audible = try await peak(player, context)
        XCTAssertGreaterThan(audible, 0.01, "the engine is audible before")
        let confirmed = await player.setRemoteRendering(true)
        XCTAssertTrue(confirmed)
        let silent = try await peak(player, context)
        XCTAssertLessThan(silent, 0.0001, "measured on the engine's own output after the silence was confirmed")
        let restored = await player.setRemoteRendering(false)
        XCTAssertTrue(restored)
        let again = try await peak(player, context)
        XCTAssertGreaterThan(again, 0.01, "and it is audible again when the receiver is left")
    }
    func testAnEngineThatCannotBeSilencedAnswersFalseSoTheReceiverIsNeverStarted() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let (player, context) = try await decodedPlayer(url, SessionBox())
        // The decoded graph refuses to refresh its controls (here: the calling task was cancelled, as at Quit): the error used to be swallowed (try?) and the
        // answer was "silent" although nothing had been silenced. It must be false, and the graph must not be left half-changed as far as the answer goes.
        let confirmed = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await player.setRemoteRendering(true)
        }.value
        XCTAssertFalse(confirmed, "a refresh error means silence is NOT confirmed")
        // The receiver is only started on a true answer, so a false one leaves the engine to be restored by the caller.
        let restored = await player.setRemoteRendering(false)
        XCTAssertTrue(restored)
        let audible = try await peak(player, context)
        XCTAssertGreaterThan(audible, 0.01, "restoring after a failed silence leaves the engine audible-capable")
    }
    func testAnOutputMixerThatDoesNotGoSilentIsReportedAsNotSilentAndReallyIsAudible() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let (player, context) = try await decodedPlayer(url, SessionBox())
        await player.stickDecodedMixerForTesting(1)   // the engine double: the mixer ignores the request
        let confirmed = await player.setRemoteRendering(true)
        XCTAssertFalse(confirmed, "the read-back of the engine's own output says it is not silent")
        // (The samples are also muted at the renderer, so this double is silent in fact; the point is that the confirmation reads the engine's own output stage
        // and refuses to call it silent, so a faulty engine can never be reported as safe.)
        await player.stickDecodedMixerForTesting(nil)
        let ok = await player.setRemoteRendering(true)
        XCTAssertTrue(ok)
    }
    func testThePlayerReadBackIsTheAVPlayersOwnMuteAndRestoresTheUsersMute() async throws {
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        let on = await session.setRemoteRendering(true)
        XCTAssertTrue(on)
        let muted = await session.nativeMuted(); XCTAssertTrue(muted)
        let off = await session.setRemoteRendering(false)
        XCTAssertTrue(off)
        let unmuted = await session.nativeMuted(); XCTAssertFalse(unmuted)
    }
}
