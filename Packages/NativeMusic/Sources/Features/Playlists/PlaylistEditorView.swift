import AccountSession
import DesignSystem
import SwiftUI

/// What happened to each change, at the playlist it applies to: a spinner while it is pending, the reason and a way forward when it
/// failed or its outcome is unknown. Nothing here claims success the service did not confirm.
struct PlaylistOperationLines: View {
    @Bindable var session: PlaylistEditSession
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            ForEach(session.operations) { operation in line(operation) }
            if session.needsRefresh {
                HStack(spacing: MusicSpace.xs) {
                    Label("The playlist couldn’t be read back after the last change, so what you see is an estimate.", systemImage: "arrow.triangle.2.circlepath").font(.caption)
                        .foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistRefreshNeeded")
                    Button("Refresh") { Task { await session.refresh() } }.musicPageAction().accessibilityIdentifier("playlistRefresh")
                }
            }
        }
    }
    @ViewBuilder private func line(_ operation: PlaylistOperation) -> some View {
        switch operation.state {
        case .pending:
            HStack(spacing: MusicSpace.xs) { ProgressView().controlSize(.small); Text("Saving this change…").font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                .accessibilityElement(children: .combine).accessibilityIdentifier("playlistPending")
        case .confirmed:
            VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                Label("Done", systemImage: "checkmark.circle").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistConfirmed")
                if operation.mergedWithRemoteChanges {
                    Text("The playlist had changed elsewhere; your change was merged with it.").font(.caption2).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistMerged")
                }
                if !operation.satisfied.isEmpty {
                    let names = operation.satisfied.joined(separator: ", ")
                    Text("Already the case: \(names)").font(.caption2).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistAlreadyTrue")
                }
            }
        case .failed(let failure):
            HStack(spacing: MusicSpace.xs) {
                Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("playlistFailed")
                MusicGlassGroup {
                    HStack(spacing: MusicSpace.xs) {
                        if ![.needsSignIn, .sessionEnded, .notPermitted, .needsConfirmation, .invalid, .notFullyRead].contains(failure) {
                            Button("Try Again") { Task { await session.retry(operation.id) } }.musicPageAction().accessibilityIdentifier("playlistRetry")
                        }
                        Button("Dismiss") { session.dismiss(operation.id) }.musicPageAction().accessibilityIdentifier("playlistDismiss")
                    }
                }
            }
            .onAppear { Announcer.post(failure.message, kind: .error) }
        case .needsReconciliation:
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Label("YouTube Music didn’t confirm this change. It may or may not have been applied.", systemImage: "questionmark.circle").font(.caption)
                    .foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistUnconfirmed")
                MusicGlassGroup {
                    HStack(spacing: MusicSpace.xs) {
                        Button("Check") { Task { await session.check(operation.id) } }.musicPageAction().accessibilityIdentifier("playlistCheck")
                        Button("Try Again") { Task { await session.retry(operation.id) } }.musicPageAction().accessibilityIdentifier("playlistRetry")
                            .help(Text("Reads the playlist first and sends only what is missing"))
                        Button("Dismiss") { session.dismissUnconfirmed(operation.id) }.musicPageAction().accessibilityIdentifier("playlistDismiss")
                    }
                }
                if operation.checkedUnreadable {
                    Text("The playlist couldn’t be read, so nothing was sent again.").font(.caption2).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistUncheckable")
                }
            }
        case .conflicted:
            Label("Part of this change needs your answer below.", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                .accessibilityIdentifier("playlistNeedsAnswer")
        }
    }
}

