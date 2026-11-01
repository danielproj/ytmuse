import Foundation
import Testing
@testable import SystemIntegration

/// T25.3 (MAC05): indexing is opt-in; by default only public saved catalog items and app actions; private entities need a second, explicit opt-in; removing an
/// account, signing out, switching accounts and turning options off remove exactly what they should. Over an in-memory index: the system's is never called.
@Suite struct SpotlightIndexTests {
    static let a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    static func entry(_ kind: SpotlightKind, _ title: String, id: String, token: String = a) -> SpotlightEntry {
        SpotlightEntry(kind: kind, title: title, subtitle: "Synthetic Artist", accountToken: token, target: kind == .album || kind == .playlist ? IntentMediaTarget(playlistID: id) : IntentMediaTarget(videoID: id))!
    }
    static let actions = SpotlightAction.allCases.map { SpotlightEntry(action: $0) }
    static let actionTitles = Set(SpotlightAction.allCases.map(\.title))
    static var library: [SpotlightEntry] {
        actions + [entry(.song, "Saved Song", id: "v1"), entry(.album, "Saved Album", id: "OLAK5uy_1"), entry(.artist, "Followed Artist", id: "UC1"),
                   entry(.playlist, "Private Playlist Name", id: "PLprivate"), entry(.history, "Listened Song", id: "h1"), entry(.upload, "Uploaded Track", id: "u1")]
    }
    func titles(_ index: InMemorySearchableIndex) -> Set<String> { Set(index.entries.map(\.title)) }

