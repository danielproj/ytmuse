import AccountSession
import DesignSystem
import SwiftUI

/// "Edit Playlist" on a playlist's page. Offered only to a signed-in account and only when the service's own header for this page is the
/// editable one (`MusicPageHeader.editing`); a playlist it does not let the person change shows nothing here.
struct PlaylistEditEntry: View {
    let model: CatalogPageModel
    let header: MusicPageHeader
    let navigator: CatalogNavigator
    @Environment(\.playlistSurface) private var surface
    @State private var editing = false
    var body: some View {
        let id = MusicPlaylistRequest.playlistID(fromBrowseID: model.target.browseID)
        if let surface, surface.isSignedIn, model.target.browseID.hasPrefix("VL"), header.editing?.canEditTracks == true, MusicPlaylistRequest.isEditablePlaylistID(id) {
            MusicGlassGroup {
                HStack {
                    Button { editing = true } label: { Label("Edit Playlist", systemImage: "pencil") }.musicButtons().accessibilityIdentifier("playlistEdit")
                }
            }
            .sheet(isPresented: $editing, onDismiss: { Task { await model.refresh() } }) {
                PlaylistEditorView(session: surface.session(for: id), surface: surface, onDeleted: { navigator.openTarget(.home, String(localized: "Home")) })
            }
        }
    }
}

/// "New Playlist" above the Library's Playlists collection. It opens the form; nothing is created until Create is pressed there.
struct NewPlaylistEntry: View {
    let navigator: CatalogNavigator
    @Environment(\.playlistSurface) private var surface
    @State private var creating = false
    var body: some View {
        if let surface, surface.isSignedIn {
            HStack {
                MusicGlassGroup {
                    HStack {
                        Button { surface.creator.reset(); creating = true } label: { Label("New Playlist", systemImage: "plus") }.musicButtons().accessibilityIdentifier("playlistNew")
                        JoinPlaylistEntry(navigator: navigator)
                    }
                }
                Spacer()
            }
            .sheet(isPresented: $creating) {
                PlaylistCreateView(creator: surface.creator) { id in navigator.openTarget(CatalogTarget(browseID: "VL" + id), String(localized: "Playlist")) }
            }
        }
    }
}

/// "Add to Playlist…" on a song's page. The song's own id comes from the page; the playlist is picked, read and checked in the sheet.
struct SongAddToPlaylistEntry: View {
    let item: MusicCatalogItem
    @Environment(\.playlistSurface) private var surface
    @State private var adding = false
    var body: some View {
        if let surface, surface.isSignedIn, let video = item.videoID, item.kind == .song || item.kind == .video, MusicPlaylistRequest.isVideoID(video) {
            Button { adding = true } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }.musicButtons().accessibilityIdentifier("songAddToPlaylist")
                .sheet(isPresented: $adding) { PlaylistAddView(surface: surface, song: PlaylistAddition(videoID: video, title: item.title)) }
        }
    }
}

/// "Join Playlist…" next to New Playlist: opens the form that reads a pasted invite link. Nothing is joined until Join is confirmed.
struct JoinPlaylistEntry: View {
    let navigator: CatalogNavigator
    @Environment(\.playlistSurface) private var surface
    @State private var joining = false
    var body: some View {
        if let surface, surface.isSignedIn {
            MusicGlassGroup {
                Button { surface.joiner.reset(); joining = true } label: { Label("Join Playlist…", systemImage: "person.2") }.musicButtons().accessibilityIdentifier("playlistJoinOpen")
            }
            .sheet(isPresented: $joining) {
                PlaylistJoinView(joiner: surface.joiner) { id in navigator.openTarget(CatalogTarget(browseID: "VL" + id), String(localized: "Playlist")) }
            }
        }
    }
}

/// "Add to Playlist…" for the songs selected in a Library collection (up to 50). It opens the same sheet as a single song: the playlist is
/// read, the person's rights come from the page, and the add goes through the naming confirmation.
struct SelectionAddToPlaylistEntry: View {
    let items: [MusicCatalogItem]
    @Environment(\.playlistSurface) private var surface
    @State private var adding = false
    private var songs: [PlaylistAddition] {
        Array(items.compactMap { item -> PlaylistAddition? in
            guard item.kind == .song || item.kind == .video, let video = item.videoID, MusicPlaylistRequest.isVideoID(video) else { return nil }
            return PlaylistAddition(videoID: video, title: item.title)
        }.prefix(MusicPlaylistRequest.maximumActions))
    }
    var body: some View {
        if let surface, surface.isSignedIn, !songs.isEmpty {
            Button("Add to Playlist…") { adding = true }.musicButtons().accessibilityIdentifier("libraryAddToPlaylist")
                .sheet(isPresented: $adding) { PlaylistAddView(surface: surface, songs: songs) }
        }
    }
}

private struct PendingDrop: Identifiable { let id = UUID(); let songs: [PlaylistAddition]; let playlist: PlaylistListing }

/// Makes a view a place songs can be dropped on to add them to one playlist. A drop only opens the add sheet for that playlist (read,
/// permitted by its page, confirmed); nothing is sent by the drop.
struct PlaylistDropTarget: ViewModifier {
    let playlistID: String
    let title: String
    @Environment(\.playlistSurface) private var surface
    @State private var pending: PendingDrop?
    func body(content: Content) -> some View {
        if let surface, surface.isSignedIn, MusicPlaylistRequest.isEditablePlaylistID(MusicPlaylistRequest.playlistID(fromBrowseID: playlistID)) {
            content
                .dropDestination(for: PlaylistDraggedSong.self) { dropped, _ in
                    let songs = PlaylistDraggedSong.additions(from: dropped)
                    guard !songs.isEmpty else { return false }
                    pending = PendingDrop(songs: songs, playlist: PlaylistListing(playlistID: MusicPlaylistRequest.playlistID(fromBrowseID: playlistID), title: title)); return true
                }
                .sheet(item: $pending) { PlaylistAddView(surface: surface, songs: $0.songs, preselected: $0.playlist) }
        } else { content }
    }
}
extension View {
    func playlistDropTarget(playlistID: String, title: String) -> some View { modifier(PlaylistDropTarget(playlistID: playlistID, title: title)) }
}

/// A playlist page whose own header is editable is a drop target for songs; any other page is not.
struct PlaylistPageDrop: ViewModifier {
    let model: CatalogPageModel
    func body(content: Content) -> some View {
        if model.target.browseID.hasPrefix("VL"), model.header?.editing?.canEditTracks == true {
            content.playlistDropTarget(playlistID: model.target.browseID, title: model.header?.title ?? "")
        } else { content }
    }
}
