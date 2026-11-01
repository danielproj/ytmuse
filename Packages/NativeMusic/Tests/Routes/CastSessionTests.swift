import Foundation
import Testing
@testable import OutputRoutes

@MainActor final class FakeClock {
    private(set) var now = ContinuousClock.now
    func advance(_ seconds: Double) { now = now.advanced(by: .seconds(seconds)) }
}

/// T39.2: the sender session against the simulated receiver, which speaks the real protocol. Position, state and capabilities are what the receiver reports.
@MainActor final class SessionHarness {
    let receiver: SimulatedCastReceiver
    let session: CastSession
    private(set) var events: [CastSessionEvent] = []
    let clock = FakeClock()
    init(options: SimulatedCastReceiver.Options = .init(), configuration: CastSessionConfiguration? = nil, device: CastDevice = CastFixtures.livingRoom) {
        receiver = SimulatedCastReceiver(options: options)
        var configuration = configuration ?? CastSessionConfiguration()
        configuration.runsHeartbeat = false
        let clock = clock
        session = CastSession(device: device, factory: receiver, configuration: configuration, now: { clock.now })
        session.onEvent = { [unowned self] in events.append($0) }
    }
    func advanceClock(_ seconds: Double) { clock.advance(seconds) }
    static func ready() async throws -> SessionHarness { let harness = SessionHarness(); try await harness.session.connect(); return harness }
    func load(_ url: String = "http://127.0.0.1:1/c/T/x.wav", autoplay: Bool = true, at: Double = 0) async throws -> UInt64 {
        try await session.load(CastMessages.Load(url: url, contentType: "audio/wav", title: "t", artist: nil, duration: 100, startAt: at, autoplay: autoplay))
    }
    var reports: [CastMediaReport] { events.compactMap { if case .media(let report) = $0 { report } else { nil } } }
    func has(_ event: CastSessionEvent) -> Bool { events.contains(event) }
    var lost: CastLossCause? { events.compactMap { if case .lost(let cause) = $0 { cause } else { nil } }.first }
}

