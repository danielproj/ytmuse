import AccountSession
import Foundation
import Observation

public enum SearchRemoteFailure: Sendable, Equatable { case offline, rateLimited, unavailable, unrecognised }
public struct SearchRemoteInfo: Sendable, Equatable {
    public let signedIn: Bool
    public let sessionExpired: Bool
    public let noResults: Bool
    public let skippedRows: Int
    public let unsupportedRows: Int
    /// False: one page of the service's answer, never a claim about the whole catalog.
    public let complete: Bool
}
public enum SearchRemoteStatus: Sendable, Equatable {
    case idle, localOnly, waiting, loading, loaded(SearchRemoteInfo), failed(SearchRemoteFailure)
}
public struct SearchCorrectionOffer: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case service, serviceAlreadyApplied, library }
    public let text: String
    public let source: Source
}

/// Persistent search: immediate local matches, then YouTube Music results after a
/// quiet period, with every asynchronous reply fenced by the query generation and the
/// account scope it was asked in.
///
/// Rules this type keeps:
/// - the typed query is never rewritten; a correction is only offered and changes the
///   query when `applyCorrection()` is called, and the original stays recoverable;
/// - typing never starts playback or any other action;
/// - a reply for an older query, or for another account scope, cannot replace what is shown;
/// - local results stay where they are when service results arrive (service results append);
/// - a failure of the service keeps the local results and says what failed.
@MainActor @Observable public final class SearchModel {
    public typealias RemoteSearch = @Sendable (String) async throws -> MusicSearchReply

    public var query: String { didSet { if query != oldValue { queryDidChange() } } }
    public var scope: SearchPlace { didSet { if scope != oldValue { corrected = nil; pendingSelection = nil; restart() } } }
    public private(set) var sections: [SearchSection] = []
    public private(set) var remoteStatus: SearchRemoteStatus = .idle
    public private(set) var correction: SearchCorrectionOffer?
    /// What the person typed before a correction was applied; nil when none was.
    public private(set) var corrected: String?
    public var selection: String? { didSet { if let selection, selection != oldValue, selection != pendingSelection, selection != restoredSelection { pendingSelection = nil } } }
    /// A selection Back or Forward is putting back (not the keyboard or a click): the list must not scroll it into view over the restored offset.
    @ObservationIgnored private var restoredSelection: String?
    /// A selection to apply once the result it names has arrived; results come in after the query, so it cannot be set straight away.
    @ObservationIgnored private var pendingSelection: String?
    public func restoreSelection(_ id: String?) {
        pendingSelection = id
        if id == nil { selection = nil } else { applyPendingSelection() }
    }
    private func applyPendingSelection() {
        guard let id = pendingSelection, results.contains(where: { $0.id == id }) else { return }
        pendingSelection = nil; restoredSelection = id; selection = id
    }
    /// True once, for the change `restoreSelection` made.
    public func takeRestoredSelection(_ id: String) -> Bool {
        defer { if restoredSelection == id { restoredSelection = nil } }
        return restoredSelection == id
    }
    public private(set) var feedback: [String: SearchItemFeedback] = [:]
    public private(set) var queryTooLong = false

    @ObservationIgnored private let sources: [any LocalSearchSource]
    @ObservationIgnored private let remote: RemoteSearch?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let playbackState: @MainActor () -> SearchPlayback
    @ObservationIgnored private let localLimit: Int
    @ObservationIgnored public weak var performer: (any SearchActionPerformer)?
    /// Opens a result's own page (artist, album, playlist, podcast show, song). Set by the shell, which owns navigation.
    @ObservationIgnored public var opener: (@MainActor (SearchResult) -> Void)?
    /// Recent queries and items (SEARCH02). Nil when the composition supplies no store.
    public let recents: SearchRecents?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var remoteTask: Task<Void, Never>?
    @ObservationIgnored private var localResults: [SearchResult] = []
    @ObservationIgnored private var localCorrection: String?
    @ObservationIgnored private var remoteTop: SearchResult?
    @ObservationIgnored private var remoteItems: [SearchResult] = []
    @ObservationIgnored private var remoteSuggestion: MusicSearchSuggestion?
    @ObservationIgnored private var scopeRetried = false

