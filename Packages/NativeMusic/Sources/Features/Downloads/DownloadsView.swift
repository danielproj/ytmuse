import DesignSystem
import Domain
import SwiftUI
import UniformTypeIdentifiers

/// The Downloads destination (OFF01): aggregate and per-item progress, storage and its limits, Smart Downloads, recovery
/// for each failure, a Downloaded-only filter, and an honest statement of what YouTube Music does not offer on Mac.
public struct DownloadsView: View {
    @Bindable var model: DownloadsModel
    public init(model: DownloadsModel) { self.model = model }
    /// The screen restores by item identity (W09-F2, `IdentityRestorer`): the first section or download fully on screen is recorded for the visit
    /// and scrolled to, once, on the way back. The sections above a position change height as the engine's state arrives, so an offset moves.
    @State private var identity = IdentityRestorer()
    private static let sections = ["header", "notice", "capability", "development", "environment", "aggregate", "storage", "choices", "collections"]
    static func rowItem(_ row: DownloadRowModel) -> String { "row-" + row.id.uuidString }
    public var body: some View {
        ScrollViewReader { proxy in
            let _ = identity.setItems(Self.sections + model.visibleRows.map { Self.rowItem($0) })
            screen(proxy)
        }
    }
    private func screen(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicSpace.lg) {
                header.audit("downloadsHeader", group: "downloads-sections", within: "detailPanel", alignLeading: "pageLeading", scrolls: true).identityItem("header")
                if let notice = model.notice { noticeBar(notice).identityItem("notice") }
                capabilityCard.audit("downloadsCapability", group: "downloads-sections", within: "detailPanel", alignLeading: "pageLeading", scrolls: true).identityItem("capability")
                if model.isDevelopment {
                    Text("Development data · Not a real download").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("downloadsDevelopmentLabel").identityItem("development")
                }
                environmentNotes.identityItem("environment")
                aggregate.audit("downloadsAggregate", group: "downloads-sections", within: "detailPanel", alignLeading: "pageLeading", scrolls: true).identityItem("aggregate")
                storageCard.audit("downloadsStorage", group: "downloads-sections", within: "detailPanel", alignLeading: "pageLeading", scrolls: true).identityItem("storage")
                if !model.snapshot.storageChoices.isEmpty { choicesCard.identityItem("choices") }
                collectionsSection.identityItem("collections")
                list
            }.musicPageContent().frame(maxWidth: .infinity, alignment: .leading)
        }
        .restoresByIdentity(identity, proxy: proxy)
        .remembersPage(identity: identity, capture: { model.pageMemory }, apply: { model.restorePage($0) })
        .accessibilityElement(children: .contain).accessibilityIdentifier("downloadsScreen")
        .task { model.start() }
        .fileImporter(isPresented: $model.importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
    }

    private var header: some View {
        MusicAdaptiveRow {
            Text("Downloads").font(MusicPageStyle.title).accessibilityAddTraits(.isHeader).accessibilityIdentifier("destinationTitle").browserRegion("destinationTitle")
        } trailing: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MusicSpace.xs) { filterPicker; addFileButton }
                VStack(alignment: .leading, spacing: MusicSpace.xs) { filterPicker; addFileButton }
            }
        }
    }
    private var filterPicker: some View {
        Picker("Show", selection: $model.filter) {
            Text("All").tag(DownloadsModel.Filter.all)
            Text("Downloaded only").tag(DownloadsModel.Filter.downloadedOnly)
        }.pickerStyle(.segmented).frame(maxWidth: 260).accessibilityIdentifier("downloadsFilter")
    }
    private var addFileButton: some View {
        Button { model.importing = true } label: { Label("Add Audio File…", systemImage: "plus") }
            .disabled(!model.snapshot.hasAccount).musicPageAction().accessibilityIdentifier("downloadsAddFile")
            .help(model.snapshot.hasAccount ? Text("Keep an audio file from this Mac and play it from here") : Text("Select a signed-in account to keep files"))
    }
    private func noticeBar(_ text: String) -> some View {
        HStack {
            Label(text, systemImage: "info.circle").accessibilityIdentifier("downloadsNotice")
            Spacer()
            Button("Dismiss") { model.dismissNotice() }.musicPageAction().accessibilityIdentifier("downloadsNoticeDismiss")
        }.padding(MusicSpace.sm).musicInsetSurface()
        .onAppear { Announcer.post(text, kind: .download) }
    }
    private var capabilityCard: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Label(DownloadsText.youTubeMusicExplanation, systemImage: "arrow.down.circle.dotted").font(.headline).accessibilityIdentifier("downloadsYouTubeMusicNote")
            Text(DownloadsText.youTubeMusicDetail).font(.callout).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface().accessibilityElement(children: .combine)
    }
    @ViewBuilder private var environmentNotes: some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            if !snapshot.hasAccount {
                Label("Select a signed-in account to keep audio files on this Mac.", systemImage: "person.crop.circle.badge.exclamationmark").accessibilityIdentifier("downloadsNoAccount")
            }
            if !snapshot.networkAvailable { Label("No network connection. Downloads wait and then continue by themselves.", systemImage: "wifi.slash").accessibilityIdentifier("downloadsOffline") }
            else if snapshot.networkConstrained { Label("Low Data Mode is on for this connection. Automatic downloads wait; you can start one anyway.", systemImage: "tortoise").accessibilityIdentifier("downloadsConstrained") }
            else if snapshot.networkExpensive { Label("This connection is metered. Automatic downloads wait; you can start one anyway.", systemImage: "dollarsign.circle").accessibilityIdentifier("downloadsExpensive") }
            if snapshot.lowPowerMode { Label("Low Power Mode: one download at a time.", systemImage: "battery.25percent").accessibilityIdentifier("downloadsLowPower") }
        }.font(.callout).foregroundStyle(MusicStyle.secondaryText)
    }
    @ViewBuilder private var aggregate: some View {
        let snapshot = model.snapshot
        if let aggregate = snapshot.aggregate {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                if let fraction = aggregate.fraction, let total = aggregate.totalBytes {
                    ProgressView(value: fraction) { Text("\(snapshot.activeCount) downloading, \(snapshot.waitingCount) waiting") }
                        .accessibilityValue(Text("\(DownloadsText.bytes(aggregate.completedBytes)) of \(DownloadsText.bytes(total))"))
                    Text("\(DownloadsText.bytes(aggregate.completedBytes)) of \(DownloadsText.bytes(total))").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                } else {
                    // The total is not known yet, so no percentage and no fake bar.
                    Text("\(snapshot.activeCount) downloading, \(snapshot.waitingCount) waiting · \(DownloadsText.bytes(aggregate.completedBytes)) so far").accessibilityIdentifier("downloadsAggregateUnknown")
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("downloadsAggregate")
        }
    }
    private var storageCard: some View {
        let storage = model.snapshot.storage
        return VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text("Storage").font(.headline).accessibilityAddTraits(.isHeader)
            ProgressView(value: Double(min(storage.usedBytes, storage.budgetBytes)), total: Double(max(1, storage.budgetBytes)))
                .accessibilityLabel(Text("Download storage used")).accessibilityValue(Text("\(DownloadsText.bytes(storage.usedBytes)) of \(DownloadsText.bytes(storage.budgetBytes))"))
            Text("\(DownloadsText.bytes(storage.usedBytes)) used of \(DownloadsText.bytes(storage.budgetBytes)) across all accounts").accessibilityIdentifier("downloadsStorageUsed")
            Text("\(DownloadsText.bytes(storage.reserveBytes)) is always kept free on this Mac.").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("downloadsReserve")
            HStack {
                Picker("Storage limit", selection: Binding(get: { storage.budgetBytes }, set: { model.setBudget(bytes: $0) })) {
                    ForEach(DownloadBudgetChoices.options(including: storage.budgetBytes), id: \.self) { Text(DownloadsText.bytes($0)).tag($0) }
                }.frame(maxWidth: 260).accessibilityIdentifier("downloadsBudget")
                Spacer()
            }
            if model.snapshot.smartDownloadsAvailable {
                Toggle(isOn: Binding(get: { model.snapshot.smartDownloadsEnabled }, set: { model.setSmartDownloads($0) })) {
                    VStack(alignment: .leading) {
                        Text("Smart Downloads")
                        Text("Off unless you turn it on. When on, it keeps suggestions for you using at most \(DownloadsText.bytes(storage.automaticCapBytes)), a quarter of the limit, and never removes anything you chose to keep.")
                            .font(.caption).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }.accessibilityIdentifier("downloadsSmart")
            } else {
                // No control: nothing here can suggest items, so a switch would do nothing.
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    Label("Smart Downloads", systemImage: "sparkles").font(.body)
                    Text(DownloadsText.smartUnavailable).font(.caption).foregroundStyle(MusicStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("downloadsSmartUnavailable")
            }
            if model.snapshot.unlistedBytes > 0 {
                Text("\(DownloadsText.bytes(model.snapshot.unlistedBytes)) of earlier downloads are no longer listed but still count toward the limit.").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("downloadsUnlisted")
            }
            Text("Lowering the limit never removes downloads you chose to keep.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
        }.padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface()
    }
    private var choicesCard: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Label("Downloads are paused for storage. Nothing you kept was deleted. Choose how to make room:", systemImage: "externaldrive.badge.exclamationmark").font(.headline)
            ForEach(model.snapshot.storageChoices, id: \.self) { choice in
                switch choice {
                case .raiseBudget:
                    Menu("Raise the storage limit") {
                        ForEach(DownloadBudgetChoices.choices.filter { $0 > model.snapshot.storage.budgetBytes }, id: \.self) { size in Button(DownloadsText.bytes(size)) { model.setBudget(bytes: size) } }
                    }.musicPageAction().accessibilityIdentifier("downloadsChoice-raiseBudget")
                case .removeAutomaticDownloads:
                    Button(DownloadsText.storageChoice(choice)) { model.removeAutomaticDownloads() }.musicPageAction().accessibilityIdentifier("downloadsChoice-removeAutomatic")
                case .removeDownloads, .freeDiskSpace:
                    Label(DownloadsText.storageChoice(choice), systemImage: "arrow.right.circle").foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("downloadsChoice-" + choice.rawValue)
                }
            }
        }.padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading).musicInsetSurface().accessibilityElement(children: .contain).accessibilityIdentifier("downloadsStorageChoices")
    }
    @ViewBuilder private var collectionsSection: some View {
        if !model.snapshot.collections.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text("Playlists kept offline").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(model.snapshot.collections) { collection in
                    HStack {
                        Label(collection.title, systemImage: "music.note.list")
                        Spacer()
                        Text("\(collection.availableCount) of \(collection.memberCount) downloaded").foregroundStyle(MusicStyle.secondaryText)
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("downloadsCollection-" + collection.id.rawValue)
                }
            }
        }
    }
    @ViewBuilder private var list: some View {
        let rows = model.visibleRows
        if rows.isEmpty {
            if model.filter == .downloadedOnly && !model.snapshot.rows.isEmpty {
                EmptyState(title: "Nothing is downloaded yet", message: "Items finish here once they are saved on this Mac.").accessibilityIdentifier("downloadsEmptyFiltered")
            } else {
                EmptyState(title: "Nothing downloaded yet", message: "Add an audio file from this Mac to keep it here and play it from this screen.").accessibilityIdentifier("downloadsEmpty")
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    DownloadItemRow(row: row, perform: { model.perform($0, on: row) }).identityItem(Self.rowItem(row))
                    Divider()
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("downloadsList")
        }
    }
}

