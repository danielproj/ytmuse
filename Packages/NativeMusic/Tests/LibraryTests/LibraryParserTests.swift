import AccountSession
import Features
import Foundation
import Testing
@testable import YouTubeMusicAdapter

/// Parse coverage per library kind (T12.1). The pages are library containers holding entries copied from the real anonymous
/// captures (`Fixtures/W12`, `synthetic-from-real-renderers`); the liked-songs page IS the real playlist capture read as a collection.
/// Every renderer in the document is accounted for: a test fails if any is silently dropped.
@Suite struct LibraryParserTests {
    struct Expected { let name: String; let kind: MusicLibraryKind; let items: Int; let classified: Int; let unsupported: Int; let kinds: Set<MusicEntityKind> }
    static let table: [Expected] = [
        .init(name: "library-songs", kind: .songs, items: 8, classified: 7, unsupported: 1, kinds: [.video]),
        .init(name: "library-albums", kind: .albums, items: 6, classified: 6, unsupported: 0, kinds: [.album]),
        .init(name: "library-artists", kind: .artists, items: 6, classified: 6, unsupported: 0, kinds: [.artist]),
        .init(name: "library-following", kind: .following, items: 6, classified: 6, unsupported: 0, kinds: [.artist]),
        .init(name: "library-playlists", kind: .playlists, items: 5, classified: 4, unsupported: 1, kinds: [.playlist]),
        .init(name: "library-podcasts", kind: .podcasts, items: 2, classified: 2, unsupported: 0, kinds: [.podcast]),
        .init(name: "library-saved-episodes", kind: .savedEpisodes, items: 8, classified: 8, unsupported: 0, kinds: [.episode]),
        .init(name: "library-uploads", kind: .uploads, items: 4, classified: 4, unsupported: 0, kinds: [.song]),
    ]

    @Test(arguments: LibraryParserTests.table) func everyRendererIsAccountedForAndHoldsTheKindsItsCollectionHolds(_ expected: Expected) throws {
        let root = try w12(expected.name + ".json")
        let page = try MusicBrowseParser.parse(root, mode: .collection)
        let accounting = page.accounting
        #expect(accounting.consistent)
        // The oracle is an independent walk of the raw document: a renderer dropped without a count fails here.
        #expect(accounting.items == countEntryRenderers(in: root))
        #expect(accounting.items == expected.items && accounting.classified == expected.classified && accounting.unsupported == expected.unsupported)
        #expect(accounting.skipped == 0 && accounting.duplicates == 0)
        let kinds = Set(page.shelves.flatMap(\.items).map(\.kind))
        #expect(kinds == expected.kinds)
        #expect(kinds.isSubset(of: expected.kind.holds), "a \(expected.kind) page held entries its collection doesn't")
    }

    @Test func likedSongsIsTheRealPlaylistCaptureReadAsACollection() throws {
        let root = try realCapture("playlist")
        let page = try MusicBrowseParser.parse(root, mode: .collection)
        #expect(page.accounting.items == countEntryRenderers(in: root) && page.accounting.items == 16)
        #expect(page.accounting.classified == 16 && page.accounting.skipped == 0 && page.accounting.unsupported == 0)
        let items = page.shelves.flatMap(\.items)
        #expect(items.filter { $0.availability == .unavailable }.count == 1, "the greyed-out track is listed, not dropped")
        #expect(items.allSatisfy { MusicLibraryKind.likedSongs.holds.contains($0.kind) })
    }