    public init(sources: [any LocalSearchSource] = [], remote: RemoteSearch? = nil, performer: (any SearchActionPerformer)? = nil,
                clock: any Clock<Duration> = ContinuousClock(), debounce: Duration = .milliseconds(180),
                /// An opaque token that differs whenever the account scope (who is active, and whether their session is live) differs.
                accountScope: @escaping @MainActor () -> String = { "" },
                playback: @escaping @MainActor () -> SearchPlayback = { .needsSignIn },
                localLimit: Int = 50, recents: SearchRecents? = nil, query: String = "", scope: SearchPlace = .all) {
        self.recents = recents
        self.sources = sources; self.remote = remote; self.performer = performer; self.clock = clock; self.debounce = debounce
        self.accountScope = accountScope; playbackState = playback; self.localLimit = localLimit
        self.query = query; self.scope = scope
        if !query.isEmpty { restart() }
    }

    // MARK: Derived state

    public var results: [SearchResult] { sections.flatMap(\.results) }
    /// The query the current results answer, before any correction the person applied.
    public var originalQuery: String { corrected ?? query }
    public var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isSearching: Bool { remoteStatus == .waiting || remoteStatus == .loading }
    public var playback: SearchPlayback { playbackState() }
    public func offers(for result: SearchResult) -> [SearchActionOffer] { SearchActionPlan.offers(for: result, playback: playbackState()) }
    /// What Return does: Play where the item has one (even if it cannot run, so the reason is shown at the item).
    public func primaryAction(for result: SearchResult) -> SearchAction? { offers(for: result).first(where: { $0.action == .play })?.action }
    public var scopeNotice: String? {
        switch scope {
        case .all: nil
        case .library: String(localized: "Searching the playlists in your library on this Mac. The service is not asked.")
        }
    }

    // MARK: Query lifecycle

    private func queryDidChange() {
        pendingSelection = nil
        if corrected != nil, !applyingCorrection { corrected = nil }
        restart()
    }
    @ObservationIgnored private var applyingCorrection = false

    /// Return in the field: ask the service now instead of waiting out the quiet period.
    public func submit() { recents?.record(query: query); restart(immediateRemote: true) }
    /// The shell calls this when the active account (or its session) changes.
    public func accountChanged() {
        feedback = [:]; scopeRetried = false
        restart(immediateRemote: !trimmedQuery.isEmpty)
    }
    /// Applies the offered respelling. The original stays available through `originalQuery` and `revertCorrection()`.
    public func applyCorrection() {
        guard let correction else { return }
        let original = query
        applyingCorrection = true; defer { applyingCorrection = false }
        corrected = original
        query = correction.text
        restart(immediateRemote: true)
    }
    public func revertCorrection() {
        guard let corrected else { return }
        applyingCorrection = true; defer { applyingCorrection = false }
        let original = corrected
        self.corrected = nil
        query = original
        restart(immediateRemote: true)
    }
    /// A local source's data changed (for example the library finished loading): re-match locally, leaving the service request alone.
    public func refreshLocal() {
        guard !trimmedQuery.isEmpty, !queryTooLong else { return }
        let current = generation, parsed = FoldedQuery(query)
        localTask?.cancel()
        localTask = Task { [weak self] in await self?.runLocal(parsed, generation: current) }
    }
    public func retryRemote() { scopeRetried = false; restart(immediateRemote: true) }
    public func clear() { query = "" }

    private func restart(immediateRemote: Bool = false) {
        generation &+= 1
        let current = generation
        scopeRetried = false   // the one automatic re-ask belongs to this query alone
        localTask?.cancel(); remoteTask?.cancel()
        localResults = []; localCorrection = nil; remoteTop = nil; remoteItems = []; remoteSuggestion = nil
        let trimmed = trimmedQuery
        queryTooLong = query.utf8.count > 512
        guard !trimmed.isEmpty, !queryTooLong else {
            remoteStatus = .idle; correction = nil; feedback = [:]; selection = nil; rebuild(); return
        }
        let parsed = FoldedQuery(query)
        rebuild()
        localTask = Task { [weak self] in await self?.runLocal(parsed, generation: current) }
        startRemote(trimmed, generation: current, immediate: immediateRemote)
    }

