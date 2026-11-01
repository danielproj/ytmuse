import Testing
import Foundation
@testable import AppShell

// W28 rework 1 (F2): an explicit interface language is turned into the process's argument-domain AppleLanguages (volatile, nothing written to any file), which is what makes
// String(localized:) and the menu bar follow it from the next launch. The real lookup is exercised by the native UI test (relaunch with German); these are the decisions.

@Suite struct UILanguageOverrideTests {
  @Test func anExplicitChoiceBecomesTheLanguageOfTheProcessAndAnUnsupportedOneBecomesEnglish() {
    #expect(UILanguageOverride.languages(stored: "de", systemPreferred: ["en"]) == ["de"])
    #expect(UILanguageOverride.languages(stored: "pt-BR", systemPreferred: ["en"]) == ["pt"], "the nearest shipped locale")
    #expect(UILanguageOverride.languages(stored: "de-CH", systemPreferred: ["en"]) == ["de-CH"])
    #expect(UILanguageOverride.languages(stored: "sr-Latn", systemPreferred: ["en"]) == ["sr-Latn"])
    #expect(UILanguageOverride.languages(stored: "ja", systemPreferred: ["de"]) == ["en"], "an unsupported choice falls back to English alone, not to the system's language")
  }
  @Test func sameAsMacOSLeavesTheSystemsNegotiationAlone() {
    #expect(UILanguageOverride.languages(stored: nil) == nil)
    #expect(UILanguageOverride.languages(stored: "system") == nil)
    #expect(UILanguageOverride.languages(stored: "") == nil)
  }
  @Test func applyingMergesIntoTheArgumentDomainAndWritesNoFile() {
    // A per-test suite object: its volatile argument domain is in memory only.
    let name = "ytmuse-w28-language-override-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.setVolatileDomain(["-ApplePersistenceIgnoreState": "YES"], forName: UserDefaults.argumentDomain)
    UILanguageOverride.apply(["de"], to: defaults)
    let domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    #expect(domain["AppleLanguages"] as? [String] == ["de"])
    #expect(domain["-ApplePersistenceIgnoreState"] as? String == "YES", "the launch arguments already in the domain survive")
    #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil, "nothing is persisted")
  }
}
