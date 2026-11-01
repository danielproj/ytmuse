import CoreAudio
import Foundation

// W22 (ROUTE01-ROUTE04, ROUTE11). The one route model: W21's `RouteIdentity` (the CoreAudio UID and how the device is attached) lives here now,
// extended with the built-in data source, so a wake and a route loss compare the same facts. Nothing in this file touches hardware.

/// A route the person can choose. Persisted as this string and never as a display name (ROUTE02): two receivers that share a name are two routes.
public struct OutputRouteID: Hashable, Sendable, Codable {
    public let rawValue: String
    private init(rawValue: String) { self.rawValue = rawValue }
    /// "Whatever the Mac is set to play through." The default until a person chooses (ROUTE02).
    public static let systemDefault = OutputRouteID(rawValue: "system-default")
    private static let devicePrefix = "coreaudio:"
    private static let castPrefix = "cast:"
    public static func device(uid: String) -> OutputRouteID { OutputRouteID(rawValue: devicePrefix + uid) }
    /// W39: a Cast receiver, by the device's own identifier (the `id` of its DNS-SD record), never by its friendly name.
    public static func cast(id: CastDeviceID) -> OutputRouteID { OutputRouteID(rawValue: castPrefix + id.rawValue) }
    /// Rebuilds an identifier read from storage; nil for anything this app never wrote, so a damaged value falls back to the system output.
    public init?(persisted: String) {
        if persisted == Self.systemDefault.rawValue { self = .systemDefault; return }
        if persisted.hasPrefix(Self.castPrefix) {
            guard let id = CastDeviceID(String(persisted.dropFirst(Self.castPrefix.count))) else { return nil }
            self = .cast(id: id); return
        }
        guard persisted.hasPrefix(Self.devicePrefix), persisted.count > Self.devicePrefix.count, persisted.count <= 512 else { return nil }
        self.init(rawValue: persisted)
    }
    public var isSystemDefault: Bool { self == .systemDefault }
    public var deviceUID: String? { rawValue.hasPrefix(Self.devicePrefix) ? String(rawValue.dropFirst(Self.devicePrefix.count)) : nil }
    public var castDeviceID: CastDeviceID? { rawValue.hasPrefix(Self.castPrefix) ? CastDeviceID(String(rawValue.dropFirst(Self.castPrefix.count))) : nil }
    public var isCast: Bool { castDeviceID != nil }
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = OutputRouteID(persisted: text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown route identifier")) }
        self = value
    }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

/// How an output is attached, from CoreAudio's transport type. Unknown codes are `.other`, never guessed.
public enum OutputTransport: Sendable, Equatable {
    case builtIn, usb, bluetooth, airPlay, hdmi, thunderbolt, virtual, aggregate, other
    public init(coreAudio code: UInt32) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .hdmi
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire: self = .thunderbolt
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        default: self = .other
        }
    }
    /// Attached to the Mac from outside (it can be taken away): everything except the built-in output and software devices.
    public var isDetachable: Bool { ![.builtIn, .virtual, .aggregate].contains(self) }
}

/// What the built-in output is currently driving (the headphone jack switches the data source of the same device).
public enum BuiltInDataSource: Sendable, Equatable {
    case speakers, headphones, other
    public init(code: UInt32) { self = code == 0x6973_706B /* 'ispk' */ ? .speakers : (code == 0x6864_706E /* 'hdpn' */ ? .headphones : .other) }
}

/// The default output device as the system names it: its stable UID, how it is attached and (built-in only) what it is driving.
public struct RouteIdentity: Equatable, Sendable {
    public let uid: String
    public let transport: UInt32
    public let dataSource: UInt32?
    public init(uid: String, transport: UInt32, dataSource: UInt32? = nil) { self.uid = uid; self.transport = transport; self.dataSource = dataSource }
}

public struct OutputDevice: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public let transportCode: UInt32
    public let dataSource: UInt32?
    /// CoreAudio exposes a level for this output. The app never writes it (system volume is the Mac's); it only decides what the picker says.
    public let hasDeviceVolume: Bool
    public init(uid: String, name: String, transportCode: UInt32, dataSource: UInt32? = nil, hasDeviceVolume: Bool = false) {
        self.uid = uid; self.name = name; self.transportCode = transportCode; self.dataSource = dataSource; self.hasDeviceVolume = hasDeviceVolume
    }
    public var id: OutputRouteID { .device(uid: uid) }
    public var transport: OutputTransport { OutputTransport(coreAudio: transportCode) }
    public var identity: RouteIdentity { RouteIdentity(uid: uid, transport: transportCode, dataSource: dataSource) }
    public var builtInSource: BuiltInDataSource? { transport == .builtIn ? dataSource.map(BuiltInDataSource.init(code:)) : nil }
    public var isHeadphones: Bool { builtInSource == .headphones }
}

/// Every live output at one instant and which of them the system plays through.
public struct OutputSnapshot: Equatable, Sendable {
    public let devices: [OutputDevice]
    public let defaultUID: String?
    public init(devices: [OutputDevice], defaultUID: String?) { self.devices = devices; self.defaultUID = defaultUID }
    public static let empty = OutputSnapshot(devices: [], defaultUID: nil)
    public func device(uid: String) -> OutputDevice? { devices.first { $0.uid == uid } }
    public var defaultDevice: OutputDevice? { defaultUID.flatMap(device(uid:)) }
}

/// A read-only view of the Mac's outputs. The real one (`CoreAudioOutputDirectory`) reads CoreAudio and registers property listeners; a test supplies
/// a scripted one, so no test ever reads or changes the real devices.
public protocol OutputDirectory: Sendable {
    func snapshot() -> OutputSnapshot
    /// Tells `onChange` (on the main actor, in the same turn as the system's notification) that the list, the default output or a device's state
    /// changed. The caller re-reads `snapshot()`; the notification carries nothing to trust.
    @MainActor func observe(_ onChange: @escaping @MainActor () -> Void) -> OutputObservation
}
public protocol OutputObservation: AnyObject { @MainActor func cancel() }

/// The two engines behind the one playback owner (PLAY01, `Docs/Playback-Addendum.md`).
public enum OutputEngineKind: String, Sendable, Equatable { case youTubeMusic, localMedia }
