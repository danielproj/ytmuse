import AppKit
import AccountSession
import DesignSystem
import Features
import Playback
import SwiftUI

/// The Library destination for a signed-in account: its library playlists (the
/// signed read the app already performs, M2), each with a native Play action
/// through YouTube Music's own player. The window's collection query and filter
/// apply locally; nothing here is development or fixture data.
struct MusicLibraryList: View {
    let accounts: AccountsModel
    @Bindable var playback: PlaybackModel
    let query: String
    let downloadedOnly: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            HStack {
                Text("Your playlists").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if accounts.proofLoading { ProgressView().controlSize(.small).accessibilityLabel(Text("Loading library")) }
            }
            content
        }
        .task { if accounts.proof == .none { await accounts.loadProof() } }
    }
    @ViewBuilder private var content: some View {
        switch accounts.proof {
        case .signedIn(let proof):
            let playlists = proof.library.playlists.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
            if downloadedOnly {
                EmptyState(title: "No downloaded playlists", message: "YouTube Music playlists in your library are streamed, not retained on this Mac.")
            } else if proof.library.playlists.isEmpty {
                EmptyState(title: "No playlists in your library yet", message: "Playlists you save in YouTube Music appear here.")
            } else if playlists.isEmpty {
                EmptyState(title: "No matching playlists", message: "No playlist title in your library matches this search.")
            } else {
                LazyVStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    ForEach(playlists) { playlist in
                        HStack {
                            MediaRow(title: playlist.title, subtitle: playlist.countText ?? String(localized: "YouTube Music playlist"), pending: playback.starting) { play(playlist) }
                                .accessibilityLabel(Text("Play \(playlist.title)"))
                                .accessibilityIdentifier("playPlaylist-" + playlist.id)
                        }.id(playlist.id)
                    }
                }
                if !proof.library.complete {
                    Text("Showing the first page of your library.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                }
            }
        case .expired:
            ErrorState(title: "Session expired", message: "Sign in again to play your library.", recovery: "Retry") { Task { await accounts.loadProof() } }
        case .unrecognised, .failed:
            ErrorState(title: "Your library could not be read", message: "Nothing was changed. Try reading your library again.", recovery: "Retry") { Task { await accounts.loadProof() } }
        case .none:
            if !accounts.proofLoading {
                Button("Show Library") { Task { await accounts.loadProof() } }.accessibilityIdentifier("showLibrary").musicButtons()
            }
        }
    }
    private func play(_ playlist: MusicLibraryPlaylist) {
        // The permit is captured at the click, so an account barrier in between rejects it.
        let request = playback.authority.requestOwnedStart()
        Task { await playback.playMusic(playlistID: playlist.id, title: playlist.title, request: request) }
    }
}

