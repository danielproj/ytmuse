import AccountSession
import DesignSystem
import SwiftUI

/// "Save Queue as Playlist…" on the Queue. It saves only songs the app actually knows as YouTube Music items (their video ids, from pages
/// it read); anything else in the queue is left out and counted. When YouTube Music's own player holds the queue, its upcoming items are
/// YouTube's and not visible to the app, so there is nothing honest to save and the reason is shown instead of a button.
public struct QueueSaveAsPlaylistEntry: View {
    let surface: PlaylistSurface?
    let songs: [PlaylistAddition]
    let leftOut: Int
    /// Why saving is not possible right now, or nil when it is.
    let unavailableReason: String?
    @State private var saving = false
    /// One queue entry as far as this feature needs to know it.
    public struct Entry: Sendable {
        public let media: String
        public let consumed: Bool
        public let isAdvertisement: Bool
        public init(media: String, consumed: Bool, isAdvertisement: Bool) { self.media = media; self.consumed = consumed; self.isAdvertisement = isAdvertisement }
    }
    /// The songs of a queue the app knows as YouTube Music items (their video id came from a page it read), in queue order, at most 50;
    /// every other live entry (owned audio, anything unknown) is counted as left out. Consumed entries and advertisements are neither.
    public static func songs(from entries: [Entry], known: (String) -> MusicCatalogItem?) -> (songs: [PlaylistAddition], leftOut: Int) {
        var songs: [PlaylistAddition] = [], leftOut = 0
        for entry in entries where !entry.consumed && !entry.isAdvertisement {
            if let item = known(entry.media), item.kind == .song || item.kind == .video, let video = item.videoID, MusicPlaylistRequest.isVideoID(video) {
                songs.append(PlaylistAddition(videoID: video, title: item.title))
            } else { leftOut += 1 }
        }
        if songs.count > MusicPlaylistRequest.maximumActions { leftOut += songs.count - MusicPlaylistRequest.maximumActions; songs = Array(songs.prefix(MusicPlaylistRequest.maximumActions)) }
        return (songs, leftOut)
    }
    public init(surface: PlaylistSurface?, songs: [PlaylistAddition], leftOut: Int, unavailableReason: String?) {
        self.surface = surface; self.songs = songs; self.leftOut = leftOut; self.unavailableReason = unavailableReason
    }
    public var body: some View {
        if let surface, surface.isSignedIn {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                if let unavailableReason {
                    Label(unavailableReason, systemImage: "info.circle").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("queueSaveUnavailable")
                } else if songs.isEmpty {
                    Label("No song in this queue is a YouTube Music song this app knows, so there is nothing to save as a playlist.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("queueSaveNothing")
                } else {
                    MusicGlassGroup {
                        Button("Save Queue as Playlist…") { surface.creator.reset(); saving = true }.musicButtons().accessibilityIdentifier("queueSaveAsPlaylist")
                    }
                    if leftOut > 0 { Text("\(leftOut) items that aren’t YouTube Music songs are left out.").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("queueSaveLeftOut") }
                }
            }
            .sheet(isPresented: $saving) { PlaylistCreateView(creator: surface.creator, songs: songs) { _ in } }
        }
    }
}
