import DesignSystem
import SwiftUI

/// Publishes the stored text size to a window's content (apply inside `appPreferences()` so the isolated QA store is the one read).
struct ContentScaleModifier: ViewModifier {
    @AppStorage(MusicContentScale.storageKey) private var stored = 1.0
    func body(content: Content) -> some View { content.environment(\.musicContentScale, stored) }
}
extension View { func appContentScale() -> some View { modifier(ContentScaleModifier()) } }
