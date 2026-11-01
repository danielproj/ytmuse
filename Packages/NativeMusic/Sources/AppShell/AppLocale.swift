import Domain
import SwiftUI

/// W28 (L10N03): applies the person's interface-language choice to a window. The environment locale selects which localization SwiftUI text
/// resolves against and how dates, numbers and plurals format; the layout direction follows the language. Content language and content
/// region are NOT read here: they only shape requests (`LanguageRegionPreferences.contentRequest`).
struct AppLocaleModifier: ViewModifier {
    @AppStorage(LanguageRegionPreferences.interfaceKey) private var storedInterface = LanguageRegionPreferences.systemToken
    func body(content: Content) -> some View {
        let preferences = LanguageRegionPreferences(stored: storedInterface, content: nil, region: nil)
        let interface = preferences.effectiveInterface(systemPreferred: Locale.preferredLanguages)
        content
            .environment(\.locale, Locale(identifier: LanguageRegionPreferences.formattingIdentifier(interface: interface, systemRegion: Locale.current.region?.identifier)))
            .environment(\.layoutDirection, AppLocales.isRightToLeft(script: interface) ? .rightToLeft : .leftToRight)
    }
}
extension View {
    /// Apply inside `appPreferences()` so the choice is read from the app's preferences store (isolated under QA).
    func appLocale() -> some View { modifier(AppLocaleModifier()) }
}
