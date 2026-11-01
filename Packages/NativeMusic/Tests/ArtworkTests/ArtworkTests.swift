import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Domain
@testable import Artwork

private let expiry = Date(timeIntervalSince1970: 4_000_000_000)
private let diskPolicy = ArtworkCachePolicy.disk(until: expiry)
private let memoryPolicy = ArtworkCachePolicy.memory(until: expiry)

private func syntheticPNG(width: Int = 512, height: Int = 256, noise: Bool = false, red: UInt8 = 180) throws -> Data {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    var state: UInt64 = 0x1234abcd
    for i in stride(from: 0, to: pixels.count, by: 4) {
        if noise {
            for j in 0..<3 { state = state &* 6364136223846793005 &+ 1; pixels[i+j] = UInt8(truncatingIfNeeded: state >> 32) }
        } else { pixels[i] = red; pixels[i+1] = 50; pixels[i+2] = 100 }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(target, image, nil)
    #expect(CGImageDestinationFinalize(target))
    return data as Data
}
private func owner() throws -> ArtworkOwner {
    ArtworkOwner(account: try AccountContext(accountID: UUID(), channelID: ID("synthetic-channel"), region: "US"))
}
private func request(_ owner: ArtworkOwner, generation: UInt64 = 1, query: UInt64 = 1, id: String = "synthetic", width: Double = 64, height: Double = 64, policy: ArtworkCachePolicy = diskPolicy) throws -> ArtworkRequest {
    ArtworkRequest(resource: try ArtworkResource(namespace: "owned-test", identifier: id, revision: "1"),
                   size: try ArtworkSize(pointsWidth: width, pointsHeight: height, scale: 2), policy: policy,
                   context: RequestContext(account: owner.account, accountGeneration: generation, requestGeneration: query))
}
private func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-artwork-w09-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
}
private func eventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { Issue.record("Timed out waiting for deterministic artwork condition"); throw ArtworkError.overloaded }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private func fails(_ expected: ArtworkError? = nil, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("Expected failure") }
    catch { if let expected { #expect(error as? ArtworkError == expected) } }
}
private func cancelled(_ body: () async throws -> Void) async {
    do { try await body(); Issue.record("Expected caller cancellation") }
    catch { #expect(error is CancellationError) }
}
private final class TestClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(interval) }
}
private struct FailingSource: ArtworkSource {
    let typed: Bool
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData {
        if typed { throw DomainError.offline }
        throw NSError(domain: "private-provider-diagnostic-do-not-forward", code: 1)
    }
}
private actor Source: ArtworkSource {
    let bytes: Data
    let policy: ArtworkCachePolicy
    let blocked: Bool
    var calls = 0
    var owners: [ArtworkOwner] = []
    var generations: [UInt64] = []
    var gates: [CheckedContinuation<Void, Never>] = []
    init(_ bytes: Data, policy: ArtworkCachePolicy = diskPolicy, blocked: Bool = false) { self.bytes = bytes; self.policy = policy; self.blocked = blocked }
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData {
        calls += 1; owners.append(owner); generations.append(generation)
        if blocked { await withCheckedContinuation { gates.append($0) } }
        // Deliberately uncooperative cancellation exercises pipeline abandonment fencing.
        return ArtworkSourceData(bytes: bytes, policy: policy)
    }
    func release() { let saved = gates; gates.removeAll(); for gate in saved { gate.resume() } }
}

