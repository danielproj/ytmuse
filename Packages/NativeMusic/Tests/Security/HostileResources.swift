import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Domain
@testable import Artwork
@testable import AccountSession
@testable import YouTubeMusicAdapter
@testable import Playback

// T29.2, resources: decompression bombs, huge or lying artwork, oversized metadata, endless bodies and unbounded probes. Bounds are tested on the bytes the app would hold,
// and on a byte stream that would produce gigabytes if the bound were missing (the test counts what was actually produced).

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in var c = UInt32(n); for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; return c }
    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 { ~bytes.reduce(UInt32.max) { table[Int(($0 ^ UInt32($1)) & 0xff)] ^ ($0 >> 8) } }
}
enum Crafted {
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(UInt32(body.count)) + Array(type.utf8) + body + be32(CRC32.checksum(Array(type.utf8) + body)) }
    /// A PNG whose header claims `width` x `height` and whose pixel data is absent: tiny on disk, enormous if a decoder believed it.
    static func pngHeaderOnly(width: UInt32, height: UInt32) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", be32(width) + be32(height) + [8, 2, 0, 0, 0]) + chunk("IEND", []))
    }
    static func realImage(width: Int, height: Int, type: UTType = .png) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
        return output as Data
    }
    /// A gzip stream of `size` zero bytes: about a thousand times smaller than what it inflates to.
    static func gzipOfZeros(size: Int) -> Data {
        let zeros = Data(count: size)
        let deflated = try! (zeros as NSData).compressed(using: .zlib) as Data
        let header: [UInt8] = [0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0x03]
        // CRC of zeros: computed once by folding the table over `size` zero bytes.
        var crc = UInt32.max
        for _ in 0..<size { crc = CRC32.table[Int(crc & 0xff)] ^ (crc >> 8) }
        let trailer = [UInt8(~crc & 0xff), UInt8((~crc >> 8) & 0xff), UInt8((~crc >> 16) & 0xff), UInt8((~crc >> 24) & 0xff)] + [UInt8(size & 0xff), UInt8((size >> 8) & 0xff), UInt8((size >> 16) & 0xff), UInt8((size >> 24) & 0xff)]
        return Data(header) + deflated + Data(trailer)
    }
}

/// A byte source that would produce `total` bytes and records how many were really pulled from it.
struct CountingBytes: AsyncSequence {
    typealias Element = UInt8
    let total: Int
    let produced: Counter
    struct Iterator: AsyncIteratorProtocol {
        let total: Int; let produced: Counter; var index = 0
        mutating func next() async -> UInt8? { guard index < total else { return nil }; index += 1; produced.bump(); return 0x20 }
    }
    func makeAsyncIterator() -> Iterator { Iterator(total: total, produced: produced) }
}

