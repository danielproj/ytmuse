import AccountSession
import Foundation
import Observation

/// What Undo will do, built from what was confirmed (never from what was merely asked).
public struct PlaylistUndo: Equatable, Sendable {
    public let operationID: UUID
    public let intent: PlaylistIntent
    /// States the effect in words ("Undo: removed 3 songs"), because this is the confirmation of a bulk reversal.
    public let label: String
}

/// Songs waiting for the person's answer before they are added: how many and which (the prompt), and which of them the playlist holds.
public struct PlaylistStagedAdd: Identifiable, Equatable, Sendable {
    public var id: String { songs.map(\.videoID).joined(separator: ",") }
    public let songs: [PlaylistAddition]
    public let duplicateTitles: [String]
    /// The naming confirmation for more than one song; nil for a single song.
    public let prompt: PlaylistPrompt?
    public var hasDuplicates: Bool { !duplicateTitles.isEmpty }
}

/// The owner's collaboration requests and what came of the last one.
public enum PlaylistCollaboration: Equatable, Sendable {
    case idle, pending
    /// Collaboration is enabled; the link is nil when the service did not return one that validates (the person is told).
    case invite(URL?)
    case closed
    case failed(PlaylistFailure)
    /// The request left and the outcome is unknown.
    case unconfirmed
}

public enum PlaylistLoadState: Equatable, Sendable {
    case idle, loading, loaded
    case failed(PlaylistFailure)
}

/// The command layer for changing one playlist. Every surface that edits a playlist submits through one of these, so a change has one
/// operation id, one optimistic view, one state and one rollback, and the safety rules are kept in one place:
///
/// - A change is sent only from `submit`, `retry`, `resolve` or `undo`, which the interface calls for an explicit action. Nothing here
///   loops, runs in the background, polls or replays a stored request.
/// - What may be changed comes from what the service published for this playlist (`PlaylistSnapshot.role`, per-row removal commands).
/// - Before anything is sent the playlist is read again and the change is reconciled with what is there now (`PlaylistReconciler`).
///   The parts that merge go out; the parts that collide with a different change are kept as questions about that one thing.
/// - A change touching more than one song needs the confirmation that names the selection.
/// - Success needs the service's positive statement. A request whose outcome is unknown is settled by reading the playlist; an add is
///   never sent again before that read, and a retry sends only what the read shows is still missing.
/// - Nothing is queued while offline; a change that did not leave says so and changes nothing.
/// - State is per account scope; a switch drops it all, and an answer for another scope is discarded.
@MainActor @Observable public final class PlaylistEditSession {
    public private(set) var loadState: PlaylistLoadState = .idle
    /// The last playlist state read from the service (the settled state).
    public private(set) var snapshot: PlaylistSnapshot?
    public private(set) var operations: [PlaylistOperation] = []
    public private(set) var conflicts: [PlaylistConflict] = []
    public private(set) var undo: PlaylistUndo?
    /// The playlist was deleted (confirmed by the service or by reading the list).
    public private(set) var deletion: PlaylistOperationState?
    /// A confirmed change could not be read back, so the settled state is a local estimate until the next read.
    public private(set) var needsRefresh = false
    /// The service's suggested songs, read on their own (never members). Empty until `loadSuggestions` has run.
    public private(set) var loadedSuggestions: [MusicCatalogItem] = []
    public private(set) var suggestionsFailed = false
    /// Owner-only collaboration requests: the invite link and closing the playlist to contributions.
    public private(set) var collaboration: PlaylistCollaboration = .idle
    /// How many times in a row a list read still showed the deleted playlist (two agreeing reads are needed to call a delete not applied).
    public private(set) var deletionStillListedReads = 0
    @ObservationIgnored private var lastCollaborationAction: MusicPlaylistEditAction?

    public let playlistID: String
    @ObservationIgnored private let service: any PlaylistServing
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let signedIn: @MainActor () -> SearchPlayback
    @ObservationIgnored private var generation: UInt64 = 0
    /// Told once per settled change of membership. A downloads feature observes this; this type decides nothing about retention.
    @ObservationIgnored public var onMembershipChange: (@MainActor (PlaylistMembershipChange) -> Void)?
    /// Requests handed to the service since this session was made (a measurement for tests: one action is one request).
    @ObservationIgnored public private(set) var sentCount = 0
    @ObservationIgnored public private(set) var readCount = 0

    public init(playlistID: String, service: any PlaylistServing, accountScope: @escaping @MainActor () -> String = { "" },
                signedIn: @escaping @MainActor () -> SearchPlayback = { .available }) {
        self.playlistID = playlistID; self.service = service; self.accountScope = accountScope; self.signedIn = signedIn
    }

    // MARK: Display

