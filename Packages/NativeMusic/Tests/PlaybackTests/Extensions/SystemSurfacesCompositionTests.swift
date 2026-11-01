import Foundation
import Testing
import SystemIntegration
import WidgetShared
@testable import AppShell

/// Real-data safety (W25 addendum 2-4): an isolated launch or a test process is given a temporary App Group directory, a recording reloader and an in-memory index,
/// whatever the app target offered, and the offered ones are not even asked for. The real container is never named, created, written or deleted.
@Suite @MainActor struct SystemSurfacesCompositionTests {
    /// Offers that FAIL THE TEST if they are ever called: they stand for the real container, WidgetCenter and Spotlight.
    private func trap(_ asked: Box) -> SystemServices {
        SystemServices(groupDirectory: { asked.groupDirectory = true; return URL(fileURLWithPath: "/dev/null/real-group-container") },
                       widgetReloader: { asked.reloader = true; return RecordingTimelineReloader() },
                       searchIndex: { asked.index = true; return InMemorySearchableIndex() })
    }
    final class Box: @unchecked Sendable { var groupDirectory = false, reloader = false, index = false }

    @Test func aTestProcessGetsTemporaryServicesAndTheOffersAreNeverAskedFor() throws {
        let asked = Box()
        let bootstrap = LocalAccountBootstrap(loginItem: InMemoryLoginItemService(), system: trap(asked))
        bootstrap.installSystemSurfaces(hub: IntentHub(), receiver: WidgetCommandReceiver())
        #expect(!asked.groupDirectory && !asked.reloader && !asked.index, "an isolated bootstrap never asks the app target for the real surfaces")
        let services = try #require(bootstrap.resolvedServices)
        let directory = try #require(services.groupDirectory)
        let root = try #require(bootstrap.isolatedStorage?.root)
        #expect(directory.path.hasPrefix(root.path + "/") && directory.lastPathComponent == "app-group", "the group is a directory under the isolation root: \(directory.path)")
        #expect(!WidgetSnapshotStore.refusesRealContainer(directory))
        #expect(services.reloader is RecordingTimelineReloader && services.searchIndex is InMemorySearchableIndex)
        #expect(bootstrap.widgetPublisher != nil && bootstrap.widgetBridge != nil && bootstrap.spotlight != nil)
    }
    @Test func theSnapshotLandsInTheTemporaryDirectoryAndTheShellsSpotlightChoicesAreOffAndStoredInThePreferencesStore() async throws {
        let bootstrap = LocalAccountBootstrap(loginItem: InMemoryLoginItemService())
        bootstrap.installSystemSurfaces(hub: IntentHub(), receiver: WidgetCommandReceiver())
        let directory = try #require(bootstrap.resolvedServices?.groupDirectory)
        let publisher = try #require(bootstrap.widgetPublisher)
        #expect(await publisher.currentSnapshot() == nil, "no account is connected in a bare bootstrap: no file")
        publisher.changed(); await publisher.settle()
        #expect(WidgetSnapshotStore(directory: directory).read() == .missing)
        #expect(!bootstrap.shell.spotlightSettings.enabled && !bootstrap.shell.spotlightSettings.includePrivate, "Spotlight is off until the person turns it on")
    }
    @Test func nowPlayingFeedsThePublisherThroughTheOneHook() async throws {
        let bootstrap = LocalAccountBootstrap(loginItem: InMemoryLoginItemService())
        bootstrap.installSystemSurfaces(hub: IntentHub(), receiver: WidgetCommandReceiver())
        #expect(bootstrap.playback.nowPlaying.onChange != nil, "Now Playing's change hook is the publisher's only trigger")
        #expect(bootstrap.widgetPublisher != nil && bootstrap.spotlight != nil, "the surfaces that listen to the authority's barrier events are built")
    }
    @Test func aLaunchWithNobodyToRestoreWritesTheSignedOutSnapshotToTheTemporaryGroup() async throws {
        let bootstrap = LocalAccountBootstrap(loginItem: InMemoryLoginItemService())
        bootstrap.installSystemSurfaces(hub: IntentHub(), receiver: WidgetCommandReceiver())
        let directory = try #require(bootstrap.resolvedServices?.groupDirectory)
        let publisher = try #require(bootstrap.widgetPublisher)
        #expect(WidgetSnapshotStore(directory: directory).read() == .missing, "before the launch has finished there is no file: nothing is claimed during the restore")
        await bootstrap.load()    // a bare isolated launch: no account to restore
        await publisher.settle()
        guard case .snapshot(let snapshot) = WidgetSnapshotStore(directory: directory).read() else { Issue.record("the launch must have written the signed-out snapshot"); return }
        #expect(snapshot.state == .signedOut && snapshot.title == nil && snapshot.scope == nil, "the contentless signed-out snapshot (F9): \(snapshot)")
    }
}
