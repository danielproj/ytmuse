import AccountSession
import DesignSystem
import SwiftUI

/// How a catalog view asks the shell to open something. The shell owns navigation; views never mutate it.
public struct CatalogNavigator {
    public var openItem: (MusicCatalogItem) -> Void
    public var openLink: (MusicLink) -> Void
    public var openTarget: (CatalogTarget, String) -> Void
    public init(openItem: @escaping (MusicCatalogItem) -> Void = { _ in }, openLink: @escaping (MusicLink) -> Void = { _ in },
                openTarget: @escaping (CatalogTarget, String) -> Void = { _, _ in }) {
        self.openItem = openItem; self.openLink = openLink; self.openTarget = openTarget
    }
}

extension MusicEntityKind {
    var symbol: String {
        switch self {
        case .song: "music.note"
        case .video: "play.rectangle"
        case .album: "square.stack"
        case .artist: "person.wave.2"
        case .playlist: "music.note.list"
        case .podcast: "mic"
        case .episode: "mic.circle"
        case .category: "square.grid.2x2"
        }
    }
    var title: String {
        switch self {
        case .song: String(localized: "Song")
        case .video: String(localized: "Video")
        case .album: String(localized: "Album")
        case .artist: String(localized: "Artist")
        case .playlist: String(localized: "Playlist")
        case .podcast: String(localized: "Podcast")
        case .episode: String(localized: "Episode")
        case .category: String(localized: "Category")
        }
    }
}
extension MusicCatalogItem {
    /// Entries that open a page of their own (a song opens its detail; an episode opens its page when the service named it, an `MPED…` id).
    var opensPage: Bool { kind != .episode || browseID?.hasPrefix("MPED") == true }
    /// The detail line in the app's own separator, with the service's type label replaced by the app's localised name where it is a plain kind.
    func detailLine(includingKind: Bool = false) -> String {
        var parts: [String] = []
        if includingKind {
            if let serviceLabel { parts.append(serviceLabel) } else { parts.append(kind.title) }
        } else if let serviceLabel, kind == .album { parts.append(serviceLabel) }
        parts += details
        return parts.joined(separator: String(localized: "detailSeparator"))
    }
    var accessibilitySummary: String {
        var parts = [title, kind.title]
        parts += details
        if explicit { parts.append(String(localized: "Explicit")) }
        if availability == .unavailable { parts.append(String(localized: "Unavailable")) }
        return parts.joined(separator: ", ")
    }
}

struct ExplicitBadge: View {
    var body: some View {
        MusicBadge("E", style: .explicit).accessibilityHidden(true)
    }
}

/// One feedback line at the item an action ran on.
struct FeedbackLine: View {
    let feedback: SearchItemFeedback?
    var body: some View {
        content
            // A failure is announced, so a VoiceOver user learns the action did not run without hunting for it.
            .onChange(of: feedback) { _, new in if case .failed(let message)? = new { Announcer.post(message, kind: .error) } }
    }
    @ViewBuilder private var content: some View {
        switch feedback {
        case .failed(let message): Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText)
            .accessibilityLabel(Text(message)).accessibilityIdentifier("catalogFeedback")
        // Starting and started say nothing at the item: the player bar shows the chosen item starting and then playing.
        case .working, .started: EmptyView()
        case .copied: Label("Link copied", systemImage: "checkmark.circle").font(.caption).foregroundStyle(MusicStyle.secondaryText)
        case nil: EmptyView()
        }
    }
}

/// What clicking a card's artwork does: a song or video plays (as YouTube Music does), anything with a page of its own opens it, and an
/// entry that only plays, plays. nil: the artwork has nothing to do.
public enum CardArtworkAction: Equatable, Sendable {
    case play, open
    public static func of(_ item: MusicCatalogItem) -> CardArtworkAction? {
        let plays = CatalogActionPlan.canEverPlay(item)
        if plays, item.kind == .song || item.kind == .video { return .play }
        if item.opensPage { return .open }
        return plays ? .play : nil
    }
}

