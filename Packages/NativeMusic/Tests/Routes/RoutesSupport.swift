import Foundation
import OutputRoutes

// W22 test support. Synthetic, sanitized values only. NOTHING here (or in any test target) reads or changes a real device: the outputs are a scripted
// list and the engines are recorders. `OutputRoutesGuardTests` sweeps every test source to keep it that way.

let builtIn: UInt32 = 0x626C_746E, bluetooth: UInt32 = 0x626C_7565, usb: UInt32 = 0x7573_6220, airPlayCode: UInt32 = 0x6169_7270
let speakersSource: UInt32 = 0x6973_706B, headphonesSource: UInt32 = 0x6864_706E

enum Synthetic {
    static let speakers = OutputDevice(uid: "SYNTH-BUILT-IN", name: "Synthetic Speakers", transportCode: builtIn, dataSource: speakersSource, hasDeviceVolume: true)
    static let jackHeadphones = OutputDevice(uid: "SYNTH-BUILT-IN", name: "Synthetic Speakers", transportCode: builtIn, dataSource: headphonesSource, hasDeviceVolume: true)
    static let buds = OutputDevice(uid: "SYNTH-BT-BUDS", name: "Synthetic Buds", transportCode: bluetooth, hasDeviceVolume: true)
    /// Same display name as `buds`, a different device (two pairs of the same model).
    static let otherBuds = OutputDevice(uid: "SYNTH-BT-OTHER-BUDS", name: "Synthetic Buds", transportCode: bluetooth, hasDeviceVolume: true)
    static let dac = OutputDevice(uid: "SYNTH-USB-DAC", name: "Synthetic DAC", transportCode: usb)
    static let receiver = OutputDevice(uid: "SYNTH-AIRPLAY", name: "Synthetic Receiver", transportCode: airPlayCode)
}

/// A scripted list of outputs; `change` plays the part of the system announcing it.
final class ScriptedDirectory: OutputDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var current: OutputSnapshot
    private var handlers: [UUID: @MainActor () -> Void] = [:]
    private(set) var observers = 0
    init(_ devices: [OutputDevice], defaultUID: String?) { current = OutputSnapshot(devices: devices, defaultUID: defaultUID) }
    func snapshot() -> OutputSnapshot { lock.withLock { current } }
    @MainActor func observe(_ onChange: @escaping @MainActor () -> Void) -> OutputObservation {
        let id = UUID(); lock.withLock { handlers[id] = onChange; observers += 1 }
        return Subscription { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: id) } }
    }
    /// Replaces the list and announces it, in the caller's turn (as CoreAudio's main-queue listeners do).
    @MainActor func change(_ devices: [OutputDevice], defaultUID: String?) {
        let list = lock.withLock { current = OutputSnapshot(devices: devices, defaultUID: defaultUID); return Array(handlers.values) }
        for handler in list { handler() }
    }
    /// A notification that carries no change (a late or duplicate announcement).
    @MainActor func announceAgain() { for handler in lock.withLock({ Array(handlers.values) }) { handler() } }
    private final class Subscription: OutputObservation {
        let onCancel: () -> Void
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        @MainActor func cancel() { onCancel() }
    }
}

/// An engine that records every call in order and can be told to be slow or to refuse.
@MainActor final class RecordingEngine: OutputEngine {
    let kind: OutputEngineKind
    var backend: OutputBackend
    var audible = false
    var confirmsStop = true
    var acceptsApply = true
    /// Called inside `apply` before it returns, so a test can run another action while this one is "in flight".
    var duringApply: (@MainActor () async -> Void)?
    /// Called inside `stopForHandoff` before it returns (a stop that is still in flight).
    var duringStop: (@MainActor () async -> Void)?
    private(set) var log: [String] = []
    private(set) var applied: [String?] = []
    init(_ kind: OutputEngineKind, backend: OutputBackend? = nil) { self.kind = kind; self.backend = backend ?? (kind == .youTubeMusic ? .hiddenWebPlayer : .avPlayer) }
    var isAudibleOrWanted: Bool { audible }
    func pauseForRouteLoss() async -> Bool { log.append("pauseForRouteLoss"); audible = false; return true }
    func stopForHandoff() async -> Bool { log.append("stopForHandoff"); await duringStop?(); if confirmsStop { audible = false }; return confirmsStop }
    func apply(output uid: String?) async -> Bool {
        log.append("apply:\(uid ?? "default")"); applied.append(uid)
        await duringApply?()
        return acceptsApply
    }
    func started() { log.append("start"); audible = true }
}
