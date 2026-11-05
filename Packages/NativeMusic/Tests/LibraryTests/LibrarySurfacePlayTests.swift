import AccountSession
import Features
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// CORE-B (C4, C3): a Library row's Play and Start Radio start exactly what the row names, through the one performer. Rows are parsed from the
/// labelled W12/W11 fixtures (`synthetic-from-real-renderers`, `real-public-anonymous-capture`) except where a test says it builds one by hand.
@Suite @MainActor struct LibrarySurfacePlayTests {
    @MainActor final class Performer: SearchActionPerformer {
        var targets: [(playlist: String, video: String?, params: String?)] = []
        var outcome: SearchPlayOutcome = .started
        var shared: [URL] = []
        var copied: [URL] = []
        func share(link: URL) -> Bool { shared.append(link); return true }
        func play(playlistID: String, title: String) async -> SearchPlayOutcome { targets.append((playlistID, nil, nil)); return outcome }
        func play(playlistID: String, title: String, videoID: String?, params: String?) async -> SearchPlayOutcome { targets.append((playlistID, videoID, params)); return outcome }
        func copy(link: URL) { copied.append(link) }
    }
    private func surface(_ performer: Performer, playback: SearchPlayback = .available) -> LibrarySurface {
        LibrarySurface(models: [:], history: HistoryModel(remote: LibraryCollectionModel(source: .history, reader: { _ in throw MusicSessionError.policy }, continuer: { _ in throw MusicSessionError.policy }),
                                                         store: nil, policy: nil, accountKey: { nil }),
                       ledger: LibraryWriteLedger(writer: { _ in throw MusicSessionError.policy }), performer: performer, playback: { playback })
    }
    private func song(_ title: String = "Row", video: String = "rowVideo0001", context: String? = nil, upload: Bool = false, radio: MusicRadioAction? = nil,
                      availability: MusicAvailability = .available) -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: title, availability: availability, videoID: video, contextPlaylistID: context, isPrivatelyOwned: upload, radio: radio)
    }

    // MARK: Play (C4)

    /// Built by hand: the Liked Songs row names the `LM` playlist as its context, and Play continues that list from this track.
    @Test func aLikedSongsRowPlaysFromTheLikedMusicListAtThatTrack() async throws {
        let performer = Performer(), library = surface(performer)
        await library.perform(.play, on: song(video: "likedTrack01", context: "LM"), key: "row")
        let call = try #require(performer.targets.first)
        #expect(performer.targets.count == 1 && call.playlist == "LM" && call.video == "likedTrack01" && call.params == nil)
        #expect(library.feedback["row"] == .started)
    }
    @Test func aLibraryAlbumRowPlaysItsOwnPlaylistFromTheStart() async throws {
        let album = try #require(try libraryPage("library-albums.json").shelves.flatMap(\.items).first { $0.kind == .album && $0.playlistID != nil })
        let performer = Performer(), library = surface(performer)
        await library.perform(.play, on: album, key: "album")
        let call = try #require(performer.targets.first)
        #expect(performer.targets.count == 1 && call.playlist == album.playlistID && call.video == nil && call.params == nil)
        #expect(library.feedback["album"] == .started)
    }
    @Test func aCollectionSongRowPlaysTheListItsOwnRowNamesFromThatTrack() async throws {
        let rows = try MusicBrowseParser.parse(try realCapture("playlist"), mode: .collection).shelves.flatMap(\.items)
        let row = try #require(rows.first { $0.kind == .song && $0.availability == .available && $0.videoID != nil && ($0.contextPlaylistID ?? "RDAMVM").hasPrefix("RDAMVM") == false })
        let performer = Performer(), library = surface(performer)
        await library.perform(.play, on: row, key: "row")
        let call = try #require(performer.targets.first)
        #expect(call.playlist == row.contextPlaylistID && call.video == row.videoID && call.params == nil)
    }
    /// The first row of the W12 history capture is a song of an album: its own row names that album's playlist, and Play continues it from the track.
    /// The expected ids are read off the fixture, not computed by the production rule.
    @Test func aHistorySongRowPlaysTheAlbumItsRowNamesFromThatTrack() async throws {
        let row = try #require(try libraryPage("history.json").shelves.flatMap(\.items).first { ($0.kind == .song || $0.kind == .video) && $0.videoID != nil })
        #expect(row.videoID == "IluRBvnYMoY" && row.contextPlaylistID == "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c", "the fixture row this test pins")
        let performer = Performer(), library = surface(performer)
        await library.perform(.play, on: row, key: "history")
        let call = try #require(performer.targets.first)
        #expect(performer.targets.count == 1 && call.playlist == "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c" && call.video == "IluRBvnYMoY" && call.params == nil)
        #expect(library.feedback["history"] == .started)
    }
    @Test func aBusyStartIsSaidAtTheRowNotSilent() async throws {
        let performer = Performer(); performer.outcome = .busy
        let library = surface(performer)
        await library.perform(.play, on: song(context: "LM"), key: "row")
        guard case .failed(let message)? = library.feedback["row"] else { Issue.record("a busy start must say so"); return }
        #expect(message == String(localized: "Another start is still in progress. Try again in a moment."))
        await library.perform(.radio, on: song(context: "LM", radio: MusicRadioAction(playlistID: "RDAMVMradioSeed01", videoID: "radioSeed01", params: "wAEB")), key: "radio")
        guard case .failed(let radioMessage)? = library.feedback["radio"] else { Issue.record("a busy Start Radio must say so"); return }
        #expect(radioMessage == message)
    }
    @Test func aSignedOutPlayNeverReachesThePerformerAndSaysWhy() async throws {
        let performer = Performer(), library = surface(performer, playback: .needsSignIn)
        await library.perform(.play, on: song(context: "LM"), key: "row")
        #expect(performer.targets.isEmpty)
        guard case .failed(let message)? = library.feedback["row"] else { Issue.record("the reason is shown at the row"); return }
        #expect(!message.isEmpty)
    }
    @Test func aFailedStartIsReportedAtTheRow() async throws {
        let performer = Performer(); performer.outcome = .failed
        let library = surface(performer)
        await library.perform(.play, on: song(context: "LM"), key: "row")
        guard case .failed? = library.feedback["row"] else { Issue.record("a failed start is not silent"); return }
    }

    // MARK: Share (SHARE)

    @Test func shareOnALibraryRowOpensTheSheetForTheRowsOwnLinkOnly() async throws {
        let performer = Performer(), library = surface(performer)
        let row = song(video: "shareRow001", context: "LM")
        _ = library.offers(for: row)
        #expect(performer.shared.isEmpty && performer.copied.isEmpty, "opening a menu shares nothing")
        await library.perform(.share, on: row, key: "row")
        #expect(performer.shared.map(\.absoluteString) == ["https://music.youtube.com/watch?v=shareRow001"], "never the Liked Music list the row sits in")
        #expect(performer.copied.isEmpty && performer.targets.isEmpty && library.feedback["row"] == nil)
        let upload = song(video: "shareRow002", upload: true)
        #expect(!library.offers(for: upload).map(\.action).contains(.share))
        await library.perform(.share, on: upload, key: "upload")
        guard case .failed? = library.feedback["upload"] else { Issue.record("a private upload is refused at its row"); return }
        #expect(performer.shared.count == 1)
    }

    // MARK: Start Radio (C3)

    @Test func startRadioOnALibraryRowStartsExactlyTheRadioTheRowPublished() async throws {
        let radio = MusicRadioAction(playlistID: "RDAMVMradioSeed01", videoID: "radioSeed01", params: "wAEB")
        let row = song(video: "radioSeed01", context: "LM", radio: radio)
        let performer = Performer(), library = surface(performer)
        let offers = library.offers(for: row)
        #expect(offers.map(\.action) == [.play, .radio, .copyLink, .share] && offers.allSatisfy(\.isAvailable))
        await library.perform(.radio, on: row, key: "row")
        let call = try #require(performer.targets.first)
        #expect(performer.targets.count == 1 && call.playlist == "RDAMVMradioSeed01" && call.video == "radioSeed01" && call.params == nil, "the flag is not sent: the player would treat it as a shuffle")
        #expect(library.feedback["row"] == .started)
    }
    @Test func aRowWhosePlayAlreadyStartsItsRadioHasNoSecondControlForIt() async throws {
        let radio = MusicRadioAction(playlistID: "RDAMVMradioSeed01", videoID: "radioSeed01", params: "wAEB")
        let row = song(video: "radioSeed01", radio: radio)   // no collection context: Play is the song's own radio
        let library = surface(Performer())
        #expect(library.offers(for: row).map(\.action) == [.play, .copyLink, .share])
    }
    @Test func aRowThatPublishedNoRadioHasNoStartRadioAndTheActionDoesNothing() async throws {
        // Its id could be turned into an RDAMVM list, and must not be: no link, no action.
        let row = song(video: "noRadioRow01", context: "LM")
        let performer = Performer(), library = surface(performer)
        #expect(!library.offers(for: row).contains { $0.action == .radio })
        await library.perform(.radio, on: row, key: "row")
        #expect(performer.targets.isEmpty)
        guard case .failed? = library.feedback["row"] else { Issue.record("a stale tap is reported, not ignored"); return }
    }
    @Test func anUploadAndAnUnavailableTrackNeverOfferStartRadio() async throws {
        let radio = MusicRadioAction(playlistID: "RDAMVMsomething01", videoID: "something01")
        let performer = Performer(), library = surface(performer)
        #expect(!library.offers(for: song(upload: true, radio: radio)).contains { $0.action == .radio })
        #expect(!library.offers(for: song(radio: radio, availability: .unavailable)).contains { $0.action == .radio })
        await library.perform(.radio, on: song(upload: true, radio: radio), key: "upload")
        #expect(performer.targets.isEmpty)
    }
    @Test func signedOutStartRadioIsStatedNotSent() async throws {
        let radio = MusicRadioAction(playlistID: "RDAMVMradioSeed01", videoID: "radioSeed01")
        let performer = Performer(), library = surface(performer, playback: .needsSignIn)
        let row = song(video: "radioSeed01", context: "LM", radio: radio)
        #expect(library.offers(for: row).first { $0.action == .radio }?.unavailable != nil)
        await library.perform(.radio, on: row, key: "row")
        #expect(performer.targets.isEmpty)
    }
}
