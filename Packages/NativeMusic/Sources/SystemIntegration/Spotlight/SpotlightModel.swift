import Foundation
import Synchronization

// W25 (MAC05, T25.3). Privacy-aware Spotlight indexing, as pure rules over values.
//
// This module never imports CoreSpotlight and never names the system index: the ONLY conformer of `SearchableIndexBackend` that reaches the real index lives
// in the app target (`App/Sources/SystemSearchableIndex.swift`), where no test can reach it. Every test, every isolated launch and every probe gets
// `InMemorySearchableIndex`. `SpotlightGuardTests` sweeps every package, test and UI-test source for the system index and keeps it that way.

public enum SpotlightKind: String, Sendable, CaseIterable {
    case song, album, artist
    /// A library playlist. The library page does not say whether a playlist is private, so every library playlist is treated as private.
    case playlist
    /// Something from this Mac's listening history.
    case history
    /// A track the person uploaded.
    case upload
    /// An app action (play/pause, next, previous, search, queue). Carries no account data.
    case action
}

/// Where an entry may be shown. `catalog`: a saved public catalog item. `privateEntity`: a private playlist, history or upload. `action`: an app action.
public enum SpotlightVisibility: Sendable, Equatable { case catalog, privateEntity, action }

public enum SpotlightAction: String, Sendable, CaseIterable {
    case playPause, next, previous, search, showQueue
    public var title: String {
        switch self {
        case .playPause: String(localized: "Play or Pause in YTMuse")
        case .next: String(localized: "Next Song in YTMuse")
        case .previous: String(localized: "Previous Song in YTMuse")
        case .search: String(localized: "Search YTMuse")
        case .showQueue: String(localized: "Show Queue in YTMuse")
        }
    }
}

public struct SpotlightEntry: Sendable, Equatable, Hashable {
    public let uniqueID: String
    public let kind: SpotlightKind
    public let title: String
    public let subtitle: String?
    /// The account the entry belongs to (the widget-style one-way token); nil for an action.
    public let accountToken: String?
    public let target: IntentMediaTarget?
    public let action: SpotlightAction?

    public var visibility: SpotlightVisibility {
        switch kind {
        case .song, .album, .artist: .catalog
        case .playlist, .history, .upload: .privateEntity
        case .action: .action
        }
    }
    public var domain: String {
        switch visibility {
        case .action: SpotlightDomains.actions
        case .catalog: SpotlightDomains.catalog(account: accountToken ?? "")
        case .privateEntity: SpotlightDomains.privateEntities(account: accountToken ?? "")
        }
    }

    public static let titleLimit = 160
    private static let prefix = "ytmuse.spot.v1"

    /// A catalog or private entry for the account `accountToken`. Nil when the entry has nothing to open (no id at all) or no title.
    public init?(kind: SpotlightKind, title: String, subtitle: String? = nil, accountToken: String, target: IntentMediaTarget) {
        guard kind != .action, !title.trimmingCharacters(in: .whitespaces).isEmpty, !accountToken.isEmpty,
              target.videoID != nil || target.playlistID != nil || target.browseID != nil else { return nil }
        self.kind = kind; self.title = String(title.prefix(Self.titleLimit)); self.subtitle = subtitle.map { String($0.prefix(Self.titleLimit)) }
        self.accountToken = accountToken; self.target = target; self.action = nil
        func part(_ tag: String, _ value: String?) -> String { value.map { tag + "=" + (Self.escape($0)) } ?? "" }
        let key = [part("v", target.videoID), part("p", target.playlistID), part("b", target.browseID), part("q", target.params)].filter { !$0.isEmpty }.joined(separator: "&")
        self.uniqueID = [Self.prefix, accountToken, kind.rawValue, key].joined(separator: "|")
    }
    public init(action: SpotlightAction) {
        self.kind = .action; self.title = action.title; self.subtitle = nil; self.accountToken = nil; self.target = nil; self.action = action
        self.uniqueID = [Self.prefix, "action", action.rawValue].joined(separator: "|")
    }

    /// What a Spotlight result's identifier means, or nil for anything this layer did not write.
    public enum Parsed: Equatable, Sendable {
        case action(SpotlightAction)
        case item(kind: SpotlightKind, accountToken: String, target: IntentMediaTarget)
    }
    public static func parse(_ uniqueID: String) -> Parsed? {
        guard uniqueID.utf8.count <= 2048 else { return nil }
        let parts = uniqueID.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0] == prefix, parts[1] == "action", let action = SpotlightAction(rawValue: parts[2]) { return .action(action) }
        guard parts.count == 4, parts[0] == prefix, !parts[1].isEmpty, let kind = SpotlightKind(rawValue: parts[2]), kind != .action else { return nil }
        var target = IntentMediaTarget()
        for field in parts[3].split(separator: "&") {
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, let value = unescape(pair[1]) else { return nil }
            switch pair[0] { case "v": target.videoID = value; case "p": target.playlistID = value; case "b": target.browseID = value; case "q": target.params = value; default: return nil }
        }
        guard target.videoID != nil || target.playlistID != nil || target.browseID != nil else { return nil }
        return .item(kind: kind, accountToken: parts[1], target: target)
    }
    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
    private static func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
    private static func unescape(_ text: String) -> String? { text.removingPercentEncoding }
}

