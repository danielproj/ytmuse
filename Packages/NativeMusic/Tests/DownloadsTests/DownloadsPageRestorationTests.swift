import Domain
import Foundation
import Testing
@testable import Features

/// W09-F2: the Downloads visit remembers its segmented filter.
@Suite @MainActor struct DownloadsPageRestorationTests {
    private final class Engine: DownloadsControlling, @unchecked Sendable {
        func snapshot() async -> DownloadsSnapshot { .unbound }
        func updates() async -> AsyncStream<DownloadsSnapshot> { AsyncStream { $0.yield(.unbound) } }
        func perform(_ action: DownloadAction, job: UUID) async -> DownloadCommandResult { .done }
        func setBudget(bytes: Int64) async -> DownloadCommandResult { .done }
        func setSmartDownloads(enabled: Bool) async -> DownloadCommandResult { .done }
        func addLocalFile(_ file: URL) async -> DownloadCommandResult { .done }
        func play(job: UUID) async -> DownloadCommandResult { .done }
        func removeAutomaticDownloads() async -> DownloadCommandResult { .done }
    }
    @Test func theFilterIsRecordedAndPutBack() {
        let model = DownloadsModel(controller: Engine())
        #expect(model.pageMemory == PageMemory(values: ["filter": "all"]))
        model.filter = .downloadedOnly
        let saved = model.pageMemory
        model.filter = .all
        model.restorePage(saved)
        #expect(model.filter == .downloadedOnly)
    }
    @Test func aFilterTheBuildDoesNotKnowFallsBackToAll() {
        let model = DownloadsModel(controller: Engine()); model.filter = .downloadedOnly
        model.restorePage(PageMemory(values: ["filter": "from-a-newer-version"]))
        #expect(model.filter == .all)
        model.filter = .downloadedOnly
        model.restorePage(PageMemory())
        #expect(model.filter == .all)
    }
}
