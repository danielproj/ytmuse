import AccountSession
import Foundation
import Testing
@testable import AppShell
@testable import Features

/// W09-F2: the Library visit remembers its collection, search, order, layout, selection and "Downloaded only"; two visits are two entries.
@Suite @MainActor struct LibraryPageRestorationTests {
    private func surface() -> LibrarySurface {
        var models: [MusicLibraryKind: LibraryCollectionModel] = [:]
        for kind in MusicLibraryKind.allCases {
            models[kind] = LibraryCollectionModel(source: LibrarySource(kind: kind), reader: { _ in throw MusicSessionError.policy }, continuer: { _ in throw MusicSessionError.policy })
        }
        return LibrarySurface(models: models,
                              history: HistoryModel(remote: LibraryCollectionModel(source: .history, reader: { _ in throw MusicSessionError.policy }, continuer: { _ in throw MusicSessionError.policy }), store: nil, policy: nil, accountKey: { nil }),
                              ledger: LibraryWriteLedger(writer: { _ in throw MusicSessionError.policy }), performer: nil, playback: { .available })
    }
    @Test func aVisitRecordsEverythingTheLibraryShowsAndPutsItBack() {
        let library = surface()
        library.selectedKind = .albums
        library.model.query = "björk"; library.model.sort = .titleDescending; library.model.layout = .grid; library.model.selection = ["a", "b"]
        let saved = library.pageMemory
        #expect(saved.query == "björk" && saved.selection == ["a", "b"])
        #expect(saved.values == ["kind": "albums", "downloadedOnly": "0", "sort": "titleDescending", "layout": "grid"])
        // Put the albums collection back to defaults too: restoring must change something, or this would pass without restoring.
        library.model.query = ""; library.model.sort = .service; library.model.layout = .list; library.model.selection = []
        library.selectedKind = .songs; library.model.query = "x"
        library.restorePage(saved)
        #expect(library.selectedKind == .albums && library.model.query == "björk" && library.model.sort == .titleDescending && library.model.layout == .grid && library.model.selection == ["a", "b"])
    }
    @Test func twoLibraryVisitsKeepTheirOwnCollectionsSearchesAndSelections() {
        let library = surface(), navigation = BrowserNavigation()
        func visit() -> NavigationPageStore { NavigationPageStore(navigation: navigation, generation: 1, keyIncludesViewState: false) }   // one store per view, bound to its entry
        navigation.open(.library)
        let first = visit()
        library.selectedKind = .albums; library.model.query = "one"; library.model.selection = ["a"]
        first.remember(library.pageMemory, for: first.token)
        navigation.open(.history)
        navigation.open(.library)
        let second = visit()
        #expect(second.recall() == nil, "a new visit has recorded nothing")
        library.beginFreshVisit()
        library.selectedKind = .artists; library.model.query = "two"; library.model.selection = ["z"]
        second.remember(library.pageMemory, for: second.token)
        navigation.back(); navigation.back()
        library.restorePage(visit().recall()!)
        #expect(library.selectedKind == .albums && library.model.query == "one" && library.model.selection == ["a"])
        navigation.forward(); navigation.forward()
        library.restorePage(visit().recall()!)
        #expect(library.selectedKind == .artists && library.model.query == "two" && library.model.selection == ["z"])
    }
    @Test func aFreshVisitClearsTheTransientStateAndKeepsTheDurableSettings() {
        let library = surface()
        library.selectedKind = .albums
        library.model.query = "björk"; library.model.selection = ["a", "b"]; library.model.sort = .titleDescending; library.model.layout = .grid
        library.beginFreshVisit()
        #expect(library.model.query.isEmpty && library.model.selection.isEmpty, "a new visit starts with no search text and nothing selected")
        #expect(library.selectedKind == .albums && library.model.sort == .titleDescending && library.model.layout == .grid, "kind, order and layout are durable settings")
        library.beginFreshVisit(opensOn: .podcasts)
        #expect(library.selectedKind == .podcasts && !library.showsDownloadedOnly, "Podcasts opens on its own collection")
    }
    @Test func valuesTheBuildDoesNotKnowFallBackToDefaultsAndDownloadedOnlyNeedsTheDownloads() {
        let library = surface()
        library.restorePage(PageMemory(query: "q", values: ["kind": "from-a-newer-version", "sort": "newest", "layout": "mosaic", "downloadedOnly": "1"]))
        #expect(library.model.sort == .service && !library.showsDownloadedOnly, "no kept-items section exists here, so it cannot be restored")
        #expect(library.model.query == "q")
    }
}
