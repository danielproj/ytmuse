import Testing
import AppKit
import SwiftUI
import Foundation
import DesignSystem
@testable import AppShell
@testable import Features

/// One audited render: where, how big, which appearance, what it found. Written to V02_AUDIT_REPORT when set.
struct AuditRecord: Codable {
    var surface: String; var size: String; var scheme: String; var frames: Int; var violations: [String]; var snapshot: String?
}
@MainActor final class AuditLog { static var records: [AuditRecord] = [] }
/// One audited render at a time in the process: suites run in parallel, and a render may force the capsule's seek state (a process-wide seam), which another
/// suite's render would otherwise reset under it.
@MainActor enum RenderGate {
    private static var busy = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []
    static func enter() async { if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true } }
    static func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct SurfaceAuditTests {
    enum Surface: String, CaseIterable, Sendable {
        case home, explore, detail, library, search, downloads, uploads, history, nowPlaying, queuePanel
        /// A hidden-player stand-in is playing (synthetic track), so the bar, Now Playing and the queue show real states.
        case playerPlaying, playerShuffleRepeat, playerAd, playerLongTitle, playerLive, nowPlayingSong, nowPlayingAd, nowPlayingLongTitle, nowPlayingLive, queueSong
        /// Now Playing with the queue panel inline (1120 pt and wider; below that the panel is a sheet), for both playback paths.
        case nowPlayingQueueOwned, nowPlayingQueueSong
        /// F4: the Library with the history banner, the Debug QA readouts and a long player error, all at once (the minimum-size contract).
        case chromeLoaded
        var track: SyntheticTrack? {
            switch self {
            case .playerPlaying, .nowPlayingSong, .queueSong, .nowPlayingQueueSong: .playing
            case .playerShuffleRepeat: .shuffledRepeating
            case .playerAd: .advertisement
            case .playerLongTitle: .longTitle
            case .playerLive: .liveStream
            case .nowPlayingAd: .advertisement
            case .nowPlayingLive: .liveStream
            case .nowPlayingLongTitle: .longTitle
            default: nil
            }
        }
        var destination: BrowserDestination {
            switch self {
            case .home: .home; case .explore: .explore; case .detail: .search; case .library: .library; case .search: .search; case .downloads: .downloads
            case .uploads: .uploads; case .history: .history; case .nowPlaying: .nowPlaying; case .queuePanel: .library
            case .playerPlaying, .playerShuffleRepeat, .playerAd, .playerLongTitle, .playerLive: .home; case .nowPlayingSong, .nowPlayingAd, .nowPlayingLongTitle, .nowPlayingLive, .nowPlayingQueueOwned, .nowPlayingQueueSong: .nowPlaying; case .queueSong: .queue
            case .chromeLoaded: .library
            }
        }
        /// Now Playing is the expanded player: the bar has become it, so only one of the two is on screen.
        var expanded: Bool { destination == .nowPlaying }
        /// Tags that must have been reported, or the render proved nothing.
        var required: [String] {
            var base = ["detailPanel", "sidebarPanel", "sidebarFirstRow"]
            if expanded { base += ["playerExpanded", "nowPlayingControls", "nowPlayingAccessories", "nowPlayingTimeline", "nowPlayingHero", "nowPlayingMain", "lightLayer"] }
            else { base += ["playerBar", "playerRow", "playerTimeline", "playerArtwork", "playerTitle", "playerControls", "playerAccessories", "detailColumn"] }
            switch self {
            case .home, .explore, .library, .search, .history, .uploads, .downloads, .chromeLoaded: base += ["destinationTitle"]
            case .nowPlayingSong, .nowPlayingLongTitle, .nowPlayingAd, .nowPlayingLive, .nowPlaying, .nowPlayingQueueOwned, .nowPlayingQueueSong: base += ["nowPlayingArtwork"]
            default: break
            }
            if self == .chromeLoaded { base += ["banner", "debugRow"] }
            return base
        }
        /// The trailing queue panel is inline only at 1120 pt and wider; below that it is a sheet.
        func required(width: Double) -> [String] {
            if self == .queuePanel && width >= 1120 { return required + ["trailingPanel"] }
            if (self == .nowPlayingQueueOwned || self == .nowPlayingQueueSong) && width >= 1120 { return required + ["expandedQueuePanel", "panelPicker", "queueList"] }
            return required
        }
        var opensQueue: Bool { self == .queuePanel || self == .nowPlayingQueueOwned || self == .nowPlayingQueueSong }
    }

    func render(_ surface: Surface, size: AuditSize, scheme: AuditScheme, mode: AuditPolicyMode = .standard, localeMode: AuditLocaleMode = .standard, seek: MusicSeekState? = nil, inspect: ((AuditHost) -> Void)? = nil) async throws -> (violations: [AuditViolation], record: AuditRecord) {
        // PLAYER-1: a hosted render cannot hover or drag, so the capsule's seek state is forced (nil: the pointer's, i.e. at rest).
        await RenderGate.enter()
        defer { RenderGate.leave() }
        CapsuleDebug.forcedSeekState = seek
        defer { CapsuleDebug.forcedSeekState = nil }
        let accounts = LocalAccountBootstrap()
        await accounts.load()
        #expect(!accounts.failure && accounts.developmentQueue != nil)
        var session = BrowserSession()
        session.owner = accounts.windowAuthority.context.account.map(WindowOwner.init)
        session.historyEpoch = await accounts.windowStore?.currentEpoch
        if surface == .chromeLoaded {
            // The same state as `RootRegionLayoutTests`' banner mode: a long player error and the history banner (the QA row is `showsQAReadouts` below).
            accounts.playback.error = String(repeating: "Disposable long error. ", count: 20); accounts.windowAuthority.historyUnavailable()
        }
        if surface == .detail { session.open(.search, item: try NativeItemRoute(kind: .album, identifier: DevelopmentCatalog.albumID)) }
        else { session.open(surface.destination) }
        if let track = surface.track { accounts.playback.music = await SyntheticPlayback.player(track) }
        let navigation = BrowserNavigation(session: session)
        let panels = AdaptivePanelPresentation<BrowserShell.TrailingPanel>()
        let host = AuditHost(LocalAccountRoot(accounts: accounts, panels: panels, navigation: navigation, showsQAReadouts: surface == .chromeLoaded), size: size, scheme: scheme, mode: mode, shell: true, localeMode: localeMode)
        defer { host.close() }
        await host.settle(until: { host.box.frames.contains { $0.tag.name == "playerBar" || $0.tag.name == "playerExpanded" } })
        if surface.opensQueue { panels.selection = .queue; await host.settle() }
        await host.settle(milliseconds: surface == .home || surface == .explore || surface == .detail ? 2500 : 900)
        await host.settleUntilReported(surface.required(width: size.width))
        if seek != nil {   // the track's 0.11 s growth finishes before it is measured
            await host.settle(until: { host.box.frames.first { $0.tag.name == "playerSeekTrack" }.map { abs($0.rect.height - PlayerCapsule.seekHoverThickness) <= 0.5 } ?? false }, milliseconds: 3000)
        }
        // Large text draws the content `scale` times larger: the grid, alignment and margin rules are stated in unscaled points, so only the scale-independent rules apply there.
        let scaleFree: Set<AuditViolation.Rule> = [.overlap, .containment, .missing, .empty]
        let violations = host.violations(expecting: surface.required(width: size.width)).filter { localeMode != .largeText || scaleFree.contains($0.rule) }
        inspect?(host)
        // Page titles share one height: 24 pt below the detail panel's top, on the grid (the audit's `pageTitleTop` key checks the rest within a render).
        let frames = Dictionary(host.box.frames.map { ($0.tag.name, $0.rect) }, uniquingKeysWith: { first, _ in first })
        if let title = frames["destinationTitle"], let panel = frames["detailPanel"] { #expect(abs(title.minY - panel.minY - MusicSpace.lg * (localeMode == .largeText ? 1.5 : 1)) <= LayoutAudit.tolerance, "\(surface) title sits \(title.minY - panel.minY) pt below the panel top") }
        // POL-A: the first sidebar row's highlight must not crowd the panel's rounded top edge. The audit sees the row's label (the highlight is drawn by
        // the list and has no frame of its own), which sits inside the highlight, so the label's gap to the panel's top must be at least the margin the sidebar
        // adds above its first row; the list's own ~4 pt inset and the highlight's inner padding come on top, which is what puts the highlight ~16 pt from the
        // edge as it is from the sides. Without that margin the label sat ~7 pt below the edge (measured before the change).
        if let row = frames["sidebarFirstRow"], let sidebar = frames["sidebarPanel"] {
            let gap = row.minY - sidebar.minY, side = row.minX - sidebar.minX
            #expect(gap >= BrowserShell.sidebarTopInset + MusicSpace.xxs, "first sidebar row sits \(gap) pt below the panel top (side gap \(side))")
            #expect(gap >= MusicSpace.md, "first sidebar row sits \(gap) pt below the panel top; the highlight needs ~16 pt around it")
        }
        if surface.expanded {
            // The expanded player takes the detail panel's place and extends to the window's trailing/bottom margin; it never covers the sidebar or leaves the window.
            let expanded = try #require(frames["playerExpanded"]), panel = try #require(frames["detailPanel"]), sidebar = try #require(frames["sidebarPanel"])
            #expect(abs(expanded.minX - panel.minX) <= LayoutAudit.tolerance && abs(expanded.minY - panel.minY) <= LayoutAudit.tolerance, "grows out of the detail panel's corner")
            #expect(expanded.minX >= sidebar.maxX - LayoutAudit.tolerance, "does not cover the sidebar")
            #expect(abs(host.bounds.maxX - expanded.maxX - MusicSpace.sm) <= LayoutAudit.tolerance && abs(host.bounds.maxY - expanded.maxY - MusicSpace.sm) <= LayoutAudit.tolerance, "keeps the 12 pt outer margin")
            #expect(frames["playerBar"] == nil, "the bar has become the expanded player: only one exists")
            // One light layer: the expanded player's own (the hero draws none), for both playback paths. The surface's glass tint is the other half of the wash.
            let lights = host.box.frames.filter { $0.tag.name == "lightLayer" }.count
            #expect(lights == 1, "exactly one light layer on the expanded player (\(lights))")
            // The sidebar uses the full height while the bar is expanded: both panels end 12 pt above the window's bottom edge, so no band is left under the sidebar.
            #expect(abs(host.bounds.maxY - sidebar.maxY - MusicSpace.sm) <= LayoutAudit.tolerance, "sidebar bottom margin \(host.bounds.maxY - sidebar.maxY)")
            #expect(abs(sidebar.maxY - expanded.maxY) <= LayoutAudit.tolerance, "sidebar and expanded player end together")
        }
        else {
            // PLAYER-1: the bar is a floating capsule at the bottom of the detail column.
            let bar = try #require(frames["playerBar"]), column = try #require(frames["detailColumn"]), sidebar = try #require(frames["sidebarPanel"]), controls = try #require(frames["playerControls"])
            let tolerance = LayoutAudit.tolerance, compact = size.width < 1000, margin: CGFloat = 16   // the brief's MusicSpace.md, as a literal
            #expect(abs(bar.height - PlayerCapsule.height(compact: compact)) <= tolerance, "the capsule is \(PlayerCapsule.height(compact: compact)) pt tall (\(bar.height))")
            #expect(bar.minX >= column.minX + margin - tolerance && bar.maxX <= column.maxX - margin + tolerance, "inside the detail column with its margins: bar \(bar), column \(column)")
            #expect(abs(bar.midX - column.midX) <= tolerance, "centred in the detail column (\(bar.midX) vs \(column.midX))")
            #expect(abs(bar.width - min(column.width - 2 * margin, PlayerCapsule.maximumWidth)) <= tolerance, "the column's width less the margins, capped at \(PlayerCapsule.maximumWidth) (\(bar.width) in a \(column.width) column)")
            #expect(abs(host.bounds.maxY - bar.maxY - margin) <= tolerance, "\(margin) pt above the window's bottom (\(host.bounds.maxY - bar.maxY))")
            #expect(column.maxX <= host.bounds.maxX + tolerance && column.minX >= sidebar.maxX - tolerance, "the column is the area beside the sidebar")
            // No panel reaches the capsule, and each ends above it with the gap.
            for name in ["detailPanel", "trailingPanel"] {
                guard let panel = frames[name] else { continue }
                #expect(!panel.intersects(bar), "\(name) \(panel) does not intersect the capsule \(bar)")
                #expect(panel.maxY <= bar.minY - PlayerCapsule.panelGap + tolerance, "\(name) ends \(bar.minY - panel.maxY) pt above the capsule")
            }
            // The sidebar uses the full height: it ends at the window's bottom margin, where the bar used to be.
            #expect(abs(host.bounds.maxY - sidebar.maxY - MusicSpace.sm) <= tolerance, "the sidebar reaches the window's bottom margin (\(host.bounds.maxY - sidebar.maxY))")
            #expect(abs(controls.midX - bar.midX) <= 1, "the transport is centred in the capsule (\(controls.midX) vs \(bar.midX))")
            // The three groups sit side by side, in either reading direction, and stay inside the capsule.
            if let title = frames["playerTitle"], let accessories = frames["playerAccessories"] {
                func apart(_ x: CGRect, _ y: CGRect) -> Bool { x.maxX <= y.minX + tolerance || y.maxX <= x.minX + tolerance }
                #expect(apart(title, controls) && apart(controls, accessories) && apart(title, accessories), "title, transport and secondary controls do not overlap")
                #expect(accessories.maxX <= bar.maxX + tolerance && accessories.minX >= bar.minX - tolerance && title.maxX <= bar.maxX + tolerance && title.minX >= bar.minX - tolerance, "the groups stay inside the capsule")
            }
        }
        if let seek, !surface.expanded {
            // PLAYER-1, hover and drag: the times, the track and the thumb never intersect the cover, the title block, the transport buttons or the secondary
            // controls, and stay at least 2 pt inside the capsule. The 4 pt track runs from the title's leading edge to the trailing inset.
            let bar = try #require(frames["playerBar"]), cover = try #require(frames["playerArtwork"]), title = try #require(frames["playerTitle"])
            let buttons = try #require(frames["playerButtons"]), accessories = try #require(frames["playerAccessories"]), track = try #require(frames["playerSeekTrack"])
            let compact = size.width < 1000, tolerance = LayoutAudit.tolerance
            var parts: [(String, CGRect)] = [("track", track)]
            if let thumb = frames["playerSeekThumb"] { parts.append(("thumb", thumb)) }
            for name in ["playerElapsed", "playerRemaining"] { if let r = frames[name], r.width > 0, r.height > 0 { parts.append((name, r)) } }
            for (name, rect) in parts {
                #expect(rect.minX >= bar.minX + 2 && rect.maxX <= bar.maxX - 2 && rect.minY >= bar.minY + 2 && rect.maxY <= bar.maxY - 2, "\(name) \(rect) stays 2 pt inside the capsule \(bar)")
                for (other, frame) in [("cover", cover), ("title", title), ("buttons", buttons), ("accessories", accessories)] {
                    #expect(!rect.insetBy(dx: 0.01, dy: 0.01).intersects(frame), "\(name) \(rect) does not intersect the \(other) \(frame)")
                }
            }
            #expect(abs(track.minX - title.minX) <= 1, "the track starts at the title's leading edge (\(track.minX) vs \(title.minX)), never under the cover")
            #expect(track.minX >= cover.maxX, "and never under the cover")
            #expect(abs(bar.maxX - track.maxX - bar.height / 2) <= 1, "and ends at the trailing inset, the corner radius (\(bar.maxX - track.maxX))")
            #expect(abs(track.height - PlayerCapsule.seekHoverThickness) <= 0.5, "4 pt under the pointer (\(track.height))")
            #expect((frames["playerSeekThumb"] != nil) == (seek == .active && surface != .playerAd), "a thumb only while dragging or focused, and never on a seek that is disabled (an ad)")
            if let thumb = frames["playerSeekThumb"] { #expect(abs(thumb.width - PlayerCapsule.thumbEdge(compact: compact)) <= 0.5) }
            if let elapsed = frames["playerElapsed"], let remaining = frames["playerRemaining"], !compact {
                #expect(elapsed.maxX <= buttons.minX + tolerance && remaining.minX >= buttons.maxX - tolerance, "the times sit beside the buttons: elapsed left of Previous, remaining right of Next")
                #expect(abs(elapsed.midY - buttons.midY) <= 1 && abs(remaining.midY - buttons.midY) <= 1, "at the buttons' centre height")
            }
        }
        var snapshotPath: String?
        if let directory = AuditOutput.directory {
            let name = "\(surface.rawValue)-\(size.name)-\(scheme.rawValue)\(mode == .standard ? "" : "-" + mode.rawValue)\(localeMode == .standard ? "" : "-" + localeMode.rawValue).png"
            try await host.snapshot(to: directory.appendingPathComponent(name)); snapshotPath = name
        }
        let record = AuditRecord(surface: surface.rawValue + (mode == .standard ? "" : "+" + mode.rawValue) + (localeMode == .standard ? "" : "+" + localeMode.rawValue), size: size.name, scheme: scheme.rawValue, frames: host.box.frames.count, violations: violations.map(\.description), snapshot: snapshotPath)
        await accounts.shutdown()
        await accounts.isolatedStorage?.destroy()
        return (violations, record)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let surface: Surface; let size: AuditSize; let scheme: AuditScheme
        var testDescription: String { "\(surface.rawValue) \(size.name) \(scheme.rawValue)" }
        /// V02_SURFACES / V02_SIZES (comma lists) narrow a development run; unset runs every surface at every size in both appearances.
        static let all: [Case] = {
            let environment = ProcessInfo.processInfo.environment
            let surfaces = environment["V02_SURFACES"].map { Set($0.split(separator: ",").map(String.init)) }
            let sizes = environment["V02_SIZES"].map { Set($0.split(separator: ",").map(String.init)) }
            return Surface.allCases.filter { surfaces?.contains($0.rawValue) ?? true }.flatMap { surface in
                (AuditSize.all + (surface == .nowPlayingQueueOwned || surface == .nowPlayingQueueSong ? [AuditSize.queueInline] : [])).filter { sizes?.contains($0.name) ?? true }.flatMap { size in AuditScheme.allCases.map { Case(surface: surface, size: size, scheme: $0) } }
            }
        }()
    }
    @Test(arguments: Case.all)
    func surfaceHasNoOverlapsMisalignmentOrEscapedContent(_ item: Case) async throws {
        let result = try await render(item.surface, size: item.size, scheme: item.scheme)
        AuditLog.records.append(result.record)
        if let url = AuditOutput.report { try? JSONEncoder().encode(AuditLog.records).write(to: url) }
        #expect(result.record.frames > 5, "the audit saw the surface (\(result.record.frames) frames)")
        #expect(result.violations.isEmpty, Comment(rawValue: result.violations.map(\.description).joined(separator: "\n")))
    }
}

/// Sheets and the palette: hosted on their own at the sizes they present at (a sheet has no sidebar or player).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct SheetAuditTests {
    enum Sheet: String, CaseIterable, Sendable { case accounts, palette }
    struct Case: Sendable, CustomTestStringConvertible {
        let sheet: Sheet; let size: AuditSize; let scheme: AuditScheme
        var testDescription: String { "\(sheet.rawValue) \(size.name) \(scheme.rawValue)" }
        static let all: [Case] = Sheet.allCases.flatMap { sheet in sizes(sheet).flatMap { size in AuditScheme.allCases.map { Case(sheet: sheet, size: size, scheme: $0) } } }
        static func sizes(_ sheet: Sheet) -> [AuditSize] {
            switch sheet {
            case .accounts: [AuditSize(name: "minimum", width: 700, height: 500), AuditSize(name: "default", width: 760, height: 640), AuditSize(name: "large", width: 1000, height: 800)]
            case .palette: [AuditSize(name: "minimum", width: 520, height: 420), AuditSize(name: "default", width: 640, height: 520), AuditSize(name: "large", width: 900, height: 700)]
            }
        }
    }
    @Test(arguments: Case.all)
    func sheetHasNoOverlapsMisalignmentOrEscapedContent(_ item: Case) async throws {
        let accounts = LocalAccountBootstrap()
        await accounts.load()
        let host: AuditHost
        var required: [String]
        switch item.sheet {
        case .accounts:
            host = AuditHost(VStack { AccountsView(model: accounts.model); Button("Done") {}.musicButtons().padding() }.musicCanvas(), size: item.size, scheme: item.scheme, title: false)
            required = ["accountsTitle", "accountsIntro", "accountsEmpty", "accountsStatus", "accountsActions"]
        case .palette:
            let commands = [("open", "Open Library", "books.vertical"), ("queue", "Show Queue", "list.bullet"), ("lyrics", "Show Lyrics", "quote.bubble"), ("accounts", "Manage Accounts", "person.crop.circle")]
                .map { PaletteCommand(id: $0.0, title: $0.1, symbol: $0.2, shortcut: nil, run: {}) }
            host = AuditHost(CommandPaletteView(model: CommandPaletteModel(search: accounts.makeSearchModel(), commands: commands, dismiss: {})), size: item.size, scheme: item.scheme, title: false)
            required = ["searchField", "paletteRow-open", "paletteRow-accounts"]
        }
        defer { host.close() }
        await host.settle(milliseconds: 900)
        await host.settleUntilReported(required)
        let violations = host.violations(expecting: required)
        var snapshotPath: String?
        if let directory = AuditOutput.directory {
            let name = "sheet-\(item.sheet.rawValue)-\(item.size.name)-\(item.scheme.rawValue).png"
            try await host.snapshot(to: directory.appendingPathComponent(name)); snapshotPath = name
        }
        AuditLog.records.append(AuditRecord(surface: "sheet-" + item.sheet.rawValue, size: item.size.name, scheme: item.scheme.rawValue, frames: host.box.frames.count, violations: violations.map(\.description), snapshot: snapshotPath))
        if let url = AuditOutput.report { try? JSONEncoder().encode(AuditLog.records).write(to: url) }
        #expect(host.box.frames.count > 3)
        #expect(violations.isEmpty, Comment(rawValue: violations.map(\.description).joined(separator: "\n")))
        await accounts.shutdown()
        await accounts.isolatedStorage?.destroy()
    }
}

/// GLASS05 fallbacks rendered: the opaque outlined surfaces (Reduce Transparency) and the high-contrast boundaries (Increase Contrast).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct PolicyAuditTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let surface: SurfaceAuditTests.Surface; let mode: AuditPolicyMode; let scheme: AuditScheme
        var testDescription: String { "\(surface.rawValue) \(mode.rawValue) \(scheme.rawValue)" }
        static let all: [Case] = [SurfaceAuditTests.Surface.playerPlaying, .nowPlayingSong, .library, .home].flatMap { surface in
            [AuditPolicyMode.reduceTransparency, .increaseContrast].flatMap { mode in AuditScheme.allCases.map { Case(surface: surface, mode: mode, scheme: $0) } }
        }
    }
    @Test(arguments: Case.all)
    func fallbackKeepsTheLayoutAndBoundaries(_ item: Case) async throws {
        let result = try await SurfaceAuditTests().render(item.surface, size: .standard, scheme: item.scheme, mode: item.mode)
        AuditLog.records.append(result.record)
        if let url = AuditOutput.report { try? JSONEncoder().encode(AuditLog.records).write(to: url) }
        #expect(result.record.frames > 5)
        #expect(result.violations.isEmpty, Comment(rawValue: result.violations.map(\.description).joined(separator: "\n")))
    }
}