    /// The playlist as it should be drawn: the settled state with every change that has not settled shown as if made.
    public var displayed: PlaylistSnapshot? {
        guard var shown = snapshot else { return nil }
        for operation in operations where operation.state == .pending || operation.state == .needsReconciliation {
            shown = shown.applying(operation.intent, token: operation.id.uuidString.prefix(8).description)
        }
        return shown
    }
    public func operation(_ id: UUID) -> PlaylistOperation? { operations.first { $0.id == id } }
    public var isBusy: Bool { operations.contains { $0.state == .pending } }
    /// A change whose outcome is unknown must be settled (checked, retried or dismissed) before another is made.
    public var hasUnsettled: Bool { operations.contains { $0.state == .needsReconciliation } }
    public func isPending(_ setVideoID: String) -> Bool {
        operations.contains { operation in
            guard operation.state == .pending || operation.state == .needsReconciliation else { return false }
            switch operation.intent {
            case .remove(let songs): return songs.contains { $0.setVideoID == setVideoID }
            case .move(let song, _): return song.setVideoID == setVideoID
            default: return false
            }
        }
    }
    public var role: MusicPlaylistRole { snapshot?.role ?? .viewer }
    public var isDeleted: Bool { deletion == .confirmed }

    // MARK: Reading

    public func load() async {
        loadState = .loading
        let ticket = generation, scope = accountScope()
        do {
            let read = try await service.read(playlistID: playlistID)
            readCount += 1
            guard ticket == generation, accountScope() == scope else { return }
            snapshot = read; loadState = .loaded; needsRefresh = false
        } catch { guard ticket == generation else { return }; loadState = .failed(Self.failure(for: error, reading: true)) }
    }
    /// Reads again when nothing is in flight; a read never changes the service.
    public func refresh() async {
        guard !isBusy else { return }
        await load()
    }

    /// Suggested songs: the snapshot's own plus those a separate read of the suggestions token found, once each.
    public var suggestions: [MusicCatalogItem] {
        var seen = Set<String>()
        return ((snapshot?.suggestions ?? []) + loadedSuggestions).filter { $0.videoID.map { seen.insert($0).inserted } ?? false }
    }
    /// Reads the service's suggested songs. A read only; a failure is shown as "unavailable" and never touches the tracks.
    public func loadSuggestions() async {
        guard let token = snapshot?.suggestionsToken else { return }
        let ticket = generation, scope = accountScope()
        do {
            let items = try await service.readSuggestions(token: token)
            guard ticket == generation, accountScope() == scope else { return }
            loadedSuggestions = items; suggestionsFailed = false
        } catch { guard ticket == generation else { return }; suggestionsFailed = true }
    }

    // MARK: Actions (each is one explicit request for one playlist)