@Suite(.serialized)
struct ArtworkTests {
    @Test func validatesInputs() throws {
        #expect(throws: ArtworkError.invalidSize) { try ArtworkSize(pointsWidth: .nan, pointsHeight: 1, scale: 1) }
        #expect(throws: ArtworkError.invalidSize) { try ArtworkSize(pointsWidth: 2049, pointsHeight: 1, scale: 1) }
        #expect(throws: ArtworkError.invalidSize) { try ArtworkSize(pointsWidth: 1, pointsHeight: 1, scale: .infinity) }
        #expect(throws: ArtworkError.invalidResource) { try ArtworkResource(namespace: "", identifier: "x", revision: "1") }
        #expect(throws: ArtworkError.invalidConfiguration) { try ArtworkConfiguration(memoryBytes: 64 * 1024 * 1024 + 1) }
        #expect(throws: ArtworkError.invalidConfiguration) { try ArtworkConfiguration(diskBytes: 512 * 1024 * 1024 + 1) }
    }
    @Test func nativeDisplayDecodeAndPaletteCache() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let data = try syntheticPNG(width: 2048, height: 1024)
        let source = Source(data)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
        let req = try request(account)
        let first = try await pipeline.image(for: req)
        #expect(first.image.cgImage.width == 128); #expect(first.image.cgImage.height == 64)
        #expect(first.image.byteCost == 128 * 64 * 4)
        #expect(first.image.palette.opacity == 0.22)
        #expect(first.image.palette.red > first.image.palette.green)
        let second = try await pipeline.image(for: request(account, query: 99))
        #expect(second.context.requestGeneration == 99)
        #expect(second.image.cgImage === first.image.cgImage)
        let stats = await pipeline.snapshot()
        #expect(stats.decodes == 1); #expect(stats.paletteExtractions == 1); #expect(stats.memoryHits == 1)
        #expect(stats.mainThreadWorkViolations == 0)
        let native = await pipeline.nativeSnapshot()
        #expect(native.completedDecodes == 1); #expect(native.paletteExtractions == 1)
        #expect(native.largestInputBytes == data.count); #expect(native.largestRasterBytes == first.image.byteCost)
        #expect(native.mainThreadWorkViolations == 0)
        #expect(await pipeline.diskSnapshot().mainThreadWorkViolations == 0)
        print("ARTWORK decode source=2048x1024 output=128x64 actualRasterBytes=\(first.image.byteCost) mainThreadViolations=\(stats.mainThreadWorkViolations)")
    }
    @Test func creatorCancellationPreservesJoinerAndContexts() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG(), blocked: true)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
        let a = Task { try await pipeline.image(for: request(account, query: 3)) }
        try await eventually { await source.calls == 1 }
        let b = Task { try await pipeline.image(for: request(account, query: 8)) }
        try await eventually { await pipeline.snapshot().waiters == 2 }
        a.cancel()
        try await eventually { await pipeline.snapshot().cancelledWaiters == 1 }
        let replacement = Task { try await pipeline.image(for: request(account, query: 4)) }
        try await eventually { await pipeline.snapshot().waiters == 2 }
        await source.release()
        await cancelled { _ = try await a.value }
        #expect(try await replacement.value.context.requestGeneration == 4)
        let peer = try await b.value
        #expect(peer.context.requestGeneration == 8)
        #expect(await source.calls == 1)
        let stats = await pipeline.snapshot()
        #expect(stats.coalescedWaiters == 2); #expect(stats.memoryBytes > 0)
        #expect(stats.paletteExtractions == 1)
    }
    @Test func joinerCancellationPreservesCreator() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG(), blocked: true)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
        let a = Task { try await pipeline.image(for: request(account, query: 2)) }
        try await eventually { await source.calls == 1 }
        let b = Task { try await pipeline.image(for: request(account, query: 7)) }
        try await eventually { await pipeline.snapshot().waiters == 2 }
        b.cancel(); try await eventually { await pipeline.snapshot().cancelledWaiters == 1 }
        await source.release(); await cancelled { _ = try await b.value }
        #expect(try await a.value.context.requestGeneration == 2)
        #expect(await source.calls == 1)
    }
    @Test func soleAbandonedLoadCannotCache() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG(), blocked: true)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
        let load = Task { try await pipeline.image(for: request(account)) }
        try await eventually { await source.calls == 1 }; load.cancel()
        await cancelled { _ = try await load.value }
        await source.release(); try await eventually { await pipeline.snapshot().activeLoads == 0 }
        #expect(await pipeline.snapshot().memoryBytes == 0)
        #expect(await pipeline.diskSnapshot().bytes == 0)
        #expect(await pipeline.snapshot().abandonedLoads == 1)
        #expect(await pipeline.nativeSnapshot().completedDecodes == 0)
        let again = Task { try await pipeline.image(for: request(account)) }
        try await eventually { await source.calls == 2 }; await source.release()
        _ = try await again.value
        #expect(await pipeline.snapshot().memoryBytes > 0)
    }
    @Test func foregroundAuthorityRejectsForgottenOwnerAndRebindBack() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG())
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        let a = try owner(), b = try owner()
        try await pipeline.setAccountGeneration(owner: a, generation: 1)
        _ = try await pipeline.image(for: request(a))
        try await pipeline.setAccountGeneration(owner: b, generation: 2)
        await fails(.staleAccount) { _ = try await pipeline.image(for: request(a)) }
        await fails(.staleAccount) { try await pipeline.setAccountGeneration(owner: a, generation: 2) }
        await fails(.staleAccount) { try await pipeline.setAccountGeneration(owner: a, generation: 1) }
        _ = try await pipeline.image(for: request(b, generation: 2))
        #expect(await source.calls == 2) // No cross-owner cache hit for identical resource.
        try await pipeline.setAccountGeneration(owner: a, generation: 3)
        await fails(.staleAccount) { _ = try await pipeline.image(for: request(a)) }
        _ = try await pipeline.image(for: request(a, generation: 3))
        #expect(await source.calls == 2) // Same-owner retained cache is authorized by new fence.
    }
    @Test func inFlightSwitchRemovalRejectsPublication() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG(), blocked: true)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        let a = try owner(), b = try owner()
        try await pipeline.setAccountGeneration(owner: a, generation: 1)
        let old = Task { try await pipeline.image(for: request(a)) }
        try await eventually { await source.calls == 1 }
        try await pipeline.setAccountGeneration(owner: b, generation: 2)
        let peer = Task { try await pipeline.image(for: request(b, generation: 2)) }
        try await eventually { await source.calls == 2 }
        try await pipeline.removeAccount(accountID: a.account.accountID)
        await source.release()
        await fails(.staleAccount) { _ = try await old.value }
        _ = try await peer.value
        try await eventually { await pipeline.snapshot().activeLoads == 0 }
        #expect(await pipeline.snapshot().decodes == 1)
        await fails(.staleAccount) { try await pipeline.setAccountGeneration(owner: a, generation: 3) }
        let diskNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!diskNames.contains { $0.hasPrefix(artworkDigest(a.account.accountID.uuidString)) })
        #expect(diskNames.count == 1)
    }
    @Test func accountRemovalPurgesAllChannelVariants() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG())
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        let a = try owner()
        try await pipeline.setAccountGeneration(owner: a, generation: 1)
        _ = try await pipeline.image(for: request(a))
        let channel = ArtworkOwner(account: try AccountContext(accountID: a.account.accountID, channelID: ID("other-channel"), region: "GB"))
        try await pipeline.setAccountGeneration(owner: channel, generation: 2)
        _ = try await pipeline.image(for: request(channel, generation: 2))
        #expect(await pipeline.diskSnapshot().entries == 2)
        try await pipeline.removeAccount(accountID: a.account.accountID)
        #expect(await pipeline.diskSnapshot().bytes == 0); #expect(await pipeline.snapshot().memoryBytes == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test func sourcePolicyIntersectionAndExpiration() async throws {
        for sourcePolicy in [ArtworkCachePolicy.noStore, memoryPolicy, ArtworkCachePolicy.disk(until: .distantPast)] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let source = Source(try syntheticPNG(), policy: sourcePolicy)
            let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
            let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
            _ = try await pipeline.image(for: request(account))
            _ = try await pipeline.image(for: request(account))
            #expect(await pipeline.diskSnapshot().bytes == 0)
            #expect(await source.calls == (sourcePolicy == memoryPolicy ? 1 : 2))
        }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG())
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
        _ = try await pipeline.image(for: request(account, policy: .noStore))
        #expect(await pipeline.snapshot().memoryBytes == 0); #expect(await pipeline.diskSnapshot().bytes == 0)
    }
    @Test func diskReuseAndCorruptionRecoverWithoutPrivateFallback() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG())
        let account = try owner()
        let first = ArtworkPipeline(source: source, diskDirectory: root)
        try await first.setAccountGeneration(owner: account, generation: 1)
        let initial = try await first.image(for: request(account))
        let second = ArtworkPipeline(source: source, diskDirectory: root)
        try await second.setAccountGeneration(owner: account, generation: 2)
        let cached = try await second.image(for: request(account, generation: 2))
        #expect(cached.image.palette == initial.image.palette)
        #expect(await second.snapshot().diskHits == 1); #expect(await second.snapshot().paletteExtractions == 0)
        #expect(await source.calls == 1)
        let path = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("not an image or plist".utf8).write(to: path)
        let third = ArtworkPipeline(source: source, diskDirectory: root)
        try await third.setAccountGeneration(owner: account, generation: 3)
        _ = try await third.image(for: request(account, generation: 3))
        #expect(await source.calls == 2)
        #expect(await third.diskSnapshot().corruptions > 0)
    }
    @Test func actualMemoryCeilingAndPressure() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG(width: 2048, height: 2048), policy: memoryPolicy)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
        for i in 0..<18 { _ = try await pipeline.image(for: request(account, id: "memory-\(i)", width: 512, height: 512, policy: memoryPolicy)) }
        let stats = await pipeline.snapshot()
        #expect(stats.largestDecodedBytes == 4 * 1024 * 1024)
        #expect(stats.memoryBytes == 64 * 1024 * 1024)
        #expect(stats.peakMemoryBytes == 64 * 1024 * 1024); #expect(stats.memoryEvictions == 2)
        await pipeline.handlePressure(.warning)
        #expect(await pipeline.snapshot().memoryBytes == 32 * 1024 * 1024)
        await pipeline.handlePressure(.critical)
        #expect(await pipeline.snapshot().memoryBytes == 0)
        await pipeline.startPressureMonitoring(); await pipeline.stopPressureMonitoring()
        print("ARTWORK memory actualOutputRaster=4194304 requests=18 peakRetained=\(stats.peakMemoryBytes) evictions=\(stats.memoryEvictions) warningRetained=33554432 criticalRetained=0")
    }
    @Test func admissionBoundsAndQueuedCancellation() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG(), blocked: true)
        let config = try ArtworkConfiguration(maximumConcurrentLoads: 2, maximumPendingLoads: 3, maximumWaiters: 128)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root, configuration: config)
        let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
        let a = Task { try await pipeline.image(for: request(account, id: "one")) }
        let b = Task { try await pipeline.image(for: request(account, id: "two")) }
        try await eventually { await source.calls == 2 }
        let c = Task { try await pipeline.image(for: request(account, id: "three")) }
        try await eventually { await pipeline.snapshot().pendingLoads == 1 }
        await fails(.overloaded) { _ = try await pipeline.image(for: request(account, id: "four")) }
        c.cancel(); await cancelled { _ = try await c.value }
        a.cancel(); b.cancel(); await cancelled { _ = try await a.value }; await cancelled { _ = try await b.value }
        // Cancelled but uncooperative sources still occupy their actual admission slots.
        #expect(await pipeline.snapshot().activeLoads == 2)
        await source.release(); try await eventually { await pipeline.snapshot().activeLoads == 0 }
        #expect(await source.calls == 2); #expect(await pipeline.snapshot().peakActiveLoads == 2)
        #expect(await pipeline.snapshot().pendingLoads == 0)
    }
    @Test func badBytesOversizeDimensionsAndUnavailableStorage() async throws {
        for (bytes, expected) in [(Data("<html>not artwork</html>".utf8), ArtworkError.invalidImage), (Data(repeating: 0, count: 8 * 1024 * 1024 + 1), .inputTooLarge), (try syntheticPNG(width: 1024, height: 1024), .dimensionsExceeded)] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let pipeline = ArtworkPipeline(source: Source(bytes), diskDirectory: root, configuration: try ArtworkConfiguration(maximumSourcePixels: 100_000))
            let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
            await fails(expected) { _ = try await pipeline.image(for: request(account)) }
            #expect(await pipeline.snapshot().memoryBytes == 0); #expect(await pipeline.diskSnapshot().bytes == 0)
        }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"); try Data([1]).write(to: file)
        let pipeline = ArtworkPipeline(source: Source(try syntheticPNG()), diskDirectory: file.appendingPathComponent("not-a-directory"))
        let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
        _ = try await pipeline.image(for: request(account)) // Storage failure is a visible counter, graceful memory-only result.
        #expect(await pipeline.diskSnapshot().failures >= 1)
        #expect(await pipeline.snapshot().memoryBytes > 0)
        await fails(.storageUnavailable) { try await pipeline.removeAccount(accountID: account.account.accountID) }
        await fails(.staleAccount) { _ = try await pipeline.image(for: request(account)) }
    }
}

