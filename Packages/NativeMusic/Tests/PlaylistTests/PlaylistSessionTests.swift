import AccountSession
import Foundation
import Testing
@testable import Features

private func v(_ n: Int) -> String { FakePlaylistRemote.video(n) }
@MainActor private func standardRemote(_ count: Int = 8, pageSize: Int = 4) async -> FakePlaylistRemote {
    let remote = FakePlaylistRemote(rows: FakePlaylistRemote.rows((0..<count).map(v)))
    await remote.setPageSize(pageSize)
    return remote
}
@MainActor private func song(_ session: PlaylistEditSession, _ index: Int) -> PlaylistOccurrence { session.snapshot!.occurrences[index] }
private func additions(_ videos: [Int]) -> [PlaylistAddition] { videos.map { PlaylistAddition(videoID: v($0), title: "Song \(v($0))") } }
@MainActor private func confirmation(_ session: PlaylistEditSession, _ intent: PlaylistIntent) -> PlaylistPrompt? { intent.prompt(playlistTitle: session.snapshot!.title) }
private let initial = ["S0", "S1", "S2", "S3", "S4", "S5", "S6", "S7"]

// MARK: T13.4 — permissions, confirmation, duplicates, private create, share

@Suite @MainActor struct PlaylistPermissionTests {
    @Test func aPlaylistTheServiceOffersNoEditingForIsNeverChangedAndNothingIsSent() async throws {
        let remote = await standardRemote()
        await remote.setEditing(nil)
        let session = await loadedSession(remote)
        #expect(session.role == .viewer && !session.role.canEdit)
        let intents: [PlaylistIntent] = [.add(additions([20]), .keepDuplicates), .remove([song(session, 0)]), .move(song(session, 0), before: nil), .rename("x"), .describe("x"), .setPrivacy(.public)]
        for intent in intents { await session.submit(intent) }
        #expect(session.operations.count == intents.count)
        #expect(session.operations.allSatisfy { $0.state == .failed(.notPermitted) })
        let state = await remote.state()
        #expect(state.requests.isEmpty)
        #expect(session.sentCount == 0)
        await session.deletePlaylist(confirmation: session.deletionPrompt)
        #expect(session.deletion == .failed(.notPermitted))
        #expect(session.sentCount == 0)
    }
    @Test func aCollaboratorChangesTracksButNotDetailsOrExistence() async throws {
        let remote = await standardRemote()
        await remote.setEditing(MusicPlaylistEditing(canEditTracks: true, canEditDetails: false, canDelete: false, privacy: .public))
        let session = await loadedSession(remote)
        #expect(session.role == .collaborator)
        await session.submit(.add(additions([20]), .keepDuplicates))
        #expect(session.operations.last?.state == .confirmed)
        await session.submit(.rename("nope"))
        #expect(session.operations.last?.state == .failed(.notPermitted))
        await session.deletePlaylist(confirmation: session.deletionPrompt)
        #expect(session.deletion == .failed(.notPermitted))
        let state = await remote.state()
        #expect(state.requests.count == 1, "only the one permitted change was sent")
    }
    @Test func anOwnerCanDoEverythingButDeletionNeedsTheConfirmationNamingThePlaylist() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        #expect(session.role == .owner)
        await session.submit(.rename("Renamed")); await session.submit(.setPrivacy(.unlisted)); await session.submit(.describe("About"))
        #expect(session.operations.allSatisfy { $0.state == .confirmed })
        var state = await remote.state()
        #expect(state.title == "Renamed")
        #expect(state.privacy == .unlisted)
        #expect(state.details == "About")
        await session.deletePlaylist(confirmation: nil)
        #expect(session.deletion == .failed(.needsConfirmation))
        let wrong = PlaylistPrompt(action: .deletePlaylist, playlistTitle: "Another", count: 1, names: ["Another"])
        await session.deletePlaylist(confirmation: wrong)
        #expect(session.deletion == .failed(.needsConfirmation))
        state = await remote.state()
        #expect(!state.requests.contains { if case .delete = $0 { true } else { false } }, "no delete left without the exact confirmation")
        session.dismissDeletionFailure()
        let prompt = try #require(session.deletionPrompt)
        #expect(prompt.names == ["Renamed"])
        #expect(prompt.isDestructive)
        await session.deletePlaylist(confirmation: prompt)
        state = await remote.state()
        #expect(session.deletion == .confirmed)
        #expect(state.deleted)
    }
    @Test func aRowWithNoRemoveCommandIsNotRemovable() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let unremovable = PlaylistOccurrence(setVideoID: "S1", videoID: v(1), title: "x", removable: false)
        var snapshot = try #require(session.snapshot)
        snapshot.occurrences[1] = unremovable
        #expect(!PlaylistEditSession.permits(.remove([unremovable]), in: snapshot))
        #expect(PlaylistEditSession.permits(.remove([snapshot.occurrences[0]]), in: snapshot))
    }
    @Test func aBulkChangeNeedsTheConfirmationThatNamesItsSelection() async throws {
        let remote = await standardRemote(10)
        let session = await loadedSession(remote)
        let selection = [song(session, 1), song(session, 2), song(session, 3)]
        let intent = PlaylistIntent.remove(selection)
        await session.submit(intent)
        #expect(session.operations.last?.state == .failed(.needsConfirmation))
        #expect(session.sentCount == 0)
        // A dialog that named a different selection does not confirm this one.
        let other = PlaylistIntent.remove([song(session, 4), song(session, 5), song(session, 6)])
        await session.submit(intent, confirmation: other.prompt(playlistTitle: session.snapshot!.title))
        #expect(session.operations.last?.state == .failed(.needsConfirmation))
        #expect(session.sentCount == 0)
        let prompt = try #require(confirmation(session, intent))
        #expect(prompt.count == 3)
        #expect(prompt.names == selection.map(\.title))
        #expect(prompt.action == .remove)
        #expect(prompt.isDestructive)
        await session.submit(intent, confirmation: prompt)
        #expect(session.operations.last?.state == .confirmed)
        #expect(session.sentCount == 1)
        let state = await remote.state()
        #expect(state.ids == ["S0", "S4", "S5", "S6", "S7", "S8", "S9"])
    }
    @Test func theConfirmationNamesTheFirstFiveAndCountsTheRest() throws {
        let songs = (0..<8).map { PlaylistOccurrence(setVideoID: "S\($0)", videoID: v($0), title: "Title \($0)") }
        let prompt = try #require(PlaylistIntent.remove(songs).prompt(playlistTitle: "Mix"))
        #expect(prompt.shownNames == ["Title 0", "Title 1", "Title 2", "Title 3", "Title 4"])
        #expect(prompt.hiddenCount == 3)
        #expect(prompt.count == 8)
        #expect(PlaylistIntent.remove([songs[0]]).prompt(playlistTitle: "Mix") == nil, "a single song needs no selection confirmation")
        #expect(PlaylistIntent.rename("x").prompt(playlistTitle: "Mix") == nil)
        #expect(PlaylistIntent.add(additions([1, 2]), .keepDuplicates).prompt(playlistTitle: "Mix")?.action == .add)
    }
    @Test func keepDuplicatesAddsASecondOccurrenceAndSkipExistingLeavesItOut() async throws {
        let keep = await standardRemote()
        let keeping = await loadedSession(keep)
        let intent = PlaylistIntent.add(additions([0, 20]), .keepDuplicates)
        await keeping.submit(intent, confirmation: confirmation(keeping, intent))
        var state = await keep.state()
        #expect(state.count(of: v(0)) == 2, "the song is now in the playlist twice")
        #expect(Set(state.ids).count == 10, "each occurrence has its own id")
        #expect(state.lastActions == [.add(videoID: v(0), duplicates: .keepDuplicates), .add(videoID: v(20), duplicates: .keepDuplicates)])

        let skip = await standardRemote()
        let skipping = await loadedSession(skip)
        let skipIntent = PlaylistIntent.add(additions([0, 20]), .skipExisting)
        await skipping.submit(skipIntent, confirmation: confirmation(skipping, skipIntent))
        state = await skip.state()
        #expect(state.count(of: v(0)) == 1)
        #expect(skipping.operations.last?.satisfied == ["Song \(v(0))"], "the song left out is named")
        #expect(state.lastActions == [.add(videoID: v(20), duplicates: .skipExisting)])
        // When everything is already there, nothing is sent at all.
        let sent = skipping.sentCount
        await skipping.submit(.add(additions([0]), .skipExisting))
        #expect(skipping.sentCount == sent)
        #expect(skipping.operations.last?.state == .confirmed)
    }
    @Test func aNewPlaylistIsPrivateUnlessThePersonChoosesOtherwise() async throws {
        #expect(PlaylistCreator.defaultPrivacy == .private)
        let remote = await standardRemote()
        let creator = PlaylistCreator(service: remote)
        await creator.create(title: "  New one  ")
        guard case .created(let id) = creator.state else { Issue.record("not created: \(creator.state)"); return }
        #expect(id.hasPrefix("PLcreated"))
        var state = await remote.state()
        guard case .create(let title, _, let privacy, let videos)? = state.requests.last else { Issue.record("no create sent"); return }
        #expect(title == "New one")
        #expect(privacy == .private)
        #expect(videos.isEmpty)
        creator.reset()
        await creator.create(title: "Shared", privacy: .unlisted, songs: additions([1, 2]))
        state = await remote.state()
        if case .create(_, _, let chosen, let seeded)? = state.requests.last { #expect(chosen == .unlisted); #expect(seeded == [v(1), v(2)]) } else { Issue.record("no create") }
    }
    @Test func aCreateWithAnInvalidTitleSendsNothing() async throws {
        let remote = await standardRemote()
        let creator = PlaylistCreator(service: remote)
        for bad in ["", "   ", "<b>", String(repeating: "x", count: 151)] {
            creator.reset(); await creator.create(title: bad)
            #expect(creator.state == .failed(.invalid), Comment(rawValue: bad))
        }
        let state = await remote.state()
        #expect(state.requests.isEmpty)
    }
    @Test func sharingNeedsAnExplicitActionAndTheLinkIsCanonicalAndValidated() throws {
        let id = "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"
        #expect(PlaylistSharing.canonicalURL(playlistID: id)?.absoluteString == "https://music.youtube.com/playlist?list=\(id)")
        #expect(PlaylistSharing.canonicalURL(playlistID: "VL" + id) == PlaylistSharing.canonicalURL(playlistID: id))
        for bad in ["", "short", "PL bad id here", "PL../../x00000"] { #expect(PlaylistSharing.canonicalURL(playlistID: bad) == nil, Comment(rawValue: bad)) }
        let good = ["https://music.youtube.com/playlist?list=\(id)", "https://www.youtube.com/playlist?list=\(id)&si=tracking", "https://m.youtube.com/playlist?list=\(id)"]
        for link in good { #expect(PlaylistSharing.playlistID(fromLink: link) == id, Comment(rawValue: link)) }
        let bad = ["http://music.youtube.com/playlist?list=\(id)", "https://evil.example/playlist?list=\(id)", "https://music.youtube.com.evil.example/playlist?list=\(id)",
                   "https://user@music.youtube.com/playlist?list=\(id)", "https://music.youtube.com:444/playlist?list=\(id)", "https://music.youtube.com/watch?list=\(id)",
                   "https://music.youtube.com/playlist?list=\(id)&list=PLother00000000000", "https://music.youtube.com/playlist", "javascript:alert(1)", "https://music.youtube.com/playlist?list=short#frag"]
        for link in bad { #expect(PlaylistSharing.playlistID(fromLink: link) == nil, Comment(rawValue: link)) }
        #expect(PlaylistSharing.note(for: .private)?.contains("only you") == true)
        #expect(PlaylistSharing.note(for: nil) == nil)
    }
}

// MARK: T13.2 — a submitted add whose answer never arrives is read back before it is ever sent again

@Suite @MainActor struct PlaylistRetryTests {
    private func addOne(_ session: PlaylistEditSession) async -> UUID {
        await session.submit(.add(additions([20]), .keepDuplicates))
        return session.operations.last!.id
    }
    @Test func aLostReplyAfterTheServiceAppliedItIsSettledByReadingAndNeverAddedTwice() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.lostReplyAfterApplying])
        let session = await loadedSession(remote)
        let id = await addOne(session)
        #expect(session.operation(id)?.state == .needsReconciliation)
        #expect(session.displayed?.occurrences.count == 9, "the add is shown as made while its outcome is unknown")
        #expect(session.displayed?.occurrences.last?.isPlaceholder == true)
        #expect(session.snapshot?.occurrences.count == 8)
        await session.check(id)
        #expect(session.operation(id)?.state == .confirmed)
        await session.retry(id)
        #expect(session.operation(id)?.state == .confirmed, "a confirmed change is not retried")
        let state = await remote.state()
        #expect(state.requests.count == 1)
        #expect(session.sentCount == 1)
        #expect(state.count(of: v(20)) == 1)
        #expect(session.snapshot?.occurrences.count == 9)
        #expect(session.snapshot?.occurrences.last?.isPlaceholder == false, "the new occurrence has the service's own id")
    }
    @Test func retryingStraightAwayReadsFirstAndSendsNothingWhenTheAddIsThere() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.lostReplyAfterApplying])
        let session = await loadedSession(remote)
        let id = await addOne(session)
        await session.retry(id)
        #expect(session.operation(id)?.state == .confirmed)
        let state = await remote.state()
        #expect(session.sentCount == 1)
        #expect(state.requests.count == 1, "no second add left")
        #expect(state.count(of: v(20)) == 1)
    }
    @Test func aLostRequestIsFoundNotAppliedAndTryAgainThenAddsItOnce() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.lostReplyBeforeApplying])
        let session = await loadedSession(remote)
        let id = await addOne(session)
        await session.check(id)
        #expect(session.operation(id)?.state == .failed(.notApplied))
        #expect(session.displayed?.occurrences.count == 8, "rolled back")
        await session.retry(id)
        #expect(session.operation(id)?.state == .confirmed)
        let state = await remote.state()
        #expect(state.requests.count == 2)
        #expect(state.count(of: v(20)) == 1)
    }
    @Test func aPartlyAppliedAddSendsOnlyWhatIsMissing() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.partialThenLost(count: 1)])
        let session = await loadedSession(remote)
        let intent = PlaylistIntent.add(additions([20, 21, 22]), .keepDuplicates)
        await session.submit(intent, confirmation: confirmation(session, intent))
        let id = try #require(session.operations.last?.id)
        await session.check(id)
        #expect(session.operation(id)?.state == .failed(.partlyApplied))
        await session.retry(id)
        #expect(session.operation(id)?.state == .confirmed)
        let state = await remote.state()
        #expect(state.lastActions == [.add(videoID: v(21), duplicates: .keepDuplicates), .add(videoID: v(22), duplicates: .keepDuplicates)], "only the two missing songs")
        for n in [20, 21, 22] { #expect(state.count(of: v(n)) == 1, Comment(rawValue: "song \(n) exactly once")) }
    }
    @Test func anOccurrenceOfTheSameSongThatWasAlreadyThereIsNotMistakenForTheNewOne() async throws {
        // The playlist already holds song 0. A duplicate add is lost before applying: song 0 is "there", but not as a NEW occurrence.
        let lost = await standardRemote()
        await lost.setFaults([.lostReplyBeforeApplying])
        let session = await loadedSession(lost)
        await session.submit(.add(additions([0]), .keepDuplicates))
        let id = try #require(session.operations.last?.id)
        await session.check(id)
        #expect(session.operation(id)?.state == .failed(.notApplied), "the old occurrence is not evidence the add happened")
        await session.retry(id)
        var state = await lost.state()
        #expect(state.count(of: v(0)) == 2)
        // And when it did apply, the new occurrence is what confirms it.
        let applied = await standardRemote()
        await applied.setFaults([.lostReplyAfterApplying])
        let second = await loadedSession(applied)
        await second.submit(.add(additions([0]), .keepDuplicates))
        let secondID = try #require(second.operations.last?.id)
        await second.check(secondID)
        state = await applied.state()
        #expect(second.operation(secondID)?.state == .confirmed)
        #expect(state.count(of: v(0)) == 2)
    }
    @Test func anAnswerTheAppCannotReadIsTreatedLikeALostReply() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.unreadableAfterApplying])
        let session = await loadedSession(remote)
        let id = await addOne(session)
        #expect(session.operation(id)?.state == .needsReconciliation)
        await session.retry(id)
        #expect(session.operation(id)?.state == .confirmed)
        #expect(session.sentCount == 1)
    }
    @Test func whenThePlaylistCannotBeReadNothingIsSentAgain() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.lostReplyAfterApplying])
        let session = await loadedSession(remote)
        let id = await addOne(session)
        await remote.failNextReads(1)
        await session.check(id)
        #expect(session.operation(id)?.state == .needsReconciliation)
        #expect(session.operation(id)?.checkedUnreadable == true)
        await remote.failNextReads(1)
        await session.retry(id)
        #expect(session.operation(id)?.state == .needsReconciliation, "an unknown outcome stays unknown")
        let state = await remote.state()
        #expect(session.sentCount == 1)
        #expect(state.requests.count == 1, "an add is never replayed without a successful read")
        // Another change cannot be made on top of an unsettled one.
        await session.submit(.rename("x"))
        #expect(session.operations.count == 1)
        session.dismissUnconfirmed(id)
        #expect(session.operations.isEmpty)
    }
    @Test func aDeleteWhoseListLagsIsNotCalledNotAppliedFromOneRead() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.lostReplyAfterApplying])
        let session = await loadedSession(remote)
        await session.deletePlaylist(confirmation: session.deletionPrompt)
        #expect(session.deletion == .needsReconciliation)
        await remote.setListed([PlaylistListing(playlistID: remote.playlistID, title: "Fixture playlist")])    // the library list lags: it still shows it
        await session.checkDeletion()
        #expect(session.deletion == .needsReconciliation, "one read that still lists it is \u{201C}not seen gone yet\u{201D}")
        #expect(session.deletionStillListedReads == 1)
        await session.checkDeletion()
        #expect(session.deletion == .failed(.notApplied), "two in a row")
        let state = await remote.state()
        #expect(state.requests.count == 1)
    }
    @Test func aRefusalRollsBackAndSaysSoAndOfflineChangesNothingAndIsNotQueued() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.refuse, .offline])
        let session = await loadedSession(remote)
        let first = await addOne(session)
        #expect(session.operation(first)?.state == .failed(.refused))
        #expect(session.displayed?.occurrences.count == 8)
        session.dismiss(first)
        let second = await addOne(session)
        #expect(session.operation(second)?.state == .failed(.offline))
        var state = await remote.state()
        #expect(state.rows.count == 8)
        #expect(!session.operations.contains { $0.state == .pending })
        await session.retry(second)
        state = await remote.state()
        #expect(session.operation(second)?.state == .confirmed)
        #expect(state.rows.count == 9, "an explicit retry sends it; nothing waited in a queue")
    }
    @Test func aRetryAfterARequestThatNeverLeftDoesNotMistakeSomeoneElsesAddForItsOwn() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.offline])
        let session = await loadedSession(remote)
        let id = await addOne(session)
        #expect(session.operation(id)?.state == .failed(.offline))
        _ = await remote.remoteAdd(v(20))                     // a collaborator added the same song meanwhile
        await session.retry(id)
        let state = await remote.state()
        #expect(session.operation(id)?.state == .confirmed)
        #expect(state.count(of: v(20)) == 2, "the person's own add still happened: nothing of theirs was sent before, so nothing of ours is found")
    }
    @Test func aRequestCancelledInFlightIsAnUnknownOutcomeNotANotSentOne() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.cancelledAfterApplying])
        let session = await loadedSession(remote)
        let id = await addOne(session)
        #expect(session.operation(id)?.state == .needsReconciliation, "the request may have been applied")
        await session.check(id)
        #expect(session.operation(id)?.state == .confirmed)
        let state = await remote.state()
        #expect(state.count(of: v(20)) == 1)
    }
    @Test func aReadBackThatFinishesAfterAnAccountSwitchIsDiscarded() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await remote.holdRead(number: 3)                       // load = 1, the precondition read = 2, the read-back = 3
        let task = Task { await session.submit(.rename("Late")) }
        while !(await remote.isReadHeld) { await Task.yield() }
        // The change was sent and confirmed; its read-back is in flight when the account changes.
        session.accountChanged()
        await remote.releaseRead()
        await task.value
        #expect(session.snapshot == nil)
        #expect(session.operations.isEmpty)
    }
    @Test func aConfirmedChangeWhoseReadBackFailsIsShownAsAnEstimateThatNeedsARefresh() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        // The read before the send succeeds; the read-back after it fails.
        await remote.setAfterRead([{ remote in remote.failReads = 1 }])
        await session.submit(.rename("Renamed"))
        #expect(session.operations.last?.state == .confirmed)
        #expect(session.needsRefresh)
        #expect(session.snapshot?.title == "Renamed")
        await session.refresh()
        #expect(!session.needsRefresh)
    }
    @Test func membershipChangesAreReportedOnceForDownloadsAndRetentionIsNotImplementedHere() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        var changes: [PlaylistMembershipChange] = []
        session.onMembershipChange = { changes.append($0) }
        await session.submit(.add(additions([20]), .keepDuplicates))
        await session.submit(.remove([song(session, 0)]))
        await session.submit(.rename("No membership change"))
        #expect(changes.count == 2)
        #expect(changes[0].added.map(\.videoID) == [v(20)])
        #expect(changes[0].removed.isEmpty)
        #expect(changes[1].removed.map(\.setVideoID) == ["S0"])
        #expect(changes[1].added.isEmpty)
    }
    @Test func anAnswerForAnotherAccountScopeIsDiscarded() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await remote.holdNextApply()
        let task = Task { await session.submit(.rename("Late")) }
        while !(await remote.isHeld) { await Task.yield() }
        session.accountChanged()
        await remote.release()
        await task.value
        #expect(session.operations.isEmpty)
        #expect(session.snapshot == nil)
        #expect(session.conflicts.isEmpty, "the late answer changed nothing in the new scope")
    }
}