public enum SpotlightDomains {
    /// Domains are hierarchical: deleting a domain deletes everything under it. `root` is the whole of this app's index.
    public static let root = "local.native-music.development.spotlight"
    public static let actions = root + ".actions"
    public static func account(_ token: String) -> String { root + ".account." + token }
    public static func catalog(account token: String) -> String { account(token) + ".catalog" }
    public static func privateEntities(account token: String) -> String { account(token) + ".private" }
}

/// The opt-in. Indexing is off until the person turns it on, and private entities are off until they turn those on too.
public struct SpotlightPolicy: Equatable, Sendable {
    public var enabled: Bool
    public var includePrivate: Bool
    public init(enabled: Bool = false, includePrivate: Bool = false) { self.enabled = enabled; self.includePrivate = includePrivate }
    public static let off = SpotlightPolicy()
    public func admits(_ entry: SpotlightEntry) -> Bool {
        guard enabled else { return false }
        switch entry.visibility {
        case .catalog, .action: return true
        case .privateEntity: return includePrivate
        }
    }
}

/// The system index, abstractly. Production: the app target's CoreSpotlight conformer. Everything else: `InMemorySearchableIndex`.
public protocol SearchableIndexBackend: Sendable {
    func index(_ entries: [SpotlightEntry], domain: String) async throws
    func delete(uniqueIDs: [String]) async throws
    /// Deletes the domain and everything under it.
    func delete(domains: [String]) async throws
}

/// A fake index that keeps what it was given and counts its calls. The default for tests, probes and isolated launches.
public final class InMemorySearchableIndex: SearchableIndexBackend, Sendable {
    public struct Call: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case index, deleteIDs, deleteDomains }
        public let kind: Kind; public let domains: [String]; public let count: Int
    }
    private struct State { var items: [String: (entry: SpotlightEntry, domain: String)] = [:]; var calls: [Call] = []; var failure: (any Error)? }
    private let state = Mutex(State())
    public init() {}
    public var entries: [SpotlightEntry] { state.withLock { $0.items.values.map(\.entry).sorted { $0.uniqueID < $1.uniqueID } } }
    public var calls: [Call] { state.withLock { $0.calls } }
    public func domain(of uniqueID: String) -> String? { state.withLock { $0.items[uniqueID]?.domain } }
    /// Makes the next calls throw (a failing system index).
    public func fail(with error: (any Error)?) { state.withLock { $0.failure = error } }
    public func index(_ entries: [SpotlightEntry], domain: String) async throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            for entry in entries { state.items[entry.uniqueID] = (entry, domain) }
            state.calls.append(Call(kind: .index, domains: [domain], count: entries.count))
        }
    }
    public func delete(uniqueIDs: [String]) async throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            for id in uniqueIDs { state.items[id] = nil }
            state.calls.append(Call(kind: .deleteIDs, domains: [], count: uniqueIDs.count))
        }
    }
    public func delete(domains: [String]) async throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            state.items = state.items.filter { _, value in !domains.contains { value.domain == $0 || value.domain.hasPrefix($0 + ".") } }
            state.calls.append(Call(kind: .deleteDomains, domains: domains, count: domains.count))
        }
    }
}

