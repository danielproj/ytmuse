import Foundation
import Testing
@testable import Updates

/// T30.3 and T30.2 through the controller: update checks are off until the person says otherwise, ask once, run at most daily after opt-in, never
/// install without the explicit restart, and never swap while playing.
@MainActor @Suite struct ControllerTests {
    let scratch = ScratchFolder()
    let builder = FeedBuilder()
    let bytes = Data("pretend dmg".utf8)
    final class Clock: @unchecked Sendable { var now = testNow; func read() -> Date { now } }

    struct Rig {
        let controller: UpdateController
        let network: FakeNetwork
        let store: InMemoryUpdateStateStore
        let relauncher: RecordingRelauncher
        let playing: PlaybackFlag
        let clock: Clock
        let installed: URL
    }
    func rig(configured: Bool = true, state: UpdateState = UpdateState(), feed: Data? = nil, offerBytes: Data? = nil) throws -> Rig {
        let applications = scratch.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let installed = applications.appendingPathComponent("YTMuse.app")
        try makeApp(at: installed, version: "1.0.0", build: 100)
        var release = FeedBuilder.release(version: "1.2.0", build: 120)
        if let offerBytes {
            var asset = release["asset"] as! [String: Any]; asset["length"] = offerBytes.count
            asset["sha256"] = offerRelease(offerBytes).asset.sha256; release["asset"] = asset
        }
        var b = builder; b.releases = [release]
        let network = FakeNetwork(feed: feed ?? b.signed()); network.asset = offerBytes ?? Data()
        let store = InMemoryUpdateStateStore(); store.save(state)
        let relauncher = RecordingRelauncher(), playing = PlaybackFlag(), clock = Clock()
        let signature = FakeSignature()
        let stager = UpdateStager(root: scratch.url.appendingPathComponent("Updates"), network: network, extractor: FakeExtractor(), signature: signature)
        let configuration = configured ? UpdateConfiguration(policy: b.policy, feedURL: URL(string: "https://github.com/\(repository)/releases/latest/download/feed.json")!) : nil
        let controller = UpdateController(configuration: configuration, running: runningApp, installedBundle: installed, store: store, network: network, stager: stager,
                                          installer: BundleInstaller(signature: signature), relauncher: relauncher, playbackActive: { playing.ask() }, now: { clock.read() })
        return Rig(controller: controller, network: network, store: store, relauncher: relauncher, playing: playing, clock: clock, installed: installed)
    }
    func offerRelease(_ data: Data) -> FeedRelease { try! offeredRelease(for: data) }

    // MARK: default off, ask once

