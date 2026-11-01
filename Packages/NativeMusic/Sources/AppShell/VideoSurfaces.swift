import AppKit
import AVFoundation
import AVKit
import DesignSystem
import Domain
import Features
import Observation
import Playback
import SwiftUI

// W17: native surfaces for the video picture. YouTube Music video shows ONLY the hidden player's own `<video>` picture, moved (the same
// web view, never reloaded) into a native view; owned and local video shows an AVPlayerLayer of the one native AVPlayer. Every control
// around the picture is native. At most one surface holds the picture at a time (`VideoSurfaceOwnership`).

/// Holds a reference to the picture container a window shows, so full screen can hand the same container's picture on.
@MainActor final class VideoHostBox { weak var view: NSView? }

// MARK: Windows

/// One native window for a picture, with full screen through the window itself. Closing the window only lets the picture go; it never
/// stops, restarts or reloads playback.
@MainActor final class VideoWindowPresenter: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    var isOpen: Bool { window != nil }
    private(set) var isFullScreen = false
    /// The window closed (by the user, by `close()`, or because its player ended).
    var onClose: (() -> Void)?
    /// Full screen was entered (true) or left (false).
    var onFullScreen: ((Bool) -> Void)?
    func show<Content: View>(title: String, identifier: String, @ViewBuilder content: () -> Content) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.setAccessibilityIdentifier(identifier)
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.contentView = NSHostingView(rootView: content())
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
    func toggleFullScreen() { window?.toggleFullScreen(nil) }
    func close() { window?.close() }
    /// Closes without telling the owner: used when the owner itself ended (its player or session is gone), so nothing is released twice.
    func closeSilently() { let saved = onClose; onClose = nil; window?.close(); onClose = saved }
    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil; window = nil; isFullScreen = false
        onClose?()
    }
    func windowDidEnterFullScreen(_ notification: Notification) { isFullScreen = true; onFullScreen?(true) }
    func windowDidExitFullScreen(_ notification: Notification) { isFullScreen = false; onFullScreen?(false) }
}

// MARK: YouTube Music: the hidden player's own picture

struct WebVideoSurface: NSViewRepresentable {
    let player: WebMusicPlayer
    let surface: VideoSurface
    var box: VideoHostBox? = nil
    /// Whether this surface may take the picture back when nothing holds it (audio only, then video again). The surface it asks for.
    var reclaims: () -> Bool = { true }
    var preferred: () -> VideoSurface = { .inline }
    func makeCoordinator() -> Coordinator { Coordinator(player: player, surface: surface) }
    @MainActor final class Coordinator { let player: WebMusicPlayer; let surface: VideoSurface; var requesting = false
        init(player: WebMusicPlayer, surface: VideoSurface) { self.player = player; self.surface = surface } }
    func makeNSView(context: Context) -> VideoPictureView {
        let view = VideoPictureView()
        view.setAccessibilityElement(true); view.setAccessibilityRole(.image); view.setAccessibilityLabel(String(localized: "Video"))
        box?.view = view
        let player = player, surface = surface
        Task { @MainActor in await player.presentVideo(on: surface, host: view) }
        return view
    }
    func updateNSView(_ view: VideoPictureView, context: Context) {
        box?.view = view
        // After audio only the picture was let go (never covered); when a video returns, the surface that is still open takes it back.
        guard reclaims(), player.canShowVideo, player.surfaces.holder == nil, !context.coordinator.requesting else { return }
        context.coordinator.requesting = true
        let player = player, wanted = preferred(), coordinator = context.coordinator
        Task { @MainActor in _ = await player.presentVideo(on: wanted, host: view); coordinator.requesting = false }
    }
    static func dismantleNSView(_ view: VideoPictureView, coordinator: Coordinator) {
        let player = coordinator.player, surface = coordinator.surface
        Task { @MainActor in
            await player.releaseVideo(surface)
            if surface == .window { await player.releaseVideo(.fullScreen) }
        }
    }
}

/// Why the picture is not on this surface, and how to bring it back.
struct VideoSurfacePlaceholder: View {
    let message: LocalizedStringKey
    var action: (title: LocalizedStringKey, run: () -> Void)?
    var body: some View {
        VStack(spacing: MusicSpace.xs) {
            Image(systemName: "rectangle.on.rectangle").font(.title2).foregroundStyle(MusicStyle.secondaryText).accessibilityHidden(true)
            Text(message).font(.callout).foregroundStyle(MusicStyle.secondaryText).multilineTextAlignment(.center)
            if let action { Button(action.title, action: action.run).musicButtons() }
        }.padding(MusicSpace.md).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.85))
    }
}

