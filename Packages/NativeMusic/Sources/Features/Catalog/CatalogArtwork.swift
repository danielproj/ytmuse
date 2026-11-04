import AccountSession
import Artwork
import CryptoKit
import Domain
import DesignSystem
import Foundation
import Observation
import SwiftUI

/// Maps adapter-issued artwork identities to the thumbnail URLs the service published, and loads them through the
/// bounded `ArtworkPipeline`. The pipeline only ever sees an opaque `ArtworkResource`; the URL lives here, the fetch
/// (exact image hosts, byte cap, no credentials) is injected by the composition. Bytes are retained in memory only.
public final class CatalogArtworkSource: ArtworkSource, @unchecked Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public static let namespace = "ytm-catalog"
    private let fetch: Fetch
    private let lock = NSLock()
    private var urls: [String: URL] = [:]
    private var order: [String] = []
    private let capacity: Int
    public init(capacity: Int = 4096, fetch: @escaping Fetch) { self.capacity = max(1, capacity); self.fetch = fetch }

    /// Remembers the best thumbnail for an entry and returns its pipeline identity (nil when none was published).
    public func register(_ thumbnails: [MusicThumbnail]) -> ArtworkResource? {
        guard let best = Self.choose(thumbnails) else { return nil }
        let id = SHA256.hash(data: Data(best.url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40)
        lock.withLock {
            if urls[String(id)] == nil {
                urls[String(id)] = best.url; order.append(String(id))
                while order.count > capacity { urls[order.removeFirst()] = nil }
            }
        }
        return try? ArtworkResource(namespace: Self.namespace, identifier: String(id), revision: "1")
    }
    /// The smallest published image at least 226 px wide (enough for a 160 pt card at 1x and sharp enough at 2x once
    /// decoded to size), else the largest there is.
    public static func choose(_ thumbnails: [MusicThumbnail]) -> MusicThumbnail? {
        let sorted = thumbnails.sorted { $0.width < $1.width }
        return sorted.first { $0.width >= 226 } ?? sorted.last
    }
    public func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData {
        guard resource.namespace == Self.namespace else { throw ArtworkError.invalidResource }
        let url = lock.withLock { urls[resource.identifier] }
        guard let url else { throw ArtworkError.sourceUnavailable }
        let data: Data
        do { data = try await fetch(url) } catch is CancellationError { throw CancellationError() } catch { throw ArtworkError.sourceUnavailable }
        guard data.count <= maximumBytes else { throw ArtworkError.inputTooLarge }
        return ArtworkSourceData(bytes: data, policy: .memory(until: Date().addingTimeInterval(1800)))
    }
}

/// What catalog views need to draw artwork: the shared pipeline, the UI authority, and the source that knows the URLs.
@MainActor @Observable public final class CatalogArtwork {
    public var pipeline: ArtworkPipeline?
    public let authority: ArtworkUIAuthority
    @ObservationIgnored public let source: CatalogArtworkSource?
    // Non-observable bookkeeping: body may read a request without publishing a view mutation.
    @ObservationIgnored private var leases: [ArtworkResource: Date] = [:]
    @ObservationIgnored private var leaseOrder: [ArtworkResource] = []
    @ObservationIgnored private var leaseContext: RequestContext?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let requestCapacity: Int
    public init(pipeline: ArtworkPipeline?, authority: ArtworkUIAuthority, source: CatalogArtworkSource?, requestCapacity: Int = 4096, clock: @escaping () -> Date = Date.init) {
        self.pipeline = pipeline; self.authority = authority; self.source = source
        self.requestCapacity = max(1, requestCapacity); self.clock = clock
    }
    /// A request template for an entry's thumbnails, or nil (placeholder art) when there is no image, no source, or no
    /// account owning the pipeline yet.
    public func request(for thumbnails: [MusicThumbnail]) -> ArtworkRequest? {
        let context = authority.context
        if leaseContext != context || !authority.accepts(context) || pipeline == nil {
            leases.removeAll(); leaseOrder.removeAll(); leaseContext = context
        }
        guard pipeline != nil, authority.accepts(context), let source, let resource = source.register(thumbnails),
              let size = try? ArtworkSize(pointsWidth: 1, pointsHeight: 1, scale: 1) else { return nil }
        let now = clock()
        let deadline: Date
        if let held = leases[resource], held > now { deadline = held }
        else {
            // Expired leases cannot extend old pixels' retention. A renewed request has a new identity;
            // the pipeline still intersects this deadline with the source response's real deadline.
            leases = leases.filter { $0.value > now }
            leaseOrder.removeAll { leases[$0] == nil }
            while leaseOrder.count >= requestCapacity { leases[leaseOrder.removeFirst()] = nil }
            deadline = now.addingTimeInterval(1800)
            leases[resource] = deadline; leaseOrder.append(resource)
        }
        return ArtworkRequest(resource: resource, size: size, policy: .memory(until: deadline), context: context)
    }
}
private struct CatalogArtworkKey: EnvironmentKey { static let defaultValue: CatalogArtwork? = nil }
extension EnvironmentValues {
    public var catalogArtwork: CatalogArtwork? {
        get { self[CatalogArtworkKey.self] }
        set { self[CatalogArtworkKey.self] = newValue }
    }
}

/// An entry's artwork at a fixed edge through the bounded pipeline; static original art when there is none.
public struct CatalogArtworkView: View {
    let thumbnails: [MusicThumbnail]
    let edge: CGFloat
    var corner: MusicCorner = .artwork
    @Environment(\.catalogArtwork) private var artwork
    public init(thumbnails: [MusicThumbnail], edge: CGFloat, corner: MusicCorner = .artwork) { self.thumbnails = thumbnails; self.edge = edge; self.corner = corner }
    public var body: some View {
        Group {
            if let artwork, let request = artwork.request(for: thumbnails) {
                NativeArtworkView(pipeline: artwork.pipeline, request: request, authority: artwork.authority, visible: true)
            } else { ResonanceArtwork() }
        }.frame(width: edge, height: edge).musicClip(corner).accessibilityHidden(true)
    }
}
