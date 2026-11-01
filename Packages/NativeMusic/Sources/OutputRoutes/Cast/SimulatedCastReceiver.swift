#if DEBUG
import Foundation
import Synchronization

// W39. A scripted Cast receiver that speaks the real protocol (it parses and answers the same JSON the sender writes) behind the `CastChannel` seam.
// Tests drive the real `CastSession` against it, and an isolated app launch uses it as the one "receiver" it lists, so no automated run opens a socket
// to a device. It exists only in Debug builds. Time on the receiver moves only when the test moves it (`advance`), unless `autoAdvance` is set for a
// launch that a person (or a UI test) watches.

fileprivate struct SimState {
    var options: SimulatedCastReceiver.Options
    var channels: [SimChannel] = []
    var appSession: String?; var transport: String?; var launches = 0
    var mediaSession = 0; var contentID: String?; var duration: Double?
    var playerState = "IDLE"; var position = 0.0
    var volume = 1.0; var muted = false
    var received: [CastMessage] = []
    var failNextLoad: String?; var heldLoadReply = false
    var onLoad: (@Sendable (String) -> Void)?
    var openCount = 0; var refuseOpen = false
    var holding = false; var held: [(SimChannel, CastMessage)] = []
}

public final class SimulatedCastReceiver: CastChannelFactory, @unchecked Sendable {
    public struct Options: Sendable {
        public var supportedMediaCommands = 15
        public var answersPings = true
        public var autoAdvance = false
        public var localAddress: String? = "127.0.0.1"
        public var remoteAddress: String? = "127.0.0.1"
        public init() {}
    }
    private let state: Mutex<SimState>
    public init(options: Options = Options()) { state = Mutex(SimState(options: options)) }

    // MARK: Factory
    public func open(_ device: CastDevice) async throws -> any CastChannel {
        let refuse = state.withLock { $0.openCount += 1; return $0.refuseOpen }
        if refuse { throw CastError.closed }
        let channel = SimChannel(owner: self)
        state.withLock { $0.channels.append(channel) }
        return channel
    }