// MARK: T13.3 — concurrent remote changes merge when they do not collide and ask when they do

@Suite @MainActor struct PlaylistConcurrencyTests {
    @Test func aReorderElsewhereDoesNotMoveYourChangeToTheWrongPlace() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let (moving, anchor) = (song(session, 2), song(session, 4))
        await remote.remoteMove("S6", before: "S0")          // somebody else moved another song to the front
        await session.submit(.move(moving, before: anchor))
        #expect(session.operations.last?.state == .confirmed)
        #expect(session.conflicts.isEmpty)
        let state = await remote.state()
        #expect(state.lastActions == [.moveBefore(setVideoID: "S2", successorSetVideoID: "S4")], "one action naming one occurrence, never a full order")
        #expect(state.ids == ["S6", "S0", "S1", "S3", "S2", "S4", "S5", "S7"], "their move is kept and ours landed before S4")
        #expect(state.requests.count == 1)
        #expect(session.operations.last?.mergedWithRemoteChanges == true, "the precondition check saw a different version and said the change was merged")
        await session.submit(.rename("Plain"))
        #expect(session.operations.last?.mergedWithRemoteChanges == false, "nothing changed elsewhere this time")
    }
    @Test func theSameSongMovedElsewhereToo_KeepsBothSnapshotsAndAsksAboutThatOneSong() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let (moving, anchor) = (song(session, 2), song(session, 4))
        await remote.remoteMove("S2", before: nil)
        await session.submit(.move(moving, before: anchor))
        #expect(session.operations.last?.state == .conflicted)
        #expect(session.sentCount == 0, "nothing was sent for the colliding piece")
        let conflict = try #require(session.conflicts.first)
        #expect(conflict.kind == .movedElsewhere(occurrence: moving))
        #expect(conflict.mine.occurrences.map(\.setVideoID) == ["S0", "S1", "S3", "S2", "S4", "S5", "S6", "S7"], "my view is kept")
        #expect(conflict.theirs.occurrences.map(\.setVideoID) == ["S0", "S1", "S3", "S4", "S5", "S6", "S7", "S2"], "their view is kept")
        #expect(conflict.summary.contains(moving.title))
        #expect(session.snapshot == conflict.theirs, "the settled view is the service's")
        await session.resolve(conflict.id, .keepTheirs)
        #expect(session.conflicts.isEmpty)
        #expect(session.operations.last?.state == .confirmed)
        let state = await remote.state()
        #expect(state.requests.isEmpty)
        #expect(state.ids.last == "S2")
    }
    @Test func keepingMineSendsOnlyThatOneMove() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let (moving, anchor) = (song(session, 2), song(session, 4))
        await remote.remoteMove("S2", before: nil)
        await remote.remoteMove("S7", before: "S0")
        await session.submit(.move(moving, before: anchor))
        let conflict = try #require(session.conflicts.first)
        await session.resolve(conflict.id, .keepMine)
        let state = await remote.state()
        #expect(state.lastActions == [.moveBefore(setVideoID: "S2", successorSetVideoID: "S4")])
        #expect(state.ids == ["S7", "S0", "S1", "S3", "S2", "S4", "S5", "S6"], "their other change survived")
        #expect(session.conflicts.isEmpty)
        #expect(session.operations.last?.state == .confirmed)
    }
    @Test func aMoveBeforeASongThatWasRemovedLandsBeforeTheNextOneThatSurvives() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let (moving, anchor) = (song(session, 2), song(session, 4))
        await remote.remoteRemove("S4")
        await session.submit(.move(moving, before: anchor))
        let state = await remote.state()
        #expect(state.lastActions == [.moveBefore(setVideoID: "S2", successorSetVideoID: "S5")])
        #expect(state.ids == ["S0", "S1", "S3", "S2", "S5", "S6", "S7"])
        #expect(session.conflicts.isEmpty)
    }
    @Test func aMoveBeforeTheLastSongThatWasRemovedGoesToTheEnd() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let (moving, anchor) = (song(session, 2), song(session, 7))
        await remote.remoteRemove("S7")
        await session.submit(.move(moving, before: anchor))
        let state = await remote.state()
        #expect(state.lastActions == [.moveBefore(setVideoID: "S2", successorSetVideoID: nil)], "no later song survives, so the end")
        #expect(state.ids == ["S0", "S1", "S3", "S4", "S5", "S6", "S2"])
    }
    @Test func aMoveOfASongThatWasRemovedElsewhereOffersOnlyToLeaveItGone() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let moving = song(session, 2)
        await remote.remoteRemove("S2")
        await session.submit(.move(moving, before: song(session, 4)))
        let conflict = try #require(session.conflicts.first)
        #expect(conflict.kind == .occurrenceRemoved(occurrence: moving))
        #expect(PlaylistReconciler.forcedAction(for: conflict) == nil)
        await session.resolve(conflict.id, .keepMine)
        #expect(session.conflicts.count == 1)
        #expect(session.sentCount == 0, "there is nothing to keep: the song is gone")
        await session.resolve(conflict.id, .keepTheirs)
        #expect(session.conflicts.isEmpty)
    }
    @Test func aBulkRemovalSkipsWhatIsAlreadyGoneAndRemovesTheRest() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let intent = PlaylistIntent.remove([song(session, 1), song(session, 2), song(session, 3)])
        await remote.remoteRemove("S2")
        await session.submit(intent, confirmation: confirmation(session, intent))
        #expect(session.operations.last?.state == .confirmed)
        #expect(session.operations.last?.satisfied == ["Song \(v(2))"])
        let state = await remote.state()
        #expect(state.lastActions == [.remove(videoID: v(1), setVideoID: "S1"), .remove(videoID: v(3), setVideoID: "S3")])
        #expect(state.ids == ["S0", "S4", "S5", "S6", "S7"], "every unrelated entry untouched and in order")
    }
    @Test func aRenameThatDoesNotCollideIsMergedWithAChangeToTheVisibility() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await remote.remoteSetPrivacy(.public)                  // somebody changed the visibility
        await session.submit(.rename("Mine"))
        let state = await remote.state()
        #expect(session.operations.last?.state == .confirmed)
        #expect(session.conflicts.isEmpty)
        #expect(state.title == "Mine")
        #expect(state.privacy == .public)
    }
    @Test func twoSidesRenamingKeepsBothTitlesUntilThePersonChooses() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await remote.remoteRename("Theirs")
        await session.submit(.rename("Mine"))
        let conflict = try #require(session.conflicts.first)
        #expect(conflict.kind == .titleChanged(theirs: "Theirs"))
        #expect(conflict.mine.title == "Mine")
        #expect(conflict.theirs.title == "Theirs")
        var state = await remote.state()
        #expect(state.title == "Theirs")
        #expect(session.sentCount == 0)
        await session.resolve(conflict.id, .keepMine)
        state = await remote.state()
        #expect(state.title == "Mine")
        #expect(session.conflicts.isEmpty)
    }
    @Test func anAdjacentSwapElsewhereIsAmbiguousAndAsked() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let moving = song(session, 0)
        await remote.remoteMove("S1", before: "S0")             // S0 and S1 swapped: which one moved is not knowable
        await session.submit(.move(moving, before: nil))
        #expect(session.conflicts.count == 1)
        #expect(session.sentCount == 0)
    }
    @Test func aSongAddedElsewhereBetweenTheReadAndTheSendIsRefusedByTheServiceNotDuplicated() async throws {
        // Skip existing is sent without the option that keeps duplicates, so a song that appeared after the precondition read is refused
        // by the service instead of duplicated; the playlist then shows it is there and the change is satisfied.
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await remote.setAfterRead([{ r in _ = r.remoteAdd(v(20)) }])
        await session.submit(.add(additions([20]), .skipExisting))
        let state = await remote.state()
        #expect(state.count(of: v(20)) == 1, "no duplicate was made")
        #expect(session.operations.last?.state == .confirmed)
        #expect(session.operations.last?.satisfied == ["Song \(v(20))"])
        #expect(session.snapshot?.count(ofVideo: v(20)) == 1)
        // A refusal that is not about a duplicate is still a failure.
        let other = await standardRemote()
        await other.setFaults([.refuse])
        let again = await loadedSession(other)
        await again.submit(.add(additions([21]), .skipExisting))
        #expect(again.operations.last?.state == .failed(.refused))
    }
    @Test func keepingADuplicateSendsTheOptionThatLetsItIn() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await session.submit(.add(additions([0]), .keepDuplicates))
        let state = await remote.state()
        #expect(state.count(of: v(0)) == 2)
        #expect(session.operations.last?.state == .confirmed)
        // The service's rule, modelled by the fake: without that option the same add is refused and nothing is added.
        let twice = await standardRemote()
        let outcome = try await twice.apply(.edit(playlistID: twice.playlistID, actions: [.add(videoID: v(0), duplicates: .skipExisting)]))
        #expect(outcome.result.outcome == .rejected(.service))
        let after = await twice.state()
        #expect(after.rows.count == 8)
    }
    @Test func keepMyChangeIsCheckedAgainstTheRightsThePlaylistShowsNow() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let (moving, anchor) = (song(session, 2), song(session, 4))
        await remote.remoteMove("S2", before: nil)
        await session.submit(.move(moving, before: anchor))
        let conflict = try #require(session.conflicts.first)
        // The person's rights are withdrawn between the question and the answer.
        await remote.setEditing(nil)
        await session.resolve(conflict.id, .keepMine)
        let state = await remote.state()
        #expect(state.requests.isEmpty, "nothing was sent to a playlist the service no longer lets them change")
        #expect(session.operations.last?.state == .failed(.notPermitted))
        #expect(session.conflicts.isEmpty)
        // Signed out: not sent either.
        let second = await standardRemote()
        nonisolated(unsafe) var expired = false
        let signedIn = PlaylistEditSession(playlistID: second.playlistID, service: second, accountScope: { "s" }, signedIn: { expired ? .sessionExpired : .available })
        await signedIn.load()
        let other = signedIn.snapshot!.occurrences[2], target = signedIn.snapshot!.occurrences[4]
        await second.remoteMove("S2", before: nil)
        await signedIn.submit(.move(other, before: target))
        let question = try #require(signedIn.conflicts.first)
        expired = true
        await signedIn.resolve(question.id, .keepMine)
        let sent = await second.state()
        #expect(sent.requests.isEmpty)
        #expect(signedIn.operations.last?.state == .failed(.sessionEnded))
        // And a session that was never signed in (needs sign-in) is not sent a write either.
        let third = await standardRemote()
        nonisolated(unsafe) var signedOut = false
        let anonymous = PlaylistEditSession(playlistID: third.playlistID, service: third, accountScope: { "s" }, signedIn: { signedOut ? .needsSignIn : .available })
        await anonymous.load()
        let movingThird = anonymous.snapshot!.occurrences[2], anchorThird = anonymous.snapshot!.occurrences[4]
        await third.remoteMove("S2", before: nil)
        await anonymous.submit(.move(movingThird, before: anchorThird))
        let ask = try #require(anonymous.conflicts.first)
        signedOut = true
        await anonymous.resolve(ask.id, .keepMine)
        let none = await third.state()
        #expect(none.requests.isEmpty)
        #expect(anonymous.operations.last?.state == .failed(.needsSignIn))
    }
    @Test func aMoveToWhereTheSongAlreadyIsIsNotAChange() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let moving = song(session, 3)
        await remote.remoteMove("S3", before: "S5")             // somebody put it exactly where we mean: before S5
        await session.submit(.move(moving, before: song(session, 5)))
        #expect(session.operations.last?.state == .confirmed)
        #expect(session.sentCount == 0)
        #expect(session.conflicts.isEmpty)
    }
    @Test func nothingTheSessionSendsEverReplacesTheWholePlaylist() async throws {
        let remote = await standardRemote(10)
        let session = await loadedSession(remote)
        await remote.remoteMove("S9", before: "S0")
        let intents: [PlaylistIntent] = [.move(song(session, 2), before: song(session, 5)), .add(additions([30]), .keepDuplicates), .remove([song(session, 7)]), .rename("N")]
        for intent in intents { await session.submit(intent) }
        let state = await remote.state()
        #expect(state.requests.count == 4)
        for request in state.requests {
            guard case .edit(_, let actions) = request else { Issue.record("unexpected request \(request)"); continue }
            #expect(actions.count == 1, "each action names one occurrence or one field: \(actions)")
        }
    }
}

