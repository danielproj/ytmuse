import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Domain
import Artwork
import Features
import AccountSession
@testable import AppShell

actor ConsumerDirectory: AccountDirectoryStore {
    var value = AccountDirectory()
    func load() -> AccountDirectory { value }
    func save(_ directory: AccountDirectory) { value = directory }
}
actor ConsumerVault: SessionVault {
    var context = RequestContext(account: nil, accountGeneration: 0, requestGeneration: 0)
    var values: [CredentialReference: (AccountContext, Data)] = [:]
    func bind(_ context: RequestContext) { self.context = context }
    func insert(_ bytes: Data, for account: AccountContext) throws -> CredentialReference {
        let reference = try CredentialReference(UUID().uuidString); values[reference] = (account, bytes); return reference
    }
    func read(_ reference: CredentialReference, context: RequestContext) throws -> Data {
        guard self.context == context, let entry = values[reference], entry.0 == context.account else { throw DomainError.unauthorized }; return entry.1
    }
    func delete(_ reference: CredentialReference, for account: AccountContext) { values[reference] = nil }
    func deleteAll(for account: AccountContext) { values = values.filter { $0.value.0 != account } }
    /// Required by main's SessionVault (E01 session rotation); unused by these consumers.
    func replace(_ reference: CredentialReference, with bytes: Data, context: RequestContext) throws { throw DomainError.unsupported }
}
actor HeldStorageParticipant: AccountLifecycleParticipant {
    nonisolated let participantID = "held-storage-test-only"
    var armed = false
    var entered = false
    var gate: CheckedContinuation<Void, Never>?
    func arm() { armed = true }
    func release() { armed = false; gate?.resume(); gate = nil }
    func detach(previous: RequestContext, barrier: RequestContext) async {
        if armed { entered = true; await withCheckedContinuation { gate = $0 } }
    }
    func restorePaused(_ identity: LocalIdentity, context: RequestContext) {}
    func removeLocal(_ account: AccountContext, context: RequestContext) {}
}
actor ConsumerSource: ArtworkSource {
    let bytes: Data
    var calls: [(ArtworkOwner, UInt64, String)] = []
    var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
    init(bytes: Data) { self.bytes = bytes }
    func load(resource: ArtworkResource, owner: ArtworkOwner, generation: UInt64, maximumBytes: Int) async throws -> ArtworkSourceData {
        calls.append((owner, generation, resource.identifier))
        await withCheckedContinuation { gates[resource.identifier, default: []].append($0) }
        return ArtworkSourceData(bytes: bytes, policy: .memory(until: .distantFuture))
    }
    func release(_ id: String) { for gate in gates.removeValue(forKey: id) ?? [] { gate.resume() } }
}
func consumerPNG() throws -> Data { try originalPNG(edge: 32) }
func largeOriginalPNG() throws -> Data { try originalPNG(edge: 1024) }
private func originalPNG(edge: Int) throws -> Data {
    let pixels = Data(repeating: 180, count: edge * edge * 4)
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let image = try #require(CGImage(width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination)); return bytes as Data
}
func consumerAccount() throws -> Account {
    let id = UUID(); let context = try AccountContext(accountID: id, channelID: ID("owned-synthetic"), region: "US")
    return try Account(id: id, serviceIdentity: ServiceID("owned-synthetic"), context: context, displayName: "Synthetic artwork identity", credential: nil)
}
func consumerRequest(_ context: RequestContext, id: String = "image", query: UInt64) throws -> ArtworkRequest {
    ArtworkRequest(resource: try ArtworkResource(namespace: "owned-original-test", identifier: id, revision: "1"), size: try ArtworkSize(pointsWidth: 16, pointsHeight: 16, scale: 2), policy: .memory(until: .distantFuture), context: RequestContext(account: context.account, accountGeneration: context.accountGeneration, requestGeneration: query))
}
@MainActor func consumerEventually(_ predicate: () async -> Bool) async throws {
    let limit = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await predicate()) { guard ContinuousClock.now < limit else { throw ArtworkError.overloaded }; try await Task.sleep(for: .milliseconds(1)) }
}
func connectConsumer(_ lifecycle: AccountLifecycle, _ account: Account) async throws {
    let challenge = try await lifecycle.beginAuthentication()
    try await lifecycle.completeAuthentication(challenge, account: account, secret: Data("owned-test-only-not-a-service-session".utf8))
}