    // MARK: Test controls
    public var received: [CastMessage] { state.withLock { $0.received } }
    public func receivedTypes() -> [String] { received.compactMap { ($0.text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any])?["type"] as? String } }
    public var openCount: Int { state.withLock { $0.openCount } }
    public var playerState: String { state.withLock { $0.playerState } }
    public var position: Double { state.withLock { $0.position } }
    public var contentID: String? { state.withLock { $0.contentID } }
    public var hasApplication: Bool { state.withLock { $0.appSession != nil } }
    public var currentMediaSessionID: Int { state.withLock { $0.mediaSession } }
    /// Replies are queued instead of delivered until `releaseReplies()` (in order), to reproduce a report that arrives after a newer command was sent.
    public func holdReplies() { state.withLock { $0.holding = true } }
    public func releaseReplies() {
        let queued = state.withLock { state -> [(SimChannel, CastMessage)] in state.holding = false; defer { state.held = [] }; return state.held }
        for (channel, message) in queued { channel.deliverNow(message) }
    }
    public func refuseConnections(_ value: Bool) { state.withLock { $0.refuseOpen = value } }
    public func setAnswersPings(_ value: Bool) { state.withLock { $0.options.answersPings = value } }
    public func setOnLoad(_ handler: (@Sendable (String) -> Void)?) { state.withLock { $0.onLoad = handler } }
    public func failNextLoad(_ type: String = "LOAD_FAILED") { state.withLock { $0.failNextLoad = type } }
    /// The next LOAD is accepted but its reply is held until `releaseLoadReply()`.
    public func holdLoadReply() { state.withLock { $0.heldLoadReply = true } }
    public func releaseLoadReply() {
        let reply = state.withLock { state -> (SimChannel?, CastMessage?) in state.heldLoadReply = false; return (state.channels.last, mediaStatus(&state, requestID: nil)) }
        if let channel = reply.0, let message = reply.1 { channel.deliver(message) }
    }
    /// The receiver's own clock moves (only when playing).
    public func advance(_ seconds: Double) {
        let message = state.withLock { state -> (SimChannel?, CastMessage?) in
            if state.playerState == "PLAYING" { state.position += seconds; if let duration = state.duration, state.position >= duration { state.position = duration } }
            return (state.channels.last, mediaStatus(&state, requestID: nil))
        }
        if let channel = message.0, let reply = message.1 { channel.deliver(reply) }
    }
    /// The item played to its end.
    public func finishCurrent() {
        let pair = state.withLock { state -> (SimChannel?, CastMessage?) in
            state.playerState = "IDLE"
            return (state.channels.last, mediaStatus(&state, requestID: nil, idleReason: "FINISHED"))
        }
        if let channel = pair.0, let reply = pair.1 { channel.deliver(reply) }
    }
    /// Another sender (a phone) loads other media on the same receiver.
    public func takeOver(contentID: String) {
        let pair = state.withLock { state -> (SimChannel?, CastMessage?) in
            state.mediaSession += 1; state.contentID = contentID; state.playerState = "PLAYING"; state.position = 0
            return (state.channels.last, mediaStatus(&state, requestID: nil))
        }
        if let channel = pair.0, let reply = pair.1 { channel.deliver(reply) }
    }
    /// Someone ends the receiver application from another app.
    public func endApplicationExternally() {
        let pair = state.withLock { state -> (SimChannel?, CastMessage?) in
            state.appSession = nil; state.transport = nil; state.playerState = "IDLE"
            return (state.channels.last, receiverStatus(&state, requestID: nil))
        }
        if let channel = pair.0, let reply = pair.1 { channel.deliver(reply) }
    }
    /// The connection drops (cable, Wi-Fi, reboot).
    public func dropConnection() { let channels = state.withLock { $0.channels }; for channel in channels { channel.finish("connection dropped") } }
    /// Delivers a hand-written message exactly as a (late) receiver would.
    public func inject(namespace: String, from source: String = "receiver-0", json: String) {
        let channel = state.withLock { $0.channels.last }
        channel?.deliver(CastMessage(sourceID: source, destinationID: CastIdentity.senderID, namespace: namespace, json: json))
    }
    public func injectMediaStatus(mediaSessionID: Int, state playerState: String, contentID: String?, position: Double, idleReason: String? = nil) {
        var entry: [String: Any] = ["mediaSessionId": mediaSessionID, "playerState": playerState, "currentTime": position, "supportedMediaCommands": 15]
        if let contentID { entry["media"] = ["contentId": contentID, "duration": 200.0] }
        if let idleReason { entry["idleReason"] = idleReason }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: ["type": "MEDIA_STATUS", "requestId": 0, "status": [entry]])) ?? Data(), as: UTF8.self)
        inject(namespace: CastNamespace.media, json: json)
    }

    fileprivate func queueIfHolding(_ channel: SimChannel, _ message: CastMessage) -> Bool {
        state.withLock { state in if state.holding { state.held.append((channel, message)); return true }; return false }
    }
    // MARK: Receiver behaviour
    fileprivate func handle(_ message: CastMessage, from channel: SimChannel) {
        guard let object = message.text.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any], let type = object["type"] as? String else { return }
        let request = (object["requestId"] as? NSNumber)?.intValue
        var replies: [CastMessage] = []
        var loaded: String?
        var handler: (@Sendable (String) -> Void)?
        var answers = true
        state.withLock { state in
            state.received.append(message)
            answers = state.options.answersPings
            switch (message.namespace, type) {
            case (CastNamespace.heartbeat, "PING"): if state.options.answersPings { replies.append(CastMessage(sourceID: "receiver-0", destinationID: CastIdentity.senderID, namespace: CastNamespace.heartbeat, json: "{\"type\":\"PONG\"}")) }
            case (CastNamespace.receiver, "GET_STATUS"): if let reply = receiverStatus(&state, requestID: request) { replies.append(reply) }
            case (CastNamespace.receiver, "LAUNCH"):
                state.launches += 1
                state.appSession = "sim-session-\(state.launches)"; state.transport = "sim-transport-\(state.launches)"; state.mediaSession = 0; state.contentID = nil; state.playerState = "IDLE"
                if let reply = receiverStatus(&state, requestID: request) { replies.append(reply) }
            case (CastNamespace.receiver, "STOP"):
                state.appSession = nil; state.transport = nil; state.playerState = "IDLE"
                if let reply = receiverStatus(&state, requestID: request) { replies.append(reply) }
            case (CastNamespace.receiver, "SET_VOLUME"):
                if let volume = object["volume"] as? [String: Any] { if let level = (volume["level"] as? NSNumber)?.doubleValue { state.volume = level }; if let muted = volume["muted"] as? Bool { state.muted = muted } }
                if let reply = receiverStatus(&state, requestID: request) { replies.append(reply) }
            case (CastNamespace.media, "LOAD"):
                guard state.appSession != nil, message.destinationID == state.transport, let media = object["media"] as? [String: Any], let url = media["contentId"] as? String else {
                    replies.append(failure("INVALID_REQUEST", request)); break
                }
                if let fail = state.failNextLoad { state.failNextLoad = nil; replies.append(failure(fail, request)); break }
                state.mediaSession += 1; state.contentID = url; state.duration = (media["duration"] as? NSNumber)?.doubleValue
                state.position = (object["currentTime"] as? NSNumber)?.doubleValue ?? 0
                state.playerState = (object["autoplay"] as? Bool ?? true) ? "PLAYING" : "PAUSED"
                loaded = url; handler = state.onLoad
                if !state.heldLoadReply, let reply = mediaStatus(&state, requestID: request) { replies.append(reply) }
            case (CastNamespace.media, "PLAY"): if (object["mediaSessionId"] as? NSNumber)?.intValue == state.mediaSession && state.mediaSession > 0 { state.playerState = "PLAYING"; if let reply = mediaStatus(&state, requestID: request) { replies.append(reply) } }
            case (CastNamespace.media, "PAUSE"): if (object["mediaSessionId"] as? NSNumber)?.intValue == state.mediaSession && state.mediaSession > 0 { state.playerState = "PAUSED"; if let reply = mediaStatus(&state, requestID: request) { replies.append(reply) } }
            case (CastNamespace.media, "SEEK"):
                if (object["mediaSessionId"] as? NSNumber)?.intValue == state.mediaSession && state.mediaSession > 0, let time = (object["currentTime"] as? NSNumber)?.doubleValue { state.position = time; if let reply = mediaStatus(&state, requestID: request) { replies.append(reply) } }
            case (CastNamespace.media, "STOP"):
                if (object["mediaSessionId"] as? NSNumber)?.intValue == state.mediaSession && state.mediaSession > 0 { state.playerState = "IDLE"; if let reply = mediaStatus(&state, requestID: request, idleReason: "CANCELLED") { replies.append(reply) } }
            case (CastNamespace.media, "GET_STATUS"): if let reply = mediaStatus(&state, requestID: request) { replies.append(reply) }
            default: break
            }
        }
        _ = answers
        // The receiver "fetches" the media first, then answers: the sender never sees an acknowledgement of media the receiver has not got.
        if let loaded, let handler { handler(loaded) }
        for reply in replies { channel.deliver(reply) }
    }
}


