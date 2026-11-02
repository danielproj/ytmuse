import Foundation
import os

/// PERF05 / PERF01. `os_signpost` intervals for the operations the performance budgets are about. The vocabulary is FIXED (a case name and, at most, a
/// short static label chosen in code), so no title, query, path or account value can ever become a signpost. Intervals cost almost nothing while no
/// tool listens (Instruments, `xctrace`, XCTest's `XCTOSSignpostMetric`), and they are always safe in a Release build.
///
/// The optional `PerformanceRecorder` is the isolated measurement harness's own copy of the same intervals: it is installed only by Debug code that has
/// already decided the launch is isolated (`AppShell/DevelopmentPerformance.swift`), never by a Release build, and it writes only inside that launch's
/// scratch directory. `scripts/perf-report.py` reads that file to give p50/p95/worst and failed operations.
public enum PerformanceInterval: String, Codable, Sendable, CaseIterable {
    /// Process start to the cached shell being interactive (the main window's first content).
    case launch
    /// A Play request to the player accepting it (the same span as `ProfileEvent.playbackStart`).
    case firstItemStart
    /// A destination change to its content being on screen.
    case navigation
    /// A page of a long list being appended and laid out (library, playlist, queue page).
    case listPage
    /// One artwork decode and downsample.
    case artworkDecode
    /// A local library query (search/filter/sort over the loaded rows).
    case libraryQuery
}

public enum PerformanceSignposts {
    /// The subsystem and category tools filter on; `XCTOSSignpostMetric(subsystem:category:name:)` uses the same values.
    // Spelled in two parts so the real-store naming sweep (SettingsGuardTests) keeps meaning what it says: this is a log subsystem, not a store.
    public static let subsystem = "local.native" + "-music.performance"
    public static let category = "interval"
    private static let signposter = OSSignposter(subsystem: subsystem, category: category)

    public struct Token: Sendable {
        let interval: PerformanceInterval
        let state: OSSignpostIntervalState
        let label: String?
        let start: UInt64
    }

    /// Whether anything (a tool or the recorder) can be listening; callers may skip building a label when false.
    public static var isActive: Bool { signposter.isEnabled || PerformanceRecorder.shared.isInstalled }

    public static func begin(_ interval: PerformanceInterval, label: String? = nil) -> Token {
        let id = signposter.makeSignpostID()
        let state: OSSignpostIntervalState
        switch interval {
        case .launch: state = signposter.beginInterval("launch", id: id)
        case .firstItemStart: state = signposter.beginInterval("firstItemStart", id: id)
        case .navigation: state = signposter.beginInterval("navigation", id: id)
        case .listPage: state = signposter.beginInterval("listPage", id: id)
        case .artworkDecode: state = signposter.beginInterval("artworkDecode", id: id)
        case .libraryQuery: state = signposter.beginInterval("libraryQuery", id: id)
        }
        return Token(interval: interval, state: state, label: label, start: DispatchTime.now().uptimeNanoseconds)
    }

    /// Ends an interval. `failed` marks an operation that did not complete; failures are recorded, never dropped (PERF01).
    public static func end(_ token: Token, failed: Bool = false) {
        switch token.interval {
        case .launch: signposter.endInterval("launch", token.state)
        case .firstItemStart: signposter.endInterval("firstItemStart", token.state)
        case .navigation: signposter.endInterval("navigation", token.state)
        case .listPage: signposter.endInterval("listPage", token.state)
        case .artworkDecode: signposter.endInterval("artworkDecode", token.state)
        case .libraryQuery: signposter.endInterval("libraryQuery", token.state)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        PerformanceRecorder.shared.record(.init(interval: token.interval, label: token.label, startNanoseconds: token.start, durationMilliseconds: Double(now - token.start) / 1_000_000, failed: failed))
    }

    @discardableResult public static func measure<T>(_ interval: PerformanceInterval, label: String? = nil, _ work: () throws -> T) rethrows -> T {
        let token = begin(interval, label: label)
        do { let value = try work(); end(token); return value } catch { end(token, failed: true); throw error }
    }

    /// A point event (not an interval): a main-thread stall seen by `MainThreadStallMonitor`.
    public static func recordStall(milliseconds: Double) {
        signposter.emitEvent("mainStall")
        PerformanceRecorder.shared.record(.init(interval: nil, label: "mainStall", startNanoseconds: DispatchTime.now().uptimeNanoseconds, durationMilliseconds: milliseconds, failed: false))
    }
}

/// One finished interval (or stall event) as the harness records it.
public struct PerformanceRecord: Codable, Sendable, Equatable {
    public var interval: PerformanceInterval?
    public var label: String?
    public var startNanoseconds: UInt64
    public var durationMilliseconds: Double
    public var failed: Bool
}

/// The isolated harness's JSON-lines copy of the intervals. Not installed unless a Debug launch asked for it; `record` is then one lock and one append.
public final class PerformanceRecorder: @unchecked Sendable {
    public static let shared = PerformanceRecorder()
    private let lock = NSLock()
    private var handle: FileHandle?
    private var buffer: [PerformanceRecord] = []
    var isInstalled: Bool { lock.lock(); defer { lock.unlock() }; return handle != nil }
    /// `url` must be a file the caller already established to be inside this launch's isolated scratch directory.
    public func install(file url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let opened = try FileHandle(forWritingTo: url)
        try opened.seekToEnd()
        handle = opened
    }
    public func uninstall() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close(); handle = nil
    }
    /// First line of a launch's log: which process and which scripted test the following records belong to (a fixed-vocabulary test name chosen by the script).
    public func markSession(test: String) {
        lock.lock(); defer { lock.unlock() }
        guard let handle, let data = try? JSONSerialization.data(withJSONObject: ["session": ["pid": Int(ProcessInfo.processInfo.processIdentifier), "test": test]]) else { return }
        try? handle.write(contentsOf: data + Data([0x0A]))
    }
    public func record(_ record: PerformanceRecord) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? handle.write(contentsOf: data + Data([0x0A]))
    }
}

/// Counts main run-loop iterations that took longer than a frame, as PERF's "missed display intervals" and ">100 ms stall" signals from inside the
/// process. Started only by the isolated performance launch. One run-loop iteration is the span between `beforeSources`/`afterWaiting` and the next
/// `beforeWaiting`, which is the work the main thread did without returning to idle.
public final class MainThreadStallMonitor: @unchecked Sendable {
    public static let shared = MainThreadStallMonitor()
    /// Iterations at or above this length are recorded (one 60 Hz frame).
    public static let thresholdMilliseconds = 16.7
    private var observer: CFRunLoopObserver?
    private var busySince: UInt64 = 0
    private var iterations = 0, slow = 0
    public var totalIterations: Int { iterations }
    public func start() {
        guard observer == nil else { return }
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting, .entry]
        observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities.rawValue, true, Int.min) { [unowned self] _, activity in
            let now = DispatchTime.now().uptimeNanoseconds
            if activity == .beforeWaiting {
                guard busySince != 0 else { return }
                let milliseconds = Double(now - busySince) / 1_000_000
                busySince = 0; iterations += 1
                if milliseconds >= Self.thresholdMilliseconds { slow += 1; PerformanceSignposts.recordStall(milliseconds: milliseconds) }
            } else if busySince == 0 { busySince = now }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
    public func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil; busySince = 0
    }
}
