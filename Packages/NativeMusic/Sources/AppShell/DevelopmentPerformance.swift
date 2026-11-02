#if DEBUG
import AccountSession
import CoreGraphics
import Diagnostics
import Features
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// PERF04 (W44-prep). Debug-only, deterministic, labelled SYNTHETIC stress data for the isolated performance runs: 50,000 library songs (every 40th row
/// a repeated occurrence of the row before it), 1,000 playlists, one 10,000-entry playlist, a 5,000-item queue and artwork in six different source sizes.
/// It is a stress fixture, not a capture of the service and not an assertion about service limits or the account holder's library.
///
/// It exists only when `YTMUSE_UI_DEVELOPMENT_PERF=1` is set on top of the development-library gate (`YTMUSE_UI_DEVELOPMENT_DATA=1`,
/// `YTMUSE_UI_DEVELOPMENT_LIBRARY=1`) AND the launch is isolated (`DevelopmentSearch.isEnabled` requires `IsolatedQAStorage.requested`). Everything is
/// generated in memory behind the same reader seams the development library already uses: it writes no store, performs no request and touches no
/// Keychain item. Release builds do not contain this file. The only file it can ask for is the measurement log, and only inside the isolated root.
enum DevelopmentPerformance {
    static let flag = "YTMUSE_UI_DEVELOPMENT_PERF"
    /// The recorder's directory comes from `YTMUSE_PERF_DIR`, which `scripts/perf-run.sh` creates (mode 700) under the user's temporary directory.
    static let recordFlag = "YTMUSE_PERF_RECORD", directoryKey = "YTMUSE_PERF_DIR", directoryPrefix = "ytmuse-perf-"
    static let recordFileName = "performance-intervals.jsonl"

