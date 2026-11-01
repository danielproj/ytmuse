import Foundation

/// A per-view authority: no shared highwater and no polling. View tasks fence expiry.
struct ScrollRestorationKey: Hashable {
    let window: UUID; let owner: WindowOwner?; let generation: UInt64; let epoch: UInt64?
    let entry: UUID; let query: String; let filter: String; let page: Int
    init(_ session: BrowserSession, generation: UInt64) { self.init(session, entry: session.current, generation: generation) }
    init(_ session: BrowserSession, entry bound: BrowserEntry, generation: UInt64) {
        window = session.windowID; owner = session.owner; self.generation = generation; epoch = session.historyEpoch
        entry = bound.id; query = bound.query; filter = bound.filter; page = bound.page
    }
    /// W09-F2: the identity of a production page's visit. Typing in its search field or changing its filter is the same visit, so neither
    /// restarts a restoration; the entry, window, owner, authority generation and history epoch still fence it.
    init(visitOf session: BrowserSession, generation: UInt64) { self.init(visitOf: session, entryID: session.current.id, generation: generation) }
    init(visitOf session: BrowserSession, entryID: UUID, generation: UInt64) {
        window = session.windowID; owner = session.owner; self.generation = generation; epoch = session.historyEpoch
        entry = entryID; query = ""; filter = ""; page = 0
    }
}
struct ScrollRestoration {
    enum Action: Equatable { case scroll(Double), hold, persist, stale }
    let key: ScrollRestorationKey
    private(set) var target: Double?
    private(set) var attempts = 0
    private let started: Double
    private var maximum: Double?, height: Double?
    init(key: ScrollRestorationKey, target: Double, now: Double) { self.key = key; self.target = target; started = now }
    mutating func cancel() { target = nil }
    mutating func sample(offset: Double, maximum: Double, height: Double, key current: ScrollRestorationKey, now: Double) -> Action {
        guard current == key else { target = nil; return .stale }
        guard let target else { return .persist }
        guard now - started <= 2, attempts < 8 else { self.target = nil; return .persist }
        guard offset.isFinite, maximum.isFinite, height.isFinite, height > 0 else { return .hold }
        // A temporary clamp is not successful restoration: keep the original target for growth.
        if maximum >= target, abs(offset - target) < 1 { self.target = nil; return .persist }
        let grew = self.maximum == nil || maximum > self.maximum! + 0.5 || height > (self.height ?? 0) + 0.5
        self.maximum = maximum; self.height = height
        guard grew else { return .hold }
        attempts += 1
        return .scroll(min(target, max(0, maximum)))
    }
    mutating func expire(key current: ScrollRestorationKey) -> Bool {
        guard key == current, target != nil else { return false }
        target = nil; return true
    }
}
