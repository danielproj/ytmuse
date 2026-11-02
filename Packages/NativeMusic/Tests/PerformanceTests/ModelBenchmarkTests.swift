import AccountSession
import Artwork
import Domain
import Features
import Foundation
import Queue
import Testing
@testable import AppShell

/// Indicative, headless measurements of the model layers at the PERF04 scale (50,000 library songs, 10,000-entry playlist, 5,000-item queue, mixed
/// artwork). They run on whatever build the caller made (`scripts/perf-run.sh headless` uses optimized Debug in its own scratch path) and are
/// INDICATIVE only: the official W44 numbers come from Release builds on the reference Mac (`Docs/Performance-Runbook.md`).
///
/// The assertions are regression bounds with wide margins (set from the measured numbers after each fix), plus the one budget row that is a pure model
/// cost: the local library query, p95 at most 50 ms on 50,000 items (spec §20).
/// True on an optimized build (assertions compiled out). The measurements and their bounds mean nothing at -Onone, so the suite is skipped there (and in
/// the whole-package run); `scripts/test.sh --suite T44P` builds the package with `-Xswiftc -O` in its own scratch path and runs it.
private let optimizedBuild: Bool = !_isDebugAssertConfiguration()

@Suite("PERF headless model measurements", .serialized, .enabled(if: optimizedBuild, "runs on the optimized build only (scripts/test.sh --suite T44P)"))
@MainActor
struct ModelBenchmarkTests {
    private func loadedLibrary(maximumEntries: Int = 100_000, maximumPages: Int = 2_000) async -> LibraryCollectionModel {
        let model = LibraryCollectionModel(source: LibrarySource(kind: .songs),
                                           reader: { source in await MainActor.run { MusicBrowseReply(value: DevelopmentPerformance.libraryPage(for: source.kind)!, mode: .signedIn, accountGeneration: 0) } },
                                           continuer: { token in MusicBrowseReply(value: DevelopmentPerformance.continuation(token)!, mode: .signedIn, accountGeneration: 0) },
                                           maximumEntries: maximumEntries, maximumPages: maximumPages)
        await model.load()
        _ = await model.loadAll()
        return model
    }

    @Test func libraryPagingReadsAllFiftyThousandRowsAndStaysLinear() async throws {
        // Time every page of the walk; a quadratic loadMore shows as the last pages costing many times the first ones.
        let model = LibraryCollectionModel(source: LibrarySource(kind: .songs),
                                           reader: { _ in MusicBrowseReply(value: DevelopmentPerformance.libraryPage(for: .songs)!, mode: .signedIn, accountGeneration: 0) },
                                           continuer: { token in MusicBrowseReply(value: DevelopmentPerformance.continuation(token)!, mode: .signedIn, accountGeneration: 0) },
                                           maximumEntries: 100_000, maximumPages: 2_000)
        await model.load()
        var perPage: [Double] = []
        let total = DispatchTime.now().uptimeNanoseconds
        while model.hasMore && perPage.count < 1_000 {
            let start = DispatchTime.now().uptimeNanoseconds
            await model.loadMore()
            perPage.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let totalMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - total) / 1_000_000
        #expect(model.entries.count == 50_000)
        #expect(model.isComplete)
        let first = Bench.percentile(Array(perPage.prefix(50)), 0.5), last = Bench.percentile(Array(perPage.suffix(50)), 0.5)
        Bench.report(.init(name: "library.loadMore.perPage", samples: perPage, notes: "50k rows, 100 per page; first-50 p50 \(String(format: "%.2f", first)) ms, last-50 p50 \(String(format: "%.2f", last)) ms"))
        Bench.report(.init(name: "library.loadAll.total", samples: [totalMilliseconds], notes: "50,000 rows in 500 pages"))
        #expect(last < max(8 * first, 5), "paging cost must not grow with the rows already loaded (first \(first) ms, last \(last) ms)")
    }