/// The inline preview in Now Playing. It takes the picture only when no other surface holds it; otherwise it says where it is.
struct WebVideoPreview: View {
    let player: WebMusicPlayer
    let showWindow: () -> Void
    var windowOpen: () -> Bool = { false }
    /// The widest the picture may be: 560 in the Now Playing page, wider in the full-screen Now Playing window (W21).
    var maxWidth: CGFloat = 560
    var body: some View {
        let holder = player.surfaces.holder
        ZStack {
            if holder == nil || holder == .inline {
                WebVideoSurface(player: player, surface: .inline, reclaims: { !windowOpen() }, preferred: { .inline }).accessibilityIdentifier("videoPreviewSurface")
            } else if holder == .pictureInPicture {
                VideoSurfacePlaceholder(message: "Playing in Picture in Picture.", action: ("Return Here", { Task { await player.releaseVideo(.pictureInPicture) } }))
            } else {
                VideoSurfacePlaceholder(message: "Playing in the video window.", action: ("Show Video Window", showWindow))
            }
        }
        .aspectRatio(player.snapshot.pictureSize.map { $0.width / max($0.height, 1) } ?? 16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: maxWidth).musicClip(.media)
        .accessibilityElement(children: .contain).accessibilityLabel(Text("Video preview")).accessibilityIdentifier("videoPreview")
    }
}

