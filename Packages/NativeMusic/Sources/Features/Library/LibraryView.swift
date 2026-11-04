import AccountSession
import DesignSystem
import SwiftUI

/// The state of one change, at the item it applies to: a spinner while it is pending, the reason and a way forward when it
/// failed or its outcome is unknown. Nothing here claims success the service did not confirm.
struct LibraryWriteLine: View {
    @Bindable var ledger: LibraryWriteLedger
    let keys: [LibraryWriteKey]
    /// Names the item the line belongs to, so each item's change state is its own element.
    var scope = ""
    var body: some View {
        ForEach(keys, id: \.self) { key in
            if let write = ledger.write(key) {
                line(write, key: key)
            }
        }
    }
    @ViewBuilder private func line(_ write: LibraryWrite, key: LibraryWriteKey) -> some View {
        switch write.state {
        case .pending:
            HStack(spacing: MusicSpace.xs) { ProgressView().controlSize(.small); Text("Saving this change…").font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                .accessibilityElement(children: .combine).accessibilityIdentifier("libraryWritePending-" + scope)
        case .confirmed:
            Label("Done", systemImage: "checkmark.circle").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("libraryWriteConfirmed-" + scope)
        case .failed(let failure):
            HStack(spacing: MusicSpace.xs) {
                Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("libraryWriteFailed-" + scope)
                if failure != .needsSignIn && failure != .sessionEnded && failure != .notOffered {
                    Button("Try Again") { Task { await ledger.retry(key) } }.musicPageAction().accessibilityIdentifier("libraryWriteRetry-" + scope)
                }
                Button("Dismiss") { ledger.dismiss(key) }.musicPageAction().accessibilityIdentifier("libraryWriteDismiss-" + scope)
            }
            .onAppear { Announcer.post(failure.message, kind: .error) }
        case .needsReconciliation:
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                HStack(spacing: MusicSpace.xs) {
                    Label("YouTube Music didn’t confirm this change. It may or may not have been applied.", systemImage: "questionmark.circle").font(.caption)
                        .foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("libraryWriteUnconfirmed-" + scope)
                    if !write.checkedUnreadable { Button("Check") { Task { await ledger.check(key) } }.musicPageAction().accessibilityIdentifier("libraryWriteCheck-" + scope) }
                }
                if write.checkedUnreadable {
                    HStack(spacing: MusicSpace.xs) {
                        Text("YouTube Music couldn’t say either. Trying again sets the same state again and can’t duplicate anything.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                            .accessibilityIdentifier("libraryWriteUncheckable-" + scope)
                        Button("Try Again") { Task { await ledger.retry(key) } }.musicPageAction().accessibilityIdentifier("libraryWriteRetry-" + scope)
                        Button("Dismiss") { ledger.dismissUnconfirmed(key) }.musicPageAction().accessibilityIdentifier("libraryWriteDismiss-" + scope)
                    }
                }
            }
        }
    }
}

/// Buttons for a set of controls: each is one explicit request for one item, disabled while that item's change is pending.
struct LibraryControlRow: View {
    @Bindable var ledger: LibraryWriteLedger
    @Environment(\.socialSurface) private var social
    let controls: [LibraryControl]
    let identifier: String
    var showsTitles = false
    var body: some View {
        HStack(spacing: MusicSpace.xxs) {
            ForEach(controls) { control in
                Group {
                    if showsTitles {
                        Button { Task { await press(control) } } label: { Label(control.title, systemImage: control.symbol) }.labelStyle(.titleAndIcon)
                    } else {
                        Button { Task { await press(control) } } label: { Label(control.title, systemImage: control.symbol) }.labelStyle(.iconOnly)
                    }
                }
                .help(Text(control.title)).accessibilityLabel(Text(control.title))
                .accessibilityValue(Text(control.isOn ? "On" : "Off"))
                .disabled(ledger.isBusy(control.key))
                .musicPageAction().accessibilityIdentifier("libraryControl-\(control.kind.rawValue)-" + identifier)
            }
        }
    }
}

extension LibraryControlRow {
    /// A like or dislike goes through the social surface (role check, outcome record), which hands it to this same ledger; every other change is the ledger's as before.
    @MainActor func press(_ control: LibraryControl) async { await LibraryControlPress.press(control, ledger: ledger, social: social) }
}
/// The one place a control press reaches the ledger. The window's buttons and the mini-player's Like both call it (W21), so a press means the
/// same thing wherever it is made and the ledger's entry points stay in this file.
@MainActor public enum LibraryControlPress {
    public static func press(_ control: LibraryControl, ledger: LibraryWriteLedger, social: SocialSurface?) async {
        if let social, control.kind == .like || control.kind == .dislike { await social.rate(control) { await ledger.submit(control.intent) } } else { await ledger.submit(control.intent) }
    }
}

/// The change buttons an entry published for itself.
struct LibraryControlButtons: View {
    @Bindable var surface: LibrarySurface
    let item: MusicCatalogItem
    let source: LibrarySource?
    var body: some View {
        LibraryControlRow(ledger: surface.ledger, controls: LibraryControls.make(item: item, source: source, ledger: surface.ledger), identifier: item.id)
    }
}

struct LibraryRow: View {
    @Bindable var surface: LibrarySurface
    let entry: LibraryEntry
    let source: LibrarySource
    let navigator: CatalogNavigator
    var body: some View {
        let item = entry.item
        let offers = surface.offers(for: item)
        let controls = LibraryControls.make(item: item, source: source, ledger: surface.ledger)
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            HStack(spacing: MusicSpace.sm) {
                HStack(spacing: MusicSpace.sm) {
                    CatalogArtworkView(thumbnails: item.thumbnails, edge: 44, corner: .thumbnail)
                    VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                        HStack(spacing: MusicSpace.xxs) {
                            Text(item.title).font(.body).lineLimit(2)
                            if item.explicit { ExplicitBadge() }
                            if entry.repeats { Text("Appears more than once").font(.caption2).foregroundStyle(MusicStyle.secondaryText) }
                        }
                        let line = item.detailLine()
                        if !line.isEmpty { Text(line).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(2) }
                    }
                    Spacer(minLength: 8)
                    if let duration = item.durationText { Text(duration).font(.callout.monospacedDigit()).foregroundStyle(MusicStyle.secondaryText) }
                }
                .opacity(item.availability == .unavailable ? 0.55 : 1)
                .songDraggable(videoID: item.videoID, title: item.title, kind: item.kind)
                .accessibilityElement(children: .combine).accessibilityLabel(Text(item.accessibilitySummary))
                .accessibilityIdentifier("libraryRow-" + entry.id)
                if offers.contains(where: { $0.action == .play }), CatalogActionPlan.canEverPlay(item) {
                    Button { Task { await surface.perform(.play, on: item, key: entry.id) } } label: { Label("Play", systemImage: "play.fill") }
                        .labelStyle(.iconOnly).help(Text("Play \(item.title)")).accessibilityLabel(Text("Play \(item.title)"))
                        .accessibilityIdentifier("libraryPlay-" + entry.id).musicPageAction()
                }
                LibraryControlButtons(surface: surface, item: item, source: source)
            }
            FeedbackLine(feedback: surface.feedback[entry.id])
            LibraryWriteLine(ledger: surface.ledger, keys: controls.map(\.key).uniqued(), scope: item.id)
        }
        .musicPageRow()
        .accessibilityActions {
            ForEach(offers.filter(\.isAvailable)) { offer in Button(offer.action.title) { Task { await surface.perform(offer.action, on: item, key: entry.id) } } }
            ForEach(controls) { control in Button(control.title) { Task { await surface.ledger.submit(control.intent) } } }
        }
    }
}
extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}

