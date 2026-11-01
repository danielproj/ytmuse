import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
import WidgetKit
@testable import WidgetShared

/// T25.1 / T25.2 (MAC06): what the small and medium widget draw is decided from the cached snapshot alone, locked / signed-out / unknown draw a redacted view with
/// no title, the provider reads the cache and schedules nothing, and the real views render. This is the extension's actual view and timeline code; an INSTALLED
/// widget's behaviour in the system is W41.
@Suite @MainActor struct WidgetDisplayTests {
    private let titles = ["Synthetic Song", "Private Playlist Name", "Synthetic Artist"]

    @Test func everyReadResultMapsToOneDisplayAndAnythingUnknownIsRedacted() {
        #expect(WidgetDisplay(.missing) == .redacted(.unknown))
        #expect(WidgetDisplay(.unreadable) == .redacted(.unknown))
        #expect(WidgetDisplay(.snapshot(.redacted(.signedOut))) == .redacted(.signedOut))
        #expect(WidgetDisplay(.snapshot(.redacted(.locked))) == .redacted(.locked))
        #expect(WidgetDisplay(.snapshot(WidgetSnapshot(state: .idle, scope: WidgetFixtures.scope))) == .idle(WidgetFixtures.scope))
        guard case .item(let item) = WidgetDisplay(.snapshot(WidgetFixtures.playing())) else { Issue.record("a playing snapshot is an item"); return }
        #expect(item.title == "Synthetic Song" && item.artist == "Synthetic Artist" && item.playing && !item.advertisement && item.scope == WidgetFixtures.scope)
        guard case .item(let paused) = WidgetDisplay(.snapshot(WidgetSnapshot(state: .paused, title: "P", scope: WidgetFixtures.scope))) else { Issue.record("paused"); return }
        #expect(!paused.playing)
    }
    @Test func lockedSignedOutAndUnknownDrawNoTitleNoPictureAndNoButton() {
        for display in [WidgetDisplay.redacted(.locked), .redacted(.signedOut), .redacted(.unknown)] {
            for family in [WidgetContent.Family.small, .medium] {
                let content = WidgetContent.make(display, family: family)
                #expect(content.controls.isEmpty && !content.hasArtwork && content.scope == nil, "\(display) \(family)")
                for title in titles { #expect(!content.texts.contains { $0.contains(title) }) }
                #expect(content.texts.first == "YTMuse", "only the app's own name, then one sentence about what to do")
            }
        }
        #expect(WidgetContent.make(.redacted(.locked), family: .small).texts.contains { $0.localizedCaseInsensitiveContains("locked") })
    }
    @Test func theSystemsPrivacyRedactionTurnsAnyDisplayIntoTheLockedOne() {
        let item = WidgetDisplay(.snapshot(WidgetFixtures.playing()))
        #expect(item.applying(privacyRedaction: false) == item)
        #expect(item.applying(privacyRedaction: true) == .redacted(.locked), "a privacy-redacted surface never shows the title")
        #expect(WidgetDisplay.placeholder.applying(privacyRedaction: true) == .redacted(.locked))
    }
    @Test func anAdvertisementShowsTheHonestStateAndNotTheSongItInterrupts() {
        let snapshot = WidgetSnapshot(state: .advertisement, capabilities: WidgetCapabilities(playPause: true), scope: WidgetFixtures.scope)
        let content = WidgetContent.make(WidgetDisplay(.snapshot(snapshot)), family: .medium)
        #expect(content.texts == [String(localized: "Advertisement")] && !content.hasArtwork)
        #expect(content.controls.map(\.enabled) == [false, true, false], "an ad cannot be skipped: only play/pause is on")
    }
    @Test func smallShowsOneButtonMediumThreeAndEachFollowsTheAppsCapabilities() {
        let all = WidgetDisplay(.snapshot(WidgetFixtures.playing()))
        let small = WidgetContent.make(all, family: .small), medium = WidgetContent.make(all, family: .medium)
        #expect(small.controls.count == 1 && small.controls[0].button == .playPause(playing: true) && small.controls[0].label == String(localized: "Pause"))
        #expect(medium.controls.map(\.button) == [.previous, .playPause(playing: true), .next])
        let some = WidgetDisplay(.snapshot(WidgetFixtures.playing(caps: WidgetCapabilities(playPause: true, next: false, previous: false))))
        #expect(WidgetContent.make(some, family: .medium).controls.map(\.enabled) == [false, true, false], "next and previous are off when the app says so")
        let none = WidgetDisplay(.snapshot(WidgetSnapshot(state: .paused, title: "T", capabilities: .none, scope: WidgetFixtures.scope)))
        #expect(WidgetContent.make(none, family: .medium).controls.allSatisfy { !$0.enabled }, "a restored last item has no live buttons")
        let paused = WidgetDisplay(.snapshot(WidgetSnapshot(state: .paused, title: "T", capabilities: WidgetFixtures.allButtons, scope: WidgetFixtures.scope)))
        #expect(WidgetContent.make(paused, family: .small).controls[0].label == String(localized: "Play"))
    }
    @Test func theGalleryPlaceholderIsFixedSampleTextAndNeverThePersonsMusic() {
        let content = WidgetContent.make(.placeholder, family: .medium)
        #expect(content.texts == [String(localized: "Song title"), String(localized: "Artist")] && content.controls.allSatisfy { !$0.enabled } && content.scope == nil)
    }

    // MARK: Provider

    @Test func theProviderReadsTheCacheOnceAndSchedulesNoRefresh() throws {
        let counter = Mutex(0)
        let dir = Scratch.make(); defer { Scratch.remove(dir) }
        let store = WidgetSnapshotStore(directory: dir)
        try store.write(WidgetFixtures.playing("First"))
        let provider = NowPlayingTimelineProvider(read: { counter.withLock { $0 += 1 }; return store.read() })
        let timeline = provider.timeline()
        #expect(counter.withLock { $0 } == 1 && timeline.entries.count == 1, "one read, one entry")
        guard case .never = timeline.policy else { Issue.record("the timeline must never schedule its own reload, got \(timeline.policy)"); return }
        guard case .item(let item) = timeline.entries[0].display else { Issue.record("an item"); return }
        #expect(item.title == "First")
        try store.write(WidgetFixtures.playing("Second"))
        guard case .item(let later) = provider.timeline().entries[0].display else { Issue.record("an item"); return }
        #expect(later.title == "Second", "a reload reads the new cache; nothing was cached by the provider")
    }
    @Test func aDeletedOrUnreadableCacheIsTheRedactedViewNotAnError() throws {
        let dir = Scratch.make(); defer { Scratch.remove(dir) }
        let store = WidgetSnapshotStore(directory: dir)
        try store.write(WidgetFixtures.playing())
        try store.delete()
        #expect(NowPlayingTimelineProvider(read: { store.read() }).timeline().entries[0].display == .redacted(.unknown))
        try Data("{\"title\":\"leak\"}".utf8).write(to: store.fileURL)
        #expect(NowPlayingTimelineProvider(read: { store.read() }).timeline().entries[0].display == .redacted(.unknown))
        #expect(NowPlayingTimelineProvider(read: { .missing }).entry().display == .redacted(.unknown))
    }
    @Test func theWidgetOffersSmallAndMediumOnly() {
        #expect(NowPlayingWidgetConfiguration.families == [.systemSmall, .systemMedium])
        #expect(WidgetIdentity.widgetKind == "local.native-music.widget.now-playing")
    }

    // MARK: The real views

    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 1
        return renderer.cgImage
    }
    @Test func theSmallAndMediumViewsRenderEveryStateAtTheirSizes() throws {
        let artwork = WidgetFixtures.picture()
        let withPicture = WidgetSnapshot(state: .playing, title: "Synthetic Song", artist: "Synthetic Artist", artwork: WidgetArtwork.thumbnail(from: artwork), capabilities: WidgetFixtures.allButtons, scope: WidgetFixtures.scope)
        let displays: [WidgetDisplay] = [.placeholder, .redacted(.locked), .redacted(.signedOut), .redacted(.unknown), .idle(WidgetFixtures.scope),
                                         WidgetDisplay(.snapshot(WidgetFixtures.playing())), WidgetDisplay(.snapshot(withPicture)),
                                         WidgetDisplay(.snapshot(WidgetSnapshot(state: .advertisement, capabilities: WidgetCapabilities(playPause: true), scope: WidgetFixtures.scope)))]
        for display in displays {
            let small = try #require(render(SmallNowPlayingView(display: display), width: 164, height: 164), "small \(display)")
            let medium = try #require(render(MediumNowPlayingView(display: display), width: 344, height: 164), "medium \(display)")
            #expect(small.width == 164 && small.height == 164 && medium.width == 344 && medium.height == 164)
        }
    }
    @Test func aRenderedItemDiffersFromTheRedactedOneAndTheRedactedOnesDoNotDependOnTheCache() throws {
        func pixels(_ display: WidgetDisplay) throws -> Data {
            let image = try #require(render(MediumNowPlayingView(display: display), width: 344, height: 164))
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
        }
        let item = try pixels(WidgetDisplay(.snapshot(WidgetFixtures.playing())))
        let locked = try pixels(.redacted(.locked))
        #expect(item != locked, "the control: the renderer does draw different things for different states")
        #expect(try pixels(.redacted(.locked)) == locked, "the locked view is the same picture whatever was cached")
    }
}