/// A card for carousels and grids: artwork, title, detail line. The artwork is a control too (`CardArtworkAction`); the title opens and
/// the Play button plays, and those two stay the card's accessible controls (the artwork repeats one of them, so VoiceOver skips it).
struct CatalogCard: View {
    let item: MusicCatalogItem
    @Bindable var model: CatalogPageModel
    let navigator: CatalogNavigator
    private let edge: CGFloat = 168
    var body: some View {
        let offers = model.offers(for: item)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            ZStack(alignment: .bottomTrailing) {
                artwork
                if CatalogActionPlan.canEverPlay(item) {
                    Button { Task { await model.perform(.play, on: item) } } label: { Label("Play", systemImage: "play.fill") }
                        .labelStyle(.iconOnly).help(Text("Play \(item.title)")).accessibilityLabel(Text("Play \(item.title)"))
                        .accessibilityIdentifier("catalogPlay-" + item.id).musicPageAction(prominent: true).padding(MusicSpace.xs)
                }
            }
            Button { if item.opensPage { navigator.openItem(item) } } label: {
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    HStack(spacing: MusicSpace.xxs) { Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2); if item.explicit { ExplicitBadge() } }
                    Text(item.detailLine()).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(2)
                }.frame(width: edge, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!item.opensPage)
                .accessibilityElement(children: .combine).accessibilityLabel(Text(item.accessibilitySummary))
                .accessibilityIdentifier("catalogItem-" + item.id)
            FeedbackLine(feedback: model.feedback[item.id]).frame(width: edge, alignment: .leading)
        }
        .frame(width: edge, alignment: .leading).audit("card-" + item.id, group: "shelf-cards", alignLeading: nil)
        .directPlaylistMenu(addition: DirectPlaylistAddition.candidate(item), identifier: "catalogAddToPlaylist-" + item.id) {
            ItemMenu(item: item, model: model, navigator: navigator)
        }
        .accessibilityActions { ForEach(offers.filter(\.isAvailable)) { offer in Button(offer.action.title) { Task { await model.perform(offer.action, on: item) } } } }
    }
    @ViewBuilder private var artwork: some View {
        let image = CatalogArtworkView(thumbnails: item.thumbnails, edge: edge)
        switch CardArtworkAction.of(item) {
        case .play?:
            Button { Task { await model.perform(.play, on: item) } } label: { image.contentShape(MusicCorner.artwork.shape(edge: edge)) }
                .buttonStyle(.plain).musicCard().help(Text("Play \(item.title)"))
                .accessibilityHidden(true).accessibilityIdentifier("catalogArtwork-" + item.id)
        case .open?:
            Button { navigator.openItem(item) } label: { image.contentShape(MusicCorner.artwork.shape(edge: edge)) }
                .buttonStyle(.plain).musicCard().help(Text("Open \(item.title)"))
                .accessibilityHidden(true).accessibilityIdentifier("catalogArtwork-" + item.id)
        case nil:
            image
        }
    }
}

struct ItemMenu: View {
    let item: MusicCatalogItem
    @Bindable var model: CatalogPageModel
    let navigator: CatalogNavigator
    @Environment(\.podcastsSurface) private var podcasts
    var body: some View {
        if item.opensPage { Button("Open") { navigator.openItem(item) } }
        // An episode's Play is the podcast surface's (the same call as the row's button); offered only when it can run.
        if item.kind == .episode, let podcasts, podcasts.playbackState == .available,
           let request = EpisodePlayTargets.request(videoID: item.videoID, title: item.title, showBrowseID: model.target.browseID.hasPrefix("MPSP") ? model.target.browseID : nil,
                                                    publishedShowPlaylist: model.pageActions?.play) {
            Button("Play") { Task { await podcasts.play(request) } }
        }
        ForEach(model.offers(for: item)) { offer in
            Button(offer.action.title) { Task { await model.perform(offer.action, on: item) } }
        }
    }
}

