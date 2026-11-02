import Testing
import Foundation
import AppKit
import Domain
import Artwork
import Features
import AccountSession
@testable import AppShell

/// POL-A: a view that replaces another for the same cover (the bar morphing into Now Playing and back) must not show the default picture in between.
@Suite(.serialized) @MainActor struct ArtworkCoverContinuityTests {
    /// One real decoded image, from the pipeline, for the seeding tests.
    @MainActor private struct Fixture {
        let directory: URL, pipeline: ArtworkPipeline, authority: ArtworkUIAuthority, context: RequestContext, account: Account
        static func make(generation: UInt64 = 1) async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pola-cover-" + UUID().uuidString)
            let source = ImmediateCoverSource(bytes: try consumerPNG()), authority = ArtworkUIAuthority(), account = try consumerAccount()
            let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
            let context = RequestContext(account: account.context, accountGeneration: generation, requestGeneration: 0)
            try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: generation)
            #expect(authority.bind(context))
            return Fixture(directory: directory, pipeline: pipeline, authority: authority, context: context, account: account)
        }
        func request(_ id: String = "cover", points: Double = 52) throws -> ArtworkRequest {
            ArtworkRequest(resource: try ArtworkResource(namespace: "owned-original-test", identifier: id, revision: "1"), size: try ArtworkSize(pointsWidth: points, pointsHeight: points, scale: 2), policy: .memory(until: .distantFuture), context: context)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func secondConsumerForTheSameCoverPaintsSynchronouslyWithNoAwait() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let bar = ArtworkConsumer(), expanded = ArtworkConsumer()
        let small = try f.request(points: 52), large = try f.request(points: 240)
        await bar.load(small, pipeline: f.pipeline, authority: f.authority)
        #expect(bar.displayed(for: small, authority: f.authority) != nil)
        // The new view's consumer has never loaded: still its first frame, still no await.
        #expect(expanded.displayed(for: large, authority: f.authority) != nil, "the replacing view paints the cover it replaces in its first frame")
        // The unmeasured template (1 pt, as the catalog's) seeds as well: the size never matters to the identity.
        #expect(expanded.displayed(for: try f.request(points: 1), authority: f.authority) != nil)
        // A different cover is not seeded.
        #expect(expanded.displayed(for: try f.request("other"), authority: f.authority) == nil)
    }
    @Test func nilRequestAndFailedLoadStillShowTheDefaultPicture() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let warm = ArtworkConsumer(), cold = ArtworkConsumer()
        let request = try f.request()
        await warm.load(request, pipeline: f.pipeline, authority: f.authority)
        #expect(cold.displayed(for: nil, authority: f.authority) == nil, "no request is the real no-artwork case")
        // A load that fails ends unavailable, even though the store holds the cover at another size.
        let failing = ArtworkConsumer()
        let failingPipeline = ArtworkPipeline(source: FailingCoverSource(), diskDirectory: f.directory.appendingPathComponent("failing"))
        try await failingPipeline.setAccountGeneration(owner: ArtworkOwner(account: f.account.context), generation: 1)
        let large = try f.request(points: 240)
        await failing.load(large, pipeline: failingPipeline, authority: f.authority)
        #expect(failing.unavailable)
        #expect(failing.displayed(for: large, authority: f.authority) == nil, "a failed load is the default picture, not a stale seed")
    }
    @Test func otherAccountRemovedAccountAndNewerGenerationGetNothing() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let owner = ArtworkConsumer()
        let request = try f.request()
        await owner.load(request, pipeline: f.pipeline, authority: f.authority)
        let newcomer = ArtworkConsumer()
        #expect(newcomer.displayed(for: request, authority: f.authority) != nil)
        // Another account's context asks for the same resource.
        let other = try consumerAccount()
        let foreign = ArtworkRequest(resource: request.resource, size: request.size, policy: request.policy, context: RequestContext(account: other.context, accountGeneration: 1, requestGeneration: 0))
        #expect(newcomer.displayed(for: foreign, authority: f.authority) == nil)
        // A newer generation binds: the store is emptied and the old context is no longer accepted.
        #expect(f.authority.bind(RequestContext(account: f.context.account, accountGeneration: 2, requestGeneration: 0)))
        #expect(f.authority.recents.count == 0, "binding a newer account generation empties the store")
        #expect(newcomer.displayed(for: request, authority: f.authority) == nil)
        // Re-seed under generation 2, then remove the account.
        try await f.pipeline.setAccountGeneration(owner: ArtworkOwner(account: f.account.context), generation: 2)
        let next = ArtworkRequest(resource: request.resource, size: request.size, policy: request.policy, context: f.authority.context)
        let loader = ArtworkConsumer()
        await loader.load(next, pipeline: f.pipeline, authority: f.authority)
        #expect(ArtworkConsumer().displayed(for: next, authority: f.authority) != nil)
        f.authority.removeAccount(try #require(f.context.account).accountID)
        #expect(f.authority.recents.count == 0, "removing the account empties the store")
        #expect(ArtworkConsumer().displayed(for: next, authority: f.authority) == nil)
    }
    @Test func aSizeOnlyReloadNeverPassesThroughNil() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let consumer = ArtworkConsumer()
        let small = try f.request(points: 52), large = try f.request(points: 240)
        await consumer.load(small, pipeline: f.pipeline, authority: f.authority)
        f.authority.recents.removeAll()   // only the consumer's own picture can carry the morph now
        #expect(consumer.displayed(for: small, authority: f.authority) != nil)
        // The morph: the demand changes size and the new decode is still outstanding (a pipeline that never answers in time).
        let slow = ArtworkPipeline(source: HeldCoverSource(), diskDirectory: f.directory.appendingPathComponent("held-size"))
        try await slow.setAccountGeneration(owner: ArtworkOwner(account: f.account.context), generation: 1)
        let reload = Task { await consumer.load(large, pipeline: slow, authority: f.authority) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(consumer.displayed(for: large, authority: f.authority) != nil, "the cover stays on screen from the size change until the new size arrives")
        #expect(!consumer.unavailable)
        reload.cancel(); consumer.cancel(); await reload.value
        // And the real decode at the new size then replaces it.
        let done = ArtworkConsumer()
        await done.load(small, pipeline: f.pipeline, authority: f.authority)
        await done.load(large, pipeline: f.pipeline, authority: f.authority)
        #expect(done.displayed(for: large, authority: f.authority) != nil && !done.unavailable)
    }
    @Test func aDifferentCoverNeverShowsTheOldOneWhileLoading() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let consumer = ArtworkConsumer()
        let first = try f.request("first"), second = try f.request("second")
        await consumer.load(first, pipeline: f.pipeline, authority: f.authority)
        f.authority.recents.removeAll()
        let slow = ArtworkPipeline(source: HeldCoverSource(), diskDirectory: f.directory.appendingPathComponent("held"))
        try await slow.setAccountGeneration(owner: ArtworkOwner(account: f.account.context), generation: 1)
        let task = Task { await consumer.load(second, pipeline: slow, authority: f.authority) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(consumer.displayed(for: second, authority: f.authority) == nil, "another cover is not the previous cover")
        task.cancel(); consumer.cancel(); await task.value
    }
    @Test func theStoreKeepsOnlyItsCapacityMostRecentCovers() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let consumer = ArtworkConsumer()
        await consumer.load(try f.request("seed"), pipeline: f.pipeline, authority: f.authority)
        let image = try #require(consumer.displayed(for: try f.request("seed"), authority: f.authority))
        let store = RecentArtworkStore(capacity: 3)
        let identities = try (0..<5).map { ArtworkImageIdentity(try f.request("c\($0)")) }
        for identity in identities { store.remember(image, for: identity) }
        #expect(store.count == 3)
        #expect(store.image(for: identities[0]) == nil && store.image(for: identities[1]) == nil, "the oldest are evicted")
        #expect(store.image(for: identities[4]) != nil)
        store.remember(image, for: identities[4]); #expect(store.count == 3, "re-remembering does not duplicate")
        #expect(RecentArtworkStore.defaultCapacity == 6 && f.authority.recents.capacity == 6)
        // Real use stays at the authority's cap.
        for index in 0..<10 { await ArtworkConsumer().load(try f.request("many\(index)"), pipeline: f.pipeline, authority: f.authority) }
        #expect(f.authority.recents.count == 6)
    }
    @Test func aHeldCoverForTheNewSongWinsOverTheViewsPreviousImage() async throws {
        let first = try consumerPNG()
        let second = { var data = first; data.append(7); return data }()
        let memo = WebCoverMemo(capacity: 4)
        let previous = try #require(await memo.decoded(first)), next = NSImage(size: NSSize(width: 4, height: 4))
        #expect(memo.displayed(for: first, current: nil) === previous)
        #expect(memo.displayed(for: second, current: previous) === previous, "nothing held for the new bytes: the view's own image stays until its decode lands")
        memo.remember(next, for: second)
        #expect(memo.displayed(for: second, current: previous) === next, "held bytes win over the previous song's image at once")
        #expect(memo.displayed(for: nil, current: previous) === previous && memo.displayed(for: nil, current: nil) == nil)
    }
    @Test func decodedCoversGoWithTheAccountOnSwitchSignOutRemovalAndStop() async throws {
        let png = try consumerPNG()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pola-memo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ImmediateCoverSource(bytes: png), authority = ArtworkUIAuthority()
        let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
        let participant = ArtworkAccountParticipant(pipeline: pipeline, presentation: authority)
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [participant])
        let a = try consumerAccount(), b = try consumerAccount()
        try await connectConsumer(lifecycle, a); try await connectConsumer(lifecycle, b)
        func hold() async throws { WebCoverMemo.shared.removeAll(); _ = try #require(await WebCoverMemo.shared.decoded(png)); #expect(WebCoverMemo.shared.count == 1) }
        defer { WebCoverMemo.shared.removeAll() }
        try await lifecycle.switchIdentity(to: a.context)
        try await hold()
        try await lifecycle.switchIdentity(to: b.context)
        #expect(WebCoverMemo.shared.count == 0, "an account switch drops the previous account's decoded covers")
        try await hold()
        try await lifecycle.signOut(b.context)
        #expect(WebCoverMemo.shared.count == 0, "signing out drops them")
        try await hold()
        try await lifecycle.remove(b.context)
        #expect(WebCoverMemo.shared.count == 0, "removing the account drops them")
        try await hold()
        // The participant's own removal hook, called alone (the lifecycle detaches first, so the line above cannot tell this hook's drop apart).
        try await participant.removeLocal(try consumerAccount().context, context: await lifecycle.snapshot().context)
        #expect(WebCoverMemo.shared.count == 0, "the participant's removal hook drops them by itself")
        try await hold()
        await participant.stop()
        #expect(WebCoverMemo.shared.count == 0, "stopping the artwork participant drops them")
    }
    @Test func theWebCoverMemoHoldsDecodedBytesAndNothingElse() async throws {
        let png = try consumerPNG()
        let other = { var data = png; data.append(0); return data }()
        let memo = WebCoverMemo(capacity: 2)
        #expect(memo.image(for: nil) == nil && memo.image(for: png) == nil)
        let first = try #require(await memo.decoded(png))
        #expect(memo.image(for: png) === first, "the second view gets the same decode, with no decode of its own")
        #expect(await memo.decoded(png) === first)
        #expect(memo.image(for: other) == nil, "other bytes (another song) never match")
        #expect(await memo.decoded(nil) == nil && memo.image(for: nil) == nil)
        #expect(await memo.decoded(Data("not an image".utf8)) == nil)
        for index in 0..<4 { _ = await memo.decoded({ var data = png; data.append(contentsOf: [UInt8](repeating: 1, count: index + 2)); return data }()) }
        #expect(memo.count <= 2, "capacity holds")
    }
}

private actor FailingCoverSource: ArtworkSource {
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData { throw ArtworkError.sourceUnavailable }
}
private actor HeldCoverSource: ArtworkSource {
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData {
        try await Task.sleep(for: .seconds(30)); throw ArtworkError.sourceUnavailable
    }
}
private actor ImmediateCoverSource: ArtworkSource {
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData {
        ArtworkSourceData(bytes: bytes, policy: .memory(until: .distantFuture))
    }
}