/// Keeps the index equal to what the policy admits, and removes an account's entities when the account goes.
public actor SpotlightIndexer {
    public static let perDomainLimit = 2000
    private let backend: any SearchableIndexBackend
    private var ledger: [String: SpotlightEntry] = [:]
    /// Domains already replaced wholesale in this process. A domain's first reconcile in a launch deletes what an earlier launch left (an item unsaved
    /// meanwhile must not outlive it) and indexes the current set; later reconciles apply only the difference.
    private var replaced: Set<String> = []
    /// The root was deleted in this process and nothing has been indexed since, so another "off" reconcile has nothing to delete.
    private var rootCleared = false
    /// Bumped when an account's entries are removed. A reconcile that started before the removal (it holds the older value) must not put anything back: the check
    /// is made at its start and after every wait on the backend, and what it already wrote after a removal is deleted again.
    private var removalEpoch: [String: UInt64] = [:]
    public init(backend: any SearchableIndexBackend) { self.backend = backend }

    public var indexedCount: Int { ledger.count }
    public func indexedIDs() -> Set<String> { Set(ledger.keys) }

    /// Makes the index match `desired` for `accountToken` under `policy`. Nothing is indexed unless the policy is enabled; private entities only when
    /// the policy includes them; with no account (signed out) every account's entities are removed and only the actions remain.
    /// What a refresh for `token` must hold up to the end: it takes this BEFORE it reads anything, and passes it back to `reconcile`.
    public func fence(for token: String) -> UInt64 { removalEpoch[token, default: 0] }

    public func reconcile(desired: [SpotlightEntry], accountToken: String?, policy: SpotlightPolicy, fence: UInt64? = nil) async throws {
        guard policy.enabled else { if !rootCleared { try await removeAll() }; return }
        if let accountToken, let fence, removalEpoch[accountToken, default: 0] != fence { return }   // the account was removed or switched away while this refresh was being prepared
        // Another account's entities never survive this account being the live one.
        let stale = Set(ledger.values.compactMap(\.accountToken)).filter { $0 != accountToken }
        for token in stale { try await removeAccount(token: token) }
        var targets: [String: [SpotlightEntry]] = [SpotlightDomains.actions: []]
        if let accountToken { targets[SpotlightDomains.catalog(account: accountToken)] = []; targets[SpotlightDomains.privateEntities(account: accountToken)] = [] }
        for entry in desired where policy.admits(entry) && (entry.accountToken == nil || entry.accountToken == accountToken) {
            guard targets[entry.domain] != nil, (targets[entry.domain]?.count ?? 0) < Self.perDomainLimit else { continue }
            targets[entry.domain]?.append(entry)
        }
        for (domain, wanted) in targets.sorted(by: { $0.key < $1.key }) {
            try await apply(wanted, to: domain, token: wanted.first?.accountToken ?? accountToken, fence: fence)
            // A removal that ran while the backend call above was waiting has already deleted the account's domain; what this call wrote after it is deleted again.
            if let accountToken, let fence, removalEpoch[accountToken, default: 0] != fence {
                try await backend.delete(domains: [SpotlightDomains.account(accountToken)])
                for (id, entry) in ledger where entry.accountToken == accountToken { ledger[id] = nil }
                replaced.remove(SpotlightDomains.catalog(account: accountToken)); replaced.remove(SpotlightDomains.privateEntities(account: accountToken))
                return
            }
        }
    }

    private func apply(_ wanted: [SpotlightEntry], to domain: String, token: String?, fence: UInt64?) async throws {
        let current = ledger.filter { $0.value.domain == domain }
        rootCleared = false
        if !replaced.contains(domain) {
            try await backend.delete(domains: [domain])
            for id in current.keys { ledger[id] = nil }
            if !wanted.isEmpty { try await backend.index(wanted, domain: domain) }
            for entry in wanted { ledger[entry.uniqueID] = entry }
            replaced.insert(domain)
            return
        }
        let wantedByID = Dictionary(wanted.map { ($0.uniqueID, $0) }, uniquingKeysWith: { first, _ in first })
        let gone = current.keys.filter { wantedByID[$0] == nil }
        let changed = wanted.filter { current[$0.uniqueID] != $0 }
        if !gone.isEmpty { try await backend.delete(uniqueIDs: Array(gone)); for id in gone { ledger[id] = nil } }
        if !changed.isEmpty { try await backend.index(changed, domain: domain); for entry in changed { ledger[entry.uniqueID] = entry } }
    }

    /// Everything of one account (catalog and private), at account removal, sign-out and account switch.
    public func removeAccount(token: String) async throws {
        removalEpoch[token, default: 0] += 1
        try await backend.delete(domains: [SpotlightDomains.account(token)])
        for (id, entry) in ledger where entry.accountToken == token { ledger[id] = nil }
        replaced.remove(SpotlightDomains.catalog(account: token)); replaced.remove(SpotlightDomains.privateEntities(account: token))
    }
    /// Only the private entities of an account (the person turned the private option off).
    public func removePrivate(token: String) async throws {
        try await backend.delete(domains: [SpotlightDomains.privateEntities(account: token)])
        for (id, entry) in ledger where entry.accountToken == token && entry.visibility == .privateEntity { ledger[id] = nil }
        replaced.insert(SpotlightDomains.privateEntities(account: token))
    }
    /// Everything this app has in the index (indexing turned off, or the whole app's data removed).
    public func removeAll() async throws {
        try await backend.delete(domains: [SpotlightDomains.root])
        ledger.removeAll(); replaced.removeAll(); rootCleared = true
    }
}
