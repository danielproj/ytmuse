import AccountSession
import Features
import Foundation
import Testing

/// SHARE: which public link Copy Link and Share hand out, for every kind of entry and for a page reopened by its route; what is refused; and that
/// pressing Share… opens the sheet for exactly that link while opening a menu, listing offers or loading a page opens nothing.
/// Ids are hand-built where a case needs a malformed one and taken from the real anonymous captures where the shape matters (labelled in each test).
@MainActor @Suite struct CatalogShareTests {
    private let video = "dQw4w9WgXcQ"
    private let channel = "UCptBkLZ6XRxoyn8SkUMc_Iw"
    private let albumBrowse = "MPREb_K8qWMWVqXGi"
    private let albumList = "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c"
    private let playlistList = "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"

    private func link(_ kind: MusicEntityKind, video: String? = nil, browse: String? = nil, list: String? = nil, context: String? = nil, privateMedia: Bool = false) -> String? {
        CatalogActionPlan.link(for: MusicCatalogItem(kind: kind, title: "t", videoID: video, browseID: browse, playlistID: list, contextPlaylistID: context, isPrivatelyOwned: privateMedia))?.absoluteString
    }

    // MARK: Targets by kind

    @Test func everyKindSharesItsOwnIdentityAndNothingElse() {
        #expect(link(.song, video: video) == "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(link(.video, video: video) == "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(link(.episode, video: video) == "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(link(.album, browse: albumBrowse, list: albumList) == "https://music.youtube.com/playlist?list=" + albumList)
        #expect(link(.artist, browse: channel) == "https://music.youtube.com/channel/" + channel)
        #expect(link(.playlist, browse: "VL" + playlistList, list: playlistList) == "https://music.youtube.com/playlist?list=" + playlistList)
        #expect(link(.podcast, browse: "MPSPPLZr1D7YmlHJw", list: "PLZr1D7YmlHJw") == "https://music.youtube.com/browse/MPSPPLZr1D7YmlHJw")
        #expect(link(.category, browse: "FEmusic_moods_and_genres_category") == nil, "a navigation tile is not an entity")
    }
    @Test func aSongNeverCarriesTheRadioAlbumOrQueueItWasStartedFrom() {
        // A real row's context is an album list, a playlist, or its own radio; none of them may ride along on the song's link.
        for context in [albumList, playlistList, "RDAMVM" + video, "RDEM123456789012", "LM"] {
            let url = link(.song, video: video, list: context, context: context)
            #expect(url == "https://music.youtube.com/watch?v=" + video, "\(context)")
        }
    }
    @Test func anAlbumIsIdentifiedAsTheAlbumNeverAsARadioOrMix() {
        #expect(link(.album, browse: albumBrowse, list: "RDAMPL" + albumList) == "https://music.youtube.com/browse/" + albumBrowse, "its mix is not the album; the page identity is")
        #expect(link(.album, browse: nil, list: "RDAMPL" + albumList) == nil, "a radio alone names no album")
        #expect(link(.album, browse: nil, list: playlistList) == nil, "a user playlist is not an album")
        #expect(link(.album, browse: albumBrowse) == "https://music.youtube.com/browse/" + albumBrowse)
        #expect(link(.album) == nil)
    }
    @Test func aPlaylistsPageIdNormalisesAndSpecialListsAreNeverHandedOut() {
        #expect(link(.playlist, browse: "VL" + playlistList) == "https://music.youtube.com/playlist?list=" + playlistList)
        #expect(link(.playlist, list: playlistList) == "https://music.youtube.com/playlist?list=" + playlistList)
        #expect(link(.playlist, browse: "VLLM", list: "LM") == nil, "Liked Music is the person's own list")
        #expect(link(.playlist, browse: "VLSE") == nil && link(.playlist, list: "WL") == nil)
        #expect(link(.playlist, list: "PL") == nil && link(.playlist, list: "PL../../x1234567") == nil)
        #expect(link(.playlist) == nil)
    }
    @Test func anArtistNeedsAChannelIdAndNothingElseStandsInForIt() {
        #expect(link(.artist, browse: "MPADUCRr1xG_2WIDs18a6cIiCxeA") == nil, "an album-list browse id is not the artist")
        #expect(link(.artist, browse: "UCshort") == nil && link(.artist, browse: "FEmusic_home") == nil && link(.artist) == nil)
        #expect(link(.artist, browse: channel + "x") == nil)
    }
    @Test func aFollowedArtistFromTheLibraryIsSharedFromItsChannelId() {
        // The library publishes a followed artist as MPLA + channel id; the link is the channel's own page, never the MPLA form.
        let expected = "https://music.youtube.com/channel/" + channel
        #expect(link(.artist, browse: "MPLA" + channel) == expected)
        #expect(CatalogShareLink.url(for: CatalogTarget(browseID: "MPLA" + channel))?.absoluteString == expected)
        #expect(CatalogActionPlan.offers(for: MusicCatalogItem(kind: .artist, title: "A", browseID: "MPLA" + channel), playback: .available).map(\.action).contains(.share))
        for bad in ["MPLA", "MPLAUCshort", "MPLA" + channel + "x", "MPLAMPLA" + channel, "MPLAMPREb_K8qWMWVqXGi", "MPLAPL" + playlistList, "MPLAFEmusic_home"] {
            #expect(link(.artist, browse: bad) == nil, "\(bad)")
            #expect(CatalogShareLink.url(for: CatalogTarget(browseID: bad)) == nil, "\(bad)")
        }
    }

