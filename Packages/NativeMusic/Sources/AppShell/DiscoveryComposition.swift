import AccountSession
import Domain
import Features
import Foundation
import Network
import Observation
import Playback
import SwiftUI

/// What decides whether a preview may start by itself: Low Power Mode and a constrained or metered connection (DISC04). Watching the
/// connection sends nothing; the system tells the app about its own path.
@MainActor @Observable final class DeviceConditionsMonitor {
    private(set) var lowPowerMode: Bool
    private(set) var constrainedNetwork = false
    @ObservationIgnored var changed: (@MainActor () -> Void)?
    @ObservationIgnored private let monitor: NWPathMonitor?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(watching: Bool = true) {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard watching else { monitor = nil; return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let constrained = path.isConstrained || path.isExpensive
            Task { @MainActor [weak self] in
                guard let self, self.constrainedNetwork != constrained else { return }
                self.constrainedNetwork = constrained; self.changed?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "ytmuse.preview.conditions", qos: .utility))
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled; self.changed?()
            }
        }
    }
    /// A fixed reading, for development data and tests of the composition.
    func pin(lowPowerMode: Bool, constrainedNetwork: Bool) { self.lowPowerMode = lowPowerMode; self.constrainedNetwork = constrainedNetwork; changed?() }
    isolated deinit { monitor?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// A preview is the clip playing in the one shared playback session — the hidden player already owns the picture and the audio, so there
/// is no second player and nothing can overlap. Stopping pauses that same player, and only if it is still on the previewed clip.
@MainActor final class SessionPreviewEngine: PreviewEngine {
    private let playback: PlaybackModel
    private weak var performer: (any SearchActionPerformer)?
    private(set) var previewing: String?
    private var duration: Double?
    private var requestsAtStart = 0
    init(playback: PlaybackModel, performer: (any SearchActionPerformer)?) { self.playback = playback; self.performer = performer }

    func start(_ clip: SampleClip) async -> Bool {
        guard let performer else { return false }
        // Marked before the player reports anything, so its first readings are never counted as a play of the full item.
        previewing = clip.id; duration = clip.durationSeconds
        // A clip with no playlist of its own plays as the service's radio for that clip, the way every other song does. The radio would run
        // on into its next tracks, so the preview is watched (`watch`) and ended with the clip.
        let outcome = await performer.play(playlistID: clip.playlistID ?? "RDAMVM" + clip.id, title: clip.title, videoID: clip.id, params: clip.params)
        guard outcome == .started else { if previewing == clip.id { previewing = nil }; return false }
        requestsAtStart = playback.playRequestCount
        return true
    }
    func stop() async {
        guard let id = previewing else { return }
        previewing = nil
        if playback.music?.snapshot.videoID == id { await playback.music?.pause() }
    }
    /// Pauses whatever the shared player is on. Used when it ran on past the previewed clip: that item was never asked for.
    func pausePlayer() async { await playback.music?.pause() }

    /// What a reading of the shared player means for the preview that owns it (a clip ends with the clip; it never runs on into what follows).
    func watch(_ snapshot: WebMusicSnapshot) -> PreviewWatch {
        guard let clip = previewing else { return .stay }
        let phase: PreviewPlayerPhase
        switch snapshot.phase {
        case .playing, .loading, .buffering: phase = .active
        case .paused: phase = .paused
        case .ended: phase = .ended
        case .idle, .failed: phase = .other
        }
        return PreviewWatcher.evaluate(clip: clip, durationSeconds: duration, videoID: snapshot.videoID, phase: phase, position: snapshot.position,
                                       playRequestsAtStart: requestsAtStart, playRequestsNow: playback.playRequestCount)
    }
    /// Acts on a reading: a clip that ended ends the preview; a player that ran on by itself is paused and the preview ends; a player that moved
    /// because something asked it just stops being previewed.
    func observe(_ snapshot: WebMusicSnapshot, arbiter: PreviewArbiter) async {
        switch watch(snapshot) {
        case .stay: break
        case .clipEnded: await arbiter.stop(.clipEnded)
        case .leftOnItsOwn: await pausePlayer(); await arbiter.stop(.leftOnItsOwn)
        case .replacedByRequest: await arbiter.playbackStartedElsewhere()
        }
    }
    /// Something is playing in the shared session that is not a preview.
    var otherPlaybackBusy: Bool {
        if let music = playback.music {
            switch music.snapshot.phase {
            case .playing, .loading, .buffering: if music.snapshot.videoID != previewing { return true }
            default: break
            }
        }
        return playback.state?.playback.state == .playing
    }
}

/// The picture of a previewing clip: the hidden player's own `<video>`, in W17's single-owner inline surface. A clip with no picture (a song) shows
/// nothing; a picture another surface holds shows that surface's placeholder.
struct SamplePicture: View {
    let playback: PlaybackModel
    var body: some View {
        if let player = playback.music, player.snapshot.hasPicture {
            WebVideoPreview(player: player, showWindow: { playback.showVideoWindow() }, windowOpen: { playback.webVideoWindows.isOpen })
        }
    }
}

extension LocalAccountBootstrap {
    static var automationIsolatedLaunch: Bool {
        #if DEBUG
        automationIsolated(ProcessInfo.processInfo.environment)
        #else
        false
        #endif
    }
    /// Samples, the tuner, Recap and badges. **No source route exists for Samples, Recap, badges or tuner controls yet**: none of the public
    /// YouTube Music responses captured so far carries them, so the application composes unresolved sources and the screens say so.
    /// Radios come from what the catalog pages already published (seeds), and starting one goes through the shared playback session.
    /// The scripted sources exist only under the Debug development flags (`DevelopmentDiscovery`).
    func makeDiscoverySurface() -> DiscoverySurface {
        var samplesSource: any SamplesSource = UnresolvedSamplesSource()
        var summarySource: any AccountSummarySource = UnresolvedSummarySource()
        var controlsSource: any RadioControlsSource = UnresolvedRadioControlsSource()
        var engine: any PreviewEngine = previewEngine
        var performer: (any SearchActionPerformer)? = searchPerformer
        var development = false
        var busy: @MainActor () -> Bool = { [unowned self] in previewEngine.otherPlaybackBusy }
        var signedIn: @MainActor () -> SearchPlayback = { [unowned self] in searchPlayback }
        #if DEBUG
        var scripted: DevelopmentDiscovery?
        if DevelopmentDiscovery.isEnabled(launchEnvironment) {
            let dev = DevelopmentDiscovery(environment: launchEnvironment)
            samplesSource = dev.samples; summarySource = dev.summaries; controlsSource = dev.controls; engine = dev.engine; performer = dev.performer
            conditions.pin(lowPowerMode: dev.lowPowerMode, constrainedNetwork: dev.constrainedNetwork); busy = { dev.engine.otherPlaybackBusy }
            development = true; scripted = dev
            discoveryReadout = { dev.readout }
            signedIn = { .available }
        }
        #endif
        let monitor = conditions
        let arbiter = PreviewArbiter(engine: engine, conditions: {
            PreviewConditions(lowPowerMode: monitor.lowPowerMode, constrainedNetwork: monitor.constrainedNetwork, playbackBusy: busy())
        })
        monitor.changed = { [weak arbiter] in arbiter?.conditionsChanged() }
        let samples = SamplesModel(source: samplesSource, arbiter: arbiter, performer: performer, signedIn: signedIn)
        let tuner = TunerModel(seedBook: RadioSeedBook(), performer: performer, source: controlsSource, signedIn: signedIn)
        let summaries = AccountSummaryModel(source: summarySource, signedIn: signedIn, localRecords: { [unowned self] in
            await library.history.loadLocal(); return library.history.local
        })
        let surface = DiscoverySurface(samples: samples, tuner: tuner, summaries: summaries, development: development)
        #if DEBUG
        scripted?.seed(tuner.seedBook)
        #endif
        catalog.radioObserver = { [weak surface] page in surface?.note(page: page) }
        return surface
    }
    /// Comments, moderation, ratings and invitations. Ratings and invitations are written only by the Library's ledger and the playlist's
    /// edit session; comments and moderation have no source route yet (`UnresolvedCommentsTransport`), so nothing here can send one.
    func makeSocialSurface() -> SocialSurface {
        var transport: any CommentsTransport = UnresolvedCommentsTransport()
        var development = false
        var signedIn: @MainActor () -> SearchPlayback = { [unowned self] in searchPlayback }
        #if DEBUG
        // The labelled development library treats the person as signed in (its Library, playlists and invitations do), so the role check here must agree.
        if DevelopmentLibrary.isEnabled(launchEnvironment) { signedIn = { .available } }
        if DevelopmentDiscovery.isEnabled(launchEnvironment) { transport = DevelopmentDiscovery.comments(); development = true }
        #endif
        return SocialSurface(transport: transport, ledger: library.ledger, signedIn: signedIn, development: development)
    }
    /// Told about every reading of the shared player. A preview is one clip: it ends with the clip, a player that ran on into the next track by
    /// itself is paused, and a player that moved on because something asked it to is simply no longer previewing.
    func discoveryObserves(_ snapshot: WebMusicSnapshot) {
        let arbiter = discovery.arbiter
        guard arbiter.active != nil else { return }
        Task { await previewEngine.observe(snapshot, arbiter: arbiter) }
    }
    func isPreviewing(_ videoID: String?) -> Bool { videoID != nil && previewEngine.previewing == videoID }
}
