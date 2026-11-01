@preconcurrency import AVFoundation
import Domain
import Synchronization
import XCTest
@testable import Playback

private final class DSPSourceLedger: Sendable {
    struct State { var sessions: [NativeAssetSession] = []; var disposals: [UUID: Int] = [:] }
    let state = Mutex(State())
    func append(_ session: NativeAssetSession) { state.withLock { $0.sessions.append(session) } }
    func closed(_ id: UUID) { state.withLock { $0.disposals[id, default: 0] += 1 } }
    func session(_ index: Int) -> NativeAssetSession { state.withLock { $0.sessions[index] } }
    func count(_ id: UUID) -> Int { state.withLock { $0.disposals[id, default: 0] } }
}
private struct DSPRecordingProvider: NativeAssetProvider {
    let base: SequenceAssets
    let ledger: DSPSourceLedger
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL { try await base.asset(for: variant, context: context) }
    func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession {
        // Cleanup receipt uses its own identifier because the session owns its UUID.
        let receipt = Mutex<UUID?>(nil)
        let ledger = self.ledger
        let session = NativeAssetSession(asset: AVURLAsset(url: try await asset(for: variant, context: context)), userSeekable: true, decodedAccess: .localPCM, authorizeUserSeek: {}, dispose: {
            if let id = receipt.withLock({ $0 }) { ledger.closed(id) }
        })
        receipt.withLock { $0 = session.id }; ledger.append(session)
        return session
    }
}

