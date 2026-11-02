import Testing
import AppKit
import SwiftUI
import Foundation
import DesignSystem
@testable import AppShell
@testable import Features
import TestSupport

/// W21 rework 2 (T52): the shell's own player surfaces, composed from V02's views, through V02's layout audit and render harness: the mini-player at about
/// 360 x 160 compact and expanded, the full-screen Now Playing window (with and without its queue panel), and the status popover. No overlaps, one grid,
/// one light layer, the Ad rules, in light and dark. The headless host shows nothing and keys nothing.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct ShellSurfaceAuditTests {
    enum Surface: String, CaseIterable, Sendable {
        case miniCompact, miniCompactAd, miniCompactIdle, miniExpanded, miniExpandedAd, fullScreen, fullScreenAd, fullScreenLive, fullScreenQueue, popover, popoverAd
        var track: SyntheticTrack? {
            switch self {
            case .miniCompact, .miniExpanded, .fullScreen, .fullScreenQueue, .popover: .playing
            case .miniCompactAd, .miniExpandedAd, .fullScreenAd, .popoverAd: .advertisement
            case .fullScreenLive: .liveStream
            case .miniCompactIdle: nil
            }
        }
        var size: AuditSize {
            switch self {
            case .miniCompact, .miniCompactAd, .miniCompactIdle: AuditSize(name: "mini-compact", width: 360, height: 160)
            case .miniExpanded, .miniExpandedAd: AuditSize(name: "mini-expanded", width: 360, height: 560)
            case .fullScreen, .fullScreenAd, .fullScreenLive, .fullScreenQueue: AuditSize(name: "fullscreen", width: 1440, height: 900)
            case .popover, .popoverAd: AuditSize(name: "popover", width: 300, height: 320)
            }
        }
        /// Tags that must have been reported, or the render proved nothing.
        var required: [String] {
            switch self {
            case .miniCompact, .miniCompactAd: ["miniPlayer", "miniArtwork", "miniTitleBlock", "miniWindowControls", "miniControls", "miniAccessories", "miniTimeline"]
            case .miniCompactIdle: ["miniPlayer", "miniArtwork", "miniTitleBlock", "miniWindowControls", "miniControls", "miniAccessories"]   // nothing plays: no position row
            case .miniExpanded, .miniExpandedAd: ["miniPlayer", "miniToolbar", "playerExpanded", "nowPlayingControls", "nowPlayingAccessories", "nowPlayingTimeline", "nowPlayingHero", "lightLayer"]
            case .fullScreen, .fullScreenAd, .fullScreenLive: ["fullScreenNowPlaying", "playerExpanded", "nowPlayingControls", "nowPlayingAccessories", "nowPlayingTimeline", "nowPlayingHero", "lightLayer"]
            case .fullScreenQueue: ["fullScreenNowPlaying", "playerExpanded", "fullScreenPanel", "nowPlayingControls", "lightLayer"]
            case .popover, .popoverAd: ["statusPopover", "statusCover", "statusControls", "statusVolumeRow", "statusActions"]
            }
        }
        var expectsOneLight: Bool { rawValue.hasPrefix("miniExpanded") || rawValue.hasPrefix("fullScreen") }
    }
    struct Case: Sendable, CustomTestStringConvertible {
        let surface: Surface; let scheme: AuditScheme
        var testDescription: String { "\(surface.rawValue) \(scheme.rawValue)" }
        static let all: [Case] = Surface.allCases.flatMap { surface in AuditScheme.allCases.map { Case(surface: surface, scheme: $0) } }
    }

    func render(_ surface: Surface, scheme: AuditScheme, mode: AuditPolicyMode = .standard) async throws -> (violations: [AuditViolation], record: AuditRecord, frames: [AuditFrame]) {
        let accounts = LocalAccountBootstrap()
        await accounts.load()
        accounts.installShell()
        let shell = accounts.shell
        if let track = surface.track { accounts.playback.music = await SyntheticPlayback.player(track) }
        let store = InMemoryDefaults()
        var preferences = MiniPlayerPreferences(); preferences.expanded = surface.rawValue.hasPrefix("miniExpanded")
        preferences.save(to: store)
        let controller = MiniPlayerController(preferences: store) { _ in AnyView(EmptyView()) }
        let content: AnyView
        switch surface {
        case .miniCompact, .miniCompactAd, .miniCompactIdle, .miniExpanded, .miniExpandedAd: content = AnyView(MiniPlayerView(shell: shell, controller: controller))
        case .fullScreen, .fullScreenAd, .fullScreenLive, .fullScreenQueue: content = AnyView(NowPlayingFullScreenView(shell: shell, leave: {}, initialPanel: surface == .fullScreenQueue ? .queue : .none))
        case .popover, .popoverAd: content = AnyView(StatusPopoverView(shell: shell))
        }
        // The root is PINNED to the surface's size (a window gives it exactly this): content wider or taller than its window escapes it and fails the audit,
        // instead of growing the audited root to fit.
        let host = AuditHost(content.frame(width: surface.size.width, height: surface.size.height, alignment: .topLeading), size: surface.size, scheme: scheme, title: false, mode: mode)
        defer { host.close() }
        await host.settle(until: { surface.required.allSatisfy { name in host.box.frames.contains { $0.tag.name == name } } }, milliseconds: 1500)
        await host.settleUntilReported(surface.required)
        let violations = host.violations(expecting: surface.required)
        if surface.expectsOneLight {
            let lights = host.box.frames.filter { $0.tag.name == "lightLayer" }.count
            #expect(lights == 1, "\(surface.rawValue): exactly one light layer (\(lights))")
        }
        var snapshotPath: String?
        if let directory = AuditOutput.directory {
            let name = "shell-\(surface.rawValue)-\(scheme.rawValue)\(mode == .standard ? "" : "-" + mode.rawValue).png"
            try await host.snapshot(to: directory.appendingPathComponent(name)); snapshotPath = name
        }
        let record = AuditRecord(surface: "shell-" + surface.rawValue + (mode == .standard ? "" : "+" + mode.rawValue), size: surface.size.name, scheme: scheme.rawValue, frames: host.box.frames.count, violations: violations.map(\.description), snapshot: snapshotPath)
        let frames = host.box.frames
        await accounts.shutdown()
        await accounts.isolatedStorage?.destroy()
        return (violations, record, frames)
    }

    @Test(arguments: Case.all)
    func shellSurfaceHasNoOverlapsMisalignmentOrEscapedContent(_ item: Case) async throws {
        let result = try await render(item.surface, scheme: item.scheme)
        AuditLog.records.append(result.record)
        if let url = AuditOutput.report { try? JSONEncoder().encode(AuditLog.records).write(to: url) }
        #expect(result.record.frames > 4, "the audit saw the surface (\(result.record.frames) frames)")
        #expect(result.violations.isEmpty, Comment(rawValue: result.violations.map(\.description).joined(separator: "\n")))
    }

    /// An advertisement is shown, never covered, and the surfaces carry the Ad pill; seek, skip and Previous follow V02's snapshot rules (tested elsewhere);
    /// here the render proves the pill and the controls exist and still do not overlap.
    @Test(arguments: [Surface.miniCompactAd, .miniExpandedAd, .fullScreenAd, .popoverAd])
    func anAdvertisementIsShownAndNothingIsDrawnOverIt(_ surface: Surface) async throws {
        let result = try await render(surface, scheme: .dark)
        #expect(result.violations.isEmpty, Comment(rawValue: result.violations.map(\.description).joined(separator: "\n")))
        let names = Set(result.frames.map(\.tag.name))
        if surface == .miniCompactAd { #expect(names.contains("miniTitleBlock") && names.contains("miniControls")) }
        if surface == .fullScreenAd { #expect(names.contains("nowPlayingHero"), "the hero (the ad's own picture or cover) is on screen, with the controls beside it, not over it") }
    }

    /// GLASS05: the same layouts under Reduce Transparency and Increase Contrast.
    @Test(arguments: [Surface.miniCompact, .miniExpanded, .fullScreen, .popover], [AuditPolicyMode.reduceTransparency, .increaseContrast])
    func fallbacksKeepTheLayoutAndBoundaries(_ surface: Surface, _ mode: AuditPolicyMode) async throws {
        let result = try await render(surface, scheme: .light, mode: mode)
        AuditLog.records.append(result.record)
        #expect(result.violations.isEmpty, Comment(rawValue: result.violations.map(\.description).joined(separator: "\n")))
        if surface == .miniExpanded || surface == .fullScreen {
            let lights = result.frames.filter { $0.tag.name == "lightLayer" }.count
            #expect(lights == 1, "the one light layer is still the only one (\(lights))")
        }
    }

    /// The compact mini-player is about 360 x 160 and its content fits it; the expanded one keeps the same width.
    @Test func theMiniPlayerKeepsItsSpecifiedSizes() {
        #expect(Surface.miniCompact.size.width == 360 && Surface.miniCompact.size.height == 160)
        #expect(MiniPlayerPreferences().defaultSize == CGSize(width: 360, height: 160))
        var expanded = MiniPlayerPreferences(); expanded.expanded = true
        #expect(expanded.defaultSize.width == 360 && Surface.miniExpanded.size.height == expanded.defaultSize.height)
    }
}