    /// Stages an add and sends nothing: always returns what the person is to be asked about (the naming confirmation for several songs,
    /// Keep duplicates / Skip existing for songs already there, a one-line question for a single new song). Used wherever the gesture is
    /// not itself the request (a drop). Nothing goes out until `confirmAdd`.
    public func stageSongs(_ songs: [PlaylistAddition]) -> PlaylistStagedAdd? {
        guard let snapshot, snapshot.role.canEdit, !songs.isEmpty else { return nil }
        let songs = Array(songs.prefix(MusicPlaylistRequest.maximumActions))
        let present = songs.filter { snapshot.count(ofVideo: $0.videoID) > 0 }
        return PlaylistStagedAdd(songs: songs, duplicateTitles: present.map(\.title), prompt: PlaylistIntent.add(songs, .skipExisting).prompt(playlistTitle: snapshot.title))
    }
    /// A drop of dragged songs: only this app's valid song values count, and the result is staged, never sent.
    public func stageDrop(_ dropped: [PlaylistDraggedSong]) -> PlaylistStagedAdd? {
        stageSongs(PlaylistDraggedSong.additions(from: dropped))
    }
    /// Adds songs when the press itself is the request (an Add button on a suggestion or in the add sheet). A single song the playlist
    /// does not hold goes at once; anything else comes back staged. Nothing else calls this: a drop uses `stageDrop`.
    public func addSongs(_ songs: [PlaylistAddition]) async -> PlaylistStagedAdd? {
        guard let staged = stageSongs(songs) else { return nil }
        if !staged.hasDuplicates, staged.prompt == nil { await submit(.add(staged.songs, .skipExisting)); return nil }
        return staged
    }
    /// Sends a staged add with the person's choice. The confirmation is the prompt the session built for exactly these songs.
    public func confirmAdd(_ staged: PlaylistStagedAdd, mode: MusicPlaylistDuplicateMode) async {
        await submit(.add(staged.songs, mode), confirmation: staged.prompt)
    }
    /// Applies the change on screen at once, reads the playlist, merges and sends. A bulk change is refused unless `confirmation` is the
    /// prompt the session itself builds for that selection.
    public func submit(_ intent: PlaylistIntent, confirmation: PlaylistPrompt? = nil) async {
        await run(intent, confirmation: confirmation, isUndo: false)
    }
    /// Sends the missing part of a change again after the service refused it or its outcome was unknown. The playlist is read first,
    /// always: a retry sends only what that read shows is still missing and never adds an occurrence the read shows exists.
    public func retry(_ id: UUID) async {
        guard let operation = operation(id) else { return }
        switch operation.state {
        case .failed(let reason) where reason != .needsConfirmation && reason != .notPermitted && reason != .invalid && reason != .notFullyRead: break
        case .needsReconciliation: break
        default: return
        }
        guard !isBusy else { return }
        update(id) { $0.state = .pending; $0.attempts += 1 }
        await execute(id)
    }
    /// After an unknown outcome: read the playlist and settle from what is there. Nothing is sent.
    public func check(_ id: UUID) async {
        guard let operation = operation(id), operation.state == .needsReconciliation else { return }
        let ticket = generation, scope = accountScope()
        let remote: PlaylistSnapshot
        do { remote = try await service.read(playlistID: playlistID); readCount += 1 }
        catch { update(id) { $0.checkedUnreadable = true }; return }
        guard ticket == generation, accountScope() == scope, let current = self.operation(id), current.state == .needsReconciliation else { return }
        let settlement = Self.settlement(of: current, in: remote)
        switch settlement {
        case .applied: finish(id, state: conflicts.contains { $0.operationID == id } ? .conflicted : .confirmed, before: snapshot ?? current.base, after: remote)
        case .none: snapshot = remote; update(id) { $0.state = .failed(.notApplied) }
        case .partly: snapshot = remote; update(id) { $0.state = .failed(.partlyApplied) }
        }
    }
    /// Answers one question about one thing. "Keep theirs" leaves the playlist as the service has it; "keep mine" sends only that piece.
    public func resolve(_ conflictID: UUID, _ resolution: PlaylistResolution) async {
        guard let conflict = conflicts.first(where: { $0.id == conflictID }), !isBusy else { return }
        if resolution == .keepTheirs { drop(conflict); return }
        guard let action = PlaylistReconciler.forcedAction(for: conflict) else { return }
        // "Keep my change" is a write like any other: it is signed in and permitted by the playlist as it is now, or it is not sent.
        switch signedIn() {
        case .needsSignIn: update(conflict.operationID) { $0.state = .failed(.needsSignIn) }; return
        case .sessionExpired: update(conflict.operationID) { $0.state = .failed(.sessionEnded) }; return
        case .available: break
        }
        let ticket = generation, scope = accountScope()
        update(conflict.operationID) { $0.state = .pending }
        let remote: PlaylistSnapshot
        do { remote = try await service.read(playlistID: playlistID); readCount += 1 }
        catch {
            guard ticket == generation else { return }
            update(conflict.operationID) { $0.state = .conflicted }; return
        }
        guard ticket == generation, accountScope() == scope else { return }
        guard Self.permits(conflict.piece, in: remote) else {
            snapshot = remote; drop(conflict, settle: false); update(conflict.operationID) { $0.state = .failed(.notPermitted) }; return
        }
        // The question is asked again against what the service has now: a piece that is no longer needed is simply done.
        let fresh = PlaylistConflict(id: conflict.id, operationID: conflict.operationID, kind: conflict.kind, piece: conflict.piece, mine: conflict.mine, theirs: remote)
        let forced = PlaylistReconciler.forcedAction(for: fresh) ?? action
        snapshot = remote
        drop(conflict, settle: false)
        await dispatch(conflict.operationID, actions: [forced], remote: remote, remainingConflicts: conflicts.filter { $0.operationID == conflict.operationID }.count)
    }
    /// Reverses the last confirmed change with a compensating change. It may fail like any change; the playlist then stays as it is.
    /// A reversal of more than one song needs the same naming confirmation as any bulk change (`undoPrompt`); one song needs none.
    public func undoLast(confirmation: PlaylistPrompt? = nil) async {
        guard let entry = undo, !isBusy else { return }
        await run(entry.intent, confirmation: confirmation, isUndo: true)
    }
    /// The confirmation `undoLast` needs, or nil when the reversal touches a single song.
    public var undoPrompt: PlaylistPrompt? {
        guard let entry = undo, let snapshot else { return nil }
        return entry.intent.prompt(playlistTitle: snapshot.title, undo: true)
    }
    /// Accepts a failure: the old view stays, the message goes.
    public func dismiss(_ id: UUID) {
        guard let operation = operation(id) else { return }
        if case .failed = operation.state { operations.removeAll { $0.id == id } }
    }
    /// Gives up on a change whose outcome stayed unknown: the settled view is shown and the change is not sent again.
    public func dismissUnconfirmed(_ id: UUID) {
        guard operation(id)?.state == .needsReconciliation else { return }
        operations.removeAll { $0.id == id }
    }
    public func accountChanged() {
        generation &+= 1; operations = []; conflicts = []; undo = nil; snapshot = nil; loadState = .idle; deletion = nil
        loadedSuggestions = []; suggestionsFailed = false; collaboration = .idle; deletionStillListedReads = 0; lastCollaborationAction = nil
    }

