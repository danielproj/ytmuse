import Testing
import Foundation
import Features
@testable import AppShell

/// W09-F2: per-entry restoration of the production pages. The store reads and writes the CURRENT entry of the existing session and
/// drives the existing `ScrollRestoration` policy; these tests pin the contract the pages rely on.
@Suite(.serialized) @MainActor struct PageRestorationTests {
    private func store(_ navigation: BrowserNavigation, generation: UInt64 = 1, includesViewState: Bool = false) -> NavigationPageStore {
        NavigationPageStore(navigation: navigation, generation: generation, keyIncludesViewState: includesViewState)
    }
    private func sample(_ offset: Double, maximum: Double = 800, height: Double = 1300) -> PageScrollSample { .init(offset: offset, maximum: maximum, contentHeight: height) }

    // MARK: Memory

    @Test func aVisitWithNothingSavedRecallsNothingAndTheFirstRecordIsKept() {
        let navigation = BrowserNavigation(); navigation.open(.library)
        let store = store(navigation)
        #expect(store.recall() == nil)
        store.remember(PageMemory(query: "bjork", values: ["kind": "albums"]), for: store.token)
        #expect(store.recall() == PageMemory(query: "bjork", values: ["kind": "albums"]))
        // An empty record is still a record: a visit that was shown with nothing typed must not adopt the next page's values.
        navigation.open(.history); let history = self.store(navigation)
        history.remember(PageMemory(), for: history.token)
        #expect(history.recall() == PageMemory())
    }
    @Test func twoVisitsToTheSameDestinationAreTwoEntriesWithTheirOwnValues() {
        // As in the app, every visit has its own view and therefore its own store, bound to the entry it was made for.
        let navigation = BrowserNavigation(); navigation.open(.library)
        let first = store(navigation)
        first.remember(PageMemory(query: "one", selection: ["a"], values: ["kind": "songs", "sort": "titleAscending"]), for: first.token)
        navigation.open(.history)
        navigation.open(.library)   // a second Library entry, not the first
        let second = store(navigation)
        #expect(navigation.session.entries.count == 4 && second.recall() == nil)
        second.remember(PageMemory(query: "two", selection: ["b"], values: ["kind": "albums", "sort": "service"]), for: second.token)
        navigation.back(); navigation.back()
        #expect(store(navigation).recall() == PageMemory(query: "one", selection: ["a"], values: ["kind": "songs", "sort": "titleAscending"]))
        navigation.forward(); navigation.forward()
        #expect(store(navigation).recall() == PageMemory(query: "two", selection: ["b"], values: ["kind": "albums", "sort": "service"]))
    }
    @Test func aWriteAddressedToAnotherEntryGenerationOwnerOrWindowIsDropped() throws {
        let navigation = BrowserNavigation(); navigation.open(.downloads)
        let leaving = store(navigation)
        let old = leaving.token
        navigation.open(.library)                                  // the entry changed under the writer
        leaving.remember(PageMemory(values: ["filter": "downloadedOnly"]), for: old)
        #expect(leaving.recall() == nil && navigation.session.current.pageValues == nil, "a store whose entry is no longer on screen writes nothing, anywhere")
        // The fences below are for a store whose entry IS on screen.
        let store = store(navigation)
        let current = store.token
        store.generation = 2                                       // an older authority generation can no longer write
        store.remember(PageMemory(query: "stale"), for: current)
        #expect(navigation.session.current.query.isEmpty && store.recall() == nil)
        store.generation = 1
        navigation.session.owner = WindowOwner(try consumerAccount().context)   // another account owns the window now
        store.remember(PageMemory(query: "other account"), for: current)
        #expect(navigation.session.current.query.isEmpty)
        let ownerToken = store.token
        navigation.session.windowID = UUID()
        store.remember(PageMemory(query: "other window"), for: ownerToken)
        #expect(navigation.session.current.query.isEmpty)
        navigation.session.historyEpoch = 9
        store.remember(PageMemory(query: "other epoch"), for: ownerToken)
        #expect(navigation.session.current.query.isEmpty && navigation.session.current.pageValues == nil)
    }
    @Test func aRecordIsBoundedAndOnlyChangesAreWritten() {
        let navigation = BrowserNavigation(); navigation.open(.library)
        let store = store(navigation)
        store.remember(PageMemory(query: String(repeating: "x", count: 5_000), selection: Set((0..<60_000).map { "id-\($0)" }), values: Dictionary(uniqueKeysWithValues: (0..<80).map { ("k\($0)", String(repeating: "v", count: 400)) })), for: store.token)
        #expect(navigation.session.current.query.count == 1024 && navigation.session.current.selection.count == 50_000)
        #expect(navigation.session.current.pageValues?.isEmpty == true, "values over the entry's bounds are refused whole, never truncated into a different value")
        #expect((try? BrowserSession.restore(navigation.session.encoded())) != nil, "what the store writes must survive the session's own validation")
        let revision = navigation.revision
        store.remember(store.recall()!, for: store.token)
        #expect(navigation.revision == revision, "an unchanged record is not a session revision (window restoration persists every revision)")
    }
    @Test func entriesCarryTheirPageValuesThroughEncodingAndOldRecordsStillDecode() throws {
        var session = BrowserSession(); session.open(.library)
        session.current.pageValues = ["kind": "albums", "layout": "grid"]; session.current.query = "q"
        #expect(try BrowserSession.restore(session.encoded()) == session)
        // A record written before page values existed has no such key.
        let legacy = BrowserEntry(destination: .history)
        let data = try PropertyListEncoder().encode(legacy)
        var object = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        object["pageValues"] = nil
        let stripped = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        #expect(try PropertyListDecoder().decode(BrowserEntry.self, from: stripped).pageValues == nil)
        session.current.pageValues = Dictionary(uniqueKeysWithValues: (0..<33).map { ("k\($0)", "v") })
        #expect(throws: (any Error).self) { try BrowserSession.restore(session.encoded()) }
        session.current.pageValues = ["kind": String(repeating: "v", count: 257)]
        #expect(throws: (any Error).self) { try BrowserSession.restore(session.encoded()) }
    }

