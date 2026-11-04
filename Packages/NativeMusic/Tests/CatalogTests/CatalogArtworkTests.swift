import AccountSession
import Artwork
import CoreGraphics
import Domain
import Features
import Foundation
import ImageIO
import Observation
import Testing
import UniformTypeIdentifiers

@Suite struct CatalogArtworkSourceTests {
    private func thumbs(_ widths: [Int], host: String = "yt3.googleusercontent.com") -> [MusicThumbnail] {
        widths.map { MusicThumbnail(url: URL(string: "https://\(host)/img=w\($0)-h\($0)")!, width: $0, height: $0) }
    }
    private func png(_ edge: Int = 8) throws -> Data {
        var bytes = [UInt8](repeating: 200, count: edge * edge * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        let image = CGImage(width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: edge * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(bytes) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ArtworkError.invalidImage }
        return data as Data
    }
    @Test func theSmallestSufficientThumbnailIsChosenElseTheLargest() {
        #expect(CatalogArtworkSource.choose(thumbs([60, 226, 544]))?.width == 226)
        #expect(CatalogArtworkSource.choose(thumbs([544, 120, 226]))?.width == 226)
        #expect(CatalogArtworkSource.choose(thumbs([60, 120]))?.width == 120)
        #expect(CatalogArtworkSource.choose([]) == nil)
    }
    @Test func registrationIsDeterministicOpaqueAndNeverAURL() throws {
        let source = CatalogArtworkSource { _ in Data() }
        let a = try #require(source.register(thumbs([226, 544])))
        let b = try #require(source.register(thumbs([226, 544])))
        #expect(a == b && a.namespace == "ytm-catalog" && a.revision == "1")
        #expect(a.identifier.count == 40 && !a.identifier.contains("/") && !a.identifier.contains("googleusercontent"))
        #expect(source.register(thumbs([226], host: "i.ytimg.com")) != a)
        #expect(source.register([]) == nil)
    }
    @Test func loadFetchesTheRegisteredURLThroughTheInjectedBoundedFetch() async throws {
        let fetched = LockedBox<[URL]>([])
        let bytes = Data([1, 2, 3])
        let source = CatalogArtworkSource { url in fetched.mutate { $0.append(url) }; return bytes }
        let resource = try #require(source.register(thumbs([226, 544])))
        let owner = ArtworkOwner(account: try AccountContext(accountID: UUID(), channelID: ID("catalog-art"), region: "US"))
        let data = try await source.load(resource: resource, owner: owner, generation: 1, maximumBytes: 1024)
        #expect(data.bytes == bytes && fetched.value.map(\.absoluteString) == ["https://yt3.googleusercontent.com/img=w226-h226"])
        guard case .memory = data.policy else { Issue.record("catalog artwork is retained in memory only"); return }
    }
    @Test func foreignUnknownFailingAndOversizedResourcesAreRefused() async throws {
        let owner = ArtworkOwner(account: try AccountContext(accountID: UUID(), channelID: ID("catalog-art"), region: "US"))
        let source = CatalogArtworkSource { _ in Data(count: 100) }
        let foreign = try ArtworkResource(namespace: "other", identifier: "x", revision: "1")
        await #expect(throws: ArtworkError.invalidResource) { try await source.load(resource: foreign, owner: owner, generation: 1, maximumBytes: 1024) }
        let unknown = try ArtworkResource(namespace: "ytm-catalog", identifier: "never-registered", revision: "1")
        await #expect(throws: ArtworkError.sourceUnavailable) { try await source.load(resource: unknown, owner: owner, generation: 1, maximumBytes: 1024) }
        let resource = try #require(source.register(thumbs([226])))
        await #expect(throws: ArtworkError.inputTooLarge) { try await source.load(resource: resource, owner: owner, generation: 1, maximumBytes: 50) }
        let failing = CatalogArtworkSource { _ in throw MusicSessionError.network }
        let failingResource = try #require(failing.register(thumbs([226])))
        await #expect(throws: ArtworkError.sourceUnavailable) { try await failing.load(resource: failingResource, owner: owner, generation: 1, maximumBytes: 1024) }
    }
    @Test func theRegistryIsBounded() async throws {
        let source = CatalogArtworkSource(capacity: 2) { _ in Data() }
        let owner = ArtworkOwner(account: try AccountContext(accountID: UUID(), channelID: ID("catalog-art"), region: "US"))
        let first = try #require(source.register([MusicThumbnail(url: URL(string: "https://i.ytimg.com/a")!, width: 300, height: 300)]))
        _ = source.register([MusicThumbnail(url: URL(string: "https://i.ytimg.com/b")!, width: 300, height: 300)])
        _ = source.register([MusicThumbnail(url: URL(string: "https://i.ytimg.com/c")!, width: 300, height: 300)])
        await #expect(throws: ArtworkError.sourceUnavailable) { try await source.load(resource: first, owner: owner, generation: 1, maximumBytes: 1024) }
    }
    @Test func theBoundedPipelineDecodesCatalogArtworkForTheActiveAccountOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ytmuse-w11-art-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try png()
        let source = CatalogArtworkSource { _ in image }
        let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
        let account = try AccountContext(accountID: UUID(), channelID: ID("catalog-art"), region: "US")
        try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account), generation: 1)
        let context = RequestContext(account: account, accountGeneration: 1, requestGeneration: 1)
        let resource = try #require(source.register(thumbs([226])))
        let request = ArtworkRequest(resource: resource, size: try ArtworkSize(pointsWidth: 4, pointsHeight: 4, scale: 1), policy: .memory(until: Date().addingTimeInterval(60)), context: context)
        let response = try await pipeline.image(for: request)
        #expect(response.image.cgImage.width > 0 && response.context == context)
        // A request for another account generation is refused by the pipeline's own fence.
        let stale = RequestContext(account: account, accountGeneration: 0, requestGeneration: 1)
        await #expect(throws: (any Error).self) { try await pipeline.image(for: ArtworkRequest(resource: resource, size: request.size, policy: request.policy, context: stale)) }
        // No third-party image was written to disk (memory-only policy).
        let written = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(written.filter { $0.hasSuffix(".png") || $0.hasSuffix(".art") }.isEmpty, "\(written)")
    }
}
final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}

