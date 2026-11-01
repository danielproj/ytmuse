import XCTest
import Foundation
import Domain
import Downloads

/// The source reality (W15 addendum): YouTube Music media has no permitted download route on Mac, so nothing is queued and
/// no control pretends otherwise; owned and local media do work. Plus the repository-wide guards for this lane.
final class EligibilityTests: XCTestCase, @unchecked Sendable {
    func testYouTubeMusicItemsAreNeverOfferedADownloadAndNeverQueued() async throws {
        let env = try Env(); defer { env.cleanup() }
        let source = FakeSource(wall: env.wall)
        let sink = MemorySink()
        let scheduler = try env.makeScheduler(source: source, sink: sink)
        await scheduler.bind(env.context)
        for id in ["dQw4w9WgXcQ", "MPREb_abcdef", "VLPLxyz", "OLAK5uy_k", "UCchannel"] {
            XCTAssertEqual(DownloadEligibility.of(youtube(id)), .notOffered(.youTubeMusicNoMacDownloads))
            let result = await scheduler.download(youtube(id), title: "YouTube Music item")
            XCTAssertEqual(result, .notOffered(.youTubeMusicNoMacDownloads), "no working or inert Download for \(id)")
            let automatic = await scheduler.download(youtube(id), title: "x", request: .automatic)
            XCTAssertNotEqual(automatic, .done)
        }
        let snapshot = await scheduler.snapshot()
        XCTAssertTrue(snapshot.rows.isEmpty, "no queued job that can never run")
        let reads = await source.readLog.count, describes = await source.describes, retained = await sink.retainCalls
        XCTAssertEqual(reads + describes + retained, 0, "no source was even asked")
        // A playlist of YouTube Music songs cannot be switched to downloading either.
        let refused = await scheduler.setCollection(try ServiceID("VLPLxyz"), title: "A playlist", members: [youtube("a"), youtube("b")], downloading: true)
        XCTAssertEqual(refused, .notOffered(.youTubeMusicNoMacDownloads))
        let collections = await scheduler.snapshot().collections; XCTAssertTrue(collections.isEmpty || collections.allSatisfy { $0.memberCount == 0 })
    }
    func testOriginsAreClassifiedByIdentifierOnly() {
        XCTAssertEqual(MediaOrigin.classify(owned("a")), .owned)
        XCTAssertEqual(MediaOrigin.classify(youtube("local-song")), .youTubeMusic, "a lookalike name is not enough")
        XCTAssertEqual(MediaOrigin.classify(youtube("local-file:3B8F")), .localFile)
        XCTAssertEqual(MediaOrigin.classify(youtube("publisher-grant:abc")), .publisherGrant)
        XCTAssertEqual(DownloadEligibility.of(owned("a")), .eligible(.owned))
    }
    func testAnOriginWithNoRegisteredSourceIsRefusedNotQueued() async throws {
        let env = try Env(); defer { env.cleanup() }
        let scheduler = try DownloadScheduler(ledgerRoot: env.ledgerURL, sink: MemorySink(), sources: [:], wall: env.wall, volume: env.volume, wake: WakeRecorder().scheduler)
        await scheduler.bind(env.context)
        let result = await scheduler.download(try ServiceID("publisher-grant:thing"), title: "x")
        XCTAssertEqual(result, .refused(.unsupported), "nothing publishes a download permission here, so nothing is queued")
        let rows = await scheduler.snapshot().rows; XCTAssertTrue(rows.isEmpty)
    }
    func testDownloadsNeedABoundAccount() async throws {
        let env = try Env(); defer { env.cleanup() }
        let scheduler = try env.makeScheduler(source: FakeSource(wall: env.wall), sink: MemorySink())
        let result = await scheduler.download(owned("a"), title: "x"); XCTAssertEqual(result, .refused(.unauthorized))
    }

    // MARK: Local files

