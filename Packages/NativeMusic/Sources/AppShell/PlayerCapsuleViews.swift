import SwiftUI
import AppKit
import Observation
import DesignSystem
import Domain
import Features
import Playback

// PLAYER-1: the pieces of the floating capsule player bar that the YouTube Music transport and the owned-media transport share. The expanded player
// reuses the same buttons, secondary controls and slim sliders (larger), so both surfaces look and read alike.

#if DEBUG
/// Test seam: a hosted audit render cannot hover or drag, so it forces the seek's state (nil: whatever the pointer says).
@MainActor enum CapsuleDebug { static var forcedSeekState: MusicSeekState? }
#endif

/// A seek being dragged or focused with the keyboard. Read by the seek layer, the times beside the transport and the capsule's own state; a position tick
/// never touches it.
@MainActor @Observable final class SeekPreview {
    var value: Double?
    var focused = false
    func state(hovering: Bool) -> MusicSeekState {
        #if DEBUG
        if let forced = CapsuleDebug.forcedSeekState { return forced }
        #endif
        return MusicSeekState(hovering: hovering, dragging: value != nil, focused: focused)
    }
}

/// The glyph a volume level wears.
enum CapsuleVolumeSymbol {
    static func name(level: Double, muted: Bool = false) -> String {
        if muted || level <= 0 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// Volume: a glyph with a slim slider beside it (regular), or the glyph alone opening a popover with the slider (compact). The slider is a real `Slider`
/// under a slim drawing: 3 pt track, accent fill, a small knob only under the pointer or while dragged.
struct CapsuleVolume: View {
    let level: Double
    var range: ClosedRange<Double> = 0...1
    let set: (Double) -> Void
    var muted = false
    let label: LocalizedStringKey
    let identifier: String
    var enabled = true
    var compact = false
    var large = false
    var help: String = ""
    /// A mute toggle on the glyph (owned media): its title, identifier and action. Without one the glyph only shows the level.
    var mute: (title: LocalizedStringKey, identifier: String, disabled: Bool, action: () -> Void)? = nil
    @State private var shown = false
    @State private var hovering = false
    @State private var dragging = false
    @FocusState private var focused: Bool
    var body: some View {
        if compact {
            Button { shown.toggle() } label: { Label(label, systemImage: symbol) }
                .buttonStyle(.musicGlyph(edge: PlayerCapsule.glyphEdge(large: large))).disabled(!enabled && (mute?.disabled ?? true)).help(help.isEmpty ? Text(label) : Text(verbatim: help))
                .accessibilityIdentifier(identifier)
                .popover(isPresented: $shown, arrowEdge: .top) {
                    HStack(spacing: MusicSpace.xs) {
                        if let mute { muteButton(mute) }
                        slider.frame(width: PlayerCapsule.titleWidth)
                    }.padding(MusicSpace.sm)
                }
        } else {
            HStack(spacing: 0) {
                if let mute { muteButton(mute) }
                else {
                    Image(systemName: symbol).font(PlayerCapsule.volumeGlyphFont)
                        .foregroundStyle(enabled ? Color.primary.opacity(0.8) : Color.primary.opacity(0.3))
                        .frame(width: PlayerCapsule.glyphEdge(large: large), height: PlayerCapsule.glyphEdge(large: large)).accessibilityHidden(true)
                }
                slider.frame(width: PlayerCapsule.volumeWidth)
            }
        }
    }
    private var symbol: String { CapsuleVolumeSymbol.name(level: level, muted: muted) }
    private func muteButton(_ mute: (title: LocalizedStringKey, identifier: String, disabled: Bool, action: () -> Void)) -> some View {
        Button(action: mute.action) { Label(mute.title, systemImage: symbol) }
            .buttonStyle(.musicGlyph(edge: PlayerCapsule.glyphEdge(large: large))).disabled(mute.disabled).help(Text(mute.title)).accessibilityIdentifier(mute.identifier)
    }
    private var slider: some View {
        let span = max(range.upperBound - range.lowerBound, 0.000001)
        return MusicSlimSlider(fraction: (level - range.lowerBound) / span, active: hovering || dragging || focused, enabled: enabled) {
            Slider(value: Binding(get: { level }, set: set), in: range, onEditingChanged: { dragging = $0 }) { Text(label) }
                .labelsHidden().focused($focused).disabled(!enabled).help(Text(verbatim: help)).accessibilityIdentifier(compact ? identifier + "Slider" : identifier)
        }.onHover { hovering = $0 }
    }
}

// MARK: YouTube Music

/// Previous / Play-Pause / Next: the buttons of the capsule and of the expanded player (`large`). Identifiers are the bar's.
struct WebCapsuleButtons: View {
    let player: WebMusicPlayer
    var compact = false
    var large = false
    var namespace: Namespace.ID? = nil
    var body: some View {
        let state = player.snapshot
        HStack(spacing: MusicSpace.xs) {
            Button { Task { await player.previous() } } label: { Label("Previous", systemImage: "backward.end.fill") }
                .buttonStyle(.musicGlyph(edge: PlayerCapsule.glyphEdge(large: large))).disabled(!state.canSkip).help(Text("Previous")).accessibilityIdentifier("musicPrevious")
            Button { Task { await player.playPause() } } label: {
                if state.phase == .loading || state.phase == .buffering {
                    ProgressView().controlSize(.small).accessibilityLabel(Text(state.intent ? "Loading, Pause" : "Play"))
                } else {
                    Label(state.intent ? "Pause" : "Play", systemImage: state.intent ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace))
                }
            }.buttonStyle(.musicPlay(edge: PlayerCapsule.playEdge(compact: compact, large: large))).disabled(state.phase == .idle).accessibilityIdentifier("musicPlayPause")
                .musicAnimation(.playPause, value: state.intent)
            Button { Task { await player.next() } } label: { Label("Next", systemImage: "forward.end.fill") }
                .buttonStyle(.musicGlyph(edge: PlayerCapsule.glyphEdge(large: large))).disabled(!state.canSkip).help(Text("Next")).accessibilityIdentifier("musicNext")
        }.playerMatched("player-controls", namespace, .position)
    }
}

/// The capsule's centre group: the elapsed time, the three buttons, the remaining time. The times' slots are reserved at rest (invisible), so the buttons
/// never move when they appear; the group sits a point above the capsule's centre, clear of the seek under it.
struct WebCapsuleTransport: View {
    let player: WebMusicPlayer
    var compact = false
    var namespace: Namespace.ID? = nil
    let showsTimes: Bool
    let preview: SeekPreview
    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            WebCapsuleTime(player: player, elapsed: true, visible: showsTimes, compact: compact, preview: preview)
                .audit("playerElapsed", group: "playerTimes", kind: .layer, within: "playerBar")
            WebCapsuleButtons(player: player, compact: compact, namespace: namespace).audit("playerButtons", group: "playerButtons", kind: .layer, within: "playerBar")
            WebCapsuleTime(player: player, elapsed: false, visible: showsTimes, compact: compact, preview: preview)
                .audit("playerRemaining", group: "playerTimes", kind: .layer, within: "playerBar")
        }.offset(y: -PlayerCapsule.transportLift)
    }
}