@Suite("T29.2 images that lie about their size") struct HostileImageTests {
    static let size = try! ArtworkSize(pointsWidth: 128, pointsHeight: 128, scale: 2)
    @Test func theArtworkDecoderRefusesBeforeAllocatingARaster() async throws {
        let decoder = ArtworkDecoder()
        let bombs: [(String, Data)] = [("30000x30000", Crafted.pngHeaderOnly(width: 30_000, height: 30_000)), ("40000x40000", Crafted.pngHeaderOnly(width: 40_000, height: 40_000)),
                                       ("100000x1", Crafted.pngHeaderOnly(width: 100_000, height: 1)), ("1x100000", Crafted.pngHeaderOnly(width: 1, height: 100_000)), ("0x0", Crafted.pngHeaderOnly(width: 0, height: 0))]
        for (name, bytes) in bombs {
            #expect(bytes.count < 200, "\(name) is tiny on disk")
            await #expect(throws: ArtworkError.self, "\(name)") { _ = try await decoder.decode(bytes, size: Self.size, configuration: .default, persist: false) }
        }
        await #expect(throws: ArtworkError.inputTooLarge) { _ = try await decoder.decode(Data(count: 9 * 1024 * 1024), size: Self.size, configuration: .default, persist: false) }
        for junk in [Data(), Data("GIF89a".utf8), Data("not an image at all".utf8), Data(repeating: 0xff, count: 4096)] {
            await #expect(throws: ArtworkError.self) { _ = try await decoder.decode(junk, size: Self.size, configuration: .default, persist: false) }
        }
        // The control: a real image decodes, to at most the size asked for, with no work on the main thread.
        let good = try await decoder.decode(Crafted.realImage(width: 600, height: 400), size: Self.size, configuration: .default, persist: false)
        #expect(good.image.cgImage.width <= Self.size.pixelWidth && good.image.cgImage.height <= Self.size.pixelHeight && good.offMain)
        let counters = await decoder.snapshot()
        #expect(counters.decodeAttempts >= 10 && counters.completedDecodes == 1 && counters.mainThreadWorkViolations == 0, "\(counters)")
        #expect(counters.largestRasterBytes <= Self.size.pixelWidth * Self.size.pixelHeight * 4, "no raster above the display size was ever made")
    }
    @Test func theNetworkImageCheckRefusesOversizedDimensionsAndBodies() async throws {
        let decoder = NetworkDecoder(), bounds = try ResponseBounds(bytes: 200_000, seconds: 5, imagePixels: 4_000_000)
        func response(_ data: Data, type: String? = "image/png") -> BoundedResponse { BoundedResponse(status: 200, body: data, contentType: type) }
        for bomb in [Crafted.pngHeaderOnly(width: 30_000, height: 30_000), Crafted.pngHeaderOnly(width: 17_000, height: 1), Crafted.pngHeaderOnly(width: 2_100, height: 2_100)] {
            await #expect(throws: NetworkFault.image) { _ = try await decoder.imageThumbnail(response: response(bomb), bounds: bounds) }
        }
        await #expect(throws: NetworkFault.oversized) { _ = try await decoder.imageThumbnail(response: response(Data(count: 300_000)), bounds: bounds) }
        await #expect(throws: NetworkFault.image, "not an image type") { _ = try await decoder.imageThumbnail(response: response(Crafted.realImage(width: 64, height: 64), type: "text/html"), bounds: bounds) }
        let dimensions = try await decoder.imageThumbnail(response: response(Crafted.realImage(width: 800, height: 600)), bounds: bounds)
        #expect(dimensions.width <= 2048 && dimensions.height <= 2048, "the control decodes within the bound")
    }
    @Test func theHiddenPlayerArtworkDownsamplerRefusesOversizedHeaders() {
        #expect(WebMusicArtworkLoader.downsampled(Crafted.pngHeaderOnly(width: 30_000, height: 30_000)) == nil)
        #expect(WebMusicArtworkLoader.downsampled(Crafted.pngHeaderOnly(width: 4_097, height: 10)) == nil)
        let small = WebMusicArtworkLoader.downsampled(Crafted.realImage(width: 2000, height: 1000))
        #expect(small != nil && (small.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyPixelWidth] as? Int ?? 9999) <= 512)
    }
}

/// Serves artwork from a fake host according to a mode, and records every host it was asked for.
final class ArtworkWire: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case image, declaredHuge, endless, redirectOut, redirectIn, notImage }
    nonisolated(unsafe) static var mode: Mode = .image
    static let hosts = HostLog()
    nonisolated(unsafe) static var chunksSent = 0
    private var timer: DispatchSourceTimer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.hosts.add(url.host ?? "")
        func respond(_ status: Int, _ headers: [String: String]) { client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed) }
        switch Self.mode {
        case .image:
            let body = Crafted.realImage(width: 300, height: 300)
            respond(200, ["Content-Type": "image/png", "Content-Length": "\(body.count)"]); client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        case .notImage:
            respond(200, ["Content-Type": "text/html"]); client?.urlProtocol(self, didLoad: Data("<html>".utf8)); client?.urlProtocolDidFinishLoading(self)
        case .declaredHuge:
            // A small, valid image behind a header that claims 900 MB: only the declared-length check can tell this from a good load.
            let body = Crafted.realImage(width: 300, height: 300)
            respond(200, ["Content-Type": "image/png", "Content-Length": "900000000"])
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        case .endless:
            respond(200, ["Content-Type": "image/png"])
            let t = DispatchSource.makeTimerSource(queue: .global()); t.schedule(deadline: .now(), repeating: .milliseconds(1))
            t.setEventHandler { [weak self] in guard let self else { return }; Self.chunksSent += 1; self.client?.urlProtocol(self, didLoad: Data(count: 256 * 1024)) }
            timer = t; t.resume()
        case .redirectOut, .redirectIn:
            let target = Self.mode == .redirectOut ? "https://evil.example.test/a.png" : "https://i.ytimg.com/vi/other/hq.png"
            let r = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: r)
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { timer?.cancel(); timer = nil }
}
final class HostLog: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func add(_ host: String) { lock.withLock { values.append(host) } }
    var all: [String] { lock.withLock { values } }
    func reset() { lock.withLock { values = [] } }
}

