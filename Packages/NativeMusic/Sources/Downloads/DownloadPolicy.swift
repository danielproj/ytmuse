import Foundation
import Domain
#if canImport(Network)
import Network
#endif

/// OFF03/OFF04/OFF05 as pure rules. Nothing here touches a disk, a network or a clock, so every boundary is testable exactly.
public enum DownloadPolicy {
    public static let gibibyte: Int64 = 1 << 30
    public static let defaultBudget: Int64 = 20 * gibibyte
    public static let smartFractionOfBudget = 0.25
    /// Free space that must remain on the volume: the larger of 5 GiB and 5% of the volume.
    public static func reserve(volumeTotal: Int64) -> Int64 { max(5 * gibibyte, volumeTotal / 20) }
    public static func automaticCap(budget: Int64) -> Int64 { Int64(Double(budget) * smartFractionOfBudget) }
    public static func concurrencyLimit(lowPowerMode: Bool) -> Int { lowPowerMode ? 1 : 2 }

    /// What the retained bytes of one object cost on disk (ciphertext framing included), so budgets are not understated.
    public static func onDiskBytes(plain: Int64) -> Int64 {
        let chunks = (plain + Int64(EncryptedStore.chunkSize) - 1) / Int64(EncryptedStore.chunkSize)
        return plain + chunks * 60 + perObjectMetadataAllowance
    }
    /// What the ledger charges every object for its index and bookkeeping files, whatever their real size.
    public static let perObjectMetadataAllowance: Int64 = 4096

    public struct Ledger: Equatable, Sendable {
        /// Retained bytes across every account (OFF03: the budget spans accounts).
        public var usedAllAccounts: Int64
        /// Retained bytes that no policy may delete on its own: manual pins and collection references.
        public var protectedBytes: Int64
        /// Retained bytes of automatic (Smart) content, the only evictable class.
        public var automaticBytes: Int64
        /// Bytes already promised to other transfers in flight.
        public var inFlightBytes: Int64
        /// The part of `inFlightBytes` that belongs to automatic downloads: it counts toward the Smart cap like stored automatic bytes.
        public var inFlightAutomaticBytes: Int64
        public init(usedAllAccounts: Int64, protectedBytes: Int64, automaticBytes: Int64, inFlightBytes: Int64 = 0, inFlightAutomaticBytes: Int64 = 0) {
            self.usedAllAccounts = usedAllAccounts; self.protectedBytes = protectedBytes; self.automaticBytes = automaticBytes; self.inFlightBytes = inFlightBytes; self.inFlightAutomaticBytes = inFlightAutomaticBytes
        }
    }
    public enum Admission: Equatable, Sendable {
        case admit
        /// Pinned/collection content leaves no room even after dropping every automatic item: pause and offer choices.
        case budgetFullOfPinned
        /// Room exists only by evicting automatic content; the caller may evict then re-ask.
        case needsEviction(Int64)
        case volumeReserve
        case smartCapReached
    }
    /// Can `bytes` more be retained? `automatic` content also answers to the Smart cap and may never evict anything.
    public static func admission(bytes: Int64, volumeBytes: Int64? = nil, automatic: Bool, ledger: Ledger, budget: Int64, volumeTotal: Int64, volumeAvailable: Int64) -> Admission {
        let need = max(0, bytes)
        let volumeNeed = max(0, volumeBytes ?? bytes)
        // The reserve is about the volume itself: whatever else is going on, never write into the last 5 GiB / 5%.
        if volumeAvailable - volumeNeed < reserve(volumeTotal: volumeTotal) { return .volumeReserve }
        if automatic {
            if ledger.automaticBytes + ledger.inFlightAutomaticBytes + need > automaticCap(budget: budget) { return .smartCapReached }
            if ledger.usedAllAccounts + ledger.inFlightBytes + need > budget { return .budgetFullOfPinned }
            return .admit
        }
        let committed = ledger.usedAllAccounts + ledger.inFlightBytes
        if committed + need <= budget { return .admit }
        // Evicting automatic content would make room only if what remains fits.
        let afterEviction = committed - ledger.automaticBytes
        if afterEviction + need <= budget { return .needsEviction(committed + need - budget) }
        return .budgetFullOfPinned
    }
}

