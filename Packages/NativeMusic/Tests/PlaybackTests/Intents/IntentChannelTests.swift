import AccountSession
import AppIntents
import MediaIntents
import Foundation
import Testing
@testable import Features
@testable import OutputRoutes
@testable import Playback
@testable import SystemIntegration
@testable import AppShell

/// T24.1 (MAC03, ARCH03): every transport, play, search, like/save, queue, player and sleep-timer command an intent can send reaches the SAME use case
/// the window's control reaches, behind the same gates (capabilities, advertisement rules, the account and generation fence, Play here, the W12 ledger).
/// The playback owner is the W23 rig: a real `PlaybackModel` over a fake hidden page.
@Suite @MainActor struct IntentTransportTests {
    private func playing(_ state: [String: Any] = lifecycleState()) async throws -> (IntentRig, FakeMusicPage) {
        let rig = try await IntentRig.make()
        let (_, page) = try await rig.rig.play(state: state)
        return (rig, page)
    }
    private func settle(_ rig: IntentRig, _ condition: @MainActor () -> Bool) async { await rig.rig.wait(condition) }

    @Test func resumePauseToggleNextPreviousAndSeekRunTheHiddenPlayersOwnCommands() async throws {
        let (rig, page) = try await playing(lifecycleState(playing: false))
        #expect(await rig.run(.resume).isDone)
        await settle(rig) { page.bodies.contains(WebMusicScripts.play) }
        #expect(page.bodies.contains(WebMusicScripts.play), "Play is the player's own play command")
        #expect(await rig.run(.pause).isDone)
        await settle(rig) { page.bodies.last == WebMusicScripts.pause }
        #expect(page.bodies.last == WebMusicScripts.pause)
        #expect(await rig.run(.seek(to: 60)).isDone)
        await settle(rig) { page.bodies.contains(WebMusicScripts.seek) }
        #expect(page.commands.last { $0.body == WebMusicScripts.seek }?.arguments["seconds"] as? Double == 60)
        let skips = page.bodies.filter { $0 == WebMusicScripts.skip }.count
        let r0 = await rig.run(.next).isDone
        #expect(r0)
        await settle(rig) { page.bodies.filter { $0 == WebMusicScripts.skip }.count > skips }
        #expect(page.bodies.filter { $0 == WebMusicScripts.skip }.count == skips + 1, "Next is the player's own skip")
        let before = page.bodies.count
        let r1 = await rig.run(.previous).isDone
        #expect(r1)
        await settle(rig) { page.bodies.count > before }
        #expect(page.bodies.count > before, "Previous reached the player (restart or skip back, its own rule)")
        #expect(await rig.run(.toggle).isDone)
    }
    @Test func anAdvertisementCannotBeSkippedOrSoughtFromAnIntentEitherAndPauseStillWorks() async throws {
        let (rig, page) = try await playing()
        page.send(lifecycleState(position: 2, duration: 15, video: lifecycleAdVideo, ad: true))
        let before = page.bodies.count
        for command in [IntentCommand.next, .previous, .seek(to: 30)] {
            let outcome = await rig.run(command)
            #expect(outcome.refusal == .advertisement, "\(command.name): \(outcome)")
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(page.bodies.count == before, "nothing reached the page")
        #expect(await rig.run(.pause).isDone, "pausing an ad is allowed")
    }
    @Test func aPositionThatIsNotAPositionIsRefusedBeforeItReachesThePlayer() async throws {
        let (rig, page) = try await playing()
        let before = page.bodies.count
        for position in [-1.0, .nan, .infinity] {
            #expect(await rig.run(.seek(to: position)).refusal == .unavailable(String(localized: "Choose a position within the item.")), "\(position)")
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(page.bodies.count == before)
    }
    @Test func nothingLoadedMeansNothingPlayingForEveryTransportCommand() async throws {
        let rig = try await IntentRig.make()
        for command in [IntentCommand.resume, .pause, .toggle, .next, .previous, .seek(to: 5)] {
            #expect(await rig.run(command).refusal == .nothingPlaying, "\(command.name)")
        }
        #expect(rig.model.music == nil && rig.model.playRequestCount == 0)
    }
    /// ARCH03 ("the same use cases AND permission checks"): with no live YouTube Music session an intent meets exactly the gate the media key or the window
    /// meets for the same command. Nothing here is refused for being signed out except what needs the account.
    @Test func withNoYouTubeMusicSessionTheTransportIsGatedExactlyAsTheMediaKeysAre() async throws {
        let commands: [(IntentCommand, RemoteCommandKind)] = [(.resume, .play), (.pause, .pause), (.toggle, .toggle), (.next, .next), (.previous, .previous), (.seek(to: 5), .seek)]
        for mode in ["needs sign-in", "session expired", "no scope"] {
            for ad in [false, true] {
                let (rig, page) = try await playing(ad ? lifecycleState(position: 2, duration: 15, video: lifecycleAdVideo, ad: true) : lifecycleState())
                switch mode {
                case "needs sign-in": rig.surface.readiness = .needsSignIn
                case "session expired": rig.surface.readiness = .sessionExpired
                default: rig.surface.scope = nil
                }
                let enabled = rig.model.remoteCapabilities().enabled
                for (command, kind) in commands {
                    let outcome = await rig.run(command)
                    #expect(outcome.refusal != .signedOut, "\(mode) ad=\(ad) \(command.name): not refused for being signed out")
                    #expect(outcome.isDone == enabled.contains(kind), "\(mode) ad=\(ad) \(command.name): done exactly when the media key's command is on (\(outcome))")
                }
                _ = page
            }
        }
    }
    @Test func withNoSessionTheWindowsSearchAndTheOwnedMediaSleepTimerStillWork() async throws {
        let rig = try await IntentRig.make()
        rig.surface.readiness = .needsSignIn; rig.surface.scope = nil
        let player = await rig.run(.showPlayer), queue = await rig.run(.showQueue), search = await rig.run(.search("anonymous search"))
        #expect(player.isDone && queue.isDone && search.isDone, "\(player) \(queue) \(search)")
        #expect(rig.surface.shown == ["player", "queue", "search:anonymous search"], "the window's own search is anonymous when signed out; the intent does not refuse it")
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.rig.rigSetNative(session)
        await rig.model.refresh()
        #expect(await rig.run(.sleepTimer(.minutes(15))).isDone, "owned audio needs no YouTube Music account")
        #expect(try await session.snapshot().timer != nil)
        #expect(await rig.run(.pause).isDone)
        #expect(await rig.run(.sleepTimer(.off)).isDone)
        await session.close()
    }
    @Test func whatNeedsTheAccountIsStillRefusedWhenSignedOut() async throws {
        let (rig, page) = try await playing()
        let before = page.bodies.count
        rig.surface.readiness = .needsSignIn
        let media = intentMedia(scope: rig.scope)
        for command in [IntentCommand.play(media), .playSearch("x"), .rate(.like, of: media), .save(of: media)] {
            #expect(await rig.run(command).refusal == .signedOut, "\(command.name)")
        }
        #expect(rig.model.playRequestCount == 1 && page.bodies.count == before, "nothing reached the player (the one request is the fixture's own start)")
    }
}

extension IntentCommand { static func like() -> IntentCommand { .rate(.like, of: nil) } }

/// T24.1: play song/album/artist/playlist/mix and search.
@Suite @MainActor struct IntentPlayTests {
    private func loadedURL(_ rig: IntentRig) async throws -> URLComponents {
        await rig.rig.wait { rig.rig.log.pages.first?.loads.isEmpty == false }
        let page = try #require(rig.rig.log.pages.first)
        let url = try #require(page.loads.last)
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    }
    private func item(_ components: URLComponents, _ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }

    @Test func eachContentTypeStartsWhatThatTypesOwnPlayButtonStarts() async throws {
        let scope: IntentScope
        let cases: [(String, IntentMediaKind, MusicCatalogItem, String, String?)] = [
            ("song", .song, IntentFixtures.song("Alpha", video: "SYNTHalpha1", context: "OLAK5uy_alpha"), "OLAK5uy_alpha", "SYNTHalpha1"),
            ("song with only its own radio", .song, IntentFixtures.song("Alpha", video: "SYNTHalpha2"), "RDAMVMSYNTHalpha2", "SYNTHalpha2"),
            ("album", .album, IntentFixtures.album("Beta", id: "beta"), "OLAK5uy_beta", nil),
            ("playlist", .playlist, IntentFixtures.playlist("Gamma", id: "PLgamma"), "PLgamma", nil),
            ("artist", .artist, IntentFixtures.artist("Delta", id: "delta"), "RDEMsynthetic", nil),
        ]
        scope = try await IntentRig.make().scope
        for (name, kind, row, playlist, video) in cases {
            let rig = try await IntentRig.make()
            let media = try #require(AppIntentChannel.media(from: row, kind: kind, scope: rig.scope), "\(name) is playable")
            let outcome = await rig.run(.play(media))
            #expect(outcome.isDone, "\(name): \(outcome)")
            let url = try await loadedURL(rig)
            #expect(item(url, "list") == playlist, "\(name): the playlist its own play button names")
            #expect(item(url, "v") == video, "\(name)")
            #expect(rig.model.playRequestCount == 1)
        }
        _ = scope
    }
    @Test func aMixIsOnlyARadioTheServicePresentedAsOne() async throws {
        let rig = try await IntentRig.make()
        rig.surface.seeds = [RadioSeed(id: "RDEMmixsynth", kind: .page, title: "My Supermix", subtitle: "YouTube Music")]
        let mixes = await rig.channel.candidates(kind: .mix, matching: "supermix", limit: 5)
        let mix = try #require(mixes.first)
        #expect(mixes.count == 1 && mix.kind == .mix && mix.target.playlistID == "RDEMmixsynth")
        // An RD-prefixed playlist in the library is a playlist, never promoted to a mix by its id.
        rig.surface.rows[.playlists] = [IntentFixtures.playlist("Curated", id: "RDCLAKsynthetic")]
        #expect(await rig.channel.candidates(kind: .mix, matching: nil, limit: 10).count == 1)
        #expect(await rig.channel.candidates(kind: .playlist, matching: nil, limit: 10).count == 1)
        #expect(await rig.run(.play(mix)).isDone)
        #expect(try await loadedURL(rig).queryItems?.first { $0.name == "list" }?.value == "RDEMmixsynth")
    }
    @Test func anItemTheRowDidNotGiveAnythingToStartIsNeverOffered() async throws {
        let rig = try await IntentRig.make()
        rig.surface.rows[.artists] = [IntentFixtures.artist("No Radio", id: "none", radio: nil)]
        rig.surface.rows[.songs] = [MusicCatalogItem(kind: .song, title: "Uploaded", details: ["Me"], videoID: "SYNTHuploa1", isPrivatelyOwned: true)]
        #expect(await rig.channel.candidates(kind: nil, matching: nil, limit: 10).isEmpty)
        let handmade = IntentMedia(scope: rig.scope, kind: .artist, title: "No Radio", target: IntentMediaTarget(browseID: "UCnone"))
        let outcome = await rig.run(.play(handmade))
        #expect(outcome.refusal == .unavailable(String(localized: "YouTube Music gave this item nothing to play.")) && rig.model.playRequestCount == 0)
    }
    @Test func theSameSongListedInTwoLibraryCollectionsIsOneCandidate() async throws {
        let rig = try await IntentRig.make()
        // Songs and Liked songs list the same song under different watch contexts.
        rig.surface.rows[.songs] = [IntentFixtures.song("Alpha", video: "SYNTHalpha1", context: "OLAK5uy_one")]
        rig.surface.rows[.likedSongs] = [IntentFixtures.song("Alpha", video: "SYNTHalpha1", context: "PLlikedsongs")]
        let found = await rig.channel.candidates(kind: .song, matching: "alpha", limit: 10)
        #expect(found.count == 1)
        let outcome = await rig.run(.playSearch("alpha"))
        #expect(outcome.isDone, "a song in two collections is not a choice between two identical lines: \(outcome)")
        let other = intentMedia(.song, "Alpha", subtitle: "Synthetic Artist", scope: rig.scope, video: "SYNTHalpha2", playlist: "PLelsewhere")
        #expect(IntentResolver.resolve("alpha", among: found + [other]) != .one(other), "a different video of that name is a different item")
    }
    @Test func duplicateSpokenNamesAreAskedAboutThroughTheChoiceInteractionAndThePickedOnePlays() async throws {
        let rig = try await IntentRig.make()
        rig.surface.rows[.songs] = [IntentFixtures.song("Intro", artist: "Artist One", video: "SYNTHintro1"), IntentFixtures.song("Intro", artist: "Artist Two", video: "SYNTHintro2")]
        var asked: [[String]] = []
        rig.hub.chooser = { lines in asked.append(lines); return 1 }
        try await rig.run(PlayMediaSearchIntent(search: AudioSearch(criteria: .searchQuery("intro"))))
        #expect(asked.count == 1, "the person is asked once")
        let lines = asked.first ?? []
        #expect(lines.count == 2 && Set(lines).count == 2, "the person is shown two distinct lines: \(asked)")
        #expect(lines.allSatisfy { $0.contains("Artist") })
        let url = try await loadedURL(rig)
        #expect(item(url, "v") == "SYNTHintro2", "the second option was picked, so the second song plays")
        #expect(rig.model.playRequestCount == 1)
    }
    @Test func ifTheChoiceCannotBeAskedOrIsCancelledTheAmbiguityIsReportedAndNothingPlays() async throws {
        let rig = try await IntentRig.make()
        rig.surface.rows[.songs] = [IntentFixtures.song("Intro", artist: "Artist One", video: "SYNTHintro1"), IntentFixtures.song("Intro", artist: "Artist Two", video: "SYNTHintro2")]
        struct Cancelled: Error {}
        rig.hub.chooser = { _ in throw Cancelled() }
        let refusal = await rig.thrown { _ = try await PlayMediaSearchIntent(search: AudioSearch(criteria: .searchQuery("intro"))).perform() }
        guard case .ambiguous(let options)? = refusal else { Issue.record("\(String(describing: refusal))"); return }
        #expect(options.count == 2 && rig.model.playRequestCount == 0 && rig.rig.log.pages.isEmpty)
        rig.hub.chooser = { _ in 7 }
        let outOfRange = await rig.thrown { _ = try await PlayMediaSearchIntent(search: AudioSearch(criteria: .searchQuery("intro"))).perform() }
        #expect(outOfRange != nil && rig.model.playRequestCount == 0, "an index that is not an option plays nothing")
    }
    @Test func theChoiceLinesAreDistinctEvenWhenTwoItemsPrintTheSameAndAreBounded() {
        let scope = IntentScope(accountID: UUID(), generation: 1)
        let same = (1...7).map { intentMedia(.song, "Intro", subtitle: "Same", scope: scope, video: "SYNTHintro\($0)") }
        let lines = IntentChoice.lines(for: same)
        #expect(lines.count == IntentChoice.limit && Set(lines).count == lines.count)
    }
    @Test func aSpokenNamePlaysOnlyAnUnambiguousPlayableMatchAndOffersTheChoiceOtherwise() async throws {
        let rig = try await IntentRig.make()
        rig.surface.rows[.songs] = [IntentFixtures.song("Intro", artist: "Artist One", video: "SYNTHintro1"), IntentFixtures.song("Intro", artist: "Artist Two", video: "SYNTHintro2"),
                                    IntentFixtures.song("Solo", video: "SYNTHsolo01")]
        let ambiguous = await rig.run(.playSearch("intro"))
        guard case .ambiguous(let options)? = ambiguous.refusal else { Issue.record("two songs called Intro must be a choice: \(ambiguous)"); return }
        #expect(options.count == 2 && Set(options.compactMap(\.subtitle)) == ["Artist One", "Artist Two"])
        #expect(rig.model.playRequestCount == 0 && rig.rig.log.pages.isEmpty, "nothing started on a guess")
        #expect(await rig.run(.playSearch("nothing like this")).refusal == .notFound)
        let solo = await rig.run(.playSearch("solo"))
        #expect(solo.isDone, "\(solo)")
        #expect(rig.model.playRequestCount == 1)
    }
    @Test func anEntityOfAnotherAccountOrAnEarlierSessionStartsNothing() async throws {
        let rig = try await IntentRig.make()
        for scope in [rig.otherScope] {
            for kind in IntentMediaKind.allCases {
                let outcome = await rig.run(.play(intentMedia(kind, scope: scope)))
                #expect(outcome.refusal == .staleIdentity, "\(kind)")
            }
        }
        #expect(rig.model.playRequestCount == 0 && rig.rig.log.pages.isEmpty)
    }
    /// T24.2 / DATA03: the start permit is captured BEFORE the account scope is read. An account switch that lands between the two (here: right after the scope is
    /// read) must not let the old account's item start under the new account's player.
    @Test func anAccountSwitchBetweenTheScopeReadAndTheStartCannotStartTheOldAccountsItemUnderTheNewOne() async throws {
        for command in ["play", "playSearch"] {
            let rig = try await IntentRig.make()
            rig.surface.rows[.songs] = [IntentFixtures.song("Solo", video: "SYNTHsolo01")]
            let old = intentMedia(scope: rig.scope, video: "SYNTHsolo01", playlist: "RDAMVMSYNTHsolo01")
            let (newIdentity, newContext) = try lifecycleIdentity()
            // The old account's scope is read; then, before the command goes on, the account is switched: the old account detaches and the new one is restored.
            rig.surface.afterScopeRead = {
                try? await rig.rig.detach()
                try? await rig.rig.authority.restorePaused(newIdentity, context: newContext)
            }
            let outcome = await rig.run(command == "play" ? .play(old) : .playSearch("solo"))
            #expect(outcome.refusal == .staleIdentity, "\(command): \(outcome)")
            #expect(rig.rig.log.pages.isEmpty && rig.model.music == nil, "\(command): nothing of the old account started under the new account's player")
        }
    }
    @Test func theStartIsFencedByTheAccountBarrierExactlyAsAClickIs() async throws {
        let rig = try await IntentRig.make()
        try await rig.rig.detach()
        let outcome = await rig.run(.play(intentMedia(scope: rig.scope)))
        #expect(outcome.refusal == .staleIdentity, "the authority refused the permit: \(outcome)")
        #expect(rig.rig.log.pages.isEmpty)
    }
    @Test func afterARouteLossAPlayAsksPlayHereInTheWindowAndNothingSoundsBeforeTheAnswer() async throws {
        let rig = try await IntentRig.make(outputs: true)
        let (player, page) = try await rig.rig.play()
        rig.rig.directory?.change([routeSpeakers], defaultUID: routeSpeakers.uid)
        await rig.rig.controller?.coordinator.settled()
        let plays = page.bodies.filter { $0 == WebMusicScripts.play }.count
        // Resume of the paused item.
        let resume = await rig.run(.resume)
        guard case .needsConfirmation? = resume.refusal else { Issue.record("Play here must be asked first: \(resume)"); return }
        #expect(rig.surface.shown.contains("player"), "the prompt is in the window, which comes forward")
        await rig.rig.wait { rig.rig.controller?.coordinator.prompt != nil }
        let prompt = try #require(rig.rig.controller?.coordinator.prompt)
        #expect(page.bodies.filter { $0 == WebMusicScripts.play }.count == plays && !player.snapshot.intent, "nothing sounds before the confirmation")
        await rig.rig.controller?.coordinator.confirm(prompt.id)
        await rig.rig.wait { page.bodies.filter { $0 == WebMusicScripts.play }.count > plays }
        #expect(page.bodies.filter { $0 == WebMusicScripts.play }.count == plays + 1)
    }
    @Test func aNewItemBehindALostRouteIsHeldWithItsPermitAndStartsOnlyAfterTheAnswer() async throws {
        let rig = try await IntentRig.make(outputs: true)
        let (_, page) = try await rig.rig.play()
        rig.rig.directory?.change([routeSpeakers], defaultUID: routeSpeakers.uid)
        await rig.rig.controller?.coordinator.settled()
        let loads = page.loads.count, scripts = page.bodies.count
        let held = await rig.run(.play(intentMedia(scope: rig.scope, video: "SYNTHother1", playlist: "PLother")))
        guard case .needsConfirmation? = held.refusal else { Issue.record("\(held)"); return }
        await rig.rig.wait { rig.rig.controller?.coordinator.prompt != nil }
        let prompt = try #require(rig.rig.controller?.coordinator.prompt)
        #expect(page.loads.count == loads && page.bodies.count == scripts, "the new item has not been sent to the player: nothing can sound")
        await rig.rig.controller?.coordinator.confirm(prompt.id)
        await rig.rig.wait { page.loads.count > loads || page.bodies.count > scripts }
        #expect(page.loads.count > loads || page.bodies.count > scripts, "after the answer the held start runs")
    }
}

/// T24.1 (like/save through the W12 ledger) and T24.3 (the same confirmation and entitlement rules as the UI).
@Suite @MainActor struct IntentLibraryTests {
    private func fullLibrary(_ rig: IntentRig, liked: Bool = false, saved: Bool = false, disliked: Bool = false) {
        rig.rig.library.states = [.like: .available(FakeRemoteLibrary.control(.like, on: liked)), .dislike: .available(FakeRemoteLibrary.control(.dislike, on: disliked)),
                                  .save: .available(FakeRemoteLibrary.control(.save, on: saved))]
    }
    private func playing() async throws -> IntentRig {
        let rig = try await IntentRig.make()
        _ = try await rig.rig.play()
        return rig
    }
    @Test func likeDislikeAndSaveAreOneLedgerPressEachOnTheSongThatIsPlaying() async throws {
        let rig = try await playing(); fullLibrary(rig)
        #expect(await rig.run(.rate(.like, of: nil)).isDone)
        await rig.rig.wait { rig.rig.library.pressed.count == 1 }
        #expect(rig.rig.library.pressed.map(\.kind) == [.like])
        #expect(await rig.run(.save(of: nil)).isDone)
        await rig.rig.wait { rig.rig.library.pressed.count == 2 }
        #expect(rig.rig.library.pressed.map(\.kind) == [.like, .save])
        #expect(await rig.run(.rate(.dislike, of: nil)).isDone)
        await rig.rig.wait { rig.rig.library.pressed.count == 3 }
        #expect(rig.rig.library.pressed.map(\.kind) == [.like, .save, .dislike])
    }
    @Test func askingForAStateThatAlreadyHoldsPressesNothingAndRemovingARatingPressesTheOneThatIsOn() async throws {
        let rig = try await playing(); fullLibrary(rig, liked: true, saved: true)
        let r0 = await rig.run(.rate(.like, of: nil)).isDone
        let r1 = await rig.run(.save(of: nil)).isDone
        #expect(r0 && r1)
        try await Task.sleep(for: .milliseconds(40))
        #expect(rig.rig.library.pressed.isEmpty, "a like on a liked song is not an unlike")
        #expect(await rig.run(.rate(.none, of: nil)).isDone)
        await rig.rig.wait { rig.rig.library.pressed.count == 1 }
        #expect(rig.rig.library.pressed.map(\.kind) == [.like] && rig.rig.library.pressed.first?.isOn == true)
        fullLibrary(rig)
        let none = await rig.run(.rate(.none, of: nil))
        #expect(none == .done(String(localized: "This song has no rating to remove.")))
    }
    @Test func theRulesTheWindowAppliesAreAppliedHere() async throws {
        // An advertisement: refused before the library is even asked.
        let ad = try await playing(); fullLibrary(ad)
        ad.rig.log.pages.first?.send(lifecycleState(position: 2, duration: 15, video: lifecycleAdVideo, ad: true))
        let asked = ad.rig.library.asked.count
        let r0 = await ad.run(.rate(.like, of: nil)).refusal
        let r1 = await ad.run(.save(of: nil)).refusal
        #expect(r0 == .advertisement && r1 == .advertisement)
        #expect(ad.rig.library.asked.count == asked && ad.rig.library.pressed.isEmpty)
        // No library path for this song (its page was not read): the reason is the window's.
        let unread = try await playing()
        let outcome = await unread.run(.rate(.like, of: nil))
        guard case .unavailable(let why)? = outcome.refusal else { Issue.record("\(outcome)"); return }
        #expect(!why.isEmpty && why == unread.model.remoteReason(.like))
        #expect(unread.rig.library.pressed.isEmpty)
        // Nothing playing.
        let idle = try await IntentRig.make()
        let i0 = await idle.run(.rate(.like, of: nil)).refusal
        let i1 = await idle.run(.save(of: nil)).refusal
        #expect(i0 == .nothingPlaying && i1 == .nothingPlaying)
    }
    @Test func onlyTheSongThatIsPlayingCanBeLikedOrSavedAndOnlyByAnEntityOfThisSession() async throws {
        let rig = try await playing(); fullLibrary(rig)
        let other = intentMedia(scope: rig.scope, video: "SYNTHother1")
        let album = intentMedia(.album, scope: rig.scope)
        let foreign = intentMedia(scope: rig.otherScope)
        let sentence = String(localized: "YTMuse can like or save only the song that is playing.")
        #expect(await rig.run(.rate(.like, of: other)).refusal == .unavailable(sentence))
        #expect(await rig.run(.save(of: album)).refusal == .unavailable(sentence))
        let r0 = await rig.run(.rate(.like, of: foreign)).refusal
        let r1 = await rig.run(.save(of: foreign)).refusal
        #expect(r0 == .staleIdentity && r1 == .staleIdentity)
        #expect(rig.rig.library.pressed.isEmpty)
        let itself = intentMedia(scope: rig.scope, video: lifecycleVideo)
        #expect(await rig.run(.rate(.like, of: itself)).isDone)
        await rig.rig.wait { rig.rig.library.pressed.count == 1 }
        #expect(rig.rig.library.pressed.count == 1)
    }
}

/// T24.1 windows and the sleep timer; T24.3 cold launch.
@Suite @MainActor struct IntentWindowAndTimerTests {
    @Test func searchShowQueueAndShowPlayerAskTheWindowsAndStartNothing() async throws {
        let rig = try await IntentRig.make()
        let r0 = await rig.run(.search("  daft punk  ")).isDone
        let r1 = await rig.run(.showQueue).isDone
        let r2 = await rig.run(.showPlayer).isDone
        #expect(r0 && r1 && r2)
        #expect(rig.surface.shown == ["search:daft punk", "queue", "player"])
        for bad in ["", "   ", String(repeating: "a", count: 513)] { #expect(await rig.run(.search(bad)).refusal != nil, "\(bad.count)") }
        #expect(rig.surface.shown.count == 3 && rig.model.playRequestCount == 0 && rig.rig.log.pages.isEmpty)
    }
    @Test func aSearchNoWindowCouldPerformIsReportedAsNotDoneNeverAsSearching() async throws {
        let rig = try await IntentRig.make()
        rig.surface.searchPerforms = false
        let outcome = await rig.run(.search("daft punk"))
        guard case .failed(let why)? = outcome.refusal else { Issue.record("\(outcome)"); return }
        #expect(why.contains("not searched") && rig.surface.shown.isEmpty)
    }
    /// P17-WEB: the hidden player has a sleep timer now, and the intent sets it through the same owner call the menu makes (it no longer refuses).
    @Test func theYouTubeMusicSleepTimerIsSetThroughTheOwnersCallAndTheIntentSaysWhatItDid() async throws {
        let timing = ManualSleepTiming()
        let rig = try await IntentRig.make(timing: timing)
        let (player, page) = try await rig.rig.play()
        #expect(await rig.run(.sleepTimer(.minutes(15))).isDone)
        #expect(player.sleepTimerState?.remaining(at: timing.wall()) == 900 && player.sleepTimerState?.endOfItem == false)
        #expect(await rig.run(.sleepTimer(.minutes(45))).isDone, "a length the menu does not list is a custom timer")
        #expect(player.sleepTimerState?.remaining(at: timing.wall()) == 2700)
        guard case .done(let said) = await rig.run(.sleepTimer(.endOfItem)) else { Issue.record("end of item"); return }
        #expect(player.sleepTimerState?.endOfItem == true && said.contains("end of this item"))
        guard case .done(let off) = await rig.run(.sleepTimer(.off)) else { Issue.record("off"); return }
        #expect(player.sleepTimerState == nil && off.contains("off"))
        #expect(!page.bodies.contains(WebMusicScripts.fadeVolume), "setting and clearing a timer sends the page nothing")
        #expect(!(rig.surface.shown.contains("player")), "and opens no window")
    }
    @Test func theYouTubeMusicSleepTimerRefusesWhatItCannotDoInPlainWords() async throws {
        let rig = try await IntentRig.make()
        _ = try await rig.rig.play()
        rig.rig.log.pages[0].send(systemMediaLiveBody())
        guard case .unavailable(let why)? = await rig.run(.sleepTimer(.endOfItem)).refusal else { Issue.record("live"); return }
        #expect(why.contains("live stream"))
        let idle = try await IntentRig.make()
        guard case .unavailable(let nothing)? = await idle.run(.sleepTimer(.minutes(5))).refusal else { Issue.record("idle"); return }
        #expect(nothing.contains("Nothing is playing"))
        guard case .unavailable? = await idle.run(.sleepTimer(.off)).refusal else { Issue.record("idle off"); return }
    }
    @Test func theNativeSessionsSleepTimerIsSetThroughTheWindowsOwnPath() async throws {
        let rig = try await IntentRig.make()
        let session = try await ownedSession(wall: ManualWall(), clock: ManualMonotonic())
        try await session.startOwnedMedia(OwnedMedia.items)
        rig.rig.rigSetNative(session)
        await rig.model.refresh()
        #expect(await rig.run(.sleepTimer(.minutes(15))).isDone)
        #expect(try await session.snapshot().timer != nil)
        #expect(await rig.run(.sleepTimer(.endOfItem)).isDone)
        #expect(try await session.snapshot().timer?.endOfItem == true)
        #expect(await rig.run(.sleepTimer(.minutes(45))).isDone, "a length the menu does not list is a custom timer")
        #expect(await rig.run(.sleepTimer(.off)).isDone)
        #expect(try await session.snapshot().timer == nil)
        await session.close()
    }
    @Test func aColdLaunchRestoresPausedAndOnlyAnExplicitPlayRequestPlaysIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-intent-resume-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = try await LifecycleRig.make()
        let store = MusicResumeFileStore(directory: root)
        try await store.save(MusicResumeRecord(playlistID: "PLsyntheticLife", playlistTitle: "Synthetic Mix", videoID: lifecycleVideo, title: "Synthetic Song", artist: "Synthetic Artist", position: 42, duration: 200),
                             account: lifecycle.identity.id.accountID.uuidString)
        lifecycle.model.resumeStore = store
        await lifecycle.model.restoreLastSession()
        let rig = IntentRig.make(lifecycle: lifecycle)
        try await Task.sleep(for: .milliseconds(100))
        #expect(lifecycle.log.pages.isEmpty && lifecycle.model.music?.snapshot.restored == true, "restored paused, nothing loaded")
        // Anything that is not an explicit play is refused by the window's own rule for a restored item, and loads nothing.
        for command in [IntentCommand.next, .previous, .seek(to: 10)] {
            #expect(await rig.run(command).refusal == .unavailable(RemoteCommandReason.restored), "\(command.name): the window's own sentence for a restored item")
        }
        for command in [IntentCommand.like(), .save(of: nil)] { #expect(await rig.run(command).refusal != nil, "\(command.name)") }
        #expect(await rig.run(.pause).isDone, "pausing an already paused item is harmless")
        try await Task.sleep(for: .milliseconds(100))
        #expect(lifecycle.log.pages.isEmpty, "none of those started anything")
        // The explicit request plays: the same Play a media key sends.
        #expect(await rig.run(.resume).isDone)
        for _ in 0..<400 where lifecycle.log.pages.first?.loads.isEmpty ?? true { try await Task.sleep(for: .milliseconds(5)) }
        let page = try #require(lifecycle.log.pages.first)
        let components = URLComponents(url: try #require(page.loads.last), resolvingAgainstBaseURL: false)
        #expect(components?.queryItems?.first { $0.name == "list" }?.value == "PLsyntheticLife")
        #expect(rig.hub.channel != nil && rig.surface.startups >= 1, "the cold start waited for the app to finish restoring")
    }
    @Test func anIntentThatArrivesBeforeTheAppIsUpWaitsForItAndDoesNotGuess() async throws {
        let rig = try await IntentRig.make()
        let hub = IntentHub(); hub.startupTimeout = .seconds(5)
        async let outcome = hub.run(.showPlayer)
        try await Task.sleep(for: .milliseconds(120))
        hub.install(rig.channel)
        #expect(await outcome == .done(String(localized: "Showing the player.")))
        #expect(rig.surface.startups == 1 && rig.surface.shown == ["player"])
        let never = IntentHub(); never.startupTimeout = .milliseconds(80)
        #expect(await never.run(.pause).refusal == .appNotReady)
    }
}
