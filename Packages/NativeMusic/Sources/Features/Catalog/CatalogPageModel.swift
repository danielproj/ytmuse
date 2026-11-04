import AccountSession
import Foundation
import Observation

/// One catalog page (Home, Explore, a chart, a mood, an album, an artist, a playlist, a podcast show): loading, cache,
/// refresh without reshuffling, and lazy pagination, every asynchronous reply fenced by generation and account scope.
///
/// Rules this type keeps:
/// - a page is cached per account scope for the session; cached data is labelled, and data older than `staleAfter` is
///   labelled stale until a refresh replaces it. A failed refresh keeps the older page and says so;
/// - refresh merges into what is on screen (`CatalogMerge`): the order of shelves and entries the person can see does not
///   change, and the shelf `anchor` the view reports as visible is never removed;
/// - a continuation token is used once per request; a second tap while one is in flight does nothing; a failure leaves
///   the token in place so the next request retries the same page;
/// - a reply for an older request, or for another account scope, cannot replace what is shown.
@MainActor @Observable public final class CatalogPageModel {
    public typealias Reader = @Sendable (CatalogTarget) async throws -> MusicBrowseReply<MusicBrowsePage>
    public typealias Continuer = @Sendable (String) async throws -> MusicBrowseReply<MusicContinuationPage>

    public enum Phase: Sendable, Equatable {
        case idle, loading, loaded, failed(CatalogFailure)
        var isFailed: Bool { if case .failed = self { return true }; return false }
    }
    public enum Origin: Sendable, Equatable { case live, cached }

    public let target: CatalogTarget
    public private(set) var phase: Phase = .idle
    public private(set) var heading: String?
    public private(set) var header: MusicPageHeader?
    public private(set) var chips: [MusicChip] = []
    public private(set) var shelves: [MusicShelf] = []
    public private(set) var pageContinuation: String?
    public private(set) var origin: Origin = .live
    public private(set) var fetchedAt: Date?
    public private(set) var isRefreshing = false
    /// The last refresh failed; the page shown is older than the person asked for.
    public private(set) var refreshFailure: CatalogFailure?
    public private(set) var loadingMore: Set<String> = []
    public private(set) var moreFailures: [String: CatalogFailure] = [:]
    public private(set) var signedIn = false
    public private(set) var sessionExpired = false
    /// Cumulative over every response applied to this page; a notice states what was left out.
    public var accounting: MusicParseAccounting { var total = firstPageAccounting; total.add(extraAccounting); return total }
    @ObservationIgnored private var firstPageAccounting = MusicParseAccounting()
    @ObservationIgnored private var extraAccounting = MusicParseAccounting()
    /// Why paging stopped before the service stopped offering tokens: the same token came back, or a page added nothing new.
    public enum PagingEnd: Sendable, Equatable { case repeatedToken, noNewEntries }
    public private(set) var pagingEnded: [String: PagingEnd] = [:]
    /// Bumped each time a refresh is merged into what is on screen, so the view can re-pin the shelf the listener is looking at.
    public private(set) var mergeRevision = 0
    public private(set) var duplicatesDropped = 0
    /// The key of the shelf at the top of the viewport, reported by the view. Refresh never removes it or moves it.
    public var anchor: String?
    public private(set) var feedback: [String: SearchItemFeedback] = [:]

    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let continuer: Continuer
    @ObservationIgnored private let cache: CatalogCache
    @ObservationIgnored private let accountScope: @MainActor () -> String
    @ObservationIgnored private let playbackState: @MainActor () -> SearchPlayback
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored public weak var performer: (any SearchActionPerformer)?
    /// W18: told AFTER a podcast show's own Play or Shuffle has started its playlist (never for a start that failed, went stale or was refused as busy,
    /// and never for another page action such as a radio), so the show's episodes get the show's speed, progress and resume exactly as an episode
    /// started from its own row. Nil where the shell offers no podcasts.
    @ObservationIgnored public var podcastStart: PodcastStartRegistration?
    @ObservationIgnored private let onItems: @MainActor ([MusicCatalogItem]) -> Void
    @ObservationIgnored private let onPage: @MainActor (MusicBrowsePage) -> Void
    @ObservationIgnored public let staleAfter: TimeInterval
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var extended: Set<String> = []
    @ObservationIgnored private var pageExtended = false