    /// The confirmation a playlist deletion needs: it names the playlist.
    public var deletionPrompt: PlaylistPrompt? {
        guard let snapshot else { return nil }
        return PlaylistPrompt(action: .deletePlaylist, playlistTitle: snapshot.title, count: snapshot.occurrences.count, names: [snapshot.title])
    }
    /// Deletes the playlist. Only an owner (the service published a delete command) can, and only with the confirmation that names it.
    public func deletePlaylist(confirmation: PlaylistPrompt?) async {
        guard let snapshot, deletion != .pending, deletion != .confirmed else { return }
        guard snapshot.role == .owner, snapshot.editing?.canDelete == true else { deletion = .failed(.notPermitted); return }
        guard confirmation == deletionPrompt else { deletion = .failed(.needsConfirmation); return }
        let request = MusicPlaylistRequest.delete(playlistID: playlistID)
        guard request.isWellFormed else { deletion = .failed(.invalid); return }
        switch signedIn() {
        case .needsSignIn: deletion = .failed(.needsSignIn); return
        case .sessionExpired: deletion = .failed(.sessionEnded); return
        case .available: break
        }
        deletion = .pending
        let ticket = generation, scope = accountScope()
        sentCount += 1
        do {
            let reply = try await service.apply(request)
            guard ticket == generation, accountScope() == scope else { return }
            switch reply.result.outcome {
            case .confirmed: deletion = .confirmed
            case .rejected(let why): deletion = .failed(Self.failure(for: why))
            case .indeterminate: deletion = .needsReconciliation
            }
        } catch {
            guard ticket == generation else { return }
            deletion = Self.isCancellation(error) ? .needsReconciliation : .failed(Self.failure(for: error, reading: false))
        }
    }
    /// After an unknown deletion: the person's playlist list says whether it is gone. Nothing is sent.
    public func checkDeletion() async {
        guard deletion == .needsReconciliation else { return }
        guard let listing = try? await service.listing() else { return }
        if listing.contains(where: { $0.playlistID == playlistID }) {
            // A list that lags just after a delete still shows the playlist: one such read is "not seen gone yet", two in a row are "not applied".
            deletionStillListedReads += 1
            if deletionStillListedReads >= 2 { deletion = .failed(.notApplied) }
        } else { deletion = .confirmed }
    }
    public func dismissDeletionFailure() { if case .failed = deletion { deletion = nil } }

    // MARK: Collaboration (owner only, explicit, one request each)

    /// What stopping contributions asks the person to confirm: it names the playlist.
    public var stopContributionsPrompt: PlaylistPrompt? {
        guard let snapshot else { return nil }
        return PlaylistPrompt(action: .stopContributions, playlistTitle: snapshot.title, count: 1, names: [snapshot.title])
    }
    /// Enables collaboration and asks for an invite link. Only the owner (the page published a delete command) is offered it. The link is
    /// shown for copying only after it validates; nothing is shared or sent to anyone.
    public func createInviteLink() async { await sendCollaboration(.createInviteLink) }
    /// Closes the playlist to further contributions, after the confirmation that names it.
    public func stopContributions(confirmation: PlaylistPrompt?) async {
        guard confirmation == stopContributionsPrompt, confirmation != nil else { collaboration = .failed(.needsConfirmation); return }
        await sendCollaboration(.closeToContributions)
    }
    /// After an unknown outcome the same single request may be sent again: both are state-setting and cannot duplicate anything.
    public func retryCollaboration() async {
        guard case .unconfirmed = collaboration, let action = lastCollaborationAction else { return }
        await sendCollaboration(action)
    }
    public func dismissCollaboration() { if case .failed = collaboration { collaboration = .idle } else if case .unconfirmed = collaboration { collaboration = .idle } }

