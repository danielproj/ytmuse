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
            HStack {
                Button { editing = true } label: { Label("Edit Playlist", systemImage: "pencil") }.musicAction(.secondary).accessibilityIdentifier("playlistEdit")
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
                HStack {
                    Button { surface.creator.reset(); creating = true } label: { Label("New Playlist", systemImage: "plus") }.musicAction(.primary).accessibilityIdentifier("playlistNew")
                    JoinPlaylistEntry(navigator: navigator)
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
            Button { adding = true } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }.musicAction(.secondary).accessibilityIdentifier("songAddToPlaylist")
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
            Button { surface.joiner.reset(); joining = true } label: { Label("Join Playlist…", systemImage: "person.2") }.musicAction(.secondary).accessibilityIdentifier("playlistJoinOpen")
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
            Button("Add to Playlist…") { adding = true }.musicAction(.secondary).accessibilityIdentifier("libraryAddToPlaylist")
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

/// Only concrete songs/videos can enter the direct chooser. Collection ids are never addition targets.
enum DirectPlaylistAddition {
    static func candidate(_ item: MusicCatalogItem) -> PlaylistAddition? {
        guard item.kind == .song || item.kind == .video, item.availability != .unavailable else { return nil }
        return song(videoID: item.videoID, title: item.title)
    }
    static func candidate(_ result: SearchResult) -> PlaylistAddition? {
        guard result.kind == .song || result.kind == .video else { return nil }
        return song(videoID: result.target.videoID, title: result.title)
    }
    static func offered(_ candidate: PlaylistAddition?, playback: SearchPlayback?) -> PlaylistAddition? {
        playback == .available ? candidate : nil
    }
    private static func song(videoID: String?, title: String) -> PlaylistAddition? {
        guard let videoID, MusicPlaylistRequest.isVideoID(videoID) else { return nil }
        return PlaylistAddition(videoID: videoID, title: title)
    }
}

/// Captured when a native action is constructed, checked both at press and presentation.
@MainActor struct DirectPlaylistScope: Equatable {
    let identity: ObjectIdentifier
    let generation: UInt64
    init(_ surface: PlaylistSurface) { identity = ObjectIdentifier(surface); generation = surface.accountGeneration }
    func admits(_ song: PlaylistAddition, current: PlaylistAddition?, surface: PlaylistSurface?) -> Bool {
        guard let surface, surface.isSignedIn else { return false }
        return self == DirectPlaylistScope(surface) && song == current
    }
}

private struct DirectPlaylistSelection: Identifiable {
    let id = UUID()
    let song: PlaylistAddition
    let scope: DirectPlaylistScope
}

/// State and sheet belong to the row/card modifier, outside the native menu's transient subtree.
/// Selecting the entry snapshots the song and opens only the existing chooser; all writes remain in its staged flow.
private struct DirectPlaylistMenu<Menu: View>: ViewModifier {
    let addition: PlaylistAddition?
    let identifier: String
    @ViewBuilder let menu: () -> Menu
    @Environment(\.playlistSurface) private var surface
    @State private var pending: DirectPlaylistSelection?
    private var offered: PlaylistAddition? { DirectPlaylistAddition.offered(addition, playback: surface?.playback) }
    func body(content: Content) -> some View {
        content
            .contextMenu {
                menu()
                if let offered, let surface { entry(offered, scope: DirectPlaylistScope(surface)) }
            }
            .accessibilityActions { if let offered, let surface { entry(offered, scope: DirectPlaylistScope(surface)) } }
            .sheet(item: $pending) { selection in
                if selection.scope.admits(selection.song, current: offered, surface: surface), let surface { PlaylistAddView(surface: surface, song: selection.song) }
            }
            .onChange(of: addition) { _, _ in pending = nil }
            .onChange(of: surface.map(ObjectIdentifier.init)) { _, _ in pending = nil }
            .onChange(of: surface?.accountGeneration) { _, _ in pending = nil }
            .onChange(of: offered) { _, new in if new == nil { pending = nil } }
    }
    private func entry(_ song: PlaylistAddition, scope: DirectPlaylistScope) -> some View {
        Button {
            guard scope.admits(song, current: offered, surface: surface) else { return }
            pending = DirectPlaylistSelection(song: song, scope: scope)
        } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
            .accessibilityLabel(Text(verbatim: String(localized: "Add to Playlist…") + " “\(song.title)”"))
            .accessibilityIdentifier(identifier)
    }
}

extension View {
    func directPlaylistMenu<Menu: View>(addition: PlaylistAddition?, identifier: String, @ViewBuilder menu: @escaping () -> Menu) -> some View {
        modifier(DirectPlaylistMenu(addition: addition, identifier: identifier, menu: menu))
    }
}
