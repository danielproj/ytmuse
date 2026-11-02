import Domain
import Foundation

// W39 (ROUTE05, ROUTE09). The JSON messages of the four Cast namespaces this sender uses, and what a receiver's replies are read as. Builders produce a
// payload string; parsers take only what the receiver REPORTED, so a position, a state or a capability always comes from the receiver and never from a
// guess. No network in this file.

public enum CastNamespace {
    public static let connection = "urn:x-cast:com.google.cast.tp.connection"
    public static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    public static let receiver = "urn:x-cast:com.google.cast.receiver"
    public static let media = "urn:x-cast:com.google.cast.media"
}

public enum CastIdentity {
    /// The Default Media Receiver: Google's own receiver application, which plays a URL the receiver can fetch. No registration, no account.
    public static let defaultMediaReceiverAppID = "CC1AD845"
    public static let senderID = "sender-0"
    public static let platformReceiverID = "receiver-0"
    public static let userAgent = "YTMuse"
}

/// A receiver found on the network, as its DNS-SD record describes it. The identifier is the device's own (the `id` TXT key), so two receivers with one
/// friendly name are two devices (ROUTE02).
public struct CastDeviceID: Hashable, Sendable, Codable {
    public let rawValue: String
    public init?(_ value: String) {
        guard (1...64).contains(value.utf8.count), value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 }) else { return nil }
        rawValue = value
    }
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = CastDeviceID(text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown cast device identifier")) }
        self = value
    }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

public struct CastDevice: Equatable, Sendable, Identifiable {
    public let id: CastDeviceID
    public let friendlyName: String
    public let model: String?
    /// The `ca` capability bit field of the DNS-SD record (video out = 1, video in = 2, audio out = 4, audio in = 8, dev mode = 16, group = 32).
    public let capabilityBits: UInt32?
    public init(id: CastDeviceID, friendlyName: String, model: String? = nil, capabilityBits: UInt32? = nil) {
        self.id = id; self.friendlyName = friendlyName; self.model = model; self.capabilityBits = capabilityBits
    }
    /// A record that states its capabilities and has no audio output cannot play music; one that does not say is assumed able (the record is advisory).
    public var playsAudio: Bool { capabilityBits.map { $0 & 4 != 0 } ?? true }
    public var isGroup: Bool { capabilityBits.map { $0 & 32 != 0 } ?? false }
    public var routeID: OutputRouteID { .cast(id: id) }
}

/// What a receiver says it can do with the media it is playing (`supportedMediaCommands`). Shown as reported; never assumed.
public struct CastReceiverCapabilities: Equatable, Sendable {
    public let canPause: Bool, canSeek: Bool, canSetStreamVolume: Bool, canMute: Bool
    public init(bits: Int) { canPause = bits & 1 != 0; canSeek = bits & 2 != 0; canSetStreamVolume = bits & 4 != 0; canMute = bits & 8 != 0 }
    public init(canPause: Bool, canSeek: Bool, canSetStreamVolume: Bool, canMute: Bool) { self.canPause = canPause; self.canSeek = canSeek; self.canSetStreamVolume = canSetStreamVolume; self.canMute = canMute }
}

public enum CastPlayerState: String, Sendable, Equatable { case idle = "IDLE", buffering = "BUFFERING", playing = "PLAYING", paused = "PAUSED", loading = "LOADING" }
public enum CastIdleReason: String, Sendable, Equatable { case cancelled = "CANCELLED", interrupted = "INTERRUPTED", finished = "FINISHED", error = "ERROR" }

/// One entry of a `MEDIA_STATUS`, as reported.
public struct CastMediaStatus: Equatable, Sendable {
    public let mediaSessionID: Int
    public let state: CastPlayerState
    public let currentTime: Double?
    public let duration: Double?
    public let contentID: String?
    public let idleReason: CastIdleReason?
    public let capabilities: CastReceiverCapabilities?
    public let volume: CastVolume?
}
public struct CastVolume: Equatable, Sendable {
    public let level: Double?, muted: Bool?
    /// The receiver's own word for how its volume is controlled: "attenuation", "master" or "fixed" (a fixed-volume receiver ignores SET_VOLUME). nil: not reported.
    public let controlType: String?
    public init(level: Double?, muted: Bool?, controlType: String? = nil) { self.level = level; self.muted = muted; self.controlType = controlType }
    public var isFixed: Bool { controlType?.lowercased() == "fixed" }
}
public struct CastApplication: Equatable, Sendable {
    public let appID: String, sessionID: String, transportID: String, displayName: String?, namespaces: [String]
}
public struct CastReceiverStatus: Equatable, Sendable { public let applications: [CastApplication]; public let volume: CastVolume? }

