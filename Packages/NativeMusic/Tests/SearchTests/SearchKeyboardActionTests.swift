import AccountSession
import Foundation
import Testing
@testable import Features

/// T10.4 — arrows/Return/Escape while editing, Space stays native, capability errors at the item.
@Suite @MainActor struct SearchKeyboardTests {
    @MainActor final class Rig {
        let clock = VirtualClock(), remote = ScriptedRemote(), performer = SpyPerformer(), box = SearchTimingTests.ScopeBox()
        let model: SearchModel
        init() {
            let remote = self.remote, box = self.box
            model = SearchModel(sources: [], remote: { try await remote.call($0) }, performer: performer, clock: clock,
                                accountScope: { box.value }, playback: { box.playback })
        }
        func load(_ fixture: String = "search-all-groups.json") async throws {
            model.query = "café"; await settle()
            clock.advance(by: .milliseconds(180)); await settle()
            await remote.answer(await remote.callCount - 1, with: reply(try parsedFixture(fixture))); await settle()
        }
        func result(_ title: String) throws -> SearchResult { try #require(model.results.first { $0.title == title }) }
    }
    @Test func arrowsMoveThroughResultsAndClampAtTheEnds() async throws {
        let rig = Rig(); try await rig.load()
        let ids = rig.model.results.map(\.id)
        #expect(rig.model.handle(.up) == .handled && rig.model.selection == ids.last, "Up with nothing selected starts from the end")
        rig.model.selection = nil
        #expect(rig.model.handle(.down) == .handled && rig.model.selection == ids.first)
        #expect(rig.model.handle(.down) == .handled && rig.model.selection == ids[1])
        for _ in 0..<(ids.count + 3) { _ = rig.model.handle(.down) }
        #expect(rig.model.selection == ids.last, "no wrap-around")
        #expect(rig.model.handle(.up) == .handled && rig.model.selection == ids[ids.count - 2])
    }
    @Test func arrowsWithNoResultsStayWithTheTextField() async throws {
        let rig = Rig()
        #expect(rig.model.handle(.down) == .passThrough && rig.model.handle(.up) == .passThrough, "the caret keeps its arrow keys")
    }
    @Test func spaceAndOtherKeysAreNeverConsumedEvenWithResultsAndASelection() async throws {
        let rig = Rig(); try await rig.load()
        rig.model.selection = rig.model.results.first?.id
        #expect(rig.model.handle(.space) == .passThrough, "Space types a space / triggers the system's own Space handling")
        #expect(rig.model.handle(.other) == .passThrough)
        #expect(rig.performer.played.isEmpty)
    }
    @Test func keysBelongToTheInputMethodWhileComposing() async throws {
        let rig = Rig(); try await rig.load()
        rig.model.selection = rig.model.results.first?.id
        for key in [SearchKey.down, .up, .returnKey, .escape, .space] { #expect(rig.model.handle(key, composing: true) == .passThrough) }
        #expect(rig.performer.played.isEmpty && rig.model.query == "café")
    }
    @Test func returnWithoutASelectionSearchesNowAndReturnOnAnEmptyFieldIsLeftAlone() async throws {
        let rig = Rig()
        #expect(rig.model.handle(.returnKey) == .passThrough)
        rig.model.query = "abc"; await settle()
        #expect(rig.model.handle(.returnKey) == .handled); await settle()
        #expect(await rig.remote.queries == ["abc"])
    }
    @Test func escapeClearsTheQueryThenLeavesTheNextOneToTheCaller() async throws {
        let rig = Rig(); try await rig.load()
        #expect(rig.model.handle(.escape) == .handled && rig.model.query.isEmpty && rig.model.results.isEmpty)
        #expect(rig.model.handle(.escape) == .passThrough, "with an empty field Escape belongs to the window/sheet")
    }
    @Test func returnOnASelectedSongPlaysItAsItsOwnRadioSeed() async throws {
        let rig = Rig(); try await rig.load()
        rig.model.selection = try rig.result("Noche Cálida").id
        #expect(rig.model.handle(.returnKey) == .handled); await settle()
        #expect(rig.performer.played.map(\.playlist) == ["RDAMVMaaaaaaaaaa3"] && rig.performer.played.map(\.title) == ["Noche Cálida"])
        #expect(rig.model.feedback[try rig.result("Noche Cálida").id] == .started)
    }
    @Test func playRoutesEachKindToItsPlayableTarget() async throws {
        let rig = Rig(); try await rig.load()
        for title in ["Synthetic Album", "Café Mix", "Cafe Talk", "Café del Mar (Official Video)", "Café del Mar"] { await rig.model.activate(try rig.result(title)) }
        #expect(rig.performer.played.map(\.playlist) == ["OLAK5uy_syntheticAlbum01", "PLsyntheticFeatured01", "PLsyntheticShow01", "RDAMVMbbbbbbbbbb1", "RDAMVMaaaaaaaaaa1"])
    }
    @Test func aKindWithNoPlayTargetReportsItAtTheItem() async throws {
        let rig = Rig(); try await rig.load()
        let episode = try rig.result("Brewing music")
        await rig.model.activate(episode)
        #expect(rig.model.feedback[episode.id] == .failed(String(localized: "Single episodes can’t be played from search yet.")))
        let artist = try rig.result("Synthetic Artist")
        await rig.model.activate(artist)
        #expect(rig.model.feedback[artist.id] == .failed(String(localized: "Opening this kind of result isn’t available yet.")))
        #expect(rig.performer.played.isEmpty, "nothing is guessed")
        #expect(rig.model.feedback.count == 2, "the other rows carry no error")
    }
    @Test func signedOutAndExpiredAccountsSeeTheReasonAtTheItemAndTheServiceIsNotCalled() async throws {
        let rig = Rig(); try await rig.load()
        let song = try rig.result("Noche Cálida")
        rig.box.playback = .needsSignIn
        await rig.model.activate(song)
        #expect(rig.model.feedback[song.id] == .failed(String(localized: "Sign in to YouTube Music to play.")))
        rig.box.playback = .sessionExpired
        await rig.model.activate(song)
        #expect(rig.model.feedback[song.id] == .failed(String(localized: "Your session ended. Sign in again to play.")))
        #expect(rig.performer.played.isEmpty)
        #expect(rig.model.offers(for: song).map(\.action) == [.play, .copyLink], "Copy Link needs no account")
        #expect(rig.model.offers(for: song).first?.isAvailable == false)
    }
    @Test func aPlayThatFailsOrGoesStaleIsReportedAndABusyOneIsQuiet() async throws {
        let rig = Rig(); try await rig.load()
        let song = try rig.result("Noche Cálida")
        rig.performer.outcome = .failed
        await rig.model.activate(song)
        #expect(rig.model.feedback[song.id] == .failed(String(localized: "YouTube Music couldn’t start this. Try Play again.")))
        rig.performer.outcome = .stale
        await rig.model.activate(song)
        #expect(rig.model.feedback[song.id] == .failed(String(localized: "Your account changed before this started. Try Play again.")), "never a silent no-op")
        rig.performer.outcome = .busy
        await rig.model.activate(song)
        #expect(rig.model.feedback[song.id] == nil, "a second press while a start is under way shows nothing; the first row says 'Starting…'")
    }
    @Test func aPlayFinishingAfterTheAccountChangedShowsNothingOnTheNewScreen() async throws {
        let rig = Rig(); try await rig.load()
        let song = try rig.result("Noche Cálida")
        rig.performer.holdPlay = true
        let pending = Task { await rig.model.activate(song) }
        await settle()
        #expect(rig.model.feedback[song.id] == .working)
        rig.box.value = "account-b"
        rig.performer.release()
        await pending.value
        #expect(rig.model.feedback[song.id] == nil)
    }
    @Test func copyLinkUsesTheKindsOwnMusicLink() async throws {
        let rig = Rig(); try await rig.load()
        for title in ["Noche Cálida", "Synthetic Album", "Café Mix", "Brewing music"] { await rig.model.perform(.copyLink, on: try rig.result(title)) }
        #expect(rig.performer.copied.map(\.absoluteString) == [
            "https://music.youtube.com/watch?v=aaaaaaaaaa3", "https://music.youtube.com/playlist?list=OLAK5uy_syntheticAlbum01",
            "https://music.youtube.com/playlist?list=PLsyntheticFeatured01", "https://music.youtube.com/watch?v=cccccccccc1"])
        #expect(rig.model.feedback[try rig.result("Noche Cálida").id] == .copied)
        await rig.model.perform(.copyLink, on: try rig.result("Synthetic Artist"))
        #expect(rig.performer.copied.last?.absoluteString == "https://music.youtube.com/channel/UCaaaaaaaaaaaaaaaaaaaaaa")
    }
    @Test func onlyRealActionsAreOffered() async throws {
        let rig = Rig(); try await rig.load()
        for result in rig.model.results {
            let offered = Set(rig.model.offers(for: result).map(\.action))
            #expect(offered.isSubset(of: [.play, .copyLink]), "no placeholder actions: \(result.title)")
        }
        #expect(SearchAction.allCases == [.play, .copyLink])
        #expect(rig.model.offers(for: try rig.result("Synthetic Artist")).map(\.action) == [.copyLink], "an artist has no Play, so none is shown")
    }
    @Test func aResultWithNoPlayTargetIsNeverGivenAGuessedOne() {
        let bare = SearchResult(kind: .album, title: "No ids", subtitle: nil, badges: [], target: SearchTarget(browseID: "MPREb_x"), fromService: true)
        #expect(SearchActionPlan.playlist(for: bare) == nil)
        #expect(SearchActionPlan.offers(for: bare, playback: .available).first?.unavailable == String(localized: "This result didn’t include anything to play."))
        let songNoID = SearchResult(kind: .song, title: "No id", subtitle: nil, badges: [], target: SearchTarget(), fromService: true)
        #expect(SearchActionPlan.playlist(for: songNoID) == nil && SearchActionPlan.link(for: songNoID) == nil)
    }
}

