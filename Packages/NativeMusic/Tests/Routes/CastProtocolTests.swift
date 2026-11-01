import Foundation
import Testing
@testable import OutputRoutes

/// T39 (protocol coverage): the Cast V2 wire format and the JSON of the four namespaces. The wire tests compare against bytes written out by hand
/// from the public protocol description, so an encoder and a decoder that are wrong in the same way cannot agree with each other and pass.
@Suite struct CastWireTests {
    static let ping = CastMessage(sourceID: "sender-0", destinationID: "receiver-0", namespace: "urn:x-cast:com.google.cast.tp.heartbeat", json: "{\"type\":\"PING\"}")

    @Test func aMessageEncodesToTheHandWrittenProtobufBytes() throws {
        func field(_ number: UInt8, _ text: String) -> [UInt8] { [number << 3 | 2, UInt8(text.utf8.count)] + Array(text.utf8) }
        let expected: [UInt8] = [0x08, 0x00] + field(2, "sender-0") + field(3, "receiver-0") + field(4, "urn:x-cast:com.google.cast.tp.heartbeat") + [0x28, 0x00] + field(6, "{\"type\":\"PING\"}")
        #expect(Array(CastWire.encodeBody(Self.ping)) == expected)
        let frame = try CastWire.frame(Self.ping)
        #expect(Array(frame.prefix(4)) == [0, 0, 0, UInt8(expected.count)], "four-byte big-endian length")
        #expect(Array(frame.dropFirst(4)) == expected)
    }
    @Test func aDecodedFrameIsTheMessageThatWasSent() throws {
        var decoder = CastFrameDecoder()
        let decoded = try decoder.append(try CastWire.frame(Self.ping))
        #expect(decoded == [Self.ping])
        let binary = CastMessage(sourceID: "a", destinationID: "b", namespace: "urn:x-cast:com.google.cast.tp.deviceauth", payload: .binary(Data([0, 1, 2, 255])))
        #expect(try decoder.append(try CastWire.frame(binary)) == [binary])
    }
    @Test func frameBoundariesDoNotMatter() throws {
        let one = try CastWire.frame(Self.ping), two = try CastWire.frame(CastMessages.connect())
        var byByte = CastFrameDecoder(), received: [CastMessage] = []
        for byte in one + two { received += try byByte.append(Data([byte])) }
        #expect(received == [Self.ping, CastMessages.connect()])
        var together = CastFrameDecoder()
        #expect(try together.append(one + two).count == 2, "two frames in one chunk")
        var split = CastFrameDecoder()
        #expect(try split.append(one.prefix(3)).isEmpty && split.bufferedBytes == 3, "a partial length prefix waits")
        #expect(try split.append(one.dropFirst(3)) == [Self.ping])
    }
    @Test func aHugeOrEmptyLengthFailsBeforeAnyBodyIsBuffered() {
        var decoder = CastFrameDecoder()
        #expect(throws: CastWireError.frameTooLarge) { try decoder.append(Data([0x7F, 0xFF, 0xFF, 0xFF])) }
        var empty = CastFrameDecoder()
        #expect(throws: CastWireError.malformed) { try empty.append(Data([0, 0, 0, 0])) }
        #expect(throws: CastWireError.frameTooLarge) { try CastWire.frame(CastMessage(sourceID: "a", destinationID: "b", namespace: "n", json: String(repeating: "x", count: 70_000))) }
        var justOver = CastFrameDecoder()
        #expect(throws: CastWireError.frameTooLarge) { try justOver.append(Data([0, 1, 0, 1])) }   // 65,537
    }
    @Test func malformedBodiesAreRefusedNotGuessedAt() throws {
        func body(_ bytes: [UInt8]) throws -> CastMessage { try CastWire.decodeBody(Data(bytes)) }
        #expect(throws: CastWireError.truncated) { try body([0x08]) }                              // a varint cut short
        #expect(throws: CastWireError.truncated) { try body([0x12, 0x09, 0x61]) }                 // a length past the end
        #expect(throws: CastWireError.malformed) { try body([0x0B]) }                              // a start-group wire type
        #expect(throws: CastWireError.missingField) { try body([0x08, 0x00]) }                     // required fields absent
        #expect(throws: CastWireError.notUTF8) { try body([0x12, 0x01, 0xFF]) }
        let good = Array(CastWire.encodeBody(Self.ping))
        #expect(throws: CastWireError.unsupportedProtocol) { try body([0x08, 0x05] + good.dropFirst(2)) }
        // An unknown field is skipped (varint, fixed64, length-delimited, fixed32), so a newer receiver still decodes.
        let extras: [UInt8] = [0x40, 0x07, 0x49, 1, 2, 3, 4, 5, 6, 7, 8, 0x52, 0x02, 0x61, 0x62, 0x5D, 1, 2, 3, 4]
        #expect(try body(good + extras) == Self.ping)
        #expect(throws: CastWireError.missingField) { try body(Array(good.prefix(while: { $0 != 0x28 }))) }   // no payload type
    }
    @Test func aNonTenOverlongVarintIsRefused() {
        #expect(throws: CastWireError.malformed) { try CastWire.decodeBody(Data([0x08] + [UInt8](repeating: 0x80, count: 11) + [0x01])) }
    }
}

