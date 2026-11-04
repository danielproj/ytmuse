import AccountSession
import Testing
@testable import Features

@Suite struct DirectPlaylistAdditionTests {
    private let video = "dQw4w9WgXcQ"

    @Test func catalogUsesVideoRatherThanCollectionIdentity() throws {
        for kind in [MusicEntityKind.song, .video] {
            let item = MusicCatalogItem(kind: kind, title: "Actual track", videoID: video, browseID: "VLcollection")
            let addition = try #require(DirectPlaylistAddition.candidate(item))
            #expect(addition == PlaylistAddition(videoID: video, title: "Actual track"))
        }
        for kind in [MusicEntityKind.artist, .album, .playlist, .category, .podcast, .episode] {
            #expect(DirectPlaylistAddition.candidate(MusicCatalogItem(kind: kind, title: "Not a song", videoID: video)) == nil)
        }
        #expect(DirectPlaylistAddition.candidate(MusicCatalogItem(kind: .song, title: "Unavailable", availability: .unavailable, videoID: video)) == nil)
        for id in [nil, "VLcollection", ""] as [String?] {
            #expect(DirectPlaylistAddition.candidate(MusicCatalogItem(kind: .song, title: "No video", videoID: id, browseID: "VLcollection")) == nil)
        }
    }

    @Test func searchUsesExactSongAndVideoTargets() throws {
        for kind in [MusicSearchKind.song, .video, .artist, .album, .playlist, .podcast, .episode] {
            let result = SearchResult(kind: kind, title: "Search title", details: [], badges: [.service],
                                      target: SearchTarget(videoID: video, browseID: "collection", playlistID: "playlist"), fromService: true)
            let addition = DirectPlaylistAddition.candidate(result)
            if kind == .song || kind == .video {
                #expect(try #require(addition) == PlaylistAddition(videoID: video, title: "Search title"))
            } else { #expect(addition == nil) }
        }
        for id in [nil, "collection", ""] as [String?] {
            let result = SearchResult(kind: .song, title: "No video", details: [], badges: [], target: SearchTarget(videoID: id, browseID: "collection"), fromService: false)
            #expect(DirectPlaylistAddition.candidate(result) == nil)
        }
    }

    @Test func missingSurfaceAndNonliveSessionsNeverOfferAnAddition() {
        let addition = PlaylistAddition(videoID: video, title: "Song")
        #expect(DirectPlaylistAddition.offered(addition, playback: .available) == addition)
        #expect(DirectPlaylistAddition.offered(nil, playback: .available) == nil)
        for playback in [nil, .needsSignIn, .sessionExpired] as [SearchPlayback?] {
            #expect(DirectPlaylistAddition.offered(addition, playback: playback) == nil)
        }
    }

    @MainActor @Test func delayedActionsAndPresentationsMustBelongToTheCurrentAccount() {
        let service = FakePlaylistRemote(rows: [])
        var playback: SearchPlayback = .available
        func makeSurface() -> PlaylistSurface {
            PlaylistSurface(creator: PlaylistCreator(service: service), joiner: PlaylistJoiner(service: service),
                            makeSession: { PlaylistEditSession(playlistID: $0, service: service) },
                            performer: nil, playback: { playback })
        }
        let surface = makeSurface()
        let song = PlaylistAddition(videoID: video, title: "A song")
        let oldAction = DirectPlaylistScope(surface)
        #expect(oldAction.admits(song, current: song, surface: surface))
        surface.accountChanged() // A → B, both signed in; old callback arrives after clearing.
        #expect(!oldAction.admits(song, current: song, surface: surface))
        let currentAction = DirectPlaylistScope(surface)
        #expect(currentAction.admits(song, current: song, surface: surface))
        #expect(!currentAction.admits(song, current: song, surface: makeSurface()))
        #expect(!currentAction.admits(song, current: nil, surface: surface))
        for state in [SearchPlayback.needsSignIn, .sessionExpired] {
            playback = state
            #expect(!currentAction.admits(song, current: song, surface: surface))
        }
        playback = .available
        surface.accountChanged() // A pending selection must also fail at presentation.
        #expect(!currentAction.admits(song, current: song, surface: surface))
    }
}