    // MARK: A store belongs to its entry (W09-F2b, U4)

    @Test func aViewThatIsLeavingCannotRunItsMemoryProtocolAgainstTheEntryThatReplacedIt() {
        // Downloads is on screen with a recorded filter; Search is opened with Command-F. The Downloads view is still there for a moment and its
        // task fires again. It used to read and write the CURRENT entry, so it recorded its filter into the new Search entry and the new Search
        // view then "restored" that filter and opened with an empty field.
        let navigation = BrowserNavigation(); navigation.open(.downloads)
        let downloads = store(navigation)
        downloads.remember(PageMemory(values: ["filter": "downloadedOnly"]), for: downloads.token)
        let tokenBefore = downloads.token
        navigation.open(.search)
        let search = store(navigation)
        #expect(downloads.token == tokenBefore, "the leaving view's token does not change under it (its task would fire again)")
        let sync = PageMemorySync()
        sync.begin(store: downloads, capture: { PageMemory(values: ["filter": "all"]) }, apply: { _ in }, fresh: nil)
        sync.changed(PageMemory(values: ["filter": "all"]), store: downloads)
        #expect(navigation.session.current.pageValues == nil && search.recall() == nil, "the Search entry has recorded nothing, so its view starts fresh and keeps its text")
        #expect(downloads.recall() == PageMemory(values: ["filter": "downloadedOnly"]), "the leaving view still reads its own entry")
        search.remember(PageMemory(query: "cafe", values: ["scope": "all"]), for: search.token)
        #expect(search.recall()?.query == "cafe" && downloads.recall()?.query == nil)
    }
    @Test func aLeavingViewsScrollReadingsNeverReachTheEntryThatReplacedIt() {
        let navigation = BrowserNavigation(); navigation.open(.history); navigation.session.current.scrollOffset = 300
        let history = store(navigation), container = UUID()
        _ = history.arm(container: container, now: 0)
        navigation.open(.library)
        #expect(history.sample(sample(0, maximum: 100, height: 700), token: history.token, container: container, now: 0.1) == .stale)
        #expect(navigation.session.current.scrollOffset == 0, "the Library entry keeps its own offset")
        #expect(!history.expire(token: history.token, container: container))
        history.rewind()
        #expect(navigation.session.entries.first { $0.destination == .history }?.scrollOffset == 300, "a leaving view cannot rewrite its own entry either")
    }

