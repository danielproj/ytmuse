@preconcurrency import AVFoundation
import CoreAudio
import Foundation

// W22. The ONLY file that points an engine at an output device or turns on AirPlay route detection. Both act on this app's own player or engine
// (not on the Mac's default output, volume, AirPlay or Bluetooth state), and both are injected: a test target never constructs the real
// implementations (`OutputRoutesGuardTests` sweeps every test source for these names and for the calls below).

/// Points a player at an output device by stable UID. `uid == nil` follows the system default again.
public protocol LocalOutputApplying: Sendable {
    func apply(uid: String?, to player: AVPlayer) -> Bool
    func apply(uid: String?, to engine: AVAudioEngine) -> Bool
}
/// What a unit-test process gets when nothing else is injected: it records nothing and moves nothing.
public struct NoOutputApplier: LocalOutputApplying {
    public init() {}
    public func apply(uid: String?, to player: AVPlayer) -> Bool { true }
    public func apply(uid: String?, to engine: AVAudioEngine) -> Bool { true }
}
/// The real implementation: `AVPlayer.audioOutputDeviceUniqueID` and the engine's output audio unit device. Both are per-player/per-engine settings
/// published by Apple (macOS 10.9+ and AudioToolbox); neither changes what the Mac plays through for any other app.
public struct AVFoundationOutputApplier: LocalOutputApplying {
    public init() {}
    public func apply(uid: String?, to player: AVPlayer) -> Bool {
        guard let uid else { player.audioOutputDeviceUniqueID = nil; return true }
        guard CoreAudioOutputDirectory.deviceID(forUID: uid) != nil else { return false }
        player.audioOutputDeviceUniqueID = uid
        return true
    }
    public func apply(uid: String?, to engine: AVAudioEngine) -> Bool {
        let device: AudioDeviceID
        if let uid {
            guard let found = CoreAudioOutputDirectory.deviceID(forUID: uid) else { return false }
            device = found
        } else {
            guard let found = CoreAudioOutputDirectory.defaultOutputID() else { return false }
            device = found
        }
        do { try engine.outputNode.withAUAudioUnit { try $0.setDeviceID(device) }; return true } catch { return false }
    }
}

/// Whether more than one AirPlay-capable route is around (`AVRouteDetector`), so the picker button can say so. It lists nothing: the public API
/// does not enumerate receivers, the system picker does.
@MainActor public final class AirPlayRouteDetection {
    private let detector = AVRouteDetector()
    private var observer: NSObjectProtocol?
    public private(set) var multipleRoutesDetected = false
    public var onChange: (@MainActor (Bool) -> Void)?
    public init() {}
    public func start() {
        detector.isRouteDetectionEnabled = true
        multipleRoutesDetected = detector.multipleRoutesDetected
        observer = NotificationCenter.default.addObserver(forName: .AVRouteDetectorMultipleRoutesDetectedDidChange, object: detector, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.multipleRoutesDetected = self.detector.multipleRoutesDetected; self.onChange?(self.multipleRoutesDetected) }
        }
    }
    public func stop() {
        detector.isRouteDetectionEnabled = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