    @Test func nothingIsIndexedByDefaultAndOnlyTheOwnRootIsEverCleared() async throws {
        let index = InMemorySearchableIndex(), indexer = SpotlightIndexer(backend: index)
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: .off)
        #expect(index.entries.isEmpty, "off by default")
        #expect(index.calls.allSatisfy { $0.kind == .deleteDomains && $0.domains == [SpotlightDomains.root] }, "the only call is clearing this app's own root domain: \(index.calls)")
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: .off)
        #expect(index.calls.count == 1, "once per process: off does not hammer the system index")
        #expect(SpotlightPolicy() == .off && SpotlightPolicy().enabled == false && SpotlightPolicy().includePrivate == false)
        #expect(!SpotlightPolicy(enabled: false, includePrivate: true).admits(Self.library[7]), "private without the first opt-in is still nothing")
    }
    @Test func enabledByItselfIndexesPublicSavedItemsAndActionsAndNeverPrivateOnes() async throws {
        let index = InMemorySearchableIndex(), indexer = SpotlightIndexer(backend: index)
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: SpotlightPolicy(enabled: true))
        #expect(titles(index) == Set(["Saved Song", "Saved Album", "Followed Artist"]).union(Self.actionTitles))
        for hidden in ["Private Playlist Name", "Listened Song", "Uploaded Track"] { #expect(!titles(index).contains(hidden), "\(hidden) is private") }
        #expect(index.entries.filter { $0.accountToken == nil }.count == SpotlightAction.allCases.count, "actions carry no account")
    }
    @Test func thePrivateOptInAddsPlaylistsHistoryAndUploadsInTheirOwnDomain() async throws {
        let index = InMemorySearchableIndex(), indexer = SpotlightIndexer(backend: index)
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: SpotlightPolicy(enabled: true, includePrivate: true))
        #expect(titles(index).isSuperset(of: ["Private Playlist Name", "Listened Song", "Uploaded Track"]))
        for entry in index.entries where entry.visibility == .privateEntity { #expect(index.domain(of: entry.uniqueID) == SpotlightDomains.privateEntities(account: Self.a)) }
        for entry in index.entries where entry.visibility == .catalog { #expect(index.domain(of: entry.uniqueID) == SpotlightDomains.catalog(account: Self.a)) }
    }
    @Test func turningThePrivateOptionOffRemovesThePrivateEntitiesAndKeepsThePublicOnes() async throws {
        let index = InMemorySearchableIndex(), indexer = SpotlightIndexer(backend: index)
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: SpotlightPolicy(enabled: true, includePrivate: true))
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: SpotlightPolicy(enabled: true, includePrivate: false))
        #expect(!titles(index).contains("Private Playlist Name") && !titles(index).contains("Listened Song") && !titles(index).contains("Uploaded Track"))
        #expect(titles(index).isSuperset(of: ["Saved Song", "Saved Album", "Followed Artist"]), "public items stay")
    }
    @Test func turningIndexingOffRemovesEverythingTheAppIndexed() async throws {
        let index = InMemorySearchableIndex(), indexer = SpotlightIndexer(backend: index)
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: SpotlightPolicy(enabled: true, includePrivate: true))
        #expect(!index.entries.isEmpty)
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: .off)
        let remaining = await indexer.indexedCount
        #expect(index.entries.isEmpty && remaining == 0)
    }
    @Test func removingAnAccountRemovesItsPublicAndPrivateEntitiesAndNotAnotherAccountsOrTheActions() async throws {
        let index = InMemorySearchableIndex(), indexer = SpotlightIndexer(backend: index)
        let policy = SpotlightPolicy(enabled: true, includePrivate: true)
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: policy)
        // A second account's entries, as they would be indexed while it was live.
        let second = [Self.entry(.song, "Second Accounts Song", id: "s2", token: Self.b), Self.entry(.playlist, "Second Accounts Playlist", id: "PLs2", token: Self.b)]
        try await indexer.removeAccount(token: Self.a)
        try await indexer.reconcile(desired: Self.actions + second, accountToken: Self.b, policy: policy)
        try await indexer.removeAccount(token: Self.a)   // idempotent
        #expect(titles(index) == Set(["Second Accounts Song", "Second Accounts Playlist"]).union(Self.actionTitles))
        try await indexer.removeAccount(token: Self.b)
        #expect(titles(index) == Self.actionTitles, "only the account-free actions remain")
        #expect(index.entries.allSatisfy { $0.accountToken == nil })
    }
    @Test func signingOutRemovesTheAccountsEntitiesAndSwitchingAccountsRemovesTheFirstOnes() async throws {
        let index = InMemorySearchableIndex(), indexer = SpotlightIndexer(backend: index)
        let policy = SpotlightPolicy(enabled: true, includePrivate: true)
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: policy)
        try await indexer.reconcile(desired: Self.actions, accountToken: nil, policy: policy)   // signed out: nobody's entities
        #expect(index.entries.allSatisfy { $0.accountToken == nil } && !index.entries.isEmpty, "the actions stay, nothing of the account does")
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: policy)
        let other = [Self.entry(.song, "Other Song", id: "o1", token: Self.b)]
        try await indexer.reconcile(desired: Self.actions + other, accountToken: Self.b, policy: policy)   // switched to account b
        #expect(!index.entries.contains { $0.accountToken == Self.a }, "the first account's entities are gone as soon as the second is live")
        #expect(titles(index).contains("Other Song"))
    }
    @Test func anEntryForAnotherAccountIsNeverIndexedUnderTheLiveOne() async throws {
        let index = InMemorySearchableIndex(), indexer = SpotlightIndexer(backend: index)
        try await indexer.reconcile(desired: Self.actions + [Self.entry(.song, "Foreign", id: "f", token: Self.b), Self.entry(.song, "Mine", id: "m")], accountToken: Self.a, policy: SpotlightPolicy(enabled: true))
        #expect(titles(index).contains("Mine") && !titles(index).contains("Foreign"))
    }
    @Test func theFirstReconcileOfALaunchReplacesWhatAnEarlierLaunchLeftAndLaterOnesApplyOnlyTheDifference() async throws {
        let index = InMemorySearchableIndex()
        let stale = Self.entry(.song, "Unsaved Since Last Launch", id: "gone")
        try await index.index([stale], domain: SpotlightDomains.catalog(account: Self.a))
        let indexer = SpotlightIndexer(backend: index)
        let policy = SpotlightPolicy(enabled: true)
        try await indexer.reconcile(desired: Self.actions + [Self.entry(.song, "Kept", id: "k")], accountToken: Self.a, policy: policy)
        #expect(!titles(index).contains("Unsaved Since Last Launch") && titles(index).contains("Kept"), "an item unsaved while the app was closed must not outlive it")
        let calls = index.calls.count
        try await indexer.reconcile(desired: Self.actions + [Self.entry(.song, "Kept", id: "k")], accountToken: Self.a, policy: policy)
        #expect(index.calls.count == calls, "nothing changed, nothing was sent")
        try await indexer.reconcile(desired: Self.actions + [Self.entry(.song, "Kept", id: "k"), Self.entry(.album, "New", id: "OLAK5uy_n")], accountToken: Self.a, policy: policy)
        #expect(index.calls.count == calls + 1 && index.calls.last == InMemorySearchableIndex.Call(kind: .index, domains: [SpotlightDomains.catalog(account: Self.a)], count: 1), "only the new item")
        try await indexer.reconcile(desired: Self.actions + [Self.entry(.album, "New", id: "OLAK5uy_n")], accountToken: Self.a, policy: policy)
        #expect(!titles(index).contains("Kept") && index.calls.last?.kind == .deleteIDs, "an item unsaved while running is deleted by id")
    }
    @Test func aDomainIsCappedSoALargeLibraryCannotFloodTheIndex() async throws {
        let index = InMemorySearchableIndex(), indexer = SpotlightIndexer(backend: index)
        let many = (0..<(SpotlightIndexer.perDomainLimit + 50)).map { Self.entry(.song, "Song \($0)", id: "v\($0)") }
        try await indexer.reconcile(desired: many, accountToken: Self.a, policy: SpotlightPolicy(enabled: true))
        #expect(index.entries.filter { $0.accountToken == Self.a }.count == SpotlightIndexer.perDomainLimit)
    }
    @Test func aFailingSystemIndexReportsTheErrorAndTheNextReconcileRetries() async throws {
        struct Down: Error {}
        let index = InMemorySearchableIndex(), indexer = SpotlightIndexer(backend: index)
        index.fail(with: Down())
        await #expect(throws: Down.self) { try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: SpotlightPolicy(enabled: true)) }
        let recorded = await indexer.indexedCount
        #expect(index.entries.isEmpty && recorded == 0, "nothing is recorded as indexed that was not")
        index.fail(with: nil)
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: SpotlightPolicy(enabled: true))
        #expect(titles(index).contains("Saved Song"))
    }
    /// A backend whose first catalog write takes a while, as the real index's asynchronous calls can.
    final class DelayedIndex: SearchableIndexBackend, Sendable {
        let inner = InMemorySearchableIndex(); let delay: Duration
        init(delay: Duration) { self.delay = delay }
        func index(_ entries: [SpotlightEntry], domain: String) async throws { if domain.hasSuffix(".catalog") { try await Task.sleep(for: delay) }; try await inner.index(entries, domain: domain) }
        func delete(uniqueIDs: [String]) async throws { try await inner.delete(uniqueIDs: uniqueIDs) }
        func delete(domains: [String]) async throws { try await inner.delete(domains: domains) }
    }
    @Test func anAccountRemovedWhileARefreshIsInFlightIsNotRestoredByIt() async throws {
        let slow = DelayedIndex(delay: .milliseconds(300)), indexer = SpotlightIndexer(backend: slow)
        let policy = SpotlightPolicy(enabled: true, includePrivate: true)
        let fence = await indexer.fence(for: Self.a)
        async let refresh: Void = indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: policy, fence: fence)
        try await Task.sleep(for: .milliseconds(100))
        try await indexer.removeAccount(token: Self.a)
        try await refresh
        let left = slow.inner.entries.filter { $0.accountToken == Self.a }.map(\.title)
        #expect(left.isEmpty, "the removed account's entries (Private Playlist Name, Saved Song) must stay gone: \(left)")
        // A refresh that was prepared before the removal and only now reaches the indexer is dropped whole.
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: policy, fence: fence)
        #expect(slow.inner.entries.filter { $0.accountToken == Self.a }.isEmpty, "a stale refresh writes nothing")
        // A refresh prepared AFTER the removal (a new fence) is legitimate: the account can sign in again.
        try await indexer.reconcile(desired: Self.library, accountToken: Self.a, policy: policy, fence: await indexer.fence(for: Self.a))
        #expect(slow.inner.entries.contains { $0.title == "Saved Song" })
    }
    @Test func hierarchicalDomainDeletionRemovesEverythingUnderItAndNothingBesides() async throws {
        let index = InMemorySearchableIndex()
        try await index.index([Self.entry(.song, "A", id: "1")], domain: SpotlightDomains.catalog(account: Self.a))
        try await index.index([Self.entry(.song, "B", id: "2", token: Self.b)], domain: SpotlightDomains.catalog(account: Self.b))
        try await index.index([SpotlightEntry(action: .search)], domain: SpotlightDomains.actions)
        try await index.delete(domains: [SpotlightDomains.account(Self.a)])
        #expect(titles(index) == ["B", SpotlightAction.search.title])
        try await index.delete(domains: [SpotlightDomains.root])
        #expect(index.entries.isEmpty)
    }

    // MARK: Identifiers

    @Test func anIdentifierRoundTripsAndOnlyOurOwnAreAccepted() throws {
        let entry = SpotlightEntry(kind: .song, title: "T", accountToken: Self.a, target: IntentMediaTarget(videoID: "v 1&=|x", playlistID: "PL/a", params: "p=q"))!
        guard case .item(let kind, let token, let target) = try #require(SpotlightEntry.parse(entry.uniqueID)) else { Issue.record("an item"); return }
        #expect(kind == .song && token == Self.a && target == IntentMediaTarget(videoID: "v 1&=|x", playlistID: "PL/a", params: "p=q"), "awkward characters survive the round trip")
        #expect(SpotlightEntry.parse(SpotlightEntry(action: .showQueue).uniqueID) == .action(.showQueue))
        for foreign in ["", "x", "com.apple.photos|123", "ytmuse.spot.v1|\(Self.a)|song|", "ytmuse.spot.v1|\(Self.a)|nonsense|v=1", "ytmuse.spot.v1||song|v=1", "ytmuse.spot.v1|action|launchMissiles",
                        "ytmuse.spot.v1|\(Self.a)|song|z=1", "ytmuse.spot.v1|\(Self.a)|action|v=1", String(repeating: "a", count: 5000)] {
            #expect(SpotlightEntry.parse(foreign) == nil, "\(foreign.prefix(40)) is not ours")
        }
        #expect(SpotlightEntry(kind: .song, title: "  ", accountToken: Self.a, target: IntentMediaTarget(videoID: "v")) == nil, "no title, no entry")
        #expect(SpotlightEntry(kind: .song, title: "T", accountToken: Self.a, target: IntentMediaTarget()) == nil, "nothing to open, no entry")
        #expect(SpotlightEntry(kind: .song, title: "T", accountToken: "", target: IntentMediaTarget(videoID: "v")) == nil, "no account, no entry")
        #expect(!entry.uniqueID.contains("T"), "the title is not in the identifier")
    }
}
