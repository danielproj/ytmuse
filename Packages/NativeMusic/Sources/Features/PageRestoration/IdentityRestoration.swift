import SwiftUI

// W09-F2 (rework 1): ONE identity-restore mechanism for every page that returns to a row, a download or a shelf instead of an offset
// (Library list, Downloads, catalog pages). Offsets are wrong for lazy content: heights are estimated until rows are realised, and sections
// above a position change height as data arrives.
//
// Three parts, none of them a copy:
//  - `IdentityRestoration`: the decision, a plain value like `ScrollRestoration` (headless-tested). One timing policy for every page.
//  - `IdentityRestorer`: per-VIEW state. It lives and dies with the page's view, so a pending target can never outlive its entry; it is
//    also stamped with the entry's token, and dropped if the token differs when it would act.
//  - `restoresByIdentity` / `identityItem`: the two modifiers the pages use.

/// When to scroll to a remembered item: once it exists, once, never twice.
/// - waits for the most specific target (a row); it scrolls `layoutDelay` after the target first exists, so the list has laid it out;
/// - a row inside a NESTED lazy stack exists only once its view is realised: `scrollTo` an id that is not realised does nothing (found by a
///   trace of the long development playlist: the call returned, no row appeared, nothing retried). So while the row is not realised the
///   decision steps toward it: `.approach(id)` names the realised item nearest before it, and scrolling there realises the next screenful,
///   until the row is realised and the final scroll can land;
/// - the WHOLE restoration is bounded by the window (2 s, the same bound `ScrollRestoration` uses), seen-then-vanished and stepping included; if it ends
///   before the target exists, it falls back to the next target (its shelf), which the page always knows;
/// - a cancel (the person scrolled, the page left) or a token that is not the one it was armed for ends it without a scroll.
public struct IdentityRestoration: Equatable {
    public enum Action: Equatable { case wait, scroll(String), approach(String), finished }
    public static let window = 2.0
    public static let layoutDelay = 0.06
    /// How long a step toward the target is given to realise the rows beyond it before the next step.
    public static let stepDelay = 0.06
    /// After a scroll, how long the page is given to show the target at the top before the scroll is repeated, and how many times it may be.
    /// (A scroll issued before the scroll view has its content laid out can be a no-op: the Downloads page, restored 77 ms after it appeared,
    /// stayed at the top. Only the scroll's effect proves it worked, so the effect is checked.)
    public static let verifyDelay = 0.15
    public static let maxAttempts = 4
    public let token: AnyHashable
    public let targets: [String]
    private let started: Double
    private var seenAt: Double?
    private var lastStep: (id: String, at: Double)?
    private var landing: (target: String, at: Double, attempts: Int)?
    public private(set) var finished = false
    public init(targets: [String], token: AnyHashable, now: Double) { self.targets = targets; self.token = token; started = now }
    public static func == (a: Self, b: Self) -> Bool {
        a.token == b.token && a.targets == b.targets && a.started == b.started && a.seenAt == b.seenAt && a.lastStep?.id == b.lastStep?.id && a.landing?.target == b.landing?.target && a.landing?.attempts == b.landing?.attempts && a.finished == b.finished
    }
    /// `exists`: the most specific target is realised and can be scrolled to. `known`: a fallback target the page knows (a shelf is a child of the
    /// page's own lazy stack, so it can be scrolled to whether or not it is realised). `approach`: the realised item nearest before a target.
    public mutating func offer(exists: (String) -> Bool, known: ((String) -> Bool)? = nil, approach: (String) -> String? = { _ in nil }, isOnTop: (String) -> Bool = { _ in true },
                               token current: AnyHashable, now: Double) -> Action {
        guard !finished else { return .finished }
        guard current == token else { finished = true; return .finished }
        // A scroll has been issued: it is finished when the target is where it was meant to be; if it is not after a moment, the scroll is repeated,
        // a few times and only inside the window.
        if let landed = landing {
            if isOnTop(landed.target) || landed.attempts >= Self.maxAttempts || now - started > Self.window { finished = true; return .finished }
            guard now - landed.at >= Self.verifyDelay else { return .wait }
            landing = (landed.target, now, landed.attempts + 1)
            return .scroll(landed.target)
        }
        // A target that was seen and then vanished (a refresh or a filter dropped it) is waited for again, within the same overall bound.
        let present = targets.first.map(exists) ?? false
        if !present { seenAt = nil } else if seenAt == nil { seenAt = now }
        if present, let since = seenAt, now - since >= Self.layoutDelay { landing = (targets[0], now, 1); return .scroll(targets[0]) }
        if now - started > Self.window {
            finished = true
            // It arrived within the window and was only waiting out the layout delay: scroll to it. Anything later is the person's page.
            if present, let since = seenAt, since - started <= Self.window { return .scroll(targets[0]) }
            for target in targets.dropFirst() where (known?(target) ?? exists(target)) { return .scroll(target) }
            return .finished
        }
        if !present, let target = targets.first, let step = approach(target), lastStep.map({ now - $0.at >= Self.stepDelay }) ?? true {
            // Never the same step twice in a row: it did not realise anything new.
            if lastStep?.id != step { lastStep = (step, now); return .approach(step) }
        }
        return .wait
    }
    public mutating func cancel() { finished = true }
}

