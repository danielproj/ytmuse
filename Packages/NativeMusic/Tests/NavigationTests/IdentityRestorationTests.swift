import Testing
import Foundation
@testable import Features

/// W09-F2 rework 1: the ONE identity-restore mechanism (Library rows, Downloads items, catalog rows and shelves) and the memory protocol, pinned
/// without a window. The earlier version had these rules written three times in views, and a mutation that disabled any of them survived.
@Suite @MainActor struct IdentityRestorationTests {
    private let a: AnyHashable = "entry-A", c: AnyHashable = "entry-C"

    // MARK: The decision

    @Test func itWaitsForTheTargetThenScrollsOnceAfterTheLayoutDelay() {
        var restoration = IdentityRestoration(targets: ["row-90"], token: a, now: 0)
        var present: Set<String> = []
        #expect(restoration.offer(exists: present.contains, token: a, now: 0.1) == .wait, "the row has not arrived")
        present = ["row-90"]
        #expect(restoration.offer(exists: present.contains, token: a, now: 0.5) == .wait, "it exists now; the list is given time to lay it out")
        #expect(restoration.offer(exists: present.contains, token: a, now: 0.5 + IdentityRestoration.layoutDelay) == .scroll("row-90"))
        #expect(restoration.offer(exists: present.contains, token: a, now: 0.7) == .finished, "once, never twice")
    }
    @Test func aRowThatNeverArrivesFallsBackToItsShelfAfterTheWindowAndThenStops() {
        var restoration = IdentityRestoration(targets: ["list|row-90", "list"], token: a, now: 0)
        let present: Set<String> = ["list"]
        #expect(restoration.offer(exists: present.contains, token: a, now: 1.9) == .wait)
        #expect(restoration.offer(exists: present.contains, token: a, now: IdentityRestoration.window + 0.01) == .scroll("list"))
        #expect(restoration.offer(exists: ["list", "list|row-90"].contains, token: a, now: 2.5) == .finished, "late arrival does not scroll a second time")
    }
    @Test func aRowThatAppearsAndVanishesIsBoundedByTheSameWindow() {
        var restoration = IdentityRestoration(targets: ["list|r90", "list"], token: a, now: 0)
        var present: Set<String> = ["list", "list|r90"]
        #expect(restoration.offer(exists: present.contains, token: a, now: 1.0) == .wait, "seen; the layout delay has not passed")
        present = ["list"]   // a refresh or a filter dropped it before the delay passed
        #expect(restoration.offer(exists: present.contains, token: a, now: 1.02) == .wait, "waited for again, within the same bound")
        #expect(restoration.offer(exists: present.contains, token: a, now: IdentityRestoration.window + 0.01) == .scroll("list"), "the bound ends it: the shelf")
        #expect(restoration.offer(exists: present.contains, token: a, now: 3) == .finished)
    }
    @Test func aRowThatArrivedInTimeIsStillScrolledToWhenTheBoundFallsInsideTheLayoutDelay() {
        var restoration = IdentityRestoration(targets: ["list|r90", "list"], token: a, now: 0)
        let present: Set<String> = ["list", "list|r90"]
        #expect(restoration.offer(exists: present.contains, token: a, now: 1.99) == .wait)
        #expect(restoration.offer(exists: present.contains, token: a, now: 2.01) == .scroll("list|r90"))
    }
    @Test func aRowThatFirstAppearsAfterTheBoundIsNotScrolledTo() {
        var restoration = IdentityRestoration(targets: ["list|r90", "list"], token: a, now: 0)
        #expect(restoration.offer(exists: ["list", "list|r90"].contains, token: a, now: 2.5) == .scroll("list"), "too late for the row: the shelf, and nothing after")
        #expect(restoration.offer(exists: ["list", "list|r90"].contains, token: a, now: 2.6) == .finished)
    }
    @Test func theDecisionStepsTowardAnUnrealisedTargetAtMostOncePerStepDelayAndNeverTheSameStepTwice() {
        var restoration = IdentityRestoration(targets: ["list|r90", "list"], token: a, now: 0)
        let none: (String) -> Bool = { _ in false }
        #expect(restoration.offer(exists: none, approach: { _ in "list|r17" }, token: a, now: 0.0) == .approach("list|r17"))
        #expect(restoration.offer(exists: none, approach: { _ in "list|r33" }, token: a, now: 0.01) == .wait, "the step has not been given time to realise anything")
        #expect(restoration.offer(exists: none, approach: { _ in "list|r17" }, token: a, now: 0.1) == .wait, "no progress: the same step is not repeated")
        #expect(restoration.offer(exists: none, approach: { _ in "list|r33" }, token: a, now: 0.2) == .approach("list|r33"))
    }
    @Test func aScrollThatDidNotTakeEffectIsRepeatedAndOnceItHasItIsNotRepeated() {
        var restoration = IdentityRestoration(targets: ["development"], token: a, now: 0)
        let present: (String) -> Bool = { _ in true }
        var onTop = false
        #expect(restoration.offer(exists: present, isOnTop: { _ in onTop }, token: a, now: 0.0) == .wait)
        #expect(restoration.offer(exists: present, isOnTop: { _ in onTop }, token: a, now: IdentityRestoration.layoutDelay) == .scroll("development"))
        #expect(restoration.offer(exists: present, isOnTop: { _ in onTop }, token: a, now: 0.1) == .wait, "the page is given a moment to show the effect")
        #expect(restoration.offer(exists: present, isOnTop: { _ in onTop }, token: a, now: 0.1 + IdentityRestoration.verifyDelay) == .scroll("development"), "it is not at the top: the scroll was lost, repeat it")
        onTop = true
        #expect(restoration.offer(exists: present, isOnTop: { _ in onTop }, token: a, now: 0.5) == .finished, "it took effect: done, and no third scroll")
    }
    @Test func aScrollThatNeverTakesEffectIsAttemptedExactlyFourTimesAndNoMore() {
        // Pinned against the literal 4, not against `IdentityRestoration.maxAttempts`: a test that compares with the constant passes for any value
        // of it (raising it to 100 survived). One initial scroll and three repeats, spaced `verifyDelay` apart, then it stops.
        var restoration = IdentityRestoration(targets: ["development"], token: a, now: 0)
        var scrolls: [Double] = [], now = 0.0
        while now < 1.9 {      // inside the 2 s window, so only the attempt limit can stop it
            if restoration.offer(exists: { _ in true }, isOnTop: { _ in false }, token: a, now: now) == .scroll("development") { scrolls.append(now) }
            now += 0.01
        }
        #expect(scrolls.count == 4, "four attempts in all (the first scroll and three repeats), however long the page stays wrong: got \(scrolls.count)")
        #expect(zip(scrolls, scrolls.dropFirst()).allSatisfy { $1 - $0 >= 0.15 - 0.0001 }, "each repeat waits for the page to show an effect first")
        #expect(restoration.finished, "and it is finished, not waiting")
    }
    @Test func aScrollThatNeverTakesEffectIsNeverRepeatedBeyondTheWindowEither() {
        var restoration = IdentityRestoration(targets: ["development"], token: a, now: 0)
        var scrolls = 0, now = 0.0
        while now < 5 {
            if restoration.offer(exists: { _ in true }, isOnTop: { _ in false }, token: a, now: now) == .scroll("development") { scrolls += 1 }
            now += 0.05
        }
        #expect(scrolls >= 2 && scrolls <= 4 && restoration.finished)
    }
    @Test func withNothingToFallBackToItGivesUpWithoutScrolling() {
        var restoration = IdentityRestoration(targets: ["row-90"], token: a, now: 0)
        #expect(restoration.offer(exists: { _ in false }, token: a, now: IdentityRestoration.window + 0.01) == .finished)
    }
    @Test func aCancelEndsItWithoutAScroll() {
        var restoration = IdentityRestoration(targets: ["row-90"], token: a, now: 0)
        restoration.cancel()
        #expect(restoration.offer(exists: { _ in true }, token: a, now: 1) == .finished)
    }
    @Test func aTargetArmedForOneEntryIsNeverAppliedInAnother() {
        var restoration = IdentityRestoration(targets: ["row-90"], token: a, now: 0)
        #expect(restoration.offer(exists: { _ in true }, token: c, now: 1) == .finished, "the row exists, but the entry on screen is not the one it was armed for")
        #expect(restoration.offer(exists: { _ in true }, token: a, now: 2) == .finished, "and it stays finished")
    }