    static var enabled: Bool { isEnabled(ProcessInfo.processInfo.environment) }
    static func isEnabled(_ environment: [String: String]) -> Bool {
        DevelopmentLibrary.isEnabled(environment) && environment[flag] == "1"
    }
    static func recording(_ environment: [String: String]) -> Bool {
        isEnabled(environment) && environment[recordFlag] == "1"
    }
    /// The directory the interval log may be written in, or nil. It must be an existing directory (not a symbolic link) directly inside the temporary
    /// directory, named `ytmuse-perf-…`, and the launch must be a recording one: the app can then add one file to a folder the script made for it and
    /// can name nothing else, so a mistaken variable can never point it at a real store, a home folder or a library.
    static func recordingDirectory(_ environment: [String: String], temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL? {
        guard recording(environment), let path = environment[directoryKey], path.hasPrefix("/"), !path.contains("..") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.lastPathComponent.hasPrefix(directoryPrefix),
              url.deletingLastPathComponent().resolvingSymlinksInPath().path == temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path else { return nil }
        var status = stat()
        guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == getuid() else { return nil }
        return url
    }
    /// Starts the interval recorder and the stall monitor for an isolated performance launch.
    @MainActor static func startRecording(environment: [String: String]) {
        guard IsolatedQAStorage.requested(environment), let directory = recordingDirectory(environment) else { return }
        try? PerformanceRecorder.shared.install(file: directory.appendingPathComponent(recordFileName))
        PerformanceRecorder.shared.markSession(test: String((environment["YTMUSE_PERF_TEST"] ?? "unknown").prefix(64)))
        MainThreadStallMonitor.shared.start()
    }

    /// The dataset's size. `standard` is PERF04; tests build a small one to check the generator without 50,000 rows.
    struct Scale: Sendable, Equatable {
        var songs = 50_000, playlists = 1_000, bigPlaylistEntries = 10_000, queueItems = 5_000, pageSize = 100, repeatEvery = 40
        static let standard = Scale()
    }
    static let label = "Synthetic performance data · Not YouTube Music"
    static let songsPrefix = "perfsongs:", playlistsPrefix = "perfplaylists:"
    static let bigPlaylistID = "PLperfbig10000000001"
    static let syntheticHost = "synthetic.invalid"      // a reserved top-level domain: it can never resolve, and nothing here fetches it
    static let artworkEdges = [60, 120, 226, 336, 544, 1200]

    // MARK: Rows

    /// The row `n` (0-based) of the library songs. Row n with n % repeatEvery == repeatEvery - 1 is the same song as row n-1 (a repeated occurrence,
    /// kept as its own row, as in a played-twice history).
    static func song(_ n: Int, scale: Scale = .standard) -> MusicCatalogItem {
        let base = n % scale.repeatEvery == scale.repeatEvery - 1 ? n - 1 : n
        let video = "perf" + String(format: "%06d", base)
        let artist = "Synthetic Artist \(base % 997)"
        let edge = artworkEdges[base % artworkEdges.count]
        return MusicCatalogItem(kind: .song, title: title(base), details: [artist, "Synthetic Album \(base / 12)"], videoID: video,
                                thumbnails: [MusicThumbnail(url: artworkURL(base, edge: max(60, edge / 2)), width: max(60, edge / 2), height: max(60, edge / 2)),
                                             MusicThumbnail(url: artworkURL(base, edge: edge), width: edge, height: edge)],
                                links: [MusicLink(kind: .artist, title: artist, browseID: "UCperfartist\(base % 997)")],
                                durationText: "\(2 + base % 5):\(String(format: "%02d", base % 60))")
    }
    /// Titles vary in length and script so that sorting and filtering do real work (accents, mixed case, digits).
    static func title(_ n: Int) -> String {
        let words = ["Café", "Noche", "Ångström", "Zeta", "Ünder", "Sol", "mar", "Ocean", "Été", "Blue"]
        return "\(words[n % words.count]) \(words[(n / 10) % words.count]) \(n)" + (n % 7 == 0 ? " (Live at the Synthetic Hall, extended version)" : "")
    }
    static func artworkURL(_ n: Int, edge: Int) -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = syntheticHost; components.path = "/perf-art/\(edge)/\(n)"
        return components.url!
    }
    static func songsPage(_ index: Int, scale: Scale = .standard) -> (items: [MusicCatalogItem], next: String?) {
        let start = index * scale.pageSize, end = min(scale.songs, start + scale.pageSize)
        guard start < end else { return ([], nil) }
        return ((start..<end).map { song($0, scale: scale) }, end < scale.songs ? songsPrefix + "\(index + 1)" : nil)
    }
    /// Playlist 0 is the 10,000-entry one; the other 999 are ordinary.
    static func playlist(_ n: Int) -> MusicCatalogItem {
        let id = n == 0 ? bigPlaylistID : "PLperf" + String(format: "%05d", n)
        let edge = artworkEdges[n % artworkEdges.count]
        return MusicCatalogItem(kind: .playlist, title: n == 0 ? "Synthetic 10,000-entry playlist" : "Synthetic playlist \(n)", details: ["Playlist", n == 0 ? "10000 songs" : "\(10 + n % 90) songs"], serviceLabel: "Playlist", browseID: "VL" + id, playlistID: id,
                                thumbnails: [MusicThumbnail(url: artworkURL(100_000 + n, edge: edge), width: edge, height: edge)])
    }
    static func playlistsPage(_ index: Int, scale: Scale = .standard) -> (items: [MusicCatalogItem], next: String?) {
        let start = index * scale.pageSize, end = min(scale.playlists, start + scale.pageSize)
        guard start < end else { return ([], nil) }
        return ((start..<end).map(playlist), end < scale.playlists ? playlistsPrefix + "\(index + 1)" : nil)
    }

    // MARK: Library seams

