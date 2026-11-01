import AccountSession
import DesignSystem
import SwiftUI

/// Explore: new releases, charts and moods & genres, and the public shelves the service shows beside them. Each
/// "More" and each tile opens its own native page (`CatalogPageScreen`), so a list is never a first page presented as the whole.
public struct ExploreView: View {
    @Bindable var model: CatalogPageModel
    let title: String
    let navigator: CatalogNavigator
    /// Opens Samples, the music tuner, Recap or Badges (W20); nil: Explore shows only the service's own shelves.
    let discovery: ((DiscoveryEntry) -> Void)?
    public init(model: CatalogPageModel, title: String, navigator: CatalogNavigator, discovery: ((DiscoveryEntry) -> Void)? = nil) {
        self.model = model; self.title = title; self.navigator = navigator; self.discovery = discovery
    }
    public var body: some View {
        CatalogShelvesView(model: model, navigator: navigator) {
            CatalogTitleRow(title: model.heading ?? title, model: model)
            if let discovery { DiscoveryEntryRow(open: discovery) }
        }
    }
}