    // MARK: What the page records

    @Test func theFirstFullyVisibleItemIsRecordedAndAPartlyVisibleOneIsTheFallback() {
        let page = IdentityRestorer()
        page.setItems(["shelf", "shelf|r1", "shelf|r2", "shelf|r3"], parents: ["shelf|r1": "shelf", "shelf|r2": "shelf", "shelf|r3": "shelf"])
        page.visibility("shelf", visible: true, full: false)
        #expect(page.top == "shelf", "nothing is fully visible: the shelf that covers the top")
        page.visibility("shelf|r2", visible: true, full: false); page.visibility("shelf|r2", visible: true, full: true)
        page.visibility("shelf|r3", visible: true, full: true)
        #expect(page.top == "shelf|r2" && page.topParent == "shelf", "the first fully visible row, with its shelf")
        page.visibility("shelf|r2", visible: false, full: true)
        #expect(page.top == "shelf|r3")
    }
    @Test func whileARestoreIsPendingTheRecordIsNotOverwritten() {
        let page = IdentityRestorer()
        page.setItems(["a", "b", "c"])
        page.arm(top: "c", parent: nil, token: a, now: 0)
        page.visibility("a", visible: true, full: true)
        #expect(page.top == "c", "the page still shows its top; recording that would erase the item being returned to")
    }
    @Test func aFreshVisitHasNothingPendingAndNothingRecorded() async {
        let page = IdentityRestorer()
        page.setItems(["a", "b"])
        page.arm(top: "b", parent: nil, token: a, now: 0)
        page.reset()
        #expect(page.top == nil && !page.isPending)
        var scrolled: [String] = [], clock = 1.0, pauses = 0
        await page.drive(token: { self.a }, scroll: { scrolled.append($0) }, now: { clock }, pause: { pauses += 1; clock += 0.1; if pauses > 100 { page.cancel() } })
        #expect(scrolled.isEmpty && pauses == 0, "a pending target left from an earlier visit is gone")
    }

