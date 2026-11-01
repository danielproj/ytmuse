import AppKit
import ImageIO
import DesignSystem

/// The artwork's light for glass (GLASS11): an average of a tiny downsample, weighted toward vivid pixels.
/// It only picks a hue; `MusicTint.glassOpacity` decides how strongly it may wash the glass so text stays legible.
enum ArtworkAccent {
    private static let cache = AccentCache()
    /// Off the main thread (DESIGN05), once per distinct artwork: the bar and Now Playing share the result.
    static func tint(fromData data: Data) async -> MusicTint? {
        let key = data.hashValue
        if let hit = cache.value(for: key) { return hit.tint }
        let result = await Task.detached(priority: .utility) { () -> MusicTint? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return nil }
            return tint(from: image)
        }.value
        cache.store(result, for: key)
        return result
    }
    private final class AccentCache: @unchecked Sendable {
        struct Entry { let tint: MusicTint? }
        private let lock = NSLock(); private var entries: [Int: Entry] = [:]
        func value(for key: Int) -> Entry? { lock.lock(); defer { lock.unlock() }; return entries[key] }
        func store(_ tint: MusicTint?, for key: Int) { lock.lock(); defer { lock.unlock() }; if entries.count > 8 { entries.removeAll() }; entries[key] = Entry(tint: tint) }
    }
    static func tint(from image: NSImage) -> MusicTint? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return tint(from: cgImage)
    }
    static func tint(from cgImage: CGImage) -> MusicTint? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let edge = 8
        var pixels = [UInt8](repeating: 0, count: edge * edge * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        guard drawn else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = Double(pixels[index]) / 255 / alpha, g = Double(pixels[index + 1]) / 255 / alpha, b = Double(pixels[index + 2]) / 255 / alpha
            let saturation = max(r, g, b) - min(r, g, b)
            let w = 0.2 + saturation
            red += r * w; green += g * w; blue += b * w; weight += w
        }
        guard weight > 0 else { return nil }
        return MusicTint(red: red / weight, green: green / weight, blue: blue / weight)
    }
}

/// Orders accent results: only the artwork still current may publish its light. On a rapid skip (A then B) A's decode can finish after B's, and A's
/// light must not land on B.
@MainActor final class AccentSequencer {
    private var current = 0
    func begin() -> Int { current += 1; return current }
    func isCurrent(_ ticket: Int) -> Bool { ticket == current }
    /// Decodes `data` (or clears when there is none) and publishes the result only if no newer artwork began in the meantime.
    func publish(_ data: Data?, decode: @escaping @Sendable (Data) async -> MusicTint? = { await ArtworkAccent.tint(fromData: $0) }, apply: @escaping @MainActor (MusicTint?) -> Void) {
        let ticket = begin()
        guard let data else { apply(nil); return }
        Task { [weak self] in
            let tint = await decode(data)
            if let self, self.isCurrent(ticket) { apply(tint) }
        }
    }
}

#if DEBUG
/// What tint each player surface was last given, so a test can prove the glass tint is the same input across the bar and the expanded player.
@MainActor enum PlayerTintProbe {
    private static var records: [String: MusicTint?] = [:]
    /// Keyed by the playback model, so concurrent windows (and concurrent tests) never read each other's input.
    static func record(_ surface: String, for model: PlaybackModel, _ tint: MusicTint?) { records["\(surface)-\(ObjectIdentifier(model).hashValue)"] = tint }
    static func tint(_ surface: String, for model: PlaybackModel) -> MusicTint? { records["\(surface)-\(ObjectIdentifier(model).hashValue)"] ?? nil }
    static func recorded(_ surface: String, for model: PlaybackModel) -> Bool { records["\(surface)-\(ObjectIdentifier(model).hashValue)"] != nil }
}
#endif

/// W27 (Artwork accent, default enabled and subdued): the one rule for whether the player is tinted. Off means no tint at all; on takes the hidden player's own
/// artwork tint while it plays and the native artwork's otherwise. (How strongly a tint may wash the glass is `MusicTint.glassOpacity`, unchanged.)
enum ArtworkAccentPolicy {
    static func accent<T>(enabled: Bool, web: T?, artwork: T?, usesWebPlayer: Bool) -> T? { enabled ? (usesWebPlayer ? web : artwork) : nil }
}
