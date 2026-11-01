import Testing
import Foundation
import Domain

// W28 T28.4: natural sorting, locale-aware search, unchanged names, mixed scripts, and pseudolocalization.

@Suite struct NaturalOrderTests {
  @Test func numbersSortAsNumbersAndCaseIsIgnored() {
    let en = Locale(identifier: "en")
    #expect(NaturalOrder.sorted(["Track 10", "Track 2", "track 1", "Track 21", "Track 3"], locale: en) == ["track 1", "Track 2", "Track 3", "Track 10", "Track 21"])
    #expect(NaturalOrder.compare("a", "B", locale: en) == .orderedAscending)
  }
  @Test func theLanguageOwnsItsAlphabet() {
    let names = ["Åsa", "Zorro", "Anna", "Ärla", "Öland", "Olle"]
    #expect(NaturalOrder.sorted(names, locale: Locale(identifier: "sv")) == ["Anna", "Olle", "Zorro", "Åsa", "Ärla", "Öland"], "Swedish å, ä, ö come after z")
    #expect(NaturalOrder.sorted(names, locale: Locale(identifier: "de")) == ["Anna", "Ärla", "Åsa", "Öland", "Olle", "Zorro"], "German ä sorts with a")
    #expect(NaturalOrder.sorted(["Ñu", "Nube", "Oso", "Nz"], locale: Locale(identifier: "es")) == ["Nube", "Nz", "Ñu", "Oso"], "Spanish ñ follows n")
  }
  @Test func mixedScriptsSortDeterministicallyAndNothingIsRewritten() {
    let names = ["東京", "Tokyo", "Ελλάδα", "القاهرة", "Москва", "שלום", "a", "ა"]
    let one = NaturalOrder.sorted(names, locale: Locale(identifier: "en")), two = NaturalOrder.sorted(names.reversed(), locale: Locale(identifier: "en"))
    #expect(one == two, "the order does not depend on the input order")
    #expect(Set(one) == Set(names) && one.count == names.count, "sorting never alters or drops a name")
    #expect(one.first == "a", "Latin first in English collation (\(one))")
  }
  @Test func searchFoldsCaseDiacriticsAndWidthInThePersonsLocale() {
    let en = Locale(identifier: "en"), tr = Locale(identifier: "tr")
    #expect(NaturalOrder.matches("Beyoncé", query: "beyonce", locale: en))
    #expect(NaturalOrder.matches("Sigur Rós", query: "ROS", locale: en))
    #expect(NaturalOrder.matches("ＡＢＣ", query: "abc", locale: en), "full-width letters match")
    #expect(NaturalOrder.matches("İSTANBUL", query: "istanbul", locale: tr), "Turkish capital dotted İ → i")
    #expect(NaturalOrder.searchKey("İSTANBUL", locale: tr) == "istanbul")
    #expect(NaturalOrder.matches("Iğdır", query: "igdir", locale: tr), "an ASCII query finds Iğdır")
    #expect(NaturalOrder.matches("IĞDIR", query: "ığdır", locale: tr))
    #expect(NaturalOrder.matches("東京タワー", query: "東京", locale: en))
    #expect(!NaturalOrder.matches("Beyoncé", query: "knowles", locale: en))
    #expect(NaturalOrder.matches("anything", query: "", locale: en), "an empty query matches")
  }
}

@Suite struct PseudolocalizerTests {
  @Test func placeholdersSurviveEveryStyleAndStillFormat() {
    let sources = ["Play %@", "Now playing “%@” by %@.", "%lld minutes", "Undo: added %lld songs", "%1$@ then %2$@", "100%% sure about %@", "{name} has %lld items"]
    for source in sources {
      for style in [Pseudolocalizer.Style.accented, .long, .rightToLeft] {
        let out = Pseudolocalizer.apply(source, style: style)
        #expect(Pseudolocalizer.placeholders(in: out) == Pseudolocalizer.placeholders(in: source), "\(style) changed the placeholders of \(source): \(out)")
      }
    }
    let formatted = String(format: Pseudolocalizer.apply("Now playing “%@” by %@.", style: .long), "Beyoncé", "Sigur Rós")
    #expect(formatted.contains("Beyoncé") && formatted.contains("Sigur Rós"), "names pass through untouched")
  }
  @Test func accentedKeepsEveryLetterRecognisableAndMarksTheString() {
    let out = Pseudolocalizer.apply("Sign in", style: .accented)
    #expect(out.hasPrefix("[") && out.hasSuffix("]"))
    #expect(out != "[Sign in]" && out.contains("Š"), "letters are accented: \(out)")
    #expect(Pseudolocalizer.apply("", style: .accented) == "[]")
  }
  @Test func longExpandsShortStringsMostAndSentencesByAboutAHalf() {
    func ratio(_ text: String) -> Double { Double(Pseudolocalizer.apply(text, style: .long).count) / Double(text.count) }
    #expect(ratio("Play") >= 3.0, "four letters at least triple: \(ratio("Play"))")
    #expect(ratio("Sign in with Google") >= 1.5)
    #expect(ratio("Your password is entered on Google’s page, never in YTMuse.") >= 1.4, "sentences grow by at least 40%")
    #expect(Pseudolocalizer.apply("Play %@", style: .long).count > "Play %@".count * 2 - 4)
  }
  @Test func rightToLeftWrapsInEmbeddingMarks() {
    let out = Pseudolocalizer.apply("Queue", style: .rightToLeft)
    #expect(out.unicodeScalars.first == "\u{202B}" && out.unicodeScalars.last == "\u{202C}")
  }
}