/// One question about one thing, with both versions side by side. The answers only ever concern this one thing.
struct PlaylistConflictView: View {
    @Bindable var session: PlaylistEditSession
    let conflict: PlaylistConflict
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Label(conflict.summary, systemImage: "arrow.triangle.branch").font(.headline).accessibilityIdentifier("playlistConflictSummary")
            HStack(alignment: .top, spacing: MusicSpace.md) {
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    Text("Your version").font(.caption.bold())
                    Text(conflict.mineDescription).font(.callout).accessibilityIdentifier("playlistConflictMine")
                }
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    Text("YouTube Music’s version").font(.caption.bold())
                    Text(conflict.theirsDescription).font(.callout).accessibilityIdentifier("playlistConflictTheirs")
                }
            }
            Text("This answer changes only this one thing. The rest of the playlist stays as it is.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
            MusicGlassGroup {
                HStack(spacing: MusicSpace.xs) {
                    if conflict.allowsKeepMine {
                        Button("Keep My Change") { Task { await session.resolve(conflict.id, .keepMine) } }.musicPageAction(prominent: true).accessibilityIdentifier("playlistKeepMine")
                    }
                    Button(conflict.allowsKeepMine ? "Keep YouTube Music’s" : "Leave It As It Is") { Task { await session.resolve(conflict.id, .keepTheirs) } }
                        .musicPageAction().accessibilityIdentifier("playlistKeepTheirs")
                }.disabled(session.isBusy)
            }
        }
        .padding(MusicSpace.sm).musicInsetSurface()
        .accessibilityElement(children: .contain).accessibilityIdentifier("playlistConflict")
    }
}

