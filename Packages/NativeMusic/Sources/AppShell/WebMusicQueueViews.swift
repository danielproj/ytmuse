import AppKit
import DesignSystem
import Features
import Playback
import SwiftUI

/// Artwork of the YouTube Music item that is playing, decoded once per artwork change.
struct WebMusicArtworkView: View {
    let player: WebMusicPlayer
    let edge: CGFloat
    /// W21: false while the window showing this is hidden, minimized, covered or the display is off: no image is decoded until it shows again.
    var visible = true
    var corner: MusicCorner = .thumbnail
    var accentChanged: (MusicTint?) -> Void = { _ in }
    /// Shared with the bar's artwork (same identity, `current-artwork`) so the cover travels between the mini-player and Now Playing.
    var namespace: Namespace.ID? = nil
    @State private var image: NSImage?
    @State private var artworkDecode = ArtworkDemandDriver()
    @State private var accentSequence = AccentSequencer()
    var body: some View {
        artworkDecode.hold(!visible)
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
        }.frame(width: edge, height: edge).musicClip(corner).playerMatched("current-artwork", namespace).accessibilityHidden(true)
            .musicAnimation(.artworkColor, value: image != nil)
            .onAppear { artworkDecode.resume() }.onDisappear { artworkDecode.suspend() }
    }
}

/// What the Queue and Now Playing surfaces can truthfully say about YouTube Music playback:
/// the item the page reports and the playlist it was started from. There is deliberately no
/// list of upcoming items, because the page does not report one and the app does not invent it.
struct WebMusicQueueSummary: Equatable {
    var title: String
    var artist: String?
    var playlist: String?
    var isAd: Bool
    /// YouTube Music owns the upcoming items; this is shown instead of an invented list.
    static let managedByYouTubeMusic = String(localized: "YouTube Music manages the upcoming items for this playlist, so they are not listed or editable here.")
    init(_ state: WebMusicSnapshot) {
        title = state.title ?? state.playlistTitle ?? "YouTube Music"
        artist = state.artist; isAd = state.isAd
        playlist = state.playlistTitle
    }
    /// True while the hidden player is the active source and has something to describe.
    @MainActor static func isActive(_ player: WebMusicPlayer?) -> Bool {
        guard let player else { return false }
        return !player.isClosed && player.snapshot.phase != .idle
    }
}

/// The Queue panel while YouTube Music plays. YouTube Music owns this queue: the page
/// reports the item that is playing and the playlist it was started from, and nothing
/// else, so only those are shown, plus an honest statement that the rest is managed
/// by YouTube Music. No upcoming item is invented, and no reorder/remove control is
/// offered for a queue the app cannot edit.
struct WebMusicQueueView: View {
    let player: WebMusicPlayer
    var body: some View {
        let summary = WebMusicQueueSummary(player.snapshot)
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            Text("Playing from YouTube Music").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            HStack(spacing: MusicSpace.sm) {
                WebMusicArtworkView(player: player, edge: 48)
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    HStack(spacing: MusicSpace.xs) {
                        Text(summary.title).font(.headline).lineLimit(2)
                            .accessibilityIdentifier("musicQueueCurrentTitle")
                        if summary.isAd {
                            MusicBadge("Ad", style: .advertisement)
                                .accessibilityLabel(Text("Advertisement playing"))
                        }
                    }
                    if let artist = summary.artist { Text(artist).font(.subheadline).foregroundStyle(MusicStyle.secondaryText).lineLimit(1) }
                }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("musicQueueCurrent")
            if let playlist = summary.playlist {
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    Text("Playlist").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                    Text(playlist).font(.body).lineLimit(2)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("musicQueuePlaylist")
            }
            Text(LocalizedStringKey(WebMusicQueueSummary.managedByYouTubeMusic))
                .font(.callout).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("musicQueueManaged")
            Spacer(minLength: 0)
        }.padding(MusicSpace.md).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The Now Playing destination while YouTube Music plays: the real artwork, title,
/// artist and Ad state the page reports, not the owned pipeline's placeholder.
struct WebMusicNowPlayingView: View {
    let player: WebMusicPlayer
    var showVideoWindow: () -> Void = {}
    var windowOpen: () -> Bool = { false }
    /// The expanded player's identity namespace, and the cover's edge (the expanded surface sizes it to the room it has).
    var namespace: Namespace.ID? = nil
    var artworkEdge: CGFloat = 280
    /// The widest a video picture may be (the full-screen Now Playing window allows more than the page does).
    var pictureWidth: CGFloat = 560
    /// False while the window showing this is hidden, minimized, covered or its display is off: the cover decodes nothing until it shows again (W21).
    var visible = true
    /// Publishes the cover's light to whoever holds the player's tint (the shell), alongside the local hero elevation.
    var accentChanged: (MusicTint?) -> Void = { _ in }
    @State private var accent: MusicTint?
    var body: some View {
        let state = player.snapshot
        VStack(spacing: MusicSpace.md) {
            // A music video or live stream shows the hidden player's own picture in a native preview; a song shows its artwork.
            if state.hasPicture {
                WebVideoPreview(player: player, showWindow: showVideoWindow, windowOpen: windowOpen, maxWidth: pictureWidth)
                WebVideoControls(player: player, window: nil)
            } else {
                WebMusicArtworkView(player: player, edge: artworkEdge, visible: visible, corner: .feature, accentChanged: { accent = $0; accentChanged($0) }, namespace: namespace).accessibilityHidden(false).accessibilityLabel(Text("Now Playing artwork"))
                    .accessibilityIdentifier("expandedArtwork").musicElevation(.hero, tint: accent?.color)
                    .audit("nowPlayingArtwork", group: "nowPlaying", within: "nowPlayingHero")
                // Rework F8: a song with a published video version can go back to the video (switching is not one-way).
                if state.counterpartRepresentation == .video, !state.isAd {
                    Button { Task { await player.selectVideo() } } label: { Label("Show Video Version", systemImage: "play.rectangle") }
                        .musicButtons().accessibilityIdentifier("songShowVideo")
                }
                if let notice = player.videoNotice {
                    Text(notice).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("videoNotice")
                }
            }
            HStack(spacing: MusicSpace.xs) {
                Text(state.title ?? state.playlistTitle ?? "YouTube Music").font(.title).accessibilityIdentifier("musicNowPlayingTitle").playerMatched("player-title", namespace, .position)
                if state.isAd {
                    MusicBadge("Ad", style: .advertisement)
                        .accessibilityLabel(Text("Advertisement playing"))
                }
            }
            if let artist = state.artist { Text(artist).font(.title3).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("musicNowPlayingArtist").playerMatched("player-artist", namespace, .position) }
            if let playlist = state.playlistTitle, playlist != state.title { Text(playlist).font(.callout).foregroundStyle(MusicStyle.secondaryText) }
        }
        .padding(.vertical, MusicSpace.lg).frame(maxWidth: .infinity)
        .musicAnimation(.reveal, value: state.isAd)
        .audit("nowPlayingHero", group: "nowPlaying", kind: .layer)
    }
}
