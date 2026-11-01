import Foundation
import Observation

/// What this build is configured to do. A source build has no feed and no pinned key, so it is `unavailable` and never contacts anything.
public struct UpdateConfiguration: Sendable, Equatable {
    public let policy: UpdateTrustPolicy
    public let feedURL: URL
    public init(policy: UpdateTrustPolicy, feedURL: URL) { self.policy = policy; self.feedURL = feedURL }
    /// Info.plist keys written at packaging time by `scripts/package-release.sh`; the repository carries none.
    public static let feedURLKey = "YTMuseUpdateFeedURL", keysKey = "YTMuseUpdatePublicKeys", repositoryKey = "YTMuseUpdateRepository"
    public init?(infoDictionary: [String: Any]) {
        guard let repository = infoDictionary[Self.repositoryKey] as? String, !repository.isEmpty,
              let encoded = infoDictionary[Self.keysKey] as? [String], !encoded.isEmpty,
              let urlText = infoDictionary[Self.feedURLKey] as? String, !urlText.isEmpty else { return nil }
        let keys = encoded.compactMap { Data(base64Encoded: $0) }
        guard keys.count == encoded.count, let policy = UpdateTrustPolicy(publicKeys: keys, repository: repository),
              let url = UpdateRequests.feedURL(urlText, policy: policy) else { return nil }
        self.init(policy: policy, feedURL: url)
    }
}

public enum UpdateUnavailableReason: Equatable, Sendable {
    case noFeedConfigured     // a source build: no feed URL or key in the app
    case notSignedForUpdates  // an ad-hoc or unsigned build has no identity a release could be matched against
    case isolatedSession      // a test or QA launch never contacts a feed
    public var message: String {
        switch self {
        case .noFeedConfigured: String(localized: "This build has no update feed. Source builds are updated from the source repository.")
        case .notSignedForUpdates: String(localized: "This build is not signed with a release identity, so it cannot verify or install updates.")
        case .isolatedSession: String(localized: "This is an isolated test session. It never contacts an update feed.")
        }
    }
}

public enum UpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case offered(String)
    case downloading(String)
    case ready(String)          // staged and verified; waiting for the person's restart
    case failed(String)         // a stable rejection code, never feed content
}

@MainActor @Observable
public final class UpdateController {
    public private(set) var status: UpdateStatus = .idle
    public private(set) var state: UpdateState
    public private(set) var offer: FeedRelease?
    public private(set) var staged: StagedUpdate?
    /// Why the last restart was refused (a stable code), while the verified update stays staged and the person may try again.
    public private(set) var installFailure: String?
    public let unavailable: UpdateUnavailableReason?

    private let configuration: UpdateConfiguration?
    private let running: RunningApplication
    private let installedBundle: URL
    private let store: any UpdateStateStore
    private let network: any UpdateNetwork
    private let stager: UpdateStager?
    private let installer: BundleInstaller?
    private let relauncher: (any AppRelaunching)?
    private let playbackActive: @MainActor () -> Bool
    private let now: @Sendable () -> Date
    @ObservationIgnored private var periodic: Task<Void, Never>?
    public static let checkInterval: TimeInterval = 86_400
    public static let retryInterval: TimeInterval = 3_600

    public init(configuration: UpdateConfiguration?, capability unavailable: UpdateUnavailableReason? = nil, running: RunningApplication, installedBundle: URL, store: any UpdateStateStore,
                network: any UpdateNetwork, stager: UpdateStager?, installer: BundleInstaller?, relauncher: (any AppRelaunching)?,
                playbackActive: @escaping @MainActor () -> Bool, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.unavailable = configuration == nil ? .noFeedConfigured : unavailable
        self.running = running; self.installedBundle = installedBundle; self.store = store; self.network = network
        self.stager = stager; self.installer = installer; self.relauncher = relauncher; self.playbackActive = playbackActive; self.now = now
        self.state = store.load()
        if self.unavailable == nil, let found = stager?.staged(running: running) { staged = found; status = .ready(found.version) }
    }

    public var isAvailable: Bool { unavailable == nil }
    /// True once, until the person answers: the app asks "Check for updates daily?" and records the answer either way.
    public var shouldAskOnce: Bool { isAvailable && state.mode == .undecided }
    public var restartBlockedByPlayback: Bool { playbackActive() }

    // MARK: choices (each is an explicit person action)

