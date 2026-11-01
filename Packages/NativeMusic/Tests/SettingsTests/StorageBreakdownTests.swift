import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Domain
import AccountSession
import Artwork
import Downloads
@testable import AppShell

struct FixedVolume: VolumeCapacityProviding {
    func capacity(at url: URL) -> VolumeCapacity { VolumeCapacity(total: 1000 << 30, available: 500 << 30) }
}
struct PNGSource: ArtworkSource {
    let png: Data
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData {
        ArtworkSourceData(bytes: png, policy: .disk(until: Date().addingTimeInterval(86_400)))
    }
}
func noisePNG(side: Int, seed: UInt64) -> Data {
    var bytes = [UInt8](repeating: 255, count: side * side * 4)
    var state = seed
    for i in stride(from: 0, to: bytes.count, by: 4) { for j in 0..<3 { state = state &* 6364136223846793005 &+ 1; bytes[i + j] = UInt8(truncatingIfNeeded: state >> 32) } }
    let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
    return data as Data
}

/// A deterministic source of owned bytes, so automatic jobs can run without a network or a file picker.
struct SyntheticSource: DownloadSource {
    let bytes: [String: Data]
    func describe(item: SourceItem, context: RequestContext) async throws -> SourceDescriptor {
        guard let data = bytes[item.media.rawValue] else { throw SourceFailure.unavailable }
        let now = Date()
        return SourceDescriptor(variant: item.media.rawValue, validator: "v1", length: Int64(data.count), supportsRanges: true,
                                permission: DownloadPermission(issuer: "Synthetic owned media", sourceEncryption: "none", validatedAt: now, expires: now.addingTimeInterval(86_400), renewAfter: nil, renewalReference: "synthetic"))
    }
    func read(item: SourceItem, descriptor: SourceDescriptor, offset: Int64, count: Int, context: RequestContext) async throws -> SourceRead {
        let data = try #require(bytes[item.media.rawValue])
        let end = min(data.count, Int(offset) + count)
        return SourceRead(data: data.subdata(in: Int(offset)..<end), endOfStream: end >= data.count)
    }
    func renew(item: SourceItem, descriptor: SourceDescriptor, context: RequestContext) async throws -> DownloadPermission { descriptor.permission }
}