    // MARK: Scroll

    @Test func contentThatLoadsLateIsRestoredOnceAndThenFollowsThePerson() {
        let navigation = BrowserNavigation(); navigation.open(.library); navigation.session.current.scrollOffset = 600
        let store = store(navigation), container = UUID()
        #expect(store.arm(container: container, now: 0) == 600)
        let token = store.token
        // Only a short page exists at first: the target is held back, never acknowledged.
        #expect(store.sample(sample(0, maximum: 100, height: 700), token: token, container: container, now: 0.1) == .scroll(100))
        #expect(store.sample(sample(100, maximum: 100, height: 700), token: token, container: container, now: 0.2) == .hold)
        #expect(navigation.session.current.scrollOffset == 600, "a clamp must not overwrite the stored offset")
        #expect(store.sample(sample(100, maximum: 900, height: 1500), token: token, container: container, now: 0.4) == .scroll(600))
        #expect(store.sample(sample(600, maximum: 900, height: 1500), token: token, container: container, now: 0.5) == .persist)
        #expect(store.sample(sample(640, maximum: 900, height: 1500), token: token, container: container, now: 0.6) == .persist, "a restored page is never pinned")
        #expect(navigation.session.current.scrollOffset == 640)
    }
    @Test func aPageThatNeverGrowsGivesUpAfterTwoSecondsAndNeverJumpsAgain() {
        let navigation = BrowserNavigation(); navigation.open(.history); navigation.session.current.scrollOffset = 900
        let store = store(navigation), container = UUID()
        _ = store.arm(container: container, now: 0); let token = store.token
        #expect(store.sample(sample(0, maximum: 100, height: 700), token: token, container: container, now: 0.1) == .scroll(100))
        #expect(store.sample(sample(100, maximum: 100, height: 700), token: token, container: container, now: 2.5) == .persist, "after the window the container is the person's")
        #expect(store.sample(sample(100, maximum: 5_000, height: 5_600), token: token, container: container, now: 2.6) == .persist, "late growth does not reissue the restoration")
        #expect(!store.expire(token: token, container: container), "the expiry of an already settled restoration records nothing")
    }
    @Test func theExpiryRecordsWhereTheContainerIsWhenNothingElseDid() {
        let navigation = BrowserNavigation(); navigation.open(.history); navigation.session.current.scrollOffset = 900
        let store = store(navigation), container = UUID()
        _ = store.arm(container: container, now: 0); let token = store.token
        _ = store.sample(sample(40, maximum: 100, height: 700), token: token, container: container, now: 0.1)
        #expect(store.expire(token: token, container: container))
        #expect(navigation.session.current.scrollOffset == 40)
    }
    @Test func anExpiryAddressedToAnotherEntryOrContainerRecordsNothing() {
        let navigation = BrowserNavigation(); navigation.open(.history); navigation.session.current.scrollOffset = 900
        let store = store(navigation), container = UUID()
        _ = store.arm(container: container, now: 0); let token = store.token
        _ = store.sample(sample(40, maximum: 100, height: 700), token: token, container: container, now: 0.1)
        #expect(!store.expire(token: token, container: UUID()), "a container that did not arm last cannot end it")
        store.generation = 2
        #expect(!store.expire(token: token, container: container), "an older generation's expiry is dropped")
        store.generation = 1
        #expect(navigation.session.current.scrollOffset == 900, "neither wrote the entry")
        #expect(store.expire(token: token, container: container) && navigation.session.current.scrollOffset == 40)
    }
    @Test func anEntryStoredAtRestIsNeverPulledBackToTheTop() {
        let navigation = BrowserNavigation(); navigation.open(.library)
        let store = store(navigation), container = UUID()
        #expect(store.arm(container: container, now: 0) == 0)
        #expect(store.sample(sample(205), token: store.token, container: container, now: 0.1) == .persist, "a later reading elsewhere is the person's")
        #expect(navigation.session.current.scrollOffset == 205)
    }
    @Test func theFirstUserScrollEndsRestorationForGood() {
        let navigation = BrowserNavigation(); navigation.open(.downloads); navigation.session.current.scrollOffset = 600
        let store = store(navigation), container = UUID()
        _ = store.arm(container: container, now: 0); let token = store.token
        store.userScrolled(container: container)
        #expect(store.sample(sample(30, maximum: 900, height: 1500), token: token, container: container, now: 0.1) == .persist)
        #expect(navigation.session.current.scrollOffset == 30)
    }
    @Test func aReadingForAnotherEntryOrGenerationIsStaleAndWritesNothing() {
        let navigation = BrowserNavigation(); navigation.open(.library); navigation.session.current.scrollOffset = 300
        let store = store(navigation), container = UUID()
        _ = store.arm(container: container, now: 0); let armed = store.token
        navigation.open(.history)
        #expect(store.sample(sample(300), token: armed, container: container, now: 0.1) == .stale)
        #expect(navigation.session.current.scrollOffset == 0, "the new entry keeps its own offset")
        navigation.back()
        store.generation = 2
        _ = store.arm(container: container, now: 0); let regenerated = store.token
        store.generation = 3   // the account changed again while the container still held the earlier token
        #expect(store.sample(sample(300), token: regenerated, container: container, now: 0.1) == .stale)
        #expect(navigation.session.current.scrollOffset == 300)
    }
    @Test func aNewContainerSupersedesTheOneItReplacesAndAnOldOneCannotSilenceIt() {
        let navigation = BrowserNavigation(); navigation.open(.library); navigation.session.current.scrollOffset = 200
        let store = store(navigation), first = UUID(), second = UUID()
        _ = store.arm(container: first, now: 0)
        _ = store.arm(container: second, now: 0.1); let token = store.token   // another kind's list replaced the first container
        store.disappear(container: first)                                     // arrives after the successor armed
        // The replaced container is asked FIRST: if it were heard it would use up the restoration's first reading and the successor would hold.
        #expect(store.sample(sample(0, maximum: 900, height: 1500), token: token, container: first, now: 0.2) == .hold, "a replaced container is not heard")
        #expect(store.sample(sample(0, maximum: 900, height: 1500), token: token, container: second, now: 0.2) == .scroll(200))
        store.userScrolled(container: first)                                  // nor can it end the successor's restoration
        #expect(store.sample(sample(0, maximum: 1000, height: 1600), token: token, container: second, now: 0.3) == .scroll(200))
    }
    @Test func rewindForgetsTheOffsetOfContentThatWasReplaced() {
        let navigation = BrowserNavigation(); navigation.open(.library); navigation.session.current.scrollOffset = 700
        let store = store(navigation), container = UUID()
        _ = store.arm(container: container, now: 0)
        store.rewind()
        #expect(navigation.session.current.scrollOffset == 0)
        #expect(store.arm(container: UUID(), now: 1) == 0, "the replacement container starts at the top")
    }
    @Test func aProductionVisitIsNotRestartedByItsOwnQueryOrFilterButThePlaceholderPageIs() {
        let navigation = BrowserNavigation(); navigation.open(.library)
        let production = store(navigation), placeholder = store(navigation, includesViewState: true)
        let before = (production.token, placeholder.token)
        navigation.session.current.query = "typed"; navigation.session.current.pageValues = ["sort": "artist"]
        #expect(production.token == before.0, "typing in a page's search field is the same visit")
        #expect(placeholder.token != before.1, "the placeholder collection keeps its W09 key")
    }