/// One download: its title, the state in words, honest progress, the reason it is waiting, and only the actions that apply.
struct DownloadItemRow: View {
    let row: DownloadRowModel
    let perform: (DownloadAction) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(row.title).font(.body)
                    if let subtitle = row.subtitle { Text(subtitle).font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                }
                Spacer()
                Text(DownloadsText.phase(row.phase)).font(.callout.bold()).accessibilityIdentifier("downloadPhase-" + row.id.uuidString)
            }
            progress
            if let cause = row.pauseCause, row.phase == .paused { Text(DownloadsText.pause(cause)).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("downloadReason-" + row.id.uuidString) }
            if let failure = row.failure, row.phase == .failed { Label(DownloadsText.failure(failure), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("downloadFailure-" + row.id.uuidString) }
            if let retry = row.retryAt, row.phase == .queued { Text("Trying again \(retry, format: .relative(presentation: .named))").font(.caption).foregroundStyle(MusicStyle.secondaryText) }
            if row.phase == .expired { Text("The permission to keep this item ended. Renew it or download it again.").font(.caption).foregroundStyle(MusicStyle.secondaryText) }
            if row.phase == .available || row.phase == .renewing, row.pinned || row.referenceCount > 0 {
                (row.pinned ? Text("Kept on this Mac") : Text("Kept for a playlist")).font(.caption).foregroundStyle(MusicStyle.secondaryText)
            }
            if !row.actions.isEmpty {
                HStack {
                    ForEach(row.actions, id: \.self) { action in
                        Button(DownloadsText.action(action)) { perform(action) }.musicPageAction().accessibilityIdentifier("downloadAction-\(action.rawValue)-" + row.id.uuidString)
                            .accessibilityLabel(Text("\(DownloadsText.action(action)) \(row.title)"))
                    }
                }
            }
        }.padding(.vertical, MusicSpace.sm).accessibilityElement(children: .contain).accessibilityIdentifier("downloadRow-" + row.id.uuidString)
    }
    @ViewBuilder private var progress: some View {
        switch row.phase {
        case .downloading, .resolving, .validating, .queued, .paused:
            if let fraction = row.progress.fraction {
                ProgressView(value: fraction).accessibilityLabel(Text("Download progress")).accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
            } else if row.phase == .downloading || row.phase == .resolving {
                // Size unknown: say so, with the bytes so far, and show no percentage.
                HStack { ProgressView().controlSize(.small); Text("\(DownloadsText.bytes(row.progress.completedBytes)) so far · size not known yet").font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("downloadIndeterminate-" + row.id.uuidString)
            }
        default: EmptyView()
        }
    }
}

