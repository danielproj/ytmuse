import Foundation

/// How update checks are scheduled. The default is `undecided`: nothing is requested, and the person is asked once (T30.3, BUILD06).
public enum UpdateCheckMode: String, Codable, Sendable, CaseIterable {
    case undecided      // never asked: no network request is made on this Mac's own initiative
    case daily          // the person opted in: at most one check a day while the app runs
    case manualOnly     // the person declined (or turned it off): only "Check Now" asks the network
}

extension UpdateCheckMode {
    /// The words Settings uses for this choice (the "Update checking" row): `askOnce` until the person answers, then `daily` or `manualOnly`.
    public var settingsValue: String { switch self { case .undecided: "askOnce"; case .daily: "daily"; case .manualOnly: "manualOnly" } }
}

public struct UpdateState: Codable, Equatable, Sendable {
    public var mode: UpdateCheckMode = .undecided
    /// "Automatic installation": a found update is downloaded and staged by itself, never while playing. It is NEVER swapped in without the person's
    /// explicit restart, whatever this says.
    public var automaticInstallation = false
    public var nextCheckAt: Date?
    public var lastCheckedAt: Date?
    /// The newest feed sequence accepted so far: an older feed is a rollback (replay of a stale, possibly vulnerable offer).
    public var lastAcceptedSequence = 0
    public init() {}
}

public protocol UpdateStateStore: Sendable {
    func load() -> UpdateState
    func save(_ state: UpdateState)
}

public final class InMemoryUpdateStateStore: UpdateStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state = UpdateState()
    public init() {}
    public func load() -> UpdateState { lock.lock(); defer { lock.unlock() }; return state }
    public func save(_ state: UpdateState) { lock.lock(); self.state = state; lock.unlock() }
}

/// The preferences store the app already uses (isolated under test). One JSON value under one key.
public final class UserDefaultsUpdateStateStore: UpdateStateStore, @unchecked Sendable {
    public static let key = "ytmuse.updates.state"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public func load() -> UpdateState {
        guard let data = defaults.data(forKey: Self.key), let state = try? JSONDecoder().decode(UpdateState.self, from: data) else { return UpdateState() }
        return state
    }
    public func save(_ state: UpdateState) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.key) }
    }
}