struct LibraryCard: View {
    @Bindable var surface: LibrarySurface
    @Bindable var model: LibraryCollectionModel
    let entry: LibraryEntry
    let navigator: CatalogNavigator
    private let edge: CGFloat = 168
    var body: some View {
        let item = entry.item
        let controls = LibraryControls.make(item: item, source: model.source, ledger: surface.ledger)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            ZStack(alignment: .topLeading) {
                CatalogArtworkView(thumbnails: item.thumbnails, edge: edge)
                Button { model.toggle(entry.id) } label: { Image(systemName: model.selection.contains(entry.id) ? "checkmark.circle.fill" : "circle") }
                    .buttonStyle(.plain).padding(MusicSpace.xs).help(Text("Select \(item.title)"))
                    .accessibilityLabel(Text("Select \(item.title)")).accessibilityValue(Text(model.selection.contains(entry.id) ? "Selected" : "Not selected"))
                    .accessibilityIdentifier("libraryCardSelect-" + entry.id)
            }
            Button { if item.opensPage { navigator.openItem(item) } } label: {
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    HStack(spacing: MusicSpace.xxs) { Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2); if item.explicit { ExplicitBadge() } }
                    Text(item.detailLine()).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(2)
                }.frame(width: edge, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!item.opensPage)
                .accessibilityElement(children: .combine).accessibilityLabel(Text(item.accessibilitySummary))
                .accessibilityIdentifier("libraryRow-" + entry.id)
            HStack(spacing: MusicSpace.xxs) {
                if CatalogActionPlan.canEverPlay(item), surface.offers(for: item).contains(where: { $0.action == .play && $0.isAvailable }) {
                    Button { Task { await surface.perform(.play, on: item, key: entry.id) } } label: { Label("Play", systemImage: "play.fill") }
                        .labelStyle(.iconOnly).help(Text("Play \(item.title)")).accessibilityLabel(Text("Play \(item.title)"))
                        .accessibilityIdentifier("libraryPlay-" + entry.id).musicPageAction()
                }
                LibraryControlButtons(surface: surface, item: item, source: model.source)
            }
            FeedbackLine(feedback: surface.feedback[entry.id]).frame(width: edge, alignment: .leading)
            LibraryWriteLine(ledger: surface.ledger, keys: controls.map(\.key).uniqued(), scope: item.id).frame(width: edge, alignment: .leading)
        }.frame(width: edge, alignment: .leading)
            .modifier(LibraryPlaylistDrop(item: item))
    }
}
/// A playlist card is a place to drop songs: it opens the add sheet for that playlist.
struct LibraryPlaylistDrop: ViewModifier {
    let item: MusicCatalogItem
    func body(content: Content) -> some View {
        if item.kind == .playlist, let browse = item.browseID { content.playlistDropTarget(playlistID: browse, title: item.title) } else { content }
    }
}

