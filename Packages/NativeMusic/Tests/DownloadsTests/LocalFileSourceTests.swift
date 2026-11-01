import XCTest
import Foundation
import Domain
import Downloads

/// The real `LocalFileDownloadSource` (not a fake) against scratch files: identity of the bytes, a file that changes under a
/// transfer, and the holder-declared permission window.
/// Wraps the real local-file source and holds a read so a test can change the file while the transfer is part-way.
actor GatedLocalSource: DownloadSource {
    private let real: LocalFileDownloadSource
    private var reads = 0
    private var holdAfter: Int?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var blocked = false
    init(real: LocalFileDownloadSource) { self.real = real }
    func hold(after count: Int) { holdAfter = count }
    func release() { holdAfter = nil; blocked = false; let w = waiting; waiting = []; for c in w { c.resume() } }
    func describe(item: SourceItem, context: RequestContext) async throws -> SourceDescriptor { try await real.describe(item: item, context: context) }
    func read(item: SourceItem, descriptor: SourceDescriptor, offset: Int64, count: Int, context: RequestContext) async throws -> SourceRead {
        reads += 1
        if let holdAfter, reads > holdAfter { blocked = true; await withCheckedContinuation { waiting.append($0) } }
        return try await real.read(item: item, descriptor: descriptor, offset: offset, count: count, context: context)
    }
    func renew(item: SourceItem, descriptor: SourceDescriptor, context: RequestContext) async throws -> DownloadPermission { try await real.renew(item: item, descriptor: descriptor, context: context) }
    func waitUntilBlocked() async { for _ in 0..<2000 where !blocked { try? await Task.sleep(for: .milliseconds(2)) }; if !blocked { XCTFail("the held read was never reached") } }
}

final class LocalFileSourceTests: XCTestCase, @unchecked Sendable {
    private func rig(_ env: Env, chunk: Int = 1024) throws -> (DownloadScheduler, MemorySink) {
        let sink = MemorySink()
        let scheduler = try DownloadScheduler(ledgerRoot: env.ledgerURL, sink: sink, sources: [.localFile: LocalFileDownloadSource(issuer: "File chosen on this Mac", wall: env.wall)], wall: env.wall, volume: env.volume,
                                              configuration: .init(chunkBytes: chunk, persistEveryChunks: 1, minimumBudget: 1024), wake: WakeRecorder().scheduler)
        return (scheduler, sink)
    }
    private func file(_ env: Env, _ name: String, _ data: Data) throws -> URL {
        let url = env.root.appendingPathComponent(name); try data.write(to: url); return url
    }
    private func add(_ scheduler: DownloadScheduler, _ url: URL, title: String) async -> DownloadCommandResult {
        guard let id = try? ServiceID(MediaOrigin.localFilePrefix + UUID().uuidString) else { return .refused(.malformedResponse) }
        return await scheduler.download(id, title: title, location: url.path)
    }