fileprivate func receiverStatus(_ state: inout SimState, requestID: Int?) -> CastMessage? {
    var status: [String: Any] = ["volume": ["level": state.volume, "muted": state.muted, "controlType": "attenuation"], "isActiveInput": false]
    if let session = state.appSession, let transport = state.transport {
        status["applications"] = [["appId": CastIdentity.defaultMediaReceiverAppID, "displayName": "Default Media Receiver", "sessionId": session, "transportId": transport,
                                   "namespaces": [["name": CastNamespace.media], ["name": CastNamespace.connection]], "statusText": "Ready"]]
    }
    var object: [String: Any] = ["type": "RECEIVER_STATUS", "status": status]
    if let requestID { object["requestId"] = requestID }
    return CastMessage(sourceID: "receiver-0", destinationID: CastIdentity.senderID, namespace: CastNamespace.receiver, json: String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self))
}
fileprivate func mediaStatus(_ state: inout SimState, requestID: Int?, idleReason: String? = nil) -> CastMessage? {
    guard state.mediaSession > 0, let contentID = state.contentID, let transport = state.transport else { return nil }
    var media: [String: Any] = ["contentId": contentID, "contentType": "audio/wav", "streamType": "BUFFERED"]
    if let duration = state.duration { media["duration"] = duration }
    var entry: [String: Any] = ["mediaSessionId": state.mediaSession, "playerState": state.playerState, "currentTime": state.position, "playbackRate": 1,
                                "supportedMediaCommands": state.options.supportedMediaCommands, "media": media, "volume": ["level": state.volume, "muted": state.muted]]
    if let idleReason { entry["idleReason"] = idleReason }
    var object: [String: Any] = ["type": "MEDIA_STATUS", "status": [entry]]
    if let requestID { object["requestId"] = requestID }
    return CastMessage(sourceID: transport, destinationID: CastIdentity.senderID, namespace: CastNamespace.media, json: String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self))
}

private func failure(_ type: String, _ request: Int?) -> CastMessage {
    var object: [String: Any] = ["type": type, "reason": "SIMULATED"]
    if let request { object["requestId"] = request }
    return CastMessage(sourceID: "sim-transport", destinationID: CastIdentity.senderID, namespace: CastNamespace.media, json: String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self))
}

private final class SimChannel: CastChannel, @unchecked Sendable {
    let events: AsyncStream<CastChannelEvent>
    private let continuation: AsyncStream<CastChannelEvent>.Continuation
    private weak var owner: SimulatedCastReceiver?
    private let closed = Mutex(false)
    init(owner: SimulatedCastReceiver) {
        self.owner = owner
        (events, continuation) = AsyncStream.makeStream(of: CastChannelEvent.self, bufferingPolicy: .unbounded)
    }
    var localAddress: String? { "127.0.0.1" }
    var remoteAddress: String? { "127.0.0.1" }
    func send(_ message: CastMessage) async throws {
        guard !closed.withLock({ $0 }) else { throw CastError.closed }
        owner?.handle(message, from: self)
    }
    func deliver(_ message: CastMessage) {
        if owner?.queueIfHolding(self, message) == true { return }
        deliverNow(message)
    }
    func deliverNow(_ message: CastMessage) { if !closed.withLock({ $0 }) { continuation.yield(.message(message)) } }
    func finish(_ reason: String?) { closed.withLock { $0 = true }; continuation.yield(.closed(reason)); continuation.finish() }
    func close() { closed.withLock { $0 = true }; continuation.finish() }
}
#endif
