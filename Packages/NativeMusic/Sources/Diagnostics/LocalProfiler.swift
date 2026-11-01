import Domain
import Foundation

/// DIAG02. Opt-in, local, bounded profiling. OFF until the person turns it on; while off, `record` does nothing and no file exists. While on it keeps
/// aggregate timings for a FIXED vocabulary of events (so no title, search or path can ever be a sample), in memory, and writes one small JSON file that is
/// rewritten (never appended to) and capped. Turning it off deletes the file. Nothing is sent anywhere.
public enum ProfileEvent: String, Codable, Sendable, CaseIterable {
    /// From process start to the account being restored (or found absent).
    case launchToAccountReady
    /// A Music search, from the request to its answer or failure.
    case searchRequest
    /// A Play on the hidden YouTube Music player, from the request to the player accepting it.
    case playbackStart
}

public final class LocalProfiler: @unchecked Sendable {
    public struct Limits: Sendable, Equatable {
        public var maxSamplesPerEvent: Int, maxFileBytes: Int
        public init(maxSamplesPerEvent: Int = 100, maxFileBytes: Int = 64 * 1024) { self.maxSamplesPerEvent = maxSamplesPerEvent; self.maxFileBytes = maxFileBytes }
        public static let standard = Limits()
    }
    public struct Aggregate: Codable, Sendable, Equatable {
        public var count = 0, totalMilliseconds = 0.0, maxMilliseconds = 0.0
        public var recent: [Double] = []
    }
    private let lock = NSLock()
    private let url: URL
    private let limits: Limits
    private var on = false
    private var aggregates: [ProfileEvent: Aggregate] = [:]
    public init(directory: URL, limits: Limits = .standard) {
        url = directory.appendingPathComponent("profile.json"); self.limits = limits
    }
    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return on }
    public func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        on = enabled
        if !enabled { aggregates.removeAll(); try? GuardedFiles(root: url.deletingLastPathComponent()).remove(url) }
    }
    /// A no-op unless profiling is on.
    public func record(_ event: ProfileEvent, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard on else { return }
        var value = aggregates[event] ?? Aggregate()
        value.count += 1; value.totalMilliseconds += milliseconds; value.maxMilliseconds = max(value.maxMilliseconds, milliseconds)
        value.recent.append((milliseconds * 10).rounded() / 10)
        if value.recent.count > limits.maxSamplesPerEvent { value.recent.removeFirst(value.recent.count - limits.maxSamplesPerEvent) }
        aggregates[event] = value
        persist()
    }
    public func measure<T>(_ event: ProfileEvent, _ work: () throws -> T) rethrows -> T {
        guard isEnabled else { return try work() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer { record(event, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
        return try work()
    }
    public func status() -> ProfilingStatus {
        lock.lock(); defer { lock.unlock() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ProfilingStatus(enabled: on, sampleCount: aggregates.values.reduce(0) { $0 + $1.recent.count }, fileBytes: size ?? 0, maxFileBytes: limits.maxFileBytes)
    }
    public func summary() -> [ProfileEvent: Aggregate] { lock.lock(); defer { lock.unlock() }; return aggregates }
    /// Caller holds the lock. Shrinks the sample windows until the file fits; never exceeds the cap.
    private func persist() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var copy = aggregates
        var data = (try? encoder.encode(copy.mapKeys { $0.rawValue })) ?? Data()
        while data.count > limits.maxFileBytes, copy.values.contains(where: { !$0.recent.isEmpty }) {
            for key in Array(copy.keys) { let recent = copy[key]?.recent ?? []; copy[key]?.recent = Array(recent.dropFirst(max(1, recent.count / 2))) }
            data = (try? encoder.encode(copy.mapKeys { $0.rawValue })) ?? Data()
        }
        guard data.count <= limits.maxFileBytes else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] { Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) }) }
}
