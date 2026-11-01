import AccountSession
import Artwork
import CoreGraphics
import Domain
import Features
import Foundation
import ImageIO
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
