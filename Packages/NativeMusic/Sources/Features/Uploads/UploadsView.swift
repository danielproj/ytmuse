import AccountSession
import DesignSystem
import SwiftUI

/// Add music: the capability as it really is. Without an upload route there is no upload control at all, only the plain statement
/// that uploading arrives later; with one, a chooser and a drop area, and the route's own facts.
struct UploadIntakeView: View {
    @Bindable var surface: UploadsSurface
    @State private var targeted = false
    var body: some View {
        let queue = surface.queue
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            switch queue.capability.availability {
            case .unavailable(let reason):
                Label { VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    Text(reason).font(.headline)
                    Text("You can browse the music you’ve already uploaded and remove it here. Adding music from this Mac isn’t available yet.").font(.callout).foregroundStyle(MusicStyle.secondaryText)
                } } icon: { Image(systemName: "clock.arrow.circlepath") }
                .accessibilityElement(children: .combine).accessibilityIdentifier("uploadsCapability-unavailable")
            case .available:
                MusicGlassGroup {
                    HStack(spacing: MusicSpace.sm) {
                        Button { Task { await surface.chooseFiles() } } label: { Label("Choose Files…", systemImage: "plus") }
                            .musicButtons(prominent: true).accessibilityIdentifier("uploadChoose")
                        Text("or drop audio files here").foregroundStyle(MusicStyle.secondaryText)
                        Spacer()
                    }
                    .padding(MusicSpace.sm).frame(maxWidth: .infinity)
                    .musicDashedOutline(.media, targeted ? Color.accentColor : MusicStyle.secondaryText.opacity(0.4))
                    .musicAnimation(.selection, value: targeted)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    Task { await queue.add(urls) }
                    return !urls.isEmpty
                } isTargeted: { targeted = $0 }
                .accessibilityElement(children: .contain).accessibilityIdentifier("uploadDropZone")
                Text("Only upload music you have the right to. YouTube Music checks each file after it’s uploaded and decides what it accepts. Your files on this Mac are only read, never changed or deleted.")
                    .font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("uploadNotice")
                Text(capabilityFacts).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("uploadFacts")
            }
            if !queue.refusals.isEmpty { refusals(queue) }
            if let failure = queue.storeFailure { Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("uploadStoreFailure") }
        }
    }
    private var capabilityFacts: String {
        let capability = surface.queue.capability
        var parts: [String] = [capability.resumption == .supported ? String(localized: "An interrupted upload can be resumed.") : String(localized: "An interrupted upload can’t be resumed; it starts over.")]
        if let limit = capability.maximumFileBytes { parts.append(String(localized: "YouTube Music accepts files up to \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)).")) }
        return parts.joined(separator: " ")
    }
    private func refusals(_ queue: UploadQueue) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            ForEach(queue.refusals) { refusal in
                Label { Text("\(refusal.name): \(refusal.reason.message)") } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("uploadRefusal-" + refusal.name)
            }
            Button("Dismiss") { queue.dismissRefusals() }.musicButtons().accessibilityIdentifier("uploadRefusalsDismiss")
        }
        .onAppear { Announcer.post(String(localized: "Some files weren’t added."), kind: .error) }
    }
}