    @Test func libraryQueryOverFiftyThousandRowsMeetsTheBudget() async throws {
        let model = await loadedLibrary()
        try #require(model.entries.count == 50_000)
        // The model remembers its last answer, so every sample uses a query it has not answered before (the spelling differs, the rows matched do not):
        // that is the cost of the first keystroke of a query, not of asking again.
        model.query = ""
        let all = Bench.timeMain("library.visibleEntries.noQuery.cached") { _ = model.visibleEntries.count }
        var cycle = 0
        func cold(_ name: String, _ queries: [String], samples: Int = 15) -> Bench.Result {
            cycle = 0
            return Bench.timeMain(name, samples: samples, warmup: 0) { model.query = queries[cycle % queries.count]; cycle += 1; _ = model.visibleEntries.count }
        }
        let search = cold("library.visibleEntries.search.cold", ["cafe", "Cafe", "cAfe", "caFe", "cafE", "CAfe", "CaFe", "CafE", "cAFe", "cAfE", "caFE", "CAFe", "CAfE", "CaFE", "cAFE"])
        let multi = cold("library.visibleEntries.searchTwoWords.cold", ["ocean blue 4", "Ocean blue 4", "ocean Blue 4", "ocean blue  4", "OCEAN blue 4", "ocean BLUE 4", "Ocean Blue 4", "oCean blue 4", "ocean bLue 4", "ocean blUe 4", "ocean bluE 4", "oceaN blue 4", "OCEAN BLUE 4", "oCEAN blue 4", "ocean BLue 4"])
        model.query = ""
        let hot = Bench.timeMain("library.visibleEntries.search.repeated") { model.query = "cafe"; _ = model.visibleEntries.count }
        // Sorting: cycling through three orders so each sample re-sorts (the model keeps only the last order).
        model.query = ""
        let orders: [LibrarySort] = [.titleAscending, .titleDescending, .artist]
        var which = 0
        let sortCold = Bench.timeMain("library.visibleEntries.sort.cold", samples: 6, warmup: 0, notes: "title asc, title desc, artist in rotation") { model.sort = orders[which % 3]; which += 1; _ = model.visibleEntries.count }
        model.sort = .service
        let state = Bench.timeMain("library.state.accessor") { _ = model.state }
        // The budget row: a local query over 50,000 rows, p95 at most 50 ms.
        #expect(Bench.percentile(search.samples, 0.95) <= 50, "search p95 \(Bench.percentile(search.samples, 0.95)) ms")
        #expect(Bench.percentile(multi.samples, 0.95) <= 50, "two-word search p95 \(Bench.percentile(multi.samples, 0.95)) ms")
        #expect(Bench.percentile(all.samples, 0.95) <= 50)
        #expect(Bench.percentile(hot.samples, 0.95) <= 50)
        #expect(Bench.percentile(state.samples, 0.95) <= 50)
        // Sorting is not a "query" row, but a re-sort the person waits for gets a loose bound so a regression to the old cost is caught.
        #expect(Bench.percentile(sortCold.samples, 0.95) <= 1_500, "cold re-sort p95 \(Bench.percentile(sortCold.samples, 0.95)) ms")
    }

    @Test func queueOfFiveThousandItemsOperationsStayCheap() throws {
        let account = try AccountContext(accountID: UUID(), channelID: ID("perf-queue"), region: "US")
        let media = try (0..<5_000).map { try ServiceID("perf-queue-\($0)") }
        var machine = QueueMachine(account: account, supportsAutoplay: false)
        Bench.time("queue.replaceContext.5000", samples: 8) { var fresh = QueueMachine(account: account, supportsAutoplay: false); try? fresh.replaceContext(media, source: ServiceID("perf-source")) }
        try machine.replaceContext(media, source: ServiceID("perf-source"))
        Bench.time("queue.snapshot.5000") { _ = try? machine.snapshot }
        let ids = machine.entries.map(\.id)
        var moves = machine
        Bench.time("queue.move.oneRow.5000") { try? moves.move([ids[2_000]], before: ids[100]); try? moves.move([ids[100]], before: ids[2_000]) }
        var removals = machine
        let removal = Bench.time("queue.remove.oneRow.5000", samples: 20, warmup: 0) { if let id = removals.entries.dropFirst(500).first?.id { try? removals.remove([id]) } }
        #expect(Bench.percentile(removal.samples, 0.95) <= 50, "removing one row of a 5,000-item queue must not cost a frame or more")
        #expect(try machine.snapshot.session.entries.count == 5_000)
    }

    @Test func artworkOfSixSourceSizesDecodesToDisplaySizeOffTheMainThread() async throws {
        let account = try AccountContext(accountID: UUID(), channelID: ID("perf-art"), region: "US")
        let context = RequestContext(account: account, accountGeneration: 1, requestGeneration: 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-perf-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        struct Source: ArtworkSource {
            func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData {
                let edge = Int(resource.identifier.split(separator: ":")[0])!, n = Int(resource.identifier.split(separator: ":")[1])!
                return ArtworkSourceData(bytes: try await DevelopmentPerformance.artwork(for: DevelopmentPerformance.artworkURL(n, edge: edge)), policy: .memory(until: Date().addingTimeInterval(600)))
            }
        }
        let pipeline = ArtworkPipeline(source: Source(), diskDirectory: root)
        try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account), generation: 1)
        var perEdge: [Int: [Double]] = [:]
        for round in 0..<4 {
            for edge in DevelopmentPerformance.artworkEdges {
                let resource = try ArtworkResource(namespace: "perf", identifier: "\(edge):\(round)", revision: "1")
                let request = ArtworkRequest(resource: resource, size: try ArtworkSize(pointsWidth: 44, pointsHeight: 44, scale: 2), policy: .memory(until: Date().addingTimeInterval(600)), context: context)
                let start = DispatchTime.now().uptimeNanoseconds
                let response = try await pipeline.image(for: request)
                perEdge[edge, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                #expect(response.image.cgImage.width <= 88 && response.image.cgImage.height <= 88, "decoded to display size, not the \(edge) px source")
            }
        }
        for (edge, samples) in perEdge.sorted(by: { $0.key < $1.key }) { Bench.report(.init(name: "artwork.decode.44pt@2x.source\(edge)px", samples: samples, notes: "first request per resource; includes source generation cost on a cold edge")) }
        let native = await pipeline.nativeSnapshot()
        #expect(native.mainThreadWorkViolations == 0, "no artwork decode ran on the main thread")
        #expect(native.largestRasterBytes <= 88 * 88 * 4 * 2, "the largest decoded raster is display size")
    }
}
