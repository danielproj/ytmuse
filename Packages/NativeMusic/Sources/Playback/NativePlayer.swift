@preconcurrency import AVFoundation
import Domain
import Queue
import Foundation
import OutputRoutes

/// Authorization-bearing URLs stay inside the engine/provider seam, never UI or persistence.
public protocol NativeAssetFailure: Error, Sendable { var playbackError: DomainError { get } }
/// The deliberate admission for kept (downloaded) media played from the W14 encrypted store. A URL alone grants nothing: the
/// session must come from the retained-store provider (an authorized-native session on this scheme) and the variant must carry
/// the retained-download authorization. The store itself still checks account, key, rights and expiry on every read.
public enum RetainedMediaAdmission {
    public static let scheme = "retained-encrypted"
    public static let authorization = "retained-download"
    public static func admits(_ session: NativeAssetSession, variant: MediaVariant) -> Bool {
        session.asset.url.scheme == scheme && variant.authorization.rawValue == authorization && session.decodedAccess == .authorizedNative
    }
}
public protocol NativeAssetProvider: Sendable {
    func asset(for variant: MediaVariant, context: PlaybackContext) async throws -> URL
    func nativeAsset(for variant: MediaVariant, context: PlaybackContext) async throws -> AVURLAsset
    func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession
}
public extension NativeAssetProvider {
    func assetSession(for variant: MediaVariant, context: PlaybackContext) async throws -> NativeAssetSession {
        NativeAssetSession(asset: try await nativeAsset(for: variant, context: context), userSeekable: variant.seekable, authorizeUserSeek: {
            guard variant.seekable else { throw DomainError.unsupported }
        })
    }
    func nativeAsset(for variant: MediaVariant, context: PlaybackContext) async throws -> AVURLAsset {
        let url = try await asset(for: variant, context: context)
        guard url.isFileURL else { throw DomainError.forbidden }
        return AVURLAsset(url: url)
    }
}
public struct NativeMediaInfo: Sendable {
    public let userSeekable: Bool
    public let duration: Double
    public let codec: String?
    public let sampleRate: Double?
    public let bitrate: Int?
    public let route: String
}

