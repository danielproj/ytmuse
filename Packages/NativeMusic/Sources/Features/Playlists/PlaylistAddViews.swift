import AccountSession
import DesignSystem
import SwiftUI

/// How a confirmation lists a selection: the first names, and how many more.
enum PlaylistPromptText {
    static func names(_ prompt: PlaylistPrompt) -> String {
        var text = prompt.shownNames.map { "• " + $0 }.joined(separator: "\n")
        if prompt.hiddenCount > 0 { text += "\n" + String(localized: "And \(prompt.hiddenCount) more.") }
        return text
    }
}

/// The question before songs are added: the naming confirmation for several songs, and Keep duplicates / Skip existing when the playlist
/// already holds one of them. It sends nothing itself; the buttons are the person's answer.
struct PlaylistStagedAddDialog: ViewModifier {
    @Bindable var session: PlaylistEditSession
    @Binding var staged: PlaylistStagedAdd?
    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(get: { staged != nil }, set: { if !$0 { staged = nil } }), titleVisibility: .visible, presenting: staged) { add in
            if add.hasDuplicates {
                Button("Keep Duplicates") { confirm(add, .keepDuplicates) }
                Button("Skip Existing") { confirm(add, .skipExisting) }
            } else if add.songs.count == 1 {
                Button("Add") { confirm(add, .skipExisting) }
            } else {
                Button(String(localized: "Add \(add.songs.count) Songs")) { confirm(add, .skipExisting) }
            }
            Button("Cancel", role: .cancel) { staged = nil }
        } message: { add in Text(message(add)) }
    }
    private var title: String {
        guard let add = staged else { return "" }
        if add.hasDuplicates { return add.songs.count == 1 ? String(localized: "This song is already in the playlist") : String(localized: "Some of these songs are already in the playlist") }
        let playlist = session.snapshot?.title ?? ""
        if add.songs.count == 1, let song = add.songs.first { return String(localized: "Add “\(song.title)” to “\(playlist)”?") }
        return String(localized: "Add \(add.songs.count) songs to “\(playlist)”?")
    }
    private func message(_ add: PlaylistStagedAdd) -> String {
        if add.songs.count == 1, let name = add.duplicateTitles.first {
            return String(localized: "“\(name)” is already here. Keep Duplicates adds it again as a separate entry; Skip Existing leaves it out.")
        }
        if add.songs.count == 1 && !add.hasDuplicates { return String(localized: "It is added only if you press Add.") }
        var text = PlaylistPromptText.names(add.prompt ?? PlaylistPrompt(action: .add, playlistTitle: "", count: add.songs.count, names: add.songs.map(\.title)))
        if add.hasDuplicates { text += "\n\n" + String(localized: "Already here: \(add.duplicateTitles.joined(separator: ", ")). Keep Duplicates adds them again; Skip Existing leaves them out.") }
        return text
    }
    private func confirm(_ add: PlaylistStagedAdd, _ mode: MusicPlaylistDuplicateMode) {
        staged = nil
        Task { await session.confirmAdd(add, mode: mode) }
    }
}

/// Add one or several songs to one of the person's playlists. The playlist is read first; if the service does not let this person change
/// it, nothing can be sent. Several songs, and songs the playlist already holds, go through the same naming confirmation and Keep
/// duplicates / Skip existing choice as everywhere else. A preselected playlist (a drop on a playlist) skips only the picking.
public struct PlaylistAddView: View {
    let surface: PlaylistSurface
    let songs: [PlaylistAddition]
    let preselected: PlaylistListing?
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [PlaylistListing]?
    @State private var failure: String?
    @State private var chosen: PlaylistEditSession?
    @State private var chosenTitle = ""
    @State private var staged: PlaylistStagedAdd?

