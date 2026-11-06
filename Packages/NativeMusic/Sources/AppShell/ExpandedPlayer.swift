import SwiftUI
import AppKit
import DesignSystem
import Features
import Playback
import Domain
import Artwork

/// Now Playing as the mini-player grown into a panel (GLASS11). It is hosted in the same window hierarchy and the same `MusicGlassGroup` as the
/// bottom player bar, with the same glass identity (`player-surface`), so the glass SHAPE morphs from one to the other and back, and the artwork,
/// title, artist and controls keep their identity (matched geometry) through it. Only one of the two exists at a time, so every control keeps its
/// accessibility identifier. It is a presentation of the same playback owner: the same player methods, the C1 snapshot for state and the separate
/// clock row for position, and nothing is drawn over a video picture (the picture, with its own controls, sits in the hero; ads are shown, never covered).
struct ExpandedPlayer<Trailing: View>: View {
    @Bindable var model: PlaybackModel
    var artwork: ArtworkPipeline?
    var artworkRequest: ArtworkRequest?
    var artworkAuthority: ArtworkUIAuthority
    var paletteChanged: ((ArtworkPalette?, ArtworkTintIdentity?) -> Void)?
    /// The player's artwork light, held once at the shell (the YouTube Music cover's, or the window artwork's for owned media) and handed to the bar and to
    /// this surface alike, so the glass tint does not drop out when one becomes the other.
    var accent: MusicTint?
    /// The cover shown here publishes its light to the shell too (the bar is not on screen to do it).
    var accentChanged: (MusicTint?) -> Void = { _ in }
    let namespace: Namespace.ID
    var windowVisible: Bool
    let collapse: () -> Void
    let showQueue: () -> Void
    let compact: Bool
    /// The widest a video picture may be in the hero (W21: the full-screen window gives it more room).
    var pictureWidth: CGFloat = 560
    var headerActions: () -> AnyView = { AnyView(EmptyView()) }
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tint = accent
        HStack(spacing: MusicSpace.sm) {
            main
            trailing()
        }
        .padding(MusicSpace.sm)
        .background { ExpandedLight(tint: tint) }
        // The surface's glass tint and the one radial light each take half of the solved wash (they sit over the same pixels).
        .musicSurface(.player, tint: tint?.glassColor(scheme: scheme, share: ExpandedLight.share), morph: MusicMorph("player-surface", in: namespace))
        .musicElevation(.floating)
        .audit("playerExpanded", group: "outer", kind: .layer)
        #if DEBUG
        .onChange(of: tint, initial: true) { _, value in PlayerTintProbe.record("expanded", for: model, value) }
        #endif
    }

    private var main: some View {
        mainColumn.audit("nowPlayingMain", group: "expandedRow", within: "playerExpanded")
    }
    private var mainColumn: some View {
        VStack(spacing: MusicSpace.sm) {
            header
            GeometryReader { room in
                // The hero scrolls only when the window is too short for it; otherwise it is plain content (no scroll view between the controls and the person).
                ViewThatFits(in: .vertical) {
                    hero(edge: Self.artworkEdge(forHeight: room.size.height)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView { hero(edge: Self.artworkEdge(forHeight: room.size.height)).frame(maxWidth: .infinity) }
                }
            }
            controls.frame(maxWidth: pictureWidth > 560 ? 640 : 480).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The YouTube Music cover takes the room it is given: up to its established 280 pt, never so large that the title and artist fall off a 560 pt window.
    /// The owned/native cover stays at its settled 240 pt (the W09 contract measures it).
    static func artworkEdge(forHeight height: CGFloat) -> CGFloat { min(280, max(96, ((height - 132) / MusicSpace.grid).rounded(.down) * MusicSpace.grid)) }

    private var header: some View {
        HStack {
            Button(action: collapse) { Label("Collapse Now Playing", systemImage: "chevron.down") }
                .labelStyle(.iconOnly).buttonStyle(.musicGlyph).help(Text("Collapse Now Playing")).accessibilityIdentifier("collapseNowPlaying")
                .keyboardShortcut(.cancelAction)
            Spacer()
            headerActions()
            // The owned session's state, as the bar says it (one `playbackState` element exists at a time: the bar's, or this one).
            if model.music == nil, let state = model.state {
                Text(LocalizedStringKey(model.pending ? "Working…" : state.playback.state.rawValue)).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playbackState")
            }
        }.audit("nowPlayingHeader", group: "expandedColumn", within: "playerExpanded")
    }

    @ViewBuilder private func hero(edge: CGFloat) -> some View {
        if let player = model.music, WebMusicQueueSummary.isActive(player) {
            WebMusicNowPlayingView(player: player, showVideoWindow: { model.showVideoWindow() }, windowOpen: { model.webVideoWindows.isOpen }, namespace: namespace, artworkEdge: edge, pictureWidth: pictureWidth, visible: windowVisible, accentChanged: accentChanged)
                .audit("nowPlayingHero", group: "expandedColumn", kind: .layer)
        } else if model.nativeVideo.hasPicture {
            VStack(spacing: MusicSpace.md) {
                NativeVideoPanel(model: model)
                Text(model.currentTitle).font(.title).playerMatched("player-title", namespace, .position)
            }.audit("nowPlayingHero", group: "expandedColumn", kind: .layer)
        } else {
            VStack(spacing: MusicSpace.md) {
                CurrentArtwork(pipeline: artwork, request: artworkRequest, authority: artworkAuthority, namespace: namespace, expanded: true, isExpandedDestination: true,
                               visible: windowVisible, expandedEdge: 240, paletteChanged: paletteChanged)
                    .musicClip(.artwork).musicElevation(.hero, tint: accent?.color)
                    .accessibilityElement(children: .ignore).accessibilityLabel(Text("Now Playing artwork")).accessibilityHidden(false).accessibilityIdentifier("expandedArtwork")
                    .audit("nowPlayingArtwork", group: "expandedColumn", within: "playerExpanded")
                Text(model.currentTitle).font(.title2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2).accessibilityIdentifier("currentMediaTitle").playerMatched("player-title", namespace, .position)
            }.padding(.vertical, MusicSpace.md).audit("nowPlayingHero", group: "expandedColumn", kind: .layer)
        }
    }

    /// Position, the transport and its accessories: the same views the bar uses, so they keep their identifiers and read the same snapshot and clock.
    @ViewBuilder private var controls: some View {
        if let player = model.music, WebMusicQueueSummary.isActive(player) {
            VStack(spacing: MusicSpace.xs) {
                WebMusicTimelineView(player: player, plain: true).audit("nowPlayingTimeline", group: "expandedColumn", within: "playerExpanded")
                transportRow {
                    WebMusicControlsView(player: player, large: true, namespace: namespace, plain: true)
                } accessories: {
                    WebCapsuleSecondary(player: player, compact: compact, expanded: true, showVideo: nil, showQueue: showQueue, outputs: model.outputs, playback: model)
                }
                SleepTimerLine(model: model, episode: model.playingEpisode(model.episodes), identifier: "nowPlayingSleepRemaining")
            }
        } else {
            VStack(spacing: MusicSpace.xs) {
                PlaybackTimeline(model: model.timeline, seek: { target in Task { await model.act(action: .seek) { try await $0.seek(target) } } }, plain: true)
                    .audit("nowPlayingTimeline", group: "expandedColumn", within: "playerExpanded")
                transportRow {
                    OwnedCapsuleButtons(model: model, large: true, namespace: namespace)
                } accessories: {
                    OwnedCapsuleSecondary(model: model, compact: compact, expanded: true, showQueue: showQueue)
                }
                SleepTimerLine(model: model, identifier: "nowPlayingSleepRemaining")
            }
        }
    }

    /// Separate, centered rows keep the play circle on the same axis as the artwork at every width.
    private func transportRow<Controls: View, Accessories: View>(@ViewBuilder _ controls: () -> Controls, @ViewBuilder accessories: () -> Accessories) -> some View {
        VStack(spacing: MusicSpace.sm) {
            controls().fixedSize().frame(maxWidth: .infinity)
                .audit("nowPlayingControls", group: "expandedColumn", within: "playerExpanded")
            accessories().frame(maxWidth: .infinity)
                .audit("nowPlayingAccessories", group: "expandedColumn", within: "playerExpanded")
        }
    }
}

/// The ONE light layer of the expanded player: a soft radial wash from the top, a fraction (`share`) of the solved wash because the surface's glass tint sits
/// over the same pixels. Static, no loop; off when transparency is reduced or contrast increased. Nothing inside the player draws a second one (the
/// hero's own light was removed in rework 3): the audit counts `lightLayer` tags on the expanded player, and one is the limit.
struct ExpandedLight: View {
    static let share = 0.5
    let tint: MusicTint?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Group {
            if let tint, !reduceTransparency, contrast != .increased {
                MusicCorner.player.shape.fill(RadialGradient(colors: [tint.glassColor(scheme: scheme, share: Self.share), .clear], center: .top, startRadius: 0, endRadius: 480))
                    .allowsHitTesting(false).accessibilityHidden(true).musicTransition(.reveal)
            }
        }
        .audit("lightLayer", group: "light", kind: .layer)
    }
}
