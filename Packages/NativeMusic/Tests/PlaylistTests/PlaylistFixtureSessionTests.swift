import AccountSession
import Foundation
import Testing
@testable import Features
@testable import YouTubeMusicAdapter

/// Sessions over the playlist pages themselves (the real anonymous capture and the pages made from its renderers), not over the fake.
/// The service stand-in records every request it is handed and answers with the fixture's own occurrence ids.
private actor RecordingService: PlaylistServing {
    private(set) var requests: [MusicPlaylistRequest] = []
    private(set) var continuationCalls: [String] = []
    private let pages: [MusicBrowsePage]
    private let more: MusicContinuationPage?
    private let suggestionsAnswer: MusicContinuationPage?
    init(pages: [MusicBrowsePage], more: MusicContinuationPage? = nil, suggestions: MusicContinuationPage? = nil) { self.pages = pages; self.more = more; self.suggestionsAnswer = suggestions }
    private func record(_ token: String) { continuationCalls.append(token) }
    func calls() -> [String] { continuationCalls }
    private func source() -> PlaylistPageSource {
        let page = pages[0], continuation = more
        return PlaylistPageSource(page: { _ in page }, continuation: { token in
            await self.record(token)
            // The tracks' own token serves the tracks; any other token (the section list's) serves the suggestions, if anything does.
            if token == "TRACKSPAGE2tokenAAAAAAAAAAAAAAAA%3D%3D", let continuation { return continuation }
            if let answer = self.suggestionsAnswer { return answer }
            throw MusicSessionError.unrecognised
        })
    }
    nonisolated func read(playlistID: String) async throws -> PlaylistSnapshot {
        try await PlaylistSnapshotReader.read(playlistID: playlistID, source: await source())
    }
    nonisolated func readSuggestions(token: String) async throws -> [MusicCatalogItem] {
        try await PlaylistSnapshotReader.readSuggestions(token: token, source: await source())
    }
    func apply(_ request: MusicPlaylistRequest) async throws -> MusicPlaylistReply {
        requests.append(request)
        return MusicPlaylistReply(result: MusicPlaylistOutcome(outcome: .rejected(.service)), accountGeneration: 0)
    }
    nonisolated func listing() async throws -> [PlaylistListing] { [] }
    func sent() -> [MusicPlaylistRequest] { requests }
}

@Suite @MainActor struct PlaylistFixtureSessionTests {
    private let list = "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"

