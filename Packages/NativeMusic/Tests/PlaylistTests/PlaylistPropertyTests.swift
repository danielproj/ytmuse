import AccountSession
import Foundation
import Testing
@testable import Features

private func v(_ n: Int) -> String { FakePlaylistRemote.video(n) }

// MARK: T13.1 — generated sequences keep the service's occurrence identity

/// Seeded sequences of adds (with and without duplicates), removals, moves and renames against a fake service that also changes
/// by itself, loses replies and expires cursors. After every step the service's own list is the oracle:
///  - occurrence ids stay unique, and an occurrence nobody targeted keeps its id and its song;
///  - removing one occurrence of a song that appears several times removes that occurrence only;
///  - a retry never creates a second copy of an occurrence a read shows exists;
///  - the session's view, once refreshed, equals the service's list exactly (so paged reads with expired cursors lose and double nothing).
@Suite @MainActor struct PlaylistPropertyTests {
    @Test(arguments: Array(0..<120)) func generatedSequencesPreserveOccurrenceIdentity(seed: Int) async throws {
        var rng = SeededRandom(seed: UInt64(seed) &* 7919 &+ 13)
        func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &rng) < percent }
        let pool = (0..<5).map(v)                                          // few songs, so duplicates are everywhere
        let start = Int.random(in: 3...14, using: &rng)
        let rows = (0..<start).map { FakePlaylistRemote.Row(setVideoID: "S\($0)", videoID: pool.randomElement(using: &rng)!, title: "Song \($0)") }
        let remote = FakePlaylistRemote(rows: rows)
        await remote.setPageSize(Int.random(in: 2...5, using: &rng))
        let session = await loadedSession(remote)
        var state = await remote.state()
        #expect(session.snapshot?.occurrences.map(\.setVideoID) == state.ids, "the first read equals the service's list")
        var identity: [String: String] = Dictionary(uniqueKeysWithValues: state.rows.map { ($0.setVideoID, $0.videoID) })

        for step in 0..<28 {
            // Somebody else changes the playlist before this person acts.
            switch Int.random(in: 0..<8, using: &rng) {
            case 0: if let id = state.ids.randomElement(using: &rng) { await remote.remoteMove(id, before: state.ids.randomElement(using: &rng))  }
            case 1: if let id = state.ids.randomElement(using: &rng) { await remote.remoteRemove(id) }
            case 2: _ = await remote.remoteAdd(pool.randomElement(using: &rng)!)
            default: break
            }
            // A cursor that goes stale while the next read is between pages.
            let midRead = chance(20)
            if midRead { await remote.setBetweenPages { r, _ in r.betweenPages = nil; _ = r.remoteAdd(pool[0]) } }
            let pre = await remote.state()
            for row in pre.rows { identity[row.setVideoID] = row.videoID }
            let view = try #require(session.snapshot).occurrences

            let fault: FakePlaylistRemote.Fault? = {
                switch Int.random(in: 0..<10, using: &rng) {
                case 0: .lostReplyAfterApplying
                case 1: .lostReplyBeforeApplying
                case 2: .refuse
                case 3: .offline
                case 4: .unreadableAfterApplying
                default: nil
                }
            }()
            if let fault { await remote.setFaults([fault]) }

            // The person's intent, expressed against what they last saw.
            var intent: PlaylistIntent
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...3:
                let count = Int.random(in: 1...3, using: &rng)
                let songs = (0..<count).map { _ in PlaylistAddition(videoID: pool.randomElement(using: &rng)!, title: "Added") }
                intent = .add(songs, chance(50) ? .keepDuplicates : .skipExisting)
            case 4...6 where !view.isEmpty:
                let picked = Array(view.shuffled(using: &rng).prefix(Int.random(in: 1...min(3, view.count), using: &rng)))
                intent = .remove(picked)
            case 7...8 where view.count >= 2:
                let moving = view.randomElement(using: &rng)!
                let anchor = chance(20) ? nil : view.filter { $0.setVideoID != moving.setVideoID }.randomElement(using: &rng)
                intent = .move(moving, before: anchor)
            default: intent = .rename("Title \(step)")
            }
            let prompt = intent.prompt(playlistTitle: session.snapshot!.title)
            await session.submit(intent, confirmation: prompt)

            // Settle: read back an unknown outcome, retry what was found missing, answer each question.
            var guardLoop = 0
            while let op = session.operations.last, guardLoop < 4 {
                guardLoop += 1
                // Sometimes the person reads first (Check); sometimes they press Try Again straight away. Neither may add a second copy.
                if op.state == .needsReconciliation { if chance(45) { await session.retry(op.id) } else { await session.check(op.id) }; continue }
                if case .failed(let why) = op.state, [.notApplied, .partlyApplied, .offline, .refused].contains(why) { await session.retry(op.id); if session.operations.last?.state == op.state { break }; continue }
                break
            }
            var keptTheirs = false
            for conflict in session.conflicts {
                let mine = chance(50)
                if !mine { keptTheirs = true }
                await session.resolve(conflict.id, mine ? .keepMine : .keepTheirs)
            }
            state = await remote.state()

            // A. identity
            #expect(Set(state.ids).count == state.ids.count, "step \(step): occurrence ids are unique")
            for row in state.rows { #expect(identity[row.setVideoID] == nil || identity[row.setVideoID] == row.videoID, "step \(step): \(row.setVideoID) kept its song") ; identity[row.setVideoID] = row.videoID }
            // B/C. what nobody targeted is untouched and in order
            var targeted = Set<String>()
            switch intent {
            case .remove(let songs): targeted = Set(songs.map(\.setVideoID))
            case .move(let song, _): targeted = [song.setVideoID]
            default: break
            }
            let survivors = pre.rows.filter { !targeted.contains($0.setVideoID) }
            let kept = state.rows.filter { row in survivors.contains { $0.setVideoID == row.setVideoID } }
            #expect(survivors.allSatisfy { s in state.rows.contains(s) }, "step \(step): an occurrence nobody targeted is still there with its song")
            if case .move = intent {} else { #expect(kept.map(\.setVideoID) == survivors.map(\.setVideoID), "step \(step): untargeted occurrences keep their order") }
            // D/E. removal is exact: the targeted occurrences, not their siblings
            if case .remove(let songs) = intent {
                let present = songs.filter { s in state.rows.contains { $0.setVideoID == s.setVideoID } }
                let wasThere = songs.filter { s in pre.rows.contains { $0.setVideoID == s.setVideoID } }
                #expect(present.isEmpty || present.count == wasThere.count, "step \(step): a removal is all or nothing")
                for gone in wasThere where !present.contains(gone) {
                    let siblingsBefore = pre.rows.filter { $0.videoID == gone.videoID && !songs.contains { $0.setVideoID == $0.setVideoID && $0.setVideoID == gone.setVideoID } }
                    for sibling in siblingsBefore where !targeted.contains(sibling.setVideoID) {
                        #expect(state.rows.contains(sibling), "step \(step): the other occurrence of the same song survived")
                    }
                }
            }
            // F. no retry ever creates a second copy
            if case .add(let songs, let mode) = intent {
                let created = state.rows.filter { $0.setVideoID.hasPrefix("A") && !pre.ids.contains($0.setVideoID) }
                for video in Set(songs.map(\.videoID)) {
                    let requested = songs.filter { $0.videoID == video }.count
                    let allowed = mode == .skipExisting ? 1 : requested
                    #expect(created.filter { $0.videoID == video }.count <= allowed, "step \(step): at most \(allowed) new occurrence(s) of one requested song, got \(created.filter { $0.videoID == video }.count)")
                }
            }
            // G. a confirmed move put the song before its anchor
            if case .move(let song, let anchor) = intent, !keptTheirs, session.operations.last?.state == .confirmed, session.operations.last?.attempts == 1,
               let index = state.ids.firstIndex(of: song.setVideoID), let anchor, let anchorIndex = state.ids.firstIndex(of: anchor.setVideoID), pre.ids.contains(anchor.setVideoID) {
                #expect(index + 1 == anchorIndex, "step \(step): the moved occurrence sits right before its anchor")
            }
            // I. every removal the service was sent named an occurrence with its own song
            for request in state.requests {
                guard case .edit(_, let actions) = request else { continue }
                for case .remove(let video, let set) in actions { #expect(identity[set] == video, "step \(step): a remove named occurrence \(set) with its own song") }
            }
            // H. refreshed, the session's view equals the service's list
            await session.refresh()
            let refreshed = try #require(session.snapshot)
            state = await remote.state()
            #expect(refreshed.occurrences.map(\.setVideoID) == state.ids, "step \(step): the view equals the service's list (paged reads lose and double nothing)")
            #expect(refreshed.occurrences.map(\.videoID) == state.rows.map(\.videoID))
            #expect(refreshed.isComplete)
            if session.operations.contains(where: { $0.state == .failed(.refused) || $0.state == .failed(.offline) }) { for op in session.operations { session.dismiss(op.id) } }
            for op in session.operations where op.state == .needsReconciliation { session.dismissUnconfirmed(op.id) }
        }
    }
}