    public init(target: CatalogTarget, reader: @escaping Reader, continuer: @escaping Continuer, cache: CatalogCache = CatalogCache(),
                accountScope: @escaping @MainActor () -> String = { "" }, playback: @escaping @MainActor () -> SearchPlayback = { .needsSignIn },
                performer: (any SearchActionPerformer)? = nil, now: @escaping @MainActor () -> Date = { Date() }, staleAfter: TimeInterval = 600,
                onItems: @escaping @MainActor ([MusicCatalogItem]) -> Void = { _ in }, onPage: @escaping @MainActor (MusicBrowsePage) -> Void = { _ in }) {
        self.onPage = onPage
        self.target = target; self.reader = reader; self.continuer = continuer; self.cache = cache; self.accountScope = accountScope
        playbackState = playback; self.performer = performer; self.now = now; self.staleAfter = staleAfter; self.onItems = onItems
    }

    // MARK: Derived

    public var playback: SearchPlayback { playbackState() }
    /// The playlists the service published for this page's Play / Shuffle / Radio. A podcast show's page publishes none for
    /// the show itself, but its browse id (`MPSP` + the show's playlist id) names it; that is the one derivation made.
    public var pageActions: MusicPageActions? {
        guard var actions = header?.actions else { return nil }
        if actions.play == nil, target.browseID.hasPrefix("MPSPPL"), target.browseID.utf8.count <= 132 { actions.play = String(target.browseID.dropFirst(4)) }
        return actions
    }
    public var hasContent: Bool { header != nil || !shelves.isEmpty || heading != nil }
    public var isStale: Bool { fetchedAt.map { now().timeIntervalSince($0) > staleAfter } ?? false }
    /// Fully loaded: no page or shelf continuation is left to follow.
    public var isComplete: Bool { pageContinuation == nil && shelves.allSatisfy { $0.continuation == nil } }
    /// Entries or sections read but not shown (unreadable, a kind the app doesn't present, repeated). Always stated, never hidden.
    public var leftOut: Int { accounting.skipped + accounting.unsupported }
    public func shelf(_ key: String) -> MusicShelf? { shelves.first { $0.key == key } }
    public func offers(for item: MusicCatalogItem) -> [CatalogActionOffer] { CatalogActionPlan.offers(for: item, playback: playbackState()) }

    // MARK: Loading

    /// Cache first: a saved copy is shown at once (labelled), and a stale one is refreshed in the same call.
    public func load() async {
        guard phase == .idle || phase.isFailed else { return }
        let scope = accountScope()
        if let entry = cache.entry(scope: scope, key: target.key) {
            apply(entry.page, origin: .cached, fetchedAt: entry.fetchedAt, signedIn: entry.signedIn, merge: false)
            phase = .loaded
            if isStale { await refresh() }
            return
        }
        phase = .loading
        await fetch(preserving: false)
    }
    /// Pull to refresh, the toolbar, and the stale path: replaces data without disturbing what is visible.
    public func refresh() async {
        guard phase != .idle else { return }
        if !hasContent { phase = .loading; await fetch(preserving: false) } else { await fetch(preserving: true) }
    }
    /// The shell calls this when the active account (or whether its session is live) changes: nothing cached for the
    /// old scope is shown again, and what is on screen is re-asked for under the new one.
    public func accountChanged() {
        generation &+= 1
        feedback = [:]; loadingMore = []; moreFailures = [:]
        cache.removeAll()
        if hasContent {
            Task { await fetch(preserving: true) }
        } else { phase = .idle }
    }

    private func fetch(preserving: Bool, retried: Bool = false) async {
        generation &+= 1
        let ticket = generation
        let scope = accountScope()
        if preserving { isRefreshing = true } else { phase = .loading }
        defer { if ticket == generation { isRefreshing = false } }
        do {
            let reply = try await reader(target)
            guard ticket == generation, !Task.isCancelled else { return }
            guard accountScope() == scope else {
                if retried { fail(.scopeChanged, preserving: preserving) } else { await fetch(preserving: preserving, retried: true) }
                return
            }
            let page = reply.value
            let time = now()
            cache.store(CatalogCache.Entry(page: page, fetchedAt: time, signedIn: reply.mode == .signedIn), scope: scope, key: target.key)
            apply(page, origin: .live, fetchedAt: time, signedIn: reply.mode == .signedIn, merge: preserving)
            sessionExpired = reply.sessionExpired
            refreshFailure = nil
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard ticket == generation else { return }
            if (error as? MusicSessionError) == .stale || (error as? MusicSessionError) == .cancelled { return }
            fail(CatalogFailure(error), preserving: preserving)
        }
    }
    private func fail(_ failure: CatalogFailure, preserving: Bool) {
        if preserving && hasContent { refreshFailure = failure } else { phase = .failed(failure) }
    }

