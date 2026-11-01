import AccountSession
import AppIntents
import Foundation
import Testing
@testable import Features
@testable import Playback
@testable import SystemIntegration
@testable import AppShell

// W24 test support. Nothing here donates to the system, invokes Shortcuts or Siri, opens a window, reaches a store or makes a request: the surface
// records which window action was asked for, the hub is the test's own (`IntentHub.$current`), and the playback owner is the fake-page rig of W23.

/// The running app as the channel sees it, over a real playback owner with a fake hidden page.
@MainActor final class TestIntentSurface: IntentAppSurface {
    let playback: PlaybackModel
    var scope: IntentScope?
    var readiness: SearchPlayback = .available
    var rows: [MusicLibraryKind: [MusicCatalogItem]] = [:]
    var seeds: [RadioSeed] = []
    private(set) var shown: [String] = []
    private(set) var startups = 0
    private(set) var scopeReads = 0
    init(playback: PlaybackModel, scope: IntentScope?) { self.playback = playback; self.scope = scope }
    /// Runs once, right AFTER the scope has been read and before it is returned (an account switch landing in that gap).
    var afterScopeRead: (@MainActor () async -> Void)?
    func liveScope() async -> IntentScope? {
        scopeReads += 1
        let read = scope
        if let hook = afterScopeRead { afterScopeRead = nil; await hook() }
        return read
    }
    func awaitStartup() async { startups += 1 }
    var playbackReadiness: SearchPlayback { readiness }
    /// Runs once, on the first read of the library rows (a test changes the session while an intent is mid-flight).
    var onFirstRowsRead: (@MainActor () -> Void)?
    func loadedRows(_ kind: MusicLibraryKind) -> [MusicCatalogItem] {
        if let hook = onFirstRowsRead { onFirstRowsRead = nil; hook() }
        return rows[kind] ?? []
    }
    func meetSeeds() -> [RadioSeed] { seeds }
    func showPlayerWindow() { shown.append("player") }
    func showQueuePanel() { shown.append("queue") }
    /// Whether a window could take a search; when false nothing is recorded as searched.
    var searchPerforms = true
    func performSearch(_ text: String) async -> Bool { if searchPerforms { shown.append("search:" + text) }; return searchPerforms }
}

/// A channel installed in a hub of the test's own, with recording donations.
@MainActor struct IntentRig {
    let media: MediaRig?
    let surface: TestIntentSurface
    let channel: AppIntentChannel
    let hub: IntentHub
    let donations: RecordingDonationSink
    let scope: IntentScope
    let model: PlaybackModel
    var rig: MediaRig { media! }
    static func make(outputs: Bool = false, timing: ManualSleepTiming? = nil) async throws -> IntentRig {
        let media = try await MediaRig.make(outputs: outputs, timing: timing)
        let scope = IntentScope(accountID: media.context.account!.accountID, generation: media.context.accountGeneration)
        return IntentRig(model: media.model, media: media, scope: scope)
    }
    /// A cold launch: the lifecycle rig's owner, restored paused from a record, with nothing loaded.
    static func make(lifecycle: LifecycleRig) -> IntentRig {
        let scope = IntentScope(accountID: lifecycle.context.account!.accountID, generation: lifecycle.context.accountGeneration)
        return IntentRig(model: lifecycle.model, media: nil, scope: scope)
    }
    init(model: PlaybackModel, media: MediaRig?, scope: IntentScope) {
        self.media = media; self.scope = scope; self.model = model
        surface = TestIntentSurface(playback: model, scope: scope)
        channel = AppIntentChannel(surface: surface)
        hub = IntentHub(); hub.startupTimeout = .milliseconds(200)
        donations = RecordingDonationSink(); hub.donations = donations
        hub.install(channel)
    }
    /// Runs `body` with this rig's hub as the one intents and queries find (a task-local, so no other test sees it).
    func within<T: Sendable>(_ body: @MainActor @Sendable () async throws -> T) async throws -> T {
        try await IntentHub.$current.withValue(hub) { try await body() }
    }
    /// The refusal `body` throws, or nil when it does not throw one. Any other error is reported as a failure refusal.
    func thrown<T: Sendable>(_ body: @MainActor @Sendable () async throws -> T) async -> IntentRefusal? {
        do { _ = try await within(body); return nil }
        catch let refusal as IntentRefusal { return refusal }
        catch { return .failed("\(error)") }
    }
    /// Runs an intent's `perform()` the way the system would, inside this rig's hub.
    func run<I: AppIntent>(_ intent: I) async throws {
        try await IntentHub.$current.withValue(hub) { _ = try await intent.perform() }
    }
    func run(_ command: IntentCommand) async -> IntentOutcome { await hub.run(command) }
    var otherScope: IntentScope { IntentScope(accountID: UUID(), generation: scope.generation) }
    /// The same account in another session: after a relaunch, or after signing in to it again.
    var laterSession: IntentScope { IntentScope(accountID: scope.accountID, generation: scope.generation + 2) }
    var earlierSession: IntentScope { IntentScope(accountID: scope.accountID, generation: scope.generation &- 1) }
}

/// Catalog rows as the library and the pages publish them.
enum IntentFixtures {
    static func song(_ title: String, artist: String = "Synthetic Artist", video: String, context: String? = nil) -> MusicCatalogItem {
        MusicCatalogItem(kind: .song, title: title, details: [artist], videoID: video, contextPlaylistID: context,
                         links: [MusicLink(kind: .artist, title: artist, browseID: "UCsynth" + artist.filter(\.isLetter))])
    }
    static func album(_ title: String, artist: String = "Synthetic Artist", id: String) -> MusicCatalogItem {
        MusicCatalogItem(kind: .album, title: title, details: [artist], browseID: "MPREb_" + id, playlistID: "OLAK5uy_" + id)
    }
    static func playlist(_ title: String, id: String) -> MusicCatalogItem {
        MusicCatalogItem(kind: .playlist, title: title, details: ["Synthetic Listener"], browseID: "VL" + id, playlistID: id)
    }
    static func artist(_ name: String, id: String, radio: String? = "RDEMsynthetic", params: String? = nil) -> MusicCatalogItem {
        MusicCatalogItem(kind: .artist, title: name, browseID: "UC" + id, radio: radio.map { MusicRadioAction(playlistID: $0, videoID: nil, params: params) })
    }
}

func intentMedia(_ kind: IntentMediaKind = .song, _ title: String = "Synthetic Song", subtitle: String? = "Synthetic Artist", scope: IntentScope, video: String? = lifecycleVideo,
                 playlist: String? = "PLsyntheticLife") -> IntentMedia {
    IntentMedia(scope: scope, kind: kind, title: title, subtitle: subtitle, target: IntentMediaTarget(videoID: video, playlistID: playlist))
}

/// The repository root, found from this file, for source sweeps.
enum IntentSources {
    nonisolated static var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/test.sh").path) { url.deleteLastPathComponent() }
        return url
    }
    nonisolated static func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    nonisolated static func swiftFiles(under path: String) -> [URL] {
        let base = root.appendingPathComponent(path)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
