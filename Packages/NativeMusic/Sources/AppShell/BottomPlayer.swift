import SwiftUI
import AppKit
import Observation
import DesignSystem
import Playback
import Domain
import Features
import Artwork

@MainActor @Observable final class PlaybackTimelineModel {
    var snapshot: PlaybackSessionSnapshot?
    /// ROUTE09: nil while the Mac itself renders the sound. While a receiver plays, `.some(seconds)` is the receiver's own last position report and
    /// `.some(nil)` means it has reported none lately: the bar then shows no position rather than a local guess.
    var receiver: Double??
    /// The position the bar shows, in seconds (nil: unknown, shown as a dash).
    var displayedPosition: Double? {
        if let receiver { return receiver }
        return snapshot?.playback.position
    }
}
struct PlaybackPanel: View {
    @Bindable var model: PlaybackModel
    var artwork: ArtworkPipeline? = nil
    var artworkRequest: ArtworkRequest? = nil
    var artworkAuthority = ArtworkUIAuthority()
    var paletteChanged: ((ArtworkPalette?, ArtworkTintIdentity?) -> Void)? = nil
    var artworkExpanded = false
    var artworkNamespace: Namespace.ID? = nil
    var showNowPlaying: () -> Void = {}
    var compact = false
    var showQueue: () -> Void = {}
    /// The window's artwork-derived light (owned/native artwork); the YouTube Music artwork supplies its own below.
    var accent: MusicTint? = nil
    /// The YouTube Music cover's light goes to the shell (which holds it for the bar and the expanded player alike).
    var accentChanged: (MusicTint?) -> Void = { _ in }
    @State private var windowVisible = true
    @State private var hovering = false
    @State private var preview = SeekPreview()
    @Environment(\.scenePhase) private var phase
    /// The capsule. The shell hosts it inside the one `MusicGlassGroup` it shares with the expanded player, so the glass shape can morph between them.
    var body: some View {
        TransportBar(tint: accent, morph: artworkNamespace.map { MusicMorph("player-surface", in: $0) }, compact: compact) {
            // One transport for the single playback owner: YouTube Music's hidden
            // player when it is the active source, otherwise the owned session.
            if let player = model.music {
                WebMusicTransportContent(player: player, compact: compact, showNowPlaying: showNowPlaying, showQueue: showQueue, accentChanged: accentChanged, namespace: artworkNamespace, outputs: model.outputs, playback: model)
            } else { ownedContent }
        }.audit("playerBar", group: "outer", kind: .floating)
        // Messages with buttons float just above the capsule (a glass pill); none of them adds a row under it.
        .overlay(alignment: .top) {
            VStack(spacing: MusicSpace.xs) {
                if let outputs = model.outputs { OutputPromptHost(controller: outputs) }
                if let error = model.error {
                    HStack { Text(error).font(.caption).accessibilityIdentifier("playbackError")
                        if model.canRetryAction { Button("Retry action") { Task { await model.retryFailedAction() } }.musicButtons() }
                    }.padding(MusicSpace.sm).musicSurface(.panel).musicTransition(.reveal)
                }
                if model.music == nil, let state = model.state, state.playback.error != nil {
                    Button("Retry selected item") { Task { await model.act { try await $0.resume() } } }.accessibilityIdentifier("retryPlayback").musicButtons()
                        .padding(MusicSpace.xs).musicGlassCapsule()
                }
            }.frame(maxWidth: PlayerCapsule.maximumWidth / 2).fixedSize(horizontal: false, vertical: true)
                .alignmentGuide(.top) { $0[.bottom] + MusicSpace.xs }
        }
        // Visibility only feeds the artwork demand and the Debug gate readout; observation of the playback owner is the shell's (`PlaybackObservation`).
        .background(WindowVisibility { visible in windowVisible = visible })
        .musicAnimation(.reveal, value: model.error)
        #if DEBUG
        .onChange(of: accent, initial: true) { _, value in PlayerTintProbe.record("bar", for: model, value) }
        #endif
    }
    @ViewBuilder private var ownedContent: some View {
        let seekState = preview.state(hovering: hovering)
        MusicCapsuleRow {
            HStack(spacing: MusicSpace.sm) {
                Button(action: showNowPlaying) {
                    playerArtwork.musicCapsuleCover(compact: compact)
                }.buttonStyle(.plain).accessibilityLabel(Text("Show Now Playing")).help(Text("Show Now Playing"))
                    .audit("playerArtwork", group: "playerRow", within: "playerBar")
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.currentTitle).accessibilityIdentifier("currentMediaTitle").font(.system(size: 13, weight: .semibold)).lineLimit(1).playerMatched("player-title", artworkNamespace, .position)
                    if let state = model.state {
                        Text(LocalizedStringKey(model.pending ? "Working…" : state.playback.state.rawValue)).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1).accessibilityIdentifier("playbackState")
                    } else { Text("Choose music to begin").font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1) }
                }.frame(maxWidth: PlayerCapsule.titleWidth, alignment: .leading).audit("playerTitle", group: "playerRow", within: "playerBar")
            }
            OwnedCapsuleTransport(model: model, compact: compact, namespace: artworkNamespace, showsTimes: seekState.showsTimes, preview: preview).audit("playerControls", group: "playerRow", within: "playerBar")
            OwnedCapsuleSecondary(model: model, compact: compact, showQueue: showQueue).audit("playerAccessories", group: "playerRow", within: "playerBar")
        }.audit("playerRow", group: "playerBar", kind: .layer, within: "playerBar")
            .overlay(alignment: .bottom) {
                OwnedCapsuleSeek(model: model, state: seekState, compact: compact, preview: preview).audit("playerTimeline", group: "playerBar", kind: .layer, within: "playerBar")
            }
            .onHover { hovering = $0 }
    }
    private var playerArtwork: some View {
        CurrentArtwork(pipeline: artwork, request: artworkRequest, authority: artworkAuthority, namespace: artworkNamespace, expanded: false, isExpandedDestination: artworkExpanded, visible: windowVisible, compactEdge: compact ? 40 : 52, paletteChanged: paletteChanged)
    }
}
/// Previous / Play-Pause / Next and the more-actions menu of the owned-media transport, shared by the bar and the expanded player.
struct OwnedControlsView: View {
    @Bindable var model: PlaybackModel
    var large = false
    var namespace: Namespace.ID? = nil
    /// The expanded player's look: the capsule's plain glyphs, accent Play circle and a ⋯ with no box or chevron.
    var plain = false
    var body: some View {
        if plain {
            HStack(spacing: MusicSpace.xs) {
                OwnedCapsuleButtons(model: model, large: large, namespace: namespace)
                Menu { OwnedMoreActions(model: model) } label: { MusicGlyphLabel(systemImage: "ellipsis", edge: PlayerCapsule.glyphEdge(large: large)).accessibilityLabel(Text("More playback actions")) }
                    .buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(model.session == nil).accessibilityIdentifier("sleepTimerMenu")
            }
        } else { boxed }
    }
    private var boxed: some View {
        HStack(spacing: MusicSpace.xs) {
            Button { Task { await model.act(action: .previous) { try await $0.previous() } } } label: { Label("Previous", systemImage: "backward.end.fill") }.accessibilityIdentifier("transportPrevious")
            Button { Task { await model.nativePlayPause() } } label: {
                Label(LocalizedStringKey(model.state?.playback.intent == .play ? "Pause" : "Play"), systemImage: model.state?.playback.intent == .play ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }.musicButtons(prominent: true).tint(MusicStyle.accentFill).buttonBorderShape(.circle).accessibilityIdentifier("transportPlayPause")
                .musicAnimation(.playPause, value: model.state?.playback.intent)
            Button { Task { await model.act(action: .next) { try await $0.next() } } } label: { Label("Next", systemImage: "forward.end.fill") }.accessibilityIdentifier("transportNext")
            Menu { OwnedMoreActions(model: model) } label: { Label("More playback actions", systemImage: "ellipsis") }.accessibilityIdentifier("sleepTimerMenu")
        }.labelStyle(.iconOnly).musicButtons().controlSize(large ? .large : .regular).playerMatched("player-controls", namespace, .position).disabled(model.session == nil)
    }
}
/// Previous item, shuffle, repeat and the sleep timer of the owned-media transport: the items of the "More playback actions" menu, in the expanded player and in the capsule.
struct OwnedMoreActions: View {
    @Bindable var model: PlaybackModel
    @State private var customMinutes = 10.0
    var body: some View {
        let mode = OwnedQueueModeState(model.state)
        Button("Previous item") { Task { await model.act(action: .previous) { try await $0.previous(directItem: true) } } }
        // The current order and repeat mode carry the checkmark.
        Toggle("Shuffle", isOn: Binding(get: { mode.shuffled }, set: { on in
            Task { await model.act(action: .shuffle) { try await $0.sendQueue(.shuffle(on ? UInt64.random(in: 0...UInt64.max) : nil)) } }
        }))
        Picker("Repeat", selection: Binding(get: { mode.repeatMode }, set: { next in Task { await model.act(action: .repeatMode) { try await $0.sendQueue(.repeatMode(next)) } } })) {
            ForEach([RepeatMode.off, .one, .all], id: \.self) { mode in
                Text(LocalizedStringKey(mode == .off ? "Repeat off" : mode == .one ? "Repeat one" : "Repeat all")).tag(mode)
            }
        }.pickerStyle(.inline).labelsHidden()
        Divider()
        Menu {
            ForEach([5, 15, 30, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") { Task { await model.nativeEnableTimer { await model.act(action: .sleepTimer) { try await $0.setTimer(.minutes(minutes)) } } } }
            }
            Button("End of item") { Task { await model.nativeEnableTimer { await model.act(action: .sleepTimer) { try await $0.setTimer(.endOfItem) } } } }
            Button("Custom: \(Int(customMinutes)) minutes") { Task { await model.nativeEnableTimer { await model.act(action: .sleepTimer) { try await $0.setTimer(.custom(customMinutes * 60)) } } } }
            ControlGroup { Stepper("Custom minutes", value: $customMinutes, in: 1...1440) }
            Divider()
            Button("Cancel timer") { Task { await model.act(action: .sleepTimer) { try await $0.setTimer(nil) } } }
        } label: { Label("Sleep Timer", systemImage: model.sleepTimerDisplay == nil ? "moon.zzz" : "moon.zzz.fill") }.accessibilityIdentifier("sleepTimerSubmenu")
    }
}

struct PlaybackTimeline: View {
    @Bindable var model: PlaybackTimelineModel
    let seek: (Double) -> Void
    /// The expanded player's slim look (see `WebMusicTimelineView`).
    var plain = false
    @State private var preview: Double?
    @State private var hovering = false
    @State private var dragging = false
    var body: some View {
        let state = model.snapshot
        let duration = max(1, state?.media?.duration ?? 1)
        let shown = preview ?? min(model.displayedPosition ?? 0, duration)
        let seekable = Self.seekEnabled(hasCurrent: state?.queue.current != nil, media: state?.media)
        let slider = Slider(value: Binding(get: { shown }, set: { preview = $0 }), in: 0...duration) { Text("Playback position") } onEditingChanged: { editing in
            dragging = editing
            if !editing, let target = preview { preview = nil; seek(target) }
        }.labelsHidden().disabled(!seekable).accessibilityIdentifier("transportTimeline")
        HStack {
            Text(model.displayedPosition == nil && preview == nil ? "–:––" : format(preview ?? model.displayedPosition ?? 0)).monospacedDigit().frame(minWidth: 36)
                .accessibilityIdentifier("transportElapsed")
            if plain {
                MusicSlimSlider(fraction: shown / duration, active: hovering || dragging, enabled: seekable, thickness: PlayerCapsule.seekHoverThickness) { slider }
                    .onHover { hovering = $0 }
            } else { slider.tint(MusicStyle.accent) }
            Text(format(state?.media?.duration ?? 0)).monospacedDigit().frame(minWidth: 36)
        }.font(.caption).foregroundStyle(MusicStyle.secondaryText)
    }
    private func format(_ value: Double) -> String { let seconds = max(0, Int(value)); return String(format: "%d:%02d", seconds / 60, seconds % 60) }
    /// Main's W14 rule (e65c1ad): a retained/offline variant that is not user-seekable
    /// offers no timeline, rather than a slider whose seek is then refused.
    static func seekEnabled(hasCurrent: Bool, media: NativeMediaInfo?) -> Bool {
        hasCurrent && media != nil && media?.userSeekable != false
    }
}
/// Window notifications, no timers. Hidden/minimized/occluded windows release their UI observer.
struct WindowVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    /// The one rule: something the person can see is being drawn. A window that is ordered out, minimized or fully covered shows nothing, and so
    /// does every window while the screen is locked or a display or the system sleeps (W21, WIN10).
    static func isVisible(onScreen: Bool, miniaturized: Bool, occlusionVisible: Bool, displayActive: Bool) -> Bool {
        onScreen && !miniaturized && occlusionVisible && displayActive
    }
    func makeNSView(context: Context) -> ObserverView { ObserverView(changed: changed) }
    func updateNSView(_ view: ObserverView, context: Context) { view.changed = changed }
    final class ObserverView: NSView {
        var changed: (Bool) -> Void
        private var tokens: [NSObjectProtocol] = []
        private var visibilityObservation: NSKeyValueObservation?
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        /// A pure observer: it must never take a click meant for what is drawn over or under it (the player layer hosts it at window size).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for token in tokens { NotificationCenter.default.removeObserver(token) }; tokens.removeAll()
            visibilityObservation = nil
            guard let window else { changed(false); return }
            // W09-F1. The view attaches while the window is created, before it is ordered on screen, so the first read is
            // usually "hidden" and an occlusion notification is not guaranteed to follow. Being ordered on screen (isVisible),
            // becoming key or main and changing screen all re-read the state; none of them polls.
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeScreenNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            visibilityObservation = window.observe(\.isVisible, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.report() }
            }
            // W21: a locked screen, a sleeping display and a sleeping system show nothing, whatever the window itself says.
            tokens.append(NotificationCenter.default.addObserver(forName: ShellDisplayState.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
            report()
        }
        private func report() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                changed(window.map { WindowVisibility.isVisible(onScreen: $0.isVisible, miniaturized: $0.isMiniaturized, occlusionVisible: $0.occlusionState.contains(.visible), displayActive: ShellDisplayState.shared.active) } ?? false)
            }
        }
        isolated deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
    }
}

/// Observes the playback owner for whichever player surface is on screen (the bar or the expanded player). It lives on the shell's player layer, so
/// swapping one surface for the other never drops the observation: C1's coarse snapshot and separate clock are read exactly as before.
struct PlaybackObservation: ViewModifier {
    let model: PlaybackModel
    @State private var observer = UUID()
    @State private var windowVisible = true
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content
            .background(WindowVisibility { visible in windowVisible = visible; model.observe(observer, visible: visible && phase != .background) })
            .onAppear { model.observe(observer, visible: windowVisible && phase != .background) }
            .onChange(of: phase) { _, value in model.observe(observer, visible: windowVisible && value != .background) }
            .onDisappear { model.observe(observer, visible: false) }
    }
}