/// OFF05: measured path properties, never "Wi-Fi is unlimited".
public struct NetworkPathState: Equatable, Sendable {
    public var isAvailable: Bool
    public var isConstrained: Bool
    public var isExpensive: Bool
    public init(isAvailable: Bool = true, isConstrained: Bool = false, isExpensive: Bool = false) { self.isAvailable = isAvailable; self.isConstrained = isConstrained; self.isExpensive = isExpensive }
    public var isMetered: Bool { isConstrained || isExpensive }
}
public struct VolumeCapacity: Equatable, Sendable {
    public var total: Int64; public var available: Int64
    public init(total: Int64, available: Int64) { self.total = total; self.available = available }
}
public protocol VolumeCapacityProviding: Sendable { func capacity(at url: URL) -> VolumeCapacity }
public struct SystemVolumeCapacity: VolumeCapacityProviding {
    public init() {}
    /// Free space as Apple defines it for a user-initiated, important save: what is free plus what the system will purge on
    /// demand (the number Finder shows as Available). The reserve rule is then applied to that figure.
    public func capacity(at url: URL) -> VolumeCapacity {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let plain = Int64(values?.volumeAvailableCapacity ?? 0)
        let important = values?.volumeAvailableCapacityForImportantUsage ?? 0
        // Unknown capacity is treated as none left: a download must never write when the volume cannot be measured.
        return VolumeCapacity(total: Int64(values?.volumeTotalCapacity ?? 0), available: max(plain, important))
    }
}

/// OFF13: exponential backoff with jitter, bounded in count and in delay.
public struct RetryPolicy: Sendable, Equatable {
    public var base: TimeInterval; public var factor: Double; public var cap: TimeInterval; public var maxAttempts: Int
    public init(base: TimeInterval = 2, factor: Double = 2, cap: TimeInterval = 300, maxAttempts: Int = 6) { self.base = base; self.factor = factor; self.cap = cap; self.maxAttempts = maxAttempts }
    /// `attempt` counts consecutive failures from 1. `unit` is a random draw in 0...1 (injected for tests).
    public func delay(attempt: Int, unit: Double) -> TimeInterval {
        let raw = min(cap, base * pow(factor, Double(max(0, attempt - 1))))
        // Jitter keeps between half and all of the exponential delay so retries from many jobs do not synchronise.
        return raw * (0.5 + 0.5 * min(1, max(0, unit)))
    }
    public func exhausted(attempt: Int) -> Bool { attempt > maxAttempts }
}

public protocol NetworkPathProviding: Sendable {
    func current() -> NetworkPathState
    func observe(_ change: @escaping @Sendable (NetworkPathState) -> Void) -> @Sendable () -> Void
}
public protocol PowerStateProviding: Sendable {
    func lowPowerMode() -> Bool
    func observe(_ change: @escaping @Sendable (Bool) -> Void) -> @Sendable () -> Void
}
#if canImport(Network)
/// Reads `NWPath.isConstrained` and `isExpensive` as the system measures them.
public final class SystemNetworkPath: NetworkPathProviding, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "downloads.network-path")
    private let lock = NSLock()
    private var state = NetworkPathState()
    private var observers: [UUID: @Sendable (NetworkPathState) -> Void] = [:]
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let next = NetworkPathState(isAvailable: path.status == .satisfied, isConstrained: path.isConstrained, isExpensive: path.isExpensive)
            self.lock.lock(); let changed = next != self.state; self.state = next; let callbacks = Array(self.observers.values); self.lock.unlock()
            if changed { for callback in callbacks { callback(next) } }
        }
        monitor.start(queue: queue)
    }
    deinit { monitor.cancel() }
    public func current() -> NetworkPathState { lock.lock(); defer { lock.unlock() }; return state }
    public func observe(_ change: @escaping @Sendable (NetworkPathState) -> Void) -> @Sendable () -> Void {
        let id = UUID(); lock.lock(); observers[id] = change; lock.unlock()
        return { [weak self] in self?.lock.lock(); self?.observers[id] = nil; self?.lock.unlock() }
    }
}
#endif
public final class SystemPowerState: PowerStateProviding, @unchecked Sendable {
    public init() {}
    public func lowPowerMode() -> Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    public func observe(_ change: @escaping @Sendable (Bool) -> Void) -> @Sendable () -> Void {
        nonisolated(unsafe) let token = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in change(ProcessInfo.processInfo.isLowPowerModeEnabled) }
        return { NotificationCenter.default.removeObserver(token) }
    }
}