    // MARK: Refusals

    @Test func privateMediaAndMalformedIdentifiersHaveNoLinkAndNoShareOffer() {
        #expect(link(.song, video: video, privateMedia: true) == nil, "an upload has no public link")
        for bad in ["", "short", "../../etc/passwd", video + "&si=abc", "dQw4w9WgXc", "dQw4w9WgXcQQ", "dQw4w9WgX/Q", "dQw4w9WgX Q", "dQw4w9WgXé"] {
            #expect(link(.song, video: bad) == nil, "\(bad)")
        }
        let upload = MusicCatalogItem(kind: .song, title: "Mine", videoID: video, isPrivatelyOwned: true)
        let none = CatalogActionPlan.offers(for: upload, playback: .available).map(\.action)
        #expect(!none.contains(.share) && !none.contains(.copyLink))
        let bad = MusicCatalogItem(kind: .album, title: "Bad", browseID: "MPREb_../x")
        #expect(CatalogActionPlan.offers(for: bad, playback: .available).map(\.action).contains(.share) == false)
    }
    @Test func everyLinkIsHttpsMusicWithAtMostTheEntitysOwnIdentifierAsQuery() {
        let all = [link(.song, video: video, list: albumList, context: albumList), link(.album, browse: albumBrowse, list: albumList), link(.artist, browse: channel),
                   link(.playlist, browse: "VL" + playlistList), link(.podcast, browse: "MPSPPLZr1D7YmlHJw"), link(.episode, video: video)]
        for text in all.compactMap({ $0 }) {
            let components = URLComponents(string: text)!
            #expect(components.scheme == "https" && components.host == "music.youtube.com" && components.port == nil && components.user == nil && components.password == nil && components.fragment == nil)
            let names = (components.queryItems ?? []).map(\.name)
            #expect(names.count <= 1 && Set(names).isSubset(of: ["v", "list"]), "\(text)")
            for banned in ["si=", "feature", "index", "jct", "continuation", "token", "cookie", "SAPISID", "file:", "/Users/"] { #expect(!text.contains(banned), "\(banned) in \(text)") }
        }
        #expect(all.compactMap { $0 }.count == 6)
    }

    // MARK: A page reopened by its route

    @Test func aPageReopenedByRouteIsSharedFromItsBrowseId() {
        #expect(CatalogShareLink.url(for: CatalogTarget(browseID: albumBrowse))?.absoluteString == "https://music.youtube.com/browse/" + albumBrowse)
        #expect(CatalogShareLink.url(for: CatalogTarget(browseID: channel))?.absoluteString == "https://music.youtube.com/channel/" + channel)
        #expect(CatalogShareLink.url(for: CatalogTarget(browseID: "VL" + playlistList))?.absoluteString == "https://music.youtube.com/playlist?list=" + playlistList)
        #expect(CatalogShareLink.url(for: CatalogTarget(browseID: "MPSPPLZr1D7YmlHJw"))?.absoluteString == "https://music.youtube.com/browse/MPSPPLZr1D7YmlHJw")
        // A route made from a bare playlist id (a pasted link) gets its VL page id and shares the same link.
        let route = CatalogTarget(kind: .playlist, identifier: playlistList)
        #expect(route.flatMap { CatalogShareLink.url(for: $0) }?.absoluteString == "https://music.youtube.com/playlist?list=" + playlistList)
        // Parameters the page was opened with are not part of what is shared.
        #expect(CatalogShareLink.url(for: CatalogTarget(browseID: albumBrowse, params: "ggMCCAI%3D")) == CatalogShareLink.url(for: CatalogTarget(browseID: albumBrowse)))
    }
    @Test func servicePagesThatAreNotEntitiesHaveNothingToShare() {
        for target in [CatalogTarget.home, .explore, .charts, .newReleases, .moodsAndGenres, CatalogTarget(browseID: "FEmusic_moods_and_genres_category", params: "x"),
                       CatalogTarget(browseID: "VLLM"), CatalogTarget(browseID: "MPADUCRr1xG_2WIDs18a6cIiCxeA"), CatalogTarget(browseID: "UCshort")] {
            #expect(CatalogShareLink.url(for: target) == nil, "\(target.browseID)")
        }
    }
    @Test func theAlbumPageOfARealCaptureOffersShareFromItsRouteAfterLoadAndNotBefore() async throws {
        let script = ServiceScript(), performer = StubPerformer()
        let target = CatalogTarget(browseID: albumBrowse)
        await script.setPages(target, [try realPage(.album)])
        let model = makeModel(target, script: script, performer: performer)
        #expect(model.pageLink == nil, "nothing loaded yet: nothing to share")
        await model.load()
        #expect(model.pageLink?.absoluteString == "https://music.youtube.com/browse/" + albumBrowse)
        #expect(performer.shared.isEmpty && performer.copied.isEmpty, "loading a page shares and copies nothing")
        model.sharePage()
        #expect(performer.shared.map(\.absoluteString) == ["https://music.youtube.com/browse/" + albumBrowse] && model.feedback[CatalogPageModel.pageShareKey] == nil)
        model.copyPageLink()
        #expect(performer.copied == performer.shared && model.feedback[CatalogPageModel.pageCopyKey] == .copied)
    }
    @Test func aPageWhoseRouteIsNotAnEntityShowsNoShareAndTheCallDoesNothing() async throws {
        let script = ServiceScript(), performer = StubPerformer()
        await script.setPages(.home, [try realPage(.home)])
        let model = makeModel(.home, script: script, performer: performer)
        await model.load()
        #expect(model.pageLink == nil)
        model.sharePage(); model.copyPageLink()
        #expect(performer.shared.isEmpty && performer.copied.isEmpty)
        guard case .failed? = model.feedback[CatalogPageModel.pageShareKey] else { Issue.record("a refusal is said, not silent"); return }
    }

    // MARK: Pressing Share…

    @Test func shareOpensTheSheetForTheSelectedItemNotForAnythingElseOnThePage() async throws {
        let script = ServiceScript(), performer = StubPerformer()
        await script.setPages(.home, [try realPage(.home)])
        let model = makeModel(.home, script: script, performer: performer)
        await model.load()
        let song = model.shelves[0].items[0], album = model.shelves[1].items[0]
        // Listing the offers (what a menu does when it opens) shares nothing.
        _ = model.offers(for: song); _ = model.offers(for: album)
        #expect(performer.shared.isEmpty && performer.copied.isEmpty)
        await model.perform(.share, on: song)
        #expect(performer.shared.map(\.absoluteString) == ["https://music.youtube.com/watch?v=Z85lxckrtzg"], "the song's id, not its radio")
        await model.perform(.share, on: album)
        #expect(performer.shared.last == CatalogActionPlan.link(for: album) && performer.shared.count == 2)
        #expect(performer.copied.isEmpty && performer.played.isEmpty, "Share does not copy and does not play")
        #expect(model.feedback[song.id] == nil && model.feedback[album.id] == nil, "the sheet is the feedback")
    }
    @Test func shareNeedsNoAccountAndIsRefusedWhereTheItemHasNoLink() async throws {
        let script = ServiceScript(), performer = StubPerformer()
        await script.setPages(.home, [try realPage(.home)])
        let model = makeModel(.home, script: script, performer: performer, playback: .needsSignIn)
        await model.load()
        let song = model.shelves[0].items[0]
        #expect(model.offers(for: song).first { $0.action == .share }?.isAvailable == true)
        await model.perform(.share, on: song)
        #expect(performer.shared.count == 1)
        let upload = MusicCatalogItem(kind: .song, title: "Mine", videoID: video, isPrivatelyOwned: true)
        await model.perform(.share, on: upload)
        guard case .failed? = model.feedback[upload.id] else { Issue.record("a stale or private item is refused at the item"); return }
        #expect(performer.shared.count == 1)
    }
    @Test func aPerformerWithNowhereToPresentSaysSoAndNeverFallsBackToTheClipboard() async throws {
        let script = ServiceScript(), performer = StubPerformer()
        performer.canShare = false
        await script.setPages(.home, [try realPage(.home)])
        let model = makeModel(.home, script: script, performer: performer)
        await model.load()
        let song = model.shelves[0].items[0]
        await model.perform(.share, on: song)
        #expect(model.feedback[song.id] == .failed(String(localized: "Sharing isn’t available right now.")))
        #expect(performer.shared.isEmpty && performer.copied.isEmpty)
    }
    @Test func sharingAndCopyingLeaveEveryRealCaptureEntryWithTheSameLink() throws {
        var checked = 0
        for capture in Capture.allCases {
            for entry in try realPage(capture).shelves.flatMap(\.items) {
                let offered = Set(CatalogActionPlan.offers(for: entry, playback: .available).map(\.action))
                #expect(offered.contains(.share) == offered.contains(.copyLink) && offered.contains(.share) == (CatalogActionPlan.link(for: entry) != nil), "\(capture) \(entry.title)")
                if let url = CatalogActionPlan.link(for: entry) {
                    checked += 1
                    #expect(url.scheme == "https" && url.host == "music.youtube.com" && (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).count <= 1)
                }
            }
        }
        #expect(checked > 100, "the sweep must not be vacuous")
    }
}