@Suite(.serialized) @MainActor struct ArtworkConsumerTests {
    @Test func twoFeatureQueriesShareProducerAndCancellationDoesNotPoisonPeer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w09-consumers-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ConsumerSource(bytes: try consumerPNG()), authority = ArtworkUIAuthority()
        let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
        let participant = ArtworkAccountParticipant(pipeline: pipeline, presentation: authority)
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [participant])
        let account = try consumerAccount(); try await connectConsumer(lifecycle, account); try await lifecycle.switchIdentity(to: account.context)
        let context = await lifecycle.snapshot().context
        let high = try consumerRequest(context, query: 80), low = try consumerRequest(context, query: 2)
        let first = ArtworkConsumer(), second = ArtworkConsumer()
        let creator = Task { await first.load(high, pipeline: pipeline, authority: authority) }
        try await consumerEventually { await source.calls.count == 1 }
        let peer = Task { await second.load(low, pipeline: pipeline, authority: authority) }
        try await consumerEventually { await pipeline.snapshot().waiters == 2 }
        creator.cancel(); await creator.value
        await source.release("image"); await peer.value
        #expect(first.displayed(for: high, authority: authority) == nil && second.displayed(for: low, authority: authority) != nil)
        #expect(await source.calls.count == 1)
        #expect(await source.calls.first?.1 == context.accountGeneration)
        #expect(await pipeline.snapshot().decodes == 1)
        #expect(await pipeline.nativeSnapshot().mainThreadWorkViolations == 0)
        #expect(!authority.bind(RequestContext(account: try consumerAccount().context, accountGeneration: context.accountGeneration, requestGeneration: 0)))
    }
    @Test func sameConsumerRejectsLateOldQueryEvenWithoutCooperativeCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w09-consumer-race-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ConsumerSource(bytes: try consumerPNG()), authority = ArtworkUIAuthority(), account = try consumerAccount()
        let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
        let context = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 0)
        try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 1); authority.bind(context)
        let old = try consumerRequest(context, id: "old", query: 1), latest = try consumerRequest(context, id: "latest", query: 2)
        let model = ArtworkConsumer()
        let oldTask = Task { await model.load(old, pipeline: pipeline, authority: authority) }
        try await consumerEventually { await source.calls.count == 1 }
        let latestTask = Task { await model.load(latest, pipeline: pipeline, authority: authority) }
        try await consumerEventually { await source.calls.count == 2 }
        await source.release("latest"); await latestTask.value
        #expect(model.displayed(for: latest, authority: authority) != nil)
        await source.release("old"); await oldTask.value
        #expect(model.displayed(for: old, authority: authority) == nil)
        #expect(model.displayed(for: latest, authority: authority) != nil)
        authority.bind(RequestContext(account: nil, accountGeneration: 2, requestGeneration: 0))
        #expect(model.displayed(for: latest, authority: authority) == nil, "Returned pixels must redact immediately at the UI authority barrier")
    }
    @Test func realLifecycleSwitchAndRemovalFenceForgottenConsumersAndDeliveredPixels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w09-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ConsumerSource(bytes: try consumerPNG()), authority = ArtworkUIAuthority()
        let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
        let participant = ArtworkAccountParticipant(pipeline: pipeline, presentation: authority)
        let heldStorage = HeldStorageParticipant()
        let lifecycle = try await AccountLifecycle.open(vault: ConsumerVault(), store: ConsumerDirectory(), participants: [participant, heldStorage])
        let a = try consumerAccount(), b = try consumerAccount()
        try await connectConsumer(lifecycle, a); try await connectConsumer(lifecycle, b)
        try await lifecycle.switchIdentity(to: a.context)
        let old = try consumerRequest(await lifecycle.snapshot().context, id: "old", query: 1)
        let model = ArtworkConsumer()
        let oldTask = Task { await model.load(old, pipeline: pipeline, authority: authority) }
        try await consumerEventually { await source.calls.count == 1 }
        await heldStorage.arm()
        let switching = Task { try await lifecycle.switchIdentity(to: b.context) }
        try await consumerEventually { await heldStorage.entered }
        #expect(!authority.accepts(old.context), "Redaction must precede the suspended storage callback")
        await #expect(throws: ArtworkError.staleAccount) { _ = try await pipeline.image(for: old) }
        await heldStorage.release(); try await switching.value
        #expect(!authority.accepts(old.context))
        await source.release("old"); await oldTask.value
        #expect(model.displayed(for: old, authority: authority) == nil)
        await #expect(throws: ArtworkError.staleAccount) { _ = try await pipeline.image(for: old) }
        let new = try consumerRequest(await lifecycle.snapshot().context, id: "new", query: 1)
        let newTask = Task { await model.load(new, pipeline: pipeline, authority: authority) }
        try await consumerEventually { await source.calls.count == 2 }
        await source.release("new"); await newTask.value
        #expect(model.displayed(for: new, authority: authority) != nil)
        try await lifecycle.remove(b.context)
        #expect(model.displayed(for: new, authority: authority) == nil)
        #expect(await pipeline.snapshot().memoryBytes == 0)
        await #expect(throws: ArtworkError.staleAccount) { try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: b.context), generation: new.context.accountGeneration + 100) }
        await participant.purgeAfterWake()
        await participant.stop()
    }
    @Test func displayGeometryAndDisappearanceBoundConsumerWork() async throws {
        let template = try consumerRequest(RequestContext(account: try consumerAccount().context, accountGeneration: 1, requestGeneration: 1), query: 1)
        let small = try #require(ArtworkDisplayRequest.make(template, width: 52, height: 52, scale: 2))
        let large = try #require(ArtworkDisplayRequest.make(template, width: 240, height: 240, scale: 2))
        #expect(small.size.pixelWidth == 104 && large.size.pixelWidth == 480)
        #expect(small.context == template.context && small.policy == template.policy && small.resource == template.resource)
        #expect(ArtworkDisplayRequest.make(template, width: 0, height: 52, scale: 2) == nil)
        #expect(ArtworkDisplayRequest.make(template, width: 2000, height: 2000, scale: 2) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w09-disappear-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ConsumerSource(bytes: try consumerPNG()), authority = ArtworkUIAuthority(), model = ArtworkConsumer()
        let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
        try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: try #require(template.context.account)), generation: 1)
        authority.bind(template.context)
        let task = Task { await model.load(small, pipeline: pipeline, authority: authority) }
        try await consumerEventually { await source.calls.count == 1 }
        task.cancel(); model.cancel(); await task.value
        #expect(await pipeline.snapshot().waiters == 0)
        await source.release("image")
        #expect(model.displayed(for: small, authority: authority) == nil)
    }
    @Test func defaultSourceRefusesWithoutAnyServiceOrFixtureGrant() async throws {
        let account = try consumerAccount()
        await #expect(throws: DomainError.unsupported) {
            _ = try await UnconnectedArtworkSource().load(resource: ArtworkResource(namespace: "test", identifier: "test", revision: "1"), owner: ArtworkOwner(account: account.context), generation: 1, maximumBytes: 1024)
        }
    }
}