/// An elapsed or remaining time. It reads the clock itself, so a position tick rebuilds only this text.
struct WebCapsuleTime: View {
    let player: WebMusicPlayer
    let elapsed: Bool
    let visible: Bool
    let compact: Bool
    let preview: SeekPreview
    var body: some View {
        let state = player.snapshot
        let position = preview.value ?? player.timeline.position
        let behind = player.timeline.behindLive
        let text: String = elapsed
            ? (state.isAd ? "Ad" : (state.isLive ? (state.atLiveEdge ? String(localized: "Live") : WebMusicTimelineView.format(behind ?? 0)) : WebMusicTimelineView.format(position)))
            : (state.isAd || state.isLive ? "" : "-" + WebMusicTimelineView.format(max(0, state.duration - position)))
        MusicTimeSlot(text, visible: visible, slot: PlayerCapsule.timeSlot(compact: compact), leadingSide: elapsed)
            .accessibilityIdentifier(elapsed ? "musicElapsed" : "musicRemaining")
    }
}

/// What the capsule's ⋯ menu offers, in order. Decided here (not in the view) so the choice is testable without opening a menu. Share has its own
/// button beside Queue and is never in this menu.
enum CapsuleMoreItem: Hashable { case sleepTimer, showVideo, goLive, episodeControls }

