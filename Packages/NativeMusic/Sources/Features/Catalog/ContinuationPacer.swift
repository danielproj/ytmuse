import Foundation

/// Spaces continuation requests per account scope: each request reserves the next free slot, one `interval` after the previous
/// one for the same scope, so fast scrolling, several shelves reaching their ends together, or a model asking again can never
/// send more than one continuation per interval for an account. The wait is served in order; nothing is dropped or reordered.
public actor ContinuationPacer {
    public typealias Now = @Sendable () -> Double
    public typealias Sleep = @Sendable (Double) async throws -> Void
    private let interval: Double
    private let now: Now
    private let sleep: Sleep
    private var next: [String: Double] = [:]
    public init(interval: Double = 1.0,
                now: @escaping Now = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }) {
        self.interval = max(0, interval); self.now = now; self.sleep = sleep
    }
    public func wait(scope: String) async throws {
        let current = now()
        let slot = max(current, next[scope] ?? current)
        next[scope] = slot + interval
        // Forget scopes whose slot has passed so the table stays small.
        if next.count > 64 { next = next.filter { $0.value > current } }
        let delay = slot - current
        if delay > 0 { try await sleep(delay) }
    }
}