/// YouTube Music content of the shared W09 `TransportBar`: artwork, title, artist,
/// transport, seek with elapsed/remaining time, buffering/error states and an
/// honest Ad badge. Seeking and skipping are refused while an ad plays.
///
/// This body reads only the coarse `player.snapshot`, which the player republishes
/// when something other than the clock changes. Elapsed/remaining/progress live in
/// `WebMusicTimelineView`, so a position tick rebuilds that one row (PERF08/WIN10).
struct WebMusicTransportContent: View {
    let player: WebMusicPlayer
    var compact = false
    var showNowPlaying: () -> Void = {}
    var showQueue: () -> Void = {}
    /// Opens the native video window for a music video or live stream (nil when the caller offers none).
    var showVideo: (() -> Void)? = nil
    /// The artwork's light for the player's glass; nil while there is no artwork.
    var accentChanged: (MusicTint?) -> Void = { _ in }
    /// Shared with the expanded player (Now Playing): artwork, title, artist and controls keep their identity across the morph.
    var namespace: Namespace.ID? = nil
    /// W22: the output coordinator, for the output picker and the Play here prompt.
    var outputs: OutputController? = nil
    /// P17-WEB: the playback owner, for the sleep timer's menu and its remaining-time line.
    var playback: PlaybackModel? = nil
    @State private var image: NSImage?
    @State private var artworkDecode = ArtworkDemandDriver()
    @State private var accentSequence = AccentSequencer()
    var body: some View {
        let state = player.snapshot
        HStack(spacing: MusicSpace.md) {
            Button(action: showNowPlaying) { artwork.frame(width: compact ? 40 : 52, height: compact ? 40 : 52).playerMatched("current-artwork", namespace) }
                .buttonStyle(.musicTile(.playerInset, edge: compact ? 40 : 52)).accessibilityLabel(Text("Show Now Playing")).help(Text("Show Now Playing"))
                .audit("playerArtwork", group: "playerRow", within: "playerBar")
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                HStack(spacing: MusicSpace.xs) {
                    Text(state.title ?? state.playlistTitle ?? "YouTube Music").font(.headline).lineLimit(1)
                        .accessibilityIdentifier("musicTitle").playerMatched("player-title", namespace, .position)
                    if state.isAd {
                        MusicBadge("Ad", style: .advertisement)
                            .accessibilityLabel(Text("Advertisement playing")).accessibilityIdentifier("musicAdBadge")
                    }
                }
                Text(state.artist ?? status(state)).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1)
                    .accessibilityIdentifier("musicArtist").playerMatched("player-artist", namespace, .position)
            }.frame(minWidth: 112, maxWidth: 240, alignment: .leading).audit("playerTitle", group: "playerRow", within: "playerBar")
            Spacer(minLength: 0)
            WebMusicControlsView(player: player, namespace: namespace).audit("playerControls", group: "playerRow", within: "playerBar")
            Spacer(minLength: 0)
            WebMusicAccessories(player: player, compact: compact, showVideo: showVideo, showQueue: showQueue, outputs: outputs, playback: playback).audit("playerAccessories", group: "playerRow", within: "playerBar")
        }.audit("playerRow", group: "playerBar", within: "playerBar")
            .announcesTransport(state)
        WebMusicTimelineView(player: player).audit("playerTimeline", group: "playerBar", within: "playerBar")
        if let playback { SleepTimerLine(model: playback, episode: playback.playingEpisode(playback.episodes), identifier: "musicSleepRemaining") }
        if let outputs { OutputPromptHost(controller: outputs) }
        if case .failed(let failure) = state.phase {
            Text(failure.message).font(.caption).accessibilityIdentifier("musicFailure")
        } else if let notice = state.notice {
            Text(notice.message).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("musicNotice")
        } else if let refusal = player.refusal {
            Text(refusal.message).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("musicRefusal")
        }
    }
    /// Decoded once per artwork change, not on every position update.
    private var artwork: some View {
        // W09-F1b: applied from the body, not `.task(id:)` (see `ArtworkDemandDriver`).
        artworkDecode.apply(player.artwork) {
            let decoded = player.artwork.flatMap(NSImage.init(data:))
            image = decoded
            accentSequence.publish(player.artwork) { accentChanged($0) }
        }
        return Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
            }
        }.musicClip(.playerInset, edge: compact ? 40 : 52).accessibilityHidden(true)
            .musicAnimation(.artworkColor, value: image != nil)
            .onAppear { artworkDecode.resume() }.onDisappear { artworkDecode.suspend() }
    }
    private func status(_ state: WebMusicSnapshot) -> String {
        switch state.phase {
        case .idle: String(localized: "Not playing")
        case .loading: String(localized: "Starting YouTube Music…")
        case .buffering: String(localized: "Buffering…")
        case .playing: String(localized: "Playing")
        case .paused: String(localized: "Paused")
        case .ended: String(localized: "Ended")
        case .failed: String(localized: "Stopped")
        }
    }
}

/// The elapsed/remaining/progress row of the YouTube Music transport, isolated so the
/// clock is the only thing a position tick invalidates. It reads `player.timeline`
/// (coalesced to whole seconds, silent while the window is hidden) plus the coarse
/// snapshot fields that decide whether seeking is possible.
struct WebMusicTimelineView: View {
    let player: WebMusicPlayer
    @State private var preview: Double?
    var body: some View {
        let state = player.snapshot
        let position = player.timeline.position
        // A live stream has no duration: the slider spans the rewindable window, and the clock says how far behind live it is.
        let behind = player.timeline.behindLive
        let span = state.isLive ? max(position + (behind ?? 0), 0.001) : max(state.duration, 0.001)
        HStack {
            Text(state.isAd ? "Ad" : (state.isLive ? (state.atLiveEdge ? String(localized: "Live") : Self.format(behind ?? 0)) : Self.format(preview ?? position))).monospacedDigit().frame(minWidth: 36)
                .accessibilityIdentifier("musicElapsed")
            Slider(value: Binding(get: { preview ?? min(position, span) }, set: { preview = $0 }), in: 0...span) {
                Text("Playback position")
            } onEditingChanged: { editing in
                if !editing, let target = preview { preview = nil; Task { await player.seek(target) } }
            }
            .disabled(!state.canSeek).labelsHidden().tint(MusicStyle.accent)
            .accessibilityLabel(Text("Playback position"))
            .accessibilityValue(Text(state.isAd ? "Ad playing" : (state.isLive ? (state.atLiveEdge ? "Live" : "\(Self.format(behind ?? 0)) behind live") : "\(Self.format(position)) of \(Self.format(state.duration))")))
            .accessibilityIdentifier("musicTimeline")
            Text(state.isAd || state.isLive ? "" : "-" + Self.format(max(0, state.duration - (preview ?? position)))).monospacedDigit().frame(minWidth: 40)
                .accessibilityIdentifier("musicRemaining")
        }.font(.caption).foregroundStyle(MusicStyle.secondaryText)
    }
    static func format(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0)); return String(format: "%d:%02d", value / 60, value % 60)
    }
}

