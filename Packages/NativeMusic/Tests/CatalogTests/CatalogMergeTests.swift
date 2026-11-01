import AccountSession
import Features
import Foundation
import Testing

/// T11.2 (pure part): a refresh never reshuffles what is on screen.
@Suite struct CatalogMergeTests {
    private func titles(_ shelf: MusicShelf) -> [String] { shelf.items.map(\.title) }

    @Test func existingShelvesKeepTheirOrderWhateverTheServiceNowSends() {
        let current = [shelf("A", ["a1", "a2"]), shelf("B", ["b1"]), shelf("C", ["c1"])]
        let fresh = [shelf("C", ["c1"]), shelf("B", ["b1"]), shelf("A", ["a1", "a2"])]
        #expect(CatalogMerge.refreshed(current: current, fresh: fresh, anchor: nil).map(\.key) == ["A", "B", "C"])
    }
    @Test func newShelvesAreAppendedAfterWhatWasVisible() {
        let current = [shelf("A", ["a1"]), shelf("B", ["b1"])]
        let fresh = [shelf("N", ["n1"]), shelf("A", ["a1"]), shelf("B", ["b1"]), shelf("M", ["m1"])]
        #expect(CatalogMerge.refreshed(current: current, fresh: fresh, anchor: nil).map(\.key) == ["A", "B", "N", "M"])
    }
    @Test func aShelfTheServiceDroppedGoesUnlessItIsTheAnchor() {
        let current = [shelf("A", ["a1"]), shelf("B", ["b1"]), shelf("C", ["c1"])]
        let fresh = [shelf("A", ["a1"])]
        #expect(CatalogMerge.refreshed(current: current, fresh: fresh, anchor: nil).map(\.key) == ["A"])
        #expect(CatalogMerge.refreshed(current: current, fresh: fresh, anchor: "B").map(\.key) == ["A", "B"])
        // The kept anchor is unchanged, not replaced by anything.
        #expect(CatalogMerge.refreshed(current: current, fresh: fresh, anchor: "B")[1] == current[1])
    }
    @Test func entriesKeepTheirOrderNewOnesAppendRemovedOnesGo() {
        let current = [shelf("A", ["a1", "a2", "a3"])]
        let fresh = [shelf("A", ["a3", "new", "a1"])]
        let merged = CatalogMerge.refreshed(current: current, fresh: fresh, anchor: nil)
        #expect(titles(merged[0]) == ["a1", "a3", "new"])
    }
    @Test func updatedEntriesReplaceTheOldOnesInPlace() {
        var old = shelf("A", ["a1", "a2"])
        let renamed = MusicCatalogItem(kind: .album, title: "a2", details: ["new detail"], browseID: old.items[1].browseID)
        let fresh = MusicShelf(key: "A", title: "A", layout: .carousel, items: [old.items[0], renamed])
        old = CatalogMerge.refreshed(current: [old], fresh: [fresh], anchor: nil)[0]
        #expect(old.items[1].details == ["new detail"])
    }
    @Test func aShelfExtendedByPaginationKeepsItsLoadedTailAndItsToken() {
        var current = shelf("A", ["a1", "a2", "a3", "a4"], continuation: "next-page")
        current.continuation = "token-after-page-2"
        let fresh = shelf("A", ["a1", "a2"], continuation: "token-after-page-1")
        let merged = CatalogMerge.refreshed(current: [current], fresh: [fresh], anchor: nil, extended: ["A"])[0]
        #expect(titles(merged) == ["a1", "a2", "a3", "a4"] && merged.continuation == "token-after-page-2")
        // Without pagination the fresh first page and its token win.
        let plain = CatalogMerge.refreshed(current: [current], fresh: [fresh], anchor: nil)[0]
        #expect(titles(plain) == ["a1", "a2"] && plain.continuation == "token-after-page-1")
    }
    @Test func duplicateEntriesInAFreshShelfAreNotListedTwice() {
        let dup = MusicCatalogItem(kind: .album, title: "x", browseID: "MPREb_x")
        let fresh = MusicShelf(key: "A", title: "A", layout: .carousel, items: [dup, dup])
        #expect(CatalogMerge.refreshed(current: [shelf("A", [])], fresh: [fresh], anchor: nil)[0].items.count == 1)
    }
    @Test func appendedDropsEntriesAlreadyListed() {
        let base = shelf("A", ["a1", "a2"])
        let more = [base.items[1]] + shelf("X", ["a3"]).items
        let result = CatalogMerge.appended(more, to: base)
        #expect(titles(result.shelf) == ["a1", "a2", "a3"] && result.duplicates == 1)
    }
    @Test func theSamePlaylistOccurrenceIsOneEntryButARepeatedSongIsTwo() {
        let a = MusicCatalogItem(kind: .song, title: "S", videoID: "aaaaaaaaaaa", occurrenceID: "occ1")
        let b = MusicCatalogItem(kind: .song, title: "S", videoID: "aaaaaaaaaaa", occurrenceID: "occ2")
        #expect(a.id != b.id)
        let base = MusicShelf(key: "T", title: nil, layout: .list, items: [a])
        #expect(CatalogMerge.appended([a, b], to: base).shelf.items.count == 2)
        #expect(CatalogMerge.appended([a], to: base).duplicates == 1)
    }
}
