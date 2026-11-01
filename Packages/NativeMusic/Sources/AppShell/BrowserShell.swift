import SwiftUI
import AppKit
import Features
import Domain
import Queue
import Playback
import DesignSystem
import SystemIntegration

struct BrowserShell: View {
    @Bindable var accounts: LocalAccountBootstrap
    @State private var navigation = BrowserNavigation()
    @SceneStorage("browser-window-id-v2") private var windowIDString = ""
    @SceneStorage("browser-session-v1") private var obsoleteUnboundState: Data?
    @State private var restored = false
    @State private var tint = WindowArtworkTint()
    /// One namespace for the whole player: the glass surface, artwork, title, artist and controls keep their identity between the bar and the expanded player.
    @Namespace private var artworkNamespace
    /// The bar's measured height: the slot the split view leaves for it while the bar floats in the player layer (and keeps while it is expanded).
    @State private var barHeight: CGFloat = 112
    /// The YouTube Music cover's light, published by whichever cover is on screen (the bar's, or the expanded player's) and held here across the morph.
    @State private var webAccent: MusicTint?
    @State private var navigationMotion = MusicMotion.navigation
    @State private var windowVisible = false
    @State private var invalidLink = false
    @State private var queuePage = 0
    @State private var confirmingWindowReset = false
    @State private var showAccounts = false
    @State private var panels = AdaptivePanelPresentation<TrailingPanel>()
    @State private var search: SearchModel
    @State private var searchFocus = 0
    @State private var queueRequestSeen: Int
    @State private var linkRequestSeen: Int
    @State private var hostWindow = WindowBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var phase
    #if DEBUG
    @State private var designRasterBytes = 0
    @State private var designPipelineState = "not polled"
    @State private var designPollTicks = 0
    #endif
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let showsQAReadouts: Bool
    enum TrailingPanel: String, CaseIterable { case queue = "Queue", lyrics = "Lyrics" }
    init(accounts: LocalAccountBootstrap, panels: AdaptivePanelPresentation<TrailingPanel> = .init(), navigation: BrowserNavigation = .init(), showsQAReadouts: Bool? = nil) {
        #if DEBUG
        self.showsQAReadouts = showsQAReadouts ?? accounts.nativeDesignTesting
        #else
        self.showsQAReadouts = false
        #endif
        self.accounts = accounts; _panels = State(initialValue: panels); _navigation = State(initialValue: navigation)
        _search = State(initialValue: accounts.makeSearchModel())
        _queueRequestSeen = State(initialValue: accounts.shell.queueRequest)
        _linkRequestSeen = State(initialValue: accounts.shell.linkRequest?.id ?? 0)
    }
    var body: some View {
        GeometryReader { geometry in
            let layout = BrowserLayout(width: geometry.size.width)
            VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
            } detail: {
                GeometryReader { available in
                VStack(spacing: 0) {
                WindowHistoryBanner(failure: accounts.windowAuthority.failure, reset: { confirmingWindowReset = true })
                    .fixedSize(horizontal: false, vertical: true)
                #if DEBUG
                if showsQAReadouts { debugQARow.fixedSize(horizontal: false, vertical: true) }
                #endif
                HStack(spacing: MusicSpace.sm) {
                    destination.musicContentZoom().id(navigation.session.current.id).musicTransition(.reveal).musicAnimation(navigationMotion, value: navigation.session.current.id, reduceMotion: reduceMotion, lowPower: lowPower, visible: windowVisible && phase != .background).frame(maxWidth: .infinity, maxHeight: .infinity).musicSurface().audit("detailPanel", group: "panels", kind: .region)
                        .anchorPreference(key: ShellPanelAnchor.self, value: .bounds) { $0 }
                        .opacity(expanded ? 0 : 1).allowsHitTesting(!expanded).accessibilityHidden(expanded)
                    if let trailing = panels.selection, panels.allowsInline, !expanded {
                        trailingPanel(trailing).musicContentZoom().frame(minWidth: 300, idealWidth: 320, maxWidth: 420).musicSurface().audit("trailingPanel", group: "panels", kind: .region).browserRegion("panel").accessibilityElement(children: .contain).accessibilityIdentifier("inlineTrailingPanel")
                            .musicTransition(.slideFromTrailing)
                    }
                }.padding(MusicSpace.sm).frame(maxWidth: .infinity, maxHeight: .infinity).browserRegion("detail")
                }.frame(width: available.size.width, height: available.size.height)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                // The bar floats in the player layer below (so it can become the expanded player); this slot keeps its room.
                Color.clear.frame(height: expanded ? 0 : barHeight)
                    .musicAnimation(.playerMorph, value: expanded, reduceMotion: reduceMotion, lowPower: lowPower, visible: windowVisible && phase != .background)
            }
            .overlayPreferenceValue(ShellPanelAnchor.self) { anchor in
                GeometryReader { overlay in playerLayer(panel: anchor.map { overlay[$0] }, size: overlay.size, layout: layout) }
            }
            .onChange(of: layout.showsTrailing, initial: true) { _, value in panels.allowsInline = value }
            .sheet(isPresented: Binding(get: { panels.presentsSheet }, set: { panels.sheetChanged($0) })) {
                VStack {
                    if let trailing = panels.selection { trailingPanel(trailing) }
                    Button("Done") { panels.selection = nil }.keyboardShortcut(.cancelAction).musicButtons().padding()
                }.frame(minWidth: 340, minHeight: 360).musicCanvas().accessibilityElement(children: .contain).accessibilityIdentifier("compactTrailingPanel")
            }
        }.background {
            MusicCanvas(artworkAccent: tint.displayed(for: accounts.artworkRequest, authority: accounts.artworkAuthority).map { Color(red: $0.red, green: $0.green, blue: $0.blue) })
        }
        .musicAnimation(.artworkColor, value: tint.displayed(for: accounts.artworkRequest, authority: accounts.artworkAuthority), reduceMotion: reduceMotion, lowPower: lowPower, visible: windowVisible)
        .background(WindowVisibility { windowVisible = $0; if !$0 { tint.retract() } })
        .background(HostWindowReader { hostWindow.window = $0 })
        // W21: the mini-player's and the status item's Queue button asks the window that is frontmost to show its queue.
        .environment(\.outputPickerRequest, accounts.shell.outputPickerRequest)
        .onChange(of: accounts.shell.queueRequest) { _, request in
            guard request != queueRequestSeen else { return }
            queueRequestSeen = request
            guard windowVisible, hostWindow.window.map({ $0.isMainWindow || $0.isKeyWindow || NSApp.mainWindow == nil }) ?? true else { return }
            if panels.selection != .queue { toggle(.queue) }
        }
        // W24: an App Intent's Search waits in the shell's inbox; the first visible, frontmost window types it and presses Return (SearchRequestReceiver).
        .modifier(SearchRequestReceiver(inbox: accounts.shell.searchInbox, search: search, visible: windowVisible,
                                        isFrontmost: { hostWindow.window.map({ $0.isMainWindow || $0.isKeyWindow || NSApp.mainWindow == nil }) ?? true },
                                        open: { navigation.open(.search); searchFocus += 1 }))
        .musicWindowEnvironment(visible: windowVisible)
        #if DEBUG
        .environment(\.sharingStandIn, accounts.isolatedQA)
        #endif
        .confirmationDialog("Reset saved window state?", isPresented: $confirmingWindowReset, titleVisibility: .visible) {
            Button("Reset saved window state", role: .destructive) { Task { await resetWindowState() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes this app’s saved window navigation, searches, filters and selections for all accounts. It does not delete listening history, accounts, music or remote data.")
        }
        // W27 (Replace explicit queue = Ask): a native start that would drop the songs the person queued waits for their answer. The buttons answer synchronously.
        .confirmationDialog("Keep your queued songs?", isPresented: Binding(get: { accounts.playback.pendingReplacement != nil }, set: { if !$0 { accounts.playback.cancelReplacement() } }), titleVisibility: .visible) {
            Button("Keep Queued Songs") { accounts.playback.resolveReplacement(.keep) }.accessibilityIdentifier("replacementKeep")
            Button("Replace Them", role: .destructive) { accounts.playback.resolveReplacement(.replace) }.accessibilityIdentifier("replacementReplace")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You queued \(accounts.playback.pendingReplacement?.count ?? 0) songs. Starting something new can keep them after it or replace them. Settings > Playback remembers your choice.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { navigationMotion = .navigation; navigation.back() } label: { Label("Back", systemImage: "chevron.left") }.disabled(!navigation.session.canBack).help(Text("Back")).accessibilityIdentifier("browserBack")
                Button { navigationMotion = .navigation; navigation.forward() } label: { Label("Forward", systemImage: "chevron.right") }.disabled(!navigation.session.canForward).help(Text("Forward")).accessibilityIdentifier("browserForward")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                AccountSwitcher(label: "Accounts", pending: accounts.model.busy) { showAccounts = true }.accessibilityIdentifier("manageAccounts")
                Button { toggle(.lyrics) } label: { Label("Lyrics", systemImage: "quote.bubble") }.help(Text("Lyrics"))
                Button { toggle(.queue) } label: { Label("Queue", systemImage: "list.bullet") }.accessibilityIdentifier("browserQueue")
            }
        }
        .sheet(isPresented: $showAccounts) {
            VStack { AccountsView(model: accounts.model); Button("Done") { showAccounts = false }.keyboardShortcut(.cancelAction).musicButtons().padding() }
                .musicCanvas().musicSignInSheet(accounts.model.signIn)
        }
        // Google's sign-in page presents from the top sheet of this window only.
        .musicSignInSheet(accounts.model.signIn, enabled: !showAccounts)
        .announcesAccountChanges(accounts.model)
        .task {
            // Legacy unbound payloads are never decoded or migrated into an account.
            obsoleteUnboundState = nil
            if let id = UUID(uuidString: windowIDString) { navigation.session.windowID = id }
            else { windowIDString = navigation.session.windowID.uuidString }
            await accounts.load()
            accounts.windowAuthority.register(navigation)
            restored = true
            await restoreWindow()
        }
        .onChange(of: accounts.artworkAuthority.context) { _, _ in tint.retract() }
        .task(id: accounts.windowAuthority.context) { if restored { await restoreWindow() } }
        .onDisappear {
            let session = navigation.session, context = accounts.windowAuthority.context
            accounts.windowAuthority.close(navigation)
            Task {
                guard context.account != nil, accounts.windowAuthority.historyEnabled else { return }
                do { try await accounts.windowStore?.save(session, context: context); accounts.windowAuthority.savedClosed(session.windowID, context: context) }
                catch WindowRestorationError.staleOwner { }
                catch { accounts.windowAuthority.historyUnavailable() }
            }
        }
        // W26: a link only navigates. The strict policy decides; a refusal is one sentence that names nothing.
        .onOpenURL { url in open(LinkPolicy.parse(url)) }
        .onChange(of: accounts.shell.linkRequest) { _, request in
            // Services, Handoff, AppleScript and Reveal ask the window that is in front.
            guard let request, request.id != linkRequestSeen else { return }
            linkRequestSeen = request.id
            guard windowVisible, hostWindow.window.map({ $0.isMainWindow || $0.isKeyWindow || NSApp.mainWindow == nil }) ?? true else { return }
            open(.success(request.destination))
        }
        .dropDestination(for: URL.self) { urls, _ in dropped(urls.first?.absoluteString) }
        .dropDestination(for: String.self) { texts, _ in dropped(texts.first) }
        .userActivity(HandoffActivity.activityType, isActive: handoff != nil) { activity in handoff?.configure(activity) }
        .onContinueUserActivity(HandoffActivity.activityType) { activity in
            guard let destination = HandoffActivity.destination(of: activity) else { invalidLink = true; return }
            open(.success(destination))
        }
        .alert("This link cannot be opened", isPresented: $invalidLink) {
            Button("OK", role: .cancel) {}
        } message: { Text(LinkRefusal.message) }
        .task(id: navigation.session) {
            guard restored, accounts.windowAuthority.historyEnabled else { return }
            let session = navigation.session, context = accounts.windowAuthority.context
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                if context.account != nil { try await accounts.windowStore?.save(session, context: context) }
            } catch is CancellationError { }
            catch WindowRestorationError.staleOwner { }
            catch { accounts.windowAuthority.historyUnavailable() }
        }
        .task(id: windowVisible) {
            #if DEBUG
            guard accounts.nativeDesignTesting, windowVisible else { return }
            while !Task.isCancelled {
                if let pipeline = accounts.artwork {
                    let native = await pipeline.nativeSnapshot(), queue = await pipeline.snapshot()
                    designRasterBytes = native.largestRasterBytes
                    designPipelineState = "decodeAttempts \(native.decodeAttempts), completed \(native.completedDecodes), sourceLoads \(queue.sourceLoads), pending \(queue.pendingLoads), active \(queue.activeLoads), waiters \(queue.waiters)"
                } else { designPipelineState = "no pipeline" }
                designPollTicks += 1
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            #endif
        }
        // W18-F1: the podcast surface is injected ONCE here, at the shell root, so the bottom bar and the expanded player (which sit outside the
        // detail pages) read the same instance as the episode and show pages. It is the bootstrap's own surface, never a second one.
        .environment(\.podcastsSurface, accounts.podcasts)
        .onReceive(MusicGlassPower.changes) { _ in lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        .onAppear { search.opener = Self.opener(accounts: accounts, navigation: navigation) }
        .modifier(SearchPaletteHost(accounts: accounts, navigation: navigation, search: search, focusToken: $searchFocus,
                                    toggleQueue: { toggle(.queue) }, toggleLyrics: { toggle(.lyrics) }, manageAccounts: { showAccounts = true }))
    }
    private func open(_ parsed: Result<LinkDestination, LinkRefusal>) {
        guard case .success(let destination) = parsed else { invalidLink = true; return }
        navigationMotion = .navigation
        if !LinkNavigation.apply(destination, to: navigation) { invalidLink = true }
    }
    /// A link dropped on the window: parsed like any other, and only navigates.
    private func dropped(_ text: String?) -> Bool {
        guard let parsed = LinkDrop.destination(from: text) else { return false }
        guard case .success = parsed else { invalidLink = true; return false }
        open(parsed); return true
    }
    /// What Handoff advertises for the page in front: the public link and the navigation context of an item page, never for a private screen. An
    /// automated (isolated) launch advertises nothing, so a test never publishes to the account holder's other devices.
    private var handoff: HandoffActivity? {
        guard !LaunchStorageDecision.isIsolated, let route = navigation.session.current.item, let kind = LinkItemKind(rawValue: route.kind.rawValue) else { return nil }
        return HandoffActivity(item: LinkItem(kind: kind, identifier: route.identifier))
    }
    /// Opening a search result: its page, in the Search destination so Back returns to the results.
    static func opener(accounts: LocalAccountBootstrap, navigation: BrowserNavigation, after: @escaping @MainActor () -> Void = {}) -> @MainActor (SearchResult) -> Void {
        { [weak navigation] result in
            guard let navigation, let route = accounts.catalog.route(for: result) else { return }
            accounts.catalog.rememberTitle(result.title, for: route)
            navigation.open(.search, item: route)
            after()
        }
    }
    #if DEBUG
    private var debugQARow: some View {
                    ScrollView(.horizontal) { HStack {
                        Text("Native design test data · Not YouTube Music")
                        Text("Raster bytes: \(designRasterBytes)").accessibilityIdentifier("designRasterBytes")
                        Text("Pipeline: \(designPipelineState)").accessibilityIdentifier("designPipelineState")
                        Text("Poll ticks: \(designPollTicks)").accessibilityIdentifier("designPollTicks")
                        Text("Window visible: \(windowVisible ? "yes" : "no"), scene \(String(describing: phase))").accessibilityIdentifier("designWindowVisible")
                        Text("Queue item position: \(accounts.developmentQueue?.trackedIndex ?? -1)").accessibilityIdentifier("designQueueIndex")
                        Text("Canvas accent: \(tint.displayed(for: accounts.artworkRequest, authority: accounts.artworkAuthority) == nil ? "absent" : "present")").accessibilityIdentifier("designCanvasTint")
                        Text("Selected: \(navigation.session.current.selection.count)").accessibilityIdentifier("designSelectionCount")
                        Text("Saved window state: \(accounts.windowAuthority.historyEnabled ? "enabled" : "disabled")").accessibilityIdentifier("designWindowHistory")
                    }.fixedSize(horizontal: true, vertical: false).font(.caption).padding(MusicSpace.xs).accessibilityElement(children: .contain) }
                    .scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true).browserRegion("debugRow")
    }
    #endif
    /// Now Playing is open: the bar has grown into the expanded player.
    private var expanded: Bool { navigation.session.current.destination == .nowPlaying }
    /// The tint both player surfaces get: the YouTube Music cover's while that plays, the window artwork's otherwise.
    /// Settings > Artwork accent: off removes the tint entirely.
    private var playerAccent: MusicTint? { accounts.playerAccent(web: webAccent, artwork: artworkLight, usesWebPlayer: accounts.playback.music != nil) }
    private var artworkLight: MusicTint? { tint.displayed(for: accounts.artworkRequest, authority: accounts.artworkAuthority).map { MusicTint(red: $0.red, green: $0.green, blue: $0.blue) } }
    private func openNowPlaying() { navigationMotion = .playerMorph; navigation.open(.nowPlaying) }
    private func collapseNowPlaying() {
        navigationMotion = .playerMorph
        if navigation.session.canBack { navigation.back() } else { navigation.open(.home) }
    }
    /// The player layer: the bar and the expanded player share ONE glass container and one namespace, so switching between them (an animated state
    /// change) morphs the glass shape and carries the artwork, title, artist and controls across. Both are the same playback owner's presentation.
    @ViewBuilder private func playerLayer(panel: CGRect?, size: CGSize, layout: BrowserLayout) -> some View {
        // The layer occupies only what it draws: the bar's strip while collapsed, the detail panel's corner-to-corner area while expanded. The glass
        // container is a hit-testable view of its own, so a full-window layer would swallow every click meant for the sidebar and the pages beneath.
        let open = expanded && panel != nil
        // W28 (L10N04): `panel` is measured from the window's physical left edge, so the layer is placed in physical terms too. Left-to-right, the expanded
        // player runs from the detail panel's left edge to the window's right edge; right-to-left (sidebar on the right) it runs from the window's left edge
        // to the detail panel's right edge. The content inside keeps the layout direction, so its own leading/trailing padding still mirrors.
        let rtl = layoutDirection == .rightToLeft
        let width = open ? (rtl ? (panel?.maxX ?? size.width) : size.width - (panel?.minX ?? 0)) : size.width
        let height = open ? size.height - (panel?.minY ?? 0) : barHeight
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                if !(open && rtl) { Spacer(minLength: 0) }
                MusicGlassGroup(spacing: MusicSpace.xs) {
                    ZStack(alignment: .bottom) {
                        if open {
                            ExpandedPlayer(model: accounts.playback, artwork: accounts.artwork, artworkRequest: accounts.artworkRequest, artworkAuthority: accounts.artworkAuthority,
                                           paletteChanged: { tint.receive($0, source: $1, current: accounts.artworkRequest.map(ArtworkTintIdentity.init), authority: accounts.artworkAuthority) },
                                           accent: playerAccent, accentChanged: { webAccent = $0 }, namespace: artworkNamespace, windowVisible: windowVisible, collapse: collapseNowPlaying, showQueue: { toggle(.queue) }, compact: layout.compactPlayer) {
                                if let trailing = panels.selection, panels.allowsInline {
                                    trailingPanel(trailing).frame(minWidth: 300, idealWidth: 320, maxWidth: 420)
                                        .background(MusicCorner.panel.shape.fill(Color.primary.opacity(0.06)))
                                        .browserRegion("panel").audit("expandedQueuePanel", group: "expandedRow", within: "playerExpanded")
                                        .accessibilityElement(children: .contain).accessibilityIdentifier("inlineTrailingPanel")
                                }
                            }
                            .padding(.trailing, MusicSpace.sm).padding(.bottom, MusicSpace.sm)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .musicTransition(.morphSwap)
                        } else {
                            PlaybackPanel(model: accounts.playback, artwork: accounts.artwork, artworkRequest: accounts.artworkRequest, artworkAuthority: accounts.artworkAuthority,
                                          paletteChanged: { tint.receive($0, source: $1, current: accounts.artworkRequest.map(ArtworkTintIdentity.init), authority: accounts.artworkAuthority) },
                                          artworkExpanded: false, artworkNamespace: artworkNamespace, showNowPlaying: openNowPlaying, compact: layout.compactPlayer, showQueue: { toggle(.queue) },
                                          accent: playerAccent, accentChanged: { webAccent = $0 })
                                .fixedSize(horizontal: false, vertical: true).browserRegion("player")
                                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { barHeight = $0 }
                                // No fade: a view at opacity 0 takes no clicks, and the bar must take the click that follows Back (the glass morph carries the motion).
                                .musicTransition(.morphSwap).zIndex(1)
                        }
                    }.frame(width: width, height: height, alignment: .bottom)
                }
                .environment(\.layoutDirection, layoutDirection)
                if open && rtl { Spacer(minLength: 0) }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .frame(width: size.width, height: size.height)
        .modifier(PlaybackObservation(model: accounts.playback))
        .musicAnimation(.playerMorph, value: expanded, reduceMotion: reduceMotion, lowPower: lowPower, visible: windowVisible && phase != .background)
    }
    private func toggle(_ panel: TrailingPanel) {
        musicWithAnimation(.navigation, reduceMotion: reduceMotion, lowPower: lowPower, visible: windowVisible && phase != .background) { panels.toggle(panel) }
    }
    private var sidebar: some View {
        List(selection: Binding<BrowserDestination?>(get: { navigation.session.current.destination }, set: { if let value = $0 { navigationMotion = .navigation; navigation.open(value) } })) {
            Section {
                ForEach([BrowserDestination.home, .explore, .search, .library, .downloads], id: \.self) { destination in
                    Label(LocalizedStringKey(destination.title), systemImage: destination.symbol).tag(destination).accessibilityIdentifier("nav-\(destination.rawValue)")
                }
            }
            Section("Your music") {
                ForEach([BrowserDestination.history, .uploads, .podcasts, .nowPlaying], id: \.self) { destination in
                    Label(LocalizedStringKey(destination.title), systemImage: destination.symbol).tag(destination).accessibilityIdentifier("nav-\(destination.rawValue)")
                }
            }
        }.listStyle(.sidebar).scrollContentBackground(.hidden)
            .safeAreaBar(edge: .bottom) {
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Text("Independent. Native. Yours.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                    SettingsLink { Label("Settings", systemImage: "gearshape") }.accessibilityIdentifier("openSettings").musicButtons().browserRegion("sidebarSettings")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(MusicSpace.md).browserRegion("sidebarFooter")
            }.scrollEdgeEffectStyle(.hard, for: .bottom).musicSurface().audit("sidebarPanel", group: "panels", kind: .region)
            .padding([.leading, .vertical], MusicSpace.sm)
    }
    @ViewBuilder private var destination: some View {
        switch navigation.session.current.destination {
        case .queue: queue
        // Now Playing is the expanded player, hosted beside the bar in the player layer (`playerLayer`); this destination keeps its navigation entry.
        case .nowPlaying: Color.clear
        default: BrowserDestinationView(navigation: navigation, accounts: accounts.model, playback: accounts.playback, manageAccounts: { showAccounts = true }, authorityGeneration: accounts.windowAuthority.context.accountGeneration, showsDiagnostics: showsQAReadouts, search: search, searchFocusToken: searchFocus, catalog: accounts.catalog, library: accounts.library, downloads: accounts.downloads, discovery: accounts.discovery, social: accounts.social, podcasts: accounts.podcasts, discoveryReadout: accounts.discoveryReadout).id(navigation.session.current.id)
        }
    }
    /// YouTube Music's player while it is the active source (the single playback owner).
    private var activeMusic: WebMusicPlayer? {
        guard WebMusicQueueSummary.isActive(accounts.playback.music) else { return nil }
        return accounts.playback.music
    }
    @ViewBuilder private var queue: some View {
        if let player = activeMusic {
            ScrollView {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    WebMusicQueueView(player: player).browserRegion("queueList")
                    // YouTube Music owns this queue and its upcoming items are not visible to the app, so there is nothing true to save.
                    QueueSaveAsPlaylistEntry(surface: accounts.library.playlists, songs: [], leftOut: 0,
                                             unavailableReason: String(localized: "YouTube Music manages the upcoming songs of this queue. The app only sees the one playing, so it can’t save this queue as a playlist."))
                        .padding(.horizontal, MusicSpace.md)
                }
            }
        } else { nativeQueue }
    }
    /// The queue's songs the app knows as YouTube Music items (a video id it read from a page), in queue order, and how many entries are not.
    private var savableQueue: (songs: [PlaylistAddition], leftOut: Int) {
        QueueSaveAsPlaylistEntry.songs(from: (currentQueueSnapshot?.session.entries ?? []).map { QueueSaveAsPlaylistEntry.Entry(media: $0.media.rawValue, consumed: $0.consumed, isAdvertisement: $0.segment == .advertisement) },
                                       known: { accounts.catalog.song($0) })
    }
    private var nativeQueue: some View {
        let entries = currentQueueSnapshot?.session.entries ?? []
        let page = min(queuePage, max(0, (entries.count - 1) / 80))
        let savable = savableQueue
        return VStack {
            QueueSaveAsPlaylistEntry(surface: accounts.library.playlists, songs: savable.songs, leftOut: savable.leftOut, unavailableReason: nil)
                .padding(.horizontal, MusicSpace.md).padding(.top, MusicSpace.xs)
            QueueList(rows: entries.dropFirst(page * 80).prefix(80).map {
                QueueRow(id: $0.id, title: mediaTitle($0.media), segment: queueSegment($0.segment.rawValue), current: $0.id == currentQueueSnapshot?.current?.id, enabled: !$0.consumed, editable: !$0.consumed && $0.id != currentQueueSnapshot?.current?.id && $0.segment != .advertisement && !(currentQueueSnapshot?.metadata.immutable.contains($0.id) ?? false))
            }, boundary: QueuePageBoundary(previous: page > 0 ? queueRow(entries[page * 80 - 1]) : nil, following: entries.dropFirst((page + 1) * 80).prefix(2).map(queueRow)), page: page, move: { ids, target in moveQueue(ids, target: target) }) { id in selectQueue(id) }.browserRegion("queueList")
            if entries.count > 80 {
                HStack {
                    Button("Previous page") { queuePage = max(0, page - 1) }.disabled(page == 0)
                    Text("Page \(page + 1)").font(.caption)
                    Button("Next page") { queuePage = page + 1 }.disabled((page + 1) * 80 >= entries.count).browserRegion("nextPage")
                }.musicButtons().padding(MusicSpace.xs).browserRegion("queueFooter")
            }
        }
    }
    private var currentQueueSnapshot: QueueSnapshot? {
        #if DEBUG
        accounts.playback.state?.queue ?? accounts.developmentQueue?.snapshot
        #else
        accounts.playback.state?.queue
        #endif
    }
    private func mediaTitle(_ media: ServiceID) -> String {
        #if DEBUG
        if accounts.playback.session == nil, let title = accounts.developmentQueue?.titles[media] { return title }
        #endif
        return accounts.playback.title(for: media)
    }
    private func moveQueue(_ ids: [UUID], target: UUID?) {
        #if DEBUG
        if accounts.playback.session == nil, let queue = accounts.developmentQueue { Task { await queue.send(.move(ids, before: target)) }; return }
        #endif
        Task { await accounts.playback.act(action: .reorderQueue) { try await $0.sendQueue(.move(ids, before: target)) } }
    }
    private func selectQueue(_ id: UUID) {
        #if DEBUG
        if accounts.playback.session == nil, let queue = accounts.developmentQueue { Task { await queue.send(.select(id)) }; return }
        #endif
        Task { await accounts.playback.act(action: .selectQueue) { try await $0.select(id) } }
    }
    private func queueRow(_ entry: Domain.QueueEntry) -> QueueRow {
        QueueRow(id: entry.id, title: mediaTitle(entry.media), segment: queueSegment(entry.segment.rawValue), current: entry.id == currentQueueSnapshot?.current?.id, enabled: !entry.consumed, editable: !entry.consumed && entry.id != currentQueueSnapshot?.current?.id && entry.segment != .advertisement && !(currentQueueSnapshot?.metadata.immutable.contains(entry.id) ?? false))
    }
    private func resetWindowState() async {
        guard let store = accounts.windowStore else { return }
        let context = accounts.windowAuthority.context
        do {
            let enabled = try await store.resetSavedWindowState(context: context)
            let epoch = await store.currentEpoch
            accounts.windowAuthority.historyReset(context: context, enabled: enabled, epoch: epoch)
        } catch is CancellationError { }
        catch WindowRestorationError.staleOwner { }
        catch { accounts.windowAuthority.failure = String(localized: "Saved window state could not be reset safely. Your account remains usable. Try again after fixing this app’s window-state storage.") }
    }
    private func restoreWindow() async {
        let context = accounts.windowAuthority.context, revision = navigation.revision
        guard context.account != nil, accounts.windowAuthority.historyEnabled else { return }
        do {
            if let session = try await accounts.windowStore?.restore(window: navigation.session.windowID, context: context) {
                accounts.windowAuthority.installRestored(session, context: context, revision: revision, into: navigation)
            }
        } catch is CancellationError { }
        catch WindowRestorationError.staleOwner { }
        catch { guard accounts.windowAuthority.accepts(context), navigation.revision == revision else { return }; accounts.windowAuthority.historyUnavailable() }
    }
    private func queueSegment(_ value: String) -> String {
        switch value {
        case "playNext": String(localized: "Play next")
        case "addToQueue", "user": String(localized: "Added to queue")
        case "recommendation": String(localized: "Autoplay")
        case "history": String(localized: "Recently played")
        case "advertisement": String(localized: "Advertisement")
        default: String(localized: "From your selection")
        }
    }
    /// The song the player is on: nil for nothing, an advertisement, or an episode (spoken audio has no song lyrics).
    private var lyricsVideoID: String? {
        #if DEBUG
        if let forced = DevelopmentPodcasts.lyricsVideoOverride { return forced }
        #endif
        guard let player = accounts.playback.music, !player.isClosed else { return nil }
        let state = player.snapshot
        guard !state.isAd, state.phase != .idle, let id = state.videoID else { return nil }
        return accounts.podcasts.playback.current?.videoID == id ? nil : id
    }
    private var lyricsPanel: some View {
        let podcasts = accounts.podcasts
        return LyricsPanelView(model: podcasts.lyrics, follow: podcasts.follow, videoID: lyricsVideoID, position: { accounts.playback.music?.timeline.position ?? 0 })
    }
    @ViewBuilder private func trailingPanel(_ panel: TrailingPanel) -> some View {
        VStack(spacing: MusicSpace.xs) {
            Picker("Panel", selection: Binding(get: { panels.selection ?? panel }, set: { panels.selection = $0 })) {
                ForEach(TrailingPanel.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented).padding(MusicSpace.sm).browserRegion("panelPicker").accessibilityIdentifier("trailingPanelPicker")
            if panel == .queue { queue } else { lyricsPanel }
        }
    }
}

/// Actual root sibling: dynamic banner height is allocated before the split view.
struct WindowHistoryBanner: View {
    let failure: String?
    let reset: () -> Void
    var body: some View {
        if let failure {
            VStack {
                Text(LocalizedStringKey(failure)).accessibilityIdentifier("windowHistoryNotice")
                Button("Reset saved window state…", action: reset).accessibilityIdentifier("resetWindowState")
            }.padding(MusicSpace.sm).musicSurface().padding(MusicSpace.sm).browserRegion("banner")
        }
    }
}

/// The detail panel's bounds, reported to the root so the expanded player can take exactly its place (and extend over the trailing panel's).
struct ShellPanelAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}
