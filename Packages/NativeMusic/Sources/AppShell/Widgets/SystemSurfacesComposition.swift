import AccountSession
import AppKit
import Domain
import Features
import Foundation
import SystemIntegration
import WidgetShared

// W25 (MAC05, MAC06, ARCH09). Wires the widget snapshot, the widget command channel and Spotlight into the one bootstrap.
//
// Real-data safety (addendum): an isolated launch or a test process never gets the real App Group container, the real widget reload or the real Spotlight
// index, whatever the app target supplied. It gets a temporary directory under the isolation root, a recording reloader and an in-memory index.
// The decision is made here, once, and the temporary-directory check is fatal.

/// Where the surfaces are tied to the account lifecycle. The authority hands every barrier listener the account that is LEAVING (it captures it before it clears its own
/// scope; the plain barrier handlers run after that and cannot know it), and tells them when an account becomes the live one.
@MainActor enum SystemSurfaceWiring {
    static func register(authority: AppPlaybackAuthority, widget: WidgetSnapshotPublisher?, spotlight: SpotlightController?) {
        authority.onBarrierEvent { [weak widget, weak spotlight] event in
            await widget?.barrier(event)
            // Quit leaves the Spotlight entries (they stay valid while the app is closed; the widget cannot, so it goes). Sign-out, switch and removal remove the account's.
            if event.reason != .quit, let departing = event.departing { await spotlight?.accountEnded(departing.account) }
        }
        authority.onScopeBound { [weak widget, weak spotlight] in
            await MainActor.run { widget?.scopeBound(); spotlight?.refresh() }
        }
    }
}

/// What this launch really uses for the widget's directory and reload and for the Spotlight index.
struct ResolvedSurfaces {
    var groupDirectory: URL?
    var reloader: (any WidgetTimelineReloading)?
    var searchIndex: (any SearchableIndexBackend)?
}

extension LocalAccountBootstrap {
    /// The services this launch really uses. Isolated (every automated launch, every test): a temporary App Group directory under the isolation root,
    /// a recording reloader, an in-memory Spotlight index. Otherwise what the app target supplied.
    func resolveSystemSurfaces() -> ResolvedSurfaces {
        #if DEBUG
        if let isolated = isolatedStorage {
            let directory = isolated.root.appendingPathComponent("app-group", isDirectory: true)
            precondition(!WidgetSnapshotStore.refusesRealContainer(directory), "an isolated launch must never use the real App Group container")
            return ResolvedSurfaces(groupDirectory: directory, reloader: RecordingTimelineReloader(), searchIndex: InMemorySearchableIndex())
        }
        #endif
        // A normal launch: only what the app target offered, asked for now and never before.
        return ResolvedSurfaces(groupDirectory: systemServices.groupDirectory?(), reloader: systemServices.widgetReloader?(), searchIndex: systemServices.searchIndex?())
    }

    /// Makes the running app publish the widget snapshot, answer the widget's buttons and keep Spotlight right. Called once by the production composition root.
    func installSystemSurfaces(hub: IntentHub = .shared, receiver: WidgetCommandReceiver = .shared) {
        let services = resolveSystemSurfaces()
        resolvedServices = services
        var publisher: WidgetSnapshotPublisher?
        if let directory = services.groupDirectory, let reloader = services.reloader {
            let made = WidgetSnapshotPublisher(store: WidgetSnapshotStore(directory: directory), reloader: reloader, nowPlaying: playback.nowPlaying) { [weak self] in await self?.scopeWithoutLoading() }
            playback.nowPlaying.onChange = { [weak made] in made?.changed() }
            let bridge = WidgetCommandBridge(surface: self, hub: hub)
            bridge.install(on: receiver)
            widgetBridge = bridge
            publisher = made; widgetPublisher = made
            if !Self.automationIsolatedLaunch { observeUserSession(made) }
        }
        var controller: SpotlightController?
        if let backend = services.searchIndex {
            let made = SpotlightController(indexer: SpotlightIndexer(backend: backend), settings: shell.spotlightSettings, source: self) { [weak self] in await self?.scopeWithoutLoading() }
            controller = made; spotlight = made
        }
        SystemSurfaceWiring.register(authority: playback.authority, widget: publisher, spotlight: controller)
        PlaybackApplicationDelegate.spotlightResult = { [weak self] identifier in Task { @MainActor in _ = await self?.openSpotlightResult(identifier, hub: hub) } }
    }

    /// The live scope as the authority has it NOW. Unlike `liveScope()` it never starts the account load: the publisher and the indexer observe, they do not launch.
    func scopeWithoutLoading() async -> IntentScope? {
        await playback.authority.activeScope().map { IntentScope(accountID: $0.account, generation: $0.generation) }
    }

    /// The Mac's user session leaving and returning (fast user switching) redacts and restores the widget. Public AppKit notifications only.
    private func observeUserSession(_ publisher: WidgetSnapshotPublisher) {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { publisher.sessionActiveChanged(false) } }
        center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { publisher.sessionActiveChanged(true) } }
    }

    /// A Spotlight result was opened: the same commands and gates as the window (ARCH03), only for this app's identifiers and the live account.
    func openSpotlightResult(_ uniqueID: String, hub: IntentHub = .shared) async -> IntentOutcome {
        await awaitStartup()
        switch SpotlightActivation.command(for: uniqueID, live: await liveScope()) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let command):
            shell.showMainWindow()
            return await hub.run(command)
        }
    }
}

extension LocalAccountBootstrap: SpotlightSource {
    func libraryRows(_ kind: MusicLibraryKind) -> [MusicCatalogItem] { library.models[kind]?.entries.map(\.item) ?? [] }
    func localHistory() -> [LocalHistoryRecord] { library.history.local }
}
