import Domain
import Foundation

/// W28 rework 1 (F2, L10N03): makes an EXPLICIT interface-language choice reach every string of the process: SwiftUI text, `String(localized:)` (errors,
/// VoiceOver announcements, palette titles) and the menu bar. The choice is turned into the argument-domain `AppleLanguages` of this process only (a volatile
/// domain: nothing is written to any preferences file, the system's or the app's), before the first string is looked up, which is exactly what a
/// `-AppleLanguages (de)` launch argument does. Strings already resolved cannot change, so a new choice applies to everything from the next launch; SwiftUI text
/// follows at once through the environment locale (`appLocale`). "Same as macOS" leaves the system negotiation alone.
public enum UILanguageOverride {
    /// The languages to force for a stored choice, or nil to leave the system's negotiation alone. An unsupported explicit choice resolves to English.
    public static func languages(stored: String?, systemPreferred: [String] = Locale.preferredLanguages) -> [String]? {
        let preferences = LanguageRegionPreferences(stored: stored, content: nil, region: nil)
        guard case .identifier = preferences.interfaceLanguage else { return nil }
        return [preferences.effectiveInterface(systemPreferred: systemPreferred)]
    }
    /// Call first thing at launch, before any string is resolved. Reads the app's own preferences store (the isolated one under QA).
    @discardableResult
    public static func applyFromStore(_ store: UserDefaults? = nil) -> [String]? {
        let store = store ?? AppPreferences.store
        guard let languages = languages(stored: store.string(forKey: LanguageRegionPreferences.interfaceKey)) else { return nil }
        apply(languages)
        return languages
    }
    static func apply(_ languages: [String], to defaults: UserDefaults = .standard) {
        // Merge: the argument domain also holds launch arguments (for example -ApplePersistenceIgnoreState) that must survive.
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["AppleLanguages"] = languages
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
}
