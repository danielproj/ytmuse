import AccountSession
import Features
import Foundation
import Testing
import YouTubeMusicAdapter

/// Edge cases the captures don't show, on `synthetic-test-only` fixtures (`Fixtures/W11`) whose entries are copied from real rows.
@Suite struct BrowseEdgeCaseTests {
    @Test func syntheticManifestIsLabelledAndHashed() throws {
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent("W11/manifest.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["mode"] as? String == "synthetic-test-only" && object["live_eligible"] as? Bool == false)
        for file in try #require(object["files"] as? [[String: Any]]) {
            let name = try #require(file["path"] as? String)
            #expect(sha256(try Data(contentsOf: fixturesRoot().appendingPathComponent("W11/" + name))) == file["sha256"] as? String, "\(name)")
        }
    }

    // MARK: Unknown variants, repeats, unreadable and unsupported entries are counted, never silently dropped

    @Test func unknownVariantsAreCountedAndNothingIsFabricated() throws {
        let page = try MusicBrowseParser.parse(try syntheticData("unknown-variants-page.json"))
        let a = page.accounting
        #expect(a.consistent)
        // Shelf 1: 3 real albums + 1 repeat + 1 unknown renderer + 1 unreadable (empty title) + 1 profile (unsupported page type).
        #expect(a.items == 7 + 2)
        #expect(a.duplicates == 1 && a.unsupported == 2 && a.skipped == 1 && a.classified == 3 + 2)
        #expect(a.unsupportedSections == 1 && a.unsupportedSectionNames == ["musicFutureShelfRenderer"])
        #expect(page.shelves.count == 2)
        #expect(page.shelves[0].items.count == 3)
        // Two shelves with the same title get distinct, stable keys.
        #expect(Set(page.shelves.map(\.key)).count == 2 && page.shelves[1].key.hasSuffix("#2"))
        // Nothing was invented for the entries that could not be read.
        #expect(page.shelves.flatMap(\.items).allSatisfy { !$0.title.isEmpty && $0.browseID != nil })
    }

    @Test func accountingFailsWhenARendererIsDropped() throws {
        // The oracle: the parser's item count must equal an independent walk. A parser that skipped counting would not.
        let root = try syntheticData("unknown-variants-page.json")
        let page = try MusicBrowseParser.parse(root)
        // The oracle counts known entry renderers; the unknown renderer is the one entry it can't see, and the parser counts it as unsupported.
        #expect(page.accounting.items == countEntryRenderers(in: root) + 1)
    }

    /// A card the service gives only a page for (no play button, no watch endpoint): the episode's id is the page id minus its prefix.
    @Test func anEpisodeKnownOnlyByItsPageIsStillReadFromThePageId() throws {
        var root = try realCapture(.explore)
        func strip(_ node: Any) -> Any {
            if var map = node as? [String: Any] {
                map["thumbnailOverlay"] = nil
                return map.mapValues(strip)
            }
            if let list = node as? [Any] { return list.map(strip) }
            return node
        }
        root = strip(root) as! [String: Any]
        let page = try MusicBrowseParser.parse(root)
        let episodes = page.shelves.flatMap(\.items).filter { $0.kind == .episode }
        #expect(!episodes.isEmpty)
        for episode in episodes {
            #expect(episode.browseID?.hasPrefix("MPED") == true && "MPED" + (episode.videoID ?? "") == episode.browseID)
        }
        #expect(page.accounting.consistent && page.accounting.skipped == 0)
    }

    // MARK: Adverse

    @Test(arguments: ["adverse-error.json", "adverse-no-container.json", "adverse-unreadable-only.json", "adverse-unknown-sections-only.json"])
    func adversePagesAreUnrecognisedNeverEmpty(name: String) throws {
        #expect(throws: MusicSessionError.unrecognised) { try MusicBrowseParser.parse(try syntheticData(name)) }
    }
    @Test func unknownContinuationEnvelopeIsUnrecognised() throws {
        #expect(throws: MusicSessionError.unrecognised) { try MusicBrowseParser.parseContinuation(try syntheticData("adverse-continuation-unknown.json")) }
        #expect(throws: MusicSessionError.unrecognised) { try MusicBrowseParser.parseContinuation(try syntheticData("adverse-error.json")) }
    }

    // MARK: Continuations (lazy pagination)

    @Test func playlistShelfContinuationCarriesItemsAndTheNextToken() throws {
        let page = try MusicBrowseParser.parseContinuation(try syntheticData("continuation-playlist-shelf.json"))
        #expect(page.items.count == 5 && page.shelves.isEmpty && page.continuation == "SYNTHETICnextShelfToken-2")
        #expect(page.accounting.consistent && page.accounting.classified == 5)
        #expect(page.items.allSatisfy { $0.occurrenceID != nil })
    }
    @Test func lastPageHasNoToken() throws {
        let page = try MusicBrowseParser.parseContinuation(try syntheticData("continuation-playlist-last.json"))
        #expect(page.items.count == 2 && page.continuation == nil)
    }
    @Test func sectionContinuationCarriesShelves() throws {
        let page = try MusicBrowseParser.parseContinuation(try syntheticData("continuation-section-list.json"))
        #expect(page.items.isEmpty && page.shelves.map(\.title) == ["More shelves (synthetic)"] && page.shelves[0].items.count == 10)
        #expect(page.continuation == "SYNTHETICpageToken-3" && page.accounting.consistent)
    }
    @Test func appendActionEnvelopeAndItsTrailingTokenMarker() throws {
        let page = try MusicBrowseParser.parseContinuation(try syntheticData("continuation-append-action.json"))
        #expect(page.items.count == 3 && page.continuation == "SYNTHETICappendToken-4" && page.accounting.continuationMarkers == 1)
    }
    @Test func aRecognisedEmptyContainerIsTheEndNotAFailure() throws {
        let page = try MusicBrowseParser.parseContinuation(try syntheticData("continuation-end.json"))
        #expect(page.items.isEmpty && page.shelves.isEmpty && page.continuation == nil)
    }

    // MARK: Validators

    @Test func identifierAndTokenValidatorsRefuseHostileInput() {
        for bad in ["", "a b", "a/b", "../x", String(repeating: "a", count: 129), "id\n", "id;x"] { #expect(!MusicBrowseParser.isBrowseID(bad), "\(bad)") }
        for bad in ["", "a b", "a\"b", String(repeating: "a", count: 1025), "<script>"] { #expect(!MusicBrowseParser.isParams(bad)) }
        for bad in ["", "a b", String(repeating: "a", count: 4097), "tok\u{0}en"] { #expect(!MusicBrowseParser.isToken(bad)) }
        #expect(MusicBrowseParser.isBrowseID("FEmusic_home") && MusicBrowseParser.isParams("ggMEgALSAg%3D%3D") && MusicBrowseParser.isToken("4qmFsgI0EiRWTFBM%3D"))
    }

    @Test func aTokenOrIDHostileInAResponseIsNotKept() throws {
        var root = try syntheticData("continuation-section-list.json")
        var contents = root["continuationContents"] as! [String: Any]
        var list = contents["sectionListContinuation"] as! [String: Any]
        list["continuations"] = [["nextContinuationData": ["continuation": "bad token with spaces"]]]
        contents["sectionListContinuation"] = list; root["continuationContents"] = contents
        #expect(try MusicBrowseParser.parseContinuation(root).continuation == nil)
    }
}
