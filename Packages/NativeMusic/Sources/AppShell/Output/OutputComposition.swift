import Foundation
import OutputRoutes
import Playback

// W22. The one place that chooses REAL or SCRIPTED outputs. A normal launch reads CoreAudio (read-only), points the local player with AVFoundation's
// per-player setting and runs AirPlay route detection. An isolated (UI test / design) launch, and every unit test, gets a scripted directory and an
// applier that moves nothing, so no automated run can read or change the account holder's devices. The real types are named here and nowhere else in
// the app (`OutputRoutesGuardTests` pins that).
extension LocalAccountBootstrap {
    func installOutputs() {
        guard outputs == nil else { return }
        #if DEBUG
        if IsolatedQAStorage.requested() {
            let scripted = ScriptedOutputDirectory()
            let controller = OutputController(coordinator: OutputRouteCoordinator(directory: scripted, store: DefaultsPreferredRoute(AppPreferences.store)), applier: NoOutputApplier())
            controller.scripted = scripted
            controller.usesRealSystemPicker = false
            // Scripted receivers and an in-process simulated one: an isolated launch never browses or connects to anything on the network.
            let simulated = SimulatedCastReceiver()
            controller.castDirectory = ScriptedCastDirectory()
            controller.castFactory = simulated
            controller.scriptedCastReceiver = simulated
            outputs = controller
            let playback = playback
            Task { @MainActor in await controller.bind(to: playback) }
            return
        }
        #endif
        let controller = OutputController(coordinator: OutputRouteCoordinator(directory: CoreAudioOutputDirectory(), store: DefaultsPreferredRoute(AppPreferences.store)),
                                          applier: AVFoundationOutputApplier())
        outputs = controller
        // The real network switch: turned on only here, in a normal launch (it refuses inside a test process). Nothing is browsed until the picker is opened.
        if (try? CastNetworkGate.enableLive()) != nil {
            let directory = NWCastDirectory()
            controller.castDirectory = directory
            controller.castFactory = NWCastChannelFactory(directory: directory)
        }
        let detection = AirPlayRouteDetection()
        detection.onChange = { [weak controller] multiple in controller?.multipleAirPlayRoutes = multiple }
        detection.start()
        controller.airPlayDetection = detection
        let playback = playback
        Task { @MainActor in await controller.bind(to: playback) }
    }
}

#if DEBUG
/// Isolated launches only: a fixed, deterministic list of outputs that a UI test can change through the Debug controls. Never reads a device.
final class ScriptedOutputDirectory: OutputDirectory, @unchecked Sendable {
    static let headphonesUID = "SCRIPTED-BT-HEADPHONES", speakersUID = "SCRIPTED-BUILT-IN-SPEAKERS"
    private let lock = NSLock()
    private var headphonesPresent = true
    private var handlers: [UUID: @MainActor () -> Void] = [:]
    private let speakers = OutputDevice(uid: speakersUID, name: "Scripted Speakers", transportCode: 0x626C_746E /* built-in */, dataSource: 0x6973_706B, hasDeviceVolume: true)
    private let headphones = OutputDevice(uid: headphonesUID, name: "Scripted Headphones", transportCode: 0x626C_7565 /* Bluetooth */, hasDeviceVolume: true)
    func snapshot() -> OutputSnapshot {
        lock.withLock { OutputSnapshot(devices: headphonesPresent ? [speakers, headphones] : [speakers], defaultUID: headphonesPresent ? Self.headphonesUID : Self.speakersUID) }
    }
    @MainActor func observe(_ onChange: @escaping @MainActor () -> Void) -> OutputObservation {
        let id = UUID(); lock.withLock { handlers[id] = onChange }
        return Observation { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: id) } }
    }
    @MainActor func setHeadphones(present: Bool) {
        let list = lock.withLock { headphonesPresent = present; return Array(handlers.values) }
        for handler in list { handler() }
    }
    private final class Observation: OutputObservation {
        private let onCancel: () -> Void
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        @MainActor func cancel() { onCancel() }
    }
}
#endif