// MARK: T13.5 — Undo is a compensating change that can fail

@Suite @MainActor struct PlaylistUndoTests {
    @Test func undoOfABulkRemovalAddsTheSongsBackAndTouchesNothingElse() async throws {
        let remote = await standardRemote(10)
        let session = await loadedSession(remote)
        let intent = PlaylistIntent.remove([song(session, 1), song(session, 2), song(session, 3)])
        await session.submit(intent, confirmation: confirmation(session, intent))
        var state = await remote.state()
        #expect(state.rows.count == 7)
        #expect(session.undo?.label == "Undo: removed 3 songs")
        await session.undoLast()                                    // m3: a bulk reversal without the naming confirmation is refused
        state = await remote.state()
        #expect(session.operations.last?.state == .failed(.needsConfirmation) && session.operations.last?.isUndo == true)
        #expect(state.rows.count == 7, "nothing was restored without the confirmation")
        let prompt = try #require(session.undoPrompt)
        #expect(prompt.action == .undo && prompt.count == 3 && prompt.names.count == 3)
        session.dismiss(try #require(session.operations.last?.id))
        await session.undoLast(confirmation: prompt)
        state = await remote.state()
        #expect(state.rows.count == 10)
        #expect(Array(state.rows.prefix(7)).map(\.setVideoID) == ["S0", "S4", "S5", "S6", "S7", "S8", "S9"], "unrelated entries keep their ids and order")
        #expect(Array(state.rows.suffix(3)).map(\.videoID) == [v(1), v(2), v(3)], "the three songs are back, at the end, with new occurrence ids")
        #expect(Set(state.ids).count == 10)
        #expect(session.undo == nil)
    }
    @Test func undoMayFailAndThenSaysSoAndLeavesThePlaylistAsItIs() async throws {
        let remote = await standardRemote(10)
        let session = await loadedSession(remote)
        let intent = PlaylistIntent.remove([song(session, 1), song(session, 2)])
        await session.submit(intent, confirmation: confirmation(session, intent))
        let before = await remote.state()
        await remote.setFaults([.refuse])
        await session.undoLast(confirmation: session.undoPrompt)
        #expect(session.operations.last?.isUndo == true)
        #expect(session.operations.last?.state == .failed(.refused))
        var state = await remote.state()
        #expect(state.rows == before.rows, "a failed undo changed nothing")
        #expect(session.undo != nil, "it can be tried again")
        session.dismiss(try #require(session.operations.last?.id))
        await session.undoLast(confirmation: session.undoPrompt)
        state = await remote.state()
        #expect(state.rows.count == 10)
    }
    @Test func undoOfRemovingOneOfTwoDuplicateOccurrencesRestoresASecondOccurrenceAndLeavesTheTwinAlone() async throws {
        // The critic's surviving probe: Undo restores with the option that lets a duplicate in, so the service does not refuse it.
        let remote = FakePlaylistRemote(rows: FakePlaylistRemote.rows([v(0), v(1), v(0), v(2)]))
        let session = await loadedSession(remote)
        let second = song(session, 2)                                    // the second occurrence of song 0
        await session.submit(.remove([second]))
        var state = await remote.state()
        #expect(state.ids == ["S0", "S1", "S3"])
        await session.undoLast()
        state = await remote.state()
        #expect(session.operations.last?.state == .confirmed)
        #expect(state.count(of: v(0)) == 2, "the song is in the playlist twice again")
        #expect(state.rows.first?.setVideoID == "S0", "the twin kept its occurrence id and place")
        if case .edit(_, let actions)? = state.requests.last { #expect(actions == [.add(videoID: v(0), duplicates: .keepDuplicates)]) } else { Issue.record("no edit") }
    }
    @Test func undoOfAMoveMovesItBack() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await session.submit(.move(song(session, 1), before: song(session, 5)))
        var state = await remote.state()
        #expect(state.ids == ["S0", "S2", "S3", "S4", "S1", "S5", "S6", "S7"])
        await session.undoLast()
        state = await remote.state()
        #expect(state.ids == initial)
    }
    @Test func undoOfAnAddRemovesOnlyTheOccurrencesThatAddCreated() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await session.submit(.add(additions([0]), .keepDuplicates))       // the song is already there once
        var state = await remote.state()
        #expect(state.count(of: v(0)) == 2)
        await session.undoLast()
        state = await remote.state()
        #expect(state.count(of: v(0)) == 1)
        #expect(state.rows.first?.setVideoID == "S0", "the original occurrence survived")
        #expect(state.rows.count == 8)
    }
    @Test func undoOfDetailChangesRestoresThePreviousValues() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await session.submit(.rename("Renamed")); await session.undoLast()
        var state = await remote.state()
        #expect(state.title == "Fixture playlist")
        await session.submit(.setPrivacy(.public)); await session.undoLast()
        state = await remote.state()
        #expect(state.privacy == .private)
    }
    @Test func aNewChangeReplacesWhatUndoWouldDo() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await session.submit(.rename("One"))
        #expect(session.undo != nil)
        await session.submit(.describe("Two"))
        #expect(session.undo?.intent == .describe(""), "only the last confirmed change is undoable")
    }
}