    private func sendCollaboration(_ action: MusicPlaylistEditAction) async {
        if case .pending = collaboration { return }
        guard let base = snapshot, base.role == .owner, base.editing?.canDelete == true else { collaboration = .failed(.notPermitted); return }
        switch signedIn() {
        case .needsSignIn: collaboration = .failed(.needsSignIn); return
        case .sessionExpired: collaboration = .failed(.sessionEnded); return
        case .available: break
        }
        let request = MusicPlaylistRequest.edit(playlistID: playlistID, actions: [action])
        guard request.isWellFormed else { collaboration = .failed(.invalid); return }
        collaboration = .pending; lastCollaborationAction = action
        let ticket = generation, scope = accountScope()
        // The same precondition as any change: the playlist is read first, and the owner's rights are the playlist's as it is now.
        do {
            let remote = try await service.read(playlistID: playlistID); readCount += 1
            guard ticket == generation, accountScope() == scope else { return }
            snapshot = remote
            guard remote.role == .owner, remote.editing?.canDelete == true else { collaboration = .failed(.notPermitted); return }
        } catch { guard ticket == generation else { return }; collaboration = .failed(Self.failure(for: error, reading: true)); return }
        sentCount += 1
        do {
            let reply = try await service.apply(request)
            guard ticket == generation, accountScope() == scope else { return }
            switch reply.result.outcome {
            case .confirmed:
                if case .createInviteLink = action { collaboration = .invite(PlaylistSharing.inviteLink(from: reply.result.inviteLink, playlistID: playlistID)) }
                else { collaboration = .closed }
            case .rejected(let why): collaboration = .failed(Self.failure(for: why))
            case .indeterminate: collaboration = .unconfirmed
            }
        } catch {
            guard ticket == generation else { return }
            collaboration = Self.isCancellation(error) ? .unconfirmed : .failed(Self.failure(for: error, reading: false))
        }
    }

    // MARK: Running a change

    private func run(_ intent: PlaylistIntent, confirmation: PlaylistPrompt?, isUndo: Bool) async {
        guard let base = snapshot, !isBusy, !hasUnsettled else { return }
        let operation = PlaylistOperation(id: UUID(), playlistID: playlistID, intent: intent, base: base, state: .pending, attempts: 1)
        func refuse(_ reason: PlaylistFailure) {
            var refused = operation; refused.state = .failed(reason); refused.attempts = 0; refused.isUndo = isUndo; operations.append(refused)
        }
        switch signedIn() {
        case .needsSignIn: refuse(.needsSignIn); return
        case .sessionExpired: refuse(.sessionEnded); return
        case .available: break
        }
        guard Self.permits(intent, in: base) else { refuse(.notPermitted); return }
        guard Self.isValid(intent) else { refuse(.invalid); return }
        if let required = intent.prompt(playlistTitle: base.title, undo: isUndo), confirmation != required { refuse(.needsConfirmation); return }
        if case .move = intent, !base.isComplete || base.unaddressableCount > 0 { refuse(.notFullyRead); return }
        var started = operation; started.isUndo = isUndo
        if !isUndo { undo = nil }
        // Settled changes are not listed forever: what stays on screen is what still needs the person (failed, unconfirmed, unanswered).
        operations.removeAll { $0.state == .confirmed }
        operations.append(started)
        await execute(started.id)
    }

    private func execute(_ id: UUID) async {
        guard let operation = operation(id) else { return }
        let ticket = generation, scope = accountScope()
        let remote: PlaylistSnapshot
        do { remote = try await service.read(playlistID: playlistID); readCount += 1 }
        catch {
            guard ticket == generation else { return }
            // Nothing was sent by this attempt. If an earlier attempt's outcome is still unknown it stays unknown.
            if operation.sentAny { update(id) { $0.state = .needsReconciliation; $0.checkedUnreadable = true } }
            else if Self.isCancellation(error) { operations.removeAll { $0.id == id } }
            else { update(id) { $0.state = .failed(Self.failure(for: error, reading: true)) } }
            return
        }
        guard ticket == generation, accountScope() == scope, self.operation(id) != nil else { return }
        guard Self.permits(operation.intent, in: remote) else {
            snapshot = remote; update(id) { $0.state = .failed(.notPermitted) }; return
        }
        if !operation.sentAny { update(id) { $0.preIDs = Set(remote.occurrences.map(\.setVideoID)) } }
        let current = self.operation(id) ?? operation
        let plan = PlaylistReconciler.plan(for: current.intent, base: current.base, remote: remote, found: Self.found(for: current, in: remote))
        snapshot = remote
        update(id) { $0.satisfied = plan.satisfied; $0.mergedWithRemoteChanges = remote.version != current.base.version }
        let mine = conflictView(current)
        for piece in plan.conflicts where !conflicts.contains(where: { $0.operationID == id && $0.piece == piece.piece && $0.kind == piece.kind }) {
            conflicts.append(PlaylistConflict(id: UUID(), operationID: id, kind: piece.kind, piece: piece.piece, mine: mine(piece.piece), theirs: remote))
        }
        if plan.actions.isEmpty {
            // Everything was already true, or everything left is a question for the person.
            update(id) { $0.state = plan.conflicts.isEmpty ? .confirmed : .conflicted }
            if plan.conflicts.isEmpty { buildUndo(for: id, before: current.base, after: remote); report(from: current.base, to: remote) }
            return
        }
        await dispatch(id, actions: plan.actions, remote: remote, remainingConflicts: plan.conflicts.count)
    }

