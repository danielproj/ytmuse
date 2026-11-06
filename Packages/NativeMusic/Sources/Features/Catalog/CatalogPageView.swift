import AccountSession
import DesignSystem
import SwiftUI

/// Loading, failure and empty states shared by every catalog page.
struct CatalogStateView: View {
    @Bindable var model: CatalogPageModel
    var body: some View {
        switch model.phase {
        case .idle, .loading:
            LoadingState().accessibilityIdentifier("catalogLoading").musicTransition(.reveal)
        case .failed(let failure):
            ErrorState(title: "This page couldn’t be loaded", detail: failure.message) { Task { await model.load() } }.accessibilityIdentifier("catalogFailure")
        case .loaded:
            if !model.hasContent || (model.shelves.allSatisfy { $0.items.isEmpty } && model.header == nil) {
                EmptyState(title: "Nothing to show here", message: "YouTube Music returned this page without any items.")
            }
        }
    }
}

/// A scrolling page of shelves. The shelf at the top of the viewport is the anchor: a refresh keeps it and the order around it.
/// `header` draws whatever sits above the shelves (a hero, a detail header).
struct CatalogShelvesView<Header: View>: View {
    @Bindable var model: CatalogPageModel
    let navigator: CatalogNavigator
    @ViewBuilder var header: () -> Header
    /// W09-F2: a catalog page restores by identity (`IdentityRestorer`): the first row fully on screen in a list shelf (a playlist's or album's tracks),
    /// else the shelf at the top. Both are recorded for the visit; on return the page scrolls to the row, or to its shelf if the row never arrives.
    @State private var identity = IdentityRestorer(rule: .coveringTop, requiresRealisation: true)
    private let headerID = "catalog-page-header"
    @Environment(\.podcastsSurface) private var podcasts
    var body: some View {
        ScrollViewReader { proxy in
            let _ = registerItems()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MusicPageStyle.sectionSpacing) {
                    // The heading is a scroll target too: a visit left at the top must
                    // restore the heading, rather than pull the first shelf over it.
                    // Its inset belongs to the target so restoration keeps page spacing.
                    VStack(alignment: .leading, spacing: MusicPageStyle.sectionSpacing) { header() }
                        .padding(.top, MusicSpace.xl).identityItem(headerID)
                    CatalogStateView(model: model)
                    ForEach(model.shelves.filter { !$0.items.isEmpty || $0.continuation != nil }) { shelf in
                        ShelfView(shelf: shelf, model: model, navigator: navigator).identityItem(shelf.key)
                    }
                    if model.pageContinuation != nil { pagePager }
                    if model.phase == .loaded, model.hasContent { FreshnessLine(model: model) }
                }.scrollTargetLayout().musicPageContent(includeTopInset: false).frame(maxWidth: .infinity, alignment: .leading)
                    .musicAnimation(.reveal, value: model.phase)
            }
            .scrollPosition(id: $model.anchor, anchor: .top)
            .restoresByIdentity(identity, proxy: proxy)
            // A merged refresh can drop or add shelves above the one being looked at; that shelf stays where it was.
            .onChange(of: model.mergeRevision) { _, _ in
                if let anchor = model.anchor, model.shelf(anchor) != nil { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
        .remembersPage(identity: identity, capture: { PageMemory() }, apply: { _ in })
        .task { await model.load() }
        // Command-R refreshes whichever page is showing. It lives here, outside the lazily created rows, so it works wherever the
        // list is scrolled to (the visible Refresh buttons scroll away with their rows).
        .background {
            Button("Refresh") { Task { await model.refresh() } }.keyboardShortcut("r", modifiers: .command)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true).frame(width: 0, height: 0)
        }
        .accessibilityIdentifier("catalogScroll")
    }
    private func registerItems() {
        let registration = CatalogRows.registration(of: model.shelves, podcasts: podcasts, pageReadAt: model.fetchedAt ?? .distantPast)
        identity.setItems([headerID] + registration.order, parents: registration.parents)
    }
    @ViewBuilder private var pagePager: some View {
        HStack {
            if model.loadingMore.contains("page") { ProgressView().controlSize(.small).accessibilityLabel(Text("Loading more")) }
            else if let failure = model.moreFailures["page"] {
                Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText)
                Button("Retry") { Task { await model.loadMorePage() } }.musicPageAction()
            } else {
                Color.clear.frame(width: 1, height: 1).onAppear { Task { await model.loadMorePage() } }
                Button("Load more") { Task { await model.loadMorePage() } }.musicPageAction().accessibilityIdentifier("catalogLoadMorePage")
            }
        }
    }
}

/// Title row with a Refresh button, shared by Home, Explore and the catalog pages.
struct CatalogTitleRow: View {
    let title: String
    @Bindable var model: CatalogPageModel
    /// Home and Explore are destinations and carry the shell's destination-title identifier.
    var identifier = "destinationTitle"
    var body: some View {
        HStack {
            Text(title).font(MusicPageStyle.title).accessibilityAddTraits(.isHeader).accessibilityIdentifier(identifier).browserRegion(identifier == "destinationTitle" ? "destinationTitle" : "pageTitle")
            Spacer()
            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .labelStyle(.iconOnly).help(Text("Refresh")).musicPageAction().disabled(model.isRefreshing || model.phase == .loading)
                .accessibilityIdentifier("catalogRefresh")
        }
    }
}