@Suite @MainActor struct CastSessionTests {
    @Test func connectingFollowsTheProtocolOrderAndEndsReady() async throws {
        let h = try await SessionHarness.ready()
        #expect(h.session.phase == .ready && h.has(.ready))
        let types = h.receiver.receivedTypes()
        #expect(types == ["CONNECT", "LAUNCH", "CONNECT"], "connect to the platform, launch the Default Media Receiver, connect to its transport: \(types)")
        let destinations = h.receiver.received.map(\.destinationID)
        #expect(destinations == ["receiver-0", "receiver-0", "sim-transport-1"])
        #expect(h.receiver.hasApplication)
    }
    @Test func theReceiverIsLaunchedWithTheDefaultMediaReceiverApplication() async throws {
        let h = try await SessionHarness.ready()
        let launch = try #require(h.receiver.received.first { $0.text?.contains("LAUNCH") == true })
        #expect(launch.text?.contains("\"appId\":\"CC1AD845\"") == true)
    }
    @Test func aRefusedConnectionFailsAndLeavesTheSessionClosed() async {
        let h = SessionHarness()
        h.receiver.refuseConnections(true)
        await #expect(throws: CastError.self) { try await h.session.connect() }
        #expect(h.session.phase == .closed && !h.events.contains { if case .lost = $0 { true } else { false } }, "a route that never existed is not a loss")
    }
    @Test func aLaunchTheReceiverDoesNotAnswerTimesOut() async {
        var configuration = CastSessionConfiguration(); configuration.launchTimeout = .milliseconds(150)
        // A receiver that opens and then says nothing at all.
        let session = CastSession(device: CastFixtures.livingRoom, factory: SlowFactory(), configuration: configuration)
        await #expect(throws: CastError.timedOut) { try await session.connect() }
        #expect(session.phase == .closed)
    }
    @Test func loadingReportsTheReceiversStateAndPositionNotALocalGuess() async throws {
        let h = try await SessionHarness.ready()
        let generation = try await h.load(at: 31)
        #expect(generation == 1)
        let first = try #require(h.reports.last)
        #expect(first.state == .playing && first.position == 31 && first.generation == 1 && first.duration != nil)
        h.receiver.advance(7)
        #expect(await waitUntil { h.reports.last?.position == 38 })
        // Time passing on the Mac changes nothing the session reports: no report was produced without the receiver sending one.
        let count = h.reports.count
        try await Task.sleep(for: .milliseconds(120))
        #expect(h.reports.count == count)
    }
    @Test func capabilitiesAreTheOnesTheReceiverStates() async throws {
        var options = SimulatedCastReceiver.Options(); options.supportedMediaCommands = 1   // pause only
        let h = SessionHarness(options: options); try await h.session.connect()
        _ = try await h.load()
        #expect(h.reports.last?.capabilities == CastReceiverCapabilities(canPause: true, canSeek: false, canSetStreamVolume: false, canMute: false))
        #expect(h.session.capabilities?.canSeek == false)
    }
    @Test func commandsReachTheReceiverAndItsNextStatusIsTheAnswer() async throws {
        let h = try await SessionHarness.ready()
        _ = try await h.load(at: 10)
        try await h.session.pause()
        #expect(await waitUntil { h.reports.last?.state == .paused })
        #expect(h.receiver.playerState == "PAUSED")
        try await h.session.seek(to: 55)
        #expect(await waitUntil { h.reports.last?.position == 55 })
        try await h.session.play()
        #expect(await waitUntil { h.reports.last?.state == .playing })
        try await h.session.setVolume(level: 0.25)
        #expect(await waitUntil { h.events.contains { if case .volume(let level, _) = $0 { level == 0.25 } else { false } } })
    }
    @Test func commandsBeforeALoadOrBeforeConnectingAreRefusedLocally() async throws {
        let idle = CastSession(device: CastFixtures.livingRoom, factory: SimulatedCastReceiver())
        await #expect(throws: CastError.notConnected) { try await idle.play() }
        let h = try await SessionHarness.ready()
        await #expect(throws: CastError.noMedia) { try await h.session.pause() }
        await #expect(throws: CastError.commandRefused("position")) { try await h.session.seek(to: -1) }
        await #expect(throws: CastError.commandRefused("position")) { try await h.session.seek(to: .nan) }
    }
    @Test func aLoadTheReceiverRefusesThrowsAndLeavesNoMedia() async throws {
        let h = try await SessionHarness.ready()
        h.receiver.failNextLoad("LOAD_FAILED")
        await #expect(throws: CastError.loadFailed("SIMULATED")) { _ = try await h.load() }
        await #expect(throws: CastError.noMedia) { try await h.session.play() }
        _ = try await h.load("http://127.0.0.1:1/c/T/y.wav")   // a later load works
    }
    @Test func aLoadThatIsNeverAcknowledgedTimesOut() async throws {
        var configuration = CastSessionConfiguration(); configuration.requestTimeout = .milliseconds(150)
        let h = SessionHarness(configuration: configuration); try await h.session.connect()
        h.receiver.holdLoadReply()
        await #expect(throws: CastError.timedOut) { _ = try await h.load() }
    }

    // MARK: Delayed and stale events (ROUTE08, DATA03)

