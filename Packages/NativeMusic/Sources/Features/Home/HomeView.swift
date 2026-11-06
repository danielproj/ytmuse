import AccountSession
import DesignSystem
import SwiftUI

/// Home: the service's own shelves for this listener (quick picks, mixes, recently played, new releases…) when a YouTube
/// Music account is active, otherwise the public front page, with the service's mood chips as filters. `intro` is the shell's
/// own welcome and account block, shown above the shelves.
public struct HomeView<Intro: View>: View {
    @Bindable var model: CatalogPageModel
    let navigator: CatalogNavigator
    let openChip: (AccountSession.MusicChip) -> Void
    /// False once the listener is signed in: the shelves and the sidebar already lead to their music, so the welcome card would only take room.
    let showsIntro: Bool
    @ViewBuilder var intro: () -> Intro
    public init(model: CatalogPageModel, navigator: CatalogNavigator, showsIntro: Bool = true, openChip: @escaping (AccountSession.MusicChip) -> Void, @ViewBuilder intro: @escaping () -> Intro) {
        self.model = model; self.navigator = navigator; self.showsIntro = showsIntro; self.openChip = openChip; self.intro = intro
    }
    public var body: some View {
        CatalogShelvesView(model: model, navigator: navigator) {
            VStack(alignment: .leading, spacing: MusicPageStyle.sectionSpacing) {
                CatalogTitleRow(title: String(localized: "Home"), model: model)
                if showsIntro { intro().padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface() }
                if !model.chips.isEmpty {
                    ScrollView(.horizontal) {
                        HStack { ForEach(model.chips, id: \.self) { chip in
                            DesignSystem.MusicChip(verbatim: chip.title, isSelected: chip.selected) { openChip(chip) }.accessibilityIdentifier("homeChip-" + chip.title)
                        } }
                    }.scrollIndicators(.hidden)
                }
                if model.phase == .loaded, !model.signedIn {
                    Label("Showing YouTube Music’s public front page. Sign in for shelves made for you.", systemImage: "person.crop.circle.badge.questionmark")
                        .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("homeAnonymousNote")
                }
            }
        }
    }
}
