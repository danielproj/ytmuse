import AccountSession
import Domain
import Features
import Foundation
import Observation
import SystemIntegration
import WidgetShared

// W25 (MAC05, T25.3). The lifecycle of the app's Spotlight entries: turn it on, keep it equal to the library, narrow it, and remove an account's entries when
// the account goes. The rules are `SpotlightPolicy` and `SpotlightIndexer` (SystemIntegration); this file feeds them from the models the windows already filled.
// It makes no request: library rows that are not loaded are simply not indexed yet.

/// The two choices the person makes. Both are off until they turn them on. Stored in the app's preferences store (a throwaway plist in an isolated run).
@MainActor @Observable final class SpotlightSettings {
    static let enabledKey = "spotlightIndexingEnabled"
    static let privateKey = "spotlightIndexPrivate"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var enabled: Bool
    private(set) var includePrivate: Bool
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    init(defaults: UserDefaults = AppPreferences.store) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey); includePrivate = defaults.bool(forKey: Self.privateKey)
    }
    var policy: SpotlightPolicy { SpotlightPolicy(enabled: enabled, includePrivate: enabled && includePrivate) }
    func setEnabled(_ value: Bool) { guard value != enabled else { return }; enabled = value; defaults.set(value, forKey: Self.enabledKey); onChange?() }
    func setIncludePrivate(_ value: Bool) { guard value != includePrivate else { return }; includePrivate = value; defaults.set(value, forKey: Self.privateKey); onChange?() }
}

/// What the controller reads. The production conformer is the bootstrap (the loaded library models and the local history).
@MainActor protocol SpotlightSource: AnyObject {
    func libraryRows(_ kind: MusicLibraryKind) -> [MusicCatalogItem]
    func localHistory() -> [LocalHistoryRecord]
}

@MainActor final class SpotlightController {
    let indexer: SpotlightIndexer
    private let settings: SpotlightSettings
    /// Weak: the bootstrap owns the controller, and a reconcile that outlives its source simply sees nothing.
    private weak var source: (any SpotlightSource)?
    private let liveScope: @MainActor () async -> IntentScope?
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var again = false
    private(set) var runs = 0
    /// The library collections whose saved rows are indexed, and the entry kind each becomes. Playlists are private entities.
    static let collections: [(MusicLibraryKind, SpotlightKind)] = [(.songs, .song), (.likedSongs, .song), (.albums, .album), (.artists, .artist), (.following, .artist), (.playlists, .playlist)]
    static let historyLimit = 200
    static var actionEntries: [SpotlightEntry] { SpotlightAction.allCases.map { SpotlightEntry(action: $0) } }

    init(indexer: SpotlightIndexer, settings: SpotlightSettings, source: any SpotlightSource, liveScope: @escaping @MainActor () async -> IntentScope?, debounce: Duration = .seconds(2)) {
        self.indexer = indexer; self.settings = settings; self.source = source; self.liveScope = liveScope; self.debounce = debounce
        settings.onChange = { [weak self] in self?.refresh() }
    }

