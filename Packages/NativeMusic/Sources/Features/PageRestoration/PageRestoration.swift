import SwiftUI

// W09-F2: per-navigation-entry restoration for the production pages.
//
// The browser session (AppShell) owns one entry per visit. A page cannot see it, so the shell hands each page a `PageRestoration`
// through the environment: a memory the page reads and writes (query, selection, named values) and a scroll driver that wraps the
// W09 `ScrollRestoration` policy. Both are bound to the entry, the window, its owner, the account-authority generation and the history
// epoch by a `token`; anything addressed to an older token is ignored, so a late write or a late scroll command can never reach a
// different entry, account or session generation. That holds for both ways a page returns to where it was: the offset path (below, in
// `NavigationPageStore`) and the identity path (`IdentityRestoration`), whose pending target lives in the page's own view state, is stamped
// with the entry's token, is checked against it before it acts, and is dropped when the page disappears.

/// What one navigation entry remembers of a page: the text the person typed, the rows they selected, and the page's named values
/// (kind, sort, layout, filter, scope). Values are plain strings so the session can be encoded and validated without knowing the page.
/// `query` and `selection` are nil for a page that has none: recording such a page must not overwrite what the entry holds for them.
public struct PageMemory: Equatable, Sendable {
    public var query: String?
    public var selection: Set<String>?
    public var values: [String: String]
    public init(query: String? = nil, selection: Set<String>? = nil, values: [String: String] = [:]) {
        self.query = query; self.selection = selection; self.values = values
    }
}

extension PageMemoryStore { public var isCurrent: Bool { true } }

/// The entry's memory of a page. `recall` is nil for a visit that has not recorded anything yet.
@MainActor public protocol PageMemoryStore: AnyObject {
    /// Identifies the entry this store addresses now (window, owner, authority generation, history epoch, entry).
    var token: AnyHashable { get }
    func recall() -> PageMemory?
    /// Whether the entry this store belongs to is the one on screen. A store is bound to the entry it was made for; a view that is leaving still
    /// holds it, and must neither write nor act once another entry is current.
    var isCurrent: Bool { get }
    /// Records `memory` only if `token` is still the current entry; otherwise it is dropped.
    func remember(_ memory: PageMemory, for token: AnyHashable)
}

/// One geometry reading of a scroll container, in points.
public struct PageScrollSample: Equatable, Sendable {
    /// `offset` counts from the container's resting position (the content origin less the top inset), as the stored offsets always have.
    public let offset: Double, maximum: Double, contentHeight: Double, topInset: Double
    public init(offset: Double, maximum: Double, contentHeight: Double, topInset: Double = 0) {
        self.offset = offset; self.maximum = maximum; self.contentHeight = contentHeight; self.topInset = topInset
    }
    public init(_ geometry: ScrollGeometry) {
        self.init(offset: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                  maximum: max(0, geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom - geometry.containerSize.height),
                  contentHeight: geometry.contentSize.height, topInset: geometry.contentInsets.top)
    }
    /// The `ScrollPosition` y that puts the container at `offset`: a position counts from the content origin, so a container with a top inset
    /// rests at `-topInset` and an offset measured from rest needs the inset taken off. Without this a restore to 0 left such a page
    /// `topInset` points too far down.
    public static func position(forOffset offset: Double, topInset: Double) -> Double { offset - topInset }
}
/// What the container should do with a reading.
public enum PageScrollCommand: Equatable, Sendable { case scroll(Double), hold, persist, stale }

/// The scroll side of an entry: it restores the stored offset (tolerating content that arrives late), then records what the person does.
/// A page can replace its scroll container (another kind, another layout); each container is a `container` id and only the one that armed
/// last is heard, so a container going away cannot silence its successor.
@MainActor public protocol PageScrollRestoring: AnyObject {
    var token: AnyHashable { get }
    /// Starts restoring for the current entry and returns the offset to scroll to now.
    func arm(container: UUID, now: Double) -> Double
    func sample(_ sample: PageScrollSample, token: AnyHashable, container: UUID, now: Double) -> PageScrollCommand
    /// The person took the scroll over: restoration stops and is never reissued.
    func userScrolled(container: UUID)
    /// The restoration window ended without success; records where the container is. Returns false if the token is no longer current.
    func expire(token: AnyHashable, container: UUID) -> Bool
    /// The container left the screen.
    func disappear(container: UUID)
    /// The page now shows other content in its container (another kind of list): the stored offset belongs to the old content.
    func rewind()
}

// The stores are main-actor objects handed only to main-actor views, so sharing the value is safe.
public struct PageRestoration: @unchecked Sendable {
    public let memory: any PageMemoryStore
    public let scroll: any PageScrollRestoring
    public init(memory: any PageMemoryStore, scroll: any PageScrollRestoring) { self.memory = memory; self.scroll = scroll }
}

private struct PageRestorationKey: EnvironmentKey { static let defaultValue: PageRestoration? = nil }
public extension EnvironmentValues {
    /// Set by the shell for the destination on screen; nil for a page shown anywhere else (a sheet, a palette, a preview).
    var pageRestoration: PageRestoration? {
        get { self[PageRestorationKey.self] }
        set { self[PageRestorationKey.self] = newValue }
    }
}

// MARK: Memory