/// The controls around a YouTube Music picture. Every one is native and sends a command through the player; none touches the page.
struct WebVideoControls: View {
    let player: WebMusicPlayer
    var window: VideoWindowPresenter?
    var body: some View {
        let state = player.snapshot
        VStack(spacing: MusicSpace.xs) {
            HStack(spacing: MusicSpace.sm) {
                Button { Task { await player.playPause() } } label: { Label(state.intent ? "Pause" : "Play", systemImage: state.intent ? "pause.fill" : "play.fill") }
                    .disabled(state.phase == .idle).accessibilityIdentifier("videoPlayPause")
                if state.isAd {
                    MusicBadge("Ad", style: .advertisement)
                        .accessibilityLabel(Text("Advertisement playing")).accessibilityIdentifier("videoAdBadge")
                }
                if state.isLive {
                    MusicBadge("LIVE", style: .live(atEdge: state.atLiveEdge))
                        .accessibilityLabel(Text(state.atLiveEdge ? "Live" : "Behind live")).accessibilityIdentifier("videoLiveBadge")
                    Button { Task { await player.goLive() } } label: { Label("Go Live", systemImage: "dot.radiowaves.left.and.right") }
                        .disabled(!state.canGoLive).help(Text("Jump to the live edge")).accessibilityIdentifier("videoGoLive")
                }
                Spacer()
                qualityMenu(state)
                Button { Task { await player.setCaptions(state.captions != .on) } } label: { Label("Captions", systemImage: state.captions == .on ? "captions.bubble.fill" : "captions.bubble") }
                    .disabled(state.captions == .unavailable).help(Text(state.captions == .unavailable ? "This video offers no captions" : "Captions")).accessibilityIdentifier("videoCaptions")
                Button { Task { await player.selectAudioOnly() } } label: { Label("Audio Only", systemImage: "speaker.wave.2") }
                    .disabled(state.audioOnlyUnavailable != nil)
                    .help(Text(state.audioOnlyUnavailable.map { LocalizedStringKey($0.message) } ?? "Switch to the audio (song) version of this recording"))
                    .accessibilityIdentifier("videoAudioOnly")
                pictureInPictureButton(state)
                if let window { Button { window.toggleFullScreen() } label: { Label(window.isFullScreen ? "Exit Full Screen" : "Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityIdentifier("videoFullScreen") }
            }.labelStyle(.iconOnly).musicButtons()
            WebMusicTimelineView(player: player)
            if let notice = player.videoNotice ?? state.restart?.message {
                Text(notice).font(.caption).foregroundStyle(MusicStyle.secondaryText).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("videoNotice")
            }
            if state.isLive {
                Text("Downloads: \(MediaCapabilityPolicy.availability(of: .download, representation: .live, hiddenPlayer: true).reason ?? "") Crossfade: \(MediaCapabilityPolicy.availability(of: .crossfade, representation: .live, hiddenPlayer: true).reason ?? "")")
                    .font(.caption2).foregroundStyle(MusicStyle.secondaryText).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("videoLiveLimits")
            }
        }.padding(MusicSpace.sm)
    }
    @ViewBuilder private func qualityMenu(_ state: WebMusicSnapshot) -> some View {
        Menu {
            ForEach(state.qualities, id: \.self) { level in
                Button { Task { await player.setQuality(level) } } label: { if level == state.quality { Label(Self.name(level), systemImage: "checkmark") } else { Text(Self.name(level)) } }
            }
        } label: { Label("Quality", systemImage: "slider.horizontal.3") }
            .disabled(state.qualities.isEmpty).help(Text(state.qualities.isEmpty ? "This video reports no quality levels" : "Quality")).accessibilityIdentifier("videoQuality")
    }
    static func name(_ level: String) -> String {
        switch level {
        case "highres": "Highest"; case "hd2160": "2160p"; case "hd1440": "1440p"; case "hd1080": "1080p"; case "hd720": "720p"
        case "large": "480p"; case "medium": "360p"; case "small": "240p"; case "tiny": "144p"; case "auto": "Auto"; default: level
        }
    }
    @ViewBuilder private func pictureInPictureButton(_ state: WebMusicSnapshot) -> some View {
        let active = player.surfaces.holder == .pictureInPicture
        Button { Task { if active { await player.releaseVideo(.pictureInPicture) } else { await player.presentVideo(on: .pictureInPicture, host: nil) } } } label: {
            Label("Picture in Picture", systemImage: active ? "pip.exit" : "pip.enter")
        }.disabled(state.pictureInPicture == .unsupported || !state.hasPicture)
            .help(Text(state.pictureInPicture == .unsupported ? "WebKit reports that this video cannot use Picture in Picture here" : "Picture in Picture"))
            .accessibilityIdentifier("videoPictureInPicture")
    }
}

struct WebVideoWindowContent: View {
    let player: WebMusicPlayer
    let presenter: VideoWindowPresenter
    let box: VideoHostBox
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if player.surfaces.holder == .pictureInPicture {
                    VideoSurfacePlaceholder(message: "Playing in Picture in Picture.", action: ("Return Here", { Task { await player.releaseVideo(.pictureInPicture) } }))
                } else {
                    WebVideoSurface(player: player, surface: .window, box: box, preferred: { presenter.isFullScreen ? .fullScreen : .window }).accessibilityIdentifier("videoWindowSurface")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            WebVideoControls(player: player, window: presenter).musicBarBackground()
        }
    }
}

/// Opens, hands over and closes the YouTube Music video window for one `PlaybackModel`.
@MainActor final class WebVideoWindows {
    let presenter = VideoWindowPresenter()
    private let box = VideoHostBox()
    private weak var player: WebMusicPlayer?
    var isOpen: Bool { presenter.isOpen }
    init() {
        presenter.onClose = { [weak self] in
            guard let self, let player = self.player else { return }
            // Closing lets the picture go (back to the inline preview or the hidden host). It never pauses or reloads.
            Task { @MainActor in await player.releaseVideo(.fullScreen); await player.releaseVideo(.window) }
        }
        presenter.onFullScreen = { [weak self] entered in
            guard let self, let player = self.player, let host = self.box.view else { return }
            Task { @MainActor in _ = await player.presentVideo(on: entered ? .fullScreen : .window, host: host) }
        }
    }
    func show(player: WebMusicPlayer) {
        self.player = player
        presenter.show(title: player.snapshot.title ?? String(localized: "Video"), identifier: "videoWindow") {
            WebVideoWindowContent(player: player, presenter: presenter, box: box)
        }
    }
    func closeAll() { player = nil; presenter.closeSilently() }
}

// MARK: Owned and local video: the native AVPlayer's picture

/// A view whose BACKING layer is the `AVPlayerLayer` (rework F5): the layer never moves between views and is never a bare sublayer under SwiftUI,
/// so AVKit's Picture in Picture finds its source layer in a stable view that stays in the window for the whole of PiP. Non-interactive like every
/// picture surface.
final class NativeVideoLayerView: NSView {
    override func makeBackingLayer() -> CALayer { let layer = AVPlayerLayer(); layer.videoGravity = .resizeAspect; layer.backgroundColor = NSColor.black.cgColor; return layer }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// The native (AVKit) video surface for owned and local media. Each surface view holds an `AVPlayerLayer` of the ONE AVPlayer the session
/// owns, but only the surface holding the picture has the player attached, so a surface coming or going never adds a decoder or an audio
/// output. Audio only disables the video tracks (the decoder stops). Picture in Picture uses AVKit's supported content-source pattern
/// (`AVPictureInPictureController.ContentSource(playerLayer:)`); the source view stays in its window the whole time, a stop is restored in
/// place, and PiP is stopped (never orphaned) before its source surface goes away.
@MainActor @Observable final class NativeVideoPresenter: NSObject, AVPictureInPictureControllerDelegate {
    private(set) var surfaces = VideoSurfaceOwnership()
    private(set) var handle: NativeVideoHandle?
    private(set) var decoding = true
    private(set) var pictureInPictureSupported = AVPictureInPictureController.isPictureInPictureSupported()
    private(set) var notice: String?
    /// The surface whose layer is the Picture in Picture source while it runs (nil otherwise).
    private(set) var pictureInPictureSource: VideoSurface?
    /// Frames the decoder delivered (measurement; a Debug readout).
    private(set) var frames = 0
    @ObservationIgnored private weak var activeView: NativeVideoLayerView?
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var pictureInPictureReturn: VideoSurface?
    var hasPicture: Bool { handle != nil }
    var pictureSize: CGSize? { handle.map(\.presentationSize) }
    /// The surface that should be mounted: while Picture in Picture runs, the surface that sourced it stays where it is.
    var displayHolder: VideoSurface? { surfaces.holder == .pictureInPicture ? pictureInPictureSource : surfaces.holder }

    func update(_ handle: NativeVideoHandle?) {
        if handle == nil, self.handle == nil { return }
        self.handle = handle
        decoding = handle?.decoding ?? true
        guard let handle else { detachAll(); return }
        if let view = activeView, view.playerLayer.player !== handle.player { view.playerLayer.player = handle.player }
    }
    func updateFrames(_ count: Int) { if count != frames { frames = count } }
    /// The session ended or lost its video: PiP stops, every surface lets go.
    func detachAll() {
        pip?.stopPictureInPicture(); pip = nil
        activeView?.playerLayer.player = nil; activeView = nil
        surfaces.releaseAll(); pictureInPictureReturn = nil; pictureInPictureSource = nil
    }
    @discardableResult func present(on surface: VideoSurface, view: NativeVideoLayerView) -> VideoSurfaceOwnership.Change? {
        guard let handle else { return nil }
        // A surface that sourced Picture in Picture and is mounted again keeps its role; it does not steal the picture back from PiP.
        if surfaces.holder == .pictureInPicture {
            if surface == pictureInPictureSource { return nil }
            pip?.stopPictureInPicture()   // another surface was asked for: PiP ends, then this surface takes the picture
        }
        notice = nil
        if let old = activeView, old !== view { old.playerLayer.player = nil }
        view.playerLayer.player = handle.player
        activeView = view
        return surfaces.request(surface)
    }
    func release(_ surface: VideoSurface) {
        // Closing the surface that sources Picture in Picture stops PiP first: the source is never left behind in a dying view.
        if surfaces.holder == .pictureInPicture, surface == pictureInPictureSource { pictureInPictureReturn = nil; pip?.stopPictureInPicture(); return }
        guard surfaces.release(surface) else { return }
        if surface == .pictureInPicture { pip?.stopPictureInPicture() }
        if surfaces.holder == nil { activeView?.playerLayer.player = nil; activeView = nil }
    }
    func setDecoding(_ enabled: Bool, session: PlaybackSession) async {
        do { try await session.setVideoDecoding(enabled); decoding = enabled; update(await session.videoHandle()) }
        catch { notice = String(localized: "The video could not be switched. Try again.") }
    }
    /// Starts Picture in Picture from the surface that holds the picture. Never called unattended by a test.
    func startPictureInPicture() {
        guard surfaces.holder != .pictureInPicture, let view = activeView, let holder = surfaces.holder else { return }
        guard pictureInPictureSupported, handle != nil else { notice = String(localized: "Picture in Picture is not supported on this Mac."); return }
        let controller = AVPictureInPictureController(contentSource: .init(playerLayer: view.playerLayer))
        controller.delegate = self
        guard controller.isPictureInPicturePossible else { notice = String(localized: "Picture in Picture is not possible for this video right now."); return }
        pip = controller
        pictureInPictureSource = holder; pictureInPictureReturn = holder
        controller.startPictureInPicture()
    }
    func stopPictureInPicture() { pip?.stopPictureInPicture() }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in _ = self.surfaces.request(.pictureInPicture) }
    }
    /// The source view never left its window, so there is nothing to move back: confirm the restore in place.
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            if self.surfaces.holder == .pictureInPicture {
                self.surfaces.release(.pictureInPicture)
                if let back = self.pictureInPictureReturn { self.surfaces.request(back) }
            }
            self.pictureInPictureReturn = nil; self.pictureInPictureSource = nil; self.pip = nil
            if self.surfaces.holder == nil { self.activeView?.playerLayer.player = nil; self.activeView = nil }
        }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        Task { @MainActor in self.notice = String(localized: "Picture in Picture could not start."); self.pictureInPictureReturn = nil; self.pictureInPictureSource = nil; self.pip = nil }
    }
}