/// The distinct states of a collection, each with its own wording and way forward.
struct LibraryStateView: View {
    @Bindable var model: LibraryCollectionModel
    let openAccounts: () -> Void
    var body: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity, minHeight: 160).accessibilityIdentifier("libraryState-loading")
        case .empty:
            ContentUnavailableView { Label(model.source.kind?.emptyTitle ?? String(localized: "Nothing here yet"), systemImage: model.source.kind?.symbol ?? "clock") }
                description: { Text("YouTube Music has nothing in this collection. It was read completely.") }
                .accessibilityIdentifier("libraryState-empty")
        case .restricted(let reason):
            ContentUnavailableView {
                Label(reason == .sessionEnded ? "Your session ended" : reason == .notAvailableHere ? "Not available here" : "Sign in to see this", systemImage: "lock")
            } description: {
                Text(reason == .sessionEnded ? "Sign in again to read your library. Your local data is kept."
                     : reason == .notAvailableHere ? "YouTube Music doesn’t offer this collection to this account or version."
                     : "Your library belongs to your YouTube Music account.")
            } actions: {
                if reason != .notAvailableHere { Button("Manage Accounts", action: openAccounts).musicPageAction() }
            }.accessibilityIdentifier("libraryState-restricted")
        case .offline:
            ContentUnavailableView {
                Label("You’re offline", systemImage: "wifi.slash")
            } description: { Text("YouTube Music couldn’t be reached, and there is no saved copy of this collection yet.") } actions: {
                Button("Try Again") { Task { await model.load() } }.musicPageAction()
            }.accessibilityIdentifier("libraryState-offline")
        case .unrecognised:
            ContentUnavailableView {
                Label("This page isn’t readable yet", systemImage: "questionmark.square.dashed")
            } description: { Text("YouTube Music sent this collection in a form this version can’t read. That isn’t the same as an empty library.") } actions: {
                Button("Try Again") { Task { await model.load() } }.musicPageAction()
            }.accessibilityIdentifier("libraryState-unrecognised")
        case .failed(let failure):
            ContentUnavailableView {
                Label("This collection couldn’t be loaded", systemImage: "exclamationmark.circle")
            } description: { Text(failure.message) } actions: {
                Button("Try Again") { Task { await model.load() } }.musicPageAction()
            }.accessibilityIdentifier("libraryState-failed")
        case .noMatches:
            ContentUnavailableView.search(text: model.query).accessibilityIdentifier("libraryState-noMatches")
        case .content:
            EmptyView()
        }
    }
}
extension LibraryFailure {
    var message: String {
        switch self {
        case .needsSignIn: String(localized: "Sign in to YouTube Music to read this.")
        case .sessionEnded: String(localized: "Your session ended. Sign in again.")
        case .offline: String(localized: "YouTube Music couldn’t be reached. Check your connection and try again.")
        case .rateLimited: String(localized: "YouTube Music is asking for a pause. Try again in a moment.")
        case .unavailable: String(localized: "YouTube Music couldn’t answer this request. Try again.")
        case .unrecognised: String(localized: "YouTube Music sent a page in a form this version can’t read yet.")
        case .scopeChanged: String(localized: "Your account changed while this loaded. Try again.")
        case .notAvailableHere: String(localized: "YouTube Music doesn’t offer this collection to this account or version.")
        }
    }
}

