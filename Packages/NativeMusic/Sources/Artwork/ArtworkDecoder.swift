import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct DecodedArtwork: Sendable {
    let image: ArtworkImage
    let png: Data
    let offMain: Bool
}
/// Serial native work executor bounds simultaneous ImageIO decode and palette buffers.
actor ArtworkDecoder {
    private var counters = ArtworkNativeCounters()
    func snapshot() -> ArtworkNativeCounters { counters }
    func decode(_ bytes: Data, size: ArtworkSize, configuration: ArtworkConfiguration, persist: Bool, savedPalette: ArtworkPalette? = nil) throws -> DecodedArtwork {
        try Task.checkCancellation()
        counters.decodeAttempts += 1
        counters.largestInputBytes = max(counters.largestInputBytes, bytes.count)
        if Thread.isMainThread { counters.mainThreadWorkViolations += 1 }
        guard bytes.count <= configuration.maximumInputBytes else { throw ArtworkError.inputTooLarge }
        guard !bytes.isEmpty,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.tiff.identifier].contains(type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ArtworkError.invalidImage }
        guard width > 0, height > 0, width <= 32768, height <= 32768,
              width <= configuration.maximumSourcePixels / height else { throw ArtworkError.dimensionsExceeded }
        // Fit within BOTH display dimensions, accounting for EXIF rotation. No original full decode.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        let w = rotated ? height : width, h = rotated ? width : height
        let factor = min(1, min(Double(size.pixelWidth) / Double(w), Double(size.pixelHeight) / Double(h)))
        let longest = max(1, Int(floor(Double(max(w, h)) * factor)))
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest
        ] as CFDictionary), thumbnail.width <= size.pixelWidth, thumbnail.height <= size.pixelHeight,
              thumbnail.bitsPerPixel <= 64 else { throw ArtworkError.invalidImage }
        try Task.checkCancellation()
        // Normalize to an eager 8-bit sRGB raster: actual row-stride costs are the cache oracle.
        guard let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height, bitsPerComponent: 8,
                                      bytesPerRow: thumbnail.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ArtworkError.invalidImage }
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        guard let image = context.makeImage() else { throw ArtworkError.invalidImage }
        let palette = try savedPalette ?? palette(image)
        if savedPalette == nil { counters.paletteExtractions += 1 }
        var encoded = Data()
        if persist {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw ArtworkError.invalidImage }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ArtworkError.invalidImage }
            encoded = output as Data
        }
        counters.completedDecodes += 1
        counters.largestRasterBytes = max(counters.largestRasterBytes, image.bytesPerRow * image.height)
        return DecodedArtwork(image: ArtworkImage(cgImage: image, palette: palette), png: encoded, offMain: !Thread.isMainThread)
    }
    private func palette(_ image: CGImage) throws -> ArtworkPalette {
        var pixel = [UInt8](repeating: 0, count: 4)
        let success = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        guard success else { throw ArtworkError.invalidImage }
        let alpha = max(1, Double(pixel[3]))
        // Blend toward neutral, with bounded opacity; never use this as an essential text color.
        return ArtworkPalette(red: min(1, Double(pixel[0]) / alpha) * 0.65 + 0.175,
                              green: min(1, Double(pixel[1]) / alpha) * 0.65 + 0.175,
                              blue: min(1, Double(pixel[2]) / alpha) * 0.65 + 0.175, opacity: 0.22)
    }
}