/// How the page records where the person is.
public enum IdentityTopRule {
    /// The first item fully on screen (else the first partly on screen): lists of similar rows (Library, Downloads), where it loses less than a row.
    case firstFullyVisible
    /// The item that covers the top edge of the page (the first partly visible one in page order), and inside it, if it is a shelf of rows, the first row fully on
    /// screen: pages of shelves, where "first fully visible" would pick the NEXT shelf and move the page by up to a whole shelf.
    case coveringTop
}

/// The page's identity bookkeeping: which item is first on screen (recorded for the visit), and the pending restore (if any).
@MainActor @Observable public final class IdentityRestorer {
    /// The item the visit is on, and the item that contains it (a shelf for a row).
    public private(set) var top: String?
    public private(set) var topParent: String?
    /// Changes whenever a restore is armed or reset, so the driving task restarts.
    public private(set) var serial = 0
    @ObservationIgnored private let rule: IdentityTopRule
    /// A page whose rows live in a nested lazy stack counts a row as present only once its view is realised.
    @ObservationIgnored private let requiresRealisation: Bool
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var parents: [String: String] = [:]
    @ObservationIgnored private var present: Set<String> = []
    @ObservationIgnored private var realised: Set<String> = []
    @ObservationIgnored private var fully: Set<String> = []
    @ObservationIgnored private var partly: Set<String> = []
    @ObservationIgnored private var restoration: IdentityRestoration?
    public init(rule: IdentityTopRule = .firstFullyVisible, requiresRealisation: Bool = false) { self.rule = rule; self.requiresRealisation = requiresRealisation }