// MARK: Creating a playlist whose answer never arrives

@Suite @MainActor struct PlaylistCreatorTests {
    @Test func aLostReplyIsSettledByReadingTheListAndNeverCreatesTwo() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.lostReplyAfterApplying])
        let creator = PlaylistCreator(service: remote)
        await creator.create(title: "Road trip")
        #expect(creator.state == .needsReconciliation)
        await creator.create(title: "Road trip")               // pressing Create again while unsettled sends nothing
        var state = await remote.state()
        #expect(state.requests.count == 1)
        await creator.check()
        guard case .created = creator.state else { Issue.record("expected created, got \(creator.state)"); return }
        state = await remote.state()
        #expect(state.requests.count == 1, "settled by reading, not by creating again")
    }
    @Test func aLostRequestIsFoundNotCreatedAndTryAgainCreatesItOnce() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.lostReplyBeforeApplying])
        let creator = PlaylistCreator(service: remote)
        await creator.create(title: "Road trip")
        await creator.check()
        #expect(creator.state == .needsReconciliation, "one read that does not show it is only \u{201C}not seen yet\u{201D}")
        await creator.check()
        #expect(creator.state == .failed(.notApplied), "two in a row are \u{201C}not created\u{201D}")
        await creator.create(title: "Road trip")
        guard case .created = creator.state else { Issue.record("expected created, got \(creator.state)"); return }
        let state = await remote.state()
        #expect(state.requests.count == 2)
    }
    @Test func aListThatLagsBehindTheCreateNeverMakesATryAgainCreateASecondPlaylist() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.lostReplyAfterApplying])
        let creator = PlaylistCreator(service: remote)
        await creator.create(title: "Road trip")
        let applied = await remote.state()
        #expect(applied.requests.count == 1)
        // The service created it, but the library list does not show it yet.
        await remote.setListed([])
        await creator.check(); await creator.check()
        #expect(creator.state == .failed(.notApplied), "two lagging reads read as not created")
        // The list catches up before the person presses Try Again: Try Again looks first and finds it.
        await remote.setListed([PlaylistListing(playlistID: "PLcreatedLATE00000000000", title: "Road trip")])
        await creator.create(title: "Road trip")
        #expect(creator.state == .created(playlistID: "PLcreatedLATE00000000000"))
        let state = await remote.state()
        #expect(state.requests.count == 1, "no second create was sent")
    }
    @Test func severalNewPlaylistsWithTheTitleAreAskedAboutNeverGuessed() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.lostReplyAfterApplying])
        let creator = PlaylistCreator(service: remote)
        await creator.create(title: "Road trip")
        await remote.setListed([PlaylistListing(playlistID: "PLcreatedAAAAAAAAAAAA", title: "Road trip"), PlaylistListing(playlistID: "PLcreatedBBBBBBBBBBBB", title: "Road trip"),
                                PlaylistListing(playlistID: "PLcreatedCCCCCCCCCCCC", title: "Another")])
        await creator.check()
        guard case .ambiguous(let options) = creator.state else { Issue.record("expected ambiguous, got \(creator.state)"); return }
        #expect(options.map(\.playlistID) == ["PLcreatedAAAAAAAAAAAA", "PLcreatedBBBBBBBBBBBB"])
        creator.choose("PLnotInTheOptions0000000")
        #expect(creator.state == .ambiguous(options), "a choice outside the options changes nothing")
        creator.choose("PLcreatedBBBBBBBBBBBB")
        #expect(creator.state == .created(playlistID: "PLcreatedBBBBBBBBBBBB"))
    }
    @Test func theListIsReadBeforeTheRequestAndIfItCannotBeReadNothingIsSent() async throws {
        let remote = await standardRemote()
        await remote.setFailListing(true)
        let creator = PlaylistCreator(service: remote)
        await creator.create(title: "Road trip")
        let state = await remote.state()
        #expect(creator.state == .failed(.couldNotRead) || creator.state == .failed(.offline))
        #expect(state.requests.isEmpty)
    }
    @Test func anExistingPlaylistWithTheSameTitleIsNotTheNewOne() async throws {
        let remote = await standardRemote()
        await remote.setListed([PlaylistListing(playlistID: "PLolderOneWithSameTitle0", title: "Road trip")])
        await remote.setFaults([.lostReplyBeforeApplying])
        let creator = PlaylistCreator(service: remote)
        await creator.create(title: "Road trip")
        await creator.check(); await creator.check()
        #expect(creator.state == .failed(.notApplied), "the old playlist with that title is not evidence the create happened")
    }
}