final class DSPReworkTests: XCTestCase, @unchecked Sendable {
    // Fixed before the first rework measurements: steady-state EQ +/-0.35 dB,
    // bypass 2e-6, peak <=1.00001; first 0.1 seconds excluded only for RMS.
    // Response constants are independent RBJ octave-band transfer evaluations at
    // 1kHz/48kHz (not production headroom constants or measured expectations).
    private let responseTolerance = 0.35
    private func wave(level: Float, hz: Double = 1000, seconds: Int = 2, samples: ((Int) -> Float)? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("W16-DSP-rework-\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for offset in stride(from: 0, to: seconds * 48000, by: 4096) {
            let count = min(4096, seconds * 48000 - offset)
            let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!; block.frameLength = UInt32(count)
            for c in 0..<2 { for i in 0..<count { block.floatChannelData![c][i] = samples?(offset + i) ?? (level * Float(sin(Double(offset + i) * 2 * .pi * hz / 48000))) } }
            try file.write(from: block)
        }
        file.close(); return url
    }
    private func measure(_ effects: AudioEffects, level: Float = 0.005, appGain: Double = 1, samples: ((Int) -> Float)? = nil) async throws -> (db: Double, peak: Float, leftRMS: Double, rightRMS: Double, lateRMS: Double) {
        let url = try wave(level: level, samples: samples); defer { try? FileManager.default.removeItem(at: url) }
        let base = SequenceAssets(files: [url, url], kinds: [.music, .music])
        let player = NativePlayer(assets: base, clock: SystemMonotonicClock(), initialGain: appGain, manualDecodedRendering: true)
        let context = PlaybackContext(request: ownedContext(), generation: 1, occurrenceID: UUID(), route: nil)
        let variant = try await base.resolve(OwnedMedia.items[0], context: context).outcome.get()[0]
        _ = try await player.prepare(variant, context: context).outcome.get()
        _ = try await player.configureEffects(effects, context: context, forceDecoded: true).outcome.get()
        let backend = await player.selectedBackend(); XCTAssertEqual(backend, .decodedNative)
        _ = try await player.play(context: context).outcome.get()
        var lateSum = 0.0; var lateCount = 0
        var sum = [Double(0), 0]; var count = 0; var steady = 0; var peak: Float = 0; var bypassError: Float = 0
        while count < 96000 {
            let block = try await player.renderSelected(UInt32(min(1024, 96000 - count)), context: context)
            guard block.frameLength > 0 else { XCTFail("early EOF"); break }
            for i in 0..<Int(block.frameLength) {
                for c in 0..<2 {
                    let v = block.floatChannelData![c][i]; XCTAssertTrue(v.isFinite); peak = max(peak, abs(v))
                    if count + i >= 4800 { sum[c] += Double(v) * Double(v) }
                    if c == 1 && count + i >= 72000 { lateSum += Double(v) * Double(v); lateCount += 1 }
                    if effects.bypass && appGain == 1 && samples == nil {
                        let expected = level * Float(sin(Double(count + i) * 2 * .pi * 1000 / 48000))
                        bypassError = max(bypassError, abs(v - expected))
                    }
                }
                if count + i >= 4800 { steady += 1 }
            }
            count += Int(block.frameLength)
        }
        XCTAssertEqual(count, 96000); XCTAssertLessThanOrEqual(peak, 1.00001)
        if effects.bypass { XCTAssertLessThanOrEqual(bypassError, 0.000002) }
        _ = await player.stop(context: context)
        let left = sqrt(sum[0] / Double(steady)); let right = sqrt(sum[1] / Double(steady))
        return (20 * log10(right / (Double(level) / sqrt(2))), peak, left, right, sqrt(lateSum / Double(lateCount)))
    }
    func testPositiveEQResponsesOnSelectedTransport() async throws {
        let cases: [(String, [Float], Double)] = [
            ("flat", Array(repeating: 0, count: 10), 0),
            ("center+6", [0,0,0,0,0,6,0,0,0,0], 6),
            ("center-6", [0,0,0,0,0,-6,0,0,0,0], -6),
            ("all+6", Array(repeating: 6, count: 10), 8.891733313975452),
            ("all+12", Array(repeating: 12, count: 10), 18.54624137123685),
            ("bass-preset", [6,5,4,2,0,0,0,0,0,0], 0.11534170643565471)
        ]
        for (name, bands, expected) in cases {
            let result = try await measure(AudioEffects(bands: bands))
            XCTAssertEqual(result.db, expected, accuracy: responseTolerance, name)
            print("W16-R1 F1 selected \(name) expectedDB=\(expected) actualDB=\(result.db) peak=\(result.peak)")
        }
        let interactions = try await measure(AudioEffects(bands: [0,0,0,0,0,6,0,0,0,0], normalizationDB: 3, balance: 1, gain: 0.5), appGain: 0.5)
        XCTAssertEqual(interactions.db, 6 + 3 + 20 * log10(0.25), accuracy: responseTolerance)
        XCTAssertEqual(interactions.leftRMS, 0)
        print("W16-R1 F1 boost+normalization+balance+independent-gain dB=\(interactions.db) leftRMS=\(interactions.leftRMS)")
    }
    func testBoostLimiterPeaksAndAutomaticNormalization() async throws {
        for bands: [Float] in [[0,0,0,0,0,12,0,0,0,0], Array(repeating: 12, count: 10)] {
            let result = try await measure(AudioEffects(bands: bands), level: 0.9)
            XCTAssertGreaterThan(result.rightRMS, 0.1) // usable signal, no blanket attenuation
            print("W16-R1 F1 high-level boosted output peak=\(result.peak) RMS=\(result.rightRMS)")
        }
        // Analysis target applies before EQ. A +6dB centre boost should remain +6dB
        // relative to -18dBFS RMS, and equal-level matching remains independent.
        for level: Float in [0.02, 0.2] {
            let result = try await measure(AudioEffects(bands: [0,0,0,0,0,6,0,0,0,0], normalize: true), level: level)
            XCTAssertEqual(20 * log10(result.rightRMS), -12, accuracy: responseTolerance)
            print("W16-R1 F1 normalized+boost input=\(level) outputRMSdBFS=\(20 * log10(result.rightRMS)) peak=\(result.peak)")
        }
    }
    func testStreamingPeakProtectionTransientAndQuietRecovery() async throws {
        let effects = try AudioEffects(bands: Array(repeating: 12, count: 10))
        let square = try await measure(effects, level: 0.9, samples: { i in
            sin(Double(i) * 2 * .pi * 1000 / 48000) >= 0 ? 0.9 : -0.9
        })
        XCTAssertGreaterThan(square.rightRMS, 0.1)
        let changing = try await measure(effects, samples: { i in
            let level: Float = i < 48000 ? 0.9 : 0.005
            return level * Float(sin(Double(i) * 2 * .pi * 1000 / 48000))
        })
        let recoveredDB = 20 * log10(changing.lateRMS / (0.005 / sqrt(2)))
        XCTAssertEqual(recoveredDB, 18.54624137123685, accuracy: responseTolerance)
        print("W16-R1 F1 square transient peak=\(square.peak) RMS=\(square.rightRMS); loud-to-quiet recoveryDB=\(recoveredDB) peak=\(changing.peak)")
    }
    private func fadeSession() async throws -> (PlaybackSession, DSPSourceLedger, [URL]) {
        let a = try wave(level: 0.2, hz: 317, seconds: 10); let b = try wave(level: 0.15, hz: 701, seconds: 10)
        let base = SequenceAssets(files: [a,b], kinds: [.music,.music]); let ledger = DSPSourceLedger()
        let session = try await PlaybackSession.open(context: ownedContext(), persistence: MemoryPersistence(), assets: DSPRecordingProvider(base: base, ledger: ledger), resolver: base, capabilities: base, automaticTick: false, initialGain: 1, manualDecodedRendering: true, effects: AudioEffects(crossfade: 4))
        try await session.startOwnedMedia(OwnedMedia.items)
        var count = 0
        while count < 300000 {
            let block = try await session.renderSelected(UInt32(min(1024, 300000 - count)))
            guard block.frameLength > 0 else { throw DomainError.malformedResponse }; count += Int(block.frameLength)
        }
        let snapshot = try await session.queueSnapshotForMeasurement(); XCTAssertEqual(snapshot.current?.media, OwnedMedia.items[1])
        XCTAssertFalse(ledger.session(0).isClosed); XCTAssertFalse(ledger.session(1).isClosed)
        return (session, ledger, [a,b])
    }
    private func peak(_ block: AVAudioPCMBuffer) -> Float { (0..<Int(block.frameLength)).map { abs(block.floatChannelData![1][$0]) }.max() ?? 0 }
    func testDiscardedOutgoingFadeIsDisposedForGainMuteSeekAndReprepare() async throws {
        for control in ["gain", "mute", "seek", "effects"] {
            let (session, ledger, files) = try await fadeSession(); defer { for file in files { try? FileManager.default.removeItem(at: file) } }
            let old = ledger.session(0); let current = ledger.session(1)
            switch control {
            case "gain": try await session.setGain(0.9)
            case "mute": try await session.setMuted(true)
            case "seek": try await session.seek(2)
            default: try await session.configureEffects(AudioEffects(balance: 0.25, crossfade: 4))
            }
            XCTAssertTrue(old.isClosed, control); XCTAssertEqual(ledger.count(old.id), 1, control)
            XCTAssertFalse(current.isClosed, control); XCTAssertEqual(ledger.count(current.id), 0, control)
            old.fail(.expiredMedia); old.dispose() // ordinary disposed-provider callbacks are inert
            let output = try await session.renderSelected(1024)
            if control == "mute" {
                XCTAssertEqual(peak(output), 0); try await session.setMuted(false)
                let audible = try await session.renderSelected(1024); XCTAssertGreaterThan(peak(audible), 0.01)
            } else { XCTAssertGreaterThan(peak(output), 0.01, control) }
            // Current authorization still retracts output; cleanup did not remove it.
            current.fail(.expiredMedia)
            do { _ = try await session.renderSelected(1024); XCTFail("current failure ignored") } catch { XCTAssertEqual(error as? DomainError, .expiredMedia) }
            await session.close(); await session.close()
            XCTAssertEqual(ledger.count(old.id), 1); XCTAssertEqual(ledger.count(current.id), 1)
            print("W16-R1 F4 \(control): discarded previous disposed once, old failure inert, current permission enforced")
        }
    }
    func testTailRetiresNaturallyAndStillNeededTailRetracts() async throws {
        for retireNaturally in [false, true] {
            let (session, ledger, files) = try await fadeSession(); defer { for file in files { try? FileManager.default.removeItem(at: file) } }
            let old = ledger.session(0); let current = ledger.session(1)
            if retireNaturally {
                // Finish outgoing audio (10s); native retirement includes its queued tail.
                for _ in 0..<210 { _ = try await session.renderSelected(1024) }
                XCTAssertTrue(old.isClosed); old.fail(.expiredMedia)
                let output = try await session.renderSelected(1024); XCTAssertGreaterThan(peak(output), 0.01)
                XCTAssertFalse(current.isClosed)
            } else {
                let output = try await session.renderSelected(1024); XCTAssertGreaterThan(peak(output), 0.01)
                XCTAssertFalse(old.isClosed); old.fail(.expiredMedia)
                do { _ = try await session.renderSelected(1024); XCTFail("still-needed tail permission ignored") } catch { XCTAssertEqual(error as? DomainError, .expiredMedia) }
            }
            await session.close(); XCTAssertEqual(ledger.count(old.id), 1); XCTAssertEqual(ledger.count(current.id), 1)
            print("W16-R1 F4 tail natural-retirement=\(retireNaturally) required-until-discarded permission and cleanup preserved")
        }
    }
    func testFadeStopAndReplacementDisposeBothInputsOnce() async throws {
        for replace in [false, true] {
            let (session, ledger, files) = try await fadeSession(); defer { for file in files { try? FileManager.default.removeItem(at: file) } }
            let old = ledger.session(0); let current = ledger.session(1)
            if replace {
                try await session.startOwnedMedia(OwnedMedia.items)
                XCTAssertTrue(old.isClosed); XCTAssertTrue(current.isClosed)
                old.fail(.expiredMedia); current.fail(.expiredMedia)
                let output = try await session.renderSelected(1024); XCTAssertGreaterThan(peak(output), 0.01)
            }
            await session.close(); await session.close()
            XCTAssertTrue(old.isClosed); XCTAssertTrue(current.isClosed)
            XCTAssertEqual(ledger.count(old.id), 1); XCTAssertEqual(ledger.count(current.id), 1)
            print("W16-R1 F4 replacement=\(replace) discarded fade sessions each disposed once")
        }
    }
}