    @Test func aScrollCommandCountsFromTheContentOriginNotFromRest() {
        #expect(PageScrollSample.position(forOffset: 0, topInset: 24) == -24, "rest is the inset above the content origin")
        #expect(PageScrollSample.position(forOffset: 300, topInset: 24) == 276)
        #expect(PageScrollSample.position(forOffset: 300, topInset: 0) == 300)
    }

    // MARK: Every production destination type

    struct Destination: Sendable, CustomTestStringConvertible {
        let name: String, destination: BrowserDestination, item: NativeItemRoute?
        var testDescription: String { name }
    }
    nonisolated static let destinations: [Destination] = {
        func route(_ kind: NativeItemKind, _ id: String) -> NativeItemRoute { try! NativeItemRoute(kind: kind, identifier: id) }
        return [
            Destination(name: "library", destination: .library, item: nil), Destination(name: "history", destination: .history, item: nil),
            Destination(name: "downloads", destination: .downloads, item: nil), Destination(name: "search", destination: .search, item: nil),
            Destination(name: "home", destination: .home, item: nil), Destination(name: "explore", destination: .explore, item: nil),
            Destination(name: "album", destination: .explore, item: route(.album, "MPREb_album1")), Destination(name: "artist", destination: .explore, item: route(.artist, "UCartist1")),
            Destination(name: "playlist", destination: .library, item: route(.playlist, "PLplaylist1")), Destination(name: "podcast", destination: .explore, item: route(.podcast, "MPSPPLshow1")),
            Destination(name: "episode", destination: .explore, item: route(.episode, "episode1")), Destination(name: "song", destination: .explore, item: route(.song, "song1")),
            Destination(name: "category", destination: .explore, item: route(.category, "FEmusic_charts")),
        ]
    }()
    @Test(arguments: destinations)
    func everyDestinationTypeKeepsItsOwnScrollOffsetAndValuesPerVisit(_ target: Destination) {
        let navigation = BrowserNavigation()
        navigation.open(target.destination, item: target.item)
        let first = store(navigation)
        navigation.session.current.scrollOffset = 400
        first.remember(PageMemory(query: "first", values: ["v": "1"]), for: first.token)
        navigation.open(.queue)
        navigation.open(target.destination, item: target.item)             // the same page again is a second visit
        let second = store(navigation)
        #expect(navigation.session.current.scrollOffset == 0 && second.recall() == nil)
        navigation.session.current.scrollOffset = 90
        second.remember(PageMemory(query: "second", values: ["v": "2"]), for: second.token)
        navigation.back(); navigation.back()
        let back = store(navigation)
        #expect(back.arm(container: UUID(), now: 0) == 400 && back.recall() == PageMemory(query: "first", values: ["v": "1"]))
        navigation.forward(); navigation.forward()
        let forward = store(navigation)
        #expect(forward.arm(container: UUID(), now: 0) == 90 && forward.recall() == PageMemory(query: "second", values: ["v": "2"]))
    }