/// Where the rows came from and what they cover: a saved copy, stale, refresh failed, partly loaded, left out.
struct LibraryStatusLine: View {
    @Bindable var model: LibraryCollectionModel
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            HStack(spacing: MusicSpace.xs) {
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Text(freshness).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("libraryFreshness")
            }
            if !model.coversEverything, !model.entries.isEmpty {
                Text(coverage).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("libraryCoverage")
            }
            if model.leftOut > 0 {
                Text("\(model.leftOut) items couldn’t be shown").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("libraryLeftOut")
            }
            if model.pagingEnded != nil {
                Text("YouTube Music stopped sending more of this collection before the end.").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("libraryPagingEnded")
            }
        }
    }
    private var freshness: String {
        guard let at = model.fetchedAt else { return "" }
        let time = at.formatted(date: .omitted, time: .shortened)
        if let failure = model.refreshFailure { return String(localized: "Couldn’t refresh. Showing a saved copy from \(time). \(failure.message)") }
        if model.isRefreshing { return String(localized: "Refreshing…") }
        if model.isStale { return String(localized: "Out of date. Last updated \(time).") }
        return String(localized: "Updated \(time).")
    }
    private var coverage: String {
        if model.sort != .service || model.searching { return String(localized: "Only the \(model.entries.count) items loaded so far are covered. Load all to cover the whole collection.") }
        return String(localized: "\(model.entries.count) items loaded so far. There is more.")
    }
}

