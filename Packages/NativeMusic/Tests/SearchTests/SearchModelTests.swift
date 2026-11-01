import AccountSession
import Foundation
import Testing
@testable import Features

/// T10.1 — virtual clock, immediate local results, stale replies.
@Suite @MainActor struct SearchTimingTests {
    @MainActor final class Rig {
        let clock = VirtualClock()
        let remote = ScriptedRemote()
        let performer = SpyPerformer()
        let box = ScopeBox()
        let model: SearchModel
        init(library: [(String, String)] = [("PLlocalcafe", "Café Mix"), ("PLlocalrock", "Rock Classics")], sources: Bool = true) {
            let remote = self.remote, box = self.box
            model = SearchModel(sources: sources ? [FakeLibrary(library)] : [], remote: { try await remote.call($0) }, performer: performer,
                                clock: clock, accountScope: { box.value }, playback: { box.playback })
        }
        var scopeToken: String { get { box.value } set { box.value = newValue } }
    }
    @MainActor final class ScopeBox { var value = "account-a"; var playback = SearchPlayback.available }

    @Test func localMatchesAreImmediateAndTheServiceWaitsExactly180ms() async throws {
        let rig = Rig()
        rig.model.query = "caf"
        await settle()
        #expect(rig.model.results.map(\.title) == ["Café Mix"], "local matches show before any quiet period has passed")
        #expect(rig.model.remoteStatus == .waiting)
        #expect(await rig.remote.callCount == 0)
        rig.clock.advance(by: .milliseconds(179))
        await settle()
        #expect(await rig.remote.callCount == 0, "179 ms is still inside the quiet period")
        rig.clock.advance(by: .milliseconds(1))
        await settle()
        #expect(await rig.remote.queries == ["caf"])
        #expect(rig.model.remoteStatus == .loading)
    }
    @Test func eachKeystrokeRestartsTheQuietPeriodSoOnlyTheLastQueryIsSent() async throws {
        let rig = Rig()
        rig.model.query = "c"; await settle()
        rig.clock.advance(by: .milliseconds(100)); await settle()
        rig.model.query = "ca"; await settle()
        rig.clock.advance(by: .milliseconds(100)); await settle()
        #expect(await rig.remote.callCount == 0, "200 ms after the first key but only 100 ms after the last")
        rig.model.query = "caf"; await settle()
        rig.clock.advance(by: .milliseconds(179)); await settle()
        #expect(await rig.remote.callCount == 0)
        rig.clock.advance(by: .milliseconds(1)); await settle()
        #expect(await rig.remote.queries == ["caf"], "intermediate queries never reach the service")
    }
    @Test func aReplyForAnOlderQueryCannotReplaceTheNewerScreen() async throws {
        let rig = Rig(sources: false)
        rig.model.query = "alpha"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        rig.model.query = "beta"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        #expect(await rig.remote.queries == ["alpha", "beta"])
        await rig.remote.answer(1, with: reply(response([song("Beta song", "bbbbbbbbbb1")])))
        await settle()
        #expect(rig.model.results.map(\.title) == ["Beta song"])
        await rig.remote.answer(0, with: reply(response([song("Alpha song", "aaaaaaaaaa1")])))
        await settle()
        #expect(rig.model.results.map(\.title) == ["Beta song"], "the late answer for 'alpha' is dropped")
    }
    @Test func theOlderReplyArrivingFirstIsAlsoDropped() async throws {
        let rig = Rig(sources: false)
        rig.model.query = "alpha"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        rig.model.query = "beta"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(0, with: reply(response([song("Alpha song", "aaaaaaaaaa1")])))
        await settle()
        #expect(rig.model.results.isEmpty, "nothing is shown for 'alpha' while 'beta' is the query")
        await rig.remote.answer(1, with: reply(response([song("Beta song", "bbbbbbbbbb1")])))
        await settle()
        #expect(rig.model.results.map(\.title) == ["Beta song"])
    }
    @Test func aReplyFromAnotherAccountScopeIsDroppedThenTheNewScopeIsAsked() async throws {
        let rig = Rig(sources: false)
        rig.model.query = "cafe"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        rig.scopeToken = "account-b"
        await rig.remote.answer(0, with: reply(response([song("Account A song")]), generation: 1))
        await settle()
        #expect(rig.model.results.isEmpty, "an answer asked under account A is never shown under account B")
        #expect(await rig.remote.queries == ["cafe", "cafe"], "asked once more for the new scope")
        await rig.remote.answer(1, with: reply(response([song("Account B song", "bbbbbbbbbb1")]), generation: 2))
        await settle()
        #expect(rig.model.results.map(\.title) == ["Account B song"])
    }
    @Test func aSecondScopeMismatchIsReportedNotLooped() async throws {
        let rig = Rig(sources: false)
        rig.model.query = "cafe"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        rig.scopeToken = "account-b"
        await rig.remote.answer(0, with: reply(response([song("A")])))
        await settle()
        rig.scopeToken = "account-c"
        await rig.remote.answer(1, with: reply(response([song("B")])))
        await settle()
        #expect(await rig.remote.callCount == 2)
        #expect(rig.model.results.isEmpty)
        #expect(rig.model.remoteStatus == .failed(.unavailable))
    }
    @Test func theCoordinatorsStaleErrorIsTreatedAsAnAccountChange() async throws {
        let rig = Rig(sources: false)
        rig.model.query = "cafe"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.fail(0, with: MusicSessionError.stale)
        await settle()
        #expect(await rig.remote.callCount == 2)
        await rig.remote.answer(1, with: reply(response([song("Fresh")])))
        await settle()
        #expect(rig.model.results.map(\.title) == ["Fresh"])
    }
    @Test func accountChangedClearsItemFeedbackAndAsksAgainWithoutWaiting() async throws {
        let rig = Rig(sources: false)
        rig.model.query = "cafe"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(0, with: reply(response([song("Song")])))
        await settle()
        let result = try #require(rig.model.results.first)
        rig.box.playback = .needsSignIn
        await rig.model.perform(.play, on: result)
        #expect(rig.model.feedback[result.id] != nil)
        rig.scopeToken = "account-b"
        rig.model.accountChanged(); await settle()
        #expect(rig.model.feedback.isEmpty)
        #expect(await rig.remote.queries == ["cafe", "cafe"], "re-asked at once, no second quiet period")
    }
    @Test func aServiceFailureKeepsLocalResultsAndNamesTheFailure() async throws {
        let rig = Rig()
        rig.model.query = "caf"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.fail(0, with: MusicSessionError.network)
        await settle()
        #expect(rig.model.remoteStatus == .failed(.offline))
        #expect(rig.model.results.map(\.title) == ["Café Mix"])
        rig.model.retryRemote(); await settle()
        await rig.remote.fail(1, with: MusicSessionError.unrecognised)
        await settle()
        #expect(rig.model.remoteStatus == .failed(.unrecognised), "an unreadable answer is 'unrecognised', never an empty result")
        #expect(rig.model.results.map(\.title) == ["Café Mix"])
        rig.model.retryRemote(); await settle()
        await rig.remote.fail(2, with: MusicSessionError.rateLimited)
        await settle()
        #expect(rig.model.remoteStatus == .failed(.rateLimited))
    }
    @Test func returnInTheFieldAsksNowAndAnEmptyQueryCancelsEverything() async throws {
        let rig = Rig(sources: false)
        rig.model.query = "cafe"; await settle()
        rig.model.submit(); await settle()
        #expect(await rig.remote.queries == ["cafe"], "no quiet period when the person presses Return")
        rig.model.query = ""; await settle()
        await rig.remote.answer(0, with: reply(response([song("Late")])))
        await settle()
        #expect(rig.model.results.isEmpty && rig.model.remoteStatus == .idle)
        rig.model.query = "   "; await settle()
        rig.clock.advance(by: .seconds(1)); await settle()
        #expect(await rig.remote.callCount == 1, "whitespace is not a query")
    }
    @Test func typingNeverStartsPlaybackOrAnyOtherAction() async throws {
        let rig = Rig()
        for text in ["c", "ca", "caf", "cafe"] { rig.model.query = text; await settle() }
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(0, with: reply(response([song("Café del Mar")], top: song("Café del Mar", "aaaaaaaaaa1"))))
        await settle()
        #expect(rig.performer.played.isEmpty && rig.performer.copied.isEmpty)
        #expect(rig.model.feedback.isEmpty)
        #expect(rig.model.selection == nil, "results arriving do not select anything")
    }
    @Test func aQueryOver512BytesIsRefusedBeforeAnyRequest() async throws {
        let rig = Rig(sources: false)
        rig.model.query = String(repeating: "é", count: 300)
        await settle(); rig.clock.advance(by: .seconds(1)); await settle()
        #expect(rig.model.queryTooLong && rig.model.remoteStatus == .idle && rig.model.results.isEmpty)
        #expect(await rig.remote.callCount == 0)
    }
}
