import AppKit
import Foundation
import Testing
import AccountSession
@testable import Features
@testable import Playback
@testable import AppShell
import TestSupport

/// Like and Dislike for the song that is playing, on every player surface (bottom bar, expanded player, full screen, mini-player), and the
/// rating read that gives a song from a mix or the queue its controls. Dislike on the playing song skips to the next one, as YouTube Music
/// does, but only once the ledger holds the dislike.
@Suite @MainActor struct LifecycleRatingTests {
    private func rig() async throws -> (LifecycleRig, ShellCoordinator, FakeMusicPage) {
        let rig = try await LifecycleRig.make()
        let shell = ShellCoordinator(playback: rig.model, loginItem: InMemoryLoginItemService(), application: FakeApplication(),
                                     preferences: InMemoryDefaults(), installsStatusItem: false)
        let (_, page) = try await rig.play()
        return (rig, shell, page)
    }
    private func control(_ kind: LibraryControl.Kind, on: Bool = false, video: String = lifecycleVideo) -> LibraryControl {
        let like = MusicItemControls.Like(videoID: video, status: on ? (kind == .like ? .like : .dislike) : .indifferent, dislikeExposed: true)
        let wanted: MusicLikeStatus = on ? .indifferent : (kind == .like ? .like : .dislike)
        return LibraryControl(kind: kind, key: .rating(videoID: video), isOn: on, intent: .rate(like, to: wanted), title: kind.rawValue, symbol: "heart")
    }
    private func skips(_ page: FakeMusicPage) -> Int { page.commands.filter { $0.body == WebMusicScripts.skip && $0.arguments["forward"] as? Bool == true }.count }

