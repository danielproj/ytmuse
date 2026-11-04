import AccountSession
import DesignSystem
import SwiftUI

/// Home: the service's own shelves for this listener (quick picks, mixes, recently played, new releases…) when a YouTube
/// Music account is active, otherwise the public front page, with the service's mood chips as filters. `intro` is the shell's
/// own welcome and account block, shown above the shelves.
public struct HomeView<Intro: View>: View {
    @Bindable var model: CatalogPageModel
    let navigator: CatalogNavigator
    let openChip: (MusicChip) -> Void
    @ViewBuilder var intro: () -> Intro
    public init(model: CatalogPageModel, navigator: CatalogNavigator, openChip: @escaping (MusicChip) -> Void, @ViewBuilder intro: @escaping () -> Intro) {
        self.model = model; self.navigator = navigator; self.openChip = openChip; self.intro = intro
    }
    public var body: some View {
        CatalogShelvesView(model: model, navigator: navigator) {
            VStack(alignment: .leading, spacing: MusicSpace.md) {
                CatalogTitleRow(title: String(localized: "Home"), model: model)
                intro().padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface()
                if !model.chips.isEmpty {
                    ScrollView(.horizontal) {
                        MusicGlassGroup {
                            HStack { ForEach(model.chips, id: \.self) { chip in
                                Button(chip.title) { openChip(chip) }.musicPageAction(prominent: chip.selected).accessibilityIdentifier("homeChip-" + chip.title)
                            } }
                        }
                    }.scrollIndicators(.hidden)
                }
                if model.phase == .loaded, !model.signedIn {
                    Label("Showing YouTube Music’s public front page. Sign in for shelves made for you.", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("homeAnonymousNote")
                }
            }
        }
    }
}
