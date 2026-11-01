import XCTest
import Foundation
import Domain
import Downloads
import AccountSession
import Features
@testable import AppShell

/// The Downloads screen's model and wording, and the production composition (late-bound engine, account lifecycle) with an
/// isolated test keychain and scratch directory. No real store, account or network.
final class ScreenAndCompositionTests: XCTestCase, @unchecked Sendable {
    @MainActor func testEveryStateCauseFailureAndActionHasWordsAndYouTubeMusicHasAnExplanationNotAControl() {
        for phase in DownloadPhase.allCases { XCTAssertFalse(DownloadsText.phase(phase).isEmpty) }
        XCTAssertEqual(DownloadPhase.allCases.count, 9, "OFF06 lists nine states")
        for cause in [DownloadPauseCause.userPaused, .offline, .constrainedNetwork, .expensiveNetwork, .storageBudgetFull, .volumeReserve, .smartCapReached, .diskFull, .accountUnavailable] { XCTAssertFalse(DownloadsText.pause(cause).isEmpty) }
        for failure in [DownloadFailure.retriesExhausted, .corruptBytes, .missingKey, .accountRevoked, .sourceUnavailable, .permissionDenied, .storageUnavailable] { XCTAssertFalse(DownloadsText.failure(failure).isEmpty) }
        for action in DownloadAction.allCases { XCTAssertFalse(DownloadsText.action(action).isEmpty) }
        XCTAssertEqual(DownloadsText.youTubeMusicExplanation, "YouTube Music doesn’t offer downloads on Mac.")
    }
    @MainActor func testAProgressWithoutATotalHasNoFractionAndOneWithATotalIsClamped() {
        XCTAssertNil(DownloadProgress(completedBytes: 500, totalBytes: nil).fraction)
        XCTAssertNil(DownloadProgress(completedBytes: 500, totalBytes: 0).fraction, "a zero total is unknown, not 100%")
        XCTAssertEqual(DownloadProgress(completedBytes: 50, totalBytes: 200).fraction, 0.25)
        XCTAssertEqual(DownloadProgress(completedBytes: 900, totalBytes: 200).fraction, 1)
    }
    @MainActor func testTheModelFollowsTheEngineAndFiltersDownloadedOnly() async throws {
        let engine = ScriptedEngine()
        let model = DownloadsModel(controller: engine)
        model.start()
        for _ in 0..<200 where model.snapshot.rows.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.snapshot.rows.count, 2)
        XCTAssertEqual(model.visibleRows.count, 2)
        model.filter = .downloadedOnly
        XCTAssertEqual(model.visibleRows.map(\.title), ["Kept"], "Downloaded only shows what is saved on this Mac")
        model.stop()
    }
    @MainActor func testRefusalsAreExplainedInWordsAndCleared() async throws {
        let engine = ScriptedEngine(); engine.result = .notOffered(.youTubeMusicNoMacDownloads)
        let model = DownloadsModel(controller: engine)
        model.addFiles([]); model.setSmartDownloads(true)
        for _ in 0..<200 where model.notice == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.notice, DownloadsText.youTubeMusicExplanation)
        engine.result = .done; model.setBudget(bytes: 5 << 30)
        for _ in 0..<200 where model.notice != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(model.notice, "a successful request clears the notice")
    }
    func testBudgetChoicesIncludeTheCurrentValueAndAreSorted() {
        XCTAssertEqual(DownloadBudgetChoices.defaultBytes, 20 * (1 << 30))
        let options = DownloadBudgetChoices.options(including: 33 << 30)
        XCTAssertTrue(options.contains(33 << 30)); XCTAssertEqual(options, options.sorted()); XCTAssertEqual(Set(options).count, options.count)
    }

    // MARK: Composition

    func testTheLateBoundEngineAnswersNoAccountUntilAttachedAndBound() async throws {
        let env = try Env(systemClock: true); defer { env.cleanup() }
        let late = LateBoundDownloads()
        let before = await late.snapshot(); XCTAssertEqual(before, DownloadsSnapshot.unbound); XCTAssertFalse(before.hasAccount)
        let refused = await late.addLocalFile(env.root.appendingPathComponent("x.wav")); XCTAssertEqual(refused, .refused(.unauthorized))
        let kit = try env.realStore(); defer { Task { try? await kit.1.destroyIsolatedTestKeychain() } }
        try await late.attach(directory: env.root.appendingPathComponent("app"), vault: kit.1, volume: env.volume)
        let attached = await late.snapshot(); XCTAssertFalse(attached.hasAccount, "attached but no connected identity yet")
        // A connected identity binds it; a signed-out or expired one does not.
        let account = try Account(id: env.account.accountID, serviceIdentity: ServiceID("w15-test"), context: env.account, displayName: "Test", credential: nil)
        try await late.restorePaused(LocalIdentity(account: account, state: .expired), context: env.context)
        let expired = await late.snapshot(); XCTAssertFalse(expired.hasAccount, "an expired identity runs no downloads")
        try await late.restorePaused(LocalIdentity(account: account, state: .connected), context: env.context)
        let bound = await late.snapshot(); XCTAssertTrue(bound.hasAccount)
        XCTAssertEqual(bound.storage.budgetBytes, DownloadPolicy.defaultBudget, "20 GiB default")
        XCTAssertFalse(bound.smartDownloadsEnabled, "Smart Downloads is off by default")
        // A real (generated) audio file is kept through the production path into the encrypted store.
        let audio = env.root.appendingPathComponent("Kept Take.wav"); try silentWave().write(to: audio)
        let added = await late.addLocalFile(audio); XCTAssertEqual(added, .done)
        for _ in 0..<400 { if await late.snapshot().rows.first?.phase == .available { break }; try await Task.sleep(for: .milliseconds(10)) }
        let finalSnapshot = await late.snapshot(); let rows = finalSnapshot.rows
        XCTAssertEqual(rows.first?.phase, .available, "row: \(String(describing: rows.first)) snapshot: \(finalSnapshot)"); XCTAssertEqual(rows.first?.title, "Kept Take")
        // Switching away leaves the work checkpointed and idle; removing the account removes its downloads data.
        try await late.detach(previous: env.context, barrier: RequestContext(account: nil, accountGeneration: 2, requestGeneration: 0))
        let detached = await late.snapshot(); XCTAssertFalse(detached.hasAccount)
        try await late.removeLocal(env.account, context: RequestContext(account: nil, accountGeneration: 3, requestGeneration: 0))
        let ledger = env.root.appendingPathComponent("app/downloads/jobs/" + DownloadLedgerNames.directory(env.account))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.path))
        await late.quit()
    }
    func testTheDevelopmentControllerIsDebugOnlyAndNeverReachesTheEngine() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AppShell/DownloadsComposition.swift")
        let text = try String(contentsOf: sources, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "#if DEBUG")), end = try XCTUnwrap(text.range(of: "#endif", options: .backwards))
        let debug = String(text[start.lowerBound..<end.upperBound])
        XCTAssertTrue(debug.contains("DevelopmentDownloadsController") && debug.contains("YTMUSE_UI_DEVELOPMENT_DOWNLOADS"))
        XCTAssertFalse(debug.contains("DownloadScheduler"), "the development controller has no engine, store or Keychain behind it")
        XCTAssertFalse(text[text.startIndex..<start.lowerBound].contains("DevelopmentDownloads"))
        XCTAssertFalse(DevelopmentDownloads.isEnabled([:]), "off unless explicitly enabled")
    }
    private func silentWave() -> Data {
        var wav = Data("RIFF".utf8); let samples = Data(count: 1600)
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        wav.append(contentsOf: le(UInt32(36 + samples.count))); wav.append(Data("WAVEfmt ".utf8)); wav.append(contentsOf: le(UInt32(16))); wav.append(contentsOf: le(UInt16(1)))
        wav.append(contentsOf: le(UInt16(1))); wav.append(contentsOf: le(UInt32(8000))); wav.append(contentsOf: le(UInt32(16000))); wav.append(contentsOf: le(UInt16(2)))
        wav.append(contentsOf: le(UInt16(16))); wav.append(Data("data".utf8)); wav.append(contentsOf: le(UInt32(samples.count))); wav.append(samples)
        return wav
    }
}