/// The kept items that can be played right now, with a Play action each: the "Downloaded only" navigation inside the Library.
/// Library rows themselves are YouTube Music and are never downloaded, so this lists only what is kept on this Mac.
public struct DownloadedItemsSection: View {
    @Bindable var model: DownloadsModel
    public init(model: DownloadsModel) { self.model = model }
    public var body: some View {
        let kept = model.snapshot.rows.filter { $0.phase == .available }
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            if kept.isEmpty {
                EmptyState(title: "Nothing is downloaded yet", message: "YouTube Music playlists are streamed, not kept on this Mac. Audio files you add in Downloads appear here.").accessibilityIdentifier("libraryDownloadedEmpty")
            } else {
                ForEach(kept) { row in
                    HStack {
                        VStack(alignment: .leading) { Text(row.title); if let subtitle = row.subtitle { Text(subtitle).font(.caption).foregroundStyle(MusicStyle.secondaryText) } }
                        Spacer()
                        if row.actions.contains(.play) {
                            Button { model.perform(.play, on: row) } label: { Label("Play", systemImage: "play.fill") }.musicPageAction(prominent: true)
                                .accessibilityLabel(Text("Play \(row.title)")).accessibilityIdentifier("libraryDownloadedPlay-" + row.id.uuidString)
                        }
                    }
                    .padding(.vertical, MusicSpace.xs)
                    .background(GeometryReader { geometry in Color.clear.preference(key: DownloadedRowFrames.self, value: [row.id.uuidString: geometry.frame(in: .named(DownloadedRowFrames.space))]) })
                    .accessibilityElement(children: .contain).accessibilityIdentifier("libraryDownloadedRow-" + row.id.uuidString)
                }
            }
        }.coordinateSpace(name: DownloadedRowFrames.space).task { model.start() }
    }
}
/// Where each kept row was laid out, so a render check can prove rows do not overlap.
public struct DownloadedRowFrames: PreferenceKey {
    public static let space = "downloadedItemsSection"
    public static let defaultValue: [String: CGRect] = [:]
    public static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}