    public func answerAskOnce(checkDaily: Bool) {
        guard isAvailable else { return }
        update { $0.mode = checkDaily ? .daily : .manualOnly; if checkDaily { $0.nextCheckAt = nil } }
    }
    public func setDailyChecks(_ on: Bool) {
        guard isAvailable else { return }
        update { $0.mode = on ? .daily : .manualOnly; if on { $0.nextCheckAt = nil } }
    }
    /// "Restore Defaults" / "Ask me once": back to undecided, no automatic download. The accepted feed sequence is kept (forgetting it would reopen a replay window).
    public func resetChoices() {
        guard isAvailable else { return }
        update { $0.mode = .undecided; $0.automaticInstallation = false; $0.nextCheckAt = nil }
    }
    public func setAutomaticInstallation(_ on: Bool) {
        guard isAvailable else { return }
        update { $0.automaticInstallation = on }
    }

    // MARK: checking

    /// "Check Now": the person asked, so it runs whatever the daily setting says.
    public func checkNow() async { await check() }

    /// The scheduler's entry: only when the person opted in, only when a day has passed since the last check (an hour after a failure).
    public func checkIfDue() async {
        guard isAvailable, state.mode == .daily else { return }
        if let next = state.nextCheckAt, now() < next { return }
        await check()
    }

    /// Wakes up hourly while the app runs and calls `checkIfDue`. Nothing runs when the app is not running: there is no agent or daemon.
    public func startPeriodicChecks(firstAfter delay: Duration = .seconds(60), every interval: Duration = .seconds(3_600), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        periodic?.cancel()
        periodic = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            while !Task.isCancelled {
                await self?.checkIfDue()
                do { try await sleep(interval) } catch { return }
            }
        }
    }
    public func stopPeriodicChecks() { periodic?.cancel(); periodic = nil }

    private func check() async {
        guard let configuration, isAvailable else { status = .failed(UpdateRejection.notConfigured.code); return }
        if case .checking = status { return }
        status = .checking
        do {
            let data = try await network.get(UpdateRequests.feed(configuration.feedURL), maxBytes: FeedFormat.maximumFeedBytes)
            let verified = try FeedVerifier.verify(data, policy: configuration.policy, running: running, now: now(), lastAcceptedSequence: state.lastAcceptedSequence)
            update { $0.lastAcceptedSequence = max($0.lastAcceptedSequence, verified.payload.sequence); $0.lastCheckedAt = self.now(); $0.nextCheckAt = self.now().addingTimeInterval(Self.checkInterval) }
            offer = verified.offer
            if let release = verified.offer, let staged, staged.version == release.version.description {
                status = .ready(staged.version)   // this very update is already downloaded and verified: keep it ready, do not download it again
            } else if let release = verified.offer {
                status = .offered(release.version.description)
                if state.automaticInstallation, !playbackActive() { await download() }
            } else { status = .upToDate }
        } catch {
            update { $0.nextCheckAt = self.now().addingTimeInterval(Self.retryInterval) }
            status = .failed(((error as? UpdateRejection) ?? UpdateRejection.transport("network")).code)
        }
    }

    // MARK: staging and installing

    /// Downloads and verifies the offered release (explicit "Download", or automatic when the person turned that on). Installs nothing.
    public func download() async {
        guard let release = offer, let stager, isAvailable else { return }
        status = .downloading(release.version.description)
        do {
            staged = try await stager.stage(release, running: running)
            status = .ready(release.version.description)
        } catch {
            staged = nil
            status = .failed(((error as? UpdateRejection) ?? UpdateRejection.transport("staging")).code)
        }
    }

    /// Installs the staged update and restarts into it. Needs the person's confirmation, refuses while anything is playing, and replaces nothing otherwise.
    public func restartToInstall(confirmation: RestartConfirmation?) {
        guard let staged, let installer, let relauncher else { installFailure = UpdateRejection.notStaged.code; return }
        installFailure = nil
        do {
            let url = try installer.install(staged, over: installedBundle, running: running, confirmation: confirmation, playbackActive: { MainActor.assumeIsolated { self.playbackActive() } })
            relauncher.relaunch(updatedAppAt: url)
        } catch {
            installFailure = ((error as? UpdateRejection) ?? UpdateRejection.installLocationNotWritable).code   // the staged update stays ready: nothing was replaced
        }
    }

    private func update(_ change: (inout UpdateState) -> Void) {
        var next = state
        change(&next)
        state = next
        store.save(next)
    }
}
