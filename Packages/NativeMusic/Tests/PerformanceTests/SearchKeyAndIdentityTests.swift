import AccountSession
import Foundation
import Testing
@testable import Features
@testable import AppShell

/// The folded search key against the reference rule on adversarial scripts (the critic's list), and the list-identity stamp of `IdentityRestorer`.
@Suite("Search keys and list identity")
@MainActor
struct SearchKeyAndIdentityTests {
    private static let titles = ["Straße", "STRASSE", "ﬁnal ﬂight", "İstanbul", "ISTANBUL", "ıssız", "Ελληνικά ΣΟΦΟΣ σοφός", "Ёлка", "елка", "Йога", "кино",
                                 "नमस्ते कि", "한국어 노래", "カフェ", "ｶﾌｪ", "ｃａｆｅ", "Cafe\u{301}", "café", "Ångström", "A\u{30A}ngstro\u{308}m", "😀 smile", "Ǆemal", "Ⅻ chapter", "x²"]
    private static let queries = ["strasse", "straße", "ss", "fi", "ﬁ", "flight", "istanbul", "ı", "i", "σοφος", "ΣΟΦΟΣ", "ς", "елка", "ё", "иога", "й", "к", "न", "कि", "ि",
                                  "한", "かふぇ", "カフェ", "cafe", "café", "angstrom", "å", "😀", "dž", "xii", "12", "x2", "2"]
    private func mismatches() -> [(title: String, query: String)] {
        var found: [(title: String, query: String)] = []
        for (n, title) in Self.titles.enumerated() {
            let entry = LibraryEntry(id: "t\(n)", ordinal: n, item: MusicCatalogItem(kind: .song, title: title, videoID: "v\(n)"), section: nil, repeats: false)
            for query in Self.queries {
                let reference = LibraryCollectionModel.matches(entry, query)
                let fast = query.split(whereSeparator: \.isWhitespace).map { LibraryEntry.fold(String($0)) }.allSatisfy { entry.matches(folded: $0) }
                if reference != fast { found.append((title, query)) }
            }
        }
        return found
    }
    @Test func theFoldedSearchAgreesWithTheReferenceExceptForTheDocumentedPathologicalQueries() {
        let found = mismatches()
        // Documented on `LibraryEntry.fold`: a lone Devanagari vowel sign and the ligature typed as the query. Anything else is a regression.
        let documented = found.filter { $0.query == "ि" || $0.query == "ﬁ" }
        #expect(found.count == documented.count, "undocumented differences: \(found.filter { pair in !documented.contains { $0 == pair } })")
        #expect(found.count <= 6, "the documented differences stay few (\(found.count))")
        // The ordinary scripts the product is used in really are covered by the comparison.
        #expect(Self.titles.count * Self.queries.count - found.count > 700)
    }

    @Test func listIdentityIsRebuiltOnlyWhenTheOwnerOrGenerationChanges() {
        let restorer = IdentityRestorer()
        let first = ObjectIdentifier(restorer), second = ObjectIdentifier(LibraryCollectionModelStub.shared)
        var builds = 0
        func ids(_ values: [String]) -> () -> [String] { { builds += 1; return values } }
        restorer.setItems(owner: first, generation: 1, ids(["a", "b"]))
        #expect(restorer.listedItems == ["a", "b"] && builds == 1)
        restorer.setItems(owner: first, generation: 1, ids(["x"]))
        #expect(restorer.listedItems == ["a", "b"] && builds == 1, "the same owner and generation does not rebuild")
        restorer.setItems(owner: first, generation: 2, ids(["c"]))
        #expect(restorer.listedItems == ["c"] && builds == 2, "a new generation rebuilds")
        restorer.setItems(owner: second, generation: 2, ids(["d"]))
        #expect(restorer.listedItems == ["d"] && builds == 3, "another owner with the same generation rebuilds")
        restorer.setItems(["plain"])
        #expect(restorer.listedItems == ["plain"])
        restorer.setItems(owner: second, generation: 2, ids(["e"]))
        #expect(restorer.listedItems == ["e"] && builds == 4, "a plain setItems forgets the stamp, so the next stamped call rebuilds")
    }
}
@MainActor private final class LibraryCollectionModelStub { static let shared = LibraryCollectionModelStub() }