    static func page(_ items: [MusicCatalogItem], layout: MusicShelf.Layout, continuation: String?) -> MusicBrowsePage {
        var accounting = MusicParseAccounting()
        accounting.sections = 1; accounting.shelves = 1; accounting.items = items.count; accounting.classified = items.count
        return MusicBrowsePage(shelves: [MusicShelf(key: "\(layout.rawValue):", title: nil, layout: layout, items: items, continuation: continuation)], accounting: accounting)
    }
    /// The library page for a kind, when the performance dataset answers for it (songs and playlists); nil leaves the kind to the ordinary development data.
    static func libraryPage(for kind: MusicLibraryKind?, scale: Scale = .standard) -> MusicBrowsePage? {
        switch kind {
        case .songs?: let first = songsPage(0, scale: scale); return page(first.items, layout: .list, continuation: first.next)
        case .playlists?: let first = playlistsPage(0, scale: scale); return page(first.items, layout: .grid, continuation: first.next)
        default: return nil
        }
    }
    /// The continuation for one of this dataset's tokens, or nil for any other token.
    static func continuation(_ token: String, scale: Scale = .standard) -> MusicContinuationPage? {
        let pageOf: (Int) -> (items: [MusicCatalogItem], next: String?)
        let prefix: String
        if token.hasPrefix(songsPrefix) { prefix = songsPrefix; pageOf = { songsPage($0, scale: scale) } }
        else if token.hasPrefix(playlistsPrefix) { prefix = playlistsPrefix; pageOf = { playlistsPage($0, scale: scale) } }
        else { return nil }
        guard let index = Int(token.dropFirst(prefix.count)), index >= 0 else { return nil }
        let result = pageOf(index)
        var accounting = MusicParseAccounting()
        accounting.items = result.items.count; accounting.classified = result.items.count
        return MusicContinuationPage(items: result.items, shelves: [], continuation: result.next, accounting: accounting)
    }

    // MARK: Playlists

    /// The 10,000-entry playlist's rows for the development playlist service: unique occurrence ids, every 50th row a second occurrence of the row before it.
    static func bigPlaylistRows(count: Int = standardBigPlaylistEntries) -> [(setVideoID: String, videoID: String, title: String)] {
        (0..<count).map { n in
            let base = n % 50 == 49 ? n - 1 : n
            return ("PERF" + String(format: "%06d", n), "perfbig" + String(format: "%06d", base), "Big playlist song " + title(base))
        }
    }
    static let standardBigPlaylistEntries = Scale.standard.bigPlaylistEntries

    // MARK: Queue

    static func queueTitle(_ n: Int) -> String { "Synthetic queue item \(n + 1) — " + title(n) }

    // MARK: Artwork (no network: bytes are generated here, in six source sizes)

    private static let artworkCache = ArtworkBytes()
    private final class ArtworkBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [Int: Data] = [:]
        func data(edge: Int) -> Data? {
            if let hit = lock.withLock({ bytes[edge] }) { return hit }
            guard let made = DevelopmentPerformance.makeJPEG(edge: edge) else { return nil }
            lock.withLock { bytes[edge] = made }
            return made
        }
    }
    /// The bytes of the synthetic image the URL names (`/perf-art/<edge>/<n>`); the pixel pattern is deterministic noise so a decode does realistic work.
    @Sendable static func artwork(for url: URL) async throws -> Data {
        guard url.host == syntheticHost, url.pathComponents.count >= 4, url.pathComponents[1] == "perf-art", let edge = Int(url.pathComponents[2]), artworkEdges.contains(edge),
              let data = artworkCache.data(edge: edge) else { throw MusicSessionError.unrecognised }
        return data
    }
    fileprivate static func makeJPEG(edge: Int) -> Data? {
        var state: UInt64 = 0x9E3779B97F4A7C15 &+ UInt64(edge)
        var pixels = [UInt8](repeating: 255, count: edge * edge * 4)
        for y in 0..<edge {
            for x in 0..<edge {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = UInt8(truncatingIfNeeded: state >> 58)    // 0...63
                let i = (y * edge + x) * 4
                pixels[i] = UInt8(truncatingIfNeeded: x * 255 / edge) &+ noise
                pixels[i + 1] = UInt8(truncatingIfNeeded: y * 255 / edge) &+ noise
                pixels[i + 2] = UInt8(truncatingIfNeeded: (x + y) * 127 / edge) &+ noise
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
#endif