    @Test func aPageOfShelvesRecordsTheShelfCoveringTheTopNotTheNextOneThatIsFullyVisible() {
        // Home: New releases is cut by the top edge, Featured playlists is entirely on screen below it. The person is reading New releases.
        let shelves = IdentityRestorer(rule: .coveringTop)
        shelves.setItems(["quick", "new", "featured", "daily"])
        shelves.visibility("new", visible: true, full: false)
        shelves.visibility("featured", visible: true, full: false); shelves.visibility("featured", visible: true, full: true)
        #expect(shelves.top == "new", "the shelf covering the top (Back used to land one shelf below)")
        // The rule for lists of similar rows (Library, Downloads) is still the first fully visible one.
        let rows = IdentityRestorer()
        rows.setItems(["quick", "new", "featured", "daily"])
        rows.visibility("new", visible: true, full: false)
        rows.visibility("featured", visible: true, full: false); rows.visibility("featured", visible: true, full: true)
        #expect(rows.top == "featured")
    }
    @Test func aListShelfRecordsItsFirstFullyVisibleRowWithItsShelfAsParent() {
        let page = IdentityRestorer(rule: .coveringTop)
        let rowIDs = (1...5).map { "list|r\($0)" }
        page.setItems(["list"] + rowIDs, parents: Dictionary(uniqueKeysWithValues: rowIDs.map { ($0, "list") }))
        page.visibility("list", visible: true, full: false)
        page.visibility("list|r2", visible: true, full: false)          // cut by the top edge
        page.visibility("list|r3", visible: true, full: false); page.visibility("list|r3", visible: true, full: true)
        #expect(page.top == "list|r3" && page.topParent == "list")
    }

    // MARK: A nested lazy container

