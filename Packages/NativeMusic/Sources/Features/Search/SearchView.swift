import AccountSession
import AppKit
import DesignSystem
import SwiftUI

/// The search field shared by the Search destination and the command palette.
/// Arrow keys, Return and Escape go to the model; Space and every other key stay with
/// the text field, so editing, the caret and input methods remain native.
public struct SearchField: View {
    @Bindable var model: SearchModel
    let prompt: LocalizedStringKey
    var focus: FocusState<Bool>.Binding
    var identifier: String
    /// Replaces the model's own key handling (the palette routes keys across commands too). The second
    /// argument is true while an input method holds marked text.
    var handler: (@MainActor (SearchKey, Bool) -> SearchKeyOutcome)?
    public init(model: SearchModel, prompt: LocalizedStringKey = "Search songs, albums, artists and playlists", focus: FocusState<Bool>.Binding,
                identifier: String = "searchField", handler: (@MainActor (SearchKey, Bool) -> SearchKeyOutcome)? = nil) {
        self.model = model; self.prompt = prompt; self.focus = focus; self.identifier = identifier; self.handler = handler
    }
    /// The seam between the text field and the models: asks the field editor whether an input method is composing,
    /// then lets the model decide. While composing, every key stays with the input method.
    @MainActor public static func route(_ key: SearchKey, firstResponder: NSResponder?, handle: (SearchKey, Bool) -> SearchKeyOutcome) -> SearchKeyOutcome {
        handle(key, (firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false)
    }
    private func route(_ key: SearchKey) -> KeyPress.Result {
        let outcome = Self.route(key, firstResponder: NSApp.keyWindow?.firstResponder) { key, composing in
            handler?(key, composing) ?? model.handle(key, composing: composing)
        }
        return outcome == .handled ? .handled : .ignored
    }
    public var body: some View {
        // Identity, focus and keys belong to the text field itself (UI automation finds a TextField by identifier); the glass is drawn around it.
        TextField(prompt, text: $model.query)
            .focused(focus)
            .accessibilityLabel(Text("Search"))
            .accessibilityIdentifier(identifier)
            .onKeyPress(.downArrow) { route(.down) }
            .onKeyPress(.upArrow) { route(.up) }
            .onKeyPress(.return) { route(.returnKey) }
            .onKeyPress(.escape) { route(.escape) }
            .musicField(focused: focus.wrappedValue)
            .audit("searchField", group: "page-top", alignLeading: "pageLeading")
    }
}

/// One result: icon, title, detail, badges, a Play button where Play exists, and the
/// result of the last action at the item itself.
public struct SearchResultRow: View {
    let result: SearchResult
    let selected: Bool
    let offers: [SearchActionOffer]
    let feedback: SearchItemFeedback?
    let select: () -> Void
    let perform: (SearchAction) -> Void
    /// Opens the result's own page; nil when the shell has none to open it with.
    let open: (() -> Void)?
    public init(result: SearchResult, selected: Bool, offers: [SearchActionOffer], feedback: SearchItemFeedback?, select: @escaping () -> Void, perform: @escaping (SearchAction) -> Void,
                open: (() -> Void)? = nil) {
        self.result = result; self.selected = selected; self.offers = offers; self.feedback = feedback; self.select = select; self.perform = perform; self.open = open
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            HStack(spacing: MusicSpace.sm) {
                // The item itself reads as one element; Play stays a separate, reachable button.
                HStack(spacing: MusicSpace.sm) {
                    Image(systemName: result.kind.symbol).frame(width: MusicPageStyle.iconColumn).foregroundStyle(MusicStyle.secondaryText).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                        Text(result.title).font(.body.weight(.medium)).lineLimit(2)
                        Text(detail).font(.caption).foregroundStyle(MusicStyle.secondaryText).lineLimit(2)
                        if !result.badges.isEmpty {
                            HStack(spacing: MusicSpace.xs) { ForEach(result.badges.sorted(), id: \.self) { MusicOutlineBadge(verbatim: $0.title, systemImage: $0.symbol) } }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .songDraggable(videoID: result.target.videoID, title: result.title, kind: result.kind == .video ? .video : result.kind == .song ? .song : .category)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("searchResult-" + result.id)
                .accessibilityActions {
                    ForEach(offers) { offer in Button(offer.action.title) { perform(offer.action) } }
                    if let open { Button("Open") { open() } }
                }
                if let open {
                    Button { open() } label: { Label("Open", systemImage: "chevron.right") }
                        .labelStyle(.iconOnly).help(Text("Open \(result.title)")).accessibilityLabel(Text("Open \(result.title)"))
                        .accessibilityIdentifier("searchOpen-" + result.id).musicPageAction()
                }
                if offers.contains(where: { $0.action == .play }) {
                    Button { perform(.play) } label: { Label("Play", systemImage: "play.fill") }
                        .labelStyle(.iconOnly).help(Text("Play \(result.title)")).accessibilityLabel(Text("Play \(result.title)"))
                        .accessibilityIdentifier("searchPlay-" + result.id).musicPageAction()
                }
            }
            if let feedback { feedbackLine(feedback) }
        }
        .musicRow(selected: selected)
        .musicAnimation(.selection, value: selected)
        .onTapGesture(perform: select)
        .directPlaylistMenu(addition: DirectPlaylistAddition.candidate(result), identifier: "searchAddToPlaylist-" + result.id) {
            if let open { Button("Open") { open() } }
            ForEach(offers) { offer in
                Button { perform(offer.action) } label: { Label(offer.action.title, systemImage: offer.action.symbol) }.disabled(!offer.isAvailable)
            }
        }
        // A failure is announced, so a VoiceOver user learns the action did not run without hunting for it.
        .onChange(of: feedback) { _, new in
            if case .failed(let message)? = new { Announcer.post(message, kind: .error) }
        }
    }
    private var detail: String {
        SearchDetail.join([result.typeLabel] + result.details) ?? result.typeLabel
    }
    private var accessibilityLabel: String {
        var parts = [result.title, result.typeLabel] + result.details
        parts += result.badges.sorted().map(\.title)
        return parts.joined(separator: ", ")
    }
    @ViewBuilder private func feedbackLine(_ feedback: SearchItemFeedback) -> some View {
        switch feedback {
        // Starting and started say nothing at the row: the player bar shows the chosen item starting and then playing, so a row never grows a line
        // (and the list never shifts) because music was chosen from it.
        case .working, .started: EmptyView()
        case .copied: Label("Link copied", systemImage: "checkmark.circle").font(.caption).foregroundStyle(MusicStyle.secondaryText)
        case .failed(let message):
            MusicInlineError(message).font(.caption).accessibilityIdentifier("searchItemError-" + result.id)
        }
    }
}

/// What the service did, in words: failures, unread rows, the single-page caveat.
struct SearchStatusView: View {
    @Bindable var model: SearchModel
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            if let correction = model.correction { correctionBanner(correction) }
            else if model.corrected != nil { revertBanner }
            if let notice = model.scopeNotice { Label(notice, systemImage: "info.circle").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("searchScopeNotice") }
            if model.queryTooLong { MusicInlineError(String(localized: "That search is too long.")).font(MusicPageStyle.note) }
            remote
        }
    }
    @ViewBuilder private var remote: some View {
        switch model.remoteStatus {
        case .idle, .localOnly: EmptyView()
        case .waiting, .loading:
            HStack { ProgressView().controlSize(.small); Text("Searching YouTube Music…") }.font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("searchRemoteLoading")
        case .failed(let failure):
            MusicInlineError(message(failure), retryIdentifier: "searchRetry") { model.retryRemote() }.font(MusicPageStyle.note).accessibilityElement(children: .contain).accessibilityIdentifier("searchRemoteError")
        case .loaded(let info):
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                if info.sessionExpired { Label("Your YouTube Music session ended. Sign in again for your own results.", systemImage: "person.crop.circle.badge.exclamationmark").font(MusicPageStyle.note) }
                else if !info.signedIn { Label("Not signed in: these are the results anyone sees.", systemImage: "person.crop.circle").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText) }
                if info.skippedRows > 0 { Label("\(info.skippedRows) results couldn’t be read and are not shown.", systemImage: "exclamationmark.triangle").font(MusicPageStyle.note).accessibilityIdentifier("searchSkipped") }
                if info.unsupportedRows > 0 { Label("\(info.unsupportedRows) results of a type this app doesn’t show were left out.", systemImage: "info.circle").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText) }
                if !info.complete && !model.results.isEmpty { Text("The first page of YouTube Music’s answer, not the whole catalog.").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText) }
            }
        }
    }
    private func message(_ failure: SearchRemoteFailure) -> LocalizedStringKey {
        switch failure {
        case .offline: "YouTube Music couldn’t be reached. Showing matches from this Mac."
        case .rateLimited: "YouTube Music asked to slow down. Showing matches from this Mac; try again shortly."
        case .unavailable: "YouTube Music search isn’t available right now. Showing matches from this Mac."
        case .unrecognised: "YouTube Music answered in a form this version can’t read. Nothing was changed."
        }
    }
    private func correctionBanner(_ correction: SearchCorrectionOffer) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Did you mean “\(correction.text)”?").font(MusicPageStyle.note)
            Button("Search for “\(correction.text)”") { model.applyCorrection() }.musicPageAction().accessibilityIdentifier("applyCorrection")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("searchCorrection")
    }
    private var revertBanner: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Showing results for “\(model.query)”.").font(MusicPageStyle.note)
            Button("Search for “\(model.originalQuery)” instead") { model.revertCorrection() }.musicPageAction().accessibilityIdentifier("revertCorrection")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("searchCorrectionApplied")
    }
}