/// Shuffle, Repeat, volume, Output, Queue, Share, the sleep timer's chip and ⋯: the trailing group. `expanded` is the expanded player's: larger, with Go Live and
/// the LIVE badge inline (as before) and no chip (the expanded player has its own sleep-timer line).
struct WebCapsuleSecondary: View {
    static func moreItems(state: WebMusicSnapshot, hasSleepTimer: Bool, canShowVideo: Bool, episode: Bool, liveInline: Bool = false) -> [CapsuleMoreItem] {
        var items: [CapsuleMoreItem] = []
        if hasSleepTimer { items.append(.sleepTimer) }
        if canShowVideo, state.hasPicture { items.append(.showVideo) }
        if state.isLive, !liveInline { items.append(.goLive) }
        if episode { items.append(.episodeControls) }
        return items
    }
    @Environment(\.podcastsSurface) private var podcasts
    @Environment(\.shareCurrentSong) private var shareCurrentSong
    @Environment(\.playingRatingShell) private var ratingShell
    let player: WebMusicPlayer
    var compact = false
    var expanded = false
    var showVideo: (() -> Void)? = nil
    var showQueue: () -> Void = {}
    var playback: PlaybackModel? = nil
    @State private var refusal: String?
    var body: some View {
        let state = player.snapshot
        let episode = podcasts?.playback.current.map { $0.videoID == state.videoID } ?? false
        if expanded {
            VStack(spacing: MusicSpace.xs) {
                if state.isLive { liveRow(state) }
                group(state, episode: episode, compactVolume: compact)
            }
        } else if compact { group(state, episode: episode, compactVolume: true) }
        else {
            // When the capsule is too narrow for the slider, the volume becomes a glyph with a popover.
            ViewThatFits(in: .horizontal) {
                group(state, episode: episode, compactVolume: false)
                group(state, episode: episode, compactVolume: true)
            }
        }
    }
    @ViewBuilder private func group(_ state: WebMusicSnapshot, episode: Bool, compactVolume: Bool) -> some View {
        let enabled = state.canControlQueue
        let edge = PlayerCapsule.glyphEdge(large: expanded)
        HStack(spacing: MusicSpace.hairline) {
            // Like and Dislike for the song that is playing, ahead of Shuffle and Repeat. Each says why when it is off.
            if let ratingShell {
                PlayingRatingButton(shell: ratingShell, kind: .like, edge: edge, identifier: "musicLike")
                PlayingRatingButton(shell: ratingShell, kind: .dislike, edge: edge, identifier: "musicDislike")
            }
            Button { Task { await player.setShuffle(!(state.shuffle ?? false)) } } label: { Label("Shuffle", systemImage: "shuffle") }
                .buttonStyle(.musicGlyph(on: state.shuffle == true, edge: edge)).disabled(!enabled || state.shuffle == nil)
                .help(Text("Shuffle")).accessibilityValue(Text(state.shuffle == true ? "On" : "Off")).accessibilityAddTraits(.isToggle).accessibilityIdentifier("musicShuffle")
            Button { if let mode = state.repeatMode { Task { await player.setRepeat(mode.next) } } } label: {
                Label { Self.repeatTitle(state.repeatMode) } icon: { Image(systemName: state.repeatMode == .one ? "repeat.1" : "repeat") }
            }.buttonStyle(.musicGlyph(on: state.repeatMode == .all || state.repeatMode == .one, edge: edge)).disabled(!enabled || state.repeatMode == nil)
                .help(Self.repeatTitle(state.repeatMode)).accessibilityIdentifier("musicRepeat")
                .contextMenu {
                    // The current mode carries the checkmark.
                    Picker("Repeat", selection: Binding(get: { state.repeatMode ?? .off }, set: { mode in Task { await player.setRepeat(mode) } })) {
                        ForEach(WebMusicRepeatMode.allCases, id: \.self) { mode in Self.repeatTitle(mode).tag(mode) }
                    }.pickerStyle(.inline).labelsHidden().disabled(!enabled || state.repeatMode == nil)
                }
            CapsuleVolume(level: state.volume, set: { level in Task { await player.setVolume(level) } }, label: "YouTube Music volume", identifier: "musicVolume", compact: compactVolume, large: expanded)
            // No output button here: the hidden player always follows the Mac's sound output, so a picker could only send a person to Control Center.
            // A route loss still reaches them through the Play here prompt; the owned-media capsule keeps its real picker.
            Button(action: showQueue) { Label("Queue", systemImage: "list.bullet") }
                .buttonStyle(.musicGlyph(edge: edge)).help(Text("Queue")).accessibilityIdentifier("transportQueue")
            // Share, beside Queue. The shell re-reads the playing song when this is pressed, so the link is the song's own (never its radio or queue) and is
            // never stale; an advertisement or a stopped player has no song to share, so the button stays in place, disabled.
            if let shareCurrentSong {
                Button { shareCurrentSong() } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.musicGlyph(edge: edge)).disabled(CurrentSongShare.item(for: player) == nil)
                    .help(Text("Share Current Song…")).accessibilityIdentifier("musicShare")
            }
            if !expanded, let playback { SleepTimerChip(model: playback, episode: episode, identifier: "musicSleepRemaining") }
            more(state, episode: episode, edge: edge)
        }
    }
    /// Keep translated live status clear of the fixed accessory controls, including in the 320 pt mini-player.
    private func liveRow(_ state: WebMusicSnapshot) -> some View {
        HStack(spacing: MusicSpace.xs) {
            MusicBadge("LIVE", style: .live(atEdge: state.atLiveEdge))
                .accessibilityLabel(Text(state.atLiveEdge ? "Live" : "Behind live")).accessibilityIdentifier("musicLiveBadge")
            Button { Task { await player.goLive() } } label: { Label("Go Live", systemImage: "dot.radiowaves.left.and.right") }
                .buttonStyle(.musicGlyph(edge: PlayerCapsule.glyphEdge(large: expanded))).disabled(!state.canGoLive)
                .help(Text("Jump to the live edge")).accessibilityIdentifier("musicGoLive")
        }
    }
    /// ⋯: what has no slot of its own: the sleep timer, the video window, Go Live and an episode's speed and jumps.
    private func more(_ state: WebMusicSnapshot, episode: Bool, edge: CGFloat) -> some View {
        Menu {
            ForEach(Self.moreItems(state: state, hasSleepTimer: playback != nil, canShowVideo: showVideo != nil, episode: episode, liveInline: expanded), id: \.self) { item in
                switch item {
                case .sleepTimer:
                    if let playback {
                        Menu { MusicSleepTimerItems(model: playback, episode: episode) { refusal = $0 } } label: {
                            Label("Sleep Timer", systemImage: playback.sleepTimerDisplay == nil ? "moon.zzz" : "moon.zzz.fill")
                        }.accessibilityIdentifier("musicSleepTimerMenu")
                    }
                case .showVideo:
                    if let showVideo { Button(action: showVideo) { Label("Show Video", systemImage: "play.rectangle") }.accessibilityIdentifier("musicShowVideo") }
                case .goLive:
                    Button { Task { await player.goLive() } } label: { Label("Go Live", systemImage: "dot.radiowaves.left.and.right") }
                        .disabled(!state.canGoLive).accessibilityIdentifier("musicGoLive")
                case .episodeControls:
                    if let podcasts {
                        Divider()
                        Button { Task { await podcasts.playback.skipBack() } } label: { Label("Back \(podcasts.playback.skip.back) seconds", systemImage: "gobackward.\(podcasts.playback.skip.back)") }
                            .accessibilityIdentifier("podcastSkipBack")
                        Button { Task { await podcasts.playback.skipForward() } } label: { Label("Forward \(podcasts.playback.skip.forward) seconds", systemImage: "goforward.\(podcasts.playback.skip.forward)") }
                            .accessibilityIdentifier("podcastSkipForward")
                        if let current = podcasts.playback.current {
                            PodcastRateMenu(playback: podcasts.playback, show: current.show, rate: podcasts.playback.rate(forShow: current.show), actual: player.confirmedRate)
                        }
                        PodcastSkipMenu(playback: podcasts.playback)
                    }
                }
            }
        } label: { MusicGlyphLabel(systemImage: "ellipsis", edge: edge).accessibilityLabel(Text("More")) }
            .buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(Text(refusal ?? String(localized: "More"))).accessibilityIdentifier("musicMore")
    }
    private static func repeatTitle(_ mode: WebMusicRepeatMode?) -> Text {
        switch mode {
        case .off?: Text("Repeat off")
        case .all?: Text("Repeat all")
        case .one?: Text("Repeat one")
        case nil: Text("Repeat")
        }
    }
}