/// GLASS11 transition stages, headless: the bar, the expanded player it becomes (Now Playing), and the bar again, for both owned media and
/// YouTube Music. The headless host cannot capture a mid-morph frame (animations are off while the window is not visible, and a bitmap cannot
/// rasterise native glass), so this proves the stages and their invariants: only one of the two surfaces exists at a time, the expanded player grows
/// out of the detail panel without covering the sidebar, and collapsing restores the bar exactly where it was.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct PlayerMorphStageTests {
    enum Source: String, CaseIterable, Sendable { case youtubeMusic, owned }
    struct Case: Sendable, CustomTestStringConvertible {
        let source: Source; let scheme: AuditScheme
        var testDescription: String { "\(source.rawValue) \(scheme.rawValue)" }
        static let all: [Case] = Source.allCases.flatMap { source in AuditScheme.allCases.map { Case(source: source, scheme: $0) } }
    }
    @Test(arguments: Case.all)
    func theBarBecomesTheExpandedPlayerAndBack(_ item: Case) async throws {
        let accounts = LocalAccountBootstrap()
        await accounts.load()
        var session = BrowserSession()
        session.owner = accounts.windowAuthority.context.account.map(WindowOwner.init)
        session.historyEpoch = await accounts.windowStore?.currentEpoch
        session.open(.home)
        if item.source == .youtubeMusic { accounts.playback.music = await SyntheticPlayback.player(.playing) }
        let navigation = BrowserNavigation(session: session)
        let host = AuditHost(LocalAccountRoot(accounts: accounts, panels: AdaptivePanelPresentation<BrowserShell.TrailingPanel>(), navigation: navigation, showsQAReadouts: false), size: .standard, scheme: item.scheme, shell: true)
        defer { host.close() }
        func names() -> Set<String> { Set(host.box.frames.map(\.tag.name)) }
        func frame(_ name: String) -> CGRect? { host.box.frames.first { $0.tag.name == name }?.rect }
        func stage(_ label: String, _ number: Int) async throws {
            if let directory = AuditOutput.directory {
                try await host.snapshot(to: directory.appendingPathComponent("morph-\(item.source.rawValue)-\(number)-\(label)-\(item.scheme.rawValue).png"))
            }
        }
        await host.settle(until: { names().contains("playerBar") })
        await host.settle(milliseconds: 1500)
        // 1. collapsed: the bar
        #expect(names().contains("playerBar") && !names().contains("playerExpanded"))
        let bar = try #require(frame("playerBar"))
        #expect(host.violations(expecting: ["playerBar", "detailPanel", "sidebarPanel", "destinationTitle"]).isEmpty)
        let barTint = PlayerTintProbe.tint("bar", for: accounts.playback)
        if item.source == .youtubeMusic { #expect(barTint != nil, "the cover's light reached the bar") }
        try await stage("collapsed", 1)
        // 2. expanded: Now Playing
        navigation.open(.nowPlaying)
        await host.settle(until: { names().contains("playerExpanded") })
        await host.settle(milliseconds: 600)
        #expect(names().contains("playerExpanded") && !names().contains("playerBar"), "only one of the bar and the expanded player exists")
        for tag in ["nowPlayingArtwork", "nowPlayingControls", "nowPlayingTimeline"] { #expect(names().contains(tag), "\(tag) is on the expanded player") }
        let expanded = try #require(frame("playerExpanded")), panel = try #require(frame("detailPanel")), sidebar = try #require(frame("sidebarPanel"))
        #expect(abs(expanded.minX - panel.minX) <= 0.75 && abs(expanded.minY - panel.minY) <= 0.75 && expanded.minX >= sidebar.maxX - 0.75)
        #expect(expanded.maxY > bar.minY, "it contains the place the bar had")
        #expect(host.violations(expecting: ["playerExpanded", "detailPanel", "sidebarPanel"]).isEmpty)
        // The glass tint is one input across the morph: the expanded player is given exactly what the bar had (it used to arrive untinted).
        let expandedTint = PlayerTintProbe.tint("expanded", for: accounts.playback)
        #expect(expandedTint == barTint, "the tint input is equal in stages 1 and 2 (\(String(describing: barTint)) vs \(String(describing: expandedTint)))")
        try await stage("expanded", 2)
        // 3. collapsed again, the bar where it was
        navigation.back()
        await host.settle(until: { names().contains("playerBar") })
        await host.settle(milliseconds: 600)
        #expect(names().contains("playerBar") && !names().contains("playerExpanded"))
        let again = try #require(frame("playerBar"))
        #expect(abs(again.minX - bar.minX) <= 0.75 && abs(again.minY - bar.minY) <= 0.75 && abs(again.width - bar.width) <= 0.75 && abs(again.height - bar.height) <= 0.75, "the bar returns to the same frame")
        #expect(PlayerTintProbe.tint("bar", for: accounts.playback) == barTint, "and the bar gets it back")
        try await stage("collapsed-again", 3)
        await accounts.shutdown()
        await accounts.isolatedStorage?.destroy()
    }
}

/// PLAYER-1: the capsule's seek under the pointer and while dragged (the audit forces the state: a hosted render cannot hover).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct CapsuleHoverAuditTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let surface: SurfaceAuditTests.Surface; let size: AuditSize; let state: MusicSeekState; let scheme: AuditScheme
        var testDescription: String { "\(surface.rawValue) \(size.name) \(state) \(scheme.rawValue)" }
        static let all: [Case] = [SurfaceAuditTests.Surface.playerPlaying, .playerAd, .playerLongTitle, .playerLive].flatMap { surface in
            [AuditSize.minimum, .standard].flatMap { size in
                [MusicSeekState.hover, .active].map { Case(surface: surface, size: size, state: $0, scheme: .dark) }
            }
        } + [Case(surface: .playerPlaying, size: .standard, state: .hover, scheme: .light), Case(surface: .playerPlaying, size: .large, state: .active, scheme: .light)]
    }
    @Test(arguments: Case.all)
    func timesTrackAndThumbNeverTouchTheControls(_ item: Case) async throws {
        let result = try await SurfaceAuditTests().render(item.surface, size: item.size, scheme: item.scheme, seek: item.state)
        #expect(result.violations.isEmpty, Comment(rawValue: result.violations.map(\.description).joined(separator: "\n")))
    }
    /// The slots are reserved at rest: the buttons are where they were when the times appear.
    @Test func theButtonsDoNotMoveWhenTheTimesAppear() async throws {
        var rest: [String: CGRect] = [:], hover: [String: CGRect] = [:]
        func buttons(_ host: AuditHost) -> [String: CGRect] { Dictionary(host.box.frames.filter { ["playerButtons", "playerControls", "playerArtwork", "playerTitle", "playerAccessories"].contains($0.tag.name) }.map { ($0.tag.name, $0.rect) }, uniquingKeysWith: { first, _ in first }) }
        _ = try await SurfaceAuditTests().render(.playerPlaying, size: .standard, scheme: .dark) { rest = buttons($0) }
        _ = try await SurfaceAuditTests().render(.playerPlaying, size: .standard, scheme: .dark, seek: .hover) { hover = buttons($0) }
        #expect(rest.count == 5 && hover.count == 5)
        for (name, frame) in rest { #expect(abs((hover[name] ?? .zero).minX - frame.minX) <= 0.5 && abs((hover[name] ?? .zero).minY - frame.minY) <= 0.5 && abs((hover[name] ?? .zero).width - frame.width) <= 0.5, "\(name) moved: \(frame) -> \(String(describing: hover[name]))") }
    }
    /// The times are laid out at rest (40 pt slots, invisible by colour): present in the view tree, so tests and VoiceOver find them; none in the compact capsule.
    @Test(arguments: [AuditSize.standard, AuditSize.minimum]) func theTimeSlotsExistAtRest(_ size: AuditSize) async throws {
        var slots: [String: CGRect] = [:]
        _ = try await SurfaceAuditTests().render(.playerPlaying, size: size, scheme: .dark) { host in
            slots = Dictionary(host.box.frames.filter { ["playerElapsed", "playerRemaining"].contains($0.tag.name) }.map { ($0.tag.name, $0.rect) }, uniquingKeysWith: { first, _ in first })
        }
        #expect(slots.count == 2, "both times are in the view tree at rest")
        #expect(slots.values.allSatisfy { abs($0.width - (size.width < 1000 ? 0 : PlayerCapsule.timeSlotWidth)) <= 0.5 }, "\(slots)")
    }
}