struct NativeVideoSurface: NSViewRepresentable {
    let presenter: NativeVideoPresenter
    let surface: VideoSurface
    var box: VideoHostBox? = nil
    func makeCoordinator() -> Coordinator { Coordinator(presenter: presenter, surface: surface) }
    @MainActor final class Coordinator { let presenter: NativeVideoPresenter; let surface: VideoSurface
        init(presenter: NativeVideoPresenter, surface: VideoSurface) { self.presenter = presenter; self.surface = surface } }
    func makeNSView(context: Context) -> NativeVideoLayerView {
        let view = NativeVideoLayerView()
        view.setAccessibilityElement(true); view.setAccessibilityRole(.image); view.setAccessibilityLabel(String(localized: "Video"))
        box?.view = view
        presenter.present(on: surface, view: view)
        return view
    }
    func updateNSView(_ view: NativeVideoLayerView, context: Context) { box?.view = view }
    static func dismantleNSView(_ view: NativeVideoLayerView, coordinator: Coordinator) {
        let presenter = coordinator.presenter, surface = coordinator.surface
        Task { @MainActor in presenter.release(surface) }
    }
}

struct NativeVideoPanel: View {
    @Bindable var model: PlaybackModel
    var body: some View {
        let presenter = model.nativeVideo
        VStack(spacing: MusicSpace.sm) {
            ZStack {
                let holder = presenter.displayHolder
                if holder == nil || holder == .inline {
                    NativeVideoSurface(presenter: presenter, surface: .inline).accessibilityIdentifier("nativeVideoSurface")
                    if presenter.surfaces.holder == .pictureInPicture {
                        VideoSurfacePlaceholder(message: "Playing in Picture in Picture.", action: ("Return Here", { presenter.stopPictureInPicture() }))
                    }
                } else {
                    VideoSurfacePlaceholder(message: "Playing in the video window.", action: ("Show Video Window", { model.showNativeVideoWindow() }))
                }
            }
            .overlay { if !presenter.decoding { audioOnlyBadge } }
            .aspectRatio(presenter.pictureSize.map { $0.width / max($0.height, 1) } ?? 16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: 560).musicClip(.media)
            .accessibilityElement(children: .contain).accessibilityLabel(Text("Owned test video")).accessibilityIdentifier("nativeVideoPreview")
            NativeVideoControls(model: model, window: nil)
        }
    }
}