    @Test func theDefaultIsAskOnceAndNothingIsRequestedUntilAnswered() async throws {
        defer { scratch.remove() }
        let r = try rig()
        #expect(r.controller.state.mode == .undecided)
        #expect(r.controller.shouldAskOnce)
        await r.controller.checkIfDue()
        r.controller.startPeriodicChecks(firstAfter: .zero, every: .seconds(1), sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
        try await Task.sleep(for: .milliseconds(60))
        r.controller.stopPeriodicChecks()
        #expect(r.network.count == 0, "an undecided Mac makes no request on its own initiative")
    }
    @Test func decliningMeansNoAutomaticRequestsAndTheQuestionIsNeverAskedAgain() async throws {
        defer { scratch.remove() }
        let r = try rig()
        r.controller.answerAskOnce(checkDaily: false)
        #expect(r.controller.state.mode == .manualOnly && !r.controller.shouldAskOnce)
        await r.controller.checkIfDue()
        r.clock.now = testNow.addingTimeInterval(86_400 * 40); await r.controller.checkIfDue()
        #expect(r.network.count == 0)
        #expect(!r.controller.shouldAskOnce)
    }
    @Test func theAnswerSurvivesARestartAndIsNotAskedAgain() async throws {
        defer { scratch.remove() }
        let first = try rig(); first.controller.answerAskOnce(checkDaily: true)
        let second = try rig(state: first.store.load())
        #expect(second.controller.state.mode == .daily && !second.controller.shouldAskOnce)
        let suite = "ytmuse-w30-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let persisted = UserDefaultsUpdateStateStore(defaults: defaults)
        var state = UpdateState(); state.mode = .daily; state.automaticInstallation = true; state.lastAcceptedSequence = 7
        persisted.save(state)
        #expect(UserDefaultsUpdateStateStore(defaults: defaults).load() == state)
        #expect(UpdateState().mode == .undecided && UpdateState().automaticInstallation == false)   // the defaults
        defaults.removePersistentDomain(forName: suite)
    }
    @Test func aBuildWithoutAFeedNeverAsksAndNeverContactsAnything() async throws {
        defer { scratch.remove() }
        let r = try rig(configured: false)
        #expect(!r.controller.isAvailable && !r.controller.shouldAskOnce)
        #expect(r.controller.unavailable == .noFeedConfigured)
        r.controller.answerAskOnce(checkDaily: true)                  // ignored
        await r.controller.checkNow(); await r.controller.checkIfDue()
        #expect(r.network.count == 0)
        #expect(r.controller.state.mode == .undecided)
    }

    // MARK: daily schedule after opt-in

    @Test func afterOptInTheCheckRunsAtMostOnceADayAndRetriesAfterAnHourOnFailure() async throws {
        defer { scratch.remove() }
        let r = try rig()
        r.controller.answerAskOnce(checkDaily: true)
        await r.controller.checkIfDue(); #expect(r.network.count == 1)
        r.clock.now = testNow.addingTimeInterval(3600 * 23); await r.controller.checkIfDue(); #expect(r.network.count == 1)
        r.clock.now = testNow.addingTimeInterval(86_400 + 1); await r.controller.checkIfDue(); #expect(r.network.count == 2)
        // a failure retries after an hour, not after a day and not immediately
        r.network.failure = URLError(.timedOut)
        r.clock.now = testNow.addingTimeInterval(86_400 * 3); await r.controller.checkIfDue(); #expect(r.network.count == 3)
        #expect(r.controller.status == .failed("transport"))
        r.clock.now = r.clock.now.addingTimeInterval(1800); await r.controller.checkIfDue(); #expect(r.network.count == 3)
        r.clock.now = r.clock.now.addingTimeInterval(1800 + 1); await r.controller.checkIfDue(); #expect(r.network.count == 4)
    }
    @Test func aPersonCanAlwaysCheckNowEvenBeforeAnsweringTheQuestion() async throws {
        defer { scratch.remove() }
        let r = try rig()
        await r.controller.checkNow()
        #expect(r.network.count == 1)
        #expect(r.controller.status == .offered("1.2.0"))
        #expect(r.controller.state.mode == .undecided)                // checking now is not consent to check daily
    }
    @Test func aRejectedFeedDoesNotAdvanceTheAcceptedSequence() async throws {
        defer { scratch.remove() }
        var tampered = envelopeObject(builder.signed()); tampered["keyID"] = "ed25519:0000000000000000"
        let r = try rig(feed: envelopeData(tampered))
        await r.controller.checkNow()
        #expect(r.controller.status == .failed("unknownKey"))
        #expect(r.controller.state.lastAcceptedSequence == 0 && r.controller.offer == nil)
        let ok = try rig(); await ok.controller.checkNow()
        #expect(ok.controller.state.lastAcceptedSequence == 10)
        ok.network.feed = { var old = builder; old.sequence = 3; return old.signed() }()
        await ok.controller.checkNow()
        #expect(ok.controller.status == .failed("rollback"))
    }

    // MARK: staging and installing

    @Test func automaticInstallationStagesButNeverInstallsOrRestarts() async throws {
        defer { scratch.remove() }
        var state = UpdateState(); state.mode = .daily; state.automaticInstallation = true
        let r = try rig(state: state, offerBytes: bytes)
        await r.controller.checkIfDue()
        #expect(r.controller.status == .ready("1.2.0"))
        #expect(marker(of: r.installed) == "version 1.0.0")           // staged, not installed
        #expect(r.relauncher.relaunched.isEmpty)
    }
    @Test func automaticInstallationWaitsWhilePlaying() async throws {
        defer { scratch.remove() }
        var state = UpdateState(); state.mode = .daily; state.automaticInstallation = true
        let r = try rig(state: state, offerBytes: bytes)
        r.playing.playing = true
        await r.controller.checkIfDue()
        #expect(r.controller.status == .offered("1.2.0"))              // found, not downloaded
        #expect(r.network.requests.count == 1)                         // only the feed was requested
    }
    @Test func withAutomaticInstallationOffNothingIsDownloadedUntilThePersonChooses() async throws {
        defer { scratch.remove() }
        let r = try rig(state: { var s = UpdateState(); s.mode = .daily; return s }(), offerBytes: bytes)
        await r.controller.checkIfDue()
        #expect(r.controller.status == .offered("1.2.0") && r.network.count == 1)
        await r.controller.download()
        #expect(r.controller.status == .ready("1.2.0") && r.network.count == 2)
    }
    @Test func restartIsRefusedWithoutConfirmationAndWhilePlayingAndRelaunchesOnlyAfterAnInstall() async throws {
        defer { scratch.remove() }
        let r = try rig(offerBytes: bytes)
        await r.controller.checkNow(); await r.controller.download()
        #expect(r.controller.status == .ready("1.2.0"))
        r.controller.restartToInstall(confirmation: nil)
        #expect(r.controller.installFailure == "restartNotRequested" && r.controller.status == .ready("1.2.0") && r.relauncher.relaunched.isEmpty && marker(of: r.installed) == "version 1.0.0")
        r.playing.playing = true
        r.controller.restartToInstall(confirmation: .fromPersonAction())
        #expect(r.controller.installFailure == "playbackActive" && r.controller.status == .ready("1.2.0") && r.relauncher.relaunched.isEmpty && marker(of: r.installed) == "version 1.0.0")   // still ready: the person may try again
        r.playing.playing = false
        r.controller.restartToInstall(confirmation: .fromPersonAction())
        #expect(r.relauncher.relaunched == [r.installed] && marker(of: r.installed) == "version 1.2.0")
    }
    @Test func checkingAgainWhileTheUpdateIsStagedKeepsItReadyAndDownloadsNothingMore() async throws {
        defer { scratch.remove() }
        var state = UpdateState(); state.mode = .daily; state.automaticInstallation = true
        let r = try rig(state: state, offerBytes: bytes)
        await r.controller.checkNow()
        #expect(r.controller.status == .ready("1.2.0") && r.network.count == 2)      // the feed, then the asset
        await r.controller.checkNow()
        #expect(r.controller.status == .ready("1.2.0") && r.network.count == 3)      // only the feed again
    }
    @Test func aDownloadThatDoesNotMatchTheFeedIsNeverStaged() async throws {
        defer { scratch.remove() }
        let r = try rig(offerBytes: bytes)
        r.network.asset = Data("something else entirely".utf8)
        await r.controller.checkNow(); await r.controller.download()
        #expect(r.controller.status == .failed("assetLengthMismatch") && r.controller.staged == nil)
        r.controller.restartToInstall(confirmation: .fromPersonAction())
        #expect(r.controller.installFailure == "notStaged" && r.relauncher.relaunched.isEmpty)
    }
}