    /// Begins following the library: a change to a loaded collection or to the history schedules a coalesced refresh. Idle until something changes.
    func start() { observe(); refresh() }
    private func observe() {
        withObservationTracking {
            for (kind, _) in Self.collections { _ = source?.libraryRows(kind).count }
            _ = source?.localHistory().count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(); self.observe()
            }
        }
    }

    /// Coalesced: a burst of changes is one reconcile after `debounce`.
    func refresh() {
        if task != nil { again = true; return }
        task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.again = false
                try? await Task.sleep(for: self.debounce)
                guard !Task.isCancelled else { break }
                await self.reconcileNow()
            } while self.again
            self.task = nil
        }
    }
    func settle() async { while let task { await task.value } }

    func reconcileNow() async {
        runs += 1
        let policy = settings.policy
        guard policy.enabled else { try? await indexer.reconcile(desired: [], accountToken: nil, policy: policy); return }
        // Signed out: no account's entity stays; the app's actions need no account and stay.
        guard let live = await liveScope() else { try? await indexer.reconcile(desired: Self.actionEntries, accountToken: nil, policy: policy); return }
        let token = WidgetScope.token(for: live.accountID)
        // Fenced by account and session: the fence is taken before anything is read, and if the account was removed or switched, or the session changed, while the
        // entries were being built, nothing is sent.
        let fence = await indexer.fence(for: token)
        let desired = desiredEntries(token: token, scope: live, policy: policy)
        guard await liveScope() == live else { return }
        try? await indexer.reconcile(desired: desired, accountToken: token, policy: policy, fence: fence)
    }

    /// The entries the policy admits for this account, built from loaded rows only.
    func desiredEntries(token: String, scope: IntentScope, policy: SpotlightPolicy) -> [SpotlightEntry] {
        var entries = Self.actionEntries
        for (library, kind) in Self.collections {
            let candidate = Self.visibility(of: kind)
            guard candidate == .catalog || policy.includePrivate else { continue }
            for item in source?.libraryRows(library) ?? [] { if let entry = Self.entry(from: item, kind: kind, token: token, scope: scope) { entries.append(entry) } }
        }
        if policy.includePrivate {
            for record in (source?.localHistory() ?? []).prefix(Self.historyLimit) {
                if let entry = SpotlightEntry(kind: .history, title: record.title, subtitle: record.artist, accountToken: token, target: IntentMediaTarget(videoID: record.videoID)) { entries.append(entry) }
            }
        }
        return entries.filter(policy.admits)
    }
    static func visibility(of kind: SpotlightKind) -> SpotlightVisibility {
        switch kind { case .song, .album, .artist: .catalog; case .playlist, .history: .privateEntity; case .action: .action }
    }
    static func entry(from item: MusicCatalogItem, kind: SpotlightKind, token: String, scope: IntentScope) -> SpotlightEntry? {
        switch kind {
        case .song, .album, .artist, .playlist:
            let mediaKind: IntentMediaKind = switch kind { case .song: .song; case .album: .album; case .artist: .artist; default: .playlist }
            guard let media = AppIntentChannel.media(from: item, kind: mediaKind, scope: scope) else { return nil }
            return SpotlightEntry(kind: kind, title: media.title, subtitle: media.subtitle, accountToken: token, target: media.target)
        case .history, .action: return nil
        }
    }

    /// W27 (privacy reset): everything this app put in Spotlight leaves the index now, every account's, and nothing is indexed again until a refresh runs.
    func eraseAll() async throws {
        task?.cancel(); task = nil; again = false
        try await indexer.removeAll()
    }
    /// An account barrier or removal: everything of that account leaves the index now, public and private. Indexing resumes (and rebuilds the account's entries
    /// from its library) the next time that account is live.
    func accountEnded(_ account: UUID) async {
        task?.cancel(); task = nil; again = false
        try? await indexer.removeAccount(token: WidgetScope.token(for: account))
    }
}

/// What a Spotlight result means when the person opens it. Only the app's own identifiers, only for the live account.
@MainActor enum SpotlightActivation {
    /// The system's names for a Spotlight result's activity (`CSSearchableItemActionType` and `CSSearchableItemActivityIdentifier`). Written out so no package source
    /// needs to import CoreSpotlight, which the guard keeps out of everything but the app target.
    static let activityType = "com.apple.corespotlightitem"
    static let identifierKey = "kCSSearchableItemActivityIdentifier"

    static func command(for uniqueID: String, live: IntentScope?) -> Result<IntentCommand, IntentRefusal> {
        switch SpotlightEntry.parse(uniqueID) {
        case nil: return .failure(.notFound)
        case .action(let action):
            switch action {
            case .playPause: return .success(.toggle); case .next: return .success(.next); case .previous: return .success(.previous)
            case .search: return .success(.showPlayer)   // opens the window; the person types in its search field
            case .showQueue: return .success(.showQueue)
            }
        case .item(let kind, let token, let target):
            guard let live else { return .failure(.signedOut) }
            guard token == WidgetScope.token(for: live.accountID) else { return .failure(.staleIdentity) }
            let mediaKind: IntentMediaKind
            switch kind { case .song, .history: mediaKind = .song; case .album: mediaKind = .album; case .artist: mediaKind = .artist; case .playlist: mediaKind = .playlist
            case .action: return .success(.showPlayer) }
            return .success(.play(IntentMedia(scope: live, kind: mediaKind, title: String(localized: "YouTube Music"), target: target)))
        }
    }
}
