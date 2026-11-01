import XCTest
import SwiftUI
import AppKit
import Domain
import Features
@testable import AppShell

/// N1: the Library offers "Downloaded only", showing only kept items, Play only when a player is wired, with an honest empty state,
/// and nothing overlaps. Rendered off-screen (never acceptance); no account, service or store.
@MainActor final class LibraryDownloadedTests: XCTestCase {
    private func row(_ title: String, play: Bool, phase: DownloadPhase = .available) -> DownloadRowModel {
        DownloadRowModel(id: UUID(), media: try! ServiceID("owned-" + title), title: title, subtitle: "File on this Mac", origin: .localFile, phase: phase, progress: DownloadProgress(completedBytes: 1, totalBytes: 1), pauseCause: nil, failure: nil,
                         pinned: true, automatic: false, referenceCount: 1, storedBytes: 10, retryAt: nil, expiresAt: nil, actions: play ? [.play, .remove] : [.remove])
    }
    private func snapshot(_ rows: [DownloadRowModel]) -> DownloadsSnapshot {
        DownloadsSnapshot(rows: rows, collections: [], aggregate: nil, activeCount: 0, waitingCount: 0, storage: DownloadsSnapshot.unbound.storage, storageChoices: [], smartDownloadsEnabled: false,
                          concurrencyLimit: 2, lowPowerMode: false, networkConstrained: false, networkExpensive: false, networkAvailable: true, hasAccount: true)
    }
    private final class Engine: DownloadsControlling, @unchecked Sendable {
        let value: DownloadsSnapshot; init(_ value: DownloadsSnapshot) { self.value = value }
        func snapshot() async -> DownloadsSnapshot { value }
        func updates() async -> AsyncStream<DownloadsSnapshot> { let v = value; return AsyncStream { $0.yield(v) } }
        func perform(_ action: DownloadAction, job: UUID) async -> DownloadCommandResult { .done }
        func setBudget(bytes: Int64) async -> DownloadCommandResult { .done }
        func setSmartDownloads(enabled: Bool) async -> DownloadCommandResult { .done }
        func addLocalFile(_ file: URL) async -> DownloadCommandResult { .done }
        func play(job: UUID) async -> DownloadCommandResult { .done }
        func removeAutomaticDownloads() async -> DownloadCommandResult { .done }
    }
    private func model(_ rows: [DownloadRowModel]) async throws -> DownloadsModel {
        let m = DownloadsModel(controller: Engine(snapshot(rows))); m.start()
        for _ in 0..<200 where m.snapshot.rows.count != rows.count { try await Task.sleep(for: .milliseconds(5)) }
        return m
    }
    private final class Frames { var values: [String: CGRect] = [:]; var rows: [String: CGRect] = [:] }
    /// Hosts a view in an off-screen window, lets it lay out, and returns.
    private func host<V: View>(_ view: V, width: CGFloat = 900, height: CGFloat = 700) async throws -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view); window.ignoresMouseEvents = true; window.alphaValue = 0; window.orderFrontRegardless()
        for _ in 0..<20 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        return window
    }

    func testTheBootstrapGivesTheLibraryTheSameDownloadsModelTheDownloadsScreenUses() {
        let accounts = LocalAccountBootstrap()
        XCTAssertTrue(accounts.library.downloads === accounts.downloads, "the Library's Downloaded-only section reads the engine's own state")
        XCTAssertFalse(accounts.library.showsDownloadedOnly, "the Library opens on its own collections")
    }
    func testTheDownloadedOnlySectionListsOnlyKeptItemsAndPlayOnlyWhereAPlayerIsWired() async throws {
        let frames = Frames()
        let kept = row("Playable", play: true), noPlayer = row("Unwired", play: false), downloading = row("Still going", play: false, phase: .downloading), failed = row("Broken", play: false, phase: .failed)
        let m = try await model([kept, noPlayer, downloading, failed])
        let view = DownloadedItemsSection(model: m).frame(width: 600).onPreferenceChange(DownloadedRowFrames.self) { frames.rows = $0 }
        let window = try await host(view, width: 640, height: 400); defer { window.orderOut(nil) }
        XCTAssertEqual(Set(frames.rows.keys), [kept.id.uuidString, noPlayer.id.uuidString], "only Downloaded items; the transfer and the failure are not listed")
        let ordered = frames.rows.values.sorted { $0.minY < $1.minY }
        XCTAssertEqual(ordered.count, 2)
        for (a, b) in zip(ordered, ordered.dropFirst()) { XCTAssertLessThanOrEqual(a.maxY, b.minY + 0.5, "rows do not overlap") }
        for r in ordered { XCTAssertGreaterThan(r.height, 20); XCTAssertGreaterThanOrEqual(r.minX, -0.5); XCTAssertLessThanOrEqual(r.maxX, 600.5) }
        let playActions = m.snapshot.rows.filter { $0.phase == .available && $0.actions.contains(.play) }.map(\.title)
        XCTAssertEqual(playActions, ["Playable"], "Play is offered only for the item that has it")
    }
    func testWithNothingKeptTheSectionSaysSoHonestly() async throws {
        let frames = Frames()
        let m = try await model([])
        let window = try await host(DownloadedItemsSection(model: m).frame(width: 600).onPreferenceChange(DownloadedRowFrames.self) { frames.rows = $0 }, width: 640, height: 300); defer { window.orderOut(nil) }
        XCTAssertTrue(frames.rows.isEmpty, "no rows, and no row is invented")
        XCTAssertTrue(m.snapshot.rows.isEmpty)
    }
    func testTheLibraryShowsTheSectionOnlyOnRequestAndItDoesNotOverlapTheChips() async throws {
        let accounts = LocalAccountBootstrap()
        let kept = row("Kept take", play: true), second = row("Second take", play: true)
        let m = try await model([kept, second])
        let surface = accounts.library; surface.downloads = m
        let frames = Frames()
        func library() -> some View {
            LibraryView(surface: surface, navigator: CatalogNavigator()).frame(width: 900, height: 700)
                .onPreferenceChange(LibraryRegionFrames.self) { frames.values = $0 }.onPreferenceChange(DownloadedRowFrames.self) { frames.rows = $0 }
        }
        surface.showsDownloadedOnly = false
        var window = try await host(library()); 
        XCTAssertNotNil(frames.values["chips"], "the chips are laid out"); XCTAssertNil(frames.values["downloaded"]); XCTAssertTrue(frames.rows.isEmpty, "by default the Library shows its own collection")
        window.orderOut(nil)
        frames.values = [:]; frames.rows = [:]
        surface.showsDownloadedOnly = true
        window = try await host(library()); defer { window.orderOut(nil) }
        let chips = try XCTUnwrap(frames.values["chips"]), section = try XCTUnwrap(frames.values["downloaded"], "the Downloaded-only section is placed in the Library")
        XCTAssertLessThanOrEqual(chips.maxY, section.minY + 0.5, "the section sits below the chips and does not overlap them")
        XCTAssertEqual(Set(frames.rows.keys), [kept.id.uuidString, second.id.uuidString])
        for r in frames.rows.values { XCTAssertGreaterThanOrEqual(r.minY, -0.5); XCTAssertLessThanOrEqual(r.maxX, section.width + 0.5) }
        let ordered = frames.rows.values.sorted { $0.minY < $1.minY }
        for (a, b) in zip(ordered, ordered.dropFirst()) { XCTAssertLessThanOrEqual(a.maxY, b.minY + 0.5) }
        // Without a downloads model the Library offers no such section at all.
        surface.downloads = nil; surface.showsDownloadedOnly = true
        frames.values = [:]; frames.rows = [:]
        let bare = try await host(library()); defer { bare.orderOut(nil) }
        XCTAssertNil(frames.values["downloaded"], "no downloads model, no section")
    }
}