private func makeRow(_ title: String, _ phase: DownloadPhase) -> DownloadRowModel {
    DownloadRowModel(id: UUID(), media: try! ServiceID("owned-" + title), title: title, subtitle: nil, origin: .owned, phase: phase, progress: DownloadProgress(completedBytes: 1, totalBytes: 2), pauseCause: nil, failure: nil, pinned: true,
                     automatic: false, referenceCount: 1, storedBytes: 0, retryAt: nil, expiresAt: nil, actions: [])
}
final class ScriptedEngine: DownloadsControlling, @unchecked Sendable {
    nonisolated(unsafe) var result: DownloadCommandResult = .done
    private var snapshotValue: DownloadsSnapshot {
        var base = DownloadsSnapshot.unbound
        base = DownloadsSnapshot(rows: [makeRow("Kept", .available), makeRow("Going", .downloading)], collections: [], aggregate: nil, activeCount: 1, waitingCount: 0, storage: base.storage, storageChoices: [], smartDownloadsEnabled: false,
                                 concurrencyLimit: 2, lowPowerMode: false, networkConstrained: false, networkExpensive: false, networkAvailable: true, hasAccount: true)
        return base
    }
    func snapshot() async -> DownloadsSnapshot { snapshotValue }
    func updates() async -> AsyncStream<DownloadsSnapshot> { AsyncStream { $0.yield(snapshotValue) } }
    func perform(_ action: DownloadAction, job: UUID) async -> DownloadCommandResult { result }
    func setBudget(bytes: Int64) async -> DownloadCommandResult { result }
    func setSmartDownloads(enabled: Bool) async -> DownloadCommandResult { result }
    func addLocalFile(_ file: URL) async -> DownloadCommandResult { result }
    func play(job: UUID) async -> DownloadCommandResult { result }
    func removeAutomaticDownloads() async -> DownloadCommandResult { result }
}
