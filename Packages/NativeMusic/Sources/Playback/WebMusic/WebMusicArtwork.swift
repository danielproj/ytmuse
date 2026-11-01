import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol WebMusicArtworkLoading: Sendable {
    func artwork(_ url: URL) async -> Data?
}

/// Redirects stay inside the artwork host allowlist: every hop is checked BEFORE the request for it is made, so an allowed host cannot bounce the loader to
/// another host (SEC05). A refused hop ends the task with the redirect response, which is not a 200 and so yields no data.
final class ArtworkRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let target = request.url, WebMusicBridge.allowedArtwork(target.absoluteString) != nil else { return nil }
        return request
    }
}
/// Answers every request with a refusal. Always the last protocol of a test session, so a request no test protocol answers can never reach the network.
final class ArtworkRefuseEverythingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// Credential-free, bounded artwork fetch from YouTube's image hosts only
/// (the same allowlist the bridge applies). Ephemeral session: no cookies sent or kept.
/// The body is read as a stream and stops at `maximumBytes`, and a declared length above it is refused before a byte is read (W29, T29.2).
public struct WebMusicArtworkLoader: WebMusicArtworkLoading {
    static let maximumBytes = 2_000_000
    private let session: URLSession
    public init() { self.init(protocolClasses: nil) }
    /// Test seam: only the given URL protocols (then a refusal) can answer, so no test session reaches the network. It takes classes, never a session.
    init(protocolClasses: [AnyClass]?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        if let protocolClasses { configuration.protocolClasses = protocolClasses + [ArtworkRefuseEverythingProtocol.self] }
        session = URLSession(configuration: configuration, delegate: ArtworkRedirectGuard(), delegateQueue: nil)
    }
    public func artwork(_ url: URL) async -> Data? {
        guard WebMusicBridge.allowedArtwork(url.absoluteString) != nil else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.mimeType ?? "").hasPrefix("image/"), http.expectedContentLength <= Int64(Self.maximumBytes),
              let final = http.url, WebMusicBridge.allowedArtwork(final.absoluteString) != nil else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < Self.maximumBytes else { return nil }
                data.append(byte)
            }
        } catch { return nil }
        return Self.downsampled(data)
    }
    static let maximumSourcePixels = 4096
    static let maximumPixels = 512
    /// Bounded decode (SEC05): header dimensions are checked before decoding, and
    /// the image is re-encoded as a PNG of at most 512 px on its long side.
    public static func downsampled(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumSourcePixels, height <= maximumSourcePixels,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
