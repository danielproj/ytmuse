import Domain
import Foundation

/// W28 (L10N03): the person's content language and content region, as the hints every service request carries. Read from the app's own preferences store on
/// each call (an isolated QA launch reads its throwaway store), so a change in Settings applies to the next request without rebuilding any client.
public enum ContentLocaleSetting {
    /// `hl` and `gl` for a request. A malformed stored value is dropped by `LanguageRegionPreferences`, never sent.
    public static func current(systemPreferred: [String] = Locale.preferredLanguages, systemRegion: String? = Locale.current.region?.identifier,
                               store: UserDefaults? = nil) -> (hl: String, gl: String?) {
        let store = store ?? AppPreferences.store
        let preferences = LanguageRegionPreferences(stored: nil, content: store.string(forKey: LanguageRegionPreferences.contentLanguageKey), region: store.string(forKey: LanguageRegionPreferences.contentRegionKey))
        let hints = preferences.contentRequest(systemPreferred: systemPreferred, systemRegion: systemRegion)
        return (hints.hl, hints.gl)
    }
}
