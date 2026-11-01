import Foundation
import Testing
import Domain
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import YouTubeMusicAdapter

@Suite struct CacheDecodingTests {
    @Test(arguments: [MetadataFreshness.dynamic, .membership, .stable]) func sourceStalenessHiddenAndRetention(kind: MetadataFreshness) async throws {
        let clock = TestTime(), cache = SourceCache(time: clock), resource = UUID(), probe = Probe()
        try await cache.bind(owner())
        let policy = try SourceRetention(seconds: 100_000, freshness: kind)
        let loader: @Sendable () async -> BoundedResponse = { await probe.record(); return .init(status: 200, body: Data("{}".utf8)) }
        #expect(try await cache.read(resource: resource, context: owner(), policy: policy, visible: false, load: loader) == nil)
        _ = try await cache.read(resource: resource, context: owner(), policy: policy, visible: true, load: loader)
        clock.advance(kind.seconds - 0.001)
        #expect(await cache.cached(resource: resource, context: owner())?.stale == false)
        clock.advance(0.001)
        #expect(await cache.cached(resource: resource, context: owner())?.stale == true)
        _ = try await cache.read(resource: resource, context: owner(), policy: policy, visible: false, load: loader)
        #expect(await probe.calls == 1)
        _ = try await cache.read(resource: resource, context: owner(), policy: policy, visible: true, load: loader)
        #expect(await probe.calls == 2)
        clock.advance(100_000)
        #expect(await cache.cached(resource: resource, context: owner()) == nil)
    }
    @Test func sourceHeadersNoStoreAgeAndBoundedEviction() async throws {
        let clock = TestTime(), cache = SourceCache(time: clock, maxBytes: 6, maxEntries: 2)
        try await cache.bind(owner())
        let policy = try SourceRetention(seconds: 30, freshness: .stable), resource = UUID()
        for directive in ["no-store", "max-age=5", "no-cache"] {
            await cache.invalidate()
            _ = try await cache.read(resource: resource, context: owner(), policy: policy, visible: true) {
                .init(status: 200, body: Data([1]), cacheControl: directive, age: "2")
            }
            if directive == "no-store" || directive == "no-cache" { #expect(await cache.cached(resource: resource, context: owner()) == nil) }
            else {
                clock.advance(3)
                #expect(await cache.cached(resource: resource, context: owner())?.stale == true)
            }
        }
        await cache.invalidate()
        _ = try await cache.read(resource: resource, context: owner(), policy: policy, visible: true) {
            .init(status: 200, body: Data([1]), cacheControl: "must-revalidate", expires: clock.wallNow().addingTimeInterval(2))
        }
        clock.advance(2)
        #expect(await cache.cached(resource: resource, context: owner()) == nil)
        let resources = [UUID(), UUID(), UUID()]
        for id in resources {
            _ = try await cache.read(resource: id, context: owner(), policy: policy, visible: true) { .init(status: 200, body: Data(repeating: 1, count: 4)) }
            clock.advance(1)
        }
        #expect(await cache.cached(resource: resources[0], context: owner()) == nil)
        #expect(await cache.cached(resource: resources[1], context: owner()) == nil)
        #expect(await cache.cached(resource: resources[2], context: owner()) != nil)
        await cache.invalidate(resource: resources[2], context: owner())
        #expect(await cache.cached(resource: resources[2], context: owner()) == nil)
    }
    @Test func coalescingAndLateCacheResponseCannotRestoreRemovedAccount() async throws {
        let cache = SourceCache(), resource = UUID(), probe = Probe(), policy = try SourceRetention(seconds: 600, freshness: .dynamic)
        let context = owner(account: try identity())
        try await cache.bind(context)
        let first = Task { try await cache.read(resource: resource, context: context, policy: policy, visible: true) { await probe.hold() } }
        #expect(await eventually { await probe.calls == 1 })
        let second = Task { try await cache.read(resource: resource, context: context, policy: policy, visible: true) { await probe.hold() } }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await probe.calls == 1)
        await probe.release()
        #expect(try await first.value != nil); #expect(try await second.value != nil)
        #expect(await cache.cached(resource: resource, context: owner(account: try identity())) == nil)
        await cache.invalidate(account: context.account)
        let late = Task { try await cache.read(resource: resource, context: context, policy: policy, visible: true) { await probe.hold() } }
        #expect(await eventually { await probe.calls == 2 })
        await cache.invalidate(account: context.account); try await cache.bind(owner(2)); await probe.release()
        await #expect(throws: NetworkFault.stale) { try await late.value }
        #expect(await cache.cached(resource: resource, context: context) == nil)
    }
    struct Shape: Codable, Sendable { let required: String }
    @Test func jsonFaultIsolationAndPreallocationBounds() async throws {
        let decoder = NetworkDecoder(), bounds = try ResponseBounds(bytes: 1024, jsonDepth: 3, jsonNodes: 20)
        let valid = BoundedResponse(status: 200, body: Data(#"{"required":"ok","newField":null}"#.utf8))
        #expect(try await decoder.json(Shape.self, response: valid, bounds: bounds).required == "ok")
        for text in ["{}", "{", "[[[[0]]]]", #"{"required":3}"#, "<html>portal</html>"] {
            await #expect(throws: NetworkFault.schema) { try await decoder.json(Shape.self, response: .init(status: 200, body: Data(text.utf8)), bounds: bounds) }
        }
        await #expect(throws: NetworkFault.contentType) { try await decoder.json(Shape.self, response: .init(status: 200, body: Data("<html>portal</html>".utf8), contentType: "text/html"), bounds: bounds) }
        // A prior decoder failure has no persistent global disable flag.
        #expect(try await decoder.json(Shape.self, response: valid, bounds: bounds).required == "ok")
    }
    @Test func imageDimensionsAreCheckedBeforeRasterDecode() async throws {
        let color = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData(), image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
        let response = BoundedResponse(status: 200, body: data as Data, contentType: "image/png"), decoder = NetworkDecoder()
        let dimensions = try await decoder.imageThumbnail(response: response, bounds: ResponseBounds(), maximumDimension: 4)
        #expect(dimensions.width == 4 && dimensions.height == 2)
        await #expect(throws: NetworkFault.image) { try await decoder.imageThumbnail(response: response, bounds: ResponseBounds(imagePixels: 127)) }
        await #expect(throws: NetworkFault.image) { try await decoder.imageThumbnail(response: .init(status: 200, body: Data("not image".utf8), contentType: "image/png"), bounds: ResponseBounds()) }
    }
    @Test func cursorRestartPreservesDistinctDuplicateOccurrences() throws {
        let collection = try ServiceID("collection"), a = try ServiceID("occurrence-a"), b = try ServiceID("occurrence-b")
        var accumulator = OccurrencePageAccumulator<String>(context: owner(), collection: collection)
        try accumulator.append([(a, "same-track"), (b, "same-track")], cursor: nil, now: Date())
        let expired = try PageCursor(reference: ID("cursor"), context: owner(), collection: collection, expiresAt: Date(timeIntervalSince1970: 0))
        #expect(throws: DomainError.expiredMedia) { try accumulator.append([], cursor: expired, now: Date()) }
        try accumulator.append([(a, "same-track"), (b, "same-track"), (try ServiceID("c"), "third")], cursor: nil, now: Date())
        #expect(accumulator.values == ["same-track", "same-track", "third"])
        let stale = try PageCursor(reference: ID("cursor"), context: owner(2), collection: collection, expiresAt: nil)
        #expect(throws: DomainError.staleContext) { try accumulator.append([], cursor: stale, now: Date()) }
    }
    @Test func explicitCredentialRefreshIsSingleFlightAndInvalidatable() async throws {
        let gate = CredentialRefreshGate(), probe = Probe(), context = owner(account: try identity()), reference = try CredentialReference("opaque-reference")
        try await gate.bind(context)
        let tasks = (0..<2).map { _ in Task {
            try await gate.refresh(reference: reference, context: context) { _ = await probe.hold(); return reference }
        } }
        #expect(await eventually { await probe.calls == 1 }); try await Task.sleep(for: .milliseconds(20))
        #expect(await probe.calls == 1)
        await gate.invalidate(); await probe.release()
        for task in tasks { await #expect(throws: NetworkFault.stale) { try await task.value } }
    }
}
