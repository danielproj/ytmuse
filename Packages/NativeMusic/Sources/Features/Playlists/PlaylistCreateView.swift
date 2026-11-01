import AccountSession
import DesignSystem
import SwiftUI

/// The New Playlist form. The visibility starts at the creator's default (private), and nothing is sent until Create is pressed.
public struct PlaylistCreateView: View {
    @Bindable var creator: PlaylistCreator
    /// Songs the new playlist starts with (a saved queue), at most 50; empty for a plain new playlist.
    let songs: [PlaylistAddition]
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var privacy: MusicPlaylistPrivacy

    public init(creator: PlaylistCreator, songs: [PlaylistAddition] = [], open: @escaping (String) -> Void) { self.creator = creator; self.songs = Array(songs.prefix(MusicPlaylistRequest.maximumActions)); self.open = open; _privacy = State(initialValue: creator.startingVisibility()) }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text(songs.isEmpty ? "New Playlist" : "Save Queue as Playlist").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if !songs.isEmpty { Text("\(songs.count) songs from the queue").font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistCreateSongs") }
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("playlistCreateTitle")
            TextField("Description (optional)", text: $details, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3).accessibilityIdentifier("playlistCreateDescription")
            Picker("Visibility", selection: $privacy) {
                ForEach(MusicPlaylistPrivacy.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }.accessibilityIdentifier("playlistCreatePrivacy")
            Text(creator.startingVisibility() == PlaylistCreator.defaultPrivacy ? LocalizedStringKey("New playlists are private unless you choose otherwise.") : LocalizedStringKey("New playlists start with the visibility chosen in Settings. You can change it here.")).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistCreateNote")
            status
            HStack {
                Spacer()
                MusicGlassGroup {
                    HStack {
                        Button("Close") { creator.reset(); dismiss() }.musicButtons().keyboardShortcut(.cancelAction).accessibilityIdentifier("playlistCreateClose")
                        Button("Create") { Task { await creator.create(title: title, description: details, privacy: privacy, songs: songs) } }
                            .musicButtons(prominent: true).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || creator.state == .creating || isCreated || creator.state == .needsReconciliation)
                            .accessibilityIdentifier("playlistCreateButton")
                    }
                }
            }
        }
        .padding(MusicSpace.lg).frame(minWidth: 460)
        .accessibilityElement(children: .contain).accessibilityIdentifier("playlistCreate")
    }
    private var isCreated: Bool { if case .created = creator.state { true } else { false } }
    @ViewBuilder private var status: some View {
        switch creator.state {
        case .idle: EmptyView()
        case .creating:
            HStack(spacing: MusicSpace.xs) { ProgressView().controlSize(.small); Text("Creating the playlist…").font(.caption) }.accessibilityIdentifier("playlistCreating")
        case .created(let id):
            HStack {
                Label("Created “\(title)” as \(privacy.title.lowercased()).", systemImage: "checkmark.circle").accessibilityIdentifier("playlistCreated")
                Button("Open") { open(id); dismiss() }.musicButtons().accessibilityIdentifier("playlistCreatedOpen")
            }
        case .failed(let failure):
            HStack {
                Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("playlistCreateFailed")
                if failure != .invalid && failure != .needsSignIn && failure != .sessionEnded { Button("Try Again") { Task { await creator.create(title: title, description: details, privacy: privacy, songs: songs) } }.musicButtons() }
            }
        case .needsReconciliation:
            HStack {
                Label("YouTube Music didn’t confirm the new playlist. It may or may not exist.", systemImage: "questionmark.circle").font(.caption).accessibilityIdentifier("playlistCreateUnconfirmed")
                Button("Check") { Task { await creator.check() } }.musicButtons().accessibilityIdentifier("playlistCreateCheck")
            }
        case .ambiguous(let options):
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Text("More than one new playlist has this title. Which one is yours?").font(.caption)
                ForEach(options, id: \.playlistID) { option in
                    Button(option.title + " · " + option.playlistID) { creator.choose(option.playlistID) }.musicButtons()
                }
            }
        }
    }
}
