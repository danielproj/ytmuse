import Foundation
import SystemIntegration
import WidgetShared

// W25 (MAC06, T25.1/T25.2/T25.4). Writes the widget's snapshot from what the app already publishes to Now Playing, and nothing else.
//
// It never polls: it runs only when `NowPlayingCenter.onChange` or a scope change tells it something changed, coalesces a burst into one write, writes
// only when the VISIBLE content differs from the last write, and asks for a timeline reload at most once per interval. It reads no store and makes no
// request; the account is the live scope from the playback authority. At an account barrier it acts on the account that is LEAVING (the authority hands it over
// before it clears its own scope): quit deletes the file and reloads at once; sign-out and switch replace it with the contentless signed-out snapshot; removal does
// the same when the file belongs to the removed account.

// W29 (ARCH02, T29.5). The publisher is main-actor state, and its work is not: decoding the artwork into a thumbnail and writing, reading and deleting the snapshot file are
// blocking disk and image work, so they run on one serial queue, never on the main actor. A serial queue (not an actor) keeps the order the main actor issued the operations
// in: a barrier's delete is queued after the write that was already waiting, so the last word on disk is always the newest decision. After every wait the publisher checks that
// no barrier ran in the meantime before it records anything.
protocol WidgetSnapshotIO: Sendable {
    func write(_ snapshot: WidgetSnapshot) throws
    func read() -> WidgetReadResult
    func delete() throws
    func thumbnail(from data: Data) -> Data?
}
struct DiskWidgetSnapshotIO: WidgetSnapshotIO {
    let store: WidgetSnapshotStore
    func write(_ snapshot: WidgetSnapshot) throws { try store.write(snapshot) }
    func read() -> WidgetReadResult { store.read() }
    func delete() throws { try store.delete() }
    func thumbnail(from data: Data) -> Data? { WidgetArtwork.thumbnail(from: data) }
}
final class WidgetSnapshotQueue: Sendable {
    private let queue = DispatchQueue(label: "local.native-music.widget-snapshot-io", qos: .utility)
    /// Runs `work` after everything already queued, off the calling thread, and returns its result.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work()) } }
    }
    /// The privacy reset's deletion: it must follow every write already queued, and it is explicit, rare and one small unlink, so it waits for the queue.
    func runBlocking<T>(_ work: () -> T) -> T { queue.sync(execute: work) }
}

@MainActor final class WidgetSnapshotPublisher {
    private let store: WidgetSnapshotStore
    private let io: any WidgetSnapshotIO
    private let queue = WidgetSnapshotQueue()
    /// Counts barriers (and resets): a continuation that resumes after the count moved records nothing, because a barrier decided in the meantime.
    private var epoch: UInt64 = 0
    /// W27: where the snapshot lives (the destructive-action guard reads it).
    var directory: URL { store.directory }
    private let reloader: any WidgetTimelineReloading
    private let liveScope: @MainActor () async -> IntentScope?
    private weak var nowPlaying: NowPlayingCenter?
    private let reloadInterval: Duration
    private var serial: UInt64 = 0
    private var dirty = false
    private var flushing: Task<Void, Never>?
    private var lastWritten: WidgetSnapshot?
    private var lastReload: ContinuousClock.Instant?
    private var pendingReload: Task<Void, Never>?
    private var lastItem: (scope: WidgetScope, title: String, artist: String?, artwork: Data?)?
    private var thumbnails: (key: Int, thumbnail: Data?)?
    /// The scope that ended at the last barrier. A flush that read the live scope just before the barrier and writes just after it must not bring that session back.
    private var ended: WidgetScope?
    /// This launch's random nonce, written into every stamp (an earlier launch's buttons are refused).
    private let launch: String
    /// An account has ended or none was found at launch: the widget then shows the signed-out sentence instead of "Open YTMuse".
    private var signedOutKnown = false
    /// Quit is final: once the quit barrier has deleted the file nothing may write again (the player's teardown, which follows, changes Now Playing and would otherwise write
    /// the signed-out snapshot back).
    private(set) var terminated = false
    /// False while the Mac's user session is not the active one (fast user switching): the snapshot is then the locked, contentless one.
    private(set) var sessionActive = true
    /// Counts for the tests and the report: files written, timeline reloads requested.
    private(set) var writes = 0
    private(set) var reloads = 0