    // MARK: The pages are wired to it

    /// What each production page must install. A page that stops calling these silently stops restoring, and nothing else notices
    /// until a person goes Back, so the wiring is pinned at its source.
    static let wiring: [(file: String, tokens: [String: Int])] = [
        ("Features/Library/LibraryView.swift", [".restoresScroll()": 2, ".remembersPage(identity: identity": 1, ".restoresByIdentity(": 1, ".identityItem(": 1]),
        ("Features/History/HistoryView.swift", [".restoresScroll()": 1]),
        ("Features/Downloads/DownloadsView.swift", [".remembersPage(identity: identity": 1, ".restoresByIdentity(": 1, ".identityItem(": 10]),
        ("Features/Search/SearchView.swift", [".restoresScroll()": 1, ".remembersPage(": 1]),
        // The shelves and the page heading are restoration targets; the heading must be registered with the restorer, or a visit left at the top could not return there.
        ("Features/Catalog/CatalogPageView.swift", [".remembersPage(identity: identity": 1, ".restoresByIdentity(": 1, ".identityItem(": 2, "identity.setItems([headerID] + registration.order": 1, ".scrollPosition(id: $model.anchor, anchor: .top)": 1]),
        ("Features/Catalog/CatalogComponents.swift", [".identityItem(": 1, "CatalogRows.drawn(": 1, "CatalogRows.rowItem(": 1]),
        ("Features/Catalog/CatalogPageView.swift", ["CatalogRows.registration(": 1, "IdentityRestorer(rule: .coveringTop, requiresRealisation: true)": 1]),
        ("Features/PageRestoration/IdentityRestoration.swift", [".onAppear { tracker.realisation(id, true) }": 1, "restoration.flatMap { $0.memory.isCurrent ? $0.memory.token : nil }": 1]),
        ("Features/PageRestoration/IdentityRestoration.swift", ["scroll: { proxy.scrollTo($0, anchor: .top) }": 1]),
        ("Features/Library/LibraryView.swift", ["surface.beginFreshVisit(opensOn: opensOn)": 1]),
        ("Features/Search/SearchView.swift", ["model.beginFreshVisit()": 1]),
        ("Features/CatalogDetails/CatalogDetailViews.swift", [".restoresScroll()": 1]),
        ("Features/Podcasts/PodcastViews.swift", [".restoresScroll()": 1]),
        ("AppShell/BrowserDestinationView.swift", [".restoresScroll(": 1, "PageRestoration(memory: pageStore, scroll: pageStore)": 1, "PageRestoration(memory: collectionStore, scroll: collectionStore)": 1]),
    ]
    @Test func everyProductionPageInstallsItsRestoration() throws {
        var sources = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { sources.deleteLastPathComponent() }
        sources.appendPathComponent("Sources")
        #expect(Self.wiring.count == 14)
        for (file, tokens) in Self.wiring {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for (token, count) in tokens {
                #expect(text.components(separatedBy: token).count - 1 == count, "\(file) must contain \(token) exactly \(count) time(s)")
            }
        }
    }
    @Test func theLibraryRewindsItsScrollWhenTheCollectionChanges() throws {
        var sources = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { sources.deleteLastPathComponent() }
        let text = try String(contentsOf: sources.appendingPathComponent("Sources/Features/Library/LibraryView.swift"), encoding: .utf8)
        #expect(text.components(separatedBy: "restoration?.scroll.rewind()").count - 1 == 2, "choosing another collection (or Downloaded only) starts that list at the top")
    }
}