/// A collection: search, sort, layout, multi-selection and complete incremental paging over the service's order.
struct LibraryCollectionView: View {
    @Bindable var surface: LibrarySurface
    @Bindable var model: LibraryCollectionModel
    /// The list restores by row identity (W09-F2): the page's one `IdentityRestorer`, shared with the Library view that remembers the visit.
    let identity: IdentityRestorer
    let navigator: CatalogNavigator
    let openAccounts: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            controls
            LibraryStateView(model: model, openAccounts: openAccounts)
            if case .content = model.state { content }
        }
        // Saved rows first; rows older than the freshness bound are refreshed in the same breath (SYNC02, SYNC03).
        .task(id: surface.selectedKind) { await model.load(); if model.isStale { await model.refresh() } }
    }
    private var controls: some View {
        MusicGlassGroup {
            HStack(spacing: MusicSpace.xs) {
                TextField("Search this collection", text: $model.query).accessibilityIdentifier("libraryQuery").musicField(dense: true).frame(maxWidth: 320)
                Picker("Sort", selection: $model.sort) {
                    ForEach(model.availableSorts) { Text($0.title).tag($0) }
                }.frame(maxWidth: 192).accessibilityIdentifier("librarySort")
                Picker("Layout", selection: $model.layout) {
                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 92).accessibilityLabel(Text("Layout")).accessibilityIdentifier("libraryLayout")
                if model.hasMore {
                    Button { Task { await model.loadAll() } } label: { Label("Load All", systemImage: "arrow.down.to.line") }
                        .musicPageAction().disabled(model.loadingMore).accessibilityIdentifier("libraryLoadAll")
                }
                Spacer()
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly).help(Text("Refresh")).musicPageAction().disabled(model.isRefreshing).accessibilityIdentifier("libraryRefresh")
                    .keyboardShortcut("r", modifiers: .command)
            }
        }.audit("libraryControls", group: "page-top", within: "detailPanel", alignLeading: "pageLeading")
    }
    @ViewBuilder private var content: some View {
        let entries = model.visibleEntries
        if !model.selection.isEmpty { selectionBar }
        Group {
            if model.layout == .grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: MusicSpace.md, alignment: .top)], alignment: .leading, spacing: MusicSpace.lg) {
                        ForEach(entries) { LibraryCard(surface: surface, model: model, entry: $0, navigator: navigator) }
                    }.padding(.vertical, MusicSpace.xs)
                    footer
                }.restoresScroll().accessibilityIdentifier("libraryGrid")
            } else {
                // W44-prep (PERF): the list is its own view with an equality check on the list it shows. SwiftUI re-lists every row of a `List` whenever the
                // view that builds it re-evaluates, and this view re-evaluates for every paging flag; at 50,000 rows that was ~1 s per flip.
                LibraryEntryList(surface: surface, model: model, navigator: navigator, identity: identity, entries: entries, generation: model.visibleGeneration).equatable()
            }
        }
    }
    private var selectionBar: some View {
        HStack(spacing: MusicSpace.xs) {
            Text("\(model.selection.count) selected").accessibilityIdentifier("librarySelectionCount")
            Button("Copy Links") { _ = surface.copyLinks(of: model.selectedEntries) }.musicPageAction().accessibilityIdentifier("libraryCopyLinks")
            SelectionAddToPlaylistEntry(items: model.selectedEntries.map(\.item))
            Button("Select All") { model.selectAllVisible() }.musicPageAction().keyboardShortcut("a", modifiers: .command)
            Button("Clear Selection") { model.clearSelection() }.musicPageAction().accessibilityIdentifier("libraryClearSelection")
            Text("Library changes are made one item at a time. Adding songs to a playlist asks first.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
        }
    }
    private var footer: some View { LibraryListFooter(model: model) }
}

