import AccountSession
import DesignSystem
import SwiftUI

/// History, with its two kinds kept visibly apart: what YouTube Music recorded (read from the service), and what this Mac played
/// (the app's own, `Local only`). Neither stands in for the other and no control on one claims to change the other.
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
            LazyVStack(alignment: .leading, spacing: MusicSpace.lg) {
                HStack {
                    Text("History").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader).accessibilityIdentifier("destinationTitle").browserRegion("destinationTitle")
                    Spacer()
                    if surface.development { Text("Development data · Not YouTube Music").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("developmentDataLabel") }
                    Button { Task { await history.remote.refresh(); await history.loadLocal() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .labelStyle(.iconOnly).help(Text("Refresh")).musicButtons().accessibilityIdentifier("historyRefresh")
                        .keyboardShortcut("r", modifiers: .command)
                }
                remoteSection.audit("historyRemote", group: "history-sections", within: "detailPanel", alignLeading: "pageLeading", scrolls: true)
                controlsSection.audit("historyControls", group: "history-sections", within: "detailPanel", alignLeading: "pageLeading", scrolls: true)
                localSection.audit("historyLocal", group: "history-sections", within: "detailPanel", alignLeading: "pageLeading", scrolls: true)
            }.padding(MusicSpace.lg).frame(maxWidth: .infinity, alignment: .leading)
        }
        .restoresScroll()
        .task { await history.remote.load(); if history.remote.isStale { await history.remote.refresh() }; await history.loadLocal() }
        .accessibilityIdentifier("historyRoot")
    }

    // MARK: YouTube Music history (read)

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Label("YouTube Music history", systemImage: "play.square").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("Read from YouTube Music. YouTube’s own player records it when it plays; this app never writes it.")
                .font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("historyRemoteProvenance")
            let remote = history.remote
            LibraryStateView(model: remote, openAccounts: openAccounts)
            if case .content = remote.state {
                let groups = Self.sections(remote.entries)
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                        if let title = group.title { Text(title).font(.headline).accessibilityAddTraits(.isHeader).padding(.top, MusicSpace.xs) }
                        ForEach(group.entries) { entry in
                            LibraryRow(surface: surface, entry: entry, source: remote.source, navigator: navigator)
                        }
                    }
                }
                if remote.hasMore {
                    HStack {
                        if remote.loadingMore { ProgressView().controlSize(.small).accessibilityLabel(Text("Loading more")) }
                        else if let failure = remote.moreFailure {
                            Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText)
                            Button("Retry") { Task { await remote.loadMore() } }.musicButtons()
                        } else {
                            Color.clear.frame(width: 1, height: 1).onAppear { Task { await remote.loadMore() } }
                            Button("Load more") { Task { await remote.loadMore() } }.musicButtons().accessibilityIdentifier("historyLoadMore")
                        }
                    }
                }
                LibraryStatusLine(model: remote)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("historyRemote")
    }
    /// Headings repeat (a continuation can bring another "Today"), so a group is identified by its place, never by its title.
    struct Group: Identifiable { let index: Int; let title: String?; let entries: [LibraryEntry]; var id: Int { index } }
    /// The service's own headings (Today, Yesterday…) over its rows, in its order. A heading is text to show, never read.
    static func sections(_ entries: [LibraryEntry]) -> [Group] {
        var result: [Group] = []
        for entry in entries {
            if let last = result.last, last.title == entry.section { result[result.count - 1] = Group(index: last.index, title: last.title, entries: last.entries + [entry]) }
            else { result.append(Group(index: result.count, title: entry.section, entries: [entry])) }
        }
        return result
    }

    // MARK: Pause and clear

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Label("YouTube Music history controls", systemImage: "info.circle").font(.headline)
            ForEach([history.controls.pause, history.controls.clear], id: \.title) { control in
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    Text(control.title).font(.subheadline.weight(.semibold))
                    Text(control.reason).font(.caption).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("historyControlUnavailable")
            }
        }
    }

    // MARK: On this Mac

    private var localSection: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack {
                Label("On this Mac", systemImage: "internaldrive").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                MusicOutlineBadge("Local only").accessibilityIdentifier("historyLocalOnlyBadge")
            }
            Text("The app’s own record of what it played here. It isn’t YouTube Music’s history, and it is never sent to YouTube Music.")
                .font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("historyLocalProvenance")
            if history.localFailure {
                Label("This Mac’s record couldn’t be read or saved.", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("historyLocalFailure")
            }
            if !history.hasLocalStore {
                Text("Local history isn’t available in this session.").font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("historyLocalUnavailable")
            } else if history.local.isEmpty, history.localLoaded {
                Text(history.localCleared ? "This Mac’s record was cleared. YouTube Music’s history is unchanged." : "Nothing has played on this Mac yet. A play is recorded after you have really listened to part of a track.")
                    .font(.callout).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("historyLocalEmpty")
            } else {
                ForEach(history.local) { record in
                    HStack(spacing: MusicSpace.sm) {
                        Image(systemName: "music.note").foregroundStyle(MusicStyle.secondaryText)
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
                }
                Button("Clear Local History…", role: .destructive) { confirmingClear = true }
                    .musicButtons().accessibilityIdentifier("historyClearLocal")
                    // The store keeps more than the list shows, and clearing removes all of it, so the question says "all".
                    .confirmationDialog("Clear all plays from this Mac?", isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button("Clear This Mac’s History", role: .destructive) { Task { await history.clearLocal() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes only the record kept on this Mac. YouTube Music’s own history is not changed.")
                    }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("historyLocal")
    }
}