/// Like or Dislike for the song that is playing, through the shell (`ratingAvailability`, `pressLike`): the bottom bar, the expanded player,
/// full-screen Now Playing and the mini-player all use this one button. A disabled button gives the actual reason as its help and its
/// accessibility hint. Pressing Dislike on the song that is playing moves on to the next song (`ShellCoordinator.pressLike`).
struct PlayingRatingButton: View {
    let shell: ShellCoordinator
    let kind: LibraryControl.Kind
    var edge: CGFloat = PlayerCapsule.glyphEdge
    let identifier: String
    var body: some View {
        let availability = shell.ratingAvailability(kind)
        let control = availability.control
        let reason = availability.reason ?? ""
        let fallback = kind == .dislike ? String(localized: "Dislike") : String(localized: "Like")
        Button { if let control { Task { await shell.pressLike(control) } } } label: {
            Label(control?.title ?? fallback, systemImage: control?.symbol ?? (kind == .dislike ? "hand.thumbsdown" : "heart"))
        }
        .buttonStyle(.musicGlyph(edge: edge)).labelStyle(.iconOnly).disabled(control == nil)
        .help(Text(control?.title ?? reason)).accessibilityHint(Text(reason))
        .accessibilityIdentifier(identifier)
    }
}

/// The seek of the YouTube Music capsule. It reads the clock itself (as `WebMusicTimelineView` does), so a position tick rebuilds only this layer.
struct WebCapsuleSeek: View {
    let player: WebMusicPlayer
    let state: MusicSeekState
    let compact: Bool
    let preview: SeekPreview
    @FocusState private var focused: Bool
    var body: some View {
        let snapshot = player.snapshot
        let position = player.timeline.position
        // A live stream has no duration: the slider spans the rewindable window, and the clock says how far behind live it is.
        let behind = player.timeline.behindLive
        let span = snapshot.isLive ? max(position + (behind ?? 0), 0.001) : max(snapshot.duration, 0.001)
        let shown = preview.value ?? min(position, span)
        MusicCapsuleSeekLayer(fraction: shown / span, state: state, enabled: snapshot.canSeek, compact: compact) {
            Slider(value: Binding(get: { shown }, set: { preview.value = $0 }), in: 0...span) {
                Text("Playback position")
            } onEditingChanged: { editing in
                if !editing, let target = preview.value { preview.value = nil; Task { await player.seek(target) } }
            }
            .disabled(!snapshot.canSeek).labelsHidden().focused($focused).onChange(of: focused) { _, value in preview.focused = value }
            .accessibilityLabel(Text("Playback position"))
            .accessibilityValue(Text(snapshot.isAd ? "Ad playing" : (snapshot.isLive ? (snapshot.atLiveEdge ? "Live" : "\(WebMusicTimelineView.format(behind ?? 0)) behind live") : "\(WebMusicTimelineView.format(position)) of \(WebMusicTimelineView.format(snapshot.duration))")))
            .accessibilityIdentifier("musicTimeline")
        }
    }
}

