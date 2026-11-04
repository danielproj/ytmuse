import AppKit
import ImageIO
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
            let data = player.artwork
            let decoded = await WebCoverMemo.shared.decoded(data)
            guard !Task.isCancelled else { return }
            image = decoded
            accentSequence.publish(data) { accentChanged($0) }
        }
        return Group {
            // POL-A: a view that replaces another paints the held decode of the same bytes in its first frame (no flash of the default note).
            if let shown = WebCoverMemo.shared.displayed(for: player.artwork, current: image) {
                Image(nsImage: shown).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
            }
        }.frame(width: edge, height: edge).musicClip(corner).playerMatched("current-artwork", namespace).accessibilityHidden(true)
            .musicAnimation(.artworkColor, value: image != nil)
            .onAppear { artworkDecode.resume() }.onDisappear { artworkDecode.suspend() }
    }
}

/// What the Queue and Now Playing surfaces can truthfully say about YouTube Music playback: the item the page reports, the playlist it was started
/// from and, when the page's own queue can be read, the items it lists after the playing one. Nothing is invented: a page whose queue cannot be
/// read leaves `upcoming` unlisted (`isListed` false) and the surface says only that YouTube Music manages the queue.
struct WebMusicQueueSummary: Equatable {
    var title: String
    var artist: String?
    var playlist: String?
    var isAd: Bool
    /// CORE-A: the page's own queue after the playing item, in the page's order; empty both when the page lists nothing after this item and when it lists no queue at all (`isListed`).
    var upcoming: [WebMusicQueueItem]
    /// True when the page listed a queue for the playing item (an empty `upcoming` then means nothing follows it).
    var isListed: Bool
    /// True when the page lists further items beyond the bounded window shown.
    var hasMore: Bool
    /// YouTube Music owns the queue; the items are shown but cannot be reordered or removed here.
    static let managedByYouTubeMusic = String(localized: "YouTube Music manages the upcoming items, so they can’t be reordered or removed here.")
    init(_ state: WebMusicSnapshot) {
        title = state.title ?? state.playlistTitle ?? "YouTube Music"
        artist = state.artist; isAd = state.isAd
        playlist = state.playlistTitle
        upcoming = state.queue?.upcoming ?? []; isListed = state.queue != nil; hasMore = (state.queue?.more ?? 0) > 0
    }
    /// True while the hidden player is the active source and has something to describe.
    @MainActor static func isActive(_ player: WebMusicPlayer?) -> Bool {
        guard let player else { return false }
        return !player.isClosed && player.snapshot.phase != .idle
    }
}

/// The Queue panel while YouTube Music plays. YouTube Music owns this queue: the page reports the item that is playing, the playlist it was started
/// from and (read only) the items it lists after it. Those are shown as the page lists them, and an item can be played; no reorder/remove control is
/// offered for a queue the app cannot edit, and a page whose queue cannot be read shows no list at all.
struct WebMusicQueueView: View {
    let player: WebMusicPlayer
    var body: some View {
        let summary = WebMusicQueueSummary(player.snapshot)
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            Text("Playing from YouTube Music").font(MusicPageStyle.section).accessibilityAddTraits(.isHeader)
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
            }.padding(MusicSpace.sm).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface().accessibilityElement(children: .combine).accessibilityIdentifier("musicQueueCurrent")
            if let playlist = summary.playlist {
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    Text("Playlist").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                    Text(playlist).font(.body).lineLimit(2)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("musicQueuePlaylist")
            }
            if summary.isListed { upNext(summary) }
            Text(LocalizedStringKey(WebMusicQueueSummary.managedByYouTubeMusic))
                .font(.callout).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("musicQueueManaged")
            Spacer(minLength: 0)
        }.padding(MusicSpace.md).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    /// The page's own list after the playing item. An item is a button that asks the page to play it; during an ad it is off (it would end the ad early).
    @ViewBuilder private func upNext(_ summary: WebMusicQueueSummary) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text("Up next").font(.headline).accessibilityAddTraits(.isHeader).accessibilityIdentifier("musicQueueUpNextHeader")
            if summary.upcoming.isEmpty {
                Text("Nothing else is queued after this item.").font(.callout).foregroundStyle(MusicStyle.secondaryText)
                    .accessibilityIdentifier("musicQueueEmpty")
            } else {
                LazyVStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    ForEach(Array(summary.upcoming.enumerated()), id: \.element.id) { offset, item in
                        WebMusicQueueRow(player: player, item: item, index: offset, enabled: !summary.isAd)
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("musicQueueUpNext")
                if summary.hasMore {
                    Text("More items follow; YouTube Music lists only the next few.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                        .accessibilityIdentifier("musicQueueMore")
                }
            }
        }
    }
}