    /// Sends the actions as one request and settles the operation from the answer.
    private func dispatch(_ id: UUID, actions: [MusicPlaylistEditAction], remote: PlaylistSnapshot, remainingConflicts: Int) async {
        let request = MusicPlaylistRequest.edit(playlistID: playlistID, actions: actions)
        guard request.isWellFormed else { update(id) { $0.state = .failed(.invalid) }; return }
        let ticket = generation, scope = accountScope()
        update(id) { $0.sent = actions; $0.sentAny = true }
        sentCount += 1
        let state: PlaylistOperationState
        var reportedAdds: [MusicPlaylistAddedOccurrence] = []
        do {
            let reply = try await service.apply(request)
            switch reply.result.outcome {
            case .confirmed: state = remainingConflicts == 0 ? .confirmed : .conflicted; reportedAdds = reply.result.added
            case .rejected(let why):
                // Skip existing is sent without the option that keeps duplicates, so the service refuses a song that appeared since the
                // read. If the playlist now holds every song asked for, the refusal means "already there": nothing was lost.
                if case .service = why, Self.allSkipExisting(actions), await alreadyThere(id, actions: actions) { return }
                state = .failed(Self.failure(for: why))
            case .indeterminate: state = .needsReconciliation
            }
        } catch {
            guard ticket == generation else { return }
            if Self.isCancellation(error) { update(id) { $0.state = .needsReconciliation } }
            else { update(id) { $0.state = .failed(Self.failure(for: error, reading: false)); $0.sentAny = false; $0.sent = [] } }
            return
        }
        guard ticket == generation, accountScope() == scope, operation(id) != nil else { return }
        if state == .confirmed || state == .conflicted {
            await adopt(id, final: state, before: remote, actions: actions, reported: reportedAdds)
        } else {
            update(id) { $0.state = state }
        }
    }

    /// A change settled from a read that is already in hand.
    private func finish(_ id: UUID, state: PlaylistOperationState, before: PlaylistSnapshot, after: PlaylistSnapshot) {
        snapshot = after
        update(id) { $0.state = state }
        buildUndo(for: id, before: before, after: after); report(from: before, to: after)
    }
    private static func allSkipExisting(_ actions: [MusicPlaylistEditAction]) -> Bool {
        !actions.isEmpty && actions.allSatisfy { if case .add(_, .skipExisting) = $0 { true } else { false } }
    }
    /// After a refused skip-existing add: read the playlist; when it holds every song asked for, the change is satisfied.
    private func alreadyThere(_ id: UUID, actions: [MusicPlaylistEditAction]) async -> Bool {
        let ticket = generation, scope = accountScope()
        guard let after = try? await service.read(playlistID: playlistID) else { return false }
        readCount += 1
        guard ticket == generation, accountScope() == scope else { return true }
        let wanted = actions.compactMap { action -> String? in if case .add(let video, _) = action { video } else { nil } }
        guard wanted.allSatisfy({ after.count(ofVideo: $0) > 0 }) else { return false }
        snapshot = after
        var names: [String] = []
        if case .add(let songs, _)? = operation(id)?.intent { names = songs.map(\.title) }
        update(id) { $0.satisfied = names.isEmpty ? wanted : names; $0.state = .confirmed }
        return true
    }

    /// A change the service confirmed: read the playlist back to adopt its occurrence ids (new songs get theirs here). While that read
    /// is in flight the change is still shown as pending. If the read-back fails the settled view is the old one with the confirmed
    /// actions applied, and the screen says it needs a refresh.
    private func adopt(_ id: UUID, final: PlaylistOperationState, before: PlaylistSnapshot, actions: [MusicPlaylistEditAction], reported: [MusicPlaylistAddedOccurrence]) async {
        let ticket = generation, scope = accountScope()
        do {
            let read = try await service.read(playlistID: playlistID); readCount += 1
            guard ticket == generation, accountScope() == scope else { return }
            needsRefresh = false
            finish(id, state: final, before: before, after: read)
        } catch {
            guard ticket == generation else { return }
            var estimate = before
            for action in actions { estimate = Self.estimate(estimate, action, reported: reported) }
            snapshot = estimate; needsRefresh = true
            update(id) { $0.state = final }
        }
    }

    // MARK: Settling