/// A list row (tracks, ranked artists, episodes).
struct CatalogRow: View {
    let item: MusicCatalogItem
    @Bindable var model: CatalogPageModel
    let navigator: CatalogNavigator
    var showsArtwork = true
    var body: some View {
        let offers = model.offers(for: item)
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            HStack(spacing: MusicSpace.sm) {
                Button { if item.opensPage { navigator.openItem(item) } } label: {
                    HStack(spacing: MusicSpace.sm) {
                        if let position = item.position { Text(position).font(.callout.monospacedDigit()).foregroundStyle(MusicStyle.secondaryText).frame(minWidth: MusicPageStyle.iconColumn, alignment: .trailing) }
                        if showsArtwork { CatalogArtworkView(thumbnails: item.thumbnails, edge: MusicFixedArtworkSize.row.edge, corner: .thumbnail) }
                        VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                            HStack(spacing: MusicSpace.xxs) { Text(item.title).font(.body).lineLimit(2); if item.explicit { ExplicitBadge() } }
                            let line = item.detailLine()
                            if !line.isEmpty { Text(line).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(2) }
                        }
                        Spacer(minLength: MusicSpace.xs)
                        if let duration = item.durationText { Text(duration).font(.callout.monospacedDigit()).foregroundStyle(MusicStyle.secondaryText) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!item.opensPage)
                    .opacity(item.availability == .unavailable ? 0.55 : 1)
                    .accessibilityElement(children: .combine).accessibilityLabel(Text(item.accessibilitySummary))
                    .accessibilityIdentifier("catalogItem-" + item.id)
                if CatalogActionPlan.canEverPlay(item) {
                    Button { Task { await model.perform(.play, on: item) } } label: { Label("Play", systemImage: "play.fill") }
                        .labelStyle(.iconOnly).help(Text("Play \(item.title)")).accessibilityLabel(Text("Play \(item.title)"))
                        .accessibilityHint(CatalogActionPlan.continuesCollection(item) ? Text("Continues the album or playlist from this track.") : Text("Plays this song and then similar music."))
                        .accessibilityIdentifier("catalogPlay-" + item.id).musicPageAction()
                }
            }
            if item.kind == .episode {
                EpisodeRowExtras(item: item, show: model.target.browseID.hasPrefix("MPSP") ? model.target.browseID : nil, showPlaylist: model.pageActions?.play,
                                 readAt: model.fetchedAt ?? .distantPast)
            }
            FeedbackLine(feedback: model.feedback[item.id])
        }
        .musicRow()
        .songDraggable(videoID: item.videoID, title: item.title, kind: item.kind)
        .directPlaylistMenu(addition: DirectPlaylistAddition.candidate(item), identifier: "catalogAddToPlaylist-" + item.id) {
            ItemMenu(item: item, model: model, navigator: navigator)
        }
        .accessibilityActions { ForEach(offers.filter(\.isAvailable)) { offer in Button(offer.action.title) { Task { await model.perform(offer.action, on: item) } } } }
    }
}

/// A compact navigation pill (a mood, a genre, Charts, New releases).
struct CategoryTile: View {
    let item: MusicCatalogItem
    let navigator: CatalogNavigator
    var body: some View {
        DesignSystem.MusicChip(verbatim: item.title, isSelected: false) { navigator.openItem(item) }
            .accessibilityIdentifier("catalogCategory-" + item.id)
    }
}

