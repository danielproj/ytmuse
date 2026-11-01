import AppIntents
import Foundation
import Testing
@testable import Features
@testable import SystemIntegration
@testable import AppShell

/// T24.2 (MAC03): entities are resolved against the current account; duplicate titles require disambiguation; an identifier from another account is
/// refused with a clear error and never resolved against the current one. An identifier is bound to the ACCOUNT, so a saved Shortcut keeps working
/// after a relaunch and after signing in to the same account again (operator decision, W24 rework 1).
@Suite @MainActor struct IntentIdentityTests {
    private let scope = IntentScope(accountID: UUID(), generation: 4)

    @Test func anIdentifierCarriesTheAccountAndTheKindButNoSessionCounterAndRoundTrips() throws {
        let media = IntentMedia(scope: scope, kind: .album, title: "Synthetic Album", subtitle: "Synthetic Artist",
                                target: IntentMediaTarget(playlistID: "OLAK5uy_x", browseID: "MPREb_x", params: "wAEB"))
        let encoded = media.encoded
        #expect(encoded.hasPrefix("ytm1:\(scope.accountID.uuidString):album:"), "the binding is readable in the identifier itself: \(encoded)")
        #expect(encoded.split(separator: ":").count == 4, "account, kind and payload only: no per-launch counter")
        #expect(IntentMedia(encoded: encoded) == media)
        #expect(IntentMedia.claimedAccount(of: encoded) == scope.accountID)
        // The same item minted in two different sessions is the same identifier.
        let relaunched = IntentMedia(scope: IntentScope(accountID: scope.accountID, generation: 99), kind: .album, title: "Synthetic Album", subtitle: "Synthetic Artist",
                                     target: IntentMediaTarget(playlistID: "OLAK5uy_x", browseID: "MPREb_x", params: "wAEB"))
        #expect(relaunched.encoded == encoded)
    }
    @Test func anythingThatIsNotAnIdentifierThisLayerWroteIsRefusedRatherThanGuessed() {
        let good = intentMedia(scope: scope).encoded
        let parts = good.split(separator: ":").map(String.init)
        let bad: [String] = ["", "ytm1", "x:y:z", good + ":extra", parts[0] + "x:" + parts[1...].joined(separator: ":"),
                             ["ytm1", "not-a-uuid", "song", parts[3]].joined(separator: ":"),
                             ["ytm1", parts[1], "podcast", parts[3]].joined(separator: ":"), ["ytm1", parts[1], "song", "%%%"].joined(separator: ":"),
                             ["ytm1", parts[1], "song", String(repeating: "A", count: 5_000)].joined(separator: ":"),
                             ["ytm1", parts[1], "4", "song", parts[3]].joined(separator: ":")]
        for text in bad { #expect(IntentMedia(encoded: text) == nil, Comment(rawValue: String(text.prefix(40)))) }
        // A well-formed payload with nothing to start or open is not an entity either.
        let empty = IntentMedia(scope: scope, kind: .song, title: "x", target: IntentMediaTarget())
        #expect(IntentMedia(encoded: empty.encoded) == nil)
    }
    @Test func onlyTheCurrentAccountIsAdmittedWhateverTheSession() {
        let media = intentMedia(scope: scope)
        #expect(IntentResolver.admit(media, current: scope) == nil)
        #expect(IntentResolver.admit(media, current: IntentScope(accountID: UUID(), generation: 4)) == .staleIdentity, "another account")
        #expect(IntentResolver.admit(media, current: IntentScope(accountID: scope.accountID, generation: 5)) == nil, "the same account, a later session (re-sign-in)")
        #expect(IntentResolver.admit(media, current: IntentScope(accountID: scope.accountID, generation: 0)) == nil, "the same account after a relaunch")
        #expect(IntentResolver.admit(media, current: nil) == .signedOut)
        #expect(IntentResolver.admit(encoded: media.encoded, current: scope) == nil)
        #expect(IntentResolver.admit(encoded: "garbage", current: scope) == .staleIdentity)
    }
    @Test func theRefusalForAnotherAccountAndForAMalformedIdentifierIsOneSentenceThatNamesNeither() {
        let other = IntentScope(accountID: UUID(), generation: 4)
        let a = IntentResolver.admit(intentMedia(scope: other), current: scope)
        let b = IntentResolver.admit(encoded: "ytm1:garbage", current: scope)
        #expect(a == b && a?.message == b?.message)
        let text = a?.message ?? ""
        #expect(!text.isEmpty && !text.contains(other.accountID.uuidString) && !text.contains(scope.accountID.uuidString) && !text.contains("Synthetic"))
    }
    @Test func theEntitiesCarryTheIdentifierAndNothingAboutAnotherAccount() throws {
        let media = intentMedia(.song, "Synthetic Song", scope: scope)
        let song = SongEntity(media: media)
        #expect(song.id == media.encoded && song.title == "Synthetic Song" && song.artistName == "Synthetic Artist")
        #expect(AudioTarget.song(song).media == media)
        #expect(AudioTarget.album(AlbumEntity(media: intentMedia(.album, scope: scope))).media?.kind == .album)
        #expect(AudioTarget.artist(ArtistEntity(media: intentMedia(.artist, scope: scope))).media?.kind == .artist)
        #expect(AudioTarget.playlist(PlaylistEntity(media: intentMedia(.playlist, scope: scope))).media?.kind == .playlist)
        #expect(AudioTarget.mix(MixEntity(media: intentMedia(.mix, scope: scope))).media?.kind == .mix)
        // What the row did not say is not claimed: a playlist is not "created by me" or "curated for me" on a guess.
        let playlist = PlaylistEntity(media: intentMedia(.playlist, scope: scope))
        #expect(playlist.createdByMe == nil && playlist.curatedForMe == nil)
        #expect(MixEntity(media: intentMedia(.mix, scope: scope)).curatedForMe == nil)
    }
}

/// T24.2: the queries.
@Suite @MainActor struct IntentQueryScopeTests {
    @Test func aSavedIdentifierSurvivesARelaunchAndASignInToTheSameAccountAndIsRefusedForAnyOtherAccount() async throws {
        let rig = try await IntentRig.make()
        let saved = intentMedia(scope: rig.scope)
        // Same process, same session.
        let now = try await rig.within { try await SongQuery().entities(for: [saved.encoded]).map(\.id) }
        #expect(now == [saved.encoded])
        // A relaunch: a new process whose per-launch counter has nothing to do with the old one.
        for session in [rig.laterSession, rig.earlierSession, IntentScope(accountID: rig.scope.accountID, generation: 0)] {
            rig.surface.scope = session
            let found = try await rig.within { try await SongQuery().entities(for: [saved.encoded]).map(\.id) }
            #expect(found == [saved.encoded], "generation \(session.generation) is the same account")
        }
        // Signing in to the same account again, then performing: the entity still plays.
        rig.surface.scope = rig.laterSession
        _ = try await rig.within { try await SongQuery().entities(for: [saved.encoded]).count }   // the system resolves the saved entity first, in this session
        #expect(await rig.run(.play(saved)).isDone)
        // Any other account is refused, alone or in a batch.
        rig.surface.scope = rig.otherScope
        let alone = await rig.thrown { try await SongQuery().entities(for: [saved.encoded]) }
        let mixed = await rig.thrown { try await SongQuery().entities(for: [intentMedia(scope: rig.otherScope).encoded, saved.encoded]) }
        #expect(alone == .staleIdentity && mixed == .staleIdentity, "one foreign identifier refuses the whole request")
        let garbage = await rig.thrown { try await AlbumQuery().entities(for: ["not an identifier"]) }
        #expect(garbage == .staleIdentity)
        #expect(await rig.run(.play(saved)).refusal == .staleIdentity)
        rig.surface.scope = nil
        let signedOut = await rig.thrown { try await SongQuery().entities(for: [saved.encoded]) }
        #expect(signedOut == .signedOut)
    }
    /// DATA03 rests on three things, none of them a shared timer: the account check at the moment the command runs, the start permit captured at the request
    /// (the authority rejects it across a barrier), and each invocation's own recheck of the session it started in.
    @Test func twoConcurrentIntentsAreEachHeldToTheAccountTheyRunUnderAndNeitherDisturbsTheOther() async throws {
        let rig = try await IntentRig.make()
        let other = rig.otherScope
        let mine = intentMedia(scope: rig.scope, video: "SYNTHalpha1", playlist: "PLalpha")
        let theirs = intentMedia(scope: other, video: "SYNTHbeta01", playlist: "PLbeta")
        // Both are resolved (queries run for each) ...
        _ = try await rig.within { try await SongQuery().entities(for: [mine.encoded]).count }
        // ... then another account becomes the live one, and the two intents run at the same time.
        rig.surface.scope = other
        // TH1: the two runs overlap by construction, not by scheduling luck. Every start captures a permit from one counter, and a permit is good only until
        // the NEXT one is minted, so with `async let` the outcome depended on which task the main actor happened to run first (the live account's intent was refused
        // `staleIdentity` in about 15% of runs, seen 3 of 20 here and 2 of 10 on main by W25). The first intent is held right after it has captured its permit and read
        // the live scope, the second then runs to its end, and the first is released: they are in flight together, and the order is the one the test describes.
        let held = HeldPoint()
        rig.surface.afterScopeRead = { await held.hold() }
        let first = Task { await rig.run(.play(mine)) }
        await held.wait()
        let b = await rig.run(.play(theirs))
        await held.release()
        let a = await first.value
        #expect(a.refusal == .staleIdentity, "the first intent's entity belongs to the account that is no longer live: \(a)")
        #expect(b.isDone, "the second intent is for the live account and is not disturbed by the first: \(b)")
        #expect(rig.model.playRequestCount == 1, "exactly one start happened")
    }
    /// TH1 rework 1: "the latest LEGITIMATE request wins". A request that is refused (a foreign account here) never takes part, so it cannot cancel a legitimate
    /// start that is in flight, whichever of them captured its permit first.
    @Test func aRefusedIntentArrivingAfterALegitimateOneLeavesTheLegitimateStartIntact() async throws {
        let rig = try await IntentRig.make()
        let good = intentMedia(scope: rig.scope, video: "SYNTHalpha1", playlist: "PLalpha")
        let foreign = intentMedia(scope: rig.otherScope, video: "SYNTHbeta01", playlist: "PLbeta")
        let held = HeldPoint()
        rig.surface.afterScopeRead = { await held.hold() }          // the legitimate intent has captured its permit and read the live scope
        let legitimate = Task { await rig.run(.play(good)) }
        await held.wait()
        let refused = await rig.run(.play(foreign))                  // captures a LATER permit, is refused at admission, runs to its end
        await held.release()
        let started = await legitimate.value
        #expect(refused.refusal == .staleIdentity, "\(refused)")
        #expect(started.isDone, "the refused intent did not disturb the legitimate one: \(started)")
        #expect(rig.model.playRequestCount == 1 && rig.rig.log.pages.count == 1, "exactly one start")
    }
    @Test func aSecondLegitimateRequestStillSupersedesTheFirst() async throws {
        let rig = try await IntentRig.make()
        let first = intentMedia(scope: rig.scope, video: "SYNTHalpha1", playlist: "PLalpha")
        let second = intentMedia(scope: rig.scope, video: "SYNTHbeta01", playlist: "PLbeta")
        let held = HeldPoint()
        rig.surface.afterScopeRead = { await held.hold() }
        let earlier = Task { await rig.run(.play(first)) }
        await held.wait()
        let later = await rig.run(.play(second))                     // a legitimate request, captured later, starts and finishes
        await held.release()
        let superseded = await earlier.value
        #expect(later.isDone, "\(later)")
        #expect(superseded.refusal == .staleIdentity, "the older legitimate request is superseded by the newer one: \(superseded)")
        #expect(rig.rig.log.pages.count == 1)
    }
    @Test func theSameAccountAfterAReSignInIsNotRefusedWhateverQueriesRanBefore() async throws {
        let rig = try await IntentRig.make()
        let media = intentMedia(scope: rig.scope)
        _ = try await rig.within { try await SongQuery().entities(for: [media.encoded]).count }
        rig.surface.scope = rig.laterSession
        _ = try await rig.within { try await AlbumQuery().entities(matching: "anything").count }   // another intent's query in between overwrites nothing
        #expect(await rig.run(.play(media)).isDone, "no timer and no shared stamp: the account is the same")
    }
    @Test func aSpokenNamePlayIsRefusedIfTheSessionChangesWhileItIsResolving() async throws {
        let rig = try await IntentRig.make()
        rig.surface.rows[.songs] = [IntentFixtures.song("Solo", video: "SYNTHsolo01")]
        let other = rig.otherScope
        rig.surface.onFirstRowsRead = { rig.surface.scope = other }      // the account switches while this invocation reads the library
        let outcome = await rig.run(.playSearch("solo"))
        #expect(outcome.refusal == .staleIdentity && rig.model.playRequestCount == 0, "\(outcome)")
        // A second invocation, started afterwards under the new session, resolves on its own (no rows for that account here: not found, not stale).
        rig.surface.rows[.songs] = [IntentFixtures.song("Solo", video: "SYNTHsolo01")]
        #expect(await rig.run(.playSearch("solo")).isDone)
    }
    @Test func theSearchBehindAQueryReadsOnlyWhatTheModelsAlreadyHold() async throws {
        let rig = try await IntentRig.make()
        rig.surface.rows[.songs] = [IntentFixtures.song("Alpha", video: "SYNTHalpha1")]
        rig.surface.rows[.albums] = [IntentFixtures.album("Beta", id: "beta")]
        let songs = try await rig.within { try await SongQuery().entities(matching: "alpha").map(\.title) }
        let albums = try await rig.within { try await AlbumQuery().entities(matching: "beta").map(\.title) }
        let crossed = try await rig.within { try await SongQuery().entities(matching: "beta").count }
        let suggested = try await rig.within { try await SongQuery().suggestedEntities().map(\.title) }
        #expect(songs == ["Alpha"] && albums == ["Beta"])
        #expect(crossed == 0, "an album is not a song")
        #expect(suggested == ["Alpha"])
        #expect(rig.surface.shown.isEmpty && rig.model.playRequestCount == 0, "a query opens no window and starts nothing")
    }
    @Test func aQueryThatCannotAnswerSaysSoInsteadOfInventingAnAnswer() async throws {
        let rig = try await IntentRig.make()
        rig.surface.scope = nil
        let refused = await rig.thrown { try await SongQuery().entities(matching: "x") }
        let suggested = try await rig.within { try await SongQuery().suggestedEntities().count }
        #expect(refused == .signedOut && suggested == 0)
        let empty = IntentHub(); empty.startupTimeout = .milliseconds(60)
        let notReady: IntentRefusal?
        do { _ = try await IntentHub.$current.withValue(empty) { try await SongQuery().entities(matching: "x") }; notReady = nil }
        catch let refusal as IntentRefusal { notReady = refusal } catch { notReady = .failed("\(error)") }
        #expect(notReady == .appNotReady)
    }
}

/// T24.2 (disambiguation): duplicate titles are never reduced to one.
@Suite struct IntentResolverTests {
    private let scope = IntentScope(accountID: UUID(), generation: 1)
    private func song(_ title: String, _ artist: String, _ video: String) -> IntentMedia { intentMedia(.song, title, subtitle: artist, scope: scope, video: video) }
    @Test func twoItemsWithTheSameTitleAreReturnedTogetherAndTheirLinesDiffer() {
        let a = song("Intro", "Artist One", "SYNTHintro1"), b = song("Intro", "Artist Two", "SYNTHintro2")
        guard case .many(let options) = IntentResolver.resolve("intro", among: [a, b]) else { Issue.record("duplicate titles must not resolve to one"); return }
        #expect(Set(options.map(\.id)) == Set([a.id, b.id]))
        #expect(Set(options.map(IntentResolver.disambiguationLine)).count == 2, "what the person is shown tells them apart")
        #expect(IntentRefusal.ambiguous(options).message.contains("Artist One") && IntentRefusal.ambiguous(options).message.contains("Artist Two"))
    }
    @Test func theSameItemSeenInTwoCachesIsOneItem() {
        let a = song("Intro", "Artist One", "SYNTHintro1")
        #expect(IntentResolver.resolve("Intro", among: [a, a]) == .one(a))
    }
    @Test func theSameVideoListedUnderTwoContextsIsOneItemButAnotherVideoIsNot() {
        let a = intentMedia(.song, "Intro", subtitle: "A", scope: scope, video: "SYNTHintro1", playlist: "OLAK5uy_album")
        let b = intentMedia(.song, "Intro", subtitle: "A", scope: scope, video: "SYNTHintro1", playlist: "PLlikedsongs")
        let c = intentMedia(.song, "Intro", subtitle: "A", scope: scope, video: "SYNTHintro2", playlist: "OLAK5uy_album")
        #expect(a.encoded != b.encoded && a.identity == b.identity, "different start contexts, one song")
        #expect(IntentResolver.resolve("intro", among: [a, b]) == .one(a))
        guard case .many = IntentResolver.resolve("intro", among: [a, b, c]) else { Issue.record("another video of that name is a choice"); return }
    }
    @Test func anExactTitleBeatsAPartialOneAndPartialMatchesAreUsedOnlyWhenNothingIsExact() {
        let exact = song("Intro", "A", "SYNTHintro1"), longer = song("Intro (Live)", "A", "SYNTHintro2")
        #expect(IntentResolver.resolve("intro", among: [exact, longer]) == .one(exact))
        #expect(IntentResolver.resolve("live", among: [exact, longer]) == .one(longer))
        #expect(IntentResolver.resolve("zzz", among: [exact, longer]) == .none)
        #expect(IntentResolver.resolve("   ", among: [exact]) == .none)
    }
    @Test func aSpokenNameMatchesAcrossCaseDiacriticsAndPunctuationButNeverChangesWhatIsShown() {
        let media = song("Beyoncé — Halo!", "B", "SYNTHhalo01")
        #expect(IntentResolver.resolve("beyonce halo", among: [media]) == .one(media))
        #expect(media.title == "Beyoncé — Halo!")
        #expect(IntentResolver.fold("  Hello,   WORLD ") == "hello world")
    }
    @Test func theKindFiltersAndKindsNeverMix() {
        let s = song("Same", "A", "SYNTHsame01"), a = intentMedia(.album, "Same", scope: scope, video: nil, playlist: "OLAK5uy_s")
        #expect(IntentResolver.resolve("same", among: [s, a], kind: .album) == .one(a))
        guard case .many = IntentResolver.resolve("same", among: [s, a]) else { Issue.record("a song and an album of one name are two choices"); return }
    }
}
