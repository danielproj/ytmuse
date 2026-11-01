// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "NativeMusic", platforms: [.macOS("27.0")], products: [
 .library(name: "Domain", targets: ["Domain"]),
 .library(name: "DesignSystem", targets: ["DesignSystem"]),
 .library(name: "Diagnostics", targets: ["Diagnostics"]),
 .library(name: "Persistence", targets: ["Persistence"]),
 .library(name: "AccountSession", targets: ["AccountSession"]),
 .library(name: "YouTubeMusicAdapter", targets: ["YouTubeMusicAdapter"]),
 .library(name: "StreamResolver", targets: ["StreamResolver"]),
 .library(name: "Queue", targets: ["Queue"]),
 .library(name: "OutputRoutes", targets: ["OutputRoutes"]),
 .library(name: "Playback", targets: ["Playback"]),
 .library(name: "Downloads", targets: ["Downloads"]),
 .library(name: "Artwork", targets: ["Artwork"]),
 .library(name: "SystemIntegration", targets: ["SystemIntegration"]),
 .library(name: "WidgetShared", targets: ["WidgetShared"]),
 .library(name: "Features", targets: ["Features"]),
 .library(name: "AppShell", targets: ["AppShell"]),
 .library(name: "Updates", targets: ["Updates"]),
], targets: [
 .target(name: "Domain", dependencies: []),
 .target(name: "DesignSystem", dependencies: ["Domain"]),
 .target(name: "Diagnostics", dependencies: ["Domain"]),
 .target(name: "Persistence", dependencies: ["Domain"]),
 .target(name: "AccountSession", dependencies: ["Domain", "Persistence"]),
 .target(name: "YouTubeMusicAdapter", dependencies: ["Domain", "AccountSession"]),
 .target(name: "StreamResolver", dependencies: ["Domain", "AccountSession"]),
 .target(name: "Queue", dependencies: ["Domain", "Persistence"]),
 .target(name: "OutputRoutes", dependencies: ["Domain"]),
 .target(name: "Playback", dependencies: ["Domain", "Queue", "OutputRoutes"], resources: [.process("Resources")]),
 .target(name: "Downloads", dependencies: ["Domain", "Persistence", "StreamResolver", "AccountSession", "Playback"]),
 .target(name: "Artwork", dependencies: ["Domain"]),
 .target(name: "SystemIntegration", dependencies: ["Domain"]),
 // W25: the App Group snapshot schema and store, the widget timeline provider and views, and the widget button intent. No playback, account, network or store code.
 .target(name: "WidgetShared", dependencies: ["DesignSystem"]),
 // W30: the in-repository updater (signed static feed, version and provenance validation, explicit restart). Foundation, CryptoKit and Security, plus Domain for the destructive-call guard (RealStores, ProcessIsolation).
 .target(name: "Updates", dependencies: ["Domain"]),
 .target(name: "Features", dependencies: ["Domain", "DesignSystem", "AccountSession", "Queue", "Artwork", "Diagnostics"]),
 .target(name: "AppShell", dependencies: ["Features", "Domain", "OutputRoutes", "DesignSystem", "AccountSession", "Persistence", "Playback", "Queue", "Artwork", "Downloads", "SystemIntegration", "WidgetShared", "Diagnostics", "Updates"]),
 .testTarget(name: "NavigationTests", dependencies: ["AppShell", "DesignSystem", "Features", "Artwork", "Domain", "AccountSession", "Queue"]),
 .testTarget(name: "ArtworkTests", dependencies: ["Artwork", "Domain"]),
 .testTarget(name: "OfflineStoreTests", dependencies: ["Downloads", "Playback", "AccountSession", "Domain"]),
 .testTarget(name: "DownloadsTests", dependencies: ["Downloads", "Playback", "AccountSession", "Domain", "Features", "AppShell", "Queue"]),
 .testTarget(name: "PlaybackTests", dependencies: ["Playback", "OutputRoutes", "Domain", "Queue", "Persistence", "AppShell", "AccountSession", "Downloads", "SystemIntegration", "Features", "WidgetShared"]),
 .testTarget(name: "VideoTests", dependencies: ["VideoSurfaceProbe", "Playback", "Domain", "Queue", "Persistence", "AppShell", "AccountSession", "Features", "SystemIntegration"]),
 .testTarget(name: "NetworkingTests", dependencies: ["YouTubeMusicAdapter", "Domain", "Persistence"]),
 .testTarget(name: "ConnectionTests", dependencies: ["YouTubeMusicAdapter", "AccountSession", "StreamResolver"]),
 .testTarget(name: "QueueTests", dependencies: ["Queue", "Persistence", "Domain", "Features"], exclude: ["Workers"]),
 .testTarget(name: "AccountSessionTests", dependencies: ["AccountSession", "Persistence", "Domain", "Features", "Downloads"]),
 .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Domain"]),
 .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
 // V02: design tokens, source guard, layout-audit rules and the headless render audit of the primary surfaces.
 .testTarget(name: "GlassPolishTests", dependencies: ["AppShell", "DesignSystem", "Features", "Playback", "Domain", "AccountSession", "Artwork", "Queue"]),
 .testTarget(name: "AccessibilityLocalizationTests", dependencies: ["AppShell", "DesignSystem", "Features", "Domain", "AccountSession", "Playback", "SystemIntegration", "YouTubeMusicAdapter"]),
 .testTarget(name: "DomainTests", dependencies: ["Domain"]),
 .testTarget(name: "SearchTests", dependencies: ["Features", "AccountSession", "YouTubeMusicAdapter", "AppShell", "Persistence", "Domain"]),
 .testTarget(name: "CatalogTests", dependencies: ["Features", "AccountSession", "YouTubeMusicAdapter", "AppShell", "Artwork", "Domain"]),
 .testTarget(name: "LibraryTests", dependencies: ["Features", "AccountSession", "YouTubeMusicAdapter", "AppShell", "Artwork", "Domain"]),
 .testTarget(name: "UploadsTests", dependencies: ["Features", "AccountSession", "YouTubeMusicAdapter", "AppShell", "Domain"]),
 .testTarget(name: "PlaylistTests", dependencies: ["Features", "AccountSession", "YouTubeMusicAdapter", "AppShell", "Domain"]),
 .testTarget(name: "DiscoverySocialTests", dependencies: ["Features", "AccountSession", "YouTubeMusicAdapter", "AppShell", "Domain"]),
 .testTarget(name: "PodcastsLyricsTests", dependencies: ["Features", "AccountSession", "YouTubeMusicAdapter", "AppShell", "Playback", "Downloads", "Domain", "SystemIntegration"]),
 .testTarget(name: "DomainContractTests", dependencies: ["Domain", "Features"]),
 // Test-only: fresh-process WebKit store probe; never a product or app dependency.
 .executableTarget(name: "WebKitStoreProbe", dependencies: ["AccountSession", "Domain"], path: "Tests/WebKitStoreProbe"),
 // Test-only: fresh-process hidden-player WebKit probe; never a product or app dependency.
 // Test-only (W22): what the shipped WebKit exposes to a page for choosing an audio output or an AirPlay target; never an app dependency.
 .executableTarget(name: "OutputCapabilityProbe", dependencies: [], path: "Tests/OutputCapabilityProbe"),
 .executableTarget(name: "WebMusicPlayerProbe", dependencies: ["Playback"], path: "Tests/WebMusicPlayerProbe"),
 // Test-only (W17): fresh-process hidden-player video/live/surface probe against the Fixtures/W17 stand-in document; never an app dependency.
 .executableTarget(name: "VideoSurfaceProbe", dependencies: ["Playback"], path: "Tests/VideoSurfaceProbe"),
 // Test-only: fresh-process quit probe for the bounded shutdown (Q1); never an app dependency.
 .executableTarget(name: "QuitProbe", dependencies: ["AppShell"], path: "Tests/QuitProbe"),
 // W22: route model, capability table, route-loss policy, handoff and remote-session rules, the WebKit probe and the guards.
 .testTarget(name: "RoutesTests", dependencies: ["OutputRoutes", "Domain", "OutputCapabilityProbe"], path: "Tests/Routes"),
 // W30: the release tooling for the signed feed; never an app dependency.
 .executableTarget(name: "FeedTool", dependencies: ["Updates"], path: "Sources/FeedTool"),
 .testTarget(name: "UpdatesTests", dependencies: ["Updates", "FeedTool", "Domain"]),
 // W27: settings registry and store, scopes, reset, privacy reset and its real-root guard, storage reconciliation, diagnostics, redaction, support bundle and profiling.
 // W29: privacy, security and failure-path hardening (T29.1-T29.5). Canaries through the real inputs, hostile inputs against local fakes, the destination audit, account deletion during work, and thread affinity.
 .testTarget(name: "SecurityTests", dependencies: ["Updates", "YouTubeMusicAdapter", "Features", "AppShell", "Diagnostics", "Domain", "AccountSession", "Persistence", "Downloads", "Playback", "Artwork", "Queue", "SystemIntegration", "WidgetShared", "OutputRoutes"], path: "Tests/Security"),
 .testTarget(name: "SettingsTests", dependencies: ["YouTubeMusicAdapter", "Features", "AppShell", "Diagnostics", "Updates", "Domain", "AccountSession", "Persistence", "Downloads", "Playback", "Artwork", "Queue", "SystemIntegration", "WidgetShared", "OutputRoutes", "DesignSystem"]),
 .testTarget(name: "WebSessionProcessTests", dependencies: ["WebKitStoreProbe", "WebMusicPlayerProbe", "QuitProbe"])
])