/// One shelf: its title (with "More" when the service names a fuller list), its entries in the layout their kind calls for,
/// and lazy pagination at the end.
struct ShelfView: View {
    let shelf: MusicShelf
    @Bindable var model: CatalogPageModel
    let navigator: CatalogNavigator
    @Environment(\.podcastsSurface) private var podcasts
    /// The rows this shelf draws, in the order it draws them (`CatalogRows`, which the page also registers its rows from).
    private var listItems: [MusicCatalogItem] { CatalogRows.drawn(shelf, podcasts: podcasts, pageReadAt: model.fetchedAt ?? .distantPast) }
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            if shelf.title?.isEmpty == false || shelf.more != nil {
                HStack {
                    if let title = shelf.title, !title.isEmpty { Text(title).font(MusicPageStyle.section).accessibilityAddTraits(.isHeader).audit("shelfTitle-" + shelf.key, group: "shelf-titles", alignLeading: "pageLeading") }
                    Spacer()
                    if let more = shelf.more { Button("More") { navigator.openTarget(CatalogTarget(link: more), shelf.title ?? "") }.musicPageAction().accessibilityIdentifier("catalogMore-" + shelf.key) }
                }
            }
            content
            pager
        }.accessibilityElement(children: .contain).accessibilityIdentifier("catalogShelf-" + shelf.key)
            .musicTransition(.reveal)
    }
    @ViewBuilder private var content: some View {
        switch shelf.layout {
        case .carousel, .grid:
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: MusicSpace.lg) { ForEach(shelf.items) { CatalogCard(item: $0, model: model, navigator: navigator) } }
                    .padding(.vertical, MusicSpace.xxs)
            }.scrollIndicators(.automatic)
        case .categories:
            MusicActionLayout {
                ForEach(shelf.items) { CategoryTile(item: $0, navigator: navigator) }
            }
        case .list:
            if let rows = shelf.rowsPerColumn, rows > 1 {
                // Rows the service stacks into columns of a horizontally scrolling shelf (Quick picks).
                let columns = stride(from: 0, to: shelf.items.count, by: rows).map { Array(shelf.items[$0..<min($0 + rows, shelf.items.count)]) }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: MusicSpace.lg) {
                        ForEach(columns, id: \.first?.id) { column in
                            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                                ForEach(column) { CatalogRow(item: $0, model: model, navigator: navigator) }
                            }.frame(width: 340, alignment: .topLeading)
                        }
                    }
                }.scrollIndicators(.automatic)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(listItems) { CatalogRow(item: $0, model: model, navigator: navigator).identityItem(CatalogRows.rowItem(shelf, $0)) }
                }
            }
        }
    }
    @ViewBuilder private var pager: some View {
        if shelf.continuation != nil {
            HStack {
                if model.loadingMore.contains(shelf.key) { ProgressView().controlSize(.small).accessibilityLabel(Text("Loading more")) }
                else if let failure = model.moreFailures[shelf.key] {
                    Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText)
                    Button("Retry") { Task { await model.loadMore(shelf: shelf.key) } }.musicPageAction()
                } else {
                    // Reaching the end loads the next page; the button is the same action for keyboard and VoiceOver users.
                    Color.clear.frame(width: 1, height: 1).onAppear { Task { await model.loadMore(shelf: shelf.key) } }
                    Button("Load more") { Task { await model.loadMore(shelf: shelf.key) } }.musicPageAction().accessibilityIdentifier("catalogLoadMore-" + shelf.key)
                }
            }
        }
    }
}

/// A description rendered as native text with its attribution; "Show more" expands the bounded body.
struct RichDescriptionView: View {
    let runs: [MusicTextRun]
    @State private var expanded = false
    var body: some View {
        let collapsed = CatalogRichText.make(runs, limit: CatalogRichText.collapsedLimit)
        let text = expanded ? CatalogRichText.make(runs, limit: CatalogRichText.expandedLimit) : collapsed
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text(text.body).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("catalogDescription")
                if collapsed.truncated {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }.buttonStyle(.link).accessibilityIdentifier("catalogDescriptionToggle")
                }
                if let attribution = text.attribution {
                    Text(attribution).font(.caption).foregroundStyle(MusicStyle.secondaryText).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("catalogAttribution")
                }
            }
        }
    }
}

