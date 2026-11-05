import AccountSession
import Features
import Foundation
import SystemIntegration
import Testing

/// SHARE: `Features` may not depend on `SystemIntegration`, so `CatalogShareLink` carries its own copy of the identifier shapes. This is the one place
/// both are linked, and it fails if the copy and the app's link policy ever disagree about what a shareable link is.
@Suite struct ShareLinkAgreementTests {
    private let samples: [(MusicEntityKind, String?, String?, String?)] = [
        (.song, "dQw4w9WgXcQ", nil, nil), (.video, "dQw4w9WgXcQ", nil, "RDAMVMdQw4w9WgXcQ"), (.episode, "dQw4w9WgXcQ", "MPED28NpW9S-5Fc", nil),
        (.album, nil, "MPREb_K8qWMWVqXGi", "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c"), (.album, nil, "MPREb_K8qWMWVqXGi", nil),
        (.artist, nil, "UCptBkLZ6XRxoyn8SkUMc_Iw", nil), (.playlist, nil, "VLPLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"),
        (.playlist, nil, nil, "RDCLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3"), (.podcast, nil, "MPSPPLZr1D7YmlHJw", "PLZr1D7YmlHJw")]

    @Test func everyLinkTheCatalogHandsOutIsOneTheAppsOwnPolicyAcceptsAndWouldRebuildIdentically() throws {
        for (kind, video, browse, list) in samples {
            let url = try #require(CatalogShareLink.url(kind: kind, videoID: video, browseID: browse, playlistID: list), "\(kind)")
            guard case .success(.item(let item)) = LinkPolicy.parse(url) else { Issue.record("\(kind) \(url) is refused by LinkPolicy"); continue }
            #expect(CanonicalLink.url(for: item) == url, "\(kind): the canonical form of what the policy reads back is the link that was handed out")
        }
    }
    @Test func aFollowedArtistsLibraryBrowseIdIsSharedAsTheChannelTheLinkPolicyAccepts() throws {
        let channel = "UCptBkLZ6XRxoyn8SkUMc_Iw"
        let url = try #require(CatalogShareLink.url(kind: .artist, videoID: nil, browseID: "MPLA" + channel, playlistID: nil))
        #expect(url == CatalogShareLink.url(kind: .artist, videoID: nil, browseID: channel, playlistID: nil))
        guard case .success(.item(let item)) = LinkPolicy.parse(url) else { Issue.record("\(url) is refused by LinkPolicy"); return }
        #expect(CanonicalLink.url(for: item) == url)
        for bad in ["MPLA", "MPLAUCshort", "MPLA" + channel + "x", "MPLAMPLA" + channel, "MPLAMPREb_K8qWMWVqXGi"] {
            #expect(CatalogShareLink.url(kind: .artist, videoID: nil, browseID: bad, playlistID: nil) == nil, "\(bad)")
        }
    }
    @Test func theSharedShapesAcceptAndRefuseTheSameIdentifiersAsTheLinkPolicy() {
        let ids = ["dQw4w9WgXcQ", "dQw4w9WgXc", "dQw4w9WgXcQQ", "dQw4w9WgX/Q", "dQw4w9WgXé", "MPREb_K8qWMWVqXGi", "MPREb_", "MPREb_../x", "UCptBkLZ6XRxoyn8SkUMc_Iw", "UCptBkLZ6XRxoyn8SkUMc_I",
                   "MPADUCRr1xG_2WIDs18a6cIiCxeA", "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN", "PL", "LM", "WL", "RDAMVMdQw4w9WgXcQ", "OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c", "MPSPPLZr1D7YmlHJw", "MPSP"]
        for id in ids {
            let kinds: [(MusicEntityKind, LinkItemKind, String?, String?, String?)] = [
                (.song, .song, id, nil, nil), (.artist, .artist, nil, id, nil), (.playlist, .playlist, nil, nil, id), (.podcast, .podcast, nil, id, nil)]
            for (entity, linkKind, video, browse, list) in kinds {
                let ours = CatalogShareLink.url(kind: entity, videoID: video, browseID: browse, playlistID: list) != nil
                let theirs = LinkItem(kind: linkKind, identifier: id) != nil
                #expect(ours == theirs, "\(entity) \(id): catalog \(ours), policy \(theirs)")
            }
            let album = CatalogShareLink.url(kind: .album, videoID: nil, browseID: id, playlistID: nil) != nil
            #expect(album == (LinkItem(kind: .album, identifier: id) != nil), "album \(id)")
        }
    }
}
