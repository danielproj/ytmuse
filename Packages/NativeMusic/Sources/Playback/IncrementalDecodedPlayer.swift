@preconcurrency import AVFoundation
import AudioToolbox
import Domain
import Foundation

/// Called exclusively on NativePlayer's actor, never from the native render thread.
/// No custom audio callbacks or completion closures. Polling retires played buffers.
final class IncrementalDecodedPlayer {
    let sampleRate: Double
    static let chunkFrames = 4096
    static let maximumQueuedFrames = 32768
    // Native decoder sample block <=16384 frames + interleaved copy + planar slice,
    // queued buffers <=32768, planar slice <=4096, manual output <=1024.
    static let maximumPayloadBytes = (32768 + 16384 * 4 + 4096 * 4 + 1024) * 8
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    let speed = AVAudioUnitTimePitch()
    let limiter: AVAudioUnitEffect
    var session: NativeAssetSession
    var track: AVAssetTrack
    var duration: Double
    let manual: Bool
    let format: AVAudioFormat
    private var registrations: [UUID: (NativeAssetSession, UUID)] = [:]
    private let permit: NativeOutputPermit
    private var input: AuthorizedPCMInput?
    private var nextInput: AuthorizedPCMInput?
    private var upcoming: NativeUpcoming?
    private var producerNormalization: Float = 1
    private var transition: (item: NativeUpcoming, start: Int64)?
    private var retiring: [(session: NativeAssetSession, end: Int64)] = []
    private var transitioned: UUID?
    private var logicalStart: Int64 = 0
    private var queued: [(end: Int64, buffer: AVAudioPCMBuffer)] = []
    private var submitted: Int64 = 0
    private var manualConsumed: Double = 0
    private var lastConsumed: Int64 = 0
    private var origin: Double = 0
    private var stopped = false
    private(set) var renderGeneration = UUID()
    private(set) var playing = false
    private(set) var eof = false
    private(set) var ended = false
    private(set) var peakRetainedFrames = 0
    private(set) var decodedFrames: Int64 = 0
    private var peakResponse: Float = 1
    var settings: AudioEffects
    var normalizationGain: Float
    var volume: Float = 1
    var muted = false
    var fade: Float = 1
    /// W39 (ROUTE08): a Cast receiver renders instead. Holds the engine's OUTPUT MIXER at zero, independent of the baked-in mute, so silence is a state of the
    /// engine itself (read back by `outputIsSilent`), not only a value the renderer will apply to the next buffers.
    var remoteSilenced = false
    var outputIsSilent: Bool { engine.mainMixerNode.outputVolume == 0 }
    var rate: Float = 1
    init(session: NativeAssetSession, track: AVAssetTrack, settings: AudioEffects, normalizationGain: Float, duration: Double, sampleRate: Double = 48000, manual: Bool) throws {
        guard session.decodedAccess != .unavailable else { throw DomainError.unsupported }
        self.sampleRate = sampleRate; self.format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        permit = NativeOutputPermit(engine: engine, node: node)
        self.session = session; self.track = track; self.settings = settings
        self.duration = duration; self.normalizationGain = normalizationGain; self.manual = manual
        limiter = NativeDecodedRenderer.makeLimiter()
        for unit in [node, eq, speed, limiter] as [AVAudioNode] { engine.attach(unit) }
        engine.connect(node, to: eq, format: format); engine.connect(eq, to: speed, format: format)
        engine.connect(speed, to: limiter, format: format); engine.connect(limiter, to: engine.mainMixerNode, format: format)
        // Must precede engine.start. In test mode no device output is initialized.
        if manual { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024) }
        applySettings()
        let permit = self.permit
        let source = session.id; permit.register(source)
        registrations[source] = (session, session.retractOnInvalidation { permit.retract(source: source) })
    }
    deinit { close() }
    func close() {
        guard !stopped else { return }; stopped = true; playing = false
        permit.retract()
        input?.close(); input = nil; nextInput?.close(); nextInput = nil
        for (session, id) in registrations.values { session.removeRetraction(id); if session.id != self.session.id { session.dispose() } }; registrations.removeAll()
        retiring.removeAll(); upcoming = nil
        node.stop(); engine.stop(); queued.removeAll()
    }
    private func check() throws {
        try Task.checkCancellation()
        guard !stopped else { throw DomainError.staleContext }
        for (session, _) in registrations.values {
            if let error = session.failure { throw error }
            guard !session.isClosed else { throw DomainError.staleContext }
        }
    }
    func applySettings() {
        peakResponse = NativeDecodedRenderer.peakResponse(settings, sampleRate: sampleRate)
        for (index, band) in eq.bands.enumerated() {
            band.filterType = .parametric; band.frequency = NativeDecodedRenderer.frequencies[index]
            band.bandwidth = 1; band.gain = settings.bands[index]; band.bypass = settings.bands[index] == 0
        }
        eq.bypass = settings.bands.allSatisfy { $0 == 0 }
        speed.bypass = rate == 1; speed.rate = rate
        // Native peak limiter is only active if a gain/filter can increase peaks.
        limiter.bypass = !NativeDecodedRenderer.needsLimiter(settings, normalizationGain: normalizationGain)
        node.volume = 1
        engine.mainMixerNode.outputVolume = remoteSilenced ? 0 : 1
        #if DEBUG
        // Test double: an engine whose output mixer does not go silent when asked (the fault ROUTE08's confirmation exists to detect).
        if let stuck = stuckMixerVolumeForTesting { engine.mainMixerNode.outputVolume = stuck }
        #endif
    }
    #if DEBUG
    var stuckMixerVolumeForTesting: Float?
    #endif
    /// Retire all previously baked control values at the current logical sample.
    /// Reset also clears EQ/limiter tails before a mute acknowledgement.
    func refreshControls() throws {
        let position = self.position; let resume = playing
        try prepare(at: position); applySettings()
        if resume { try play() }
    }
    private var consumed: Int64 {
        if manual { return Int64(manualConsumed) }
        guard let time = node.lastRenderTime, let position = node.playerTime(forNodeTime: time) else { return lastConsumed }
        lastConsumed = max(lastConsumed, position.sampleTime)
        return lastConsumed
    }
    private var tailFrames: Int64 {
        let seconds = (eq.bypass ? 0 : eq.auAudioUnit.latency) + (speed.bypass ? 0 : speed.auAudioUnit.latency) + (limiter.bypass ? 0 : limiter.auAudioUnit.latency)
        return Int64(ceil(seconds * sampleRate * Double(rate)))
    }
    var position: Double { origin + Double(min(submitted, max(0, consumed - tailFrames)) - logicalStart) / sampleRate }
    var pendingTransition: (NativeUpcoming, Double)? {
        guard let transition, consumed >= transition.start + tailFrames else { return nil }
        return (transition.item, max(0, Double(consumed - tailFrames - transition.start) / sampleRate))
    }
    var framesUntilTransition: Int? { transition.map { max(0, Int($0.start + tailFrames - consumed)) } }
    func adoptTransition(_ id: UUID) throws {
        guard let transition, transition.item.id == id else { throw DomainError.staleContext }
        logicalStart = transition.start; origin = 0
        session = transition.item.session; track = transition.item.track; duration = transition.item.duration; normalizationGain = transition.item.normalization
        self.transition = nil
    }
    var authorizationSessions: [NativeAssetSession] { registrations.values.map { $0.0 } }
    var canInstallNext: Bool { upcoming == nil && transition == nil }
    func install(_ item: NativeUpcoming) throws {
        try check(); guard upcoming == nil, transition == nil, item.sampleRate == sampleRate, rate == 1 else { throw DomainError.unsupported }
        upcoming = item; transitioned = nil
        if item.normalization > 1 { limiter.bypass = false }
        let permit = self.permit
        let source = item.session.id; permit.register(source)
        registrations[source] = (item.session, item.session.retractOnInvalidation { permit.retract(source: source) })
        eof = false
        // Withdraw already-staged current samples, preserving native logical position.
        // The caller installs initial plans before Play. Later plans must precede the
        // overlap boundary by the current queued horizon.
        let current = position
        guard !playing else { return }
        try prepare(at: current)
    }

    var retainedFrames: Int { queued.reduce(0) { $0 + Int($1.buffer.frameLength) } + (input?.retainedFrames ?? 0) + (nextInput?.retainedFrames ?? 0) }
    var finished: Bool { eof && consumed >= submitted + tailFrames }
    private func retire(_ old: NativeAssetSession) {
        guard old.id != session.id else { return }
        if let registration = registrations.removeValue(forKey: old.id) {
            permit.unregister(old.id)
            old.removeRetraction(registration.1)
            old.dispose()
        }
    }
    func prepare(at seconds: Double) throws {
        try check()
        // A reset withdraws every scheduled sample and reader, including an adopted
        // outgoing fade. Only the current source and a still-planned next survive.
        // Unregister before disposal so obsolete authorization cannot retract the
        // shared output permit belonging to the current, authorized source.
        let discarded = registrations.values.map { $0.0 }.filter {
            $0.id != session.id && $0.id != upcoming?.session.id
        }
        renderGeneration = UUID(); node.stop(); engine.stop(); engine.reset(); input?.close(); nextInput?.close(); nextInput = nil; queued.removeAll()
        for old in discarded { retire(old) }
        retiring.removeAll()
        origin = seconds; logicalStart = 0; transition = nil; transitioned = nil; producerNormalization = normalizationGain
        submitted = 0; manualConsumed = 0; lastConsumed = 0; eof = false; ended = false
        if seconds >= duration { eof = true; input = nil; return }
        input = try AuthorizedPCMInput(session: session, track: track, sampleRate: sampleRate, duration: duration, start: seconds)
        try refill()
    }
    func play() throws { try check(); try refill(); try permit.perform { if !engine.isRunning { try engine.start() }; applySettings(); node.play(); playing = true } }
    func pause() { node.pause(); playing = false }
    func refill() throws {
        try check()
        let cursor = consumed; queued.removeAll { $0.end <= cursor }
        for old in retiring where cursor >= old.end + tailFrames && old.session.id != session.id {
            retire(old.session)
        }
        retiring.removeAll { cursor >= $0.end + tailFrames && $0.session.id != session.id }
        while submitted - cursor < Self.maximumQueuedFrames && !eof {
            guard let input else { eof = true; break }
            let available = min(Self.chunkFrames, Self.maximumQueuedFrames - Int(submitted - cursor))
            let overlap = upcoming.map { Int64((min($0.overlap, Double(input.totalFrames - input.startFrame) / sampleRate / 2, $0.duration / 2) * sampleRate).rounded(.down)) } ?? 0
            let boundary = input.totalFrames - overlap
            if let item = upcoming, input.cursor >= boundary, transitioned != item.id {
                nextInput = try AuthorizedPCMInput(session: item.session, track: item.track, sampleRate: sampleRate, duration: item.duration, start: 0)
                transition = (item, submitted); transitioned = item.id
            }
            if input.cursor >= input.totalFrames {
                if let nextInput, let item = upcoming {
                    input.close()
                    retiring.append((input.session, submitted))
                    // Old initial-session retraction remains installed until close; an
                    // old grant cannot silently outlive overlapping scheduled samples.
                    self.input = nextInput; self.nextInput = nil; producerNormalization = item.normalization
                    upcoming = nil
                    continue
                }
                eof = true; break
            }
            let count = min(available, Int(input.totalFrames - input.cursor), input.cursor < boundary ? Int(boundary - input.cursor) : available)
            guard count > 0, let buffer = try input.readExact(count) else { throw DomainError.malformedResponse }
            let length = Int(buffer.frameLength)
            let baseGain = producerNormalization
            if let nextInput, let item = upcoming {
                guard let second = try nextInput.readExact(length), second.frameLength == buffer.frameLength else { throw DomainError.malformedResponse }
                let progress = input.cursor - Int64(length) - boundary
                for c in 0..<2 { for i in 0..<length {
                    let t = overlap > 1 ? Float(progress + Int64(i)) / Float(overlap - 1) : 1
                    buffer.floatChannelData![c][i] = buffer.floatChannelData![c][i] * baseGain * (1 - t) + second.floatChannelData![c][i] * item.normalization * t
                } }
            } else if baseGain != 1 { for c in 0..<2 { for i in 0..<length { buffer.floatChannelData![c][i] *= baseGain } } }
            // Preserve the requested small-signal EQ response. Native streaming
            // peak limiting handles only peaks that exceed available output range.
            let scalar = (muted ? 0 : volume * fade) * pow(Float(10), (settings.normalizationDB ?? 0) / 20) * settings.gain
            if scalar != 1 || settings.balance != 0 {
                for c in 0..<2 {
                    let balance = c == 0 ? min(1, 1 - settings.balance) : min(1, 1 + settings.balance)
                    for i in 0..<length { buffer.floatChannelData![c][i] *= scalar * balance }
                }
            }
            if !limiter.bypass { NativeDecodedRenderer.compensatePeaks(buffer, response: peakResponse) }
            try permit.perform { try check(); node.scheduleBuffer(buffer, at: nil) }
            submitted += Int64(length); decodedFrames += Int64(length); queued.append((submitted, buffer))
            peakRetainedFrames = max(peakRetainedFrames, retainedFrames)
        }
    }
    func markEnded() -> Bool { guard playing, finished, !ended else { return false }; ended = true; playing = false; node.pause(); engine.pause(); input?.close(); return true }
    func render(_ frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        try check(); guard manual, frames > 0, frames <= 1024 else { throw DomainError.unsupported }
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        if !playing { result.frameLength = frames; for c in 0..<2 { result.floatChannelData![c].update(repeating: 0, count: Int(frames)) }; return result }
        try refill()
        let amount = min(Int(frames), max(0, Int(submitted + (eof ? tailFrames : 0) - consumed)))
        guard amount > 0 else { result.frameLength = 0; return result }
        let status = try engine.renderOffline(AVAudioFrameCount(amount), to: result)
        guard status == .success else { throw DomainError.transientTransport }
        manualConsumed += Double(result.frameLength) * Double(rate)
        try refill(); return result
    }
    static func makeReader(session: NativeAssetSession, track: AVAssetTrack, start: Double) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        if let error = session.failure { throw error }
        guard !session.isClosed, session.decodedAccess != .unavailable else { throw DomainError.unsupported }
        let reader = try AVAssetReader(asset: session.asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(out) else { throw DomainError.unsupported }; reader.add(out)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48000), duration: .positiveInfinity)
        guard reader.startReading() else { throw session.failure ?? DomainError.unsupported }
        return (reader, out)
    }
    /// Whole-track unweighted stereo RMS in a streaming pass, constant memory.
    /// Silence (< -80 dBFS RMS) is not amplified; matching target is -18 dBFS RMS.
    static func analyze(session: NativeAssetSession, track: AVAssetTrack) async throws -> Float {
        try await session.authorizeDecodedRead()
        let cancellation=NativeReaderCancellation()
        return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        let (reader, output) = try makeReader(session: session, track: track, start: 0)
        cancellation.install(reader)
        let retraction=session.retractOnInvalidation { cancellation.cancel() }
        defer { session.removeRetraction(retraction); cancellation.cancel() }
        var squares: Double = 0; var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            try await session.authorizeDecodedRead()
            guard let sample = output.copyNextSampleBuffer() else { break }
            try Task.checkCancellation()
            if let error = session.failure { throw error }
            guard !session.isClosed, let data = CMSampleBufferGetDataBuffer(sample) else { throw DomainError.staleContext }
            let bytes = CMBlockBufferGetDataLength(data)
            guard bytes <= 16384 * 8 else { throw DomainError.unsupported }
            var values = Array(repeating: Float(0), count: bytes / 4)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard status == noErr else { throw DomainError.unsupported }
            for value in values { guard value.isFinite else { throw DomainError.unsupported }; squares += Double(value) * Double(value) }
            count += Int64(values.count)
        }
        guard reader.status == .completed, count > 0 else { throw session.failure ?? DomainError.unsupported }
        let rms = sqrt(squares / Double(count))
        return rms > 0.0001 ? Float(min(15.8489319, pow(10, -18.0 / 20) / rms)) : 1
        } onCancel: { cancellation.cancel() }
    }
}
