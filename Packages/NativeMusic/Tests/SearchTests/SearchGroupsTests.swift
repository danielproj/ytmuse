import AccountSession
import Foundation
import Testing
@testable import Features

/// T10.3 — grouped Top/Songs/Albums/Artists/Playlists/Videos/Podcasts/Episodes, Library and
/// Uploads scopes, and badges that survive merging and scope changes.
@Suite @MainActor struct SearchGroupsTests {
    @MainActor final class Rig {
        let clock = VirtualClock(), remote = ScriptedRemote(), performer = SpyPerformer()
        let model: SearchModel
        init(library: [(String, String)] = [("PLsyntheticFeatured01", "Café Mix"), ("PLonlylocal", "Café Local Only")]) {
            let remote = self.remote
            model = SearchModel(sources: [FakeLibrary(library)], remote: { try await remote.call($0) }, performer: performer, clock: clock)
        }
        func search(_ text: String, answer fixture: String? = nil) async throws {
            model.query = text; await settle()
            clock.advance(by: .milliseconds(180)); await settle()
            if let fixture { await remote.answer(await remote.callCount - 1, with: reply(try parsedFixture(fixture))); await settle() }
        }
    }
    @Test func groupsAppearInTheSpecifiedOrderWithEveryKind() async throws {
        let rig = Rig()
        try await rig.search("café", answer: "search-all-groups.json")
        let order = rig.model.sections.map(\.group)
        #expect(order == [.top, .songs, .albums, .artists, .playlists, .videos, .podcasts, .episodes])
        #expect(SearchGroup.allCases == order, "presentation order is the declared order")
        let byGroup = Dictionary(uniqueKeysWithValues: rig.model.sections.map { ($0.group, $0.results.map(\.title)) })
        #expect(byGroup[.top] == ["Café del Mar"])
        #expect(byGroup[.songs] == ["Café del Mar (Radio Edit)", "Noche Cálida"], "the top result is not repeated in Songs")
        #expect(byGroup[.albums] == ["Synthetic Album"] && byGroup[.artists] == ["Synthetic Artist"])
        #expect(byGroup[.videos] == ["Café del Mar (Official Video)"] && byGroup[.podcasts] == ["Cafe Talk"] && byGroup[.episodes] == ["Brewing music"])
    }
    @Test func badgesCarryTheirMeaning() async throws {
        let rig = Rig()
        try await rig.search("café", answer: "search-all-groups.json")
        let all = Dictionary(uniqueKeysWithValues: rig.model.results.map { ($0.title, $0) })
        #expect(all["Noche Cálida"]?.badges == [.service, .explicit])
        #expect(all["Café del Mar"]?.badges == [.service])
        #expect(all["Café Local Only"]?.badges == [.library], "a local-only result has no service badge")
        #expect(SearchBadge.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty }, "no badge is conveyed by colour alone")
    }
    @Test func theSameItemFromTheLibraryAndTheServiceIsOneRowWithBothBadges() async throws {
        let rig = Rig()
        try await rig.search("café", answer: "search-all-groups.json")
        let featured = rig.model.results.filter { $0.target.playlistID == "PLsyntheticFeatured01" }
        #expect(featured.count == 1)
        #expect(featured.first?.badges == [.library, .service])
        #expect(featured.first?.fromService == true, "the service's description wins")
        #expect(rig.model.results.filter { $0.title == "Café Mix" }.count == 1, "the service names it 'Café Mix' too, so there is no duplicate local row")
    }
    @Test func localResultsStayPutWhenServiceResultsArrive() async throws {
        let rig = Rig()
        rig.model.query = "café"; await settle()
        let before = rig.model.sections.flatMap(\.results).map(\.title)
        #expect(before == ["Café Local Only", "Café Mix"], "equal quality sorts alphabetically")
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(0, with: reply(try parsedFixture("search-all-groups.json"))); await settle()
        let playlists = try #require(rig.model.sections.first { $0.group == .playlists }).results.map(\.title)
        #expect(Array(playlists.prefix(2)) == ["Café Local Only", "Café Mix"], "local first, in their earlier order; the service's other playlists follow")
        #expect(playlists.last == "My cafe list")
    }
    @Test func libraryScopeIsLocalOnlyAndKeepsItsBadges() async throws {
        let rig = Rig()
        try await rig.search("café", answer: "search-all-groups.json")
        rig.model.scope = .library; await settle()
        #expect(rig.model.results.map(\.title) == ["Café Local Only", "Café Mix"])
        #expect(rig.model.results.allSatisfy { $0.badges == [.library] })
        #expect(rig.model.remoteStatus == .localOnly && rig.model.scopeNotice != nil)
        rig.clock.advance(by: .seconds(1)); await settle()
        #expect(await rig.remote.callCount == 1, "no further service request in the Library scope")
        rig.model.scope = .all; await settle()
        #expect(rig.model.remoteStatus == .waiting, "switching back asks the service again after the quiet period")
        #expect(rig.model.results.first { $0.title == "Café Mix" }?.badges.contains(.library) == true)
    }
    @Test func uploadsScopeIsHonestlyEmptyAndAsksNothing() async throws {
        let rig = Rig()
        rig.model.scope = .uploads
        rig.model.query = "café"; await settle()
        rig.clock.advance(by: .seconds(1)); await settle()
        let calls = await rig.remote.callCount
        #expect(rig.model.sections.isEmpty && calls == 0)
        #expect(rig.model.scopeNotice == String(localized: "Uploads aren’t connected yet, so there is nothing to search here."))
    }
    @Test func aServiceStatementThatItHasNoResultsIsNotAFailure() async throws {
        let rig = Rig(library: [])
        try await rig.search("zzzzzz", answer: "search-no-results.json")
        guard case .loaded(let info) = rig.model.remoteStatus else { Issue.record("expected loaded"); return }
        #expect(info.noResults && info.complete == false && rig.model.results.isEmpty)
    }
    @Test func unreadAndUnshownRowsAreReportedNotHidden() async throws {
        let rig = Rig(library: [])
        try await rig.search("café", answer: "search-all-groups.json")
        guard case .loaded(let info) = rig.model.remoteStatus else { Issue.record("expected loaded"); return }
        #expect(info.skippedRows == 1 && info.unsupportedRows == 1 && !info.complete && info.signedIn)
    }
    @Test func theCapOnEachGroupBoundsWhatIsShown() async throws {
        let rig = Rig(library: [])
        let many = (0..<80).map { song("Song \($0)", String(format: "id%09d", $0)) }
        rig.model.query = "song"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(0, with: reply(response(many))); await settle()
        #expect(rig.model.sections.first?.results.count == 50)
    }
}
