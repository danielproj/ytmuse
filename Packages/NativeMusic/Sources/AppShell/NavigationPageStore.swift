import Foundation
import Features

/// W09-F2: the browser session's side of per-entry page restoration. One store serves one destination view, and it is BOUND to the entry that
/// view was made for (W09-F2b, U4): it reads that entry by identity, and writes only while that entry is the one on screen. Earlier it followed
/// `session.current`, so a view that was leaving (still holding its store) re-ran its memory protocol against the entry that replaced it and wrote
/// its own values there — the new Search visit then "restored" a Downloads filter and opened empty.
/// It drives the existing `ScrollRestoration` policy (sampling, generation fencing, the 2 s / 8 attempt bound). There is no second mechanism: the
/// placeholder collection page and the production pages share it.
///
/// Fencing: the token names the entry, window, owner, authority generation and history epoch. A write or a scroll reading addressed to anything
/// else, or from a store whose entry is no longer current, is dropped, so an entry from another account or an older session generation can
/// neither be restored into the current one nor be changed by it.
@MainActor final class NavigationPageStore: PageMemoryStore, PageScrollRestoring {
    private let navigation: BrowserNavigation
    /// The entry this store belongs to. Fixed at creation, so the token of a leaving view does not change under it.
    let entryID: UUID
    var generation: UInt64
    /// The placeholder collection page restarts its restoration when its query, filter or page changes (the key then includes them);
    /// a production page's visit is one restoration however it is filtered.
    private let keyIncludesViewState: Bool
    private var policy: ScrollRestoration
    private var lastSample: PageScrollSample?
    private var active = true

    init(navigation: BrowserNavigation, generation: UInt64, keyIncludesViewState: Bool, entry: UUID? = nil) {
        self.navigation = navigation; self.generation = generation; self.keyIncludesViewState = keyIncludesViewState
        entryID = entry ?? navigation.session.current.id
        policy = ScrollRestoration(key: Self.makeKey(navigation.session, entryID, generation, keyIncludesViewState), target: navigation.session.entry(id: entryID)?.scrollOffset ?? 0, now: ProcessInfo.processInfo.systemUptime)
    }
    private static func makeKey(_ session: BrowserSession, _ entryID: UUID, _ generation: UInt64, _ includesViewState: Bool) -> ScrollRestorationKey {
        guard includesViewState, let entry = session.entry(id: entryID) else { return ScrollRestorationKey(visitOf: session, entryID: entryID, generation: generation) }
        return ScrollRestorationKey(session, entry: entry, generation: generation)
    }
    private var boundEntry: BrowserEntry? { navigation.session.entry(id: entryID) }
    var isCurrent: Bool { navigation.session.current.id == entryID }
    var scrollKey: ScrollRestorationKey { Self.makeKey(navigation.session, entryID, generation, keyIncludesViewState) }
    var token: AnyHashable { scrollKey }
    /// The offset the entry has stored (diagnostics and tests).
    var storedOffset: Double { boundEntry?.scrollOffset ?? 0 }

    // MARK: PageMemoryStore

    func recall() -> PageMemory? {
        guard let entry = boundEntry, let values = entry.pageValues else { return nil }
        return PageMemory(query: entry.query.isEmpty ? nil : entry.query, selection: entry.selection.isEmpty ? nil : entry.selection, values: values)
    }
    func remember(_ memory: PageMemory, for token: AnyHashable) {
        guard token == self.token, isCurrent, let entry = boundEntry else { return }
        let query = memory.query.map { String($0.prefix(1024)) }
        let selection = memory.selection.map { $0.count <= 50_000 ? $0 : Set($0.prefix(50_000)) }
        let values = memory.values.filter { $0.key.utf8.count <= 64 && $0.value.utf8.count <= 256 }.prefix(32).reduce(into: [String: String]()) { $0[$1.key] = $1.value }
        // Assign only what changed: every write is a session revision that window restoration persists.
        if let query, entry.query != query { navigation.session.update(entryID) { $0.query = query } }
        if let selection, entry.selection != selection { navigation.session.update(entryID) { $0.selection = selection } }
        if entry.pageValues != values { navigation.session.update(entryID) { $0.pageValues = values } }
    }

    // MARK: PageScrollRestoring

    private var owner: UUID?
    func arm(container: UUID, now: Double) -> Double {
        owner = container; active = true; lastSample = nil
        let target = boundEntry?.scrollOffset ?? 0
        policy = ScrollRestoration(key: scrollKey, target: target, now: now)
        // An entry stored at rest has nothing to restore. Left armed, a target of 0 would pull the container back to the top the first time
        // it is read anywhere else (a reading that arrives before the person's, or a test's, own scroll).
        if target <= 0 { policy.cancel() }
        return target
    }
    func sample(_ sample: PageScrollSample, token: AnyHashable, container: UUID, now: Double) -> PageScrollCommand {
        guard active, container == owner else { return .hold }
        lastSample = sample
        let current = scrollKey
        // A reading addressed to another entry or generation, or from a view whose entry is no longer on screen, is stale whatever the policy holds.
        guard token == AnyHashable(current), isCurrent else { policy.cancel(); return .stale }
        switch policy.sample(offset: sample.offset, maximum: sample.maximum, height: sample.contentHeight, key: current, now: now) {
        case .scroll(let target): return .scroll(target)
        case .persist:
            if boundEntry?.scrollOffset != sample.offset { navigation.session.update(entryID) { $0.scrollOffset = sample.offset } }
            return .persist
        case .hold: return .hold
        case .stale: return .stale
        }
    }
    func userScrolled(container: UUID) { if container == owner { policy.cancel() } }
    func expire(token: AnyHashable, container: UUID) -> Bool {
        guard container == owner, token == AnyHashable(scrollKey), isCurrent, active, policy.expire(key: scrollKey), let sample = lastSample else { return false }
        navigation.session.update(entryID) { $0.scrollOffset = sample.offset }
        return true
    }
    func disappear(container: UUID) { if container == owner { active = false; policy.cancel() } }
    func rewind() {
        policy.cancel()
        guard isCurrent, boundEntry?.scrollOffset != 0 else { return }
        navigation.session.update(entryID) { $0.scrollOffset = 0 }
    }
}