/// A receiver's reply, reduced to what the sender acts on.
public enum CastInbound: Equatable, Sendable {
    case ping, pong
    case close                                   // tp.connection CLOSE
    case receiverStatus(requestID: Int?, CastReceiverStatus)
    case mediaStatus(requestID: Int?, [CastMediaStatus])
    case failure(type: String, requestID: Int?, reason: String?)   // LOAD_FAILED, LOAD_CANCELLED, INVALID_REQUEST, INVALID_PLAYER_STATE, LAUNCH_ERROR
    case other(type: String)
}

public enum CastMessages {
    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
    private static func message(_ namespace: String, to destination: String, _ object: [String: Any]) -> CastMessage {
        CastMessage(sourceID: CastIdentity.senderID, destinationID: destination, namespace: namespace, json: json(object))
    }
    // Connection and heartbeat
    public static func connect(to destination: String = CastIdentity.platformReceiverID) -> CastMessage {
        message(CastNamespace.connection, to: destination, ["type": "CONNECT", "origin": [String: Any](), "userAgent": CastIdentity.userAgent, "connType": 0])
    }
    public static func close(to destination: String = CastIdentity.platformReceiverID) -> CastMessage { message(CastNamespace.connection, to: destination, ["type": "CLOSE"]) }
    public static func ping() -> CastMessage { message(CastNamespace.heartbeat, to: CastIdentity.platformReceiverID, ["type": "PING"]) }
    public static func pong() -> CastMessage { message(CastNamespace.heartbeat, to: CastIdentity.platformReceiverID, ["type": "PONG"]) }
    // Receiver namespace (to the platform receiver)
    public static func getStatus(requestID: Int) -> CastMessage { message(CastNamespace.receiver, to: CastIdentity.platformReceiverID, ["type": "GET_STATUS", "requestId": requestID]) }
    public static func launch(appID: String = CastIdentity.defaultMediaReceiverAppID, requestID: Int) -> CastMessage {
        message(CastNamespace.receiver, to: CastIdentity.platformReceiverID, ["type": "LAUNCH", "appId": appID, "requestId": requestID])
    }
    public static func stopApplication(sessionID: String, requestID: Int) -> CastMessage {
        message(CastNamespace.receiver, to: CastIdentity.platformReceiverID, ["type": "STOP", "sessionId": sessionID, "requestId": requestID])
    }
    public static func setVolume(level: Double?, muted: Bool?, requestID: Int) -> CastMessage {
        var volume: [String: Any] = [:]
        if let level { volume["level"] = min(1, max(0, level)) }
        if let muted { volume["muted"] = muted }
        return message(CastNamespace.receiver, to: CastIdentity.platformReceiverID, ["type": "SET_VOLUME", "volume": volume, "requestId": requestID])
    }
    // Media namespace (to the application's transport)
    public struct Load: Equatable, Sendable {
        public var url: String, contentType: String, title: String, artist: String?, duration: Double?, startAt: Double, autoplay: Bool
        public init(url: String, contentType: String, title: String, artist: String?, duration: Double?, startAt: Double, autoplay: Bool) {
            self.url = url; self.contentType = contentType; self.title = title; self.artist = artist; self.duration = duration; self.startAt = startAt; self.autoplay = autoplay
        }
    }
    public static func load(_ load: Load, sessionID: String, transportID: String, requestID: Int) -> CastMessage {
        var metadata: [String: Any] = ["metadataType": 3, "title": load.title]
        if let artist = load.artist { metadata["artist"] = artist }
        var media: [String: Any] = ["contentId": load.url, "contentType": load.contentType, "streamType": "BUFFERED", "metadata": metadata]
        if let duration = load.duration, duration.isFinite, duration > 0 { media["duration"] = duration }
        return message(CastNamespace.media, to: transportID, ["type": "LOAD", "requestId": requestID, "sessionId": sessionID, "media": media,
                                                              "autoplay": load.autoplay, "currentTime": max(0, load.startAt)])
    }
    public static func mediaCommand(_ type: String, mediaSessionID: Int, transportID: String, requestID: Int, extra: [String: Any] = [:]) -> CastMessage {
        message(CastNamespace.media, to: transportID, ["type": type, "mediaSessionId": mediaSessionID, "requestId": requestID].merging(extra) { $1 })
    }
    public static func mediaGetStatus(transportID: String, requestID: Int) -> CastMessage { message(CastNamespace.media, to: transportID, ["type": "GET_STATUS", "requestId": requestID]) }

