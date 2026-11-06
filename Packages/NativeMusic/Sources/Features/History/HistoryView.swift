import AccountSession
import DesignSystem
import SwiftUI

/// History, with its two kinds kept visibly apart: what YouTube Music recorded (read from the service), and what this Mac played
/// (the app's own, `Local only`). Neither stands in for the other and no control on one claims to change the other.
///
/// The page is virtualized: every row it lists (each of the service's rows, each day heading and each of this Mac's plays) is a direct child of
/// the one `LazyVStack`, so only the rows on screen are built, and the load-more trigger at the end of the service's rows exists only once the
/// person scrolls to it. While the rows sat inside each section's own `VStack`, the lazy stack saw three children and built every row at once;
/// the trigger was built with them and read every page of the history in a row, re-listing all of it on each page.
public struct HistoryView: View {
    @Bindable var surface: LibrarySurface
    let navigator: CatalogNavigator
    let openAccounts: () -> Void
    @State private var confirmingClear = false
    public init(surface: LibrarySurface, navigator: CatalogNavigator, openAccounts: @escaping () -> Void = {}) {
        self.surface = surface; self.navigator = navigator; self.openAccounts = openAccounts
    }
    private var history: HistoryModel { surface.history }
    public var body: some View {
        ScrollView {
            // Each section below is several children of this stack, never one: a section that wrapped its rows in a container would build them all again.
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("History").font(MusicPageStyle.title).accessibilityAddTraits(.isHeader).accessibilityIdentifier("destinationTitle").browserRegion("destinationTitle")
                    Spacer()
                    if surface.development { Text("Development data · Not YouTube Music").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("developmentDataLabel") }
                    Button { Task { await history.remote.refresh(); await history.loadLocal() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .labelStyle(.iconOnly).help(Text("Refresh")).musicPageAction().accessibilityIdentifier("historyRefresh")
                        .keyboardShortcut("r", modifiers: .command)
                }
                HistoryRemoteSection(surface: surface, navigator: navigator, openAccounts: openAccounts)
                controlsSection.padding(MusicSpace.md).musicInsetSurface()
                    .audit("historyControls", group: "history-sections", within: "detailPanel", alignLeading: "pageLeading", scrolls: true)
                    .padding(.top, MusicSpace.lg)
                HistoryLocalSection(history: history, confirmingClear: $confirmingClear)
            }.musicPageContent().frame(maxWidth: .infinity, alignment: .leading)
        }
        .restoresScroll()
        .task { await history.remote.load(); if history.remote.isStale { await history.remote.refresh() }; await history.loadLocal() }
        .accessibilityIdentifier("historyRoot")
    }

    // MARK: Pause and clear

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Label("YouTube Music history controls", systemImage: "info.circle").font(.headline)
            ForEach([history.controls.pause, history.controls.clear], id: \.title) { control in
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    Text(control.title).font(.subheadline.weight(.semibold))
                    Text(control.reason).font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("historyControlUnavailable")
            }
        }
    }
}

// MARK: YouTube Music history (read)

/// One row of the service's history as the page lists it: a day heading or an entry. The list is flat so the lazy stack builds each row on its own.
struct HistoryRow: Identifiable, Equatable {
    /// Headings repeat (a continuation can bring another "Today"), so a heading is identified by its place, never by its title.
    enum ID: Hashable { case heading(Int), entry(String) }
    enum Content: Equatable { case heading(String), entry(LibraryEntry) }
    let id: ID
    let content: Content
    /// The space above the row. A heading opens a day (the gap between days and the heading's own top margin); an entry follows its neighbour
    /// closely, or the section's header when it opens a day the service gave no heading.
    let gap: CGFloat

    /// The service's headings (Today, Yesterday…) over its rows, in its order, in one pass. A heading is text to show, never read.
    static func rows(_ entries: [LibraryEntry]) -> [HistoryRow] {
        var rows: [HistoryRow] = []
        rows.reserveCapacity(entries.count + 8)
        var days = 0
        var previous: LibraryEntry?
        for entry in entries {
            if let previous, previous.section == entry.section {
                rows.append(HistoryRow(id: .entry(entry.id), content: .entry(entry), gap: MusicSpace.hairline))
                continue
            }
            if let title = entry.section {
                rows.append(HistoryRow(id: .heading(days), content: .heading(title), gap: MusicSpace.md))
                rows.append(HistoryRow(id: .entry(entry.id), content: .entry(entry), gap: MusicSpace.hairline))
            } else {
                rows.append(HistoryRow(id: .entry(entry.id), content: .entry(entry), gap: MusicSpace.xs))
            }
            days += 1
            previous = entry
        }
        return rows
    }
}