    init(store: WidgetSnapshotStore, io: (any WidgetSnapshotIO)? = nil, reloader: any WidgetTimelineReloading, nowPlaying: NowPlayingCenter, liveScope: @escaping @MainActor () async -> IntentScope?, reloadInterval: Duration = .seconds(2),
         launch: String = WidgetLaunch.nonce) {
        self.store = store; self.io = io ?? DiskWidgetSnapshotIO(store: store); self.reloader = reloader; self.nowPlaying = nowPlaying; self.liveScope = liveScope; self.reloadInterval = reloadInterval; self.launch = launch
    }

    /// Something the widget shows may have changed.
    func changed() {
        guard !terminated else { return }
        dirty = true
        guard flushing == nil else { return }
        flushing = Task { [weak self] in
            while let self, self.dirty {
                self.dirty = false
                await self.flush()
            }
            self?.flushing = nil
        }
    }
    func sessionActiveChanged(_ active: Bool) { guard !terminated, active != sessionActive else { return }; sessionActive = active; changed() }
    /// Waits for the writes in flight (tests).
    func settle() async { while let task = flushing { await task.value } }

    /// The app finished starting with nobody signed in: show the signed-out sentence.
    func noteSignedOut() { guard !terminated else { return }; signedOutKnown = true; changed() }
    /// An account became the live one.
    func scopeBound() { guard !terminated else { return }; signedOutKnown = false; ended = nil; changed() }

    /// An account barrier, with the account that is leaving captured BEFORE the owner cleared it.
    func barrier(_ event: AppPlaybackAuthority.BarrierEvent) async {
        guard !terminated else { return }
        let leaving = event.departing.map { WidgetScope(account: $0.account, generation: $0.generation, launch: launch) }
        let io = io
        switch event.reason {
        case .quit:
            // The process is going: nothing may keep buttons. The file goes and the widget is told at once (a coalesced reload could die with the process).
            terminated = true; epoch &+= 1
            ended = leaving; forget(); lastWritten = nil
            _ = await queue.run { try? io.delete() }
            reloadNow()
        case .detach:
            epoch &+= 1
            ended = leaving; forget(); signedOutKnown = true; await writeSignedOut(); reloadNow()
        case .removal:
            // Another account's removal leaves this account's snapshot alone.
            guard let leaving else { return }
            guard case .snapshot(let current) = await queue.run({ io.read() }), current.scope?.accountToken == leaving.accountToken else { return }
            epoch &+= 1
            ended = leaving; forget(); signedOutKnown = true; await writeSignedOut(); reloadNow()
        }
    }
    /// W27 (privacy reset): the snapshot file leaves the App Group now and the widget is told, so it shows its "Open YTMuse" state. Nothing of any account stays, and
    /// nothing is written in its place; a later change writes the contentless signed-out snapshot like any other.
    func eraseSnapshot() throws {
        forget(); ended = nil; epoch &+= 1
        let io = io
        // Behind every queued write, so a write that was waiting cannot bring the snapshot back; the one place the main actor waits for the file queue (an explicit reset).
        try queue.runBlocking { Result { try io.delete() } }.get()
        lastWritten = nil
        signedOutKnown = true; reloadNow()
    }
    private func forget() { dirty = false; lastItem = nil; thumbnails = nil }
    /// The contentless signed-out snapshot: nothing of the account that was here.
    private func writeSignedOut() async {
        serial &+= 1
        let marker = WidgetSnapshot.redacted(.signedOut, serial: serial, writtenAt: Date())
        let io = io, mine = epoch
        let wrote = await queue.run { () -> Bool in do { try io.write(marker); return true } catch { try? io.delete(); return false } }
        guard epoch == mine else { return }   // another barrier decided while the file was written; its own write or delete follows this one
        if wrote { writes += 1; lastWritten = marker } else { lastWritten = nil }
    }
    private func reloadNow() { pendingReload?.cancel(); pendingReload = nil; performReload() }

