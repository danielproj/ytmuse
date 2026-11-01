import Testing
import Foundation
@testable import AppShell
import DesignSystem

struct NavigationTests {
    @Test func backForwardRestoresCompleteEntryAndBranches() throws {
        var session = BrowserSession()
        session.current.query = "Björk 東京"
        session.current.selection = ["occurrence-1", "occurrence-2"]
        session.current.filter = "Downloaded only"; session.current.scrollOffset = 1437.5; session.current.page = 4
        let home = session.current
        session.open(.library)
        session.current.query = "独立"; let library = session.current
        let item = try NativeItemRoute(kind: .album, identifier: "album-42")
        session.open(.library, item: item)
        #expect(session.current.item == item)
        session.back(); #expect(session.current == library)
        session.back(); #expect(session.current == home)
        session.forward(); #expect(session.current == library)
        session.open(.downloads); #expect(!session.canForward)
        #expect(session.entries.count == 3)
    }
    @Test @MainActor func independentWindowsAndRestoration() throws {
        let first = BrowserNavigation(), second = BrowserNavigation()
        first.open(.search); first.session.current.query = "first"
        second.open(.downloads); second.session.current.filter = "Downloaded only"
        #expect(first.session.current.destination == .search)
        #expect(second.session.current.query.isEmpty)
        #expect(first.session.windowID != second.session.windowID)
        let restored = try BrowserSession.restore(first.session.encoded())
        #expect(restored == first.session)
        #expect(throws: (any Error).self) { try BrowserSession.restore(Data(repeating: 0, count: 16 * 1024 * 1024 + 1)) }
        var large = first.session
        large.current.selection = Set((0..<50_000).map { "occurrence-\($0)" })
        #expect(try BrowserSession.restore(large.encoded()).current.selection.count == 50_000)
        var invalid = first.session; invalid.current.scrollOffset = .nan
        #expect(throws: (any Error).self) { try BrowserSession.restore(invalid.encoded()) }
    }
    @Test func everyItemKindHasMeaningfulTypedRouteAndInvalidInputRefused() throws {
        for kind in [NativeItemKind.song, .album, .artist, .playlist, .podcast, .episode, .video, .sample, .tuner, .recap, .badge] {
            var session = BrowserSession(); let item = try NativeItemRoute(kind: kind, identifier: "public_42")
            session.open(.library, item: item)
            #expect(try BrowserSession.restore(session.encoded()).current.item == item)
        }
        for invalid in ["", "../../private", "file:secret", "x?play=1", String(repeating: "x", count: 257)] {
            #expect(throws: (any Error).self) { try NativeItemRoute(kind: .song, identifier: invalid) }
        }
    }
    @Test func linksOnlyNavigateToValidatedNativeItems() throws {
        // W26: identifiers must have the shape of their kind (a video id is 11 URL-safe characters, a playlist id has a playlist prefix), so the
        // old placeholders ("public_42", "PL42", "album_1") are no longer links. The full corpus is in `LinkPolicyTests` (T26.2).
        #expect(try NativeItemRoute.parse(URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")!).kind == .song)
        #expect(try NativeItemRoute.parse(URL(string: "https://music.youtube.com/playlist?list=PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")!).identifier == "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN")
        #expect(try NativeItemRoute.parse(URL(string: "ytmuse://album/MPREb_AbCdEfGhIjK")!).kind == .album)
        for url in ["https://evil.example/watch?v=dQw4w9WgXcQ", "http://music.youtube.com/watch?v=dQw4w9WgXcQ", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&play=1", "ytmuse://song/../../private", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&v=dQw4w9WgXcR", "https://music.youtube.com:443/watch?v=dQw4w9WgXcQ",
                    "https://music.youtube.com/watch?v=public_42", "https://music.youtube.com/playlist?list=PL42", "ytmuse://album/album_1"] {
            #expect(throws: (any Error).self) { try NativeItemRoute.parse(URL(string: url)!) }
        }
    }
    @Test func boundedHistoryAndPageWindowPreservesOccurrences() {
        struct Row: Identifiable, Sendable { let id: Int; let media: String }
        var window = BrowserPageWindow<Row>(limit: 80)
        window.replace((0..<80).map { Row(id: $0, media: "duplicate") })
        window.append((80..<160).map { Row(id: $0, media: "duplicate") })
        #expect(window.rows.count == 80 && window.rows.first?.id == 80)
        #expect(Set(window.rows.map(\.id)).count == 80)
        var session = BrowserSession()
        for index in 0..<250 { session.open(index.isMultiple(of: 2) ? .library : .downloads) }
        #expect(session.entries.count == 100 && session.index == 99)
        for _ in 0..<150 { session.back() }; #expect(!session.canBack)
    }
    @Test @MainActor func onePlaybackUISamplerIsLeasedByVisibleWindowsOnly() {
        let model = PlaybackModel(controlledAudioTest: true)
        let a = UUID(), b = UUID()
        #expect(!model.isObservingUI)
        model.observe(a, visible: true); model.observe(b, visible: true)
        #expect(model.isObservingUI && model.visibleUIObserverCount == 2)
        model.observe(a, visible: false)
        #expect(model.isObservingUI && model.visibleUIObserverCount == 1)
        model.observe(b, visible: false)
        #expect(!model.isObservingUI && model.visibleUIObserverCount == 0)
        #expect(model.session == nil, "UI observation never creates a player or starts audio")
    }
    @Test func motionTokensAndAdaptiveBreakpoints() {
        let ranges: [MusicMotion: ClosedRange<Double>] = [.hoverPress: 0.08...0.14, .navigation: 0.18...0.24, .artworkExpansion: 0.28...0.36, .artworkColor: 0.6...0.9, .lyrics: 0.18...0.26, .miniPlayer: 0.2...0.28, .loading: 0.1...0.16]
        for (token, range) in ranges { #expect(range.contains(token.seconds)) }
        #expect(MusicMotion.queueReorder.seconds == 0)
        for token in MusicMotion.allCases { #expect(token.duration(reduceMotion: false, lowPower: false, visible: false) == 0) }
        #expect(MusicMotion.artworkExpansion.duration(reduceMotion: true, lowPower: false, visible: true) == 0)
        #expect(MusicMotion.artworkColor.duration(reduceMotion: false, lowPower: true, visible: true) == 0)
        #expect(BrowserLayout(width: 1240).showsTrailing)
        #expect(!BrowserLayout(width: 840).showsTrailing && BrowserLayout(width: 840).compactPlayer)
        #expect(BrowserLayout.sidebar == 200...280 && BrowserLayout.trailing == 300...420)
    }
}