@Suite struct CastMessageTests {
    func object(_ message: CastMessage) throws -> [String: Any] {
        let text = try #require(message.text)
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(parsed as? [String: Any])
    }

    @Test func theConnectionHandshakeAndHeartbeatUseTheDocumentedNamespacesAndTypes() throws {
        let connect = CastMessages.connect()
        #expect(connect.namespace == "urn:x-cast:com.google.cast.tp.connection" && connect.destinationID == "receiver-0" && connect.sourceID == "sender-0")
        #expect(try object(connect)["type"] as? String == "CONNECT")
        #expect(try object(CastMessages.close())["type"] as? String == "CLOSE")
        #expect(CastMessages.ping().namespace == "urn:x-cast:com.google.cast.tp.heartbeat")
        #expect(try object(CastMessages.ping())["type"] as? String == "PING" && (try object(CastMessages.pong())["type"] as? String) == "PONG")
    }
    @Test func launchTargetsTheDefaultMediaReceiverAndNothingElse() throws {
        let launch = try object(CastMessages.launch(requestID: 7))
        #expect(launch["appId"] as? String == "CC1AD845" && launch["requestId"] as? Int == 7 && launch["type"] as? String == "LAUNCH")
        let stop = try object(CastMessages.stopApplication(sessionID: "S", requestID: 9))
        #expect(stop["type"] as? String == "STOP" && stop["sessionId"] as? String == "S")
    }
    @Test func loadCarriesOnlyTheMediaAddressAndItsDescription() throws {
        let load = CastMessages.Load(url: "http://192.168.1.20:5000/c/TOKEN/tag.wav", contentType: "audio/wav", title: "Tone", artist: "Synthetic", duration: 120, startAt: 31.5, autoplay: false)
        let message = CastMessages.load(load, sessionID: "SESSION", transportID: "TRANSPORT", requestID: 3)
        #expect(message.destinationID == "TRANSPORT" && message.namespace == "urn:x-cast:com.google.cast.media")
        let json = try object(message)
        #expect(json["type"] as? String == "LOAD" && json["autoplay"] as? Bool == false && json["currentTime"] as? Double == 31.5 && json["sessionId"] as? String == "SESSION")
        let media = try #require(json["media"] as? [String: Any])
        #expect(media["contentId"] as? String == load.url && media["contentType"] as? String == "audio/wav" && media["streamType"] as? String == "BUFFERED" && media["duration"] as? Double == 120)
        #expect(Set(json.keys) == ["type", "requestId", "sessionId", "media", "autoplay", "currentTime"], "no customData, credentials or account fields: \(json.keys.sorted())")
        #expect(Set(media.keys) == ["contentId", "contentType", "streamType", "metadata", "duration"])
    }
    @Test func mediaCommandsAddressTheMediaSessionOnTheTransport() throws {
        let seek = try object(CastMessages.mediaCommand("SEEK", mediaSessionID: 4, transportID: "T", requestID: 11, extra: ["currentTime": 62.5]))
        #expect(seek["type"] as? String == "SEEK" && seek["mediaSessionId"] as? Int == 4 && seek["currentTime"] as? Double == 62.5)
        let volume = try object(CastMessages.setVolume(level: 1.7, muted: nil, requestID: 2))
        #expect((volume["volume"] as? [String: Any])?["level"] as? Double == 1, "a level outside 0...1 is clamped")
    }
    @Test func aMediaStatusIsReadAsTheReceiverReportedIt() throws {
        let json = """
        {"type":"MEDIA_STATUS","requestId":5,"status":[{"mediaSessionId":3,"playerState":"PLAYING","currentTime":42.25,"supportedMediaCommands":15,
         "media":{"contentId":"http://x/y.wav","duration":200.5},"volume":{"level":0.4,"muted":false},"idleReason":null}]}
        """
        let parsed = CastMessages.parse(CastMessage(sourceID: "t", destinationID: "sender-0", namespace: CastNamespace.media, json: json))
        guard case .mediaStatus(let request, let entries)? = parsed, let entry = entries.first else { Issue.record("not a media status: \(String(describing: parsed))"); return }
        #expect(request == 5 && entry.mediaSessionID == 3 && entry.state == .playing && entry.currentTime == 42.25 && entry.duration == 200.5 && entry.contentID == "http://x/y.wav")
        #expect(entry.capabilities == CastReceiverCapabilities(canPause: true, canSeek: true, canSetStreamVolume: true, canMute: true))
        #expect(entry.volume == CastVolume(level: 0.4, muted: false))
    }
    @Test func capabilityBitsAreReadIndividually() {
        #expect(CastReceiverCapabilities(bits: 1) == CastReceiverCapabilities(canPause: true, canSeek: false, canSetStreamVolume: false, canMute: false))
        #expect(CastReceiverCapabilities(bits: 2 | 8) == CastReceiverCapabilities(canPause: false, canSeek: true, canSetStreamVolume: false, canMute: true))
        #expect(CastReceiverCapabilities(bits: 0) == CastReceiverCapabilities(canPause: false, canSeek: false, canSetStreamVolume: false, canMute: false))
    }
    @Test func aReceiverStatusNamesTheApplicationAndItsTransport() throws {
        let json = #"{"type":"RECEIVER_STATUS","requestId":1,"status":{"applications":[{"appId":"CC1AD845","sessionId":"S1","transportId":"T1","displayName":"Default Media Receiver","namespaces":[{"name":"urn:x-cast:com.google.cast.media"}]}],"volume":{"level":0.5,"muted":true}}}"#
        guard case .receiverStatus(_, let status)? = CastMessages.parse(CastMessage(sourceID: "receiver-0", destinationID: "sender-0", namespace: CastNamespace.receiver, json: json)) else { Issue.record("not a receiver status"); return }
        #expect(status.applications == [CastApplication(appID: "CC1AD845", sessionID: "S1", transportID: "T1", displayName: "Default Media Receiver", namespaces: ["urn:x-cast:com.google.cast.media"])])
        #expect(status.volume == CastVolume(level: 0.5, muted: true))
    }
    @Test func failuresAndPingsAreRecognisedAndGarbageIsNot() {
        func parse(_ namespace: String, _ json: String) -> CastInbound? { CastMessages.parse(CastMessage(sourceID: "r", destinationID: "sender-0", namespace: namespace, json: json)) }
        #expect(parse(CastNamespace.media, #"{"type":"LOAD_FAILED","requestId":4,"reason":"X"}"#) == .failure(type: "LOAD_FAILED", requestID: 4, reason: "X"))
        #expect(parse(CastNamespace.heartbeat, #"{"type":"PING"}"#) == .ping)
        #expect(parse(CastNamespace.connection, #"{"type":"CLOSE"}"#) == .close)
        // The reason is receiver-supplied text: a URL in it is scrubbed before it can be stored or shown (SafeErrorText).
        if case .failure(_, _, let reason)? = parse(CastNamespace.media, #"{"type":"LOAD_FAILED","reason":"cannot fetch http://192.168.1.20:5000/c/TOKEN/x.wav now"}"#) {
            #expect(reason == "cannot fetch <url> now", "\(reason ?? "nil")")
        } else { Issue.record("not a failure") }
        #expect(parse(CastNamespace.media, "not json") == nil && parse(CastNamespace.media, "[1,2]") == nil && parse(CastNamespace.media, #"{"no":"type"}"#) == nil)
        #expect(parse(CastNamespace.media, #"{"type":"MEDIA_STATUS","status":[{"mediaSessionId":1,"playerState":"WEIRD"}]}"#) == .mediaStatus(requestID: nil, []), "an unknown player state is not guessed")
    }
}