/// Play / Shuffle / Start Radio for the page, only those the service published a playlist for; an unavailable one says why.
struct PageActionsBar: View {
    @Bindable var model: CatalogPageModel
    @Environment(\.libraryLedger) private var ledger
    var body: some View {
        if model.header != nil, let actions = model.pageActions {
            let offers = CatalogActionPlan.offers(for: actions, playback: model.playback)
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                if !offers.isEmpty {
                    MusicActionLayout() {
                        ForEach(offers) { offer in
                            Button { Task { await model.perform(offer.action) } } label: { Label(offer.action.title, systemImage: offer.action.symbol) }
                                .musicAction(CatalogActionPlan.pageRole(of: offer.action, in: offers, song: false)).accessibilityIdentifier("pageAction-" + offer.action.rawValue)
                        }
                    }
                }
                ForEach(offers) { offer in
                    if let message = offer.unavailable { Text(message).font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("pageActionReason") }
                }
                ForEach([CatalogAction.play, .shuffle, .radio], id: \.self) { action in FeedbackLine(feedback: model.feedback["page:" + action.rawValue]) }
                let controls = (model.signedIn ? ledger.map { LibraryControls.make(page: actions, ledger: $0) } : nil) ?? []
                if let ledger, !controls.isEmpty {
                    LibraryControlRow(ledger: ledger, controls: controls, identifier: "page", showsTitles: true)
                    LibraryWriteLine(ledger: ledger, keys: controls.map(\.key).uniqued(), scope: "page")
                } else if let note = CatalogActionPlan.writeNote(for: actions, signedIn: model.signedIn) {
                    Label(note, systemImage: "info.circle").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("catalogWriteNote")
                }
            }
        }
    }
}

/// Share… and Copy Link for the page itself (an album, artist, playlist or show), drawn only when the page's route names something shareable. The
/// link comes from the route, so a page reopened from history shares exactly as one opened from a row. Pressing Share… opens the share sheet;
/// opening the page or hovering this row does nothing.
struct PageShareBar: View {
    @Bindable var model: CatalogPageModel
    var body: some View {
        if model.header != nil, model.pageLink != nil {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicActionLayout() {
                    Button { model.sharePage() } label: { Label(CatalogAction.share.title, systemImage: CatalogAction.share.symbol) }
                        .musicPageAction().accessibilityIdentifier("pageAction-share")
                    Button { model.copyPageLink() } label: { Label(CatalogAction.copyLink.title, systemImage: CatalogAction.copyLink.symbol) }
                        .musicPageAction().accessibilityIdentifier("pageAction-copyLink")
                }
                FeedbackLine(feedback: model.feedback[CatalogPageModel.pageShareKey])
                FeedbackLine(feedback: model.feedback[CatalogPageModel.pageCopyKey])
            }
        }
    }
}

/// Where the data on screen came from: live, a saved copy, or stale; and what was left out.
struct FreshnessLine: View {
    @Bindable var model: CatalogPageModel
    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Text(status).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("catalogFreshness")
            if model.leftOut > 0 {
                Text(String(localized: "\(model.leftOut) items couldn’t be shown")).font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText)
                    .accessibilityIdentifier("catalogLeftOut")
            }
        }
    }
    private var status: String {
        if let failure = model.refreshFailure, let at = model.fetchedAt {
            return String(localized: "Couldn’t refresh. Showing a saved copy from \(at.formatted(date: .omitted, time: .shortened)). \(failure.message)")
        }
        guard let at = model.fetchedAt else { return "" }
        let time = at.formatted(date: .omitted, time: .shortened)
        if model.isRefreshing { return model.origin == .cached ? String(localized: "Saved copy from \(time). Refreshing…") : String(localized: "Refreshing…") }
        if model.isStale { return String(localized: "Out of date. Last updated \(time).") }
        return model.origin == .cached ? String(localized: "Saved copy from \(time).") : String(localized: "Updated \(time).")
    }
}