    /// A lazy container nested in another one: scrolling to a row that is NOT realised does nothing (what a trace of the long development
    /// playlist showed); scrolling to a realised row realises the next screenful after it.
    @MainActor final class LazyShelf {
        let page: IdentityRestorer
        let rowCount: Int, window = 16
        var realised: Set<String> = [], scrolls: [String] = [], onScreen: Set<String> = []
        init(page: IdentityRestorer, rowCount: Int) {
            self.page = page; self.rowCount = rowCount
            page.setItems(["shelf"] + (1...rowCount).map { "shelf|r\($0)" }, parents: Dictionary(uniqueKeysWithValues: (1...rowCount).map { ("shelf|r\($0)", "shelf") }))
            realise(from: 1)
        }
        func realise(from first: Int) {
            for n in first...min(rowCount, first + window) { realised.insert("shelf|r\(n)"); page.realisation("shelf|r\(n)", true) }
        }
        func scroll(_ id: String) {
            scrolls.append(id)
            guard id == "shelf" || realised.contains(id), let n = Int(id.split(separator: "r").last ?? "") else { return }
            realise(from: n)
            // What is on screen now is the row scrolled to; what was on screen before no longer is.
            for old in onScreen { page.visibility(old, visible: false, full: false); page.visibility(old, visible: false, full: true) }
            onScreen = [id]
            page.visibility("shelf", visible: true, full: false)
            page.visibility(id, visible: true, full: false); page.visibility(id, visible: true, full: true)
        }
    }
    @Test func aRowInANestedLazyShelfIsSteppedTowardUntilItIsRealisedAndOnlyThenScrolledTo() async {
        let page = IdentityRestorer(rule: .coveringTop, requiresRealisation: true)
        let shelf = LazyShelf(page: page, rowCount: 150)
        page.arm(top: "shelf|r65", parent: "shelf", token: a, now: 0)
        var clock = 0.0, pauses = 0
        await page.drive(token: { self.a }, scroll: { shelf.scroll($0) }, now: { clock }, pause: { pauses += 1; clock += 0.07; if pauses > 100 { page.cancel() } })
        #expect(shelf.scrolls.last == "shelf|r65" && shelf.realised.contains("shelf|r65"), "the page ends on the remembered row")
        #expect(shelf.scrolls.count > 2, "the row was not realised at first: the driver stepped toward it, one realised screenful at a time")
        #expect(shelf.scrolls.dropLast().allSatisfy { $0 != "shelf|r65" }, "and scrolled to the row itself only once it was realised")
        #expect(pauses <= 100 && clock <= IdentityRestoration.window, "inside the same 2 s bound")
    }
    @Test func aContainerThatNeverRealisesTheRowFallsBackToTheShelfWithinTheWindow() async {
        let page = IdentityRestorer(rule: .coveringTop, requiresRealisation: true)
        let shelf = LazyShelf(page: page, rowCount: 150)
        page.arm(top: "shelf|r65", parent: "shelf", token: a, now: 0)
        var clock = 0.0, pauses = 0
        // This container ignores every scroll: nothing is ever realised beyond the first rows.
        await page.drive(token: { self.a }, scroll: { shelf.scrolls.append($0) }, now: { clock }, pause: { pauses += 1; clock += 0.07; if pauses > 100 { page.cancel() } })
        #expect(shelf.scrolls.last == "shelf", "the bound ends the stepping and the shelf is the fallback")
        #expect(pauses <= 100 && clock <= IdentityRestoration.window + 0.2)
    }
    @Test func aPageWhoseRowsAreNotInANestedLazyContainerStillScrollsStraightToTheRow() async {
        let page = IdentityRestorer()   // Library and Downloads: presence is enough
        page.setItems(["a", "b", "c"])
        page.arm(top: "c", parent: nil, token: a, now: 0)
        var scrolled: [String] = [], clock = 0.0, pauses = 0
        await page.drive(token: { self.a }, scroll: { scrolled.append($0); self.landOnTop($0, page) }, now: { clock }, pause: { pauses += 1; clock += 0.07; if pauses > 100 { page.cancel() } })
        #expect(scrolled == ["c"])
    }

    /// What the page reports when a scroll to `id` has taken effect: the item is the first one fully on screen.
    private func landOnTop(_ id: String, _ page: IdentityRestorer) {
        page.visibility(id, visible: true, full: false); page.visibility(id, visible: true, full: true)
    }

    // MARK: Driving it