    @Test func aLateStatusOfAnEarlierItemCannotMoveTheCurrentOne() async throws {
        let h = try await SessionHarness.ready()
        _ = try await h.load("http://127.0.0.1:1/c/T/a.wav", at: 5)
        let firstID = h.receiver.currentMediaSessionID
        _ = try await h.load("http://127.0.0.1:1/c/T/b.wav", at: 90)
        let secondID = h.receiver.currentMediaSessionID
        #expect(firstID != secondID && h.session.loadGeneration == 2)
        let before = h.reports.count, ignored = h.session.ignoredStale
        // The receiver's delayed report about item A (position 6 s, playing) arrives AFTER item B was loaded.
        h.receiver.injectMediaStatus(mediaSessionID: firstID, state: "PLAYING", contentID: "http://127.0.0.1:1/c/T/a.wav", position: 6)
        // ...and so does its eventual IDLE/INTERRUPTED, which must not read as the receiver being taken over.
        h.receiver.injectMediaStatus(mediaSessionID: firstID, state: "IDLE", contentID: "http://127.0.0.1:1/c/T/a.wav", position: 6, idleReason: "INTERRUPTED")
        #expect(await waitUntil { h.session.ignoredStale == ignored + 2 })
        #expect(h.reports.count == before, "nothing about item A reached the observer")
        #expect(h.lost == nil && h.reports.last?.position == 90 && h.reports.last?.generation == 2)
    }
    @Test func aStatusForMediaWeNeverLoadedDoesNotEstablishTheSession() async throws {
        let h = try await SessionHarness.ready()
        h.receiver.holdLoadReply()
        async let pending: UInt64? = try? await h.load("http://127.0.0.1:1/c/T/mine.wav")
        #expect(await waitUntil { h.receiver.receivedTypes().contains("LOAD") })
        h.receiver.injectMediaStatus(mediaSessionID: 77, state: "PLAYING", contentID: "http://elsewhere.example/other.mp3", position: 1)
        #expect(await waitUntil { h.session.ignoredStale >= 1 } || h.lost == .takenOver)
        h.receiver.releaseLoadReply()
        #expect(await pending == 1)
    }
    @Test func aSecondLoadWhileTheFirstIsPendingSupersedesIt() async throws {
        let h = try await SessionHarness.ready()
        h.receiver.holdLoadReply()
        async let first: UInt64? = try? await h.load("http://127.0.0.1:1/c/T/a.wav")
        #expect(await waitUntil { h.receiver.receivedTypes().filter { $0 == "LOAD" }.count == 1 })
        async let second: UInt64? = try? await h.load("http://127.0.0.1:1/c/T/b.wav")
        #expect(await waitUntil { h.session.loadGeneration == 2 })
        // The receiver acknowledges the SECOND item, then the first one's late acknowledgement shows up.
        h.receiver.takeOver(contentID: "http://127.0.0.1:1/c/T/b.wav")
        #expect(await second == 2)
        #expect(await first == nil, "the first load was overtaken and reports no success")
    }
    @Test func theReceiverFinishingTheItemIsReportedForTheCurrentGenerationOnly() async throws {
        let h = try await SessionHarness.ready()
        _ = try await h.load()
        h.receiver.finishCurrent()
        #expect(await waitUntil { h.has(.finished(generation: 1)) })
        await #expect(throws: CastError.noMedia) { try await h.session.play() }
    }

    // MARK: Loss (ROUTE03, ROUTE09)