/// The editor for one playlist the service lets this person change. Every control is one explicit request; nothing here runs by itself.
public struct PlaylistEditorView: View {
    @Bindable var session: PlaylistEditSession
    let surface: PlaylistSurface
    var onDeleted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.socialSurface) private var social
    @Environment(\.sharingStandIn) private var sharingStandIn
    @State private var standInPresses = 0
    @State private var selection = Set<String>()
    @State private var pendingBulk: PlaylistIntent?
    @State private var titleDraft = ""
    @State private var detailsDraft = ""
    @State private var privacyDraft = MusicPlaylistPrivacy.private
    @State private var staged: PlaylistStagedAdd?
    @State private var pendingUndo: PlaylistPrompt?
    @State private var confirmingStop = false
    @State private var confirmingDelete = false

    public init(session: PlaylistEditSession, surface: PlaylistSurface, onDeleted: @escaping () -> Void = {}) {
        self.session = session; self.surface = surface; self.onDeleted = onDeleted
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            header
            Divider()
            content
        }
        .padding(MusicSpace.lg).frame(minWidth: 620, minHeight: 560)
        .accessibilityElement(children: .contain).accessibilityIdentifier("playlistEditor")
        .modifier(PlaylistStagedAddDialog(session: session, staged: $staged))
        .confirmationDialog(undoTitle, isPresented: Binding(get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } }), titleVisibility: .visible, presenting: pendingUndo) { prompt in
            Button(undoButton(prompt), role: prompt.isDestructive ? .destructive : nil) { pendingUndo = nil; Task { await session.undoLast(confirmation: prompt) } }
            Button("Cancel", role: .cancel) { pendingUndo = nil }
        } message: { prompt in
            Text(PlaylistPromptText.names(prompt))
        }
        .task { if session.snapshot == nil { await session.load() }; syncDrafts(); await session.loadSuggestions() }
        .onChange(of: session.snapshot?.version) { _, _ in syncDrafts() }
        .onChange(of: session.isDeleted) { _, deleted in if deleted { onDeleted(); dismiss() } }
    }
    private var undoTitle: String { session.undo?.label ?? "" }
    private func undoButton(_ prompt: PlaylistPrompt) -> String { String(localized: "Undo for \(prompt.count) Songs") }
    private func syncDrafts() {
        guard let snapshot = session.snapshot else { return }
        titleDraft = snapshot.title; detailsDraft = snapshot.details; privacyDraft = snapshot.privacy ?? .private
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Text(session.displayed?.title ?? "").font(MusicPageStyle.section).accessibilityAddTraits(.isHeader).accessibilityIdentifier("playlistEditorTitle")
                HStack(spacing: MusicSpace.sm) {
                    Label(session.role.title, systemImage: "person.crop.circle").font(.caption).accessibilityIdentifier("playlistRole")
                    if let privacy = session.displayed?.privacy {
                        Label(privacy.title, systemImage: privacy.symbol).font(.caption).accessibilityIdentifier("playlistPrivacyLabel")
                    }
                    if let count = session.displayed?.occurrences.count { Text("\(count) songs").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistCount") }
                }
            }
            Spacer()
            Button("Done") { dismiss() }.musicPageAction(prominent: true).keyboardShortcut(.defaultAction).accessibilityIdentifier("playlistDone")
        }
    }

    @ViewBuilder private var content: some View {
        switch session.loadState {
        case .idle, .loading:
            ProgressView("Reading the playlist…").frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("playlistLoading")
        case .failed(let failure):
            VStack(spacing: MusicSpace.xs) {
                Label(failure.message, systemImage: "exclamationmark.triangle").accessibilityIdentifier("playlistLoadFailed")
                Button("Try Again") { Task { await session.load() } }.musicPageAction()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let snapshot = session.displayed { loaded(snapshot) }
        }
    }

    @ViewBuilder private func loaded(_ snapshot: PlaylistSnapshot) -> some View {
        let canEdit = session.role.canEdit
        ScrollView {
            VStack(alignment: .leading, spacing: MusicSpace.lg) {
                if !canEdit {
                    Label("YouTube Music doesn’t let you change this playlist, so nothing here can edit it.", systemImage: "lock").accessibilityIdentifier("playlistReadOnly")
                }
                if !snapshot.isComplete {
                    Label("The playlist wasn’t read completely, so reordering is off until it is.", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(MusicStyle.secondaryText)
                        .accessibilityIdentifier("playlistIncomplete")
                }
                PlaylistOperationLines(session: session)
                ForEach(session.conflicts) { PlaylistConflictView(session: session, conflict: $0) }
                if let undo = session.undo {
                    HStack(spacing: MusicSpace.xs) {
                        Text(undo.label).font(.callout).accessibilityIdentifier("playlistUndoLabel")
                        // One song is reversed at once; more than one needs the same naming confirmation as the change itself.
                        Button("Undo") { if let prompt = session.undoPrompt { pendingUndo = prompt } else { Task { await session.undoLast() } } }
                            .musicPageAction().disabled(session.isBusy).accessibilityIdentifier("playlistUndo")
                    }
                }
                if canEdit, session.snapshot?.editing?.canEditDetails == true { detailsEditor.padding(MusicSpace.md).musicInsetSurface() }
                trackList(snapshot, canEdit: canEdit)
                if canEdit, !session.suggestions.isEmpty || session.suggestionsFailed { suggestions(snapshot) }
                shareSection(snapshot).padding(MusicSpace.md).musicInsetSurface()
                if session.role == .owner { collaborationSection.padding(MusicSpace.md).musicInsetSurface() }
                if session.role == .owner { deleteSection }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detailsEditor: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text("Details").font(.headline)
            HStack {
                TextField("Title", text: $titleDraft).textFieldStyle(.roundedBorder).accessibilityIdentifier("playlistTitleField")
                Button("Rename") { Task { await session.submit(.rename(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines))) } }
                    .musicPageAction().disabled(session.isBusy || titleDraft.trimmingCharacters(in: .whitespacesAndNewlines) == session.snapshot?.title).accessibilityIdentifier("playlistRename")
            }
            HStack {
                TextField("Description", text: $detailsDraft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3).accessibilityIdentifier("playlistDescriptionField")
                Button("Save Description") { Task { await session.submit(.describe(detailsDraft)) } }
                    .musicPageAction().disabled(session.isBusy || detailsDraft == session.snapshot?.details).accessibilityIdentifier("playlistSaveDescription")
            }
            HStack {
                Picker("Visibility", selection: $privacyDraft) {
                    ForEach(MusicPlaylistPrivacy.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }.accessibilityIdentifier("playlistPrivacyPicker")
                Button("Change Visibility") { Task { await session.submit(.setPrivacy(privacyDraft)) } }
                    .musicPageAction().disabled(session.isBusy || privacyDraft == session.snapshot?.privacy).accessibilityIdentifier("playlistApplyPrivacy")
            }
        }
    }

    private func trackList(_ snapshot: PlaylistSnapshot, canEdit: Bool) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack {
                Text("Songs").font(.headline)
                Spacer()
                if canEdit {
                    Button("Remove Selected…") { startBulkRemove(snapshot) }
                        .musicPageAction().disabled(session.isBusy || selection.count < 2 || selection.count > MusicPlaylistRequest.maximumActions)
                        .accessibilityIdentifier("playlistRemoveSelected")
                }
            }
            if snapshot.occurrences.isEmpty {
                Text("This playlist has no songs yet.").foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistEmpty")
            } else {
                List(selection: $selection) {
                    ForEach(Array(snapshot.occurrences.enumerated()), id: \.element.id) { index, occurrence in
                        row(snapshot, index: index, occurrence: occurrence, canEdit: canEdit).tag(occurrence.id)
                    }
                    // A drag inside the list is a single move before the occurrence it was dropped on; off while the playlist is not fully read.
                    .onMove(perform: canEdit && snapshot.isComplete && snapshot.unaddressableCount == 0 && !session.isBusy ? { source, destination in
                        guard source.count == 1, let from = source.first, let intent = PlaylistIntent.dragMove(in: snapshot, from: from, to: destination) else { return }
                        Task { await session.submit(intent) }
                    } : nil)
                }
                .frame(minHeight: 180, idealHeight: 260)
                .dropDestination(for: PlaylistDraggedSong.self) { dropped, _ in
                    // A drop is never the request: it stages the add and the person confirms (one line for a song, the naming dialog for several).
                    guard canEdit, let pending = session.stageDrop(dropped) else { return false }
                    staged = pending; return true
                }
                .accessibilityIdentifier("playlistSongs")
            }
        }
        .confirmationDialog(bulkTitle, isPresented: Binding(get: { pendingBulk != nil }, set: { if !$0 { pendingBulk = nil } }), titleVisibility: .visible, presenting: pendingBulk) { intent in
            Button(String(localized: "Remove \(intent.affectedCount) Songs"), role: .destructive) { confirmBulk(intent) }
            Button("Cancel", role: .cancel) { pendingBulk = nil }
        } message: { intent in
            Text(bulkMessage(intent))
        }
    }
    private var bulkTitle: String {
        guard let intent = pendingBulk, let prompt = intent.prompt(playlistTitle: session.snapshot?.title ?? "") else { return "" }
        return String(localized: "Remove \(prompt.count) songs from “\(prompt.playlistTitle)”?")
    }
    private func bulkMessage(_ intent: PlaylistIntent) -> String {
        guard let prompt = intent.prompt(playlistTitle: session.snapshot?.title ?? "") else { return "" }
        return PlaylistPromptText.names(prompt) + "\n\n" + String(localized: "This removes only these entries. Undo is offered afterwards.")
    }
    private func startBulkRemove(_ snapshot: PlaylistSnapshot) {
        let chosen = snapshot.occurrences.filter { selection.contains($0.id) && !$0.isPlaceholder }
        guard chosen.count >= 2 else { return }
        pendingBulk = .remove(chosen)
    }
    private func confirmBulk(_ intent: PlaylistIntent) {
        let prompt = intent.prompt(playlistTitle: session.snapshot?.title ?? "")
        pendingBulk = nil; selection = []
        Task { await session.submit(intent, confirmation: prompt) }
    }

    private func row(_ snapshot: PlaylistSnapshot, index: Int, occurrence: PlaylistOccurrence, canEdit: Bool) -> some View {
        HStack(spacing: MusicSpace.xs) {
            VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                Text(occurrence.title).lineLimit(1).opacity(occurrence.isAvailable ? 1 : 0.5)
                if let subtitle = occurrence.subtitle { Text(subtitle).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1) }
            }
            Spacer()
            if occurrence.isPlaceholder || session.isPending(occurrence.id) { ProgressView().controlSize(.small) }
            else if canEdit {
                let mover = !occurrence.isPlaceholder && snapshot.isComplete && snapshot.unaddressableCount == 0
                Button { move(snapshot, index: index, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }.labelStyle(.iconOnly)
                    .disabled(!mover || index == 0 || session.isBusy).accessibilityIdentifier("playlistMoveUp-" + occurrence.id)
                Button { move(snapshot, index: index, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }.labelStyle(.iconOnly)
                    .disabled(!mover || index == snapshot.occurrences.count - 1 || session.isBusy).accessibilityIdentifier("playlistMoveDown-" + occurrence.id)
                Button(role: .destructive) { Task { await session.submit(.remove([occurrence])) } } label: { Label("Remove", systemImage: "minus.circle") }.labelStyle(.iconOnly)
                    .disabled(!occurrence.removable || session.isBusy).accessibilityIdentifier("playlistRemove-" + occurrence.id)
            }
        }
        .buttonStyle(.borderless)
        // W28 (A11Y01): reordering without dragging and without finding the small buttons: VoiceOver's actions rotor offers the same moves, under the same conditions.
        .accessibilityActions {
            if canEdit, !occurrence.isPlaceholder, snapshot.isComplete, snapshot.unaddressableCount == 0, !session.isBusy {
                if index > 0 { Button("Move Up") { move(snapshot, index: index, by: -1) } }
                if index < snapshot.occurrences.count - 1 { Button("Move Down") { move(snapshot, index: index, by: 1) } }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("playlistRow-" + occurrence.id)
    }
    /// A move is expressed against the neighbouring occurrence, never a number: down one place means "before the one after the next".
    private func move(_ snapshot: PlaylistSnapshot, index: Int, by step: Int) {
        let occurrences = snapshot.occurrences
        let moving = occurrences[index]
        let target: PlaylistOccurrence?
        if step < 0 { target = occurrences[index - 1] }
        else { target = index + 2 < occurrences.count ? occurrences[index + 2] : nil }
        Task { await session.submit(.move(moving, before: target)) }
    }

    /// The service's suggested songs, kept apart from the members: nothing here is in the playlist, and nothing is added until Add.
    private func suggestions(_ snapshot: PlaylistSnapshot) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text("Suggested songs").font(.headline)
            Text("Nothing is added until you press Add.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
            if session.suggestionsFailed { Text("YouTube Music’s suggestions couldn’t be read. Your songs are unaffected.").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistSuggestionsUnavailable") }
            ForEach(session.suggestions.prefix(8), id: \.id) { item in
                if let video = item.videoID {
                    HStack {
                        Text(item.title).lineLimit(1)
                        Spacer()
                        Button("Add") { stage([PlaylistAddition(videoID: video, title: item.title)]) }
                            .musicPageAction().disabled(session.isBusy).accessibilityIdentifier("playlistAddSuggestion-" + video)
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("playlistSuggestion-" + video)
                }
            }
        }
    }
    /// Songs the person chose to add (a suggestion's Add, or a drop): the session adds one new song at once and otherwise asks.
    private func stage(_ songs: [PlaylistAddition]) {
        Task { staged = await session.addSongs(songs) }
    }

    private func shareSection(_ snapshot: PlaylistSnapshot) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text("Share").font(.headline)
            if let note = PlaylistSharing.note(for: snapshot.privacy) { Text(note).font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistShareNote") }
            MusicGlassGroup {
                HStack {
                    Button { surface.copyLink(playlistID: snapshot.playlistID) } label: { Label("Copy Link", systemImage: "link") }
                        .musicPageAction().accessibilityIdentifier("playlistCopyLink")
                    // The system share sheet, opened by this press; the link is the canonical one and nothing is uploaded by the app.
                    if let url = PlaylistSharing.canonicalURL(playlistID: snapshot.playlistID) {
                        if sharingStandIn {
                            // Isolated Debug runs (UI automation) never open the system share machinery: a button with the same identifier stands in.
                            Button { standInPresses += 1 } label: { Label("Share…", systemImage: "square.and.arrow.up") }.musicPageAction().accessibilityIdentifier("playlistShare")
                        } else {
                            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }.musicPageAction().accessibilityIdentifier("playlistShare")
                        }
                    }
                }
            }
        }
    }
    /// Owner-only collaboration: enable and copy an invite link, or close the playlist to contributions. Each is one explicit request.
    private var collaborationSection: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text("Collaboration").font(.headline)
            if session.snapshot?.privacy == .private {
                Text("Collaborators can’t use a private playlist. Make it unlisted or public first.").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistInviteNote")
            } else {
                Text("An invite link lets people you send it to join and add songs. Nothing is sent to anyone by this app.").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("playlistInviteNote")
            }
            switch session.collaboration {
            case .pending: ProgressView().controlSize(.small).accessibilityIdentifier("playlistCollaborationPending")
            case .invite(let link):
                if let link {
                    HStack(spacing: MusicSpace.xs) {
                        Label("Collaboration is on. The invite link is ready.", systemImage: "checkmark.circle").font(.caption).accessibilityIdentifier("playlistInviteReady")
                        MusicGlassGroup {
                            Button { surface.copy(link: link) } label: { Label("Copy Invite Link", systemImage: "link.badge.plus") }.musicPageAction().accessibilityIdentifier("playlistInviteCopy")
                        }
                    }
                } else {
                    Label("Collaboration is on, but YouTube Music returned no link this app can show.", systemImage: "questionmark.circle").font(.caption).accessibilityIdentifier("playlistInviteNoLink")
                }
            case .closed: Label("The playlist is closed to contributions.", systemImage: "lock").font(.caption).accessibilityIdentifier("playlistContributionsClosed")
            case .failed(let failure):
                HStack { Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("playlistCollaborationFailed")
                    Button("Dismiss") { session.dismissCollaboration() }.musicPageAction() }
            case .unconfirmed:
                HStack { Label("YouTube Music didn’t confirm this. It may or may not have happened.", systemImage: "questionmark.circle").font(.caption).accessibilityIdentifier("playlistCollaborationUnconfirmed")
                    Button("Try Again") { Task { await session.retryCollaboration() } }.musicPageAction().accessibilityIdentifier("playlistCollaborationRetry")
                    Button("Dismiss") { session.dismissCollaboration() }.musicPageAction() }
            case .idle: EmptyView()
            }
            MusicGlassGroup {
                HStack {
                    Button { Task { if let social { await social.createInvite(for: session, title: session.snapshot?.title ?? "") } else { await session.createInviteLink() } } } label: { Label("Create Invite Link", systemImage: "person.badge.plus") }
                        .musicPageAction().disabled(session.collaboration == .pending || session.isBusy).accessibilityIdentifier("playlistInviteCreate")
                    Button { confirmingStop = true } label: { Label("Stop Contributions…", systemImage: "person.badge.minus") }
                        .musicPageAction().disabled(session.collaboration == .pending || session.isBusy).accessibilityIdentifier("playlistStopContributions")
                }
            }
        }
        .confirmationDialog(String(localized: "Stop contributions to “\(session.snapshot?.title ?? "")”?"), isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop Contributions", role: .destructive) {
                Task { if let social { await social.stopContributions(for: session, title: session.snapshot?.title ?? "", confirmation: session.stopContributionsPrompt) } else { await session.stopContributions(confirmation: session.stopContributionsPrompt) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("People who joined can no longer add songs. This app can’t reopen it; do that in YouTube Music.")
        }
    }
    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Divider()
            if case .failed(let failure)? = session.deletion {
                HStack {
                    Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("playlistDeleteFailed")
                    Button("Dismiss") { session.dismissDeletionFailure() }.musicPageAction()
                }
            }
            if session.deletion == .needsReconciliation {
                HStack {
                    Label("YouTube Music didn’t confirm the deletion.", systemImage: "questionmark.circle").font(.caption).accessibilityIdentifier("playlistDeleteUnconfirmed")
                    Button("Check") { Task { await session.checkDeletion() } }.musicPageAction()
                }
            }
            Button("Delete Playlist…", role: .destructive) { confirmingDelete = true }
                .musicPageAction().disabled(session.deletion == .pending).accessibilityIdentifier("playlistDelete")
                .confirmationDialog(String(localized: "Delete “\(session.snapshot?.title ?? "")”?"), isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete Playlist", role: .destructive) { Task { await session.deletePlaylist(confirmation: session.deletionPrompt) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently deletes the playlist and its \(session.snapshot?.occurrences.count ?? 0) entries from YouTube Music. It can’t be undone.")
                }
        }
    }
}

private struct SharingStandInKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    /// True only for an isolated Debug launch (set by the shell): the editor then renders a stand-in button instead of the system `ShareLink`.
    var sharingStandIn: Bool { get { self[SharingStandInKey.self] } set { self[SharingStandInKey.self] = newValue } }
}