    func testAFileIsKeptByteForByteAndItsIdentityNamesTheExactBytes() async throws {
        let env = try Env(); defer { env.cleanup() }
        let data = payload(5000, seed: 4)
        let (scheduler, sink) = try rig(env)
        await scheduler.bind(env.context)
        let result = await add(scheduler, try file(env, "a.wav", data), title: "A"); XCTAssertEqual(result, .done)
        await scheduler.settleBounded()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.phase, .available)
        let found = await scheduler.variantForTesting(row.media); let variant = try XCTUnwrap(found)
        XCTAssertTrue(variant.hasPrefix(row.media.rawValue + "#"), "the variant ties the media to the exact file revision")
        let stored = await sink.bytes(variant); XCTAssertEqual(stored, data)
        let grant = await sink.grant(variant)
        XCTAssertEqual(grant?.issuer, "File chosen on this Mac"); XCTAssertEqual(grant?.rights, ["play", "seek", "retain"])
        XCTAssertEqual(grant?.expires, env.wall.now().addingTimeInterval(LocalFileDownloadSource.validity), "the stated window, not an open-ended grant")
    }
    func testAFileThatChangesDuringATransferIsRestartedFromItsNewBytes() async throws {
        let env = try Env(); defer { env.cleanup() }
        let first = payload(6 * 1024, seed: 1), second = payload(7 * 1024 + 100, seed: 2)
        let sink = MemorySink()
        let gate = GatedLocalSource(real: LocalFileDownloadSource(issuer: "File chosen on this Mac", wall: env.wall))
        let scheduler = try DownloadScheduler(ledgerRoot: env.ledgerURL, sink: sink, sources: [.localFile: gate], wall: env.wall, volume: env.volume,
                                              configuration: .init(chunkBytes: 1024, persistEveryChunks: 1, minimumBudget: 1024), wake: WakeRecorder().scheduler)
        await scheduler.bind(env.context)
        let url = try file(env, "b.wav", first)
        let id = try ServiceID(MediaOrigin.localFilePrefix + UUID().uuidString)
        await gate.hold(after: 2)
        _ = await scheduler.download(id, title: "B", location: url.path)
        await gate.waitUntilBlocked()
        try second.write(to: url)                      // the file is replaced under the running transfer
        await gate.release()
        await scheduler.settleBounded()
        let row = try await scheduler.onlyRow(); XCTAssertEqual(row.phase, .available)
        let variant = await scheduler.variantForTesting(id)
        let stored = await sink.bytes(try XCTUnwrap(variant))
        XCTAssertEqual(stored, second, "the new bytes in full: the first chunks of the old file were discarded, not appended to")
    }
    func testAMissingSourceFileFailsExplicitlyAndRetryWorksOnceItIsBack() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, sink) = try rig(env)
        await scheduler.bind(env.context)
        let url = env.root.appendingPathComponent("gone.wav")
        _ = await add(scheduler, url, title: "Gone"); await scheduler.settleBounded()
        let row = try await scheduler.onlyRow()
        XCTAssertEqual(row.phase, .failed); XCTAssertEqual(row.failure, .sourceUnavailable); XCTAssertTrue(row.actions.contains(.retry))
        let none = await sink.count; XCTAssertEqual(none, 0)
        try payload(2048).write(to: url)
        _ = await scheduler.perform(.retry, job: row.id); await scheduler.settleBounded()
        let again = try await scheduler.onlyRow(); XCTAssertEqual(again.phase, .available)
    }
    func testThePermissionIsRenewedBeforeItEndsAndExpiresOnlyAtItsStatedEnd() async throws {
        let env = try Env(); defer { env.cleanup() }
        let (scheduler, sink) = try rig(env)
        await scheduler.bind(env.context)
        let url = try file(env, "c.wav", payload(2048))
        _ = await add(scheduler, url, title: "C"); await scheduler.settleBounded()
        let initial = try await scheduler.onlyRow()
        let firstEnd = try XCTUnwrap(initial.expiresAt)
        // Inside the window but before the renewal point: nothing changes.
        env.manual.advance(LocalFileDownloadSource.validity - LocalFileDownloadSource.renewBefore - 3600); await scheduler.renewalSweep()
        let early = try await scheduler.onlyRow(); XCTAssertEqual(early.expiresAt, firstEnd)
        // Past the renewal point: renewed from the holder's declaration, extending the end.
        env.manual.advance(7200); await scheduler.renewalSweep()
        let renewed = try await scheduler.onlyRow()
        XCTAssertEqual(renewed.phase, .available); XCTAssertGreaterThan(renewed.expiresAt ?? .distantPast, firstEnd)
        let found = await scheduler.variantForTesting(initial.media); let variant = try XCTUnwrap(found)
        let grant = await sink.grant(variant); XCTAssertEqual(grant?.expires, renewed.expiresAt, "the store holds the extended end")
        // The file is gone and the extended window runs out: the copy reads Expired, never silently usable forever.
        try FileManager.default.removeItem(at: url)
        env.manual.advance(LocalFileDownloadSource.validity + 10); await scheduler.renewalSweep()
        let expired = try await scheduler.onlyRow()
        XCTAssertEqual(expired.phase, .expired, "with the source gone and the stated window over, the copy reads Expired")
        XCTAssertTrue(expired.actions.contains(.renew) && expired.actions.contains(.downloadAgain))
    }
}
