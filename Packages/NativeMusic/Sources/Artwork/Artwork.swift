import Foundation
import CoreGraphics
import Domain

public enum ArtworkError: Error, Equatable, Sendable {
    case invalidResource, invalidSize, invalidConfiguration, invalidPolicy, staleAccount
    /// Pipeline pressure revocation; a still-current visible consumer may retry once.
    case pressureRevoked
    case sourceUnavailable, overloaded, inputTooLarge, invalidImage, dimensionsExceeded, storageUnavailable
}

/// Opaque adapter-issued identity, including source namespace and content revision.
/// The adapter maps it to an approved remote resource; it is never a path or URL.
public struct ArtworkResource: Hashable, Sendable {
    public let namespace: String
    public let identifier: String
    public let revision: String
    public init(namespace: String, identifier: String, revision: String) throws {
        guard [namespace, identifier, revision].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw ArtworkError.invalidResource }
        self.namespace = namespace; self.identifier = identifier; self.revision = revision
    }
}
public struct ArtworkOwner: Hashable, Sendable {
    public let account: AccountContext
    public init(account: AccountContext) { self.account = account }
}
public struct ArtworkSize: Hashable, Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public init(pointsWidth: Double, pointsHeight: Double, scale: Double) throws {
        guard pointsWidth.isFinite, pointsHeight.isFinite, scale.isFinite,
              pointsWidth > 0, pointsHeight > 0, scale > 0, scale <= 4,
              pointsWidth * scale <= 2048, pointsHeight * scale <= 2048 else { throw ArtworkError.invalidSize }
        pixelWidth = Int(ceil(pointsWidth * scale)); pixelHeight = Int(ceil(pointsHeight * scale))
    }
}
/// Absolute source retention deadline, intersected with the source's response policy.
public enum ArtworkCachePolicy: Hashable, Sendable {
    case noStore
    case memory(until: Date)
    case disk(until: Date)
    var deadline: Date? { switch self { case .noStore: nil; case .memory(let d), .disk(let d): d } }
    var allowsDisk: Bool { if case .disk = self { true } else { false } }
    func restricted(by other: Self) -> Self {
        guard let a = deadline, let b = other.deadline else { return .noStore }
        return allowsDisk && other.allowsDisk ? .disk(until: min(a, b)) : .memory(until: min(a, b))
    }
}
public struct ArtworkSourceData: Sendable {
    public let bytes: Data
    public let policy: ArtworkCachePolicy
    public init(bytes: Data, policy: ArtworkCachePolicy) { self.bytes = bytes; self.policy = policy }
}
/// Inject one query-independent account producer. Enforce the byte bound while receiving,
/// validate remote destinations/redirects in the adapter, and cooperate with Task cancellation.
public protocol ArtworkSource: Sendable {
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData
}
public struct ArtworkRequest: Sendable {
    public let resource: ArtworkResource
    public let size: ArtworkSize
    public let policy: ArtworkCachePolicy
    public let context: RequestContext
    public init(resource: ArtworkResource, size: ArtworkSize, policy: ArtworkCachePolicy, context: RequestContext) {
        self.resource = resource; self.size = size; self.policy = policy; self.context = context
    }
}
public struct ArtworkPalette: Codable, Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    /// Subdued decoration only. Essential foregrounds require independent semantic colors.
    public let opacity: Double
}
/// Immutable native raster; no AppKit/SwiftUI wrapper or animation owner.
public struct ArtworkImage: Sendable {
    public let cgImage: CGImage
    public let palette: ArtworkPalette
    public var byteCost: Int { cgImage.bytesPerRow * cgImage.height }
}
public struct ArtworkResponse: Sendable {
    public let context: RequestContext
    public let image: ArtworkImage
}
public struct ArtworkConfiguration: Sendable {
    public let memoryBytes: Int
    public let diskBytes: Int
    public let maximumInputBytes: Int
    public let maximumSourcePixels: Int
    public let maximumConcurrentLoads: Int
    public let maximumPendingLoads: Int
    public let maximumWaiters: Int
    public let maximumEntries: Int
    public init(memoryBytes: Int = 64 * 1024 * 1024, diskBytes: Int = 512 * 1024 * 1024,
                maximumInputBytes: Int = 8 * 1024 * 1024, maximumSourcePixels: Int = 100_000_000,
                maximumConcurrentLoads: Int = 2, maximumPendingLoads: Int = 32,
                maximumWaiters: Int = 128, maximumEntries: Int = 4096) throws {
        guard (0...64 * 1024 * 1024).contains(memoryBytes), (0...512 * 1024 * 1024).contains(diskBytes),
              (1...8 * 1024 * 1024).contains(maximumInputBytes), (1...100_000_000).contains(maximumSourcePixels),
              (1...2).contains(maximumConcurrentLoads), (1...32).contains(maximumPendingLoads),
              (1...128).contains(maximumWaiters), (1...4096).contains(maximumEntries) else { throw ArtworkError.invalidConfiguration }
        self.memoryBytes = memoryBytes; self.diskBytes = diskBytes; self.maximumInputBytes = maximumInputBytes
        self.maximumSourcePixels = maximumSourcePixels; self.maximumConcurrentLoads = maximumConcurrentLoads
        self.maximumPendingLoads = maximumPendingLoads; self.maximumWaiters = maximumWaiters; self.maximumEntries = maximumEntries
    }
    public static let `default` = try! Self()
}
public enum ArtworkPressure: Sendable { case warning, critical }
public struct ArtworkCounters: Sendable {
    public internal(set) var sourceLoads = 0, coalescedWaiters = 0, cancelledWaiters = 0, abandonedLoads = 0
    public internal(set) var memoryHits = 0, diskHits = 0, decodes = 0, paletteExtractions = 0
    public internal(set) var memoryBytes = 0, peakMemoryBytes = 0, memoryEvictions = 0
    public internal(set) var activeLoads = 0, peakActiveLoads = 0, pendingLoads = 0, waiters = 0
    public internal(set) var decodedBytes = 0, largestDecodedBytes = 0, mainThreadWorkViolations = 0
    public internal(set) var storageFailures = 0
}

/// Pure bounded demand selection for incremental collection consumers. No prefetch task,
/// timer or catalog ownership: the view owns/cancels tasks when this window changes.
public enum ArtworkDemandWindow {
    public static func indices(visible: Range<Int>, totalCount: Int, isVisible: Bool = true,
                               nearby: Int = 2, maximumCount: Int = 24) -> [Int] {
        guard isVisible, totalCount > 0, !visible.isEmpty, nearby >= 0, nearby <= 8,
              maximumCount > 0, maximumCount <= 64, visible.lowerBound >= 0,
              visible.lowerBound < totalCount else { return [] }
        let start = max(0, visible.lowerBound - nearby)
        // Subtractions before addition avoid overflow on untrusted collection bounds.
        let endVisible = min(totalCount, visible.upperBound)
        let end = endVisible + min(nearby, totalCount - endVisible)
        return Array(start..<min(end, start + min(maximumCount, totalCount - start)))
    }
}

public struct ArtworkNativeCounters: Sendable {
    public internal(set) var decodeAttempts = 0, completedDecodes = 0, paletteExtractions = 0
    public internal(set) var largestInputBytes = 0, largestRasterBytes = 0, mainThreadWorkViolations = 0
}