    private func apply(_ page: MusicBrowsePage, origin: Origin, fetchedAt: Date, signedIn: Bool, merge: Bool) {
        if merge && hasContent {
            shelves = CatalogMerge.refreshed(current: shelves, fresh: page.shelves, anchor: anchor, extended: extended)
            if !pageExtended { pageContinuation = page.continuation }
            // Header, heading and chips describe the page itself and may change in place; they are not a list to reorder.
            header = page.header ?? header; heading = page.heading ?? heading; chips = page.chips
            mergeRevision &+= 1
        } else {
            shelves = page.shelves; header = page.header; heading = page.heading; chips = page.chips; pageContinuation = page.continuation
            extended = []; pageExtended = false
            extraAccounting = MusicParseAccounting(); pagingEnded = [:]
            duplicatesDropped = 0
        }
        // What was left out reflects the first page now on screen (a refresh replaces it), plus what pagination has added since.
        firstPageAccounting = page.accounting
        self.origin = origin; self.fetchedAt = fetchedAt; self.signedIn = signedIn
        onItems(page.shelves.flatMap(\.items))
        // A live read shows what the service currently says about this page's own Save / Follow state.
        if origin == .live, signedIn { onPage(page) }
    }

    // MARK: Pagination

    /// The next entries of one shelf (a playlist's tracks, a show's episodes). Paging ends, with the reason recorded, when the
    /// service answers with the token just sent or with nothing this shelf did not already list.
    public func loadMore(shelf key: String) async {
        guard let shelf = shelf(key), let token = shelf.continuation, !loadingMore.contains(key) else { return }
        loadingMore.insert(key); moreFailures[key] = nil
        let ticket = generation, scope = accountScope()
        defer { loadingMore.remove(key) }
        do {
            let reply = try await continuer(token)
            guard ticket == generation, accountScope() == scope, let index = shelves.firstIndex(where: { $0.key == key }) else { return }
            let page = reply.value
            // A shelf's token normally answers with entries; a service that answers with sections instead has them appended.
            let appended = CatalogMerge.appended(page.items, to: shelves[index])
            var updated = appended.shelf
            let newSections = absorb(sections: page.shelves)
            let added = appended.shelf.items.count - shelves[index].items.count
            let end = Self.pagingEnd(sent: token, next: page.continuation, progressed: added > 0 || newSections > 0)
            updated.continuation = end == nil ? page.continuation : nil
            shelves[index] = updated
            if let end { pagingEnded[key] = end }
            duplicatesDropped += appended.duplicates
            var acc = page.accounting; acc.duplicates += appended.duplicates; acc.classified -= min(acc.classified, appended.duplicates)
            extraAccounting.add(acc)
            extended.insert(key)
            onItems(page.items)
        } catch is CancellationError {
        } catch {
            guard ticket == generation, (error as? MusicSessionError) != .stale else { return }
            moreFailures[key] = CatalogFailure(error)
        }
    }
    /// The next sections of the page (Home loads more shelves as the listener scrolls). A page whose token answers with
    /// entries rather than sections (a playlist's token) appends them to its last list shelf.
    public func loadMorePage() async {
        let key = "page"
        guard let token = pageContinuation, !loadingMore.contains(key) else { return }
        loadingMore.insert(key); moreFailures[key] = nil
        let ticket = generation, scope = accountScope()
        defer { loadingMore.remove(key) }
        do {
            let reply = try await continuer(token)
            guard ticket == generation, accountScope() == scope else { return }
            let page = reply.value
            pageExtended = true
            var acc = page.accounting
            var added = 0
            if !page.items.isEmpty, let index = shelves.lastIndex(where: { $0.layout == .list }) {
                let appended = CatalogMerge.appended(page.items, to: shelves[index])
                added = appended.shelf.items.count - shelves[index].items.count
                shelves[index] = appended.shelf
                duplicatesDropped += appended.duplicates
                acc.duplicates += appended.duplicates; acc.classified -= min(acc.classified, appended.duplicates)
                extended.insert(shelves[index].key)
            }
            let newSections = absorb(sections: page.shelves)
            let end = Self.pagingEnd(sent: token, next: page.continuation, progressed: added > 0 || newSections > 0)
            pageContinuation = end == nil ? page.continuation : nil
            if let end { pagingEnded[key] = end }
            extraAccounting.add(acc)
            onItems(page.items + page.shelves.flatMap(\.items))
        } catch is CancellationError {
        } catch {
            guard ticket == generation, (error as? MusicSessionError) != .stale else { return }
            moreFailures[key] = CatalogFailure(error)
        }
    }
    /// A continuation that returns the token it was asked with, or adds nothing, would be asked for again forever.
    static func pagingEnd(sent: String, next: String?, progressed: Bool) -> PagingEnd? {
        guard let next else { return nil }
        if next == sent { return .repeatedToken }
        return progressed ? nil : .noNewEntries
    }
    /// New sections are appended once; a section the page already shows is not duplicated.
    @discardableResult private func absorb(sections: [MusicShelf]) -> Int {
        var known = Set(shelves.map(\.key)), added = 0
        for section in sections where known.insert(section.key).inserted { shelves.append(section); added += 1 }
        return added
    }