/// Grouped, scrollable results. The selection follows the keyboard and scrolls into view.
public struct SearchResultsList: View {
    @Bindable var model: SearchModel
    var perform: (@MainActor (SearchResult, SearchAction) -> Void)?
    private let motion = MusicMotionContext()
    public init(model: SearchModel, perform: (@MainActor (SearchResult, SearchAction) -> Void)? = nil) { self.model = model; self.perform = perform }
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MusicSpace.xxs, pinnedViews: []) {
                    ForEach(model.sections) { section in
                        Text(section.group.title).font(MusicPageStyle.section).padding(.top, MusicSpace.sm).accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("searchGroup-" + section.group.rawValue)
                        ForEach(section.results) { result in
                            SearchResultRow(result: result, selected: model.selection == result.id, offers: model.offers(for: result), feedback: model.feedback[result.id],
                                            select: { model.selection = result.id }, perform: { action in run(result, action) },
                                            open: model.canOpen(result) ? { model.open(result) } : nil).id(result.id)
                        }
                    }
                }.padding(.horizontal, MusicSpace.xxs)
            }
            .restoresScroll()
            // A selection put back by Back/Forward is already where the person left it; scrolling to it would move the restored offset.
            .onChange(of: model.selection) { _, id in if let id, model.takeRestoredSelection(id) == false { motion.perform(.selection) { proxy.scrollTo(id) } } }
        }.accessibilityIdentifier("searchResults")
    }
    private func run(_ result: SearchResult, _ action: SearchAction) {
        model.selection = result.id
        if let perform { perform(result, action) } else { Task { await model.perform(action, on: result) } }
    }
}