/// The Library destination: its nine collections, and the one on screen.
public struct LibraryView: View {
    @Bindable var surface: LibrarySurface
    let navigator: CatalogNavigator
    let openAccounts: () -> Void
    /// The collection a fresh visit opens on (Podcasts opens on the podcasts collection); nil keeps whichever was last shown.
    let opensOn: MusicLibraryKind?
    @Environment(\.pageRestoration) private var restoration
    @State private var identity = IdentityRestorer()
    public init(surface: LibrarySurface, navigator: CatalogNavigator, openAccounts: @escaping () -> Void = {}, opensOn: MusicLibraryKind? = nil) {
        self.surface = surface; self.navigator = navigator; self.openAccounts = openAccounts; self.opensOn = opensOn
    }
    private func show(_ kind: MusicLibraryKind) {
        restoration?.scroll.rewind()
        identity.reset()
        surface.showsDownloadedOnly = false; surface.selectedKind = kind
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.lg) {
            HStack {
                Text("Library").font(MusicPageStyle.title).accessibilityAddTraits(.isHeader).accessibilityIdentifier("destinationTitle").browserRegion("destinationTitle")
                Spacer()
                if surface.development { Text("Development data · Not YouTube Music").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("developmentDataLabel") }
            }
            ScrollView(.horizontal) {
                MusicGlassGroup {
                    HStack(spacing: MusicSpace.xs) {
                        ForEach(MusicLibraryKind.allCases, id: \.self) { kind in
                            Button { show(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                                .musicPageAction(prominent: kind == surface.selectedKind && !surface.showsDownloadedOnly)
                                .accessibilityAddTraits(kind == surface.selectedKind && !surface.showsDownloadedOnly ? .isSelected : [])
                                .accessibilityIdentifier("libraryKind-" + kind.rawValue)
                        }
                        if surface.downloads != nil {
                            Button { restoration?.scroll.rewind(); surface.showsDownloadedOnly = true } label: { Label("Downloaded only", systemImage: "arrow.down.circle") }
                                .musicPageAction(prominent: surface.showsDownloadedOnly)
                                .accessibilityAddTraits(surface.showsDownloadedOnly ? .isSelected : [])
                                .accessibilityIdentifier("libraryDownloadedOnly")
                        }
                    }
                }.padding(.vertical, MusicSpace.hairline)
            }.scrollIndicators(.never).audit("libraryKinds", group: "page-top", within: "detailPanel", alignLeading: "pageLeading")
                .background(GeometryReader { Color.clear.preference(key: LibraryRegionFrames.self, value: ["chips": $0.frame(in: .named(LibraryRegionFrames.space))]) })
            if surface.showsDownloadedOnly, let downloads = surface.downloads {
                // Only what is kept on this Mac; nothing from the service's library is mixed in.
                ScrollView { DownloadedItemsSection(model: downloads).padding(.vertical, MusicSpace.xxs).frame(maxWidth: .infinity, alignment: .leading) }
                    .restoresScroll()
                    .background(GeometryReader { Color.clear.preference(key: LibraryRegionFrames.self, value: ["downloaded": $0.frame(in: .named(LibraryRegionFrames.space))]) })
                    .accessibilityIdentifier("libraryDownloadedSection")
            } else {
                if surface.selectedKind == .playlists { NewPlaylistEntry(navigator: navigator) }
                LibraryCollectionView(surface: surface, model: surface.model, identity: identity, navigator: navigator, openAccounts: openAccounts)
                    .id(surface.selectedKind)
            }
        }
        .musicPageContent().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.libraryLedger, surface.ledger)
        .environment(\.playlistSurface, surface.playlists)
        .coordinateSpace(name: LibraryRegionFrames.space)
        .remembersPage(identity: identity, fresh: { surface.beginFreshVisit(opensOn: opensOn) }, capture: { surface.pageMemory }, apply: { surface.restorePage($0) })
    }
}
/// W18: the Episodes-for-Later press on an episode page. One press is one request for one episode (the ledger's `submit`); a direction is
/// offered only when the episode page published it, and nothing is drawn for a signed-out listener (the page decides).
struct EpisodeLaterButton: View {
    @Bindable var ledger: LibraryWriteLedger
    let later: MusicEpisodeLater
    var body: some View {
        let key = LibraryWriteKey.episodeLater(videoID: later.videoID)
        let saved = ledger.isSaved(key, service: later.isSaved)
        if let desired = later.offeredChange(shownSaved: saved) {
            Button { Task { await ledger.submit(.setEpisodeLater(videoID: later.videoID, to: desired, was: saved)) } } label: {
                Label(saved ? "Remove from Episodes for Later" : "Save for Later", systemImage: saved ? "bookmark.fill" : "bookmark")
            }.musicPageAction().disabled(ledger.isBusy(key)).accessibilityIdentifier("episodeLater")
        }
    }
}

