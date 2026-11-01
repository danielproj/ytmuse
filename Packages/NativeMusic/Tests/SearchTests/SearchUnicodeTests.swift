import AccountSession
import Foundation
import Testing
@testable import Features

/// T10.2 — typos, combining characters, mixed scripts, diacritics, the preserved original
/// query, and a correction that needs an explicit action.
@Suite struct SearchTextTests {
    @Test func foldingMakesCaseAccentsCompositionAndWidthIrrelevant() {
        let forms = ["Café", "CAFÉ", "cafe", "Cafe\u{301}", "café", "ＣＡＦＥ"]
        #expect(Set(forms.map(SearchText.fold)) == ["cafe"], "\(forms.map(SearchText.fold))")
        #expect(SearchText.fold("Straße") == "strasse")
        #expect(SearchText.fold("Ørsted") == "orsted" && SearchText.fold("Łódź") == "lodz" && SearchText.fold("Æon") == "aeon")
        #expect(SearchText.fold("Ελλάδα") == "ελλαδα" && SearchText.fold("Привет") == "привет")
    }
    @Test func turkishCapitalsFoldInTheOrderThatKeepsThemMatchable() {
        // Folding before lowercasing turns İ into I and then dotless ı; the order here prevents it.
        for typed in ["istanbul", "ISTANBUL", "İSTANBUL", "Istanbul", "ıstanbul"] { #expect(SearchText.fold(typed) == "istanbul", "\(typed)") }
        #expect(SearchText.fold("IĞDIR") == "igdir" && SearchText.fold("ığdır") == "igdir")
        #expect(FoldedQuery("istanbul").match("İSTANBUL Nights") == .prefix)
        #expect(FoldedQuery("nights ıstanbul").match("İSTANBUL Nights") == .tokenPrefix)
    }
    @Test func matchQualityRanksExactThenPrefixThenWordPrefixThenSubstring() {
        #expect(FoldedQuery("blue").match("Blue") == .exact)
        #expect(FoldedQuery("blue").match("Blue Monday") == .prefix)
        #expect(FoldedQuery("mon").match("Blue Monday") == .tokenPrefix)
        #expect(FoldedQuery("lue mon").match("Blue Monday") == .substring)
        #expect(FoldedQuery("monday blue").match("Blue Monday") == .tokenPrefix, "word order does not matter")
        #expect(FoldedQuery("zzz").match("Blue Monday") == nil)
        let ranked: [SearchMatchQuality] = [.exact, .prefix, .tokenPrefix, .substring, .tolerant]
        #expect(ranked == ranked.sorted(by: >))
    }
    @Test func typosMatchTolerantlyButShortWordsAndIdeographsAreExact() {
        #expect(FoldedQuery("beyonse").match("Beyoncé") == .tolerant, "substitution in a 7-letter word")
        #expect(FoldedQuery("beyoncee").match("Beyoncé") == .tolerant, "insertion")
        #expect(FoldedQuery("tihngs").match("Things") == .tolerant, "adjacent transposition counts as one edit")
        #expect(FoldedQuery("coldply").match("Coldplay") == .tolerant, "deletion")
        #expect(FoldedQuery("cat").match("car") == nil, "one edit on three letters is a different word")
        #expect(FoldedQuery("beyxxxx").match("Beyoncé") == nil, "too many edits")
        #expect(FoldedQuery("東亰").match("東京タワー") == nil, "ideographs never match by edit distance")
        #expect(FoldedQuery("coldpl").match("Coldplay") == .prefix, "an exact prefix wins before tolerance is tried")
        #expect(FoldedQuery("coldplya").match("Coldplay") == .tolerant)
    }
    @Test func everyQueryWordMustMatchForATolerantHit() {
        #expect(FoldedQuery("beyonse mix").match("Beyoncé Mix") == .tolerant)
        #expect(FoldedQuery("beyonse zebra").match("Beyoncé Mix") == nil)
        #expect(FoldedQuery("mix mix").match("Beyoncé Mix") == nil, "one title word cannot satisfy two query words")
    }
    @Test func mixedScriptsAndIdeographRunsMatch() {
        #expect(SearchText.tokens("東京タワー").count == 5, "each ideograph is its own token")
        #expect(FoldedQuery("東京").match("東京タワー") == .prefix)
        #expect(FoldedQuery("京タ").match("東京タワー") == .substring)
        #expect(FoldedQuery("タ京").match("東京タワー") == nil, "an ideograph run keeps its order")
        #expect(FoldedQuery("tokyo 東京").match("Tokyo 東京 Nights") == .prefix)
        #expect(FoldedQuery("nights 東京").match("Tokyo 東京 Nights") == .tokenPrefix)
        #expect(FoldedQuery("kafé 東京").match("Café 東京") == .tolerant, "the word may be a typo; the ideographs are exact")
        #expect(FoldedQuery("kafé 東亰").match("Café 東京") == nil)
        #expect(FoldedQuery("привет").match("ПРИВЕТ мир") == .prefix)
        #expect(FoldedQuery("ελλαδα").match("Ελλάδα") == .exact)
    }
    @Test func queryKeepsExactlyWhatWasTyped() {
        let typed = "  Beyoncé\u{301}  Mix "
        let query = FoldedQuery(typed)
        #expect(query.original == typed, "folding never rewrites the original")
        #expect(query.tokens == ["beyonce", "mix"])
    }
    @Test func distanceIsBoundedAndCountsTranspositionOnce() {
        func d(_ a: String, _ b: String, _ limit: Int = 2) -> Int? { SearchText.distance(Array(a), Array(b), limit: limit) }
        #expect(d("ab", "ba") == 1 && d("kitten", "sitting", 3) == 3 && d("abc", "abc") == 0)
        #expect(d("kitten", "sitting", 2) == nil && d("a", "abcd") == nil)
        #expect(d("", "ab") == 2 && d("", "abc") == nil)
    }
    @Test func tolerantWordsArePrefixesOfWordsBeingTyped() {
        #expect(FoldedQuery("beyonsé m").match("Beyoncé Mix") == .tolerant, "typo in a word, and a partly typed next word")
    }
}

@Suite @MainActor struct SearchCorrectionTests {
    @MainActor final class Rig {
        let clock = VirtualClock()
        let remote = ScriptedRemote()
        let model: SearchModel
        init() {
            let remote = self.remote
            model = SearchModel(sources: [FakeLibrary([("PL1", "Beyoncé Mix"), ("PL2", "Rock Classics"), ("PL3", "Café Del Mar Sessions")])],
                                remote: { try await remote.call($0) }, clock: clock)
        }
    }
    @Test func aLibraryTypoIsFoundApproximatelyAndBadgedAsApproximate() async throws {
        let rig = Rig()
        rig.model.query = "beyonse mix"; await settle()
        let result = try #require(rig.model.results.first)
        #expect(result.title == "Beyoncé Mix" && result.quality == .tolerant && result.badges.contains(.approximate) && result.badges.contains(.library))
    }
    @Test func aCorrectionIsOfferedButNeverAppliedUntilTheExplicitAction() async throws {
        let rig = Rig()
        rig.model.query = "beyonse mix"; await settle()
        #expect(rig.model.correction == SearchCorrectionOffer(text: "Beyoncé mix", source: .library))
        rig.clock.advance(by: .milliseconds(180)); await settle()
        #expect(await rig.remote.queries == ["beyonse mix"], "the service is asked for what was typed, not for the guess")
        #expect(rig.model.query == "beyonse mix" && rig.model.originalQuery == "beyonse mix")
        rig.model.applyCorrection(); await settle()
        #expect(rig.model.query == "Beyoncé mix" && rig.model.originalQuery == "beyonse mix", "the original stays recoverable")
        #expect(rig.model.corrected == "beyonse mix")
        #expect(await rig.remote.queries == ["beyonse mix", "Beyoncé mix"], "applying asks at once, with the corrected text")
        rig.model.revertCorrection(); await settle()
        #expect(rig.model.query == "beyonse mix" && rig.model.corrected == nil)
    }
    @Test func editingAfterApplyingForgetsTheOldOriginalAndAnExactHitOffersNothing() async throws {
        let rig = Rig()
        rig.model.query = "beyonse mix"; await settle()
        rig.model.applyCorrection(); await settle()
        rig.model.query = "Beyoncé mix x"; await settle()
        #expect(rig.model.corrected == nil && rig.model.originalQuery == "Beyoncé mix x")
        rig.model.query = "beyoncé"; await settle()
        #expect(rig.model.correction == nil, "an exact local match needs no respelling")
    }
    @Test func theServiceDidYouMeanIsAlsoOnlyAnOffer() async throws {
        let rig = Rig()
        rig.model.query = "cafe del mer"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(0, with: reply(response([song("Something")], suggestion: MusicSearchSuggestion(text: "cafe del mar", appliedByService: false))))
        await settle()
        #expect(rig.model.correction == SearchCorrectionOffer(text: "cafe del mar", source: .service))
        #expect(rig.model.query == "cafe del mer")
        #expect(await rig.remote.callCount == 1)
    }
    @Test func aServiceAlreadyShowingCorrectedResultsIsLabelledAsSuch() async throws {
        let rig = Rig()
        rig.model.query = "synthtic"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(0, with: reply(response([song("Hit")], suggestion: MusicSearchSuggestion(text: "synthetic", appliedByService: true))))
        await settle()
        #expect(rig.model.correction?.source == .serviceAlreadyApplied && rig.model.query == "synthtic")
    }
    @Test func aSuggestionThatFoldsToTheTypedQueryIsNotOffered() async throws {
        let rig = Rig()
        rig.model.query = "Café"; await settle()
        rig.clock.advance(by: .milliseconds(180)); await settle()
        await rig.remote.answer(0, with: reply(response([song("Hit")], suggestion: MusicSearchSuggestion(text: "cafe", appliedByService: false))))
        await settle()
        #expect(rig.model.correction == nil)
    }
    @Test func localCorrectionNeedsAWordWithinReachAndNeverTouchesIdeographs() {
        let titles = ["Beyoncé Mix", "Rock Classics"]
        #expect(SearchCorrection.suggest(for: FoldedQuery("rock clasics"), vocabulary: titles) == "rock Classics", "words that already match keep the typed spelling")
        #expect(SearchCorrection.suggest(for: FoldedQuery("rock classics"), vocabulary: titles) == nil)
        #expect(SearchCorrection.suggest(for: FoldedQuery("qqqqqqq"), vocabulary: titles) == nil)
        #expect(SearchCorrection.suggest(for: FoldedQuery("東亰"), vocabulary: ["東京"]) == nil)
        #expect(SearchCorrection.suggest(for: FoldedQuery(""), vocabulary: titles) == nil)
    }
}