// MARK: Owned media

/// What the owned queue's menu shows as current: shuffled (a seed is set) and the repeat mode.
struct OwnedQueueModeState: Equatable {
    var shuffled: Bool
    var repeatMode: RepeatMode
    init(seed: UInt64?, repeatMode: RepeatMode) { shuffled = seed != nil; self.repeatMode = repeatMode }
    init(_ snapshot: PlaybackSessionSnapshot?) { self.init(seed: snapshot?.queue.session.shuffleSeed, repeatMode: snapshot?.queue.session.repeatMode ?? .off) }
}

/// Previous / Play-Pause / Next of the owned-media capsule or expanded player.
struct OwnedCapsuleButtons: View {
    @Bindable var model: PlaybackModel
    var compact = false
    var large = false
    var namespace: Namespace.ID? = nil
    var body: some View {
        let playing = model.state?.playback.intent == .play
        HStack(spacing: MusicSpace.xs) {
            Button { Task { await model.act(action: .previous) { try await $0.previous() } } } label: { Label("Previous", systemImage: "backward.end.fill") }
                .buttonStyle(.musicGlyph(edge: PlayerCapsule.glyphEdge(large: large))).help(Text("Previous")).accessibilityIdentifier("transportPrevious")
            Button { Task { await model.nativePlayPause() } } label: {
                Label(LocalizedStringKey(playing ? "Pause" : "Play"), systemImage: playing ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace))
            }.buttonStyle(.musicPlay(edge: PlayerCapsule.playEdge(compact: compact, large: large))).accessibilityIdentifier("transportPlayPause").musicAnimation(.playPause, value: model.state?.playback.intent)
            Button { Task { await model.act(action: .next) { try await $0.next() } } } label: { Label("Next", systemImage: "forward.end.fill") }
                .buttonStyle(.musicGlyph(edge: PlayerCapsule.glyphEdge(large: large))).help(Text("Next")).accessibilityIdentifier("transportNext")
        }.disabled(model.session == nil).playerMatched("player-controls", namespace, .position)
    }
}

