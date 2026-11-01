import AccountSession
import Features
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// What the pages say about who may change a playlist, read from the real anonymous capture and the pages made from its renderers.
@Suite struct PlaylistParserTests {
    private func realPage() throws -> MusicBrowsePage {
        guard let root = try JSONSerialization.jsonObject(with: try w13Real("browse-playlist.json")) as? [String: Any] else { throw MusicSessionError.unrecognised }
        return try MusicBrowseParser.parse(root)
    }
    private func rows(_ page: MusicBrowsePage) -> [MusicCatalogItem] { page.shelves.flatMap(\.items) }

    @Test func theRealCopiesAreByteIdenticalToTheirSourcesAndTheManifestSaysWhatTheyAre() throws {
        let manifest = try #require(try JSONSerialization.jsonObject(with: try w13Real("manifest.json")) as? [String: Any])
        let files = try #require(manifest["files"] as? [[String: Any]])
        #expect(files.count == 2)
        for file in files {
            let name = try #require(file["path"] as? String)
            #expect(sha256(try w13Real(name)) == file["sha256"] as? String, Comment(rawValue: name))
        }
        // The real capture is also byte-identical to the W11 file it was copied from.
        let w11 = try Data(contentsOf: fixturesRoot().appendingPathComponent("W11-real/browse-playlist.json"))
        #expect(sha256(w11) == sha256(try w13Real("browse-playlist.json")))
        // The brief called Kaset's fixture a real signed one; the manifest says what it actually is.
        #expect((manifest["description"] as? String)?.contains("HAND-WRITTEN") == true)
        let generated = try #require(try JSONSerialization.jsonObject(with: try w13Data("manifest.json")) as? [String: Any])
        #expect(generated["mode"] as? String == "synthetic-from-real-renderers" && generated["live_eligible"] as? Bool == false)
        for file in try #require(generated["files"] as? [[String: Any]]) {
            let name = try #require(file["path"] as? String)
            #expect(sha256(try w13Data(name)) == file["sha256"] as? String, Comment(rawValue: name))
        }
    }
    @Test func theRealAnonymousCapturePublishesNoEditAffordanceSoNothingIsOffered() throws {
        let page = try realPage()
        #expect(page.header?.editing == nil)
        #expect(MusicPlaylistRole.of(page.header?.editing, saved: page.header?.actions.controls.save?.isSaved) == .viewer)
        let items = rows(page)
        #expect(items.count == 16 && items.allSatisfy { $0.occurrenceID != nil }, "all 16 first-page rows carry their occurrence id")
        #expect(items.allSatisfy { $0.controls?.playlistRemoval == nil })
    }
    @Test func aHeaderOnlyLayoutIsNotMisreadAsEditable() throws {
        let root = try #require(try JSONSerialization.jsonObject(with: try w13Real("kaset-playlist_detail.json")) as? [String: Any])
        // That fixture has no section header at all; whatever it parses to, it has no edit affordance.
        if let page = try? MusicBrowseParser.parse(root) { #expect(page.header?.editing == nil) }
    }
    @Test func anEditableHeaderWithADeleteCommandIsTheOwner() throws {
        let page = try playlistPage("owned-playlist.json")
        let editing = try #require(page.header?.editing)
        #expect(editing.canEditTracks && editing.canEditDetails && editing.canDelete && editing.privacy == .private)
        #expect(MusicPlaylistRole.of(editing, saved: nil) == .owner)
        #expect(page.header?.title == "The Black Eyed Peas/Daft Punk" || page.header?.title.isEmpty == false)
        #expect(page.accounting.consistent)
    }
    @Test func aDeleteCommandForAnotherPlaylistDoesNotMakeTheOwner() throws {
        var text = String(decoding: try w13Data("owned-playlist.json"), as: UTF8.self)
        // Only the header's delete command is retargeted; the edit header and the rows keep naming the page's playlist.
        let marker = "\"deletePlaylistEndpoint\": {\n"
        let range = try #require(text.range(of: marker))
        let id = try #require(text[range.upperBound...].range(of: "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"))
        text.replaceSubrange(id, with: "PLsomeoneElsesPlaylist00000000000000")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let editing = try #require(try MusicBrowseParser.parse(root).header?.editing)
        #expect(editing.canEditTracks && !editing.canDelete, "a delete command that names a different playlist is not this playlist's owner")
    }
    @Test func withoutADeleteCommandTheEditorIsACollaborator() throws {
        let editing = try #require(try playlistPage("collaborator-playlist.json").header?.editing)
        #expect(editing.canEditTracks && !editing.canEditDetails && !editing.canDelete && editing.privacy == nil)
        #expect(MusicPlaylistRole.of(editing, saved: nil) == .collaborator)
    }
    @Test func roleFollowsOnlyWhatTheServicePublishedSavedAndPublicAreRead_OnlyForViewing() {
        #expect(MusicPlaylistRole.of(nil, saved: true) == .saved)
        #expect(MusicPlaylistRole.of(nil, saved: false) == .viewer)
        #expect(MusicPlaylistRole.of(nil, saved: nil) == .viewer)
        #expect(MusicPlaylistRole.of(MusicPlaylistEditing(canEditTracks: false, canEditDetails: false, canDelete: true, privacy: .public), saved: nil) == .viewer,
                "a delete command without an editable header gives no editing rights")
        for role in [MusicPlaylistRole.saved, .viewer] { #expect(!role.canEdit) }
        for role in [MusicPlaylistRole.owner, .collaborator] { #expect(role.canEdit) }
    }
    @Test func everyOccurrenceKeepsItsOwnIdAndItsOwnRemoveCommand() throws {
        let page = try playlistPage("owned-playlist.json")
        let items = rows(page)
        let withIDs = items.compactMap(\.occurrenceID)
        #expect(withIDs.count == 17 && Set(withIDs).count == 17, "16 real rows + one duplicated song with its own id")
        let duplicated = items.filter { $0.videoID == items[0].videoID }
        #expect(duplicated.count == 2 && Set(duplicated.compactMap(\.occurrenceID)).count == 2)
        // The greyed-out row published no menu: it has an id and no remove command.
        let removable = items.filter { $0.controls?.playlistRemoval != nil }
        #expect(removable.count == 16)
        for item in removable {
            let removal = try #require(item.controls?.playlistRemoval)
            #expect(removal.setVideoID == item.occurrenceID && removal.videoID == item.videoID && removal.playlistID == "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")
        }
        #expect(items.filter { $0.controls?.playlistRemoval == nil }.count == 1)
    }
    @Test func aRemoveCommandThatNamesAnotherOccurrenceOrIsMissingGivesNoRemoval() throws {
        let items = rows(try playlistPage("owned-playlist-partial-removals.json"))
        #expect(items[1].controls?.playlistRemoval == nil, "no remove command published")
        #expect(items[2].controls?.playlistRemoval == nil, "the command names SOMEOTHEROCCURRENCE, not this row's occurrence")
        #expect(items[0].controls?.playlistRemoval != nil)
    }
    @Test func theContinuationPageKeepsItsOccurrencesAndRemoveCommands() throws {
        let page = try MusicBrowseParser.parseContinuation(try w13("owned-playlist-page2.json"))
        #expect(page.items.count == 3 && Set(page.items.compactMap(\.occurrenceID)).count == 3)
        #expect(page.items.allSatisfy { $0.controls?.playlistRemoval?.setVideoID == $0.occurrenceID })
    }
    @Test func theSnapshotReaderBuildsTheSamePlaylistTheParserSaw() async throws {
        let first = try playlistPage("owned-playlist-long.json")
        let more = try MusicBrowseParser.parseContinuation(try w13("owned-playlist-page2.json"))
        // The track shelf's own trailing continuation item names page 2 (the page's section-list token is the suggestions', not this).
        #expect(first.shelves.first?.continuation == "TRACKSPAGE2tokenAAAAAAAAAAAAAAAA%3D%3D")
        let source = PlaylistPageSource(page: { _ in first }, continuation: { token in
            guard token == "TRACKSPAGE2tokenAAAAAAAAAAAAAAAA%3D%3D" else { throw MusicSessionError.unrecognised }
            return more
        })
        let snapshot = try await PlaylistSnapshotReader.read(playlistID: "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", source: source)
        #expect(snapshot.isComplete && snapshot.occurrences.count == 20)
        #expect(Set(snapshot.occurrences.map(\.setVideoID)).count == 20)
        #expect(snapshot.role == .owner && snapshot.privacy == .private)
        #expect(snapshot.occurrences.filter(\.removable).count == 19, "the greyed row is listed but not removable")
        #expect(snapshot.unaddressableCount == 0)
    }
}