/// The service's history: a header, its rows and the paging footer, each a child of the page's lazy stack (this view adds no container around them).
/// The paging flags are read only by the footer, so a page being read invalidates the footer, never the rows.
struct HistoryRemoteSection: View {
    let surface: LibrarySurface
    let navigator: CatalogNavigator
    let openAccounts: () -> Void
    var body: some View {
        let remote = surface.history.remote
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Label("YouTube Music history", systemImage: "play.square").font(MusicPageStyle.section).accessibilityAddTraits(.isHeader)
            Text("Read from YouTube Music. YouTube’s own player records it when it plays; this app never writes it.")
                .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("historyRemoteProvenance")
            LibraryStateView(model: remote, openAccounts: openAccounts)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("historyRemote")
        .audit("historyRemote", group: "history-sections", within: "detailPanel", alignLeading: "pageLeading", scrolls: true)
        .padding(.top, MusicSpace.lg)
        if case .content = remote.state {
            ForEach(HistoryRow.rows(remote.entries)) { row in
                switch row.content {
                case .heading(let title):
                    Text(title).font(MusicPageStyle.group).accessibilityAddTraits(.isHeader).padding(.top, row.gap)
                case .entry(let entry):
                    LibraryRow(surface: surface, entry: entry, source: remote.source, navigator: navigator).padding(.top, row.gap)
                }
            }
            HistoryRemoteFooter(model: remote).padding(.top, MusicSpace.xs)
        }
    }
}

/// The end of the service's rows: the load-more trigger (built only when the person scrolls here), its progress and failure, and the status line.
private struct HistoryRemoteFooter: View {
    let model: LibraryCollectionModel
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
                        Button("Load more") { Task { await model.loadMore() } }.musicPageAction().accessibilityIdentifier("historyLoadMore")
                    }
                }
            }
            LibraryStatusLine(model: model)
        }
    }
}

// MARK: On this Mac

/// This Mac's record: a header, then each play as a child of the page's lazy stack, then the clear button.
private struct HistoryLocalSection: View {
    let history: HistoryModel
    @Binding var confirmingClear: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack {
                Label("On this Mac", systemImage: "internaldrive").font(MusicPageStyle.section).accessibilityAddTraits(.isHeader)
                MusicOutlineBadge("Local only").accessibilityIdentifier("historyLocalOnlyBadge")
            }
            Text("The app’s own record of what it played here. It isn’t YouTube Music’s history, and it is never sent to YouTube Music.")
                .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("historyLocalProvenance")
            if history.localFailure {
                Label("This Mac’s record couldn’t be read or saved.", systemImage: "exclamationmark.circle").font(MusicPageStyle.note).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("historyLocalFailure")
            }
            if !history.hasLocalStore {
                Text("Local history isn’t available in this session.").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("historyLocalUnavailable")
            } else if history.local.isEmpty, history.localLoaded {
                Text(history.localCleared ? "This Mac’s record was cleared. YouTube Music’s history is unchanged." : "Nothing has played on this Mac yet. A play is recorded after you have really listened to part of a track.")
                    .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("historyLocalEmpty")
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("historyLocal")
        .audit("historyLocal", group: "history-sections", within: "detailPanel", alignLeading: "pageLeading", scrolls: true)
        .padding(.top, MusicSpace.lg)
        if history.hasLocalStore, !(history.local.isEmpty && history.localLoaded) {
            ForEach(history.local) { record in
                HStack(spacing: MusicSpace.sm) {
                    MusicArtworkPlaceholder(corner: .thumbnail).frame(width: MusicArtworkSize.row.edge, height: MusicArtworkSize.row.edge)
                    VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                        Text(record.title.isEmpty ? String(localized: "Unknown song") : record.title).lineLimit(2)
                        Text(([record.artist].compactMap { $0 } + [record.startedAt.formatted(date: .abbreviated, time: .shortened)]).joined(separator: String(localized: "detailSeparator")))
                            .font(.caption).foregroundStyle(MusicStyle.secondaryText)
                    }
                    Spacer()
                    Text("Local only").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(record.title), \(record.artist ?? String()), local only"))
                .accessibilityIdentifier("historyLocalRow")
                .musicRow(hoverable: false)
            }
            Button("Clear Local History…", role: .destructive) { confirmingClear = true }
                .musicPageAction().accessibilityIdentifier("historyClearLocal")
                // The store keeps more than the list shows, and clearing removes all of it, so the question says "all".
                .confirmationDialog("Clear all plays from this Mac?", isPresented: $confirmingClear, titleVisibility: .visible) {
                    Button("Clear This Mac’s History", role: .destructive) { Task { await history.clearLocal() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes only the record kept on this Mac. YouTube Music’s own history is not changed.")
                }
                .padding(.top, MusicSpace.xs)
        }
    }
}