/// The memory protocol of one visit, apart from any view so it can be tested: apply the entry's saved values BEFORE anything is written back,
/// record what the page shows on a visit with nothing saved, and write later changes only for the entry whose values were applied.
@MainActor public final class PageMemorySync {
    public private(set) var applied: AnyHashable?
    public init() {}
    public func begin(store: any PageMemoryStore, capture: () -> PageMemory, apply: (PageMemory) -> Void, fresh: (() -> Void)?) {
        let token = store.token
        if let saved = store.recall() { apply(saved) } else { fresh?(); store.remember(capture(), for: token) }
        applied = token
    }
    public func changed(_ memory: PageMemory, store: any PageMemoryStore) {
        // Only after this entry's saved values were applied: before that, the page still shows the previous entry's.
        guard let applied, applied == store.token else { return }
        store.remember(memory, for: applied)
    }
}

private struct PageMemoryModifier: ViewModifier {
    @Environment(\.pageRestoration) private var restoration
    @State private var sync = PageMemorySync()
    let identity: IdentityRestorer?
    let capture: @MainActor () -> PageMemory
    let apply: @MainActor (PageMemory) -> Void
    let fresh: (@MainActor () -> Void)?
    private static let key = "topItem", parentKey = "topParent"
    /// The page's values, plus the item it is on (when it restores by identity).
    private func captured() -> PageMemory {
        var memory = capture()
        if let identity {
            if let top = identity.top { memory.values[Self.key] = top }
            if let parent = identity.topParent { memory.values[Self.parentKey] = parent }
        }
        return memory
    }
    func body(content: Content) -> some View {
        let current = captured()
        content
            .task(id: restoration?.memory.token) {
                guard let store = restoration?.memory else { return }
                let token = store.token
                sync.begin(store: store, capture: { captured() },
                           apply: { saved in
                               apply(saved)
                               identity?.arm(top: saved.values[Self.key], parent: saved.values[Self.parentKey], token: token, now: ProcessInfo.processInfo.systemUptime)
                           },
                           fresh: { fresh?(); identity?.reset() })
            }
            .onChange(of: current) { _, memory in
                guard let store = restoration?.memory else { return }
                sync.changed(memory, store: store)
            }
    }
}

public extension View {
    /// Keeps `capture()` in the current navigation entry as it changes, and puts the entry's saved values back through `apply` when the
    /// entry is shown again. A visit with nothing saved records what the page shows. A page outside the shell does neither.
    /// `fresh` runs first on a visit with nothing saved (a page that opens on a particular kind, for instance).
    /// A page that restores by identity passes its `IdentityRestorer`: the item it is on is recorded with the visit and re-armed on return.
    func remembersPage(identity: IdentityRestorer? = nil, fresh: (@MainActor () -> Void)? = nil, capture: @escaping @MainActor () -> PageMemory, apply: @escaping @MainActor (PageMemory) -> Void) -> some View {
        modifier(PageMemoryModifier(identity: identity, capture: capture, apply: apply, fresh: fresh))
    }
}

// MARK: Scroll

private struct PageScrollModifier: ViewModifier {
    @Environment(\.pageRestoration) private var restoration
    // No initial position: a position at y 0 is a command (the content origin), which would move a container whose rest is inset above it.
    @State private var position = ScrollPosition()
    /// The entry this container was armed for; readings carry it so one addressed to another entry or generation is stale.
    @State private var armed: AnyHashable?
    @State private var container = UUID()
    /// The top inset last seen on this container (0 until a reading arrives); `ScrollPosition` commands are in content coordinates.
    @State private var topInset = 0.0
    let observe: (@MainActor (PageScrollSample) -> Void)?
    func body(content: Content) -> some View {
        if let driver = restoration?.scroll {
            content
                .scrollPosition($position)
                .onScrollGeometryChange(for: PageScrollSample.self) { PageScrollSample($0) } action: { _, sample in
                    observe?(sample)
                    topInset = sample.topInset
                    switch driver.sample(sample, token: armed ?? driver.token, container: container, now: ProcessInfo.processInfo.systemUptime) {
                    case .scroll(let target): position.scrollTo(y: PageScrollSample.position(forOffset: target, topInset: sample.topInset))
                    case .persist, .hold, .stale: break
                    }
                }
                .onScrollPhaseChange { _, phase in if phase == .interacting || phase == .tracking { driver.userScrolled(container: container) } }
                .task(id: driver.token) {
                    let token = driver.token
                    armed = token
                    let target = driver.arm(container: container, now: ProcessInfo.processInfo.systemUptime)
                    // Nothing to restore: the container is at rest already (a view is made per entry), and issuing a position would only pin it there.
                    if target > 0 { position.scrollTo(y: PageScrollSample.position(forOffset: target, topInset: topInset)) }
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    _ = driver.expire(token: token, container: container)
                }
                .onDisappear { driver.disappear(container: container) }
        } else {
            content
        }
    }
}

public extension View {
    /// Restores this scroll container's offset for the navigation entry on screen and records where the person leaves it.
    /// Apply it to the `ScrollView` or `List` itself; outside the shell (no restoration in the environment) it does nothing. `observe` sees
    /// every geometry reading (diagnostics). Lists and lazy pages restore by row or shelf identity instead (see `LibraryView`, `CatalogShelvesView`).
    func restoresScroll(observe: (@MainActor (PageScrollSample) -> Void)? = nil) -> some View {
        modifier(PageScrollModifier(observe: observe))
    }
}