    private func flush() async {
        let mine = epoch
        var computed = await currentSnapshot()
        // A barrier may have run while the live scope was being read: it may have made the app known to be signed out in the meantime, and that stands. (What is computed for the
        // session that ended is dropped inside `currentSnapshot`, right after the scope is read and again after the artwork is made.)
        guard !terminated, epoch == mine else { return }   // quit ran, or a barrier decided, while the scope and the picture were being prepared: its decision is final
        if computed == nil, signedOutKnown { computed = .redacted(.signedOut) }
        let io = io
        guard let snapshot = computed else {
            // Nothing to show and nobody to show it to (no account, and not known to be signed out yet): no file.
            let hadFile = lastWritten != nil
            let removed = await queue.run { () -> Bool in if hadFile || io.read() != .missing { try? io.delete(); return true }; return false }
            guard epoch == mine else { return }
            if removed { lastWritten = nil; requestReload() }
            return
        }
        if let last = lastWritten, Self.sameContent(last, snapshot) { return }
        serial &+= 1
        var stamped = snapshot; stamped.serial = serial; stamped.writtenAt = Date()
        let toWrite = stamped
        let wrote = await queue.run { () -> Bool in (try? io.write(toWrite)) != nil }
        guard epoch == mine, !terminated else { return }   // a barrier's write or delete is queued behind this one and stands
        if wrote { writes += 1; lastWritten = stamped; requestReload() } else { lastWritten = nil }
    }

    /// nil: no file at all (no live account).
    func currentSnapshot() async -> WidgetSnapshot? {
        guard sessionActive else { return .redacted(.locked) }
        let signedOut: WidgetSnapshot? = signedOutKnown ? .redacted(.signedOut) : nil
        guard let live = await liveScope() else { return signedOut }
        let scope = WidgetScope(account: live.accountID, generation: live.generation, launch: launch)
        if scope == ended { return signedOut }
        if let remembered = lastItem, remembered.scope.accountToken != scope.accountToken { lastItem = nil }
        guard let center = nowPlaying, let item = center.current, center.isActive else {
            // Nothing published: the last item of this account, paused with no buttons, or a contentless idle snapshot.
            if let last = lastItem, last.scope.accountToken == scope.accountToken {
                return WidgetSnapshot(state: .paused, title: last.title, artist: last.artist, artwork: last.artwork, capabilities: .none, scope: scope)
            }
            return WidgetSnapshot(state: .idle, scope: scope)
        }
        let caps = center.currentCapabilities
        let capabilities = WidgetCapabilities(playPause: caps.allows(.toggle) || caps.allows(.play) || caps.allows(.pause), next: caps.allows(.next), previous: caps.allows(.previous))
        if item.advertisement { return WidgetSnapshot(state: .advertisement, capabilities: capabilities, scope: scope) }
        let artwork = await thumbnail(for: item.artwork)
        // The picture took time: if a barrier ended this session meanwhile, nothing about it is published.
        if scope == ended || terminated { return signedOut }
        lastItem = (scope, item.title, item.artist, artwork)
        return WidgetSnapshot(state: item.playing ? .playing : .paused, title: item.title, artist: item.artist, artwork: artwork, capabilities: capabilities, scope: scope)
    }
    private func thumbnail(for data: Data?) async -> Data? {
        guard let data else { return nil }
        let io = io
        // The key and the thumbnail are both made off the main actor: hashing and decoding a picture are not main-actor work.
        let result = await queue.run { () -> (key: Int, thumbnail: Data?) in (data.hashValue ^ data.count, nil) }
        if let cached = thumbnails, cached.key == result.key { return cached.thumbnail }
        let made = await queue.run { io.thumbnail(from: data) }
        thumbnails = (result.key, made)
        return made
    }
    /// Equal in everything the widget shows (serial and time are bookkeeping).
    static func sameContent(_ a: WidgetSnapshot, _ b: WidgetSnapshot) -> Bool {
        a.state == b.state && a.title == b.title && a.artist == b.artist && a.artwork == b.artwork && a.capabilities == b.capabilities && a.scope == b.scope
    }

    /// Coalesced: at most one reload per interval, the trailing one scheduled rather than dropped.
    private func requestReload() {
        guard pendingReload == nil else { return }
        let now = ContinuousClock.now
        if let last = lastReload, now - last < reloadInterval {
            let wait = reloadInterval - (now - last)
            pendingReload = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled else { return }
                self.pendingReload = nil; self.performReload()
            }
        } else { performReload() }
    }
    private func performReload() { lastReload = .now; reloads += 1; reloader.reloadNowPlaying() }
}