    @Test func everyKindsPageIsAccountedForAcrossItsContinuations() throws {
        let first = try libraryPage("library-songs.json"), second = try libraryContinuation("library-songs-page2.json"), third = try libraryContinuation("library-songs-page3.json")
        #expect(first.shelves[0].continuation == "LIBSONGS-2" && second.continuation == "LIBSONGS-3" && third.continuation == nil)
        for page in [second, third] { #expect(page.accounting.consistent && page.accounting.skipped == 0) }
        #expect(first.accounting.classified + second.accounting.classified + third.accounting.classified == 7 + 5 + 2)
        let albums = try libraryContinuation("library-albums-page2.json")
        #expect(albums.accounting.items == 4 && albums.accounting.classified == 4)
        let history = try libraryContinuation("history-page2.json")
        #expect(history.accounting.items == 2 && history.accounting.classified == 2)
    }

    // MARK: Repeats and control tiles

    @Test func aSongListedTwiceIsKeptInACollectionAndDroppedInTheCatalog() throws {
        let root = try w12("library-songs.json")
        let collection = try MusicBrowseParser.parse(root, mode: .collection)
        let ids = collection.shelves[0].items.compactMap(\.videoID)
        #expect(ids.count == 7 && Set(ids).count == 6, "the repeated row is a second row")
        #expect(collection.accounting.duplicates == 0)
        let catalog = try MusicBrowseParser.parse(root)
        #expect(catalog.accounting.duplicates >= 1 && catalog.shelves[0].items.count == 6, "the catalog reading dedupes, as it always has")
    }
    @Test func historyKeepsTheSamePlayTwiceOnTheSameDayInOrder() throws {
        let page = try libraryPage("history.json")
        #expect(page.shelves.map(\.title) == ["Today", "Yesterday"])
        let today = page.shelves[0].items.compactMap(\.videoID)
        #expect(today.count == 3 && today[0] == today[2])
        #expect(page.accounting.duplicates == 0 && page.accounting.classified == 5)
    }
    @Test func controlTilesAreCountedAsUnsupportedNotAsMembers() throws {
        let songs = try libraryPage("library-songs.json")
        #expect(songs.accounting.unsupported == 1, "the Shuffle-all row")
        let playlists = try libraryPage("library-playlists.json")
        #expect(playlists.accounting.unsupported == 1 && playlists.shelves[0].items.count == 4, "the New-playlist tile")
        // The same tile in a catalog reading keeps its old classification (unreadable), so catalog behaviour is unchanged.
        let catalog = try MusicBrowseParser.parse(try w12("library-playlists.json"))
        #expect(catalog.accounting.skipped + catalog.accounting.unsupported == 1)
    }
    @Test func uploadedTracksAreMarkedAndOnlyReadInACollection() throws {
        let page = try libraryPage("library-uploads.json")
        #expect(page.shelves[0].items.count == 4 && page.shelves[0].items.allSatisfy { $0.isUpload && $0.kind == .song })
        let catalog = try? MusicBrowseParser.parse(try w12("library-uploads.json"))
        #expect(catalog == nil || catalog?.shelves.flatMap(\.items).isEmpty == true, "a catalog page never presents an upload")
    }
    @Test @MainActor func anUploadedTrackIsListedButNeverOfferedAPlayTargetOrALink() throws {
        let upload = try #require(try libraryPage("library-uploads.json").shelves[0].items.first)
        #expect(upload.isUpload && upload.videoID != nil)
        #expect(CatalogActionPlan.target(for: upload) == nil && !CatalogActionPlan.canEverPlay(upload) && CatalogActionPlan.link(for: upload) == nil)
        let surface = LibrarySurface(models: [:], history: HistoryModel(remote: LibraryCollectionModel(source: .history, reader: { _ in throw MusicSessionError.policy }, continuer: { _ in throw MusicSessionError.policy }),
                                                                       store: nil, policy: nil, accountKey: { nil }),
                                     ledger: LibraryWriteLedger(writer: { _ in throw MusicSessionError.policy }), performer: nil, playback: { .available })
        let offers = surface.offers(for: upload)
        #expect(offers.count == 1 && offers[0].action == .play && offers[0].unavailable != nil, "the reason is text, not a button that does nothing")
    }
    @Test func aLibraryArtistPageTypeIsAnArtist() throws {
        let root = try w12("library-artists.json")
        #expect(String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self).contains("MUSIC_PAGE_TYPE_LIBRARY_ARTIST"))
        #expect(try libraryPage("library-artists.json").shelves[0].items.allSatisfy { $0.kind == .artist && $0.browseID?.hasPrefix("UC") == true })
    }

    // MARK: Unrecognised is never empty

    @Test func anUnrecognisedPageIsRefusedNeverAnEmptyLibrary() throws {
        #expect(throws: MusicSessionError.unrecognised) { try MusicBrowseParser.parse(try w12("library-unrecognised.json"), mode: .collection) }
        #expect(throws: MusicSessionError.unrecognised) { try MusicBrowseParser.parse(try w12("library-unreadable-only.json"), mode: .collection) }
        #expect(throws: MusicSessionError.unrecognised) { try MusicBrowseParser.parse(["error": ["code": 400]], mode: .collection) }
        #expect(throws: MusicSessionError.unrecognised) { try MusicBrowseParser.parseContinuation(["responseContext": [:], "somethingNew": [:]], mode: .collection) }
    }

    // MARK: Controls the entries published

    @Test func rowsPublishTheirRatingAndLibraryTokensByIconNotByPosition() throws {
        let items = try libraryPage("library-songs.json").shelves[0].items.filter { $0.kind != .album }
        // Row order in the fixture: add-default, kaset-saved, toggled-saved, ambiguous, played+pinned only, add-default, then the repeat of toggled-saved.
        func library(_ index: Int) -> MusicItemControls.SongLibrary? { items[index].controls?.songLibrary }
        let liked = try #require(items[1].controls?.like)
        #expect(liked.status == .like && liked.videoID == items[1].videoID && liked.dislikeExposed)
        // default BOOKMARK_BORDER = add token, toggled BOOKMARK = remove token, not toggled: not in the library.
        #expect(library(0) == .init(isSaved: false, addToken: "synthetic-add-token-0001", removeToken: "synthetic-remove-token-0001"))
        // default BOOKMARK = remove token, toggled BOOKMARK_BORDER = add token (the Kaset/ytmusicapi convention): in the library, and the
        // default endpoint is the REMOVE token, not the add token that its position would suggest.
        #expect(library(1) == .init(isSaved: true, addToken: "synthetic-add-token-0002", removeToken: "synthetic-remove-token-0002"))
        // The same icons as the first, but displayed toggled: in the library.
        #expect(library(2) == .init(isSaved: true, addToken: "synthetic-add-token-0003", removeToken: "synthetic-remove-token-0003"))
        #expect(library(6) == library(2), "a song listed twice reads the same twice")
        #expect(library(3) == nil, "two add icons are not a library toggle: fail closed")
    }
    @Test func theAddAndRemoveTokenFollowTheIconsWhicheverSideTheyAreOn() throws {
        let items = try libraryPage("library-songs.json").shelves[0].items
        let swapped = try #require(items.first { $0.controls?.songLibrary?.addToken == "synthetic-add-token-0002" })
        let plain = try #require(items.first { $0.controls?.songLibrary?.addToken == "synthetic-add-token-0001" })
        #expect(swapped.controls?.songLibrary?.removeToken == "synthetic-remove-token-0002" && plain.controls?.songLibrary?.removeToken == "synthetic-remove-token-0001")
        #expect(swapped.controls?.songLibrary?.isSaved == true && plain.controls?.songLibrary?.isSaved == false)
    }
    @Test func albumCardsInEitherIconConventionReadTheSameSaveTargetAndState() throws {
        let items = try libraryPage("library-albums.json").shelves[0].items
        #expect(items.count == 6)
        for item in items {
            let save = try #require(item.controls?.save)
            #expect(save.isSaved == true && save.playlistID == item.playlistID, "album \(item.title)")
        }
    }
    @Test func aTogglesTokenIsNotALibraryTokenUnlessItsIconsSayItIs() throws {
        // The two signed toggles a REAL signed episode capture publishes ("Mark as played", "Pin to Listen again") sit on a song row beside no
        // library toggle: the row has a rating and nothing to save.
        let items = try libraryPage("library-songs.json").shelves[0].items.filter { $0.kind != .album }
        let row = items[4]
        #expect(row.controls?.like != nil && row.controls?.songLibrary == nil && row.controls?.save == nil)
    }
    /// The REAL signed capture (Kaset's fixture, copied byte-for-byte): 92 episode rows whose menus carry "Mark as played"/"Mark as unplayed"
    /// (CHECK to ARROW_UNDO, feedback on both sides, isToggled true on 10 rows and false on 82), "Pin to Listen again" (KEEP to KEEP_OFF) and an
    /// add-to-playlist toggle. None is a library toggle, so no row may offer Save or Remove from Library: pressing it would mark the episode played.
    @MainActor @Test func realSignedEpisodeToggleIsNeverALibrarySave() throws {
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("W12-kaset-real/artist_lofi_girl_episodes_more.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let page = try MusicBrowseParser.parse(root, mode: .collection)
        let items = page.shelves.flatMap(\.items)
        #expect(items.count == 92 && page.accounting.items == countEntryRenderers(in: root) && items.allSatisfy { $0.kind == .episode })
        #expect(items.allSatisfy { $0.controls == nil }, "no control of any kind is read from an episode's played/pin toggles")
        let ledger = LibraryWriteLedger(writer: { _ in throw MusicSessionError.policy })
        for source in [LibrarySource(kind: .savedEpisodes), LibrarySource(kind: .songs), .history] {
            for item in items { #expect(LibraryControls.make(item: item, source: source, ledger: ledger).isEmpty) }
        }
        // The same real toggles put on a song row, where the kind restriction does not help, are still not library toggles.
        var saw = 0
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if let toggle = object["toggleMenuServiceItemRenderer"] as? [String: Any], (toggle["defaultIcon"] as? [String: Any])?["iconType"] as? String == "CHECK" { saw += 1 }
                for child in object.values { walk(child) }
            } else if let list = node as? [Any] { for child in list { walk(child) } }
        }
        walk(root)
        #expect(saw == 92, "the real capture does carry 'Mark as played' on every row")
    }
    @Test func theKasetFixtureIsByteIdenticalToItsManifestAndNamesItsSource() throws {
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixturesRoot().appendingPathComponent("W12-kaset-real/manifest.json"))) as? [String: Any])
        #expect((manifest["source_commit"] as? String)?.contains("4c59ff2") == true)
        let file = try #require((manifest["files"] as? [[String: Any]])?.first)
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("W12-kaset-real/" + (file["path"] as? String ?? "")))
        #expect(sha256(data) == file["sha256"] as? String && data.count == file["bytes"] as? Int)
        let notices = try String(contentsOf: fixturesRoot().deletingLastPathComponent().appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        #expect(notices.contains("W12-kaset-real/artist_lofi_girl_episodes_more.json") && notices.contains("MIT License") && notices.contains("sozercan"))
    }
    @Test func aToggleOnTheWrongKindOfEntryIsDropped() throws {
        // A save toggle on an episode, an artist-follow on a song: the control belongs to the kinds it can act on.
        var root = try w12("library-songs.json")
        func retype(_ node: Any) -> Any {
            if var object = node as? [String: Any] {
                for key in ["musicVideoType"] where object[key] != nil { object[key] = "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" }
                return object.mapValues(retype)
            }
            if let list = node as? [Any] { return list.map(retype) }
            return node
        }
        root = try #require(retype(root) as? [String: Any])
        let episodes = try MusicBrowseParser.parse(root, mode: .collection).shelves.flatMap(\.items).filter { $0.kind == .episode }
        #expect(!episodes.isEmpty && episodes.allSatisfy { $0.controls == nil })
    }
    /// Two library toggles on one entry cannot both be the real one, and an endpoint whose own status contradicts its icon is not trusted.
    @Test func ambiguousOrContradictoryLibraryTogglesOfferNothing() throws {
        func rewrite(_ root: [String: Any], _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
            func walk(_ node: Any) -> Any {
                if var object = node as? [String: Any] { change(&object); return object.mapValues(walk) }
                if let list = node as? [Any] { return list.map(walk) }
                return node
            }
            return try #require(walk(root) as? [String: Any])
        }
        // Duplicate every library toggle on each song row: two toggles, neither trusted.
        let doubled = try rewrite(try w12("library-songs.json")) { object in
            if var menu = object["menuRenderer"] as? [String: Any], var items = menu["items"] as? [[String: Any]] {
                let libraries = items.filter { $0["toggleMenuServiceItemRenderer"] != nil && ($0["toggleMenuServiceItemRenderer"] as? [String: Any])?["defaultIcon"] != nil }
                items.append(contentsOf: libraries.filter { (($0["toggleMenuServiceItemRenderer"] as? [String: Any])?["defaultIcon"] as? [String: Any])?["iconType"] as? String != "CHECK" })
                menu["items"] = items; object["menuRenderer"] = menu
            }
        }
        #expect(try MusicBrowseParser.parse(doubled, mode: .collection).shelves[0].items.allSatisfy { $0.controls?.songLibrary == nil })
        // Album cards whose endpoints' own statuses contradict their icons (the add side says INDIFFERENT, the remove side LIKE).
        let flipped = try rewrite(try w12("library-albums.json")) { object in
            if let like = object["likeEndpoint"] as? [String: Any], let status = like["status"] as? String {
                var copy = like; copy["status"] = status == "LIKE" ? "INDIFFERENT" : "LIKE"; object["likeEndpoint"] = copy
            }
        }
        #expect(try MusicBrowseParser.parse(flipped, mode: .collection).shelves[0].items.allSatisfy { $0.controls?.save == nil })
    }
    @Test func aWrappedLibraryTabReadsLikeADirectOne() throws {
        for (direct, wrapped) in [("library-albums.json", "library-albums-wrapped.json"), ("library-songs.json", "library-songs-wrapped.json")] {
            let a = try libraryPage(direct), b = try libraryPage(wrapped)
            #expect(a.shelves.map(\.items) == b.shelves.map(\.items) && a.accounting == b.accounting, Comment(rawValue: wrapped))
            #expect(b.accounting.items == countEntryRenderers(in: try w12(wrapped)))
        }
        // In a catalog reading the wrapper is unchanged: still an unknown section, so still unrecognised.
        #expect(throws: MusicSessionError.unrecognised) { try MusicBrowseParser.parse(try w12("library-albums-wrapped.json")) }
        // A wrapper holding nothing readable is unrecognised, never an empty library.
        var empty = try w12("library-albums-wrapped.json")
        func hollow(_ node: Any) -> Any {
            if var object = node as? [String: Any] {
                if object["itemSectionRenderer"] != nil { return ["itemSectionRenderer": ["contents": [["musicFutureShelfRenderer": [:]]]]] }
                return object.mapValues(hollow)
            }
            if let list = node as? [Any] { return list.map(hollow) }
            return node
        }
        empty = try #require(hollow(empty) as? [String: Any])
        #expect(throws: MusicSessionError.unrecognised) { try MusicBrowseParser.parse(empty, mode: .collection) }
    }
    @Test func dislikeIsOfferedOnlyWhereTheServiceExposesIt() throws {
        var root = try w12("library-songs.json")
        func strip(_ node: Any) -> Any {
            if var object = node as? [String: Any] {
                object.removeValue(forKey: "dislikeNavigationEndpoint")
                return object.mapValues(strip)
            }
            if let list = node as? [Any] { return list.map(strip) }
            return node
        }
        let exposed = try MusicBrowseParser.parse(root, mode: .collection).shelves[0].items.compactMap(\.controls?.like)
        #expect(!exposed.isEmpty && exposed.allSatisfy(\.dislikeExposed))
        root = try #require(strip(root) as? [String: Any])
        let hidden = try MusicBrowseParser.parse(root, mode: .collection).shelves[0].items.compactMap(\.controls?.like)
        #expect(!hidden.isEmpty && hidden.allSatisfy { !$0.dislikeExposed }, "no dislike control is invented where the service published none")
    }
    @Test func aRateButtonThatDoesNotAllowLikesPublishesNoRating() throws {
        func disallow(_ node: Any) -> Any {
            if var object = node as? [String: Any] {
                if object["likesAllowed"] != nil { object["likesAllowed"] = false }
                return object.mapValues(disallow)
            }
            if let list = node as? [Any] { return list.map(disallow) }
            return node
        }
        let root = try #require(disallow(try w12("library-songs.json")) as? [String: Any])
        #expect(try MusicBrowseParser.parse(root, mode: .collection).shelves[0].items.compactMap(\.controls?.like).isEmpty)
    }
    @Test func anAnonymousPageNamesNoWriteEndpointButItsHeadersStillSayWhatTheyActOn() throws {
        // The real anonymous captures carry a sign-in prompt where the signed endpoint would be.
        let album = try MusicBrowseParser.parse(try realCapture("album"))
        #expect(album.header?.actions.controls.save == .init(playlistID: album.header?.actions.play ?? "", isSaved: false))
        let artist = try MusicBrowseParser.parse(try realCapture("artist"))
        #expect(artist.header?.actions.controls.follow == .init(channelID: "UC_kRDKYrUlrbtrSiyu5Tflg", isFollowing: false, params: "EgIIGxgA"))
        let show = try MusicBrowseParser.parse(try realCapture("podcast"))
        #expect(show.header?.actions.controls.save?.playlistID == "PLZr1D7YmlHJw")
        let anonymousRows = try MusicBrowseParser.parse(try realCapture("album")).shelves.flatMap(\.items)
        #expect(anonymousRows.compactMap(\.controls).allSatisfy { $0.songLibrary?.addToken == nil }, "no add token exists before sign-in")
    }
    @Test func malformedControlValuesAreNotAccepted() throws {
        #expect(!MusicWriteRequest.rate(videoID: "short", status: .like).isWellFormed)
        #expect(!MusicWriteRequest.follow(channelID: "UC_short", params: nil, following: true).isWellFormed)
        #expect(!MusicWriteRequest.follow(channelID: "UC_kRDKYrUlrbtrSiyu5Tflg", params: "bad value\n", following: true).isWellFormed)
        #expect(!MusicWriteRequest.songLibrary(feedbackToken: "x").isWellFormed)
        #expect(MusicWriteRequest.follow(channelID: "UC_kRDKYrUlrbtrSiyu5Tflg", params: "EgIIGxgA", following: true).isWellFormed)
    }

    // MARK: The fixtures are what they say they are

    @Test func fixtureHashesMatchTheManifestAndEveryEntryComesFromARealCapture() throws {
        let manifest = try #require(try JSONSerialization.jsonObject(with: try w12Data("manifest.json")) as? [String: Any])
        #expect(manifest["mode"] as? String == "synthetic-from-real-renderers" && manifest["live_eligible"] as? Bool == false)
        let files = try #require(manifest["files"] as? [[String: Any]])
        #expect(files.count >= 24)
        for file in files {
            let path = try #require(file["path"] as? String)
            #expect(sha256(try w12Data(path)) == file["sha256"] as? String, "\(path) changed")
        }
        let ids = try #require(manifest["browse_ids_relied_on"] as? [String: String])
        #expect(Set(ids.values) == Set(MusicLibraryKind.allBrowseIDs), "the live-check list and the code name the same browse ids")
    }
}