/// One job: what it is doing now, in the service's terms, with only the actions that make sense for its state.
struct UploadJobRow: View {
    @Bindable var queue: UploadQueue
    let job: UploadJob
    var body: some View {
        let name = job.source.displayName
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            HStack(spacing: MusicSpace.xs) {
                VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                    Text(job.source.metadata.title).font(.body).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(1)
                }
                Spacer()
                if job.isActive || job.phase == .interrupted {
                    Button("Cancel") { Task { await queue.cancel(job.id) } }.musicButtons().accessibilityIdentifier("uploadJobCancel-" + name)
                }
                if job.isTerminal {
                    Button("Dismiss") { queue.dismiss(job.id) }.musicButtons().accessibilityIdentifier("uploadJobDismiss-" + name)
                }
            }
            if job.phase == .uploading { ProgressView(value: job.fraction).accessibilityLabel(Text("Uploading \(job.source.metadata.title)")).accessibilityIdentifier("uploadJobProgress-" + name) }
            if job.phase == .processing { ProgressView().controlSize(.small).accessibilityLabel(Text("Processing \(job.source.metadata.title)")) }
            Text(stateLine).font(.caption).foregroundStyle(job.phase == .failed ? MusicStyle.errorText : MusicStyle.secondaryText)
                .accessibilityIdentifier("uploadJobState-" + name)
            if let words = job.serverMessage, !words.isEmpty {
                Text("YouTube Music said: \(words)").font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("uploadJobServerMessage-" + name)
            }
            if let note = job.checkNote { Text(note).font(.caption).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("uploadJobNote-" + name) }
            actions(name)
        }
        .padding(.vertical, MusicSpace.xxs)
        .accessibilityElement(children: .contain).accessibilityIdentifier("uploadJob-" + name)
        .onChange(of: job.phase) { _, phase in
            if phase == .completed || phase == .failed { Announcer.post(stateLine, kind: phase == .failed ? .error : .download) }
        }
    }
    private var detail: String {
        var parts = [job.source.displayName, ByteCountFormatter.string(fromByteCount: job.source.byteCount, countStyle: .file)]
        if let format = job.source.format { parts.append(job.source.contentConfirmed ? format.label : String(localized: "\(format.label) by its name")) }
        if let artist = job.source.metadata.artist { parts.insert(artist, at: 0) }
        return parts.joined(separator: " · ")
    }
    private var stateLine: String {
        let percent = Int((job.fraction ?? 0) * 100)
        return switch job.phase {
        case .queued: String(localized: "Waiting to upload")
        case .uploading: String(localized: "Uploading… \(percent)%")
        case .processing: String(localized: "Uploaded. YouTube Music is processing this file; it isn’t in your library yet.")
        case .completed:
            switch job.listing {
            case .refreshed?: String(localized: "YouTube Music finished processing this file. Your uploads list was updated.")
            case .refreshFailed?: String(localized: "YouTube Music finished processing this file, but your uploads list couldn’t be updated. Refresh it to see the file.")
            default: String(localized: "YouTube Music finished processing this file.")
            }
        case .failed: job.reason?.message ?? String(localized: "This upload failed.")
        case .cancelled: job.serverMayStillProcess ? String(localized: "Cancelled. YouTube Music already had this file and may still add it.") : String(localized: "Cancelled. Your file wasn’t changed.")
        case .interrupted:
            queue.canResume(job) ? (job.reason?.message ?? "") + " " + String(localized: "It can be resumed.")
                : (job.reason?.message ?? "") + " " + String(localized: "YouTube Music can’t resume an interrupted upload, so it has to start over.")
        }
    }
    @ViewBuilder private func actions(_ name: String) -> some View {
        HStack(spacing: MusicSpace.xs) {
            if queue.canResume(job) { Button("Resume") { queue.resume(job.id) }.musicButtons(prominent: true).accessibilityIdentifier("uploadJobResume-" + name) }
            if queue.canStartOver(job), job.phase == .interrupted { Button("Start Over") { queue.startOver(job.id) }.musicButtons().accessibilityIdentifier("uploadJobStartOver-" + name) }
            else if queue.canStartOver(job) { Button("Try Again") { queue.startOver(job.id) }.musicButtons().accessibilityIdentifier("uploadJobStartOver-" + name) }
            if job.phase == .processing { Button("Check Now") { Task { await queue.checkNow(job.id) } }.musicButtons().accessibilityIdentifier("uploadJobCheck-" + name) }
        }
    }
}

struct UploadJobsView: View {
    @Bindable var queue: UploadQueue
    var body: some View {
        if !queue.jobs.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Text("Uploads in progress and finished").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(queue.jobs) { UploadJobRow(queue: queue, job: $0) }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("uploadJobs")
        }
    }
}