    // MARK: Actions

    public func perform(_ action: CatalogAction, on item: MusicCatalogItem) async {
        guard let offer = offers(for: item).first(where: { $0.action == action }) else {
            feedback[item.id] = .failed(String(localized: "This action isn’t available for this item.")); return
        }
        if let reason = offer.unavailable { feedback[item.id] = .failed(reason); return }
        guard let performer else { feedback[item.id] = .failed(String(localized: "This action isn’t available right now.")); return }
        switch action {
        case .copyLink:
            guard let link = CatalogActionPlan.link(for: item) else { feedback[item.id] = .failed(String(localized: "This item has no link.")); return }
            performer.copy(link: link); feedback[item.id] = .copied
        case .play:
            guard let target = CatalogActionPlan.target(for: item) else { feedback[item.id] = .failed(String(localized: "This item didn’t include anything to play.")); return }
            await start(target: target, title: item.title, feedbackKey: item.id)
        case .radio:
            // The row's own published radio, nothing derived; an item without one never had the offer, so this is only a stale tap.
            guard let target = CatalogActionPlan.radioTarget(for: item) else { feedback[item.id] = .failed(String(localized: "This action isn’t available for this item.")); return }
            await start(target: target, title: item.title, feedbackKey: item.id)
        case .shuffle:
            feedback[item.id] = .failed(String(localized: "This action isn’t available for this item."))
        }
    }
    /// Play, Shuffle or Start Radio for the page itself, from the playlists the service published for it.
    public func perform(_ action: CatalogAction) async {
        guard let actions = pageActions else { return }
        let key = "page:" + action.rawValue
        if action == .copyLink { return }
        guard let offer = CatalogActionPlan.offers(for: actions, playback: playbackState()).first(where: { $0.action == action }),
              let target = CatalogActionPlan.target(for: action, in: actions) else { feedback[key] = .failed(String(localized: "This action isn’t available for this page.")); return }
        if let reason = offer.unavailable { feedback[key] = .failed(reason); return }
        guard performer != nil else { feedback[key] = .failed(String(localized: "This action isn’t available right now.")); return }
        // Only the show's own Play and Shuffle register its episodes; a radio (or any other page action) does not.
        await start(target: target, title: header?.title ?? heading ?? "", feedbackKey: key, registersShow: action == .play || action == .shuffle, shuffle: action == .shuffle)
    }
    private func start(target: CatalogActionPlan.PlayTarget, title: String, feedbackKey: String, registersShow: Bool = false, shuffle: Bool = false) async {
        guard let performer else { return }
        let scopeAtStart = accountScope()
        feedback[feedbackKey] = .working
        let outcome = (target.videoID == nil && target.params == nil && !shuffle)
            ? await performer.play(playlistID: target.playlistID, title: title)
            : await performer.play(playlistID: target.playlistID, title: title, videoID: target.videoID, params: target.params, intent: shuffle ? .shuffle : .endpoint)
        if registersShow, self.target.browseID.hasPrefix("MPSP"), outcome == .started, accountScope() == scopeAtStart { podcastStart?.began(self.target.browseID, target.playlistID) }
        guard accountScope() == scopeAtStart else { feedback[feedbackKey] = nil; return }
        switch outcome {
        case .started: feedback[feedbackKey] = .started
        // Another start (a shuffle still being set up, a Play a moment ago) is under way; this one was not sent. Said, never silent.
        case .busy: feedback[feedbackKey] = .failed(String(localized: "Another start is still in progress. Try again in a moment."))
        case .stale: feedback[feedbackKey] = .failed(String(localized: "Your account changed before this started. Try again."))
        case .failed: feedback[feedbackKey] = .failed(String(localized: "YouTube Music couldn’t start this. Try again."))
        }
    }
}

/// A session-only, per-account-scope cache of the pages read. Never written to disk.
@MainActor public final class CatalogCache {
    public struct Entry: Sendable { public let page: MusicBrowsePage; public let fetchedAt: Date; public let signedIn: Bool
        public init(page: MusicBrowsePage, fetchedAt: Date, signedIn: Bool) { self.page = page; self.fetchedAt = fetchedAt; self.signedIn = signedIn } }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let limit: Int
    public init(limit: Int = 48) { self.limit = max(1, limit) }
    public func entry(scope: String, key: String) -> Entry? { entries[scope + "|" + key] }
    public func store(_ entry: Entry, scope: String, key: String) {
        let id = scope + "|" + key
        order.removeAll { $0 == id }; order.append(id); entries[id] = entry
        while order.count > limit { entries[order.removeFirst()] = nil }
    }
    public func removeAll() { entries = [:]; order = [] }
    public var count: Int { entries.count }
}