/// Where the Library's regions were laid out (render checks only).
public struct LibraryRegionFrames: PreferenceKey {
    public static let space = "libraryRegions"
    public static let defaultValue: [String: CGRect] = [:]
    public static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct LibraryLedgerKey: EnvironmentKey { static let defaultValue: LibraryWriteLedger? = nil }
public extension EnvironmentValues {
    /// The shell's write ledger, for catalog pages that show the same Save, Follow and Like controls.
    var libraryLedger: LibraryWriteLedger? {
        get { self[LibraryLedgerKey.self] }
        set { self[LibraryLedgerKey.self] = newValue }
    }
}

/// The list layout of a collection, equal to its previous self while the list it shows (and the model it belongs to) is the same.
struct LibraryEntryList: View, Equatable {
    let surface: LibrarySurface
    @Bindable var model: LibraryCollectionModel
    let navigator: CatalogNavigator
    let identity: IdentityRestorer
    let entries: [LibraryEntry]
    let generation: Int
    private let identityStamp: [ObjectIdentifier]      // the model and surface this list belongs to
    init(surface: LibrarySurface, model: LibraryCollectionModel, navigator: CatalogNavigator, identity: IdentityRestorer, entries: [LibraryEntry], generation: Int) {
        self.surface = surface; self.model = model; self.navigator = navigator; self.identity = identity; self.entries = entries; self.generation = generation
        identityStamp = [ObjectIdentifier(model), ObjectIdentifier(surface)]
    }
    /// Equal while the list generation and the model and surface it belongs to are the same. `navigator` and `identity` are deliberately not compared: the
    /// identity restorer is the page's own `@State` and the navigator is stable for the page's life, so neither can differ between two evaluations of one page.
    nonisolated static func == (a: LibraryEntryList, b: LibraryEntryList) -> Bool { a.generation == b.generation && a.identityStamp == b.identityStamp }
    var body: some View {
        ScrollViewReader { proxy in
        let _ = identity.setItems(owner: ObjectIdentifier(model), generation: generation) { entries.map(\.id) }
        List(selection: $model.selection) {
            ForEach(entries) { entry in
                LibraryRow(surface: surface, entry: entry, source: model.source, navigator: navigator).tag(entry.id)
                    .identityItem(entry.id)
            }
            LibraryListFooter(model: model).listRowSeparator(.hidden)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
                if entry.item.opensPage { Button("Open") { navigator.openItem(entry.item) } }
                ForEach(surface.offers(for: entry.item)) { offer in Button(offer.action.title) { Task { await surface.perform(offer.action, on: entry.item, key: entry.id) } } }
            } else if !ids.isEmpty {
                Button("Copy Links") { _ = surface.copyLinks(of: entries.filter { ids.contains($0.id) }) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let entry = entries.first(where: { $0.id == id }), entry.item.opensPage { navigator.openItem(entry.item) }
        }
        .scrollContentBackground(.hidden)
        .restoresByIdentity(identity, proxy: proxy)
        .accessibilityIdentifier("libraryList")
        }
    }
}

/// The end of a long list: the load-more trigger, its progress and failure, and the status line. Its own view, so that the paging flags it reads
/// invalidate only this row, never the list above it.
struct LibraryListFooter: View {
    @Bindable var model: LibraryCollectionModel
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            if model.hasMore {
                HStack {
                    if model.loadingMore { ProgressView().controlSize(.small).accessibilityLabel(Text("Loading more")) }
                    else if let failure = model.moreFailure {
                        Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText)
                        Button("Retry") { Task { await model.loadMore() } }.musicPageAction()
                    } else {
                        Color.clear.frame(width: 1, height: 1).onAppear { Task { await model.loadMore() } }
                        Button("Load more") { Task { await model.loadMore() } }.musicPageAction().accessibilityIdentifier("libraryLoadMore")
                    }
                }
            }
            LibraryStatusLine(model: model)
        }.padding(.vertical, MusicSpace.xs)
    }
}
