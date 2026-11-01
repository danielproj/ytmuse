import Foundation

/// DIAG01, DIAG02. Where a fault came from. A source outage must be distinguishable from a local crash: the first is the service (or the network to it)
/// not answering, the second is this app's own process ending unexpectedly. Everything else is local or the person's doing.
public enum FaultOrigin: String, Codable, Sendable, CaseIterable { case source, network, local, user }

public enum DiagnosticCategory: String, Codable, Sendable, CaseIterable {
    /// The service did not answer, answered with a server fault, or throttled this client: nothing in the app is broken.
    case sourceOutage
    /// The service answered, but not in a shape the adapter's parser recognises: an upstream parser change. A deterministic reproduction is kept.
    case sourceChanged
    /// The service refused the session (expired or revoked): the person needs to sign in again.
    case authExpired
    /// This Mac could not reach the network at all.
    case networkOffline
    case storage
    case playbackFailure
    /// A request this app refused on its own policy (an unsafe link, an over-size response).
    case policyRefusal
    /// The previous run of this app ended without a clean quit.
    case localCrash
    case internalError

    public var origin: FaultOrigin {
        switch self {
        case .sourceOutage, .sourceChanged: .source
        case .authExpired: .user
        case .networkOffline: .network
        case .storage, .playbackFailure, .policyRefusal, .localCrash, .internalError: .local
        }
    }
    public var isSourceOutage: Bool { self == .sourceOutage }
}

/// One recorded event. The detail was redacted when the event was recorded and is redacted again, with the then-current context, when it is exported.
public struct DiagnosticEntry: Codable, Sendable, Equatable, Identifiable {
    /// An opaque local correlation id (SEC03): random, meaningful to nothing outside this log.
    public let id: String
    public let at: Date
    public let category: DiagnosticCategory
    /// A fixed vocabulary of components ("adapter", "playback", "downloads" ...), never a path or a title.
    public let component: String
    public let detail: String
    public init(id: String, at: Date, category: DiagnosticCategory, component: String, detail: String) { self.id = id; self.at = at; self.category = category; self.component = component; self.detail = detail }
}

/// The bounded, local, redacted error log. Nothing in it is ever sent anywhere; the only way out is a bundle the person exports.
public final class DiagnosticLog: @unchecked Sendable {
    public struct Limits: Sendable, Equatable {
        public var maxEntries: Int, maxAge: TimeInterval, maxDetailLength: Int
        public init(maxEntries: Int = 200, maxAge: TimeInterval = 14 * 86_400, maxDetailLength: Int = 400) { self.maxEntries = maxEntries; self.maxAge = maxAge; self.maxDetailLength = maxDetailLength }
        public static let standard = Limits()
    }
    private let lock = NSLock()
    private var entries: [DiagnosticEntry] = []
    private var context: RedactionContext
    private let limits: Limits
    private let clock: @Sendable () -> Date
    /// The context is read at every record and export: private names learned after an event (a playlist opened later) still scrub the earlier lines.
    private let contextProvider: @Sendable () -> RedactionContext
    public init(limits: Limits = .standard, clock: @escaping @Sendable () -> Date = { Date() }, context: @escaping @Sendable () -> RedactionContext = { .empty }) {
        self.limits = limits; self.clock = clock; self.contextProvider = context; self.context = context()
    }
    @discardableResult
    public func record(_ category: DiagnosticCategory, component: String, detail: String = "") -> DiagnosticEntry {
        let now = clock()
        let ctx = contextProvider()
        let safeComponent = Self.componentName(component)
        var safeDetail = DiagnosticRedactor.redact(detail, context: ctx)
        if safeDetail.count > limits.maxDetailLength { safeDetail = String(safeDetail.prefix(limits.maxDetailLength)) + "…" }
        let entry = DiagnosticEntry(id: Self.correlationID(), at: now, category: category, component: safeComponent, detail: safeDetail)
        lock.lock(); defer { lock.unlock() }
        context = ctx
        entries.append(entry)
        trim(now: now)
        return entry
    }
    /// Components are a vocabulary: anything that is not a short identifier is replaced, so a caller cannot smuggle a title or path in as a component.
    static func componentName(_ value: String) -> String {
        value.range(of: #"^[a-z][a-z0-9.-]{0,31}$"#, options: .regularExpression) != nil ? value : "unknown"
    }
    static func correlationID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased() }
    private func trim(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.at) > limits.maxAge }
        if entries.count > limits.maxEntries { entries.removeFirst(entries.count - limits.maxEntries) }
    }
    /// Newest last, redacted again with the current context.
    public func snapshot() -> [DiagnosticEntry] {
        let ctx = contextProvider()
        lock.lock(); defer { lock.unlock() }
        trim(now: clock())
        return entries.map { DiagnosticEntry(id: $0.id, at: $0.at, category: $0.category, component: $0.component, detail: DiagnosticRedactor.redact($0.detail, context: ctx)) }
    }
    public var count: Int { lock.lock(); defer { lock.unlock() }; trim(now: clock()); return entries.count }
    public func clear() { lock.lock(); entries.removeAll(); lock.unlock() }
    /// Counts per category, newest timestamp per category.
    public func summary() -> [CategoryCount] {
        let all = snapshot()
        return DiagnosticCategory.allCases.compactMap { category in
            let mine = all.filter { $0.category == category }
            return mine.isEmpty ? nil : CategoryCount(category: category, count: mine.count, last: mine.map(\.at).max()!)
        }
    }
    public struct CategoryCount: Codable, Sendable, Equatable { public let category: DiagnosticCategory; public let count: Int; public let last: Date }
}

/// The difference between a source outage and a crash (DIAG02). At launch the marker of the previous run is read: if it is still there, that run never
/// reached its clean quit. The marker holds a random run id and the time, nothing else.
public final class RunMarker: @unchecked Sendable {
    public enum Previous: Equatable, Sendable { case none, endedCleanly, endedUnexpectedly(since: Date) }
    private let url: URL
    private let fileManager = FileManager.default
    public init(directory: URL) { url = directory.appendingPathComponent("run-marker.json") }
    public func begin(now: Date = Date()) -> Previous {
        var previous = Previous.none
        if let data = try? Data(contentsOf: url), let marker = try? JSONDecoder().decode(Marker.self, from: data) {
            previous = marker.clean ? .endedCleanly : .endedUnexpectedly(since: marker.at)
        }
        write(Marker(run: UUID().uuidString, at: now, clean: false))
        return previous
    }
    public func endCleanly(now: Date = Date()) { write(Marker(run: UUID().uuidString, at: now, clean: true)) }
    private func write(_ marker: Marker) {
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private struct Marker: Codable { let run: String; let at: Date; let clean: Bool }
}