/// Previous / Play-Pause / Next of the YouTube Music transport. One definition for the bar and the expanded player, so the controls keep their
/// identifiers and their identity across the morph; only one of the two exists at a time.
struct WebMusicControlsView: View {
    let player: WebMusicPlayer
    var large = false
    var namespace: Namespace.ID? = nil
    var body: some View {
        let state = player.snapshot
        HStack(spacing: MusicSpace.xs) {
            Button { Task { await player.previous() } } label: { Label("Previous", systemImage: "backward.end.fill") }
                .disabled(!state.canSkip).accessibilityIdentifier("musicPrevious")
            Button { Task { await player.playPause() } } label: {
                if state.phase == .loading || state.phase == .buffering {
                    ProgressView().controlSize(.small).accessibilityLabel(Text(state.intent ? "Loading, Pause" : "Play"))
                } else {
                    Label(state.intent ? "Pause" : "Play", systemImage: state.intent ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
            }.disabled(state.phase == .idle).musicButtons(prominent: true).tint(MusicStyle.accentFill).buttonBorderShape(.circle).accessibilityIdentifier("musicPlayPause")
                .musicAnimation(.playPause, value: state.intent)
            Button { Task { await player.next() } } label: { Label("Next", systemImage: "forward.end.fill") }
                .disabled(!state.canSkip).accessibilityIdentifier("musicNext")
        }.labelStyle(.iconOnly).musicButtons().controlSize(large ? .large : .regular).playerMatched("player-controls", namespace, .position)
    }
}

extension View {
    /// Gives a player element its identity in the shared namespace (nil outside the shell: no identity).
    @ViewBuilder func playerMatched(_ id: String, _ namespace: Namespace.ID?, _ properties: MatchedGeometryProperties = .frame) -> some View {
        if let namespace { musicMatched(id, in: namespace, properties: properties) } else { self }
    }
}

/// Live state, video, volume and queue of the YouTube Music transport: one definition for the bar and the expanded player.
struct WebMusicAccessories: View {
    @Environment(\.podcastsSurface) private var podcasts
    let player: WebMusicPlayer
    var compact = false
    var showVideo: (() -> Void)? = nil
    var showQueue: () -> Void = {}
    var outputs: OutputController? = nil
    /// P17-WEB: when given, the sleep-timer menu is offered (the playback owner sets the timer; this view never talks to the page).
    var playback: PlaybackModel? = nil
    var body: some View {
        let state = player.snapshot
            HStack(spacing: MusicSpace.xs) {
                if state.isLive {
                    MusicBadge("LIVE", style: .live(atEdge: state.atLiveEdge))
                        .accessibilityLabel(Text(state.atLiveEdge ? "Live" : "Behind live")).accessibilityIdentifier("musicLiveBadge")
                    Button { Task { await player.goLive() } } label: { Label("Go Live", systemImage: "dot.radiowaves.left.and.right") }.labelStyle(.iconOnly)
                        .disabled(!state.canGoLive).help(Text("Jump to the live edge")).accessibilityIdentifier("musicGoLive")
                }
                if let showVideo, state.hasPicture {
                    Button(action: showVideo) { Label("Show Video", systemImage: "play.rectangle") }.labelStyle(.iconOnly).help(Text("Show the video in its own window"))
                        .accessibilityIdentifier("musicShowVideo")
                }
                // Speed and the jump buttons, only while the item that plays is an episode.
                if let podcasts, let episode = podcasts.playback.current, episode.videoID == state.videoID {
                    PodcastTransportControls(playback: podcasts.playback, rate: podcasts.playback.rate(forShow: episode.show), actual: player.confirmedRate)
                }
                Slider(value: Binding(get: { state.volume }, set: { level in Task { await player.setVolume(level) } }), in: 0...1) {
                    Text("YouTube Music volume")
                }.labelsHidden().tint(MusicStyle.accent).frame(width: compact ? 64 : 100).accessibilityLabel(Text("YouTube Music volume")).accessibilityIdentifier("musicVolume")
                if let outputs { OutputPickerHost(controller: outputs).labelStyle(.iconOnly) }
                if let playback { MusicSleepTimerMenu(model: playback, episode: podcasts?.playback.current.map { $0.videoID == state.videoID } ?? false) }
                Button(action: showQueue) { Label("Queue", systemImage: "list.bullet") }.labelStyle(.iconOnly).help(Text("Queue")).accessibilityIdentifier("transportQueue")
        }.musicButtons()
    }
}