extension ArtworkTests {
    @Test func boundedIncrementalDemandWithoutBackgroundWork() {
        #expect(ArtworkDemandWindow.indices(visible: 100..<110, totalCount: 50_000) == Array(98..<112))
        #expect(ArtworkDemandWindow.indices(visible: 0..<50_000, totalCount: 50_000).count == 24)
        #expect(ArtworkDemandWindow.indices(visible: 0..<50_000, totalCount: 50_000, isVisible: false).isEmpty)
        #expect(ArtworkDemandWindow.indices(visible: (Int.max-2)..<Int.max, totalCount: Int.max) == Array((Int.max-4)..<Int.max))
        #expect(ArtworkDemandWindow.indices(visible: 5..<5, totalCount: 50_000).isEmpty)
    }
    @Test func sourceFailureIsTypedAndDiagnosticsDoNotEscape() async throws {
        for typed in [false, true] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try owner()
            let pipeline = ArtworkPipeline(source: FailingSource(typed: typed), diskDirectory: root)
            try await pipeline.setAccountGeneration(owner: account, generation: 1)
            do { _ = try await pipeline.image(for: request(account)); Issue.record("Expected source failure") }
            catch {
                if typed { #expect(error as? DomainError == .offline) }
                else { #expect(error as? ArtworkError == .sourceUnavailable) }
                #expect(!String(describing: error).contains("private-provider"))
            }
            #expect(await pipeline.snapshot().sourceLoads == 1)
            #expect(await pipeline.snapshot().memoryBytes == 0)
        }
    }
    @Test func expiryPurgesExistingMemoryAndDiskOnDemand() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(Date())
        let policy = ArtworkCachePolicy.disk(until: clock.now().addingTimeInterval(10))
        let source = Source(try syntheticPNG(), policy: policy)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root, clock: clock)
        let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
        _ = try await pipeline.image(for: request(account, policy: policy))
        #expect(await pipeline.snapshot().memoryBytes > 0)
        #expect(await pipeline.diskSnapshot().bytes > 0)
        clock.advance(11)
        try await pipeline.purgeExpired()
        #expect(await pipeline.snapshot().memoryBytes == 0)
        #expect(await pipeline.diskSnapshot().bytes == 0)
        _ = try await pipeline.image(for: request(account, policy: policy))
        #expect(await source.calls == 2)
        #expect(await pipeline.snapshot().memoryBytes == 0)
    }
    @Test func pressureCancelsPendingWorkAndNoStoreNeverCoalescesWithRetainedPolicy() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG(), blocked: true)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
        let a = Task { try await pipeline.image(for: request(account)) }
        let b = Task { try await pipeline.image(for: request(account, policy: .noStore)) }
        try await eventually { await source.calls == 2 }
        await pipeline.handlePressure(.critical)
        await fails(.pressureRevoked) { _ = try await a.value }; await fails(.pressureRevoked) { _ = try await b.value }
        await source.release(); try await eventually { await pipeline.snapshot().activeLoads == 0 }
        #expect(await pipeline.snapshot().memoryBytes == 0)
        #expect(await pipeline.diskSnapshot().bytes == 0)
    }
    @Test func cancelledBeforeAdmissionAndInvalidPolicyDoNotLoad() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Source(try syntheticPNG())
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        let account = try owner(); try await pipeline.setAccountGeneration(owner: account, generation: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.image(for: request(account))
        }
        await cancelled { _ = try await task.value }
        await fails(.invalidPolicy) { _ = try await pipeline.image(for: request(account, policy: .disk(until: Date(timeIntervalSince1970: .infinity)))) }
        #expect(await source.calls == 0)
    }
    @Test func staticSingleFrameAndRotatedNativeInput() async throws {
        let decoder = ArtworkDecoder()
        let png = try syntheticPNG(width: 512, height: 256)
        let source = CGImageSourceCreateWithData(png as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let animated = NSMutableData()
        let gif = CGImageDestinationCreateWithData(animated, UTType.gif.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(gif, image, nil); CGImageDestinationAddImage(gif, image, nil)
        #expect(CGImageDestinationFinalize(gif))
        await fails(.invalidImage) { _ = try await decoder.decode(animated as Data, size: ArtworkSize(pointsWidth: 64, pointsHeight: 64, scale: 1), configuration: .default, persist: false) }
        let jpeg = NSMutableData()
        let target = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(target, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(target))
        let rotated = try await decoder.decode(jpeg as Data, size: ArtworkSize(pointsWidth: 64, pointsHeight: 128, scale: 1), configuration: .default, persist: false)
        #expect(rotated.image.cgImage.width == 64); #expect(rotated.image.cgImage.height == 128)
        let stats = await decoder.snapshot()
        #expect(stats.decodeAttempts == 2); #expect(stats.completedDecodes == 1)
        #expect(stats.mainThreadWorkViolations == 0)
    }
}

extension ArtworkTests {
    @Test func signedOutAuthorityRejectsRetainedFacadeUntilNewGeneration() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try owner(), source = Source(try syntheticPNG())
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        try await pipeline.setAccountGeneration(owner: account, generation: 1)
        _ = try await pipeline.image(for: request(account))
        try await pipeline.invalidateForeground(generation: 2)
        try await pipeline.invalidateForeground(generation: 2) // Idempotent signed-out publication.
        await fails(.staleAccount) { _ = try await pipeline.image(for: request(account)) }
        await fails(.staleAccount) { try await pipeline.setAccountGeneration(owner: account, generation: 2) }
        try await pipeline.setAccountGeneration(owner: account, generation: 3)
        _ = try await pipeline.image(for: request(account, generation: 3))
        #expect(await source.calls == 1)
    }
}

