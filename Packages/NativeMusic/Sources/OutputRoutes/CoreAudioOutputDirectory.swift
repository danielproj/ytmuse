import CoreAudio
import Foundation

/// The Mac's outputs, READ from CoreAudio (ROUTE01, ROUTE11). Read-only: nothing here sets a property, the default output, a volume or a sample
/// rate (`OutputRoutesGuardTests` sweeps this package for any call that could). Property listeners are the only registration, and they run on the
/// main queue so a disconnect reaches the route-loss pause in the turn the system announces it.
public struct CoreAudioOutputDirectory: OutputDirectory {
    public init() {}

    public func snapshot() -> OutputSnapshot {
        let devices = Self.deviceIDs().compactMap(Self.outputDevice(_:))
        let defaultUID = Self.defaultOutputID().flatMap { Self.string($0, kAudioDevicePropertyDeviceUID) }
        return OutputSnapshot(devices: devices, defaultUID: defaultUID)
    }

    @MainActor public func observe(_ onChange: @escaping @MainActor () -> Void) -> OutputObservation {
        CoreAudioObservation(onChange: onChange)
    }

    /// The default output as a route identity (UID, transport and built-in data source) when it exists and is alive; read-only.
    public static func defaultOutputIdentity() -> RouteIdentity? { defaultOutputID().flatMap(outputDevice(_:))?.identity }

    // MARK: Reading

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func deviceIDs() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
    static func defaultOutputID() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &address), AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address(selector)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let text = value?.takeRetainedValue() as String?, !text.isEmpty else { return nil }
        return text
    }
    private static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }
    /// A live output: it has output streams, answers as alive and has a stable UID. Hidden devices (the system's own plumbing) are left out.
    static func outputDevice(_ id: AudioObjectID) -> OutputDevice? {
        guard hasOutputStreams(id), uint32(id, kAudioDevicePropertyDeviceIsAlive) == 1, uint32(id, kAudioDevicePropertyIsHidden) != 1,
              let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
        var volume = address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
        let hasVolume = AudioObjectHasProperty(id, &volume)
        return OutputDevice(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, transportCode: transport,
                            dataSource: uint32(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput), hasDeviceVolume: hasVolume)
    }
    /// The AudioDeviceID of a UID, for pointing a player at it (`AVFoundationOutputApplier`). Read-only.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    // MARK: Listening

    @MainActor private final class CoreAudioObservation: OutputObservation {
        private var onChange: (@MainActor () -> Void)?
        private var registrations: [(id: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
        init(onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
            let notify: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.fire() } }
            register(CoreAudioOutputDirectory.system, CoreAudioOutputDirectory.address(kAudioHardwarePropertyDefaultOutputDevice), notify)
            // The device list changing also changes which devices need a state listener.
            let relist: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.attachDeviceListeners(); self?.fire() } }
            register(CoreAudioOutputDirectory.system, CoreAudioOutputDirectory.address(kAudioHardwarePropertyDevices), relist)
            attachDeviceListeners()
        }
        private var deviceListeners: [(id: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
        private func attachDeviceListeners() {
            for entry in deviceListeners { var a = entry.address; AudioObjectRemovePropertyListenerBlock(entry.id, &a, DispatchQueue.main, entry.block) }
            deviceListeners.removeAll()
            let notify: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.fire() } }
            for id in CoreAudioOutputDirectory.deviceIDs() where CoreAudioOutputDirectory.hasOutputStreams(id) {
                // Alive (a device that goes away), the data source (the headphone jack on the built-in output) and the jack itself.
                for (selector, scope) in [(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal), (kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput), (kAudioDevicePropertyJackIsConnected, kAudioObjectPropertyScopeOutput)] {
                    var a = CoreAudioOutputDirectory.address(selector, scope: scope)
                    guard AudioObjectHasProperty(id, &a) else { continue }
                    if AudioObjectAddPropertyListenerBlock(id, &a, DispatchQueue.main, notify) == noErr { deviceListeners.append((id, a, notify)) }
                }
            }
        }
        private func register(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ block: @escaping AudioObjectPropertyListenerBlock) {
            var a = address
            if AudioObjectAddPropertyListenerBlock(id, &a, DispatchQueue.main, block) == noErr { registrations.append((id, address, block)) }
        }
        private func fire() { onChange?() }
        func cancel() {
            onChange = nil
            for entry in registrations + deviceListeners { var a = entry.address; AudioObjectRemovePropertyListenerBlock(entry.id, &a, DispatchQueue.main, entry.block) }
            registrations.removeAll(); deviceListeners.removeAll()
        }
        isolated deinit { cancel() }
    }
}