/// Audio only is stated, not painted over: the video tracks are not being decoded, and this says so.
@MainActor var audioOnlyBadge: some View {
    Label("Audio only. The video is not being decoded.", systemImage: "speaker.wave.2").font(.callout).padding(MusicSpace.sm)
        .musicOverlayLabel().accessibilityIdentifier("nativeVideoAudioOnlyBadge")
}

struct NativeVideoControls: View {
    @Bindable var model: PlaybackModel
    var window: VideoWindowPresenter?
    var body: some View {
        let presenter = model.nativeVideo
        VStack(spacing: MusicSpace.xs) {
            HStack(spacing: MusicSpace.sm) {
                Button { Task { if let session = model.session { await presenter.setDecoding(!presenter.decoding, session: session) } } } label: {
                    Label(presenter.decoding ? "Audio Only" : "Show Video", systemImage: presenter.decoding ? "speaker.wave.2" : "play.rectangle")
                }.help(Text(presenter.decoding ? "Stop decoding the video; the audio keeps playing" : "Decode the video again")).accessibilityIdentifier("nativeVideoAudioOnly")
                Button { if presenter.surfaces.holder == .pictureInPicture { presenter.stopPictureInPicture() } else { presenter.startPictureInPicture() } } label: {
                    Label("Picture in Picture", systemImage: "pip.enter")
                }.disabled(!presenter.pictureInPictureSupported || !presenter.decoding).help(Text(presenter.pictureInPictureSupported ? "Picture in Picture" : "Picture in Picture is not supported on this Mac"))
                    .accessibilityIdentifier("nativeVideoPictureInPicture")
                if let window {
                    Button { window.toggleFullScreen() } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }.accessibilityIdentifier("nativeVideoFullScreen")
                } else {
                    Button { model.showNativeVideoWindow() } label: { Label("Video Window", systemImage: "macwindow") }.accessibilityIdentifier("nativeVideoWindow")
                }
            }.labelStyle(.iconOnly).musicButtons()
            if let notice = presenter.notice { Text(notice).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("nativeVideoNotice") }
            #if DEBUG
            HStack(spacing: MusicSpace.md) {
                Text(presenter.surfaces.holder?.rawValue ?? "none").accessibilityIdentifier("videoSurfaceOwner")
                Text(presenter.decoding ? "decoding" : "stopped").accessibilityIdentifier("videoDecoderState")
                Text("\(presenter.frames)").accessibilityIdentifier("videoFrames")
                Text(presenter.pictureInPictureSupported ? "pip-supported" : "pip-unsupported").accessibilityIdentifier("videoPictureInPictureSupport")
                Text(model.state?.playback.state.rawValue ?? "none").accessibilityIdentifier("videoPlaybackState")
                Text("\(Int(model.timeline.snapshot?.playback.position ?? 0))").accessibilityIdentifier("videoPosition")
            }.font(.caption2).foregroundStyle(MusicStyle.secondaryText)
            #endif
        }
    }
}