/// TH1: the W09-F2b critic asked whether catalog scrolling writes enough session updates to re-render the window while a UI test scrolls it. Every write to
/// the session is a navigation revision, and the window shell reads the session. This pins the write rate the page store has: one revision for each item that
/// reaches the top of the page, never one per scroll frame, so a full Home scroll of N shelves is N revisions in total. (Measured the other way, by the UI
/// test, a 240 px step crosses about one shelf, so the UI test's scroll causes about one shell refresh per 0.3 s step: real, small, and not per frame.)
extension PageRestorationTests {
    @Test func scrollingAPageWritesTheSessionOncePerItemThatReachesTheTopAndNeverOncePerFrame() {
        let navigation = BrowserNavigation(); navigation.open(.library)
        let store = store(navigation)
        let identity = IdentityRestorer(rule: .coveringTop, requiresRealisation: true)
        let shelves = (0..<8).map { "shelf\($0)" }
        identity.setItems(shelves)
        let before = navigation.revision
        for frame in 0..<240 {                       // 30 frames of scrolling per shelf
            let top = frame / 30
            if frame % 30 == 0, top > 0 { identity.visibility(shelves[top - 1], visible: false, full: false); identity.visibility(shelves[top - 1], visible: false, full: true) }
            identity.visibility(shelves[top], visible: true, full: false)
            store.remember(PageMemory(values: identity.top.map { ["topItem": $0] } ?? [:]), for: store.token)
        }
        #expect(identity.top == "shelf7")
        #expect(navigation.revision - before == 8, "one revision per shelf that reached the top, not one per frame (\(navigation.revision - before))")
    }
}
