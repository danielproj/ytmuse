import Foundation
import ImageIO
import UniformTypeIdentifiers

// W25 (MAC06). The widget's one picture: a small JPEG thumbnail, decoded from the bytes the app already holds. No URL is ever fetched here.
public enum WidgetArtwork {
    public static let edge = 192
    /// A square-bounded JPEG of at most `limit` bytes, or nil if the bytes are not an image or cannot be made small enough.
    public static func thumbnail(from data: Data, limit: Int = WidgetSnapshot.artworkByteLimit) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: edge]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        for quality in [0.7, 0.5, 0.35, 0.2] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= limit { return output as Data }
        }
        return nil
    }
}
