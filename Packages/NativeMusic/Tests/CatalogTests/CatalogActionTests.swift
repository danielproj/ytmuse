import AccountSession
import Features
import Foundation
import Playback
import Testing
import YouTubeMusicAdapter

/// T11.3: artist, album and song workflows, plus the rule that no control is ever inert.
@MainActor @Suite struct CatalogActionTests {
    private func item(_ capture: Capture, shelf: Int = 0, index: Int = 0) throws -> MusicCatalogItem { try realPage(capture).shelves[shelf].items[index] }

    // MARK: Action plan

    @Test func playTargetsAreTheEntrysOwnIdentifiers() throws {
        let song = try item(.home)
        #expect(CatalogActionPlan.playlist(for: song) == "RDAMVMZ85lxckrtzg")
        let album = try item(.home, shelf: 1)
        #expect(CatalogActionPlan.playlist(for: album) == album.playlistID)
        let artist = try item(.charts, shelf: 1)
        #expect(CatalogActionPlan.playlist(for: artist) == nil)
        #expect(CatalogActionPlan.offers(for: artist, playback: .available).isEmpty == false && CatalogActionPlan.offers(for: artist, playback: .available).map(\.action) == [.copyLink])
        let category = try item(.explore)
        #expect(CatalogActionPlan.offers(for: category, playback: .available).isEmpty && CatalogActionPlan.link(for: category) == nil)
    }
    @Test func canonicalLinksAreMusicYouTubeLinks() throws {
        #expect(CatalogActionPlan.link(for: try item(.home))?.absoluteString == "https://music.youtube.com/watch?v=Z85lxckrtzg")
        let album = try item(.home, shelf: 1)
        #expect(CatalogActionPlan.link(for: album)?.absoluteString == "https://music.youtube.com/playlist?list=" + album.playlistID!)
        #expect(CatalogActionPlan.link(for: try item(.charts, shelf: 1))?.absoluteString == "https://music.youtube.com/channel/UCptBkLZ6XRxoyn8SkUMc_Iw")
        let podcastEpisode = try item(.podcast)
        #expect(CatalogActionPlan.link(for: podcastEpisode)?.absoluteString == "https://music.youtube.com/watch?v=" + podcastEpisode.videoID!)
    }
    /// A Play button is drawn only where Play could ever run; elsewhere the reason is text. Signing in changes what a
    /// button does, never whether one exists, so a signed-out song still has its Play.
    @Test func aPlayControlExistsOnlyWhereItCouldEverRun() throws {
        #expect(CatalogActionPlan.canEverPlay(try item(.home)))
        #expect(CatalogActionPlan.canEverPlay(try item(.home, shelf: 1)))
        let grey = try #require(try realPage(.playlist).shelves[0].items.first { $0.availability == .unavailable })
        #expect(!CatalogActionPlan.canEverPlay(grey))
        #expect(!CatalogActionPlan.canEverPlay(try item(.podcast)), "a lone episode")
        #expect(!CatalogActionPlan.canEverPlay(try item(.charts, shelf: 1)), "an artist has no Play")
        #expect(!CatalogActionPlan.canEverPlay(try item(.explore)), "a category")
        for capture in Capture.allCases {
            for entry in try realPage(capture).shelves.flatMap(\.items) where CatalogActionPlan.canEverPlay(entry) {
                #expect(CatalogActionPlan.offers(for: entry, playback: .available).first { $0.action == .play }?.unavailable == nil, "\(capture) \(entry.title)")
            }
        }
    }
    @Test func playbackReasonsAreStatedAtTheAction() throws {
        let song = try item(.home)
        #expect(CatalogActionPlan.offers(for: song, playback: .available).first?.unavailable == nil)
        #expect(CatalogActionPlan.offers(for: song, playback: .needsSignIn).first?.unavailable != nil)
        #expect(CatalogActionPlan.offers(for: song, playback: .sessionExpired).first?.unavailable != nil)
        let episode = try item(.podcast)
        // W18 rework 1: an episode plays from its own row or page (the podcast surface), so this table no longer claims it "can't be played from here yet".
        #expect(!CatalogActionPlan.offers(for: episode, playback: .available).contains { $0.action == .play }, "Play for an episode is the podcast surface's")
    }
    @Test func pageActionsAreOnlyThosetheServicePublishedAPlaylistFor() throws {
        let artist = try #require(try realPage(.artist).header)
        #expect(CatalogActionPlan.offers(for: artist.actions, playback: .available).map(\.action) == [.shuffle, .radio])
        let album = try #require(try realPage(.album).header)
        #expect(CatalogActionPlan.offers(for: album.actions, playback: .available).map(\.action) == [.play, .shuffle, .radio])
        let podcast = try #require(try realPage(.podcast).header)
        #expect(CatalogActionPlan.offers(for: podcast.actions, playback: .available).isEmpty)
        #expect(CatalogActionPlan.offers(for: album.actions, playback: .needsSignIn).allSatisfy { $0.unavailable != nil })
    }
    @Test func followAndSaveAreNeverControlsOnlyAnHonestNote() throws {
        let artist = try #require(try realPage(.artist).header)
        let note = try #require(CatalogActionPlan.writeNote(for: artist.actions))
        #expect(note.localizedCaseInsensitiveContains("following") && !note.localizedCaseInsensitiveContains("saving"))
        let album = try #require(try realPage(.album).header)
        #expect(CatalogActionPlan.writeNote(for: album.actions)?.localizedCaseInsensitiveContains("saving") == true)
        #expect(CatalogActionPlan.writeNote(for: MusicPageActions(offersSave: true, offersFollow: true))?.contains("Following and saving") == true)
        #expect(CatalogActionPlan.writeNote(for: MusicPageActions(play: "x")) == nil && CatalogActionPlan.writeNote(for: nil) == nil)
        // No action enum case exists for a write.
        #expect(Set(CatalogAction.allCases.map(\.rawValue)) == ["play", "shuffle", "radio", "copyLink"])
    }