    @Test func aDroppedConnectionIsALoss() async throws {
        let h = try await SessionHarness.ready()
        _ = try await h.load()
        h.receiver.dropConnection()
        #expect(await waitUntil { h.lost == .connectionLost })
        #expect(h.session.phase == .closed)
        await #expect(throws: CastError.notConnected) { try await h.session.play() }
    }
    @Test func aReceiverThatStopsAnsweringIsLostWhenTheHeartbeatTimesOut() async throws {
        let h = try await SessionHarness.ready()
        h.receiver.setAnswersPings(false)
        await h.session.heartbeatTick()
        #expect(h.receiver.receivedTypes().contains("PING") && h.lost == nil, "a ping went out and the receiver is still within its allowance")
        h.advanceClock(14); await h.session.heartbeatTick()
        #expect(h.lost == nil, "14 s of silence is inside the 15 s allowance")
        h.advanceClock(2); await h.session.heartbeatTick()
        #expect(h.lost == .heartbeatTimeout && h.session.phase == .closed)
    }
    @Test func anyMessageFromTheReceiverCountsAsLife() async throws {
        let h = try await SessionHarness.ready()
        h.advanceClock(14)
        h.receiver.inject(namespace: CastNamespace.heartbeat, json: #"{"type":"PONG"}"#)
        #expect(await waitUntil { h.session.phase == .ready })
        h.advanceClock(14); await h.session.heartbeatTick()
        #expect(h.lost == nil, "the PONG renewed the allowance")
    }
    @Test func aPingFromTheReceiverIsAnsweredWithAPong() async throws {
        let h = try await SessionHarness.ready()
        h.receiver.inject(namespace: CastNamespace.heartbeat, json: #"{"type":"PING"}"#)
        #expect(await waitUntil { h.receiver.receivedTypes().contains("PONG") })
    }
    @Test func theApplicationBeingEndedElsewhereIsALoss() async throws {
        let h = try await SessionHarness.ready()
        _ = try await h.load()
        h.receiver.endApplicationExternally()
        #expect(await waitUntil { h.lost == .receiverClosed })
    }
    @Test func anotherSenderLoadingOtherMediaIsALossNotAnUpdate() async throws {
        let h = try await SessionHarness.ready()
        _ = try await h.load("http://127.0.0.1:1/c/T/mine.wav")
        h.receiver.takeOver(contentID: "http://phone.example/theirs.mp3")
        #expect(await waitUntil { h.lost == .takenOver })
    }
    @Test(arguments: ["CANCELLED", "INTERRUPTED"]) func theReceiverCancellingOrInterruptingOurOwnMediaIsALoss(reason: String) async throws {
        // Stop pressed in another app: the receiver reports our item idle with CANCELLED or INTERRUPTED. The Mac must not stay "casting".
        let h = try await SessionHarness.ready()
        _ = try await h.load("http://127.0.0.1:1/c/T/mine.wav")
        h.receiver.injectMediaStatus(mediaSessionID: h.receiver.currentMediaSessionID, state: "IDLE", contentID: "http://127.0.0.1:1/c/T/mine.wav", position: 3, idleReason: reason)
        #expect(await waitUntil { h.lost == .takenOver })
        #expect(h.session.phase == .closed)
    }
    @Test func theReceiverClosingOurConnectionIsALoss() async throws {
        let h = try await SessionHarness.ready()
        h.receiver.inject(namespace: CastNamespace.connection, from: "sim-transport-1", json: #"{"type":"CLOSE"}"#)
        #expect(await waitUntil { h.lost == .receiverClosed })
    }

    // MARK: Ending (ROUTE10)

    @Test func stoppingSendsStopThenClosesBothConnections() async throws {
        let h = try await SessionHarness.ready()
        _ = try await h.load()
        await h.session.shutdown(.stopReceiver)
        #expect(h.receiver.receivedTypes().suffix(3) == ["STOP", "CLOSE", "CLOSE"], Comment(rawValue: "\(h.receiver.receivedTypes())"))
        #expect(!h.receiver.hasApplication && h.session.phase == .closed)
    }
    @Test func leavingClosesTheConnectionsAndDoesNotStopTheApplication() async throws {
        let h = try await SessionHarness.ready()
        _ = try await h.load()
        await h.session.shutdown(.leave)
        #expect(!h.receiver.receivedTypes().contains("STOP") && h.receiver.receivedTypes().suffix(2) == ["CLOSE", "CLOSE"])
        #expect(h.receiver.hasApplication)
    }

    // MARK: The receiver gets no account material (ROUTE06)

    @Test func nothingSentToTheReceiverCarriesCookiesTokensOrAccountData() async throws {
        let h = try await SessionHarness.ready()
        _ = try await h.load("http://127.0.0.1:5000/c/RANDOMTOKEN/tag.wav")
        try await h.session.pause(); try await h.session.seek(to: 3); try await h.session.play(); try await h.session.setVolume(level: 0.5)
        await h.session.shutdown(.stopReceiver)
        let wire = h.receiver.received.map { "\($0.namespace) \($0.text ?? "")" }.joined(separator: "\n").lowercased()
        for forbidden in ["cookie", "sapisid", "authorization", "bearer", "refresh_token", "access_token", "ya29.", "youtube", "google.com", "set-cookie", "oauth"] {
            #expect(!wire.contains(forbidden), "the receiver was sent \(forbidden)")
        }
        #expect(wire.contains("cc1ad845"), "the only third-party identifier is the Default Media Receiver's own application id")
    }
}

/// A factory whose receiver never answers (opening works, nothing comes back).
struct SlowFactory: CastChannelFactory {
    func open(_ device: CastDevice) async throws -> any CastChannel { SilentChannel() }
}
final class SilentChannel: CastChannel, @unchecked Sendable {
    let events: AsyncStream<CastChannelEvent>
    private let continuation: AsyncStream<CastChannelEvent>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream(of: CastChannelEvent.self) }
    var localAddress: String? { "127.0.0.1" }
    var remoteAddress: String? { "127.0.0.1" }
    func send(_ message: CastMessage) async throws {}
    func close() { continuation.finish() }
}


/// S4: LAUNCH adopts only the Default Media Receiver. A receiver status that lists some other application must never be taken as ours.
final class LaunchScriptChannel: CastChannel, @unchecked Sendable {
    let events: AsyncStream<CastChannelEvent>
    private let continuation: AsyncStream<CastChannelEvent>.Continuation
    private let applications: String
    private let log = NSLock(); private var seen: [String] = []
    init(applications: String) { self.applications = applications; (events, continuation) = AsyncStream.makeStream(of: CastChannelEvent.self) }
    var localAddress: String? { "127.0.0.1" }
    var remoteAddress: String? { "127.0.0.1" }
    var destinations: [String] { log.withLock { seen } }
    func send(_ message: CastMessage) async throws {
        log.withLock { seen.append(message.destinationID + " " + (message.text ?? "")) }
        if message.text?.contains("\"LAUNCH\"") == true {
            continuation.yield(.message(CastMessage(sourceID: "receiver-0", destinationID: "sender-0", namespace: CastNamespace.receiver,
                json: #"{"type":"RECEIVER_STATUS","status":{"applications":\#(applications)}}"#)))
        }
    }
    func close() { continuation.finish() }
}
struct LaunchScriptFactory: CastChannelFactory {
    let channel: LaunchScriptChannel
    func open(_ device: CastDevice) async throws -> any CastChannel { channel }
}
@Suite @MainActor struct CastLaunchAdoptionTests {
    static let other = #"{"appId":"233637DE","sessionId":"OTHER-S","transportId":"OTHER-T","displayName":"Another app","namespaces":[{"name":"urn:x-cast:com.google.cast.media"}]}"#
    static let defaultReceiver = #"{"appId":"CC1AD845","sessionId":"DMR-S","transportId":"DMR-T","displayName":"Default Media Receiver","namespaces":[{"name":"urn:x-cast:com.google.cast.media"}]}"#
    @Test func onlyTheDefaultMediaReceiverIsAdoptedEvenWhenAnotherApplicationIsListedFirst() async throws {
        let channel = LaunchScriptChannel(applications: "[\(Self.other),\(Self.defaultReceiver)]")
        let session = CastSession(device: CastFixtures.livingRoom, factory: LaunchScriptFactory(channel: channel), configuration: { var c = CastSessionConfiguration(); c.runsHeartbeat = false; return c }())
        try await session.connect()
        #expect(session.phase == .ready)
        let connects = channel.destinations.filter { $0.contains("CONNECT") }
        #expect(connects.last?.hasPrefix("DMR-T ") == true && !channel.destinations.contains { $0.hasPrefix("OTHER-T ") }, "the transport connected to is the Default Media Receiver's: \(channel.destinations.map { String($0.prefix(20)) })")
    }
    @Test func aReceiverThatOffersOnlyAnotherApplicationIsNeverAdoptedAndTheLaunchFails() async throws {
        let channel = LaunchScriptChannel(applications: "[\(Self.other)]")
        var configuration = CastSessionConfiguration(); configuration.runsHeartbeat = false; configuration.launchTimeout = .milliseconds(200)
        let session = CastSession(device: CastFixtures.livingRoom, factory: LaunchScriptFactory(channel: channel), configuration: configuration)
        await #expect(throws: CastError.timedOut) { try await session.connect() }
        #expect(!channel.destinations.contains { $0.hasPrefix("OTHER-T ") }, "nothing was sent to the other application")
    }
}
