import Foundation
import ImageIO
import Domain

/// Feature-local failures never change playback/session state. Run decoding on this actor, off MainActor.
public actor NetworkDecoder {
    public init() {}
    public func json<T: Decodable & Sendable>(_ type: T.Type, response: BoundedResponse, bounds: ResponseBounds) throws -> T {
        guard response.body.count <= bounds.bytes else { throw NetworkFault.oversized }
        let mime = response.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard mime == "application/json" || mime?.hasSuffix("+json") == true else { throw NetworkFault.contentType }
        // Check nesting BEFORE Foundation allocates a recursive object graph. Strings do not count as syntax.
        var depth = 0, nodes = 0, quoted = false, escaped = false
        for byte in response.body {
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else {
                if byte == 34 { quoted = true; nodes += 1 }
                if byte == 123 || byte == 91 { depth += 1; nodes += 1 }
                if byte == 125 || byte == 93 { depth -= 1 }
                if byte == 44 || byte == 58 { nodes += 1 }
                guard depth >= 0, depth <= bounds.jsonDepth, nodes <= bounds.jsonNodes else { throw NetworkFault.schema }
            }
        }
        do { return try JSONDecoder().decode(type, from: response.body) } catch { throw NetworkFault.schema }
    }
    /// Inspect dimensions before any raster allocation; reject animated/multipage images.
    /// Raster consumers must use bounded thumbnails, never decode the original behind this check.
    public func imageThumbnail(response: BoundedResponse, bounds: ResponseBounds, maximumDimension: Int = 2048) throws -> ImageDimensions {
        guard response.body.count <= bounds.bytes, (1...4096).contains(maximumDimension) else { throw NetworkFault.oversized }
        guard response.contentType?.lowercased().hasPrefix("image/") == true,
              let source = CGImageSourceCreateWithData(response.body as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width <= bounds.imagePixels / height else { throw NetworkFault.image }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension, kCGImageSourceShouldCacheImmediately: false] as CFDictionary),
              image.width <= maximumDimension, image.height <= maximumDimension else { throw NetworkFault.image }
        return ImageDimensions(width: image.width, height: image.height)
    }
}
public struct ImageDimensions: Sendable, Equatable { public let width: Int; public let height: Int }
/// A source adapter must decode its actual operation schema and explicitly produce this verdict.
/// No generic HTTP-200 or missing-field fallback can acknowledge a mutation.
public enum OperationAcknowledgement: Sendable { case confirmed, rejected, indeterminate }

/// Restart deduplication uses occurrence IDs, never media IDs. Distinct duplicates are retained.
public struct OccurrencePageAccumulator<Value: Sendable>: Sendable {
    private var seen: Set<ServiceID> = []
    public private(set) var values: [Value] = []
    public let context: RequestContext
    public let collection: ServiceID
    public init(context: RequestContext, collection: ServiceID) { self.context = context; self.collection = collection }
    public mutating func append(_ rows: [(ServiceID, Value)], cursor: PageCursor?, now: Date) throws {
        if let cursor { try cursor.validate(for: context, collection: collection, now: now) }
        guard values.count + rows.count <= 100_000 else { throw NetworkFault.oversized }
        for (occurrence, value) in rows where seen.insert(occurrence).inserted { values.append(value) }
    }
}
