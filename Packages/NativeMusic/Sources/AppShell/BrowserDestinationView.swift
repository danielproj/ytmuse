import SwiftUI
import Observation
import DesignSystem
import Features
import AccountSession

struct BrowserDestinationView: View {
    @Bindable var navigation: BrowserNavigation
    let accounts: AccountsModel
    /// The shared application playback owner; the Library's Play actions go through it.
    var playback: PlaybackModel? = nil
    /// Presents this window's single Accounts sheet (owned by the shell).
    var manageAccounts: () -> Void = {}
    /// The window's persistent search; the Search destination shows it.
    var search: SearchModel? = nil
    var searchFocusToken = 0
    /// Home, Explore and the catalog detail pages (nil: the older placeholders).
    var catalog: CatalogHub? = nil
    /// Library and History (nil: the older placeholders).
    var library: LibrarySurface? = nil
    /// The Downloads destination (nil: the older placeholder).
    var downloads: DownloadsModel? = nil
    /// Samples, the music tuner, Recap and badges, opened from Explore (nil: the older development rows).
    var discovery: DiscoverySurface? = nil
    /// Comments, moderation and invitations beside songs and playlists.
    var social: SocialSurface? = nil
    /// Episode pages, the speed / jump / resume controls and the lyrics panel (W18).
    var podcasts: PodcastsSurface? = nil
    /// Debug only: the development data's measurement line.
    var discoveryReadout: (@MainActor () -> String)? = nil
    /// W09-F2: the entry's restoration for the production pages (one visit, however it is filtered), and for the placeholder collection
    /// page (whose scroll key still includes its query, filter and page).
    @State private var pageStore: NavigationPageStore
    @State private var collectionStore: NavigationPageStore
    let authorityGeneration: UInt64
    private let development: Bool
    private let diagnosticsEnabled: Bool
    #if DEBUG
    @State private var liveScroll = LiveScrollDiagnostic()
    #endif
    init(navigation: BrowserNavigation, accounts: AccountsModel, playback: PlaybackModel? = nil, manageAccounts: @escaping () -> Void = {}, authorityGeneration: UInt64 = 0, showsDiagnostics: Bool? = nil, search: SearchModel? = nil, searchFocusToken: Int = 0, catalog: CatalogHub? = nil, library: LibrarySurface? = nil, downloads: DownloadsModel? = nil,
         discovery: DiscoverySurface? = nil, social: SocialSurface? = nil, podcasts: PodcastsSurface? = nil, discoveryReadout: (@MainActor () -> String)? = nil) {
        self.discovery = discovery; self.social = social; self.podcasts = podcasts; self.discoveryReadout = discoveryReadout
        self.navigation = navigation; self.accounts = accounts; self.authorityGeneration = authorityGeneration
        self.search = search; self.searchFocusToken = searchFocusToken; self.catalog = catalog; self.library = library; self.downloads = downloads
        self.playback = playback; self.manageAccounts = manageAccounts
        _pageStore = State(initialValue: NavigationPageStore(navigation: navigation, generation: authorityGeneration, keyIncludesViewState: false))
        _collectionStore = State(initialValue: NavigationPageStore(navigation: navigation, generation: authorityGeneration, keyIncludesViewState: true))
        #if DEBUG
        development = ProcessInfo.processInfo.environment["YTMUSE_UI_DEVELOPMENT_DATA"] == "1"
        diagnosticsEnabled = showsDiagnostics ?? (ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1")
        #else
        development = false; diagnosticsEnabled = false
        #endif
    }
    private var entry: BrowserEntry { navigation.session.current }
    var body: some View {
        // The generation can change under a live view (an account switch); the stores fence everything by it.
        pageStore.generation = authorityGeneration; collectionStore.generation = authorityGeneration
        return Group {
            if let discovery, let page = discoveryEntry(entry) { discoveryPane(page, discovery) }
            else if let catalog, catalogOwns(entry, catalog) { catalogPane(catalog) }
            else if let downloads, entry.destination == .downloads, entry.item == nil { DownloadsView(model: downloads) }
            else if let library, libraryOwns(entry, library) { libraryPane(library) }
            else if entry.destination == .search, let search { searchPane(search) }
            else { collectionBody.environment(\.pageRestoration, PageRestoration(memory: collectionStore, scroll: collectionStore)) }
        }
        .environment(\.pageRestoration, PageRestoration(memory: pageStore, scroll: pageStore))
        .environment(\.socialSurface, social)
        .environment(\.podcastsSurface, podcasts)
    }
    /// The discovery screen a route opens, if it is one (Samples, tuner, Recap, Badges). A development placeholder route is not.
    private func discoveryEntry(_ entry: BrowserEntry) -> DiscoveryEntry? {
        guard let route = entry.item, !route.identifier.hasPrefix("development-") else { return nil }
        switch route.kind {
        case .sample: return .samples
        case .tuner: return .tuner
        case .recap: return route.identifier == DiscoveryEntry.local.rawValue ? .local : .recap
        case .badge: return .badges
        default: return nil
        }
    }
    private func openDiscovery(_ page: DiscoveryEntry) {
        let kind: NativeItemKind
        switch page { case .samples: kind = .sample; case .tuner: kind = .tuner; case .recap, .local: kind = .recap; case .badges: kind = .badge }
        if let route = try? NativeItemRoute(kind: kind, identifier: page.rawValue) { navigation.open(.explore, item: route) }
    }
    private var samplePicture: (@MainActor (SampleClip) -> AnyView)? {
        guard let playback else { return nil }
        return { @MainActor _ in AnyView(SamplePicture(playback: playback)) }
    }
    @ViewBuilder private func discoveryPane(_ page: DiscoveryEntry, _ surface: DiscoverySurface) -> some View {
        VStack(spacing: 0) {
            DiscoveryDestinationView(entry: page, surface: surface)
            #if DEBUG
            if let discoveryReadout { Text(discoveryReadout()).font(.caption2).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("discoveryReadout").padding(.horizontal, MusicSpace.lg).padding(.bottom, MusicSpace.xxs) }
            #endif
        }
        .environment(\.catalogArtwork, catalog?.artwork ?? CatalogArtwork(pipeline: nil, authority: ArtworkUIAuthority(), source: nil))
        // A previewing clip's picture is the hidden player's own, in W17's single-owner inline surface (or its placeholder when another surface holds it).
        .environment(\.sampleVideoSurface, samplePicture)
        .accessibilityElement(children: .contain)
    }
    /// Home and Explore with nothing open, and any catalog route, are the catalog's; the older development routes are not.
    private func catalogOwns(_ entry: BrowserEntry, _ catalog: CatalogHub) -> Bool {
        if let route = entry.item { return catalog.handles(route) }
        return entry.destination == .home || entry.destination == .explore
    }
    /// Library, History and Podcasts with nothing open are the Library screens'. The older development rows keep their
    /// destinations only for UI runs that ask for them (the development-rows flag without the development-library flag).
    private func libraryOwns(_ entry: BrowserEntry, _ library: LibrarySurface) -> Bool {
        guard entry.item == nil, [.library, .history, .podcasts].contains(entry.destination) else { return false }
        return library.development || !development
    }
    @ViewBuilder private func libraryPane(_ library: LibrarySurface) -> some View {
        let navigator = catalog?.navigator(navigation) ?? CatalogNavigator()
        Group {
            if entry.destination == .history { HistoryView(surface: library, navigator: navigator, openAccounts: manageAccounts) }
            else { LibraryView(surface: library, navigator: navigator, openAccounts: manageAccounts, opensOn: entry.destination == .podcasts ? .podcasts : nil) }
        }
        .environment(\.catalogArtwork, catalog?.artwork ?? CatalogArtwork(pipeline: nil, authority: ArtworkUIAuthority(), source: nil))
        .accessibilityElement(children: .contain)
    }
    @ViewBuilder private func catalogPane(_ catalog: CatalogHub) -> some View {
        VStack(spacing: 0) {
            if let route = entry.item, route.kind == .episode, let podcasts {
                // An episode page is read by its own model (not a catalog page): it has progress, chapters and Episodes for Later.
                EpisodeDetailView(model: podcasts.page(forBrowseID: route.identifier), surface: podcasts, navigator: catalog.navigator(navigation))
            } else if let model = catalog.model(for: entry) {
                let navigator = catalog.navigator(navigation)
                if let route = entry.item {
                    if route.kind == .song || route.kind == .video {
                        if let item = catalog.song(route.identifier), let detail = SongDetail(item: item) {
                            SongDetailView(detail: detail, playback: model.playback, model: model, navigator: navigator)
                        } else {
                            // Restored from history: the row this song came from is gone. Play and Copy Link still work from its id.
                            SongDetailView(detail: SongDetail(item: MusicCatalogItem(kind: .song, title: String(localized: "Unknown song"), availability: .unknown, videoID: route.identifier))!,
                                           playback: model.playback, model: model, navigator: navigator)
                        }
                    } else {
                        CollectionDetailView(model: model, fallbackTitle: catalog.title(for: route), navigator: navigator)
                    }
                } else if entry.destination == .home {
                    HomeView(model: model, navigator: navigator, showsIntro: !signedInLibrary, openChip: { chip in navigator.openTarget(CatalogTarget(browseID: chip.browseID, params: chip.params), chip.title) }) { welcome }
                } else {
                    ExploreView(model: model, title: String(localized: "Explore"), navigator: navigator, discovery: discovery == nil ? nil : { openDiscovery($0) })
                }
            } else {
                ErrorState(title: "This item cannot be loaded", message: "Connect a source that can open this item, or return to your collection.", recovery: "Back to collection") { navigation.back() }
            }
        }
        // The development label floats in the page margin above the page, so every page's title sits at the same height.
        .overlay(alignment: .topTrailing) {
            if catalog.development {
                Text("Development data · Not YouTube Music").font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, MusicSpace.lg).padding(.top, MusicSpace.xs).accessibilityIdentifier("developmentDataLabel").browserRegion("developmentLabel").allowsHitTesting(false)
            }
        }
        .environment(\.catalogArtwork, catalog.artwork)
        .environment(\.libraryLedger, library?.ledger)
        .environment(\.playlistSurface, library?.playlists)
        .accessibilityElement(children: .contain)
    }
    private func searchPane(_ model: SearchModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                // The title keeps its room (larger text and long translations wrap the label beside it, never crush the title).
                Text(LocalizedStringKey(entry.destination.title)).font(MusicPageStyle.title).accessibilityAddTraits(.isHeader).accessibilityIdentifier("destinationTitle").browserRegion("destinationTitle").layoutPriority(1)
                Spacer(minLength: MusicSpace.xs)
                if development { Text("Development data · Not YouTube Music").font(.caption).foregroundStyle(MusicStyle.secondaryText).multilineTextAlignment(.trailing).accessibilityIdentifier("developmentDataLabel") }
            }.musicPageContent()
            SearchView(model: model, focusToken: searchFocusToken).padding(.horizontal, MusicSpace.lg).padding(.bottom, MusicSpace.md)
                .environment(\.playlistSurface, library?.playlists)
        }
        .task {
            if accounts.activeConnected, accounts.proof == .none, !accounts.proofLoading { await accounts.loadProof() }
        }
    }
    private var collectionBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                // The title keeps its room (larger text and long translations wrap the label beside it, never crush the title).
                Text(LocalizedStringKey(entry.destination.title)).font(MusicPageStyle.title).accessibilityAddTraits(.isHeader).accessibilityIdentifier("destinationTitle").browserRegion("destinationTitle").layoutPriority(1)
                Spacer(minLength: MusicSpace.xs)
                if showsDevelopmentLabel { Text("Development data · Not YouTube Music").font(.caption).foregroundStyle(MusicStyle.secondaryText).multilineTextAlignment(.trailing).accessibilityIdentifier("developmentDataLabel") }
            }.musicPageContent()
            if entry.destination != .home && entry.item == nil {
                HStack {
                    TextField("Search this collection", text: Binding(get: { entry.query }, set: { navigation.session.current.query = String($0.prefix(1024)) })).accessibilityIdentifier("collectionQuery").musicField(dense: true).browserRegion("collectionQuery")
                    Picker("Filter", selection: Binding(get: { entry.filter }, set: { navigation.session.current.filter = $0 })) {
                        Text("All").tag("All"); Text("Downloaded only").tag("Downloaded only")
                    }.frame(maxWidth: 200).accessibilityIdentifier("collectionFilter").browserRegion("collectionFilter")
                }.padding(.horizontal, MusicSpace.lg).padding(.bottom, MusicSpace.sm)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: MusicSpace.lg) {
                    if entry.item != nil {
                        ErrorState(title: "This item cannot be loaded", message: "Connect a source that can open this item, or return to your collection.", recovery: "Back to collection") { navigation.back() }
                            .accessibilityIdentifier("unavailableItem")
                    } else if entry.destination == .home { welcome }
                    else if entry.destination == .library, signedInLibrary, let playback {
                        // The signed-in account's own library read (M2), never development data.
                        MusicLibraryList(accounts: accounts, playback: playback, query: entry.query, downloadedOnly: entry.filter == "Downloaded only")
                    }
                    else if development { developmentCollection }
                    else {
                        EmptyState(title: "Your music will appear here", message: "A music source is not connected to this destination yet.")
                        Button("Manage accounts", action: manageAccounts).musicPageAction()
                    }
                }.musicPageContent().frame(maxWidth: .infinity, alignment: .leading)
            }.restoresScroll(observe: { sample in
                #if DEBUG
                if diagnosticsEnabled { liveScroll.offset = sample.offset; liveScroll.maximum = sample.maximum; liveScroll.contentHeight = sample.contentHeight }
                #endif
            })
                .accessibilityIdentifier("destinationScroll")
            #if DEBUG
            if diagnosticsEnabled {
                ScrollDiagnosticReadout(live: liveScroll, navigation: navigation)
            }
            #endif
        }
    }
    private var signedInLibrary: Bool { accounts.usesMusicSession && accounts.activeConnected }
    /// Only destinations that render development rows carry the label; the signed-in
    /// Library shows the account's own playlists and must never be labelled test data.
    private var showsDevelopmentLabel: Bool { Self.labelsDevelopmentData(development: development, destination: entry.destination, signedInLibrary: signedInLibrary) }
    static func labelsDevelopmentData(development: Bool, destination: BrowserDestination, signedInLibrary: Bool) -> Bool {
        development && !(destination == .library && signedInLibrary)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: MusicSpace.lg) {
            HStack(alignment: .center, spacing: MusicSpace.lg) {
                ResonanceArtwork().frame(width: 96)
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Text("Welcome to YTMuse").font(MusicPageStyle.section)
                    Text("An independent native YouTube Music client for Mac").foregroundStyle(MusicStyle.secondaryText)
                    Text(accounts.connectionStatus).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("connectionStatus")
                }
            }
            HStack {
                if signedInLibrary {
                    Button("Open Your Library") { navigation.open(.library) }.accessibilityIdentifier("openLibrary").musicPageAction(prominent: true)
                    Button("Your Music Account", action: manageAccounts).accessibilityIdentifier("musicAccount").musicPageAction()
                } else {
                    // An active expired identity signs in again as itself (a new record), never
                    // as a new account that the duplicate-account check would refuse.
                    Button(accounts.activeExpired ? String(localized: "Sign In Again") : accounts.authenticationLabel) {
                        Task { await accounts.authenticate(accounts.activeExpired ? accounts.active : nil) }
                    }.disabled(!accounts.canAuthenticate || accounts.busy).accessibilityIdentifier("musicSignIn").musicPageAction(prominent: true)
                    Button("Manage Accounts", action: manageAccounts).accessibilityIdentifier("welcomeAccounts").musicPageAction()
                }
                if accounts.busy {
                    Button(accounts.usesMusicSession ? String(localized: "Cancel Sign-In") : String(localized: "Cancel authorization")) {
                        Task { await accounts.cancelAuthentication() }
                    }.musicPageAction()
                }
            }
            if accounts.usesMusicSession && !accounts.activeConnected {
                Label("Your password is entered on Google’s page, never in YTMuse.", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(MusicStyle.secondaryText)
            }
            AccountActionFeedback(model: accounts)
            if !accounts.canAuthenticate { Text("Browser sign-in is not connected in this development build.").foregroundStyle(MusicStyle.secondaryText) }
            if development {
                SectionShelf("Original artwork studies · Development data") {
                    ForEach(0..<3) { index in
                        ArtworkCard(title: "Resonance \(index + 1)", subtitle: "Original study · Development data", artwork: { ResonanceArtwork() }) {
                            if let item = try? NativeItemRoute(kind: .album, identifier: "development-\(index)") { navigation.open(.library, item: item) }
                        }.frame(width: 160)
                    }
                }
            }
        }
    }
    private var developmentCollection: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            if entry.destination == .explore {
                Text("Discovery").font(MusicPageStyle.section)
                ForEach([NativeItemKind.sample, .tuner, .recap, .badge], id: \.self) { kind in
                    MediaRow(title: discoveryTitle(kind), subtitle: "Development navigation example") { openDevelopment(kind, id: kind.rawValue) }
                }
            }
            if entry.filter == "Downloaded only" {
                EmptyState(title: "No downloaded items", message: "This development collection contains no retained media.")
            } else {
                // The lazy layout indexes actual rows only. Conditional headers, empty
                // states and paging controls are measured outside that item sequence.
                LazyVStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    ForEach(visibleDevelopmentIndices, id: \.self) { index in
                        let identifier = "development-\(entry.page * 80 + index)"
                        let title = "Development item \(entry.page * 80 + index + 1)"
                        HStack {
                            Toggle(isOn: Binding(get: { entry.selection.contains(identifier) }, set: { selected in
                                if selected { navigation.session.current.selection.insert(identifier) } else { navigation.session.current.selection.remove(identifier) }
                            })) { Text("Select \(title)") }.labelsHidden().accessibilityLabel(Text("Select \(title)"))
                            MediaRow(title: title, subtitle: "Navigation test data · No service media", selected: entry.selection.contains(identifier)) { openDevelopment(.song, id: identifier) }
                        }.id(identifier)
                    }
                }
                HStack {
                    Button("Previous page") { collectionStore.rewind(); navigation.session.current.page = max(0, entry.page - 1) }.disabled(entry.page == 0)
                    Button("Next page") { collectionStore.rewind(); navigation.session.current.page += 1 }.disabled(entry.page >= 624).accessibilityIdentifier("nextCollectionPage")
                }.musicPageAction().padding(.top, MusicSpace.md)
            }
        }
    }
    private var visibleDevelopmentIndices: [Int] {
        (0..<80).filter { index in
            entry.query.isEmpty || "Development item \(entry.page * 80 + index + 1)".localizedStandardContains(entry.query)
        }
    }
    private func discoveryTitle(_ kind: NativeItemKind) -> String {
        switch kind {
        case .sample: String(localized: "Samples")
        case .tuner: String(localized: "Music tuner")
        case .recap: String(localized: "Recap")
        case .badge: String(localized: "Badges")
        default: String(localized: "Untitled item")
        }
    }
    private func openDevelopment(_ kind: NativeItemKind, id: String) {
        if let item = try? NativeItemRoute(kind: kind, identifier: id) { navigation.open(entry.destination, item: item) }
    }
}

#if DEBUG
/// Local observable state: live geometry updates only this readout, never the shell/session.
@MainActor @Observable final class LiveScrollDiagnostic {
    var offset: Double = 0; var maximum: Double = 0; var contentHeight: Double = 0
}
struct ScrollDiagnosticReadout: View {
    let live: LiveScrollDiagnostic
    @Bindable var navigation: BrowserNavigation
    var body: some View {
        HStack {
            Text("Live scroll (pt): \(String(format: "%.2f", live.offset))").accessibilityIdentifier("designLiveScrollOffset")
            Text("Maximum scroll (pt): \(String(format: "%.2f", live.maximum))").accessibilityIdentifier("designScrollMaximum")
            Text("Content height (pt): \(String(format: "%.2f", live.contentHeight))").accessibilityIdentifier("designScrollContentHeight")
            Text("Stored scroll (pt): \(String(format: "%.2f", navigation.session.current.scrollOffset))").accessibilityIdentifier("designScrollOffset")
        }.font(.caption).padding(MusicSpace.xxs).allowsHitTesting(false)
    }
}
#endif
