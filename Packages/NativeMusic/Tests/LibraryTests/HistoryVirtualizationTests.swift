import AccountSession
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Features

/// The History page's rows, flattened for its lazy stack: one row per heading and per entry, in the service's order.
@Suite @MainActor struct HistoryRowsTests {
    private func entries(_ sections: [String?]) async throws -> [LibraryEntry] {
        let script = LibraryScript()
        var shelves: [MusicShelf] = []
        for (index, title) in sections.enumerated() { shelves.append(MusicShelf(key: "s\(index)", title: title, layout: .list, items: [item("Row \(index) A"), item("Row \(index) B")])) }
        var acc = MusicParseAccounting(); acc.items = sections.count * 2; acc.classified = sections.count * 2
        await script.setPage(LibrarySource.history.browseID, MusicBrowsePage(shelves: shelves, accounting: acc))
        let model = makeCollection(.history, script: script)
        await model.load()
        return model.entries
    }
    @Test func eachDayGetsOneHeadingAboveItsRowsAndEveryRowAppearsOnceInOrder() async throws {
        let entries = try await entries(["Today", "Yesterday", "Today"])
        let rows = HistoryRow.rows(entries)
        let shown: [String] = rows.map { if case .heading(let title) = $0.content { "# " + title } else if case .entry(let entry) = $0.content { entry.id } else { "" } }
        #expect(shown == ["# Today", entries[0].id, entries[1].id, "# Yesterday", entries[2].id, entries[3].id, "# Today", entries[4].id, entries[5].id])
        #expect(Set(rows.map(\.id)).count == rows.count, "a repeated heading (another Today) is told apart by its place")
        #expect(rows.compactMap { if case .entry(let entry) = $0.content { entry } else { nil } } == entries, "every row once, in the service's order")
    }
    @Test func theGapsKeepTheDaysApartAndTheRowsOfADayTogether() async throws {
        let rows = HistoryRow.rows(try await entries(["Today", nil]))
        let gaps = rows.map(\.gap)
        #expect(gaps.count == 5)
        #expect(gaps[0] > gaps[3] && gaps[3] > gaps[1], "a heading opens a day with the most space; a day the service gave no heading opens with less")
        #expect(gaps[1] == gaps[2] && gaps[2] == gaps[4] && gaps[1] > 0, "the rows of a day sit together, under their heading too")
        #expect(HistoryRow.rows([]).isEmpty)
    }
}

private final class HistoryFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The History page is virtualized: hosted in a real (invisible, offscreen) window with 1,500 rows of history, it builds only the rows on screen, and it
/// reads the next page only when the end of the list is reached. Before the rows were direct children of the page's lazy stack, every row was built at
/// once and the load-more trigger, built with them, read the next page before anything had scrolled.
///
/// A row is counted when it is built: each History row asks the surface what can be played (`LibrarySurface.offers`, which reads the playback state)
/// once per build, so the playback closure counts row builds. (SwiftUI publishes no accessibility tree to an in-process caller, so the rows cannot be
/// read from there.)
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"))
@MainActor struct HistoryVirtualizationTests {
    static let days = ["Today", "Yesterday", "This week"]
    static let perDay = 500

    @Test func historyBuildsOnlyTheRowsOnScreenAndReadsTheNextPageOnlyAtTheEnd() async throws {
        let script = LibraryScript()
        let shelves = Self.days.enumerated().map { index, title in
            MusicShelf(key: "day\(index)", title: title, layout: .list, items: (0..<Self.perDay).map { item("Song \(index * Self.perDay + $0)") },
                       continuation: index == Self.days.count - 1 ? "next" : nil)
        }
        var acc = MusicParseAccounting(); acc.sections = 1; acc.shelves = shelves.count; acc.items = Self.days.count * Self.perDay; acc.classified = acc.items
        await script.setPage(LibrarySource.history.browseID, MusicBrowsePage(shelves: shelves, accounting: acc))
        await script.setToken("next", continuationOf([item("Later")]))
        let remote = makeCollection(.history, script: script)
        await remote.load()
        let total = Self.days.count * Self.perDay
        #expect(remote.entries.count == total && remote.hasMore)
        let builds = Box(0)
        let surface = LibrarySurface(models: [:], history: HistoryModel(remote: remote, store: nil, policy: nil, accountKey: { nil }),
                                     ledger: LibraryWriteLedger(writer: { _ in throw MusicSessionError.policy }), performer: nil,
                                     playback: { builds.value += 1; return .available })

        let controller = NSHostingController(rootView: HistoryView(surface: surface, navigator: CatalogNavigator()))
        let frame = CGRect(x: -24000, y: -24000, width: 900, height: 700)
        let window = HistoryFixtureWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller; window.alphaValue = 0; window.ignoresMouseEvents = true; window.orderFrontRegardless()
        window.setFrame(frame, display: true)   // invisible host setup: nothing is shown or keyed
        defer { window.orderOut(nil); window.contentViewController = nil }
        func settle(_ rounds: Int) async throws { for _ in 0..<rounds { controller.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) } }
        try await settle(30)

        let onScreen = builds.value
        print("HISTORY_VIRTUALIZATION builds on open=\(onScreen) of \(total) rows")
        #expect(onScreen > 0, "the rows on screen are built")
        #expect(onScreen < 100, "\(onScreen) row builds for \(total) rows; only the rows on screen (and a margin) should be built")
        #expect(await script.tokenCalls.isEmpty, "nothing has scrolled to the end, so no further page is read")

        // Jump to the end: the rows there are built, the ones in between are not, and reaching the end reads the next page (once).
        let scroll = try #require(Self.scrollViews(in: controller.view).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        for _ in 0..<60 where await script.tokenCalls.isEmpty {
            let height = scroll.documentView?.frame.height ?? 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(3)
        }
        try await settle(10)
        print("HISTORY_VIRTUALIZATION builds after the end=\(builds.value) tokens=\(await script.tokenCalls)")
        #expect(await script.tokenCalls == ["next"], "reaching the end reads the next page")
        #expect(builds.value > onScreen, "the rows at the end are built when they come on screen")
        #expect(builds.value < total / 4, "\(builds.value) row builds after jumping to the end of \(total) rows; the rows skipped over should never be built")
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews) }
}