    enum Settlement { case applied, none, partly }
    /// What a read shows of a change that was sent: judged action by action, by occurrence, never by counting rows overall.
    static func settlement(of operation: PlaylistOperation, in remote: PlaylistSnapshot) -> Settlement {
        var applied = 0, total = 0
        var addsWanted: [String: Int] = [:]
        for action in operation.sent {
            switch action {
            case .add(let video, _): addsWanted[video, default: 0] += 1
            case .remove(_, let set): total += 1; if remote.occurrence(set) == nil { applied += 1 }
            case .moveBefore(let set, let successor):
                total += 1
                if let index = remote.index(of: set) {
                    if let successor { if remote.index(of: successor) == index + 1 { applied += 1 } }
                    else if index == remote.occurrences.count - 1 { applied += 1 }
                }
            case .rename(let title): total += 1; if remote.title == title { applied += 1 }
            case .describe(let text): total += 1; if remote.details == text { applied += 1 }
            case .setPrivacy(let privacy): total += 1; if remote.privacy == privacy { applied += 1 }
            case .createInviteLink, .closeToContributions, .joinCollaboration: total += 1       // never part of a settled edit: nothing to read
            }
        }
        if !addsWanted.isEmpty {
            let fresh = remote.occurrences.filter { !operation.preIDs.contains($0.setVideoID) }
            for (video, wanted) in addsWanted {
                let seen = fresh.filter { $0.videoID == video }.count
                total += wanted; applied += min(seen, wanted)
            }
        }
        if total == 0 { return .none }
        return applied == total ? .applied : applied == 0 ? .none : .partly
    }
    /// Per video, how many of the occurrences a change asked to add are already in the playlist from an earlier attempt of the same
    /// change (new since it was first prepared). Only a change that has been sent can have any.
    static func found(for operation: PlaylistOperation, in remote: PlaylistSnapshot) -> [String: Int] {
        guard operation.sentAny, case .add = operation.intent else { return [:] }
        var counts: [String: Int] = [:]
        for occurrence in remote.occurrences where !operation.preIDs.contains(occurrence.setVideoID) { counts[occurrence.videoID, default: 0] += 1 }
        return counts
    }

    private func buildUndo(for id: UUID, before: PlaylistSnapshot, after: PlaylistSnapshot) {
        guard let operation = operation(id), !operation.isUndo else { if operation(id)?.isUndo == true { undo = nil }; return }
        let reverse: PlaylistIntent?
        let label: String
        switch operation.intent {
        case .add(let songs, _):
            let wanted = Set(songs.map(\.videoID))
            let fresh = after.occurrences.filter { !operation.preIDs.contains($0.setVideoID) && wanted.contains($0.videoID) }
            reverse = fresh.isEmpty ? nil : .remove(fresh.map { PlaylistOccurrence(setVideoID: $0.setVideoID, videoID: $0.videoID, title: $0.title, removable: true) })
            label = String(localized: "Undo: added \(fresh.count) songs")
        case .remove(let songs):
            let gone = songs.filter { after.occurrence($0.setVideoID) == nil && before.occurrence($0.setVideoID) != nil }
            reverse = gone.isEmpty ? nil : .add(gone.map { PlaylistAddition(videoID: $0.videoID, title: $0.title) }, .keepDuplicates)
            label = String(localized: "Undo: removed \(gone.count) songs")
        case .move(let song, _):
            guard let index = operation.base.index(of: song.setVideoID) else { reverse = nil; label = ""; break }
            let next = index + 1 < operation.base.occurrences.count ? operation.base.occurrences[index + 1] : nil
            reverse = after.occurrence(song.setVideoID) == nil ? nil : .move(song, before: next)
            label = String(localized: "Undo: moved “\(song.title)”")
        case .rename:
            reverse = .rename(operation.base.title); label = String(localized: "Undo: renamed the playlist")
        case .describe:
            reverse = .describe(operation.base.details); label = String(localized: "Undo: changed the description")
        case .setPrivacy:
            reverse = operation.base.privacy.map { .setPrivacy($0) }; label = String(localized: "Undo: changed the visibility")
        }
        undo = reverse.map { PlaylistUndo(operationID: id, intent: $0, label: label) }
    }
    private func report(from before: PlaylistSnapshot, to after: PlaylistSnapshot) {
        let was = Set(before.occurrences.map(\.setVideoID)), now = Set(after.occurrences.map(\.setVideoID))
        let added = after.occurrences.filter { !was.contains($0.setVideoID) }, removed = before.occurrences.filter { !now.contains($0.setVideoID) }
        guard !added.isEmpty || !removed.isEmpty else { return }
        onMembershipChange?(PlaylistMembershipChange(playlistID: playlistID, added: added, removed: removed))
    }
    /// A local estimate of one confirmed action when the read-back failed. Songs added get their reported occurrence ids if the service gave
    /// them, otherwise placeholders that cannot be targeted until the next read.
    private static func estimate(_ snapshot: PlaylistSnapshot, _ action: MusicPlaylistEditAction, reported: [MusicPlaylistAddedOccurrence]) -> PlaylistSnapshot {
        var result = snapshot
        switch action {
        case .add(let video, _):
            let known = Set(result.occurrences.map(\.setVideoID))
            if let given = reported.first(where: { $0.videoID == video && !known.contains($0.setVideoID) }) {
                result.occurrences.append(PlaylistOccurrence(setVideoID: given.setVideoID, videoID: video, title: video, removable: false))
            } else {
                result.occurrences.append(PlaylistOccurrence(setVideoID: PlaylistOccurrence.placeholderPrefix + "estimate:" + String(result.occurrences.count), videoID: video, title: video, removable: false))
            }
        case .remove(_, let set): result.occurrences.removeAll { $0.setVideoID == set }
        case .moveBefore(let set, let successor):
            guard let from = result.index(of: set) else { break }
            let moved = result.occurrences.remove(at: from)
            if let successor, let to = result.index(of: successor) { result.occurrences.insert(moved, at: to) } else { result.occurrences.append(moved) }
        case .rename(let title): result.title = title
        case .describe(let text): result.details = text
        case .setPrivacy(let privacy): result.privacy = privacy
        case .createInviteLink, .closeToContributions, .joinCollaboration: break
        }
        return result
    }