/// Single transport owner. AVPlayer is primary; an authorized decoded native graph
/// replaces its active output for supported effects. Recovery/timers never add an owner.
public actor NativePlayer: PlaybackEngine {
    private let player = AVPlayer()
    private var decoded: IncrementalDecodedPlayer?
    private var decodedPump: Task<Void, Never>?
    private var normalizationCache: (session: UUID, gain: Float)?
    private var analysis: Task<Float, Error>?
    private var backendRevision: UInt64 = 0
    private var effects = try! AudioEffects()
    private let manualDecodedRendering: Bool
    public enum Backend: Sendable { case avPlayer, decodedNative }
    public func selectedBackend() -> Backend { decoded == nil ? .avPlayer : .decodedNative }

    // MARK: Output route (W22, ROUTE01, ROUTE04). Per-player and per-engine only: nothing here changes the Mac's default output, volume,
    // AirPlay or Bluetooth state. The applier is injected; a process that injects none (every unit test) moves nothing.
    private var outputApplier: any LocalOutputApplying = NoOutputApplier()
    private var outputUID: String?
    private var externalPlayback: NSKeyValueObservation?
    public func configureOutput(applier: any LocalOutputApplying) { outputApplier = applier; _ = setOutput(uid: outputUID) }
    /// Points the player (and the decoded graph, if it is the active backend) at an output device by stable UID; nil follows the system default.
    @discardableResult public func setOutput(uid: String?) -> Bool {
        outputUID = uid
        var applied = outputApplier.apply(uid: uid, to: player)
        if let decoded { applied = outputApplier.apply(uid: uid, to: decoded.engine) && applied }
        return applied
    }
    /// W39 (ROUTE08): silences (or restores) every output stage for a Cast receiver that renders instead. True ONLY when the engine's own state, read back after the
    /// change, is silent: the `AVPlayer` reads muted, and for the decoded graph the refresh succeeded (its error is NOT swallowed) and the engine's output mixer
    /// reads zero. When it cannot be confirmed the caller must not start the receiver.
    @discardableResult public func setRemoteRendering(_ on: Bool) -> Bool {
        remoteRendering = on
        player.isMuted = effectiveMuted
        guard let decoded else { return outputStagesAgree(on) }
        decoded.remoteSilenced = on; decoded.muted = effectiveMuted
        do { try refreshDecodedControls(decoded) } catch { return false }
        return outputStagesAgree(on)
    }
    /// The state the outputs actually report, compared with what was asked.
    private func outputStagesAgree(_ silent: Bool) -> Bool {
        let playerAgrees = player.isMuted == effectiveMuted && (!silent || player.isMuted)
        guard let decoded else { return playerAgrees }
        return playerAgrees && decoded.outputIsSilent == silent
    }
    public func isRemoteRendering() -> Bool { remoteRendering }
    #if DEBUG
    /// Test double (Debug only): the decoded graph's output mixer stays at `volume` whatever is asked, as a faulty engine would.
    func stickDecodedMixerForTesting(_ volume: Float?) { decoded?.stuckMixerVolumeForTesting = volume }
    #endif
    public func outputBackend() -> OutputBackend { decoded == nil ? .avPlayer : .decodedGraph }
    /// W22 (ROUTE03): silences the `AVPlayer` at once, from the caller's own turn, without waiting for this actor. A route loss uses it so the
    /// sound stops before the state machine's own pause (one actor hop later) is processed. The decoded graph's engine is stopped by that later pause.
    public nonisolated func silenceNow() { player.pause() }
    /// The `AVPlayer` the system AirPlay picker attaches to (AppKit only; it never plays through this reference).
    public nonisolated var routePickerPlayer: AVPlayer { player }
    /// Tells `handler` when AVFoundation external playback (AirPlay) starts or stops for this player.
    public func observeExternalPlayback(_ handler: @escaping @Sendable (Bool) -> Void) {
        player.allowsExternalPlayback = true
        externalPlayback = player.observe(\.isExternalPlaybackActive, options: [.new]) { _, change in handler(change.newValue ?? false) }
    }
    public func isExternalPlaybackActive() -> Bool { player.isExternalPlaybackActive }
    private func applyOutput(to backend: IncrementalDecodedPlayer) { if outputUID != nil { _ = outputApplier.apply(uid: outputUID, to: backend.engine) } }
    public struct DSPCapabilities: Sendable {
        public let selected: Backend
        public let effects: CapabilityState
        public let gapless: Bool
        public let crossfade: Bool
        init(selected: Backend, effects: CapabilityState, gapless: Bool = false, crossfade: Bool = false) { self.selected = selected; self.effects = effects; self.gapless = gapless; self.crossfade = crossfade }
    }
    public func dspCapabilities(context: PlaybackContext) async -> DSPCapabilities {
        guard self.context == context, let session = assetSession, !session.isClosed else { return .init(selected: selectedBackend(), effects: .unknown) }
        guard session.decodedAccess != .unavailable else { return .init(selected: selectedBackend(), effects: .temporarilyUnavailable(.unsupported)) }
        let revision = operation
        do {
            guard let track = try await session.asset.loadTracks(withMediaType: .audio).first,
                  let desc = try await track.load(.formatDescriptions).first,
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  [kAudioFormatLinearPCM, kAudioFormatMPEG4AAC, kAudioFormatOpus].contains(format.pointee.mFormatID), [44100.0, 48000.0].contains(format.pointee.mSampleRate),
                  format.pointee.mChannelsPerFrame == 2 else { return .init(selected: selectedBackend(), effects: .temporarilyUnavailable(.unsupported)) }
            guard self.context == context, operation == revision, assetSession?.id == session.id, !session.isClosed else { return .init(selected: selectedBackend(), effects: .unknown) }
            return .init(selected: selectedBackend(), effects: .supported, gapless: rate == 1, crossfade: rate == 1 && session.contentKind == .music)
        } catch { return .init(selected: selectedBackend(), effects: .failed(Self.failure(error))) }
    }
    public func decodedResourceState() -> (retainedFrames: Int, peakFrames: Int, ceilingBytes: Int) {
        (decoded?.retainedFrames ?? 0, decoded?.peakRetainedFrames ?? 0, IncrementalDecodedPlayer.maximumPayloadBytes)
    }
    private func closeDecoded() {
        backendRevision += 1; nextScope = nil; nextItem = nil; prefetchWork?.cancel(); prefetchWork = nil; pendingNextSession?.dispose(); pendingNextSession = nil; analysis?.cancel(); analysis = nil
        decodedPump?.cancel(); decodedPump = nil; decoded?.close(); decoded = nil; decodedResumeNeedsReset = false
    }
    /// Device-free entry into the SAME selected production graph, bounded per call.
    func renderSelected(_ frames: UInt32, context: PlaybackContext, throughPump: Bool = false) async throws -> AVAudioPCMBuffer {
        if self.context == context, let error = assetSession?.failure { throw error }
        await retractExpiredNext()
        guard self.context == context, let decoded else { throw DomainError.staleContext }
        guard let session = assetSession else { throw DomainError.staleContext }
        for authorization in decoded.authorizationSessions { try await authorization.authorizeDecodedRead() }
        guard self.context == context, self.decoded === decoded else { throw DomainError.staleContext }
        if throughPump {
            guard manualDecodedRendering else { throw DomainError.unsupported }
            await serviceDecoded(context: context, revision: backendRevision)
        } else { try await processHandoff() }
        let limit = decoded.framesUntilTransition.map { $0 > 0 ? min(Int(frames), $0) : Int(frames) } ?? Int(frames)
        let output = try decoded.render(UInt32(limit))
        if throughPump {
            if let current = self.context { await serviceDecoded(context: current, revision: backendRevision) }
        } else { try await processHandoff() }
        if decoded.markEnded(), let current = self.context { wantedPlay = false; decodedPump?.cancel(); decodedPump = nil; emit(.ended, current) }
        return output
    }
    private func startDecodedPump() {
        guard !manualDecodedRendering, wantedPlay, decoded != nil, decodedPump == nil else { return }
        let revision = backendRevision
        decodedPump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                guard !Task.isCancelled else { return }
                await self?.serviceCurrentDecoded(revision: revision)
            }
        }
    }
    private func retractExpiredNext() async {
        guard let item = nextItem else { return }
        do {
            guard item.variant.expiresAt.map({ wall.now() < $0 }) ?? true else { throw DomainError.expiredMedia }
            try await item.session.authorizeDecodedRead()
        } catch { await cancelPlannedNext() }
    }
    /// Runs the production pump service/error path with a disconnected manual graph.
    func serviceDecodedForMeasurement() async throws {
        guard manualDecodedRendering else { throw DomainError.unsupported }
        await serviceCurrentDecoded(revision: backendRevision)
    }
    private func serviceCurrentDecoded(revision: UInt64) async {
        guard let context, wantedPlay else { return }
        await serviceDecoded(context: context, revision: revision)
    }
    private func serviceDecoded(context: PlaybackContext, revision: UInt64) async {
        await retractExpiredNext()
        guard wantedPlay, self.context == context, backendRevision == revision, let decoded, let session = assetSession else { return }
        do {
            for authorization in decoded.authorizationSessions { try await authorization.authorizeDecodedRead() }
            guard wantedPlay, self.context == context, backendRevision == revision, self.decoded === decoded else { return }
            try await processHandoff()
            try decoded.refill()
            if let current = self.context { emit(.position(decoded.position), current) }
            if decoded.markEnded(), let current = self.context { wantedPlay = false; decodedPump?.cancel(); decodedPump = nil; emit(.ended, current) }
        } catch {
            // An operation that replaced this backend while the handoff awaited
            // admission cannot fail the new live graph with its stale error.
            guard backendRevision == revision, self.decoded === decoded, self.context == context else { return }
            assetFailed(Self.failure(error), sessionID: session.id, revision: operation, context: context)
        }
    }
    let assets: any NativeAssetProvider
    private let wall: any WallClock
    private let preferGapless: Bool
    private var nextScope: (plan: QueueHandoff, context: PlaybackContext)?
    private var nextPreparing = false
    private var prefetchWork: Task<Float, Error>?
    private var pendingNextSession: NativeAssetSession?
    private var nextItem: NativeUpcoming?
    /// Set when a started decoded backend is paused; the next start restarts it at
    /// its exact logical position rather than resuming the player node in place.
    private var decodedResumeNeedsReset = false
    private var handoffHandler: (@Sendable (UUID, PlaybackContext, PlaybackContext, MediaVariant, Double) async throws -> Void)?
    private var backendPreparing: UUID?
    private var adopting = false
    private var hasAdoptedNative = false
    private static func codecName(_ format: AudioStreamBasicDescription) -> String {
        switch format.mFormatID {
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatOpus: return "Opus"
        default: return "PCM \(format.mBitsPerChannel)-bit"
        }
    }
    private let clock: any MonotonicClock
    private var context: PlaybackContext?
    private var controlOwner: RequestContext?
    private let maximumStartGain: Float?
    private var startObservations: [Float] = []
    private var operation: UInt64 = 0
    private var seekRevision: UInt64 = 0
    private var seekRequest: UInt64 = 0
    private var assetSession: NativeAssetSession?
    private var assetFailureTask: Task<Void, Never>?
    private var reportedFailure: UUID?
    private var transport: UInt64 = 0
    private var wantedPlay = false
    private var rate: Float = 1
    private var gain: Float = 0.08
    private var gainRevision: UInt64 = 0
    private var muteRevision: UInt64 = 0
    private var rateRevision: UInt64 = 0
    private var fadeFactor: Float = 1
    private var muted = false
    /// W39 (ROUTE08): a Cast receiver renders this item. The engine keeps running as a silent transport clock for the queue, but nothing it decodes may be
    /// heard on the Mac: this forces every output stage muted, whatever the person's own mute says, and the person's mute is kept underneath.
    private var remoteRendering = false
    private var effectiveMuted: Bool { muted || remoteRendering }
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var info: NativeMediaInfo?
    private let probe: RenderProbe?
    /// W17: whether the prepared item's video tracks decode. Audio-only selection turns this off; it survives item replacement.
    private var videoDecoding = true
    private var videoProbe: NativeVideoProbe?
    private var measuresVideo = false
    private let stream: AsyncStream<ScopedEngineEvent>
    private let output: AsyncStream<ScopedEngineEvent>.Continuation
    public init(assets: any NativeAssetProvider, clock: any MonotonicClock, observeRendering: Bool = false, initialGain: Double = 0.08, initiallyMuted: Bool = false, maximumStartGain: Float? = nil, manualDecodedRendering: Bool = false, preferGapless: Bool = false, initialEffects: AudioEffects = try! AudioEffects(), wall: any WallClock = SystemWallClock()) {
        precondition(initialGain.isFinite && (0...1).contains(initialGain))
        self.wall = wall; self.preferGapless = preferGapless; self.effects = initialEffects
        self.manualDecodedRendering = manualDecodedRendering
        gain = Float(initialGain); muted = initiallyMuted; self.maximumStartGain = maximumStartGain
        probe = observeRendering ? RenderProbe() : nil
        self.assets = assets; self.clock = clock
        let channel = AsyncStream<ScopedEngineEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        stream = channel.stream; output = channel.continuation
    }
    public func validatesObservation(_ event: ScopedEngineEvent) async -> Bool {
        guard event.context == context else { return false }
        return event.renderGeneration.map { $0 == decoded?.renderGeneration } ?? true
    }
    public func renderMeasurement() -> RenderMeasurement? { probe?.measurement.withLock { $0 } }
    public func observations() -> AsyncStream<ScopedEngineEvent> { stream }
    public func mediaInfo() -> NativeMediaInfo? { info }
    /// Supported provider-granted local PCM selects an actual native transport.
    /// Crossfade/next-item composition remain explicitly unavailable until Stage C.
    public func configureEffects(_ requested: AudioEffects, context: PlaybackContext, forceDecoded: Bool = false) async -> PlaybackResult<Void> {
        guard self.context == context, let session = assetSession, !session.isClosed else { return result(context, .staleContext) }
        guard !forceDecoded || session.decodedAccess != .unavailable else { return result(context, .unsupported) }
        guard requested.bypass || session.decodedAccess != .unavailable else { return result(context, .unsupported) }
        let preparation = UUID(); backendPreparing = preparation
        defer { if backendPreparing == preparation { backendPreparing = nil } }
        let position = nativePosition()
        player.pause(); decoded?.pause(); closeDecoded()
        emit(.position(position), context)
        if wantedPlay { emit(.buffering, context) }
        let ticket = backendRevision; let revision = operation; let seekTicket = seekRequest
        do {
            if requested.bypass && !forceDecoded && !preferGapless && !hasAdoptedNative {
                let success = await player.seek(to: CMTime(seconds: position, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
                guard self.context == context, operation == revision, backendRevision == ticket, seekRequest == seekTicket else { return result(context, .staleContext) }
                guard success else { throw DomainError.transientTransport }
                effects = requested
                if wantedPlay {
                    // Tests must never start AVPlayer hardware output. Device-free
                    // mode may select primary paused, but cannot Play that route.
                    if manualDecodedRendering { wantedPlay = false; return result(context) }
                    return await play(context: context)
                }
                return result(context)
            }
            let tracks = try await session.asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { throw DomainError.unsupported }
            guard self.context == context, operation == revision, backendRevision == ticket, seekRequest == seekTicket, !session.isClosed else { return result(context, .staleContext) }
            let descriptions = try await track.load(.formatDescriptions)
            guard self.context == context, operation == revision, backendRevision == ticket, seekRequest == seekTicket, !session.isClosed else { return result(context, .staleContext) }
            guard let description = descriptions.first,
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  [kAudioFormatLinearPCM, kAudioFormatMPEG4AAC, kAudioFormatOpus].contains(format.pointee.mFormatID),
                  [44100.0, 48000.0].contains(format.pointee.mSampleRate), format.pointee.mChannelsPerFrame == 2 else { throw DomainError.unsupported }
            try await session.authorizeDecodedRead()
            guard self.context == context, operation == revision, backendRevision == ticket else { return result(context, .staleContext) }
            var normalization: Float = 1
            if requested.normalize {
                if normalizationCache?.session == session.id { normalization = normalizationCache!.gain }
                else {
                    let work = Task.detached { try await NativeNormalizationLane.shared.analyze(session: session, track: track) }
                    analysis = work; normalization = try await work.value
                }
            }
            guard self.context == context, operation == revision, backendRevision == ticket, seekRequest == seekTicket, !session.isClosed else { return result(context, .staleContext) }
            if requested.normalize { normalizationCache = (session.id, normalization) }
            let backend = try IncrementalDecodedPlayer(session: session, track: track, settings: requested, normalizationGain: normalization, duration: info?.duration ?? 0, sampleRate: format.pointee.mSampleRate, manual: manualDecodedRendering)
            backend.volume = gain; backend.muted = effectiveMuted; backend.remoteSilenced = remoteRendering; backend.fade = fadeFactor; backend.rate = rate; backend.applySettings()
            do { try backend.prepare(at: position) } catch { backend.close(); throw error }
            player.pause(); effects = requested; decoded = backend; applyOutput(to: backend); analysis = nil
            if let previous = info {
                let source = format.pointee
                let bitrate = source.mFormatID == kAudioFormatLinearPCM ? Int(source.mSampleRate) * Int(source.mBitsPerChannel) * 2 : previous.bitrate
                info = NativeMediaInfo(userSeekable: session.userSeekable, duration: previous.duration, codec: Self.codecName(source), sampleRate: source.mSampleRate, bitrate: bitrate, route: manualDecodedRendering ? "Offline manual · no hardware output" : "Native decoded · system output transformations unknown")
            }
            if wantedPlay { try backend.play(); emit(.started, context) }
            startDecodedPump()
            return result(context)
        } catch {
            guard self.context == context, operation == revision, backendRevision == ticket else { return result(context, .staleContext) }
            wantedPlay = false
            let failure = session.failure ?? Self.failure(error)
            emit(.failed(failure), context)
            return result(context, failure)
        }
    }
    /// Internal qualification entry point through the existing owner/provider session.
    /// Reads only the prepared owned asset, never an arbitrary URL or a rights bypass.
    /// Decoding is bounded and off the audio callback. This does not alter transport,
    /// user-seek permissions, or authorize a live DSP route.
    func measurePreparedAudio(effects: AudioEffects, context: PlaybackContext) async throws -> AVAudioPCMBuffer {
        guard self.context == context, let session = assetSession, !session.isClosed,
              context.request.account == OwnedMedia.account else { throw DomainError.staleContext }
        let revision = operation
        let tracks = try await session.asset.loadTracks(withMediaType: .audio)
        guard self.context == context, operation == revision, assetSession?.id == session.id,
              !session.isClosed else { throw DomainError.staleContext }
        if let error = session.failure { throw error }
        guard let track = tracks.first else { throw DomainError.unavailableContent }
        let reader = try AVAssetReader(asset: session.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw DomainError.unsupported }
        reader.add(output)
        guard reader.startReading() else { throw DomainError.unsupported }
        defer { reader.cancelReading() }
        var chunks: [AVAudioPCMBuffer] = []; var total = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if let error = session.failure { throw error }
            guard !session.isClosed else { throw DomainError.staleContext }
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  asbd.pointee.mChannelsPerFrame == 2, asbd.pointee.mSampleRate == 48000,
                  let data = CMSampleBufferGetDataBuffer(sample) else { throw DomainError.unsupported }
            let count = CMSampleBufferGetNumSamples(sample)
            total += count
            guard total <= 576000, count > 0 else { throw DomainError.invalidInput(.invalidRange) }
            var interleaved = Array(repeating: Float(0), count: count * 2)
            let status = interleaved.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            guard status == noErr, let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { throw DomainError.unsupported }
            buffer.frameLength = AVAudioFrameCount(count)
            for c in 0..<2 { for i in 0..<count { buffer.floatChannelData![c][i] = interleaved[i * 2 + c] } }
            chunks.append(buffer)
        }
        guard reader.status == .completed else { throw session.failure ?? DomainError.unsupported }
        guard self.context == context, operation == revision, assetSession?.id == session.id, !session.isClosed else { throw DomainError.staleContext }
        return try NativeDecodedRenderer.render(chunks, effects: effects)
    }
    public func nativePosition() -> Double { if let decoded { return decoded.position }; return max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0) }
    func requestedPlay() -> Bool { wantedPlay }
    public func nativeRate() -> Float { if let decoded { return decoded.playing ? rate : 0 }; return player.rate }
    func nativeSeekCount() -> UInt64 { seekRevision }
    func controlsOwned(by request: RequestContext) -> Bool { controlOwner == request }
    func nativeStartGains() -> [Float] { startObservations }
    func configuredGain() -> Float { gain }
    func nativeGain() -> Float { decoded.map { $0.volume * $0.fade } ?? player.volume }
    func nativeMuted() -> Bool { player.isMuted }
    private func accepts(_ candidate: PlaybackContext) -> Bool {
        guard let context else { return controlOwner == nil || controlOwner == candidate.request }
        if context == candidate { return true }
        return candidate.request.accountGeneration > context.request.accountGeneration ||
            (candidate.request == context.request && candidate.generation > context.generation)
    }
    private func result(_ context: PlaybackContext, _ error: DomainError? = nil) -> PlaybackResult<Void> {
        .init(context: context, outcome: error.map(Result.failure) ?? .success(()))
    }
    private func emit(_ event: EngineEvent, _ context: PlaybackContext) {
        guard self.context == context else { return }
        output.yield(.init(context: context, event: event, observedAt: clock.now(), renderGeneration: decoded?.renderGeneration))
    }
    deinit { decodedPump?.cancel(); analysis?.cancel(); assetFailureTask?.cancel(); assetSession?.dispose() }
    private func clearObservers(disposeAsset: Bool = true) {
        closeDecoded()
        assetFailureTask?.cancel(); assetFailureTask = nil
        if disposeAsset { normalizationCache = nil; assetSession?.dispose(); assetSession = nil; reportedFailure = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        videoProbe?.stop(item: player.currentItem); videoProbe = nil
        endObserver = nil; failureObserver = nil; timeObserver = nil; statusObserver = nil
    }
    // MARK: W17 native video (owned and local media only)

    /// Audio only for owned/local video: the item's video tracks stop decoding (`AVPlayerItemTrack.isEnabled`), rather than the picture
    /// being covered. The choice persists across items; items without video are unaffected.
    public func setVideoDecoding(_ enabled: Bool, context: PlaybackContext) -> PlaybackResult<Void> {
        guard self.context == context, accepts(context) else { return result(context, .staleContext) }
        videoDecoding = enabled
        applyVideoDecoding()
        return result(context)
    }
    private func applyVideoDecoding() {
        guard let item = player.currentItem else { return }
        for track in item.tracks where track.assetTrack?.mediaType == .video { track.isEnabled = videoDecoding }
    }
    /// The handle a native surface attaches to, only for the current context and only when the item holds a video track.
    public func videoHandle(context: PlaybackContext) -> NativeVideoHandle? {
        guard self.context == context, let item = player.currentItem, item.status == .readyToPlay else { return nil }
        let video = item.tracks.filter { $0.assetTrack?.mediaType == .video }
        guard !video.isEmpty else { return nil }
        return NativeVideoHandle(player: player, presentationSize: item.presentationSize, hasVideoTrack: true, decoding: video.allSatisfy(\.isEnabled))
    }
    /// Starts counting the pixel buffers the decoder delivers for the current item (measurement only).
    public func startVideoMeasurement(context: PlaybackContext) -> PlaybackResult<Void> {
        // Allowed before the first item is prepared (the flag then applies to every item); a newer owner's context is refused.
        guard accepts(context) else { return result(context, .staleContext) }
        measuresVideo = true
        if let item = player.currentItem, item.status == .readyToPlay { videoProbe?.stop(item: item); videoProbe = NativeVideoProbe(item: item) }
        return result(context)
    }
    public func videoFramesDelivered() -> Int { videoProbe?.framesDelivered ?? 0 }

    public func stop(context: PlaybackContext) async -> PlaybackResult<Void> {
        guard accepts(context) else { return result(context, .staleContext) }
        self.context = context; controlOwner = context.request; operation += 1; transport += 1; wantedPlay = false
        fadeFactor = 1
        let previous = assetSession
        let drains = (decoded?.authorizationSessions ?? []) + [pendingNextSession].compactMap { $0 }
        player.pause(); clearObservers(); player.replaceCurrentItem(with: nil); info = nil
        await previous?.disposeAndDrain()
        for session in drains { await session.disposeAndDrain() }
        return result(context)
    }
    public func prepare(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<Void> {
        guard accepts(context) else { return result(context, .staleContext) }
        if self.context != context { fadeFactor = 1 }
        self.context = context; controlOwner = context.request; hasAdoptedNative = false; operation += 1; let revision = operation
        let previous = assetSession
        let drains = (decoded?.authorizationSessions ?? []) + [pendingNextSession].compactMap { $0 }
        player.pause(); clearObservers(); player.replaceCurrentItem(with: nil); info = nil
        await previous?.disposeAndDrain()
        for session in drains { await session.disposeAndDrain() }
        guard self.context == context, operation == revision else { return result(context, .staleContext) }
        var preparedSession: NativeAssetSession?
        do {
            let session = try await assets.assetSession(for: variant, context: context)
            preparedSession = session
            guard self.context == context, operation == revision else { session.dispose(); return result(context, .staleContext) }
            let asset = session.asset
            guard asset.url.isFileURL || RetainedMediaAdmission.admits(session, variant: variant) || (asset.url.scheme == "owned-encrypted" && context.request.account == OwnedMedia.account && OwnedMedia.items.contains(variant.id) && variant.authorization.rawValue == "owned-bundle-only") else { session.dispose(); return result(context, .forbidden) }
            guard !session.isClosed else { return result(context, session.failure ?? .staleContext) }
            assetSession = session
            assetFailureTask = Task { [weak self, session] in
                for await error in session.failures {
                    guard !Task.isCancelled else { return }
                    await self?.assetFailed(error, sessionID: session.id, revision: revision, context: context)
                }
            }
            if let error = session.failure { assetFailed(error, sessionID: session.id, revision: revision, context: context); return result(context, error) }
            let duration = try await asset.load(.duration).seconds
            guard self.context == context, operation == revision else { return result(context, .staleContext) }
            if let error = session.failure { assetFailed(error, sessionID: session.id, revision: revision, context: context); return result(context, error) }
            guard duration.isFinite, duration > 0 else { clearObservers(); return result(context, .unavailableContent) }
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .timeDomain
            if let probe, let track = try await asset.loadTracks(withMediaType: .audio).first {
                let mix = try probe.mix(track: track)
                await MainActor.run { item.audioMix = mix }
            }
            guard self.context == context, operation == revision else { return result(context, .staleContext) }
            player.volume = gain; player.isMuted = effectiveMuted
            player.replaceCurrentItem(with: item)
            // The return acknowledges readiness, not construction of an AVPlayerItem.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while item.status == .unknown, ContinuousClock.now < deadline {
                if let error = session.failure { assetFailed(error, sessionID: session.id, revision: revision, context: context); return result(context, error) }
                try await Task.sleep(for: .milliseconds(10))
                guard self.context == context, operation == revision else { return result(context, .staleContext) }
            }
            if let error = session.failure { assetFailed(error, sessionID: session.id, revision: revision, context: context); return result(context, error) }
            guard item.status == .readyToPlay else { let error = Self.failure(item.error); clearObservers(); return result(context, error) }
            applyVideoDecoding()
            if measuresVideo { videoProbe = NativeVideoProbe(item: item) }
            var sampleRate: Double?
            var codec: String?
            var bitrate: Int?
            if asset.url.isFileURL, let file = try? AVAudioFile(forReading: asset.url) {
                sampleRate = file.fileFormat.sampleRate
                let asbd = file.fileFormat.streamDescription.pointee
                if asbd.mFormatID == kAudioFormatLinearPCM {
                    codec = "PCM \(asbd.mBitsPerChannel)-bit"
                    bitrate = Int(asbd.mSampleRate) * Int(asbd.mBitsPerChannel) * Int(asbd.mChannelsPerFrame)
                }
            }
            guard self.context == context, operation == revision else { return result(context, .staleContext) }
            let controls = await applyDesiredControls(context: context)
            guard self.context == context, operation == revision else { return result(context, .staleContext) }
            if case .failure(let error) = controls.outcome { return result(context, error) }
            info = NativeMediaInfo(userSeekable: session.userSeekable, duration: duration, codec: codec, sampleRate: sampleRate, bitrate: bitrate, route: "System default output · transformations unknown")
            let eventClock = clock
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil) { [weak self] _ in
                let observedAt = eventClock.now()
                Task { await self?.nativeEvent(.ended, sessionID: session.id, revision: revision, context: context, observedAt: observedAt) }
            }
            failureObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: nil) { [weak self] note in
                let raw = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                if session.failure == nil, Self.isCancellation(raw) { return }
                let error = session.failure ?? Self.failure(raw)
                let observedAt = eventClock.now()
                Task { await self?.assetFailed(error, sessionID: session.id, revision: revision, context: context, observedAt: observedAt) }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: nil) { [weak self] time in
                guard time.seconds.isFinite else { return }
                let observedAt = eventClock.now()
                Task { await self?.nativeEvent(.position(time.seconds), sessionID: session.id, revision: revision, context: context, observedAt: observedAt) }
            }
            statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let event: EngineEvent?
                if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { event = .buffering }
                else if player.timeControlStatus == .playing { event = .started }
                else { event = nil }
                if let event {
                    let observedAt = eventClock.now()
                    Task { await self?.nativeEvent(event, sessionID: session.id, revision: revision, context: context, observedAt: observedAt) }
                }
            }
            if !effects.bypass { return await configureEffects(effects, context: context, forceDecoded: true) }
            if preferGapless, (await dspCapabilities(context: context)).effects == .supported { return await configureEffects(effects, context: context, forceDecoded: true) }
            return result(context)
        } catch {
            guard self.context == context, operation == revision else { preparedSession?.dispose(); return result(context, .staleContext) }
            let failure = preparedSession?.failure ?? Self.failure(error)
            if let session = preparedSession, session.failure != nil { assetFailed(failure, sessionID: session.id, revision: revision, context: context) }
            else { preparedSession?.dispose(); clearObservers() }
            return result(context, failure)
        }
    }
    private func nativeEvent(_ event: EngineEvent, sessionID: UUID, revision: UInt64, context: PlaybackContext, observedAt: Duration) {
        guard decoded == nil, self.context == context, operation == revision, assetSession?.id == sessionID, reportedFailure != sessionID else { return }
        output.yield(.init(context: context, event: event, observedAt: observedAt))
    }
    private func assetFailed(_ error: DomainError, sessionID: UUID, revision: UInt64, context: PlaybackContext, observedAt: Duration? = nil) {
        guard self.context == context, operation == revision, assetSession?.id == sessionID, reportedFailure != sessionID else { return }
        reportedFailure = sessionID; wantedPlay = false
        player.pause(); player.replaceCurrentItem(with: nil); info = nil
        assetSession?.dispose(); clearObservers(disposeAsset: false)
        output.yield(.init(context: context, event: .failed(error), observedAt: observedAt ?? clock.now()))
    }
    private static func isCancellation(_ error: Error?) -> Bool {
        if error is CancellationError { return true }
        var current = error as NSError?
        for _ in 0..<4 {
            guard let value = current else { return false }
            if value.domain == NSURLErrorDomain, value.code == NSURLErrorCancelled { return true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
    private static func failure(_ error: Error?) -> DomainError {
        if isCancellation(error) { return .staleContext }
        if let error = error as? DomainError { return error }
        if let error = error as? any NativeAssetFailure { return error.playbackError }
        let code = (error as NSError?)?.code
        if code == -1100 { return .unavailableContent }
        if code == -1009 || code == -1005 { return .offline }
        if code == -1012 || code == -1013 { return .unauthorized }
        return .transientTransport
    }
    public func play(context: PlaybackContext) async -> PlaybackResult<Void> {
        guard self.context == context, player.currentItem != nil || decoded != nil else { return result(context, .staleContext) }
        if backendPreparing != nil {
            transport += 1; let reservation = transport; wantedPlay = true
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while backendPreparing != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(2))
                guard self.context == context, transport == reservation, wantedPlay else { return result(context, .staleContext) }
            }
            guard backendPreparing == nil, self.context == context, transport == reservation, wantedPlay else { return result(context, .transientTransport) }
        }
        if self.context == context, let error = assetSession?.failure { return result(context, error) }
        guard self.context == context, player.currentItem != nil else { return result(context, .staleContext) }
        if var decoded {
            do {
                try await assetSession?.authorizeDecodedRead()
                guard self.context == context, self.decoded === decoded else { return result(context, .staleContext) }
                if let maximumStartGain, gain * fadeFactor > maximumStartGain + 0.000001 { return result(context, .invalidInput(.invalidRange)) }
                if decodedResumeNeedsReset {
                    // Resuming the paused player node in place shortly after a gapless
                    // input switch was observed to insert ~1 s of silence ahead of the
                    // queued samples while the logical position kept advancing (offline
                    // manual rendering; wake after sleep at the boundary). Restart at
                    // the exact logical position through the reset that control changes
                    // use. A next item whose staging has begun is withdrawn first (N2);
                    // an unstaged planned next survives the reset.
                    if decoded.framesUntilTransition != nil {
                        guard await withdrawPlannedNext() else { return result(context, .staleContext) }
                        guard self.context == context, let rebuilt = self.decoded else { return result(context, .staleContext) }
                        decoded = rebuilt; applyOutput(to: rebuilt)
                    }
                    if decodedResumeNeedsReset { try decoded.prepare(at: decoded.position) }
                    decodedResumeNeedsReset = false
                }
                decoded.volume = gain; decoded.fade = fadeFactor; decoded.muted = effectiveMuted; decoded.applySettings()
                try decoded.play(); startObservations.append(decoded.volume * decoded.fade); startObservations = Array(startObservations.suffix(100))
                transport += 1; wantedPlay = true; startDecodedPump(); emit(.started, context); return result(context)
            } catch { return result(context, assetSession?.failure ?? Self.failure(error)) }
        }
        guard !manualDecodedRendering else { return result(context, .unsupported) }
        transport += 1; let revision = transport; wantedPlay = true
        let controls = await applyDesiredControls(context: context)
        guard self.context == context, transport == revision, wantedPlay else { return result(context, .staleContext) }
        if case .failure(let error) = controls.outcome { return result(context, error) }
        if let maximumStartGain, player.volume > maximumStartGain + 0.000001 { return result(context, .invalidInput(.invalidRange)) }
        if let maximumStartGain { print("W06 controlled native admission gain=\(player.volume) limit=\(maximumStartGain)") }
        startObservations.append(player.volume); startObservations = Array(startObservations.suffix(100))
        player.playImmediately(atRate: rate)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while player.timeControlStatus != .playing, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            guard self.context == context, transport == revision, wantedPlay else { return result(context, .staleContext) }
            if player.currentItem?.status == .failed { return result(context, Self.failure(player.currentItem?.error)) }
        }
        return result(context, player.timeControlStatus == .playing ? nil : .offline)
    }
    public func pause(context: PlaybackContext) -> PlaybackResult<Void> {
        if self.context == nil, accepts(context) { self.context = context; controlOwner = context.request }
        guard self.context == context else { return result(context, .staleContext) }
        if decoded?.playing == true { decodedResumeNeedsReset = true }
        // Read before pausing: a paused node reports no player time, so a later read
        // would return the last pump-polled value and the decoded resume reset would
        // replay up to one pump interval (U-N1).
        let pausedAt = nativePosition()
        transport += 1; wantedPlay = false; decodedPump?.cancel(); decodedPump = nil; player.pause(); decoded?.pause(); emit(.position(pausedAt), context)
        return result(context)
    }
    private func observedSeekable(_ value: Bool) {
        guard let info else { return }
        self.info = NativeMediaInfo(userSeekable: value, duration: info.duration, codec: info.codec, sampleRate: info.sampleRate, bitrate: info.bitrate, route: info.route)
    }
    public func validateSeek(context: PlaybackContext) async -> PlaybackResult<Void> {
        guard self.context == context else { return result(context, .staleContext) }
        // An unresolved seek is queued intent; actual application revalidates after prepare.
        guard let session = assetSession else { return result(context) }
        let revision = operation
        do {
            try await session.authorizeUserSeek()
            guard self.context == context, operation == revision, assetSession?.id == session.id else { return result(context, .staleContext) }
            observedSeekable(true)
            return result(context)
        } catch {
            guard self.context == context, operation == revision, assetSession?.id == session.id else { return result(context, .staleContext) }
            let failure = Self.failure(error)
            if failure != .staleContext { observedSeekable(false) }
            return result(context, failure)
        }
    }
    public func seek(to seconds: Double, context: PlaybackContext) async -> PlaybackResult<Void> {
        guard !Task.isCancelled, self.context == context, let item = player.currentItem, let session = assetSession else { return result(context, .staleContext) }
        guard seconds.isFinite, seconds >= 0, seconds <= item.duration.seconds else { return result(context, .invalidInput(.invalidRange)) }
        seekRequest += 1; let request = seekRequest; let revision = operation
        let permission = await validateSeek(context: context)
        guard self.context == context, operation == revision, assetSession?.id == session.id, player.currentItem === item, seekRequest == request, !Task.isCancelled else { return result(context, .staleContext) }
        if case .failure(let error) = permission.outcome { return result(context, error) }
        guard await withdrawPlannedNext() else { return result(context, .staleContext) }
        guard self.context == context, operation == revision, seekRequest == request else { return result(context, .staleContext) }
        seekRevision += 1
        if let decoded {
            do {
                let resume = wantedPlay; decoded.pause(); try decoded.prepare(at: seconds)
                if resume { try decoded.play() }
                return result(context)
            } catch { return result(context, session.failure ?? Self.failure(error)) }
        }
        player.pause(); item.cancelPendingSeeks()
        let completed = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
        guard self.context == context, operation == revision, assetSession?.id == session.id, seekRequest == request, !Task.isCancelled else { return result(context, .staleContext) }
        return result(context, session.failure ?? (completed ? nil : .transientTransport))
    }
    private func acceptControls(_ context: PlaybackContext) -> Bool {
        if let owner = controlOwner { return owner == context.request }
        controlOwner = context.request; return true
    }
    private func applyDesiredControls(context: PlaybackContext) async -> PlaybackResult<Void> {
        while self.context == context {
            let value = await setGain(Double(gain), context: context)
            if case .failure(.staleContext) = value.outcome { continue }
            player.isMuted = effectiveMuted
            return value
        }
        return result(context, .staleContext)
    }
    public func setGain(_ gain: Double, context: PlaybackContext) async -> PlaybackResult<Void> {
        guard acceptControls(context) else { return result(context, .staleContext) }
        guard gain.isFinite, (0...1).contains(gain) else { return result(context, .invalidInput(.invalidRange)) }
        self.gain = Float(gain); gainRevision += 1; let desired = gainRevision
        guard await withdrawPlannedNext() else { return result(context, .staleContext) }
        guard controlOwner == context.request, gainRevision == desired else { return result(context, .staleContext) }
        return await applyGainTarget(self.gain * fadeFactor, context: context)
    }
    /// A temporary timer envelope never replaces the desired independent app gain.
    func setFadeFactor(_ factor: Double, context: PlaybackContext) async -> PlaybackResult<Void> {
        guard self.context == context else { return result(context, .staleContext) }
        guard factor.isFinite, (0...1).contains(factor) else { return result(context, .invalidInput(.invalidRange)) }
        if fadeFactor == Float(factor) { return result(context) }
        // refreshControls may reset decoded staging. Always withdraw the owner's
        // pending next reference first, including a timer clear before adoption.
        guard await withdrawPlannedNext() else { return result(context, .staleContext) }
        guard self.context == context else { return result(context, .staleContext) }
        fadeFactor = Float(factor)
        return await applyGainTarget(gain * fadeFactor, context: context)
    }
    private func applyGainTarget(_ target: Float, context: PlaybackContext) async -> PlaybackResult<Void> {
        gainRevision += 1; let revision = gainRevision
        if let decoded {
            decoded.volume = gain; decoded.fade = fadeFactor; decoded.muted = effectiveMuted
            do { try refreshDecodedControls(decoded); return result(context) }
            catch { return result(context, assetSession?.failure ?? Self.failure(error)) }
        }
        player.volume = target
        // AVPlayer can briefly expose the preceding volume while applying a change
        // across its media queue (observed on pause after a timer fade). Acknowledge
        // the actual property, with a bound and supersession guard, rather than only
        // updating the coordinator's desired gain.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        var stableSince: ContinuousClock.Instant?
        var lastApplication = ContinuousClock.now
        while ContinuousClock.now < deadline {
            guard controlOwner == context.request, gainRevision == revision else { return result(context, .staleContext) }
            if abs(player.volume - target) <= 0.000001 {
                if let stableSince, stableSince.duration(to: .now) >= .milliseconds(30) { return result(context) }
                if stableSince == nil { stableSince = .now }
            } else {
                stableSince = nil
                if lastApplication.duration(to: .now) >= .milliseconds(20) {
                    player.volume = target; lastApplication = .now
                }
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return result(context, .transientTransport)
    }
    public func setMuted(_ muted: Bool, context: PlaybackContext) async -> PlaybackResult<Void> {
        guard acceptControls(context) else { return result(context, .staleContext) }
        self.muted = muted; player.isMuted = effectiveMuted; muteRevision += 1; let desired = muteRevision
        guard await withdrawPlannedNext() else { return result(context, .staleContext) }
        guard controlOwner == context.request, muteRevision == desired else { return result(context, .staleContext) }
        if let decoded {
            decoded.muted = effectiveMuted
            do { try refreshDecodedControls(decoded) } catch { return result(context, assetSession?.failure ?? Self.failure(error)) }
        }
        return result(context)
    }
    /// Balance selects the authorized decoded path; unsupported routes fail explicitly.
    public func setBalance(_ balance: Double, context: PlaybackContext) async -> PlaybackResult<Void> {
        do { return await configureEffects(try AudioEffects(bands: effects.bands, normalizationDB: effects.normalizationDB, normalize: effects.normalize, balance: Float(balance), gain: effects.gain, crossfade: effects.crossfade), context: context) }
        catch { return result(context, .invalidInput(.invalidRange)) }
    }
    public func setRate(_ rate: Double, context: PlaybackContext) async -> PlaybackResult<Void> {
        guard self.context == context else { return result(context, .staleContext) }
        guard rate.isFinite, (0.5...3).contains(rate) else { return result(context, .invalidInput(.invalidRange)) }
        self.rate = Float(rate); rateRevision += 1; let desired = rateRevision
        await cancelPlannedNext()
        guard self.context == context, rateRevision == desired else { return result(context, .staleContext) }
        if let decoded { decoded.rate = self.rate; decoded.applySettings(); return result(context) }; if wantedPlay && !manualDecodedRendering { player.rate = self.rate }; return result(context)
    }
    func setHandoffHandler(_ handler: @escaping @Sendable (UUID, PlaybackContext, PlaybackContext, MediaVariant, Double) async throws -> Void) { handoffHandler = handler }
    func canPlanNext(context: PlaybackContext) -> Bool { self.context == context && decoded?.canInstallNext == true && nextItem == nil && !nextPreparing && rate == 1 && assetSession?.contentKind != .live && assetSession?.contentKind != .advertisement }
    func bindQueueNext(_ plan: QueueHandoff, next: PlaybackContext, variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<Void> {
        guard self.context == context else { return result(context, .staleContext) }
        nextScope = (plan, next)
        return await scheduleNext(variant, context: context)
    }
    /// N2: every decoded reset must follow withdrawal of the owner's planned next.
    /// cancelPlannedNext rebuilds the backend across suspensions, during which a
    /// speculation may bind again; the reset itself is synchronous, so confirm none
    /// remains at that point rather than relying on a single earlier cancel.
    private func withdrawPlannedNext() async -> Bool {
        for _ in 0..<3 {
            await cancelPlannedNext()
            if nextScope == nil && nextItem == nil { return true }
        }
        return false
    }
    /// A control reset mints a new render generation. A start acknowledged by the
    /// backend rebuild in cancelPlannedNext carries the previous generation and is
    /// discarded by observation validation, leaving Domain in buffering (no next
    /// planning, no gapless boundary). Restate the still-active start.
    private func refreshDecodedControls(_ decoded: IncrementalDecodedPlayer) throws {
        try decoded.refreshControls()
        if decoded.playing, wantedPlay, let current = self.context { emit(.started, current) }
    }
    func cancelPlannedNext() async {
        guard nextScope != nil || nextItem != nil, let context else { return }
        nextScope = nil; nextItem = nil
        _ = await configureEffects(effects, context: context, forceDecoded: decoded != nil)
    }
    private func processHandoff() async throws {
        guard !adopting, let backend = decoded, let (item, position) = backend.pendingTransition,
              let old = context, let handler = handoffHandler else { return }
        guard item.variant.expiresAt.map({ wall.now() < $0 }) ?? true else { throw DomainError.expiredMedia }
        try await item.session.authorizeDecodedRead()
        guard decoded === backend, context == old, nextItem?.id == item.id else { throw DomainError.staleContext }
        adopting = true; defer { adopting = false }
        let revision = backendRevision
        try await handler(item.id, old, item.context, item.variant, position)
        guard backendRevision == revision, context == item.context, decoded === backend else { throw DomainError.staleContext }
    }
    func hasStagedHandoffForMeasurement() -> Bool { decoded?.framesUntilTransition != nil && nextItem != nil }
    func pendingHandoffPosition(_ id: UUID) -> Double? {
        guard let (item, position) = decoded?.pendingTransition, item.id == id else { return nil }
        return position
    }
    func adoptPreparedNative(_ id: UUID, from old: PlaybackContext, to next: PlaybackContext) throws {
        guard let backend = decoded, let (item, _) = backend.pendingTransition, item.id == id, context == old, item.context == next, nextItem?.id == id else { throw DomainError.staleContext }
        try backend.adoptTransition(item.id); hasAdoptedNative = true
        self.context = item.context; assetFailureTask?.cancel(); assetSession = item.session
        info = NativeMediaInfo(userSeekable: item.session.userSeekable, duration: item.duration, codec: item.variant.codec, sampleRate: item.sampleRate, bitrate: item.variant.bitrate, route: manualDecodedRendering ? "Native manual output · owned evidence" : "Native decoded · system output transformations unknown")
        let operation = self.operation
        assetFailureTask = Task { [weak self] in for await error in item.session.failures { await self?.assetFailed(error, sessionID: item.session.id, revision: operation, context: item.context) } }
        nextItem = nil; nextScope = nil
        // The transaction owner publishes the accepted Domain start with identity.
        // A second queued started event can otherwise outlive a same-context sleep.
    }
    public func scheduleNext(_ variant: MediaVariant?, context: PlaybackContext) async -> PlaybackResult<Void> {
        guard self.context == context else { return result(context, .staleContext) }
        guard let variant else { await cancelPlannedNext(); return result(context) }
        guard !nextPreparing, let scope = nextScope, let backend = decoded, backend.canInstallNext else { return result(context, .unsupported) }
        nextPreparing = true; defer { nextPreparing = false }
        let revision = backendRevision
        var candidate: NativeAssetSession?
        do {
            guard variant.expiresAt.map({ wall.now() < $0 }) ?? true else { throw DomainError.expiredMedia }
            let session = try await assets.assetSession(for: variant, context: scope.context); candidate = session
            guard session.asset.url.isFileURL || RetainedMediaAdmission.admits(session, variant: variant) || (session.asset.url.scheme == "owned-encrypted" && scope.context.request.account == OwnedMedia.account && OwnedMedia.items.contains(variant.id) && variant.authorization.rawValue == "owned-bundle-only") else { throw DomainError.forbidden }
            guard self.context == context, backendRevision == revision, nextScope?.plan.id == scope.plan.id else { throw DomainError.staleContext }
            pendingNextSession = session
            try await session.authorizeDecodedRead()
            let tracks = try await session.asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first, let description = try await track.load(.formatDescriptions).first,
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description), format.pointee.mSampleRate == backend.sampleRate,
                  format.pointee.mChannelsPerFrame == 2 else { throw DomainError.unsupported }
            let duration = try await session.asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration * backend.sampleRate < Double(Int64.max), session.contentKind != .live else { throw DomainError.unsupported }
            var normalization: Float = 1
            if effects.normalize {
                let work = Task.detached { try await NativeNormalizationLane.shared.analyze(session: session, track: track) }
                prefetchWork = work; normalization = try await work.value
            }
            try await session.authorizeDecodedRead()
            guard self.context == context, backendRevision == revision, nextScope?.plan.id == scope.plan.id, decoded === backend else { throw DomainError.staleContext }
            let overlap = assetSession?.contentKind == .music && session.contentKind == .music ? effects.crossfade : 0
            let item = NativeUpcoming(id: scope.plan.id, context: scope.context, variant: variant, session: session, track: track, duration: duration, sampleRate: backend.sampleRate, normalization: normalization, overlap: overlap)
            try backend.install(item); nextItem = item; pendingNextSession = nil; prefetchWork = nil
            return result(context)
        } catch {
            candidate?.dispose()
            guard self.context == context, backendRevision == revision, nextScope?.plan.id == scope.plan.id else { return result(context, .staleContext) }
            return result(context, Self.failure(error))
        }
    }
    public func events(context: PlaybackContext) -> PlaybackResult<AsyncStream<ScopedEngineEvent>> { .init(context: context, outcome: .success(stream)) }
}