/// The state of a removal at the row it applies to. Nothing here claims removal the service did not confirm.
struct UploadRemovalLine: View {
    @Bindable var removal: UploadRemovalModel
    let itemID: String
    var body: some View {
        if let target = removal.target(itemID: itemID) {
            switch removal.state {
            case .removing:
                HStack(spacing: MusicSpace.xs) { ProgressView().controlSize(.small); Text("Removing “\(target.title)”…").font(.caption).foregroundStyle(MusicStyle.secondaryText) }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("uploadRemovePending-" + itemID)
            case .removed:
                EmptyView()      // shown by `UploadRemovedBanner`: the row is gone once the list is read again
            case .failed(_, let failure):
                HStack(spacing: MusicSpace.xs) {
                    Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText).accessibilityIdentifier("uploadRemoveFailed-" + itemID)
                    if failure != .needsSignIn && failure != .sessionEnded && failure != .notOffered {
                        Button("Try Again") { Task { await removal.retry() } }.musicButtons().accessibilityIdentifier("uploadRemoveRetry-" + itemID)
                    }
                    Button("Dismiss") { removal.dismiss() }.musicButtons().accessibilityIdentifier("uploadRemoveDismiss-" + itemID)
                }.onAppear { Announcer.post(failure.message, kind: .error) }
            case .unconfirmed(_, let unreadable):
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    HStack(spacing: MusicSpace.xs) {
                        Label("YouTube Music didn’t confirm the removal. “\(target.title)” may or may not have been removed.", systemImage: "questionmark.circle").font(.caption)
                            .foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("uploadRemoveUnconfirmed-" + itemID)
                        if !unreadable { Button("Check") { Task { await removal.check() } }.musicButtons().accessibilityIdentifier("uploadRemoveCheck-" + itemID) }
                    }
                    if unreadable {
                        HStack(spacing: MusicSpace.xs) {
                            Text("Your uploads list couldn’t say either. Removing again can’t remove anything else.").font(.caption).foregroundStyle(MusicStyle.secondaryText)
                                .accessibilityIdentifier("uploadRemoveUncheckable-" + itemID)
                            Button("Try Again") { Task { await removal.retryUnconfirmed() } }.musicButtons().accessibilityIdentifier("uploadRemoveRetry-" + itemID)
                            Button("Dismiss") { removal.dismiss() }.musicButtons().accessibilityIdentifier("uploadRemoveDismiss-" + itemID)
                        }
                    }
                }
            case .idle, .confirming: EmptyView()
            }
        }
    }
}

/// The service confirmed a removal. Shown above the list rather than on the row, because the refreshed list no longer holds the row.
struct UploadRemovedBanner: View {
    @Bindable var removal: UploadRemovalModel
    var body: some View {
        if case .removed(let target) = removal.state {
            HStack(spacing: MusicSpace.xs) {
                Label("Removed “\(target.title)” from your uploads. The file on your Mac wasn’t touched.", systemImage: "checkmark.circle").font(.callout)
                    .accessibilityIdentifier("uploadRemoved-" + target.itemID)
                Button("Dismiss") { removal.dismiss() }.musicButtons().accessibilityIdentifier("uploadRemoveDismiss-" + target.itemID)
            }
            .onAppear { Announcer.post(String(localized: "Removed “\(target.title)” from your uploads."), kind: .confirmation) }
        }
    }
}

/// The uploaded songs, albums or artists: the Library's own collection model and rows, plus the one explicit removal action.
struct UploadsCollectionView: View {
    @Bindable var surface: UploadsSurface
    @Bindable var model: LibraryCollectionModel
    let navigator: CatalogNavigator
    let openAccounts: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicGlassGroup {
                HStack(spacing: MusicSpace.xs) {
                    TextField("Search your uploads", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 320).accessibilityIdentifier("uploadsQuery")
                    Spacer()
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .labelStyle(.iconOnly).help(Text("Refresh")).musicButtons().disabled(model.isRefreshing).accessibilityIdentifier("uploadsRefresh")
                }
            }
            UploadRemovedBanner(removal: surface.removal)
            LibraryStateView(model: model, openAccounts: openAccounts)
            if case .content = model.state {
                List {
                    ForEach(model.visibleEntries) { entry in
                        VStack(alignment: .leading, spacing: MusicSpace.hairline) {
                            HStack(alignment: .top, spacing: MusicSpace.xs) {
                                LibraryRow(surface: surface.library, entry: entry, source: model.source, navigator: navigator)
                                if surface.removal.offers(entry.item) {
                                    Button { surface.removal.request(removing: entry.item) } label: { Label("Remove…", systemImage: "trash") }
                                        .labelStyle(.iconOnly).accessibilityLabel(Text("Remove \(entry.item.title) from your uploads"))
                                        .help(surface.removal.canRequest ? Text("Remove \(entry.item.title) from your uploads") : Text("Finish or dismiss the removal in progress first."))
                                        .disabled(!surface.removal.canRequest).musicButtons().accessibilityIdentifier("uploadRemove-" + entry.item.id)
                                }
                            }
                            UploadRemovalLine(removal: surface.removal, itemID: entry.item.id)
                        }
                        .accessibilityActions {
                            if surface.removal.offers(entry.item), surface.removal.canRequest { Button("Remove from Uploads…") { surface.removal.request(removing: entry.item) } }
                        }
                    }
                    footer.listRowSeparator(.hidden)
                }
                .scrollContentBackground(.hidden).accessibilityIdentifier("uploadsList")
            }
        }
        .task(id: surface.selectedKind) { await model.load(); if model.isStale { await model.refresh() } }
    }
    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            if model.hasMore {
                HStack {
                    if model.loadingMore { ProgressView().controlSize(.small).accessibilityLabel(Text("Loading more")) }
                    else if let failure = model.moreFailure {
                        Label(failure.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(MusicStyle.errorText)
                        Button("Retry") { Task { await model.loadMore() } }.musicButtons()
                    } else { Color.clear.frame(width: 1, height: 1).onAppear { Task { await model.loadMore() } } }
                }
            }
            LibraryStatusLine(model: model)
        }.padding(.vertical, MusicSpace.xs)
    }
}