/// The owned capsule's centre group (see `WebCapsuleTransport`).
struct OwnedCapsuleTransport: View {
    @Bindable var model: PlaybackModel
    var compact = false
    var namespace: Namespace.ID? = nil
    let showsTimes: Bool
    let preview: SeekPreview
    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            OwnedCapsuleTime(model: model, elapsed: true, visible: showsTimes, compact: compact, preview: preview)
                .audit("playerElapsed", group: "playerTimes", kind: .layer, within: "playerBar")
            OwnedCapsuleButtons(model: model, compact: compact, namespace: namespace).audit("playerButtons", group: "playerButtons", kind: .layer, within: "playerBar")
            OwnedCapsuleTime(model: model, elapsed: false, visible: showsTimes, compact: compact, preview: preview)
                .audit("playerRemaining", group: "playerTimes", kind: .layer, within: "playerBar")
        }.offset(y: -PlayerCapsule.transportLift)
    }
}

struct OwnedCapsuleTime: View {
    @Bindable var model: PlaybackModel
    let elapsed: Bool
    let visible: Bool
    let compact: Bool
    let preview: SeekPreview
    var body: some View {
        let position = model.timeline.displayedPosition
        let text: String = elapsed
            ? (position == nil && preview.value == nil ? "–:––" : WebMusicTimelineView.format(preview.value ?? position ?? 0))
            : WebMusicTimelineView.format(model.timeline.snapshot?.media?.duration ?? 0)
        MusicTimeSlot(text, visible: visible, slot: PlayerCapsule.timeSlot(compact: compact), leadingSide: elapsed)
            .accessibilityIdentifier(elapsed ? "transportElapsed" : "transportDuration")
    }
}