    @Test func theDriverScrollsOnceWhenTheRowArrivesLate() async {
        let page = IdentityRestorer()
        page.setItems(["list"])
        page.arm(top: "list|r90", parent: "list", token: a, now: 0)
        var clock = 0.0, scrolled: [String] = [], pauses = 0
        // The safety valve: a driver that never scrolls must FAIL this test, not wait for ever.
        await page.drive(token: { self.a }, scroll: { scrolled.append($0); self.landOnTop($0, page) }, now: { clock },
                         pause: { pauses += 1; clock += 0.01; if pauses == 5 { page.setItems(["list", "list|r90"]) }; if pauses > 200 { page.cancel() } })
        #expect(scrolled == ["list|r90"], "waited for the row, then scrolled to it once")
        #expect(pauses >= 5 && pauses <= 200)
        #expect(page.top == "list|r90" && !page.isPending)
    }
    @Test func aFirstScrollThatTheContainerIgnoresIsRepeatedUntilItLands() async {
        // Downloads, restored 77 ms after the page appeared: scrollTo(development) was a no-op and the page stayed at the top for good.
        let page = IdentityRestorer()
        page.setItems(["header", "capability", "development", "storage"])
        page.visibility("header", visible: true, full: true); page.visibility("capability", visible: true, full: true)
        page.arm(top: "development", parent: nil, token: a, now: 0)
        var scrolled: [String] = [], clock = 0.0, pauses = 0
        await page.drive(token: { self.a }, scroll: { id in
            scrolled.append(id)
            if scrolled.count == 2 { page.visibility("header", visible: false, full: true); page.visibility("capability", visible: false, full: true); self.landOnTop(id, page) }
        }, now: { clock }, pause: { pauses += 1; clock += 0.05; if pauses > 200 { page.cancel() } })
        #expect(scrolled == ["development", "development"], "the first scroll had no effect, the second landed, and there was no third")
        #expect(page.top == "development" && !page.isPending)
    }
    @Test func theDriverNeverMovesAnEntryItWasNotArmedFor() async {
        let page = IdentityRestorer()
        page.setItems(["r90"])
        page.arm(top: "r90", parent: nil, token: a, now: 0)   // armed on entry A; the leftover reaches entry C
        var scrolled: [String] = [], clock = 1.0, pauses = 0
        // A ticking clock and a safety valve: a defective driver must FAIL this test, not wait for ever.
        await page.drive(token: { self.c }, scroll: { scrolled.append($0) }, now: { clock }, pause: { pauses += 1; clock += 0.1; if pauses > 100 { page.cancel() } })
        #expect(scrolled.isEmpty && !page.isPending && pauses <= 100)
    }
    @Test func theDriverStopsWhenThePageIsLeftOrTheEntryIsGone() async {
        let page = IdentityRestorer()
        page.setItems(["r90"])
        page.arm(top: "r90", parent: nil, token: a, now: 0)
        var scrolled: [String] = []
        await page.drive(token: { nil }, scroll: { scrolled.append($0) }, now: { 1 }, pause: { page.cancel() })
        #expect(scrolled.isEmpty && !page.isPending, "no entry on screen")
        page.arm(top: "r90", parent: nil, token: a, now: 0)
        page.cancel()
        var clock = 1.0, pauses = 0
        await page.drive(token: { self.a }, scroll: { scrolled.append($0) }, now: { clock }, pause: { pauses += 1; clock += 0.1; if pauses > 100 { page.cancel() } })
        #expect(scrolled.isEmpty && pauses == 0, "the person scrolled, or the page disappeared")
    }
}

/// The memory protocol of one visit.
@Suite @MainActor struct PageMemorySyncTests {
    @MainActor final class Store: PageMemoryStore {
        var token: AnyHashable = "entry-C"
        var saved: PageMemory?
        var remembered: [PageMemory] = []
        func recall() -> PageMemory? { saved }
        func remember(_ memory: PageMemory, for token: AnyHashable) { if token == self.token { remembered.append(memory) } }
    }
    @Test func aFreshVisitRecordsWhatThePageShowsAfterItsFreshStart() {
        let store = Store(), sync = PageMemorySync()
        var steps: [String] = []
        sync.begin(store: store, capture: { steps.append("capture"); return PageMemory(query: "q") }, apply: { _ in steps.append("apply") }, fresh: { steps.append("fresh") })
        #expect(steps == ["fresh", "capture"] && store.remembered == [PageMemory(query: "q")], "the new visit starts clean, then records")
    }
    @Test func aRecordedVisitAppliesItsValuesAndWritesNothingBack() {
        let store = Store(); store.saved = PageMemory(query: "saved")
        let sync = PageMemorySync()
        var applied: [PageMemory] = []
        sync.begin(store: store, capture: { PageMemory(query: "the previous entry's") }, apply: { applied.append($0) }, fresh: { Issue.record("not fresh") })
        #expect(applied == [PageMemory(query: "saved")] && store.remembered.isEmpty, "the page's own values are not written over the saved ones")
    }
    @Test func nothingIsWrittenBeforeTheEntrysValuesWereApplied() {
        let store = Store(), sync = PageMemorySync()
        sync.changed(PageMemory(query: "still the previous entry's"), store: store)
        #expect(store.remembered.isEmpty)
        sync.begin(store: store, capture: { PageMemory() }, apply: { _ in }, fresh: nil)
        store.remembered = []
        sync.changed(PageMemory(query: "now"), store: store)
        #expect(store.remembered == [PageMemory(query: "now")])
    }
    @Test func aChangeAfterTheEntryMovedOnIsDropped() {
        let store = Store(), sync = PageMemorySync()
        sync.begin(store: store, capture: { PageMemory() }, apply: { _ in }, fresh: nil)
        store.remembered = []
        store.token = "entry-D"
        sync.changed(PageMemory(query: "late"), store: store)
        #expect(store.remembered.isEmpty)
    }
}