// MARK: Paged reads, cursors and overlap

@Suite @MainActor struct PlaylistReaderTests {
    private nonisolated func occurrenceItem(_ set: String, _ video: String) -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: "T \(set)", videoID: video, occurrenceID: set)
    }
    private nonisolated func page(_ ids: [(String, String)], token: String?) -> MusicBrowsePage {
        MusicBrowsePage(header: MusicPageHeader(title: "P"), shelves: [MusicShelf(key: "list", title: nil, layout: .list, items: ids.map { occurrenceItem($0.0, $0.1) }, continuation: token)])
    }
    private nonisolated func more(_ ids: [(String, String)], token: String?) -> MusicContinuationPage { MusicContinuationPage(items: ids.map { occurrenceItem($0.0, $0.1) }, shelves: [], continuation: token) }

    @Test func anExpiredCursorRestartsTheReadAndTheResultIsTheWholePlaylistOnce() async throws {
        let remote = FakePlaylistRemote(rows: FakePlaylistRemote.rows((0..<11).map(v)))
        await remote.setPageSize(3)
        await remote.setBetweenPages { r, offset in if offset == 6 { r.betweenPages = nil; _ = r.remoteAdd(v(99)); r.remoteMove("S0", before: nil) } }
        let snapshot = try await remote.read(playlistID: remote.playlistID)
        let state = await remote.state()
        #expect(snapshot.isComplete)
        #expect(snapshot.occurrences.map(\.setVideoID) == state.ids, "after the restart the snapshot is the playlist as it is now, in order, with nothing doubled or missing")
        #expect(Set(snapshot.occurrences.map(\.setVideoID)).count == 12)
    }
    @Test func aCursorThatNeverStaysValidGivesAnIncompleteSnapshotNeverAWholeOne() async throws {
        let remote = FakePlaylistRemote(rows: FakePlaylistRemote.rows((0..<9).map(v)))
        await remote.setPageSize(3)
        await remote.setBetweenPages { r, _ in _ = r.remoteAdd(v(99)) }           // every continuation is stale
        let snapshot = try await remote.read(playlistID: remote.playlistID)
        #expect(!snapshot.isComplete)
        #expect(Set(snapshot.occurrences.map(\.setVideoID)).count == snapshot.occurrences.count)
        #expect(snapshot.occurrences.count <= 3, "what was read is the first page, and says so")
    }
    @Test func anIncompleteSnapshotAllowsAnAddButNotAReorder() async throws {
        let remote = FakePlaylistRemote(rows: FakePlaylistRemote.rows((0..<9).map(v)))
        await remote.setPageSize(3)
        let session = await loadedSession(remote)
        var snapshot = try #require(session.snapshot)
        #expect(snapshot.isComplete)
        await remote.setBetweenPages { r, _ in _ = r.remoteAdd(v(99)) }
        await session.load()
        snapshot = try #require(session.snapshot)
        #expect(!snapshot.isComplete)
        await session.submit(.move(snapshot.occurrences[0], before: snapshot.occurrences[1]))
        #expect(session.operations.last?.state == .failed(.notFullyRead))
        #expect(session.sentCount == 0)
    }
    @Test func aRepeatedTokenAndAnOverlappingPageDoNotLoopOrDouble() async throws {
        let first = page([("A", "vidAAAAAAAA"), ("B", "vidBBBBBBBB")], token: "t1")
        let source = PlaylistPageSource(page: { _ in first }, continuation: { token in
            // Page two repeats row B (an overlap) and offers the same token again.
            self.more([("B", "vidBBBBBBBB"), ("C", "vidAAAAAAAA")], token: token)
        })
        let snapshot = try await PlaylistSnapshotReader.read(playlistID: "PLabcdefghij", source: source)
        #expect(snapshot.occurrences.map(\.setVideoID) == ["A", "B", "C"], "B once; C is the same song as A with its own id and is kept")
        #expect(!snapshot.isComplete, "the service never stopped offering the same token: honest about it")
    }
    @Test func theSameSongTwiceIsTwoOccurrencesAndRowsWithoutAnIdAreCountedNotTargeted() async throws {
        let rows: [MusicCatalogItem] = [occurrenceItem("A", "vidAAAAAAAA"), occurrenceItem("B", "vidAAAAAAAA"), MusicCatalogItem(kind: .song, title: "No id", videoID: "vidCCCCCCCC")]
        let source = PlaylistPageSource(page: { _ in MusicBrowsePage(header: MusicPageHeader(title: "P"), shelves: [MusicShelf(key: "l", title: nil, layout: .list, items: rows)]) }, continuation: { _ in throw MusicSessionError.unrecognised })
        let snapshot = try await PlaylistSnapshotReader.read(playlistID: "PLabcdefghij", source: source)
        #expect(snapshot.occurrences.map(\.setVideoID) == ["A", "B"])
        #expect(snapshot.unaddressableCount == 1)
        #expect(snapshot.count(ofVideo: "vidAAAAAAAA") == 2)
    }
    @Test func aTransportFailureIsNotAnExpiredCursor() async throws {
        let first = page([("A", "vidAAAAAAAA")], token: "t1")
        let source = PlaylistPageSource(page: { _ in first }, continuation: { _ in throw MusicSessionError.network })
        await #expect(throws: MusicSessionError.network) { _ = try await PlaylistSnapshotReader.read(playlistID: "PLabcdefghij", source: source) }
    }
    @Test func theServicesOtherShelvesAreSuggestionsNotMembers() async throws {
        let list = MusicShelf(key: "list", title: nil, layout: .list, items: [occurrenceItem("A", "vidAAAAAAAA")])
        let suggestions = MusicShelf(key: "sugg", title: "Suggestions", layout: .list, items: [MusicCatalogItem(kind: .song, title: "Maybe", videoID: "vidSSSSSSSS")])
        let source = PlaylistPageSource(page: { _ in MusicBrowsePage(header: MusicPageHeader(title: "P"), shelves: [list, suggestions]) }, continuation: { _ in throw MusicSessionError.unrecognised })
        let snapshot = try await PlaylistSnapshotReader.read(playlistID: "PLabcdefghij", source: source)
        #expect(snapshot.occurrences.count == 1)
        #expect(snapshot.suggestions.map(\.videoID) == ["vidSSSSSSSS"])
    }
}