/// Volume (with mute), Output, Queue, the sleep timer's chip and ⋯ of the owned-media capsule or expanded player (the trailing group).
struct OwnedCapsuleSecondary: View {
    @Bindable var model: PlaybackModel
    var compact = false
    var expanded = false
    var showQueue: () -> Void = {}
    var body: some View {
        if compact || expanded { group(compactVolume: compact) }
        else {
            ViewThatFits(in: .horizontal) {
                group(compactVolume: false)
                group(compactVolume: true)
            }
        }
    }
    @ViewBuilder private func group(compactVolume: Bool) -> some View {
        let volume = model.volumeSlider
        let muted = model.state?.muted == true
        let edge = PlayerCapsule.glyphEdge(large: expanded)
        HStack(spacing: MusicSpace.hairline) {
            CapsuleVolume(level: volume.level, range: volume.range, set: { model.setSliderVolume($0) }, muted: muted,
                          label: LocalizedStringKey(volume.isReceiver ? "Receiver volume" : "App volume"), identifier: "appVolume",
                          enabled: model.session != nil && volume.isEnabled, compact: compactVolume, large: expanded, help: volume.disabledReason ?? "",
                          mute: (title: LocalizedStringKey(muted ? "Unmute" : "Mute"), identifier: "transportMute", disabled: model.session == nil,
                                 action: { Task { await model.act(action: .mute) { try await $0.setMuted(!muted) } } }))
            if let outputs = model.outputs { if outputs.offersPicker { OutputPickerHost(controller: outputs).buttonStyle(.musicGlyph(edge: edge)) } }
            else { RoutePicker(current: model.state?.media?.route ?? String(localized: "System output")).labelStyle(.iconOnly).buttonStyle(.musicGlyph(edge: edge)) }
            Button(action: showQueue) { Label("Queue", systemImage: "list.bullet") }
                .buttonStyle(.musicGlyph(edge: edge)).help(Text("Queue")).accessibilityIdentifier("transportQueue")
            if !expanded { SleepTimerChip(model: model, identifier: "sleepRemaining") }
            // Keep secondary actions together, leaving the three transport buttons centered.
            Menu {
                if let state = model.state {
                    // The quality line used to sit under the bar; it is a menu item now.
                    Text("Source: \(state.media?.codec ?? String(localized: "Unknown")) · \(state.media?.bitrate.map { "\($0) bit/s" } ?? String(localized: "Unknown bitrate")) · \(state.media?.sampleRate.map { "\(Int($0)) Hz" } ?? String(localized: "Unknown sample rate")) · \(state.media?.route ?? String(localized: "Unknown output"))")
                        .accessibilityIdentifier("playbackQuality")
                    Divider()
                }
                OwnedMoreActions(model: model)
            } label: { MusicGlyphLabel(systemImage: "ellipsis", edge: edge).accessibilityLabel(Text("More playback actions")) }
                .buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(model.session == nil).help(Text("More playback actions")).accessibilityIdentifier("sleepTimerMenu")
        }
    }
}

/// The seek of the owned-media capsule.
struct OwnedCapsuleSeek: View {
    @Bindable var model: PlaybackModel
    let state: MusicSeekState
    let compact: Bool
    let preview: SeekPreview
    @FocusState private var focused: Bool
    var body: some View {
        let snapshot = model.timeline.snapshot
        let duration = max(1, snapshot?.media?.duration ?? 1)
        let position = model.timeline.displayedPosition
        let shown = preview.value ?? min(position ?? 0, duration)
        let seekable = PlaybackTimeline.seekEnabled(hasCurrent: snapshot?.queue.current != nil, media: snapshot?.media)
        MusicCapsuleSeekLayer(fraction: shown / duration, state: state, enabled: seekable, compact: compact) {
            Slider(value: Binding(get: { shown }, set: { preview.value = $0 }), in: 0...duration) { Text("Playback position") } onEditingChanged: { editing in
                if !editing, let target = preview.value { preview.value = nil; Task { await model.act(action: .seek) { try await $0.seek(target) } } }
            }.labelsHidden().focused($focused).onChange(of: focused) { _, value in preview.focused = value }
                .disabled(!seekable).accessibilityIdentifier("transportTimeline")
        }
    }
}