/// One upcoming item: artwork, title and artist exactly as the page lists them. Playing it hands the page its own queue item.
struct WebMusicQueueRow: View {
    let player: WebMusicPlayer
    let item: WebMusicQueueItem
    let index: Int
    let enabled: Bool
    var body: some View {
        let title = item.title ?? "YouTube Music"
        Button { Task { await player.playQueueItem(item.videoID) } } label: {
            HStack(spacing: MusicSpace.sm) {
                WebMusicQueueArtwork(url: item.artworkURL, edge: 36)
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    Text(verbatim: title).font(.body).lineLimit(1)
                    if let artist = item.artist { Text(verbatim: artist).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).musicPageRow().disabled(!enabled)
            .accessibilityLabel(Text("Play \(title)"))
            .accessibilityIdentifier("musicQueueItem-\(index)")
    }
}

/// Decodes a queue row's cover off the main actor (the loader already bounded it to 512 px); the main actor only wraps the result.
enum WebMusicQueueImageDecoder {
    struct Decoded: @unchecked Sendable { let image: CGImage }
    nonisolated static func decode(_ data: Data) async -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) >= 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Decoded(image: image)
    }
}

/// A queue row's cover: fetched from YouTube's image hosts only (the same bounded, credential-free loader the player uses), remembered per address.
struct WebMusicQueueArtwork: View {
    let url: URL?
    let edge: CGFloat
    @State private var image: NSImage?
    private static let cache = NSCache<NSURL, NSImage>()
    private static let loader = WebMusicArtworkLoader()
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.body).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
            }
        }.frame(width: edge, height: edge).musicClip(.thumbnail).accessibilityHidden(true)
            .task(id: url) {
                guard let url else { image = nil; return }
                if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
                image = nil
                guard let data = await Self.loader.artwork(url), let bitmap = await WebMusicQueueImageDecoder.decode(data), !Task.isCancelled else { return }
                let decoded = NSImage(cgImage: bitmap.image, size: NSSize(width: bitmap.image.width, height: bitmap.image.height))
                Self.cache.setObject(decoded, forKey: url as NSURL)
                image = decoded
            }
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
                Text(state.title ?? state.playlistTitle ?? "YouTube Music").font(.title2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2).accessibilityIdentifier("musicNowPlayingTitle").playerMatched("player-title", namespace, .position)
                if state.isAd {
                    MusicBadge("Ad", style: .advertisement)
                        .accessibilityLabel(Text("Advertisement playing"))
                }
            }
            if let artist = state.artist { Text(artist).font(.callout).lineLimit(1).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("musicNowPlayingArtist").playerMatched("player-artist", namespace, .position) }
            if let playlist = state.playlistTitle, playlist != state.title { Text(playlist).font(.caption).lineLimit(1).foregroundStyle(MusicStyle.secondaryText) }
        }
        .padding(.vertical, MusicSpace.sm).frame(maxWidth: .infinity)
        .musicAnimation(.reveal, value: state.isAd)
        .audit("nowPlayingHero", group: "nowPlaying", kind: .layer)
    }
}