    public var isPending: Bool { restoration.map { !$0.finished } ?? false }
    /// The items now on the page, in display order, and the item each one belongs to (a row's shelf).
    public func setItems(_ ids: [String], parents: [String: String] = [:]) { order = ids; present = Set(ids); self.parents = parents }
    /// A row's view was created or removed by its lazy container.
    public func realisation(_ id: String, _ isRealised: Bool) { if isRealised { realised.insert(id) } else { realised.remove(id) } }
    public func visibility(_ id: String, visible: Bool, full: Bool) {
        if full { if visible { fully.insert(id) } else { fully.remove(id) } } else { if visible { partly.insert(id) } else { partly.remove(id) } }
        // While a restore is pending the page still shows its top; recording that would erase the item being returned to.
        guard !isPending else { return }
        record(candidateTop())
    }
    /// What the rule would record from what is on screen now.
    private func candidateTop() -> String? {
        switch rule {
        case .firstFullyVisible:
            return order.first { fully.contains($0) } ?? order.first { partly.contains($0) }
        case .coveringTop:
            guard let cover = order.first(where: { partly.contains($0) }) else { return nil }
            return order.first { parents[$0] == cover && fully.contains($0) } ?? cover
        }
    }
    private func record(_ id: String?) {
        if top != id { top = id }
        let parent = id.flatMap { parents[$0] }
        if topParent != parent { topParent = parent }
    }
    /// Arms a restore for the entry `token` names. `top` is the item the visit was left on, `parent` the item that contained it.
    public func arm(top saved: String?, parent: String?, token: AnyHashable, now: Double) {
        serial += 1
        guard let saved else { restoration = nil; record(nil); return }
        restoration = IdentityRestoration(targets: [saved] + (parent.map { [$0] } ?? []), token: token, now: now)
        top = saved; topParent = parent
    }
    /// A fresh visit: nothing pending, nothing recorded.
    public func reset() { serial += 1; restoration = nil; record(nil) }
    /// The person scrolled, or the page is leaving.
    public func cancel() { restoration?.cancel() }
    private func nearestRealisedBefore(_ target: String) -> String? {
        guard let index = order.firstIndex(of: target) else { return nil }
        return order[..<index].last { realised.contains($0) }
    }
    func poll(token: AnyHashable, now: Double) -> IdentityRestoration.Action {
        guard var current = restoration else { return .finished }
        let action = current.offer(exists: { self.requiresRealisation ? self.realised.contains($0) : self.present.contains($0) }, known: { self.present.contains($0) },
                                   approach: { self.requiresRealisation ? self.nearestRealisedBefore($0) : nil }, isOnTop: { self.candidateTop() == $0 }, token: token, now: now)
        restoration = current
        if case .scroll(let id) = action { top = id; topParent = parents[id] }
        return action
    }
    /// Runs the armed restore: polls until the target is there, steps toward it if it is not realised, then scrolls to it once through `scroll`.
    /// `token` is the entry now on screen, nil when there is none.
    public func drive(token: @MainActor () -> AnyHashable?, scroll: @MainActor (String) -> Void, now: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
                      pause: @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(30)) }) async {
        while !Task.isCancelled, isPending {
            guard let current = token() else { cancel(); return }
            switch poll(token: current, now: now()) {
            case .scroll(let id): scroll(id); await pause()
            case .approach(let id): scroll(id); await pause()
            case .finished: return
            case .wait: await pause()
            }
        }
    }
}

private struct IdentityTrackerKey: EnvironmentKey { static let defaultValue: IdentityRestorer? = nil }
extension EnvironmentValues {
    var identityTracker: IdentityRestorer? {
        get { self[IdentityTrackerKey.self] }
        set { self[IdentityTrackerKey.self] = newValue }
    }
}

private struct IdentityDriveModifier: ViewModifier {
    @Environment(\.pageRestoration) private var restoration
    let identity: IdentityRestorer
    let proxy: ScrollViewProxy
    func body(content: Content) -> some View {
        content
            .environment(\.identityTracker, identity)
            .task(id: identity.serial) {
                await identity.drive(token: { restoration.flatMap { $0.memory.isCurrent ? $0.memory.token : nil } }, scroll: { proxy.scrollTo($0, anchor: .top) })
            }
            .onScrollPhaseChange { _, phase in if phase == .interacting || phase == .tracking { identity.cancel() } }
            .onDisappear { identity.cancel() }
    }
}

private struct IdentityItemModifier: ViewModifier {
    @Environment(\.identityTracker) private var tracker
    let id: String
    func body(content: Content) -> some View {
        if let tracker {
            content.id(id)
                .onAppear { tracker.realisation(id, true) }
                .onDisappear { tracker.realisation(id, false) }
                .onScrollVisibilityChange(threshold: 0.99) { tracker.visibility(id, visible: $0, full: true) }
                .onScrollVisibilityChange(threshold: 0.01) { tracker.visibility(id, visible: $0, full: false) }
        } else {
            content.id(id)
        }
    }
}

public extension View {
    /// Apply to the `ScrollView` or `List` itself, inside a `ScrollViewReader`. Restores the item the visit was left on, once, when it exists;
    /// the first scroll by the person, or the page leaving, ends a pending restore.
    func restoresByIdentity(_ identity: IdentityRestorer, proxy: ScrollViewProxy) -> some View {
        modifier(IdentityDriveModifier(identity: identity, proxy: proxy))
    }
    /// Names an item of the page so a visit can be returned to it, and reports when it is on screen.
    func identityItem(_ id: String) -> some View { modifier(IdentityItemModifier(id: id)) }
}