    public init(surface: PlaylistSurface, songs: [PlaylistAddition], preselected: PlaylistListing? = nil) { self.surface = surface; self.songs = songs; self.preselected = preselected }
    public init(surface: PlaylistSurface, song: PlaylistAddition) { self.init(surface: surface, songs: [song]) }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text("Add to Playlist").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(songs.count == 1 ? "“\(songs[0].title)”" : String(localized: "\(songs.count) songs")).font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistAddSongs")
            if let chosen { destination(chosen) } else { picker }
            MusicGlassGroup {
                HStack { Spacer(); Button("Close") { dismiss() }.musicButtons().keyboardShortcut(.cancelAction).accessibilityIdentifier("playlistAddClose") }
            }
        }
        .padding(MusicSpace.lg).frame(minWidth: 460, minHeight: 280)
        .accessibilityElement(children: .contain).accessibilityIdentifier("playlistAdd")
        .task { if let preselected { await choose(preselected) } else { await loadChoices() } }
    }
    @ViewBuilder private var picker: some View {
        if let failure { Label(failure, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("playlistAddFailed") }
        else if let choices {
            if choices.isEmpty { Text("You have no playlists yet.").foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistAddNone") }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                        ForEach(choices, id: \.playlistID) { option in
                            Button(option.title) { Task { await choose(option) } }.buttonStyle(.plain).padding(.vertical, MusicSpace.xxs).accessibilityIdentifier("playlistAddChoice-" + option.playlistID)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else { ProgressView().accessibilityIdentifier("playlistAddLoading") }
    }
    @ViewBuilder private func destination(_ session: PlaylistEditSession) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text(chosenTitle).font(.headline)
            switch session.loadState {
            case .idle, .loading: ProgressView().accessibilityIdentifier("playlistAddReading")
            case .failed(let failure): Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("playlistAddReadFailed")
            case .loaded:
                if !session.role.canEdit {
                    Label("YouTube Music doesn’t let you change this playlist.", systemImage: "lock").accessibilityIdentifier("playlistAddNotPermitted")
                } else {
                    MusicGlassGroup {
                        Button { Task { staged = await session.addSongs(songs) } } label: { Text(songs.count == 1 ? "Add to “\(chosenTitle)”" : String(localized: "Add \(songs.count) Songs to “\(chosenTitle)”")) }
                            .musicButtons(prominent: true).disabled(session.isBusy).accessibilityIdentifier("playlistAddButton")
                    }
                }
                PlaylistOperationLines(session: session)
            }
        }
        .modifier(PlaylistStagedAddDialog(session: session, staged: $staged))
    }
    private func loadChoices() async {
        do { choices = try await surface.playlistChoices() } catch { failure = PlaylistEditSession.failure(for: error, reading: true).message }
    }
    private func choose(_ option: PlaylistListing) async {
        let session = surface.session(for: option.playlistID)
        chosenTitle = option.title; chosen = session
        await session.load()
    }
}

/// Join a collaborative playlist from a pasted invite link. The link is only read; Join asks first, naming the playlist.
public struct PlaylistJoinView: View {
    @Bindable var joiner: PlaylistJoiner
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var confirming = false
    public init(joiner: PlaylistJoiner, open: @escaping (String) -> Void) { self.joiner = joiner; self.open = open }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text("Join a Collaborative Playlist").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            TextField("Paste an invite link", text: $link).textFieldStyle(.roundedBorder).accessibilityIdentifier("playlistJoinLink")
            Text("The link is only read to name the playlist. You join only if you press Join and confirm.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
            status
            MusicGlassGroup {
                HStack {
                    Spacer()
                    Button("Close") { joiner.reset(); dismiss() }.musicButtons().keyboardShortcut(.cancelAction).accessibilityIdentifier("playlistJoinClose")
                    Button("Look Up") { Task { await joiner.prepare(link: link) } }.musicButtons()
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || joiner.state == .reading || joiner.state == .joining).accessibilityIdentifier("playlistJoinLookUp")
                    if case .offer(let offer) = joiner.state {
                        Button("Join…") { confirming = true }.musicButtons(prominent: true).accessibilityIdentifier("playlistJoinButton")
                            .confirmationDialog(String(localized: "Join “\(offer.title)”?"), isPresented: $confirming, titleVisibility: .visible) {
                                Button("Join Playlist") { Task { await joiner.join(confirmation: joiner.joinPrompt) } }
                                Button("Cancel", role: .cancel) {}
                            } message: { Text("You will be able to add and change songs in this playlist, and it is added to your library.") }
                    }
                }
            }
        }
        .padding(MusicSpace.lg).frame(minWidth: 480)
        .accessibilityElement(children: .contain).accessibilityIdentifier("playlistJoin")
    }
    @ViewBuilder private var status: some View {
        switch joiner.state {
        case .idle: EmptyView()
        case .reading, .joining: ProgressView().controlSize(.small).accessibilityIdentifier("playlistJoining")
        case .invalidLink: Label("That isn’t a YouTube Music invite link.", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("playlistJoinInvalid")
        case .offer(let offer): Label("Ready to join “\(offer.title)”.", systemImage: "person.2").accessibilityIdentifier("playlistJoinOffer")
        case .alreadyMember(let title): Label("You can already edit “\(title)”. Nothing was sent.", systemImage: "checkmark.circle").accessibilityIdentifier("playlistJoinAlready")
        case .joined(let id):
            HStack {
                Label("You joined the playlist.", systemImage: "checkmark.circle").accessibilityIdentifier("playlistJoined")
                Button("Open") { open(id); dismiss() }.musicButtons().accessibilityIdentifier("playlistJoinedOpen")
            }
        case .failed(let failure): Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("playlistJoinFailed")
        case .needsReconciliation:
            HStack {
                Label("YouTube Music didn’t confirm this. You may or may not have joined.", systemImage: "questionmark.circle").font(.caption).accessibilityIdentifier("playlistJoinUnconfirmed")
                Button("Check") { Task { await joiner.check() } }.musicButtons().accessibilityIdentifier("playlistJoinCheck")
            }
        }
    }
}
