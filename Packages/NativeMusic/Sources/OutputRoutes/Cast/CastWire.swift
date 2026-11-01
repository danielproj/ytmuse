import Foundation

// W39 (ROUTE05). The Cast V2 wire format, written from the public protocol description: a `CastMessage` protobuf (proto2) carried in frames that
// start with a four-byte big-endian length. Pure functions over bytes; nothing here touches a network.
//
//   message CastMessage {
//     required ProtocolVersion protocol_version = 1;   // CASTV2_1_0 = 0
//     required string source_id = 2;
//     required string destination_id = 3;
//     required string namespace = 4;
//     required PayloadType payload_type = 5;           // STRING = 0, BINARY = 1
//     optional string payload_utf8 = 6;
//     optional bytes payload_binary = 7;
//   }

public enum CastWireError: Error, Equatable, Sendable {
    case truncated, malformed, frameTooLarge, notUTF8, unsupportedProtocol, missingField
}

public struct CastMessage: Equatable, Sendable {
    public enum Payload: Equatable, Sendable { case text(String), binary(Data) }
    public var sourceID: String
    public var destinationID: String
    public var namespace: String
    public var payload: Payload
    public init(sourceID: String, destinationID: String, namespace: String, payload: Payload) {
        self.sourceID = sourceID; self.destinationID = destinationID; self.namespace = namespace; self.payload = payload
    }
    public init(sourceID: String, destinationID: String, namespace: String, json: String) {
        self.init(sourceID: sourceID, destinationID: destinationID, namespace: namespace, payload: .text(json))
    }
    public var text: String? { if case .text(let value) = payload { value } else { nil } }
}

public enum CastWire {
    /// A frame larger than this is refused before it is buffered: the protocol caps a message at 64 KiB.
    public static let maximumFrame = 65_536

    // MARK: Encoding
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat { var byte = UInt8(value & 0x7F); value >>= 7; if value != 0 { byte |= 0x80 }; bytes.append(byte) } while value != 0
        return bytes
    }
    static func field(_ number: UInt64, string: String) -> [UInt8] { field(number, bytes: Array(string.utf8)) }
    static func field(_ number: UInt64, bytes: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes }
    static func field(_ number: UInt64, varint value: UInt64) -> [UInt8] { varint(number << 3) + varint(value) }

    /// The protobuf body of one message (no length prefix).
    public static func encodeBody(_ message: CastMessage) -> Data {
        var bytes = field(1, varint: 0) + field(2, string: message.sourceID) + field(3, string: message.destinationID) + field(4, string: message.namespace)
        switch message.payload {
        case .text(let text): bytes += field(5, varint: 0) + field(6, string: text)
        case .binary(let data): bytes += field(5, varint: 1) + field(7, bytes: Array(data))
        }
        return Data(bytes)
    }
    /// One frame: four-byte big-endian length, then the body. Throws for a body the protocol would refuse.
    public static func frame(_ message: CastMessage) throws -> Data {
        let body = encodeBody(message)
        guard body.count <= maximumFrame else { throw CastWireError.frameTooLarge }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    // MARK: Decoding
    private struct Reader {
        let bytes: [UInt8]; var index = 0
        var done: Bool { index >= bytes.count }
        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard index < bytes.count else { throw CastWireError.truncated }
                let byte = bytes[index]; index += 1
                guard shift < 64 else { throw CastWireError.malformed }
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }
        mutating func take(_ count: UInt64) throws -> [UInt8] {
            guard count <= UInt64(bytes.count - index) else { throw CastWireError.truncated }
            defer { index += Int(count) }
            return Array(bytes[index..<index + Int(count)])
        }
    }
    /// Parses one protobuf body. Unknown fields are skipped by wire type; groups and a missing required field are errors.
    public static func decodeBody(_ data: Data) throws -> CastMessage {
        var reader = Reader(bytes: Array(data))
        var version: UInt64?, source: String?, destination: String?, namespace: String?, type: UInt64?, text: String?, binary: [UInt8]?
        func string(_ bytes: [UInt8]) throws -> String { guard let value = String(bytes: bytes, encoding: .utf8) else { throw CastWireError.notUTF8 }; return value }
        while !reader.done {
            let key = try reader.varint(), number = key >> 3, wire = key & 7
            switch (number, wire) {
            case (1, 0): version = try reader.varint()
            case (2, 2): source = try string(try reader.take(try reader.varint()))
            case (3, 2): destination = try string(try reader.take(try reader.varint()))
            case (4, 2): namespace = try string(try reader.take(try reader.varint()))
            case (5, 0): type = try reader.varint()
            case (6, 2): text = try string(try reader.take(try reader.varint()))
            case (7, 2): binary = try reader.take(try reader.varint())
            case (_, 0): _ = try reader.varint()
            case (_, 1): _ = try reader.take(8)
            case (_, 2): _ = try reader.take(try reader.varint())
            case (_, 5): _ = try reader.take(4)
            default: throw CastWireError.malformed   // groups (3, 4) and reserved wire types
            }
        }
        guard let source, let destination, let namespace, let type, let version else { throw CastWireError.missingField }
        guard version == 0 else { throw CastWireError.unsupportedProtocol }
        switch type {
        case 0: guard let text else { throw CastWireError.missingField }; return CastMessage(sourceID: source, destinationID: destination, namespace: namespace, payload: .text(text))
        case 1: guard let binary else { throw CastWireError.missingField }; return CastMessage(sourceID: source, destinationID: destination, namespace: namespace, payload: .binary(Data(binary)))
        default: throw CastWireError.malformed
        }
    }
}

/// Reassembles frames from arbitrary chunks of a TCP stream. A length above the cap fails at once, before any of the body is buffered.
public struct CastFrameDecoder: Sendable {
    private var buffer = Data()
    public init() {}
    public var bufferedBytes: Int { buffer.count }
    public mutating func append(_ chunk: Data) throws -> [CastMessage] {
        buffer.append(chunk)
        var messages: [CastMessage] = []
        while buffer.count >= 4 {
            let base = buffer.startIndex
            let length = buffer[base..<base + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard length > 0, length <= UInt32(CastWire.maximumFrame) else { throw length == 0 ? CastWireError.malformed : CastWireError.frameTooLarge }
            guard buffer.count >= 4 + Int(length) else { break }
            let size = Int(length)
            let bodyStart = base + 4, bodyEnd = bodyStart + size
            let body = Data(buffer[bodyStart..<bodyEnd])
            buffer = Data(buffer[bodyEnd...])
            messages.append(try CastWire.decodeBody(body))
        }
        return messages
    }
}