extension ArtworkTests {
    @Test func entryCeilingsEvictBeforeByteCeilings() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try owner(), source = Source(try syntheticPNG())
        let config = try ArtworkConfiguration(maximumEntries: 2)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root, configuration: config)
        try await pipeline.setAccountGeneration(owner: account, generation: 1)
        for id in ["first", "second", "third"] { _ = try await pipeline.image(for: request(account, id: id)) }
        #expect(await pipeline.snapshot().memoryBytes == 2 * 128 * 64 * 4)
        #expect(await pipeline.snapshot().memoryEvictions == 1)
        #expect(await pipeline.diskSnapshot().entries == 2)
        #expect(await pipeline.diskSnapshot().evictions == 1)
        _ = try await pipeline.image(for: request(account, id: "first"))
        #expect(await source.calls == 4)
    }
    @Test func waiterBoundIsIndependentOfDistinctLoadBound() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try owner(), source = Source(try syntheticPNG(), blocked: true)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root, configuration: try ArtworkConfiguration(maximumWaiters: 2))
        try await pipeline.setAccountGeneration(owner: account, generation: 1)
        let first = Task { try await pipeline.image(for: request(account, query: 1)) }
        try await eventually { await source.calls == 1 }
        let second = Task { try await pipeline.image(for: request(account, query: 2)) }
        try await eventually { await pipeline.snapshot().waiters == 2 }
        await fails(.overloaded) { _ = try await pipeline.image(for: request(account, query: 3)) }
        #expect(await source.calls == 1)
        first.cancel(); second.cancel()
        await cancelled { _ = try await first.value }; await cancelled { _ = try await second.value }
        await source.release(); try await eventually { await pipeline.snapshot().activeLoads == 0 }
        #expect(await pipeline.snapshot().memoryBytes == 0)
    }
}