extension MusicUploadKind {
    var title: String {
        switch self { case .songs: String(localized: "Songs"); case .albums: String(localized: "Albums"); case .artists: String(localized: "Artists") }
    }
    var symbol: String {
        switch self { case .songs: "music.note"; case .albums: "square.stack"; case .artists: "person.2" }
    }
}

/// The Uploads destination (MEDIA06): add music (when the service route exists), the jobs, and the uploaded songs, albums and artists.
public struct UploadsView: View {
    @Bindable var surface: UploadsSurface
    let navigator: CatalogNavigator
    let openAccounts: () -> Void
    public init(surface: UploadsSurface, navigator: CatalogNavigator, openAccounts: @escaping () -> Void = {}) {
        self.surface = surface; self.navigator = navigator; self.openAccounts = openAccounts
    }
    public var body: some View {
        let removal = surface.removal
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            HStack(alignment: .top) {
                Text("Uploads").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader).accessibilityIdentifier("destinationTitle").browserRegion("destinationTitle").layoutPriority(1)
                Spacer(minLength: MusicSpace.xs)
                if surface.development { Text("Development data · Not YouTube Music").font(.caption).foregroundStyle(MusicStyle.secondaryText).multilineTextAlignment(.trailing).accessibilityIdentifier("developmentDataLabel") }
            }
            UploadIntakeView(surface: surface).audit("uploadsIntake", group: "page-top", within: "detailPanel", alignLeading: "pageLeading")
            UploadJobsView(queue: surface.queue).audit("uploadsJobs", group: "page-top", within: "detailPanel", alignLeading: "pageLeading")
            MusicGlassGroup {
                HStack(spacing: MusicSpace.xs) {
                    ForEach(MusicUploadKind.allCases, id: \.self) { kind in
                        Button { surface.selectedKind = kind } label: { Label(kind.title, systemImage: kind.symbol) }
                            .musicButtons(prominent: kind == surface.selectedKind)
                            .accessibilityAddTraits(kind == surface.selectedKind ? .isSelected : [])
                            .accessibilityIdentifier("uploadsKind-" + kind.rawValue)
                    }
                }
            }
            UploadsCollectionView(surface: surface, model: surface.model, navigator: navigator, openAccounts: openAccounts).id(surface.selectedKind)
        }
        .padding(MusicSpace.lg).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.libraryLedger, surface.library.ledger)
        // The question names the one upload and says what stays untouched; sending happens only from its destructive button.
        .confirmationDialog(removal.confirming.map { String(localized: "Remove “\($0.title)” from your uploads?") } ?? "",
                            isPresented: Binding(get: { removal.confirming != nil }, set: { if !$0 { removal.cancel() } }), titleVisibility: .visible, presenting: removal.confirming) { _ in
            Button("Remove from Uploads", role: .destructive) { if removal.begin() { Task { await removal.complete() } } }
            Button("Cancel", role: .cancel) { removal.cancel() }
        } message: { target in
            Text("This deletes “\(target.description)” from your YouTube Music uploads. The file on your Mac isn’t touched.")
        }
    }
}