/// The Search destination: field, scope, status and grouped results.
public struct SearchView: View {
    @Bindable var model: SearchModel
    /// Increment to move keyboard focus to the field (Command-F).
    var focusToken: Int
    @FocusState private var focused: Bool
    public init(model: SearchModel, focusToken: Int = 0) { self.model = model; self.focusToken = focusToken }
    public var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.lg) {
            SearchField(model: model, focus: $focused)
            Picker("Where to search", selection: $model.scope) {
                ForEach(SearchPlace.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(Text("Where to search")).accessibilityIdentifier("searchScope")
                .audit("searchScope", group: "page-top", alignLeading: "pageLeading")
            SearchStatusView(model: model)
            content
        }
        .remembersPage(fresh: { model.beginFreshVisit() }, capture: { model.pageMemory }, apply: { model.restorePage($0) })
        .task { focused = true }
        .onChange(of: focusToken) { _, _ in focused = true }
    }
    @ViewBuilder private var content: some View {
        if model.trimmedQuery.isEmpty {
            SearchEmptyState(model: model)
        } else if model.sections.isEmpty && !model.isSearching {
            EmptyState(title: "No results", message: "Nothing matched. Check the spelling or try fewer words.")
        } else {
            SearchResultsList(model: model)
        }
    }
}

/// An empty search: recent queries and items (kept locally, clearable) and an honest note about discovery.
struct SearchEmptyState: View {
    @Bindable var model: SearchModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MusicSpace.md) {
                if let recents = model.recents, !recents.queries.isEmpty {
                    HStack {
                        Text("Recent searches").font(MusicPageStyle.section).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Clear") { recents.clearQueries() }.musicPageAction().accessibilityIdentifier("clearRecentQueries")
                    }
                    ForEach(recents.queries, id: \.self) { text in
                        Button { model.query = text } label: { Label(text, systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, alignment: .leading).musicRow() }
                            .buttonStyle(.borderless).accessibilityIdentifier("recentQuery").accessibilityHint(Text("Searches again"))
                    }
                }
                if let recents = model.recents, !recents.items.isEmpty {
                    HStack {
                        Text("Recent items").font(MusicPageStyle.section).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Clear") { recents.clearItems() }.musicPageAction().accessibilityIdentifier("clearRecentItems")
                    }
                    ForEach(recents.items) { item in
                        let result = item.result
                        SearchResultRow(result: result, selected: model.selection == result.id, offers: model.offers(for: result), feedback: model.feedback[result.id],
                                        select: { model.selection = result.id }, perform: { action in Task { await model.perform(action, on: result) } },
                                        open: model.canOpen(result) ? { model.open(result) } : nil)
                    }
                }
                if model.recents?.isEmpty ?? true {
                    EmptyState(title: "Search YouTube Music", message: "Matches from your library appear as you type. YouTube Music results follow a moment later.")
                }
                Label("For suggestions and discovery, open Home and Explore.", systemImage: "info.circle")
                    .font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText).accessibilityIdentifier("searchDiscoveryNote")
                if let recents = model.recents, !recents.isEmpty {
                    Text("Recent searches and items stay on this Mac, are never sent anywhere and are removed with the account.").font(MusicPageStyle.note).foregroundStyle(MusicStyle.secondaryText)
                }
            }.padding(.horizontal, MusicSpace.xxs)
        }.accessibilityIdentifier("searchEmpty")
    }
}