    func testAFileOnThisMacBecomesAnOwnedDownloadAndANonAudioFileIsRefused() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let kit = try env.realStore(); defer { Task { try? await kit.1.destroyIsolatedTestKeychain() } }
        let audio = env.root.appendingPathComponent("My Recording.wav")
        // A small valid WAVE (silence): 8 kHz mono 16-bit, 0.1 s.
        var wav = Data("RIFF".utf8); let samples = Data(count: 1600)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(36 + samples.count).littleEndian) { Array($0) }); wav.append(Data("WAVEfmt ".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }); wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }); wav.append(contentsOf: withUnsafeBytes(of: UInt32(8000).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Array($0) }); wav.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }); wav.append(Data("data".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(samples.count).littleEndian) { Array($0) }); wav.append(samples)
        try wav.write(to: audio)
        let text = env.root.appendingPathComponent("notes.txt"); try Data("not audio".utf8).write(to: text)
        let scheduler = try DownloadScheduler(ledgerRoot: env.ledgerURL, sink: kit.2, sources: [.localFile: LocalFileDownloadSource(issuer: "File chosen on this Mac")], wall: SystemWallClock(), volume: env.volume,
                                              configuration: .init(chunkBytes: 512, persistEveryChunks: 2, minimumBudget: 1024), wake: WakeRecorder().scheduler)
        await scheduler.bind(env.context)
        let refused = await scheduler.addLocalFile(text); XCTAssertEqual(refused, .refused(.unsupported))
        let missing = await scheduler.addLocalFile(env.root.appendingPathComponent("nope.wav")); XCTAssertEqual(missing, .refused(.unsupported))
        let accepted = await scheduler.addLocalFile(audio); XCTAssertEqual(accepted, .done)
        await scheduler.settleBounded()
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.phase, .available); XCTAssertEqual(row.origin, .localFile); XCTAssertEqual(row.title, "My Recording"); XCTAssertTrue(row.pinned)
        let variant = await scheduler.variantForTesting(row.media)
        let stored = try await kit.0.read(variant: try XCTUnwrap(variant), offset: 0, count: wav.count, context: env.context)
        XCTAssertEqual(stored, wav, "the retained bytes are exactly the chosen file's")
        // The source file changing after the fact does not silently replace the retained copy: it is a different variant.
        let entitlement = try await kit.0.validateEntitlement(try ServiceID(variant!), context: env.context).outcome.get().source
        XCTAssertEqual(entitlement, "File chosen on this Mac")
    }

    // MARK: Guards

    /// No live media fetch: the Downloads sources contain no URL loading, socket or website code (W12 live-transport guard).
    func testTheDownloadEngineContainsNoLiveNetworkCode() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Downloads")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 8, "the sweep covers the package")
        let forbidden = ["URLSession", "URLRequest(", "NWConnection", "WKWebView", "CFNetwork", "https://", "http://", "youtube.com", "googlevideo", "NSURLConnection"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden { XCTAssertFalse(text.contains(token), "\(file.lastPathComponent) mentions \(token)") }
        }
        // And the sweep would notice one: the check is not vacuous.
        XCTAssertTrue("let s = URLSession.shared".contains(forbidden[0]))
    }
    func testNoDownloadsTestUsesTheProductionStoresOrKeychain() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: tests, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 9, "the sweep covers this target")
        // Assembled from parts so this file does not itself trip the repository-wide source sweep for those spellings.
        let productionVault = ["Keychain", "Vault", "()"].joined(), appSupport = ["application", "SupportDirectory"].joined(), realStores = ["YTMUSE_USE_", "REAL_STORES"].joined()
        var seen = 0
        for file in files where file.lastPathComponent != "EligibilityTests.swift" {
            let text = try String(contentsOf: file, encoding: .utf8); seen += 1
            XCTAssertFalse(text.contains(productionVault), file.lastPathComponent)
            XCTAssertFalse(text.contains(appSupport), file.lastPathComponent)
            XCTAssertFalse(text.contains(realStores), file.lastPathComponent)
        }
        XCTAssertGreaterThanOrEqual(seen, 8)
        // Not vacuous: the spellings it looks for are the ones that would offend.
        XCTAssertTrue("let v = \(productionVault)".contains(productionVault))
    }
}
