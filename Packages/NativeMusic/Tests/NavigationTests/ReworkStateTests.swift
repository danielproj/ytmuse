import Foundation
import Testing
import Domain
import Queue
import DesignSystem
import Features
import Artwork
import AccountSession
@testable import AppShell

@Suite(.serialized) @MainActor struct ReworkStateTests {
    @Test func pagedMovesUseGlobalOccurrencesAndProtectImmutableSlots() throws {
        for page in [0, 1, 2] {
            for mode in 0..<3 {
                var queue = QueueMachine(account: try consumerAccount().context, supportsAutoplay: false)
                try queue.replaceContext((0..<240).map { try ServiceID("internal-\($0)") }, source: ServiceID("test-owned-context"))
                let entries = queue.entries
                let rows = entries.map { QueueRow(id: $0.id, title: "Untitled item", segment: "Selection", current: $0.id == queue.current, editable: $0.id != queue.current) }
                let start = page * 80, slice = Array(rows[start..<start+80])
                let boundary = QueuePageBoundary(previous: start > 0 ? rows[start - 1] : nil, following: Array(rows.dropFirst(start + 80).prefix(2)))
                let index = mode == 0 ? 10 : mode == 1 ? 78 : 79
                let intent = mode == 0 ? QueuePageMoves.drag(rows: slice, boundary: boundary, source: [10], destination: 80) : QueuePageMoves.down(rows: slice, boundary: boundary, index: index)
                if page == 2 && index == 79 { #expect(intent == nil); continue }
                let move = try #require(intent)
                try queue.move(move.occurrences, before: move.before)
                #expect(queue.entries.firstIndex(where: { $0.id == slice[index].id }) == start + (mode == 0 ? 79 : index + 1))
                #expect(queue.current == entries[0].id)
                // The UI's non-drag action has the same occurrence semantics as the drag command.
                if page > 0 { #expect(QueuePageMoves.up(rows: slice, boundary: boundary, index: 0)?.before == rows[start - 1].id) }
            }
        }
        var queue = QueueMachine(account: try consumerAccount().context, supportsAutoplay: false)
        try queue.replaceContext((0..<200).map { try ServiceID("protected-\($0)") }, source: ServiceID("test"))
        let current = queue.entries[0].id
        let immutable = try QueueEntry(media: ServiceID("source-ad"), segment: .advertisement, originalOrder: 999, consumed: false)
        try queue.appendService(immutable, immutable: true)
        #expect(throws: (any Error).self) { try queue.move([current], before: nil) }
        #expect(throws: (any Error).self) { try queue.move([immutable.id], before: nil) }
        let protected = QueueRow(id: immutable.id, title: "Advertisement", segment: "Advertisement", current: false, editable: false)
        let normal = QueueRow(id: UUID(), title: "Untitled item", segment: "Selection", current: false)
        #expect(QueuePageMoves.down(rows: [normal], boundary: .init(following: [protected]), index: 0) == nil)
        #expect(QueuePageMoves.drag(rows: [protected, normal], boundary: .init(), source: [0], destination: 2) == nil)
    }
    @Test func pageIntentExecutesRealQueueCommandsAndRetainsProtectedEntries() async throws {
        let account = try consumerAccount().context
        let context = RequestContext(account: account, accountGeneration: 1, requestGeneration: 0)
        var machine = QueueMachine(account: account, supportsAutoplay: false)
        try machine.replaceContext((0..<240).map { try ServiceID("owned-queue-\($0)") }, source: ServiceID("original-test-context"))
        let commands = try QueueCommands(machine: machine, context: context, persistence: ReworkQueueStorage(), playback: ReworkSilentBoundary(), repeatSupported: true)
        let original = try await commands.snapshot(), entries = original.session.entries
        let rows = entries.prefix(80).map { QueueRow(id: $0.id, title: "Untitled item", segment: "Selection", current: $0.id == original.current?.id, editable: $0.id != original.current?.id) }
        let next = entries.dropFirst(80).prefix(2).map { QueueRow(id: $0.id, title: "Untitled item", segment: "Selection", current: false) }
        let move = try #require(QueuePageMoves.drag(rows: rows, boundary: .init(following: next), source: [10], destination: 80))
        _ = try await commands.execute(.move(move.occurrences, before: move.before), context: context, origin: .userInterface)
        #expect(try await commands.snapshot().session.entries.firstIndex { $0.id == entries[10].id } == 79)
        let protected = try QueueEntry(media: ServiceID("owned-test-ad"), segment: .advertisement, originalOrder: 999, consumed: false)
        _ = try await commands.execute(.serviceEntry(protected, immutable: true), context: context, origin: .userInterface)
        let before = try await commands.snapshot().session.entries.map(\.id)
        await #expect(throws: (any Error).self) { _ = try await commands.execute(.move([protected.id], before: nil), context: context, origin: .userInterface) }
        #expect(try await commands.snapshot().session.entries.map(\.id) == before)
        await #expect(throws: (any Error).self) { _ = try await commands.execute(.move([try #require(original.current?.id)], before: nil), context: context, origin: .userInterface) }
        #expect(try await commands.snapshot().current?.id == original.current?.id)
    }
    @Test func adaptivePanelPreservesSelectionAcrossAutomaticDismissal() {
        let panel = AdaptivePanelPresentation<String>()
        panel.selection = "Lyrics"; panel.allowsInline = false
        #expect(panel.presentsSheet)
        panel.allowsInline = true
        panel.sheetChanged(false)
        #expect(panel.selection == "Lyrics" && !panel.presentsSheet)
        panel.allowsInline = false
        #expect(panel.presentsSheet)
        panel.sheetChanged(false)
        #expect(panel.selection == nil, "An actual compact-sheet user dismissal closes the panel")
        panel.toggle("Queue"); panel.toggle("Queue"); #expect(panel.selection == nil)
    }
    @Test func sameAccountNewGenerationRetractsReturnedPixels_M15() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ConsumerSource(bytes: try consumerPNG()), authority = ArtworkUIAuthority()
        let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
        let account = try consumerAccount(), model = ArtworkConsumer()
        let one = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 7)
        try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 1); authority.bind(one)
        let request = try consumerRequest(one, query: 7)
        let load = Task { await model.load(request, pipeline: pipeline, authority: authority) }
        try await consumerEventually { await source.calls.count == 1 }; await source.release("image"); await load.value
        #expect(model.displayed(for: request, authority: authority) != nil)
        let two = RequestContext(account: account.context, accountGeneration: 2, requestGeneration: 7)
        authority.bind(two)
        #expect(!authority.accepts(one))
        #expect(model.displayed(for: request, authority: authority) == nil)
        try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 2)
        let fresh = try consumerRequest(two, query: 7)
        await model.load(fresh, pipeline: pipeline, authority: authority)
        #expect(model.displayed(for: fresh, authority: authority) != nil)
        #expect(await source.calls.count == 1, "Authorized retained content may be reused at the newer generation")
    }
    @Test func uiRetractsBeforeThrowingPipelineInvalidation_M20() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ConsumerSource(bytes: try consumerPNG()), authority = ArtworkUIAuthority(), account = try consumerAccount()
        let pipeline = ArtworkPipeline(source: source, diskDirectory: directory)
        let one = RequestContext(account: account.context, accountGeneration: 1, requestGeneration: 0)
        authority.bind(one); try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 1)
        let request = try consumerRequest(one, query: 1), model = ArtworkConsumer()
        let task = Task { await model.load(request, pipeline: pipeline, authority: authority) }
        try await consumerEventually { await source.calls.count == 1 }; await source.release("image"); await task.value
        #expect(model.displayed(for: request, authority: authority) != nil)
        try await pipeline.setAccountGeneration(owner: ArtworkOwner(account: account.context), generation: 10)
        let participant = ArtworkAccountParticipant(pipeline: pipeline, presentation: authority)
        await #expect(throws: ArtworkError.staleAccount) { try await participant.detach(previous: one, barrier: .init(account: nil, accountGeneration: 2, requestGeneration: 0)) }
        #expect(!authority.accepts(one))
        #expect(model.displayed(for: request, authority: authority) == nil)
    }
    @Test func actionFailureRecoveryAndTitlesNeverExposeProviderIdentifiers() async throws {
        let model = PlaybackModel(controlledAudioTest: true)
        let media = try ServiceID("private-provider-identifier")
        #expect(model.title(for: media) == "Untitled item")
        model.titles[media] = "Björk — supplied metadata"
        #expect(model.title(for: media) == "Björk — supplied metadata")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Since main's offline store (W14) the owned session opens protected records; keep them in an isolated keychain file.
        let vault = try KeychainVault(testNamespace: KeychainVault.applicationNamespace + ".test.w09-rework-" + UUID().uuidString, isolatedKeychainURL: directory.appendingPathComponent("isolated.keychain-db"))
        let authority = AppPlaybackAuthority(directory: directory, offlineVault: vault)
        model.session = try await authority.owned(request: authority.requestOwnedStart(), initialGain: 0.001, maximumStartGain: 0.001)
        await model.act(action: .reorderQueue) { _ in throw DomainError.forbidden }
        #expect(model.error?.contains("queue") == true && model.canRetryAction)
        #expect(model.error?.contains("selected item") == false)
        await model.retryFailedAction()
        #expect(model.failedAction == .reorderQueue)
        model.session = nil
        #expect(!model.canRetryAction)
        await authority.quit()
    }
}

private actor ReworkQueueStorage: QueuePersistence {
    var value: QueueSnapshot?
    func load(context: RequestContext) -> QueueSnapshot? { value }
    func save(_ value: QueueSnapshot, context: RequestContext) { self.value = value }
}
private struct ReworkSilentBoundary: QueuePlaybackBoundary {
    func select(_ entry: QueueEntry, token: UUID, context: RequestContext, origin: CommandOrigin) {}
    func pause(context: RequestContext, origin: CommandOrigin) {}
}