// MARK: The merge rule on its own

@Suite struct PlaylistReconcilerTests {
    private func snapshot(_ ids: [String], title: String = "T", privacy: MusicPlaylistPrivacy? = .private) -> PlaylistSnapshot {
        PlaylistSnapshot(playlistID: "PLabcdefghij", title: title, privacy: privacy, occurrences: ids.map { PlaylistOccurrence(setVideoID: $0, videoID: "vid" + $0.padding(toLength: 8, withPad: "0", startingAt: 0), title: $0) },
                         editing: MusicPlaylistEditing(canEditTracks: true, canEditDetails: true, canDelete: true, privacy: privacy))
    }
    @Test func mayHaveMovedTable() {
        // Nothing changed.
        #expect(!PlaylistReconciler.mayHaveMoved("B", base: ["A", "B", "C"], remote: ["A", "B", "C"]))
        // Another song went to the front: B did not move.
        #expect(!PlaylistReconciler.mayHaveMoved("B", base: ["A", "B", "C", "D"], remote: ["D", "A", "B", "C"]))
        // B went to the end: B moved.
        #expect(PlaylistReconciler.mayHaveMoved("B", base: ["A", "B", "C", "D"], remote: ["A", "C", "D", "B"]))
        // An adjacent swap: either could have moved.
        #expect(PlaylistReconciler.mayHaveMoved("A", base: ["A", "B", "C"], remote: ["B", "A", "C"]))
        #expect(PlaylistReconciler.mayHaveMoved("B", base: ["A", "B", "C"], remote: ["B", "A", "C"]))
        // Occurrences only one side has do not count.
        #expect(!PlaylistReconciler.mayHaveMoved("B", base: ["A", "B", "C", "X"], remote: ["A", "B", "C", "Y"]))
        #expect(!PlaylistReconciler.mayHaveMoved("Z", base: ["A", "B"], remote: ["A", "B"]), "an occurrence not in the base cannot have moved")
    }
    @Test func aRemovedOccurrenceThatNowNamesAnotherSongIsAQuestionNotARemoval() {
        let base = snapshot(["A", "B", "C"])
        var remote = base
        remote.occurrences[1] = PlaylistOccurrence(setVideoID: "B", videoID: "vidDIFFERENT", title: "B")
        let plan = PlaylistReconciler.plan(for: .remove([base.occurrences[1]]), base: base, remote: remote)
        #expect(plan.actions.isEmpty)
        #expect(plan.conflicts.count == 1)
        if case .occurrenceChanged? = plan.conflicts.first?.kind {} else { Issue.record("expected occurrenceChanged") }
    }
    @Test func twoSkipExistingAddsOfOneSongAreOneAddAndAnExistingSongIsNone() {
        let base = snapshot(["A", "B"])
        let plan = PlaylistReconciler.plan(for: .add([PlaylistAddition(videoID: "vidNEW00000", title: "n"), PlaylistAddition(videoID: "vidNEW00000", title: "n"), PlaylistAddition(videoID: base.occurrences[0].videoID, title: "a")], .skipExisting), base: base, remote: base)
        #expect(plan.actions == [.add(videoID: "vidNEW00000", duplicates: .skipExisting)])
        #expect(plan.satisfied.count == 2)
    }
    @Test func foundOccurrencesFromAnEarlierAttemptAreSubtractedFromAnAdd() {
        let base = snapshot(["A"])
        let adds = [PlaylistAddition(videoID: "vidNEW00000", title: "n"), PlaylistAddition(videoID: "vidNEW00000", title: "n"), PlaylistAddition(videoID: "vidOLD00000", title: "o")]
        let plan = PlaylistReconciler.plan(for: .add(adds, .keepDuplicates), base: base, remote: base, found: ["vidNEW00000": 1])
        #expect(plan.actions == [.add(videoID: "vidNEW00000", duplicates: .keepDuplicates), .add(videoID: "vidOLD00000", duplicates: .keepDuplicates)])
    }
    @Test func aMoveNamesNothingByPositionAndAnAnchorThatBecameTheMovedSongIsRefused() {
        let base = snapshot(["A", "B", "C"])
        let plan = PlaylistReconciler.plan(for: .move(base.occurrences[0], before: base.occurrences[0]), base: base, remote: base)
        #expect(plan.actions.isEmpty)
        let ok = PlaylistReconciler.plan(for: .move(base.occurrences[0], before: nil), base: base, remote: base)
        #expect(ok.actions == [.moveBefore(setVideoID: "A", successorSetVideoID: nil)])
    }
    @Test func detailsAreMergedFieldByField() {
        let base = snapshot(["A"], title: "Old")
        var remote = base; remote.privacy = .public
        #expect(PlaylistReconciler.plan(for: .rename("New"), base: base, remote: remote).actions == [.rename("New")])
        remote.title = "Old"; remote.privacy = .private
        #expect(PlaylistReconciler.plan(for: .rename("Old"), base: snapshot(["A"], title: "Was"), remote: remote).satisfied == ["Old"], "already says the new value")
        remote.title = "Theirs"
        #expect(PlaylistReconciler.plan(for: .rename("Mine"), base: base, remote: remote).conflicts.count == 1)
    }
    @Test func theLongestCommonSubsequenceGivesUpHonestlyOnAHugeDifference() {
        let ids = (0..<2500).map { "I\($0)" }
        let shuffled = ids.reversed() as [String]
        // Too large to decide exactly: the answer is "may have moved", never "did not".
        #expect(PlaylistReconciler.mayHaveMoved("I1", base: ids, remote: shuffled))
    }
}