@Suite struct CastDeviceRouteTests {
    @Test func aDeviceIdentifierIsOnlyWhatARecordCanLegitimatelyHold() {
        #expect(CastDeviceID("0123abcd-EF45") != nil)
        for bad in ["", "has space", "semi;colon", "a/b", "a:b", "ü", String(repeating: "a", count: 65)] { #expect(CastDeviceID(bad) == nil, "\(bad)") }
    }
    @Test func theRouteIdentifierPersistsTheDeviceIdNeverTheName() throws {
        let route = CastFixtures.livingRoom.routeID
        #expect(route.rawValue == "cast:SYNTH-CAST-LIVING" && route.isCast && route.castDeviceID == CastFixtures.livingRoom.id)
        #expect(OutputRouteID(persisted: route.rawValue) == route)
        #expect(OutputRouteID(persisted: "cast:") == nil && OutputRouteID(persisted: "cast:bad id") == nil && OutputRouteID(persisted: "cast:" + String(repeating: "a", count: 65)) == nil)
        #expect(CastFixtures.livingRoom.routeID != CastFixtures.otherLivingRoom.routeID, "two receivers that share a name are two routes")
        let data = try JSONEncoder().encode(route)
        #expect(try JSONDecoder().decode(OutputRouteID.self, from: data) == route)
        #expect(!route.rawValue.contains("Living Room"))
        #expect(route.deviceUID == nil && !route.isSystemDefault, "a Cast route is not a CoreAudio device")
    }
    @Test func aReceiverThatStatesNoAudioOutputIsNotOffered() {
        #expect(CastFixtures.livingRoom.playsAudio && CastFixtures.kitchen.playsAudio)
        #expect(!CastFixtures.videoOnly.playsAudio)
        #expect(CastDevice(id: CastDeviceID("NOBITS")!, friendlyName: "x").playsAudio, "a record that does not say is assumed able")
        #expect(CastDevice(id: CastDeviceID("GROUP")!, friendlyName: "g", capabilityBits: 36).isGroup)
    }
}


@Suite struct CastCertificatePinTests {
    @Test func aSessionKeepsTheCertificateItFirstPresentedAndAnotherIsRefused() {
        let pins = CastCertificatePins()
        #expect(pins.accepts("aa", for: CastFixtures.livingRoom.id), "first sight is pinned")
        #expect(pins.accepts("aa", for: CastFixtures.livingRoom.id))
        #expect(!pins.accepts("bb", for: CastFixtures.livingRoom.id), "a different certificate for the same device is refused")
        #expect(pins.accepts("bb", for: CastFixtures.kitchen.id), "pins are per device")
        #expect(!pins.accepts("aa", for: CastFixtures.kitchen.id))
    }
    @Test func aNewConnectionAcceptsARegeneratedCertificateSoReconnectSurvivesRotation() {
        // Each connection gets its own pin set; a receiver that rebooted or rotated its certificate is a new session, not an attack.
        let first = CastCertificatePins(), afterReboot = CastCertificatePins()
        #expect(first.accepts("old", for: CastFixtures.livingRoom.id) && !first.accepts("new", for: CastFixtures.livingRoom.id))
        #expect(afterReboot.accepts("new", for: CastFixtures.livingRoom.id), "the same device with a new certificate on a later connection is accepted")
    }
    @Test func theFactoryCreatesFreshPinsForEveryConnectionAndKeepsNoneBetweenThem() throws {
        let source = OutputRoutesGuardTests.code(try String(contentsOf: OutputRoutesGuardTests.packageRoot.appendingPathComponent("Sources/OutputRoutes/Cast/CastNetwork.swift"), encoding: .utf8))
        #expect(source.contains("pins: CastCertificatePins())"), "constructed at each open")
        let factory = try #require(source.components(separatedBy: "public struct NWCastChannelFactory").dropFirst().first?.components(separatedBy: "final class NWCastChannel").first)
        #expect(!factory.contains("CastCertificatePins()") || factory.components(separatedBy: "CastCertificatePins()").count == 2, "one construction, inside open")
        #expect(!factory.contains("private let pins") && !factory.contains("let pins ="), "no pin set is stored on the factory")
        #expect(source.contains("(parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4"), "F1: the control connection is held to IPv4, as the relay is")
    }
    @Test func theFingerprintIsASha256OfTheCertificateBytes() {
        #expect(CastCertificatePins.fingerprint(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(CastCertificatePins.fingerprint(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