    /// Never an inert control: every offer on every entry of every real capture either runs (a playlist the hidden
    /// player's validator accepts, or a link) or carries a reason.
    @Test(arguments: Capture.allCases) func everyOfferEitherRunsOrSaysWhy(capture: Capture) throws {
        let page = try realPage(capture)
        for entry in page.shelves.flatMap(\.items) {
            for offer in CatalogActionPlan.offers(for: entry, playback: .available) {
                switch offer.action {
                case .play:
                    if offer.unavailable == nil { #expect(CatalogActionPlan.playlist(for: entry).map(WebMusicIdentifier.isPlaylistID) == true, "\(capture) \(entry.title)") }
                    else { #expect(offer.unavailable?.isEmpty == false) }
                case .copyLink: #expect(CatalogActionPlan.link(for: entry) != nil)
                case .radio:
                    // Only a song or video, only from the radio its own row published; the hidden player's validator accepts the playlist.
                    let radio = try #require(CatalogActionPlan.radioTarget(for: entry), "\(capture) \(entry.title)")
                    #expect(entry.kind == .song || entry.kind == .video)
                    #expect(WebMusicIdentifier.isPlaylistID(radio.playlistID) && radio.playlistID == entry.radio?.playlistID, "\(capture) \(entry.title)")
                    #expect(radio.params == nil, "a row radio is never sent with the shuffle-shaped parameters")
                    #expect(offer.unavailable == nil)
                case .shuffle: Issue.record("an entry offered \(offer.action)")
                }
            }
        }
        if let actions = page.header?.actions {
            for offer in CatalogActionPlan.offers(for: actions, playback: .available) {
                let id = try #require(CatalogActionPlan.playlist(for: offer.action, in: actions))
                #expect(WebMusicIdentifier.isPlaylistID(id), "\(capture) \(offer.action)")
            }
        }
    }

    // MARK: Performing (shared command layer → hidden player)

    @Test func playGoesThroughThePerformerWithTheEntrysPlaylist() async throws {
        let script = ServiceScript(), performer = StubPerformer()
        await script.setPages(.home, [try realPage(.home)])
        let model = makeModel(.home, script: script, performer: performer)
        await model.load()
        let song = model.shelves[0].items[0]
        await model.perform(.play, on: song)
        #expect(performer.played.map(\.0) == ["RDAMVMZ85lxckrtzg"] && performer.played.map(\.1) == ["Thriller"] && model.feedback[song.id] == .started)
        await model.perform(.copyLink, on: song)
        #expect(performer.copied.map(\.absoluteString) == ["https://music.youtube.com/watch?v=Z85lxckrtzg"] && model.feedback[song.id] == .copied)
    }
    @Test func outcomesAreShownAtTheItem() async throws {
        let script = ServiceScript(), performer = StubPerformer()
        await script.setPages(.home, [try realPage(.home)])
        let model = makeModel(.home, script: script, performer: performer)
        await model.load()
        let song = model.shelves[0].items[0]
        performer.outcome = .failed
        await model.perform(.play, on: song)
        guard case .failed(let message)? = model.feedback[song.id] else { Issue.record("expected a failure at the item"); return }
        #expect(!message.isEmpty)
        performer.outcome = .stale
        await model.perform(.play, on: song)
        if case .failed? = model.feedback[song.id] {} else { Issue.record("stale is reported") }
        performer.outcome = .busy
        await model.perform(.play, on: song)
        // C5: a start refused because another is still under way says so, at the item; it is neither silent nor a failure of the service.
        guard case .failed(let busy)? = model.feedback[song.id] else { Issue.record("busy is not silent"); return }
        #expect(!busy.isEmpty && busy != message)
    }
    @Test func aPlayPressedWhileAShuffleIsStillStartingSaysSoAtThePageAndAtTheItem() async throws {
        let script = ServiceScript(), performer = StubPerformer()
        await script.setPages(.home, [try realPage(.home)])
        let model = makeModel(.home, script: script, performer: performer)
        await model.load()
        let song = model.shelves[0].items[0]
        performer.outcome = .busy
        await model.perform(.play, on: song)
        guard case .failed(let first)? = model.feedback[song.id] else { Issue.record("expected the busy line"); return }
        performer.outcome = .started
        await model.perform(.play, on: song)
        #expect(model.feedback[song.id] == .started, "once the other start is over the line is replaced by the real outcome")
        #expect(!first.isEmpty)
    }
    @Test func signedOutPlayNeverReachesThePerformer() async throws {
        let script = ServiceScript(), performer = StubPerformer()
        await script.setPages(.home, [try realPage(.home)])
        let model = makeModel(.home, script: script, performer: performer, playback: .needsSignIn)
        await model.load()
        let song = model.shelves[0].items[0]
        await model.perform(.play, on: song)
        #expect(performer.played.isEmpty)
        guard case .failed(let message)? = model.feedback[song.id] else { Issue.record("expected the reason"); return }
        #expect(message == CatalogActionPlan.offers(for: song, playback: .needsSignIn).first?.unavailable)
    }
    @Test func pageActionsStartThePlaylistsTheServicePublishedIncludingThePodcastShow() async throws {
        let script = ServiceScript(), performer = StubPerformer()
        let album = CatalogTarget(browseID: "MPREb_K8qWMWVqXGi")
        await script.setPages(album, [try realPage(.album)])
        let model = makeModel(album, script: script, performer: performer)
        await model.load()
        await model.perform(.radio)
        await model.perform(.play)
        #expect(performer.played.map(\.0) == ["RDAMPLOLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c", "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c"])
        #expect(performer.played.allSatisfy { $0.1 == "Random Access Memories" })
        let show = CatalogTarget(browseID: "MPSPPLZr1D7YmlHJw")
        await script.setPages(show, [try realPage(.podcast)])
        let podcast = makeModel(show, script: script, performer: performer)
        await podcast.load()
        #expect(podcast.pageActions?.play == "PLZr1D7YmlHJw")
        await podcast.perform(.play)
        #expect(performer.played.last?.0 == "PLZr1D7YmlHJw")
        await podcast.perform(.shuffle)
        #expect(performer.played.count == 3 && { if case .failed? = podcast.feedback["page:shuffle"] { return true }; return false }(), "an unpublished action is refused, not guessed")
    }

    // MARK: Detail projections

    @Test func songDetailCarriesCreditsAvailabilityQualityAndActions() throws {
        let song = try item(.home)
        let detail = try #require(SongDetail(item: song))
        #expect(detail.artists.map(\.browseID) == ["UCoIOOL7QKuBhQHVKL8y7BEQ"] && detail.album?.browseID == "MPREb_dqWTncCjkSp")
        #expect(detail.isAvailable && detail.quality == .chosenByService)
        #expect(detail.offers(playback: .available).map(\.action) == [.play, .copyLink], "a Home song's Play already starts its radio, so there is no second control for it")
        let grey = try #require(try realPage(.playlist).shelves[0].items.first { $0.availability == .unavailable })
        let unavailable = try #require(SongDetail(item: grey))
        #expect(!unavailable.isAvailable && unavailable.offers(playback: .available).first?.unavailable != nil)
        #expect(SongDetail(item: try item(.charts, shelf: 1)) == nil, "an artist is not a song")
    }
    @Test func shelfRolesComeFromTheEntriesNotTheLocalisedTitles() throws {
        let artist = try realPage(.artist)
        #expect(artist.shelves.map { CatalogShelves.role(of: $0) } == [.tracks, .albums, .singles, .videos, .videos, .playlists, .playlists, .artists])
        let home = try realPage(.home)
        #expect(home.shelves.map { CatalogShelves.role(of: $0) } == [.tracks, .singles])
        let explore = try realPage(.explore)
        #expect(explore.shelves.map { CatalogShelves.role(of: $0) } == [.categories, .releases, .categories, .videos])
        // Retitling every shelf (another interface language) changes no role.
        let retitled = artist.shelves.map { MusicShelf(key: $0.key, title: "—", layout: $0.layout, items: $0.items) }
        #expect(retitled.map { CatalogShelves.role(of: $0) } == artist.shelves.map { CatalogShelves.role(of: $0) })
        let album = try realPage(.album)
        #expect(album.shelves.map { CatalogShelves.role(of: $0, pageTitle: album.header?.title) } == [.tracks, .editions, .releases])
    }
    @Test func targetsFromRoutesAndEntries() throws {
        #expect(CatalogTarget(kind: .artist, identifier: "UCRr1xG_2WIDs18a6cIiCxeA")?.browseID == "UCRr1xG_2WIDs18a6cIiCxeA")
        #expect(CatalogTarget(kind: .playlist, identifier: "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")?.browseID == "VLPLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")
        #expect(CatalogTarget(kind: .playlist, identifier: "VLPLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")?.browseID == "VLPLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")
        #expect(CatalogTarget(kind: .song, identifier: "Z85lxckrtzg") == nil && CatalogTarget(kind: .album, identifier: "bad id") == nil)
        let mood = try item(.explore, shelf: 2)
        #expect(CatalogTarget(item: mood) == CatalogTarget(browseID: "FEmusic_moods_and_genres_category", params: mood.browseParams))
        #expect(CatalogTarget(item: try item(.home)) == nil)
        #expect(CatalogTarget(link: MusicLink(kind: .other, title: "x", browseID: "FEmusic_new_releases_albums", params: "p%3D")).key == "FEmusic_new_releases_albums?p%3D")
    }
    // MARK: Start Radio on a song (CORE-B C3)

    /// A song or video that published a radio gets Start Radio exactly where its Play does something else (it continues a collection): the
    /// rule is written here from the row's own context, not from the production function. Where Play already starts that same radio there is no second control.
    @Test func startRadioIsOfferedExactlyWhereItDiffersFromPlay() async throws {
        var offeredCount = 0, suppressedCount = 0
        for capture in Capture.allCases {
            for entry in try realPage(capture).shelves.flatMap(\.items) where entry.kind == .song || entry.kind == .video {
                let offered = CatalogActionPlan.offers(for: entry, playback: .available).contains { $0.action == .radio }
                let playContinuesACollection = entry.contextPlaylistID.map { !$0.hasPrefix("RDAMVM") } ?? false
                if let radio = entry.radio, entry.availability != .unavailable, !entry.isUpload {
                    if playContinuesACollection {
                        offeredCount += 1
                        #expect(offered, "\(capture) \(entry.title): Play continues a collection, the radio is a different outcome")
                        #expect(CatalogActionPlan.radioTarget(for: entry) == CatalogActionPlan.PlayTarget(playlistID: radio.playlistID, videoID: radio.videoID, params: nil))
                    } else {
                        suppressedCount += 1
                        #expect(!offered, "\(capture) \(entry.title): Play already starts this radio")
                    }
                } else { #expect(!offered, "\(capture) \(entry.title) published none") }
            }
        }
        #expect(offeredCount > 0 && suppressedCount > 0, "the captures must contain both kinds of row or this proves nothing (\(offeredCount), \(suppressedCount))")
    }
    @Test func aHomeSongPlayThatIsItsOwnRadioHasNoStartRadio() throws {
        let song = try item(.home)
        #expect(song.radio?.playlistID == "RDAMVMZ85lxckrtzg" && CatalogActionPlan.playlist(for: song) == "RDAMVMZ85lxckrtzg")
        #expect(!CatalogActionPlan.offers(for: song, playback: .available).contains { $0.action == .radio })
        #expect(CatalogActionPlan.radioTarget(for: song) == nil)
    }
    @Test func performingStartRadioSendsTheRowsOwnPlaylistAndTrackWithoutParameters() async throws {
        var found: MusicCatalogItem?
        for capture in Capture.allCases where found == nil {
            found = try realPage(capture).shelves.flatMap(\.items).first { CatalogActionPlan.radioTarget(for: $0) != nil }
        }
        let row = try #require(found, "a real row with an offered Start Radio")
        let radio = try #require(row.radio)
        #expect(radio.params != nil, "the published radio carries the service's flag; it must not be sent")
        let script = ServiceScript(), performer = StubPerformer()
        let model = makeModel(.home, script: script, performer: performer)
        await model.perform(.radio, on: row)
        let call = try #require(performer.targets.first)
        #expect(performer.targets.count == 1 && call.playlist == radio.playlistID && call.video == radio.videoID && call.params == nil)
        #expect(performer.played.first?.1 == row.title && model.feedback[row.id] == .started)
    }
    @Test func aRowInsideACollectionStartsItsRadioNotTheCollection() async throws {
        // Built by hand: an album track whose Play continues the album and whose menu also published "Start mix".
        let radio = MusicRadioAction(playlistID: "RDAMVMtrackInAlbum", videoID: "trackInAlbum", params: "wAEB")
        let track = MusicCatalogItem(kind: .song, title: "Track", videoID: "trackInAlbum", contextPlaylistID: "OLAK5uy_albumList0001", radio: radio)
        let script = ServiceScript(), performer = StubPerformer()
        let model = makeModel(.home, script: script, performer: performer)
        #expect(model.offers(for: track).map(\.action) == [.play, .radio, .copyLink])
        await model.perform(.play, on: track)
        await model.perform(.radio, on: track)
        #expect(performer.targets.count == 2)
        #expect(performer.targets[0].playlist == "OLAK5uy_albumList0001" && performer.targets[0].video == "trackInAlbum" && performer.targets[0].params == nil)
        #expect(performer.targets[1].playlist == "RDAMVMtrackInAlbum" && performer.targets[1].video == "trackInAlbum" && performer.targets[1].params == nil, "the radio's flag is not sent")
    }
    /// The action is absent, not disabled, and a stale tap starts nothing: a radio is never made from a video id.
    @Test func aRowWithoutAPublishedRadioHasNoStartRadioAndNothingIsDerived() async throws {
        let track = MusicCatalogItem(kind: .song, title: "Plain", videoID: "plainTrack01", contextPlaylistID: "OLAK5uy_albumList0001")
        let script = ServiceScript(), performer = StubPerformer()
        let model = makeModel(.home, script: script, performer: performer)
        #expect(!model.offers(for: track).contains { $0.action == .radio })
        #expect(!SongDetail(item: track)!.offers(playback: .available).contains { $0.action == .radio })
        #expect(CatalogActionPlan.radioTarget(for: track) == nil)
        await model.perform(.radio, on: track)
        #expect(performer.targets.isEmpty)
        guard case .failed? = model.feedback[track.id] else { Issue.record("a stale tap is reported"); return }
    }
    @Test func startRadioIsNeverOfferedForAnUploadAnUnavailableTrackOrAnotherKind() throws {
        let radio = MusicRadioAction(playlistID: "RDAMVMsomething01", videoID: "something01")
        let upload = MusicCatalogItem(kind: .song, title: "Mine", videoID: "something01", isUpload: true, radio: radio)
        let grey = MusicCatalogItem(kind: .song, title: "Grey", availability: .unavailable, videoID: "something01", radio: radio)
        let album = MusicCatalogItem(kind: .album, title: "Album", browseID: "MPREb_x", playlistID: "OLAK5uy_albumList0001", radio: radio)
        for entry in [upload, grey, album] { #expect(!CatalogActionPlan.offers(for: entry, playback: .available).contains { $0.action == .radio }, "\(entry.title)") }
    }
    @Test func signedOutStartRadioCarriesTheSameReasonAsPlayAndSendsNothing() async throws {
        let radio = MusicRadioAction(playlistID: "RDAMVMsomething01", videoID: "something01")
        let track = MusicCatalogItem(kind: .song, title: "Track", videoID: "something01", contextPlaylistID: "OLAK5uy_albumList0001", radio: radio)
        let script = ServiceScript(), performer = StubPerformer()
        let model = makeModel(.home, script: script, performer: performer, playback: .needsSignIn)
        let offers = CatalogActionPlan.offers(for: track, playback: .needsSignIn)
        #expect(offers.first { $0.action == .radio }?.unavailable != nil && offers.first { $0.action == .radio }?.unavailable == offers.first { $0.action == .play }?.unavailable)
        await model.perform(.radio, on: track)
        #expect(performer.targets.isEmpty)
    }
}