    private func runLocal(_ parsed: FoldedQuery, generation current: UInt64) async {
        var found: [SearchResult] = []
        var vocabulary: [String] = []
        for source in sources where source.scopes.contains(scope) {
            found += await source.search(parsed, limit: localLimit)
            if Task.isCancelled || current != generation { return }
        }
        if !found.contains(where: { $0.quality != .tolerant }) {
            for source in sources where source.scopes.contains(scope) { vocabulary += await source.vocabulary() }
            if Task.isCancelled || current != generation { return }
        }
        guard current == generation else { return }
        localResults = found
        localCorrection = found.contains(where: { $0.quality != .tolerant }) ? nil : SearchCorrection.suggest(for: parsed, vocabulary: vocabulary)
        rebuild()
    }

    private func startRemote(_ trimmed: String, generation current: UInt64, immediate: Bool) {
        guard scope.asksService, let remote else { remoteStatus = scope.asksService ? .failed(.unavailable) : .localOnly; return }
        remoteStatus = immediate ? .loading : .waiting
        remoteTask = Task { [weak self, clock, debounce] in
            if !immediate {
                do { try await clock.sleep(for: debounce) } catch { return }
            }
            guard let self, !Task.isCancelled, current == self.generation else { return }
            self.remoteStatus = .loading
            await self.runRemote(trimmed, generation: current, remote: remote)
        }
    }

    private func runRemote(_ trimmed: String, generation current: UInt64, remote: RemoteSearch) async {
        do {
            let scopeAtStart = accountScope()
            let reply = try await remote(trimmed)
            guard !Task.isCancelled, current == generation else { return }
            guard accountScope() == scopeAtStart else {
                await askAgainForNewScope(trimmed, generation: current, remote: remote); return
            }
            apply(reply)
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            switch error as? MusicSessionError {
            case .stale: await askAgainForNewScope(trimmed, generation: current, remote: remote); return
            case .network, .timedOut: remoteStatus = .failed(.offline)
            case .rateLimited: remoteStatus = .failed(.rateLimited)
            case .unrecognised, .oversized: remoteStatus = .failed(.unrecognised)
            default: remoteStatus = .failed(.unavailable)
            }
            rebuild()
        }
    }
    /// The account changed while a request was in flight, so its answer cannot be shown.
    /// Ask once more for the current scope; a second mismatch is reported, not looped.
    private func askAgainForNewScope(_ trimmed: String, generation current: UInt64, remote: RemoteSearch) async {
        guard !scopeRetried else { remoteStatus = .failed(.unavailable); rebuild(); return }
        scopeRetried = true
        await runRemote(trimmed, generation: current, remote: remote)
    }

    private func apply(_ reply: MusicSearchReply) {
        let response = reply.response
        remoteTop = response.top.map { SearchResult($0, top: true) }
        remoteItems = response.items.map { SearchResult($0, top: false) }
        remoteSuggestion = response.suggestion
        remoteStatus = .loaded(SearchRemoteInfo(signedIn: reply.mode == .signedIn, sessionExpired: reply.sessionExpired,
            noResults: response.serviceReportedNoResults, skippedRows: response.skippedRows, unsupportedRows: response.unsupportedRows,
            complete: response.complete))
        rebuild()
    }

    // MARK: Presentation

    private func rebuild() {
        correction = {
            if let remoteSuggestion {
                let text = remoteSuggestion.text
                guard SearchText.fold(text) != SearchText.fold(query) else { return nil }
                return SearchCorrectionOffer(text: text, source: remoteSuggestion.appliedByService ? .serviceAlreadyApplied : .service)
            }
            return localCorrection.map { SearchCorrectionOffer(text: $0, source: .library) }
        }()
        guard !trimmedQuery.isEmpty else { sections = []; return }
        let admitted = localResults.filter { result in
            switch scope {
            case .all: true
            case .library: result.badges.contains(.library)
            }
        }
        var merged: [String: SearchResult] = [:]
        var order: [String] = []
        func place(_ result: SearchResult) {
            if let existing = merged[result.id] { merged[result.id] = existing.merged(with: result) }
            else { merged[result.id] = result; order.append(result.id) }
        }
        if scope.asksService, let remoteTop { place(remoteTop) }
        for result in admitted.sorted(by: SearchRanking.order) { place(result) }
        if scope.asksService { for result in remoteItems { place(result) } }
        var byGroup: [SearchGroup: [SearchResult]] = [:]
        let topID = scope.asksService ? remoteTop?.id : nil
        for id in order {
            guard var result = merged[id] else { continue }
            if id != topID, result.group == .top { result.group = SearchGroup.group(for: result.kind) }
            if byGroup[result.group, default: []].count < localLimit { byGroup[result.group, default: []].append(result) }
        }
        sections = SearchGroup.allCases.compactMap { group in
            byGroup[group].map { SearchSection(group: group, results: $0) }
        }
        if let selection, !results.contains(where: { $0.id == selection }) { self.selection = nil }
        applyPendingSelection()
    }

