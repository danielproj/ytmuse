import AccountSession
import Foundation
import Testing
@testable import AppShell

/// PERF04: the synthetic dataset's shape, determinism and gating. These are the guard tests the brief asks for: the dataset exists only behind the
/// development flags AND isolation, is generated in memory (no store is opened by any function tested here), and is labelled synthetic.
@Suite("PERF04 synthetic dataset")
struct DatasetTests {
    private let isolatedEnvironment: [String: String] = ["YTMUSE_UI_TEST_ISOLATED": "1", "YTMUSE_UI_DEVELOPMENT_DATA": "1", "YTMUSE_UI_DEVELOPMENT_LIBRARY": "1", "YTMUSE_UI_DEVELOPMENT_PERF": "1"]

    @Test func gateNeedsEveryFlagAndIsolation() {
        #expect(DevelopmentPerformance.isEnabled(isolatedEnvironment))
        // (YTMUSE_UI_TEST_ISOLATED itself is not a required flag: a Debug launch is isolated unless it explicitly opts into the real stores, tested below.)
        for missing in isolatedEnvironment.keys where missing != "YTMUSE_UI_TEST_ISOLATED" {
            var environment = isolatedEnvironment; environment[missing] = nil
            #expect(!DevelopmentPerformance.isEnabled(environment), "without \(missing) the dataset must not exist")
        }
        // The perf flag alone, or with the real-stores opt-in, never enables it.
        #expect(!DevelopmentPerformance.isEnabled(["YTMUSE_UI_DEVELOPMENT_PERF": "1"]))
        var real = isolatedEnvironment; real["YTMUSE_UI_TEST_ISOLATED"] = nil; real[IsolatedQAStorage.realStoresKey] = "1"   // only ever handed to the pure gate function, never to a launch
        #expect(!DevelopmentPerformance.isEnabled(real), "a launch that opted into the real stores never gets the synthetic dataset")
        // Values other than "1" are not flags.
        var loose = isolatedEnvironment; loose["YTMUSE_UI_DEVELOPMENT_PERF"] = "true"
        #expect(!DevelopmentPerformance.isEnabled(loose))
    }
    @Test func recordingNeedsItsOwnFlagOnTopOfTheGate() {
        var environment = isolatedEnvironment
        #expect(!DevelopmentPerformance.recording(environment))
        environment["YTMUSE_PERF_RECORD"] = "1"
        #expect(DevelopmentPerformance.recording(environment))
        environment["YTMUSE_UI_DEVELOPMENT_PERF"] = nil
        #expect(!DevelopmentPerformance.recording(environment), "the record flag alone does nothing")
    }
    @Test func theScreensCanLabelItSynthetic() {
        #expect(DevelopmentPerformance.label.contains("Synthetic"))
        #expect(DevelopmentPerformance.label.contains("Not YouTube Music"))
    }
    @Test func songsAreFiftyThousandInPagesWithRepeatedOccurrences() throws {
        var items: [MusicCatalogItem] = [], index = 0, pages = 0
        while true {
            let page = DevelopmentPerformance.songsPage(index)
            items += page.items; pages += 1
            guard let next = page.next else { break }
            index = try #require(Int(next.dropFirst(DevelopmentPerformance.songsPrefix.count)))
            try #require(pages < 1_000, "paging must end")
        }
        #expect(items.count == 50_000)
        #expect(pages == 500)
        // Every 40th row is a second occurrence of the row before it: 1,250 repeats, each with the same video id as its neighbour.
        let repeats = items.indices.filter { $0 % 40 == 39 }
        #expect(repeats.count == 1_250)
        for n in repeats { #expect(items[n].videoID == items[n - 1].videoID) }
        #expect(Set(items.compactMap(\.videoID)).count == 50_000 - 1_250)
        // Mixed artwork sizes: all six source edges are in use, and every thumbnail is a synthetic URL (no real host).
        let edges = Set(items.flatMap(\.thumbnails).map(\.width))
        #expect(edges.isSuperset(of: Set(DevelopmentPerformance.artworkEdges)))
        #expect(items.flatMap(\.thumbnails).allSatisfy { $0.url.host == "synthetic.invalid" })
    }
    @Test func theDatasetIsDeterministic() {
        #expect(DevelopmentPerformance.songsPage(137).items == DevelopmentPerformance.songsPage(137).items)
        #expect(DevelopmentPerformance.playlist(5) == DevelopmentPerformance.playlist(5))
        #expect(DevelopmentPerformance.bigPlaylistRows(count: 500).map(\.setVideoID) == DevelopmentPerformance.bigPlaylistRows(count: 500).map(\.setVideoID))
    }
    @Test func playlistsAreOneThousandAndTheBigOneHasTenThousandEntries() throws {
        var count = 0, index = 0
        while true {
            let page = DevelopmentPerformance.playlistsPage(index)
            #expect(page.items.allSatisfy { $0.kind == .playlist })
            count += page.items.count
            guard let next = page.next else { break }
            index = try #require(Int(next.dropFirst(DevelopmentPerformance.playlistsPrefix.count)))
        }
        #expect(count == 1_000)
        let rows = DevelopmentPerformance.bigPlaylistRows()
        #expect(rows.count == 10_000)
        #expect(Set(rows.map(\.setVideoID)).count == 10_000, "occurrence ids are unique even where the song repeats")
        #expect(rows.count - Set(rows.map(\.videoID)).count == 200, "every 50th row repeats the song before it")
        #expect(rows.allSatisfy { MusicPlaylistRequest.isOccurrenceID($0.setVideoID) })
    }
    @Test func continuationsAnswerOnlyTheirOwnTokens() {
        #expect(DevelopmentPerformance.continuation("devsongs2") == nil)
        #expect(DevelopmentPerformance.continuation(DevelopmentPerformance.songsPrefix + "499")?.continuation == nil)
        #expect(DevelopmentPerformance.continuation(DevelopmentPerformance.songsPrefix + "498")?.continuation == DevelopmentPerformance.songsPrefix + "499")
        #expect(DevelopmentPerformance.continuation(DevelopmentPerformance.songsPrefix + "-1") == nil)
        #expect(DevelopmentPerformance.continuation(DevelopmentPerformance.songsPrefix + "x") == nil)
    }
    @Test func artworkBytesComeFromTheGeneratorAndOnlyForSyntheticURLs() async throws {
        for edge in DevelopmentPerformance.artworkEdges.prefix(3) {
            let data = try await DevelopmentPerformance.artwork(for: DevelopmentPerformance.artworkURL(7, edge: edge))
            #expect(data.count > 1_000)
            #expect(data.prefix(2) == Data([0xFF, 0xD8]), "a JPEG")
        }
        // Another host, or an edge outside the six, is refused rather than fetched.
        await #expect(throws: (any Error).self) { _ = try await DevelopmentPerformance.artwork(for: URL(string: "https://i.ytimg.com/perf-art/60/1")!) }
        await #expect(throws: (any Error).self) { _ = try await DevelopmentPerformance.artwork(for: URL(string: "https://synthetic.invalid/perf-art/61/1")!) }
    }

    // MARK: Where the interval log may be written

    private func recordingEnvironment(_ directory: String?) -> [String: String] {
        var environment = isolatedEnvironment; environment["YTMUSE_PERF_RECORD"] = "1"
        if let directory { environment["YTMUSE_PERF_DIR"] = directory }
        return environment
    }
    @Test func theLogDirectoryMustBeAFreshPerfFolderDirectlyInsideTheTemporaryDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory
        let good = temporary.appendingPathComponent("ytmuse-perf-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: good) }     // a directory this test made, under the temporary directory, named by its own UUID
        #expect(DevelopmentPerformance.recordingDirectory(recordingEnvironment(good.path))?.resolvingSymlinksInPath().path == good.resolvingSymlinksInPath().path)
        // Not recording, or not a recording launch: nothing.
        #expect(DevelopmentPerformance.recordingDirectory(isolatedEnvironment.merging(["YTMUSE_PERF_DIR": good.path]) { $1 }) == nil)
        #expect(DevelopmentPerformance.recordingDirectory(recordingEnvironment(nil)) == nil)
        var withoutGate = recordingEnvironment(good.path); withoutGate["YTMUSE_UI_DEVELOPMENT_LIBRARY"] = nil
        #expect(DevelopmentPerformance.recordingDirectory(withoutGate) == nil)
        // Wrong name, wrong parent, relative, traversal, a file, a missing folder: refused. None of these paths is created or written by this test.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for bad in [temporary.appendingPathComponent("not-a-perf-dir").path, home + "/Library/Application Support/ytmuse-perf-x", home + "/ytmuse-perf-x", "ytmuse-perf-x",
                    good.path + "/../ytmuse-perf-up", temporary.appendingPathComponent("ytmuse-perf-missing-" + UUID().uuidString).path, "/", ""] {
            #expect(DevelopmentPerformance.recordingDirectory(recordingEnvironment(bad)) == nil, "\(bad)")
        }
        let nested = good.appendingPathComponent("ytmuse-perf-nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(DevelopmentPerformance.recordingDirectory(recordingEnvironment(nested.path)) == nil, "only a direct child of the temporary directory")
        // A file with the right name, and a symbolic link with the right name pointing somewhere else, are not folders it may use.
        let file = temporary.appendingPathComponent("ytmuse-perf-file-" + UUID().uuidString)
        try Data().write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        #expect(DevelopmentPerformance.recordingDirectory(recordingEnvironment(file.path)) == nil)
        let link = temporary.appendingPathComponent("ytmuse-perf-link-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: good); defer { try? FileManager.default.removeItem(at: link) }
        #expect(DevelopmentPerformance.recordingDirectory(recordingEnvironment(link.path)) == nil, "a symbolic link is refused")
    }
}