// MARK: Collaboration (owner-only, explicit, one request each) and joining

@Suite @MainActor struct PlaylistCollaborationTests {
    @Test func theOwnerCreatesAnInviteLinkAndOnlyAValidOneIsShown() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        #expect(session.collaboration == .idle)
        await session.createInviteLink()
        let state = await remote.state()
        #expect(state.requests == [.edit(playlistID: remote.playlistID, actions: [.createInviteLink])])
        guard case .invite(let link?) = session.collaboration else { Issue.record("expected a link, got \(session.collaboration)"); return }
        #expect(link.absoluteString == "https://music.youtube.com/playlist?list=\(remote.playlistID)&jct=\(FakePlaylistRemote.joinToken)")
        // The plain share link never carries the join token.
        #expect(PlaylistSharing.canonicalURL(playlistID: remote.playlistID)?.absoluteString.contains("jct") == false)
    }
    @Test func aLinkThePlaylistDidNotReturnForItselfIsNotShown() {
        let id = "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", token = "kM9wXdRj2p8v_qL3sHBkTz"
        #expect(PlaylistSharing.inviteLink(from: "https://music.youtube.com/playlist?list=\(id)&jct=\(token)", playlistID: id) != nil)
        #expect(PlaylistSharing.inviteLink(from: "https://music.youtube.com/playlist?list=\(id)&jct=\(token)", playlistID: "VL" + id) != nil)
        for bad in ["https://evil.example/playlist?list=\(id)&jct=\(token)", "https://music.youtube.com/playlist?list=PLanother00000000000&jct=\(token)", "https://music.youtube.com/playlist?list=\(id)",
                    "https://music.youtube.com/playlist?list=\(id)&jct=short", "https://music.youtube.com/playlist?list=\(id)&jct=\(token)&jct=\(token)", "http://music.youtube.com/playlist?list=\(id)&jct=\(token)", ""] {
            #expect(PlaylistSharing.inviteLink(from: bad, playlistID: id) == nil, Comment(rawValue: bad))
        }
        #expect(PlaylistSharing.inviteLink(from: nil, playlistID: id) == nil)
        #expect(PlaylistSharing.invite(fromLink: "https://music.youtube.com/playlist?list=\(id)&jct=\(token)")?.token == token)
    }
    @Test func onlyTheOwnerIsOfferedCollaborationAndStoppingAsksFirst() async throws {
        let collaborator = await standardRemote()
        await collaborator.setEditing(MusicPlaylistEditing(canEditTracks: true, canEditDetails: false, canDelete: false, privacy: .public))
        let other = await loadedSession(collaborator)
        await other.createInviteLink()
        #expect(other.collaboration == .failed(.notPermitted))
        let none = await collaborator.state()
        #expect(none.requests.isEmpty)

        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await session.stopContributions(confirmation: nil)
        #expect(session.collaboration == .failed(.needsConfirmation))
        let wrong = PlaylistPrompt(action: .stopContributions, playlistTitle: "Another", count: 1, names: ["Another"])
        await session.stopContributions(confirmation: wrong)
        #expect(session.collaboration == .failed(.needsConfirmation))
        var state = await remote.state()
        #expect(state.requests.isEmpty)
        await session.stopContributions(confirmation: session.stopContributionsPrompt)
        state = await remote.state()
        #expect(session.collaboration == .closed)
        #expect(state.requests == [.edit(playlistID: remote.playlistID, actions: [.closeToContributions])])
        let closed = await remote.contributionsClosed
        #expect(closed)
    }
    @Test func aLostCollaborationReplyIsUnconfirmedAndTryAgainSendsTheSameSingleRequest() async throws {
        let remote = await standardRemote()
        await remote.setFaults([.lostReplyAfterApplying])
        let session = await loadedSession(remote)
        await session.createInviteLink()
        #expect(session.collaboration == .unconfirmed)
        await session.retryCollaboration()
        guard case .invite = session.collaboration else { Issue.record("expected an invite, got \(session.collaboration)"); return }
        let state = await remote.state()
        #expect(state.requests.count == 2 && state.requests.allSatisfy { $0 == .edit(playlistID: remote.playlistID, actions: [.createInviteLink]) })
    }
    @Test func rightsWithdrawnBeforeTheSendStopTheCollaborationRequest() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        await remote.setEditing(MusicPlaylistEditing(canEditTracks: true, canEditDetails: false, canDelete: false, privacy: .public))
        await session.createInviteLink()
        #expect(session.collaboration == .failed(.notPermitted))
        let state = await remote.state()
        #expect(state.requests.isEmpty, "the precondition read showed the person is no longer the owner")
    }

    // Joining
    private func joinLink(_ remote: FakePlaylistRemote) -> String { "https://music.youtube.com/playlist?list=\(remote.playlistID)&jct=\(FakePlaylistRemote.joinToken)" }
    @Test func aPastedLinkIsOnlyReadAndJoiningNeedsTheConfirmationNamingThePlaylist() async throws {
        let remote = await standardRemote()
        await remote.setEditing(nil)
        let joiner = PlaylistJoiner(service: remote)
        await joiner.prepare(link: joinLink(remote))
        guard case .offer(let offer) = joiner.state else { Issue.record("expected an offer, got \(joiner.state)"); return }
        #expect(offer.title == "Fixture playlist")
        var state = await remote.state()
        #expect(state.requests.isEmpty, "looking up a link sends nothing")
        await joiner.join(confirmation: nil)
        #expect(joiner.state == .failed(.needsConfirmation))
        state = await remote.state()
        #expect(state.requests.isEmpty)
    }
    @Test func joiningSendsExactlyOneJoinWithTheTokenAndTheServiceThenShowsTheRights() async throws {
        let remote = await standardRemote()
        await remote.setEditing(nil)
        let joiner = PlaylistJoiner(service: remote)
        await joiner.prepare(link: joinLink(remote))
        await joiner.join(confirmation: joiner.joinPrompt)
        #expect(joiner.state == .joined(playlistID: remote.playlistID))
        let state = await remote.state()
        #expect(state.requests == [.edit(playlistID: remote.playlistID, actions: [.joinCollaboration(token: FakePlaylistRemote.joinToken)])])
        // The person now collaborates: the playlist page shows editing and the role is a collaborator's.
        let session = await loadedSession(remote)
        #expect(session.role == .collaborator)
    }
    @Test func aMemberIsNotAskedToJoinAndABadLinkOrTokenSendsNothing() async throws {
        let remote = await standardRemote()                                     // the person already edits it
        let joiner = PlaylistJoiner(service: remote)
        await joiner.prepare(link: joinLink(remote))
        #expect(joiner.state == .alreadyMember(title: "Fixture playlist"))
        for bad in ["", "not a link", "https://evil.example/playlist?list=\(remote.playlistID)&jct=\(FakePlaylistRemote.joinToken)", "https://music.youtube.com/playlist?list=\(remote.playlistID)",
                    "https://music.youtube.com/playlist?list=LM&jct=\(FakePlaylistRemote.joinToken)"] {
            joiner.reset(); await joiner.prepare(link: bad)
            #expect(joiner.state == .invalidLink, Comment(rawValue: bad))
        }
        let state = await remote.state()
        #expect(state.requests.isEmpty)
    }
    @Test func aRefusedOrLostJoinIsReportedAndSettledByReading() async throws {
        let refused = await standardRemote()
        await refused.setEditing(nil); await refused.setFaults([.refuse])
        let first = PlaylistJoiner(service: refused)
        await first.prepare(link: joinLink(refused)); await first.join(confirmation: first.joinPrompt)
        #expect(first.state == .failed(.refused))

        let lost = await standardRemote()
        await lost.setEditing(nil); await lost.setFaults([.lostReplyAfterApplying])
        let second = PlaylistJoiner(service: lost)
        await second.prepare(link: joinLink(lost)); await second.join(confirmation: second.joinPrompt)
        #expect(second.state == .needsReconciliation)
        await second.check()
        #expect(second.state == .joined(playlistID: lost.playlistID), "the read shows the person now edits it")
        let state = await lost.state()
        #expect(state.requests.count == 1, "no second join was sent")
    }
}