@Suite("T29.2 the hidden player's artwork fetch", .serialized) struct HostileArtworkFetchTests {
    func loader() -> WebMusicArtworkLoader { WebMusicArtworkLoader(protocolClasses: [ArtworkWire.self]) }
    let url = URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hq.png")!
    @Test func aWellFormedImageFromAnAllowedHostLoads() async {
        ArtworkWire.mode = .image; ArtworkWire.hosts.reset()
        let data = await loader().artwork(url)
        #expect(data != nil && ArtworkWire.hosts.all == ["i.ytimg.com"])
    }
    @Test func anAllowedHostCannotBounceTheLoaderToAnotherHost() async throws {
        ArtworkWire.mode = .redirectOut; ArtworkWire.hosts.reset()
        #expect(await loader().artwork(url) == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!ArtworkWire.hosts.all.contains("evil.example.test"), "the redirect target was never requested: \(ArtworkWire.hosts.all)")
    }
    @Test func aRedirectInsideTheAllowedHostsIsStillFollowedAndChecked() async {
        ArtworkWire.mode = .redirectIn; ArtworkWire.hosts.reset()
        _ = await loader().artwork(url)
        #expect(ArtworkWire.hosts.all.first == "i.ytimg.com")
    }
    @Test func aDeclaredLengthAboveTheCapIsRefusedWithoutReadingTheBody() async {
        ArtworkWire.mode = .declaredHuge
        #expect(await loader().artwork(url) == nil)
    }
    @Test func anEndlessBodyStopsAtTheCap() async throws {
        ArtworkWire.mode = .endless; ArtworkWire.chunksSent = 0
        let start = Date()
        #expect(await loader().artwork(url) == nil)
        let sent = ArtworkWire.chunksSent
        try await Task.sleep(for: .milliseconds(200))
        // 2,000,000 bytes is under eight 256 KiB chunks; the source may be a little ahead of the reader, but it is stopped, not drained.
        #expect(ArtworkWire.chunksSent - sent <= 4, "the transfer was cancelled (\(sent) chunks at refusal, \(ArtworkWire.chunksSent) after)")
        #expect(Date().timeIntervalSince(start) < 8)
    }
    @Test func aNonImageIsRefused() async { ArtworkWire.mode = .notImage; #expect(await loader().artwork(url) == nil) }
    @Test func theHostAllowlistIsExactNotASubstringMatch() {
        let bad = ["https://evilytimg.com/a.png", "https://i.ytimg.com.evil.example/a.png", "https://i.ytimg.com@evil.example/a.png", "http://i.ytimg.com/a.png", "https://i.ytimg.com:8443/a.png", "https://user:pw@i.ytimg.com/a.png",
                   "https://127.0.0.1/a.png", "https://ytimg.com.evil.example/", "file:///etc/passwd", "https://i.ytimg.com\\@evil.example/a.png", "https://localhost/a.png"]
        for text in bad { #expect(WebMusicBridge.allowedArtwork(text) == nil, "\(text)") }
        #expect(WebMusicBridge.allowedArtwork("https://i.ytimg.com/vi/x/hq.jpg") != nil && WebMusicBridge.allowedArtwork("https://lh3.googleusercontent.com/a") != nil)
    }
}

@Suite("T29.2 bodies that never end and documents that nest forever") struct HostileBodyTests {
    @Test func aBodyIsReadNoFurtherThanItsLimitWhateverItClaims() async throws {
        let produced = Counter()
        await #expect(throws: NetworkFault.oversized) { _ = try await DirectBoundedTransport.collect(CountingBytes(total: 2_000_000_000, produced: produced), expected: -1, limit: 4096) }
        #expect(produced.value <= 4097, "pulled \(produced.value) of two billion bytes")
        await #expect(throws: NetworkFault.oversized, "a lying length") { _ = try await DirectBoundedTransport.collect(CountingBytes(total: 10, produced: Counter()), expected: 900_000_000, limit: 4096) }
        let honest = try await DirectBoundedTransport.collect(CountingBytes(total: 100, produced: Counter()), expected: 100, limit: 4096)
        #expect(honest.count == 100)
        let produced2 = Counter()
        await #expect(throws: ConnectionError.oversized) { _ = try await DirectPublicTransport.collect(CountingBytes(total: 2_000_000_000, produced: produced2), expectedLength: -1, limit: 4096) }
        #expect(produced2.value <= 4097)
    }
    @Test func aCompressedBombCannotExceedTheBound() async throws {
        let bomb = Crafted.gzipOfZeros(size: 8 * 1024 * 1024)
        #expect(bomb.count < 64 * 1024, "the bomb is \(bomb.count) bytes on the wire")
        GzipWire.body = bomb
        let route = try NetworkRoute(host: "music.example.test", path: "/read", method: "GET", purpose: .metadata)
        let request = try BoundedRequest(route: route, url: URL(string: "https://music.example.test/read")!, bounds: ResponseBounds(bytes: 256 * 1024, seconds: 10))
        let io = DirectBoundedTransport(protocolClasses: [GzipWire.self])
        do {
            let response = try await io.send(request, authorization: nil)
            #expect(response.body.count <= 256 * 1024, "whatever the system inflated, the caller never holds more than the bound (\(response.body.count))")
        } catch let fault as NetworkFault { #expect(fault == .oversized || fault == .transport || fault == .schema, "\(fault)") }
    }
    @Test func jsonThatNestsOrFansOutIsRefusedBeforeItIsBuilt() async throws {
        let decoder = NetworkDecoder(), bounds = try ResponseBounds(bytes: 8_000_000, seconds: 5, jsonDepth: 48, jsonNodes: 100_000)
        struct Anything: Decodable, Sendable { init(from decoder: any Decoder) throws {} }
        func response(_ text: String, type: String? = "application/json") -> BoundedResponse { BoundedResponse(status: 200, body: Data(text.utf8), contentType: type) }
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        let wide = "[" + (0..<150_000).map { "\($0)" }.joined(separator: ",") + "]"
        let manyStrings = "[" + String(repeating: "\"a\",", count: 120_000) + "\"a\"]"
        for bad in [deep, wide, manyStrings] { await #expect(throws: NetworkFault.schema) { _ = try await decoder.json(Anything.self, response: response(bad), bounds: bounds) } }
        await #expect(throws: NetworkFault.contentType) { _ = try await decoder.json(Anything.self, response: response("[]", type: "text/html"), bounds: bounds) }
        await #expect(throws: NetworkFault.oversized) { _ = try await decoder.json(Anything.self, response: response(String(repeating: " ", count: 9_000_000) + "[]"), bounds: bounds) }
        _ = try await decoder.json(Anything.self, response: response("[1,2,3]"), bounds: bounds)
        // A document that fits the byte cap but is mostly a string of braces inside quotes is not counted as nesting (the control for the depth check).
        _ = try await decoder.json(Anything.self, response: response("[\"" + String(repeating: "{", count: 100_000) + "\"]"), bounds: bounds)
    }
    @Test func theResponseBoundsRefuseAbsurdLimits() {
        for (bytes, seconds, depth, nodes, pixels) in [(0, 30.0, 48, 1000, 1000), (17_000_000, 30.0, 48, 1000, 1000), (1000, 0.0, 48, 1000, 1000), (1000, 121.0, 48, 1000, 1000), (1000, .infinity, 48, 1000, 1000),
                                                       (1000, 30.0, 0, 1000, 1000), (1000, 30.0, 65, 1000, 1000), (1000, 30.0, 48, 0, 1000), (1000, 30.0, 48, 200_001, 1000), (1000, 30.0, 48, 1000, 0), (1000, 30.0, 48, 1000, 40_000_001)] {
            #expect(throws: NetworkFault.input) { _ = try ResponseBounds(bytes: bytes, seconds: seconds, jsonDepth: depth, jsonNodes: nodes, imagePixels: pixels) }
        }
    }
}
final class GzipWire: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Content-Encoding": "gzip", "Content-Length": "\(Self.body.count)"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: Self.body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("T29.2 metadata that is larger than any screen") struct HostileMetadataTests {
    func fixture(_ path: String) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Repo.root.appendingPathComponent(path))) as? [String: Any]) }
    /// Replaces every `text` value in a parsed document with `replacement`, at any depth.
    func rewrite(_ value: Any, _ replacement: String) -> Any {
        if var object = value as? [String: Any] { for (k, v) in object { object[k] = k == "text" || k == "simpleText" ? replacement : rewrite(v, replacement) }; return object }
        if let list = value as? [Any] { return list.map { rewrite($0, replacement) } }
        return value
    }
    /// Replaces the first `text` value found, depth first.
    func rewriteFirst(_ value: Any, _ replacement: String) -> Any {
        var done = false
        func walk(_ value: Any) -> Any {
            if done { return value }
            if var object = value as? [String: Any] {
                for key in object.keys.sorted() { if done { break }; if key == "text" { object[key] = replacement; done = true } else if let v = object[key] { object[key] = walk(v) } }
                return object
            }
            if let list = value as? [Any] { return list.map { walk($0) } }
            return value
        }
        return walk(value)
    }
    @Test func aSearchRowWithAnOversizedTitleIsSkippedNotCarried() throws {
        let root = try fixture("Fixtures/W10/search-all-groups.json")
        let normal = try MusicSearchParser.parse(root)
        #expect(normal.items.count + (normal.top == nil ? 0 : 1) > 3, "the fixture parses to rows")
        // A page in which every text is oversized yields no rows: it is refused as unrecognised, or it parses to nothing. It never yields a row carrying the text.
        for size in [6000, 3_000_000] {
            let hostile = try #require(rewrite(root, String(repeating: "Ж", count: size)) as? [String: Any])
            switch Result(catching: { try MusicSearchParser.parse(hostile) }) {
            case .failure(let error): #expect(error as? MusicSessionError == .unrecognised, "\(error)")
            case .success(let parsed): #expect((parsed.items + (parsed.top.map { [$0] } ?? [])).isEmpty, "rows with a \(size)-character text are not produced")
            }
        }
        // One oversized title among good rows costs that row only.
        var mixed = root
        mixed = try #require(rewriteFirst(mixed, String(repeating: "A", count: 6000)) as? [String: Any])
        let partial = try MusicSearchParser.parse(mixed)
        #expect(partial.items.count + (partial.top == nil ? 0 : 1) < normal.items.count + (normal.top == nil ? 0 : 1) || partial.skippedRows > 0)
    }
    @Test func aBrowsePageWithOversizedTextCarriesNoOversizedField() throws {
        let root = try fixture("Fixtures/W11-real/browse-album.json")
        let page = try MusicBrowseParser.parse(root)
        let normalSize = String(reflecting: page).utf8.count
        let hostileRoot = try #require(rewrite(root, String(repeating: "B", count: 2_000_000)) as? [String: Any])
        let hostile = (try? MusicBrowseParser.parse(hostileRoot)).map { String(reflecting: $0).utf8.count } ?? 0
        #expect(normalSize > 1000)
        #expect(hostile < 1_000_000, "a 2 MB text in every field leaves \(hostile) bytes of output (the real page is \(normalSize))")
    }
}