extension ArtworkTests {
    @Test func unusableRootThreeReadsAreStorageFailuresNotCorruptEntries() async throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real"), alias = base.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let account = try owner()
        // Requested disk reads reach prepare; source then restricts retention to memory,
        // so exactly three reads (and no disk writes) fail at the symlinked ROOT.
        let pipeline = ArtworkPipeline(source: Source(try syntheticPNG(), policy: memoryPolicy), diskDirectory: alias)
        try await pipeline.setAccountGeneration(owner: account, generation: 1)
        for id in ["root-one", "root-two", "root-three"] { _ = try await pipeline.image(for: request(account, id: id)) }
        let stats = await pipeline.diskSnapshot()
        print("REWORK R8 rootReads=3 failures=\(stats.failures) corruptions=\(stats.corruptions) entries=\(stats.entries)")
        #expect(stats.failures == 3); #expect(stats.corruptions == 0); #expect(stats.entries == 0)
        #expect(await pipeline.snapshot().memoryBytes > 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
    }
}

extension ArtworkTests {
    @Test func pressureRevocationIsDistinctAndExplicitCurrentRetrySucceeds() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try owner(), source = Source(try syntheticPNG(), blocked: true)
        let pipeline = ArtworkPipeline(source: source, diskDirectory: root)
        try await pipeline.setAccountGeneration(owner: account, generation: 1)
        let creator = Task { try await pipeline.image(for: request(account, query: 1)) }
        try await eventually { await source.calls == 1 }
        let peer = Task { try await pipeline.image(for: request(account, query: 9)) }
        try await eventually { await pipeline.snapshot().waiters == 2 }
        creator.cancel()
        await cancelled { _ = try await creator.value }
        await pipeline.handlePressure(.warning)
        await fails(.pressureRevoked) { _ = try await peer.value }
        await source.release()
        try await eventually { await pipeline.snapshot().activeLoads == 0 }
        #expect(await pipeline.snapshot().memoryBytes == 0)
        #expect(await pipeline.diskSnapshot().bytes == 0)
        // Pipeline never retries/polls by itself. Still-current consumer explicitly re-requests.
        #expect(await source.calls == 1)
        let retry = Task { try await pipeline.image(for: request(account, query: 9)) }
        try await eventually { await source.calls == 2 }; await source.release()
        #expect(try await retry.value.context.requestGeneration == 9)
        try await pipeline.invalidateForeground(generation: 2)
        await fails(.staleAccount) { _ = try await pipeline.image(for: request(account, query: 9)) }
    }
}