    @Test func theRealAnonymousCaptureIsReadOnlyAndEveryChangeIsRefusedWithoutARequest() async throws {
        let root = try #require(try JSONSerialization.jsonObject(with: try w13Real("browse-playlist.json")) as? [String: Any])
        let service = RecordingService(pages: [try MusicBrowseParser.parse(root)])
        let session = PlaylistEditSession(playlistID: list, service: service)
        await session.load()
        let snapshot = try #require(session.snapshot)
        #expect(snapshot.role == .viewer)
        #expect(snapshot.occurrences.count == 16, "all sixteen real occurrences are listed with their own ids")
        #expect(Set(snapshot.occurrences.map(\.setVideoID)).count == 16)
        #expect(snapshot.occurrences.allSatisfy { !$0.removable })
        let song = snapshot.occurrences[0]
        for intent in [PlaylistIntent.remove([song]), .move(song, before: nil), .add([PlaylistAddition(videoID: "dQw4w9WgXcQ", title: "x")], .keepDuplicates), .rename("x")] { await session.submit(intent) }
        #expect(session.operations.allSatisfy { $0.state == .failed(.notPermitted) })
        #expect(await service.sent().isEmpty)
    }
    @Test func theOwnedPageRemovesExactlyTheDuplicateOccurrenceItWasAskedFor() async throws {
        let first = try playlistPage("owned-playlist.json")
        let service = RecordingService(pages: [first])
        let session = PlaylistEditSession(playlistID: list, service: service)
        await session.load()
        let snapshot = try #require(session.snapshot)
        #expect(snapshot.role == .owner)
        let duplicate = try #require(snapshot.occurrence("DUPLICATE00000001"))
        let original = try #require(snapshot.occurrences.first { $0.videoID == duplicate.videoID && $0.setVideoID != duplicate.setVideoID })
        #expect(duplicate.videoID == original.videoID && duplicate.setVideoID != original.setVideoID)
        await session.submit(.remove([duplicate]))
        let sent = await service.sent()
        #expect(sent == [.edit(playlistID: list, actions: [.remove(videoID: duplicate.videoID, setVideoID: "DUPLICATE00000001")])], "the removal names the duplicate's own occurrence, not the original's")
        #expect(original.setVideoID != "DUPLICATE00000001")
    }
    @Test func theGreyedOutRealRowIsListedButNotRemovableBecauseItPublishedNoRemoveCommand() async throws {
        let service = RecordingService(pages: [try playlistPage("owned-playlist.json")])
        let session = PlaylistEditSession(playlistID: list, service: service)
        await session.load()
        let snapshot = try #require(session.snapshot)
        let greyed = try #require(snapshot.occurrences.first { !$0.isAvailable })
        #expect(!greyed.removable)
        await session.submit(.remove([greyed]))
        #expect(session.operations.last?.state == .failed(.notPermitted))
        #expect(await service.sent().isEmpty)
    }
    @Test func theCollaboratorPageEditsTracksButNotDetails() async throws {
        let rest = try MusicBrowseParser.parseContinuation(try w13("owned-playlist-page2.json"))
        let service = RecordingService(pages: [try playlistPage("collaborator-playlist-long.json")], more: rest)
        let session = PlaylistEditSession(playlistID: list, service: service)
        await session.load()
        #expect(session.role == .collaborator)
        #expect(session.snapshot?.isComplete == true)
        await session.submit(.rename("x"))
        #expect(session.operations.last?.state == .failed(.notPermitted))
        #expect(session.snapshot?.privacy == nil, "a collaborator’s header publishes no visibility")
        let snapshot = try #require(session.snapshot)
        let (moved, anchor) = (snapshot.occurrences[3], snapshot.occurrences[1])
        await session.submit(.move(moved, before: anchor))
        // The recording service refuses every request; the point is that this one was permitted to leave and named occurrences.
        let sent = await service.sent()
        #expect(sent == [.edit(playlistID: list, actions: [.moveBefore(setVideoID: moved.setVideoID, successorSetVideoID: anchor.setVideoID)])])
    }
    @Test func aPlaylistThatWasNotReadToTheEndIsNeverReordered() async throws {
        let service = RecordingService(pages: [try playlistPage("owned-playlist-long.json")])      // the tracks' continuation is not honoured
        let session = PlaylistEditSession(playlistID: list, service: service)
        await session.load()
        let snapshot = try #require(session.snapshot)
        #expect(!snapshot.isComplete)
        await session.submit(.move(snapshot.occurrences[3], before: snapshot.occurrences[1]))
        #expect(session.operations.last?.state == .failed(.notFullyRead))
        #expect(await service.sent().isEmpty)
    }
    @Test func aNewSongIsAddedByVideoIdAndKeepsTheOwnedPagesEveryOtherOccurrence() async throws {
        let service = RecordingService(pages: [try playlistPage("owned-playlist.json")])
        let session = PlaylistEditSession(playlistID: list, service: service)
        await session.load()
        await session.submit(.add([PlaylistAddition(videoID: "dQw4w9WgXcQ", title: "New")], .skipExisting))
        #expect(await service.sent() == [.edit(playlistID: list, actions: [.add(videoID: "dQw4w9WgXcQ", duplicates: .skipExisting)])])
        #expect(session.operations.last?.state == .failed(.refused), "a refusal rolls the optimistic add back")
        #expect(session.displayed?.occurrences.count == session.snapshot?.occurrences.count)
    }