    // MARK: Conflicts

    /// "Mine" for a piece of a change: the person's own base with only that piece applied.
    private func conflictView(_ operation: PlaylistOperation) -> (PlaylistIntent) -> PlaylistSnapshot {
        let base = operation.base
        return { piece in base.applying(piece) }
    }
    private func drop(_ conflict: PlaylistConflict, settle: Bool = true) {
        conflicts.removeAll { $0.id == conflict.id }
        guard settle else { return }
        let left = conflicts.contains { $0.operationID == conflict.operationID }
        update(conflict.operationID) { if $0.state == .conflicted && !left { $0.state = .confirmed } }
    }

    // MARK: Rules

    /// Whether the service offered this person this change on this playlist. A removal also needs the row's own remove command.
    static func permits(_ intent: PlaylistIntent, in snapshot: PlaylistSnapshot) -> Bool {
        guard snapshot.role.canEdit, let editing = snapshot.editing else { return false }
        switch intent {
        case .add: return editing.canEditTracks
        case .remove(let songs): return editing.canEditTracks && songs.allSatisfy { snapshot.occurrence($0.setVideoID).map(\.removable) ?? true }
        case .move: return editing.canEditTracks
        case .rename, .describe, .setPrivacy: return editing.canEditDetails
        }
    }
    static func isValid(_ intent: PlaylistIntent) -> Bool {
        switch intent {
        case .add(let songs, _): return !songs.isEmpty && songs.count <= MusicPlaylistRequest.maximumActions && songs.allSatisfy { MusicPlaylistRequest.isVideoID($0.videoID) }
        case .remove(let songs):
            return !songs.isEmpty && songs.count <= MusicPlaylistRequest.maximumActions
                && songs.allSatisfy { MusicPlaylistRequest.isVideoID($0.videoID) && MusicPlaylistRequest.isOccurrenceID($0.setVideoID) && !$0.isPlaceholder }
        case .move(let song, let anchor):
            return !song.isPlaceholder && anchor?.isPlaceholder != true && song.setVideoID != anchor?.setVideoID
        case .rename(let title): return MusicPlaylistRequest.edit(playlistID: "PL12345678", actions: [.rename(title)]).isWellFormed
        case .describe(let text): return MusicPlaylistRequest.edit(playlistID: "PL12345678", actions: [.describe(text)]).isWellFormed
        case .setPrivacy: return true
        }
    }
    private func update(_ id: UUID, _ change: (inout PlaylistOperation) -> Void) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        change(&operations[index])
    }

    static func failure(for rejection: MusicWriteRejection) -> PlaylistFailure {
        switch rejection { case .service: .refused; case .rateLimited: .rateLimited; case .unavailable: .unavailable }
    }
    static func failure(for error: any Error, reading: Bool) -> PlaylistFailure {
        guard let error = error as? MusicSessionError else { return reading ? .couldNotRead : .unavailable }
        switch error {
        case .signedOut: return .sessionEnded
        case .notSignedIn: return .needsSignIn
        case .network, .timedOut: return .offline
        case .rateLimited: return .rateLimited
        case .policy: return .notPermitted
        default: return reading ? .couldNotRead : .unavailable
        }
    }
    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? MusicSessionError) == .cancelled || (error as? MusicSessionError) == .stale
    }
}