    @Test func dislikeComesFromTheSongsPublishedControlsAndLikeFromTheLikeProvider() async throws {
        let (_, shell, _) = try await rig()
        shell.likeControlProvider = { _ in self.control(.like) }
        shell.libraryControlsProvider = { _ in [self.control(.like), self.control(.dislike)] }
        #expect(shell.ratingAvailability(.like).control?.kind == .like)
        #expect(shell.ratingAvailability(.dislike).control?.kind == .dislike)
        #expect(shell.likeAvailability() == shell.ratingAvailability(.like))
    }
    @Test func aSongThatOffersLikeButNotDislikeSaysSo() async throws {
        let (_, shell, _) = try await rig()
        shell.likeControlProvider = { _ in self.control(.like) }
        shell.libraryControlsProvider = { _ in [self.control(.like)] }
        #expect(shell.ratingAvailability(.dislike) == .unavailable(.dislikeNotOffered))
        #expect(shell.ratingAvailability(.dislike).reason == RemoteCommandReason.noDislike)
    }
    @Test func whileTheRatingIsMissingTheButtonsSayWhy() async throws {
        let (_, shell, page) = try await rig()
        shell.likeControlProvider = { _ in nil }
        shell.libraryControlsProvider = { _ in [] }
        for gap in [ShellCoordinator.LikeUnavailable.reading, .notOffered, .signedOut] {
            shell.ratingGapProvider = { _ in gap }
            #expect(shell.ratingAvailability(.like) == .unavailable(gap) && shell.ratingAvailability(.dislike) == .unavailable(gap))
            #expect(shell.remoteLibraryControl(.dislike) == .unavailable(gap.message), "the system's Dislike button gives the same reason")
        }
        shell.ratingGapProvider = { _ in nil }
        #expect(shell.ratingAvailability(.like) == .unavailable(.pageNotRead))
        // An advertisement wins over any gap: nothing to rate while it plays.
        shell.ratingGapProvider = { _ in .reading }
        page.send(lifecycleState(position: 0, duration: 15, video: lifecycleAdVideo, ad: true))
        #expect(shell.ratingAvailability(.dislike) == .unavailable(.advertisement))
        let messages = [ShellCoordinator.LikeUnavailable.nothingPlaying, .advertisement, .ownedMedia, .pageNotRead, .reading, .notOffered, .signedOut, .dislikeNotOffered].map(\.message)
        #expect(Set(messages).count == messages.count && messages.allSatisfy { !$0.isEmpty }, "every cause has its own sentence: \(messages)")
    }
    @Test func dislikingThePlayingSongSkipsOnlyOnceTheLedgerHoldsTheDislike() async throws {
        let (_, shell, page) = try await rig()
        let dislike = control(.dislike)
        var pressed: [LibraryControl] = []
        shell.likePress = { pressed.append($0) }
        var held = false
        shell.ratingHeld = { _ in held }
        let before = skips(page)
        await shell.pressLike(dislike)
        #expect(pressed == [dislike] && skips(page) == before, "the ledger rejected the dislike: the song keeps playing")
        held = true
        await shell.pressLike(dislike)
        #expect(pressed.count == 2 && skips(page) == before + 1, "the dislike took: on to the next song")
    }
    @Test func onlySettingDislikeOnThePlayingSongSkips() async throws {
        let (_, shell, page) = try await rig()
        shell.likePress = { _ in }
        shell.ratingHeld = { _ in true }
        let before = skips(page)
        await shell.pressLike(control(.like))
        await shell.pressLike(control(.like, on: true))
        await shell.pressLike(control(.dislike, on: true))                              // removing a dislike
        await shell.pressLike(control(.dislike, video: lifecycleOtherVideo))            // disliking a song that is not playing
        #expect(skips(page) == before)
        #expect(ShellCoordinator.dislikeSkips(control(.dislike), playing: lifecycleVideo))
        #expect(!ShellCoordinator.dislikeSkips(control(.dislike), playing: nil) && !ShellCoordinator.dislikeSkips(control(.dislike), playing: lifecycleOtherVideo))
    }
    @Test func noSkipWhenTheSongChangedWhileTheDislikeWasInFlight() async throws {
        let (_, shell, page) = try await rig()
        shell.ratingHeld = { _ in true }
        shell.likePress = { _ in page.send(lifecycleState(position: 0, video: lifecycleOtherVideo, title: "Next")) }
        let before = skips(page)
        await shell.pressLike(control(.dislike))
        #expect(skips(page) == before, "the queue already moved on: skipping again would lose a song")
    }
    @Test func theRemoteDislikeTakesTheSamePathAndSkipsToo() async throws {
        let (_, shell, page) = try await rig()
        shell.libraryControlsProvider = { _ in [self.control(.like), self.control(.dislike)] }
        shell.likePress = { _ in }
        shell.ratingHeld = { _ in true }
        let before = skips(page)
        guard case .available(let dislike) = shell.remoteLibraryControl(.dislike) else { Issue.record("no remote dislike"); return }
        await shell.remoteLibraryPress(dislike)
        #expect(skips(page) == before + 1)
    }
    @Test func everyPlayerSurfaceShowsLikeAndDislikeThroughTheOneButton() throws {
        let capsule = try LifecycleSources.source("Sources/AppShell/PlayerCapsuleViews.swift")
        #expect(capsule.contains("PlayingRatingButton(shell: ratingShell, kind: .like") && capsule.contains("PlayingRatingButton(shell: ratingShell, kind: .dislike"))
        #expect(capsule.contains("shell.ratingAvailability(kind)") && capsule.contains(".accessibilityHint(Text(reason))") && capsule.contains(".help(Text(control?.title ?? reason))"))
        #expect(capsule.contains("await shell.pressLike(control)"), "a press goes through the shell, so it reaches the one ledger and the system buttons follow")
        let mini = try LifecycleSources.source("Sources/AppShell/Lifecycle/MiniPlayer.swift")
        #expect(mini.contains("PlayingRatingButton(shell: shell, kind: .like, identifier: \"miniLike\")") && mini.contains("PlayingRatingButton(shell: shell, kind: .dislike, identifier: \"miniDislike\")"))
        // The bar (browser window) and the expanded / full-screen player (shell surfaces) both receive the shell.
        #expect(try LifecycleSources.source("Sources/AppShell/BrowserShell.swift").contains(".environment(\\.playingRatingShell, accounts.shell)"))
        #expect(try LifecycleSources.source("Sources/AppShell/Lifecycle/ShellPlayerSurfaces.swift").contains(".environment(\\.playingRatingShell, shell)"))
    }
}