    @Test func draggingARowIsAMoveBeforeTheOccurrenceItWasDroppedOn() throws {
        let snapshot = PlaylistSnapshot(playlistID: list, title: "T", occurrences: ["A", "B", "C", "D"].map { PlaylistOccurrence(setVideoID: $0, videoID: "vid" + $0 + "000000", title: $0) })
        func move(_ from: Int, _ to: Int) -> PlaylistIntent? { PlaylistIntent.dragMove(in: snapshot, from: from, to: to) }
        #expect(move(0, 3) == .move(snapshot.occurrences[0], before: snapshot.occurrences[3]), "A dropped on D lands before D")
        #expect(move(2, 0) == .move(snapshot.occurrences[2], before: snapshot.occurrences[0]))
        #expect(move(0, 4) == .move(snapshot.occurrences[0], before: nil), "dropped after the last row: to the end")
        for (from, to) in [(1, 1), (1, 2), (3, 4), (0, 1)] { #expect(move(from, to) == nil, "a drop that changes nothing is not a change: \(from)→\(to)") }
        for (from, to) in [(-1, 2), (4, 2), (1, -1), (1, 5)] { #expect(move(from, to) == nil, "out of range: \(from)→\(to)") }
    }

    // MARK: B2 — the page's other token is the suggestions', never more tracks (the critic's three probes, adopted)

    @Test func theRealCaptureReadsCompleteWithNoContinuationCall() async throws {
        let root = try #require(try JSONSerialization.jsonObject(with: try w13Real("browse-playlist.json")) as? [String: Any])
        let page = try MusicBrowseParser.parse(root)
        #expect(page.shelves.first?.continuation == nil, "the real shelf names no continuation")
        #expect(page.continuation != nil, "while the section list does (the suggestions reload)")
        let service = RecordingService(pages: [page])
        let session = PlaylistEditSession(playlistID: list, service: service)
        await session.load()
        let snapshot = try #require(session.snapshot)
        #expect(snapshot.isComplete)
        #expect(snapshot.occurrences.count == 16)
        #expect(await service.calls().isEmpty, "a playlist read to its end asks for nothing more")
        #expect(snapshot.suggestionsToken == nil, "a viewer has no suggestions to read")
    }
    @Test func theOwnedFixtureIsFullyReadAndReorderableAndReadsNoContinuation() async throws {
        let service = RecordingService(pages: [try playlistPage("owned-playlist.json")])
        let session = PlaylistEditSession(playlistID: list, service: service)
        await session.load()
        let snapshot = try #require(session.snapshot)
        #expect(snapshot.isComplete)
        #expect(snapshot.suggestionsToken != nil, "kept for the suggestions read, not followed for tracks")
        #expect(await service.calls().isEmpty)
        await session.submit(.move(snapshot.occurrences[3], before: snapshot.occurrences[1]))
        #expect(session.operations.last?.state != .failed(.notFullyRead))
        #expect(await service.sent().count == 1, "the move was sent: a single-page playlist can be reordered")
    }
    @Test func aSuggestionsAnswerNeverAddsAMemberAndItsPlaceholderIdIsNotAnOccurrence() async throws {
        let answer = try MusicBrowseParser.parseContinuation(try w13("suggestions-answer.json"))
        #expect(answer.shelves.flatMap(\.items).count == 2)
        let service = RecordingService(pages: [try playlistPage("owned-playlist.json")], suggestions: answer)
        let session = PlaylistEditSession(playlistID: list, service: service)
        await session.load()
        let before = try #require(session.snapshot).occurrences.count
        await session.loadSuggestions()
        let snapshot = try #require(session.snapshot)
        #expect(snapshot.occurrences.count == before, "suggested songs are not members")
        #expect(!snapshot.occurrences.contains { $0.setVideoID == MusicPlaylistRequest.suggestionPlaceholder })
        #expect(session.suggestions.count == 2)
        #expect(session.suggestions.allSatisfy { $0.videoID != nil })
        // Even handed to the reader as if they were track rows, the placeholder is not an occurrence.
        let source = PlaylistPageSource(page: { _ in try playlistPage("owned-playlist-long.json") }, continuation: { _ in answer })
        let fooled = try await PlaylistSnapshotReader.read(playlistID: list, source: source)
        #expect(fooled.occurrences.count == before, "rows with no occurrence id are never members, however they arrive")
        #expect(fooled.unaddressableCount == 2)
        #expect(!fooled.occurrences.contains { $0.setVideoID == MusicPlaylistRequest.suggestionPlaceholder })
    }
    @Test func suggestionsThatCannotBeReadLeaveTheTracksAlone() async throws {
        let service = RecordingService(pages: [try playlistPage("owned-playlist.json")])           // the token answers nothing
        let session = PlaylistEditSession(playlistID: list, service: service)
        await session.load()
        let before = session.snapshot
        await session.loadSuggestions()
        #expect(session.suggestionsFailed)
        #expect(session.snapshot == before)
        #expect(session.suggestions.isEmpty)
    }
    @Test func aRowCommandNamingAnotherPlaylistIsNotTrustedEvenUnderAMatchingHeader() async throws {
        let service = RecordingService(pages: [try playlistPage("owned-playlist-foreign-command.json")])
        let session = PlaylistEditSession(playlistID: list, service: service)
        await session.load()
        let snapshot = try #require(session.snapshot)
        #expect(snapshot.role == .owner)
        let rows = snapshot.occurrences
        #expect(!rows[2].removable, "that row's command names a different playlist")
        #expect(rows[0].removable && rows[1].removable)
        await session.submit(.remove([rows[2]]))
        #expect(session.operations.last?.state == .failed(.notPermitted))
        #expect(await service.sent().isEmpty)
    }
    @Test func aCommandOrHeaderNamingAnotherPlaylistIsNotTrusted() async throws {
        // Read as a different playlist than the one the page's commands and header name: nothing is removable and the page is not editable.
        let service = RecordingService(pages: [try playlistPage("owned-playlist.json")])
        let session = PlaylistEditSession(playlistID: "PLanotherPlaylist0000000000000000001", service: service)
        await session.load()
        let snapshot = try #require(session.snapshot)
        #expect(snapshot.editing == nil && snapshot.role == .viewer)
        #expect(snapshot.occurrences.allSatisfy { !$0.removable })
        await session.submit(.remove([snapshot.occurrences[0]]))
        #expect(session.operations.last?.state == .failed(.notPermitted))
        #expect(await service.sent().isEmpty)
    }
}

@Suite struct PlaylistQueueSaveTests {
    private func known(_ id: String) -> MusicCatalogItem? {
        ["dQw4w9WgXcQ": "A", "aaaaaaaaaa1": "B"].first { $0.key == id }.map { MusicCatalogItem(kind: .song, title: $0.value, videoID: $0.key) }
    }
    @Test func onlySongsTheAppKnowsAsYouTubeMusicItemsAreSavedAndTheRestAreCountedLeftOut() {
        let entries = [QueueSaveAsPlaylistEntry.Entry(media: "dQw4w9WgXcQ", consumed: false, isAdvertisement: false),
                       .init(media: "owned-audio-1", consumed: false, isAdvertisement: false),
                       .init(media: "aaaaaaaaaa1", consumed: false, isAdvertisement: false),
                       .init(media: "dQw4w9WgXcQ", consumed: false, isAdvertisement: false),             // the same song twice is two entries
                       .init(media: "aaaaaaaaaa1", consumed: true, isAdvertisement: false),               // already played
                       .init(media: "dQw4w9WgXcQ", consumed: false, isAdvertisement: true)]               // an advertisement is not a song
        let result = QueueSaveAsPlaylistEntry.songs(from: entries, known: known)
        #expect(result.songs.map(\.videoID) == ["dQw4w9WgXcQ", "aaaaaaaaaa1", "dQw4w9WgXcQ"])
        #expect(result.leftOut == 1, "the owned audio is left out and counted; consumed entries and ads are neither")
        #expect(QueueSaveAsPlaylistEntry.songs(from: [], known: known).songs.isEmpty)
        let many = Array(repeating: QueueSaveAsPlaylistEntry.Entry(media: "dQw4w9WgXcQ", consumed: false, isAdvertisement: false), count: 60)
        let capped = QueueSaveAsPlaylistEntry.songs(from: many, known: known)
        #expect(capped.songs.count == 50 && capped.leftOut == 10)
    }
}
