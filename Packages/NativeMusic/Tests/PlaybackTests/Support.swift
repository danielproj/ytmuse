import Foundation
import Domain
import AccountSession
import Testing
import Synchronization

let testWall = Date(timeIntervalSince1970: 1_000_000)
func sid(_ value: String = "synthetic-media") throws -> ServiceID { try ServiceID(value) }
func account(_ id: UUID = UUID(), channel: String = "synthetic-channel", region: String = "US") throws -> AccountContext {
    try AccountContext(accountID: id, channelID: ID(channel), region: region)
}
func request(_ account: AccountContext? = nil, generation: UInt64 = 1, query: UInt64 = 1) -> RequestContext {
    RequestContext(account: account, accountGeneration: generation, requestGeneration: query)
}
func permission(_ context: AccountContext, _ state: CapabilityState = .supported) throws -> Capability {
    try Capability(state: state, source: "Synthetic W02 test provider", context: context, checkedAt: testWall, expiresAt: testWall.addingTimeInterval(60))
}
func variant() throws -> MediaVariant {
    try MediaVariant(id: sid("synthetic-variant"), codec: "synthetic", container: "synthetic", bitrate: nil, sampleRate: nil, expiresAt: testWall.addingTimeInterval(30), seekable: true, authorization: ID("test-only-reference"))
}
struct FixedWall: WallClock { let date: Date; func now() -> Date { date } }
struct FixedMonotonic: MonotonicClock { var instant: Duration = .zero; func now() -> Duration { instant } }
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9; z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
struct FixtureManifest: Decodable {
    let id: String; let mode: String; let label: String; let provenance: String
    let live_eligible: Bool; let allowed_evidence_layers: [String]; let seeds: [UInt64]
    static func load() throws -> Self {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appending(path: "Fixtures/W02/manifest.json")))
    }
    func require(layer: String) throws(DomainError) {
        guard mode == "synthetic-test-only", !live_eligible, allowed_evidence_layers.contains(layer), layer != "live-service" else { throw .forbidden }
    }
}
actor TestEngine: PlaybackEngine {
    var calls: [String] = []
    var preparationErrors: [DomainError] = []
    func failPreparation(_ errors: [DomainError]) { preparationErrors = errors }
    var holdPreparation = false
    var preparation: CheckedContinuation<Void, Never>?
    var current: PlaybackContext?
    var holdPause = false
    var pauseAcknowledgement: CheckedContinuation<Void, Never>?
    var pauseEntered: CheckedContinuation<Void, Never>?
    var delayedPauseFailure: DomainError?
    func holdNextPause(failure: DomainError? = nil) { holdPause = true; delayedPauseFailure = failure }
    func waitUntilPauseHeld() async {
        if pauseAcknowledgement != nil { return }
        await withCheckedContinuation { pauseEntered = $0 }
    }
    func releasePause() { pauseAcknowledgement?.resume(); pauseAcknowledgement = nil }
    var holdPlay = false
    var playAcknowledgement: CheckedContinuation<Void, Never>?
    var playEntered: CheckedContinuation<Void, Never>?
    var delayedPlayFailure: DomainError?
    func holdNextPlay(failure: DomainError? = nil) { holdPlay = true; delayedPlayFailure = failure }
    func waitUntilPlayHeld() async {
        if playAcknowledgement != nil { return }
        await withCheckedContinuation { playEntered = $0 }
    }
    func releasePlay() { playAcknowledgement?.resume(); playAcknowledgement = nil }
    func hold() { holdPreparation = true }
    func waiting() -> Bool { preparation != nil }
    func release() { preparation?.resume(); preparation = nil }
    func recorded() -> [String] { calls }
    func result(_ name: String, _ context: PlaybackContext) -> PlaybackResult<Void> {
        guard current == nil || current == context || name == "stop" else { return .init(context: context, outcome: .failure(.staleContext)) }
        calls.append(name); return .init(context: context, outcome: .success(()))
    }
    func prepare(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<Void> {
        if holdPreparation { await withCheckedContinuation { preparation = $0 } }
        if !preparationErrors.isEmpty { return .init(context: context, outcome: .failure(preparationErrors.removeFirst())) }
        return result("prepare", context)
    }
    func play(context: PlaybackContext) async -> PlaybackResult<Void> {
        let response = result("play", context)
        if holdPlay {
            holdPlay = false
            let failure = delayedPlayFailure
            await withCheckedContinuation { playAcknowledgement = $0; playEntered?.resume(); playEntered = nil }
            if let failure { return .init(context: context, outcome: .failure(failure)) }
        }
        return response
    }
    func pause(context: PlaybackContext) async -> PlaybackResult<Void> {
        let response = result("pause", context)
        if holdPause {
            holdPause = false
            let failure = delayedPauseFailure
            await withCheckedContinuation { pauseAcknowledgement = $0; pauseEntered?.resume(); pauseEntered = nil }
            if let failure { return .init(context: context, outcome: .failure(failure)) }
        }
        return response
    }
    var seekValidationError: DomainError?
    var seekApplicationError: DomainError?
    var holdSeekPermission = false
    var heldSeekPermission: CheckedContinuation<Void, Never>?
    var seekPermissionEntered: CheckedContinuation<Void, Never>?
    func setSeekErrors(validation: DomainError? = nil, application: DomainError? = nil) { seekValidationError = validation; seekApplicationError = application }
    func holdNextSeekPermission() { holdSeekPermission = true }
    func waitForSeekPermission() async { if heldSeekPermission != nil { return }; await withCheckedContinuation { seekPermissionEntered = $0 } }
    func releaseSeekPermission() { heldSeekPermission?.resume(); heldSeekPermission = nil }
    func validateSeek(context: PlaybackContext) async -> PlaybackResult<Void> {
        if holdSeekPermission {
            holdSeekPermission = false
            await withCheckedContinuation { heldSeekPermission = $0; seekPermissionEntered?.resume(); seekPermissionEntered = nil }
        }
        return .init(context: context, outcome: seekValidationError.map(Result.failure) ?? .success(()))
    }
    func seek(to seconds: Double, context: PlaybackContext) -> PlaybackResult<Void> {
        if let error = seekApplicationError { return .init(context: context, outcome: .failure(error)) }
        return result("seek:\(seconds)", context)
    }
    func stop(context: PlaybackContext) -> PlaybackResult<Void> { current = context; return result("stop", context) }
    func setGain(_ gain: Double, context: PlaybackContext) -> PlaybackResult<Void> { result("gain", context) }
    func setRate(_ rate: Double, context: PlaybackContext) -> PlaybackResult<Void> { result("rate", context) }
    func scheduleNext(_ variant: MediaVariant?, context: PlaybackContext) -> PlaybackResult<Void> { result("schedule", context) }
    func events(context: PlaybackContext) -> PlaybackResult<AsyncStream<ScopedEngineEvent>> { .init(context: context, outcome: .success(AsyncStream { $0.finish() })) }
}
struct TestProvider: CapabilityProvider, PlaybackResolver {
    let account: AccountContext
    var state: CapabilityState = .supported
    func capabilities(context: RequestContext) async -> ServiceResult<AccountCapabilities> {
        .init(context: context, outcome: .success(try! AccountCapabilities(context: account, features: [.playback: permission(account, state), .libraryMutation: permission(account, state), .playlistMutation: permission(account, state)])))
    }
    func resolve(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<[MediaVariant]> { .init(context: context, outcome: .success([try! variant()])) }
    func validateEligibility(_ media: ServiceID, context: PlaybackContext) async -> PlaybackResult<Capability> { .init(context: context, outcome: .success(try! permission(account, state))) }
    func refresh(_ variant: MediaVariant, context: PlaybackContext) async -> PlaybackResult<MediaVariant> { .init(context: context, outcome: .success(variant)) }
    func report(_ event: ServicePlaybackEvent, context: PlaybackContext) async -> PlaybackResult<Void> { .init(context: context, outcome: .success(())) }
}
actor TestLifecycle: PlaybackLifecycleSink {
    var checkpoints = 0; var advances = 0
    func checkpoint(_ snapshot: PlaybackSnapshot) { checkpoints += 1 }
    func advance(context: PlaybackContext) { advances += 1 }
}
func commands(_ context: RequestContext, engine: TestEngine, state: CapabilityState = .supported) throws -> PlaybackCommands {
    let provider = TestProvider(account: try #require(context.account), state: state)
    return PlaybackCommands(request: context, engine: engine, resolver: provider, capabilities: provider, wall: FixedWall(date: testWall), monotonic: FixedMonotonic(), lifecycle: TestLifecycle())
}

func seededUUID(_ generator: inout SeededGenerator) -> UUID {
    let digits = String(format: "%016llx%016llx", generator.next(), generator.next())
    let text = Array(digits)
    let formatted = [String(text[0..<8]), String(text[8..<12]), String(text[12..<16]), String(text[16..<20]), String(text[20..<32])].joined(separator: "-")
    return UUID(uuidString: formatted)!
}

final class ManualMonotonic: MonotonicClock {
    private let instant = Mutex<Duration>(.zero)
    func now() -> Duration { instant.withLock { $0 } }
    func advance(to value: Duration) { instant.withLock { precondition(value >= $0); $0 = value } }
}

/// C1: every test that starts owned audio must give the owner an isolated vault. Without
/// one `AppPlaybackAuthority` falls through to `KeychainVault()`, the production
/// `local.native-music.development.sessions` Keychain item, which on a fresh machine it
/// would create. The keychain file lives inside `directory`, so removing that scratch
/// directory removes the vault; nothing is searched in the login Keychain.
func isolatedOwnedVault(in directory: URL) throws -> KeychainVault {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return try KeychainVault(testNamespace: KeychainVault.applicationNamespace + ".test.playback-" + UUID().uuidString.lowercased(),
                             isolatedKeychainURL: directory.appendingPathComponent("isolated-" + UUID().uuidString + ".keychain-db"))
}