/// T27.3: the breakdown by account equals the download ledger, the W14 encrypted object store and the artwork cache across accounts, with pinned AND automatic bytes on
/// both accounts.
@Suite(.serialized) @MainActor struct StorageBreakdownTests {
    func wav(_ directory: URL, name: String, seconds: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var data = Data("RIFF".utf8); let payload = Data(repeating: 0x41, count: seconds * 4096)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(36 + payload.count).littleEndian, Array.init)); data.append(Data("WAVEfmt ".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init)); data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init)); data.append(contentsOf: withUnsafeBytes(of: UInt32(8000).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian, Array.init)); data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian, Array.init)); data.append(Data("data".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian, Array.init)); data.append(payload)
        try data.write(to: url); return url
    }
    func contexts() throws -> (AccountContext, AccountContext, RequestContext, RequestContext) {
        let a = try AccountContext(accountID: UUID(), channelID: ID("UCstorageA0001"), region: "US"), b = try AccountContext(accountID: UUID(), channelID: ID("UCstorageB0002"), region: "US")
        return (a, b, RequestContext(account: a, accountGeneration: 1, requestGeneration: 0), RequestContext(account: b, accountGeneration: 2, requestGeneration: 0))
    }
    /// Waits for the SPECIFIC jobs this test started (their row ids), on the monotonic clock, and says whether every one of them is available. A wall-clock deadline or
    /// "any three finished items" would let a slow machine compare a ledger that is still mid-download.
    func waitForJobs(_ scheduler: DownloadScheduler, _ ids: Set<UUID>, seconds: Double = 90) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < end {
            let rows = await scheduler.snapshot().rows
            let phases = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.phase) })
            if ids.allSatisfy({ phases[$0] == .available }) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
    func rowIDs(_ scheduler: DownloadScheduler) async -> Set<UUID> { Set(await scheduler.snapshot().rows.map(\.id)) }
    func owned(_ name: String) -> ServiceID { try! ServiceID("owned-" + name) }

    @Test func theBreakdownByAccountEqualsTheLedgerTheObjectStoreAndTheArtworkCacheWithPinnedAndAutomaticBytesOnBothAccounts() async throws {
        let scratch = try Scratch(); defer { scratch.cleanup() }
        let (vault, _, _) = try isolatedVault(); defer { Task { try? await vault.destroyIsolatedTestKeychain() } }
        let store = try EncryptedStore(root: scratch.url.appendingPathComponent("objects"), vault: vault)
        let bytes: [String: Data] = ["owned-auto-a": Data(repeating: 0x11, count: 30_000), "owned-auto-b": Data(repeating: 0x22, count: 50_000), "owned-auto-b2": Data(repeating: 0x33, count: 20_000)]
        let scheduler = try DownloadScheduler(ledgerRoot: scratch.url.appendingPathComponent("jobs"), sink: EncryptedStoreSink(store: store),
                                              sources: [.localFile: LocalFileDownloadSource(issuer: "File chosen on this Mac"), .owned: SyntheticSource(bytes: bytes)], volume: FixedVolume(),
                                              configuration: .init(chunkBytes: 64 * 1024, persistEveryChunks: 4, minimumBudget: 1024), wake: { _, _ in {} }, suggestionsAvailable: true,
                                              originOf: { $0.rawValue.hasPrefix("owned-") ? .owned : MediaOrigin.classify($0) })
        let (a, b, contextA, contextB) = try contexts()
        _ = await scheduler.setBudget(bytes: 1 << 30); _ = await scheduler.setSmartDownloads(enabled: true)
        // Account A: two pinned files and one automatic download. Account B: one pinned file and two automatic downloads.
        let beforeA = await rowIDs(scheduler)
        await scheduler.bind(contextA)
        #expect(await scheduler.addLocalFile(try wav(scratch.url, name: "a1.wav", seconds: 3)) == .done)
        #expect(await scheduler.addLocalFile(try wav(scratch.url, name: "a2.wav", seconds: 5)) == .done)
        #expect(await scheduler.download(owned("auto-a"), title: "Auto A", request: .automatic) == .done)
        let startedA = await rowIDs(scheduler).subtracting(beforeA)
        try #require(startedA.count == 3, "three jobs were started for A")
        // Nothing is compared until every job THIS test started has finished (the rows are the bound account's, so A is awaited while A is bound).
        try #require(await waitForJobs(scheduler, startedA), "every job the test started for A finished")
        let beforeB = await rowIDs(scheduler)
        await scheduler.bind(contextB)
        #expect(await scheduler.addLocalFile(try wav(scratch.url, name: "b1.wav", seconds: 4)) == .done)
        #expect(await scheduler.download(owned("auto-b"), title: "Auto B", request: .automatic) == .done)
        #expect(await scheduler.download(owned("auto-b2"), title: "Auto B2", request: .automatic) == .done)
        let startedB = await rowIDs(scheduler).subtracting(beforeB)
        try #require(startedB.count == 3, "three jobs were started for B")
        try #require(await waitForJobs(scheduler, startedB), "every job the test started for B finished")
        let usageA = await scheduler.usage(for: a), usageB = await scheduler.usage(for: b), total = await scheduler.usageAcrossAccounts()
        #expect(usageA.automaticBytes > 0 && usageB.automaticBytes > 0 && usageA.pinnedBytes > 0 && usageB.pinnedBytes > 0, "automatic AND pinned bytes on both accounts: \(usageA) \(usageB)")
        #expect(usageB.automaticBytes > usageA.automaticBytes, "B holds two automatic items to A's one")
        #expect(usageA.automaticBytes + usageB.automaticBytes == total.automaticBytes && usageA.pinnedBytes + usageB.pinnedBytes == total.pinnedBytes && usageA.storedBytes + usageB.storedBytes == total.storedBytes)
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.storage.usedBytes == total.storedBytes && snapshot.storage.pinnedBytes == total.pinnedBytes && snapshot.storage.automaticBytes == total.automaticBytes, "reconciles with the W15 ledger's snapshot")
        // W14: what the encrypted object store holds on disk is what the ledger says it stored.
        let onDisk = await store.onDiskObjectBytes()
        #expect(onDisk > 0, "the store holds the objects")

        // The artwork cache: a real pipeline over a stub source, two accounts.
        let pipeline = ArtworkPipeline(source: PNGSource(png: noisePNG(side: 64, seed: 7)), diskDirectory: scratch.url.appendingPathComponent("artwork"))
        func request(_ context: RequestContext, _ id: String) throws -> ArtworkRequest {
            ArtworkRequest(resource: try ArtworkResource(namespace: "storage-test", identifier: id, revision: "1"), size: try ArtworkSize(pointsWidth: 32, pointsHeight: 32, scale: 1), policy: .disk(until: Date().addingTimeInterval(86_400)), context: context)
        }
        try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: a), generation: 1)
        _ = try await pipeline.image(for: request(contextA, "one")); _ = try await pipeline.image(for: request(contextA, "two"))
        try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: b), generation: 2)
        _ = try await pipeline.image(for: request(contextB, "three"))
        var cacheA = 0, cacheB = 0, settled = false
        let cacheEnd = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < cacheEnd {
            cacheA = await pipeline.cacheBytes(accountID: a.accountID); cacheB = await pipeline.cacheBytes(accountID: b.accountID)
            let whole = await pipeline.diskSnapshot().bytes
            if cacheA > 0 && cacheB > 0 && cacheA + cacheB == whole { settled = true; break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        try #require(settled, "the artwork writes settled before anything is compared")
        #expect(cacheA > 0 && cacheB > 0 && cacheA > cacheB, "two cached pictures for A, one for B")

        let unlistedNone = await scheduler.usageOutside([a, b])
        #expect(unlistedNone == AccountDownloadUsage(), "no ledger directory is outside the two listed accounts")
        let breakdown = await StorageBreakdown.make(accounts: [(a, "Alpha"), (b, "Beta")], usage: { await scheduler.usage(for: $0) }, unlisted: unlistedNone, ledgerTotals: total,
                                                    cache: { await pipeline.cacheBytes(accountID: $0.accountID) }, artworkDiskBytes: await pipeline.diskSnapshot().bytes, objectStoreBytes: onDisk)
        #expect(breakdown.reconciles && breakdown.unattributedDownloadBytes == 0)
        #expect(breakdown.totalPinned == total.pinnedBytes && breakdown.totalAutomatic == total.automaticBytes && breakdown.totalDownloads == snapshot.storage.usedBytes)
        let wholeDisk = await pipeline.diskSnapshot().bytes
        #expect(breakdown.totalCache == Int64(wholeDisk))
        #expect(breakdown.accounts.map(\.label) == ["Alpha", "Beta"] && breakdown.accounts[0].automaticBytes == usageA.automaticBytes && breakdown.accounts[1].automaticBytes == usageB.automaticBytes && breakdown.accounts[1].cacheBytes == Int64(cacheB))
        // The object store and the ledger measure the same bytes from two sides.
        print("W27-STORAGE ledger stored=\(total.storedBytes) objectStoreOnDisk=\(onDisk)")
        #expect(breakdown.objectStoreAgrees, "ledger \(total.storedBytes) vs object store \(onDisk)")

        // An account the roster no longer lists keeps its bytes on disk: the unlisted line is ENUMERATED from the ledger directories it owns, and the total still reconciles.
        let unlistedB = await scheduler.usageOutside([a])
        #expect(unlistedB == usageB, "the directories outside A's are exactly B's")
        let withoutB = await StorageBreakdown.make(accounts: [(a, "Alpha")], usage: { await scheduler.usage(for: $0) }, unlisted: unlistedB, ledgerTotals: total,
                                                   cache: { await pipeline.cacheBytes(accountID: $0.accountID) }, artworkDiskBytes: await pipeline.diskSnapshot().bytes, objectStoreBytes: onDisk)
        #expect(withoutB.unlistedDownloads.automaticBytes == usageB.automaticBytes && withoutB.unlistedDownloads.pinnedBytes == usageB.pinnedBytes && withoutB.unattributedCacheBytes == Int64(cacheB) && withoutB.reconciles)
        #expect(withoutB.unattributedDownloadBytes == usageB.storedBytes && withoutB.unattributedDownloadBytes > 0, "the bytes of the account the roster no longer lists are reported as unattributed")
        // An under-counted listed account is NOT absorbed into the unlisted line: it breaks the reconciliation.
        let underCounted = await StorageBreakdown.make(accounts: [(a, "Alpha"), (b, "Beta")], usage: { account in
            let real = await scheduler.usage(for: account)
            return account == b ? AccountDownloadUsage(storedBytes: real.storedBytes, pinnedBytes: real.pinnedBytes, automaticBytes: 0, unlistedBytes: real.unlistedBytes) : real
        }, unlisted: unlistedNone, ledgerTotals: total, cache: { await pipeline.cacheBytes(accountID: $0.accountID) }, artworkDiskBytes: wholeDisk, objectStoreBytes: onDisk)
        #expect(!underCounted.reconciles, "dropping an account's automatic bytes is noticed, not absorbed")

        // Clearing A's cache removes exactly A's artwork and nothing of B's or any download.
        try await pipeline.clearCache(accountID: a.accountID)
        let afterA = await pipeline.cacheBytes(accountID: a.accountID), afterB = await pipeline.cacheBytes(accountID: b.accountID)
        #expect(afterA == 0 && afterB == cacheB)
        let totalAfter = await scheduler.usageAcrossAccounts()
        #expect(totalAfter == total, "downloads are not cache")
        await scheduler.quit()
    }

    @Test func aBreakdownThatDoesNotAddUpSaysSo() {
        let account = try! AccountContext(accountID: UUID(), channelID: ID("UCmismatch0001"), region: "US")
        let row = StorageBreakdown.AccountRow(account: account, label: "x", pinnedBytes: 10, automaticBytes: 5, cacheBytes: 3, otherDownloadBytes: 0)
        func make(stored: Int64, pinned: Int64, automatic: Int64, unlisted: AccountDownloadUsage = AccountDownloadUsage()) -> StorageBreakdown {
            StorageBreakdown(accounts: [row], unlistedDownloads: unlisted, unattributedCacheBytes: 0, ledgerTotals: AccountDownloadUsage(storedBytes: stored, pinnedBytes: pinned, automaticBytes: automatic), artworkDiskBytes: 3, objectStoreBytes: 15)
        }
        #expect(!make(stored: 99, pinned: 10, automatic: 5).reconciles && make(stored: 99, pinned: 10, automatic: 5).totalBytes == 18)
        #expect(!make(stored: 15, pinned: 11, automatic: 5).reconciles && !make(stored: 15, pinned: 10, automatic: 6).reconciles, "pinned and automatic are reconciled on their own")
        #expect(make(stored: 15, pinned: 10, automatic: 5).reconciles && make(stored: 15, pinned: 10, automatic: 5).objectStoreAgrees)
        #expect(!make(stored: 16, pinned: 10, automatic: 5, unlisted: AccountDownloadUsage(storedBytes: 0)).objectStoreAgrees, "the object store holds 15 bytes while the ledger says 16")
    }
}