/// The playing song's rating as the hidden page's player bar shows it (`NowPlayingRatings`): taken once per song start, never during an
/// advertisement or signed out, never kept across accounts, and reported as not offered only after the song has played a while without one.
@Suite @MainActor struct NowPlayingRatingsTests {
    @MainActor final class Box { var scope = "account-a"; var signedIn = SearchPlayback.available; var clock = Date(timeIntervalSince1970: 1_000) }
    private func ratings(_ box: Box) -> NowPlayingRatings {
        NowPlayingRatings(accountScope: { box.scope }, signedIn: { box.signedIn }, now: { box.clock })
    }
    private let song = "Zgbfx0KLwUk", other = "khnokW3Mw24"

    @Test func theRatingThePageShowsIsTakenOncePerSongStart() {
        let box = Box(); let ratings = ratings(box)
        ratings.observe(videoID: song, isAd: false, rating: .like)
        #expect(ratings.like(for: song) == .init(videoID: song, status: .like, dislikeExposed: true) && ratings.gap(for: song) == nil)
        // The page keeps showing the state from before a press made through the ledger: a later report of the same song changes nothing.
        ratings.observe(videoID: song, isAd: false, rating: .indifferent)
        #expect(ratings.like(for: song)?.status == .like)
        // The song starts again: its rating is taken again, so it is current.
        ratings.observe(videoID: other, isAd: false, rating: .dislike)
        ratings.observe(videoID: song, isAd: false, rating: .dislike)
        #expect(ratings.like(for: song)?.status == .dislike && ratings.like(for: other)?.status == .dislike)
    }
    @Test func aSongWithoutARatingOnThePageIsReadingThenNotOffered() {
        let box = Box(); let ratings = ratings(box)
        ratings.observe(videoID: song, isAd: false, rating: nil)
        #expect(ratings.gap(for: song) == .reading)
        box.clock += NowPlayingRatings.patience - 1
        ratings.observe(videoID: song, isAd: false, rating: nil)
        #expect(ratings.gap(for: song) == .reading)
        box.clock += 1
        ratings.observe(videoID: song, isAd: false, rating: nil)
        #expect(ratings.gap(for: song) == .notOffered)
        // A rating that appears late is still taken.
        ratings.observe(videoID: song, isAd: false, rating: .like)
        #expect(ratings.like(for: song)?.status == .like && ratings.gap(for: song) == nil)
    }
    @Test func nothingIsTakenDuringAnAdvertisementForAMalformedIdOrSignedOut() {
        let box = Box(); let ratings = ratings(box)
        ratings.observe(videoID: song, isAd: true, rating: .like)
        ratings.observe(videoID: "not-an-id", isAd: false, rating: .like)
        ratings.observe(videoID: nil, isAd: false, rating: .like)
        #expect(ratings.like(for: song) == nil && ratings.current == nil)
        box.signedIn = .needsSignIn
        ratings.observe(videoID: song, isAd: false, rating: .like)
        #expect(ratings.like(for: song) == nil && ratings.gap(for: song) == .signedOut)
        // Signing in changes the account scope, and the same song's rating is then taken.
        box.signedIn = .available; box.scope = "account-a|connected"
        ratings.observe(videoID: song, isAd: false, rating: .like)
        #expect(ratings.like(for: song)?.status == .like)
    }
    @Test func anAccountChangeForgetsEveryRating() {
        let box = Box(); let ratings = ratings(box)
        ratings.observe(videoID: song, isAd: false, rating: .like)
        box.scope = "account-b"
        ratings.observe(videoID: nil, isAd: false, rating: nil)
        #expect(ratings.like(for: song) == nil && ratings.current == nil)
    }
    @Test func aPressThatTookUpdatesTheKeptRating() {
        let box = Box(); let ratings = ratings(box)
        ratings.observe(videoID: song, isAd: false, rating: .indifferent)
        ratings.settle(song, to: .dislike)
        #expect(ratings.like(for: song) == .init(videoID: song, status: .dislike, dislikeExposed: true))
        ratings.settle(other, to: .like)
        #expect(ratings.like(for: other) == nil, "settling never invents a rating that was not shown")
    }
}
