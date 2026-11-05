import AppKit
import Artwork
import DesignSystem
import Features
import Playback
import SwiftUI

// W21 rework 2. The shell's player surfaces are V02's, composed: the cover is `WebMusicArtworkView` / `CurrentArtwork` (its decode, its accent), the
// transport is `WebMusicControlsView` / `OwnedControlsView` (Previous, Next and seek are off in an advertisement through the same snapshot rules), the
// position is `WebMusicTimelineView` / `PlaybackTimeline`, the expanded surface is `ExpandedPlayer` itself, the Ad pill is `MusicBadge`, and every
// space, corner, surface and animation is a design token. What W21 adds is the window around them and the controls only a shell surface has.

/// What a shell surface needs of the app's artwork (the same pipeline, request and authority the browser window hands its own player).
@MainActor struct ShellArtworkContext {
    var pipeline: ArtworkPipeline?
    var request: ArtworkRequest?
    var authority = ArtworkUIAuthority()
}

/// The cover of whatever plays, through V02's views: the YouTube Music cover while the hidden player is the source, the window artwork for owned media.
struct ShellCover: View {
    let shell: ShellCoordinator
    let edge: CGFloat
    var visible = true
    var accentChanged: (MusicTint?) -> Void = { _ in }
    var paletteChanged: ((ArtworkPalette?, ArtworkTintIdentity?) -> Void)? = nil
    var body: some View {
        if let player = shell.playback.music, WebMusicQueueSummary.isActive(player) {
            WebMusicArtworkView(player: player, edge: edge, visible: visible, corner: .playerInset, accentChanged: accentChanged)
        } else {
            let context = shell.artworkContext()
            CurrentArtwork(pipeline: context.pipeline, request: context.request, authority: context.authority, namespace: nil, expanded: false, isExpandedDestination: false,
                           visible: visible, compactEdge: edge, paletteChanged: paletteChanged)
                .musicClip(.playerInset, edge: edge)
        }
    }
}

/// Previous / Play-Pause / Next for whichever engine is the source: V02's own control views, so an advertisement disables Previous and Next exactly
/// as the bar does, and every command is the owner's.
struct ShellControls: View {
    let shell: ShellCoordinator
    var large = false
    var showMore = true
    var body: some View {
        if let player = shell.playback.music, WebMusicQueueSummary.isActive(player) { WebMusicControlsView(player: player, large: large, plain: true) }
        else if showMore { OwnedControlsView(model: shell.playback, large: large, plain: true) }
        else { OwnedCapsuleButtons(model: shell.playback, large: large) }
    }
}

/// The position row for whichever engine is the source (the C1 clock for YouTube Music; the session's timeline for owned media).
struct ShellTimeline: View {
    let shell: ShellCoordinator
    var body: some View {
        if let player = shell.playback.music, WebMusicQueueSummary.isActive(player) { WebMusicTimelineView(player: player, plain: true) }
        else if shell.transport.source == .owned {
            PlaybackTimeline(model: shell.playback.timeline, seek: { target in Task { await shell.playback.act(action: .seek) { try await $0.seek(target) } } }, plain: true)
        }
    }
}

/// V02's expanded player hosted in a shell window (the mini-player's expanded mode and the full-screen Now Playing): the same glass container, namespace
/// and tint plumbing the browser window gives it, with the window's visibility feeding the playback owner's observation.
struct ShellExpandedPlayer<Trailing: View>: View {
    let shell: ShellCoordinator
    let collapse: () -> Void
    var showQueue: () -> Void
    var pictureWidth: CGFloat = 560
    var compact = true
    var headerActions: () -> AnyView = { AnyView(EmptyView()) }
    @ViewBuilder var trailing: () -> Trailing
    @Namespace private var namespace
    @State private var tint = WindowArtworkTint()
    @State private var webAccent: MusicTint?
    @State private var windowVisible = false
    var body: some View {
        let context = shell.artworkContext()
        let artworkLight = tint.displayed(for: context.request, authority: context.authority).map { MusicTint(red: $0.red, green: $0.green, blue: $0.blue) }
        MusicGlassGroup(spacing: MusicSpace.xs) {
            ExpandedPlayer(model: shell.playback, artwork: context.pipeline, artworkRequest: context.request, artworkAuthority: context.authority,
                           paletteChanged: { tint.receive($0, source: $1, current: context.request.map(ArtworkTintIdentity.init), authority: context.authority) },
                           accent: shell.playback.music != nil ? webAccent : artworkLight, accentChanged: { webAccent = $0 }, namespace: namespace,
                           windowVisible: windowVisible, collapse: collapse, showQueue: showQueue, compact: compact, pictureWidth: pictureWidth, headerActions: headerActions, trailing: trailing)
        }
        .background(WindowVisibility { value in windowVisible = value; if !value { tint.retract() } })
        .modifier(PlaybackObservation(model: shell.playback))
        .environment(\.shareCurrentSong, { [shell] in shell.shareCurrentSong() })
    }
}