@MainActor final class NativeVideoWindows {
    let presenter = VideoWindowPresenter()
    private let box = VideoHostBox()
    private weak var model: PlaybackModel?
    var isOpen: Bool { presenter.isOpen }
    init() {
        presenter.onClose = { [weak self] in
            guard let self, let model = self.model else { return }
            model.nativeVideo.release(.fullScreen); model.nativeVideo.release(.window)
        }
        presenter.onFullScreen = { [weak self] entered in
            guard let self, let model = self.model, let host = self.box.view else { return }
            if let view = host as? NativeVideoLayerView { model.nativeVideo.present(on: entered ? .fullScreen : .window, view: view) }
        }
    }
    func show(model: PlaybackModel) {
        self.model = model
        presenter.show(title: String(localized: "Owned test video"), identifier: "nativeVideoWindow") {
            NativeVideoWindowContent(model: model, presenter: presenter, box: box)
        }
    }
    func closeAll() { presenter.closeSilently() }
}
struct NativeVideoWindowContent: View {
    @Bindable var model: PlaybackModel
    let presenter: VideoWindowPresenter
    let box: VideoHostBox
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // The source view of Picture in Picture stays mounted (rework F5); PiP is stated over it.
                NativeVideoSurface(presenter: model.nativeVideo, surface: presenter.isFullScreen ? .fullScreen : .window, box: box).accessibilityIdentifier("nativeVideoWindowSurface")
                if model.nativeVideo.surfaces.holder == .pictureInPicture {
                    VideoSurfacePlaceholder(message: "Playing in Picture in Picture.", action: ("Return Here", { model.nativeVideo.stopPictureInPicture() }))
                }
            }.overlay { if !model.nativeVideo.decoding { audioOnlyBadge } }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            NativeVideoControls(model: model, window: presenter).padding(MusicSpace.sm).musicBarBackground()
        }
    }
}