    // MARK: Reading what the receiver said
    public static func parse(_ message: CastMessage) -> CastInbound? {
        guard let text = message.text, text.utf8.count <= CastWire.maximumFrame,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let type = object["type"] as? String else { return nil }
        let requestID = (object["requestId"] as? NSNumber)?.intValue
        switch (message.namespace, type) {
        case (CastNamespace.heartbeat, "PING"): return .ping
        case (CastNamespace.heartbeat, "PONG"): return .pong
        case (CastNamespace.connection, "CLOSE"): return .close
        case (CastNamespace.receiver, "RECEIVER_STATUS"):
            guard let status = object["status"] as? [String: Any] else { return nil }
            let apps = (status["applications"] as? [[String: Any]] ?? []).compactMap { app -> CastApplication? in
                guard let appID = app["appId"] as? String, let session = app["sessionId"] as? String, let transport = app["transportId"] as? String else { return nil }
                return CastApplication(appID: appID, sessionID: session, transportID: transport, displayName: app["displayName"] as? String,
                                       namespaces: (app["namespaces"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
            }
            return .receiverStatus(requestID: requestID, CastReceiverStatus(applications: apps, volume: volume(status["volume"])))
        case (CastNamespace.media, "MEDIA_STATUS"):
            let entries = (object["status"] as? [[String: Any]] ?? []).compactMap { entry -> CastMediaStatus? in
                guard let id = (entry["mediaSessionId"] as? NSNumber)?.intValue, let raw = entry["playerState"] as? String, let state = CastPlayerState(rawValue: raw) else { return nil }
                let media = entry["media"] as? [String: Any]
                return CastMediaStatus(mediaSessionID: id, state: state, currentTime: (entry["currentTime"] as? NSNumber)?.doubleValue,
                                       duration: (media?["duration"] as? NSNumber)?.doubleValue, contentID: media?["contentId"] as? String,
                                       idleReason: (entry["idleReason"] as? String).flatMap(CastIdleReason.init(rawValue:)),
                                       capabilities: (entry["supportedMediaCommands"] as? NSNumber).map { CastReceiverCapabilities(bits: $0.intValue) }, volume: volume(entry["volume"]))
            }
            return .mediaStatus(requestID: requestID, entries)
        case (CastNamespace.media, "LOAD_FAILED"), (CastNamespace.media, "LOAD_CANCELLED"), (CastNamespace.media, "INVALID_REQUEST"), (CastNamespace.media, "INVALID_PLAYER_STATE"), (CastNamespace.receiver, "LAUNCH_ERROR"), (CastNamespace.receiver, "INVALID_REQUEST"):
            // A receiver chooses this text: it is scrubbed (URLs, addresses, paths) and capped before it can be stored or shown.
            return .failure(type: type, requestID: requestID, reason: (object["reason"] as? String).map(SafeErrorText.scrub))
        default: return .other(type: type)
        }
    }
    private static func volume(_ value: Any?) -> CastVolume? {
        guard let object = value as? [String: Any] else { return nil }
        return CastVolume(level: (object["level"] as? NSNumber)?.doubleValue, muted: object["muted"] as? Bool, controlType: object["controlType"] as? String)
    }
}