@Suite @MainActor struct CommandPaletteTests {
    @MainActor final class Rig {
        let clock = VirtualClock(), remote = ScriptedRemote(), performer = SpyPerformer()
        var ran: [String] = [], dismissed = 0
        var canGoBack = false
        var model: CommandPaletteModel!
        let search: SearchModel
        init() {
            let remote = self.remote
            search = SearchModel(sources: [], remote: { try await remote.call($0) }, performer: performer, clock: clock, playback: { .available })
            model = CommandPaletteModel(search: search, commands: commands(), dismiss: { [unowned self] in dismissed += 1 })
        }
        func commands() -> [PaletteCommand] {
            [PaletteCommand(id: "go-library", title: "Go to Library", symbol: "square.stack", keywords: ["Open"]) { [unowned self] in ran.append("library") },
             PaletteCommand(id: "go-search", title: "Go to Search", symbol: "magnifyingglass") { [unowned self] in ran.append("search") },
             PaletteCommand(id: "back", title: "Back", symbol: "chevron.left", unavailable: "There is nothing to go back to.") { [unowned self] in ran.append("back") }]
        }
    }
    @Test func commandsMatchTolerantlyAndTheBestCommandIsSelectedWhenTyping() async throws {
        let rig = Rig()
        #expect(rig.model.matchingCommands.map(\.id) == ["go-library", "go-search", "back"], "an empty field lists every command")
        rig.search.query = "libary"; await settle(); rig.model.queryChanged()
        #expect(rig.model.matchingCommands.map(\.id) == ["go-library"])
        #expect(rig.model.selection == "command:go-library")
    }
    @Test func returnRunsTheSelectedCommandAndClosesThePalette() async throws {
        let rig = Rig()
        rig.search.query = "go to lib"; await settle(); rig.model.queryChanged()
        #expect(rig.model.handle(.returnKey) == .handled)
        #expect(rig.ran == ["library"] && rig.dismissed == 1)
    }
    @Test func anUnavailableCommandExplainsItselfAtTheRowAndStaysOpen() async throws {
        let rig = Rig()
        rig.model.selection = "command:back"
        #expect(rig.model.handle(.returnKey) == .handled)
        #expect(rig.model.failure["command:back"] == "There is nothing to go back to." && rig.ran.isEmpty && rig.dismissed == 0)
    }
    @Test func typingNeverSelectsASearchResultSoAStrayReturnCannotPlay() async throws {
        let rig = Rig()
        rig.search.query = "café"; await settle(); rig.model.queryChanged()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(0, with: reply(try parsedFixture("search-all-groups.json"))); await settle()
        rig.model.queryChanged()
        #expect(rig.model.entries.contains { if case .result = $0 { true } else { false } })
        #expect(rig.model.selection == nil, "no command matched 'café', and results are never auto-selected")
        #expect(rig.model.handle(.returnKey) == .handled, "Return searches now instead")
        #expect(rig.performer.played.isEmpty)
    }
    @Test func arrowsCrossFromCommandsIntoResultsAndEscapeClearsThenCloses() async throws {
        let rig = Rig()
        rig.search.query = "go"; await settle(); rig.model.queryChanged()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(0, with: reply(response([song("Go song", "gggggggggg1")]))); await settle()
        let ids = rig.model.entries.map(\.id)
        #expect(ids == ["command:go-library", "command:go-search", "result:song:gggggggggg1"])
        #expect(rig.model.handle(.down) == .handled && rig.model.selection == "command:go-search")
        #expect(rig.model.handle(.down) == .handled && rig.model.selection == "result:song:gggggggggg1")
        #expect(rig.model.handle(.escape) == .handled && rig.search.query.isEmpty && rig.dismissed == 0)
        #expect(rig.model.handle(.escape) == .handled && rig.dismissed == 1)
        #expect(rig.model.handle(.space) == .passThrough)
    }
    @Test func returnOnASelectedResultPlaysItThroughTheSameActionPathAndClosesOnStart() async throws {
        let rig = Rig()
        rig.search.query = "go"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(0, with: reply(response([song("Go song", "gggggggggg1")]))); await settle()
        rig.model.selection = "result:song:gggggggggg1"
        #expect(rig.model.handle(.returnKey) == .handled); await settle()
        #expect(rig.performer.played.map(\.playlist) == ["RDAMVMgggggggggg1"])
    }
}