    // MARK: Keyboard-driven selection

    public func moveSelection(by delta: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selection.flatMap(ids.firstIndex(of:)) else { selection = delta >= 0 ? ids.first : ids.last; return }
        selection = ids[min(ids.count - 1, max(0, current + delta))]
    }
    public var selectedResult: SearchResult? { selection.flatMap { id in results.first { $0.id == id } } }

    // MARK: Actions (the only path from a result to an effect)

    /// Runs `action` on `result`. A capability the item or account lacks is reported at
    /// that item, never swallowed and never retried as something else.
    public func perform(_ action: SearchAction, on result: SearchResult) async {
        guard let offer = offers(for: result).first(where: { $0.action == action }) else {
            feedback[result.id] = .failed(String(localized: "Opening this kind of result isn’t available yet.")); return
        }
        if let reason = offer.unavailable { feedback[result.id] = .failed(reason); return }
        guard let performer else { feedback[result.id] = .failed(String(localized: "This action isn’t available right now.")); return }
        switch action {
        case .copyLink:
            guard let link = SearchActionPlan.link(for: result) else { feedback[result.id] = .failed(String(localized: "This result has no link.")); return }
            performer.copy(link: link); feedback[result.id] = .copied
            recordChoice(result)
        case .share:
            if let refusal = CatalogShareLink.share(SearchActionPlan.link(for: result), via: performer) { feedback[result.id] = .failed(refusal) } else { feedback[result.id] = nil }
        case .play:
            guard let playlist = SearchActionPlan.playlist(for: result) else { feedback[result.id] = .failed(String(localized: "This result didn’t include anything to play.")); return }
            let scopeAtStart = accountScope()
            feedback[result.id] = .working
            let outcome = if let video = SearchActionPlan.startVideo(for: result) {
                await performer.play(playlistID: playlist, title: result.title, videoID: video, params: nil)
            } else {
                await performer.play(playlistID: playlist, title: result.title)
            }
            guard accountScope() == scopeAtStart else { feedback[result.id] = nil; return }
            switch outcome {
            case .started: feedback[result.id] = .started; recordChoice(result)
            case .busy: feedback[result.id] = nil
            case .stale: feedback[result.id] = .failed(String(localized: "Your account changed before this started. Try Play again."))
            case .failed: feedback[result.id] = .failed(String(localized: "YouTube Music couldn’t start this. Try Play again."))
            }
        }
    }
    /// Acting on a result is the person choosing it: remember the query that found it and the item itself.
    private func recordChoice(_ result: SearchResult) {
        guard let recents else { return }
        recents.record(query: originalQuery)
        recents.record(item: result)
    }
    /// Whether the result has a page of its own the shell can open.
    public func canOpen(_ result: SearchResult) -> Bool { opener != nil && result.opensPage }
    public func open(_ result: SearchResult) {
        guard canOpen(result), let opener else { feedback[result.id] = .failed(String(localized: "Opening this kind of result isn’t available yet.")); return }
        selection = result.id
        recordChoice(result)
        opener(result)
    }
    /// Return on a result.
    public func activate(_ result: SearchResult) async {
        guard let action = primaryAction(for: result) else {
            if canOpen(result) { open(result); return }
            feedback[result.id] = .failed(String(localized: "Opening this kind of result isn’t available yet.")); return
        }
        await perform(action, on: result)
    }
    public func activateSelection() async { if let result = selectedResult { await activate(result) } }
}