@MainActor @Suite struct CatalogArtworkRequestStabilityTests {
    private final class Clock { var now = Date(timeIntervalSince1970: 10_000) }
    private func thumbnails(_ name: String) -> [MusicThumbnail] {
        [MusicThumbnail(url: URL(string: "https://i.ytimg.com/\(name)")!, width: 300, height: 300)]
    }
    private func context(_ generation: UInt64 = 1) throws -> RequestContext {
        RequestContext(account: try AccountContext(accountID: UUID(), channelID: ID("lease"), region: "US"), accountGeneration: generation, requestGeneration: 1)
    }
    @Test func redrawsKeepIdentityUntilTheRealDeadlineThenRenew() throws {
        let clock = Clock(), authority = ArtworkUIAuthority()
        let source = CatalogArtworkSource { _ in Data() }
        let pipeline = ArtworkPipeline(source: source, diskDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(authority.bind(try context()))
        let artwork = CatalogArtwork(pipeline: pipeline, authority: authority, source: source, clock: { clock.now })
        let first = try #require(artwork.request(for: thumbnails("a")))
        let published = LockedBox(false)
        withObservationTracking {
            _ = artwork.request(for: thumbnails("a"))
        } onChange: { published.mutate { $0 = true } }
        _ = artwork.request(for: thumbnails("b"))
        #expect(!published.value, "request bookkeeping must not publish changes during body evaluation")
        for _ in 0..<100 {
            clock.now.addTimeInterval(1)
            let redraw = try #require(artwork.request(for: thumbnails("a")))
            #expect(redraw.policy == first.policy)
            #expect(ArtworkImageIdentity(redraw) == ArtworkImageIdentity(first))
            #expect(redraw.size == first.size)
        }
        let small = try #require(ArtworkDisplayRequest.make(first, width: 44, height: 44, scale: 2))
        let large = try #require(ArtworkDisplayRequest.make(first, width: 200, height: 200, scale: 2))
        #expect(small.size != large.size)
        #expect(small.policy == large.policy && ArtworkImageIdentity(small) == ArtworkImageIdentity(large), "size-only fallback keeps the same cover identity")
        clock.now = Date(timeIntervalSince1970: 11_800)
        let renewed = try #require(artwork.request(for: thumbnails("a")))
        #expect(renewed.policy == .memory(until: clock.now.addingTimeInterval(1800)))
        #expect(ArtworkImageIdentity(renewed) != ArtworkImageIdentity(first))
        #expect(artwork.request(for: []) == nil)
    }
    @Test func resourcesOwnersGenerationsRemovalAndCapacityAreFenced() throws {
        let clock = Clock(), authority = ArtworkUIAuthority()
        let source = CatalogArtworkSource { _ in Data() }
        let pipeline = ArtworkPipeline(source: source, diskDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let owner = try context()
        #expect(authority.bind(owner))
        let artwork = CatalogArtwork(pipeline: pipeline, authority: authority, source: source, requestCapacity: 2, clock: { clock.now })
        let a = try #require(artwork.request(for: thumbnails("a")))
        clock.now.addTimeInterval(1)
        let b = try #require(artwork.request(for: thumbnails("b")))
        #expect(a.resource != b.resource)
        #expect(ArtworkImageIdentity(a) != ArtworkImageIdentity(b))
        _ = artwork.request(for: thumbnails("c"))
        clock.now.addTimeInterval(1)
        #expect(try #require(artwork.request(for: thumbnails("a"))).policy != a.policy, "the oldest lease was evicted at capacity")
        let next = RequestContext(account: owner.account, accountGeneration: 2, requestGeneration: 1)
        #expect(authority.bind(next))
        let generation = try #require(artwork.request(for: thumbnails("a")))
        #expect(generation.context == next && ArtworkImageIdentity(generation) != ArtworkImageIdentity(a))
        let other = try context(3)
        #expect(authority.bind(other))
        let switched = try #require(artwork.request(for: thumbnails("a")))
        #expect(switched.context == other && ArtworkImageIdentity(switched) != ArtworkImageIdentity(generation))
        authority.removeAccount(try #require(other.account).accountID)
        #expect(artwork.request(for: thumbnails("a")) == nil)
        artwork.pipeline = nil
        #expect(artwork.request(for: thumbnails("a")) == nil)
    }
}
