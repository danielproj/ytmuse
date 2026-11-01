import Testing
import Foundation
import Domain
import Artwork
import Features

@Suite(.serialized) @MainActor struct PressureRecoveryTests {
    @Test func pressureRecoversUnchangedVisibleDemandOnce() async throws {
        let source = ConsumerSource(bytes: try consumerPNG()), authority = ArtworkUIAuthority(), consumer = ArtworkConsumer(), account = try consumerAccount()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 1)
        authority.bind(context); try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 1)
        let request = try consumerRequest(context, query: 1)
        let task = Task { await consumer.load(request, pipeline: pipeline, authority: authority) }
        try await consumerEventually { await source.calls.count == 1 }
        await pipeline.handlePressure(.warning); await source.release("image")
        try await consumerEventually { await source.calls.count == 2 }
        await source.release("image"); await task.value
        #expect(consumer.displayed(for: request, authority: authority) != nil && !consumer.unavailable)
        #expect(await source.calls.count == 2)
    }
    @Test func repeatedPressureStopsWithoutBusyRetry() async throws {
        let source = ConsumerSource(bytes: try consumerPNG()), authority = ArtworkUIAuthority(), consumer = ArtworkConsumer(), account = try consumerAccount()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 1)
        authority.bind(context); try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 1)
        let request = try consumerRequest(context, query: 1)
        let task = Task { await consumer.load(request, pipeline: pipeline, authority: authority) }
        try await consumerEventually { await source.calls.count == 1 }
        await pipeline.handlePressure(.warning); await source.release("image")
        try await consumerEventually { await source.calls.count == 2 }
        await pipeline.handlePressure(.critical); await source.release("image"); await task.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(await source.calls.count == 2)
        #expect(consumer.unavailable && consumer.displayed(for: request, authority: authority) == nil)
    }
    @Test func hiddenCancelledSupersededOrStaleOwnerCannotRetryPressure() async throws {
        for exclusion in 0..<4 {
            let source = ConsumerSource(bytes: try consumerPNG()), authority = ArtworkUIAuthority(), consumer = ArtworkConsumer(), account = try consumerAccount()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
            let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 1)
            authority.bind(context); try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 1)
            let request = try consumerRequest(context, query: 1)
            let task = Task { await consumer.load(request, pipeline: pipeline, authority: authority) }
            try await consumerEventually { await source.calls.count == 1 }
            await pipeline.handlePressure(.warning)
            if exclusion == 0 { consumer.cancel() } // View disappearance invalidates this demand.
            if exclusion == 1 { task.cancel() }
            if exclusion == 2 { authority.bind(.init(account: nil, accountGeneration: 2, requestGeneration: 0)) }
            if exclusion == 3 {
                consumer.cancel() // A newer explicit demand owns the consumer, with no hidden I/O.
                await consumer.load(try consumerRequest(context, query: 2), pipeline: pipeline, authority: authority, visible: false)
            }
            await source.release("image"); await task.value
            try await Task.sleep(for: .milliseconds(180))
            #expect(await source.calls.count == 1)
            #expect(consumer.displayed(for: request, authority: authority) == nil)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