// MARK: Adding several songs through the one confirmed path

@Suite @MainActor struct PlaylistStagedAddTests {
    private func dragged(_ n: Int) -> PlaylistDraggedSong { PlaylistDraggedSong(videoID: v(n), title: "Song \(v(n))")! }
    @Test func droppingOneNewSongOnlyStagesItAndNothingIsSentUntilTheConfirmation() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let staged = try #require(session.stageDrop([dragged(20)]))
        #expect(staged.songs.map(\.videoID) == [v(20)] && staged.prompt == nil && !staged.hasDuplicates)
        var state = await remote.state()
        #expect(state.requests.isEmpty, "a drop is not a request")
        #expect(session.sentCount == 0 && session.operations.isEmpty)
        await session.confirmAdd(staged, mode: .skipExisting)
        state = await remote.state()
        #expect(state.requests.count == 1 && state.count(of: v(20)) == 1)
    }
    @Test func droppingSeveralSongsStagesTheNamingConfirmationAndSendsNothingUntilItIsGiven() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let staged = try #require(session.stageDrop([dragged(20), dragged(21), dragged(22)]))
        #expect(staged.prompt?.count == 3 && staged.prompt?.action == .add)
        var state = await remote.state()
        #expect(state.requests.isEmpty && session.sentCount == 0)
        await session.confirmAdd(staged, mode: .skipExisting)
        state = await remote.state()
        #expect(state.requests.count == 1 && state.count(of: v(21)) == 1)
    }
    @Test func aDropIsCheckedAndNeverStagedForAPlaylistThePersonCannotChangeOrForNothingValid() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let forged = try JSONDecoder().decode(PlaylistDraggedSong.self, from: Data(#"{"format":"other","videoID":"dQw4w9WgXcQ","title":"x"}"#.utf8))
        #expect(session.stageDrop([forged]) == nil && session.stageDrop([]) == nil)
        let staged = try #require(session.stageDrop([dragged(0)]))
        #expect(staged.hasDuplicates, "a song already there is asked about (Keep duplicates / Skip existing)")
        let viewer = await standardRemote()
        await viewer.setEditing(nil)
        let readOnly = await loadedSession(viewer)
        #expect(readOnly.stageDrop([dragged(20)]) == nil)
        let state = await remote.state(), other = await viewer.state()
        #expect(state.requests.isEmpty && other.requests.isEmpty)
    }
    @Test func oneNewSongIsAddedAtOnceByTheExplicitAddButtonAndNothingElseIsAskedAbout() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let staged = await session.addSongs(additions([20]))
        #expect(staged == nil)
        let state = await remote.state()
        #expect(state.count(of: v(20)) == 1)
    }
    @Test func severalSongsAreStagedWithTheNamingConfirmationAndNothingIsSentUntilConfirmed() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let staged = try #require(await session.addSongs(additions([20, 21, 22])))
        #expect(!staged.hasDuplicates)
        #expect(staged.prompt?.count == 3 && staged.prompt?.action == .add)
        var state = await remote.state()
        #expect(state.requests.isEmpty)
        // The wrong confirmation does not confirm it.
        await session.submit(.add(staged.songs, .skipExisting), confirmation: PlaylistIntent.add(additions([30, 31]), .skipExisting).prompt(playlistTitle: "x"))
        #expect(session.operations.last?.state == .failed(.needsConfirmation))
        session.dismiss(try #require(session.operations.last?.id))
        await session.confirmAdd(staged, mode: .skipExisting)
        state = await remote.state()
        #expect(state.count(of: v(20)) == 1 && state.count(of: v(21)) == 1 && state.count(of: v(22)) == 1)
        #expect(state.requests.count == 1)
    }
    @Test func aSingleSongAlreadyThereIsAskedAboutAndNothingIsSentUntilTheChoice() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let staged = try #require(await session.addSongs(additions([0])))
        #expect(staged.hasDuplicates && staged.prompt == nil, "one song needs no naming confirmation, but the duplicate question")
        let state = await remote.state()
        #expect(state.requests.isEmpty)
        await session.confirmAdd(staged, mode: .keepDuplicates)
        let after = await remote.state()
        #expect(after.count(of: v(0)) == 2)
    }
    @Test func songsAlreadyThereAskForKeepOrSkipAndEachChoiceDoesWhatItSays() async throws {
        let remote = await standardRemote()
        let session = await loadedSession(remote)
        let staged = try #require(await session.addSongs(additions([0, 20])))
        #expect(staged.duplicateTitles == ["Song \(v(0))"])
        await session.confirmAdd(staged, mode: .skipExisting)
        var state = await remote.state()
        #expect(state.count(of: v(0)) == 1 && state.count(of: v(20)) == 1)

        let second = await standardRemote()
        let again = await loadedSession(second)
        let restaged = try #require(await again.addSongs(additions([0, 20])))
        await again.confirmAdd(restaged, mode: .keepDuplicates)
        state = await second.state()
        #expect(state.count(of: v(0)) == 2 && state.count(of: v(20)) == 1, "Keep duplicates added the second occurrence")
    }
}
